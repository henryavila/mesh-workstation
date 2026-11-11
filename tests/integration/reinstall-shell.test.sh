#!/usr/bin/env bash
# tests/integration/reinstall-shell.test.sh
#
# Contract for `mesh reinstall shell`:
#   - allowlist is the shell layer only (no PHP/web/db/docker/node)
#   - unmanaged ~/.zshrc / ~/.bashrc does not block; deploy backs it up
#   - empty / mesh-marked rc files are allowed
#   - ~/.config/mesh/selections.list is never rewritten
#   - engine is called as a normal apply (not --repair / --update / --adopt)
#   - --dry-run prints the plan and does not apply
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

LIB="$WS/scripts/lib/reinstall-shell.sh"
RUNNER="$WS/scripts/runners/reinstall.sh"
MODULE="$WS/scripts/commands/reinstall.sh"

SANDBOX="$(mktemp -d -t mesh-reinstall-shell.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

assert_file_exists "$LIB" "reinstall-shell lib exists"
assert_file_exists "$RUNNER" "reinstall runner exists"
assert_file_exists "$MODULE" "reinstall command module exists"

# shellcheck disable=SC1090
source "$LIB"

echo "── allowlist is the approved shell layer ──"
bundles="$(reinstall_shell_bundles)"
for want in \
    foundation/base \
    git/config \
    git/lazygit \
    shell-terminal/cli-tools \
    shell-terminal/zsh \
    shell-terminal/tmux \
    shell-terminal/nvim \
    shell-terminal/fonts
do
    assert_contains "$bundles" "$want" "allowlist includes $want"
done

while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -n "$line" ]] || continue
    case "$line" in
        foundation/base|git/config|git/lazygit|shell-terminal/*) ;;
        *) fail "allowlist leaked unexpected bundle: $line" ;;
    esac
done <<< "$bundles"

for forbidden in \
    web/valet \
    web/nginx-php-fpm \
    databases/mysql \
    databases/postgresql \
    languages/php \
    languages/node \
    containers/docker \
    personal/personal \
    identity/identity \
    syncthing/syncthing \
    ai/claude-code
do
    assert_not_contains "$bundles" "$forbidden" "allowlist excludes $forbidden"
done

echo
echo "── command help ──"
help_out="$(bash "$RUNNER" --help 2>&1)"
help_rc=$?
assert_eq "$help_rc" "0" "reinstall --help exits 0"
assert_contains "$help_out" "mesh reinstall shell" "help names mesh reinstall shell"
assert_contains "$help_out" "PHP" "help says it does not touch PHP"
assert_contains "$help_out" "selections.list" "help says it does not rewrite selections.list"

echo
echo "── unknown target is refused ──"
set +e
unknown_out="$(bash "$RUNNER" dx 2>&1)"
unknown_rc=$?
set -e
assert_ne "$unknown_rc" "0" "unknown target exits non-zero"
assert_contains "$unknown_out" "shell" "unknown target points at shell"

# ── sandbox HOME / XDG ─────────────────────────────────────────────
HOME_SANDBOX="$SANDBOX/home"
CFG="$SANDBOX/config"
TRACE="$SANDBOX/engine.trace"
FAKE_ENGINE="$SANDBOX/fake-engine.sh"
mkdir -p "$HOME_SANDBOX" "$CFG/mesh"
printf '%s\n' 'languages/php' 'web/valet' 'databases/mysql' > "$CFG/mesh/selections.list"
cp "$CFG/mesh/selections.list" "$SANDBOX/selections.before"

cat > "$FAKE_ENGINE" <<'SH'
#!/usr/bin/env bash
trace="${MESH_REINSTALL_ENGINE_TRACE:?}"
printf 'argv:%s\n' "$*" >> "$trace"
i=0
while (( i < $# )); do
    i=$((i + 1))
    eval "arg=\${$i}"
    if [[ "$arg" == "--repair" || "$arg" == "--update" || "$arg" == "--adopt" || "$arg" == "--health" ]]; then
        printf 'forbidden-mode:%s\n' "$arg" >> "$trace"
    fi
    if [[ "$arg" == "--selections" ]]; then
        i=$((i + 1))
        eval "sel=\${$i}"
        printf 'selections-file:%s\n' "$sel" >> "$trace"
        if [[ -f "$sel" ]]; then
            printf 'selections-body:\n' >> "$trace"
            cat "$sel" >> "$trace"
        fi
    fi
    if [[ "$arg" == "--bundle" ]]; then
        i=$((i + 1))
        eval "b=\${$i}"
        printf 'bundle:%s\n' "$b" >> "$trace"
    fi
done
printf 'applied\n' >> "$trace"
exit "${MESH_TEST_ENGINE_RC:-0}"
SH
chmod +x "$FAKE_ENGINE"

run_reinstall() {
    HOME="$HOME_SANDBOX" \
        XDG_CONFIG_HOME="$CFG" \
        MESH_REINSTALL_ENGINE="$FAKE_ENGINE" \
        MESH_REINSTALL_ENGINE_TRACE="$TRACE" \
        MESH_WORKSTATION_DIR="$WS" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        NO_COLOR=1 \
        bash "$RUNNER" "$@"
}

echo
echo "── unmanaged zshrc does not block; engine is invoked ──"
printf '# oh-my-zsh leftover\nexport ZSH="$HOME/.oh-my-zsh"\n' > "$HOME_SANDBOX/.zshrc"
: > "$TRACE"
set +e
refuse_out="$(run_reinstall shell 2>&1)"
refuse_rc=$?
set -e
assert_eq "$refuse_rc" "0" "unmanaged zshrc does not block reinstall"
assert_contains "$refuse_out" "shell-terminal/zsh" "reinstall lists the zsh bundle"
assert_true "grep -q '^applied$' '$TRACE'"
assert_eq "$(cat "$CFG/mesh/selections.list")" "$(cat "$SANDBOX/selections.before")" \
    "reinstall does not rewrite selections.list"

echo
echo "── empty zshrc is unowned and may proceed ──"
: > "$HOME_SANDBOX/.zshrc"
: > "$HOME_SANDBOX/.bashrc"
: > "$TRACE"
set +e
empty_out="$(run_reinstall --dry-run shell 2>&1)"
empty_rc=$?
set -e
assert_eq "$empty_rc" "0" "empty rc --dry-run exits 0"
assert_contains "$empty_out" "shell-terminal/zsh" "dry-run lists zsh bundle"
assert_contains "$empty_out" "git/lazygit" "dry-run lists git/lazygit"
assert_not_contains "$empty_out" "languages/php" "dry-run does not list PHP"
assert_false "[ -s '$TRACE' ]"  # dry-run must not invoke the engine
assert_eq "$(cat "$CFG/mesh/selections.list")" "$(cat "$SANDBOX/selections.before")" \
    "dry-run does not rewrite selections.list"

echo
echo "── marked rc applies via engine without --repair and without persisting selection ──"
printf '# managed by mesh-workstation\n# load zshrc.d\n' > "$HOME_SANDBOX/.zshrc"
printf '# managed by mesh-workstation\n# load bashrc.d\n' > "$HOME_SANDBOX/.bashrc"
: > "$TRACE"
set +e
apply_out="$(run_reinstall shell 2>&1)"
apply_rc=$?
set -e
assert_eq "$apply_rc" "0" "marked rc apply exits 0"
assert_file_contains "$TRACE" "applied" "engine was invoked"
assert_false "grep -q '^forbidden-mode:' '$TRACE'"
assert_file_contains "$TRACE" "shell-terminal/zsh" "engine selection includes zsh"
assert_file_contains "$TRACE" "git/config" "engine selection includes git/config"
assert_false "grep -q 'languages/php' '$TRACE'"
assert_false "grep -q 'web/valet' '$TRACE'"
assert_false "grep -q 'databases/mysql' '$TRACE'"
assert_eq "$(cat "$CFG/mesh/selections.list")" "$(cat "$SANDBOX/selections.before")" \
    "apply does not rewrite selections.list"
assert_contains "$apply_out" "tmux kill-server" "summary mentions tmux kill-server"

echo
echo "── engine failure propagates and cleans temporary selection ──"
: > "$TRACE"
if failure_out="$(MESH_TEST_ENGINE_RC=42 run_reinstall shell 2>&1)"; then
    failure_rc=0
else
    failure_rc=$?
fi
assert_eq "$failure_rc" "42" "engine failure retains its exit code"
assert_contains "$failure_out" "engine exited 42" "engine failure is reported"
assert_not_contains "$failure_out" "apply finished" "failed engine does not report success"
selection_path="$(sed -n 's/^selections-file://p' "$TRACE")"
assert_false "[ -e '$selection_path' ]"

echo
echo "── module registers the public command ──"
assert_file_contains "$MODULE" 'mesh_register_command' "module registers a command"
assert_contains "$(cat "$MODULE")" $'--name reinstall' "module name is reinstall"

summary
