#!/usr/bin/env bash
# tests/integration/workstation-dir-persist.test.sh
#
# Regression suite for setup.sh's persist_workstation_dir() — ensures
# MESH_WORKSTATION_DIR is written into ~/.config/mesh/config.env when setup.sh runs,
# preserving other entries (CODE_DIR, AUTO_UPDATE_REPOS, etc.).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
BOOT="$REPO_ROOT/setup.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-ws-dir-persist.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

# Pull in the real function from setup.sh
eval "$(sed -n '/^persist_workstation_dir() {/,/^}/p' "$BOOT")"
info() { :; }
DRY_RUN=0

if ! declare -F persist_workstation_dir >/dev/null; then
    echo "FATAL: could not extract persist_workstation_dir from $BOOT" >&2
    exit 1
fi

# Case 1: absent config.env → created with MESH_WORKSTATION_DIR
SELECTIONS_DIR="$SANDBOX/c1"
HERE="/Volumes/Custom/mesh-workstation"
MESH_WORKSTATION_DIR=""
persist_workstation_dir
assert_file_exists "$SELECTIONS_DIR/config.env" "Case 1a: config.env is created"
assert_file_contains "$SELECTIONS_DIR/config.env" "MESH_WORKSTATION_DIR=/Volumes/Custom/mesh-workstation" \
    "Case 1b: workstation dir written"
assert_eq "$MESH_WORKSTATION_DIR" "/Volumes/Custom/mesh-workstation" \
    "Case 1c: MESH_WORKSTATION_DIR exported"

# Case 2: existing config.env → updates MESH_WORKSTATION_DIR without clobbering CODE_DIR
SELECTIONS_DIR="$SANDBOX/c2"
mkdir -p "$SELECTIONS_DIR"
cat > "$SELECTIONS_DIR/config.env" <<EOF
CODE_DIR=/Volumes/Custom/code
MESH_WORKSTATION_DIR=/stale/path
AUTO_UPDATE_REPOS=(
    "\$MESH_WORKSTATION_DIR"
)
EOF
HERE="/Volumes/Custom/mesh-workstation"
MESH_WORKSTATION_DIR=""
persist_workstation_dir
assert_eq "$(grep -c '^MESH_WORKSTATION_DIR=' "$SELECTIONS_DIR/config.env")" "1" \
    "Case 2a: exactly one MESH_WORKSTATION_DIR line"
assert_file_contains "$SELECTIONS_DIR/config.env" "MESH_WORKSTATION_DIR=/Volumes/Custom/mesh-workstation" \
    "Case 2b: updated workstation dir written"
assert_file_contains "$SELECTIONS_DIR/config.env" "CODE_DIR=/Volumes/Custom/code" \
    "Case 2c: CODE_DIR preserved"
assert_file_contains "$SELECTIONS_DIR/config.env" "AUTO_UPDATE_REPOS=(" \
    "Case 2d: bash array preserved"

# Case 3: DRY_RUN never writes
SELECTIONS_DIR="$SANDBOX/c3"
HERE="/Volumes/Custom/mesh-workstation"
MESH_WORKSTATION_DIR=""
DRY_RUN=1 persist_workstation_dir
DRY_RUN=0
assert_false "[[ -f '$SELECTIONS_DIR/config.env' ]]" "Case 3a: dry-run writes no config.env"

summary
