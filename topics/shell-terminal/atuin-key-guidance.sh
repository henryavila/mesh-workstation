#!/usr/bin/env bash
# Informational post-install step, including installs that defer login.
# Never run `atuin key`: installer output can be captured in shared logs.
check() { return 0; }

install() {
    [[ "${MESH_NO_MESH:-0}" == "1" ]] && return 0
    command -v atuin >/dev/null 2>&1 || [[ -x "$HOME/.atuin/bin/atuin" ]] || return 0
    local message
    message="Atuin sync: save your encryption key in a password manager (such as Keeper), together with your username and password.
For an existing account, run 'atuin key' on a machine that already syncs, then use that SAME key with 'atuin login -u YOUR_USERNAME' on this machine. Enter the password and key at the prompts, then run 'atuin sync'.
For a new account only, run 'atuin register -u YOUR_USERNAME -e YOUR_EMAIL', then 'atuin key' and save the key before adding another machine.
Keep the key out of Git, chat and installation logs. If all copies are lost, the server cannot recover it. Mesh does not back up this key automatically."
    if declare -f followup >/dev/null; then
        followup info "$message"
    else
        printf '%s\n' "$message" >&2
    fi
}

verify() { return 0; }
rollback() { :; }
