#!/usr/bin/env bash
# tests/deploy-smoke.sh — smoke test for lib/deploy.sh.
#
# Run: bash tests/deploy-smoke.sh
#
# Exercises the three behaviors that the 30-shell regression taught us to
# care about:
#   1. .template files pass through envsubst with ${BREW_PREFIX} allowlist
#      entry properly substituted on this machine.
#   2. Destinations without the "managed by mesh-workstation" marker are
#      backed up and replaced. Extra lines land in the matching *.local file.
#   3. Templates or DEPLOY entries with .local suffix are refused.
#
# Design: all fixtures live in a temp dir. $HOME is redirected to a fake
# one so nothing outside the tmpdir is ever touched. envsubst is the only
# external dependency (matches deploy.sh's hard requirement).
#
# Exit code: 0 on all tests pass, 1 otherwise.

set -euo pipefail

# ---------- Harness ----------

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
DEPLOY_SH="$REPO_ROOT/scripts/lib/deploy.sh"

if [[ ! -f "$DEPLOY_SH" ]]; then
    echo "FAIL: deploy.sh not found at $DEPLOY_SH" >&2
    exit 1
fi
if ! command -v envsubst >/dev/null 2>&1; then
    echo "SKIP: envsubst not available (install gettext)" >&2
    exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass_count=0
fail_count=0
assert() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  ✓ $label"
        pass_count=$((pass_count + 1))
    else
        echo "  ✗ $label — expected: $expected, got: $actual"
        fail_count=$((fail_count + 1))
    fi
}
assert_file_contains() {
    local label="$1" file="$2" needle="$3"
    if [[ -f "$file" ]] && grep -qF "$needle" "$file"; then
        echo "  ✓ $label"
        pass_count=$((pass_count + 1))
    else
        echo "  ✗ $label — '$needle' not found in $file"
        [[ -f "$file" ]] && echo "    (file exists, head:)" && head -5 "$file"
        fail_count=$((fail_count + 1))
    fi
}

# Each test gets its own templates/ + fake HOME
new_fixture() {
    local name="$1"
    local dir="$work/$name"
    mkdir -p "$dir/templates" "$dir/home"
    printf '%s\n' "$dir"
}

# ---------- Test 1: envsubst ${BREW_PREFIX} substitution ----------

echo "Test 1: envsubst \${BREW_PREFIX} in .template files"
fx1="$(new_fixture test1)"
cat > "$fx1/templates/bashrc.template" <<'TPL'
# ~/.bashrc — managed by mesh-workstation / test
__prefix='${BREW_PREFIX}'
echo "$__prefix"
TPL

export HOME="$fx1/home"
export BREW_PREFIX="/Volumes/External/homebrew"
# Clear other allowlist vars to ensure isolation
export CODE_DIR="" NGINX_CONF_DIR="" MESH_IDENTITY_DIR=""

if bash "$DEPLOY_SH" "$fx1/templates" >"$fx1/log" 2>&1; then
    assert_file_contains "bashrc deployed to fake HOME" \
        "$HOME/.bashrc" "managed by mesh-workstation"
    assert_file_contains "BREW_PREFIX substituted correctly" \
        "$HOME/.bashrc" "__prefix='/Volumes/External/homebrew'"
else
    echo "  ✗ deploy.sh failed unexpectedly"
    cat "$fx1/log"
    fail_count=$((fail_count + 1))
fi

# ---------- Test 2: empty BREW_PREFIX degrades gracefully ----------

echo
echo "Test 2: empty BREW_PREFIX produces empty string (Linux without brew)"
fx2="$(new_fixture test2)"
cat > "$fx2/templates/bashrc.template" <<'TPL'
# ~/.bashrc — managed by mesh-workstation / test
__prefix='${BREW_PREFIX}'
TPL

export HOME="$fx2/home"
unset BREW_PREFIX
export BREW_PREFIX=""

if bash "$DEPLOY_SH" "$fx2/templates" >"$fx2/log" 2>&1; then
    assert_file_contains "empty prefix produces __prefix=''" \
        "$HOME/.bashrc" "__prefix=''"
else
    echo "  ✗ deploy.sh failed unexpectedly"
    cat "$fx2/log"
    fail_count=$((fail_count + 1))
fi

# ---------- Test 3: backup and replace an unmanaged file ----------

echo
echo "Test 3: unmanaged rc is backed up, replaced, and extra lines are preserved"
fx3="$(new_fixture test3)"
cat > "$fx3/templates/bashrc.template" <<'TPL'
# ~/.bashrc — managed by mesh-workstation / test
new_content=yes
TPL

export HOME="$fx3/home"
# Pre-create a user's handcrafted .bashrc without the marker
cat > "$HOME/.bashrc" <<'USER'
# User's handwritten .bashrc
export PATH="/custom/path:$PATH"
USER

unset ALLOW_OVERWRITE_UNMANAGED
if bash "$DEPLOY_SH" "$fx3/templates" >"$fx3/log" 2>&1; then
    rc=$?
    assert "deploy.sh exited zero" "0" "$rc"
    assert_file_contains "managed file installed" \
        "$HOME/.bashrc" "new_content=yes"
    backup_count="$(ls "$HOME"/.bashrc.bak-* 2>/dev/null | wc -l | tr -d '[:space:]')"
    assert "one backup created" "1" "$backup_count"
    backup_file="$(ls "$HOME"/.bashrc.bak-* | head -1)"
    assert_file_contains "backup keeps the previous file" \
        "$backup_file" "User's handwritten .bashrc"
    assert_file_contains "extra line preserved in bashrc.local" \
        "$HOME/.bashrc.local" 'export PATH="/custom/path:$PATH"'
else
    echo "  ✗ deploy.sh failed on unmanaged .bashrc"
    cat "$fx3/log"
    fail_count=$((fail_count + 1))
fi

# ---------- Test 4: ALLOW_OVERWRITE_UNMANAGED escape hatch ----------

echo
echo "Test 4: ALLOW_OVERWRITE_UNMANAGED=1 allows overwrite + creates backup"
fx4="$(new_fixture test4)"
cat > "$fx4/templates/bashrc.template" <<'TPL'
# ~/.bashrc — managed by mesh-workstation / test
new_content=yes
TPL

export HOME="$fx4/home"
cat > "$HOME/.bashrc" <<'USER'
# User's handwritten .bashrc
USER

ALLOW_OVERWRITE_UNMANAGED=1 bash "$DEPLOY_SH" "$fx4/templates" >"$fx4/log" 2>&1
rc=$?
assert "deploy.sh succeeded with escape hatch" "0" "$rc"
assert_file_contains "new content deployed" "$HOME/.bashrc" "new_content=yes"
# Backup should exist. BSD wc pads with spaces; normalize for bash 3.2/macOS.
backup_count="$(ls "$HOME"/.bashrc.bak-* 2>/dev/null | wc -l | tr -d '[:space:]')"
assert "one backup created" "1" "$backup_count"
unset ALLOW_OVERWRITE_UNMANAGED

# ---------- Test 5: refuse .local template ----------

echo
echo "Test 5: refuse templates with .local suffix"
fx5="$(new_fixture test5)"
cat > "$fx5/templates/bashrc.local" <<'TPL'
# Should never be deployed
TPL

export HOME="$fx5/home"
if bash "$DEPLOY_SH" "$fx5/templates" >"$fx5/log" 2>&1; then
    echo "  ✗ expected deploy.sh to REFUSE .local template"
    fail_count=$((fail_count + 1))
else
    rc=$?
    assert "deploy.sh exited non-zero on .local template" "1" "$rc"
    # The message used to say "with .local suffix/path" — tightened
    # to "with .local-suffix filename" after the basename-based refactor
    # (see tests/unit/deploy-local-suffix.test.sh). Accept either phrasing.
    if grep -qE "with \.local[- ]suffix" "$fx5/log"; then
        echo "  ✓ refuse-.local message emitted"
        pass_count=$((pass_count + 1))
    else
        echo "  ✗ refuse-.local message missing"
        cat "$fx5/log"
        fail_count=$((fail_count + 1))
    fi
fi

# ---------- Test 6: fragments in .bashrc.d/ bypass header check ----------

echo
echo "Test 6: .bashrc.d/ fragments overwrite without marker check"
fx6="$(new_fixture test6)"
cat > "$fx6/templates/bashrc.d-30-shell.sh.template" <<'TPL'
# New fragment content (no marker needed for .d/ files)
TPL

export HOME="$fx6/home"
mkdir -p "$HOME/.bashrc.d"
# Pre-existing fragment without marker (represents legacy state)
cat > "$HOME/.bashrc.d/30-shell.sh" <<'OLD'
old_fragment_content=yes
OLD

if bash "$DEPLOY_SH" "$fx6/templates" >"$fx6/log" 2>&1; then
    assert_file_contains "fragment overwritten despite no marker" \
        "$HOME/.bashrc.d/30-shell.sh" "New fragment content"
else
    echo "  ✗ deploy.sh failed on .bashrc.d/ fragment overwrite"
    cat "$fx6/log"
    fail_count=$((fail_count + 1))
fi

# ---------- Test 7: prune_backups keeps 5 newest + oldest ----------

echo
echo "Test 7: prune_backups retains 5 newest + 1 oldest (8 backups → 6)"
fx7="$(new_fixture test7)"
cat > "$fx7/templates/bashrc.template" <<'TPL'
# ~/.bashrc — managed by mesh-workstation / test
version_9=yes
TPL

export HOME="$fx7/home"
# Pre-existing .bashrc with marker (so overwrite proceeds cleanly)
printf '# managed by mesh-workstation\noriginal=yes\n' > "$HOME/.bashrc"
# 8 pre-existing backups with ascending mtime
for i in 1 2 3 4 5 6 7 8; do
    ts="20260420-0${i}0000"
    touch -d "2026-04-20 0${i}:00:00" "$HOME/.bashrc.bak-${ts}"
done

bash "$DEPLOY_SH" "$fx7/templates" >"$fx7/log" 2>&1 || true

# After deploy: one new backup created (.bak-<now>), plus prune run.
# Expected: 5 newest (new + 4 old) + 1 oldest = 6 total + new file-count = 7?
# Actually deploy creates ONE new backup, then prune_backups is called which
# keeps 5 newest + oldest. With 9 total (8 + 1 new), prune keeps 6.
final_count="$(ls "$HOME"/.bashrc.bak-* 2>/dev/null | wc -l | tr -d '[:space:]')"
assert "prune left 6 backups" "6" "$final_count"
# Oldest (-010000) should survive
if [[ -f "$HOME/.bashrc.bak-20260420-010000" ]]; then
    echo "  ✓ oldest backup preserved"
    pass_count=$((pass_count + 1))
else
    echo "  ✗ oldest backup deleted"
    fail_count=$((fail_count + 1))
fi

# ---------- Test 8: real 30-shell brew loop works under bash AND zsh ----------

echo
echo "Test 8: deployed .bashrc/.zshrc brew loop iterates correctly (bash + zsh if available)"
fx8="$(new_fixture test8)"
# Fake brew binary: prints a shellenv that sets a sentinel var
mkdir -p "$fx8/fake-brew/bin"
cat > "$fx8/fake-brew/bin/brew" <<'STUB'
#!/bin/sh
case "$1" in
    shellenv)
        echo 'export HOMEBREW_PREFIX="'"$(cd "$(dirname "$0")"/.. && pwd)"'"'
        echo 'export HOMEBREW_PREFIX_LOADED_BY_TEST=yes'
        ;;
esac
STUB
chmod +x "$fx8/fake-brew/bin/brew"

# Use the real repo templates (not synthetic) to catch actual template bugs
cp "$REPO_ROOT/topics/shell-terminal/templates/zsh/bashrc.template" "$fx8/templates/"
cp "$REPO_ROOT/topics/shell-terminal/templates/zsh/zshrc.template" "$fx8/templates/"

export HOME="$fx8/home"
export BREW_PREFIX="$fx8/fake-brew"
export CODE_DIR="" NGINX_CONF_DIR="" MESH_IDENTITY_DIR=""

bash "$DEPLOY_SH" "$fx8/templates" >"$fx8/log" 2>&1 || {
    echo "  ✗ deploy.sh failed"
    cat "$fx8/log"
    fail_count=$((fail_count + 1))
}

# Source the deployed .bashrc in a fresh bash and check the sentinel.
# shellcheck disable=SC2034 # read via $probe_bashrc later in this file
probe_bashrc=$(bash --norc -c "
    unset HOMEBREW_PREFIX HOMEBREW_PREFIX_LOADED_BY_TEST
    HOME='$HOME'
    # Skip the 'if not interactive return' guard by forcing -i
    source '$HOME/.bashrc' 2>/dev/null
    echo \"\$HOMEBREW_PREFIX_LOADED_BY_TEST\"
" 2>/dev/null || true)
# Note: .bashrc has `case \$- in *i*) ;; *) return ;; esac` — non-interactive
# sourcing returns early. We bypass this by using bash -i in a subprocess.
probe_bashrc_interactive=$(bash -ic "
    echo \"MARKER=\$HOMEBREW_PREFIX_LOADED_BY_TEST\"
" 2>/dev/null </dev/null || true)
# Bash -i sources /etc/bash.bashrc which may emit WSL noise etc.
# We prefixed our echo with MARKER= to find our specific line.
probe_bashrc_interactive="$(echo "$probe_bashrc_interactive" | grep -oE 'MARKER=[a-z]*' | head -1 | sed 's/MARKER=//')"
if [[ "$probe_bashrc_interactive" == "yes" ]]; then
    echo "  ✓ bash loop evaluated brew shellenv (fake brew at BREW_PREFIX)"
    pass_count=$((pass_count + 1))
else
    echo "  ✗ bash did NOT eval brew shellenv — word-splitting bug?"
    echo "    probe output: [$probe_bashrc_interactive]"
    echo "    .bashrc snippet:"
    grep -n -A 10 '__bootstrap_brew_prefix' "$HOME/.bashrc" | head -12
    fail_count=$((fail_count + 1))
fi

# If zsh is available, run the same check under zsh (catches bash-only patterns)
if command -v zsh >/dev/null 2>&1; then
    probe_zshrc=$(zsh -c "
        source '$HOME/.zshrc' 2>/dev/null
        echo \"MARKER=\$HOMEBREW_PREFIX_LOADED_BY_TEST\"
    " 2>/dev/null || true)
    probe_zshrc="$(echo "$probe_zshrc" | grep -oE 'MARKER=[a-z]*' | head -1 | sed 's/MARKER=//')"
    if [[ "$probe_zshrc" == "yes" ]]; then
        echo "  ✓ zsh loop evaluated brew shellenv"
        pass_count=$((pass_count + 1))
    else
        echo "  ✗ zsh did NOT eval brew shellenv (regression of the zsh word-split bug)"
        echo "    probe output: [$probe_zshrc]"
        fail_count=$((fail_count + 1))
    fi
else
    echo "  – zsh not installed; skipping zsh-specific check"
fi

# Also guard-rail: refuse the old word-split pattern in the deployed files
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    if grep -qE 'for brew in \$__brew_candidates' "$rc" 2>/dev/null; then
        echo "  ✗ $rc still uses word-splitting pattern (not zsh-safe)"
        fail_count=$((fail_count + 1))
    fi
done

# ---------- Summary ----------

echo
echo "=== summary ==="
echo "  passed: $pass_count"
echo "  failed: $fail_count"

if [[ "$fail_count" -gt 0 ]]; then
    exit 1
fi
exit 0
