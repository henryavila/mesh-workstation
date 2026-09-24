#!/usr/bin/env bash
# Client-certificate and raw-TCP Funnel gates.
# This file does not call tailscale, brew, or openssl unless a caller asks
# ensure_* to create missing files. Publication is a printed argv, not an exec.
# Sourced copies define functions and do not run main.

_csp_tls_openssl() {
    printf '%s\n' "${CODE_SERVER_OPENSSL:-openssl}"
}

# Reads TAILSCALE_STATUS_JSON. Prints preflight=ok or preflight=<reason>.
# Exit 0 only when https, funnel, and port 443 are all allowed.
code_server_funnel_preflight() {
    local raw="${TAILSCALE_STATUS_JSON-}" result
    if [[ -z "${raw//[[:space:]]/}" ]]; then
        printf '%s\n' 'preflight=missing-status'
        return 2
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        printf '%s\n' 'preflight=no-python'
        return 2
    fi
    result="$(TAILSCALE_STATUS_JSON="$raw" python3 - <<'PY'
import json, os
raw = os.environ.get("TAILSCALE_STATUS_JSON", "")
try:
    data = json.loads(raw)
except Exception:
    print("bad-json")
    raise SystemExit(0)
self_ = data.get("Self") if isinstance(data, dict) else None
if not isinstance(self_, dict):
    self_ = data if isinstance(data, dict) else {}
caps = self_.get("Capabilities") or []
capmap = self_.get("CapMap") or {}
if not isinstance(caps, list):
    caps = []
if not isinstance(capmap, dict):
    capmap = {}
names = [str(item) for item in caps] + [str(key) for key in capmap]

def has_exact(token):
    return token in names

def ports_from_caps():
    found = False
    allowed = set()
    for name in names:
        if "funnel-ports" not in name and "ports=" not in name:
            continue
        if "funnel" not in name:
            continue
        found = True
        query = name.split("?", 1)[1] if "?" in name else ""
        for part in query.split("&"):
            if part.startswith("ports="):
                for item in part.split("=", 1)[1].split(","):
                    item = item.strip()
                    if item:
                        allowed.add(item)
    return found, allowed

if not has_exact("https"):
    print("no-https")
elif not any(name == "funnel" or name.endswith("/cap/funnel") or "/cap/funnel?" in name for name in names):
    print("no-funnel")
else:
    found, allowed = ports_from_caps()
    if found and "443" not in allowed:
        print("port-443-denied")
    elif not found:
        print("ok")
    else:
        print("ok")
PY
)"
    case "$result" in
        ok)
            printf '%s\n' 'preflight=ok'
            return 0
            ;;
        *)
            printf 'preflight=%s\n' "$result"
            return 2
            ;;
    esac
}

# Prints the only publication argv, one argument per line, or skip:<reason>.
# Does not exec. Requires preflight=ok, CODE_SERVER_LOCAL_MTLS=ok, and a
# :443 key that is absent or already our raw TCP forward.
code_server_funnel_publish_plan() {
    local preflight_line=""
    if ! preflight_line="$(code_server_funnel_preflight)"; then
        printf 'skip:%s\n' "${preflight_line#preflight=}"
        return 2
    fi
    if [[ "${CODE_SERVER_LOCAL_MTLS:-}" != "ok" ]]; then
        printf '%s\n' 'skip:local-mtls'
        return 2
    fi
    if ! code_server_port_443_is_free_or_ours; then
        printf '%s\n' 'skip:port-443-owned'
        return 2
    fi
    printf '%s\n' \
        tailscale \
        funnel \
        --bg \
        --yes \
        --tcp=443 \
        'tcp://127.0.0.1:8092'
    return 0
}

code_server_port_443_is_free_or_ours() {
    local raw="${SERVE_JSON-}"
    if [[ -z "${raw//[[:space:]]/}" || "$raw" == "{}" ]]; then
        return 0
    fi
    SERVE_JSON="$raw" python3 - <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ.get("SERVE_JSON", ""))
except Exception:
    sys.exit(1)
if not isinstance(data, dict):
    sys.exit(1)
tcp = data.get("TCP") or {}
if not isinstance(tcp, dict) or ("443" not in tcp and 443 not in tcp):
    sys.exit(0)
handler = tcp.get("443", tcp.get(443))
if not isinstance(handler, dict):
    sys.exit(1)
if handler.get("TCPForward") != "127.0.0.1:8092":
    sys.exit(1)
if "HTTPS" in handler or "HTTP" in handler or "ProxyProtocol" in handler:
    sys.exit(1)
if handler.get("TerminateTLS", "") not in ("", None):
    sys.exit(1)
sys.exit(0)
PY
}

# Prints the off argv only when this install owns the forward.
# Never prints reset. Alien :443 and unowned installs print skip.
code_server_funnel_off_plan() {
    if [[ "${CODE_SERVER_FUNNEL_OWNED:-}" != "1" ]]; then
        printf '%s\n' 'skip:not-owned'
        return 0
    fi
    if ! code_server_port_443_is_free_or_ours; then
        printf '%s\n' 'skip:alien'
        return 0
    fi
    local raw="${SERVE_JSON-}"
    if [[ -z "${raw//[[:space:]]/}" || "$raw" == "{}" ]]; then
        printf '%s\n' 'skip:absent'
        return 0
    fi
    printf '%s\n' \
        tailscale \
        funnel \
        --tcp=443 \
        'tcp://127.0.0.1:8092' \
        off
    return 0
}

code_server_tls_ensure_ca() {
    local dir="${1:-${CODE_SERVER_TLS_DIR:-}}"
    local openssl
    [[ -n "$dir" ]] || return 2
    mkdir -p "$dir"
    if [[ -s "$dir/ca.crt" && -s "$dir/ca.key" ]]; then
        return 0
    fi
    openssl="$(_csp_tls_openssl)"
    "$openssl" req -x509 -newkey rsa:2048 -nodes \
        -keyout "$dir/ca.key" -out "$dir/ca.crt" \
        -subj '/CN=code-server-client-ca' -days 825 >/dev/null 2>&1 || return 1
    chmod 0600 "$dir/ca.key" "$dir/ca.crt" 2>/dev/null || true
    return 0
}

code_server_node_cert_reusable() {
    local cert="$1" openssl
    [[ -s "$cert" ]] || return 1
    openssl="$(_csp_tls_openssl)"
    "$openssl" x509 -checkend 86400 -in "$cert" -noout >/dev/null 2>&1
}

code_server_tls_ensure_node_cert() {
    local dir="${1:-${CODE_SERVER_TLS_DIR:-}}"
    local openssl
    [[ -n "$dir" ]] || return 2
    if [[ -s "$dir/node.crt" ]] && code_server_node_cert_reusable "$dir/node.crt"; then
        return 0
    fi
    if [[ ! -s "$dir/ca.crt" || ! -s "$dir/ca.key" ]]; then
        return 2
    fi
    openssl="$(_csp_tls_openssl)"
    "$openssl" req -newkey rsa:2048 -nodes \
        -keyout "$dir/node.key" -out "$dir/node.csr" \
        -subj '/CN=code-server-node' >/dev/null 2>&1 || return 1
    "$openssl" x509 -req -in "$dir/node.csr" \
        -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -CAcreateserial \
        -out "$dir/node.crt" -days 30 >/dev/null 2>&1 || return 1
    chmod 0600 "$dir/node.key" "$dir/node.crt" 2>/dev/null || true
    return 0
}

code_server_tls_require_test_leaf() {
    if [[ -z "${CODE_SERVER_TEST_CERT:-}" || -z "${CODE_SERVER_TEST_KEY:-}" ]]; then
        printf '%s\n' 'test-leaf=missing'
        return 2
    fi
    printf '%s\n' 'test-leaf=ok'
    return 0
}

# Repair reuses the CA and does not write a new PKCS#12.
code_server_tls_export_device() {
    local dir="${1:-${CODE_SERVER_TLS_DIR:-}}" dest="${2:-}"
    if [[ "${CODE_SERVER_TLS_REPAIR:-}" == "1" ]]; then
        printf '%s\n' 'pkcs12=skipped-repair'
        return 0
    fi
    [[ -n "$dir" && -n "$dest" ]] || return 2
    if [[ ! -s "$dir/ca.crt" ]]; then
        return 2
    fi
    "$(_csp_tls_openssl)" pkcs12 -export -inkey "$dir/node.key" -in "$dir/node.crt" \
        -certfile "$dir/ca.crt" -out "$dest" -passout "pass:${CODE_SERVER_P12_PASS:-}" \
        >/dev/null 2>&1 || return 1
    chmod 0600 "$dest" 2>/dev/null || true
    printf '%s\n' 'pkcs12=written'
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -uo pipefail
    case "${1:-}" in
        preflight) code_server_funnel_preflight ;;
        publish-plan) code_server_funnel_publish_plan ;;
        off-plan) code_server_funnel_off_plan ;;
        *) printf '%s\n' 'usage: preflight|publish-plan|off-plan' >&2; exit 2 ;;
    esac
fi
