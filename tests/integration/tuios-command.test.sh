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

cat > "$MESH_TUIOS_PROFILE" <<'JSON'
{"schema":1,"hosts":{"testbox":{"system_hostname":"fixture-host","public_hostname":"evil;touch /tmp/mesh-tuios-pwn.example.com","access_email":"user@example.com","session":"web","local_port":7681,"remote_port":7685}}}
JSON
out="$(bash "$ROOT/bin/mesh" tuios status --host testbox 2>&1)"
rc=$?
assert_ne "$rc" 0 "invalid hostname is rejected"

summary
