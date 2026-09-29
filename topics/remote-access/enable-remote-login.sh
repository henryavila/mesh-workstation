#!/usr/bin/env bash
# Custom installer: enable macOS Remote Login (sshd).
#
# Detection model (2026-05-28): replaced `sudo systemsetup -getremotelogin`
# with `launchctl print-disabled system`, which reads launchd's
# user-override database without sudo. The output line
#   "com.openssh.sshd" => enabled    (or disabled)
# is the same authoritative signal that the Sharing prefpane reads.
# Verified live on macOS — works as a non-admin user with zero prompts.
#
# The install side still requires sudo because flipping the Remote Login
# toggle is a privileged system mutation; there is no documented
# non-sudo path for that. Sudo there is correct friction (user opted in).

check() {
    # Capture then bash-match — NOT `launchctl print-disabled | grep -q`: under the
    # engine's pipefail, grep -q closing the pipe early SIGPIPE-kills launchctl (141)
    # → a false "disabled". See feedback_engine_pipefail_grep_q_broken_pipe (lint L21).
    local _lc re; _lc="$(launchctl print-disabled system 2>/dev/null)"
    re='"com\.openssh\.sshd"[[:space:]]*=>[[:space:]]*enabled'
    [[ "$_lc" =~ $re ]]
}

install() {
    local output rc=0
    if output="$(sudo systemsetup -setremotelogin on 2>&1)"; then
        rc=0
    else
        rc=$?
    fi
    [[ -z "$output" ]] || printf '%s\n' "$output" >&2

    if [[ "$output" == *"requires Full Disk Access privileges"* ]]; then
        printf '%s\n' \
            '[remote-login-mac] macOS blocked enabling Remote Login: Full Disk Access is required by systemsetup, even with sudo.' \
            '[remote-login-mac] Open System Settings > General > Sharing > Remote Login and turn it on, then re-run this installation.' \
            '[remote-login-mac] Em portugues: Ajustes do Sistema > Geral > Compartilhamento > Login Remoto. Ative a opcao e execute novamente a instalacao.' >&2
        # Some systemsetup versions report errors with a successful exit status.
        [[ "$rc" -ne 0 ]] || rc=1
    fi
    return "$rc"
}

verify() {
    check
}

repair() { install; }

rollback() {
    # Don't auto-disable — the user may have enabled it for other reasons.
    :
}
