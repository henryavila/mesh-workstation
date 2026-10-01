#!/usr/bin/env bash
# Link the mesh Yazi herdr plugin (overlay picker). soft_fail when herdr is absent.

_yazi_plugin_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_yazi_plugin_src="$_yazi_plugin_here/configs/herdr-plugin-yazi"

check() {
    command -v herdr >/dev/null 2>&1 || return 0
    herdr plugin list --json 2>/dev/null | grep -q '"mesh.yazi"'
}

install() {
    command -v herdr >/dev/null 2>&1 || return 0
    [[ -f "$_yazi_plugin_src/herdr-plugin.toml" ]] || return 1
    herdr plugin link "$_yazi_plugin_src"
}

verify() { check; }
repair() { install; }
rollback() {
    command -v herdr >/dev/null 2>&1 || return 0
    herdr plugin unlink mesh.yazi >/dev/null 2>&1 || true
}
