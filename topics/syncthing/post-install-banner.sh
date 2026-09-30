#!/usr/bin/env bash
# Custom item: Syncthing post-install pairing (spec §11 / D-10).
#
# REPLACES the old passive echo+read banner. Instead of printing 3 vague manual
# UI steps and blocking on `read`, this drives the declarative reconcile
# (`mesh syncthing pair`): it sets GUI auth, adds the hub(s), creates+shares the
# folder(s) over the REST API from the identity syncthing-mesh.yaml, then prints
# a real, filled-in summary. It pauses ONLY when a genuine first-time hub
# approval remains, and never under NON_INTERACTIVE.
#
# Non-blocking by contract (like the old banner): a transient pairing problem
# prints a note and returns 0 — pairing is additive UX at the tail of the
# install, not a gate. The syncthing-service item already verified the daemon.
# Marked `idempotent: true` in the manifest so it runs on every apply.

if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _WS="${MESH_WORKSTATION_DIR}"
else
    _WS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
_RUNNER="$_WS/scripts/runners/syncthing.sh"

_data_file() {
    local id="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}" c
    [[ -n "${MESH_SYNCTHING_DATA:-}" ]] && { printf '%s\n' "$MESH_SYNCTHING_DATA"; return 0; }
    for c in "$id/sync/syncthing-mesh.yaml" "$id/claude/sync/syncthing-mesh.yaml"; do
        [[ -f "$c" ]] && { printf '%s\n' "$c"; return 0; }
    done
    return 1
}

check() {
    # Idempotent banner — never "already done"; the engine always re-runs it
    # (manifest idempotent: true). Returning 1 keeps the contract honest even
    # if the idempotent flag were dropped.
    return 1
}

install() {
    if [[ ! -f "$_RUNNER" ]]; then
        echo "  [syncthing] runner not found ($_RUNNER) — skipping pairing." >&2
        return 0
    fi
    if ! _data_file >/dev/null; then
        cat <<BANNER

  ┌─ Syncthing — no mesh data yet ─────────────────────────────────────┐
   This machine runs Syncthing, but there is no syncthing-mesh.yaml to
   pair against. Two cases:
     • First machine of the mesh → run:  mesh syncthing init-hub
       then commit the printed hub id into syncthing-mesh.yaml (identity).
     • Joining an existing mesh → add the hub id + folders to
       <identity>/sync/syncthing-mesh.yaml, then run:  mesh syncthing pair
  └────────────────────────────────────────────────────────────────────┘

BANNER
        return 0
    fi

    # Drive the real reconcile. The runner renders the summary / cold-start /
    # hub banner and handles the (only) interactive approval pause itself.
    if ! bash "$_RUNNER" pair; then
        echo "  [syncthing] pairing reconcile hit a snag (daemon not ready?)." \
             "Re-run later with:  mesh syncthing pair" >&2
    fi
    return 0
}

verify() {
    return 0
}

rollback() {
    :
}
