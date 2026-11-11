# shellcheck shell=bash
# A shared image must not receive a personal git-crypt key, GitHub login, or
# SSH key. Set MESH_SHARED_IMAGE=1, or the same line in
# ~/.config/mesh/config.env.
mesh_shared_image() {
    [ "${MESH_SHARED_IMAGE:-0}" = "1" ] && return 0
    local cfg="${HOME}/.config/mesh/config.env"
    [ -f "$cfg" ] && grep -qE '^[[:space:]]*MESH_SHARED_IMAGE=1[[:space:]]*$' "$cfg"
}
