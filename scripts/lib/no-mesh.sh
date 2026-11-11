#!/usr/bin/env bash
# shellcheck shell=bash
# no-mesh.sh — catalog filter + headless default for --no-mesh (MESH_NO_MESH=1).
# Source-only. Drops bundles whose membership is mesh; topics with no remaining
# bundles emit no rows and therefore disappear from the catalog.
#
# The membership filter is data-driven (`membership: mesh`). Callers must not
# hardcode a membership-bundle denylist in the TUI. The unlock list below is the
# documented plan constant for required→optional demotion under no-mesh only.

# True when --no-mesh is active (exported by setup.sh / mesh menu).
no_mesh_active() {
    [[ "${MESH_NO_MESH:-0}" == "1" ]]
}

# Bundles that stay in the catalog under no-mesh but lose required locks and
# start unchecked (Decision 10). Mirrored in scripts/menu/src/core/init.ts.
NO_MESH_UNLOCK_KEYS=(
    git/config
    shell-terminal/cli-tools
    shell-terminal/zsh
)

# Return 0 when $1 is on the unlock list.
no_mesh_is_unlock_key() {
    local key="${1:-}" k
    [[ -n "$key" ]] || return 1
    for k in "${NO_MESH_UNLOCK_KEYS[@]}"; do
        [[ "$k" == "$key" ]] && return 0
    done
    return 1
}

# Return 0 when this bundle should be omitted from the catalog.
# $1 = membership scalar from yaml-parse (BUNDLE_N_MEMBERSHIP), may be empty.
no_mesh_omit_bundle() {
    local membership="${1:-}"
    no_mesh_active || return 1
    [[ "$membership" == "mesh" ]]
}

# stdin:  topic<TAB>bundle<TAB>membership
# stdout: topic<TAB>bundle for kept rows. Empty topics are omitted.
no_mesh_filter_records() {
    local topic bundle membership
    while IFS=$'\t' read -r topic bundle membership || [[ -n "${topic:-}" ]]; do
        [[ -n "$topic" ]] || continue
        no_mesh_omit_bundle "$membership" && continue
        printf '%s\t%s\n' "$topic" "$bundle"
    done
}

# Headless default under no-mesh with no explicit selections/--bundle:
# only foundation/base (unlock list is off; membership is absent).
no_mesh_emit_headless_default() {
    printf '%s\n' 'foundation/base'
}

# Interactive first-run when the Blink menu cannot open (usually: Node not on
# PATH yet). Headless `--non-interactive --no-mesh` must NOT use this — that
# path stays foundation/base only. This list is the no-mesh analogue of
# setup.sh emit_lean_bootstrap_selections: enough shell to continue, without
# membership: mesh bundles (identity/personal). languages/node is not a bundle.
no_mesh_emit_lean_bootstrap() {
    printf '%s\n' \
        foundation/base \
        git/config \
        shell-terminal/cli-tools \
        shell-terminal/zsh \
        shell-terminal/fonts
}

# Emit the headless selection lines for setup.sh.
# When no-mesh is active and no explicit bundles were passed, prints only
# foundation/base. Otherwise returns 1 so the caller uses the unflagged emitter.
# $1... = optional explicit topic/bundle keys (--bundle); when non-empty under
# no-mesh, prints foundation/base plus those keys (deduped, membership not added).
no_mesh_emit_default_or_bundles() {
    no_mesh_active || return 1
    local key
    if [[ $# -eq 0 ]]; then
        no_mesh_emit_headless_default
        return 0
    fi
    # Explicit --bundle list: keep foundation/base (still required) + requested.
    {
        printf '%s\n' 'foundation/base'
        for key in "$@"; do
            [[ -n "$key" ]] || continue
            printf '%s\n' "$key"
        done
    } | awk 'NF && !seen[$0]++'
    return 0
}
