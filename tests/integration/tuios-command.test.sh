#!/usr/bin/env bash
# The public command reads only per-host private data and performs no setup in status/help.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-tuios-command.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export MESH_HOME="$ROOT"
export MESH_WORKSTATION_DIR="$ROOT"
export MESH_IDENTITY_DIR="$SANDBOX/identity"
export MESH_TUIOS_PROFILE="$SANDBOX/identity/config/tuios-hosts.json"
export TUIOS_SERVICE_DRY_RUN=1
export TUIOS_SYSTEMD_DIR="$SANDBOX/systemd"
mkdir -p "$(dirname "$MESH_TUIOS_PROFILE")"

cat > "$MESH_TUIOS_PROFILE" <<'JSON'
{
  "schema": 1,
  "hosts": {
    "testbox": {
      "system_hostname": "fixture-host",
      "public_hostname": "quiet-otter.example.com",
      "access_email": "user@example.com",
      "session": "web",
      "local_port": 7681,
      "remote_port": 7685,
      "tunnel_id": "00000000-1111-4222-8333-444444444444"
    }
  }
}
JSON

out="$(bash "$ROOT/bin/mesh" tuios --help 2>&1)"
rc=$?
assert_eq "$rc" 0 "mesh tuios help is registered"
assert_contains "$out" 'setup' "help includes setup"
assert_contains "$out" 'status' "help includes status"
out="$( (unset MESH_WORKSTATION_DIR; MESH_HOME="$ROOT" bash "$ROOT/bin/mesh" tuios --help) 2>&1)"
assert_not_contains "$out" 'No such file' "worktree command loads companion code from its own checkout"

out="$(bash "$ROOT/bin/mesh" tuios status --host testbox 2>&1)"
rc=$?
assert_eq "$rc" 0 "explicit host profile resolves"
assert_contains "$out" 'quiet-otter.example.com' "status reports configured hostname"
assert_contains "$out" 'session: web' "status reports shared session"

export MESH_HOST_ALIAS=testbox
out="$(bash "$ROOT/bin/mesh" tuios status 2>&1)"
rc=$?
assert_eq "$rc" 0 "Mesh host alias selects profile"
assert_not_contains "$out" 'apiToken' "status prints no credential field"
unset MESH_HOST_ALIAS
out="$(bash "$ROOT/bin/mesh" tuios status 2>&1)"
rc=$?
assert_ne "$rc" 0 "another machine does not inherit the sole profile host"
export MESH_HOST_ALIAS=testbox

cat > "$SANDBOX/setup-stub.sh" <<'SH'
#!/bin/bash
printf 'argc=%s\n' "$#"
for arg in "$@"; do printf 'arg=%s\n' "$arg"; done
SH
export MESH_TUIOS_SETUP_SCRIPT="$SANDBOX/setup-stub.sh"
out="$(bash "$ROOT/bin/mesh" tuios setup 2>&1)"
rc=$?
assert_eq "$rc" 0 "setup delegates to the publisher"
assert_eq "$out" 'argc=0' "setup without host passes no empty argument"
out="$(bash "$ROOT/bin/mesh" tuios setup --host testbox 2>&1)"
assert_contains "$out" 'argc=2' "setup forwards explicit host option"
assert_contains "$out" 'arg=testbox' "setup forwards host alias"
out="$(bash "$ROOT/bin/mesh" tuios setup --host testbox --confirm-access-email user@example.com 2>&1)"
rc=$?
assert_eq "$rc" 0 "setup accepts exact Access email confirmation"
assert_contains "$out" 'argc=4' "setup forwards confirmation to publisher"
assert_contains "$out" 'arg=user@example.com' "publisher receives confirmed email"
out="$(bash "$ROOT/bin/mesh" tuios disable --host testbox 2>&1)"
rc=$?
assert_eq "$rc" 0 "disable delegates to publisher"
assert_contains "$out" 'arg=--disable' "disable uses explicit operation flag"

mkdir -p "$SANDBOX/fakebin"
cat > "$SANDBOX/fakebin/systemctl" <<'SH'
#!/bin/sh
exit 0
SH
cat > "$SANDBOX/fakebin/curl" <<'SH'
#!/bin/sh
for arg in "$@"; do
  if [ "$arg" = '%{http_code}' ]; then printf '200'; exit 0; fi
done
if [ "${TUIOS_TEST_ACCESS_STATUS:-302}" = 302 ]; then
  printf 'HTTP/2 302\r\nlocation: https://team.cloudflareaccess.com/login\r\n\r\n'
else
  printf 'HTTP/2 200\r\n\r\n'
fi
SH
cat > "$SANDBOX/fakebin/tuios" <<'SH'
#!/bin/sh
printf 'tuios version 0.8.4\n'
SH
cat > "$SANDBOX/fakebin/tuios-web" <<'SH'
#!/bin/sh
printf 'tuios-web version 0.8.4\n'
SH
cat > "$SANDBOX/fakebin/cloudflared" <<'SH'
#!/bin/sh
if [ "$1" = --version ]; then printf 'cloudflared version 2026.9.3\n'; exit 0; fi
if [ "${TUIOS_TEST_EDGE:-connected}" = connected ]; then
  printf '{"id":"00000000-1111-4222-8333-444444444444","conns":[{"conns":[{"is_pending_reconnect":false}]}]}\n'
else
  printf '{"id":"00000000-1111-4222-8333-444444444444","conns":[]}\n'
fi
SH
chmod +x "$SANDBOX/fakebin/systemctl" "$SANDBOX/fakebin/curl" "$SANDBOX/fakebin/tuios" "$SANDBOX/fakebin/tuios-web" "$SANDBOX/fakebin/cloudflared"
old_path="$PATH"
export PATH="$SANDBOX/fakebin:$PATH"
export TUIOS_BIN_DIR="$SANDBOX/fakebin" TUIOS_CLOUDFLARED_BIN_DIR="$SANDBOX/fakebin"
export TUIOS_SERVICE_DRY_RUN=0 TUIOS_TEST_ACCESS_STATUS=302
out="$(bash "$ROOT/bin/mesh" tuios status --host testbox 2>&1)"
rc=$?
assert_eq "$rc" 0 "status is readable when healthy"
assert_contains "$out" 'versions: tuios=0.8.4 tuios-web=0.8.4 cloudflared=2026.9.3' "status reports installed versions"
assert_contains "$out" 'tunnel: connected' "status reports edge connection"
assert_contains "$out" 'Access: protected' "status reports the public gate"
out="$(bash "$ROOT/bin/mesh" tuios doctor --host testbox 2>&1)"
rc=$?
assert_eq "$rc" 0 "doctor accepts active services with Access redirect"
assert_contains "$out" 'Access: protected' "doctor reports public Access gate"
export TUIOS_TEST_EDGE=disconnected
out="$(bash "$ROOT/bin/mesh" tuios status --host testbox 2>&1)"
assert_contains "$out" 'tunnel: disconnected' "status reports a disconnected tunnel"
out="$(bash "$ROOT/bin/mesh" tuios doctor --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "doctor rejects a tunnel with no edge connector"
export TUIOS_TEST_EDGE=connected
export TUIOS_TEST_ACCESS_STATUS=200
out="$(bash "$ROOT/bin/mesh" tuios doctor --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "doctor rejects public origin with no Access redirect"
cat > "$SANDBOX/fakebin/launchctl" <<'SH'
#!/bin/sh
if [ "$1" = print ]; then
  case "$2" in
    *tuios-tunnel-testbox) [ "${TUIOS_TEST_TUNNEL_STATE:-running}" = running ] || { printf 'state = exited\n'; exit 0; } ;;
  esac
  printf 'state = running\n'
  exit 0
fi
exit 1
SH
chmod +x "$SANDBOX/fakebin/launchctl"
export TUIOS_TEST_OS=Darwin TUIOS_TEST_ACCESS_STATUS=302 TUIOS_TEST_TUNNEL_STATE=running
out="$(bash "$ROOT/bin/mesh" tuios doctor --host testbox 2>&1)"
rc=$?
assert_eq "$rc" 0 "Mac doctor accepts running local, remote and tunnel agents"
export TUIOS_TEST_TUNNEL_STATE=exited
out="$(bash "$ROOT/bin/mesh" tuios doctor --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "Mac doctor rejects a loaded but stopped tunnel agent"
unset TUIOS_TEST_OS TUIOS_TEST_TUNNEL_STATE
export PATH="$old_path" TUIOS_SERVICE_DRY_RUN=1

cat > "$MESH_TUIOS_PROFILE" <<'JSON'
{"schema":1,"hosts":{"testbox":{"system_hostname":"fixture-host","public_hostname":"evil;touch /tmp/mesh-tuios-pwn.example.com","access_email":"user@example.com","session":"web","local_port":7681,"remote_port":7685}}}
JSON
out="$(bash "$ROOT/bin/mesh" tuios status --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "invalid hostname is rejected"

summary
