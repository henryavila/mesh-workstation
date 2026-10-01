#!/usr/bin/env bash
# Custom installer: link Yazi default config (first-writer-wins).
# Identity bookmarks/openers win on conflict — that topic runs AFTER this one.

_yazi_cfg_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _yazi_cfg_lib="${MESH_WORKSTATION_DIR}/scripts/lib"
else
    _yazi_cfg_lib="$(cd "$_yazi_cfg_here/../.." && pwd)/scripts/lib"
fi
# shellcheck source=/dev/null
. "$_yazi_cfg_lib/topic-configs.sh"

_src_yazi() { printf '%s/configs/yazi/yazi.toml\n' "$_yazi_cfg_here"; }
_src_theme() { printf '%s/configs/yazi/theme.toml\n' "$_yazi_cfg_here"; }

check() {
    local dst
    dst="$HOME/.config/yazi/yazi.toml"
    [[ -e "$dst" ]] || [[ -L "$dst" ]] || return 1
    dst="$HOME/.config/yazi/theme.toml"
    [[ -e "$dst" ]] || [[ -L "$dst" ]] || return 1
    return 0
}

install() {
    link_default_config "$(_src_yazi)" "$HOME/.config/yazi/yazi.toml"
    link_default_config "$(_src_theme)" "$HOME/.config/yazi/theme.toml"
}

verify() { check; }
repair() { install; }

rollback() {
    local src dst
    src="$(_src_yazi)"
    dst="$HOME/.config/yazi/yazi.toml"
    if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
        rm -f "$dst"
    fi
    src="$(_src_theme)"
    dst="$HOME/.config/yazi/theme.toml"
    if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
        rm -f "$dst"
    fi
}
