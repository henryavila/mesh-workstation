#!/usr/bin/env bash
# Check both macOS font registration and the managed dynamic profile.
_iterm2_dir() {
    local candidate
    for candidate in /Applications/iTerm.app "$HOME/Applications/iTerm.app"; do
        if [[ -d "$candidate" ]]; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}
_iterm2_configure() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    bash "$here/../scripts/configure-iterm2-font.sh" "$@"
}
check() {
    _iterm2_dir >/dev/null || return 0
    _iterm2_configure --check
}
install() {
    _iterm2_dir >/dev/null || return 0
    _iterm2_configure
}
verify() { check; }
repair() { install; }
rollback() { :; }
