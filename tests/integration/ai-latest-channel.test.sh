#!/usr/bin/env bash
# tests/integration/ai-latest-channel.test.sh
#
# Contract: mesh AI installers track the newest published release, not a
# pinned/stable/maintained channel. Setup stays skip-if-present (check());
# `mesh upgrade` / daily autoupdate actually moves the binary via update()
# or the npx/npm-global updater + autoupdate: true.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MANIFEST="$REPO_ROOT/topics/ai/manifest.yaml"
INSTALL_CLAUDE="$REPO_ROOT/topics/ai/install-claude.sh"
INSTALL_BUN="$REPO_ROOT/topics/ai/install-bun.sh"
PARSER="$REPO_ROOT/scripts/lib/yaml-parse.sh"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

assert_file_exists "$MANIFEST" "ai/manifest.yaml exists"
assert_file_exists "$INSTALL_CLAUDE" "install-claude.sh exists"
assert_file_exists "$INSTALL_BUN" "install-bun.sh exists"
assert_file_exists "$PARSER" "yaml-parse.sh exists"

TMP=$(mktemp -d -t ai-latest-channel.XXXXXX)
trap 'rm -rf "$TMP"' EXIT
bash "$PARSER" < "$MANIFEST" > "$TMP/parsed.env"
# shellcheck source=/dev/null
source "$TMP/parsed.env"

# Resolve BUNDLE_i_ITEM_j field for an item named $1. Prints the value of
# suffix $2 (e.g. AUTOUPDATE, SPEC, SCRIPT). Empty if the item is missing.
_item_field() {
    local want="$1" field="$2" i j n items name_var field_var
    n="${BUNDLE_COUNT:-0}"
    for i in $(seq 0 $((n - 1))); do
        items="BUNDLE_${i}_ITEM_COUNT"
        for j in $(seq 0 $(( ${!items:-0} - 1 ))); do
            name_var="BUNDLE_${i}_ITEM_${j}_NAME"
            if [[ "${!name_var:-}" == "$want" ]]; then
                field_var="BUNDLE_${i}_ITEM_${j}_${field}"
                printf '%s' "${!field_var:-}"
                return 0
            fi
        done
    done
    return 1
}

# ── Claude native installer: latest channel + update() ────────────────────
ASSERT_MSG="install-claude.sh install() passes the latest channel to the official installer" \
    assert_true "grep -qE 'bash[[:space:]]+-s[[:space:]]+(--[[:space:]]+)?latest' '$INSTALL_CLAUDE'"
ASSERT_MSG="install-claude.sh does not pass the stable/maintained channel" \
    assert_false "grep -qE 'bash[[:space:]]+-s[[:space:]]+(--[[:space:]]+)?stable' '$INSTALL_CLAUDE'"
ASSERT_MSG="install-claude.sh defines update() so mesh upgrade can move a stale CLI" \
    assert_true "grep -qE '^update\\(\\)' '$INSTALL_CLAUDE'"
assert_eq "$(_item_field claude-code-cli AUTOUPDATE)" "1" \
    "claude-code-cli is autoupdate: true (otherwise update() never runs)"

# ── Bun: update() so the claude-mem runtime does not freeze ───────────────
ASSERT_MSG="install-bun.sh defines update()" \
    assert_true "grep -qE '^update\\(\\)' '$INSTALL_BUN'"
assert_eq "$(_item_field bun AUTOUPDATE)" "1" \
    "bun is autoupdate: true"

# ── atomic-skills: unpinned @latest (1.7.0 was an explicit freeze) ────────
spec="$(_item_field atomic-skills SPEC)"
assert_contains "$spec" "@henryavila/atomic-skills@latest" \
    "atomic-skills spec tracks @latest"
assert_not_contains "$spec" "@1.7.0" \
    "atomic-skills spec is not pinned to 1.7.0"
assert_eq "$(_item_field atomic-skills AUTOUPDATE)" "1" \
    "atomic-skills is autoupdate: true"

# ── mdprobe + claude-mem: already @unpinned/@latest, but must autoupdate ──
assert_eq "$(_item_field mdprobe AUTOUPDATE)" "1" \
    "mdprobe is autoupdate: true (npm-global_update is a no-op without the flag)"
assert_eq "$(_item_field claude-mem AUTOUPDATE)" "1" \
    "claude-mem is autoupdate: true (npx_update re-runs @latest)"

# Already-correct leaf tools stay flagged (regression lock).
assert_eq "$(_item_field claudebar AUTOUPDATE)" "1" "claudebar stays autoupdate"
assert_eq "$(_item_field rtk AUTOUPDATE)" "1" "rtk stays autoupdate"

summary
