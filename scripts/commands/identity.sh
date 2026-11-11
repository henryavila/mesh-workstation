# shellcheck shell=bash
# mesh identity — opt-in clone and apply of mesh-identity.
# DX setup does not call this. status never clones.

cmd_identity_help() {
    cat <<'EOF'
Usage:
  mesh identity status
      Print whether a mesh-identity checkout is present. Exits 0 either way.
      Does not clone.

  mesh identity enable
      Clone or update mesh-identity, run its install.sh, and offer secret
      unlock. Safe to run twice. Prints the Atuin login hint and does not
      run `atuin login` unless ATUIN_LOGIN_NOW=1.

Atuin the binary is installed by DX setup. Atuin login is identity.
EOF
}

cmd_identity_status() {
    local dir="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"
    if [[ -d "$dir/.git" ]]; then
        printf 'identity: on (%s)\n' "$dir"
    else
        printf 'identity: off (%s)\n' "$dir"
    fi
    return 0
}

cmd_identity_enable() {
    local ws apply dir
    ws="$(_resolve_workstation_repo)" || _die "mesh-workstation repo not found (set MESH_WORKSTATION_DIR)"
    apply="$ws/topics/personal/apply.sh"
    [[ -f "$apply" ]] || _die "personal apply script not found"
    dir="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"
    export MESH_IDENTITY_DIR="$dir"
    # shellcheck disable=SC1090
    bash -c '
        set -euo pipefail
        # shellcheck disable=SC1090
        source "$1"
        install
    ' bash "$apply" || return $?
    bash "$ws/bin/mesh" secret offer-unlock || true
    printf '%s\n' "[atuin-login] Atuin login is identity, not DX. Run 'atuin login' when ready."
    if [[ "${ATUIN_LOGIN_NOW:-0}" == "1" ]]; then
        command -v atuin >/dev/null 2>&1 && atuin login || true
    fi
    return 0
}

cmd_identity_run() {
    local sub="${1:-status}"
    case "$sub" in
        -h|--help|help)
            cmd_identity_help
            ;;
        status)
            cmd_identity_status
            ;;
        enable)
            shift || true
            case "${1:-}" in
                -h|--help)
                    cmd_identity_help
                    ;;
                *)
                    cmd_identity_enable
                    ;;
            esac
            ;;
        *)
            _die "identity: unknown subcommand '$sub' (status | enable)"
            ;;
    esac
}

mesh_register_command \
    --name identity \
    --summary "Show or enable mesh-identity sync" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_identity_run
