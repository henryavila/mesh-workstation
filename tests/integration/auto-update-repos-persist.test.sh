#!/usr/bin/env bash
# Fixture variables are consumed by sourced production functions.
# shellcheck disable=SC2034
# tests/integration/auto-update-repos-persist.test.sh
#
# Regression: persist_code_dir / persist_workstation_dir used to CREATE
# ~/.config/mesh/config.env with only CODE_DIR + MESH_WORKSTATION_DIR.
# `mesh update` then failed with "AUTO_UPDATE_REPOS is empty".
# setup.sh must seed the array once (never overwrite a user list).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
BOOT="$REPO_ROOT/setup.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-au-repos-persist.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

eval "$(sed -n '/^persist_identity_dir() {/,/^}/p' "$BOOT")"
eval "$(sed -n '/^persist_auto_update_repos() {/,/^}/p' "$BOOT")"
info() { :; }
DRY_RUN=0
MESH_NO_MESH=0

if ! declare -F persist_identity_dir >/dev/null; then
    echo "FATAL: could not extract persist_identity_dir from $BOOT" >&2
    exit 1
fi
if ! declare -F persist_auto_update_repos >/dev/null; then
    echo "FATAL: could not extract persist_auto_update_repos from $BOOT" >&2
    exit 1
fi

load_repos() {
    local file="$1"
    # shellcheck source=/dev/null
    AUTO_UPDATE_REPOS=()
    set +u
    # shellcheck disable=SC1090
    . "$file"
    set -u
}

# ─── Case 1: absent config.env → seed workstation + identity ─────────────────
SELECTIONS_DIR="$SANDBOX/c1"
HERE="$SANDBOX/c1/mesh-workstation"
MESH_WORKSTATION_DIR="$HERE"
MESH_IDENTITY_DIR="$SANDBOX/c1/mesh-identity"
persist_identity_dir
persist_auto_update_repos
assert_file_exists "$SELECTIONS_DIR/config.env" "Case 1a: config.env is created"
assert_file_contains "$SELECTIONS_DIR/config.env" "MESH_IDENTITY_DIR=$MESH_IDENTITY_DIR" \
    "Case 1b: identity dir written"
assert_file_contains "$SELECTIONS_DIR/config.env" 'AUTO_UPDATE_REPOS=(' \
    "Case 1c: AUTO_UPDATE_REPOS seeded"
load_repos "$SELECTIONS_DIR/config.env"
assert_eq "${#AUTO_UPDATE_REPOS[@]}" "2" "Case 1d: two repos (workstation + identity)"
assert_eq "${AUTO_UPDATE_REPOS[0]}" "$HERE" "Case 1e: workstation path first"
assert_eq "${AUTO_UPDATE_REPOS[1]}" "$MESH_IDENTITY_DIR" "Case 1f: identity path second"

# ─── Case 2: existing user list is once-mode (never overwritten) ─────────────
SELECTIONS_DIR="$SANDBOX/c2"
mkdir -p "$SELECTIONS_DIR"
cat > "$SELECTIONS_DIR/config.env" <<EOF
CODE_DIR=$SANDBOX/c2/code
MESH_WORKSTATION_DIR=$SANDBOX/c2/ws
AUTO_UPDATE_REPOS=(
    "$SANDBOX/c2/custom-only"
)
EOF
HERE="$SANDBOX/c2/ws"
MESH_WORKSTATION_DIR="$HERE"
MESH_IDENTITY_DIR="$SANDBOX/c2/id"
persist_identity_dir
persist_auto_update_repos
persist_auto_update_repos
assert_eq "$(grep -c '^AUTO_UPDATE_REPOS=' "$SELECTIONS_DIR/config.env")" "1" \
    "Case 2a: exactly one AUTO_UPDATE_REPOS assignment after two runs"
load_repos "$SELECTIONS_DIR/config.env"
assert_eq "${#AUTO_UPDATE_REPOS[@]}" "1" "Case 2b: user list length preserved"
assert_eq "${AUTO_UPDATE_REPOS[0]}" "$SANDBOX/c2/custom-only" \
    "Case 2c: user-edited path kept"
assert_file_contains "$SELECTIONS_DIR/config.env" "CODE_DIR=$SANDBOX/c2/code" \
    "Case 2d: CODE_DIR preserved"
assert_file_contains "$SELECTIONS_DIR/config.env" "MESH_IDENTITY_DIR=$MESH_IDENTITY_DIR" \
    "Case 2e: identity dir upserted alongside the existing list"

# ─── Case 3: CODE_DIR-only leftover config.env is healed ─────────────────────
SELECTIONS_DIR="$SANDBOX/c3"
mkdir -p "$SELECTIONS_DIR"
printf 'CODE_DIR=%s\nMESH_WORKSTATION_DIR=%s\n' "$SANDBOX/c3/code" "$SANDBOX/c3/ws" \
    > "$SELECTIONS_DIR/config.env"
HERE="$SANDBOX/c3/ws"
MESH_WORKSTATION_DIR="$HERE"
MESH_IDENTITY_DIR="$SANDBOX/c3/id"
persist_auto_update_repos
load_repos "$SELECTIONS_DIR/config.env"
assert_eq "${#AUTO_UPDATE_REPOS[@]}" "2" "Case 3a: leftover CODE_DIR-only config is seeded"
assert_file_contains "$SELECTIONS_DIR/config.env" "CODE_DIR=$SANDBOX/c3/code" \
    "Case 3b: existing CODE_DIR kept"

# ─── Case 4: --no-mesh omits identity ────────────────────────────────────────
SELECTIONS_DIR="$SANDBOX/c4"
HERE="$SANDBOX/c4/ws"
MESH_WORKSTATION_DIR="$HERE"
MESH_IDENTITY_DIR="$SANDBOX/c4/id"
MESH_NO_MESH=1
persist_auto_update_repos
MESH_NO_MESH=0
load_repos "$SELECTIONS_DIR/config.env"
assert_eq "${#AUTO_UPDATE_REPOS[@]}" "1" "Case 4a: no-mesh seeds workstation only"
assert_eq "${AUTO_UPDATE_REPOS[0]}" "$HERE" "Case 4b: workstation path is the only entry"
assert_not_contains "$(cat "$SELECTIONS_DIR/config.env")" "$SANDBOX/c4/id" \
    "Case 4c: identity path is absent"

# ─── Case 5: DRY_RUN never writes ────────────────────────────────────────────
SELECTIONS_DIR="$SANDBOX/c5"
HERE="$SANDBOX/c5/ws"
MESH_WORKSTATION_DIR="$HERE"
MESH_IDENTITY_DIR="$SANDBOX/c5/id"
DRY_RUN=1 persist_identity_dir
DRY_RUN=1 persist_auto_update_repos
DRY_RUN=0
assert_false "[[ -f '$SELECTIONS_DIR/config.env' ]]" "Case 5a: dry-run writes no config.env"

# ─── Case 6: path with a space round-trips through %q ────────────────────────
SELECTIONS_DIR="$SANDBOX/c6"
HERE="$SANDBOX/c6/mesh workstation"
MESH_WORKSTATION_DIR="$HERE"
MESH_IDENTITY_DIR="$SANDBOX/c6/mesh identity"
persist_auto_update_repos
load_repos "$SELECTIONS_DIR/config.env"
assert_eq "${AUTO_UPDATE_REPOS[0]}" "$HERE" "Case 6a: spaced workstation path decodes intact"
assert_eq "${AUTO_UPDATE_REPOS[1]}" "$MESH_IDENTITY_DIR" \
    "Case 6b: spaced identity path decodes intact"

summary
