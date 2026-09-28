#!/usr/bin/env bash
# Unit tests for identity setup terminal hygiene and preflight
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        passed=$((passed+1)); echo "  ✓ $name"
    else
        failed=$((failed+1)); echo "  ✗ $name (expected: $expected, got: $actual)" >&2
    fi
}

SETUP_IDENTITY="$WS/topics/identity/scripts/setup-identity.sh"

# 1. Verify setup-identity.sh resets terminal state and drains /dev/tty
grep -q 'stty sane' "$SETUP_IDENTITY"
assert "setup-identity resets terminal with stty sane" "0" "$?"

grep -q 'read -r -t' "$SETUP_IDENTITY"
assert "setup-identity drains pending escape sequences from /dev/tty" "0" "$?"

# 2. Verify setup-identity.sh configures git credential helper prior to login to avoid prompt
grep -B 5 'gh auth login' "$SETUP_IDENTITY" | grep -q 'gh auth setup-git'
assert "setup-identity configures git credentials before gh auth login" "0" "$?"

# 3. Verify setup.sh detects brew and prepends to PATH
grep -A 8 'detect_brew_if_mac()' "$WS/setup.sh" | grep -q 'PATH=.*BREW_PREFIX/bin'
assert "setup.sh adds BREW_PREFIX/bin to PATH in detect_brew_if_mac" "0" "$?"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
