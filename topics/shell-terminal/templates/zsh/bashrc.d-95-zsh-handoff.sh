# shellcheck shell=bash
# ~/.bashrc.d/95-zsh-handoff.sh — managed by mesh-workstation
# WSL often cannot chsh (sudo wants a password, and a headless install has
# no terminal). Interactive bash then never loads fzf-tab. Hand off to zsh
# once the mesh ~/.zshrc is in place. Set MESH_BASH_STAY=1 to keep bash.

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
