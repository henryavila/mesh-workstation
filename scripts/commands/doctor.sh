# shellcheck shell=bash

cmd_doctor_run() {
    local fix=0
    local passthrough=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --fix) fix=1; shift ;;
            -h|--help)
                cat <<'EOF'
Usage:
  mesh doctor            Report identity deploy drift + system phantoms (read-only).
  mesh doctor --fix      Verify every installed item's strongest probe and REPAIR
                         broken-but-installed items through the installer (engine
                         --repair). Reinstalls a brew formula whose dylib a
                         dependency bump removed.
                         rc 0 = healthy/repaired, 67 = unresolved.

Recovery:
  Messy bash/zsh, unmanaged rc, login-shell mismatch:
    mesh reinstall shell
    --fix does not rewrite shell rc files.
  New owner on an upgraded marker-owned bundle:
    mesh doctor --fix    Adopt it when healthy, or repair and then record it.
  Reapply the complete saved selection after an update:
    mesh update --full
  Update the current non-main branch:
    mesh update --force
    --force is branch authorization only; it is not repair and does not imply --full.
EOF
                return 0 ;;
            *) passthrough+=("$1"); shift ;;
        esac
    done
    if [[ "$fix" -eq 1 ]]; then
        local repo
        repo="$(_resolve_workstation_repo)" || \
            _die "mesh-workstation repo not found (set MESH_WORKSTATION_DIR) -- needed for doctor --fix"
        # External-brew mount self-heal (macOS; clean no-op elsewhere). MUST run
        # before the engine repair sweep so the stack is repaired on the corrected
        # mount. If it remounts the volume, this repo's path (.../External 1)
        # becomes stale (.../External), so detect that and ask for a re-run.
        local healer="$repo/scripts/runners/heal-external-brew-mount.sh" healer_rc
        if [[ -f "$healer" ]]; then
            bash "$healer"
            healer_rc=$?
            if (( healer_rc != 0 )); then
                return "$healer_rc"
            fi
            if [[ ! -d "$repo/topics" ]]; then
                echo "mesh doctor --fix: volume was remounted to its canonical path -- re-run 'mesh doctor --fix' to finish the service repair on the corrected mount." >&2
                return 0
            fi
        fi
        # Re-sync identity deploy drift first. setup.sh --repair (below) fixes
        # installed-but-broken items, not config drift.
        local drift_runner
        drift_runner="$(_resolve_companion "runners/doctor.sh" 2>/dev/null || true)"
        [[ -n "$drift_runner" ]] && bash "$drift_runner" --fix --quiet || true
        exec bash "$repo/setup.sh" --repair "${passthrough[@]+"${passthrough[@]}"}"
    fi
    local runner
    runner="$(_resolve_companion "runners/doctor.sh")"
    [[ -n "$runner" ]] || _die "runners/doctor.sh not found (set \$MESH_HOME or check installation)"
    exec bash "$runner" "${passthrough[@]+"${passthrough[@]}"}"
}

sub_doctor() {
    cmd_doctor_run "$@"
}

mesh_register_command \
    --name doctor \
    --summary "Report or repair mesh health" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_doctor_run
