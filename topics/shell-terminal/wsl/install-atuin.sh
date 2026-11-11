#!/usr/bin/env bash
# atuin lands in ~/.atuin/bin (official installer), which is NOT on the engine
# item-subshell PATH on WSL — fall back to the absolute path so post-verify holds.
# The shared WSL image must not carry personal shell history. Set
# MESH_INSTALL_ATUIN=1 to install Atuin on a personal machine.
_atuin_wanted() { [[ "${MESH_INSTALL_ATUIN:-0}" == "1" ]]; }

check() {
    _atuin_wanted || return 1
    command -v atuin >/dev/null 2>&1 || [[ -x "$HOME/.atuin/bin/atuin" ]]
}

# The official atuin setup script UNCONDITIONALLY appends `eval "$(atuin init …)"`
# to ~/.zshrc and ~/.bashrc (creating ~/.zshrc if absent) — there is no opt-out
# flag (--non-interactive only gates the import/login prompts; it still edits the
# rc files). mesh OWNS both rc files: the zsh bundle deploys them carrying the
# "managed by mesh-workstation" marker and already provides atuin's PATH + init
# via its own .zshrc.d/.bashrc.d `20-terminal-ux` fragment (with the nicer
# --disable-up-arrow). atuin's append is therefore redundant AND harmful — it
# leaves an unmarked ~/.zshrc and dirties the /etc/skel-identical ~/.bashrc, both
# of which the deploy overwrite-guard then refuses, silently blocking the
# canonical rc deploy on every fresh machine (this is what failed the CI smoke
# test once the rust-bins hang ahead of it was removed).
#
# So snapshot the two rc files immediately before the installer runs and restore
# them exactly afterwards: a file that existed is byte-restored (dropping atuin's
# append); a file atuin created from nothing is removed. The atuin binary
# (~/.atuin/bin), its env shim, and ~/.bash-preexec.sh (which mesh's bash fragment
# sources) are untouched — only the unsolicited rc edits are reverted.
install() {
    if ! _atuin_wanted; then
        echo "[atuin-wsl] skipped — Atuin stores personal shell history and is not part of the shared WSL image." >&2
        return 0
    fi
    local _zsrc="$HOME/.zshrc" _bsrc="$HOME/.bashrc"
    local _zbak="" _bbak=""
    [[ -e "$_zsrc" ]] && { _zbak="$(mktemp)"; cp -p "$_zsrc" "$_zbak"; }
    [[ -e "$_bsrc" ]] && { _bbak="$(mktemp)"; cp -p "$_bsrc" "$_bbak"; }

    local _rc=0
    if [[ "${NON_INTERACTIVE:-0}" == "1" || ! -t 0 ]]; then
        curl --proto '=https' --tlsv1.2 -LsSf --connect-timeout 8 --max-time 45 https://setup.atuin.sh | sh -s -- --non-interactive || _rc=$?
    else
        curl --proto '=https' --tlsv1.2 -LsSf --connect-timeout 8 --max-time 45 https://setup.atuin.sh | sh || _rc=$?
    fi

    _atuin_restore_rc "$_zsrc" "$_zbak"
    _atuin_restore_rc "$_bsrc" "$_bbak"
    return "$_rc"
}

# Restore one rc file to its pre-atuin state. A non-empty backup path means the
# file existed → copy it back (reverting atuin's append); an empty path means
# atuin created the file → remove it so mesh deploys the canonical marked one.
_atuin_restore_rc() {
    local f="$1" bak="$2"
    if [[ -n "$bak" ]]; then
        cp -p "$bak" "$f" 2>/dev/null || true
        rm -f "$bak"
    else
        rm -f "$f"
    fi
}

verify() {
    _atuin_wanted || return 0
    check
}
repair() { install; }

rollback() {
    local dir="$HOME/.atuin"
    [[ -d "$dir" ]] && rm -rf "$dir"
}
