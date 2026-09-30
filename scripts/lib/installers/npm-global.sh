# shellcheck shell=bash
# Driver: npm-global. Installs npm package globally.

# `npm` ships with Node, which mesh installs via fnm (~/.local/share/fnm) whose
# shell activation the engine's non-interactive per-item subshell never runs — so
# on a FRESH bootstrap `npm` is not on PATH yet even though `languages/node`
# installed Node earlier in the same run, and the item dies with rc 127. Activate
# the fnm-managed default Node first (mirrors the npx driver + node-fnm.sh); no-op
# when npm is already resolvable (brew/apt Node, or an already-activated shell).
_npm_is_native() {
    case "${1:-}" in
        ''|/mnt/[a-zA-Z]/*) return 1 ;;
        *) return 0 ;;
    esac
}

_npm_global_ensure_on_path() {
    local npm_bin
    npm_bin="$(command -v npm 2>/dev/null || true)"
    if ! _npm_is_native "$npm_bin"; then
        if ! command -v fnm >/dev/null 2>&1 && [[ -x "$HOME/.local/share/fnm/fnm" ]]; then
            PATH="$HOME/.local/share/fnm:$PATH"; export PATH
        fi
        if command -v fnm >/dev/null 2>&1; then
            eval "$(fnm env 2>/dev/null || true)"
            fnm use default >/dev/null 2>&1 || true
        fi
        npm_bin="$(command -v npm 2>/dev/null || true)"
    fi
    if command -v npm >/dev/null 2>&1; then
        local pfx
        pfx="$(npm config get prefix 2>/dev/null || true)"
        if [[ -n "$pfx" && -d "$pfx/bin" ]]; then
            case ":$PATH:" in
                *":$pfx/bin:"*) ;;
                *) export PATH="$pfx/bin:$PATH" ;;
            esac
        fi
    fi
    _npm_is_native "$npm_bin"
}

# check uses --parseable + non-empty output (regex metachars in scoped pkg
# names like `@foo/bar.baz` would false-match with the previous grep "$1@").
npm_global_check()   {
    _npm_global_ensure_on_path || return 1
    local out
    out=$(npm list -g --depth=0 --parseable "$1" 2>/dev/null) || return 1
    [[ -n "$out" ]]
}
npm_global_verify() { npm_global_check "$1"; }
npm_global_install() {
    _npm_global_ensure_on_path || true
    npm install -g "$1"
    local pfx
    pfx="$(npm config get prefix 2>/dev/null || true)"
    if [[ -n "$pfx" && -d "$pfx/bin" ]]; then
        mkdir -p "$HOME/.local/bin"
        for b in "$pfx/bin"/*; do
            if [[ -x "$b" ]] && [[ ! -e "$HOME/.local/bin/$(basename "$b")" ]]; then
                ln -sf "$b" "$HOME/.local/bin/$(basename "$b")" 2>/dev/null || true
            fi
        done
    fi
}
npm_global_repair() {
    _npm_global_ensure_on_path || true
    npm install -g --force "$1"
    local pfx
    pfx="$(npm config get prefix 2>/dev/null || true)"
    if [[ -n "$pfx" && -d "$pfx/bin" ]]; then
        mkdir -p "$HOME/.local/bin"
        for b in "$pfx/bin"/*; do
            if [[ -x "$b" ]] && [[ ! -e "$HOME/.local/bin/$(basename "$b")" ]]; then
                ln -sf "$b" "$HOME/.local/bin/$(basename "$b")" 2>/dev/null || true
            fi
        done
    fi
}
# Version-aware update (T-600): `npm outdated -g <pkg>` exits 0 when the package
# is current, non-zero when a newer version exists — only reinstall if stale.
npm_global_update() {
    _npm_global_ensure_on_path || true
    if npm outdated -g "$1" >/dev/null 2>&1; then
        echo "npm-global: $1 already latest" >&2
    else
        echo "npm-global: updating $1" >&2
        npm install -g "$1"
    fi
}
