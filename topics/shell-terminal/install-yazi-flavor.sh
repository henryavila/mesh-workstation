#!/usr/bin/env bash
# Soft-fail Catppuccin Mocha flavor fetch via `ya pkg add`.
# Theme.toml already names the flavor; CDN/offline must not fail bootstrap.

check() {
    command -v ya >/dev/null 2>&1 || return 0
    local flavor_dir="${XDG_CONFIG_HOME:-$HOME/.config}/yazi/flavors/catppuccin-mocha"
    [[ -d "$flavor_dir" ]]
}

install() {
    command -v ya >/dev/null 2>&1 || return 0
    ya pkg add yazi-rs/flavors:catppuccin-mocha || return 0
}

verify() { check; }
repair() { install; }
rollback() { return 0; }
