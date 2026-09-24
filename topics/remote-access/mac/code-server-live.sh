#!/usr/bin/env bash
# Live checks for an already-installed code-server.
# MESH_CODE_SERVER_LIVE unset: every subcommand exits 0 immediately and does
# not run lsof, curl, launchctl, or tailscale. MESH_CODE_SERVER_LIVE=1 runs
# the check. This file is not invoked by tests/run-all.sh except through
# hermetic PATH fakes.

set -uo pipefail

_csl_listener_pid() {
    local listeners pid port="${CODE_SERVER_PORT:-8091}"
    listeners="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$listeners" ]] || return 1
    pid="$(printf '%s\n' "$listeners" | awk -v port="$port" '
        $0 !~ /\(LISTEN\)/ { next }
        {
            if ($0 !~ ("TCP 127\\.0\\.0\\.1:" port " \\(LISTEN\\)")) bad=1
            else {
                if (pid != "" && pid != $2) bad=1
                pid=$2
                seen=1
            }
        }
        END {
            if (bad || !seen) exit 1
            print pid
        }
    ')" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$pid"
}

_csl_agent_pid() {
    local label="${CODE_SERVER_LABEL:-com.${USER}.code-server}" uid out pid
    command -v launchctl >/dev/null 2>&1 || return 1
    uid="$(id -u)"
    out="$(launchctl print "gui/${uid}/${label}" 2>/dev/null)" || return 1
    pid="$(printf '%s\n' "$out" | awk '
        /^[[:space:]]*pid = [0-9]+[[:space:]]*$/ {
            sub(/^[[:space:]]*pid = /, "")
            sub(/[[:space:]]*$/, "")
            print
            exit
        }
    ')"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$pid"
}

_csl_healthz_ok() {
    local code port="${CODE_SERVER_PORT:-8091}"
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 --noproxy '*' \
        "http://127.0.0.1:${port}/healthz" 2>/dev/null || true)"
    [[ "$code" == "200" ]]
}

_csl_serve_ok() {
    local status
    status="$(tailscale serve status --json 2>/dev/null)" || return 1
    # Reject TCP 443, a Web key ending in :443, and the same shapes inside
    # Foreground. Presence fails even when CODE_SERVER_SERVE_BEFORE already
    # had that key; a foreground session on another port does not.
    CURRENT_JSON="$status" CODE_SERVER_SERVE_BEFORE="${CODE_SERVER_SERVE_BEFORE:-}" python3 - <<'PY'
import json, os, sys

def load(raw):
    try:
        data = json.loads(raw)
    except Exception:
        raise SystemExit(1)
    if not isinstance(data, dict):
        raise SystemExit(1)
    return data

def section_keys(data, section):
    if section not in data or data[section] is None:
        return set()
    val = data[section]
    if not isinstance(val, dict):
        raise SystemExit(1)
    return {str(key) for key in val.keys()}

def web_has_443(web):
    if web is None:
        return False
    if not isinstance(web, dict):
        raise SystemExit(1)
    for key in web:
        if str(key).endswith(":443"):
            return True
    return False

def mentions_443(cfg):
    if not isinstance(cfg, dict):
        return False
    tcp = cfg.get("TCP")
    if tcp is not None and not isinstance(tcp, dict):
        raise SystemExit(1)
    if isinstance(tcp, dict) and "443" in tcp:
        return True
    return web_has_443(cfg.get("Web"))

def forbidden_443(data):
    if mentions_443(data):
        return True
    foreground = data.get("Foreground")
    if foreground is None:
        return False
    if not isinstance(foreground, dict):
        raise SystemExit(1)
    for cfg in foreground.values():
        if not isinstance(cfg, dict) or mentions_443(cfg):
            return True
    return False

current = load(os.environ.get("CURRENT_JSON", ""))
if forbidden_443(current):
    raise SystemExit(1)

before_path = os.environ.get("CODE_SERVER_SERVE_BEFORE", "")
if before_path and os.path.isfile(before_path):
    with open(before_path, "r", encoding="utf-8") as handle:
        before = load(handle.read())
    for section in ("TCP", "Web"):
        prev = section_keys(before, section)
        cur = section_keys(current, section)
        if not prev.issubset(cur):
            raise SystemExit(1)
raise SystemExit(0)
PY
}

cmd_loopback() {
    [[ "${MESH_CODE_SERVER_LIVE:-}" == "1" ]] || return 1
    local listener_pid agent_pid
    listener_pid="$(_csl_listener_pid)" || return 1
    agent_pid="$(_csl_agent_pid)" || return 1
    [[ "$listener_pid" == "$agent_pid" ]] || return 1
    _csl_healthz_ok || return 1
    _csl_serve_ok
}

main() {
    if [[ -z "${MESH_CODE_SERVER_LIVE+x}" ]]; then
        exit 0
    fi
    local cmd="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    case "$cmd" in
        loopback)
            cmd_loopback "$@"
            ;;
        *)
            printf 'unknown command: %s\n' "$cmd" >&2
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
    exit $?
fi
