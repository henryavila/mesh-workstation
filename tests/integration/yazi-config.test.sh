#!/usr/bin/env bash
# tests/integration/yazi-config.test.sh — first-writer-wins Yazi defaults.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME"

LINKER="$REPO_ROOT/topics/shell-terminal/link-yazi-config.sh"
THEME="$REPO_ROOT/topics/shell-terminal/configs/yazi/theme.toml"
YAZI_TOML="$REPO_ROOT/topics/shell-terminal/configs/yazi/yazi.toml"

assert_file_exists "$LINKER" "link-yazi-config.sh exists"
assert_file_exists "$THEME" "theme.toml exists"
assert_file_exists "$YAZI_TOML" "yazi.toml exists"
assert_file_contains "$THEME" 'use = "catppuccin-mocha"' "theme names catppuccin-mocha"
assert_file_contains "$YAZI_TOML" 'EDITOR:-nvim' "opener uses EDITOR nvim"
assert_file_contains "$YAZI_TOML" 'block = true' "edit opener is blocking"

warn() { :; }
ok() { :; }
# shellcheck source=/dev/null
source "$LINKER"
install
if [[ -L "$HOME/.config/yazi/yazi.toml" ]]; then
  pass "yazi.toml is a symlink"
else
  fail "yazi.toml is a symlink"
fi
if [[ -L "$HOME/.config/yazi/theme.toml" ]]; then
  pass "theme.toml is a symlink"
else
  fail "theme.toml is a symlink"
fi
assert_eq "$(readlink "$HOME/.config/yazi/yazi.toml")" "$YAZI_TOML" "yazi.toml points at workstation source"
install
assert_eq "$(readlink "$HOME/.config/yazi/yazi.toml")" "$YAZI_TOML" "second install is idempotent"

# First-writer-wins: existing regular file is left.
rm -f "$HOME/.config/yazi/yazi.toml"
printf 'user-override\n' > "$HOME/.config/yazi/yazi.toml"
install
if [[ -L "$HOME/.config/yazi/yazi.toml" ]]; then
  fail "existing file is not replaced with a symlink"
else
  pass "existing file is not replaced with a symlink"
fi
assert_file_contains "$HOME/.config/yazi/yazi.toml" 'user-override' "existing file contents kept"

FLAVOR="$REPO_ROOT/topics/shell-terminal/install-yazi-flavor.sh"
assert_file_exists "$FLAVOR" "flavor installer exists"
if grep -q 'ya pkg add yazi-rs/flavors:catppuccin-mocha' "$FLAVOR"; then
  pass "flavor installer calls ya pkg add catppuccin-mocha"
else
  fail "flavor installer missing ya pkg add catppuccin-mocha"
fi
if grep -q 'command -v ya' "$FLAVOR"; then
  pass "flavor installer no-ops when ya is missing"
else
  fail "flavor installer does not guard on ya"
fi

summary
