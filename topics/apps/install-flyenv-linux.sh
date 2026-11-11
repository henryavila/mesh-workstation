#!/usr/bin/env bash
# FlyEnv native Linux packages from the v4.20.2 release recorded in the
# F0 evidence block. Not used for WSL.
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

BASE="https://github.com/xpf0000/FlyEnv/releases/download/v4.20.2"

_asset() {
    local arch deb rpm
    case "$(uname -m)" in
        x86_64|amd64) deb="FlyEnv-4.20.2-x64.deb"; rpm="FlyEnv-4.20.2-x64.rpm" ;;
        aarch64|arm64) deb="FlyEnv-4.20.2-arm64.deb"; rpm="FlyEnv-4.20.2-arm64.rpm" ;;
        *) echo "flyenv: unsupported arch $(uname -m)" >&2; return 1 ;;
    esac
    if command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' "$BASE/$deb"
    elif command -v dnf >/dev/null 2>&1; then
        printf '%s\n' "$BASE/$rpm"
    else
        echo "flyenv: need apt-get or dnf" >&2
        return 1
    fi
}

check() {
    if command -v dpkg >/dev/null 2>&1; then
        dpkg -s flyenv >/dev/null 2>&1 && return 0
    fi
    if command -v rpm >/dev/null 2>&1; then
        rpm -q flyenv >/dev/null 2>&1 && return 0
    fi
    [[ -d /opt/FlyEnv || -d /usr/lib/flyenv ]]
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
    if command -v apt-get >/dev/null 2>&1 && dpkg -s flyenv >/dev/null 2>&1; then
        sudo apt-get remove -y flyenv || true
    elif command -v dnf >/dev/null 2>&1; then
        sudo dnf remove -y flyenv || true
    fi
}
