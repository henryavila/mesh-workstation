#!/usr/bin/env bash
# setup.sh — run every topic in order on this machine.
#
# Interactive by default: prompts for opt-in topics and identity via whiptail.
# Skip the menu by passing --non-interactive or pre-seeding any control var.
#
# Env vars (primarily for automation/CI):
#   NON_INTERACTIVE=1   skip the menu even on a TTY
#   SKIP_TOPICS         space-separated list of topics to skip
#   ONLY_TOPICS         space-separated list of topics to run exclusively
#   DRY_RUN=1           print actions without executing
#   MESH_IDENTITY_REPO       identity repo URL (used by 82-ai-tools / 95-dotfiles-personal)
#   MESH_IDENTITY_DIR        where to clone identity repo (default: ~/mesh-identity)
#   INCLUDE_AI_TOOLS=1  install AI review prompts + token-saving CLI tools
#   INCLUDE_IDENTITY=1 apply personal identity from MESH_IDENTITY_REPO
#   MESH_NPM_GLOBAL=1 configure npm globals under ~/.npm-global
#   MESH_AI_PACKAGES=1 legacy alias for INCLUDE_AI_TOOLS=1
#   GIT_NAME, GIT_EMAIL identity for 50-git
#   GPG_SIGN=1          enable commit/tag signing in 50-git (opt-in)
#   GPG_KEY_ID          explicit signing key (else first secret key is picked)
#   CODE_DIR            project root (default: ~/code/web)
#   INCLUDE_DOCKER=1    enables 45-docker
#   INCLUDE_WEBSTACK=1  enables 60-web-stack  (legacy alias: INCLUDE_LARAVEL=1)
#   INCLUDE_REMOTE=1    enables 70-remote-access
#   INCLUDE_CODE_SERVER=1 enables 85-code-server
#   CODE_SERVER_VERSION=X.Y.Z pins the standalone code-server release
#   CODE_SERVER_UPGRADE=1 reinstall/upgrade the standalone code-server release
#   CODE_SERVER_CHECK_UPDATES=0 skip checking for a newer upstream release
#   CODE_SERVER_LABEL=com.${USER}.code-server
#   CODE_SERVER_PORT=8080
#   CODE_SERVER_INSTALL_METHOD=standalone
#   CODE_SERVER_TAILSCALE_SERVE=0 disables the default Tailscale Serve exposure
#   INCLUDE_EDITOR=1    enables 90-editor
#   PHP_VERSIONS        space-separated list (e.g. "8.4 8.5"); last = default
#                       (if unset: all versions listed in
#                       topics/10-languages/data/php-versions.conf)
#   PHP_DEFAULT         override which version becomes PATH / FPM / composer default
#   INCLUDE_MAILPIT=1   installs mailpit (SMTP :1025, UI :8025) inside 60-web-stack
#   INCLUDE_NGROK=1     installs ngrok + share-project wrapper
#   INCLUDE_MSSQL=1     installs Microsoft SQL Server ODBC driver + sqlsrv/pdo_sqlsrv
#                       PECL extensions (ACCEPT_EULA=Y auto-set)
#   NGROK_AUTHTOKEN     ngrok token to auto-configure during install
#                       (if unset, the menu prompts once + persists to
#                       ~/.local/state/mesh-workstation/secrets.env, mode 0600)
#   CHSH_AUTO=0         skip the auto `sudo chsh` attempt in 20-terminal-ux
#                       (default 1 — tries to set zsh as default login
#                       shell using the cached sudo ticket; falls back
#                       to an advisory if refused)
#   ATUIN_LOGIN_AUTO=0  skip running `atuin login` inline in 20-terminal-ux
#                       (default 1 on TTY — opens browser for atuin.sh
#                       OAuth; falls back to an advisory in NON_INTERACTIVE
#                       mode or when this env is set to 0)
#   DEV_DEFAULT_PORT    default port for *.front.localhost proxy (default 3000)
#   FORCE_VALET_INSTALL=1  (Mac only) force re-run `valet install` even when
#                       it appears already configured. Useful after macOS
#                       upgrades that rotate dnsmasq config or when
#                       recovering from a corrupted Valet state.
#   NO_COLOR=1          disable colored output (auto if not a TTY)
#
# Usage: bash setup.sh [--help] [--non-interactive] [--dry-run] [--list-topics]

set -euo pipefail

# Minimal shells (docker run, `su -`, some cron contexts, `env -i`) leave $USER
# unset even when the effective UID is a real account. `id -un` always works.
# Exported so every topic + envsubst in lib/deploy.sh sees a consistent value.
export USER="${USER:-$(id -un)}"
export HOME="${HOME:-$(getent passwd "$USER" | cut -d: -f6)}"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# C13.5 mesh-symlink prelude lives below, after `--help` and `--list-topics`
# early-exits, so introspection flags don't have filesystem side effects
# (Review B finding B6). The actual install is in install_mesh_symlink(),
# invoked further down once we know the user is running setup, not
# inspecting.

collect_topics() {
    # Portable across bash 3.2 (macOS default) and bash 4+: no `mapfile`, no
    # GNU find `-printf`. Parameter expansion `${p##*/}` does basename without
    # a fork, and the while-read loop fills the array in bash-3-friendly syntax.
    all_topics=()
    while IFS= read -r topic_dir; do
        all_topics+=("${topic_dir##*/}")
    done < <(find "$HERE/topics" -mindepth 1 -maxdepth 1 -type d | sort)
}

# Opt-in gating map: topic_name -> env var that must equal 1.
optin_var_for() {
    case "$1" in
        45-docker)        echo "INCLUDE_DOCKER" ;;
        60-web-stack)     echo "INCLUDE_WEBSTACK" ;;
        70-remote-access) echo "INCLUDE_REMOTE" ;;
        82-ai-tools)      echo "INCLUDE_AI_TOOLS" ;;
        85-code-server)   echo "INCLUDE_CODE_SERVER" ;;
        90-editor)        echo "INCLUDE_EDITOR" ;;
        95-dotfiles-personal) echo "INCLUDE_IDENTITY" ;;
        *)                echo "" ;;
    esac
}

print_topic_list() {
    local topic number var
    collect_topics
    for topic in "${all_topics[@]+"${all_topics[@]}"}"; do
        number="${topic%%-*}"
        var="$(optin_var_for "$topic")"
        if [[ "$topic" == "82-ai-tools" ]]; then
            printf '%s  %s  opt-in: INCLUDE_AI_TOOLS=1 MESH_IDENTITY_REPO=<url>  AI review prompts + token-saving CLI tools\n' "$number" "$topic"
        elif [[ "$topic" == "95-dotfiles-personal" ]]; then
            printf '%s  %s  opt-in: INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=<url>\n' "$number" "$topic"
        elif [[ -n "$var" ]]; then
            printf '%s  %s  opt-in: %s=1\n' "$number" "$topic" "$var"
        else
            printf '%s  %s\n' "$number" "$topic"
        fi
    done
}

known_topics_inline() {
    local topic
    printf '%s' "${all_topics[*]:-}"
}

resolve_topic_selector() {
    local selector="$1"
    local topic number match=""
    local matches=0

    if in_list "$selector" "${all_topics[@]+"${all_topics[@]}"}"; then
        printf '%s\n' "$selector"
        return 0
    fi

    case "$selector" in
        ''|*[!0-9]*)
            fail "unknown topic selector '$selector' (known: $(known_topics_inline))"
            return 1
            ;;
    esac

    number="$(printf '%02d' "$((10#$selector))")"
    for topic in "${all_topics[@]+"${all_topics[@]}"}"; do
        case "$topic" in
            "$number"-*)
                match="$topic"
                matches=$((matches + 1))
                ;;
        esac
    done

    case "$matches" in
        1)
            printf '%s\n' "$match"
            return 0
            ;;
        *)
            fail "unknown topic selector '$selector' (known: $(known_topics_inline))"
            return 1
            ;;
    esac
}

for arg in "$@"; do
    case "$arg" in
        --list-topics)
            print_topic_list
            exit 0
            ;;
    esac
done

# Parse --dry-run BEFORE any side effects (BOOTSTRAP_STATE_DIR creation,
# symlink prelude, topic invocation). The usage text promises dry-run
# "prints actions without executing"; the previous ordering ran state
# + symlink mutations before --dry-run was honored.
for arg in "$@"; do
    case "$arg" in
        --dry-run) export DRY_RUN=1 ;;
        --non-interactive) export NON_INTERACTIVE=1 ;;
    esac
done

# Collect follow-up actions from every topic into a single file so we
# can render one consolidated summary at the end (vs. scattering `!`
# warnings across hundreds of lines of topic output). Topics invoke
# `followup <severity> <msg>` from lib/log.sh — the severity bucket
# (critical / manual / info) drives how the summary renders.
BOOTSTRAP_FOLLOWUP_FILE="$(mktemp -t mesh-workstation-followup.XXXXXX 2>/dev/null || mktemp)"
export BOOTSTRAP_FOLLOWUP_FILE
trap 'rm -f "${BOOTSTRAP_FOLLOWUP_FILE:-}"' EXIT

# Persistent state across bootstrap runs — stores last-used values so
# the interactive menu can pre-fill fields (CODE_DIR, PHP_VERSIONS,
# opt-in flags, etc.) on re-runs instead of always showing the defaults.
# Format: shell-sourceable `export KEY=value` lines — readable, diff-able,
# editable by hand. Delete the file to reset to defaults.
export BOOTSTRAP_STATE_DIR="$HOME/.local/state/mesh-workstation"
export BOOTSTRAP_STATE_CONFIG="$BOOTSTRAP_STATE_DIR/config.env"
if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "+ mkdir -p $BOOTSTRAP_STATE_DIR  [dry-run, skipped]"
else
    mkdir -p "$BOOTSTRAP_STATE_DIR"
    # Migrate state from the old directory name (dev-bootstrap → mesh-workstation).
    _old_state="$HOME/.local/state/dev-bootstrap"
    if [[ -d "$_old_state" ]] && [[ "$_old_state" != "$BOOTSTRAP_STATE_DIR" ]]; then
        for _f in "$_old_state"/*; do
            [[ -f "$_f" ]] || continue
            _base="${_f##*/}"
            [[ -f "$BOOTSTRAP_STATE_DIR/$_base" ]] || cp "$_f" "$BOOTSTRAP_STATE_DIR/$_base"
        done
    fi
    unset _old_state _f _base
    # Remove stale shell fragments from the env rename (dev-bootstrap → mesh).
    for _stale in "$HOME/.bashrc.d/00-dev-bootstrap-env.sh" "$HOME/.zshrc.d/00-dev-bootstrap-env.sh"; do
        [[ -f "$_stale" ]] && rm -f "$_stale"
    done
    unset _stale
fi
if [[ -f "$BOOTSTRAP_STATE_CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$BOOTSTRAP_STATE_CONFIG"
    # Signal to should_show_menu that the control vars came from state,
    # not from a user-set env — state-loaded values must not suppress
    # the interactive menu (we want it to re-show with them as defaults).
    export STATE_LOADED=1
fi

# ─── Legacy alias: INCLUDE_LARAVEL=1 → INCLUDE_WEBSTACK=1 ───────────────
# The topic was renamed from 60-laravel-stack to 60-web-stack (it installs
# a full web dev stack: nginx + reverse proxy + MySQL + Redis + mkcert +
# PHP-FPM, of which Laravel is just one consumer). The env var + state
# file keys are canonically INCLUDE_WEBSTACK now, but we honor the
# previous name indefinitely so automation scripts, CI configs, and
# persisted state files from older runs keep working unchanged.
if [[ -n "${INCLUDE_LARAVEL:-}" ]] && [[ -z "${INCLUDE_WEBSTACK:-}" ]]; then
    export INCLUDE_WEBSTACK="$INCLUDE_LARAVEL"
fi

cd "$HERE"

# shellcheck disable=SC1091
source "$HERE/scripts/lib/log.sh"

# ─── Secrets (tokens) ───────────────────────────────────────────────
# Separate from config.env because of different mode (0600 vs 0644)
# and different blast-radius semantics. Sourced BEFORE the menu so
# `secrets_has NGROK_AUTHTOKEN` can gate whether the menu prompts
# for a token, and BEFORE topics run so installers just read env.
# See lib/secrets.sh for the allowed/forbidden key taxonomy.
# shellcheck disable=SC1091
source "$HERE/scripts/lib/secrets.sh"
secrets_load || warn "secrets file present but could not be sourced — continuing without it"

# ─── Persistent state (prefixes, decisions) ───────────────────────────
# Loaded BEFORE topics so 00-core can honor a previously-recorded
# BREW_PREFIX choice (e.g. user picked /Volumes/External/homebrew on a
# previous run; never re-prompt). See lib/state.sh.
# shellcheck disable=SC1091
source "$HERE/scripts/lib/state.sh"
state_load

usage() {
    cat <<'EOF'
mesh-workstation — set up a development machine

Interactive mode (default):
  bash setup.sh                 prompts for opt-ins + identity, then runs

Automation / CI mode:
  NON_INTERACTIVE=1 bash setup.sh       skip menu even on a TTY
  bash setup.sh --non-interactive       same, flag form
  DRY_RUN=1 bash setup.sh               print actions without executing
  bash setup.sh --dry-run               same, flag form
  bash setup.sh --list-topics           list topic numbers and names
  SKIP_TOPICS="NN-x" ...                    skip specific topics
  ONLY_TOPICS="NN-x NN-y" ...               run only these topics
  ONLY_TOPICS="20 30" ...                   numeric shorthand is accepted

Opt-in topics (menu toggles these, or set env var in automation):
  45-docker             INCLUDE_DOCKER=1
  60-web-stack          INCLUDE_WEBSTACK=1   (legacy: INCLUDE_LARAVEL=1 still accepted)
  70-remote-access      INCLUDE_REMOTE=1
  82-ai-tools           INCLUDE_AI_TOOLS=1 MESH_IDENTITY_REPO=<url>  AI review prompts + token-saving CLI tools
  85-code-server        INCLUDE_CODE_SERVER=1
  90-editor             INCLUDE_EDITOR=1
  95-dotfiles-personal  INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=<url>
                       MESH_NPM_GLOBAL=1  npm globals under ~/.npm-global

Other env vars:
  GIT_NAME, GIT_EMAIL, CODE_DIR, MESH_IDENTITY_DIR, NO_COLOR
  GPG_SIGN=1 [+ GPG_KEY_ID=<id>]  enable GPG commit signing in 50-git
  PHP_VERSIONS="8.4 8.5" [+ PHP_DEFAULT=8.5]  multi-PHP install (60-web-stack)
  INCLUDE_WEBSTACK=1              opt-in for 60-web-stack
                                  (accepted: INCLUDE_LARAVEL=1 for backward compat)
  INCLUDE_MAILPIT=1, INCLUDE_NGROK=1 [+ NGROK_AUTHTOKEN=], INCLUDE_MSSQL=1
  DEV_DEFAULT_PORT=3000           default port for *.front.localhost proxy

See topics/*/README.md for topic-specific documentation.
EOF
}

for arg in "$@"; do
    case "$arg" in
        --help|-h)
            usage
            exit 0
            ;;
        --non-interactive)
            export NON_INTERACTIVE=1
            ;;
        --dry-run)
            export DRY_RUN=1
            ;;
    esac
done

# C13.5: ensure bin/mesh is discoverable on PATH via ~/.local/bin/ symlink.
# Idempotent — only touches the link if absent or pointing elsewhere.
# Moved below --help / --list-topics handling so introspection has no FS
# side effects (Review B finding B6). Under --dry-run, prints the action
# without performing it (CP4 chunk B finding B-F-004).
install_mesh_symlink() {
    local dst="$HOME/.local/bin/mesh"
    local target="$HERE/bin/mesh"
    # Refuse to symlink a non-directory at ~/.local/bin/ (e.g. if the
    # user pre-created a regular file there). Warn + skip; remaining
    # setup proceeds without the convenience symlink.
    if [[ -e "$HOME/.local/bin" && ! -d "$HOME/.local/bin" ]]; then
        warn "$HOME/.local/bin is not a directory — skipping mesh symlink install"
        return 0
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        echo "+ mkdir -p $HOME/.local/bin  [dry-run, skipped]"
        echo "+ ln -sf $target $dst  [dry-run, skipped]"
        return 0
    fi
    mkdir -p "$HOME/.local/bin"
    # Already correct → no-op.
    if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$target" ]]; then
        return 0
    fi
    # Regular file at the destination: don't silently clobber a binary
    # the user (or another package manager) put there. Warn and skip;
    # the user can move it and re-run setup.sh if they want our link.
    if [[ -e "$dst" ]] && ! [[ -L "$dst" ]]; then
        warn "$dst is a regular file (not a symlink) — leaving alone; mv it aside to install the bin/mesh shim"
        return 0
    fi
    ln -sf "$target" "$dst"
}
install_mesh_symlink

# ---------- Detect OS ----------
OS="$(bash "$HERE/scripts/lib/detect-os.sh")"
export OS

if [[ "$OS" == "unknown" ]]; then
    fail "unsupported OS (uname -s = $(uname -s))"
    exit 1
fi

banner "mesh-workstation :: $OS"

# ---------- Detect Brew (macOS only; may be absent on fresh install) ----------
BREW_BIN=""
BREW_PREFIX=""

detect_brew_if_mac() {
    # Populates BREW_BIN and BREW_PREFIX. Safe to call repeatedly — on WSL/Linux
    # it's a no-op. On Mac it refreshes both if brew has since been installed.
    if [[ "$OS" != "mac" ]]; then
        return 0
    fi
    if out=$(bash "$HERE/scripts/lib/detect-brew.sh" 2>/dev/null); then
        eval "$out"
        export BREW_BIN BREW_PREFIX
    fi
}

derive_nginx_conf_dir() {
    # 60-web-stack deploys multiple nginx files that reference these
    # paths via envsubst. deploy.sh runs in a fresh subshell from the
    # bootstrap parent (NOT from install.*.sh), so exports inside the
    # installer don't propagate here. Every path the DEPLOY file mentions
    # must be derived + exported in the bootstrap shell itself.
    case "$OS" in
        wsl|linux)
            NGINX_AVAILABLE_DIR="/etc/nginx/sites-available"
            NGINX_ENABLED_DIR="/etc/nginx/sites-enabled"
            NGINX_SNIPPET_DIR="/etc/nginx/snippets"
            NGINX_MAP_DIR="/etc/nginx/conf.d"
            CERT_DIR="/etc/nginx/certs"
            ;;
        mac)
            if [[ -n "$BREW_PREFIX" ]]; then
                NGINX_AVAILABLE_DIR="$BREW_PREFIX/etc/nginx/servers-available"
                NGINX_ENABLED_DIR="$BREW_PREFIX/etc/nginx/servers"
                NGINX_SNIPPET_DIR="$BREW_PREFIX/etc/nginx/snippets"
                NGINX_MAP_DIR="$BREW_PREFIX/etc/nginx/conf.d"
                CERT_DIR="$BREW_PREFIX/etc/nginx/certs"
            else
                NGINX_AVAILABLE_DIR="" NGINX_ENABLED_DIR=""
                NGINX_SNIPPET_DIR=""   NGINX_MAP_DIR=""
                CERT_DIR=""
            fi
            ;;
        *)
            NGINX_AVAILABLE_DIR="" NGINX_ENABLED_DIR=""
            NGINX_SNIPPET_DIR=""   NGINX_MAP_DIR=""
            CERT_DIR=""
            ;;
    esac
    # Back-compat alias (templates that still use $NGINX_CONF_DIR — same
    # semantic as sites-enabled for historical reasons).
    NGINX_CONF_DIR="$NGINX_ENABLED_DIR"
    export NGINX_CONF_DIR NGINX_AVAILABLE_DIR NGINX_ENABLED_DIR \
           NGINX_SNIPPET_DIR NGINX_MAP_DIR CERT_DIR

    # DEV_DEFAULT_PORT is used by catchall-proxy.conf; default if unset
    # so envsubst never leaves a literal ${DEV_DEFAULT_PORT} in the file.
    : "${DEV_DEFAULT_PORT:=3000}"
    export DEV_DEFAULT_PORT
}

detect_brew_if_mac
derive_nginx_conf_dir

if [[ "$OS" == "mac" ]]; then
    if [[ -n "$BREW_BIN" ]]; then
        info "brew found at $BREW_BIN (prefix $BREW_PREFIX)"
    else
        warn "brew not installed yet; topic 00-core will install it"
    fi
fi

# ---------- Interactive menu (default on TTYs; skipped for automation) ----------
# shellcheck disable=SC1091
source "$HERE/scripts/lib/menu.sh"

ensure_node() {
    command -v node >/dev/null 2>&1 && return 0
    if [[ "$OS" == "mac" ]]; then
        local brew_bin="${BREW_BIN:-$(command -v brew 2>/dev/null || true)}"
        if [[ -n "$brew_bin" ]]; then
            info "Installing Node.js for the interactive menu..."
            "$brew_bin" install node 2>&1 | sed 's/^/    /' || true
            command -v node >/dev/null 2>&1 && return 0
        fi
    else
        if command -v apt-get >/dev/null 2>&1; then
            info "Installing Node.js for the interactive menu..."
            sudo apt-get install -y -qq nodejs npm 2>&1 | sed 's/^/    /' || true
            command -v node >/dev/null 2>&1 && return 0
        fi
    fi
    return 1
}

if should_show_menu; then
    MENU_DIR="$HERE/scripts/menu"
    if [[ -f "$MENU_DIR/index.js" ]] && ensure_node; then
        # Node.js @clack menu (F9.5): per-item selection, search, uninstall
        if [[ ! -d "$MENU_DIR/node_modules" ]]; then
            (cd "$MENU_DIR" && npm install --omit=dev --no-audit --no-fund --silent 2>/dev/null) || true
        fi
        # First-run migration: old config.env → selections.list + params.env
        SELECTIONS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list"
        OLD_STATE_CONFIG="$HOME/.local/state/mesh-workstation/config.env"
        if [[ -f "$OLD_STATE_CONFIG" && ! -f "$SELECTIONS_FILE" ]]; then
            info "Migrating legacy config.env to selections.list + params.env..."
            node -e "import { migrateLegacyConfig } from '$MENU_DIR/lib/core/migrate.js'; migrateLegacyConfig('$HERE/topics');" 2>/dev/null || true
        fi
        node "$MENU_DIR/index.js" || true
    else
        # Fallback: legacy whiptail menu
        prepare_interactive_menu_dependencies || true
        if ensure_whiptail; then
            run_menu
        fi
    fi
fi

# ---------- Bridge: @clack menu output → legacy INCLUDE_* gates ----------
# The new menu writes selections.list (one `topic/item` per line) and
# params.env (KEY=VALUE). Per-topic install.sh + a handful of opt-in
# extras (mailpit, ngrok, postgres, mssql-driver) still consume the
# legacy INCLUDE_* env names — this function bridges the two so a tick
# in the menu actually reaches the engine.
#
# Precedence:
#   - params.env (typed inputs like POSTGRES_VERSION) flows into the
#     environment first so any later prompt/override can see it.
#   - INCLUDE_* are set to 1 for every topic that has at least one
#     selected item, and for the 4 gated extras when their item is
#     selected. We never set to 0 — a CLI override `INCLUDE_FOO=1
#     bash setup.sh` still wins over an absent selection.
#
# Skip-safe: noop if selections.list doesn't exist (fresh install,
# legacy whiptail flow, or `mesh` ran the menu via a different path).
ingest_menu_selections() {
    local sel="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list"
    local par="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/params.env"
    [[ -f "$sel" ]] || return 0

    if [[ -f "$par" ]]; then
        set -a
        # shellcheck disable=SC1090
        source "$par"
        set +a
    fi

    local entry topic item
    while IFS= read -r entry || [[ -n "$entry" ]]; do
        # Trim whitespace and skip comments / blank lines.
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z "$entry" || "${entry:0:1}" == "#" ]] && continue

        topic="${entry%%/*}"
        item="${entry#*/}"

        case "$topic" in
            45-docker)            export INCLUDE_DOCKER=1 ;;
            60-web-stack)         export INCLUDE_WEBSTACK=1 ;;
            70-remote-access)     export INCLUDE_REMOTE=1 ;;
            82-ai-tools)          export INCLUDE_AI_TOOLS=1 ;;
            85-code-server)       export INCLUDE_CODE_SERVER=1 ;;
            90-editor)            export INCLUDE_EDITOR=1 ;;
            95-dotfiles-personal) export INCLUDE_IDENTITY=1 ;;
        esac

        case "$item" in
            mailpit)      export INCLUDE_MAILPIT=1 ;;
            ngrok)        export INCLUDE_NGROK=1 ;;
            postgres)     export INCLUDE_POSTGRES=1 ;;
            mssql-driver) export INCLUDE_MSSQL=1 ;;
        esac
    done < "$sel"
}
ingest_menu_selections

# ---------- Defaults for inherited vars ----------
export MESH_IDENTITY_REPO="${MESH_IDENTITY_REPO:-}"
export MESH_IDENTITY_DIR="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"
export MESH_NPM_GLOBAL="${MESH_NPM_GLOBAL:-0}"
export MESH_AI_PACKAGES="${MESH_AI_PACKAGES:-0}"
if [[ "${MESH_AI_PACKAGES:-0}" == "1" && -z "${INCLUDE_AI_TOOLS:-}" ]]; then
    export INCLUDE_AI_TOOLS=1
fi
if [[ -z "${INCLUDE_IDENTITY+x}" ]]; then
    # Backward compatibility: MESH_IDENTITY_REPO alone used to mean "run 95".
    # The interactive menu sets this explicitly, so an AI-only selection can
    # use MESH_IDENTITY_REPO as manifest source without applying personal dotfiles.
    if [[ -n "${MESH_IDENTITY_REPO:-}" ]]; then
        export INCLUDE_IDENTITY=1
    else
        export INCLUDE_IDENTITY=0
    fi
else
    export INCLUDE_IDENTITY="${INCLUDE_IDENTITY:-0}"
fi
export GIT_NAME="${GIT_NAME:-}"
export GIT_EMAIL="${GIT_EMAIL:-}"
export CODE_DIR="${CODE_DIR:-$HOME/code/web}"
export INCLUDE_DOCKER="${INCLUDE_DOCKER:-0}"
export INCLUDE_WEBSTACK="${INCLUDE_WEBSTACK:-0}"
# Keep legacy name exported too so any external integration / script that
# reads INCLUDE_LARAVEL continues to observe the canonical value.
export INCLUDE_LARAVEL="$INCLUDE_WEBSTACK"
export INCLUDE_REMOTE="${INCLUDE_REMOTE:-0}"
export INCLUDE_AI_TOOLS="${INCLUDE_AI_TOOLS:-0}"
export INCLUDE_CODE_SERVER="${INCLUDE_CODE_SERVER:-0}"
export CODE_SERVER_PORT="${CODE_SERVER_PORT:-8080}"
export CODE_SERVER_LABEL="${CODE_SERVER_LABEL:-com.${USER}.code-server}"
export CODE_SERVER_INSTALL_METHOD="${CODE_SERVER_INSTALL_METHOD:-standalone}"
export CODE_SERVER_TAILSCALE_SERVE="${CODE_SERVER_TAILSCALE_SERVE:-1}"
export CODE_SERVER_UPGRADE="${CODE_SERVER_UPGRADE:-0}"
export CODE_SERVER_CHECK_UPDATES="${CODE_SERVER_CHECK_UPDATES:-1}"
export INCLUDE_EDITOR="${INCLUDE_EDITOR:-0}"
export NO_COLOR="${NO_COLOR:-}"

# ---------- Collect + validate topics ----------
collect_topics

in_list() {
    local needle="$1"
    shift
    for x in "$@"; do
        [[ "$x" == "$needle" ]] && return 0
    done
    return 1
}

# bash 3.2 (macOS default) + `set -u` is peculiar about empty arrays:
# `skip_list=(${SKIP_TOPICS:-})` leaves `skip_list` "declared but unbound"
# when the env var is empty, so any later `"${skip_list[@]}"` trips
# "unbound variable". Workaround: only build the array when the source
# var has content; otherwise stay explicit empty. Commas are accepted
# too because `mesh update --topics 20,30` normalizes through this path.
skip_list=()
only_list=()
if [[ -n "${SKIP_TOPICS:-}" ]]; then
    skip_source="${SKIP_TOPICS//,/ }"
    # shellcheck disable=SC2206
    skip_raw=($skip_source)
    for topic_selector in "${skip_raw[@]+"${skip_raw[@]}"}"; do
        topic="$(resolve_topic_selector "$topic_selector")" || exit 1
        skip_list+=("$topic")
    done
fi
if [[ -n "${ONLY_TOPICS:-}" ]]; then
    only_source="${ONLY_TOPICS//,/ }"
    # shellcheck disable=SC2206
    only_raw=($only_source)
    for topic_selector in "${only_raw[@]+"${only_raw[@]}"}"; do
        topic="$(resolve_topic_selector "$topic_selector")" || exit 1
        only_list+=("$topic")
    done
fi

# ---------- Sudo cache warmup ----------
# Bootstrap needs sudo for apt, systemctl, /etc/ writes in several topics.
# Prompt once upfront; subsequent sudo calls within the cache window
# (default 5-15min via /etc/sudoers timestamp_timeout) are silent.
# If the run takes longer than the cache, the next sudo call will re-prompt —
# acceptable trade-off vs. permanent NOPASSWD which is attack surface.
if [[ "${DRY_RUN:-}" != "1" ]]; then
    if ! sudo -v 2>/dev/null; then
        warn "sudo cache warmup failed (non-fatal — topics will prompt individually)"
    fi
fi

# ---------- Legacy cleanup (unconditional) ----------
# Pre-v2026-04-22 versions of topic 70-remote-access created a permanent
# NOPASSWD sudoers entry. That's attack surface we don't want. Clean it
# up on every bootstrap run — independent of opt-ins — so forks inherit
# the fix even if they don't re-run 70-remote-access.
if [[ "$OS" == "wsl" || "$OS" == "linux" ]] && [[ "${DRY_RUN:-}" != "1" ]]; then
    legacy_nopasswd="/etc/sudoers.d/10-${USER}-nopasswd"
    if [[ -f "$legacy_nopasswd" ]] || sudo test -f "$legacy_nopasswd" 2>/dev/null; then
        info "removing legacy NOPASSWD sudoers entry at $legacy_nopasswd"
        sudo rm -f "$legacy_nopasswd"
        ok "legacy NOPASSWD sudoers removed"
    fi
fi

# ---------- Log file ----------
LOG="/tmp/mesh-workstation-$OS-$(date +%Y%m%d-%H%M%S).log"
info "full log: $LOG"

# Avoid `declare -a foo=() bar=() baz=()` one-liner — bash 3.2 parses it
# inconsistently. Split into 3 plain assignments.
passed=()
failed=()
skipped=()

run_topic() {
    local topic="$1"
    local dir="$HERE/topics/$topic"

    # Opt-in gate
    local var
    var="$(optin_var_for "$topic")"
    if [[ -n "$var" ]]; then
        local val="${!var:-0}"
        if [[ "$val" != "1" ]]; then
            if [[ "${MESH_REQUIRE_ONLY_TOPICS:-0}" == "1" ]] && \
               in_list "$topic" "${only_list[@]+"${only_list[@]}"}"; then
                fail "$topic is opt-in; set $var=1 to run it"
                failed+=("$topic")
            else
                info "skip $topic (opt-in: set $var=1 to enable)"
                skipped+=("$topic")
            fi
            return 0
        fi
    fi

    # Dotfiles-backed opt-ins require MESH_IDENTITY_REPO.
    if [[ ( "$topic" == "82-ai-tools" || "$topic" == "95-dotfiles-personal" ) && -z "$MESH_IDENTITY_REPO" ]]; then
        if [[ "${MESH_REQUIRE_ONLY_TOPICS:-0}" == "1" ]] && \
           in_list "$topic" "${only_list[@]+"${only_list[@]}"}"; then
            fail "$topic is opt-in; set MESH_IDENTITY_REPO=<url> to run it"
            failed+=("$topic")
        else
            info "skip $topic (set MESH_IDENTITY_REPO to enable)"
            skipped+=("$topic")
        fi
        return 0
    fi

    # Resolve installer
    local installer=""
    if [[ -f "$dir/install.$OS.sh" ]]; then
        installer="$dir/install.$OS.sh"
    elif [[ -f "$dir/install.sh" ]]; then
        installer="$dir/install.sh"
    fi

    if [[ -z "$installer" ]] && [[ ! -d "$dir/templates" ]]; then
        info "skip $topic (no installer, no templates)"
        skipped+=("$topic")
        return 0
    fi

    banner "topic :: $topic"

    if [[ -n "$installer" ]]; then
        if [[ "${DRY_RUN:-}" == "1" ]]; then
            info "would run: $installer"
        else
            if ! bash "$installer" 2>&1 | tee -a "$LOG"; then
                fail "$topic installer failed"
                failed+=("$topic")
                return 0
            fi
        fi
    fi

    if [[ -d "$dir/templates" ]]; then
        if [[ "${DRY_RUN:-}" == "1" ]]; then
            info "would deploy: $dir/templates"
        else
            if ! bash "$HERE/scripts/lib/deploy.sh" "$dir/templates" 2>&1 | tee -a "$LOG"; then
                fail "$topic templates deploy failed"
                failed+=("$topic")
                return 0
            fi
        fi
    fi

    # Refresh brew detection + derived vars. Cheap, and catches the case where
    # 00-core (or any earlier topic) just installed brew on a fresh Mac.
    if [[ "$OS" == "mac" ]] && [[ -z "$BREW_BIN" ]]; then
        detect_brew_if_mac
        derive_nginx_conf_dir
        [[ -n "$BREW_BIN" ]] && info "brew now available at $BREW_BIN"
    fi

    passed+=("$topic")
}

for topic in "${all_topics[@]}"; do
    # Defensive `${arr[@]+"${arr[@]}"}` expansion — under bash 3.2 + set -u,
    # empty arrays passed via plain `"${arr[@]}"` raise "unbound variable".
    # The `+` form expands to nothing when the array is empty, to the full
    # contents otherwise. Works identically on bash 4+ / 5.x.
    if [[ "${#only_list[@]}" -gt 0 ]] && ! in_list "$topic" "${only_list[@]+"${only_list[@]}"}"; then
        continue
    fi
    if in_list "$topic" "${skip_list[@]+"${skip_list[@]}"}"; then
        info "skip $topic (SKIP_TOPICS)"
        skipped+=("$topic")
        continue
    fi
    run_topic "$topic"
done

# ---------- Summary ----------
banner "summary"
printf '  passed : %d  (%s)\n' "${#passed[@]}"  "${passed[*]:-}"
printf '  failed : %d  (%s)\n' "${#failed[@]}"  "${failed[*]:-}"
printf '  skipped: %d  (%s)\n' "${#skipped[@]}" "${skipped[*]:-}"

# Consolidated follow-up summary — one place to see every manual step
# + every critical gap that survived the run. Topics write these via
# `followup <severity> <msg>` from lib/log.sh; render_followup_summary
# reads the collected file and renders grouped by severity.
render_followup_summary

if [[ "${#failed[@]}" -gt 0 ]]; then
    fail "some topics failed — see $LOG"
    exit 1
fi

if ! command -v mesh >/dev/null 2>&1; then
    warn "mesh is installed at ~/.local/bin/mesh but not in your current \$PATH"
    warn "open a new terminal, or run:  export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

ok "done — full log: $LOG"
