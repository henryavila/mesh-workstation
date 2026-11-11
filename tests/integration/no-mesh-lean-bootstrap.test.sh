#!/usr/bin/env bash
# Interactive --no-mesh with no Blink menu (Node missing) must still install a
# usable shell + Node so the second run can open the menu. Headless
# (--non-interactive) stays foundation/base only.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

SETUP="$WS/setup.sh"
HELPER="$WS/scripts/lib/no-mesh.sh"

assert_file_exists "$SETUP" "setup.sh exists"
assert_file_exists "$HELPER" "scripts/lib/no-mesh.sh exists"

# shellcheck source=/dev/null
. "$HELPER"

# shellcheck disable=SC2034 # read by no_mesh_emit_lean_bootstrap
MESH_NO_MESH=1
if declare -f no_mesh_emit_lean_bootstrap >/dev/null 2>&1; then
    lean="$(no_mesh_emit_lean_bootstrap)"
    pass "no_mesh_emit_lean_bootstrap is defined"
else
    lean=""
    fail "no_mesh_emit_lean_bootstrap is defined"
fi
assert_contains "$lean" "foundation/base" "no-mesh lean includes foundation/base"
assert_contains "$lean" "git/config" "no-mesh lean includes git/config"
assert_contains "$lean" "shell-terminal/cli-tools" "no-mesh lean includes cli-tools"
assert_contains "$lean" "shell-terminal/zsh" "no-mesh lean includes zsh"
assert_contains "$lean" "shell-terminal/fonts" "no-mesh lean includes fonts (WT/NF)"
assert_not_contains "$lean" "languages/" "no-mesh lean does not include removed language bundles"
assert_not_contains "$lean" "personal/" "no-mesh lean omits membership personal"
assert_not_contains "$lean" "identity/" "no-mesh lean omits membership identity"
assert_not_contains "$lean" "databases/" "no-mesh lean must not pull databases"
assert_not_contains "$lean" "syncthing/" "no-mesh lean omits membership syncthing"
unset MESH_NO_MESH

# setup.sh must prefer MESH_LEAN_BOOTSTRAP over the headless foundation-only
# default (otherwise a virgin --no-mesh first run never installs Node).
emit_fn="$(awk '/^emit_default_selections\(\)/,/^}/' "$SETUP")"
lean_line="$(printf '%s\n' "$emit_fn" | grep -n 'MESH_LEAN_BOOTSTRAP' | head -1 | cut -d: -f1)"
headless_line="$(printf '%s\n' "$emit_fn" | grep -n 'no_mesh_emit_default_or_bundles' | head -1 | cut -d: -f1)"
assert_true "[[ -n '$lean_line' && -n '$headless_line' ]]"
if [[ -n "$lean_line" && -n "$headless_line" && "$lean_line" -lt "$headless_line" ]]; then
    pass "emit_default_selections checks MESH_LEAN_BOOTSTRAP before no-mesh headless default"
else
    fail "emit_default_selections must check MESH_LEAN_BOOTSTRAP before no_mesh_emit_default_or_bundles (lean=$lean_line headless=$headless_line)"
fi

TMP="$(mktemp -d /tmp/no-mesh-lean.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# Menu-unavailable path: MESH_LEAN_BOOTSTRAP=1 + --no-mesh dry-run.
home1="$TMP/home-lean"
mkdir -p "$home1"
rc1=0
out1="$(
    HOME="$home1" \
    XDG_CONFIG_HOME="$home1/.config" \
    XDG_STATE_HOME="$home1/.local/state" \
    MESH_LEAN_BOOTSTRAP=1 \
    bash "$SETUP" --no-mesh --non-interactive --dry-run 2>&1
)" || rc1=$?
assert_eq "$rc1" "0" "no-mesh lean dry-run exits 0"
assert_contains "$out1" "foundation/base" "lean dry-run log mentions foundation/base"

sel1="$home1/.config/mesh/selections.list"
# --dry-run + no-mesh currently persists; lean rewrite must land in that file
# or in a temp file referenced in the log. Prefer the persisted list.
if [[ -f "$sel1" ]]; then
    body1="$(grep -vE '^[[:space:]]*(#|$)' "$sel1" || true)"
else
    body1=""
    fail "no-mesh lean dry-run did not write selections.list"
fi
assert_contains "$body1" "foundation/base" "lean no-mesh list includes foundation/base"
assert_contains "$body1" "shell-terminal/zsh" "lean no-mesh list includes zsh"
assert_contains "$body1" "shell-terminal/cli-tools" "lean no-mesh list includes cli-tools"
assert_not_contains "$body1" "languages/" "lean no-mesh list excludes removed language bundles"
assert_not_contains "$body1" "personal/" "lean no-mesh list excludes personal"
assert_eq "$rc1" "0" "lean no-mesh dry-run exited 0"

# Headless contract unchanged: --non-interactive --no-mesh is foundation/base only.
home2="$TMP/home-headless"
mkdir -p "$home2"
rc2=0
out2="$(
    HOME="$home2" \
    XDG_CONFIG_HOME="$home2/.config" \
    XDG_STATE_HOME="$home2/.local/state" \
    NON_INTERACTIVE=1 \
    bash "$SETUP" --no-mesh --non-interactive --dry-run 2>&1
)" || rc2=$?
sel2="$home2/.config/mesh/selections.list"
body2="$(grep -vE '^[[:space:]]*(#|$)' "$sel2" || true)"
assert_eq "$body2" "foundation/base" \
    "headless --no-mesh is still foundation/base only"
assert_not_contains "$body2" "shell-terminal/" "headless --no-mesh does not sneak in shell bundles"
assert_eq "$rc2" "0" "headless no-mesh dry-run exited 0"
assert_not_contains "$out2" "unknown arg" "--no-mesh/--dry-run accepted"

summary
