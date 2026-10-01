#!/usr/bin/env bash
# setup.sh — configure this machine: pick bundles, then apply them via the engine.
#
# Manifest v2 flow (F9.6): the unit of selection is the BUNDLE (topic/bundle).
#   interactive (default on a TTY): run the blink-tui menu (scripts/menu), which
#     writes ~/.config/mesh/{selections.list,params.env}; then the engine applies
#     the selection. If the menu is not built yet, fall back to default selections.
#   --non-interactive / NON_INTERACTIVE=1: skip the menu. Honor an existing
#     selections.list if present; otherwise compute the default selection
#     (every bundle except those with default_selected:false) and let the engine
#     resolve silent option defaults.
#
# State (spec §4.6, ratified D-15):
#   ~/.config/mesh/{selections.list,params.env}  — menu/user state
#   ~/.local/state/mesh/{installed/,secrets.env}  — machine/install state
#
# Env vars (primarily for automation/CI):
#   NON_INTERACTIVE=1     skip the menu even on a TTY
#   DRY_RUN=1             print what the engine would do without executing
#   MESH_IDENTITY_REPO    identity repo URL (used by ai / personal topics)
#   MESH_IDENTITY_DIR     where to clone the identity repo (default ~/mesh-identity)
#   CODE_DIR              dev root — where your repos live (default ~/code). Asked
#                         in the menu (dev-root screen); persisted to config.env.
#   NO_COLOR=1            disable colored output (auto if not a TTY)
#
# Usage: bash setup.sh [--help] [--non-interactive] [--dry-run] [--list-bundles]
#                      [--no-mesh] [--bundle topic/bundle]...
set -euo pipefail

# Minimal shells (docker run, `su -`, env -i) leave $USER unset even with a real
# uid. `id -un` always works. Exported so every item script sees a consistent value.
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$HERE"
export MESH_WORKSTATION_DIR="${MESH_WORKSTATION_DIR:-$HERE}"

# ─── arg parsing (introspection flags exit before any side effects) ──────────
NON_INTERACTIVE="${NON_INTERACTIVE:-0}"
DRY_RUN="${DRY_RUN:-0}"
LIST_BUNDLES=0
REPAIR_MODE=0
ADOPT_MODE=0
CLI_BUNDLES=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --help|-h)         SHOW_HELP=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --dry-run)         DRY_RUN=1; shift ;;
        --list-bundles)    LIST_BUNDLES=1; shift ;;
        --no-mesh)
            MESH_NO_MESH=1
            export MESH_NO_MESH
            shift
            ;;
        --bundle)
            if [[ $# -lt 2 || "$2" == -* ]]; then
                echo "setup.sh: --bundle needs a topic/bundle argument" >&2
                exit 64
            fi
            CLI_BUNDLES+=("$2")
            shift 2
            ;;
        --repair)          REPAIR_MODE=1; shift ;;
        --adopt)           ADOPT_MODE=1; shift ;;
        *) echo "setup.sh: unknown arg: $1 (try --help)" >&2; exit 64 ;;
    esac
done
# Explicit --bundle list is a headless selection; never open the menu over it.
[[ "${#CLI_BUNDLES[@]}" -gt 0 ]] && NON_INTERACTIVE=1
# --repair (verify/operational plan §C, via `mesh doctor --fix`): a verify+repair
# sweep, never the menu. Force non-interactive so the menu is skipped and any
# unset option falls back to its silent default; the engine repairs only items
# with an install marker (so the selection just scopes the sweep).
[[ "$REPAIR_MODE" == "1" ]] && NON_INTERACTIVE=1
# --adopt (scanner-marker-coherence handoff, via `mesh adopt`): a READ-ONLY
# marker backfill, never the menu. Force non-interactive (skip menu + silent
# option defaults); the engine writes a marker for every already-present item
# that lacks one — no install/deploy/sudo. Scopes over ALL bundles (below) so
# opt-in tools installed under v1 also get a marker.
[[ "$ADOPT_MODE" == "1" ]] && NON_INTERACTIVE=1
if [[ "$ADOPT_MODE" == "1" && "$REPAIR_MODE" == "1" ]]; then
    echo "setup.sh: --adopt and --repair are mutually exclusive" >&2; exit 64
fi
export NON_INTERACTIVE DRY_RUN

# shellcheck disable=SC1091
source "$HERE/scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/scripts/lib/no-mesh.sh"

usage() {
    cat <<'EOF'
mesh-workstation — set up a development machine

Interactive mode (default on a TTY):
  bash setup.sh                  pick bundles in the menu, then apply

Automation / CI mode:
  NON_INTERACTIVE=1 bash setup.sh   skip the menu (use saved or default selection)
  bash setup.sh --non-interactive   same, flag form
  DRY_RUN=1 bash setup.sh           print what the engine would do, don't execute
  bash setup.sh --dry-run           same, flag form
  bash setup.sh --list-bundles      list every topic/bundle + default selection
  bash setup.sh --no-mesh           omit membership: mesh bundles from the catalog
                                    (exports MESH_NO_MESH=1 before the menu);
                                    headless default is foundation/base only
  bash setup.sh --bundle T/B        add topic/bundle to the headless selection
                                    (repeatable; implies --non-interactive)
  bash setup.sh --repair            verify+repair installed-but-broken items only
                                    (no menu; engine --repair; = mesh doctor --fix)
  bash setup.sh --adopt             read-only: backfill install markers for tools
                                    already present but unmarked (v1→v2 machines);
                                    no install/deploy/sudo (= mesh adopt)

Selection lives in ~/.config/mesh/selections.list (one topic/bundle per line);
resolved non-secret options in ~/.config/mesh/params.env. Delete selections.list
to reset to defaults. See topics/*/README.md for per-topic docs.
EOF
}

if [[ "${SHOW_HELP:-0}" == "1" ]]; then usage; exit 0; fi

# ─── enumerate manifests + default selection ─────────────────────────────────
# Default selection = every bundle whose default_selected is not false (required
# bundles are always in; parser omits the field when absent, so we apply the
# spec defaults required=0 / default_selected=1 via ${VAR:-default}).
# Lean first-run when the Blink menu cannot open (usually: Node not on PATH yet).
# Installs the required shell/foundation path + Node so a second interactive
# `bash setup.sh` can open the menu. Avoids silently applying the full
# default-on fleet (DBs, web, AI, …) without operator consent.
# Under MESH_NO_MESH=1 the membership bundles (identity/personal) are omitted;
# see no_mesh_emit_lean_bootstrap. Headless `--non-interactive --no-mesh` does
# not set MESH_LEAN_BOOTSTRAP and still emits only foundation/base.
emit_lean_bootstrap_selections() {
    printf '%s\n' \
        foundation/base \
        identity/identity \
        git/config \
        shell-terminal/cli-tools \
        shell-terminal/zsh \
        shell-terminal/fonts \
        languages/node \
        personal/personal
}

emit_default_selections() {
    # Menu-unavailable lean bootstrap must win over the no-mesh headless
    # default. Otherwise `bash setup.sh --no-mesh` on a virgin box (no Node)
    # installs only foundation/base, never gets Node, and can never open the
    # menu on a second run.
    if [[ "${MESH_LEAN_BOOTSTRAP:-0}" == "1" ]]; then
        if no_mesh_active; then
            no_mesh_emit_lean_bootstrap
        else
            emit_lean_bootstrap_selections
        fi
        return 0
    fi
    if no_mesh_emit_default_or_bundles; then
        return 0
    fi
    local mf topic vf
    for mf in "$HERE"/topics/*/manifest.yaml; do
        [[ -f "$mf" ]] || continue
        topic="$(basename "$(dirname "$mf")")"
        vf="$(bash "$HERE/scripts/lib/yaml-parse.sh" < "$mf" 2>/dev/null)" || continue
        (
            eval "$vf"
            [[ "${__YAML_PARSE_OK:-0}" == "1" ]] || exit 0
            local n="${BUNDLE_COUNT:-0}" i name_v ds_v req_v name ds req
            for ((i=0; i<n; i++)); do
                name_v="BUNDLE_${i}_NAME"; ds_v="BUNDLE_${i}_DEFAULT_SELECTED"; req_v="BUNDLE_${i}_REQUIRED"
                name="${!name_v:-}"; ds="${!ds_v:-1}"; req="${!req_v:-0}"
                [[ -n "$name" ]] || continue
                if [[ "$req" == "1" || "$ds" != "0" ]]; then
                    printf '%s/%s\n' "$topic" "$name"
                fi
            done
        )
    done
}

# Every bundle, ignoring required / default_selected. Used by --adopt so the
# read-only marker backfill probes opt-in bundles too (a v1 machine may have
# installed Docker/MSSQL/etc.); the menu can then show true state for all of them.
emit_all_selections() {
    local mf topic vf
    for mf in "$HERE"/topics/*/manifest.yaml; do
        [[ -f "$mf" ]] || continue
        topic="$(basename "$(dirname "$mf")")"
        vf="$(bash "$HERE/scripts/lib/yaml-parse.sh" < "$mf" 2>/dev/null)" || continue
        (
            eval "$vf"
            [[ "${__YAML_PARSE_OK:-0}" == "1" ]] || exit 0
            local n="${BUNDLE_COUNT:-0}" i name_v name
            for ((i=0; i<n; i++)); do
                name_v="BUNDLE_${i}_NAME"; name="${!name_v:-}"
                [[ -n "$name" ]] || continue
                printf '%s/%s\n' "$topic" "$name"
            done
        )
    done
}

if [[ "$LIST_BUNDLES" == "1" ]]; then
    # topic/bundle  [default|opt-out]
    for mf in "$HERE"/topics/*/manifest.yaml; do
        [[ -f "$mf" ]] || continue
        topic="$(basename "$(dirname "$mf")")"
        vf="$(bash "$HERE/scripts/lib/yaml-parse.sh" < "$mf" 2>/dev/null)" || continue
        (
            eval "$vf"
            [[ "${__YAML_PARSE_OK:-0}" == "1" ]] || exit 0
            n="${BUNDLE_COUNT:-0}"
            for ((i=0; i<n; i++)); do
                name_v="BUNDLE_${i}_NAME"; ds_v="BUNDLE_${i}_DEFAULT_SELECTED"; req_v="BUNDLE_${i}_REQUIRED"
                mem_v="BUNDLE_${i}_MEMBERSHIP"
                name="${!name_v:-}"; ds="${!ds_v:-1}"; req="${!req_v:-0}"
                mem="${!mem_v:-}"
                [[ -n "$name" ]] || continue
                no_mesh_omit_bundle "$mem" && continue
                # Under --no-mesh the unlock list loses required locks and starts
                # unchecked (mirrors applyNoMeshUnlocks in the Blink menu).
                if no_mesh_is_unlock_key "$topic/$name"; then
                    req=0
                    ds=0
                fi
                if [[ "$req" == "1" ]]; then mark="required"
                elif [[ "$ds" == "0" ]]; then mark="opt-in (default off)"
                else mark="default on"; fi
                printf '%-32s %s\n' "$topic/$name" "$mark"
            done
        )
    done
    exit 0
fi

# ─── persistent state + secrets (sourced before the engine) ──────────────────
# Canonical state dir is ~/.local/state/mesh; finish the dev-bootstrap →
# mesh-workstation → mesh rename one-shot before anything reads state (T-004).
# shellcheck disable=SC1091
source "$HERE/scripts/lib/state-dir.sh"
[[ "$DRY_RUN" != "1" ]] && mesh_migrate_legacy_state
MESH_STATE_DIR="$(mesh_state_dir)"; export MESH_STATE_DIR
[[ "$DRY_RUN" != "1" ]] && mkdir -p "$MESH_STATE_DIR"

# Secrets (input-only tokens). Sourced so item scripts read them via env; the
# engine also sources them per bundle. See lib/secrets.sh for the key taxonomy.
# MESH_STATE_DIR is already the canonical mesh dir, so secrets.sh resolves
# MESH_SECRETS_FILE there (the legacy override removed — fixed T-004 F2).
# shellcheck disable=SC1091
source "$HERE/scripts/lib/secrets.sh"
secrets_load || warn "secrets file present but could not be sourced — continuing without it"

# Persisted decisions (e.g. a previously chosen BREW_PREFIX). See lib/state.sh.
# shellcheck disable=SC1091
source "$HERE/scripts/lib/state.sh"
state_load

# Defaults inherited by item scripts that read non-option env directly.
export MESH_IDENTITY_REPO="${MESH_IDENTITY_REPO:-}"
export MESH_IDENTITY_DIR="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"
export CODE_DIR="${CODE_DIR:-$HOME/code}"
export NO_COLOR="${NO_COLOR:-}"

# ─── mesh symlink (~/.local/bin/mesh → bin/mesh) ─────────────────────────────
install_mesh_symlink() {
    local dst="$HOME/.local/bin/mesh" target="$HERE/bin/mesh"
    if [[ -e "$HOME/.local/bin" && ! -d "$HOME/.local/bin" ]]; then
        warn "$HOME/.local/bin is not a directory — skipping mesh symlink install"; return 0
    fi
    if [[ "$DRY_RUN" == "1" ]]; then
        echo "+ ln -sf $target $dst  [dry-run, skipped]"; return 0
    fi
    mkdir -p "$HOME/.local/bin"
    if [[ -L "$dst" && "$(readlink "$dst")" == "$target" ]]; then return 0; fi
    # A machine provisioned by the v1 system has a REGULAR FILE here (the
    # pre-rename `scripts/mesh` dispatcher, no doctor/adopt). Take ownership:
    # back it up (the deploy driver's .bak-<TS> pattern) and install the shim,
    # so v1-migrated boxes self-heal instead of keeping the stale dispatcher.
    if [[ -e "$dst" && ! -L "$dst" ]]; then
        local backup
        backup="$dst.bak-$(date +%Y%m%d-%H%M%S)"
        if ! mv "$dst" "$backup"; then
            warn "$dst is a regular file and could not be backed up — leaving alone"; return 0
        fi
        warn "$dst was a regular file (pre-v2 dispatcher) — backed up to $backup; installing the bin/mesh symlink"
    fi
    ln -sf "$target" "$dst"
}
install_mesh_symlink

# ─── pre-flight: ensure gh CLI + auth for GitHub API access ───────────────────
# In --no-mesh mode the identity bundle (which installs gh and runs gh auth
# login) is filtered out. Downstream items call gh_api_curl() / gh_latest_tag()
# from github-api.sh, which need a token to avoid the 60-req/hour anonymous
# rate limit. This pre-flight installs gh and prompts for auth BEFORE the
# engine so that every item script can authenticate.
# Never fatal — every failure path warns and degrades to anonymous API access.
_preflight_gh_auth() {
    # 1. Already authenticated → nothing to do.
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
        info "gh CLI already authenticated — skipping pre-flight auth"
        return 0
    fi

    # 2. Token already in env → API access is fine, no need for gh auth.
    if [[ -n "${GITHUB_TOKEN:-}" || -n "${GH_TOKEN:-}" ]]; then
        info "GITHUB_TOKEN / GH_TOKEN found in env — skipping pre-flight auth"
        return 0
    fi

    # 3. Install gh if not on PATH.
    if ! command -v gh >/dev/null 2>&1; then
        info "installing gh CLI for GitHub API access…"
        if [[ "$OS" == "wsl" || "$OS" == "linux" ]]; then
            if apt-cache show gh >/dev/null 2>&1; then
                sudo apt-get update -qq && sudo apt-get install -y -qq gh || {
                    warn "gh install via apt failed — GitHub API will use anonymous access (60 req/hour)"
                    return 0
                }
            else
                # Fallback: add GitHub's official APT repo (older distros).
                sudo mkdir -p -m 755 /etc/apt/keyrings \
                    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
                        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null \
                    && sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
                    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
                        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null \
                    && sudo apt-get update -qq \
                    && sudo apt-get install -y -qq gh || {
                    warn "gh install via GitHub APT repo failed — GitHub API will use anonymous access (60 req/hour)"
                    return 0
                }
            fi
        elif [[ "$OS" == "mac" ]]; then
            if [[ -n "${BREW_BIN:-}" ]]; then
                "$BREW_BIN" install gh || {
                    warn "gh install via brew failed — GitHub API will use anonymous access (60 req/hour)"
                    return 0
                }
            else
                warn "brew not available — cannot install gh; GitHub API will use anonymous access (60 req/hour)"
                return 0
            fi
        else
            warn "unsupported OS for gh pre-flight install — GitHub API will use anonymous access (60 req/hour)"
            return 0
        fi

        if ! command -v gh >/dev/null 2>&1; then
            warn "gh installed but not found on PATH — GitHub API will use anonymous access (60 req/hour)"
            return 0
        fi
        ok "gh CLI installed"
    fi

    # 4. Authenticate gh if not already logged in.
    if ! gh auth status >/dev/null 2>&1; then
        if [[ -t 0 && -e /dev/tty ]]; then
            info "authenticating gh CLI (opens a browser for GitHub login)…"
            gh auth login --web --git-protocol https </dev/tty >/dev/tty 2>&1 || {
                warn "gh auth login cancelled or failed — GitHub API will use anonymous access (60 req/hour)"
                return 0
            }
            ok "gh CLI authenticated"
        else
            warn "non-interactive session with no GitHub token — GitHub API will use anonymous access (60 req/hour)"
            warn "run 'gh auth login' manually, or set GITHUB_TOKEN, to raise the rate limit"
            return 0
        fi
    fi

    # 5. Configure git user.name / user.email if not already set.
    #    Uses the authenticated gh account as a default suggestion.
    if [[ -z "$(git config --global user.name 2>/dev/null)" || -z "$(git config --global user.email 2>/dev/null)" ]]; then
        if [[ -t 0 && -e /dev/tty ]]; then
            # Try to fetch defaults from the authenticated GitHub account.
            local gh_name gh_email
            gh_name="$(gh api user --jq '.name // empty' 2>/dev/null)" || gh_name=""
            gh_email="$(gh api user --jq '.email // empty' 2>/dev/null)" || gh_email=""

            if [[ -z "$(git config --global user.name 2>/dev/null)" ]]; then
                local prompt="git user.name"
                [[ -n "$gh_name" ]] && prompt="git user.name [${gh_name}]"
                printf '%s: ' "$prompt" >/dev/tty
                local input_name
                read -r input_name </dev/tty
                input_name="${input_name:-$gh_name}"
                if [[ -n "$input_name" ]]; then
                    git config --global user.name "$input_name"
                    ok "git user.name set to '$input_name'"
                else
                    warn "git user.name left unconfigured — git commits will fail until set"
                fi
            fi

            if [[ -z "$(git config --global user.email 2>/dev/null)" ]]; then
                local prompt="git user.email"
                [[ -n "$gh_email" ]] && prompt="git user.email [${gh_email}]"
                printf '%s: ' "$prompt" >/dev/tty
                local input_email
                read -r input_email </dev/tty
                input_email="${input_email:-$gh_email}"
                if [[ -n "$input_email" ]]; then
                    git config --global user.email "$input_email"
                    ok "git user.email set to '$input_email'"
                else
                    warn "git user.email left unconfigured — git commits will fail until set"
                fi
            fi
        else
            warn "git user.name/email not configured and no TTY — git commits will fail until set"
            warn "run: git config --global user.name 'Your Name' && git config --global user.email 'you@example.com'"
        fi
    fi
}

# ─── detect OS + brew ────────────────────────────────────────────────────────
OS="$(bash "$HERE/scripts/lib/detect-os.sh")"
export OS MESH_OS="$OS"
[[ "$OS" == "unknown" ]] && { fail "unsupported OS (uname -s = $(uname -s))"; exit 1; }

banner "mesh-workstation :: $OS"

BREW_BIN=""; BREW_PREFIX=""
detect_brew_if_mac() {
    [[ "$OS" == "mac" ]] || return 0
    if out=$(bash "$HERE/scripts/lib/detect-brew.sh" 2>/dev/null); then
        eval "$out"; export BREW_BIN BREW_PREFIX
        if [[ -n "${BREW_PREFIX:-}" && ":$PATH:" != *":$BREW_PREFIX/bin:"* ]]; then
            PATH="$BREW_PREFIX/bin:$BREW_PREFIX/sbin:$PATH"; export PATH
        fi
    fi
}
detect_brew_if_mac
if [[ "$OS" == "mac" ]]; then
    if [[ -n "$BREW_BIN" ]]; then
        info "brew found at $BREW_BIN (prefix $BREW_PREFIX)"
    else
        # Ask here, in this process. The engine below is piped through tee, so
        # foundation's own prefix prompt never sees a TTY. The answer is exported
        # as BREW_CUSTOM_PREFIX, which foundation's decision ladder already honors.
        # shellcheck disable=SC1091
        source "$HERE/scripts/lib/brew-prefix-offer.sh"
        offer_separate_brew_prefix || exit 1
    fi
fi

# ─── sudo warmup + legacy NOPASSWD cleanup ───────────────────────────────────
# Skipped under --adopt: a read-only marker backfill must never warm sudo or
# mutate sudoers (its probes are check()/verify() only — no privileged action).
#
# `sudo -v` prompts when %sudo requires a password (verifypw=all), even if a
# later NOPASSWD:ALL matches. WSL still allocates a pts, so hiding sudo
# validate behind a redirected stderr hangs forever on NON_INTERACTIVE / piped runs.
if [[ "$DRY_RUN" != "1" && "$ADOPT_MODE" != "1" ]]; then
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]] || ! [[ -t 0 && -t 1 ]]; then
        sudo -n -v >/dev/null 2>&1 || warn "sudo cache warmup failed (non-fatal — items will prompt individually)"
    else
        sudo -v || warn "sudo cache warmup failed (non-fatal — items will prompt individually)"
    fi
fi
# Pre-v2026-04-22 remote-access left a permanent NOPASSWD sudoers entry.
# Clean it up unconditionally so forks inherit the fix.
if [[ ( "$OS" == "wsl" || "$OS" == "linux" ) && "$DRY_RUN" != "1" && "$ADOPT_MODE" != "1" ]]; then
    legacy_nopasswd="/etc/sudoers.d/10-${USER}-nopasswd"
    if [[ -f "$legacy_nopasswd" ]] || sudo test -f "$legacy_nopasswd" 2>/dev/null; then
        info "removing legacy NOPASSWD sudoers entry at $legacy_nopasswd"
        sudo rm -f "$legacy_nopasswd" && ok "legacy NOPASSWD sudoers removed"
    fi
fi

# Consolidated follow-up summary file (item scripts append via `followup`).
MESH_FOLLOWUP_FILE="$(mktemp -t mesh-workstation-followup.XXXXXX 2>/dev/null || mktemp)"
export MESH_FOLLOWUP_FILE
trap 'rm -f "${MESH_FOLLOWUP_FILE:-}"' EXIT

# Pre-flight gh auth: install gh + prompt login so downstream items that call
# gh_api_curl() / gh_latest_tag() get an authenticated token. Skipped under
# --dry-run (no side effects) and --adopt (read-only marker backfill).
if [[ "$DRY_RUN" != "1" && "$ADOPT_MODE" != "1" ]]; then
    _preflight_gh_auth
fi

# ─── resolve the selection ───────────────────────────────────────────────────
SELECTIONS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/mesh"
SELECTIONS_FILE="$SELECTIONS_DIR/selections.list"
# Bundles the menu computed as deselected-since-last-apply (computeDelta.remove).
# The menu writes them here; the Apply runs uninstall-engine on them BEFORE the
# install pass, then deletes the file. Headless runs have no menu/delta → no
# file → install-only (marker-diff for headless is future work, see handoff).
REMOVALS_FILE="$SELECTIONS_DIR/removals.list"
MENU_DIR="$HERE/scripts/menu"

run_menu_if_available() {
    # Propagates the menu's exit status so the caller can tell apart:
    #   0   = applied (wrote selections.list)         → use the selection
    #   130 = user quit / Ctrl-C (EXIT_CANCEL)         → abort the whole run
    #   2   = menu not present / Node missing          → fall back to default
    #   *   = no TTY (app.tsx) / crashed               → fall back to default
    [[ -f "$MENU_DIR/index.js" || -f "$MENU_DIR/dist/index.js" ]] || return 2
    command -v node >/dev/null 2>&1 || { warn "Node.js not found — cannot run the setup menu"; return 2; }
    info "launching the bundle menu…"
    # Dependency provisioning lives in the launcher (scripts/menu/index.js), not
    # here: it is the single entry every path runs (`node index.js`), so a fresh
    # OR stale machine self-heals there with `npm ci` against the committed
    # lockfile — no duplicated guard, no "go run npm" prompt. If it cannot
    # provision (offline), index.js exits non-zero and the caller below falls
    # back to the saved/default selection.
    node "$MENU_DIR/index.js"
}

should_run_menu() {
    [[ "$NON_INTERACTIVE" == "1" || "$DRY_RUN" == "1" ]] && return 1
    [[ -t 0 && -t 1 ]] || return 1
    return 0
}

if should_run_menu; then
    run_menu_if_available; menu_rc=$?
    if [[ "$menu_rc" -eq 130 ]]; then
        # The user explicitly quit the menu (q / Ctrl-C). Honour it: apply
        # nothing, do NOT silently fall back to the default selection.
        info "menu cancelled — nothing was applied."
        exit 130
    elif [[ "$menu_rc" -ne 0 ]]; then
        # Menu not built / Node missing / crashed — do NOT flip NON_INTERACTIVE.
        # That flag means the operator asked for headless; missing Node must not
        # block personal identity TTY prompts. Use a lean bootstrap selection
        # (foundation + shell + node + personal) instead of the full default-on
        # fleet so virgin machines get Node/PATH without surprise DB/web installs.
        warn "interactive bundle menu unavailable — using lean bootstrap selection (foundation/shell/node/personal)"
        warn "re-run bash setup.sh after Node is on PATH to open the full Blink menu"
        MESH_LEAN_BOOTSTRAP=1; export MESH_LEAN_BOOTSTRAP
        # selections.list is only rewritten when absent. A stale/synced file would
        # keep MESH_LEAN_BOOTSTRAP inert and skip languages/node. When Node itself
        # is missing, clear it so lean bootstrap actually runs.
        if ! command -v node >/dev/null 2>&1; then
            rm -f "$SELECTIONS_FILE"
        fi
        followup info "Blink menu was skipped (Node missing or menu failed). After this run, open a new shell and re-run bash setup.sh for the full picker."
    fi
    # menu_rc == 0 → selections.list was written; proceed with it.
fi

# ─── persist the dev root (CODE_DIR) for the interactive shell ────────────────
# The menu writes CODE_DIR to params.env (the engine sources it, so the web stack
# gets the right site root at install time). But the interactive shell reads
# ~/.config/mesh/config.env, NOT params.env — mesh-identity's shell/aliases.sh
# sources config.env for auto-cd + the tmux project shortcuts. Bridge the two:
# lift CODE_DIR from params.env into config.env (idempotent line upsert that
# leaves every other line — repo paths, the AUTO_UPDATE_REPOS array — untouched),
# and re-export it so the post-menu engine pass inherits the chosen value.
persist_code_dir() {
    [[ "$DRY_RUN" == "1" ]] && return 0
    local params="$SELECTIONS_DIR/params.env" config="$SELECTIONS_DIR/config.env"
    [[ -f "$params" ]] || return 0
    # Source in a subshell so bash applies the same quoting it wrote — never
    # leaks the other KEY=values into setup.sh's environment.
    local chosen
    # shellcheck source=/dev/null
    chosen="$(set +u; . "$params" >/dev/null 2>&1; printf '%s' "${CODE_DIR:-}")"
    [[ -n "$chosen" ]] || return 0
    export CODE_DIR="$chosen"
    mkdir -p "$SELECTIONS_DIR"
    local tmp; tmp="$(mktemp "$SELECTIONS_DIR/.config.env.XXXXXX")" || return 0
    {
        [[ -f "$config" ]] && grep -v '^CODE_DIR=' "$config"
        printf 'CODE_DIR=%q\n' "$chosen"
    } > "$tmp" && mv "$tmp" "$config" || { rm -f "$tmp"; return 0; }
    info "dev root persisted: CODE_DIR=$chosen → ${config/#$HOME/\~}"
}
persist_code_dir

# ─── persist workstation dir for the interactive shell and subshells ─────────
persist_workstation_dir() {
    [[ "$DRY_RUN" == "1" ]] && return 0
    local config="$SELECTIONS_DIR/config.env"
    local dir="${MESH_WORKSTATION_DIR:-$HERE}"
    [[ -n "$dir" ]] || return 0
    export MESH_WORKSTATION_DIR="$dir"
    mkdir -p "$SELECTIONS_DIR"
    local tmp; tmp="$(mktemp "$SELECTIONS_DIR/.config.env.XXXXXX")" || return 0
    {
        [[ -f "$config" ]] && grep -v '^MESH_WORKSTATION_DIR=' "$config"
        printf 'MESH_WORKSTATION_DIR=%q\n' "$dir"
    } > "$tmp" && mv "$tmp" "$config" || { rm -f "$tmp"; return 0; }
    info "workstation dir persisted: MESH_WORKSTATION_DIR=$dir → ${config/#$HOME/\~}"
}
persist_workstation_dir

if [[ "$ADOPT_MODE" == "1" ]]; then
    # Adopt probes EVERY bundle (not just the default/saved selection) so an
    # opt-in tool installed under v1 also gets its marker. Never persist a
    # selections.list as a side effect; feed the engine via a temp file. The
    # user's real selections.list (if any) is left untouched.
    SELECTIONS_FILE="$(mktemp -t mesh-adopt.XXXXXX)"
    trap 'rm -f "${MESH_FOLLOWUP_FILE:-}" "'"$SELECTIONS_FILE"'"' EXIT
    {
        echo "# mesh adopt — all bundles (read-only marker-backfill scope)"
        emit_all_selections
    } > "$SELECTIONS_FILE"
elif [[ ! -f "$SELECTIONS_FILE" || "${#CLI_BUNDLES[@]}" -gt 0 ]]; then
    # No saved list, or explicit --bundle overrides: compute the selection.
    # --bundle always rebuilds the list (headless contract). Under --no-mesh the
    # default is foundation/base only; with --bundle, foundation/base + bundles.
    if [[ "${#CLI_BUNDLES[@]}" -gt 0 ]]; then
        info "computing selection from --bundle (${#CLI_BUNDLES[@]} explicit)"
    else
        info "no selections.list — computing the default selection"
    fi
    mkdir -p "$SELECTIONS_DIR"
    if [[ "$REPAIR_MODE" == "1" ]]; then
        # Don't persist a selections.list as a side effect of a --repair sweep;
        # feed the engine via a temp file (repair only touches marker-present
        # items anyway, so the default set merely scopes it).
        SELECTIONS_FILE="$(mktemp -t mesh-selections.XXXXXX)"
        trap 'rm -f "${MESH_FOLLOWUP_FILE:-}" "'"$SELECTIONS_FILE"'"' EXIT
    elif [[ "$DRY_RUN" == "1" ]] && ! no_mesh_active && [[ "${#CLI_BUNDLES[@]}" -eq 0 ]]; then
        # Unflagged dry-run: avoid persisting a full default-on fleet list.
        SELECTIONS_FILE="$(mktemp -t mesh-selections.XXXXXX)"
        trap 'rm -f "${MESH_FOLLOWUP_FILE:-}" "'"$SELECTIONS_FILE"'"' EXIT
    fi
    {
        if [[ "${#CLI_BUNDLES[@]}" -gt 0 ]]; then
            echo "# mesh selections — from --bundle"
            if no_mesh_emit_default_or_bundles "${CLI_BUNDLES[@]}"; then
                :
            else
                printf '%s\n' "${CLI_BUNDLES[@]}"
            fi
        else
            if [[ "${MESH_LEAN_BOOTSTRAP:-0}" == "1" ]]; then
                if no_mesh_active; then
                    echo "# mesh selections — no-mesh lean bootstrap (menu unavailable; foundation/shell/node)"
                else
                    echo "# mesh selections — lean bootstrap (menu unavailable; foundation/shell/node/personal)"
                fi
            elif no_mesh_active; then
                echo "# mesh selections — no-mesh headless default (foundation/base only)"
            else
                echo "# mesh selections — auto-generated default (every bundle except default_selected:false)"
            fi
            emit_default_selections
        fi
    } > "$SELECTIONS_FILE"
fi

# ─── honor SKIP_TOPICS (CI / automation) ─────────────────────────────────────
# Space-separated topic names to drop from the resolved selection. The smoke
# test uses it to skip 'identity'/'personal', which need real credentials or a
# TTY and must not hard-fail an unattended bootstrap. Defaults empty, so
# interactive and ordinary non-interactive runs are unaffected. We filter into
# a temp copy and never mutate a persisted selections.list.
if [[ -n "${SKIP_TOPICS:-}" ]]; then
    read -ra _skip_arr <<< "$SKIP_TOPICS"
    _skip_re=""
    for _t in "${_skip_arr[@]}"; do
        _skip_re+="${_skip_re:+|}^${_t}/"
    done
    _filtered="$(mktemp -t mesh-selections-filtered.XXXXXX)"
    grep -vE "$_skip_re" "$SELECTIONS_FILE" > "$_filtered" || true
    SELECTIONS_FILE="$_filtered"
    trap 'rm -f "${MESH_FOLLOWUP_FILE:-}" "'"$_filtered"'"' EXIT
    info "SKIP_TOPICS active — dropped topics: $SKIP_TOPICS"
fi

info "selections: $SELECTIONS_FILE"

# ─── apply via the engine ────────────────────────────────────────────────────
LOG="/tmp/mesh-workstation-$OS-$(date +%Y%m%d-%H%M%S).log"
info "full log: $LOG"

engine_args=(--selections "$SELECTIONS_FILE" --platform "$OS")
[[ "$NON_INTERACTIVE" == "1" ]] && engine_args+=(--non-interactive)
[[ "$DRY_RUN" == "1" ]] && engine_args+=(--dry-run)
[[ "$REPAIR_MODE" == "1" ]] && engine_args+=(--repair)
[[ "$ADOPT_MODE" == "1" ]] && engine_args+=(--adopt)

# ─── uninstall pass: bundles deselected in the menu (Frente A) ────────────────
# Run BEFORE install so re-selecting a previously-removed dependency reinstalls
# cleanly. Skipped under --repair (a marker sweep, independent of the selection)
# and when nothing was deselected. uninstall-engine takes no --non-interactive
# (it never prompts) and computes no requires_bundles closure, so it removes
# exactly the listed bundles — never an auto-removed shared dependency.
if [[ "$REPAIR_MODE" != "1" && "$ADOPT_MODE" != "1" ]] && [[ -s "$REMOVALS_FILE" ]] && grep -qvE '^[[:space:]]*(#|$)' "$REMOVALS_FILE"; then
    info "uninstall pass: $REMOVALS_FILE"
    uninstall_args=(--selections "$REMOVALS_FILE" --platform "$OS")
    [[ "$DRY_RUN" == "1" ]] && uninstall_args+=(--dry-run)
    set +e
    bash "$HERE/scripts/lib/uninstall-engine.sh" "${uninstall_args[@]}" 2>&1 | tee -a "$LOG"
    uninstall_rc="${PIPESTATUS[0]}"
    set -e
    [[ "$uninstall_rc" -ne 0 ]] && warn "uninstall pass exited rc=$uninstall_rc — continuing to install (see $LOG)"
    # Clear so a later plain re-run doesn't re-trigger the uninstall.
    [[ "$DRY_RUN" == "1" ]] || rm -f "$REMOVALS_FILE"
fi

set +e
bash "$HERE/scripts/lib/install-engine.sh" "${engine_args[@]}" 2>&1 | tee -a "$LOG"
engine_rc="${PIPESTATUS[0]}"
set -e

# Secrets unlock belongs HERE, after the engine tee, while /dev/tty is the
# controlling terminal again. personal/apply runs `mesh secret deploy` early
# (order 30) under the tee pipe; a prompt there is easy to miss, and
# NON_INTERACTIVE / a missing TTY skips it entirely. Ask once at the end.
# A skipped/headless lock is a follow-up, not a setup failure.
if [[ "$DRY_RUN" != "1" && "${MESH_NO_MESH:-0}" != "1" && "$ADOPT_MODE" != "1" ]]; then
    "$HERE/bin/mesh" secret offer-unlock || true
fi

banner "summary"
render_followup_summary

if [[ "$engine_rc" -ne 0 ]]; then
    fail "engine exited with rc=$engine_rc — see $LOG"
    exit "$engine_rc"
fi

if ! command -v mesh >/dev/null 2>&1; then
    warn "mesh is installed at ~/.local/bin/mesh but not in your current \$PATH"
    warn "open a new terminal, or run:  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

ok "done — full log: $LOG"
