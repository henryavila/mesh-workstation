#!/usr/bin/env bash
# tests/integration/regression-recent-fixes.test.sh
#
# Static regression tests for the bug class fixed in the 2026-04-22 session.
# Each fix corresponds to either a presence assertion (the fix is in place)
# or an absence assertion (the anti-pattern is gone). Grep-based — no mocking,
# no actual command execution — fast, deterministic, impossible to bypass
# silently.
#
# When adding a new fix in the same class, append the corresponding test
# below so future refactors cannot quietly regress the behavior.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$ROOT/tests/lib/assert.sh"

BOOTSTRAP="$ROOT/setup.sh"
LOG="$ROOT/scripts/lib/log.sh"
# NOTE: the old lib/menu.sh (F9.5 whiptail flow) was deleted in audit T-005 —
# the interactive menu is now the Ink TUI in scripts/menu/ (its own JS tests).
# Assertions that probed menu.sh were removed here.

# Post-migration each topic's logic is split across multiple custom .sh files
# under mac/, wsl/, and extras/. We bundle each topic's customs into a single
# temp file so the existing pattern-based assertions still grep against the
# topic's complete install logic (the *invariants* are file-location-agnostic).
_bundle_dir="$(mktemp -d -t mesh-workstation-test-bundle.XXXXXX)"
trap 'rm -rf "$_bundle_dir"' EXIT

_make_bundle() {
    local out="$1"; shift
    local dir f
    : > "$out"
    for dir in "$@"; do
        [[ -d "$dir" ]] || continue
        while IFS= read -r f; do
            printf '\n# === BUNDLE: %s ===\n' "$f" >> "$out"
            cat "$f" >> "$out"
        done < <(find "$dir" -maxdepth 2 -name '*.sh' -type f 2>/dev/null | LC_ALL=C sort)
    done
}

REMOTE_MAC="$_bundle_dir/70-remote-access-mac.bundle.sh"

_make_bundle "$REMOTE_MAC" "$ROOT/topics/remote-access"

# Helper: count matches of an extended regex in a file (works on bash 3.2)
_count_matches() {
    local pattern="$1" file="$2"
    grep -cE "$pattern" "$file" 2>/dev/null || echo 0
}

# Helper: assert pattern appears at least once in file
assert_pattern_present() {
    local file="$1" pattern="$2" msg="$3"
    if grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        fail "$msg (pattern '$pattern' not found in $file)"
    fi
}

# Helper: assert pattern does NOT appear in file
assert_pattern_absent() {
    local file="$1" pattern="$2" msg="$3"
    if ! grep -qE "$pattern" "$file" 2>/dev/null; then
        pass "$msg"
    else
        local matches
        matches=$(grep -nE "$pattern" "$file" 2>/dev/null | head -3)
        fail "$msg (anti-pattern '$pattern' found in $file)"
        printf "      first matches:\n%s\n" "$matches" | sed 's/^/        /' >&2
    fi
}

# Helper: assert pattern absent in CODE (excludes comment-only lines).
# A "comment-only line" is one whose first non-whitespace character is #.
# Inline comments (`code # comment`) still count as code — that's correct
# because the code itself is what we test for.
assert_code_absent() {
    local file="$1" pattern="$2" msg="$3"
    local matches
    matches=$(grep -nE "$pattern" "$file" 2>/dev/null \
        | grep -vE '^[[:digit:]]+:[[:space:]]*#' || true)
    if [[ -z "$matches" ]]; then
        pass "$msg"
    else
        fail "$msg (anti-pattern '$pattern' found as CODE in $file)"
        printf "      first matches:\n%s\n" "$(echo "$matches" | head -3)" \
            | sed 's/^/        /' >&2
    fi
}

echo
echo "═══ /etc/paths.d/ injection for non-standard BREW_PREFIX (Mac sshd-exec PATH) ═══"

assert_pattern_present "$REMOTE_MAC" '/etc/paths.d/60-extbrew' \
    "70-remote-access/install.mac.sh — writes /etc/paths.d/60-extbrew for non-standard prefix"

assert_pattern_present "$REMOTE_MAC" 'symlinked mosh-server' \
    "70-remote-access/install.mac.sh — belt-and-suspenders symlink in /usr/local/bin"

assert_pattern_present "$ROOT/scripts/lib/deploy.sh" 'managed by (mesh-workstation|dev-bootstrap)' \
    "lib/deploy.sh — overwrite-protection accepts both old and new marker"

echo
echo "═══ fzf shell integration: do NOT source completion.zsh (fzf-tab owns TAB) ═══"

# Regression 2026-04-23: fzf's completion.zsh runs \`bindkey '^I' fzf-completion\`
# at the end of its source, which races against fzf-tab's own TAB rebinding.
# When fzf-tab fails to load (turbo regression, zinit issue, etc.), TAB stays
# stuck on the primitive fzf-completion — user reports "autocomplete not
# contextual". Defense in depth: only source key-bindings.zsh (Ctrl-R / Ctrl-T
# / Alt-C); TAB is owned exclusively by fzf-tab, falling back to native zsh
# \`expand-or-complete\` if fzf-tab is unavailable.
TUX_ZSH="$ROOT/topics/shell-terminal/templates/cli-tools/zshrc.d-20-terminal-ux.sh.template"

assert_pattern_absent "$TUX_ZSH" 'shell/completion\.zsh' \
    "20-terminal-ux zsh template — does NOT source fzf's completion.zsh (stomps TAB / fzf-tab)"

assert_pattern_present "$TUX_ZSH" 'shell/key-bindings\.zsh' \
    "20-terminal-ux zsh template — DOES source fzf key-bindings.zsh (Ctrl-R / Ctrl-T / Alt-C)"

echo
echo "═══ Topic rename complete: no '60-laravel-stack' references in code ═══"

# Allow:
#   - this test file itself (self-references the string in regex literals)
#   - comment lines explaining the rename history (`# was 60-laravel-stack ...`)
# Forbid: any actual code reference to the old topic name.
laravel_refs=$(grep -rn '60-laravel-stack' "$ROOT" \
    --include='*.sh' --include='*.md' --include='*.ps1' \
    --include='*.txt' --include='*.conf' --include='*.template' \
    2>/dev/null \
    | grep -v "$HERE/regression-recent-fixes.test.sh" \
    | grep -vE ':[[:space:]]*#' \
    | grep -vE '^\.git/' \
    || true)
ref_count=$(printf '%s\n' "$laravel_refs" | grep -c . || true)
if [[ "${ref_count:-0}" -eq 0 ]]; then
    pass "no '60-laravel-stack' code references remain (rename complete)"
else
    fail "'60-laravel-stack' still referenced in code:"
    printf '%s\n' "$laravel_refs" | sed 's/^/        /' >&2
fi

echo
echo "═══ Legacy INCLUDE_* pre-seeds no longer drive setup selection ═══"

assert_pattern_present "$BOOTSTRAP" 'selections.list' \
    "setup.sh — selection source is selections.list, not legacy INCLUDE_* gates"

assert_pattern_absent "$BOOTSTRAP" 'INCLUDE_LARAVEL' \
    "setup.sh — no longer consumes legacy INCLUDE_LARAVEL directly"

assert_pattern_present "$ROOT/scripts/runners/auto-update.sh" \
    'unset INCLUDE_DOCKER INCLUDE_WEBSTACK INCLUDE_LARAVEL INCLUDE_REMOTE' \
    "auto-update.sh — clears legacy INCLUDE_* gates before non-interactive setup"

echo
echo "═══ 2026-04-23 : auto-chsh + secrets.env scaffold ═══"

# Issue 1 — zsh auto-chsh. Bootstrap must try sudo chsh/usermod before
# falling through to the advisory, default-on, CHSH_AUTO=0 opts out.
TUX_WSL="$_bundle_dir/20-terminal-ux-wsl.bundle.sh"; _make_bundle "$TUX_WSL" "$ROOT/topics/shell-terminal/wsl" "$ROOT/topics/shell-terminal"
TUX_MAC="$_bundle_dir/20-terminal-ux-mac.bundle.sh"; _make_bundle "$TUX_MAC" "$ROOT/topics/shell-terminal/mac" "$ROOT/topics/shell-terminal"

assert_pattern_present "$TUX_WSL" 'CHSH_AUTO:-1' \
    "20-terminal-ux/install.wsl.sh — CHSH_AUTO defaults to 1 (auto-on)"

assert_pattern_present "$TUX_WSL" 'sudo -n chsh -s' \
    "20-terminal-ux/install.wsl.sh — attempts sudo chsh with cached ticket"

assert_pattern_present "$TUX_WSL" 'sudo -n usermod -s' \
    "20-terminal-ux/install.wsl.sh — falls back to sudo usermod when chsh refused"

assert_pattern_present "$TUX_WSL" 'grep -qxF "\$zsh_bin" /etc/shells' \
    "20-terminal-ux/install.wsl.sh — /etc/shells check before chsh"

# LDAP/SSSD fallback: chsh returns 0 but /etc/passwd doesn't update —
# the code must detect this and emit an advisory, not claim success.
assert_pattern_present "$TUX_WSL" 'managed externally' \
    "20-terminal-ux/install.wsl.sh — advisory when account is LDAP/SSSD-managed"

assert_pattern_present "$TUX_MAC" 'CHSH_AUTO:-1' \
    "20-terminal-ux/install.mac.sh — CHSH_AUTO defaults to 1 (auto-on)"

assert_pattern_present "$TUX_MAC" 'sudo -n chsh -s' \
    "20-terminal-ux/install.mac.sh — attempts sudo chsh with cached ticket"

assert_pattern_present "$TUX_MAC" 'MDM/directory-managed' \
    "20-terminal-ux/install.mac.sh — advisory when directory is authoritative"

# chsh interactive fallback — sudo -n is a fast-path only; on a TTY we
# must also try plain `sudo chsh` so the user gets a single password
# prompt instead of an advisory when the upfront ticket has expired.
# This was the root cause of the failed chsh on crc (corporate WSL).
assert_pattern_present "$TUX_WSL" 'sudo chsh -s.*</dev/tty' \
    "20-terminal-ux/install.wsl.sh — interactive sudo chsh fallback via /dev/tty"

assert_pattern_present "$TUX_WSL" 'NON_INTERACTIVE:-0.*!=.*1' \
    "20-terminal-ux/install.wsl.sh — interactive fallback skipped in NON_INTERACTIVE"

assert_pattern_present "$TUX_MAC" 'sudo chsh -s.*</dev/tty' \
    "20-terminal-ux/install.mac.sh — interactive sudo chsh fallback via /dev/tty"

assert_pattern_present "$TUX_MAC" 'NON_INTERACTIVE:-0.*!=.*1' \
    "20-terminal-ux/install.mac.sh — interactive fallback skipped in NON_INTERACTIVE"

# atuin detection — must use `atuin status` exit code, NOT the stale
# ~/.local/share/atuin/session filesystem check. v18 stopped creating
# that file; filesystem-based detection gave a permanent false-negative
# advisory on logged-in machines (observed on ultron + crc + mac).
assert_pattern_present "$TUX_WSL" 'atuin status >/dev/null 2>&1' \
    "20-terminal-ux/install.wsl.sh — atuin detection uses 'atuin status' exit code"

assert_pattern_absent "$TUX_WSL" '\[ ! -f "\$HOME/\.local/share/atuin/session" \]' \
    "20-terminal-ux/install.wsl.sh — no longer checks ~/.local/share/atuin/session (v18 dropped it)"

assert_pattern_present "$TUX_MAC" 'atuin status >/dev/null 2>&1' \
    "20-terminal-ux/install.mac.sh — atuin detection uses 'atuin status' exit code"

assert_pattern_absent "$TUX_MAC" '\[ ! -f "\$HOME/\.local/share/atuin/session" \]' \
    "20-terminal-ux/install.mac.sh — no longer checks ~/.local/share/atuin/session (v18 dropped it)"

# Atuin login is now attempted inline when interactive — same design as
# CHSH_AUTO. Deferring to a post-hoc manual step was inconsistent with
# the auto-chsh/ngrok-passwordbox pattern shipped alongside it.
assert_pattern_present "$TUX_WSL" 'ATUIN_LOGIN_AUTO:-1' \
    "20-terminal-ux/install.wsl.sh — ATUIN_LOGIN_AUTO defaults to 1 (auto-on)"

assert_pattern_present "$TUX_WSL" 'atuin login </dev/tty' \
    "20-terminal-ux/install.wsl.sh — runs 'atuin login' inline via /dev/tty"

# The upstream setup.atuin.sh script now has its own import/register/setup
# prompts. `mesh run update -f` calls setup.sh with --non-interactive
# but still allocates ssh -tt, so upstream sees /dev/tty unless we pass
# its explicit flag. Regression: crc appeared stuck after "Atuin installed
# successfully!" and each ENTER answered one hidden upstream prompt.
assert_pattern_present "$TUX_WSL" 'NON_INTERACTIVE:-0.*=.*1' \
    "20-terminal-ux/install.wsl.sh — checks NON_INTERACTIVE before setup.atuin.sh"

assert_pattern_present "$TUX_WSL" 'sh -s -- --non-interactive' \
    "20-terminal-ux/install.wsl.sh — passes --non-interactive to setup.atuin.sh in automation"

assert_pattern_present "$TUX_MAC" 'ATUIN_LOGIN_AUTO:-1' \
    "20-terminal-ux/install.mac.sh — ATUIN_LOGIN_AUTO defaults to 1 (auto-on)"

assert_pattern_present "$TUX_MAC" 'atuin login </dev/tty' \
    "20-terminal-ux/install.mac.sh — runs 'atuin login' inline via /dev/tty"

# TTY gate must test for controlling terminal via /dev/tty, NOT via
# `-t 1`. setup.sh pipes each installer's stdout to `tee -a LOG`,
# which makes `-t 1` always false even when the human is still at the
# terminal. This silently disabled every interactive fallback (chsh
# prompt + atuin login) in actual runs. /dev/tty is the canonical ctty
# check — opens iff the process has a controlling terminal.
assert_pattern_present "$TUX_WSL" '_has_ctty\(\) \{' \
    "20-terminal-ux/install.wsl.sh — defines _has_ctty helper"

assert_pattern_present "$TUX_WSL" ': </dev/tty >/dev/null 2>&1' \
    "20-terminal-ux/install.wsl.sh — _has_ctty uses /dev/tty open test"

assert_pattern_absent "$TUX_WSL" '\[ -t 0 \] && \[ -t 1 \]' \
    "20-terminal-ux/install.wsl.sh — no longer gates on '-t 1' (broken under 'tee' pipe)"

assert_pattern_present "$TUX_MAC" '_has_ctty\(\) \{' \
    "20-terminal-ux/install.mac.sh — defines _has_ctty helper"

assert_pattern_present "$TUX_MAC" ': </dev/tty >/dev/null 2>&1' \
    "20-terminal-ux/install.mac.sh — _has_ctty uses /dev/tty open test"

assert_pattern_absent "$TUX_MAC" '\[ -t 0 \] && \[ -t 1 \]' \
    "20-terminal-ux/install.mac.sh — no longer gates on '-t 1' (broken under 'tee' pipe)"

# Issue 2 — secrets scaffold. setup.sh must source lib/secrets.sh
# and call secrets_load AFTER log.sh, BEFORE the menu runs.
SECRETS_LIB="$ROOT/scripts/lib/secrets.sh"

assert_file_exists "$SECRETS_LIB" \
    "lib/secrets.sh — new helper in place"

assert_pattern_present "$BOOTSTRAP" 'source "\$HERE/scripts/lib/secrets.sh"' \
    "setup.sh — sources scripts/lib/secrets.sh"

assert_pattern_present "$BOOTSTRAP" 'secrets_load' \
    "setup.sh — calls secrets_load"

# Order check: secrets_load must run before the interactive (Ink) menu so item
# scripts and `when:` see the tokens. setup.sh sources secrets right after the
# state-dir setup and before run_menu_if_available.
secrets_line=$(grep -n 'secrets_load' "$BOOTSTRAP" | head -1 | cut -d: -f1)
menu_line=$(grep -n 'run_menu_if_available' "$BOOTSTRAP" | head -1 | cut -d: -f1)
if [[ -n "$secrets_line" && -n "$menu_line" ]] && [[ "$secrets_line" -lt "$menu_line" ]]; then
    pass "setup.sh — secrets_load runs before the menu (line $secrets_line < $menu_line)"
else
    fail "setup.sh — secrets_load must run before the menu (secrets=$secrets_line, menu=$menu_line)"
fi

# (ngrok-capture assertions removed with the dead menu.sh in T-005 — the ngrok
# authtoken is now a tier-2 env-token added via `mesh secret add`, not captured
# locally by any menu.)

# Taxonomy check: secrets.sh header must document forbidden keys so a future
# contributor can't "just add GITHUB_TOKEN" without reading the rationale.
assert_pattern_present "$SECRETS_LIB" 'GITHUB_TOKEN.*gh auth' \
    "lib/secrets.sh — documents GITHUB_TOKEN belongs to gh auth, not here"

assert_pattern_present "$SECRETS_LIB" 'ATUIN_KEY.*atuin login' \
    "lib/secrets.sh — documents ATUIN_KEY belongs to atuin login, not here"

echo
echo "═══ 2026-04-23 : stale \$SHELL + tmux SHELL detection (crc regression) ═══"

# Observed on crc: chsh succeeded (getent passwd = /usr/bin/zsh) but the
# running ssh/mosh session still had $SHELL=/bin/bash cached from before
# chsh. tmux server, started under that stale env, then propagated
# SHELL=/bin/bash to every new pane → status-position wrong, Moshi
# misdetected sessions, subprocesses opened the wrong shell.
#
# Static tests that the 2 detection blocks exist in both installers.
# The actual runtime behavior is hard to unit-test (requires a session
# with a real $SHELL mismatch + a running tmux server) — the static
# asserts ensure the code is present and anyone refactoring gets told
# before they silently drop the detection.

# --- $SHELL vs /etc/passwd mismatch detection (WSL) ---
assert_pattern_present "$TUX_WSL" '\$SHELL.*!=.*passwd_shell|passwd_shell.*!=.*\$SHELL' \
    "20-terminal-ux/install.wsl.sh — detects \$SHELL ≠ /etc/passwd mismatch"

assert_pattern_present "$TUX_WSL" 'exit this ssh/mosh session' \
    "20-terminal-ux/install.wsl.sh — advisory instructs session reconnect (not just 'exec zsh')"

assert_pattern_present "$TUX_WSL" 'tmux kill-server' \
    "20-terminal-ux/install.wsl.sh — advisory mentions tmux kill-server for stale server"

# --- tmux server stale SHELL detection (WSL) ---
assert_pattern_present "$TUX_WSL" 'tmux show-environment -g SHELL' \
    "20-terminal-ux/install.wsl.sh — probes tmux server's cached SHELL"

# --- same for Mac via dscl ---
assert_pattern_present "$TUX_MAC" 'UserShell.*!=.*\$SHELL|\$SHELL.*!=.*UserShell|passwd_shell.*!=.*\$SHELL|\$SHELL.*!=.*passwd_shell' \
    "20-terminal-ux/install.mac.sh — detects \$SHELL ≠ dscl UserShell mismatch"

assert_pattern_present "$TUX_MAC" 'exit this ssh/mosh session' \
    "20-terminal-ux/install.mac.sh — advisory instructs session reconnect"

assert_pattern_present "$TUX_MAC" 'tmux kill-server' \
    "20-terminal-ux/install.mac.sh — advisory mentions tmux kill-server"

assert_pattern_present "$TUX_MAC" 'tmux show-environment -g SHELL' \
    "20-terminal-ux/install.mac.sh — probes tmux server's cached SHELL"

# tmux.conf must force default-shell from the authoritative login-shell
# registry (getent passwd on Linux, dscl on macOS), NOT from $SHELL env
# — because $SHELL is frozen at login time and goes stale after chsh.
# Without this, `tmux new` after a fresh reconnect picks up the right
# shell, but `tmux attach` to an old server (carrying stale env) keeps
# opening the wrong shell. With this, a post-kill-server restart loads
# tmux.conf and resolves default-shell from /etc/passwd — authoritative.
TMUX_CONF="$ROOT/topics/shell-terminal/templates/tmux/tmux.conf"

assert_file_exists "$TMUX_CONF" \
    "40-tmux/templates/tmux.conf — exists"

assert_pattern_present "$TMUX_CONF" 'default-shell' \
    "40-tmux/templates/tmux.conf — sets default-shell (not relying on \$SHELL env)"

assert_pattern_present "$TMUX_CONF" 'getent passwd' \
    "40-tmux/templates/tmux.conf — resolves shell via getent passwd (Linux)"

assert_pattern_present "$TMUX_CONF" 'dscl.*UserShell' \
    "40-tmux/templates/tmux.conf — resolves shell via dscl (macOS)"

assert_pattern_present "$TMUX_CONF" 'pane_current_path' \
    "40-tmux/templates/tmux.conf — status directory uses live pane_current_path"

assert_code_absent "$TMUX_CONF" '@dev_bootstrap_pane_cwd' \
    "40-tmux/templates/tmux.conf — no runtime dependency on stale @dev_bootstrap_pane_cwd"

assert_pattern_absent "$TMUX_CONF" 'SSH_CONNECTION' \
    "40-tmux/templates/tmux.conf — does not infer inbound SSH as status"

assert_pattern_present "$TMUX_CONF" '#\{user\}@#h' \
    "40-tmux/templates/tmux.conf — host card shows user@short-host"

assert_pattern_absent "$TMUX_CONF" '@dev_bootstrap_outbound_ssh_context' \
    "40-tmux/templates/tmux.conf — no fragile outbound SSH status context"

assert_pattern_absent "$TMUX_CONF" '󰣀' \
    "40-tmux/templates/tmux.conf — no separate SSH card in nested-tmux model"

assert_pattern_present "$TMUX_CONF" 'client_width' \
    "40-tmux/templates/tmux.conf — line 2 is sized by client_width for cwd + user@host"

# Advisory text must NOT claim `exec zsh` is a sufficient fix — that
# only changes the running process, not \$SHELL, so tmux/mosh etc still
# inherit the stale value. The original "exec zsh" hint is still fine
# as a LOCAL prompt fix as long as the advisory ALSO explains the full
# fix via reconnect. We assert the reconnect text is present; we don't
# forbid 'exec zsh' because it's still a useful convenience.

echo
echo "═══ 40-tmux ships generic tmux helpers (tl / ta / tn / tm) ═══"

# These used to live in Henry's private dotfiles; lifted to the
# public mesh-workstation after the 'tm' helper proved useful enough
# to belong in the shared baseline. The dotfiles-private file
# should NOT redeclare them — the aliases_private_keeps_only_project
# assertion catches accidental drift.
TMUX_BASHRC="$ROOT/topics/shell-terminal/templates/tmux/bashrc.d-40-tmux.sh"
TMUX_ZSHRC="$ROOT/topics/shell-terminal/templates/tmux/zshrc.d-40-tmux.sh"

assert_file_exists "$TMUX_BASHRC" \
    "40-tmux — bashrc fragment exists"
assert_file_exists "$TMUX_ZSHRC" \
    "40-tmux — zshrc fragment exists"

for f in "$TMUX_BASHRC" "$TMUX_ZSHRC"; do
    base="$(basename "$f")"
    assert_pattern_present "$f" "alias tl='tmux ls'" \
        "$base — ships 'tl' (list sessions)"
    assert_pattern_present "$f" "ta()" \
        "$base — ships 'ta' as a function"
    assert_pattern_present "$f" "tmux attach -t" \
        "$base — 'ta' attaches by name outside tmux"
    assert_pattern_present "$f" "tmux switch-client -t" \
        "$base — 'ta' switches clients instead of nesting inside tmux"
    assert_pattern_present "$f" "alias tn='tmux new -s'" \
        "$base — ships 'tn' (new by name)"
    assert_pattern_present "$f" "tm()" \
        "$base — ships 'tm' as a function"
    assert_pattern_present "$f" "tmux new-session -A -s main" \
        "$base — 'tm' attaches-or-creates 'main' outside tmux"
    assert_pattern_present "$f" "tmux switch-client -t main" \
        "$base — 'tm' switches clients instead of nesting inside tmux"
    assert_pattern_present "$f" "tmux_project()" \
        "$base — ships reusable project-session helper"
    assert_pattern_present "$f" 'tmux new-session -d -s "\$session" -c "\$dir"' \
        "$base — tmux_project creates detached sessions with cwd inside tmux"
    # Fragment must be no-op when tmux isn't on PATH — otherwise it
    # pollutes the shell on machines where the user skipped 40-tmux.
    assert_pattern_present "$f" 'command -v tmux' \
        "$base — gates aliases on 'command -v tmux'"
done

assert_pattern_present "$TMUX_BASHRC" '@dev_bootstrap_pane_cwd' \
    "bashrc.d-40-tmux.sh — reports cwd into a pane-local tmux option"

assert_pattern_present "$TMUX_BASHRC" 'PROMPT_COMMAND.*__dev_bootstrap_tmux_update_cwd' \
    "bashrc.d-40-tmux.sh — refreshes tmux cwd from PROMPT_COMMAND"

assert_pattern_absent "$TMUX_BASHRC" '@dev_bootstrap_outbound_ssh_context' \
    "bashrc.d-40-tmux.sh — does not report SSH context into tmux"

assert_pattern_absent "$TMUX_BASHRC" 'ssh\(\)' \
    "bashrc.d-40-tmux.sh — does not wrap ssh"

assert_pattern_present "$TMUX_ZSHRC" '@dev_bootstrap_pane_cwd' \
    "zshrc.d-40-tmux.sh — reports cwd into a pane-local tmux option"

assert_pattern_present "$TMUX_ZSHRC" 'chpwd_functions.*__dev_bootstrap_tmux_update_cwd' \
    "zshrc.d-40-tmux.sh — refreshes tmux cwd on chpwd"

assert_pattern_absent "$TMUX_ZSHRC" '@dev_bootstrap_outbound_ssh_context' \
    "zshrc.d-40-tmux.sh — does not report SSH context into tmux"

assert_pattern_absent "$TMUX_ZSHRC" 'ssh\(\)' \
    "zshrc.d-40-tmux.sh — does not wrap ssh"

echo
echo "═══ Bash 3.2 color variables must be braced before Unicode literals ═══"

# macOS /bin/bash 3.2 treats non-ASCII bytes adjacent to an unbraced
# parameter expansion as part of the parameter token. Under `set -u`,
# `$_C_RED✗$_C_RST` aborts as `_C_RED�: unbound variable`.
assert_pattern_absent "$LOG" '\$_C_[A-Z]+[✓✗→]' \
    "lib/log.sh — _C_* color vars are braced before Unicode symbols"

echo
echo "═══ Baseline shell aliases migrated from private dotfiles to public topics ═══"

# 30-shell — navigation + shell shortcuts + alert + mkd/md/fs/tre
SHELL_ZSH="$ROOT/topics/shell-terminal/templates/zsh/zshrc.d-30-shell.sh.template"
SHELL_BASH="$ROOT/topics/shell-terminal/templates/zsh/bashrc.d-30-shell.sh.template"

for f in "$SHELL_ZSH" "$SHELL_BASH"; do
    base="$(basename "$f")"
    assert_pattern_present "$f" "alias \\.\\.='cd \\.\\.'" \
        "$base — navigation '..' alias"
    assert_pattern_present "$f" "alias home='cd ~'" \
        "$base — 'home' alias"
    assert_pattern_present "$f" "alias c='clear'" \
        "$base — 'c' clear alias"
    assert_pattern_present "$f" 'mkd\(\) \{' \
        "$base — mkd() function"
    assert_pattern_present "$f" 'notify-send' \
        "$base — 'alert' Linux desktop helper gated on notify-send"
done

# 20-terminal-ux — Phase E CLI replacements (btop/duf/dust/gping/xh/procs)
TUX_ZSH="$ROOT/topics/shell-terminal/templates/cli-tools/zshrc.d-20-terminal-ux.sh.template"
TUX_BASH="$ROOT/topics/shell-terminal/templates/cli-tools/bashrc.d-20-terminal-ux.sh.template"

for f in "$TUX_ZSH" "$TUX_BASH"; do
    base="$(basename "$f")"
    assert_pattern_present "$f" "alias top='btop'" \
        "$base — Phase E: top→btop"
    assert_pattern_present "$f" "alias df='duf'" \
        "$base — Phase E: df→duf"
    assert_pattern_present "$f" "alias ping='gping'" \
        "$base — Phase E: ping→gping"
done


# 70-remote-access — Tailscale aliases + tip-of function
REM_ZSH="$ROOT/topics/remote-access/templates/tailscale/zshrc.d-70-remote-access.sh"
REM_BASH="$ROOT/topics/remote-access/templates/tailscale/bashrc.d-70-remote-access.sh"

for f in "$REM_ZSH" "$REM_BASH"; do
    base="$(basename "$f")"
    assert_file_exists "$f" "$base — fragment exists"
    assert_pattern_present "$f" "alias ts='tailscale status'" \
        "$base — Tailscale status alias"
    assert_pattern_present "$f" "tip-of\\(\\) \\{" \
        "$base — tip-of() helper"
    assert_pattern_present "$f" 'command -v tailscale' \
        "$base — aliases gated on 'command -v tailscale'"
done

echo
echo "═══ 80-claude-code fragment puts Bun in PATH (fixes crc bun-not-in-PATH bug) ═══"

# Observed on crc: ~/.bun/bin/bun existed (103 MB) but `which bun`
# returned "bun not found". Cause: 80-claude-code's installer does
# `export PATH=...` inside the install script (doesn't persist) and
# `curl bun.sh/install | bash` writes to .bashrc/.zshrc — but our
# managed .bashrc/.zshrc templates overwrite those writes. Fix:
# ship a .bashrc.d/.zshrc.d fragment that puts Bun in PATH, gated
# on file existence (same pattern as 10-languages + fnm).
CLAUDE_BASH="$ROOT/topics/ai/templates/claude-code/bashrc.d-80-claude-code.sh"
CLAUDE_ZSH="$ROOT/topics/ai/templates/claude-code/zshrc.d-80-claude-code.sh"

assert_file_exists "$CLAUDE_BASH" \
    "80-claude-code — bashrc fragment exists"
assert_file_exists "$CLAUDE_ZSH" \
    "80-claude-code — zshrc fragment exists"

for f in "$CLAUDE_BASH" "$CLAUDE_ZSH"; do
    base="$(basename "$f")"
    assert_pattern_present "$f" '\$HOME/\.bun/bin/bun' \
        "$base — gates on ~/.bun/bin/bun presence"
    assert_pattern_present "$f" 'export PATH=.*(\.bun/bin|BUN_INSTALL/bin)' \
        "$base — prepends ~/.bun/bin to PATH"
    assert_pattern_present "$f" 'BUN_INSTALL' \
        "$base — exports BUN_INSTALL so bun's internal tooling resolves its root"
done

echo
summary
