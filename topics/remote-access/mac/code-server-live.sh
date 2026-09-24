#!/usr/bin/env bash
# Live checks for an already-installed code-server.
# MESH_CODE_SERVER_LIVE unset: every subcommand exits 0 immediately and does
# not run lsof, curl, launchctl, or tailscale. MESH_CODE_SERVER_LIVE=1 runs
# the check. This file is not invoked by tests/run-all.sh except through
# hermetic PATH fakes.

set -uo pipefail

_csl_listener_pid() {
    local listeners pid
    listeners="$(lsof -nP -iTCP:8091 -sTCP:LISTEN 2>/dev/null || true)"
    [[ -n "$listeners" ]] || return 1
    pid="$(printf '%s\n' "$listeners" | awk '
        $0 !~ /\(LISTEN\)/ { next }
        {
            if ($0 !~ /TCP 127\.0\.0\.1:8091 \(LISTEN\)/) bad=1
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
    local label="com.${USER}.code-server" uid out pid
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
    local code
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 2 --noproxy '*' \
        "http://127.0.0.1:8091/healthz" 2>/dev/null || true)"
    [[ "$code" == "200" ]]
}

_csl_serve_ok() {
    local status
    status="$(tailscale serve status --json 2>/dev/null)" || return 1
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

current = load(os.environ.get("CURRENT_JSON", ""))
if "443" in section_keys(current, "TCP"):
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
        if "443" in cur and "443" not in prev:
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
