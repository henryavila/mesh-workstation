#!/usr/bin/env bash
# Hermetic loopback checks. PATH fakes only — no live network.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/remote-access/mac/code-server-live.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/code-server-live.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
printf 'lsof %s\n' "$*" >> "${MARK:?}"
port="8091"
for arg in "$@"; do
    case "$arg" in
        -iTCP:*|iTCP:*) port="${arg#*TCP:}" ;;
    esac
done
if [[ "${LSOF_MODE:-ok}" != "ok" ]]; then
    printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
    printf 'node 999 tester 15u IPv4 0 0t0 TCP 0.0.0.0:%s (LISTEN)\n' "$port"
    exit 0
fi
printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
printf 'node %s tester 15u IPv4 0 0t0 TCP 127.0.0.1:%s (LISTEN)\n' "${LSOF_PID:-4242}" "$port"
EOF
cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >> "${MARK:?}"
if [[ "${1:-}" == "print" ]]; then
    printf 'pid = %s\n' "${AGENT_PID:-4242}"
    exit 0
fi
exit 1
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "${MARK:?}"
printf '%s' "${CURL_CODE:-200}"
EOF
cat > "$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf 'tailscale %s\n' "$*" >> "${MARK:?}"
if [[ "${1:-}" == "serve" && "${2:-}" == "status" && "${3:-}" == "--json" ]]; then
    cat "${SERVE_JSON_FILE:?}"
    exit 0
fi
exit 1
EOF
cat > "$TMP/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then
    printf '501\n'
    exit 0
fi
exit 1
EOF
chmod +x "$TMP/bin/"*
printf '%s\n' '{"Web":{"host:8443":{"Handlers":{"/":{}}}}}' > "$TMP/serve.json"

run_live() {
    local errf="$TMP/err"
    LIVE_RC=0
    LIVE_OUT="$(
        PATH="$TMP/bin:/usr/bin:/bin" \
            MARK="$TMP/mark" \
            USER="tester" \
            LSOF_PID="${1:-4242}" \
            AGENT_PID="${2:-4242}" \
            LSOF_MODE="${3:-ok}" \
            CURL_CODE="${4:-200}" \
            SERVE_JSON_FILE="${5:-$TMP/serve.json}" \
            CODE_SERVER_SERVE_BEFORE="${6:-}" \
            CODE_SERVER_PORT="${7-}" \
            CODE_SERVER_LABEL="${8-}" \
            MESH_CODE_SERVER_LIVE=1 \
            bash -u "$SCRIPT" loopback 2>"$errf"
    )" || LIVE_RC=$?
}

rm -f "$TMP/mark"
off_rc=0
off_out="$(
    env -u MESH_CODE_SERVER_LIVE \
        PATH="$TMP/bin:$PATH" \
        MARK="$TMP/mark" \
        bash -u "$SCRIPT" loopback 2>"$TMP/off.err"
)" || off_rc=$?
assert_eq "$off_rc" "0" "loopback exits 0 when live mode is unset"
assert_eq "$off_out" "" "unset loopback prints nothing"
if [[ -f "$TMP/mark" ]]; then
    fail "unset loopback did not touch lsof, curl, or tailscale"
else
    pass "unset loopback did not touch lsof, curl, or tailscale"
fi

off_rc=0
off_out="$(
    env -u MESH_CODE_SERVER_LIVE \
        PATH="$TMP/bin:$PATH" \
        MARK="$TMP/mark" \
        bash -u "$SCRIPT" anything 2>"$TMP/off-any.err"
)" || off_rc=$?
assert_eq "$off_rc" "0" "unknown subcommand exits 0 when live mode is unset"
if [[ -f "$TMP/mark" ]]; then
    fail "unset unknown subcommand did not run commands"
else
    pass "unset unknown subcommand did not run commands"
fi

run_live 4242 4242 ok 200 "$TMP/serve.json"
assert_eq "$LIVE_RC" "0" "loopback passes for our listener, healthz, and serve without 443"
assert_contains "$(cat "$TMP/mark")" "iTCP:8091" "unset CODE_SERVER_PORT probes 8091"
assert_contains "$(cat "$TMP/mark")" "127.0.0.1:8091/healthz" "unset CODE_SERVER_PORT checks healthz on 8091"
assert_contains "$(cat "$TMP/mark")" "gui/501/com.tester.code-server" "unset CODE_SERVER_LABEL uses com.\$USER.code-server"

printf '%s\n' '{"TCP":{"22":{"TCPForward":"127.0.0.1:22"}},"Web":{"other:8443":{}}}' > "$TMP/before.json"
printf '%s\n' '{"Web":{"other:8443":{}},"TCP":{"22":{"TCPForward":"127.0.0.1:22"},"8443":{"HTTPS":true}}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json" "$TMP/before.json"
assert_eq "$LIVE_RC" "0" "loopback keeps normalized snapshot TCP and Web keys and allows a non-443 addition"

printf '%s\n' '{"TCP":{"443":{"HTTPS":true}}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json" "$TMP/before.json"
assert_ne "$LIVE_RC" "0" "loopback fails when serve JSON gains TCP 443"

printf '%s\n' '{"TCP":{"8443":{"HTTPS":true}}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json" "$TMP/before.json"
assert_ne "$LIVE_RC" "0" "loopback fails when a snapshot TCP key disappears"

printf '%s\n' '{"Web":{"host:8443":{}}}' > "$TMP/serve.json"
run_live 9999 4242 ok 200 "$TMP/serve.json"
assert_ne "$LIVE_RC" "0" "loopback fails when the listener PID is not the LaunchAgent"

run_live 4242 4242 other 200 "$TMP/serve.json"
assert_ne "$LIVE_RC" "0" "loopback fails when 8091 is not bound on 127.0.0.1"

run_live 4242 4242 ok 500 "$TMP/serve.json"
assert_ne "$LIVE_RC" "0" "loopback fails when healthz is not HTTP 200"

printf '%s\n' '{"Web":{"host.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8091"}}}},"AllowFunnel":{"host.example.ts.net:443":true}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json"
assert_ne "$LIVE_RC" "0" "loopback fails when a Web key ends with :443"

printf '%s\n' '{"Web":{"host.example.ts.net:443":{}}}' > "$TMP/before.json"
printf '%s\n' '{"Web":{"host.example.ts.net:443":{}},"AllowFunnel":{"host.example.ts.net:443":true}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json" "$TMP/before.json"
assert_ne "$LIVE_RC" "0" "loopback fails when a Web :443 key is already in the snapshot"

printf '%s\n' '{"Web":{"host:8443":{}},"Foreground":{"sess":{"TCP":{"443":{"HTTPS":true}}}}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json"
assert_ne "$LIVE_RC" "0" "loopback fails when a Foreground TCP map has 443"

printf '%s\n' '{"Web":{"host:8443":{}},"Foreground":{"sess":{"TCP":{"443":{"HTTPS":true}},"Web":{"host.example.ts.net:443":{}}}}}' > "$TMP/before.json"
printf '%s\n' '{"Web":{"host:8443":{}},"Foreground":{"sess":{"TCP":{"443":{"HTTPS":true}},"Web":{"host.example.ts.net:443":{}}}}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json" "$TMP/before.json"
assert_ne "$LIVE_RC" "0" "loopback fails when Foreground :443 was already present"

printf '%s\n' '{"Web":{"host:8443":{}}}' > "$TMP/before.json"
printf '%s\n' '{"Web":{"host:8443":{}},"Foreground":{"sess":{"Web":{"host.example.ts.net:443":{"Handlers":{"/":{}}}}}}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json" "$TMP/before.json"
assert_ne "$LIVE_RC" "0" "loopback fails when a new Foreground Web key ends with :443"

printf '%s\n' '{"TCP":{"22":{"TCPForward":"127.0.0.1:22"}},"Web":{"host:8443":{}}}' > "$TMP/before.json"
printf '%s\n' '{"TCP":{"22":{"TCPForward":"127.0.0.1:22"}},"Web":{"host:8443":{}},"Foreground":{"sess":{"TCP":{"8443":{"HTTPS":true}},"Web":{"host:8443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8091"}}}}}}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json" "$TMP/before.json"
assert_eq "$LIVE_RC" "0" "foreground on another port does not fail a clean background"

rm -f "$TMP/mark"
printf '%s\n' '{"Web":{"host:8443":{"Handlers":{"/":{}}}}}' > "$TMP/serve.json"
run_live 4242 4242 ok 200 "$TMP/serve.json" "" 8099 "com.tester.custom"
assert_eq "$LIVE_RC" "0" "CODE_SERVER_PORT=8099 probes that port"
live_mark="$(cat "$TMP/mark" 2>/dev/null || true)"
assert_contains "$live_mark" "iTCP:8099" "live lsof uses CODE_SERVER_PORT"
assert_contains "$live_mark" "127.0.0.1:8099/healthz" "live healthz uses CODE_SERVER_PORT"
assert_contains "$live_mark" "gui/501/com.tester.custom" "live LaunchAgent lookup uses CODE_SERVER_LABEL"
assert_not_contains "$live_mark" "8091" "CODE_SERVER_PORT=8099 does not probe 8091"

summary
