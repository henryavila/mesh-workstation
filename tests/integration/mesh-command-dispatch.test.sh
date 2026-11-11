#!/usr/bin/env bash
# tests/integration/mesh-command-dispatch.test.sh
#
# Contract for the registry-first mesh dispatcher:
#   - bare mesh and top-level status flags still route to status
#   - public built-ins are registered by command modules
#   - duplicate real modules fail during load with a clear registry error
#   - unregistered identity sub_* functions remain a private fallback
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-command-dispatch.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
mkdir -p "$MESH_HOME_FAKE/lib" "$MESH_HOME_FAKE/internal" "$MESH_HOME_FAKE/runners" "$IDENTITY_EMPTY"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

cat > "$MESH_HOME_FAKE/internal/mesh-status" <<'SH'
#!/usr/bin/env bash
printf 'STATUS:%s\n' "$*"
SH
chmod +x "$MESH_HOME_FAKE/internal/mesh-status"

cat > "$MESH_HOME_FAKE/runners/config.sh" <<'SH'
#!/usr/bin/env bash
printf 'CONFIG:%s\n' "$*"
SH
chmod +x "$MESH_HOME_FAKE/runners/config.sh"

run_mesh() {
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    "$MESH" "$@"
}

echo "status compatibility"
out="$(run_mesh 2>&1)"
rc=$?
assert_eq "$rc" 0 "bare mesh exits 0"
assert_eq "$out" "STATUS:" "bare mesh routes to status"

out="$(run_mesh --json 2>&1)"
rc=$?
assert_eq "$rc" 0 "top-level --json exits 0"
assert_eq "$out" "STATUS:--json" "top-level --json routes to status"

echo
echo "module-backed public commands"
expected_commands="status snap doctor adopt update upgrade topic run init template-check lint catalog personal-clone menu setup secret syncthing clean ai config reinstall"
commands_out="$(run_mesh __commands 2>&1)"
for name in $expected_commands; do
    count="$(printf '%s\n' "$commands_out" | awk -F '\t' -v n="$name" '$1 == n { c++ } END { print c + 0 }')"
    assert_eq "$count" "1" "module registry emits one $name row"
done

out="$(run_mesh config list git 2>&1)"
rc=$?
assert_eq "$rc" 0 "config module exits 0"
assert_eq "$out" "CONFIG:list git" "config module dispatches to runner"

echo
echo "core command duplicate is rejected"
MODULES_REAL="$SANDBOX/modules-real"
mkdir -p "$MODULES_REAL"
cat > "$MODULES_REAL/10-doctor.sh" <<'SH'
cmd_real_doctor() {
    printf 'REAL_DOCTOR:%s\n' "$*"
}
mesh_register_command \
    --name doctor \
    --summary "Real doctor module" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_real_doctor
SH

out="$(
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_COMMAND_MODULE_DIR="$MODULES_REAL" \
    "$MESH" doctor from-module 2>&1
)"
rc=$?
assert_ne "$rc" 0 "duplicate doctor module exits non-zero"
assert_contains "$out" "duplicate command: doctor" "duplicate doctor module surfaces registry error"
assert_contains "$out" "command module failed to load" "duplicate doctor module names module-load failure"

echo
echo "duplicate real modules"
MODULES_DUP="$SANDBOX/modules-dup"
mkdir -p "$MODULES_DUP"
cat > "$MODULES_DUP/10-one.sh" <<'SH'
cmd_dupe_one() { :; }
mesh_register_command \
    --name dupe \
    --summary "First duplicate" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_dupe_one
SH
cat > "$MODULES_DUP/20-two.sh" <<'SH'
cmd_dupe_two() { :; }
mesh_register_command \
    --name dupe \
    --summary "Second duplicate" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_dupe_two
SH

out="$(
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_COMMAND_MODULE_DIR="$MODULES_DUP" \
    "$MESH" dupe 2>&1
)"
rc=$?
assert_ne "$rc" 0 "duplicate real modules exit non-zero"
assert_contains "$out" "duplicate command: dupe" "duplicate real modules surface registry error"
assert_contains "$out" "command module failed to load" "duplicate real modules name module-load failure"

MODULES_MASKED="$SANDBOX/modules-masked"
mkdir -p "$MODULES_MASKED"
cat > "$MODULES_MASKED/10-masked.sh" <<'SH'
cmd_masked_one() { :; }
cmd_masked_two() { :; }
mesh_register_command \
    --name masked-dupe \
    --summary "Masked duplicate one" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_masked_one
mesh_register_command \
    --name masked-dupe \
    --summary "Masked duplicate two" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_masked_two
:
SH

out="$(
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_COMMAND_MODULE_DIR="$MODULES_MASKED" \
    "$MESH" masked-dupe 2>&1
)"
rc=$?
assert_ne "$rc" 0 "masked registration failure exits non-zero"
assert_contains "$out" "duplicate command: masked-dupe" "masked registration failure keeps registry error"
assert_contains "$out" "command module failed to load" "masked registration failure names module-load failure"

echo
echo "identity fallback"
IDENTITY_PRIVATE="$SANDBOX/identity-private"
mkdir -p "$IDENTITY_PRIVATE/extensions"
cat > "$IDENTITY_PRIVATE/extensions/mesh.sh" <<'SH'
sub_private_tool() {
    printf 'PRIVATE:%s\n' "$*"
}
sub_config() {
    printf 'PRIVATE_CONFIG:%s\n' "$*"
}
SH

out="$(
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_PRIVATE" \
    "$MESH" private-tool alpha beta 2>&1
)"
rc=$?
assert_eq "$rc" 0 "unregistered identity fallback exits 0"
assert_eq "$out" "PRIVATE:alpha beta" "unregistered identity sub_* fallback executes"

out="$(
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_PRIVATE" \
    "$MESH" config list 2>&1
)"
rc=$?
assert_eq "$rc" 0 "registered public command shadows identity config fallback"
assert_eq "$out" "CONFIG:list" "registered public config module wins over private sub_config"

echo
summary
