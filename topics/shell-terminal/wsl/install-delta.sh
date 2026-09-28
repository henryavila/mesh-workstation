#!/usr/bin/env bash
_delta_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _delta_ws="${MESH_WORKSTATION_DIR}"
else
    _delta_ws="$(cd "$_delta_here/../../.." && pwd)"
fi
# shellcheck source=/dev/null
. "$_delta_ws/scripts/lib/github-api.sh"
check() { command -v delta >/dev/null 2>&1; }

install() {
    local ver tmp
    command -v jq >/dev/null 2>&1 || { echo '[delta] jq required' >&2; return 1; }
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    ver="$(gh_latest_tag dandavison/delta)"
    [[ -n "$ver" && "$ver" != "null" ]] || { echo '[delta] could not resolve latest release tag' >&2; return 1; }
    curl -fsSL --connect-timeout 8 --max-time 45 \
        -o "$tmp/delta.deb" \
        "https://github.com/dandavison/delta/releases/download/${ver}/git-delta_${ver}_amd64.deb"
    sudo dpkg -i "$tmp/delta.deb"
}

verify()  { check; }
repair() { install; }

rollback() {
    dpkg -s git-delta >/dev/null 2>&1 && sudo apt-get remove -y -q git-delta 2>/dev/null || true
}
