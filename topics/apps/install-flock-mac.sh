#!/usr/bin/env bash
# Flock on macOS. Upstream: open Flock-<version>-macOS.dmg and drag Flock
# to Applications. Asset from the v1.0.0 release in the F0 evidence block.
# shellcheck shell=bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"

URL="https://github.com/flock-php/flock/releases/download/v1.0.0/Flock-1.0.0-macOS.dmg"
APP="/Applications/Flock.app"

check() { [[ -d "$APP" ]]; }

install() {
    local tmp mount
    tmp="$(mktemp -d)"
    curl -fsSL --connect-timeout 8 --max-time 180 -o "$tmp/Flock.dmg" "$URL"
    mount="$(hdiutil attach "$tmp/Flock.dmg" -nobrowse | awk '/\/Volumes\// { print $NF; exit }')"
    [[ -n "$mount" && -d "$mount/Flock.app" ]] || { echo "flock: Flock.app not in the dmg" >&2; return 1; }
    local dir="$APP"
    sudo rm -rf "$dir"
    sudo cp -R "$mount/Flock.app" /Applications/
    hdiutil detach "$mount" >/dev/null || true
    rm -rf "$tmp"
}

verify() { [[ -d "$APP" ]]; }
repair() { install; }

uninstall() {
    local dir="$APP"
    sudo rm -rf "$dir"
}
