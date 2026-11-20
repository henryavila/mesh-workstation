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
assert_pattern_present "$INSTALL" ': "\$\{CODE_SERVER_TAILSCALE_HTTPS_PORT=8449\}"' \
    "installer defaults the Serve HTTPS port to 8449 only when it is unset"
assert_pattern_absent "$INSTALL" 'CODE_SERVER_TAILSCALE_HTTPS_PORT:-8449' \
    "an explicitly empty Serve HTTPS port never falls back to 8449"
assert_pattern_present "$INSTALL" 'tailscale serve --bg --yes --https="\$CODE_SERVER_TAILSCALE_HTTPS_PORT" "\$CODE_SERVER_PORT"' \
    "installer publishes Serve on the configured HTTPS port"
assert_pattern_absent "$INSTALL" 'tailscale serve --bg --yes "\$CODE_SERVER_PORT"' \
    "installer never publishes Serve on the default HTTPS 443"
assert_pattern_present "$INSTALL" 'log in, then run: tailscale serve --bg --yes --https=\$CODE_SERVER_TAILSCALE_HTTPS_PORT \$CODE_SERVER_PORT' \
    "manual Serve hint uses the same configured HTTPS port"
assert_pattern_present "$INSTALL" 'code-server URL:' \
    "installer prints the Tailscale URL when Serve is active"
assert_pattern_present "$INSTALL" 'tailscale serve --https=443 off' \
    "installer turns the legacy HTTPS 443 route off after moving it"
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
SERVE_ROUTES="$SERVE_SANDBOX/routes"
SERVE_STATIC_JSON="$SERVE_SANDBOX/static.json"
SERVE_LOG="$SERVE_SANDBOX/routes.log"
SERVE_IGNORE_MUTATIONS=0
mkdir -p "$SERVE_BIN" "$SERVE_HOME/.local/state/code-server"
# Stub `tailscale`: records argv and models Serve state as one route per line
# ("https_port local_port"). Publishing on a port replaces only that route and
# `--https=N off` removes only that route, so a migration must be observed
# leaving 443 in place until it is explicitly turned off. SERVE_STATIC_JSON
# freezes the reported status so a test can prove the installer refuses to
# mutate a config it does not own.
cat > "$SERVE_BIN/tailscale" <<'SH'
#!/bin/bash
# The installer invokes tailscale with a narrowed PATH; restore the system
# directories so the stub can use cat/mv for its state model.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
printf '%s\n' "$*" >> "${CALLS:?}"
if [[ "${1:-}" == "status" ]]; then
    exit 0
fi
[[ "${1:-}" == "serve" ]] || exit 0
routes_json() {
    local first
    printf '{"TCP":{'
    first=1
    while read -r https_port local_port; do
        [[ "$first" == "1" ]] || printf ','
        first=0
        printf '"%s":{"HTTPS":true}' "$https_port"
    done < "${SERVE_ROUTES:-/dev/null}"
    printf '},"Web":{'
    first=1
    while read -r https_port local_port; do
        [[ "$first" == "1" ]] || printf ','
        first=0
        printf '"host.test.ts.net:%s":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:%s"}}}' \
            "$https_port" "$local_port"
    done < "${SERVE_ROUTES:-/dev/null}"
    printf '}}'
}
if [[ "${2:-}" == "status" ]]; then
    if [[ -s "${SERVE_STATIC_JSON:-}" ]]; then
        cat "$SERVE_STATIC_JSON"
    elif [[ -s "${SERVE_ROUTES:-}" ]]; then
        routes_json
    else
        printf 'No serve config\n'
    fi
    exit 0
fi
[[ "${SERVE_IGNORE_MUTATIONS:-0}" == "1" ]] && exit 0
if [[ "${2:-}" == "--bg" ]]; then
    https_port="" local_port=""
    for arg in "$@"; do
        case "$arg" in
            --https=*) https_port="${arg#--https=}" ;;
            [0-9]*) local_port="$arg" ;;
        esac
    done
    : > "${SERVE_ROUTES:?}.tmp"
    while read -r known_port known_local; do
        [[ "$known_port" == "$https_port" ]] && continue
        printf '%s %s\n' "$known_port" "$known_local" >> "${SERVE_ROUTES}.tmp"
    done < "$SERVE_ROUTES"
    printf '%s %s\n' "$https_port" "$local_port" >> "${SERVE_ROUTES}.tmp"
    mv "${SERVE_ROUTES}.tmp" "$SERVE_ROUTES"
    printf 'routes after %s: %s\n' "$*" "$(tr '\n' ';' < "$SERVE_ROUTES")" >> "${SERVE_LOG:?}"
    exit 0
fi
if [[ "${2:-}" == --https=* && "${3:-}" == "off" ]]; then
    https_port="${2#--https=}"
    : > "${SERVE_ROUTES:?}.tmp"
    while read -r known_port known_local; do
        [[ "$known_port" == "$https_port" ]] && continue
        printf '%s %s\n' "$known_port" "$known_local" >> "${SERVE_ROUTES}.tmp"
    done < "$SERVE_ROUTES"
    mv "${SERVE_ROUTES}.tmp" "$SERVE_ROUTES"
    printf 'routes after %s: %s\n' "$*" "$(tr '\n' ';' < "$SERVE_ROUTES")" >> "${SERVE_LOG:?}"
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

serve_mutations() {
    grep -E '^serve ' "${SERVE_CALLS:-/dev/null}" 2>/dev/null | grep -v '^serve status' | tr '\n' '|' || true
}

# serve_setup [initial routes | none] — reset calls, Serve state and the saved
# serve-port file. ``serve_use_static JSON`` pins the status the stub reports.
serve_setup() {
    local initial="${1:-none}"
    : > "$SERVE_CALLS"
    : > "$SERVE_ROUTES"
    : > "$SERVE_STATIC_JSON"
    : > "$SERVE_LOG"
    SERVE_IGNORE_MUTATIONS=0
    rm -f "$SERVE_HOME/.local/state/code-server/serve-port"
    [[ "$initial" == "none" ]] || printf '%s\n' "$initial" > "$SERVE_ROUTES"
}
serve_use_static() { printf '%s\n' "$1" > "$SERVE_STATIC_JSON"; }

run_serve_step() {
    local port="${1-__unset__}"
    : > "$SERVE_CALLS"
    local -a envv=(
        HOME="$SERVE_HOME" USER="tester" MESH_WORKSTATION_DIR="$ROOT"
        PATH="$SERVE_BIN:$PATH" CALLS="$SERVE_CALLS"
        SERVE_ROUTES="$SERVE_ROUTES" SERVE_STATIC_JSON="$SERVE_STATIC_JSON"
        SERVE_LOG="$SERVE_LOG"
        SERVE_IGNORE_MUTATIONS="$SERVE_IGNORE_MUTATIONS"
        CODE_SERVER_TAILSCALE_SERVE=1
        CODE_SERVER_PORT=8080
        CODE_SERVER_INSTALL_PREFIX="$SERVE_HOME/.local"
        CODE_SERVER_EXTRA_PATH="$SERVE_BIN"
        CODE_SERVER_STATE_DIR="$SERVE_HOME/.local/state/code-server"
    )
    # The unset case must not inherit the variable from whoever runs the tests.
    local -a runenv=(env)
    if [[ "$port" == "__unset__" ]]; then
        runenv+=(-u CODE_SERVER_TAILSCALE_HTTPS_PORT)
    else
        envv+=(CODE_SERVER_TAILSCALE_HTTPS_PORT="$port")
    fi
    SERVE_OUT="$(
        "${runenv[@]}" "${envv[@]}" bash -c '
            . "$1/scripts/lib/log.sh"
            . "$1/scripts/lib/code-server-port.sh"
            . "$2"
            mesh_tailscale_cli() { return 0; }
            followup() { printf "followup %s: %s\n" "$1" "$2"; }
            print_tailscale_code_server_url() { :; }
            maybe_configure_tailscale_serve
        ' _ "$ROOT" "$SERVE_HELPERS" 2>&1
    )"
    SERVE_RC=$?
}

serve_setup
run_serve_step
assert_eq "$SERVE_RC" "0" "Serve step succeeds with the default HTTPS port"
assert_contains "$(cat "$SERVE_CALLS")" "serve --bg --yes --https=8449 8080" \
    "Serve step publishes on HTTPS 8449 by default"
assert_not_contains "$(serve_mutations)" "--https=443 off" \
    "a fresh install never turns 443 off"

# An explicitly empty HTTPS port is invalid, exactly like "abc", "0", "65536".
for invalid in "" "abc" "0" "65536"; do
    label="${invalid:-<empty>}"
    serve_setup "443 8080"
    run_serve_step "$invalid"
    assert_eq "$SERVE_RC" "0" "invalid HTTPS port $label does not abort the install"
    assert_contains "$SERVE_OUT" "CODE_SERVER_TAILSCALE_HTTPS_PORT" \
        "invalid HTTPS port $label follow-up names the variable"
    assert_eq "$(cat "$SERVE_CALLS")" "" \
        "invalid HTTPS port $label never calls tailscale"
done

# Legacy dedicated 443 route with the backend already matching: move it to the
# configured port and only then turn 443 off.
serve_setup "443 8080"
printf '8080\n' > "$SERVE_HOME/.local/state/code-server/serve-port"
run_serve_step
assert_eq "$SERVE_RC" "0" "legacy 443 migration succeeds"
assert_eq "$(serve_mutations)" "serve --bg --yes --https=8449 8080|serve --https=443 off|" \
    "legacy 443 is moved to 8449 before it is turned off"
publish_snapshot="$(grep -F 'routes after serve --bg --yes --https=8449 8080:' "$SERVE_LOG" | head -1)"
assert_contains "$publish_snapshot" "443 8080" \
    "the publish call leaves the legacy 443 route in place"
assert_contains "$publish_snapshot" "8449 8080" \
    "the publish call adds the configured HTTPS route next to 443"
assert_contains "$SERVE_OUT" "Tailscale Serve proxies / to 127.0.0.1:8080" \
    "legacy migration reports the final Serve state as OK"
assert_eq "$(cat "$SERVE_ROUTES")" "8449 8080" \
    "legacy migration leaves only the 8449 route"
assert_eq "$(cat "$SERVE_HOME/.local/state/code-server/serve-port")" "8080" \
    "legacy migration records the served loopback port"

# Same migration without the serve-port state file older installs may lack.
serve_setup "443 8080"
run_serve_step
assert_eq "$SERVE_RC" "0" "legacy 443 migration succeeds without a serve-port file"
assert_eq "$(serve_mutations)" "serve --bg --yes --https=8449 8080|serve --https=443 off|" \
    "legacy 443 without a serve-port file is still moved to 8449"
assert_eq "$(cat "$SERVE_ROUTES")" "8449 8080" \
    "legacy migration without state file leaves only the 8449 route"

# Any additional handler makes the config unrelated: leave it untouched.
serve_setup
serve_use_static '{"TCP":{"443":{"HTTPS":true}},"Web":{"host.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"},"/other":{"Proxy":"http://127.0.0.1:9999"}}}}}'
run_serve_step
assert_eq "$SERVE_RC" "0" "a mixed 443 config does not abort the install"
assert_eq "$(serve_mutations)" "" \
    "a mixed 443 config is never mutated"
assert_contains "$SERVE_OUT" "followup manual" \
    "a mixed 443 config emits a follow-up"
assert_contains "$SERVE_OUT" "Tailscale Serve already has handlers" \
    "the follow-up explains that Serve was left alone"

# A handler without Proxy (Text) is still a handler: never treat it as empty.
serve_setup
serve_use_static '{"TCP":{"8449":{"HTTPS":true}},"Web":{"host.test.ts.net:8449":{"Handlers":{"/":{"Text":"existing website"}}}}}'
run_serve_step
assert_eq "$SERVE_RC" "0" "a Text-only Serve config does not abort the install"
assert_eq "$(serve_mutations)" "" \
    "a Text-only Serve config is never mutated"
assert_contains "$SERVE_OUT" "followup manual" \
    "a Text-only Serve config emits a follow-up"

# The plain-text sentinel is the only non-JSON status classified as empty.
serve_setup
run_serve_step
assert_eq "$SERVE_RC" "0" "a plain 'No serve config' sentinel does not abort the install"
assert_contains "$(serve_mutations)" "serve --bg --yes --https=8449 8080" \
    "a plain 'No serve config' sentinel configures Serve normally"
assert_not_contains "$SERVE_OUT" "followup" \
    "a plain 'No serve config' sentinel emits no follow-up"

# Surrounding whitespace does not change the sentinel.
serve_setup
serve_use_static '  No serve config  '
run_serve_step
assert_contains "$(serve_mutations)" "serve --bg --yes --https=8449 8080" \
    "a whitespace-padded 'No serve config' sentinel configures Serve normally"

# The sentinel inside a JSON handler is content, not an empty status: the
# config has a foreign Text route and must be preserved.
serve_setup
serve_use_static '{"TCP":{"8449":{"HTTPS":true}},"Web":{"host.test.ts.net:8449":{"Handlers":{"/":{"Text":"No serve config"}}}}}'
run_serve_step
assert_eq "$SERVE_RC" "0" "a Text handler containing the sentinel does not abort the install"
assert_eq "$(serve_mutations)" "" \
    "a Text handler containing the sentinel is never mutated"
assert_contains "$SERVE_OUT" "followup manual" \
    "a Text handler containing the sentinel emits a follow-up"

# Plain text only counts as the sentinel when it is the whole trimmed output.
serve_setup
serve_use_static 'No serve config here'
run_serve_step
assert_eq "$SERVE_RC" "0" "plain text containing the sentinel does not abort the install"
assert_eq "$(serve_mutations)" "" \
    "plain text containing the sentinel is never mutated"
assert_contains "$SERVE_OUT" "followup manual" \
    "plain text containing the sentinel emits a follow-up"

# Same for a Path handler on a port the installer does not manage.
serve_setup
serve_use_static '{"TCP":{"8450":{"HTTPS":true}},"Web":{"host.test.ts.net:8450":{"Handlers":{"/x":{"Path":"/var/www"}}}}}'
run_serve_step
assert_eq "$SERVE_RC" "0" "a Path-only Serve config does not abort the install"
assert_eq "$(serve_mutations)" "" \
    "a Path-only Serve config is never mutated"
assert_contains "$SERVE_OUT" "followup manual" \
    "a Path-only Serve config emits a follow-up"

# The root proxy is on our port, but the config also owns another handler:
# report it as already served and leave every handler byte-identical.
serve_setup
serve_use_static '{"TCP":{"8449":{"HTTPS":true}},"Web":{"host.test.ts.net:8449":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"},"/other":{"Text":"existing website"}}}}}'
run_serve_step
assert_eq "$SERVE_RC" "0" "a config with the root proxy plus another handler does not abort the install"
assert_eq "$(serve_mutations)" "" \
    "a config with the root proxy plus another handler is never mutated"
assert_contains "$SERVE_OUT" "Tailscale Serve already proxies / to 127.0.0.1:8080" \
    "the existing root proxy is reported as served"

# Without a confirmed new route the installer must leave 443 alone.
serve_setup
serve_use_static '{"TCP":{"443":{"HTTPS":true}},"Web":{"host.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}'
SERVE_IGNORE_MUTATIONS=1
run_serve_step
assert_eq "$SERVE_RC" "0" "an unconfirmed migration does not abort the install"
assert_contains "$(serve_mutations)" "serve --bg --yes --https=8449 8080" \
    "the unconfirmed migration still tries the configured HTTPS port"
assert_not_contains "$(serve_mutations)" "--https=443 off" \
    "443 is not turned off until the new route is confirmed"
assert_contains "$SERVE_OUT" "followup manual" \
    "an unconfirmed migration emits a follow-up"

# Explicit 443 is the desired port: nothing to migrate, nothing turned off.
serve_setup "443 8080"
run_serve_step "443"
assert_eq "$SERVE_RC" "0" "explicit HTTPS 443 is accepted"
assert_eq "$(serve_mutations)" "" \
    "explicit HTTPS 443 does not mutate Serve"
assert_contains "$SERVE_OUT" "Tailscale Serve already proxies / to 127.0.0.1:8080 (HTTPS 443)" \
    "explicit HTTPS 443 is reported as desired on 443"

# Migration matcher: a managed config on the configured HTTPS port (or legacy
# 443) may be updated; any other Serve port is left alone.
# shellcheck source=/dev/null
. "$ROOT/scripts/lib/code-server-port.sh"
serve_json_8449='{"TCP":{"8449":{"HTTPS":true}},"Web":{"host.test.ts.net:8449":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}'
serve_json_443='{"TCP":{"443":{"HTTPS":true}},"Web":{"host.test.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}'
serve_json_8450='{"TCP":{"8450":{"HTTPS":true}},"Web":{"host.test.ts.net:8450":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8080"}}}}}'
ASSERT_MSG="managed Serve matcher accepts the configured HTTPS port 8449"
assert_true "env -u CODE_SERVER_TAILSCALE_HTTPS_PORT bash -c '. \"$ROOT/scripts/lib/code-server-port.sh\"; code_server_managed_serve_matches \"\$1\" 8080' _ '$serve_json_8449'"
ASSERT_MSG="managed Serve matcher accepts a legacy HTTPS port 443"
assert_true "code_server_managed_serve_matches '$serve_json_443' 8080"
ASSERT_MSG="managed Serve matcher rejects an unconfigured Serve port"
assert_false "code_server_managed_serve_matches '$serve_json_8450' 8080"
ASSERT_MSG="managed Serve matcher accepts the default when the variable is unset"
assert_true "env -u CODE_SERVER_TAILSCALE_HTTPS_PORT bash -c '. \"$ROOT/scripts/lib/code-server-port.sh\"; code_server_managed_serve_matches \"\$1\" 8080' _ '$serve_json_8449'"
ASSERT_MSG="managed Serve matcher does not treat an empty HTTPS port as configured"
assert_false "CODE_SERVER_TAILSCALE_HTTPS_PORT= bash -c '. \"$ROOT/scripts/lib/code-server-port.sh\"; code_server_managed_serve_matches \"\$1\" 8080' _ '$serve_json_8449'"

summary
