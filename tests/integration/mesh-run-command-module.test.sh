#!/usr/bin/env bash
# tests/integration/mesh-run-command-module.test.sh
#
# T3.2 contract: `mesh run` is a source-pure command module and preserves
# selector flags, dry-run output, local/remote execution, fanout validators, and
# noninteractive fanout env handling.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-run-command-module.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

MESH_HOME_FAKE="$SANDBOX/scripts"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
RUN_CONF="$SANDBOX/mesh-status.conf"
SHIM="$SANDBOX/shim"
SSH_LOG="$SANDBOX/ssh.log"
mkdir -p "$MESH_HOME_FAKE/lib" "$MESH_HOME_FAKE/internal" "$MESH_HOME_FAKE/runners" "$IDENTITY_EMPTY" "$SHIM"
ln -s "$REPO_ROOT/scripts/lib/mesh-command.sh" "$MESH_HOME_FAKE/lib/mesh-command.sh"

cat > "$RUN_CONF" <<'SH'
MESH_RUN_HOSTS=("self=self" "mac=mac" "remote=remote")
SH

cat > "$MESH_HOME_FAKE/internal/mesh-status" <<'SH'
#!/usr/bin/env bash
printf 'STATUS:%s\n' "$*"
SH
chmod +x "$MESH_HOME_FAKE/internal/mesh-status"

cat > "$MESH_HOME_FAKE/internal/mesh-snap" <<'SH'
#!/usr/bin/env bash
printf 'SNAP:%s\n' "$*"
SH
chmod +x "$MESH_HOME_FAKE/internal/mesh-snap"

cat > "$MESH_HOME_FAKE/runners/auto-update.sh" <<'SH'
#!/usr/bin/env bash
printf 'UPDATE:%s:alias=%s\n' "$*" "${MESH_AUTOUPDATE_ALIAS:-}"
SH
chmod +x "$MESH_HOME_FAKE/runners/auto-update.sh"

cat > "$MESH_HOME_FAKE/runners/syncthing.sh" <<'SH'
#!/usr/bin/env bash
printf 'SYNCTHING:%s:noninteractive=%s\n' "$*" "${NON_INTERACTIVE:-}"
SH
chmod +x "$MESH_HOME_FAKE/runners/syncthing.sh"

cat > "$MESH_HOME_FAKE/runners/services.sh" <<'SH'
#!/usr/bin/env bash
printf 'SERVICES:%s:noninteractive=%s\n' "$*" "${NON_INTERACTIVE:-}"
SH
chmod +x "$MESH_HOME_FAKE/runners/services.sh"

cat > "$SHIM/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MESH_SSH_LOG"
exit 0
SH
chmod +x "$SHIM/ssh"

run_mesh() {
    HOME="$SANDBOX/home" \
    MESH_HOME="$MESH_HOME_FAKE" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_STATUS_CONF="$RUN_CONF" \
    MESH_RUN_SELF_ALIAS=self \
    "$MESH" "$@"
}

echo "module file and source purity"
assert_file_exists "$REPO_ROOT/scripts/commands/run.sh" "run module exists"
assert_file_contains "$REPO_ROOT/scripts/commands/run.sh" "mesh_register_command" "run module registers command"
assert_pattern_absent "$REPO_ROOT/bin/mesh" '^sub_run\(\)' "bin/mesh no longer owns sub_run body"

source_check="$(
    REPO_ROOT="$REPO_ROOT" bash <<'SH'
set -uo pipefail
source "$REPO_ROOT/scripts/lib/mesh-command.sh"
_die() { printf 'DIE:%s\n' "$*" >&2; exit 1; }
ask_line() { printf 'unexpected ask_line\n' >&2; exit 1; }
source "$REPO_ROOT/scripts/commands/run.sh"
mesh_command_emit_tsv --internal
SH
)"
count="$(printf '%s\n' "$source_check" | awk -F '\t' '$1 == "run" { c++ } END { print c + 0 }')"
assert_eq "$count" "1" "source registers run exactly once"
assert_contains "$source_check" $'run\tFan out mesh subcommands across hosts\tcore\tcore\tpublic\tnone' \
    "run metadata is public core/core fanout none"

echo
echo "selector flags and dry-run"
out="$(run_mesh run --hosts mac --dry-run status --write 2>&1)"
rc=$?
assert_eq "$rc" 0 "--hosts dry-run exits 0"
assert_contains "$out" "DRY-RUN: mac (ssh mac): mesh status --write" "--hosts dry-run preserves remote target"

out="$(MESH_RUN_ONLINE_HOSTS=self,remote run_mesh run --online --dry-run snap --quiet 2>&1)"
rc=$?
assert_eq "$rc" 0 "--online dry-run exits 0"
assert_contains "$out" "DRY-RUN: self (local): mesh snap --quiet" "--online includes configured local host"
assert_contains "$out" "DRY-RUN: remote (ssh remote): mesh snap --quiet" "--online includes configured remote host"

out="$(run_mesh run --all --dry-run update -f 2>&1)"
rc=$?
assert_eq "$rc" 0 "--all dry-run exits 0"
assert_contains "$out" "DRY-RUN: self (local): mesh update -f" "--all includes local host"
assert_contains "$out" "DRY-RUN: remote (ssh remote): mesh update -f" "--all includes remote host"

out="$(run_mesh run --hosts missing --dry-run status 2>&1)"
rc=$?
assert_ne "$rc" 0 "unknown host exits non-zero"
assert_contains "$out" "run: unknown host 'missing'" "unknown host rejection names requested host"

out="$(MESH_RUN_ONLINE_HOSTS=self,remote run_mesh run --dry-run status 2>&1)"
rc=$?
assert_ne "$rc" 0 "implicit selector without TTY exits non-zero"
assert_contains "$out" "run: no interactive selector available; pass --hosts, --online, or --all" \
    "implicit selector without TTY tells the user how to be explicit"
assert_not_contains "$out" "ask_line: command not found" "implicit selector without TTY does not call missing prompt"
assert_not_contains "$out" "DRY-RUN:" "implicit selector without TTY does not select online hosts"

echo
echo "local and remote execution"
out="$(run_mesh run --hosts self status --write 2>&1)"
rc=$?
assert_eq "$rc" 0 "local execution exits 0"
assert_contains "$out" "STATUS:--write" "local execution invokes target command"

rm -f "$SSH_LOG"
out="$(
    MESH_RUN_SSH="$SHIM/ssh" \
    MESH_SSH_LOG="$SSH_LOG" \
    run_mesh run --hosts remote status --write 2>&1
)"
rc=$?
assert_eq "$rc" 0 "remote execution exits 0"
assert_file_exists "$SSH_LOG" "remote execution invokes ssh shim"
ssh_args="$(cat "$SSH_LOG" 2>/dev/null || true)"
assert_contains "$ssh_args" "mesh status --write" "remote execution renders mesh command"

echo
echo "fanout validators and noninteractive env"
out="$(run_mesh run --all run status 2>&1)"
rc=$?
assert_ne "$rc" 0 "nested mesh run is rejected"
assert_contains "$out" "no registered fanout validator" "nested run rejection uses fanout policy"

out="$(run_mesh run --all update -i 2>&1)"
rc=$?
assert_ne "$rc" 0 "interactive update is rejected"
assert_contains "$out" "-i/--interactive is not supported" "interactive update rejection names flag"

out="$(run_mesh run --hosts self syncthing pair 2>&1)"
rc=$?
assert_eq "$rc" 0 "syncthing pair local fanout exits 0"
assert_contains "$out" "SYNCTHING:pair:noninteractive=1" "syncthing fanout receives NON_INTERACTIVE"

out="$(run_mesh run --all syncthing password 2>&1)"
rc=$?
assert_ne "$rc" 0 "syncthing unsafe verb is rejected"
assert_contains "$out" "only \`syncthing pair\` and \`syncthing status\` can fan out" \
    "syncthing rejection names safe verbs"

out="$(run_mesh run --all services status 2>&1)"
rc=$?
assert_ne "$rc" 0 "services fan-out is rejected"
assert_contains "$out" "unsupported mesh subcommand 'services'" "services is not a registered fan-out"

echo
summary
