#!/usr/bin/env bash
# Atuin login is identity. This item only prints the hint.

# Audit 2026-06-03 (path-fragility): on WSL atuin lives in ~/.atuin/bin (official
# curl|sh installer) which is NOT on the engine item-subshell PATH, so a bare
# `command -v atuin` misses and the login feature silently never runs. Prepend
# the install dir so the bare `atuin` calls below resolve.
case ":$PATH:" in *":$HOME/.atuin/bin:"*) ;; *) PATH="$HOME/.atuin/bin:$PATH" ;; esac

check() {
    # Login is not part of DX setup. Presence of the binary is enough.
    return 0
}

install() {
    echo "[atuin-login] Atuin login is identity, not DX. Run 'atuin login' when ready." >&2
    return 0
}

verify() {
    # Codex review 2026-05-19: login is advisory / best-effort. If the user
    # cancelled or has no account, install() already emitted the advisory;
    # verify() must not abort bootstrap.
    return 0
}

repair() { install; }

rollback() {
    :
}
