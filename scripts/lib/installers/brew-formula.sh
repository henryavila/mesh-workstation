# shellcheck shell=bash
# Driver: brew-formula. Installs Homebrew formula.
# CP4 A2-F-002: `--` separator stops brew option parsing.
#
# Read probes use ${BREW_BIN:-brew} + offline env guards: on a custom prefix a
# plain `brew list` can reach the Homebrew API and exit non-zero when DNS is down
# (verify/operational audit 2026-06-03, Codex finding #4) even though the local
# Cellar is present. The guards force a purely local, offline-safe query.
_brew_formula_bin() {
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

brew_formula_check() {
    HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1 \
        "$(_brew_formula_bin)" list --formula -- "$1" >/dev/null 2>&1
}

# install(): a present formula reaching install() means its check FAILED — for an
# operational manifest `check:` (e.g. mosh-mac) or the engine --repair sweep that
# means the listed formula is broken ⇒ this is a REPAIR, so reinstall instead of
# no-op'ing. Always-on, single attempt (the engine caps the lifecycle; a
# persistent break surfaces as rc 67, never an install loop). Absent ⇒ plain
# install. `brew install` on an already-present formula is a no-op, which is
# exactly why a stronger check alone could not fix the live mosh break.
brew_formula_install() {
    local brew; brew="$(_brew_formula_bin)"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
    if "$brew" list --formula -- "$1" >/dev/null 2>&1; then
        echo "brew-formula: $1 present but install() called → reinstall (repair)" >&2
        "$brew" reinstall --formula -- "$1"
    else
        "$brew" install --formula -- "$1"
    fi
}

# verify(): present AND every linked library of the formula's binaries resolves
# on disk, via the standalone Mach-O resolver. Catches a downstream formula left
# linked against a dependency dylib that a major-version bump removed (the live
# mosh case: mosh-server/-client vs the absent libprotobuf.34.1.0.dylib) — a
# break `brew list` cannot see. Formulae that ship NO bin/sbin executables
# (zsh-completions/-autosuggestions/-syntax-highlighting) fall back to
# presence-only: they lack the native-dependency fragility, so there is nothing
# to otool-probe and a false-fail there would needlessly abort the run.
brew_formula_verify() {
    local brew; brew="$(_brew_formula_bin)"
    export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_FROM_API=1
    "$brew" list --formula -- "$1" >/dev/null 2>&1 || return 1
    local resolver="${MESH_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/mach-o-resolvable.sh"
    [[ -r "$resolver" ]] || return 0   # resolver unavailable → presence-only
    local binp
    while IFS= read -r binp; do
        [[ -n "$binp" ]] || continue
        bash "$resolver" "$binp" || return 1
    done < <("$brew" list --formula --verbose -- "$1" 2>/dev/null | grep -E '/(s?bin)/[^/]+$')
    return 0
}

# repair() (engine --repair sweep): brew_formula_install is already reinstall-aware,
# so a repair is just re-running it (reinstall when present).
brew_formula_repair() { brew_formula_install "$1"; }

# Version-aware update (T-600): upgrade only when brew reports it outdated.
# Returns the engine's "changed" sentinel (rc 10) when an actual upgrade ran, so
# the engine can restart a linked service (restart_service:) that must reload the
# new binary; rc 0 = already latest (nothing to restart). A failed `brew upgrade`
# propagates its own non-zero rc unchanged.
brew_formula_update() {
    local brew; brew="$(_brew_formula_bin)"
    if [[ -n "$(HOMEBREW_NO_AUTO_UPDATE=1 "$brew" outdated --formula "$1" 2>/dev/null)" ]]; then
        echo "brew-formula: upgrading $1" >&2
        "$brew" upgrade --formula -- "$1" || return $?
        return 10
    fi
    echo "brew-formula: $1 already latest" >&2
    return 0
}
