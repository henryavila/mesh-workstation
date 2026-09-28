#!/usr/bin/env bash
# scripts/lib/brew-prefix-offer.sh — ask where Homebrew should live.
#
# Source-only. setup.sh calls offer_separate_brew_prefix() as soon as it sees
# that macOS has no brew binary. The install engine is started later as
# `install-engine.sh 2>&1 | tee`, so foundation's own TTY prompt (decide_brew_prefix
# rung 4) never sees a terminal on the normal `bash setup.sh` path. This offer
# runs in the setup.sh process, while stdin and stdout are still the terminal,
# and exports BREW_CUSTOM_PREFIX for foundation's rung 3.
#
# No-op unless this run will install Homebrew and nobody has chosen a prefix:
#   OS=mac, BREW_BIN empty, BREW_CUSTOM_PREFIX unset, no recorded BREW_PREFIX,
#   not --adopt, not --dry-run.
# Interactive TTY: confirm a separate path, then ask for it, and export the
# variable. "No", or a blank/relative answer, exports /opt/homebrew so foundation
# does not fall through to its own prompt. Non-interactive: leave the variable
# unset (foundation defaults to /opt/homebrew) and warn.
#
# Test injection: BREW_OFFER_FORCE_TTY=1 treats the caller as a TTY. It does
# not override NON_INTERACTIVE=1.

# True when detect-brew.sh can find this prefix with an empty PATH.
# The external arm matches the glob in detect-brew.sh: /Volumes/External*/homebrew.
brew_prefix_detectable() {
    local p="${1%/}"
    case "$p" in
        /opt/homebrew|/usr/local) return 0 ;;
        /Volumes/External*/homebrew) return 0 ;;
        *) return 1 ;;
    esac
}

# Suggested separate path when the usual external volume is mounted.
brew_prefix_suggest() {
    if [[ -d /Volumes/External ]]; then
        printf '%s' /Volumes/External/homebrew
    fi
}

_brew_offer_recorded_prefix() {
    declare -F state_get >/dev/null 2>&1 || return 0
    state_get BREW_PREFIX 2>/dev/null || true
}

_brew_offer_interactive() {
    [[ "${NON_INTERACTIVE:-0}" == "1" ]] && return 1
    [[ "${BREW_OFFER_FORCE_TTY:-0}" == "1" ]] && return 0
    [[ -t 0 && -t 1 ]]
}

# Export BREW_CUSTOM_PREFIX, or leave it unset. rc 1 = the chosen directory
# exists and is not empty (caller should abort before the menu).
offer_separate_brew_prefix() {
    [[ "${OS:-}" == "mac" ]] || return 0
    [[ -z "${BREW_BIN:-}" ]] || return 0
    [[ "${ADOPT_MODE:-0}" == "1" ]] && return 0
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0

    if [[ -n "${BREW_CUSTOM_PREFIX:-}" ]]; then
        info "Homebrew will be installed at $BREW_CUSTOM_PREFIX (BREW_CUSTOM_PREFIX)"
        return 0
    fi

    local recorded
    recorded="$(_brew_offer_recorded_prefix)"
    if [[ -n "$recorded" ]]; then
        info "Homebrew prefix $recorded is recorded in state; foundation will reinstall there"
        return 0
    fi

    if ! _brew_offer_interactive; then
        warn "brew not installed yet; the foundation topic will install it at /opt/homebrew"
        warn "  (set BREW_CUSTOM_PREFIX=/Volumes/External/homebrew to choose a separate path)"
        return 0
    fi

    cat >&2 <<'EOF'

  Homebrew is not installed. This run installs it.

    Canonical path:  /opt/homebrew
                     bottles work, no extra workarounds
    Separate path:   tooling on another disk. The path this setup finds
                     again with brew off PATH is /Volumes/External/homebrew
                     (also /Volumes/External 1/homebrew, …).
                     Most formulae build from source there.

EOF
    if ! confirm "Install Homebrew on a separate path"; then
        export BREW_CUSTOM_PREFIX="/opt/homebrew"
        info "Homebrew will be installed at /opt/homebrew"
        return 0
    fi

    local suggested chosen
    suggested="$(brew_prefix_suggest)"
    chosen="$(ask_line 'Homebrew prefix' "$suggested")"
    chosen="${chosen%/}"
    if [[ -z "$chosen" || "$chosen" != /* ]]; then
        warn "prefix must be an absolute path — using /opt/homebrew"
        export BREW_CUSTOM_PREFIX="/opt/homebrew"
        info "Homebrew will be installed at /opt/homebrew"
        return 0
    fi
    if ! brew_prefix_detectable "$chosen"; then
        warn "$chosen will not be found on the next run until brew is on PATH"
        warn "  use /Volumes/External/homebrew so detect-brew.sh finds it with an empty PATH"
    fi
    if [[ -e "$chosen" ]] && [[ -n "$(ls -A "$chosen" 2>/dev/null || true)" ]]; then
        log_error "refusing $chosen — directory exists and is not empty"
        log_error "  remove it or pick a different prefix"
        return 1
    fi
    export BREW_CUSTOM_PREFIX="$chosen"
    info "Homebrew will be installed at $BREW_CUSTOM_PREFIX"
}
