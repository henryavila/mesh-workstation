#!/usr/bin/env bash
# Raw TCP funnel argv and serve-snapshot key retention.
# Injected JSON and argv only — no live network, no tailscale.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/remote-access/mac/code-server-public-dns.sh"
DNS_NAME="mac-mini-m4-de-henry.bream-goldeye.ts.net"
WEB_KEY="${DNS_NAME}:8443"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/code-server-funnel-dns.XXXXXX")" || exit 1
trap 'rm -rf "$TMP"' EXIT

assert_file_exists "$SCRIPT" "code-server-public-dns.sh exists"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NET_MARK:?}"
exit 99
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NET_MARK:?}"
exit 99
EOF
cat > "$TMP/bin/dig" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${NET_MARK:?}"
exit 99
EOF
chmod +x "$TMP/bin/tailscale" "$TMP/bin/curl" "$TMP/bin/dig"
export PATH="$TMP/bin:$PATH"
export NET_MARK="$TMP/net-mark"
rm -f "$NET_MARK"

GOOD_JSON="{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\"},\"8443\":{\"HTTPS\":true}},\"AllowFunnel\":{\"${DNS_NAME}:443\":true},\"Web\":{\"${WEB_KEY}\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8091\"}}}}}"
HTTPS_JSON="{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\",\"HTTPS\":true}},\"AllowFunnel\":{\"${DNS_NAME}:443\":true}}"
WEB_443_JSON="{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\"}},\"AllowFunnel\":{\"${DNS_NAME}:443\":true},\"Web\":{\"${DNS_NAME}:443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8091\"}}}}}"
NO_ALLOW_JSON='{"TCP":{"443":{"TCPForward":"127.0.0.1:8092"}}}'
PROXY_JSON="{\"TCP\":{\"443\":{\"TCPForward\":\"127.0.0.1:8092\",\"ProxyProtocol\":1}},\"AllowFunnel\":{\"${DNS_NAME}:443\":true}}"

# Passing snapshot keeps the tailnet Web key and does not introduce port 443.
# AFTER adds a non-443 key and changes a handler value; values are not the check.
SNAP_BEFORE="{\"TCP\":{\"8443\":{\"HTTPS\":true}},\"Web\":{\"${WEB_KEY}\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8091\"}}}}}"
SNAP_AFTER="{\"TCP\":{\"8443\":{\"HTTPS\":true},\"9443\":{\"HTTPS\":true}},\"Web\":{\"${WEB_KEY}\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8099\"}}},\"other.example.ts.net:9443\":{\"Handlers\":{\"/\":{\"Text\":\"kept\"}}}}}"
SNAP_LOST_WEB="{\"TCP\":{\"8443\":{\"HTTPS\":true}},\"Web\":{\"other.example.ts.net:9443\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8091\"}}}}}"
SNAP_LOST_TCP="{\"TCP\":{},\"Web\":{\"${WEB_KEY}\":{\"Handlers\":{\"/\":{\"Proxy\":\"http://127.0.0.1:8091\"}}}}}"

expect_funnel() {
    local want_rc="$1" want_line="$2" json="$3" msg="$4"
    local errf="$TMP/funnel.err" out rc=0
    out="$(
        env -u CODE_SERVER_PUBLIC_DNS_NAME SERVE_JSON="$json" \
            bash -u "$SCRIPT" funnel-check 2>"$errf"
    )" || rc=$?
    if [[ "$rc" == "$want_rc" && "$out" == "$want_line" && ! -s "$errf" ]]; then
        pass "$msg"
    else
        fail "$msg"
        printf '      exit: %s (want %s)\n      stdout: %q\n      want:   %q\n      stderr: %q\n' \
            "$rc" "$want_rc" "$out" "$want_line" "$(cat "$errf")" >&2
    fi
}

expect_argv() {
    local want_rc="$1" want_out="$2" msg="$3"
    shift 3
    local outf="$TMP/argv.out" errf="$TMP/argv.err" out rc=0
    : >"$outf"
    : >"$errf"
    bash -u "$SCRIPT" funnel-argv "$@" >"$outf" 2>"$errf" || rc=$?
    out="$(cat "$outf")"
    if [[ "$want_out" == "" ]]; then
        if [[ "$rc" == "$want_rc" && ! -s "$outf" && ! -s "$errf" ]]; then
            pass "$msg"
            return
        fi
    elif [[ "$rc" == "$want_rc" && "$out" == "$want_out" && ! -s "$errf" ]]; then
        # One line, no extras. cat strips the trailing newline inside $out.
        local lines
        lines="$(wc -l < "$outf" | tr -d ' ')"
        if [[ "$lines" == "1" ]]; then
            pass "$msg"
            return
        fi
    fi
    fail "$msg"
    printf '      exit: %s (want %s)\n      stdout: %q\n      want:   %q\n      stderr: %q\n' \
        "$rc" "$want_rc" "$out" "$want_out" "$(cat "$errf")" >&2
}

expect_snapshot() {
    local want_rc="$1" want_line="$2" before="$3" after="$4" msg="$5"
    local errf="$TMP/snap.err" out rc=0
    out="$(
        SERVE_BEFORE="$before" SERVE_AFTER="$after" \
            bash -u "$SCRIPT" snapshot-check 2>"$errf"
    )" || rc=$?
    if [[ "$rc" == "$want_rc" && "$out" == "$want_line" && ! -s "$errf" ]]; then
        pass "$msg"
    else
        fail "$msg"
        printf '      exit: %s (want %s)\n      stdout: %q\n      want:   %q\n      stderr: %q\n' \
            "$rc" "$want_rc" "$out" "$want_line" "$(cat "$errf")" >&2
    fi
}

# --- funnel-check: good raw TCP, and the rejects that are not our funnel ---
expect_funnel 0 "funnel=yes" "$GOOD_JSON" \
    "good raw TCP JSON is our funnel"
expect_funnel 1 "funnel=no" "$HTTPS_JSON" \
    "HTTPS true is not our funnel"
expect_funnel 1 "funnel=no" "$WEB_443_JSON" \
    "a Web handler on :443 is not our funnel"
expect_funnel 1 "funnel=no" "(Funnel on)" \
    "(Funnel on) text alone is not JSON and is not our funnel"
expect_funnel 1 "funnel=no" "$NO_ALLOW_JSON" \
    "missing AllowFunnel is not our funnel"
expect_funnel 1 "funnel=no" "$PROXY_JSON" \
    "ProxyProtocol 1 is not our funnel"

# --- funnel-argv: separate arguments, exact raw TCP order only ---
expect_argv 0 "" "exact raw TCP argv is allowed" \
    tailscale funnel --bg --yes --tcp=443 tcp://127.0.0.1:8092
expect_argv 1 "funnel-argv=rejected" "tailscale funnel 8091 is rejected" \
    tailscale funnel 8091
expect_argv 1 "funnel-argv=rejected" "tailscale funnel --bg --yes 8091 is rejected" \
    tailscale funnel --bg --yes 8091
expect_argv 1 "funnel-argv=rejected" "--tls-terminated-tcp appended is rejected" \
    tailscale funnel --bg --yes --tcp=443 tcp://127.0.0.1:8092 --tls-terminated-tcp
expect_argv 1 "funnel-argv=rejected" "--tls-terminated-tcp=443 is rejected" \
    tailscale funnel --tls-terminated-tcp=443 tcp://127.0.0.1:8092
expect_argv 1 "funnel-argv=rejected" "a single joined string is not the allowlisted form" \
    "tailscale funnel --bg --yes --tcp=443 tcp://127.0.0.1:8092"
expect_argv 1 "funnel-argv=rejected" "raw TCP pointed at 8091 is rejected" \
    tailscale funnel --bg --yes --tcp=443 tcp://127.0.0.1:8091
expect_argv 1 "funnel-argv=rejected" "flag order other than --bg --yes is rejected" \
    tailscale funnel --yes --bg --tcp=443 tcp://127.0.0.1:8092

# --- snapshot-check: disappearance fails; a new non-443 key does not ---
assert_not_contains "$SNAP_BEFORE" '"443"' "passing snapshot before has no TCP 443 key"
assert_not_contains "$SNAP_AFTER" '"443"' "passing snapshot after has no TCP 443 key"
assert_not_contains "$SNAP_BEFORE" ':443' "passing snapshot before has no :443 web key"
assert_not_contains "$SNAP_AFTER" ':443' "passing snapshot after has no :443 web key"
expect_snapshot 0 "snapshot=ok" "$SNAP_BEFORE" "$SNAP_AFTER" \
    "kept TCP and Web keys pass even when a new non-443 key appears"
expect_snapshot 1 "snapshot=lost" "$SNAP_BEFORE" "$SNAP_LOST_WEB" \
    "losing ${WEB_KEY} is a snapshot loss"
expect_snapshot 1 "snapshot=lost" "$SNAP_BEFORE" "$SNAP_LOST_TCP" \
    "losing TCP key 8443 is a snapshot loss"

unset_rc=0
unset_out="$(
    env -u SERVE_BEFORE -u SERVE_AFTER bash -u "$SCRIPT" snapshot-check 2>"$TMP/snap-unset.err"
)" || unset_rc=$?
assert_eq "$unset_rc" "1" "unset snapshot JSON fails closed"
assert_eq "$unset_out" "snapshot=lost" "unset snapshot JSON prints snapshot=lost"
assert_eq "$(cat "$TMP/snap-unset.err")" "" "unset snapshot JSON writes no stderr"

src_rc=0
src_out="$(
    bash -uc 'source "$1"; funnel_argv_is_allowed tailscale funnel --bg --yes --tcp=443 tcp://127.0.0.1:8092' \
        bash "$SCRIPT" 2>"$TMP/src-argv.err"
)" || src_rc=$?
assert_eq "$src_rc" "0" "sourced funnel_argv_is_allowed returns 0 for the exact argv"
assert_eq "$src_out" "" "sourced allowlist prints nothing on success"
assert_eq "$(cat "$TMP/src-argv.err")" "" "sourced allowlist writes no stderr"

src_rc=0
src_out="$(
    bash -uc 'source "$1"; funnel_argv_is_allowed tailscale funnel 8091' \
        bash "$SCRIPT" 2>"$TMP/src-argv-no.err"
)" || src_rc=$?
assert_ne "$src_rc" "0" "sourced funnel_argv_is_allowed rejects tailscale funnel 8091"
assert_eq "$src_out" "" "sourced rejection prints nothing; the subcommand prints the token"
assert_eq "$(cat "$TMP/src-argv-no.err")" "" "sourced rejection writes no stderr"

src_rc=0
src_out="$(
    SERVE_BEFORE="$SNAP_BEFORE" SERVE_AFTER="$SNAP_AFTER" \
        bash -uc 'source "$1"; serve_snapshot_keeps_handlers' \
        bash "$SCRIPT" 2>"$TMP/src-snap.err"
)" || src_rc=$?
assert_eq "$src_rc" "0" "sourced serve_snapshot_keeps_handlers returns 0 when keys remain"
assert_eq "$src_out" "snapshot=ok" "sourced snapshot prints snapshot=ok"
assert_eq "$(cat "$TMP/src-snap.err")" "" "sourced snapshot writes no stderr"

if [[ -f "$NET_MARK" ]]; then
    fail "funnel checks executed tailscale, dig, or curl"
else
    pass "funnel checks did not execute tailscale, dig, or curl"
fi

summary
