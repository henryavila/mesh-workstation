#!/usr/bin/env bash
# tests/integration/yazi-wrapper.test.sh — y() cwd-on-quit vs multiplexer passthrough.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME" "$SANDBOX/bin" "$SANDBOX/newdir"

FRAGMENT="$REPO_ROOT/topics/shell-terminal/templates/cli-tools/zshrc.d-20-terminal-ux.sh.template"
CHOOSER="$REPO_ROOT/topics/shell-terminal/templates/cli-tools/bin/yazi-choose"

assert_file_exists "$FRAGMENT" "zsh fragment exists"
assert_file_exists "$CHOOSER" "yazi-choose helper exists"
assert_file_contains "$FRAGMENT" 'completion.zsh is NOT' "fzf completion.zsh stays unsourced"
assert_file_contains "$FRAGMENT" ':fzf-tab:complete' "fzf-tab preview zstyles remain"
if grep -vE '^\s*#' "$FRAGMENT" | grep -q "bindkey '^I'"; then
  fail "fragment rebound TAB"
else
  pass "fragment does not bind TAB"
fi
if grep -q 'completion.zsh' "$FRAGMENT" && grep -q 'source' <<<"$(grep completion.zsh "$FRAGMENT")"; then
  if grep -q 'is NOT sourced' "$FRAGMENT"; then
    pass "completion.zsh mention is the skip comment"
  else
    fail "fragment sources completion.zsh"
  fi
else
  pass "fragment does not source completion.zsh"
fi

awk '/^y\(\) \{/,/^}$/' "$FRAGMENT" > "$SANDBOX/y.fn"
assert_file_contains "$SANDBOX/y.fn" 'HERDR_ENV' "y() guards HERDR_ENV"
# shellcheck source=/dev/null
source "$SANDBOX/y.fn"
if declare -F y >/dev/null; then
  pass "y function is defined"
else
  fail "y function is defined"
fi

cat > "$SANDBOX/bin/yazi" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${YAZI_ARGV_LOG:?}"
for arg in "$@"; do
  case "$arg" in
    --cwd-file=*)
      printf '%s\n' "${YAZI_CD_TARGET:?}" > "${arg#--cwd-file=}"
      ;;
    --chooser-file=*)
      printf '%s\n' "/tmp/picked.txt" > "${arg#--chooser-file=}"
      ;;
  esac
done
exit 0
EOF
chmod +x "$SANDBOX/bin/yazi" "$CHOOSER"
export PATH="$SANDBOX/bin:$PATH"
export YAZI_ARGV_LOG="$SANDBOX/yazi.argv"
export YAZI_CD_TARGET="$SANDBOX/newdir"

# Bare shell: --cwd-file and cd.
unset HERDR_ENV TUIOS_SESSION
: > "$YAZI_ARGV_LOG"
pushd "$SANDBOX" >/dev/null
y
got_cwd="$PWD"
popd >/dev/null
assert_contains "$(cat "$YAZI_ARGV_LOG")" "--cwd-file=" "bare y passes --cwd-file"
assert_eq "$got_cwd" "$SANDBOX/newdir" "bare y cds to cwd-file path"

# HERDR_ENV: passthrough, no cwd-file, no cd.
export HERDR_ENV=1
: > "$YAZI_ARGV_LOG"
pushd "$SANDBOX" >/dev/null
y
got_cwd="$PWD"
popd >/dev/null
assert_not_contains "$(cat "$YAZI_ARGV_LOG")" "--cwd-file=" "HERDR_ENV y omits --cwd-file"
assert_eq "$got_cwd" "$SANDBOX" "HERDR_ENV y does not cd"
unset HERDR_ENV

# TUIOS_SESSION: same passthrough.
export TUIOS_SESSION=web
: > "$YAZI_ARGV_LOG"
y >/dev/null
assert_not_contains "$(cat "$YAZI_ARGV_LOG")" "--cwd-file=" "TUIOS_SESSION y omits --cwd-file"
unset TUIOS_SESSION

# yazi-choose uses --chooser-file and prints the pick.
picked="$("$CHOOSER")"
assert_eq "$picked" "/tmp/picked.txt" "yazi-choose prints chooser-file contents"
assert_contains "$(cat "$YAZI_ARGV_LOG")" "--chooser-file=" "yazi-choose passes --chooser-file"

summary
