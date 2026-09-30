#!/usr/bin/env bash
# Integration test: mid-run Homebrew installation.
# Reproduces the virgin mac bootstrap bug:
# When Homebrew is not installed at the start of `install-engine.sh`, Item 1
# (foundation/base) installs it. Subsequent items in the SAME engine run
# (e.g. identity/gh-mac using type: brew-formula) must detect the newly
# installed Homebrew and have it on PATH / BREW_BIN, rather than failing with
# rc=127 (brew: command not found).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        passed=$((passed+1)); echo "  ✓ $name"
    else
        failed=$((failed+1)); echo "  ✗ $name (expected [$expected], got [$actual])" >&2
    fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
TD="$TMP/topics"
MOCK_BREW_PREFIX="$TMP/mock-homebrew"
mkdir -p "$TD/foundation" "$TD/identity" "$TMP/home" "$TMP/state" "$TMP/config"

# Topic 1: foundation/base installs Homebrew at MOCK_BREW_PREFIX
cat > "$TD/foundation/manifest.yaml" <<'YAML'
topic:
  label: "Foundation"
  order: 10
bundles:
  - name: base
    label: "Base"
    desc: "installs brew"
    items:
      - name: core-mac
        type: custom
        script: ./install-brew.sh
YAML

cat > "$TD/foundation/install-brew.sh" <<SH
check() { [[ -x "$MOCK_BREW_PREFIX/bin/brew" ]]; }
install() {
    mkdir -p "$MOCK_BREW_PREFIX/bin"
    cat > "$MOCK_BREW_PREFIX/bin/brew" <<'BREW_EOF'
#!/usr/bin/env bash
if [[ "\$1" == "--prefix" ]]; then
    printf '%s\n' "$MOCK_BREW_PREFIX"
    exit 0
fi
if [[ "\$1" == "list" ]]; then
    target="\${@: -1}"
    if [[ -f "$TMP/brew-installed.log" ]] && grep -q -F -e "\$target" "$TMP/brew-installed.log" 2>/dev/null; then
        exit 0
    fi
    exit 1
fi
if [[ "\$1" == "install" ]]; then
    echo "mock-brew installed: \$*" >> "$TMP/brew-installed.log"
    exit 0
fi
exit 0
BREW_EOF
    chmod +x "$MOCK_BREW_PREFIX/bin/brew"
    # Record state just like foundation/mac/core.sh does
    mkdir -p "$TMP/state"
    cat >> "$TMP/state/state.env" <<EOF
BREW_PREFIX="$MOCK_BREW_PREFIX"
BREW_PREFIX_DECISION_METHOD="env_var"
EOF
}
verify() { check; }
SH

# Topic 2: identity/gh-mac (type: brew-formula)
cat > "$TD/identity/manifest.yaml" <<'YAML'
topic:
  label: "Identity"
  order: 20
bundles:
  - name: identity
    label: "Identity"
    desc: "installs gh via brew-formula"
    items:
      - name: gh-mac
        type: brew-formula
        spec: gh
YAML

cat > "$TMP/selections.list" <<'EOF'
foundation/base
identity/identity
EOF

# Run the engine on platform mac with Homebrew NOT yet on disk or PATH
# We pass BREW_CUSTOM_PREFIX="$MOCK_BREW_PREFIX"
log_out="$TMP/engine.log"
/usr/bin/env -i \
    HOME="$TMP/home" \
    MESH_STATE_DIR="$TMP/state" \
    MESH_INSTALL_STATE_DIR="$TMP/state/installed" \
    BREW_CUSTOM_PREFIX="$MOCK_BREW_PREFIX" \
    DETECT_BREW_IGNORE_SYSTEM=1 \
    PATH=/usr/bin:/bin \
    bash "$ENGINE" \
        --topics-dir "$TD" \
        --platform mac \
        --selections "$TMP/selections.list" \
        --non-interactive > "$log_out" 2>&1
engine_rc=$?

assert "engine exits 0 when brew is installed mid-run" "0" "$engine_rc"

# Check log for the failure message
if grep -q "brew: command not found" "$log_out"; then
    echo "  ✗ Found 'brew: command not found' in engine log" >&2
    failed=$((failed+1))
else
    echo "  ✓ No 'brew: command not found' in engine log"
    passed=$((passed+1))
fi

if [[ -f "$TMP/brew-installed.log" ]] && grep -q "gh" "$TMP/brew-installed.log"; then
    echo "  ✓ mock-brew was invoked to install gh"
    passed=$((passed+1))
else
    echo "  ✗ mock-brew was NOT invoked to install gh" >&2
    failed=$((failed+1))
fi

echo
if [[ "$failed" -eq 0 ]]; then
    echo "engine-brew-mid-run: $passed passed"
    exit 0
else
    echo "engine-brew-mid-run: $failed FAILED, $passed passed" >&2
    echo "--- engine log ---" >&2
    cat "$log_out" >&2
    exit 1
fi
