#!/usr/bin/env bash
# scripts/runners/auto-update.sh — propagate mesh-workstation + mesh-identity changes across machines.
#
# Spec: docs/2026-04-25-auto-update-spec.md
#
# Usage:
#   bash scripts/runners/auto-update.sh                     manual run, all repos, incremental
#   bash scripts/runners/auto-update.sh --from-shell-start  hook invocation (allows auto-exec)
#   bash scripts/runners/auto-update.sh -o|--only NAME      restrict to repo NAME (mesh-workstation | mesh-identity)
#   bash scripts/runners/auto-update.sh -f|--full           force full apply: bash setup.sh / install.sh
#                                                   ignoring last-applied diff
#   bash scripts/runners/auto-update.sh -i|--interactive    in --full + mesh-workstation, run setup.sh
#                                                   WITHOUT --non-interactive (i.e. show the menu).
#                                                   Silently ignored for mesh-identity or incremental runs.
#   bash scripts/runners/auto-update.sh --force             update the CURRENT branch even if not `main`
#                                                   (the shell-start auto path stays main-only; this is
#                                                   opt-in for a fleet running a feature/release branch).
#                                                   Still refuses on a dirty tree or unpushed commits.
#   bash scripts/runners/auto-update.sh --reset-auth        clear auth-failed-* flags and exit
#   bash scripts/runners/auto-update.sh -h|--help           this help
#
# Exit codes:
#   0  no work, or successful apply across all repos
#   1  fatal orchestration error (config missing, git pre-flight, etc.)
#   other non-zero  primary repo-apply or package-update failure, preserved
#                   for the caller
#
# Side effects (state dir = ~/.local/state/mesh; legacy mesh-workstation migrated):
#   $STATE_DIR/last-applied-<repo>  SHA aplicada por repo
#   $STATE_DIR/update.lock          flock mutex
#   $STATE_DIR/pending-sudo-<repo>  marker se sudo cancelado
#   $STATE_DIR/auth-failed-<repo>   marker se git fetch deu 401/403

set -uo pipefail
# NOTE: not -e — we handle per-repo failures gracefully; lib funcs return non-zero
# without aborting the loop.

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# CONF lookup priority (first hit wins) — spec §C10 path migration 2026-05:
#   1. $AUTO_UPDATE_CONF                            — explicit override (tests, manual relocation)
#   2. $HOME/.config/mesh/config.env                — canonical per-host config
#   3. $HERE/../auto-update.conf                    — in-tree (workstation layout, conf in scripts/)
# Config lives at ~/.config/mesh/config.env (canonical per-host config).
# STATE_DIR overridable via env for test fixtures (see tests/auto-update.test.sh).
CONF="${AUTO_UPDATE_CONF:-}"
if [[ -z "$CONF" ]]; then
    if [[ -r "$HOME/.config/mesh/config.env" ]]; then
        CONF="$HOME/.config/mesh/config.env"
    else
        CONF="$HERE/../auto-update.conf"
    fi
fi
# Canonical state dir is ~/.local/state/mesh. auto-update runs without setup.sh,
# so finish the legacy rename one-shot here too before touching markers (T-004).
# shellcheck disable=SC1091
. "$HERE/../lib/state-dir.sh"
mesh_migrate_legacy_state
STATE_DIR="${AUTO_UPDATE_STATE_DIR:-$(mesh_state_dir)}"
# (Legacy `LOCK="$STATE_DIR/update.lock"` removed — see LOCK_DIR below;
# the mkdir-based mutex superseded the file-based one and the unused
# variable was tripping shellcheck SC2034.)

# ─── Args ────────────────────────────────────────────────────────────
FROM_SHELL_START=0
RESET_AUTH=0
FULL=0
INTERACTIVE=0
FORCE=0
ONLY=""
while (( $# > 0 )); do
    case "$1" in
        --from-shell-start) FROM_SHELL_START=1 ;;
        --reset-auth)       RESET_AUTH=1 ;;
        --full|-f)          FULL=1 ;;
        --interactive|-i)   INTERACTIVE=1 ;;
        --force)            FORCE=1 ;;
        --only|-o)
            shift
            ONLY="${1:-}"
            # Reject empty AND flag-like values (e.g. `--only --full` would
            # otherwise consume `--full` as the repo name and emit a confusing
            # "did not match" warning). Both long and short forms route here.
            if [[ -z "$ONLY" || "$ONLY" == -* ]]; then
                echo "auto-update: -o/--only requires a repo name (e.g. mesh-workstation, mesh-identity)" >&2
                exit 1
            fi
            ;;
        --help|-h)
            # Fail loud if we can't read $0 — silent empty help would mislead.
            if ! sed -n '2,25p' "$0" 2>/dev/null | sed 's/^# \{0,1\}//'; then
                echo "auto-update: cannot read self for --help (\$0=$0)" >&2
                exit 1
            fi
            exit 0
            ;;
        *)
            echo "auto-update: unknown arg: $1" >&2
            exit 1
            ;;
    esac
    shift
done

# Fail-loud on STATE_DIR creation: if we can't persist state, the motor is
# pointless. Silent failure here was a pure footgun (script kept going,
# lock acquisition then failed, exited 0 — user saw nothing).
if ! mkdir -p "$STATE_DIR" 2>/dev/null; then
    echo "auto-update: cannot create state dir $STATE_DIR" >&2
    exit 1
fi

if (( RESET_AUTH )); then
    # Honor -o/--only when set: only clear that domain's flag — `mesh update
    # -o mesh-workstation --reset-auth` shouldn't touch mesh-identity auth state.
    if [[ -n "$ONLY" ]]; then
        rm -f "$STATE_DIR/auth-failed-$ONLY"
        echo "auto-update: cleared auth-failed flag for $ONLY"
    else
        rm -f "$STATE_DIR"/auth-failed-*
        echo "auto-update: cleared auth-failed flags"
    fi
    exit 0
fi

if [[ ! -r "$CONF" ]]; then
    # --from-shell-start runs on every zsh login. A guest/--no-mesh box has
    # no auto-update conf yet; yelling here paints the prompt every time.
    if (( FROM_SHELL_START )); then
        exit 0
    fi
    echo "auto-update: config not found at $CONF" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$CONF"

# Operational defaults — the SCRIPT owns these, not the config FILE. The
# conf.example documents them, but a deployed config.env predating a tunable
# would leave it unset, and these are read BARE under `set -u` (fetch timeout,
# sudo pre-check regex) → an unbound-variable crash. Default them here so any
# config that defines at least AUTO_UPDATE_REPOS runs. (AUTO_UPDATE_VERBOSE and
# AUTO_EXEC_SHELL are already read with `${…:-0}`, so they need no default.)
: "${AUTO_UPDATE_FETCH_TIMEOUT:=3}"
: "${AUTO_UPDATE_SUDO_REGEX:=\\b(apt|brew|pip install|npm i |chsh|sudo)\\b|curl[^|]*\\|[^|]*sh}"

# Pre-fix installs (and guests) may have a CODE_DIR-only config.env.
# Under `set -u`, ${#AUTO_UPDATE_REPOS[@]} then aborts every zsh login.
# setup.sh now seeds the array; keep this guard for leftover partial files.
if ! declare -p AUTO_UPDATE_REPOS >/dev/null 2>&1; then
    AUTO_UPDATE_REPOS=()
fi

# Spec §C10 clean break: per-host .local override removed. ~/.config/mesh/
# config.env is already per-user/per-host (lives in $HOME), so the separate
# .local pattern is redundant. AUTO_UPDATE_REPOS overrides go directly into
# config.env. Identity I4 (commit 9e1071f) made the same drop on the
# code-server resolver.

# ─── Lock (mkdir-based mutex; portable across Linux + macOS) ────────
# Why not flock(1): GNU-only, not shipped on macOS without `brew install
# flock`. `mkdir` is atomic on POSIX and fails when target exists — gives
# us mutex semantics for free with zero deps. Stale-lock recovery via
# mtime heuristic (auto-update normally finishes in <2s; if dir is older
# than 60s, assume crashed prior run and steal).
LOCK_DIR="$STATE_DIR/update.lock.d"
_acquire_lock() {
    if mkdir "$LOCK_DIR" 2>/dev/null; then
        return 0
    fi
    if [[ -d "$LOCK_DIR" ]] && \
       [[ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null
        mkdir "$LOCK_DIR" 2>/dev/null && return 0
    fi
    return 1
}
if ! _acquire_lock; then
    # Another instance running, or lock contention — silent skip.
    exit 0
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT INT TERM

# ─── Output helpers ─────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_DIM=$'\e[2m'; C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_RST=$'\e[0m'
else
    C_DIM=""; C_OK=""; C_WARN=""; C_ERR=""; C_RST=""
fi

notice() { printf '%s↻%s %s\n' "$C_DIM" "$C_RST" "$1"; }
ok()     { printf '%s✓%s %s\n' "$C_OK" "$C_RST" "$1"; }
warn()   { printf '%s!%s %s\n' "$C_WARN" "$C_RST" "$1" >&2; }
err()    { printf '%s✗%s %s\n' "$C_ERR" "$C_RST" "$1" >&2; }
dbg()    { (( ${AUTO_UPDATE_VERBOSE:-0} )) && printf '%s· %s%s\n' "$C_DIM" "$1" "$C_RST" >&2; return 0; }

# Atomic state write — mktemp + mv -f. The 4 last-applied callsites used to
# do `echo "$sha" > "$path"`, which truncates on disk-full and leaves a
# 0-byte file on failure under set -uo pipefail (script continues with
# corrupted state). CP4 D-F-007 fix: centralize through a helper that fails
# loudly + leaves the existing file intact when the write does not commit.
write_state_file() {
    local path="$1" content="$2"
    local dir tmp
    dir="$(dirname "$path")"
    tmp="$(mktemp "$dir/.state.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' "$content" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mv -f "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

# Canonical retry hint for user-facing messages. The old `bup`/`dotup`
# wrappers were retired in D41 (mesh-cli refactor); messages now point at
# the unified `mesh update -o <repo>` form so the suggestion matches what
# the user actually has on PATH.
wrapper_for() {
    echo "mesh update -o $1"
}

# Detect timeout(1) — Linux ships `timeout`, macOS may ship `gtimeout` via
# `brew install coreutils`, neither is guaranteed. If absent, _run_with_timeout
# degrades to running the command without bound (last-resort fallback;
# `git fetch` will use its own internal protocol timeouts).
if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT_BIN=timeout
elif command -v gtimeout >/dev/null 2>&1; then
    _TIMEOUT_BIN=gtimeout
else
    _TIMEOUT_BIN=""
fi
_run_with_timeout() {
    local sec="$1"; shift
    if [[ -n "$_TIMEOUT_BIN" ]]; then
        "$_TIMEOUT_BIN" "$sec" "$@"
    else
        "$@"
    fi
}

# Run setup.sh interactively in a sanitized subshell so the menu actually
# renders. Inherited automation exports (NON_INTERACTIVE, CI, ONLY_TOPICS,
# INCLUDE_*, etc.) are pre-seeds that should_show_menu reads as "skip the
# menu" — leaking them into the child defeats `-i/--interactive`. The
# subshell scopes the unsets so the parent env stays untouched.
run_setup_interactive() {
    local repo="$1"
    # CP4 chunk D finding D-F-003: setup.sh treats ANY pre-set INCLUDE_* /
    # MESH_* / PHP_* / POSTGRES_* / GIT_NAME/GIT_EMAIL as "automation mode" and
    # suppresses the interactive (Ink) menu. Hard-coding the unset list got out
    # of sync — newer gates (INCLUDE_AI_TOOLS, INCLUDE_CODE_SERVER,
    # INCLUDE_IDENTITY, INCLUDE_NPM_GLOBAL, MESH_NPM_GLOBAL, MESH_AI_PACKAGES)
    # silently leaked through and defeated the wrapper's whole purpose.
    #
    # Defense: unset EVERY automation gate the menu treats as "skip me". If a new
    # gate is added to the menu/selection layer, update this list too.
    (
        unset NON_INTERACTIVE CI ONLY_TOPICS DRY_RUN
        # All INCLUDE_* automation gates.
        unset INCLUDE_DOCKER INCLUDE_WEBSTACK INCLUDE_LARAVEL INCLUDE_REMOTE
        unset INCLUDE_AI_TOOLS INCLUDE_CODE_SERVER INCLUDE_EDITOR
        unset INCLUDE_IDENTITY INCLUDE_MAILPIT INCLUDE_NGROK
        unset INCLUDE_MSSQL INCLUDE_POSTGRES INCLUDE_FRONTEND_PROXY
        unset INCLUDE_NPM_GLOBAL
        # MESH_* automation gates.
        unset MESH_NPM_GLOBAL MESH_AI_PACKAGES MESH_IDENTITY_REPO
        # PHP / POSTGRES version pins (PHP_VERSIONS triggers automation mode).
        unset PHP_VERSIONS PHP_DEFAULT POSTGRES_VERSION
        # Identity overrides (intentionally kept: $HOME, $USER).
        bash "$repo/setup.sh"
    )
}

# ─── Role detection ────────────────────────────────────────────────
# Classifies a repo by content, not basename — works with any directory name.
_is_identity_repo()  { [[ -f "$1/install.sh" && ! -f "$1/setup.sh" ]]; }
_is_workstation_repo() { [[ -f "$1/setup.sh" && -d "$1/topics" ]]; }

# Match --only NAME against a repo, accepting both canonical and legacy names.
_only_matches() {
    local repo="$1" only="$2" bn
    bn="$(basename "$repo")"
    [[ "$bn" == "$only" ]] && return 0
    case "$only" in
        mesh-identity)  _is_identity_repo "$repo"  && return 0 ;;
        mesh-workstation) _is_workstation_repo "$repo" && return 0 ;;
    esac
    return 1
}

# Given newline-separated git diff paths ($1) and the contents of
# selections.list ($2), echo the selected `topic/bundle` lines whose topic had
# a file change. Manifest v2 topics are `topics/<name>/...` (the NN- prefix was
# dropped in the F9.6 migration); the engine drives them from selections.list,
# so the incremental re-apply re-runs the engine for exactly the changed,
# still-selected bundles. Pure: no side effects, deterministic, unit-tested.
_affected_selected_bundles() {
    local diff_paths="$1" selections="$2"
    local affected
    # v2 path shape: topics/<name>/...  (NOT topics/NN-name/...)
    affected="$(printf '%s\n' "$diff_paths" | sed -n 's#^topics/\([^/]*\)/.*#\1#p' | sort -u)"
    [[ -n "$affected" ]] || return 0
    local line topic
    while IFS= read -r line; do
        line="${line%%#*}"                # strip trailing comment
        line="${line//[[:space:]]/}"      # strip whitespace (topic/bundle has none)
        [[ -n "$line" ]] || continue
        topic="${line%%/*}"
        if printf '%s\n' "$affected" | grep -qxF "$topic"; then
            printf '%s\n' "$line"
        fi
    done <<< "$selections"
}

# T-002: did this identity diff touch the declarative Syncthing mesh? The mesh
# replicates the DATA on pull (sync/syncthing-mesh.yaml, or claude/sync/…), but
# only `mesh syncthing pair` applies a topology/peer change to the local daemon.
# Pure + deterministic so the reconcile decision is unit-tested; the pair itself
# is metal-validated (needs the daemon). The `\.yaml$` anchor excludes the
# shipped `.example` template. here-string (not `echo "$1" | grep -q`): this
# runner is under `set -o pipefail`, so a large input would EPIPE echo on the
# early match → false negative. (L21-safe; F-D class.)
_syncthing_yaml_changed() {
    grep -qE '(^|/)sync/syncthing-mesh\.yaml$' <<<"$1"
}

# T-006: a per-host config/services.default.<alias> change means boot-state may
# need reconciling — gate the incremental `mesh services reconcile` on it.
# here-string mirroring _syncthing_yaml_changed (not `echo "$1" | grep -q`;
# same F-D/pipefail class). (services.default lives under config/ — a per-host,
# template-parity-exempt namespace, not the universal shell/ scaffold.)
_services_default_changed() {
    grep -qE '(^|/)config/services\.default(\.[^/]+)?$' <<<"$1"
}

# ─── Accumulators ───────────────────────────────────────────────────
SHELL_RC_CHANGED=0
FOLLOWUPS=()

# ─── Per-repo logic ─────────────────────────────────────────────────
# Returns 0 if repo was inspected (whether or not work was done).
# Returns 1 only on fatal error (we keep going to next repo).
process_repo() {
    local repo="$1"
    local name
    name="$(basename "$repo")"

    # Visible diagnostic (was `dbg`, silent by default): a configured path
    # that isn't a git repo means AUTO_UPDATE_REPOS is wrong for this host.
    # Silent skip used to leave users with a 3-second exit and zero hints.
    if [[ ! -d "$repo/.git" ]]; then
        notice "pulado: $name (caminho '$repo' não é repo git)"
        notice "  → ajuste AUTO_UPDATE_REPOS em $CONF"
        return 0
    fi

    local wrap; wrap="$(wrapper_for "$name")"

    # Auth-fail flag silences this repo until user resolves and runs --reset-auth.
    # --full bypasses with an explicit notice — user invoking `bup --full`
    # explicitly intends to force, silent skip would be confusing.
    if [[ -f "$STATE_DIR/auth-failed-$name" ]]; then
        if (( FULL )); then
            notice "$name: auth-failed flag present; clearing for --full attempt (rode \`gh auth refresh\` se preciso)"
            rm -f "$STATE_DIR/auth-failed-$name"
        else
            dbg "skip $name (auth-failed flag present; run \`$wrap --reset-auth\` after fixing)"
            return 0
        fi
    fi

    # ─── Pre-flight: branch must be main ────────────────────────────
    local branch
    branch="$(git -C "$repo" symbolic-ref --short HEAD 2>/dev/null || echo '')"
    if [[ -z "$branch" ]]; then
        dbg "skip $name (detached HEAD or unreadable branch)"
        return 0
    fi
    if [[ "$branch" != "main" ]]; then
        if (( FORCE )); then
            notice "forçando update de $name na branch $branch (--force)"
        else
            notice "pulado: $name em branch $branch (use --force para atualizar mesmo assim)"
            return 0
        fi
    fi

    # ─── Pre-flight: working tree must be clean ─────────────────────
    if [[ -n "$(git -C "$repo" status --porcelain 2>/dev/null)" ]]; then
        notice "pulado: $name tem mudanças não-commitadas"
        return 0
    fi

    # ─── Fetch (with timeout + auth-fail detection) ─────────────────
    local fetch_err fetch_rc
    fetch_err="$(_run_with_timeout "$AUTO_UPDATE_FETCH_TIMEOUT" git -C "$repo" fetch --quiet 2>&1)" \
        && fetch_rc=0 || fetch_rc=$?
    if (( fetch_rc != 0 )); then
        if grep -qE 'Authentication failed|Permission denied|could not read Username|HTTP/.*40[13]' <<<"$fetch_err"; then
            warn "$name: auth failed — rode \`gh auth refresh\` então \`$wrap --reset-auth\`"
            touch "$STATE_DIR/auth-failed-$name"
        fi
        # Other failures (timeout, transient network): NOOP silencioso (spec §4.5).
        dbg "$name: fetch rc=$fetch_rc (silent skip)"
        return 0
    fi

    # ─── Pre-flight: upstream must be configured ────────────────────
    local head_remote
    head_remote="$(git -C "$repo" rev-parse '@{upstream}' 2>/dev/null || echo '')"
    if [[ -z "$head_remote" ]]; then
        dbg "skip $name (no upstream tracking branch)"
        return 0
    fi

    # ─── --full path: force setup.sh / install.sh, ignore diff ──
    # Skips last-applied/diff/pending-sudo logic and runs the orchestrator
    # in full. Used by `bup --full` (rebootstrap mesh-workstation from scratch)
    # and `dotup --full` (re-deploy mesh-identity). Bumps last-applied on success
    # so the next incremental run sees a fresh baseline.
    if (( FULL )); then
        notice "atualizando $name (--full)"
        # Pre-emptive sudo for mesh-workstation (setup.sh runs apt/brew/services).
        # identity install.sh is HOME-only — no sudo needed.
        if _is_workstation_repo "$repo"; then
            notice "$name: --full requer sudo (setup.sh roda apt/brew/services)"
            if ! sudo -v 2>/dev/null; then
                warn "$name: sudo cancelado — abortando --full"
                return 1
            fi
        fi
        # Capture HEAD before pull so we can summarize what moved (and bump
        # last-applied to the actual post-pull SHA, not the upstream snapshot
        # we sampled earlier — they normally match, but a stale upstream
        # cache or a parallel writer could diverge them).
        local old_head old_short pull_err new_head new_short
        old_head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo '')"
        old_short="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '')"
        # Pull and ABORT on failure — `--full` against a stale tree would then
        # bump last-applied to upstream HEAD even though the working tree
        # never received those commits, creating invisible state divergence.
        # Pre-flights above guarantee FF-safe; capture stderr to surface why
        # if a hook / lock / FS error breaks pull anyway.
        if ! pull_err="$(git -C "$repo" pull --ff-only --quiet 2>&1)"; then
            err "$name: git pull --ff-only falhou em --full — abortando sem rebootstrap"
            [[ -n "$pull_err" ]] && printf '    %s\n' "$pull_err" >&2
            return 1
        fi
        new_head="$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo '')"
        new_short="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo '')"
        if [[ -n "$old_head" && -n "$new_head" && "$old_head" != "$new_head" ]]; then
            ok "$name: pulled $old_short..$new_short"
        else
            ok "$name: already at $new_short"
        fi
        if _is_workstation_repo "$repo"; then
            # -i/--interactive drops --non-interactive so setup.sh shows
            # its whiptail menu (used to validate new opt-ins like postgres
            # without committing config.env tweaks first). Default stays
            # automated so the shell-start hook never blocks on a prompt.
            #
            # CRITICAL: do NOT pipe through `sed` when interactive — the pipe
            # makes stdout a non-TTY, and whiptail (plus any other dialog)
            # falls back to non-interactive mode silently. The pretty-prefix
            # cosmetic loses to having the menu actually render. Default
            # mode keeps the pipe so the shell-start hook output stays
            # uniform.
            local setup_rc=0
            if (( INTERACTIVE )); then
                notice "$name: --interactive — setup.sh roda com menu (output direto pro TTY, sem prefix)"
                run_setup_interactive "$repo" || setup_rc=$?
            else
                bash "$repo/setup.sh" --non-interactive 2>&1 | sed 's/^/    /' || setup_rc=$?
            fi
            if (( setup_rc != 0 )); then
                warn "$name: setup.sh --full falhou (rc=$setup_rc) — last-applied NÃO bumped"
                return "$setup_rc"
            fi
        elif _is_identity_repo "$repo"; then
            local install_rc=0
            bash "$repo/install.sh" 2>&1 | sed 's/^/    /' || install_rc=$?
            if (( install_rc != 0 )); then
                warn "$name: install.sh --full falhou (rc=$install_rc) — last-applied NÃO bumped"
                return "$install_rc"
            fi
            # Capture doctor output so the warn is actionable — silent
            # `>/dev/null 2>&1` previously made the user re-run by hand.
            #
            # CP4 chunk D finding D-F-004: post-Phase 7a identity no
            # longer has scripts/runners/doctor.sh (workstation owns it).
            # Use the WORKSTATION doctor relative to this auto-update
            # script ($HERE = scripts/runners/, so doctor.sh is a peer),
            # passing MESH_IDENTITY_DIR=$repo so the deploy.map resolves
            # to the just-applied identity tree.
            local doctor_path="$HERE/doctor.sh"
            if [[ -f "$doctor_path" ]]; then
                local doctor_out doctor_rc=0
                doctor_out="$(MESH_IDENTITY_DIR="$repo" bash "$doctor_path" --quiet 2>&1)" || doctor_rc=$?
                if (( doctor_rc != 0 )); then
                    warn "$name: doctor.sh reporta drift residual após --full"
                    [[ -n "$doctor_out" ]] && printf '%s\n' "$doctor_out" | sed 's/^/    /' >&2
                fi
            fi
            # T-002: a --full identity re-apply reconciles Syncthing too — the
            # yaml may carry a topology/peer change. No diff to gate on in --full
            # (force re-apply everything), so reconcile unconditionally when
            # syncthing is installed. Idempotent + non-interactive; non-fatal.
            if command -v syncthing >/dev/null 2>&1 && [[ -f "$HERE/syncthing.sh" ]]; then
                notice "$name: reconciliando Syncthing (mesh syncthing pair)…"
                if ! NON_INTERACTIVE=1 MESH_IDENTITY_DIR="$repo" \
                        bash "$HERE/syncthing.sh" pair 2>&1 | sed 's/^/    /'; then
                    warn "$name: \`mesh syncthing pair\` retornou non-zero (continuando)"
                fi
            fi
            # T-006: a --full identity re-apply reconciles service boot-state too.
            # No diff to gate on in --full — reconcile unconditionally toward the
            # per-host services.default.<alias>. Enabled bit only; non-fatal.
            local mesh_bin_full="$HERE/../../bin/mesh"
            if [[ -f "$mesh_bin_full" ]]; then
                notice "$name: reconciliando boot-state de serviços (mesh services reconcile)…"
                if ! NON_INTERACTIVE=1 MESH_IDENTITY_DIR="$repo" \
                        bash "$mesh_bin_full" services reconcile 2>&1 | sed 's/^/    /'; then
                    warn "$name: \`mesh services reconcile\` retornou non-zero (continuando)"
                fi
            fi
        fi
        # Defense in depth: never write empty last-applied. new_head is the
        # actual post-pull SHA; head_remote was the upstream snapshot at
        # pre-flight time (normally same, but a stale upstream cache or
        # parallel writer could disagree). Prefer the post-pull truth.
        if [[ -n "$new_head" ]]; then
            write_state_file "$STATE_DIR/last-applied-$name" "$new_head" \
                || warn "$name: falha gravando last-applied (mantendo valor anterior)"
        fi
        rm -f "$STATE_DIR/pending-sudo-$name"
        ok "$name reaplicado em modo --full"
        # --full skips the reload + followup tables on purpose: a full
        # rebootstrap re-deploys everything, so per-path reload triggers
        # are redundant. Document via this comment + spec §3.4.
        return 0
    fi

    # ─── Determine baseline (last-applied SHA, or current upstream on first run) ──
    local last_applied
    last_applied="$(cat "$STATE_DIR/last-applied-$name" 2>/dev/null || echo '')"
    if [[ -z "$last_applied" ]]; then
        # First run on this machine: seed with current upstream HEAD; do nothing this round.
        write_state_file "$STATE_DIR/last-applied-$name" "$head_remote" \
            || { err "$name: falha gravando seed em last-applied"; return 1; }
        dbg "$name: seeded last-applied=$head_remote (first run, no apply)"
        return 0
    fi

    # ─── Nothing new on remote? → return ────────────────────────────
    if [[ "$last_applied" == "$head_remote" ]]; then
        dbg "$name: up to date ($head_remote)"
        return 0
    fi

    # ─── Pre-flight: local commits ahead → skip ─────────────────────
    local ahead
    ahead="$(git -C "$repo" rev-list --count "${head_remote}..HEAD" 2>/dev/null || echo 0)"
    if (( ahead > 0 )); then
        notice "pulado: $name tem $ahead commit(s) local(is) não-pushed"
        return 0
    fi

    # ─── Pre-flight: fast-forward feasibility ───────────────────────
    if ! git -C "$repo" merge-base --is-ancestor HEAD "$head_remote" 2>/dev/null; then
        warn "$name: pull não fast-forward — resolva manualmente (\`cd $repo && git status\`)"
        return 0
    fi

    # ─── Diff content + paths (used by Phases 3+4) ──────────────────
    local diff_paths diff_content
    diff_paths="$(git -C "$repo" diff --name-only "$last_applied" "$head_remote" 2>/dev/null)"
    diff_content="$(git -C "$repo" diff "$last_applied" "$head_remote" 2>/dev/null)"
    if [[ -z "$diff_paths" ]]; then
        # Edge case: empty diff but SHAs differ (merge commit?). Bump baseline silently.
        write_state_file "$STATE_DIR/last-applied-$name" "$head_remote" \
            || warn "$name: falha gravando last-applied no merge-empty-diff"
        dbg "$name: empty diff between $last_applied..$head_remote — baseline bumped"
        return 0
    fi

    # ─── Pending-sudo short-circuit ─────────────────────────────────
    # If user previously cancelled sudo for THIS exact head_remote, stay silent
    # until new commits arrive (so we don't re-prompt every shell start).
    local pending_sudo_file="$STATE_DIR/pending-sudo-$name"
    if [[ -f "$pending_sudo_file" ]]; then
        local pending_sha
        pending_sha="$(cat "$pending_sudo_file" 2>/dev/null || echo '')"
        if [[ "$pending_sha" == "$head_remote" ]]; then
            dbg "$name: pending-sudo for $pending_sha matches current head — silent until new commits"
            return 0
        fi
        # New commits arrived since last cancel — stale flag, drop it.
        rm -f "$pending_sudo_file"
    fi

    notice "atualizando $name ($(echo "$diff_paths" | wc -l | tr -d ' ') arquivo(s))…"
    dbg "diff_paths:"$'\n'"$diff_paths"

    # ─── Apply: sudo heuristic + prompt ─────────────────────────────
    local needs_sudo=0
    # here-string, NOT `echo "$diff_content" | grep -q`: this runner is under
    # `set -o pipefail` (line 32). With a large diff, `grep -q` matches early +
    # closes the pipe → echo hits EPIPE → the pipeline returns non-zero →
    # needs_sudo wrongly stays 0 → sudo prompt skipped → install scripts fail
    # partway. 100% reproducible on diffs > the pipe buffer (root of "quase
    # sempre falha"; F-D). A here-string is a single command, not a pipeline,
    # so pipefail/EPIPE cannot apply. Keep `grep` (not [[ =~ ]]): the regex uses
    # \b, which BSD grep -E supports but bash 3.2 [[ =~ ]] does not.
    # See feedback_engine_pipefail_grep_q_broken_pipe + lint L21.
    if grep -qE "$AUTO_UPDATE_SUDO_REGEX" <<<"$diff_content"; then
        needs_sudo=1
    fi

    local skip_install=0
    if (( needs_sudo )); then
        notice "$name: precisa de sudo para mudanças detectadas"
        if ! sudo -v 2>/dev/null; then
            warn "$name: sudo cancelado — pulando install scripts (re-tente com \`$wrap\`)"
            echo "$head_remote" > "$pending_sudo_file"
            skip_install=1
            # Continua: pull ainda é safe (só atualiza arquivos do repo, não toca sistema).
        fi
    fi

    # ─── Apply: pull (fast-forward, já validado em pre-flight) ──────
    if ! git -C "$repo" pull --ff-only --quiet 2>/dev/null; then
        err "$name: git pull --ff-only falhou (inesperado pós pre-flight)"
        return 1
    fi

    # ─── Apply: re-apply changed topics via the engine (mesh-workstation) ──
    # Manifest v2 has no per-topic install.sh — topics are driven by
    # install-engine.sh from the saved selections.list. So re-run the engine for
    # the SELECTED bundles of the topics whose files changed: idempotent items
    # re-apply (configs/deploys land), skip-if-present items no-op. The package
    # *version* upgrade pass is run_update_phase (post-pull, opt-in), separate.
    # Guarded: no selections.list, or no changed topic in it → clean no-op.
    if (( ! skip_install )) && [[ "$name" == "mesh-workstation" ]]; then
        local sel_file="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list"
        if [[ -r "$sel_file" ]]; then
            local affected_sel
            affected_sel="$(_affected_selected_bundles "$diff_paths" "$(cat "$sel_file")")"
            if [[ -n "$affected_sel" ]]; then
                local tmp_sel; tmp_sel="$(mktemp)"
                printf '%s\n' "$affected_sel" > "$tmp_sel"
                dbg "$name: re-applying changed topics via engine:"$'\n'"$affected_sel"
                if ! bash "$repo/scripts/lib/install-engine.sh" \
                        --non-interactive --selections "$tmp_sel" 2>&1 | sed 's/^/    /'; then
                    warn "$name: engine re-apply of changed topics returned non-zero (continuando)"
                fi
                rm -f "$tmp_sel"
            else
                dbg "$name: changed topics not selected in selections.list — nothing to re-apply"
            fi
        else
            dbg "$name: no selections.list — skipping incremental topic re-apply"
        fi
    fi

    # ─── Apply: re-run install.sh of identity (idempotent, no sudo) ─
    if (( ! skip_install )) && _is_identity_repo "$repo"; then
        if ! bash "$repo/install.sh" 2>&1 | sed 's/^/    /'; then
            warn "$name: install.sh falhou (continuando)"
        fi
    fi

    # ─── Apply: auto-reconcile Syncthing when the mesh yaml changed (T-002) ──
    # The mesh replicates the yaml on pull but nothing applies it — close that
    # gap by re-running the idempotent `mesh syncthing pair` here, non-interactive
    # (a genuinely-new device just defers to the Tier-0 approve; already handled).
    # Gated on syncthing being installed; failure warns but never aborts update.
    if (( ! skip_install )) && _is_identity_repo "$repo" \
            && command -v syncthing >/dev/null 2>&1 \
            && _syncthing_yaml_changed "$diff_paths"; then
        local st_runner="$HERE/syncthing.sh"
        if [[ -f "$st_runner" ]]; then
            notice "$name: syncthing-mesh.yaml mudou — reconciliando (mesh syncthing pair)…"
            if ! NON_INTERACTIVE=1 MESH_IDENTITY_DIR="$repo" \
                    bash "$st_runner" pair 2>&1 | sed 's/^/    /'; then
                warn "$name: \`mesh syncthing pair\` retornou non-zero (continuando) — reconcilie manualmente"
            fi
        fi
    fi

    # ─── Apply: reconcile service boot-state when services.default changed (T-006) ──
    # Like the Syncthing block above: the mesh replicates services.default.<alias>
    # on pull but nothing applies it. Reconcile the enabled bit ONLY toward the
    # per-host file (never stops a running unit). Gated on the file having changed;
    # failure warns but never aborts the update.
    if (( ! skip_install )) && _is_identity_repo "$repo" \
            && _services_default_changed "$diff_paths"; then
        local svc_mesh_bin="$HERE/../../bin/mesh"
        if [[ -f "$svc_mesh_bin" ]]; then
            notice "$name: services.default mudou — reconciliando boot-state (mesh services reconcile)…"
            if ! NON_INTERACTIVE=1 MESH_IDENTITY_DIR="$repo" \
                    bash "$svc_mesh_bin" services reconcile 2>&1 | sed 's/^/    /'; then
                warn "$name: \`mesh services reconcile\` retornou non-zero (continuando)"
            fi
        fi
    fi

    # ─── Validador (apenas identity) ─────────────────────────────────
    # CP4 chunk D finding D-F-004: incremental path uses workstation
    # doctor.sh (peer to this script post-Phase 7a). Identity no longer
    # ships scripts/runners/doctor.sh; the previous `[[ -f $repo/... ]]`
    # check always failed silently.
    if (( ! skip_install )) && _is_identity_repo "$repo" && [[ -f "$HERE/doctor.sh" ]]; then
        if ! MESH_IDENTITY_DIR="$repo" bash "$HERE/doctor.sh" --quiet >/dev/null 2>&1; then
            warn "$name: doctor.sh reporta drift residual — rode \`MESH_IDENTITY_DIR=$repo bash $HERE/doctor.sh\` para detalhes"
        fi
    fi

    # ─── Apply: success — bump last-applied SHA (only if NOT skip_install) ──
    if (( ! skip_install )); then
        write_state_file "$STATE_DIR/last-applied-$name" "$head_remote" \
            || warn "$name: falha gravando last-applied (estado pode dessincronizar)"
        ok "$name atualizado"
    else
        # Pull happened but install scripts skipped — DO NOT bump last-applied.
        # Next run will re-detect the same diff and re-prompt sudo.
        # The pending-sudo-<name>-with-matching-SHA short-circuit silences re-prompt
        # until new commits arrive.
        warn "$name: pull aplicado, install scripts pendentes — \`$wrap\` para retentar com sudo"
    fi

    # ─── Reload table matching ──────────────────────────────────────
    # For each diff path × each reload entry: if glob matches, run cmd.
    # "exec-shell-advice" is special — sets SHELL_RC_CHANGED instead of running.
    # bash 3.2 quirk: under `set -u`, "${AUTO_UPDATE_RELOAD[@]}" aborts when
    # the array is empty (e.g. test fixtures with a minimal conf). The
    # ${arr[@]+...} substitution checks set-ness before expansion (bash 3.2
    # lacks the empty-array-is-set semantic that bash 4+ has).
    local entry glob cmd path
    for entry in "${AUTO_UPDATE_RELOAD[@]+"${AUTO_UPDATE_RELOAD[@]}"}"; do
        glob="${entry%%:*}"
        cmd="${entry#*:}"
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            # Bash pattern match — $glob must be UNquoted to act as pattern.
            # shellcheck disable=SC2053
            if [[ "$path" == $glob ]]; then
                if [[ "$cmd" == "exec-shell-advice" ]]; then
                    SHELL_RC_CHANGED=1
                    dbg "$name: shell rc affected by $path"
                else
                    dbg "$name: reload via \`$cmd\` (matched $path)"
                    # eval needed for cmd with args + redirection; we trust the conf.
                    # Capture stderr so the warn is actionable — bare `2>/dev/null`
                    # left users with `reload \`X\` falhou` and zero context.
                    local reload_err
                    if ! reload_err="$(eval "$cmd" 2>&1)"; then
                        warn "reload \`$cmd\` falhou${reload_err:+: $reload_err}"
                    fi
                fi
            fi
        done <<< "$diff_paths"
    done

    # ─── Followup table matching ────────────────────────────────────
    # Same bash 3.2 empty-array guard as the reload loop above.
    local msg
    for entry in "${AUTO_UPDATE_FOLLOWUPS[@]+"${AUTO_UPDATE_FOLLOWUPS[@]}"}"; do
        glob="${entry%%:*}"
        msg="${entry#*:}"
        while IFS= read -r path; do
            [[ -z "$path" ]] && continue
            # shellcheck disable=SC2053
            if [[ "$path" == $glob ]]; then
                FOLLOWUPS+=("$msg")
                dbg "$name: followup queued for $path → $msg"
                break  # one followup per glob entry, even if multiple paths match
            fi
        done <<< "$diff_paths"
    done

    return 0
}

# ─── Version-aware update phase (T-600) ─────────────────────────────
# After repos are pulled, upgrade installed packages via the engine's --update
# mode — opt-in, version-aware (only stale items). No-op by default: nothing
# runs unless the user enabled at least one MESH_UPDATE_* category (params.env
# or env), so existing `mesh update` behavior is unchanged.
_any_update_optin() {
    local params="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/params.env" v
    # shellcheck source=/dev/null
    [[ -r "$params" ]] && . "$params" 2>/dev/null
    for v in "${MESH_UPDATE_AGENT_CLIS:-0}" "${MESH_UPDATE_RUNTIMES_DBS:-0}" "${MESH_UPDATE_CLI_TOOLS:-0}"; do
        case "$v" in 1|true|yes|on) return 0 ;; esac
    done
    return 1
}

# rc 0 iff ≥1 manifest item under $1/topics declares `autoupdate: true` — the
# per-item override that self-updates regardless of the global category switches.
# Cheap grep so a zero-flag, zero-category machine never spawns the engine.
_has_autoupdate_items() {
    local ws="$1"
    [[ -d "$ws/topics" ]] || return 1
    grep -rqiE '^[[:space:]]*autoupdate:[[:space:]]*(true|yes|1)([[:space:]]|#|$)' \
        "$ws/topics" 2>/dev/null
}

# Epoch mtime of $1. GNU `stat -c` FIRST, then BSD `stat -f`.
#
# CRITICAL: never try BSD `stat -f %m` first on Linux. GNU coreutils treats
# `-f` as `--file-system` (a real flag), still writes multi-line filesystem
# status starting with `  File: "..."` to stdout for the real path, exits
# non-zero for the bogus `%m` operand, then a trailing `|| stat -c %Y` appends
# a real epoch. The capture becomes multi-line garbage + digits. Under
# `set -u`, `(( now - mtime < interval ))` tokenizes `File` as a variable →
# `File: unbound variable` and aborts the whole motor. That is the recurrent
# `mesh update` / `mesh update -f` crash on Linux once last-package-update
# exists. Pattern matches scripts/internal/mesh-snap `_mtime_epoch`.
# Empty + rc1 if neither works.
_mtime() {
    local p="$1" out
    out="$(stat -c %Y "$p" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
    out="$(stat -f %m "$p" 2>/dev/null)" && { printf '%s\n' "$out"; return 0; }
    return 1
}

# rc 0 = throttled (the daily login package pass already ran within the window →
# skip). MESH_UPDATE_FORCE=1 (set by `mesh upgrade`) bypasses; interval ≤0 or
# MESH_PACKAGE_UPDATE_INTERVAL=0 disables the throttle; no stamp yet = allowed.
_package_update_throttled() {
    case "${MESH_UPDATE_FORCE:-0}" in 1|true|yes|on) return 1 ;; esac
    local interval="${MESH_PACKAGE_UPDATE_INTERVAL:-86400}"
    [[ "$interval" =~ ^[0-9]+$ ]] || interval=86400
    (( interval <= 0 )) && return 1
    local stamp="$STATE_DIR/last-package-update" now mtime
    [[ -f "$stamp" ]] || return 1
    now="$(date +%s)"; mtime="$(_mtime "$stamp")"
    # Digits only — never feed multi-line/stat-dump garbage into (( )).
    # Defense-in-depth if _mtime ever regresses on a weird stat(1).
    [[ "$mtime" =~ ^[0-9]+$ ]] || return 1
    (( now - mtime < interval ))
}

run_update_phase() {
    local r ws=""
    for r in "${AUTO_UPDATE_REPOS[@]}"; do _is_workstation_repo "$r" && { ws="$r"; break; }; done
    [[ -n "$ws" ]] || { dbg "update phase: no workstation repo configured — skipping"; return 0; }
    # Fire when EITHER a global category is opted in OR ≥1 item carries
    # `autoupdate: true`. Subshell on the optin guard so sourcing params.env
    # never pollutes our globals.
    if ! ( _any_update_optin ) && ! _has_autoupdate_items "$ws"; then
        dbg "update phase: no opt-in categories and no autoupdate items — skipping"; return 0
    fi
    # Daily throttle for the auto/login path: the package phase (a native
    # `outdated` query per item) is heavier than the git-pull, so cap it to once
    # per interval. `mesh upgrade` exports MESH_UPDATE_FORCE=1 to bypass.
    if _package_update_throttled; then
        dbg "update phase: throttled (<${MESH_PACKAGE_UPDATE_INTERVAL:-86400}s since last run) — skipping"; return 0
    fi
    local sel="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list"
    [[ -r "$sel" ]] || { dbg "update phase: no selections.list — skipping"; return 0; }
    local engine="$ws/scripts/lib/install-engine.sh"
    [[ -r "$engine" ]] || { warn "update phase: engine not found at $engine"; return 0; }
    notice "version-aware update phase"
    local engine_rc=0
    bash "$engine" --update --non-interactive --selections "$sel" 2>&1 | sed 's/^/    /' \
        || engine_rc=$?
    # Stamp the attempt so the throttle holds until the next interval (a transient
    # failure waits one interval; `mesh upgrade` forces an immediate retry).
    mkdir -p "$STATE_DIR" 2>/dev/null || true
    : > "$STATE_DIR/last-package-update" 2>/dev/null || true
    return "$engine_rc"
}

# ─── Main loop ──────────────────────────────────────────────────────
# -o/--only NAME restricts processing to that repo (matched against the basename
# of each entry in AUTO_UPDATE_REPOS). Used by `mesh update -o <repo>` to scope
# each invocation. Unfiltered runs (e.g. shell-start hook, `mesh update`) still
# cover all repos.
#
# EXIT_RC is the script's overall outcome:
#   0  no work, or all repo and package-update work succeeded
#   N  first non-zero repo rc (including a causal --full setup/install rc) or,
#      if repos succeeded, the package-update rc; 1 also covers orchestration
#      errors such as an unmatched --only target.
# Honest exit codes matter for piped composition — without this
# the user's `&&` composition would silently mask first-stage failures.
EXIT_RC=0

if (( ${#AUTO_UPDATE_REPOS[@]} == 0 )); then
    if (( FROM_SHELL_START )); then
        exit 0
    fi
    err "auto-update: AUTO_UPDATE_REPOS is empty in $CONF"
    exit 1
fi

for repo in "${AUTO_UPDATE_REPOS[@]}"; do
    if [[ -n "$ONLY" ]] && ! _only_matches "$repo" "$ONLY"; then
        continue
    fi
    process_rc=0
    process_repo "$repo" || process_rc=$?
    if (( process_rc != 0 )); then
        warn "process_repo failed for $repo (rc=$process_rc; continuing)"
        (( EXIT_RC == 0 )) && EXIT_RC=$process_rc
    fi
done

if [[ -n "$ONLY" ]]; then
    matched=0
    for repo in "${AUTO_UPDATE_REPOS[@]}"; do
        _only_matches "$repo" "$ONLY" && matched=1
    done
    if (( ! matched )); then
        err "auto-update: -o/--only $ONLY did not match any configured repo (AUTO_UPDATE_REPOS in $CONF)"
        EXIT_RC=1
    fi
fi

# ─── Version-aware package update (opt-in; no-op unless a category enabled) ──
update_phase_rc=0
run_update_phase || update_phase_rc=$?
if (( update_phase_rc != 0 )); then
    warn "update phase failed (rc=$update_phase_rc; continuing)"
    (( EXIT_RC == 0 )) && EXIT_RC=$update_phase_rc
fi

# ─── Followup summary ───────────────────────────────────────────────
if (( ${#FOLLOWUPS[@]} > 0 )); then
    echo
    echo "${C_DIM}Manual follow-ups:${C_RST}"
    for msg in "${FOLLOWUPS[@]}"; do
        echo "  - $msg"
    done
fi

# ─── mesh snap hook (best-effort, never fails auto-update) ──────────
# After every successful auto-update run (incremental or --full), refresh
# this host's mesh snapshot so the cross-host panel reflects the new
# state without requiring the user to do anything. Hook is intentionally
# silent + tolerant: missing binary, mesh snap exiting non-zero, or
# config gaps must NOT propagate as auto-update failures.
# Spec: docs/2026-05-01-mesh-status-spec.md §5.3.1 + the mesh-cli refactor
# spec (docs/2026-05-02-mesh-cli-refactor-spec.md §4.3) which made `mesh
# snap` the canonical entrypoint replacing the old `mesh-snap` binary.
if command -v mesh >/dev/null 2>&1; then
    mesh snap --quiet >/dev/null 2>&1 || true
fi

# ─── Auto-exec (Phase 5 final wiring) ───────────────────────────────
if (( SHELL_RC_CHANGED )); then
    if (( FROM_SHELL_START )) && (( ${AUTO_EXEC_SHELL:-0} )); then
        notice "shell config mudou — exec zsh"
        # Recursion guard: replaced shell will sourced auto-update.zsh again,
        # but it short-circuits on this flag. See shell/auto-update.zsh.
        export AUTO_UPDATE_RECURSED=1
        exec zsh
    else
        notice "shell config mudou — reabra esta janela ou rode \`exec zsh\`"
    fi
fi

exit "$EXIT_RC"
