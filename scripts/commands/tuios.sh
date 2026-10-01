# shellcheck shell=bash

cmd_tuios_run() {
    local runner
    runner="$(_resolve_companion "runners/tuios.sh")"
    [[ -n "$runner" ]] || _die "runners/tuios.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$runner" "$@"
}

mesh_register_command \
    --name tuios \
    --summary "Set up and inspect TUIOS browser access" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_tuios_run
