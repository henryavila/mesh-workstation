# shellcheck shell=bash

cmd_setup_run() {
    local do_update=1
    local pass=()
    while (( $# > 0 )); do
        case "$1" in
            --no-update) do_update=0; shift ;;
            -h|--help)
                cat <<'EOF'
Usage: mesh setup [--no-update] [setup.sh args...]
  Run the bootstrap from anywhere. By default runs `mesh update --force` (both
  repos, current branch) first so the install system + identity config are
  current, then runs setup.sh.
    --no-update   skip the refresh; run the current checkout's setup.sh as-is
  Extra args pass through to setup.sh (e.g. --non-interactive, --server, --repair).
EOF
                return 0
                ;;
            --) shift; while (( $# > 0 )); do pass+=("$1"); shift; done; break ;;
            *) pass+=("$1"); shift ;;
        esac
    done

    local ws setup_sh
    ws="$(cd "$HERE/.." 2>/dev/null && pwd -P)"
    setup_sh="$ws/setup.sh"
    [[ -f "$setup_sh" ]] || _die "setup: setup.sh not found at $setup_sh"

    if (( do_update )); then
        printf 'mesh setup: refreshing both repos (mesh update --force)...\n' >&2
        # Run as a child (NOT exec) so control returns here to launch setup.sh.
        local urc=0
        bash "$HERE/mesh" update --force || urc=$?
        (( urc == 0 )) || printf 'mesh setup: warning -- update returned rc %d; continuing with the current checkout\n' "$urc" >&2
    fi

    printf 'mesh setup: running %s\n' "$setup_sh" >&2
    exec bash "$setup_sh" "${pass[@]+"${pass[@]}"}"
}

sub_setup() {
    cmd_setup_run "$@"
}

mesh_register_command \
    --name setup \
    --summary "Update repos and run setup" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_setup_run
