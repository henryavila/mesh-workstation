#!/usr/bin/env bash
# Fixture variables are consumed by sourced production functions.
# shellcheck disable=SC2034
# setup.sh asks for a separate Homebrew path and exports BREW_CUSTOM_PREFIX
# before the engine is piped through tee (foundation's own prompt has no TTY).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# log.sh defines fail(); assert.sh must be sourced after it so failures count.
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$ROOT/scripts/lib/brew-prefix-offer.sh"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

assert_file_contains "$ROOT/setup.sh" 'offer_separate_brew_prefix' \
    "setup.sh asks for the prefix before the engine"
assert_file_contains "$ROOT/setup.sh" 'brew-prefix-offer.sh' \
    "setup.sh sources the offer helper"
assert_file_contains "$ROOT/scripts/lib/brew-prefix-offer.sh" 'export BREW_CUSTOM_PREFIX=' \
    "offer exports BREW_CUSTOM_PREFIX"

assert_true "brew_prefix_detectable /opt/homebrew" "canonical Apple Silicon prefix is detectable"
ASSERT_MSG="canonical Intel prefix is detectable" assert_true "brew_prefix_detectable /usr/local"
ASSERT_MSG="External/homebrew is detectable" assert_true "brew_prefix_detectable /Volumes/External/homebrew"
ASSERT_MSG="disambiguated External 1/homebrew is detectable" \
    assert_true "brew_prefix_detectable '/Volumes/External 1/homebrew'"
ASSERT_MSG="a non-External volume is not detectable with an empty PATH" \
    assert_false "brew_prefix_detectable /Volumes/Backup/homebrew"
ASSERT_MSG="trailing slash still counts as detectable" \
    assert_true "brew_prefix_detectable /Volumes/External/homebrew/"

CONFIRMS=0
ANSWER_YES=0
TYPED_PATH=""
ASK_LOG="/tmp/brew-offer-asks.$$"

# ask_line runs inside $(...) in the offer, so its assignments do not survive.
# Record the call in a file. confirm runs in the current shell.
confirm() { CONFIRMS=$((CONFIRMS + 1)); [[ "$ANSWER_YES" == "1" ]]; }
ask_line() { printf '%s\n' "${2:-}" >> "$ASK_LOG"; printf '%s' "$TYPED_PATH"; }
ask_count() { [[ -f "$ASK_LOG" ]] && wc -l < "$ASK_LOG" | tr -d ' ' || printf '0'; }
ask_default() { [[ -f "$ASK_LOG" ]] && tail -n 1 "$ASK_LOG" || true; }

reset_offer() {
    OS=mac
    BREW_BIN=""
    BREW_CUSTOM_PREFIX=""
    NON_INTERACTIVE=0
    DRY_RUN=0
    ADOPT_MODE=0
    BREW_OFFER_FORCE_TTY=1
    CONFIRMS=0
    ANSWER_YES=0
    TYPED_PATH=""
    : > "$ASK_LOG"
    unset -f state_get 2>/dev/null || true
    brew_prefix_suggest() { printf '%s' /Volumes/TestVol/homebrew; }
}

# Run in this shell. A $(...) subshell would drop the export and the confirm count.
run_offer() {
    OFFER_RC=0
    offer_separate_brew_prefix >/tmp/brew-offer-out.$$ 2>/tmp/brew-offer-err.$$ || OFFER_RC=$?
}

reset_offer
ANSWER_YES=1
TYPED_PATH="/Volumes/TestVol/homebrew/"
run_offer
assert_eq "$OFFER_RC" "0" "yes + absolute path returns 0"
assert_eq "$BREW_CUSTOM_PREFIX" "/Volumes/TestVol/homebrew" "yes exports the path with the trailing slash stripped"
assert_eq "$CONFIRMS" "1" "yes asks the confirm once"
assert_eq "$(ask_count)" "1" "yes asks for the path"
assert_eq "$(ask_default)" "/Volumes/TestVol/homebrew" "path prompt is seeded with the suggestion"

reset_offer
ANSWER_YES=0
run_offer
assert_eq "$OFFER_RC" "0" "no returns 0"
assert_eq "$BREW_CUSTOM_PREFIX" "/opt/homebrew" "no exports the canonical prefix"
assert_eq "$(ask_count)" "0" "no does not ask for a path"

reset_offer
ANSWER_YES=1
TYPED_PATH="homebrew"
run_offer
assert_eq "$OFFER_RC" "0" "relative path returns 0"
assert_eq "$BREW_CUSTOM_PREFIX" "/opt/homebrew" "relative path falls back to /opt/homebrew"

reset_offer
BREW_CUSTOM_PREFIX="/Volumes/External/homebrew"
run_offer
assert_eq "$OFFER_RC" "0" "preset env returns 0"
assert_eq "$BREW_CUSTOM_PREFIX" "/Volumes/External/homebrew" "preset env is kept"
assert_eq "$CONFIRMS" "0" "preset env skips the question"

reset_offer
BREW_BIN="/opt/homebrew/bin/brew"
run_offer
assert_eq "$OFFER_RC" "0" "existing brew returns 0"
assert_eq "$BREW_CUSTOM_PREFIX" "" "existing brew does not export a prefix"
assert_eq "$CONFIRMS" "0" "existing brew skips the question"

reset_offer
NON_INTERACTIVE=1
ANSWER_YES=1
run_offer
assert_eq "$OFFER_RC" "0" "non-interactive returns 0"
assert_eq "$BREW_CUSTOM_PREFIX" "" "non-interactive leaves the variable unset"
assert_eq "$CONFIRMS" "0" "non-interactive does not ask even with FORCE_TTY"

reset_offer
OS=linux
ANSWER_YES=1
run_offer
assert_eq "$OFFER_RC" "0" "linux returns 0"
assert_eq "$CONFIRMS" "0" "linux does not ask"
assert_eq "$BREW_CUSTOM_PREFIX" "" "linux does not export a prefix"

reset_offer
state_get() { printf '%s' /Volumes/External/homebrew; }
ANSWER_YES=1
run_offer
assert_eq "$OFFER_RC" "0" "recorded state returns 0"
assert_eq "$BREW_CUSTOM_PREFIX" "" "recorded state does not override with a new export"
assert_eq "$CONFIRMS" "0" "recorded state skips the question"

reset_offer
ADOPT_MODE=1
ANSWER_YES=1
run_offer
assert_eq "$CONFIRMS" "0" "--adopt does not ask"

reset_offer
DRY_RUN=1
ANSWER_YES=1
run_offer
assert_eq "$CONFIRMS" "0" "--dry-run does not ask"

reset_offer
ANSWER_YES=1
TYPED_PATH="$(mktemp -d)"
touch "$TYPED_PATH/marker"
run_offer
assert_eq "$OFFER_RC" "1" "non-empty directory refuses"
assert_eq "$BREW_CUSTOM_PREFIX" "" "non-empty directory does not export"
rm -rf "$TYPED_PATH"

rm -f /tmp/brew-offer-out.$$ /tmp/brew-offer-err.$$ "$ASK_LOG"
summary
