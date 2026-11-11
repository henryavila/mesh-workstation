#!/usr/bin/env bash
# F2 T-002 — MESH_NO_MESH=1 makes atuin-login.sh exit 0 without invoking
# `atuin login`; unset MESH_NO_MESH keeps the existing login path.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SCRIPT="$WS/topics/shell-terminal/atuin-login.sh"
assert_file_exists "$SCRIPT" "atuin-login.sh exists"
assert_file_contains "$SCRIPT" 'MESH_NO_MESH' \
    "atuin-login.sh guards on MESH_NO_MESH"

TMP="$(mktemp -d /tmp/atuin-no-mesh.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
# Isolate HOME so atuin-login.sh cannot prepend ~/.atuin/bin (real OAuth login).
mkdir -p "$TMP/home"
export HOME="$TMP/home"

# Fake atuin that records invocations; `login` fails the test if reached under no-mesh.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/atuin" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "${ATUIN_LOG:?}"
if [[ "${1:-}" == "login" ]]; then
    echo "LOGIN_CALLED" >> "$ATUIN_LOG"
    exit 0
fi
if [[ "${1:-}" == "status" ]]; then
    exit 1
fi
exit 0
SH
chmod +x "$TMP/bin/atuin"

run_phase() {
    local phase="$1"
    (
        # shellcheck source=/dev/null
        . "$SCRIPT"
        "$phase"
    )
}

# --- no-mesh: install/check must not call atuin login ---
: > "$TMP/atuin.log"
export ATUIN_LOG="$TMP/atuin.log"
export PATH="$TMP/bin:$PATH"
# Pretend binary exists via PATH; also clear NON_INTERACTIVE so only MESH_NO_MESH gates.
unset NON_INTERACTIVE ATUIN_LOGIN_AUTO || true
export MESH_NO_MESH=1

rc=0
out="$(run_phase install 2>&1)" || rc=$?
assert_eq "$rc" "0" "install() under MESH_NO_MESH=1 exits 0"
assert_contains "$out" "MESH_NO_MESH=1" "install() logs no-mesh skip"
if grep -q 'LOGIN_CALLED' "$TMP/atuin.log" 2>/dev/null; then
    fail "install() under no-mesh does not call atuin login"
else
    pass "install() under no-mesh does not call atuin login"
fi

rc=0
run_phase check >/dev/null 2>&1 || rc=$?
assert_eq "$rc" "0" "check() under MESH_NO_MESH=1 exits 0"
if grep -q 'status' "$TMP/atuin.log" 2>/dev/null; then
    fail "check() under no-mesh does not call atuin status"
else
    pass "check() under no-mesh does not call atuin status"
fi

# --- DX setup prints the hint and does not run atuin login ---
: > "$TMP/atuin.log"
unset MESH_NO_MESH
export NON_INTERACTIVE=0
export ATUIN_LOGIN_AUTO=1
rc=0
out="$(run_phase install 2>&1)" || rc=$?
assert_eq "$rc" "0" "unflagged install() exits 0 without logging in"
assert_contains "$out" "Run 'atuin login' when ready" "unflagged install() prints the login hint"
if grep -q 'LOGIN_CALLED' "$TMP/atuin.log" 2>/dev/null; then
    fail "DX install() does not call atuin login"
else
    pass "DX install() does not call atuin login"
fi
assert_pattern_absent "$SCRIPT" 'atuin login </dev/tty' \
    "atuin-login.sh does not invoke atuin login"

summary
