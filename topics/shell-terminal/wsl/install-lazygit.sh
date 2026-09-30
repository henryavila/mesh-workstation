#!/usr/bin/env bash
_lazygit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _lazygit_ws="${MESH_WORKSTATION_DIR}"
else
    _lazygit_ws="$(cd "$_lazygit_here/../../.." && pwd)"
fi
# shellcheck source=/dev/null
. "$_lazygit_ws/scripts/lib/github-api.sh"
check() { command -v lazygit >/dev/null 2>&1; }

install() {
    local ver tmp
    ver="$(gh_latest_tag jesseduffield/lazygit | sed 's/^v//')"
    tmp="$(mktemp -d)"
    curl -fsSL --connect-timeout 8 --max-time 45 \
        -o "$tmp/lg.tgz" \
        "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${ver}_Linux_x86_64.tar.gz"
    tar -C "$tmp" -xzf "$tmp/lg.tgz" lazygit
    # shellcheck disable=SC2033  # coreutils install, not the engine install() fn
    sudo install -m 0755 "$tmp/lazygit" /usr/local/bin/lazygit
    rm -rf "$tmp"
}

verify()  { check; }
repair() { install; }

rollback() { [[ -x /usr/local/bin/lazygit ]] && sudo rm -f /usr/local/bin/lazygit; }
