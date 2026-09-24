#!/usr/bin/env bash
# Public-name contract. Injected DNS only — no live network, no tailscale.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/remote-access/mac/code-server-public-dns.sh"
DNS_NAME="mac-mini-m4-de-henry.bream-goldeye.ts.net"
EGRESS="9.9.9.9"
PROBE="100.71.187.99"

# Fail closed before trap and before any "$TMP/..." path. A broken mktemp
# must not leave TMP empty and fall through into /bin or the rest of the suite.
csp_acquire_tmp() {
    local rc=0
    TMP="$(mktemp -d "${TMPDIR:-/tmp}/code-server-public-name.XXXXXX")" || rc=$?
    if [[ "$rc" -ne 0 || -z "${TMP:-}" || ! -d "${TMP:-}" ]]; then
        printf 'error: mktemp failed to create a temp directory\n' >&2
        exit 1
    fi
}

csp_acquire_tmp
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
expect_classify 2 unpublished NXDOMAIN NXDOMAIN "8.8.8.8" "$EGRESS" \
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

# --- Sets, dig failures, and globally routable IPv4 ---
assert_pattern_absent "$SCRIPT" '177\.55\.231\.7' \
    "classifier does not hardcode a measured public address"

expect_classify 0 public-funnel \
    "8.8.8.8 1.1.1.1 8.8.8.8" $'1.1.1.1\t8.8.8.8' \
    "$PROBE" "$EGRESS" "equal sets ignore order and duplicates"
expect_classify 3 disagreement "8.8.8.8" "1.1.1.1" \
    "$PROBE" "$EGRESS" "unequal routable sets disagree"
expect_classify 3 disagreement NXDOMAIN "8.8.8.8" \
    "$PROBE" "$EGRESS" "NXDOMAIN plus an address set disagrees"
expect_classify 3 disagreement "8.8.8.8" NXDOMAIN \
    "$PROBE" "$EGRESS" "address set plus NXDOMAIN disagrees"
expect_classify 3 disagreement NXDOMAIN "10.1.2.3" \
    "$PROBE" "$EGRESS" "NXDOMAIN plus a rejected address still disagrees"
expect_classify 3 disagreement NXDOMAIN example.com \
    "$PROBE" "$EGRESS" "NXDOMAIN plus a non-IPv4 token still disagrees"
expect_classify 2 unpublished "" "" \
    "$PROBE" "$EGRESS" "blank answers are an empty set"
expect_classify 2 unpublished $' \tNXDOMAIN\n' "NXDOMAIN" \
    "$PROBE" "$EGRESS" "padded NXDOMAIN is an empty set"
expect_classify 3 disagreement $' \tNXDOMAIN\n' "8.8.8.8" \
    "$PROBE" "$EGRESS" "padded NXDOMAIN plus an address disagrees"

for sentinel in TIMEOUT SERVFAIL NODIG; do
    expect_classify 3 disagreement "$sentinel" "8.8.8.8" \
        "$PROBE" "$EGRESS" "$sentinel beats a routable address"
    expect_classify 3 disagreement "$sentinel" NXDOMAIN \
        "$PROBE" "$EGRESS" "$sentinel beats NXDOMAIN"
    expect_classify 3 disagreement "$sentinel" "10.1.2.3" \
        "$PROBE" "$EGRESS" "$sentinel beats a rejected address"
    expect_classify 3 disagreement "  ${sentinel}  " "$sentinel" \
        "$PROBE" "$EGRESS" "padded $sentinel is a dig failure"
done

expect_classify 2 unpublished "1.1.1.1" "1.1.1.1" \
    "$PROBE" "1.1.1.1" "routable address equal to HOME_EGRESS is unpublished"
expect_classify 2 unpublished "1.1.1.1 8.8.8.8" "8.8.8.8 1.1.1.1" \
    "$PROBE" "8.8.8.8" "egress inside an equal set is unpublished"
expect_classify 3 disagreement "1.1.1.1" "8.8.8.8" \
    "$PROBE" "8.8.8.8" "unequal routable sets disagree even if one is the egress"
expect_classify 3 disagreement "10.1.2.3" "10.9.9.9" \
    "$PROBE" "$EGRESS" "unequal rejected sets disagree"
expect_classify 3 disagreement "8.8.8.8" "10.1.2.3" \
    "$PROBE" "$EGRESS" "a rejected address disagrees when sets differ"
expect_classify 3 disagreement "example.com" "8.8.8.8" \
    "$PROBE" "$EGRESS" "unequal sets disagree when a token is not IPv4"
expect_classify 2 unpublished "8.8.8.8 10.1.2.3" "10.1.2.3 8.8.8.8" \
    "$PROBE" "$EGRESS" "equal set containing a rejected address is unpublished"
expect_classify 0 public-funnel "9.9.9.9" "9.9.9.9" \
    "$PROBE" "1.1.1.1" "9.9.9.9 stays routable when it is not the egress"
expect_classify 0 public-funnel "8.8.8.8" "8.8.8.8" \
    "$PROBE" "$EGRESS" "tailnet probe does not block a matching public set" \
    "$TAILNET_JSON"
expect_classify 2 unpublished NXDOMAIN NXDOMAIN \
    "$PROBE" "$EGRESS" "funnel JSON does not promote NXDOMAIN" \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}},"AllowFunnel":{"mac-mini-m4-de-henry.bream-goldeye.ts.net:443":true}}'

bad_tokens=(
    example.com
    mac-mini.example.ts.net
    '2001:db8::1'
    '::1'
    junk
    '1.2.3.256'
    '256.1.1.1'
    '1.2.999.4'
    '1.2.3'
    '1.2.3.4.5'
    '01.2.3.4'
    '1.02.3.4'
    '1.2.3.4/32'
    '-1.2.3.4'
    '1.2.3.4.'
    nxdomain
    timeout
)
for tok in "${bad_tokens[@]}"; do
    expect_classify 2 unpublished "$tok" "$tok" \
        "$PROBE" "$EGRESS" "non-IPv4 token is unpublished: $tok"
done

rejected_addrs=(
    0.0.0.0
    0.255.255.255
    10.0.0.0
    10.255.255.255
    100.64.0.0
    100.71.187.99
    100.127.255.255
    127.0.0.0
    127.0.0.1
    127.255.255.255
    169.254.0.0
    169.254.255.255
    172.16.0.0
    172.16.5.1
    172.31.255.255
    192.0.2.0
    192.0.2.1
    192.0.2.255
    192.168.0.0
    192.168.1.1
    192.168.255.255
    198.18.0.0
    198.18.1.1
    198.19.255.255
    198.51.100.0
    198.51.100.10
    198.51.100.255
    203.0.113.0
    203.0.113.10
    203.0.113.255
    224.0.0.0
    224.0.0.1
    239.255.255.255
    240.0.0.0
    240.0.0.1
    255.255.255.254
    255.255.255.255
)
for ip in "${rejected_addrs[@]}"; do
    expect_classify 2 unpublished "$ip" "$ip" \
        "$PROBE" "$EGRESS" "rejected $ip is unpublished"
done

routable_addrs=(
    1.0.0.1
    1.1.1.1
    8.8.8.8
    9.255.255.255
    11.0.0.1
    100.63.255.255
    100.128.0.1
    126.255.255.255
    128.0.0.1
    169.253.255.255
    169.255.0.1
    172.15.255.255
    172.32.0.1
    192.0.1.255
    192.0.3.0
    192.167.255.255
    192.169.0.1
    198.17.255.255
    198.20.0.1
    198.51.99.255
    198.51.101.0
    203.0.112.255
    203.0.114.0
    223.255.255.255
)
for ip in "${routable_addrs[@]}"; do
    expect_classify 0 public-funnel "$ip" "$ip" \
        "$PROBE" "$EGRESS" "routable $ip is public-funnel"
done

mkdir -p "$TMP/bin-sort"
cat > "$TMP/bin-sort/sort" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin-sort/sort"
saved_path="$PATH"
PATH="$TMP/bin-sort:$saved_path"
sort_rc=0
sort_out="$(
    PUBLIC_A_1="8.8.8.8" \
        PUBLIC_A_2="8.8.8.8" \
        SYSTEM_A="$PROBE" \
        HOME_EGRESS="$EGRESS" \
        bash -u "$SCRIPT" classify 2>"$TMP/sort-fail.err"
)" || sort_rc=$?
PATH="$saved_path"
assert_eq "$sort_rc" "3" "sort failure is disagreement, not public-funnel"
assert_eq "$sort_out" "tailnet_probe=${PROBE}"$'\n'"class=disagreement" \
    "sort failure class is disagreement"
assert_not_contains "$sort_out" "public-funnel" \
    "sort failure does not report public-funnel"
assert_eq "$(cat "$TMP/sort-fail.err")" "" "sort failure writes no stderr"

unset_rc=0
unset_out="$(
    env -u PUBLIC_A_1 -u PUBLIC_A_2 -u SYSTEM_A -u HOME_EGRESS -u SERVE_JSON \
        bash -u "$SCRIPT" 2>"$TMP/unset.err"
)" || unset_rc=$?
assert_eq "$unset_rc" "2" "unset answers stay unpublished under set -u"
assert_eq "$unset_out" $'tailnet_probe=\nclass=unpublished' \
    "default subcommand prints an empty tailnet probe"
assert_eq "$(cat "$TMP/unset.err")" "" "unset classify writes no stderr"

same_rc=0
same_out="$(
    env -u PUBLIC_A_1 -u PUBLIC_A_2 -u SYSTEM_A -u HOME_EGRESS -u SERVE_JSON \
        bash -u "$SCRIPT" classify 2>"$TMP/unset-classify.err"
)" || same_rc=$?
assert_eq "$same_out" "$unset_out" "classify is the default subcommand"
assert_eq "$same_rc" "$unset_rc" "explicit classify matches the default exit"

cat > "$TMP/bin/dig" <<'EOF'
#!/usr/bin/env bash
printf 'ran\n' >> "${DIG_MARKER:?}"
printf '8.8.8.8\n'
EOF
chmod +x "$TMP/bin/dig"
rm -f "$TMP/dig-ran" "$TMP/curl-ran"
PATH="$TMP/bin:$PATH" DIG_MARKER="$TMP/dig-ran" dig >/dev/null
assert_file_exists "$TMP/dig-ran" "fake dig writes a marker when executed"
rm -f "$TMP/dig-ran"

net_rc=0
net_out="$(
    PATH="$TMP/bin:$PATH" \
        CURL_MARKER="$TMP/curl-ran" \
        DIG_MARKER="$TMP/dig-ran" \
        PUBLIC_A_1="8.8.8.8" \
        PUBLIC_A_2="8.8.8.8" \
        SYSTEM_A="$PROBE" \
        HOME_EGRESS="$EGRESS" \
        bash -u "$SCRIPT" classify 2>"$TMP/net.err"
)" || net_rc=$?
assert_eq "$net_rc" "0" "classify with fakes on PATH still passes a public set"
assert_eq "$net_out" "tailnet_probe=${PROBE}"$'\n'"class=public-funnel" \
    "classify stdout ignores PATH dig and curl"
if [[ -f "$TMP/dig-ran" ]]; then
    fail "classify did not execute dig"
else
    pass "classify did not execute dig"
fi
if [[ -f "$TMP/curl-ran" ]]; then
    fail "classify did not execute curl"
else
    pass "classify did not execute curl"
fi

resolve_rc=0
resolve_out="$(
    PATH="$TMP/bin:$PATH" \
        CURL_MARKER="$TMP/curl-ran" \
        bash -u "$SCRIPT" public-probe --resolve "${DNS_NAME}:443:8.8.8.8" \
        "https://${DNS_NAME}/" 2>"$TMP/resolve.err"
)" || resolve_rc=$?
assert_ne "$resolve_rc" "4" "public-probe with --resolve is not the refusal exit"
assert_ne "$resolve_out" "refused: system-resolver curl is not a public probe" \
    "public-probe with --resolve does not print the refusal"
assert_not_contains "$resolve_out" "HTTP 200" "--resolve path does not print HTTP 200"
if [[ -f "$TMP/curl-ran" ]]; then
    fail "public-probe --resolve did not execute curl"
else
    pass "public-probe --resolve did not execute curl"
fi

# --- funnel-check: only the :443 raw TCP stanza ---
allow_key="${DNS_NAME}:443"
PASS_JSON="{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\"},\"8443\":{\"HTTPS\":true}},\"AllowFunnel\":{\"${allow_key}\":true},\"Web\":{\"${DNS_NAME}:8443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8091\"}}}}}"
PASS_TLS_JSON="{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\",\"TerminateTLS\":\"\"}},\"AllowFunnel\":{\"${allow_key}\":true}}"

expect_funnel() {
    local want_rc="$1" want_line="$2" json="$3" msg="$4" name="${5-__default__}"
    local errf="$TMP/funnel.err" out rc=0
    if [[ "$name" == "__default__" ]]; then
        out="$(
            env -u CODE_SERVER_PUBLIC_DNS_NAME SERVE_JSON="$json" \
                bash -u "$SCRIPT" funnel-check 2>"$errf"
        )" || rc=$?
    else
        out="$(
            CODE_SERVER_PUBLIC_DNS_NAME="$name" SERVE_JSON="$json" \
                bash -u "$SCRIPT" funnel-check 2>"$errf"
        )" || rc=$?
    fi
    if [[ "$rc" == "$want_rc" && "$out" == "$want_line" && ! -s "$errf" ]]; then
        pass "$msg"
    else
        fail "$msg"
        printf '      exit: %s (want %s)\n      stdout: %q\n      want:   %q\n      stderr: %q\n' \
            "$rc" "$want_rc" "$out" "$want_line" "$(cat "$errf")" >&2
    fi
}

expect_funnel 0 "funnel=yes" "$PASS_JSON" \
    "TCPForward 8092 with other :8443 HTTPS is our funnel"
expect_funnel 0 "funnel=yes" "$PASS_TLS_JSON" \
    "empty TerminateTLS is our funnel"
expect_funnel 0 "funnel=yes" \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}},"AllowFunnel":{"vpn.example.ts.net:443":true}}' \
    "AllowFunnel follows CODE_SERVER_PUBLIC_DNS_NAME" "vpn.example.ts.net"
expect_funnel 1 "funnel=no" "$PASS_JSON" \
    "a different DNS name does not match the default AllowFunnel key" "vpn.example.ts.net"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\",\"HTTPS\":true}},\"AllowFunnel\":{\"${allow_key}\":true}}" \
    "HTTPS true is not our funnel"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\",\"HTTPS\":false}},\"AllowFunnel\":{\"${allow_key}\":true}}" \
    "HTTPS false is still present"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\"}},\"AllowFunnel\":{\"${allow_key}\":false}}" \
    "AllowFunnel false is not our funnel"
expect_funnel 1 "funnel=no" \
    '{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}}}' \
    "missing AllowFunnel is not our funnel"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\"}},\"AllowFunnel\":{\"other.example.ts.net:443\":true}}" \
    "AllowFunnel for another host is not ours"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\",\"ProxyProtocol\":1}},\"AllowFunnel\":{\"${allow_key}\":true}}" \
    "ProxyProtocol 1 is not our funnel"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\",\"ProxyProtocol\":2}},\"AllowFunnel\":{\"${allow_key}\":true}}" \
    "ProxyProtocol 2 is not our funnel"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\"}},\"AllowFunnel\":{\"${allow_key}\":true},\"Web\":{\"${DNS_NAME}:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8091\"}}}}}" \
    "a Web handler on :443 is not our funnel"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8091\"}},\"AllowFunnel\":{\"${allow_key}\":true}}" \
    "TCPForward to another port is not our funnel"
expect_funnel 1 "funnel=no" \
    "{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\",\"TerminateTLS\":\"example.com\"}},\"AllowFunnel\":{\"${allow_key}\":true}}" \
    "non-empty TerminateTLS is not our funnel"
expect_funnel 1 "funnel=no" "$TAILNET_JSON" "tailnet-only Serve JSON is not our funnel"
expect_funnel 1 "funnel=no" "not-json" "invalid SERVE_JSON is not our funnel"
expect_funnel 1 "funnel=no" \
    '{"TCP":{"8443":{"HTTPS":true}},"AllowFunnel":{"'"${allow_key}"'":true}}' \
    "HTTPS on another TCP port does not invent a :443 funnel"

FG_HTTPS_WINS_JSON="$(cat <<EOF
{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}},"AllowFunnel":{"${allow_key}":true},"Foreground":{"sess-a":{"TCP":{"443":{"HTTPS":true}}}}}
EOF
)"
FG_RAW_WINS_JSON="$(cat <<EOF
{"TCP":{"443":{"HTTPS":true}},"AllowFunnel":{"${allow_key}":false},"Web":{"${DNS_NAME}:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}},"Foreground":{"sess-a":{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}},"AllowFunnel":{"${allow_key}":true}}}}
EOF
)"
FG_8443_JSON="$(cat <<EOF
{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}},"AllowFunnel":{"${allow_key}":true},"Foreground":{"sess-a":{"TCP":{"8443":{"HTTPS":true}},"Web":{"${DNS_NAME}:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8091"}}}}}}}
EOF
)"
FG_CONFLICT_JSON="$(cat <<EOF
{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}},"AllowFunnel":{"${allow_key}":true},"Foreground":{"sess-a":{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}},"AllowFunnel":{"${allow_key}":true}},"sess-b":{"Web":{"${DNS_NAME}:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}}}
EOF
)"
expect_funnel 1 "funnel=no" "$FG_HTTPS_WINS_JSON" \
    "foreground HTTPS on 443 replaces a good background funnel"
expect_funnel 0 "funnel=yes" "$FG_RAW_WINS_JSON" \
    "foreground raw TCP funnel wins over a bad background stanza"
expect_funnel 0 "funnel=yes" "$FG_8443_JSON" \
    "foreground on 8443 does not replace a good background port 443"
expect_funnel 1 "funnel=no" "$FG_CONFLICT_JSON" \
    "two foreground configs that mention 443 conflict"

fn_rc=0
fn_out="$(
    env -u CODE_SERVER_PUBLIC_DNS_NAME SERVE_JSON="$PASS_JSON" \
        bash -uc 'source "$1"; serve_json_is_our_funnel' bash "$SCRIPT" 2>"$TMP/fn.err"
)" || fn_rc=$?
assert_eq "$fn_rc" "0" "sourced serve_json_is_our_funnel returns 0 for a pass"
assert_eq "$fn_out" "funnel=yes" "sourced function prints funnel=yes"
assert_eq "$(cat "$TMP/fn.err")" "" "sourced function writes no stderr"

fn_rc=0
fn_out="$(
    bash -uc 'source "$1"; unset SERVE_JSON; unset CODE_SERVER_PUBLIC_DNS_NAME; serve_json_is_our_funnel' \
        bash "$SCRIPT" 2>"$TMP/fn-unset.err"
)" || fn_rc=$?
assert_eq "$fn_rc" "1" "sourced function fails closed when SERVE_JSON is unset"
assert_eq "$fn_out" "funnel=no" "sourced function prints funnel=no when unset"
assert_eq "$(cat "$TMP/fn-unset.err")" "" "unset funnel-check writes no stderr"

src_rc=0
src_out="$(bash -uc 'source "$1"' bash "$SCRIPT" 2>"$TMP/src.err")" || src_rc=$?
assert_eq "$src_rc" "0" "sourcing the script does not run main"
assert_eq "$src_out" "" "sourcing the script prints nothing"
assert_eq "$(cat "$TMP/src.err")" "" "sourcing the script writes no stderr"
src_fns="$(bash -uc 'source "$1"; declare -F serve_json_is_our_funnel' bash "$SCRIPT")"
assert_contains "$src_fns" "serve_json_is_our_funnel" \
    "serve_json_is_our_funnel is defined when sourced"

mkdir -p "$TMP/bin-mktemp"
cat > "$TMP/bin-mktemp/mktemp" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/bin-mktemp/mktemp"
mk_rc=0
(
    trap - EXIT
    hash -r
    PATH="$TMP/bin-mktemp:$PATH"
    hash -r
    csp_acquire_tmp
) >/dev/null 2>"$TMP/mktemp-fail.err" || mk_rc=$?
assert_eq "$mk_rc" "1" "mktemp failure exits non-zero before use"
assert_contains "$(cat "$TMP/mktemp-fail.err")" "mktemp failed" \
    "mktemp failure prints an error on stderr"

# --- probe: no live flag, no dig, no curl ---
mkdir -p "$TMP/probe-bin"
cat > "$TMP/probe-bin/dig" <<'EOF'
#!/usr/bin/env bash
printf 'ran\n' >> "${DIG_MARKER:?}"
printf 'NXDOMAIN\n'
EOF
cat > "$TMP/probe-bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'ran\n' >> "${CURL_MARKER:?}"
printf '200\n'
EOF
chmod +x "$TMP/probe-bin/dig" "$TMP/probe-bin/curl"
rm -f "$TMP/probe-dig" "$TMP/probe-curl"
probe_rc=0
probe_out="$(
    env -u MESH_CODE_SERVER_LIVE \
        PATH="$TMP/probe-bin:$PATH" \
        DIG_MARKER="$TMP/probe-dig" \
        CURL_MARKER="$TMP/probe-curl" \
        bash -u "$SCRIPT" probe --expect unpublished 2>"$TMP/probe-off.err"
)" || probe_rc=$?
assert_eq "$probe_rc" "0" "probe --expect unpublished exits 0 when live mode is unset"
assert_eq "$probe_out" "" "unset probe prints nothing"
assert_eq "$(cat "$TMP/probe-off.err")" "" "unset probe writes no stderr"
if [[ -f "$TMP/probe-dig" || -f "$TMP/probe-curl" ]]; then
    fail "unset probe did not exec dig or curl"
else
    pass "unset probe did not exec dig or curl"
fi

dig_script() {
    cat > "$TMP/probe-bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${DIG_MARKER:?}"
server=""
for arg in "$@"; do
    case "$arg" in
        @1.1.1.1|@8.8.8.8) server="${arg#@}" ;;
    esac
done
if [[ -z "$server" ]]; then
    printf 'system resolver\n' >> "${DIG_MARKER:?}"
    exit 99
fi
case "$server" in
    1.1.1.1) printf '%s\n' "${DIG_1:?}" ;;
    8.8.8.8) printf '%s\n' "${DIG_2:?}" ;;
esac
exit "${DIG_RC:-0}"
EOF
    chmod +x "$TMP/probe-bin/dig"
}

run_live_probe() {
    local errf="$TMP/probe-live.err"
    rm -f "$TMP/probe-dig" "$TMP/probe-curl"
    PROBE_RC=0
    PROBE_OUT="$(
        MESH_CODE_SERVER_LIVE=1 \
            CODE_SERVER_PUBLIC_DNS_NAME="$DNS_NAME" \
            HOME_EGRESS="${PROBE_EGRESS:-$EGRESS}" \
            PATH="$TMP/probe-bin:/usr/bin:/bin" \
            DIG_MARKER="$TMP/probe-dig" \
            CURL_MARKER="$TMP/probe-curl" \
            DIG_1="$1" \
            DIG_2="$2" \
            DIG_RC="${3:-0}" \
            bash -u "$SCRIPT" probe --expect unpublished 2>"$errf"
    )" || PROBE_RC=$?
    PROBE_ERR="$(cat "$errf")"
}

dig_script
run_live_probe $';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 1' \
    $';; ->>HEADER<<- opcode: QUERY, status: NXDOMAIN, id: 2'
assert_eq "$PROBE_RC" "0" "live probe exits 0 for NXDOMAIN at both public resolvers"
assert_contains "$PROBE_OUT" "class=unpublished" "live NXDOMAIN probe prints class=unpublished"
assert_not_contains "$(cat "$TMP/probe-dig")" "system resolver" "live probe never queries the system resolver"
assert_contains "$(cat "$TMP/probe-dig")" "@1.1.1.1" "live probe queries 1.1.1.1"
assert_contains "$(cat "$TMP/probe-dig")" "@8.8.8.8" "live probe queries 8.8.8.8"
assert_contains "$(cat "$TMP/probe-dig")" "$DNS_NAME" "live probe queries the public DNS name"
if [[ -f "$TMP/probe-curl" ]]; then
    fail "live probe did not exec curl"
else
    pass "live probe did not exec curl"
fi

run_live_probe $'example.test. 60 IN A 8.8.8.8' $'example.test. 60 IN A 1.1.1.1'
assert_ne "$PROBE_RC" "0" "live probe is non-zero when resolvers disagree"
assert_contains "$PROBE_OUT" "class=disagreement" "disagreement probe prints class=disagreement"

run_live_probe $'example.test. 60 IN A 8.8.8.8' $'example.test. 30 IN A 8.8.8.8'
assert_ne "$PROBE_RC" "0" "live probe is non-zero for a public-funnel class"
assert_contains "$PROBE_OUT" "class=public-funnel" "routable answers print class=public-funnel"

run_live_probe $';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 1' \
    $';; ->>HEADER<<- opcode: QUERY, status: SERVFAIL, id: 2'
assert_ne "$PROBE_RC" "0" "SERVFAIL at both resolvers is not an unpublished probe success"

run_live_probe ';; connection timed out; no servers could be reached' \
    ';; connection timed out; no servers could be reached' 9
assert_ne "$PROBE_RC" "0" "dig timeout is not an unpublished probe success"

mkdir -p "$TMP/no-dig-bin"
rm -f "$TMP/probe-curl"
probe_rc=0
probe_out="$(
    MESH_CODE_SERVER_LIVE=1 \
        CODE_SERVER_PUBLIC_DNS_NAME="$DNS_NAME" \
        PATH="$TMP/no-dig-bin:/bin" \
        CURL_MARKER="$TMP/probe-curl" \
        /bin/bash -u "$SCRIPT" probe --expect unpublished 2>"$TMP/probe-nodig.err"
)" || probe_rc=$?
assert_ne "$probe_rc" "0" "missing dig is not an unpublished probe success"
assert_contains "$probe_out" "class=disagreement" "missing dig maps to a dig-failure token"
if [[ -f "$TMP/probe-curl" ]]; then
    fail "missing-dig probe did not exec curl"
else
    pass "missing-dig probe did not exec curl"
fi

dig_script
PROBE_EGRESS="9.9.9.9"
run_live_probe $'example.test. 60 IN A 9.9.9.9' $'example.test. 60 IN A 9.9.9.9'
assert_eq "$PROBE_RC" "0" "egress address at both resolvers is an unpublished probe success"
assert_contains "$PROBE_OUT" "class=unpublished" "egress probe prints class=unpublished"
PROBE_EGRESS="$EGRESS"

dig_before="$(wc -l < "$TMP/probe-dig" | tr -d ' ')"
probe_rc=0
probe_out="$(
    MESH_CODE_SERVER_LIVE=1 \
        PATH="$TMP/probe-bin:/usr/bin:/bin" \
        DIG_MARKER="$TMP/probe-dig" \
        bash -u "$SCRIPT" probe 2>"$TMP/probe-noexpect.err"
)" || probe_rc=$?
dig_after="$(wc -l < "$TMP/probe-dig" | tr -d ' ')"
assert_ne "$probe_rc" "0" "live probe without --expect unpublished is non-zero"
assert_eq "$dig_before" "$dig_after" "live probe without --expect unpublished does not exec dig"

summary
