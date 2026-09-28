#!/usr/bin/env bash
# Custom installer: launch syncthing on macOS.
#
# Two paths:
#   - canonical brew prefix (/opt/homebrew or /usr/local): brew services start
#   - custom prefix (e.g. /Volumes/External/homebrew): launch-wrapper for TCC
#
# Detection ladder (any hit = "already running"):
#   1. UI listening on :8384
#   2. syncthing process under this user
#   3. brew services reports started (canonical path)
#   4. wrapper-managed launchd reports running (custom path)

_use_wrapper() {
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local|"") return 1 ;;
        *) return 0 ;;
    esac
}

_is_running() {
    curl -sf -o /dev/null --max-time 2 http://127.0.0.1:8384 2>/dev/null && return 0
    pgrep -u "$USER" -f 'syncthing' >/dev/null 2>&1 && return 0
    if ! _use_wrapper; then
        "${BREW_BIN:-brew}" services list 2>/dev/null \
            | awk '$1=="syncthing"{print $2}' | grep -qx 'started' && return 0
    else
        # Capture then bash-match — NOT `launchctl print | grep -q`: under the
        # engine's pipefail, grep -q closing the pipe early SIGPIPE-kills launchctl
        # (141) → a false "not running". See feedback_engine_pipefail_grep_q_broken_pipe (lint L21).
        local _lc; _lc="$(launchctl print "gui/$(id -u)/com.${USER}.syncthing" 2>/dev/null)"
        [[ "$_lc" =~ state[[:space:]]*=[[:space:]]*running ]] && return 0
    fi
    return 1
}

check() {
    _is_running
}

install() {
    if _use_wrapper; then
        local ws_dir
        if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
            ws_dir="${MESH_WORKSTATION_DIR}"
        else
            ws_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
        fi
        # shellcheck disable=SC1091
        . "$ws_dir/scripts/lib/launch-wrapper.sh"
        local bin="${BREW_PREFIX}/bin/syncthing"
        [[ -x "$bin" ]] || { echo "[syncthing-service-mac] $bin not executable" >&2; return 1; }
        launch_wrapper_install_extbrew \
            --svc syncthing \
            --label "com.${USER}.syncthing" \
            --brew-bin "$bin" \
            -- serve --no-browser --no-restart
    else
        "${BREW_BIN:-brew}" services start syncthing \
            || { echo "[syncthing-service-mac] brew services start failed" >&2; return 1; }
    fi
    # Wait briefly for :8384
    for _ in $(seq 1 20); do
        curl -sf -o /dev/null --max-time 1 http://127.0.0.1:8384 2>/dev/null && return 0
        sleep 1
    done
    # UI not up yet — but the service may still be coming up (cold start, slow
    # disk, pending TCC prompt). Succeed as long as it is registered/running;
    # leave authoritative pass/fail to verify(). Only fail if not running at all.
    echo "[syncthing-service-mac] launched but UI not on :8384 after 20s — inspect launchctl/brew services" >&2
    _is_running && return 0
    return 1
}

verify() {
    _is_running
}

repair() { install; }

rollback() {
    if _use_wrapper; then
        launchctl bootout "gui/$(id -u)/com.${USER}.syncthing" 2>/dev/null || true
    else
        "${BREW_BIN:-brew}" services stop syncthing 2>/dev/null || true
    fi
}
