# shellcheck shell=bash
# ~/.bashrc.d/00-mesh-env.sh — global mesh feature defaults.

# Hard kill switch for dormant auto-main. This fragment loads before
# ~/.bashrc.d/40-tmux.sh, including older deployed copies whose own default was
# opt-out instead of opt-in.
export MESH_TMUX_AUTO_MAIN=0

# MESH_WORKSTATION_DIR auto-derived from the ~/.local/bin/mesh symlink that
# setup.sh creates (C13.5). Lets ~/.bashrc.d/auto-update + downstream
# fragments find the workstation root without needing each user to set the
# env var manually. Honors a pre-set value. See Review B finding B2.
if [[ -z "${MESH_WORKSTATION_DIR:-}" || -z "${MESH_IDENTITY_DIR:-}" ]]; then
    [[ -r "$HOME/.config/mesh/config.env" ]] && . "$HOME/.config/mesh/config.env"
fi

if [[ -n "${MESH_WORKSTATION_DIR:-}" && ! -d "${MESH_WORKSTATION_DIR}" ]]; then
    unset MESH_WORKSTATION_DIR
fi

if [[ -z "${MESH_WORKSTATION_DIR:-}" ]] && [[ -L "$HOME/.local/bin/mesh" ]]; then
    _mesh_link=$(readlink "$HOME/.local/bin/mesh")
    case "$_mesh_link" in
        */bin/mesh) export MESH_WORKSTATION_DIR="${_mesh_link%/bin/mesh}" ;;
    esac
    unset _mesh_link
fi

: "${MESH_IDENTITY_DIR:=$HOME/mesh-identity}"
export MESH_WORKSTATION_DIR MESH_IDENTITY_DIR
