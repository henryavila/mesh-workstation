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
printf '<plist><dict><key>Label</key><string>com.mesh.tuios-web-local</string></dict></plist>\n' > "$plist"
if check; then fail "Mac check rejects foreign plist"; else pass "Mac check rejects foreign plist"; fi

summary
