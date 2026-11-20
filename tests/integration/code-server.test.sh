#!/usr/bin/env bash
# tests/integration/code-server.test.sh — static coverage for remote-access/code-server.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

INSTALL="$ROOT/topics/remote-access/mac/code-server.sh"
VERIFY="$ROOT/topics/remote-access/mac/code-server.sh"
BOOTSTRAP="$ROOT/setup.sh"
MANIFEST="$ROOT/topics/remote-access/manifest.yaml"

echo
echo "═══ remote-access/code-server topic wiring ═══"

assert_file_exists "$INSTALL" "mac/code-server.sh exists"
assert_file_exists "$MANIFEST" "remote-access/manifest.yaml exists"

list_out="$(HOME="$(mktemp -d /tmp/code-server-list.XXXXXX)" bash "$BOOTSTRAP" --list-bundles 2>&1)"
cs_line="$(printf '%s\n' "$list_out" | grep -E 'remote-access/code-server' || true)"
assert_contains "$cs_line" "remote-access/code-server" \
    "bootstrap --list-bundles includes remote-access/code-server"
assert_contains "$cs_line" "opt-in" \
    "code-server is listed as opt-in"

assert_pattern_present "$MANIFEST" 'name: code-server' \
    "manifest declares the code-server bundle"
assert_pattern_present "$INSTALL" 'CODE_SERVER_LABEL:=com\.\$\{USER\}\.code-server' \
    "installer default label is com.\${USER}.code-server"
assert_pattern_present "$INSTALL" 'CODE_SERVER_INSTALL_METHOD:=standalone' \
    "installer default install method is standalone"
assert_pattern_present "$INSTALL" 'CODE_SERVER_TAILSCALE_SERVE:=1' \
    "installer exposes code-server through Tailscale Serve by default"
assert_pattern_present "$INSTALL" 'CODE_SERVER_UPGRADE:=0' \
    "installer defaults code-server upgrades to explicit opt-in"
assert_pattern_present "$INSTALL" 'CODE_SERVER_CHECK_UPDATES:=1' \
    "installer checks for code-server updates by default"

# (menu.sh code-server checklist/state assertions removed with the dead F9.5 menu
# in T-005; the Ink TUI in scripts/menu/ owns the code-server bundle item.)

echo
echo "═══ remote-access/code-server installer contract ═══"

assert_pattern_present "$INSTALL" 'curl -fsSL https://code-server\.dev/install\.sh' \
    "installer uses official code-server install script"
assert_pattern_present "$INSTALL" '[-][-]method=standalone --prefix "\$CODE_SERVER_INSTALL_PREFIX"' \
    "installer uses standalone method with prefix"
assert_pattern_present "$INSTALL" 'env -u OS -u ARCH -u DISTRO sh -s --' \
    "installer clears mesh-workstation OS env before running upstream install script"
assert_pattern_absent "$INSTALL" 'brew install code-server' \
    "installer does not use Homebrew code-server formula"
assert_pattern_present "$INSTALL" 'CODE_SERVER_UPGRADE:=0' \
    "installer requires CODE_SERVER_UPGRADE=1 before reinstalling an existing binary"
assert_pattern_present "$INSTALL" 'CODE_SERVER_CHECK_UPDATES:=1' \
    "installer checks upstream releases by default"
assert_pattern_present "$INSTALL" 'https://api\.github\.com/repos/coder/code-server/releases/latest' \
    "installer checks the upstream code-server latest release"
assert_pattern_present "$INSTALL" 'code-server update available: \$current -> \$latest' \
    "installer records update availability in the final bootstrap summary"
assert_pattern_present "$INSTALL" 'CODE_SERVER_UPGRADE=1 CODE_SERVER_VERSION=\$latest ONLY_TOPICS=85 bash' \
    "installer prints an explicit pinned upgrade command"

assert_pattern_present "$INSTALL" 'CODE_SERVER_INSTALL_METHOD.*!= "standalone"' \
    "installer rejects non-standalone install methods"
assert_pattern_present "$INSTALL" 'CODE_SERVER_INSTALL_PREFIX.*!= "\$HOME/\.local"' \
    "installer rejects prefixes outside \$HOME/.local in this release"
assert_pattern_present "$INSTALL" 'bind-addr: 127\.0\.0\.1:%s' \
    "generated config binds to 127.0.0.1"
assert_pattern_absent "$INSTALL" 'bind-addr: 0\.0\.0\.0' \
    "installer does not generate 0.0.0.0 bind"
assert_pattern_present "$INSTALL" 'config must bind only to 127\.0\.0\.1' \
    "installer rejects existing non-loopback bind"
assert_pattern_present "$INSTALL" 'config must keep auth: password' \
    "installer rejects existing config without password auth"
assert_pattern_present "$INSTALL" 'verify_local_only_listener' \
    "installer validates the actual TCP listener after healthz"
assert_pattern_present "$INSTALL" 'lsof -nP -iTCP:"\$CODE_SERVER_PORT" -sTCP:LISTEN' \
    "installer inspects the actual listener with lsof"
assert_pattern_present "$INSTALL" '/usr/bin/openssl rand -hex 24' \
    "password generation uses openssl rand, not a fragile pipeline"
assert_pattern_present "$INSTALL" 'ask_secret .*Enter a password for code-server' \
    "interactive install prompts for hidden password"
assert_pattern_present "$INSTALL" 'Confirm code-server password' \
    "interactive password prompt asks for confirmation"
assert_pattern_present "$INSTALL" 'MESH_FOLLOWUP_FILE' \
    "generated password is deferred to bootstrap final summary"
assert_pattern_present "$INSTALL" 'Deliberately bypass followup\(\)' \
    "generated password is not printed through tee'd topic logs"
assert_pattern_present "$INSTALL" 'read the password from that file on this host' \
    "final password summary tells how to recover a missed password"
assert_pattern_absent "$INSTALL" 'echo "\$password"' \
    "installer does not echo generated password"

assert_pattern_present "$INSTALL" 'CODE_SERVER_LABEL:=com\.\$\{USER\}\.code-server' \
    "installer default label is user-derived"
assert_pattern_present "$INSTALL" '/usr/bin/plutil -lint "\$tmp"' \
    "installer validates plist with plutil (on tmp before atomic mv — CP4 C-F-010)"
assert_pattern_present "$INSTALL" 'mv -f "\$tmp" "\$CODE_SERVER_PLIST"' \
    "installer atomically renames validated plist into place (CP4 C-F-010)"
assert_pattern_absent "$INSTALL" '<key>GITHUB_TOKEN</key>' \
    "plist generation does not write GITHUB_TOKEN"
assert_pattern_absent "$INSTALL" '<key>EnvironmentVariables</key>' \
    "plist generation omits EnvironmentVariables"

echo
echo "═══ service wrapper + external brew PATH ═══"

assert_pattern_present "$INSTALL" 'bash "\$HERE/\.\./\.\./scripts/lib/detect-brew\.sh"' \
    "installer calls detect-brew.sh as a subprocess"
assert_pattern_present "$INSTALL" 'BREW_BIN=\*\).*BREW_BIN=' \
    "installer parses only BREW_BIN lines from detect-brew output"
assert_pattern_present "$INSTALL" 'BREW_PREFIX=\*\).*BREW_PREFIX=' \
    "installer parses only BREW_PREFIX lines from detect-brew output"
assert_pattern_absent "$INSTALL" 'source .*/detect-brew\.sh' \
    "installer does not source detect-brew.sh"
assert_pattern_present "$INSTALL" 'append_extra_path "\$BREW_PREFIX/bin"' \
    "wrapper PATH includes BREW_PREFIX/bin"
assert_pattern_present "$INSTALL" 'append_extra_path "\$BREW_PREFIX/sbin"' \
    "wrapper PATH includes BREW_PREFIX/sbin"
assert_pattern_present "$INSTALL" 'gh auth token' \
    "wrapper obtains GitHub token from gh at runtime"
assert_pattern_present "$INSTALL" 'perl -e .*alarm shift @ARGV; exec @ARGV.* gh auth token </dev/null' \
    "wrapper token probe has a timeout under launchd"
assert_pattern_present "$INSTALL" '/Volumes/\*' \
    "wrapper avoids spawning external-volume gh under launchd"
assert_pattern_present "$INSTALL" '\.config/gh/hosts\.yml' \
    "wrapper can fall back to the gh hosts file without printing the token"
assert_pattern_present "$INSTALL" 'export GITHUB_TOKEN="\$token"' \
    "wrapper exports GITHUB_TOKEN only for child process"

echo
echo "═══ Tailscale Serve safeguards ═══"

assert_pattern_present "$INSTALL" 'CODE_SERVER_TAILSCALE_SERVE' \
    "Tailscale Serve is gated by CODE_SERVER_TAILSCALE_SERVE"
assert_pattern_present "$INSTALL" 'CODE_SERVER_TAILSCALE_SERVE:=1' \
    "topic defaults Tailscale Serve on"
assert_pattern_present "$INSTALL" 'tailscale serve status --json' \
    "installer preflights existing Tailscale Serve config"
assert_pattern_present "$INSTALL" 'No serve config' \
    "preflight treats 'No serve config' as empty state"
assert_pattern_present "$INSTALL" 'CODE_SERVER_TAILSCALE_HTTPS_PORT:=8449' \
    "installer defaults the Serve HTTPS port to 8449, never 443"
assert_pattern_present "$INSTALL" 'tailscale serve --bg --yes --https="\$CODE_SERVER_TAILSCALE_HTTPS_PORT" "\$CODE_SERVER_PORT"' \
    "installer publishes Serve on the configured HTTPS port"
assert_pattern_absent "$INSTALL" 'tailscale serve --bg --yes "\$CODE_SERVER_PORT"' \
    "installer never publishes Serve on the default HTTPS 443"
assert_pattern_present "$INSTALL" 'log in, then run: tailscale serve --bg --yes --https=\$CODE_SERVER_TAILSCALE_HTTPS_PORT \$CODE_SERVER_PORT' \
    "manual Serve hint uses the same configured HTTPS port"
assert_pattern_present "$INSTALL" 'code-server URL:' \
    "installer prints the Tailscale URL when Serve is active"
assert_pattern_present "$INSTALL" 'code-server uninstall: tailscale serve reset failed' \
    "tailscale serve reset is scoped to uninstall of a dedicated Serve config"

assert_pattern_present "$VERIFY" 'auth:\[\[:space:\]\]\*password' \
    "verify checks password auth"
assert_pattern_present "$VERIFY" 'lsof -nP -iTCP:"\$CODE_SERVER_PORT" -sTCP:LISTEN' \
    "verify checks the actual listener"
assert_pattern_present "$VERIFY" 'loopback-only on 127\.0\.0\.1' \
    "verify fails if listener is not loopback-only"


echo
echo "═══ Tailscale Serve HTTPS port (behaviour) ═══"

SERVE_SANDBOX="$(mktemp -d -t code-server-serve.XXXXXX)"
cleanup_serve() { rm -rf "$SERVE_SANDBOX"; }
trap cleanup_serve EXIT

SERVE_BIN="$SERVE_SANDBOX/bin"
SERVE_HOME="$SERVE_SANDBOX/home"
SERVE_CALLS="$SERVE_SANDBOX/calls.log"
mkdir -p "$SERVE_BIN" "$SERVE_HOME/.local/state/code-server"
cat > "$SERVE_BIN/tailscale" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${CALLS:?}"
if [[ "${1:-}" == "status" ]]; then
    exit 0
fi
if [[ "${1:-}" == "serve" && "${2:-}" == "status" ]]; then
    printf 'No serve config\n'
    exit 0
fi
exit 0
SH
chmod +x "$SERVE_BIN/tailscale"

# The installer nests its Serve helpers inside install(); lift the two we
# exercise into a sourceable file so the step can run without the installer.
SERVE_HELPERS="$SERVE_SANDBOX/serve-helpers.sh"
{
    awk '/^tailscale_serve_state\(\) \{/{copy=1} copy{print} copy&&/^\}$/{copy=0}' "$INSTALL"
    awk '/^maybe_configure_tailscale_serve\(\) \{/{copy=1} copy{print} copy&&/^\}$/{copy=0}' "$INSTALL"
} > "$SERVE_HELPERS"
assert_file_contains "$SERVE_HELPERS" "maybe_configure_tailscale_serve" \
    "Serve step helper is available for behavioural coverage"

run_serve_step() {
    : > "$SERVE_CALLS"
    SERVE_OUT="$(
        HOME="$SERVE_HOME" USER="tester" MESH_WORKSTATION_DIR="$ROOT" \
        PATH="$SERVE_BIN:$PATH" CALLS="$SERVE_CALLS" \
        CODE_SERVER_TAILSCALE_SERVE=1 \
        CODE_SERVER_PORT=8080 \
        CODE_SERVER_INSTALL_PREFIX="$SERVE_HOME/.local" \
        CODE_SERVER_EXTRA_PATH="$SERVE_BIN" \
        CODE_SERVER_STATE_DIR="$SERVE_HOME/.local/state/code-server" \
        CODE_SERVER_TAILSCALE_HTTPS_PORT="${1:-}" \
        bash -c '. "$1/scripts/lib/log.sh"; . "$2"; mesh_tailscale_cli() { return 0; }; maybe_configure_tailscale_serve' _ "$ROOT" "$SERVE_HELPERS" 2>&1
    )"
    SERVE_RC=$?
}

run_serve_step
assert_eq "$SERVE_RC" "0" "Serve step succeeds with the default HTTPS port"
assert_contains "$(cat "$SERVE_CALLS")" "serve --bg --yes --https=8449 8080" \
    "Serve step publishes on HTTPS 8449 by default"

run_serve_step "abc"
assert_eq "$SERVE_RC" "0" "Serve step with an invalid HTTPS port does not abort the install"
assert_contains "$SERVE_OUT" "CODE_SERVER_TAILSCALE_HTTPS_PORT" \
    "invalid HTTPS port follow-up names the variable"
assert_not_contains "$(cat "$SERVE_CALLS")" "serve" \
    "invalid HTTPS port never calls tailscale serve"

# Migration matcher: a managed config on the configured HTTPS port (or legacy
# 443) may be updated; any other Serve port is left alone.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/code-server-port.sh"
serve_json_8449='{"TCP":{"8449":{"HTTPS":true}},"Web":{"host.test.ts.net:8449":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}'
serve_json_443='{"TCP":{"443":{"HTTPS":true}},"Web":{"host.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}'
serve_json_8450='{"TCP":{"8450":{"HTTPS":true}},"Web":{"host.test.ts.net:8450":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}'
ASSERT_MSG="managed Serve matcher accepts the configured HTTPS port 8449"
assert_true "code_server_managed_serve_matches '$serve_json_8449' 8080"
ASSERT_MSG="managed Serve matcher accepts a legacy HTTPS port 443"
assert_true "code_server_managed_serve_matches '$serve_json_443' 8080"
ASSERT_MSG="managed Serve matcher rejects an unconfigured Serve port"
assert_false "code_server_managed_serve_matches '$serve_json_8450' 8080"

summary
