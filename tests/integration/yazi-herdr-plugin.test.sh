#!/usr/bin/env bash
# tests/integration/yazi-herdr-plugin.test.sh — herdr Yazi overlay plugin.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME" "$SANDBOX/bin"

PLUGIN="$REPO_ROOT/topics/shell-terminal/configs/herdr-plugin-yazi/herdr-plugin.toml"
INSTALLER="$REPO_ROOT/topics/shell-terminal/install-herdr-yazi-plugin.sh"

assert_file_exists "$PLUGIN" "herdr-plugin.toml exists"
assert_file_exists "$INSTALLER" "plugin installer exists"
assert_file_contains "$PLUGIN" 'id = "mesh.yazi"' "plugin id is mesh.yazi"
assert_file_contains "$PLUGIN" 'id = "picker"' "pane entrypoint is picker"
assert_file_contains "$PLUGIN" 'placement = "overlay"' "default placement is overlay"
assert_file_contains "$PLUGIN" 'yazi-choose' "pane command is yazi-choose"
assert_file_contains "$INSTALLER" 'herdr plugin link' "installer links the plugin"

# Isolate PATH so the host herdr is never invoked.
export PATH="$SANDBOX/bin:/bin:/usr/bin"
hash -r 2>/dev/null || true
# shellcheck source=/dev/null
source "$INSTALLER"
if install; then
  pass "installer no-ops when herdr is missing"
else
  fail "installer no-ops when herdr is missing"
fi

# With stub herdr, installer calls plugin link on the source dir.
export HERDR_LOG="$SANDBOX/herdr.log"
: > "$HERDR_LOG"
cat > "$SANDBOX/bin/herdr" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${HERDR_LOG:?}"
exit 0
EOF
chmod +x "$SANDBOX/bin/herdr"
hash -r 2>/dev/null || true
install
assert_contains "$(cat "$HERDR_LOG")" "plugin link" "installer runs herdr plugin link"
assert_contains "$(cat "$HERDR_LOG")" "configs/herdr-plugin-yazi" "link path is the shipped plugin dir"

summary
