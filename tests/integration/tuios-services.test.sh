#!/usr/bin/env bash
# User services are rendered in a temporary tree; no real service is touched.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SERVICE="$ROOT/topics/remote-access/tuios/services.sh"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"

if [[ ! -f "$SERVICE" ]]; then
    fail "TUIOS service manager exists"
    summary
fi

SANDBOX="$(mktemp -d -t mesh-tuios-services.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export TUIOS_BIN_DIR="$SANDBOX/bin"
export TUIOS_SYSTEMD_DIR="$SANDBOX/systemd"
export TUIOS_LAUNCHD_DIR="$SANDBOX/launchd"
export TUIOS_SERVICE_DRY_RUN=1
export TUIOS_TEST_OS=Linux
mkdir -p "$TUIOS_BIN_DIR"
cat > "$TUIOS_BIN_DIR/tuios-web" <<'EOF'
#!/bin/sh
printf '%s\n' 'tuios-web version 0.8.4'
EOF
chmod +x "$TUIOS_BIN_DIR/tuios-web"
# shellcheck source=/dev/null
source "$SERVICE"

if install; then pass "renders a local systemd user service"; else fail "renders a local systemd user service"; fi
unit="$TUIOS_SYSTEMD_DIR/tuios-web-local.service"
assert_file_exists "$unit" "local unit exists"
assert_file_contains "$unit" 'ExecStart=.*--host 127\.0\.0\.1 --port 7681 --default-session web' "local web uses loopback and shared session"
assert_file_contains "$unit" 'Restart=on-failure' "local unit restarts on failure"

if tuios_service_apply_remote 'codename.example.com' 7685 access; then pass "renders protected remote origin"; else fail "renders protected remote origin"; fi
remote="$TUIOS_SYSTEMD_DIR/tuios-web-remote.service"
assert_file_contains "$remote" 'ExecStart=.*--host 127\.0\.0\.1 --port 7685 --allow-host codename\.example\.com --no-auth --default-session web' "remote origin uses exact host and shared session"

printf '[Service]\nExecStart=/usr/bin/other\n' > "$remote"
if tuios_service_apply_remote 'codename.example.com' 7685 access; then
    fail "foreign remote unit is preserved"
else
    pass "foreign remote unit is preserved"
fi
assert_file_contains "$remote" 'ExecStart=/usr/bin/other' "foreign content remains unchanged"

old_path="$PATH"
export TUIOS_SYSTEMD_DIR="$SANDBOX/port-check-systemd"
mkdir -p "$SANDBOX/fakebin"
cat > "$SANDBOX/fakebin/lsof" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$SANDBOX/fakebin/lsof"
export PATH="$SANDBOX/fakebin:$PATH"
export TUIOS_SERVICE_CHECK_PORTS_IN_DRY_RUN=1
if install; then fail "busy local port blocks a new service"; else pass "busy local port blocks a new service"; fi
if [[ -e "$TUIOS_SYSTEMD_DIR/tuios-web-local.service" ]]; then
    fail "busy port leaves no new unit"
else
    pass "busy port leaves no new unit"
fi
export PATH="$old_path"
unset TUIOS_SERVICE_CHECK_PORTS_IN_DRY_RUN

export TUIOS_SYSTEMD_DIR="$SANDBOX/rollback-systemd"
if tuios_service_apply_remote 'codename.example.com' 7685 access; then pass "remote fixture created"; else fail "remote fixture created"; fi
rollback
if [[ -f "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" ]]; then
    pass "local item rollback preserves separately published remote unit"
else
    fail "local item rollback preserves separately published remote unit"
fi

export TUIOS_TEST_OS=Darwin
if install; then pass "renders a macOS LaunchAgent"; else fail "renders a macOS LaunchAgent"; fi
plist="$TUIOS_LAUNCHD_DIR/com.mesh.tuios-web-local.plist"
assert_file_exists "$plist" "local LaunchAgent exists"
assert_file_contains "$plist" '<string>127\.0\.0\.1</string>' "LaunchAgent binds loopback"
assert_file_contains "$plist" '<key>KeepAlive</key>' "LaunchAgent restarts automatically"
assert_eq "$(sed -n '1p' "$plist")" '<?xml version="1.0" encoding="UTF-8"?>' "LaunchAgent begins with XML declaration"
printf '<plist><dict><key>Label</key><string>com.mesh.tuios-web-local</string></dict></plist>\n' > "$plist"
if check; then fail "Mac check rejects foreign plist"; else pass "Mac check rejects foreign plist"; fi
rm -f "$plist"
install
mkdir -p "$SANDBOX/launchctl-bin"
cat > "$SANDBOX/launchctl-bin/launchctl" <<'SH'
#!/bin/sh
if [ -n "${TUIOS_TEST_LAUNCH_LOG:-}" ]; then printf '%s\n' "$*" >> "$TUIOS_TEST_LAUNCH_LOG"; fi
if [ "$1" = bootout ] && [ "${TUIOS_TEST_BOOTOUT_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "$1" = print ]; then printf 'state = %s\n' "${TUIOS_TEST_LAUNCH_STATE:-waiting}"; fi
SH
chmod +x "$SANDBOX/launchctl-bin/launchctl"
old_path="$PATH"
export PATH="$SANDBOX/launchctl-bin:$PATH"
export TUIOS_SERVICE_DRY_RUN=0 TUIOS_TEST_LAUNCH_STATE=waiting
if check; then fail "Mac check rejects loaded but stopped LaunchAgent"; else pass "Mac check rejects loaded but stopped LaunchAgent"; fi
export TUIOS_TEST_LAUNCH_STATE=running
if check; then pass "Mac check accepts running LaunchAgent"; else fail "Mac check accepts running LaunchAgent"; fi
export TUIOS_TEST_LAUNCH_LOG="$SANDBOX/launchctl.log"
printf '<!-- Managed by mesh-workstation: tuios-tunnel-testbox -->\n' > "$TUIOS_LAUNCHD_DIR/com.mesh.tuios-tunnel-testbox.plist"
if tuios_service_restart_tunnel testbox; then pass "Mac restarts the managed JWT connector"; else fail "Mac restarts the managed JWT connector"; fi
assert_pattern_present "$TUIOS_TEST_LAUNCH_LOG" 'kickstart -k gui/[0-9]+/com.mesh.tuios-tunnel-testbox' "Mac connector restart uses kickstart"
export TUIOS_SERVICE_DRY_RUN=1
tuios_service_apply_remote 'codename.example.com' 7685 access
printf 'test-password\n' > "$SANDBOX/mac-password"
chmod 0600 "$SANDBOX/mac-password"
export TUIOS_WEB_PASSWORD_FILE="$SANDBOX/mac-password"
export TUIOS_SERVICE_DRY_RUN=0 TUIOS_TEST_BOOTOUT_FAIL=1
if tuios_service_apply_remote 'codename.example.com' 7685 password; then fail "Mac refuses to claim a password switch when no-auth job stays loaded"; else pass "Mac refuses to claim a password switch when no-auth job stays loaded"; fi
if tuios_service_disable_public; then fail "Mac quarantine fails when bootout leaves the public job loaded"; else pass "Mac quarantine fails when bootout leaves the public job loaded"; fi
assert_file_exists "$TUIOS_LAUNCHD_DIR/com.mesh.tuios-web-remote.plist" "failed Mac quarantine keeps service file for recovery"
unset TUIOS_TEST_BOOTOUT_FAIL TUIOS_WEB_PASSWORD_FILE
export PATH="$old_path" TUIOS_SERVICE_DRY_RUN=1

mkdir -p "$SANDBOX/linger-bin"
export TUIOS_LINGER_TEST_MARKER="$SANDBOX/linger-enabled"
cat > "$SANDBOX/linger-bin/loginctl" <<'SH'
#!/bin/sh
if [ -e "$TUIOS_LINGER_TEST_MARKER" ]; then printf 'Linger=yes\n'; else printf 'Linger=no\n'; fi
SH
cat > "$SANDBOX/linger-bin/sudo" <<'SH'
#!/bin/sh
if [ "$1 $2" = 'loginctl enable-linger' ]; then touch "$TUIOS_LINGER_TEST_MARKER"; exit 0; fi
exit 1
SH
chmod +x "$SANDBOX/linger-bin/loginctl" "$SANDBOX/linger-bin/sudo"
old_path="$PATH"
export PATH="$SANDBOX/linger-bin:$PATH"
if _tuios_service_ensure_linger; then pass "WSL enables user-service linger"; else fail "WSL enables user-service linger"; fi
assert_file_exists "$TUIOS_LINGER_TEST_MARKER" "linger enable was requested"
export PATH="$old_path"

export TUIOS_TEST_OS=Linux
export TUIOS_SYSTEMD_DIR="$SANDBOX/tunnel-systemd"
export TUIOS_CLOUDFLARED_BIN_DIR="$SANDBOX/bin"
cat > "$TUIOS_CLOUDFLARED_BIN_DIR/cloudflared" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$TUIOS_CLOUDFLARED_BIN_DIR/cloudflared"
printf 'tunnel: test\n' > "$SANDBOX/tunnel.yml"
if tuios_service_apply_tunnel testbox "$SANDBOX/tunnel.yml" 00000000-1111-4222-8333-444444444444; then
    pass "renders a persistent connector service"
else
    fail "renders a persistent connector service"
fi
tunnel_unit="$TUIOS_SYSTEMD_DIR/tuios-tunnel-testbox.service"
assert_file_contains "$tunnel_unit" 'tunnel --protocol http2 --no-autoupdate run 00000000-1111-4222-8333-444444444444' "connector uses HTTP/2 with fixed tunnel ID"
mkdir -p "$SANDBOX/restart-bin"
export TUIOS_TEST_SYSTEMCTL_LOG="$SANDBOX/systemctl.log"
cat > "$SANDBOX/restart-bin/systemctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$TUIOS_TEST_SYSTEMCTL_LOG"
SH
chmod +x "$SANDBOX/restart-bin/systemctl"
old_path="$PATH"
export PATH="$SANDBOX/restart-bin:$PATH" TUIOS_SERVICE_DRY_RUN=0
if tuios_service_restart_tunnel testbox; then pass "JWT transition restarts the managed connector"; else fail "JWT transition restarts the managed connector"; fi
assert_file_contains "$TUIOS_TEST_SYSTEMCTL_LOG" 'restart tuios-tunnel-testbox.service' "managed connector restart reaches systemd"
printf '[Service]\nExecStart=/usr/bin/other\n' > "$tunnel_unit"
if tuios_service_restart_tunnel testbox; then fail "foreign connector is not restarted"; else pass "foreign connector is not restarted"; fi
export PATH="$old_path" TUIOS_SERVICE_DRY_RUN=1

summary
