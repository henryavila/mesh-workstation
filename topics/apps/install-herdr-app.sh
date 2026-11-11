#!/usr/bin/env bash
# Herdr desktop app. Upstream README:
#   curl -fsSL https://releases.herdr.dev/app/install.sh | sh
# The script puts herdr-app on PATH. It does not install the herdr CLI.
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

_app_present() {
    [[ -x "$HOME/.local/bin/herdr-app" ]] && return 0
    [[ -d "$HOME/Applications/Herdr.app" ]] && return 0
    [[ -d "${XDG_DATA_HOME:-$HOME/.local/share}/herdr-app" ]] && return 0
    return 1
}

check() { _app_present; }

install() {
    curl -fsSL --connect-timeout 8 --max-time 180 https://releases.herdr.dev/app/install.sh | sh
}

verify() { _app_present; }

repair() { install; }

uninstall() {
    local dir
    rm -f "$HOME/.local/bin/herdr-app"
    dir="$HOME/Applications/Herdr.app"
    rm -rf "$dir"
    dir="${XDG_DATA_HOME:-$HOME/.local/share}/herdr-app"
    rm -rf "$dir"
}
