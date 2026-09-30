# shellcheck shell=bash
# Driver: brew-cask. Installs Homebrew cask.
# CP4 A2-F-002: `--` separator stops brew option parsing.
# Read probes use ${BREW_BIN:-brew} + offline guards (same rationale as
# brew-formula: a plain `brew list` can hit the API and fail when DNS is down).
_brew_cask_bin() {
    if [[ -n "${BREW_BIN:-}" && -x "${BREW_BIN:-}" ]]; then
        printf '%s' "$BREW_BIN"
    elif command -v brew >/dev/null 2>&1; then
        printf 'brew'
    else
        local cand
        cand="$(bash "${MESH_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/detect-brew.sh" 2>/dev/null || true)"
        if [[ -n "$cand" ]]; then
            eval "$cand"
            export BREW_BIN BREW_PREFIX
            [[ -n "${BREW_PREFIX:-}" && ":$PATH:" != *":$BREW_PREFIX/bin:"* ]] && PATH="$BREW_PREFIX/bin:$PATH"
            printf '%s' "${BREW_BIN:-brew}"
        else
            printf 'brew'
        fi
    fi
}

brew_cask_check()   {
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 \
        "$(_brew_cask_bin)" list --cask -- "$1" >/dev/null 2>&1
}
brew_cask_verify() { brew_cask_check "$1"; }
brew_cask_install() { "$(_brew_cask_bin)" install --cask -- "$1"; }
# repair() (engine --repair sweep): force a reinstall of an installed-but-broken
# cask. `brew install --cask` no-ops when present, so repair needs reinstall.
brew_cask_repair() {
    local brew; brew="$(_brew_cask_bin)"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
    echo "brew-cask: reinstalling $1 (repair)" >&2
    "$brew" reinstall --cask -- "$1"
}
# Version-aware update (T-600): upgrade only when brew reports it outdated.
brew_cask_update() {
    local brew; brew="$(_brew_cask_bin)"
    if [[ -n "$("$brew" outdated --cask "$1" 2>/dev/null)" ]]; then
        echo "brew-cask: upgrading $1" >&2
        "$brew" upgrade --cask -- "$1"
    else
        echo "brew-cask: $1 already latest" >&2
    fi
}
