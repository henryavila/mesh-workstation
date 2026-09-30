#!/usr/bin/env bash
# 05-identity/scripts/setup-identity.sh
# Cross-platform identity bootstrap: gh auth + SSH key + GitHub registration.
#
# Called by install.wsl.sh and install.mac.sh after gh CLI is installed.
# Idempotent — safe to re-run; checks each step before acting.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/lib/log.sh"

# ─── 1. Authenticate gh ─────────────────────────────────────────────
# OAuth device flow via browser — 1 token per machine, revokable
# independently.
#
# CRITICAL: `gh auth login` MUST run against a real TTY. Our parent
# (setup.sh:276) invokes topics via `bash installer 2>&1 | tee
# -a LOG` — the `| tee` makes stdout/stderr non-TTY. When gh detects
# non-TTY, it SKIPS the "Press Enter to continue" pause built into
# its interactive flow and starts polling GitHub's OAuth endpoint
# IMMEDIATELY, before the user can copy the one-time code + approve
# it in the browser. GitHub then rate-limits (`slow_down` response
# per RFC 8628), which gh 2.x treats as a fatal error. The auth
# "fails" in seconds — but the real cause is the missing TTY, not
# the user being slow.
#
# Fix: bind stdin/stdout/stderr of `gh auth login` to /dev/tty —
# the controlling terminal that exists for any shell session
# launched from a user TTY. This bypasses the tee pipe for just
# this command; gh sees a real terminal and behaves normally
# (pauses for Press Enter, starts polling only after user is
# actually ready).
#
# NON_INTERACTIVE=1 + GITHUB_TOKEN path skips TTY entirely (CI).
if gh auth status >/dev/null 2>&1; then
    ok "gh already authenticated ($(gh api user -q .login 2>/dev/null || echo 'unknown'))"
else
    if [[ "${NON_INTERACTIVE:-0}" == "1" ]] && [[ -n "${GITHUB_TOKEN:-}" ]]; then
        info "authenticating gh via GITHUB_TOKEN (non-interactive)"
        echo "$GITHUB_TOKEN" | gh auth login --with-token
    elif [ -r /dev/tty ] && [ -w /dev/tty ]; then
        info "authenticating gh interactively (/dev/tty — bypasses tee pipe)"
        info ""
        info "gh will pause and ask you to press Enter before opening the browser."
        info "Scopes: admin:public_key (register SSH key) + repo (clone private)."
        info ""
        # --git-protocol https (NOT ssh): with --git-protocol ssh, gh's
        # interactive flow offers to generate a new SSH key automatically
        # and register it as "GitHub CLI" — creating a SECOND key
        # alongside the one this script generates below. Using https
        # means gh uses HTTPS credential helper for clones (handled by
        # `gh auth setup-git`) while we stay in full control of the SSH
        # key (generation, title, fingerprint-idempotent registration).
        #
        # --clipboard: gh auto-copies the OAuth device code to the OS
        # clipboard. Enabled on Mac (pbcopy built-in) and native Linux
        # (xclip/xsel with X11/Wayland). DISABLED on WSL: empirical
        # testing showed that xclip writes to the X11 buffer inside
        # WSLg but does NOT propagate to the Windows clipboard, while
        # wl-copy fails with "This seat has no keyboard" and clip.exe
        # may be unreachable (I/O error on /mnt/c) on some WSL setups.
        # In WSL the code is printed to stdout only — user selects +
        # copies with mouse, same as pre-clipboard behavior.
        clipboard_flag=""
        if [[ "$(uname)" == "Darwin" ]]; then
            clipboard_flag="--clipboard"
        elif grep -qi microsoft /proc/version 2>/dev/null; then
            : # WSL — clipboard bridge unreliable, skip
        elif command -v xclip >/dev/null 2>&1 || command -v xsel >/dev/null 2>&1; then
            clipboard_flag="--clipboard"
        fi

        # Reset terminal state and flush any lingering escape sequences / OSC responses
        # left in /dev/tty from earlier Node.js (Ink) TUI menus or terminal queries.
        # Without this, gh's Go survey library encounters \x1b] and crashes with:
        # "unexpected escape sequence from terminal: ['\x1b' ']']".
        if [ -r /dev/tty ] && [ -w /dev/tty ]; then
            stty sane </dev/tty 2>/dev/null || true
            printf '\e[?2004l\e[?1l' >/dev/tty 2>/dev/null || true
            while read -r -t 0.1 -n 10000 _ < /dev/tty 2>/dev/null; do :; done
        fi

        # Pre-configure git credentials helper so gh auth login does not prompt
        # "? Authenticate Git with your GitHub credentials? (Y/n)"
        gh auth setup-git -f -h github.com >/dev/null 2>&1 || true

        if ! gh auth login --web ${clipboard_flag:+$clipboard_flag} \
                --git-protocol https \
                --scopes "admin:public_key,repo" \
                --hostname github.com \
                </dev/tty >/dev/tty 2>&1; then
            fail "gh auth login failed"
            info ""
            info "This is unexpected now that we're using /dev/tty. Possible causes:"
            info "  - Actual GitHub rate-limit (5-10 failed attempts in ~5 min)"
            info "    → wait 5min, re-run bootstrap (idempotent — skips completed topics)"
            info "  - Network blocking github.com"
            info "    → test: curl -v https://api.github.com/"
            info "  - gh version issue"
            info "    → test: gh --version ; gh auth status"
            exit 1
        fi
    else
        fail "no /dev/tty available and GITHUB_TOKEN not set"
        info "Headless setup: set GITHUB_TOKEN env var with a PAT that has"
        info "admin:public_key,repo scopes, then re-run with NON_INTERACTIVE=1."
        exit 1
    fi
fi

# ─── 2. Git credential helper ──────────────────────────────────────
# Makes HTTPS git clones use the gh-stored token transparently.
# Idempotent — no-op if already configured.
info "configuring git credential helper"
gh auth setup-git 2>/dev/null || true

# ─── 3. Generate SSH key if missing ────────────────────────────────
# ed25519 is the current standard — shorter keys, same security as RSA-3072.
# No passphrase: machine-local identity; disk encryption + OS login handle
# at-rest protection.
if [[ -f "$HOME/.ssh/id_ed25519" ]]; then
    ok "SSH key already exists at ~/.ssh/id_ed25519"
else
    info "generating SSH key (no passphrase)"
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    ssh-keygen -t ed25519 -N "" \
        -C "${USER}@$(hostname -s)" \
        -f "$HOME/.ssh/id_ed25519" \
        -q
    chmod 600 "$HOME/.ssh/id_ed25519"
    chmod 644 "$HOME/.ssh/id_ed25519.pub"
    ok "SSH key created — comment: ${USER}@$(hostname -s)"
fi

# ─── 4. Register SSH pubkey on GitHub (only if needed) ─────────────
# SSH handshake is the ground truth: if `ssh -T git@github.com` succeeds,
# the key IS registered — no need to consult the GitHub API at all.
# This avoids the false-negative trap where `gh ssh-key list` returns
# empty because the token lacks `admin:public_key` scope, making the
# script think the key isn't registered and trying to re-add it
# (which also fails, for the same scope reason) while the key has
# been registered and working all along.
#
# Flow:
#   (a) smoke test SSH — if green, done
#   (b) if red, try `gh ssh-key add` (best effort)
#   (c) re-smoke — if still red, print manual steps

title="$(hostname -s)"

run_ssh_smoke_test() {
    # BatchMode=yes fails fast if credentials are missing instead of prompting.
    # StrictHostKeyChecking=accept-new auto-accepts GitHub's host key on first
    # contact (safer than 'no' which also accepts changed keys = MITM risk).
    local out
    out="$(ssh -T -o BatchMode=yes \
                   -o StrictHostKeyChecking=accept-new \
                   git@github.com 2>&1 || true)"
    grep -q "successfully authenticated" <<<"$out"
}

info "verifying SSH authentication to github.com"
if run_ssh_smoke_test; then
    ok "SSH auth to GitHub: working (key already registered)"
else
    # Key exists locally but GitHub doesn't accept it yet. Try the API
    # call — it's fine if it fails, we'll fall back to manual instructions.
    info "SSH not yet authorised — attempting to register via gh API"
    if gh ssh-key add "$HOME/.ssh/id_ed25519.pub" --title "$title" 2>/dev/null; then
        ok "SSH key registered via gh"
        # Re-test — GitHub needs a moment to index the new key.
        sleep 2
        if run_ssh_smoke_test; then
            ok "SSH auth to GitHub: working"
        else
            warn "SSH auth still failing — GitHub may need a few more seconds"
            warn "Retry manually: ssh -T git@github.com"
        fi
    else
        warn "gh ssh-key add failed (token likely lacks admin:public_key scope)"
        warn "Register the key manually:"
        warn "    cat ~/.ssh/id_ed25519.pub    # copy this"
        warn "    open https://github.com/settings/ssh/new  and paste the key"
        warn "Or grant the scope + re-run this topic:"
        warn "    gh auth refresh -s admin:public_key"
        warn "    bash ~/mesh-workstation/setup.sh"
    fi
fi

ok "identity setup complete"
