#!/usr/bin/env bash
# Soft_fail installers must bound every curl download (Issue 3 review).
# Asserts --connect-timeout and --max-time on curl lines in the capped scripts.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: [$expected], got: [$actual])" >&2; fi
}

SCRIPTS=(
    "$WS/topics/shell-terminal/wsl/install-starship.sh"
    "$WS/topics/shell-terminal/wsl/install-lazygit.sh"
    "$WS/topics/shell-terminal/wsl/install-delta.sh"
    "$WS/topics/shell-terminal/wsl/install-rust-bins.sh"
    "$WS/topics/shell-terminal/wsl/install-atuin.sh"
    "$WS/topics/shell-terminal/install-zinit.sh"
    "$WS/topics/ai/install-rtk.sh"
)

for script in "${SCRIPTS[@]}"; do
    rel="${script#"$WS/"}"
    assert "$rel exists" "yes" "$([[ -f "$script" ]] && echo yes || echo no)"

    # Every non-comment curl *invocation* must carry both bound flags.
    unbound=0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        # Require a real argv form (curl -… / curl --…), not the word in a string.
        [[ "$line" =~ (^|[^[:alnum:]_])curl[[:space:]]+- ]] || continue
        if ! grep -q -- '--connect-timeout' <<<"$line" \
            || ! grep -q -- '--max-time' <<<"$line"; then
            unbound=$((unbound + 1))
            echo "    unbound curl: $line" >&2
        fi
    done < <(grep -E 'curl[[:space:]]+-' "$script" || true)

    assert "$rel: all curl lines bounded" "0" "$unbound"

    assert "$rel: has --connect-timeout 8" "yes" \
        "$(grep -qE -- '--connect-timeout[[:space:]]+8' "$script" && echo yes || echo no)"
    assert "$rel: has --max-time 45" "yes" \
        "$(grep -qE -- '--max-time[[:space:]]+45' "$script" && echo yes || echo no)"
done

echo
echo "Passed: $passed  Failed: $failed"
[[ "$failed" -eq 0 ]]
