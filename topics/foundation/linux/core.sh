#!/usr/bin/env bash
# foundation/base on native Linux. Apt core packages without the PHP PPA
# prerequisite (software-properties-common). Not a WSL item: no wslu.
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/lib/log.sh"

CORE_PKGS=(
    git
    curl
    wget
    ca-certificates
    gnupg
    jq
    unzip
    gettext-base
)

CORE_BINS=(
    git
    curl
    wget
    gpg
    jq
    unzip
    envsubst
)

check() {
    local p b
    for p in "${CORE_PKGS[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || return 1
    done
    for b in "${CORE_BINS[@]}"; do
        command -v "$b" >/dev/null 2>&1 || return 1
    done
    return 0
}

install() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get update
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${CORE_PKGS[@]}"
}

verify() { check; }
repair() { install; }

uninstall() {
    :
}
