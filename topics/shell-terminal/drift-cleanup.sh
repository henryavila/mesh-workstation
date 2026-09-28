#!/usr/bin/env bash
# Drift cleanup — delegates to scripts/lib/topic-cleanup.sh's uninstall_apply()
# applied against data/uninstall.list.

check() {
    # Cleanup is idempotent and cheap; signal "needs run" so the engine
    # always invokes install(). uninstall_apply itself short-circuits
    # when nothing matches.
    return 1
}

install() {
    local here ws_lib
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
        ws_lib="${MESH_WORKSTATION_DIR}/scripts/lib"
    else
        ws_lib="$(cd "$here/../.." && pwd)/scripts/lib"
    fi
    # shellcheck disable=SC1091
    . "$ws_lib/log.sh"
    # shellcheck disable=SC1091
    . "$ws_lib/topic-cleanup.sh"
    uninstall_apply "$here/data/uninstall.list"
}

verify() {
    # Cleanup verification is "best-effort by design"; treat post-install as ok.
    return 0
}

rollback() {
    :
}
