#!/usr/bin/env bash
# Public-name contract. Injected DNS only — no live network, no tailscale.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/remote-access/mac/code-server-public-dns.sh"
DNS_NAME="mac-mini-m4-de-henry.bream-goldeye.ts.net"
EGRESS="198.51.100.200"
PROBE="100.71.187.99"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/code-server-public-name.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

TAILNET_JSON='{"TCP":{"443":{"HTTPS":true}},"Web":{"mac-mini-m4-de-henry.bream-goldeye.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}'

assert_file_exists "$SCRIPT" "code-server-public-dns.sh exists"

run_classify() {
    local p1="$1" p2="$2" system_a="${3-}" egress="${4-}" serve="${5-}"
    local errf="$TMP/classify.err"
    CLASS_RC=0
    CLASS_OUT="$(
        PUBLIC_A_1="$p1" \
            PUBLIC_A_2="$p2" \
            SYSTEM_A="$system_a" \
            HOME_EGRESS="$egress" \
            SERVE_JSON="$serve" \
            bash -u "$SCRIPT" classify 2>"$errf"
    )" || CLASS_RC=$?
    CLASS_ERR="$(cat "$errf")"
}

expect_classify() {
    local want_rc="$1" want_class="$2" p1="$3" p2="$4"
    local system_a="${5-}" egress="${6-}" msg="${7:-classify}" serve="${8-}"
    local want_out
    run_classify "$p1" "$p2" "$system_a" "$egress" "$serve"
    want_out="tailnet_probe=${system_a}"$'\n'"class=${want_class}"
    if [[ "$CLASS_RC" == "$want_rc" && "$CLASS_OUT" == "$want_out" && -z "$CLASS_ERR" ]]; then
        pass "$msg"
    else
        fail "$msg"
        printf '      exit: %s (want %s)\n      stdout: %q\n      want:   %q\n      stderr: %q\n' \
            "$CLASS_RC" "$want_rc" "$CLASS_OUT" "$want_out" "$CLASS_ERR" >&2
    fi
}

# --- MagicDNS fixture: system resolver 100.x, public NXDOMAIN, tailnet Serve ---
expect_classify 2 unpublished NXDOMAIN NXDOMAIN "$PROBE" "$EGRESS" \
    "NXDOMAIN plus 100.x tailnet probe is unpublished" "$TAILNET_JSON"
expect_classify 2 unpublished NXDOMAIN NXDOMAIN "203.0.113.10" "$EGRESS" \
    "SYSTEM_A does not change the unpublished exit" "$TAILNET_JSON"

run_classify NXDOMAIN NXDOMAIN "$PROBE" "$EGRESS" "$TAILNET_JSON"
assert_eq "$CLASS_OUT" $'tailnet_probe=100.71.187.99\nclass=unpublished' \
    "MagicDNS fixture stdout is tailnet_probe plus class=unpublished"
assert_not_contains "$CLASS_OUT" "public-funnel" \
    "MagicDNS fixture does not report public-funnel"

# --- public-probe without --resolve does not run curl ---
mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'ran\n' >> "${CURL_MARKER:?}"
printf 'HTTP 200\n'
EOF
chmod +x "$TMP/bin/curl"

rm -f "$TMP/curl-ran"
PATH="$TMP/bin:$PATH" CURL_MARKER="$TMP/curl-ran" curl >/dev/null
assert_file_exists "$TMP/curl-ran" "fake curl writes a marker when executed"
rm -f "$TMP/curl-ran"

probe_rc=0
probe_out="$(
    PATH="$TMP/bin:$PATH" \
        CURL_MARKER="$TMP/curl-ran" \
        env -u PUBLIC_A_1 -u PUBLIC_A_2 -u SYSTEM_A -u HOME_EGRESS -u SERVE_JSON \
        bash -u "$SCRIPT" public-probe 2>"$TMP/probe.err"
)" || probe_rc=$?
assert_eq "$probe_rc" "4" "public-probe without --resolve exits 4"
assert_eq "$probe_out" "refused: system-resolver curl is not a public probe" \
    "public-probe refusal line is exact"
assert_eq "$(cat "$TMP/probe.err")" "" "public-probe refusal writes no stderr"
if [[ -f "$TMP/curl-ran" ]]; then
    fail "public-probe did not execute curl"
else
    pass "public-probe did not execute curl"
fi

probe_rc=0
probe_out="$(
    PATH="$TMP/bin:$PATH" \
        CURL_MARKER="$TMP/curl-ran" \
        bash -u "$SCRIPT" public-probe "https://${DNS_NAME}/" 2>"$TMP/probe-url.err"
)" || probe_rc=$?
assert_eq "$probe_rc" "4" "public-probe with a URL and no --resolve exits 4"
assert_eq "$probe_out" "refused: system-resolver curl is not a public probe" \
    "URL without --resolve is still the refusal line"
assert_not_contains "$probe_out" "HTTP 200" "refusal is not the fake curl HTTP 200"
if [[ -f "$TMP/curl-ran" ]]; then
    fail "public-probe URL form did not execute curl"
else
    pass "public-probe URL form did not execute curl"
fi

summary
