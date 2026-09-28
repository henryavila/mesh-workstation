#!/usr/bin/env bash
# Exercise the post-install notice through the real custom driver and summary.
set -uo pipefail
WS="$(cd "$(dirname "$0")/../.." && pwd)"
. "$WS/scripts/lib/log.sh"
. "$WS/scripts/lib/installers/custom.sh"
. "$WS/tests/lib/assert.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" MESH_FOLLOWUP_FILE="$TMP/followups"
mkdir -p "$HOME/.atuin/bin" "$TMP/bin"
cat > "$HOME/.atuin/bin/atuin" <<'SH'
#!/usr/bin/env bash
echo "Unexpected credential access" >&2
echo "$*" >> "$HOME/atuin-calls"
exit 99
SH
chmod +x "$HOME/.atuin/bin/atuin"
SCRIPT="$WS/topics/shell-terminal/atuin-key-guidance.sh"
assert_file_exists "$SCRIPT" "post-install guidance exists"
[[ -f "$SCRIPT" ]] || { summary; exit 1; }

# Verify delivery through the real manifest, including CLI-only installs.
parsed="$(bash "$WS/scripts/lib/yaml-parse.sh" < "$WS/topics/shell-terminal/manifest.yaml")" || exit 1
eval "$parsed"
found=0
for ((b=0; b<BUNDLE_COUNT; b++)); do
    name="BUNDLE_${b}_NAME"
    [[ "${!name}" == cli-tools ]] || continue
    count="BUNDLE_${b}_ITEM_COUNT"
    mac=-1 wsl=-1
    for ((i=0; i<${!count}; i++)); do
        prefix="BUNDLE_${b}_ITEM_${i}"
        name="${prefix}_NAME"
        case "${!name}" in
            atuin-mac) mac=$i ;;
            atuin-wsl) wsl=$i ;;
            atuin-key-guidance)
                found=1
                assert_eq "$((mac >= 0 && wsl >= 0 && i > mac && i > wsl))" 1 'notice follows both platform installers'
                field="${prefix}_IDEMPOTENT"
                assert_eq "${!field:-0}" 1 'notice runs even when Atuin was already installed'
                field="${prefix}_PLATFORMS_COUNT"
                assert_eq "${!field:-0}" 0 'notice applies to both platforms'
                field="${prefix}_SCRIPT"
                assert_eq "${!field}" './atuin-key-guidance.sh' 'manifest invokes tested notice'
                ;;
        esac
    done
done
assert_eq "$found" 1 'CLI-only installs include the notice'

for mode in interactive non-interactive opted-out; do
    export MESH_NO_MESH=0 NON_INTERACTIVE=0 ATUIN_LOGIN_AUTO=1
    [[ "$mode" == non-interactive ]] && NON_INTERACTIVE=1
    [[ "$mode" == opted-out ]] && ATUIN_LOGIN_AUTO=0
    : > "$MESH_FOLLOWUP_FILE"
    rc=0
    out="$(custom_install "$SCRIPT" 2>&1)" || rc=$?
    assert_eq "$rc" 0 "$mode: guidance succeeds with WSL binary outside PATH"
    assert_contains "$out" 'atuin key' "$mode: shows recovery command"
    assert_contains "$out" 'Keeper' "$mode: explains password-manager backup"
    assert_contains "$out" 'already syncs' "$mode: identifies the existing machine"
    summary_out="$(render_followup_summary 2>&1)"
    assert_contains "$summary_out" 'atuin key' "$mode: guidance survives into final summary"
done

export MESH_NO_MESH=1
: > "$MESH_FOLLOWUP_FILE"
assert_eq "$(custom_install "$SCRIPT" 2>&1)" '' 'no-mesh does not prompt for sync credentials'
assert_eq "$(cat "$MESH_FOLLOWUP_FILE")" '' 'no-mesh queues no follow-up'
export MESH_NO_MESH=0
# Simulate a macOS/PATH installation instead of the WSL fallback.
mv "$HOME/.atuin/bin/atuin" "$TMP/bin/atuin"
export PATH="$TMP/bin:/usr/bin:/bin"
assert_contains "$(custom_install "$SCRIPT" 2>&1)" 'Keeper' 'PATH-installed Atuin receives guidance'
rm "$TMP/bin/atuin"
assert_eq "$(custom_install "$SCRIPT" 2>&1)" '' 'failed or absent Atuin install emits no misleading notice'
assert_eq "$(test -e "$HOME/atuin-calls" && echo called || echo untouched)" untouched 'guidance never invokes Atuin or reads credentials'
summary
