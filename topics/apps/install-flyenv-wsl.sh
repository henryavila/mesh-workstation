#!/usr/bin/env bash
# WSL has no in-distro FlyEnv package. Upstream publishes a Windows setup
# (FlyEnv-Setup-4.20.2.exe) and Mesh has no winget id. check/verify succeed
# only when that Windows app is already visible. install does not launch it.
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

FLYENV_WIN_SETUP="https://github.com/xpf0000/FlyEnv/releases/download/v4.20.2/FlyEnv-Setup-4.20.2.exe"

flyenv_present() {
    [[ -d /Applications/FlyEnv.app ]] && return 0
    if command -v dpkg >/dev/null 2>&1; then
        dpkg -s flyenv >/dev/null 2>&1 && return 0
    fi
    if command -v rpm >/dev/null 2>&1; then
        rpm -q flyenv >/dev/null 2>&1 && return 0
    fi
    [[ -d /opt/FlyEnv || -d /usr/lib/flyenv ]] && return 0
    local p
    for p in \
        "/mnt/c/Program Files/FlyEnv/FlyEnv.exe" \
        "/mnt/c/Program Files/FlyEnv/flyenv.exe"
    do
        [[ -e "$p" ]] && return 0
    done
    return 1
}

check() { flyenv_present; }

install() {
    if flyenv_present; then
        return 0
    fi
    info "FlyEnv on WSL is the Windows app. Mesh does not install it inside the distro."
    info "Windows setup: $FLYENV_WIN_SETUP"
    return 1
}

verify() { flyenv_present; }
repair() { install; }
uninstall() { return 0; }
