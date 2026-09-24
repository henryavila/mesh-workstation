#!/usr/bin/env bash
# Hermetic F1 checks for the code-server installer. No live network:
# curl, npx, tailscale, lsof, and launchctl are PATH fakes.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/remote-access/mac/code-server.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/code-server-f1.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin"
cat > "$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CURL_LOG:?}"
case "$*" in
    *127.0.0.1:*/healthz*) exit 0 ;;
esac
printf 'unexpected curl\n' >> "${CURL_LOG:?}"
exit 1
EOF
cat > "$TMP/bin/npx" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${NPX_ARGV:?}"
cat > "${NPX_STDIN:?}"
touch "${NPX_MARK:?}"
printf '%s\n' '$argon2id$v=19$m=4096,t=3,p=1$dGVzdHNhbHQ$dGVzdGhhc2g'
EOF
cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LSOF_LOG:?}"
pid="${LSOF_PID:-4242}"
printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\n'
printf 'node %s tester 22u IPv4 0 0t0 TCP 127.0.0.1:8091 (LISTEN)\n' "$pid"
EOF
cat > "$TMP/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${LAUNCHCTL_LOG:?}"
if [[ "${1:-}" == "print" && -f "${LAUNCHCTL_PID_FILE:-}" ]]; then
    cat "${LAUNCHCTL_PID_FILE}"
    exit 0
fi
if [[ "${1:-}" == "print" ]]; then
    exit 1
fi
exit 0
EOF
cat > "$TMP/bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${TS_LOG:?}"
exit 99
EOF
chmod +x "$TMP/bin/"*

prepare_home() {
    local home="$1"
    mkdir -p "$home/.local/bin" "$home/.local/share" "$home/Library/LaunchAgents"
    cat > "$home/.local/bin/code-server" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
    --version) printf '4.99.0\n' ;;
    --help) printf '%s\n' '--disable-proxy' ;;
esac
exit 0
EOF
    cat > "$home/.local/bin/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$home/.local/bin/code-server" "$home/.local/bin/gh"
}

run_install() {
    local home="$1"
    shift
    # BSD env accepts -u only before name=value assignments. Keep every
    # unset first, then the optional overrides.
    local -a env_args=()
    env_args+=( -u CODE_SERVER_PORT -u CODE_SERVER_TAILSCALE_SERVE )
    env_args+=( -u BREW_PREFIX -u BREW_BIN -u MESH_IDENTITY_DIR )
    if [[ -z "${CODE_SERVER_TEST_FOLLOWUP:-}" ]]; then
        env_args+=( -u MESH_FOLLOWUP_FILE )
    fi
    if [[ -z "${CODE_SERVER_TEST_PASSWORD:-}" ]]; then
        env_args+=( -u CODE_SERVER_PASSWORD )
    fi
    if [[ -n "${CODE_SERVER_TEST_FOLLOWUP:-}" ]]; then
        env_args+=( "MESH_FOLLOWUP_FILE=${CODE_SERVER_TEST_FOLLOWUP}" )
    fi
    if [[ -n "${CODE_SERVER_TEST_PASSWORD:-}" ]]; then
        env_args+=( "CODE_SERVER_PASSWORD=${CODE_SERVER_TEST_PASSWORD}" )
    fi
    if [[ -n "${CODE_SERVER_TEST_TMPDIR:-}" ]]; then
        env_args+=( "TMPDIR=${CODE_SERVER_TEST_TMPDIR}" )
    fi
    INSTALL_RC=0
    INSTALL_OUT="$(
        HOME="$home" \
            USER="tester" \
            PATH="$TMP/bin:/usr/bin:/bin" \
            NON_INTERACTIVE=1 \
            CODE_SERVER_CHECK_UPDATES=0 \
            CODE_SERVER_LABEL="com.tester.code-server" \
            CURL_LOG="$TMP/curl.log" \
            NPX_ARGV="$TMP/npx.argv" \
            NPX_STDIN="$TMP/npx.stdin" \
            NPX_MARK="$TMP/npx.mark" \
            LSOF_LOG="$TMP/lsof.log" \
            LSOF_PID="${LSOF_PID:-4242}" \
            LAUNCHCTL_LOG="$TMP/launchctl.log" \
            LAUNCHCTL_PID_FILE="${LAUNCHCTL_PID_FILE:-$TMP/no-such-pid}" \
            TS_LOG="$TMP/ts.log" \
            env "${env_args[@]}" \
            bash -c '. "$1"; install "$@"' _ "$SCRIPT" "$@" 2>&1
    )" || INSTALL_RC=$?
}

HOME_A="$TMP/home-a"
prepare_home "$HOME_A"
rm -f "$TMP/curl.log" "$TMP/npx.argv" "$TMP/npx.stdin" "$TMP/npx.mark" "$TMP/lsof.log" "$TMP/launchctl.log" "$TMP/ts.log"
run_install "$HOME_A"
if [[ "$INSTALL_RC" -eq 0 ]]; then
    pass "install exits 0 with fakes on the default port"
else
    fail "install exits 0 with fakes on the default port (rc=$INSTALL_RC)"
    printf '%s\n' "$INSTALL_OUT" >&2
fi

cfg="$HOME_A/.config/code-server/config.yaml"
wrapper="$HOME_A/.local/bin/code-server-service"
machine="$HOME_A/.local/share/code-server/Machine/settings.json"
if [[ -f "$cfg" ]]; then
    pass "install wrote config.yaml"
else
    fail "install wrote config.yaml"
fi
assert_file_contains "$cfg" "bind-addr: 127.0.0.1:8091" "fresh config binds 127.0.0.1:8091"
assert_file_contains "$cfg" "auth: password" "fresh config requires auth password"
assert_file_contains "$cfg" "hashed-password:" "fresh config stores a hashed-password"
assert_file_contains "$cfg" "cert: false" "fresh config keeps cert false"
assert_eq "$(cat "$cfg")" "$(printf '%s\n' \
    'bind-addr: 127.0.0.1:8091' \
    'auth: password' \
    'hashed-password: $argon2id$v=19$m=4096,t=3,p=1$dGVzdHNhbHQ$dGVzdGhhc2g' \
    'cert: false')" \
    "fresh config is only the four canonical lines"
if grep -Eq '^[[:space:]]*password:' "$cfg"; then
    fail "fresh config has no plaintext password line"
else
    pass "fresh config has no plaintext password line"
fi
assert_eq "$(cat "$TMP/npx.argv" 2>/dev/null || true)" "--yes argon2-cli -e" \
    "install hashes with npx --yes argon2-cli -e"
stdin="$(cat "$TMP/npx.stdin" 2>/dev/null || true)"
if [[ ${#stdin} -eq 48 && "$stdin" != *$'\n'* ]] && ! grep -qF "$stdin" "$cfg"; then
    pass "hash stdin is the generated password with no trailing newline"
else
    fail "hash stdin is the generated password with no trailing newline"
fi

# Non-interactive fresh install must record the same plaintext that was hashed,
# and only in the final summary — not in the tee'd topic log.
mkdir -p "$TMP/gen-pw"
: > "$TMP/followup"
HOME_PW="$TMP/home-pw"
prepare_home "$HOME_PW"
rm -f "$TMP/npx.argv" "$TMP/npx.stdin" "$TMP/npx.mark"
CODE_SERVER_TEST_FOLLOWUP="$TMP/followup"
CODE_SERVER_TEST_TMPDIR="$TMP/gen-pw"
unset CODE_SERVER_TEST_PASSWORD || true
run_install "$HOME_PW"
unset CODE_SERVER_TEST_FOLLOWUP CODE_SERVER_TEST_TMPDIR || true
pw_stdin="$(cat "$TMP/npx.stdin" 2>/dev/null || true)"
pw_follow="$(cat "$TMP/followup" 2>/dev/null || true)"
if [[ "$INSTALL_RC" -eq 0 && ${#pw_stdin} -eq 48 && "$pw_follow" == *"$pw_stdin"* ]]; then
    pass "non-interactive fresh config records the plaintext that was hashed"
else
    fail "non-interactive fresh config records the plaintext that was hashed (rc=$INSTALL_RC)"
fi
assert_not_contains "$INSTALL_OUT" "$pw_stdin" "generated password is not written to the topic log"
assert_not_contains "$(cat "$HOME_PW/.config/code-server/config.yaml")" "$pw_stdin" \
    "recorded plaintext is not stored in the config"
pw_left="$(find "$TMP/gen-pw" -type f 2>/dev/null | wc -l | tr -d '[:space:]')"
assert_eq "$pw_left" "0" "generated password file is shredded or removed"

HOME_OP="$TMP/home-op"
prepare_home "$HOME_OP"
: > "$TMP/followup-op"
rm -f "$TMP/npx.stdin"
CODE_SERVER_TEST_FOLLOWUP="$TMP/followup-op"
CODE_SERVER_TEST_PASSWORD="operator-secret-value"
run_install "$HOME_OP"
unset CODE_SERVER_TEST_FOLLOWUP CODE_SERVER_TEST_PASSWORD || true
op_follow="$(cat "$TMP/followup-op" 2>/dev/null || true)"
op_stdin="$(cat "$TMP/npx.stdin" 2>/dev/null || true)"
assert_eq "$op_stdin" "operator-secret-value" "operator password is the value that was hashed"
assert_not_contains "$op_follow" "operator-secret-value" \
    "operator password is not copied into the generated-password summary"
assert_not_contains "$op_follow" "Generated code-server password" \
    "operator password does not take the generated-password summary"
assert_not_contains "$INSTALL_OUT" "operator-secret-value" \
    "operator password is not written to the topic log"
if grep -F -q -- '--disable-proxy' "$wrapper"; then
    pass "service wrapper passes --disable-proxy"
else
    fail "service wrapper passes --disable-proxy"
    printf '%s\n' "$(cat "$wrapper" 2>/dev/null || echo missing)" >&2
fi
assert_file_contains "$wrapper" "export PATH=" "service wrapper keeps the PATH preamble"
assert_file_contains "$wrapper" "NODE_EXTRA_CA_CERTS" "service wrapper keeps NODE_EXTRA_CA_CERTS"
assert_file_contains "$wrapper" "GITHUB_TOKEN" "service wrapper keeps the GITHUB_TOKEN preamble"
assert_contains "$(cat "$TMP/lsof.log" 2>/dev/null || true)" "iTCP:8091" "install checks the 8091 listener"
if [[ -f "$TMP/ts.log" ]]; then
    fail "default install did not call tailscale ($(cat "$TMP/ts.log"))"
else
    pass "default install did not call tailscale"
fi
if grep -q 'code-server.dev\|github.com' "$TMP/curl.log" 2>/dev/null; then
    fail "install curl stayed on the fake healthz path"
else
    pass "install curl stayed on the fake healthz path"
fi
assert_file_contains "$machine" "extensions.supportNodeGlobalNavigator" "machine settings enable the navigator flag"
assert_file_contains "$machine" '"remote.autoForwardPorts": false' "machine settings disable auto port forwarding"

# Byte-for-byte canonical config, then plaintext and bind migrations.
# install() defines the nested config helpers; run it once in this shell.
(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        NON_INTERACTIVE=1 \
        CODE_SERVER_CHECK_UPDATES=0 \
        CODE_SERVER_LABEL="com.tester.code-server" \
        CURL_LOG="$TMP/curl.log" \
        NPX_ARGV="$TMP/npx.argv" \
        NPX_STDIN="$TMP/npx.stdin" \
        NPX_MARK="$TMP/npx.mark" \
        LSOF_LOG="$TMP/lsof.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl.log" \
        LAUNCHCTL_PID_FILE="$TMP/no-such-pid" \
        TS_LOG="$TMP/ts.log" \
        env -u MESH_IDENTITY_DIR \
        bash -c '
            set -u
            . "$1"
            install
            canonical="$CODE_SERVER_CONFIG_FILE"
            printf "%s\n" "# keep" "bind-addr: 127.0.0.1:8091" "auth: password" "hashed-password: \$argon2id\$keep" "cert: false" > "$canonical"
            before="$(cksum "$canonical")"
            rm -f "$NPX_MARK"
            ensure_code_server_config
            after="$(cksum "$canonical")"
            [[ "$before" == "$after" ]] || { printf "bytes changed\n" >&2; exit 1; }
            [[ ! -e "$NPX_MARK" ]] || { printf "npx ran\n" >&2; exit 1; }

            printf "%s\n" "bind-addr: 0.0.0.0:8080" "auth: password" "password: \"s3cret\"" "cert: true" "proxy-domain: example" "# keep" > "$canonical"
            rm -f "$NPX_MARK" "$NPX_STDIN"
            ensure_code_server_config
            grep -q "bind-addr: 127.0.0.1:8091" "$canonical" || exit 1
            grep -q "hashed-password: \$argon2id" "$canonical" || exit 1
            grep -q "auth: password" "$canonical" || exit 1
            grep -q "proxy-domain: example" "$canonical" || exit 1
            grep -q "# keep" "$canonical" || exit 1
            grep -q "s3cret" "$canonical" && exit 1
            [[ "$(grep -Ec "^bind-addr:" "$canonical")" -eq 1 ]] || exit 1
            [[ "$(grep -Ec "^[[:space:]]*auth:" "$canonical")" -eq 1 ]] || exit 1
            [[ "$(cat "$NPX_STDIN")" == "s3cret" ]] || exit 1

            printf "%s\n" "bind-addr: 127.0.0.1:8080" "auth: password" "hashed-password: \$argon2id\$already" "cert: false" "proxy-domain: example" > "$canonical"
            rm -f "$NPX_MARK"
            ensure_code_server_config
            grep -q "hashed-password: \$argon2id\$already" "$canonical" || exit 1
            grep -q "bind-addr: 127.0.0.1:8091" "$canonical" || exit 1
            grep -q "proxy-domain: example" "$canonical" || exit 1
            grep -q "auth: password" "$canonical" || exit 1
            [[ ! -e "$NPX_MARK" ]] || exit 1

            printf "%s\n" "bind-addr: 0.0.0.0:8080" "auth: none" "hashed-password: \$argon2id\$already" "cert: false" "proxy-domain: example" > "$canonical"
            rm -f "$NPX_MARK"
            ensure_code_server_config
            grep -q "bind-addr: 127.0.0.1:8091" "$canonical" || exit 1
            grep -q "auth: password" "$canonical" || exit 1
            grep -q "auth: none" "$canonical" && exit 1
            grep -q "hashed-password: \$argon2id\$already" "$canonical" || exit 1
            grep -q "proxy-domain: example" "$canonical" || exit 1
            grep -q "cert: false" "$canonical" || exit 1
            [[ "$(grep -Ec "^[[:space:]]*auth:" "$canonical")" -eq 1 ]] || exit 1
            [[ ! -e "$NPX_MARK" ]] || exit 1
        ' _ "$SCRIPT"
) >"$TMP/migrate.out" 2>"$TMP/migrate.err"
migrate_rc=$?
if [[ "$migrate_rc" -eq 0 ]]; then
    pass "canonical config is unchanged and bad bind or plaintext is rewritten to a hash"
else
    fail "canonical config is unchanged and bad bind or plaintext is rewritten to a hash (rc=$migrate_rc)"
    cat "$TMP/migrate.err" >&2
fi

ident="$TMP/identity"
mkdir -p "$ident/code-server" "$HOME_A/.local/share/code-server/User"
rm -f "$HOME_A/.local/share/code-server/User/settings.json"
printf '{\n  "editor.fontSize": 14\n}\n' > "$ident/code-server/settings.json"
src_before="$(cksum "$ident/code-server/settings.json")"
(
    HOME="$HOME_A" \
        USER="tester" \
        MESH_IDENTITY_DIR="$ident" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        NON_INTERACTIVE=1 \
        CODE_SERVER_CHECK_UPDATES=0 \
        CODE_SERVER_LABEL="com.tester.code-server" \
        CURL_LOG="$TMP/curl.log" \
        NPX_ARGV="$TMP/npx.argv" \
        NPX_STDIN="$TMP/npx.stdin" \
        NPX_MARK="$TMP/npx.mark" \
        LSOF_LOG="$TMP/lsof.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl.log" \
        LAUNCHCTL_PID_FILE="$TMP/no-such-pid" \
        TS_LOG="$TMP/ts.log" \
        bash -c '. "$1"; install >/dev/null; deploy_user_settings_from_identity' _ "$SCRIPT" >"$TMP/deploy.out" 2>"$TMP/deploy.err"
)
deploy_rc=$?
dst="$HOME_A/.local/share/code-server/User/settings.json"
src_after="$(cksum "$ident/code-server/settings.json")"
if [[ "$deploy_rc" -eq 0 && "$src_before" == "$src_after" ]]; then
    pass "settings seed does not rewrite the identity file"
else
    fail "settings seed does not rewrite the identity file (rc=$deploy_rc)"
fi
assert_file_contains "$dst" '"remote.autoForwardPorts": false' "created user settings disable auto port forwarding"
assert_file_contains "$dst" '"editor.fontSize": 14' "created user settings keep the identity seed"
dst_before="$(cksum "$dst")"
printf '{\n  "editor.fontSize": 18\n}\n' > "$ident/code-server/settings.json"
(
    HOME="$HOME_A" \
        USER="tester" \
        MESH_IDENTITY_DIR="$ident" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        NON_INTERACTIVE=1 \
        CODE_SERVER_CHECK_UPDATES=0 \
        CODE_SERVER_LABEL="com.tester.code-server" \
        CURL_LOG="$TMP/curl.log" \
        NPX_ARGV="$TMP/npx.argv" \
        NPX_STDIN="$TMP/npx.stdin" \
        NPX_MARK="$TMP/npx.mark" \
        LSOF_LOG="$TMP/lsof.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl.log" \
        LAUNCHCTL_PID_FILE="$TMP/no-such-pid" \
        TS_LOG="$TMP/ts.log" \
        bash -c '. "$1"; install >/dev/null; deploy_user_settings_from_identity' _ "$SCRIPT" >/dev/null 2>&1
)
dst_after="$(cksum "$dst")"
assert_eq "$dst_before" "$dst_after" "existing user settings are left byte-for-byte"

printf '{\n  "extensions.supportNodeGlobalNavigator": true\n}\n' > "$machine"
(
    HOME="$HOME_A" \
        CODE_SERVER_USER_DATA_DIR="$HOME_A/.local/share/code-server" \
        PATH="/usr/bin:/bin" \
        bash -c '. "$1"; . "$2"; write_code_server_machine_settings' _ "$SCRIPT" "$WS/scripts/lib/log.sh" >/dev/null
)
assert_file_contains "$machine" '"remote.autoForwardPorts": false' \
    "machine settings merge autoForwardPorts even when the navigator flag is already true"
assert_file_contains "$machine" '"extensions.supportNodeGlobalNavigator": true' \
    "machine settings keep the navigator flag"

# verify: LaunchAgent pid must own 8091, wrapper flag, hashed config.
printf 'pid = 4242\n' > "$TMP/agent.pid"
export LAUNCHCTL_PID_FILE="$TMP/agent.pid"
export LSOF_PID=4242
verify_rc=0
verify_out="$(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_LABEL="com.tester.code-server" \
        LSOF_LOG="$TMP/lsof-verify.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl-verify.log" \
        LAUNCHCTL_PID_FILE="$TMP/agent.pid" \
        bash -c '. "$1"; verify' _ "$SCRIPT" 2>&1
)" || verify_rc=$?
if [[ "$verify_rc" -eq 0 ]]; then
    pass "verify passes when the LaunchAgent owns 8091"
else
    fail "verify passes when the LaunchAgent owns 8091 (rc=$verify_rc; $verify_out)"
fi

verify_rc=0
verify_out="$(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_LABEL="com.tester.code-server" \
        LSOF_LOG="$TMP/lsof-verify.log" \
        LSOF_PID="9999" \
        LAUNCHCTL_LOG="$TMP/launchctl-verify.log" \
        LAUNCHCTL_PID_FILE="$TMP/agent.pid" \
        bash -c '. "$1"; verify' _ "$SCRIPT" 2>&1
)" || verify_rc=$?
assert_ne "$verify_rc" "0" "verify fails when another process owns 8091"

saved_wrapper="$(cat "$wrapper")"
printf '%s\n' '#!/bin/bash' 'exec /bin/true' > "$wrapper"
verify_rc=0
verify_out="$(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_LABEL="com.tester.code-server" \
        LSOF_LOG="$TMP/lsof-verify.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl-verify.log" \
        LAUNCHCTL_PID_FILE="$TMP/agent.pid" \
        bash -c '. "$1"; verify' _ "$SCRIPT" 2>&1
)" || verify_rc=$?
assert_ne "$verify_rc" "0" "verify fails when the wrapper lacks --disable-proxy"
printf '%s\n' "$saved_wrapper" > "$wrapper"

printf '%s\n' 'bind-addr: 127.0.0.1:8091' 'auth: password' 'cert: false' > "$cfg"
verify_rc=0
verify_out="$(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_LABEL="com.tester.code-server" \
        LSOF_LOG="$TMP/lsof-verify.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl-verify.log" \
        LAUNCHCTL_PID_FILE="$TMP/agent.pid" \
        bash -c '. "$1"; verify' _ "$SCRIPT" 2>&1
)" || verify_rc=$?
assert_ne "$verify_rc" "0" "verify fails when hashed-password is missing"

printf '%s\n' 'bind-addr: 127.0.0.1:8091' 'auth: none' 'hashed-password: $argon2id$keep' 'cert: false' > "$cfg"
verify_rc=0
verify_out="$(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_LABEL="com.tester.code-server" \
        LSOF_LOG="$TMP/lsof-verify.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl-verify.log" \
        LAUNCHCTL_PID_FILE="$TMP/agent.pid" \
        bash -c '. "$1"; verify' _ "$SCRIPT" 2>&1
)" || verify_rc=$?
assert_ne "$verify_rc" "0" "verify fails when auth is none"
assert_contains "$verify_out" "auth: password" "verify names the auth: password requirement"

printf '%s\n' 'bind-addr: 127.0.0.1:8091' 'auth: password' 'auth: password' 'hashed-password: $argon2id$keep' 'cert: false' > "$cfg"
verify_rc=0
verify_out="$(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_LABEL="com.tester.code-server" \
        LSOF_LOG="$TMP/lsof-verify.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl-verify.log" \
        LAUNCHCTL_PID_FILE="$TMP/agent.pid" \
        bash -c '. "$1"; verify' _ "$SCRIPT" 2>&1
)" || verify_rc=$?
assert_ne "$verify_rc" "0" "verify fails unless there is exactly one auth: password line"

printf '%s\n' 'bind-addr: 127.0.0.1:8091' 'hashed-password: $argon2id$keep' 'cert: false' > "$cfg"
verify_rc=0
verify_out="$(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_LABEL="com.tester.code-server" \
        LSOF_LOG="$TMP/lsof-verify.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl-verify.log" \
        LAUNCHCTL_PID_FILE="$TMP/agent.pid" \
        bash -c '. "$1"; verify' _ "$SCRIPT" 2>&1
)" || verify_rc=$?
assert_ne "$verify_rc" "0" "verify fails when the auth line is missing"

printf '%s\n' 'bind-addr: 127.0.0.1:8091' 'auth: password' 'hashed-password: $argon2id$keep' 'cert: false' > "$cfg"
verify_rc=0
verify_out="$(
    HOME="$HOME_A" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_LABEL="com.tester.code-server" \
        LSOF_LOG="$TMP/lsof-verify.log" \
        LSOF_PID="4242" \
        LAUNCHCTL_LOG="$TMP/launchctl-verify.log" \
        LAUNCHCTL_PID_FILE="$TMP/agent.pid" \
        bash -c '. "$1"; verify' _ "$SCRIPT" 2>&1
)" || verify_rc=$?
assert_eq "$verify_rc" "0" "verify passes for exactly one auth: password line"

HOME_AUTH="$TMP/home-auth"
prepare_home "$HOME_AUTH"
mkdir -p "$HOME_AUTH/.config/code-server"
printf '%s\n' 'bind-addr: 127.0.0.1:8091' 'auth: none' 'hashed-password: $argon2id$keep' 'cert: false' \
    > "$HOME_AUTH/.config/code-server/config.yaml"
chmod 0600 "$HOME_AUTH/.config/code-server/config.yaml"
auth_before="$(cksum "$HOME_AUTH/.config/code-server/config.yaml")"
run_install "$HOME_AUTH"
auth_after="$(cksum "$HOME_AUTH/.config/code-server/config.yaml")"
assert_ne "$INSTALL_RC" "0" "install does not report success when auth is not password"
assert_not_contains "$INSTALL_OUT" "85-code-server done" "auth: none install does not finish as success"
assert_not_contains "$INSTALL_OUT" "config already exists" "auth: none is not already good"
assert_eq "$auth_before" "$auth_after" "auth: none with a good bind and hash is not rewritten"

HOME_B="$TMP/home-b"
mkdir -p "$HOME_B"
rm -f "$TMP/ts.log" "$TMP/npx.mark"
bad_rc=0
bad_out="$(
    HOME="$HOME_B" \
        USER="tester" \
        PATH="$TMP/bin:/usr/bin:/bin" \
        CODE_SERVER_PORT=8080 \
        TS_LOG="$TMP/ts.log" \
        NPX_ARGV="$TMP/npx.argv" \
        NPX_STDIN="$TMP/npx.stdin" \
        NPX_MARK="$TMP/npx.mark" \
        bash -c '. "$1"; install' _ "$SCRIPT" 2>&1
)" || bad_rc=$?
assert_ne "$bad_rc" "0" "install aborts when the resolved port is 8080"
if [[ -e "$HOME_B/.config/code-server/config.yaml" || -e "$HOME_B/Library/LaunchAgents/com.tester.code-server.plist" ]]; then
    fail "port 8080 abort happens before config or plist writes"
else
    pass "port 8080 abort happens before config or plist writes"
fi
if [[ -f "$TMP/ts.log" || -f "$TMP/npx.mark" ]]; then
    fail "port 8080 abort does not call tailscale or npx"
else
    pass "port 8080 abort does not call tailscale or npx"
fi

summary
