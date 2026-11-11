#!/usr/bin/env bash
# Contract for registry-backed `mesh run` fanout policy:
#   - only commands with registered fanout validators can run across hosts
#   - update rejects interactive flags before host/ssh work
#   - syncthing/services expose only their safe fanout verbs
#   - fanout env providers emit newline-delimited KEY=VALUE records, validated
#     before execution, and applied the same way to local and remote invocations
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
MESH="$REPO_ROOT/bin/mesh"

# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-run-fanout-policy.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

HOME_FAKE="$SANDBOX/home"
IDENTITY_EMPTY="$SANDBOX/identity-empty"
MODULES="$SANDBOX/modules"
RUN_CONF="$SANDBOX/mesh-status.conf"
SHIM="$SANDBOX/shim"
SSH_LOG="$SANDBOX/ssh.log"
mkdir -p "$HOME_FAKE" "$IDENTITY_EMPTY" "$MODULES" "$SHIM"

cat > "$RUN_CONF" <<'SH'
MESH_RUN_HOSTS=("self=self" "mac=mac" "remote=remote")
SH

cat > "$MODULES/10-fanout-fixtures.sh" <<'SH'
cmd_envcheck() {
    printf 'ENVCHECK:%s\n' "${FOO:-}"
}
validate_envcheck() {
    return 0
}
env_envcheck() {
    printf 'FOO=bar\n'
}

cmd_badenv() {
    printf 'BADENV-RAN\n'
}
validate_badenv() {
    return 0
}
env_badenv() {
    printf 'BAD RECORD\n'
}

cmd_rejectval() {
    printf 'REJECTVAL-RAN\n'
}
validate_rejectval() {
    printf 'validator rejected fixture\n' >&2
    return 43
}

mesh_register_command \
    --name envcheck \
    --summary "Fanout env fixture" \
    --group tests \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_envcheck \
    --fanout-validator validate_envcheck \
    --fanout-env-provider env_envcheck

mesh_register_command \
    --name badenv \
    --summary "Malformed fanout env fixture" \
    --group tests \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_badenv \
    --fanout-validator validate_badenv \
    --fanout-env-provider env_badenv

mesh_register_command \
    --name rejectval \
    --summary "Rejecting fanout validator fixture" \
    --group tests \
    --origin core \
    --visibility public \
    --fanout allowed \
    --handler cmd_rejectval \
    --fanout-validator validate_rejectval
SH

cat > "$SHIM/ssh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$MESH_SSH_LOG"
exit 0
SH
chmod +x "$SHIM/ssh"

run_mesh() {
    HOME="$HOME_FAKE" \
    MESH_STATUS_CONF="$RUN_CONF" \
    MESH_IDENTITY_DIR="$IDENTITY_EMPTY" \
    MESH_COMMAND_MODULE_DIR="$MODULES" \
    "$MESH" "$@"
}

assert_run_accepts() {
    local msg="$1"
    shift
    local out rc
    out="$(run_mesh run --hosts mac --dry-run "$@" 2>&1)"
    rc=$?
    assert_eq "$rc" 0 "$msg exits 0"
    assert_contains "$out" "DRY-RUN: mac" "$msg reaches dry-run host selection"
}

assert_run_rejects() {
    local msg="$1" needle="$2"
    shift 2
    local out rc
    out="$(run_mesh run "$@" 2>&1)"
    rc=$?
    assert_ne "$rc" 0 "$msg exits non-zero"
    assert_contains "$out" "$needle" "$msg prints expected rejection"
}

echo "core fanout registrations"
assert_run_accepts "status fanout" status --write
assert_run_accepts "snap fanout" snap --quiet
assert_run_accepts "update fanout" update -f

assert_run_rejects "update rejects -i" "-i/--interactive is not supported" --all update -i
assert_run_rejects "update rejects --interactive" "-i/--interactive is not supported" --all update --interactive

echo
echo "syncthing fanout validator"
assert_run_accepts "syncthing pair fanout" syncthing pair
assert_run_accepts "syncthing status fanout" syncthing status
assert_run_rejects "syncthing rejects password" "only \`syncthing pair\` and \`syncthing status\` can fan out" --all syncthing password
assert_run_rejects "syncthing rejects topology" "only \`syncthing pair\` and \`syncthing status\` can fan out" --all syncthing topology

echo
echo "removed services fan-out"
assert_run_rejects "services is not a fan-out" "unsupported mesh subcommand 'services'" --all services status

echo
echo "unsupported commands"
assert_run_rejects "clean has no fanout validator" "no registered fanout validator" --all clean
assert_run_rejects "config has no fanout validator" "no registered fanout validator" --all config

echo
echo "fanout env validation"
out="$(run_mesh run --hosts mac --dry-run rejectval 2>&1)"
rc=$?
assert_eq "$rc" 43 "rejected fanout validator preserves validator exit code"
assert_contains "$out" "validator rejected fixture" "rejected fanout validator prints validator output"
assert_not_contains "$out" "DRY-RUN:" "rejected fanout validator rejects before host selection"
assert_not_contains "$out" "REJECTVAL-RAN" "rejected fanout validator does not execute handler"

out="$(run_mesh run --hosts mac --dry-run badenv 2>&1)"
rc=$?
assert_ne "$rc" 0 "malformed fanout env exits non-zero"
assert_contains "$out" "malformed record" "malformed fanout env is rejected before execution"
assert_not_contains "$out" "DRY-RUN:" "malformed fanout env rejects before host selection"
assert_not_contains "$out" "BADENV-RAN" "malformed fanout env does not execute handler"

echo
echo "fanout env application"
out="$(MESH_RUN_SELF_ALIAS=self run_mesh run --hosts self envcheck 2>&1)"
rc=$?
assert_eq "$rc" 0 "local fanout env invocation exits 0"
assert_contains "$out" "ENVCHECK:bar" "local invocation receives fanout env record"

rm -f "$SSH_LOG"
out="$(
    MESH_RUN_SELF_ALIAS=self \
    MESH_RUN_SSH="$SHIM/ssh" \
    MESH_SSH_LOG="$SSH_LOG" \
    run_mesh run --hosts remote envcheck 2>&1
)"
rc=$?
assert_eq "$rc" 0 "remote fanout env invocation exits 0"
assert_file_exists "$SSH_LOG" "remote invocation reaches ssh shim"
ssh_args="$(cat "$SSH_LOG" 2>/dev/null || true)"
assert_contains "$ssh_args" "FOO=bar; export FOO;" "remote invocation exports fanout env record"
assert_contains "$ssh_args" "mesh envcheck" "remote invocation runs mesh envcheck"

echo
summary
