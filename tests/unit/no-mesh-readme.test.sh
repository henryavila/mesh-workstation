#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$WS/tests/lib/assert.sh"
out="$(bash "$WS/setup.sh" --no-mesh 2>&1)" && rc=0 || rc=$?
assert_ne "$rc" "0" "--no-mesh exits nonzero"
assert_contains "$out" "--no-mesh was removed. setup.sh is DX and does not join identity." "retirement message line 1"
assert_contains "$out" "For a headless Linux server: setup.sh --server" "retirement message line 2"
env_out="$(MESH_NO_MESH=1 bash "$WS/setup.sh" --dry-run 2>&1)" && env_rc=0 || env_rc=$?
assert_ne "$env_rc" "0" "MESH_NO_MESH exits nonzero"
assert_contains "$env_out" "--no-mesh was removed" "MESH_NO_MESH prints the retirement message"
summary
