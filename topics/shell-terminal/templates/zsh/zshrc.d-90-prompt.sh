# shellcheck shell=bash
# shellcheck disable=SC1090
# ~/.zshrc.d/90-prompt.sh — mesh-owned zsh prompt + plugins.
# Loaded by ~/.zshrc from ~/.zshrc.d/. Does NOT require ~/.zshrc.local or
# mesh-identity, so --no-mesh / guest machines still get p10k (git status)
# and the apt/brew zsh plugins. Identity may still override from
# ~/.zshrc.local, which ~/.zshrc sources after this directory.

# Dynamic path: apt vs brew vs ~/.local. Missing files are a silent no-op.
# shellcheck disable=SC1090
_mesh_source_if() { [ -r "$1" ] && . "$1"; }

# Autosuggestions (apt on WSL, brew on mac). Missing files are a silent no-op.
_mesh_source_if /usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh
if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    _mesh_source_if "$HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
fi
_mesh_source_if /opt/homebrew/share/zsh-autosuggestions/zsh-autosuggestions.zsh
_mesh_source_if /usr/local/share/zsh-autosuggestions/zsh-autosuggestions.zsh

# fzf-tab (cloned by shell-terminal/zsh/fzf-tab). Direct source: do not wait
# on zinit turbo, which never ran when ~/.zshrc.local was absent.
# zsh's own menu takes TAB unless this is set. It has to be mesh-owned:
# a machine without ~/.zshrc.local would otherwise keep the native menu.
zstyle ':completion:*' menu no
_mesh_source_if "$HOME/.local/share/fzf-tab/fzf-tab.plugin.zsh"

# Powerlevel10k — clone is mesh-managed (~/.local/share/powerlevel10k).
# Source the theme, then the shipped config (~/.p10k.zsh, git-aware lean).
if [ -r "$HOME/.local/share/powerlevel10k/powerlevel10k.zsh-theme" ]; then
    . "$HOME/.local/share/powerlevel10k/powerlevel10k.zsh-theme"
fi
_mesh_source_if "$HOME/.p10k.zsh"

# Syntax highlighting LAST (must run after widgets are defined).
_mesh_source_if /usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
if [ -n "${HOMEBREW_PREFIX:-}" ]; then
    _mesh_source_if "$HOMEBREW_PREFIX/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"
fi
_mesh_source_if /opt/homebrew/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
_mesh_source_if /usr/local/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh

unset -f _mesh_source_if
