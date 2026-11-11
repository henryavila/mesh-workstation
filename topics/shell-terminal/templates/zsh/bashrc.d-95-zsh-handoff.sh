# shellcheck shell=bash
# ~/.bashrc.d/95-zsh-handoff.sh — managed by mesh-workstation
# WSL often cannot chsh (sudo wants a password, and a headless install has
# no terminal). Interactive bash then never loads fzf-tab. ~/.bashrc calls
# mesh_zsh_handoff after ~/.bashrc.local so PATH and LESSOPEN from that
# file survive the exec. Sourcing this file must not exec by itself.
# Set MESH_BASH_STAY=1 to keep bash.

mesh_zsh_handoff() {
    case $- in
        *i*) ;;
        *) return ;;
    esac

    if [ "${MESH_BASH_STAY:-0}" = "1" ]; then
        return
    fi

    if [ -z "${ZSH_VERSION:-}" ] && [ -x /usr/bin/zsh ] && [ -f "$HOME/.zshrc" ]; then
        export SHELL=/usr/bin/zsh
        exec /usr/bin/zsh
    fi
}
