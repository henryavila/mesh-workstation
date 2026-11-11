#!/usr/bin/env bash
# tests/integration/launch-wrapper.test.sh
#
# Validates lib/launch-wrapper.sh — the user-scope LaunchAgent generator
# that wraps brew binaries living in non-canonical (e.g. /Volumes/External)
# prefixes. Workaround for the TCC sandbox exit-78 bug; empirical mechanism
# TCC entitlement is granted at spawn and preserved across execve; rootfs wrapper bypasses noowners volume exit 78.
#
# Two layers of coverage:
#   (1) lib/launch-wrapper.sh unit-style: exercise public API in DRY_RUN
#       mode against a tempdir; assert wrapper script + plist content.
#   (2) topics/80-claude-code/syncthing-service-mac.sh structural: grep that the
#       custom-prefix branch wires the wrapper instead of failing with
#       a `warn` block (regression on the original broken UX).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

LIB="$ROOT/scripts/lib/launch-wrapper.sh"
TOPIC="$ROOT/topics/syncthing/syncthing-service-mac.sh"

# ---------------------------------------------------------------------
# Layer 1: lib/launch-wrapper.sh unit behavior
# ---------------------------------------------------------------------
echo
echo "═══ lib/launch-wrapper.sh — wrapper + plist generation ═══"

assert_file_exists "$LIB" "lib/launch-wrapper.sh exists"

# Set up isolated tempdir + dry-run mode (skip launchctl)
TMPROOT="$(mktemp -d -t launch-wrapper-test.XXXXXX)"
trap 'rm -rf "$TMPROOT"' EXIT
export LAUNCH_WRAPPER_BIN_DIR="$TMPROOT/bin"
export LAUNCH_WRAPPER_LOG_DIR="$TMPROOT/log"
export LAUNCH_WRAPPER_PLIST_DIR="$TMPROOT/LaunchAgents"
export LAUNCH_WRAPPER_DRY_RUN=1

# shellcheck source=../../lib/launch-wrapper.sh
source "$LIB"

# Run install for a fake syncthing-like service.
# Use `false` as a stand-in brew_bin path — content correctness matters,
# not whether the binary exists for the wait-loop (we're not bootstrapping
# in DRY_RUN).
fake_bin="/Volumes/External/homebrew/bin/syncthing"
launch_wrapper_install_extbrew \
    --svc syncthing \
    --label "com.testuser.syncthing" \
    --brew-bin "$fake_bin" \
    -- serve --no-browser --no-restart

WRAPPER="$LAUNCH_WRAPPER_BIN_DIR/syncthing-extbrew-wrapper.sh"
PLIST="$LAUNCH_WRAPPER_PLIST_DIR/com.testuser.syncthing.plist"

assert_file_exists "$WRAPPER" "wrapper script created"
assert_file_exists "$PLIST"   "user-named plist created"

if [[ -f "$WRAPPER" ]]; then
    if [[ -x "$WRAPPER" ]]; then pass "wrapper is executable (mode 0755)"
    else fail "wrapper is NOT executable"; fi

    # Wait-loop must exist (D42 family defense)
    assert_pattern_present "$WRAPPER" 'while \[\[ \$i -lt 30 \]\]' \
        "wrapper has 30-iteration wait-loop for external mount"

    # Must `exec` the target (preserves TCC entitlement via execve heritage)
    assert_pattern_present "$WRAPPER" '^exec "\$target"' \
        "wrapper exec's the target binary"

    # Target path must be the brew_bin we passed
    assert_pattern_present "$WRAPPER" "target='$fake_bin'" \
        "wrapper hardcodes the brew_bin path"

    # All passed args appear after exec (each as a separate quoted token)
    assert_pattern_present "$WRAPPER" 'exec "\$target".*serve' \
        "wrapper passes 'serve' arg to target"
    assert_pattern_present "$WRAPPER" 'exec "\$target".*--no-browser' \
        "wrapper passes '--no-browser' arg"
    assert_pattern_present "$WRAPPER" 'exec "\$target".*--no-restart' \
        "wrapper passes '--no-restart' arg"

    # Tells future readers WHY this exists (anti-rot)
    assert_pattern_present "$WRAPPER" 'TCC sandbox' \
        "wrapper documents WHY (TCC sandbox)"
    assert_pattern_present "$WRAPPER" 'preserved across execve' \
        "wrapper documents the empirical TCC finding"

    # Honest exit code if target permanently absent
    assert_pattern_present "$WRAPPER" 'exit 78' \
        "wrapper exits 78 (EX_CONFIG, matches launchd convention) if target missing"
fi

if [[ -f "$PLIST" ]]; then
    # XML preamble (DOCTYPE)
    assert_pattern_present "$PLIST" 'DOCTYPE plist PUBLIC' \
        "plist has well-formed DOCTYPE preamble"

    # REGRESSION: bash 3.2 array expansion `"${arr[@]+"${arr[@]}"}"` emits a
    # single empty arg when arr is empty (different from bash 4+, which
    # emits zero args). That empty arg used to leak into the plist as a
    # `<key></key><string></string>` pair inside EnvironmentVariables,
    # producing malformed XML that launchd rejected with EX_CONFIG (exit 78)
    # — the very thing this lib exists to AVOID. Guard explicitly: when
    # the install was called without any --env, the plist must contain
    # NO EnvironmentVariables block at all.
    assert_pattern_absent "$PLIST" '<key></key>' \
        "plist contains no empty <key></key> tag (bash 3.2 empty-array regression)"
    assert_pattern_absent "$PLIST" '<key>EnvironmentVariables</key>' \
        "plist with no --env omits EnvironmentVariables block entirely"

    # Label key
    assert_pattern_present "$PLIST" '<string>com\.testuser\.syncthing</string>' \
        "plist Label = com.testuser.syncthing"

    # ProgramArguments points to wrapper, NOT the brew bin
    assert_pattern_present "$PLIST" "<string>$WRAPPER</string>" \
        "plist ProgramArguments[0] = wrapper path (rootfs, TCC-safe)"
    assert_pattern_absent "$PLIST" '<string>/Volumes/' \
        "plist contains NO /Volumes/* path (would re-trigger TCC exit 78)"

    # KeepAlive=true so launchd retries if mount comes up later
    assert_pattern_present "$PLIST" '<key>KeepAlive</key>' \
        "plist has KeepAlive key"
    assert_pattern_present "$PLIST" '<key>RunAtLoad</key>' \
        "plist has RunAtLoad key"

    # Logs go to the user's launch-wrapper dir, not /tmp
    assert_pattern_present "$PLIST" '<key>StandardOutPath</key>' \
        "plist has StandardOutPath key"
    assert_pattern_present "$PLIST" '<key>StandardErrorPath</key>' \
        "plist has StandardErrorPath key"
    assert_pattern_present "$PLIST" "<string>${LAUNCH_WRAPPER_LOG_DIR}/syncthing\\.log</string>" \
        "log path under \$LAUNCH_WRAPPER_LOG_DIR/syncthing.log"
fi

# ---------- Idempotency: run install twice, content stable ----------
echo
echo "═══ lib/launch-wrapper.sh — idempotency ═══"
WRAPPER_BEFORE_HASH="$(/bin/cat "$WRAPPER" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
PLIST_BEFORE_HASH="$(/bin/cat "$PLIST" 2>/dev/null | shasum -a 256 | awk '{print $1}')"

launch_wrapper_install_extbrew \
    --svc syncthing \
    --label "com.testuser.syncthing" \
    --brew-bin "$fake_bin" \
    -- serve --no-browser --no-restart

WRAPPER_AFTER_HASH="$(/bin/cat "$WRAPPER" 2>/dev/null | shasum -a 256 | awk '{print $1}')"
PLIST_AFTER_HASH="$(/bin/cat "$PLIST" 2>/dev/null | shasum -a 256 | awk '{print $1}')"

assert_eq "$WRAPPER_BEFORE_HASH" "$WRAPPER_AFTER_HASH" \
    "wrapper content unchanged after second install (idempotent)"
assert_eq "$PLIST_BEFORE_HASH" "$PLIST_AFTER_HASH" \
    "plist content unchanged after second install (idempotent)"

# ---------- WorkingDirectory + env vars optional path ----------
echo
echo "═══ lib/launch-wrapper.sh — workdir + env options ═══"
launch_wrapper_install_extbrew \
    --svc redistest \
    --label "com.testuser.redistest" \
    --brew-bin "/Volumes/External/homebrew/bin/redis-server" \
    --workdir "/Volumes/External/homebrew/var" \
    --env "REDIS_PORT=16399" \
    --env "FOO=bar" \
    -- /Volumes/External/homebrew/etc/redis.conf

PLIST2="$LAUNCH_WRAPPER_PLIST_DIR/com.testuser.redistest.plist"
assert_file_exists "$PLIST2" "redistest plist created"
if [[ -f "$PLIST2" ]]; then
    assert_pattern_present "$PLIST2" '<key>WorkingDirectory</key>' \
        "plist with --workdir adds WorkingDirectory key"
    assert_pattern_present "$PLIST2" '<key>EnvironmentVariables</key>' \
        "plist with --env adds EnvironmentVariables dict"
    assert_pattern_present "$PLIST2" '<key>REDIS_PORT</key>' \
        "plist contains REDIS_PORT env key"
    assert_pattern_present "$PLIST2" '<string>16399</string>' \
        "plist contains REDIS_PORT=16399 value"
    assert_pattern_present "$PLIST2" '<key>FOO</key>' \
        "plist contains FOO env key"
fi

# ---------- teardown_homebrew_plist renames to .bak ----------
echo
echo "═══ lib/launch-wrapper.sh — teardown_homebrew_plist ═══"
HBPLIST="$LAUNCH_WRAPPER_PLIST_DIR/homebrew.mxcl.fakesvc.plist"
echo '<plist></plist>' > "$HBPLIST"
launch_wrapper_teardown_homebrew_plist "fakesvc"
if [[ ! -f "$HBPLIST" ]] && [[ -f "${HBPLIST}.bak" ]]; then
    pass "teardown renames homebrew.mxcl.fakesvc.plist → .bak"
else
    fail "teardown should rename plist to .bak (got: orig=$([[ -f "$HBPLIST" ]] && echo present || echo absent), bak=$([[ -f "${HBPLIST}.bak" ]] && echo present || echo absent))"
fi

# Second teardown call: existing .bak must NOT be overwritten by current plist
echo '<plist>NEW</plist>' > "$HBPLIST"
launch_wrapper_teardown_homebrew_plist "fakesvc"
if [[ ! -f "$HBPLIST" ]] && grep -q '<plist></plist>' "${HBPLIST}.bak" 2>/dev/null; then
    pass "teardown preserves existing .bak (does not overwrite first backup)"
else
    fail "second teardown should preserve existing .bak"
fi

# ---------- Missing required args fail loudly ----------
echo
echo "═══ lib/launch-wrapper.sh — required arg validation ═══"
ASSERT_MSG="install fails when --svc is missing" \
    assert_false "launch_wrapper_install_extbrew --label com.x.y --brew-bin /tmp/x"
ASSERT_MSG="install fails when --label is missing" \
    assert_false "launch_wrapper_install_extbrew --svc x --brew-bin /tmp/x"
ASSERT_MSG="install fails when --brew-bin is missing" \
    assert_false "launch_wrapper_install_extbrew --svc x --label com.x.y"

# ---------------------------------------------------------------------
# Layer 2: topics/80-claude-code/syncthing-service-mac.sh structural
# ---------------------------------------------------------------------
echo
echo "═══ topics/80-claude-code/syncthing-service-mac.sh — wrapper integration ═══"

assert_pattern_present "$TOPIC" '(source|^[[:space:]]*\.).*lib/launch-wrapper\.sh' \
    "80-claude-code sources lib/launch-wrapper.sh (source or dot-include)"

# Branches on BREW_PREFIX (case statement OR helper function with same effect)
assert_pattern_present "$TOPIC" '(case "\$BREW_PREFIX"|_use_wrapper)' \
    "80-claude-code branches on BREW_PREFIX (case stmt or _use_wrapper helper)"
assert_pattern_present "$TOPIC" '/opt/homebrew\|/usr/local' \
    "80-claude-code names canonical prefixes /opt/homebrew + /usr/local"

# Custom-prefix branch invokes the wrapper
assert_pattern_present "$TOPIC" 'launch_wrapper_install_extbrew' \
    "80-claude-code calls launch_wrapper_install_extbrew in custom-prefix branch"
# Note: '--' cannot start a grep ERE pattern (grep parses as option). Use [-]-
# to escape the leading double-dash without losing readability.
assert_pattern_present "$TOPIC" '[-]-svc syncthing' \
    "wrapper call uses --svc syncthing"
assert_pattern_present "$TOPIC" '[-]-label "com\.\$\{USER\}\.syncthing"' \
    "wrapper call labels plist com.\${USER}.syncthing (user-derived)"
assert_pattern_present "$TOPIC" '[-][-] serve --no-browser --no-restart' \
    "wrapper call passes Syncthing v2 args (serve --no-browser --no-restart)"

# Liveness probe after bootstrap (we don't lie about "installed = working")
assert_pattern_present "$TOPIC" 'curl.*127\.0\.0\.1:8384' \
    "80-claude-code probes :8384 after wrapper bootstrap (honest liveness check)"

# Old broken UX must be GONE — no `warn` block telling user to manually
# create a plist. The whole point of f2 is making it automatic.
assert_pattern_absent "$TOPIC" 'workaround: create ~/Library/LaunchAgents' \
    "80-claude-code no longer instructs manual plist creation (regression guard)"

summary
