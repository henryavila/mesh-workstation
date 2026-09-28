# shellcheck shell=bash disable=all
# shell/auto-update.zsh — fire auto-update on zsh shell start.
#
# Spec: docs/2026-04-25-auto-update-spec.md §3.2.
# Sourced from shell/aliases.sh under `[[ -n "$ZSH_VERSION" ]]` guard so bash
# deploys (bashrc.d/) ignore us.
#
# Skip in:
#   - non-zsh shells (defensive; aliases.sh already guards)
#   - non-interactive contexts (CI, scripts, sourced from non-tty)
#   - missing controlling tty (matches mesh-workstation _has_ctty convention,
#     see feedback_tty_detection_under_tee_pipe.md)
#
# Why precmd instead of running synchronously here:
#   Powerlevel10k's instant_prompt redirects fd 1/2 to a tmpfile during init
#   (p10k.zsh:6484). Any output during this window is captured and dumped at
#   the end with a "Console output during zsh initialization" warning. By
#   deferring to the first precmd, we run AFTER `_p9k_instant_prompt_precmd_first`
#   restores fds — output goes directly to the terminal, no capture, no warning.
#   Same total latency, same trigger semantics, no glitch.
#
# Caveats:
#   - Ctrl-C during the deferred motor permanently disables auto-update for
#     this shell session (the hook is already deregistered when the motor
#     starts). Reopen the shell to retry — or run `bup`/`dotup` manually.
#   - Hook ordering depends on P10K prepending `_p9k_instant_prompt_precmd_first`
#     to precmd_functions. We add a defensive fd check inside the hook so
#     a future P10K reordering degrades to "no warning, output may glitch"
#     instead of reintroducing the captured-output trap.

[[ -n "${ZSH_VERSION:-}" ]] || return 0
[[ -o interactive ]] || return 0
{ : </dev/tty; } >/dev/null 2>&1 || return 0

# Recursion guard: auto-update.sh exports AUTO_UPDATE_RECURSED=1 right before
# `exec zsh`. The replaced shell sees the flag, skips re-running, and unsets it
# so that subsequent `exec zsh` invocations from the user behave normally.
[[ "${AUTO_UPDATE_RECURSED:-0}" == "1" ]] && { unset AUTO_UPDATE_RECURSED; return 0; }

_resolve_auto_update_runner() {
    if [[ -n "${MESH_WORKSTATION_DIR:-}" && -x "${MESH_WORKSTATION_DIR}/scripts/runners/auto-update.sh" ]]; then
        printf '%s' "${MESH_WORKSTATION_DIR}/scripts/runners/auto-update.sh"
        return 0
    fi
    if [[ -r "$HOME/.config/mesh/config.env" ]]; then
        local MESH_WORKSTATION_DIR=""
        # shellcheck disable=SC1090
        . "$HOME/.config/mesh/config.env"
        if [[ -n "${MESH_WORKSTATION_DIR:-}" && -x "${MESH_WORKSTATION_DIR}/scripts/runners/auto-update.sh" ]]; then
            printf '%s' "${MESH_WORKSTATION_DIR}/scripts/runners/auto-update.sh"
            return 0
        fi
    fi
    if [[ -L "$HOME/.local/bin/mesh" ]]; then
        local _mlink; _mlink=$(readlink "$HOME/.local/bin/mesh" 2>/dev/null || true)
        if [[ -x "${_mlink%/bin/mesh}/scripts/runners/auto-update.sh" ]]; then
            printf '%s' "${_mlink%/bin/mesh}/scripts/runners/auto-update.sh"
            return 0
        fi
    fi
    printf '%s' "${HOME}/mesh-workstation/scripts/runners/auto-update.sh"
}
_auto_update_runner="$(_resolve_auto_update_runner)"

# If add-zsh-hook is unavailable for any reason (corrupt fpath, exotic
# customization, or `unfunction add-zsh-hook` somewhere upstream), we
# fall back to running the motor synchronously. Synchronous output WILL
# trigger the P10K `Console output during zsh initialization` warning,
# but that's strictly better than silently dropping auto-update for the
# rest of this session — the latter is exactly what the user must NOT
# discover only by drift in production.
if ! autoload -Uz add-zsh-hook 2>/dev/null; then
    "$_auto_update_runner" --from-shell-start
    return 0
fi

_auto_update_first_precmd() {
    # Deregister BEFORE running so a recursive precmd cycle (motor calls
    # `exec zsh` with AUTO_UPDATE_RECURSED=1, replaced shell skips, etc.)
    # never re-fires us within the same logical session.
    add-zsh-hook -d precmd _auto_update_first_precmd
    # Defense-in-depth: if stdout/stderr are not connected to a tty at
    # this point, we are still inside P10K's fd-capture window — running
    # the motor would dump into the tmpfile and re-trigger the warning.
    # Bail out (next prompt will not retry — accept the silent skip; the
    # user's next manual `bup`/`dotup` covers the gap).
    if [[ ! -t 1 || ! -t 2 ]]; then
        unfunction _auto_update_first_precmd 2>/dev/null
        return 0
    fi
    "$_auto_update_runner" --from-shell-start
    unfunction _auto_update_first_precmd 2>/dev/null
}

if ! add-zsh-hook precmd _auto_update_first_precmd 2>/dev/null; then
    # precmd_functions readonly or array op failed — same fallback.
    print -u2 "auto-update.zsh: precmd hook registration failed; running synchronously"
    "$_auto_update_runner" --from-shell-start
fi
