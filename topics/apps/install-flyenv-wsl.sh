#!/usr/bin/env bash
# WSL: no in-distro FlyEnv install. Upstream publishes a Windows installer
# (FlyEnv-Setup-4.20.2.exe) and Mesh has no FlyEnv winget id. This item
# does not apt-install FlyEnv and does not launch the Windows setup.
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

check() { return 0; }

install() {
    info "FlyEnv on WSL is the Windows app, not an in-distro package. Mesh does not install it inside the distro."
}

verify() { return 0; }
repair() { return 0; }
uninstall() { return 0; }
