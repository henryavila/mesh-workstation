#!/usr/bin/env bash
# Public-name classifier for the code-server hostname.
# classify reads injected answers only. It never queries resolvers or HTTP.
# SYSTEM_A is printed as tailnet_probe and does not affect the exit code.
# Sourced copies define functions and do not run main.

# Sentinels are the whole answer, not one token inside an address list.
# NXDOMAIN (and a blank answer) is an empty set. TIMEOUT, SERVFAIL, and NODIG
# are dig failures and win over every address check.
#
# Rejected, not globally routable: 0/8, 10/8, 100.64/10, 127/8, 169.254/16,
# 172.16/12, 192.0.2/24, 192.168/16, 198.18/15, 198.51.100.0/24, 203.0.113.0/24,
# 224.0.0.0/4, 240.0.0.0/4 (first octet >= 240, including 255.255.255.255).
# Addresses just outside those ranges stay routable.

_csp_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_csp_parse_a() {
    local raw="$1"
    local trimmed tok noglob=0 canon="" canon_rc=0
    local -a toks=()

    trimmed="$(_csp_trim "$raw")"
    _csp_kind="empty"
    _csp_canon=""
    case "$trimmed" in
        ""|NXDOMAIN)
            _csp_kind="empty"
            return 0
            ;;
        TIMEOUT|SERVFAIL|NODIG)
            _csp_kind="failure"
            return 0
            ;;
    esac

    case $- in
        *f*) noglob=1 ;;
    esac
    set -f
    local IFS=$' \t\n'
    # shellcheck disable=SC2086 # intentional split; pathname expansion is off
    for tok in $trimmed; do
        [[ -n "$tok" ]] && toks+=("$tok")
    done
    if [[ "$noglob" -eq 0 ]]; then
        set +f
    fi

    if [[ ${#toks[@]} -eq 0 ]]; then
        _csp_kind="empty"
        return 0
    fi
    # pipefail applies only inside this substitution. A failing sort must not
    # become an empty canon and then look like a public answer. set -u stays on.
    canon="$(
        set -u -o pipefail
        printf '%s\n' "${toks[@]}" | LC_ALL=C sort -u
    )" || canon_rc=$?
    if [[ "$canon_rc" -ne 0 ]]; then
        _csp_kind="failure"
        _csp_canon=""
        return 0
    fi
    _csp_kind="addrs"
    _csp_canon="$canon"
    return 0
}

# 0 when $1 is dotted IPv4 with no leading zeros and outside the reject list.
_csp_routable() {
    local ip="$1" o1 o2 o3 o4
    local re='^(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})\.(0|[1-9][0-9]{0,2})$'

    [[ "$ip" =~ $re ]] || return 1
    o1=$((10#${BASH_REMATCH[1]}))
    o2=$((10#${BASH_REMATCH[2]}))
    o3=$((10#${BASH_REMATCH[3]}))
    o4=$((10#${BASH_REMATCH[4]}))
    if (( o1 > 255 || o2 > 255 || o3 > 255 || o4 > 255 )); then
        return 1
    fi
    if (( o1 == 0 )); then
        return 1
    fi
    if (( o1 == 10 )); then
        return 1
    fi
    if (( o1 == 100 && o2 >= 64 && o2 <= 127 )); then
        return 1
    fi
    if (( o1 == 127 )); then
        return 1
    fi
    if (( o1 == 169 && o2 == 254 )); then
        return 1
    fi
    if (( o1 == 172 && o2 >= 16 && o2 <= 31 )); then
        return 1
    fi
    if (( o1 == 192 && o2 == 0 && o3 == 2 )); then
        return 1
    fi
    if (( o1 == 192 && o2 == 168 )); then
        return 1
    fi
    if (( o1 == 198 && o2 >= 18 && o2 <= 19 )); then
        return 1
    fi
    if (( o1 == 198 && o2 == 51 && o3 == 100 )); then
        return 1
    fi
    if (( o1 == 203 && o2 == 0 && o3 == 113 )); then
        return 1
    fi
    if (( o1 >= 224 && o1 <= 239 )); then
        return 1
    fi
    if (( o1 >= 240 )); then
        return 1
    fi
    return 0
}

# Prints "bad" and/or "egress" when a token is not routable or is the egress.
_csp_addr_flags() {
    local canon="$1" egress="$2" tok bad=0 hit=0
    while IFS= read -r tok; do
        [[ -n "$tok" ]] || continue
        if ! _csp_routable "$tok"; then
            bad=1
        fi
        if [[ -n "$egress" && "$tok" == "$egress" ]]; then
            hit=1
        fi
    done <<< "$canon"
    if [[ "$bad" -eq 1 ]]; then
        printf 'bad\n'
    fi
    if [[ "$hit" -eq 1 ]]; then
        printf 'egress\n'
    fi
}

_csp_finish() {
    printf 'tailnet_probe=%s\nclass=%s\n' "${SYSTEM_A-}" "$1"
    return "$2"
}

_csp_classify_body() {
    local kind1 kind2 canon1 canon2 egress flags

    : "${SERVE_JSON-}"
    _csp_parse_a "${PUBLIC_A_1-}"
    kind1="$_csp_kind"
    canon1="$_csp_canon"
    _csp_parse_a "${PUBLIC_A_2-}"
    kind2="$_csp_kind"
    canon2="$_csp_canon"
    egress="$(_csp_trim "${HOME_EGRESS-}")"

    if [[ "$kind1" == "failure" || "$kind2" == "failure" ]]; then
        _csp_finish disagreement 3
        return $?
    fi
    if [[ "$kind1" == "empty" && "$kind2" == "empty" ]]; then
        _csp_finish unpublished 2
        return $?
    fi
    if [[ "$kind1" == "empty" || "$kind2" == "empty" ]]; then
        _csp_finish disagreement 3
        return $?
    fi

    # Compare sets before routability. Unequal non-empty answers disagree even
    # when a token is rejected, non-IPv4, or the egress address.
    if [[ "$canon1" != "$canon2" ]]; then
        _csp_finish disagreement 3
        return $?
    fi
    flags="$(_csp_addr_flags "$canon1" "$egress")"
    case "$flags" in
        *bad*|*egress*)
            _csp_finish unpublished 2
            return $?
            ;;
    esac
    _csp_finish public-funnel 0
}

classify_public_name() {
    _csp_classify_body
    local rc=$?
    unset _csp_kind _csp_canon
    return "$rc"
}

# Prints funnel=yes/no. Exit 0 only for our raw TCP/443 funnel stanza.
# A foreground config that names port 443 (TCP["443"] or a Web key ending
# in :443) replaces the top-level object. More than one such config conflicts.
serve_json_is_our_funnel() {
    local dns json result py_rc
    dns="${CODE_SERVER_PUBLIC_DNS_NAME:-mac-mini-m4-de-henry.bream-goldeye.ts.net}"
    json="${SERVE_JSON-}"
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'funnel=no\n'
        return 1
    fi
    py_rc=0
    result="$(
        SERVE_JSON="$json" CODE_SERVER_PUBLIC_DNS_NAME="$dns" python3 - <<'PY'
import json
import os

def _web_has_443(web):
    if not isinstance(web, dict):
        return False
    for key in web:
        if isinstance(key, str) and key.endswith(":443"):
            return True
    return False

def _mentions_443(cfg):
    if not isinstance(cfg, dict):
        return False
    tcp = cfg.get("TCP")
    if isinstance(tcp, dict) and "443" in tcp:
        return True
    return _web_has_443(cfg.get("Web"))

def _effective_443(data):
    fg = data.get("Foreground")
    if fg is None:
        return data
    if not isinstance(fg, dict):
        return None
    hits = [cfg for cfg in fg.values() if _mentions_443(cfg)]
    if len(hits) > 1:
        return None
    if len(hits) == 1:
        return hits[0]
    return data

def _is_our_funnel(data, name):
    if not isinstance(data, dict):
        return False
    tcp = data.get("TCP")
    if not isinstance(tcp, dict):
        return False
    port = tcp.get("443")
    if not isinstance(port, dict):
        return False
    if port.get("TCPForward") != "127.0.0.1:8092":
        return False
    if "TerminateTLS" in port and port.get("TerminateTLS") != "":
        return False
    if "HTTPS" in port:
        return False
    if "ProxyProtocol" in port:
        return False
    allow = data.get("AllowFunnel")
    if not isinstance(allow, dict):
        return False
    if allow.get(name + ":443") is not True:
        return False
    web = data.get("Web")
    if web is None:
        return True
    if not isinstance(web, dict):
        return False
    if _web_has_443(web):
        return False
    return True

def main():
    raw = os.environ.get("SERVE_JSON", "")
    name = os.environ.get("CODE_SERVER_PUBLIC_DNS_NAME", "")
    try:
        data = json.loads(raw)
    except Exception:
        return False
    if not isinstance(data, dict):
        return False
    effective = _effective_443(data)
    if effective is None:
        return False
    return _is_our_funnel(effective, name)

print("yes" if main() else "no")
PY
    )" || py_rc=$?
    if [[ "$py_rc" -ne 0 || "$result" != "yes" ]]; then
        printf 'funnel=no\n'
        return 1
    fi
    printf 'funnel=yes\n'
    return 0
}

# Separate arguments only, in this order:
#   tailscale funnel --bg --yes --tcp=443 tcp://127.0.0.1:8092
# A single joined string is rejected. Any argument containing
# --tls-terminated-tcp is rejected. This does not exec tailscale.
funnel_argv_is_allowed() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            *--tls-terminated-tcp*) return 1 ;;
        esac
    done
    [[ $# -eq 6 ]] || return 1
    [[ "$1" == "tailscale" ]] || return 1
    [[ "$2" == "funnel" ]] || return 1
    [[ "$3" == "--bg" ]] || return 1
    [[ "$4" == "--yes" ]] || return 1
    [[ "$5" == "--tcp=443" ]] || return 1
    [[ "$6" == "tcp://127.0.0.1:8092" ]] || return 1
    return 0
}

# Prints snapshot=ok/lost. Exit 0 only when every top-level TCP key and every
# top-level Web key in SERVE_BEFORE is still present in SERVE_AFTER.
# A new key is not a loss. Values are not compared. Port 443 is not required
# and is not added. Foreground session ids are not compared. Missing or
# invalid JSON is a loss. This does not exec tailscale.
serve_snapshot_keeps_handlers() {
    local result py_rc
    if ! command -v python3 >/dev/null 2>&1; then
        printf 'snapshot=lost\n'
        return 1
    fi
    py_rc=0
    result="$(
        SERVE_BEFORE="${SERVE_BEFORE-}" SERVE_AFTER="${SERVE_AFTER-}" python3 - <<'PY'
import json
import os

def section_keys(node, field):
    if field not in node or node[field] is None:
        return set()
    section = node[field]
    if not isinstance(section, dict):
        return None
    keys = set()
    for key in section:
        if not isinstance(key, str):
            return None
        keys.add(key)
    return keys

def kept(before, after):
    if not isinstance(before, dict) or not isinstance(after, dict):
        return False
    for field in ("TCP", "Web"):
        old = section_keys(before, field)
        new = section_keys(after, field)
        if old is None or new is None or not old <= new:
            return False
    return True

def main():
    try:
        before = json.loads(os.environ.get("SERVE_BEFORE", ""))
        after = json.loads(os.environ.get("SERVE_AFTER", ""))
    except Exception:
        return False
    return kept(before, after)

print("ok" if main() else "lost")
PY
    )" || py_rc=$?
    if [[ "$py_rc" -ne 0 || "$result" != "ok" ]]; then
        printf 'snapshot=lost\n'
        return 1
    fi
    printf 'snapshot=ok\n'
    return 0
}

# Without --resolve this is not a public probe. Never exec curl.
public_probe() {
    local arg saw=0
    if [[ $# -gt 0 ]]; then
        for arg in "$@"; do
            case "$arg" in
                --resolve|--resolve=*) saw=1 ;;
            esac
        done
    fi
    if [[ "$saw" -eq 0 ]]; then
        printf '%s\n' 'refused: system-resolver curl is not a public probe'
        return 4
    fi
    printf '%s\n' 'public-probe: refusing live curl' >&2
    return 1
}

# Map one public-resolver dig answer onto a classifier token.
# Servers are only 1.1.1.1 and 8.8.8.8; never the system resolver.
# Argv is: dig +time=2 +tries=1 +noall +comments +answer @SERVER NAME A
_csp_dig_public() {
    local server="$1" name="$2" out rc=0 trimmed addrs
    if ! command -v dig >/dev/null 2>&1; then
        printf 'NODIG'
        return 0
    fi
    out="$(dig +time=2 +tries=1 +noall +comments +answer "@${server}" "$name" A 2>&1)" || rc=$?
    trimmed="$(_csp_trim "$out")"
    case "$trimmed" in
        NXDOMAIN|SERVFAIL|TIMEOUT|NODIG)
            printf '%s' "$trimmed"
            return 0
            ;;
    esac
    if printf '%s\n' "$out" | grep -q 'status:[[:space:]]*NXDOMAIN'; then
        printf 'NXDOMAIN'
        return 0
    fi
    if printf '%s\n' "$out" | grep -q 'status:[[:space:]]*SERVFAIL'; then
        printf 'SERVFAIL'
        return 0
    fi
    if [[ "$rc" -eq 9 ]] || printf '%s\n' "$out" | grep -Eqi 'timed out|no servers could be reached'; then
        printf 'TIMEOUT'
        return 0
    fi
    addrs="$(printf '%s\n' "$out" | awk '
        BEGIN { sep = "" }
        toupper($4) == "A" && $5 ~ /^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$/ {
            printf "%s%s", sep, $5
            sep = " "
            next
        }
        NF == 1 && $1 ~ /^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$/ {
            printf "%s%s", sep, $1
            sep = " "
        }
    ')"
    if [[ -n "$addrs" ]]; then
        printf '%s' "$addrs"
        return 0
    fi
    if [[ "$rc" -ne 0 ]]; then
        printf 'TIMEOUT'
        return 0
    fi
    printf 'SERVFAIL'
}

_csp_probe_unpublished() {
    local name a1 a2 out rc=0
    name="${CODE_SERVER_PUBLIC_DNS_NAME:-mac-mini-m4-de-henry.bream-goldeye.ts.net}"
    a1="$(_csp_dig_public 1.1.1.1 "$name")"
    a2="$(_csp_dig_public 8.8.8.8 "$name")"
    out="$(
        PUBLIC_A_1="$a1" \
            PUBLIC_A_2="$a2" \
            classify_public_name
    )" || rc=$?
    printf '%s\n' "$out"
    if [[ "$rc" -eq 2 ]] && printf '%s\n' "$out" | grep -qx 'class=unpublished'; then
        return 0
    fi
    return 1
}

# MESH_CODE_SERVER_LIVE unset: exit 0 immediately. Do not exec dig or curl.
probe() {
    if [[ -z "${MESH_CODE_SERVER_LIVE+x}" ]]; then
        return 0
    fi
    local expect=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --expect)
                if [[ $# -lt 2 ]]; then
                    printf 'probe: --expect requires a value\n' >&2
                    return 1
                fi
                expect="$2"
                shift 2
                ;;
            --expect=*)
                expect="${1#*=}"
                shift
                ;;
            *)
                printf 'probe: unknown argument: %s\n' "$1" >&2
                return 1
                ;;
        esac
    done
    if [[ "$expect" != "unpublished" ]]; then
        printf 'probe: only --expect unpublished is supported\n' >&2
        return 1
    fi
    if [[ "${MESH_CODE_SERVER_LIVE}" != "1" ]]; then
        printf 'probe: refusing live DNS query\n' >&2
        return 1
    fi
    _csp_probe_unpublished
}

main() {
    local cmd="${1:-classify}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    case "$cmd" in
        classify)
            classify_public_name
            ;;
        public-probe)
            public_probe "$@"
            ;;
        funnel-check)
            serve_json_is_our_funnel
            ;;
        funnel-argv)
            if funnel_argv_is_allowed "$@"; then
                return 0
            fi
            printf 'funnel-argv=rejected\n'
            return 1
            ;;
        snapshot-check)
            serve_snapshot_keeps_handlers
            ;;
        probe)
            probe "$@"
            ;;
        *)
            printf 'unknown command: %s\n' "$cmd" >&2
            return 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    main "$@"
    exit $?
fi
