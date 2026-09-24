#!/usr/bin/env bash
# tests/integration/code-server-uninstall.test.sh
#
# The remote-access/code-server bundle is a custom standalone install. Its
# uninstall() must stop launchd, remove the mesh-managed runtime footprint, clear
# the dedicated Tailscale Serve proxy, and keep VS Code user data by default.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$ROOT/topics/remote-access/mac/code-server.sh"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$ROOT/tests/lib/assert.sh"

SANDBOX="$(mktemp -d -t code-server-uninstall.XXXXXX)"
cleanup() { rm -rf "$SANDBOX"; }
trap cleanup EXIT

HOME_DIR="$SANDBOX/home"
BIN="$SANDBOX/bin"
CALLS="$SANDBOX/calls.log"
LOADED="$SANDBOX/launchd-loaded"
mkdir -p "$BIN" \
    "$HOME_DIR/.local/bin" \
    "$HOME_DIR/.local/lib/code-server-4.126.0/bin" \
    "$HOME_DIR/.config/code-server" \
    "$HOME_DIR/.local/state/code-server" \
    "$HOME_DIR/.local/share/code-server/User/globalStorage" \
    "$HOME_DIR/Library/LaunchAgents"

cat > "$HOME_DIR/.local/lib/code-server-4.126.0/bin/code-server" <<'SH'
#!/usr/bin/env bash
printf '4.126.0\n'
SH
chmod +x "$HOME_DIR/.local/lib/code-server-4.126.0/bin/code-server"
ln -s "$HOME_DIR/.local/lib/code-server-4.126.0/bin/code-server" "$HOME_DIR/.local/bin/code-server"
printf '#!/usr/bin/env bash\n' > "$HOME_DIR/.local/bin/code-server-service"
chmod +x "$HOME_DIR/.local/bin/code-server-service"
printf 'bind-addr: 127.0.0.1:8091\n' > "$HOME_DIR/.config/code-server/config.yaml"
printf 'log\n' > "$HOME_DIR/.local/state/code-server/launchd.log"
printf '<plist/>\n' > "$HOME_DIR/Library/LaunchAgents/com.tester.code-server.plist"
printf 'user-state\n' > "$HOME_DIR/.local/share/code-server/User/globalStorage/state.txt"
touch "$LOADED"

cat > "$BIN/uname" <<'SH'
#!/usr/bin/env bash
printf 'Darwin\n'
SH
cat > "$BIN/launchctl" <<'SH'
#!/usr/bin/env bash
printf 'launchctl:%s\n' "$*" >> "${CALLS:?}"
if [[ "${1:-}" == "print" ]]; then
    [[ -f "${LOADED:?}" ]]
    exit $?
fi
if [[ "${1:-}" == "bootout" ]]; then
    rm -f "${LOADED:?}"
fi
exit 0
SH
cat > "$BIN/tailscale" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "serve" && "${2:-}" == "status" && "${3:-}" == "--json" ]]; then
    cat <<'JSON'
{
  "TCP": {"443": {"HTTPS": true}},
  "Web": {
    "code-server.test.ts.net:443": {
      "Handlers": {
        "/": {"Proxy": "http://127.0.0.1:8091"}
      }
    }
  }
}
JSON
    exit 0
fi
if [[ "${1:-}" == "serve" && "${2:-}" == "reset" ]]; then
    printf 'tailscale:serve reset\n' >> "${CALLS:?}"
    exit 0
fi
printf 'unexpected tailscale args: %s\n' "$*" >&2
exit 1
SH
chmod +x "$BIN/"*

echo "code-server uninstall script loads without MESH_WORKSTATION_DIR"
load_home="$SANDBOX/no-default-repo-home"
mkdir -p "$load_home"
set +e
load_out="$(
    HOME="$load_home" \
    USER="tester" \
    PATH="$BIN:$PATH" \
    env -u MESH_WORKSTATION_DIR bash -e -c '. "$1"; declare -f uninstall >/dev/null' _ "$SCRIPT" 2>&1
)"
load_rc=$?
set +e
assert_eq "$load_rc" "0" "script can be sourced for uninstall without a default mesh-workstation checkout"
assert_eq "$load_out" "" "script load is quiet when only uninstall helpers are needed"

echo "code-server uninstall refuses unsupported install prefix"
bad_out="$(
    HOME="$HOME_DIR" \
    USER="tester" \
    MESH_WORKSTATION_DIR="$ROOT" \
    PATH="$BIN:$PATH" \
    CALLS="$CALLS" \
    LOADED="$LOADED" \
    CODE_SERVER_LABEL="com.tester.code-server" \
    CODE_SERVER_INSTALL_PREFIX="$SANDBOX/not-local" \
    bash -c '. "$1"; uninstall' _ "$SCRIPT" 2>&1
)"
bad_rc=$?
assert_eq "$bad_rc" "1" "uninstall rejects non-mesh install prefix"
assert_contains "$bad_out" "refusing unsupported CODE_SERVER_INSTALL_PREFIX" "unsupported prefix explains refusal"

echo "code-server uninstall removes managed runtime and preserves user data"
out="$(
    HOME="$HOME_DIR" \
    USER="tester" \
    MESH_WORKSTATION_DIR="$ROOT" \
    PATH="$BIN:$PATH" \
    CALLS="$CALLS" \
    LOADED="$LOADED" \
    NON_INTERACTIVE=1 \
    CODE_SERVER_LABEL="com.tester.code-server" \
    bash -c '. "$1"; uninstall' _ "$SCRIPT" 2>&1
)"
rc=$?
assert_eq "$rc" "0" "uninstall exits 0"
assert_contains "$out" "preserving user data at $HOME_DIR/.local/share/code-server" "non-interactive uninstall warns about preserved user data"
assert_false "[ -e '$HOME_DIR/Library/LaunchAgents/com.tester.code-server.plist' ]"
assert_false "[ -e '$HOME_DIR/.local/bin/code-server' ]"
assert_false "[ -e '$HOME_DIR/.local/bin/code-server-service' ]"
assert_false "[ -e '$HOME_DIR/.local/lib/code-server-4.126.0' ]"
assert_false "[ -e '$HOME_DIR/.config/code-server' ]"
assert_false "[ -e '$HOME_DIR/.local/state/code-server' ]"
assert_true "[ -f '$HOME_DIR/.local/share/code-server/User/globalStorage/state.txt' ]"
assert_contains "$(cat "$CALLS")" "launchctl:bootout" "launchd service is booted out"
assert_contains "$(cat "$CALLS")" "tailscale:serve reset" "dedicated Tailscale Serve config is reset"

echo "code-server uninstall prompts before purging user data"
printf 'y\n' > "$SANDBOX/prompt.in"
prompt_out="$SANDBOX/prompt.out"
out="$(
    HOME="$HOME_DIR" \
    USER="tester" \
    MESH_WORKSTATION_DIR="$ROOT" \
    PATH="$BIN:$PATH" \
    CALLS="$CALLS" \
    LOADED="$LOADED" \
    MESH_PROMPT_IN="$SANDBOX/prompt.in" \
    MESH_PROMPT_OUT="$prompt_out" \
    CODE_SERVER_LABEL="com.tester.code-server" \
    bash -c '. "$1"; uninstall' _ "$SCRIPT" 2>&1
)"
rc=$?
assert_eq "$rc" "0" "uninstall exits 0 after user-data purge confirmation"
assert_eq "$out" "" "confirmed purge is quiet on stderr"
assert_contains "$(cat "$prompt_out")" "Remove code-server user data at $HOME_DIR/.local/share/code-server" "uninstall asks before purging user data"
assert_false "[ -e '$HOME_DIR/.local/share/code-server' ]"

summary
