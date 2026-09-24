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
# 172.16/12, 192.0.2/24, 192.168/16, 198.18/15, 224.0.0.0/4, 255.255.255.255.
# Addresses just outside those ranges stay routable. 240.0.0.0/4 is not rejected
# except for the limited broadcast above.

_csp_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

_csp_parse_a() {
    local raw="$1"
    local trimmed tok noglob=0
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
    _csp_kind="addrs"
    _csp_canon="$(printf '%s\n' "${toks[@]}" | LC_ALL=C sort -u)"
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
    if (( o1 >= 224 && o1 <= 239 )); then
        return 1
    fi
    if (( o1 == 255 && o2 == 255 && o3 == 255 && o4 == 255 )); then
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

    flags="$(_csp_addr_flags "$canon1" "$egress")$(_csp_addr_flags "$canon2" "$egress")"
    case "$flags" in
        *bad*)
            _csp_finish unpublished 2
            return $?
            ;;
    esac
    if [[ "$canon1" != "$canon2" ]]; then
        _csp_finish disagreement 3
        return $?
    fi
    case "$flags" in
        *egress*)
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

def main():
    raw = os.environ.get("SERVE_JSON", "")
    name = os.environ.get("CODE_SERVER_PUBLIC_DNS_NAME", "")
    try:
        data = json.loads(raw)
    except Exception:
        return False
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
    for key in web:
        if isinstance(key, str) and key.endswith(":443"):
            return False
    return True

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
