#!/usr/bin/env bash
# Topic verification follows the selected TUIOS bundle and checks paired versions.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-tuios-onboarding.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin"
for name in ssh mosh tailscale; do
    cat > "$SANDBOX/bin/$name" <<'SH'
#!/bin/sh
exit 0
SH
    chmod +x "$SANDBOX/bin/$name"
done
export PATH="$SANDBOX/bin:$PATH"
export TUIOS_BIN_DIR="$SANDBOX/bin"
export MESH_SELECTIONS_FILE="$SANDBOX/selections.list"
printf 'remote-access/ssh\n' > "$MESH_SELECTIONS_FILE"
out="$(bash "$ROOT/topics/remote-access/verify.sh" 2>&1)"
rc=$?
assert_eq "$rc" 0 "unselected TUIOS does not affect remote-access verifier"
assert_not_contains "$out" 'tuios-web' "unselected TUIOS is not probed"

for name in tuios tuios-web; do
    cat > "$SANDBOX/bin/$name" <<EOF
#!/bin/sh
printf '%s\\n' '$name version 0.8.4'
EOF
    chmod +x "$SANDBOX/bin/$name"
done
printf 'remote-access/tuios\n' > "$MESH_SELECTIONS_FILE"
out="$(bash "$ROOT/topics/remote-access/verify.sh" 2>&1)"
rc=$?
assert_eq "$rc" 0 "selected TUIOS pair verifies"
assert_contains "$out" 'tuios-web' "web binary appears in selected verification"
assert_not_contains "$out" 'mosh' "TUIOS-only selection does not verify unselected mosh"
assert_not_contains "$out" 'tailscale' "TUIOS-only selection does not verify unselected Tailscale"
assert_not_contains "$out" 'ssh' "TUIOS-only selection does not verify unselected SSH"

cat > "$SANDBOX/bin/tuios-web" <<'SH'
#!/bin/sh
printf '%s\n' 'tuios-web version 0.8.3'
SH
chmod +x "$SANDBOX/bin/tuios-web"
out="$(bash "$ROOT/topics/remote-access/verify.sh" 2>&1)"
rc=$?
assert_ne "$rc" 0 "mismatched TUIOS pair is unhealthy"
assert_contains "$out" 'version mismatch' "verifier explains the version problem"

summary
