#!/usr/bin/env bash
# Hermetic gates for the client certificate and the raw TCP publish argv.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/remote-access/mac/code-server-public-tls.sh"
DNS="mac-mini-m4-de-henry.bream-goldeye.ts.net"

assert_file_exists "$SCRIPT" "code-server-public-tls.sh exists"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/code-server-client-cert.XXXXXX")" || exit 1
[[ -n "$TMP" && -d "$TMP" ]] || exit 1
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == "x509" && "$2" == "-checkend" ]]; then
    if [[ "${OPENSSL_CHECKEND_RC:-0}" != "0" ]]; then
        exit "$OPENSSL_CHECKEND_RC"
    fi
    exit 0
fi
printf '%s\n' "$*" >> "${OPENSSL_LOG:-/dev/null}"
prev=""
for arg in "$@"; do
    case "$prev" in
        -keyout|-out)
            printf 'made\n' > "$arg"
            ;;
    esac
    prev="$arg"
done
exit 0
SH
chmod +x "$TMP/openssl"
export OPENSSL_LOG="$TMP/openssl.log"

run_preflight() {
    local json="$1"
    PRE_OUT="$(TAILSCALE_STATUS_JSON="$json" bash "$SCRIPT" preflight 2>"$TMP/pre.err")" || PRE_RC=$?
}

PRE_RC=0
run_preflight '{"Self":{"Capabilities":["https"],"CapMap":{"https":null}}}'
assert_eq "$PRE_RC" "2" "https without funnel is not a pass"
assert_eq "$PRE_OUT" "preflight=no-funnel" "missing funnel capability is named"

PRE_RC=0
run_preflight "{\"Self\":{\"Capabilities\":[\"https\",\"funnel\"],\"CapMap\":{\"https\":null,\"funnel\":null,\"https://tailscale.com/cap/funnel-ports?ports=8443\":null}}}"
assert_eq "$PRE_RC" "2" "funnel ports that omit 443 fail"
assert_eq "$PRE_OUT" "preflight=port-443-denied" "denied port 443 is named"

PRE_RC=0
run_preflight '{"Self":{"Capabilities":["https","funnel"],"CapMap":{"https":null,"funnel":null}}}'
assert_eq "$PRE_RC" "0" "https plus funnel with no ports list allows 443"
assert_eq "$PRE_OUT" "preflight=ok" "preflight ok token"

GOOD='{"Self":{"Capabilities":["https","funnel"],"CapMap":{"https":null,"funnel":null}}}'
OURS='{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}},"AllowFunnel":{"'"$DNS"':443":true}}'
ALIEN='{"TCP":{"443":{"HTTPS":true}},"Web":{"'"$DNS"':443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3002"}}}}}'

PUB_RC=0
PUB_OUT="$(
    TAILSCALE_STATUS_JSON="$GOOD" \
    CODE_SERVER_LOCAL_MTLS=ok \
    SERVE_JSON='{}' \
    bash "$SCRIPT" publish-plan
)" || PUB_RC=$?
assert_eq "$PUB_RC" "0" "publish plan exits 0 when preflight and local mTLS pass"
assert_eq "$PUB_OUT" $'tailscale\nfunnel\n--bg\n--yes\n--tcp=443\ntcp://127.0.0.1:8092' \
    "publish plan is the raw TCP argv"

PUB_RC=0
PUB_OUT="$(
    TAILSCALE_STATUS_JSON='{"Self":{"Capabilities":["https"]}}' \
    CODE_SERVER_LOCAL_MTLS=ok \
    SERVE_JSON='{}' \
    bash "$SCRIPT" publish-plan
)" || PUB_RC=$?
assert_eq "$PUB_RC" "2" "publish plan refuses without funnel"
assert_eq "$PUB_OUT" "skip:no-funnel" "refused publish does not print an argv"

PUB_RC=0
PUB_OUT="$(
    TAILSCALE_STATUS_JSON="$GOOD" \
    CODE_SERVER_LOCAL_MTLS= \
    SERVE_JSON='{}' \
    bash "$SCRIPT" publish-plan
)" || PUB_RC=$?
assert_eq "$PUB_RC" "2" "publish plan waits for the local certificate test"
assert_eq "$PUB_OUT" "skip:local-mtls" "local mTLS failure is named"

PUB_RC=0
PUB_OUT="$(
    TAILSCALE_STATUS_JSON="$GOOD" \
    CODE_SERVER_LOCAL_MTLS=ok \
    SERVE_JSON="$ALIEN" \
    bash "$SCRIPT" publish-plan
)" || PUB_RC=$?
assert_eq "$PUB_RC" "2" "publish plan does not take an alien :443"
assert_eq "$PUB_OUT" "skip:port-443-owned" "alien owner is named"

PUB_RC=0
PUB_OUT="$(
    TAILSCALE_STATUS_JSON="$GOOD" \
    CODE_SERVER_LOCAL_MTLS=ok \
    SERVE_JSON="$OURS" \
    bash "$SCRIPT" publish-plan
)" || PUB_RC=$?
assert_eq "$PUB_RC" "0" "an existing raw forward to 8092 is still our argv"

OFF_RC=0
OFF_OUT="$(CODE_SERVER_FUNNEL_OWNED=1 SERVE_JSON="$OURS" bash "$SCRIPT" off-plan)" || OFF_RC=$?
assert_eq "$OFF_RC" "0" "owned off plan exits 0"
assert_eq "$OFF_OUT" $'tailscale\nfunnel\n--tcp=443\ntcp://127.0.0.1:8092\noff' \
    "owned off is the single forward, not a reset"
assert_not_contains "$OFF_OUT" "reset" "off plan does not reset"

OFF_OUT="$(CODE_SERVER_FUNNEL_OWNED= SERVE_JSON="$OURS" bash "$SCRIPT" off-plan)"
assert_eq "$OFF_OUT" "skip:not-owned" "unowned install does not off"
OFF_OUT="$(CODE_SERVER_FUNNEL_OWNED=1 SERVE_JSON="$ALIEN" bash "$SCRIPT" off-plan)"
assert_eq "$OFF_OUT" "skip:alien" "alien :443 is not turned off"

# shellcheck disable=SC1090
source "$SCRIPT"
CA="$TMP/tls"
OPENSSL_LOG="$TMP/openssl.log"
: > "$OPENSSL_LOG"
CODE_SERVER_OPENSSL="$TMP/openssl" code_server_tls_ensure_ca "$CA"
assert_file_exists "$CA/ca.crt" "CA certificate is created"
assert_file_exists "$CA/ca.key" "CA key is created"
first="$(cat "$OPENSSL_LOG")"
CODE_SERVER_OPENSSL="$TMP/openssl" code_server_tls_ensure_ca "$CA"
second="$(cat "$OPENSSL_LOG")"
assert_eq "$first" "$second" "an existing CA is not regenerated"

CODE_SERVER_OPENSSL="$TMP/openssl" code_server_tls_ensure_node_cert "$CA"
assert_file_exists "$CA/node.crt" "missing node certificate is written"
before="$(cat "$OPENSSL_LOG")"
CODE_SERVER_OPENSSL="$TMP/openssl" code_server_tls_ensure_node_cert "$CA"
after="$(cat "$OPENSSL_LOG")"
assert_eq "$before" "$after" "a reusable node certificate is not rewritten"
OPENSSL_CHECKEND_RC=1 CODE_SERVER_OPENSSL="$TMP/openssl" code_server_tls_ensure_node_cert "$CA"
rewritten="$(cat "$OPENSSL_LOG")"
assert_ne "$after" "$rewritten" "an expiring node certificate is rewritten"
assert_file_exists "$CA/ca.crt" "rewriting the node certificate keeps the CA"

LEAF_RC=0
LEAF_OUT="$(CODE_SERVER_TEST_CERT= CODE_SERVER_TEST_KEY= code_server_tls_require_test_leaf)" || LEAF_RC=$?
assert_eq "$LEAF_RC" "2" "a test leaf needs both files"
assert_eq "$LEAF_OUT" "test-leaf=missing" "missing test leaf is named"
LEAF_RC=0
LEAF_OUT="$(CODE_SERVER_TEST_CERT="$CA/node.crt" CODE_SERVER_TEST_KEY="$CA/node.key" code_server_tls_require_test_leaf)" || LEAF_RC=$?
assert_eq "$LEAF_RC" "0" "both test leaf paths pass"
assert_eq "$LEAF_OUT" "test-leaf=ok" "test leaf ok token"

P12_OUT="$(CODE_SERVER_TLS_REPAIR=1 CODE_SERVER_OPENSSL="$TMP/openssl" code_server_tls_export_device "$CA" "$TMP/phone.p12")"
assert_eq "$P12_OUT" "pkcs12=skipped-repair" "repair does not export a device certificate"
assert_file_exists "$CA/ca.crt" "repair leaves the CA in place"
if [[ -e "$TMP/phone.p12" ]]; then
    fail "repair does not write a PKCS#12"
else
    pass "repair does not write a PKCS#12"
fi

summary
