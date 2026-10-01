#!/usr/bin/env bash
# Protected publication staged against fake Cloudflare and service managers.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PUBLISH="$ROOT/topics/remote-access/tuios/publish.sh"
AUD=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"
if [[ ! -f "$PUBLISH" ]]; then fail "publication helper exists"; summary; fi

SANDBOX="$(mktemp -d -t mesh-tuios-publish.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export MESH_WORKSTATION_DIR="$ROOT"
export MESH_IDENTITY_DIR="$SANDBOX/identity"
export MESH_TUIOS_PROFILE="$MESH_IDENTITY_DIR/config/tuios-hosts.json"
export TUIOS_BIN_DIR="$SANDBOX/bin"
export TUIOS_CLOUDFLARED_BIN_DIR="$SANDBOX/bin"
export TUIOS_CLOUDFLARED_DIR="$SANDBOX/cloudflared"
export TUIOS_SYSTEMD_DIR="$SANDBOX/systemd"
export TUIOS_WEB_PASSWORD_FILE="$SANDBOX/password"
export TUIOS_SERVICE_DRY_RUN=1 TUIOS_TEST_OS=Linux
export TUIOS_TEST_LOG="$SANDBOX/cloudflared.log"
mkdir -p "$MESH_IDENTITY_DIR/config" "$TUIOS_BIN_DIR" "$TUIOS_CLOUDFLARED_DIR"
cat > "$MESH_TUIOS_PROFILE" <<'JSON'
{"schema":1,"hosts":{"testbox":{"system_hostname":"fixture-host","public_hostname":"quiet-otter.example.com","access_email":"user@example.com","session":"web","local_port":7681,"remote_port":7685,"tunnel_id":"00000000-1111-4222-8333-444444444444"}}}
JSON
printf '{}\n' > "$TUIOS_CLOUDFLARED_DIR/00000000-1111-4222-8333-444444444444.json"
chmod 0400 "$TUIOS_CLOUDFLARED_DIR/00000000-1111-4222-8333-444444444444.json"
cat > "$TUIOS_BIN_DIR/tuios-web" <<'SH'
#!/bin/sh
printf '%s\n' 'tuios-web version 0.8.4'
SH
cat > "$TUIOS_BIN_DIR/cloudflared" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TUIOS_TEST_LOG"
case "$1 $2" in
  'tunnel --config')
    if [ "$4 $5" = 'ingress validate' ]; then
      [ "${TUIOS_TEST_CONFIG_VALID:-1}" = 1 ] || exit 1
      if [ "${TUIOS_TEST_EXPECT_PASSWORD_AT_VALIDATE:-0}" = 1 ] && grep -q 'required: true' "$3"; then
        grep -q -- '--password-file' "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" || exit 1
      fi
      exit 0
    fi
    ;;
  'tunnel info') exit 0 ;;
  'tunnel route') exit 0 ;;
  'tunnel create')
    mkdir -p "$TUIOS_CLOUDFLARED_DIR"
    printf '{}\n' > "$TUIOS_CLOUDFLARED_DIR/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.json"
    chmod 0400 "$TUIOS_CLOUDFLARED_DIR/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.json"
    exit 0
    ;;
  'tunnel list')
    if [ -f "$TUIOS_CLOUDFLARED_DIR/aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee.json" ]; then
      printf '[{"id":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee","name":"mesh-tuios-newbox"}]\n'
    else
      printf '[]\n'
    fi
    exit 0
    ;;
esac
exit 1
SH
chmod +x "$TUIOS_BIN_DIR/tuios-web" "$TUIOS_BIN_DIR/cloudflared"
mkdir -p "$SANDBOX/fakebin"
cat > "$SANDBOX/fakebin/curl" <<'SH'
#!/bin/sh
if [ "${TUIOS_TEST_ACCESS_STATUS:-302}" = 302 ]; then
  printf 'HTTP/2 302\r\nlocation: https://team.cloudflareaccess.com/cdn-cgi/access/login\r\n\r\n'
else
  printf 'HTTP/2 200\r\n\r\n'
fi
SH
chmod +x "$SANDBOX/fakebin/curl"
export PATH="$SANDBOX/fakebin:$PATH"

out="$(bash "$PUBLISH" --host testbox 2>&1)"
rc=$?
assert_eq "$rc" 0 "first setup stages protected origin"
assert_contains "$out" 'Cloudflare Access' "setup names next Access step"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" '.*--password-file' "staged origin requires password"
ASSERT_MSG="password has owner-only mode" assert_true "test \"$(stat -c %a "$TUIOS_WEB_PASSWORD_FILE")\" = 600"
assert_file_contains "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.yml" 'hostname: quiet-otter.example.com' "ingress uses only selected host"
assert_file_contains "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.yml" 'service: http_status:404' "unmatched hosts get 404"
assert_eq "$(grep -c 'tunnel route dns' "$TUIOS_TEST_LOG")" 1 "first setup adds one DNS route"

chmod 0644 "$TUIOS_CLOUDFLARED_DIR/00000000-1111-4222-8333-444444444444.json"
out="$(bash "$PUBLISH" --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "refuses a tunnel credential readable by other users"
chmod 0400 "$TUIOS_CLOUDFLARED_DIR/00000000-1111-4222-8333-444444444444.json"

out="$(bash "$PUBLISH" --host testbox 2>&1)"
assert_eq "$(grep -c 'tunnel route dns' "$TUIOS_TEST_LOG")" 1 "repeat setup does not rewrite DNS"

export TUIOS_TEST_ACCESS_STATUS=200
out="$(bash "$PUBLISH" --host testbox --confirm-access-email user@example.com 2>&1)"
rc=$?
assert_ne "$rc" 0 "origin stays protected when Access redirect is absent"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" '.*--password-file' "failed Access check preserves password"

export TUIOS_TEST_ACCESS_STATUS=302
out="$(bash "$PUBLISH" --host testbox --confirm-access-email user@example.com 2>&1)"
rc=$?
assert_ne "$rc" 0 "Access confirmation requires an application AUD before no-auth"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" '.*--password-file' "missing AUD leaves the password gate active"
export TUIOS_TEST_CONFIG_VALID=0
out="$(bash "$PUBLISH" --host testbox --confirm-access-email user@example.com --access-aud "$AUD" 2>&1)"
rc=$?
assert_ne "$rc" 0 "invalid JWT ingress configuration blocks no-auth"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" '.*--password-file' "failed ingress validation preserves password"
export TUIOS_TEST_CONFIG_VALID=1
export TUIOS_TEST_EXPECT_PASSWORD_AT_VALIDATE=1
out="$(bash "$PUBLISH" --host testbox --confirm-access-email user@example.com --access-aud "$AUD" 2>&1)"
rc=$?
assert_eq "$rc" 0 "exact email confirmation completes setup"
unset TUIOS_TEST_EXPECT_PASSWORD_AT_VALIDATE
assert_file_contains "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.yml" 'required: true' "connector requires an Access JWT"
assert_file_contains "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.yml" 'teamName: team' "connector uses the redirect-derived team"
assert_file_contains "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.yml" "$AUD" "connector pins the application audience"
assert_eq "$(jq -r '.hosts.testbox.access_aud' "$MESH_TUIOS_PROFILE")" "$AUD" "private profile records non-secret AUD"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" '.*--no-auth' "ready origin delegates login to Access"
ASSERT_MSG="ready origin omits Basic Auth" assert_false "grep -q -- '--password-file' '$TUIOS_SYSTEMD_DIR/tuios-web-remote.service'"
out="$(bash "$PUBLISH" --host testbox 2>&1)"
rc=$?
assert_eq "$rc" 0 "ready publication remains usable on repeat setup"
assert_contains "$out" 'Access ready:' "repeat setup reports the already-ready state"
sed 's/required: true/required: false\n        # required: true/' "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.yml" > "$SANDBOX/tampered.yml"
cp "$SANDBOX/tampered.yml" "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.yml"
out="$(bash "$PUBLISH" --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "tampered JWT gate revokes ready publication"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" '.*--password-file' "tampered gate restores the origin password"
if [[ ! -f "$TUIOS_SYSTEMD_DIR/tuios-tunnel-testbox.service" ]]; then pass "tampered gate quarantines the connector"; else fail "tampered gate quarantines the connector"; fi
out="$(bash "$PUBLISH" --host testbox --confirm-access-email user@example.com --access-aud "$AUD" 2>&1)"
rc=$?
assert_eq "$rc" 0 "publication can recover after JWT gate repair"
assert_file_contains "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.yml" 'required: true' "repair restores connector JWT requirement"

export TUIOS_TEST_ACCESS_STATUS=200
out="$(bash "$PUBLISH" --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "rerun refuses to leave public origin unprotected when Access disappears"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" '.*--password-file' "Access loss restores password gate"

export TUIOS_TEST_ACCESS_STATUS=302
out="$(bash "$PUBLISH" --host testbox --confirm-access-email user@example.com --access-aud "$AUD" 2>&1)"
assert_eq "$?" 0 "ready state can be restored before testing crash recovery"
rm "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-testbox.access-ready"
saved_password_file="$TUIOS_WEB_PASSWORD_FILE"
printf 'blocked\n' > "$SANDBOX/blocker"
export TUIOS_WEB_PASSWORD_FILE="$SANDBOX/blocker/password"
out="$(bash "$PUBLISH" --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "password-file failure does not leave prior no-auth publication running"
if [[ ! -f "$TUIOS_SYSTEMD_DIR/tuios-tunnel-testbox.service" ]]; then pass "failed password recovery quarantines the connector"; else fail "failed password recovery quarantines the connector"; fi
export TUIOS_WEB_PASSWORD_FILE="$saved_password_file"

export MESH_IDENTITY_DIR="$SANDBOX/new-identity"
export MESH_TUIOS_PROFILE="$MESH_IDENTITY_DIR/config/tuios-hosts.json"
export TUIOS_CLOUDFLARED_DIR="$SANDBOX/new-cloudflared"
export TUIOS_SYSTEMD_DIR="$SANDBOX/new-systemd"
export TUIOS_WEB_PASSWORD_FILE="$SANDBOX/new-password"
export MESH_TUIOS_SETUP_ALIAS=newbox
export MESH_TUIOS_SETUP_HOSTNAME=leaf-river.example.com
export MESH_TUIOS_SETUP_EMAIL=new@example.com
export TUIOS_SESSION=mobile-work TUIOS_LOCAL_PORT=7691
mkdir -p "$TUIOS_CLOUDFLARED_DIR"
printf 'test certificate\n' > "$TUIOS_CLOUDFLARED_DIR/cert.pem"
out="$(bash "$PUBLISH" 2>&1)"
rc=$?
assert_eq "$rc" 0 "new identity can create its first host profile and tunnel"
assert_eq "$(jq -r '.hosts.newbox.public_hostname' "$MESH_TUIOS_PROFILE" 2>/dev/null)" 'leaf-river.example.com' "new user's codename is recorded privately"
assert_eq "$(jq -r '.hosts.newbox.tunnel_id' "$MESH_TUIOS_PROFILE" 2>/dev/null)" 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee' "profile receives tunnel ID without credential"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-local.service" '.*--port 7691 --default-session mobile-work' "local web follows the private profile"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" '.*--default-session mobile-work' "remote web shares the customized local session"
ASSERT_MSG="private profile contains no account or tunnel credential" assert_false "grep -qE 'apiToken|TunnelSecret|cert.pem' '$MESH_TUIOS_PROFILE'"

out="$(bash "$PUBLISH" --host newbox --disable 2>&1)"
rc=$?
assert_eq "$rc" 0 "disable stops only Mesh-managed publication services"
if [[ ! -e "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" && ! -e "$TUIOS_SYSTEMD_DIR/tuios-tunnel-newbox.service" ]]; then
    pass "remote and connector units are removed"
else
    fail "remote and connector units are removed"
fi
assert_file_exists "$MESH_TUIOS_PROFILE" "disable preserves private profile"
assert_file_exists "$TUIOS_CLOUDFLARED_DIR/mesh-tuios-newbox.route" "disable preserves DNS route metadata"

printf '[Service]\nExecStart=/usr/bin/other\n' > "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service"
out="$(bash "$PUBLISH" --host newbox --disable 2>&1)"
rc=$?
assert_ne "$rc" 0 "disable refuses to claim success while an unmanaged origin exists"
assert_contains "$out" 'unmanaged' "disable identifies foreign origin"
assert_file_contains "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" 'ExecStart=/usr/bin/other' "unmanaged origin remains untouched"

summary
