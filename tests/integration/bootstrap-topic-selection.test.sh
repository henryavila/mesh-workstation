#!/usr/bin/env bash
# tests/integration/bootstrap-topic-selection.test.sh
#
# v2 catalog: setup.sh --list-bundles / --bundle / --server. The numbered
# ONLY_TOPICS / INCLUDE_* topic selectors are gone.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

TESTROOT="$(mktemp -d /tmp/mesh-workstation-topic-selection.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

echo
echo "═══ bootstrap bundle selection ═══"

list_out="$(HOME="$TESTROOT/home-list" bash "$REPO_ROOT/setup.sh" --list-bundles 2>&1)"
assert_contains "$list_out" "foundation/base" \
    "bootstrap --list-bundles lists foundation/base"
assert_contains "$list_out" "apps/flyenv" \
    "bootstrap --list-bundles includes FlyEnv"
assert_not_contains "$list_out" "web/nginx-php-fpm" \
    "bootstrap --list-bundles does not list the removed web stack"
assert_contains "$list_out" "ai/" \
    "bootstrap --list-bundles includes AI bundles"
assert_contains "$list_out" "personal/personal" \
    "unflagged --list-bundles still shows personal/personal"
if [[ ! -e "$TESTROOT/home-list/.local/state/mesh" ]]; then
    pass "bootstrap --list-bundles is read-only and does not create runtime state"
else
    fail "bootstrap --list-bundles should not create runtime state"
fi

dry_out="$(
    HOME="$TESTROOT/home-dry" \
    XDG_CONFIG_HOME="$TESTROOT/home-dry/.config" \
    XDG_STATE_HOME="$TESTROOT/home-dry/.local/state" \
    NON_INTERACTIVE=1 \
        bash "$REPO_ROOT/setup.sh" --non-interactive --dry-run \
            --bundle shell-terminal/cli-tools --bundle shell-terminal/zsh 2>&1
)"
assert_contains "$dry_out" "shell-terminal/cli-tools" \
    "--bundle shell-terminal/cli-tools is in the dry-run plan"
assert_contains "$dry_out" "shell-terminal/zsh" \
    "--bundle shell-terminal/zsh is in the dry-run plan"
assert_not_contains "$dry_out" "personal/personal" \
    "explicit --bundle list does not apply personal/personal"
assert_not_contains "$dry_out" "web/nginx-php-fpm" \
    "unrelated web stack is not pulled in by a shell-only --bundle list"

php_out="$(
    HOME="$TESTROOT/home-php" \
    XDG_CONFIG_HOME="$TESTROOT/home-php/.config" \
    XDG_STATE_HOME="$TESTROOT/home-php/.local/state" \
        bash "$REPO_ROOT/setup.sh" --server --non-interactive --dry-run \
            --bundle languages/php 2>&1
)"
assert_contains "$php_out" "languages/php" \
    "server rejects a removed bundle id"
assert_not_contains "$php_out" "personal/personal" \
    "rejected server bundle does not apply personal"

ai_only_out="$(
    HOME="$TESTROOT/home-ai-only" \
    XDG_CONFIG_HOME="$TESTROOT/home-ai-only/.config" \
    XDG_STATE_HOME="$TESTROOT/home-ai-only/.local/state" \
        bash "$REPO_ROOT/setup.sh" --non-interactive --dry-run \
            --bundle ai/claude-code 2>&1
)"
assert_contains "$ai_only_out" "ai/claude-code" \
    "AI tools run as ai/claude-code when explicitly bundled"

summary
