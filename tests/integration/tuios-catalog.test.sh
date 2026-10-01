#!/usr/bin/env bash
# TUIOS is an optional remote-access bundle; a new identity has no host data.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"

MANIFEST="$ROOT/topics/remote-access/manifest.yaml"
PROFILE="$ROOT/template/config/tuios-hosts.json.example"
PARSED="$(bash "$ROOT/scripts/lib/yaml-parse.sh" < "$MANIFEST")" || exit 2
eval "$PARSED"

bundle_index() {
    local wanted="$1" i name
    for ((i=0; i<${BUNDLE_COUNT:-0}; i++)); do
        eval "name=\${BUNDLE_${i}_NAME:-}"
        if [[ "$name" == "$wanted" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

for bundle in tuios tuios-cloudflare; do
    idx="$(bundle_index "$bundle")" || idx=""
    assert_ne "$idx" "" "remote-access/$bundle is listed"
    if [[ -n "$idx" ]]; then
        default="BUNDLE_${idx}_DEFAULT_SELECTED"
        assert_eq "${!default:-}" "0" "$bundle is opt-in"
    fi
done

idx="$(bundle_index tuios-cloudflare)" || idx=""
if [[ -n "$idx" ]]; then
    dep="BUNDLE_${idx}_REQUIRES_BUNDLES_0"
    assert_eq "${!dep:-}" "remote-access/tuios" "publication requires local TUIOS"
fi

idx="$(bundle_index tuios)" || idx=""
if [[ -n "$idx" ]]; then
    systemd_item=""
    binary_item=""
    count_var="BUNDLE_${idx}_ITEM_COUNT"
    for ((j=0; j<${!count_var:-0}; j++)); do
        item_var="BUNDLE_${idx}_ITEM_${j}_NAME"
        if [[ "${!item_var:-}" == systemd-wsl ]]; then systemd_item="$j"; break; fi
    done
    assert_ne "$systemd_item" "" "TUIOS WSL bundle prepares persistent systemd"
    for ((j=0; j<${!count_var:-0}; j++)); do
        item_var="BUNDLE_${idx}_ITEM_${j}_NAME"
        if [[ "${!item_var:-}" == tuios-binaries ]]; then binary_item="$j"; break; fi
    done
    update_var="BUNDLE_${idx}_ITEM_${binary_item}_AUTOUPDATE"
    assert_eq "${!update_var:-0}" "0" "stateful daemon binaries do not autoupdate during work"
fi

if [[ -f "$PROFILE" ]]; then
    pass "new-identity profile exists"
    assert_eq "$(jq -er '.schema == 1 and (.hosts | type == "object" and length == 0)' "$PROFILE" 2>/dev/null)" "true" "profile has an empty host map"
    ASSERT_MSG="template has no current operator hostname or email" \
        assert_false "grep -qE 'henryavila|velvet-otter|crc' '$PROFILE'"
else
    fail "new-identity profile exists"
fi

summary
