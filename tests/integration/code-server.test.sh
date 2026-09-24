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
assert_pattern_present "$INSTALL" 'CODE_SERVER_TAILSCALE_SERVE:=0' \
    "installer leaves Tailscale Serve off by default"
assert_pattern_absent "$INSTALL" 'CODE_SERVER_TAILSCALE_SERVE:=1' \
    "installer no longer defaults Tailscale Serve on"
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
assert_pattern_present "$INSTALL" 'stores the hash' \
    "final password summary says the config file stores the hash"
assert_pattern_present "$INSTALL" 'plaintext cannot be recovered' \
    "final password summary says the plaintext cannot be recovered from the hash"
assert_pattern_absent "$INSTALL" 'read the password from that file on this host' \
    "final password summary does not tell the user to read the password from the file"
assert_pattern_present "$INSTALL" 'npx --yes argon2-cli -e' \
    "password hash uses npx --yes argon2-cli -e"
assert_pattern_present "$INSTALL" 'echo -n "\$pw"' \
    "password hash reads the password on stdin with no trailing newline"
assert_pattern_present "$INSTALL" 'hashed-password: %s' \
    "generated config writes hashed-password"
assert_pattern_absent "$INSTALL" "printf 'password: %s" \
    "generated config does not write a plaintext password line"
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
assert_pattern_present "$INSTALL" 'CODE_SERVER_TAILSCALE_SERVE:=0' \
    "topic defaults Tailscale Serve off"
assert_pattern_absent "$INSTALL" 'tailscale funnel' \
    "installer does not call tailscale funnel"
assert_pattern_absent "$INSTALL" 'tailscale funnel reset' \
    "installer does not call tailscale funnel reset"
assert_pattern_present "$INSTALL" 'tailscale serve status --json' \
    "installer preflights existing Tailscale Serve config"
assert_pattern_present "$INSTALL" 'No serve config' \
    "preflight treats 'No serve config' as empty state"
assert_pattern_present "$INSTALL" 'tailscale serve --bg --yes "\$CODE_SERVER_PORT"' \
    "installer uses non-interactive tailscale serve command"
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

summary
