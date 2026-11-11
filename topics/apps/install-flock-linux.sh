#!/usr/bin/env bash
# Flock Linux package. Upstream install doc, files from release v1.0.0:
#   sudo apt install ./flockphp_<version>_amd64.deb
#   sudo dnf install ./flockphp-<version>.x86_64.rpm
# Linux server is not a Flock target; this item is for a desktop.
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

BASE="https://github.com/flock-php/flock/releases/download/v1.0.0"

_asset() {
    case "$(uname -m)" in
        x86_64|amd64)
            if command -v apt-get >/dev/null 2>&1; then
                printf '%s\n' "$BASE/flockphp_1.0.0_amd64.deb"
            else
                printf '%s\n' "$BASE/flockphp-1.0.0.x86_64.rpm"
            fi
            ;;
        aarch64|arm64)
            if command -v apt-get >/dev/null 2>&1; then
                printf '%s\n' "$BASE/flockphp_1.0.0_arm64.deb"
            else
                printf '%s\n' "$BASE/flockphp-1.0.0.aarch64.rpm"
            fi
            ;;
        *) echo "flock: unsupported arch $(uname -m)" >&2; return 1 ;;
    esac
}

check() {
    command -v flk >/dev/null 2>&1 && return 0
    if command -v dpkg >/dev/null 2>&1; then
        dpkg -s flockphp >/dev/null 2>&1 && return 0
    fi
    return 1
}

install() {
    local url tmp name
    url="$(_asset)" || return 1
    tmp="$(mktemp -d)"
    name="$(basename "$url")"
    curl -fsSL --connect-timeout 8 --max-time 180 -o "$tmp/$name" "$url"
    if [[ "$name" == *.deb ]]; then
        sudo apt-get install -y "$tmp/$name"
    else
        sudo dnf install -y "$tmp/$name"
    fi
    rm -rf "$tmp"
}

verify() { check; }
repair() { install; }

uninstall() {
    if command -v apt-get >/dev/null 2>&1 && dpkg -s flockphp >/dev/null 2>&1; then
        sudo apt-get remove -y flockphp || true
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf remove -y flockphp || true
    fi
}
