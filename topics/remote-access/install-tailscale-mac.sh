#!/usr/bin/env bash
# Custom installer: Tailscale.app on macOS.
#
# Detection precedence: Tailscale.app may be installed via .pkg, brew cask,
# or Mac App Store. If /Applications/Tailscale.app exists by any route,
# treat as installed.
#
# Fresh install via brew cask CAN fail on first try because the kernel
# extension needs user approval in System Settings → Privacy & Security,
# which fails silently when brew runs /usr/sbin/installer under sudo. In
# that case, instructions for the .pkg fallback are emitted.

_tailscale_cli_load() {
    local root
    root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)" || return 1
    . "$root/scripts/lib/tailscale-cli.sh"
}

check() {
    local cli
    cli="$(PATH="$HOME/.local/bin:$PATH" type -P tailscale 2>/dev/null || true)"
    [[ -n "$cli" && -x "$cli" ]] || return 1
    [[ -d /Applications/Tailscale.app || -d "$HOME/Applications/Tailscale.app" ]] && return 0
    "${BREW_BIN:-brew}" list --cask tailscale >/dev/null 2>&1
}

install() {
    if [[ -d /Applications/Tailscale.app || -d "$HOME/Applications/Tailscale.app" ]]; then
        _tailscale_cli_load && mesh_tailscale_cli
        return $?
    fi
    if ! "${BREW_BIN:-brew}" install --cask tailscale; then
        echo "[tailscale-mac] brew install --cask tailscale failed — likely kext approval" >&2
        echo "[tailscale-mac] fix: download the .pkg from https://tailscale.com/download/macos" >&2
        echo "[tailscale-mac]      run it locally (not via SSH) to trigger System Settings approval" >&2
        echo "[tailscale-mac]      then re-run this topic; it'll detect Tailscale.app already installed" >&2
        return 1
    fi
    _tailscale_cli_load && mesh_tailscale_cli
}

verify() {
    check
}

repair() { install; }

rollback() {
    # Don't auto-uninstall — Tailscale carries state (auth, ACL, MagicDNS).
    :
}
