#!/usr/bin/env bash
# Regression test for auto-update.sh operational defaults.
#
# THE BUG: auto-update.sh runs under `set -u` and reads tunables BARE —
# AUTO_UPDATE_FETCH_TIMEOUT (fetch) and AUTO_UPDATE_SUDO_REGEX (sudo pre-check)
# — with NO fallback in the script; the defaults lived only in the
# auto-update.conf.example TEMPLATE. A deployed ~/.config/mesh/config.env that
# predates a tunable left it unbound → `unbound variable` crash. It was masked
# by the `branch != main` gate (returns before the fetch); `mesh update --force`
# proceeds past the gate and surfaced it (the fetch subshell crashed → every
# repo silently "failed to fetch" and nothing updated).
#
# A config with ONLY the required AUTO_UPDATE_REPOS must still run cleanly.
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
AU="$REPO_ROOT/scripts/runners/auto-update.sh"
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

git init -q --bare "$TMP/remote.git"
git clone -q "$TMP/remote.git" "$TMP/work" 2>/dev/null
(
    cd "$TMP/work" || exit 1
    printf '#!/usr/bin/env bash\nexit 0\n' > install.sh   # identity-type repo
    git add install.sh; git commit -qm init; git branch -M main; git push -q origin main
    git checkout -q -b feat; git push -q -u origin feat
) 2>/dev/null
OLD="$(git -C "$TMP/work" rev-parse HEAD)"
git clone -q "$TMP/remote.git" "$TMP/pusher" 2>/dev/null
(
    cd "$TMP/pusher" || exit 1
    git checkout -q feat; echo x > new.txt; git add new.txt
    git commit -qm "remote ahead"; git push -q origin feat
) 2>/dev/null
NEW="$(git -C "$TMP/pusher" rev-parse feat)"

# MINIMAL config: ONLY the required repo list — NO fetch-timeout / sudo-regex.
# This is the deployed-config-predates-the-tunable scenario.
printf 'AUTO_UPDATE_REPOS=("%s")\n' "$TMP/work" > "$TMP/conf"

mkdir -p "$TMP/st"; printf '%s\n' "$OLD" > "$TMP/st/last-applied-work"
out="$(AUTO_UPDATE_CONF="$TMP/conf" AUTO_UPDATE_STATE_DIR="$TMP/st" bash "$AU" --force 2>&1)"; rc=$?

assert_not_contains "$out" "unbound variable" "no unbound-variable crash on a minimal config"
assert_eq "$rc" "0" "auto-update exits 0 on a minimal config"
assert_eq "$(git -C "$TMP/work" rev-parse HEAD)" "$NEW" "the update actually completed (HEAD advanced)"

# Leftover/partial config.env (pre-seed installer, or a guest file with only
# CODE_DIR). The zsh login hook sources it as CONF; AUTO_UPDATE_REPOS is unset.
# setup.sh now seeds the array on a normal install; keep these guards for files
# that predate that seed.
printf 'CODE_DIR=%s\n' "$TMP/code" > "$TMP/conf-partial"
mkdir -p "$TMP/st2" "$TMP/st3" "$TMP/st4"

out_ss="$(AUTO_UPDATE_CONF="$TMP/conf-partial" AUTO_UPDATE_STATE_DIR="$TMP/st2" \
    bash "$AU" --from-shell-start 2>&1)"; rc_ss=$?
assert_not_contains "$out_ss" "unbound variable" \
    "CODE_DIR-only config.env does not crash under set -u on shell-start"
assert_eq "$rc_ss" "0" "--from-shell-start with no AUTO_UPDATE_REPOS is a silent skip"

out_man="$(AUTO_UPDATE_CONF="$TMP/conf-partial" AUTO_UPDATE_STATE_DIR="$TMP/st3" \
    bash "$AU" 2>&1)"; rc_man=$?
assert_contains "$out_man" "AUTO_UPDATE_REPOS is empty" \
    "manual run still reports empty AUTO_UPDATE_REPOS"
assert_eq "$rc_man" "1" "manual run with empty AUTO_UPDATE_REPOS exits 1"

out_miss="$(AUTO_UPDATE_CONF="$TMP/no-such-conf" AUTO_UPDATE_STATE_DIR="$TMP/st4" \
    bash "$AU" --from-shell-start 2>&1)"; rc_miss=$?
assert_not_contains "$out_miss" "unbound variable" \
    "missing config.env does not crash under set -u on shell-start"
assert_eq "$rc_miss" "0" "--from-shell-start with missing config is a silent skip"

summary
