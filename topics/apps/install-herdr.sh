#!/usr/bin/env bash
# herdr CLI. Upstream: https://herdr.dev/docs/install/
#   curl -fsSL https://herdr.dev/install.sh | sh
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

check() { command -v herdr >/dev/null 2>&1; }

install() {
    curl -fsSL --connect-timeout 8 --max-time 120 https://herdr.dev/install.sh | sh
}

verify() { command -v herdr >/dev/null 2>&1; }

repair() { install; }

uninstall() {
    local bin
    bin="$(command -v herdr 2>/dev/null || true)"
    case "$bin" in
        "$HOME/.local/bin/herdr") rm -f "$bin" ;;
    esac
}
