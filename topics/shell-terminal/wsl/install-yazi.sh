#!/usr/bin/env bash
# Custom WSL installer: Yazi + ya into ~/.local/bin (no sudo).
# Does not use scripts/lib/installers/github-release.sh — Yazi ships a
# platform-named zip with yazi+ya under yazi-<triple>/, not */bin/*.
_yazi_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _yazi_ws="${MESH_WORKSTATION_DIR}"
else
    _yazi_ws="$(cd "$_yazi_here/../../.." && pwd)"
fi
# shellcheck source=/dev/null
. "$_yazi_ws/scripts/lib/github-api.sh"

check() { command -v yazi >/dev/null 2>&1 && command -v ya >/dev/null 2>&1; }

_yazi_arch() {
    case "${UNAME_M:-$(uname -m)}" in
        x86_64|amd64) printf 'x86_64\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;;
        *) return 1 ;;
    esac
}

install() {
    local ver arch tmp asset url bin
    ver="$(gh_latest_tag sxyazi/yazi)" || return 1
    arch="$(_yazi_arch)" || return 1
    asset="yazi-${arch}-unknown-linux-gnu.zip"
    tmp="$(mktemp -d)"
    url="https://github.com/sxyazi/yazi/releases/download/${ver}/${asset}"
    curl -fsSL --connect-timeout 8 --max-time 45 -o "$tmp/yazi.zip" "$url" || {
        rm -rf "$tmp"
        return 1
    }
    mkdir -p "$tmp/unpack" "$HOME/.local/bin"
    unzip -qo "$tmp/yazi.zip" -d "$tmp/unpack"
    bin="$(find "$tmp/unpack" -type f -name yazi -print -quit)"
    if [[ -z "$bin" || ! -f "${bin%/*}/ya" ]]; then
        rm -rf "$tmp"
        return 1
    fi
    command install -m 0755 "$bin" "$HOME/.local/bin/yazi"
    command install -m 0755 "${bin%/*}/ya" "$HOME/.local/bin/ya"
    rm -rf "$tmp"
}

verify() { check; }
repair() { install; }
rollback() {
    rm -f "$HOME/.local/bin/yazi" "$HOME/.local/bin/ya"
}
