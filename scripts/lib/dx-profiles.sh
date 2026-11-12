#!/usr/bin/env bash
# dx-profiles.sh — load scripts/data/dx-profiles.yaml through yaml-parse.sh.
# Source-only. Bash 3.2: no mapfile, readarray, or ${var^^}.
# shellcheck shell=bash

dx_profiles_root() {
    if [[ -n "${MESH_WORKSTATION_DIR:-}" && -f "${MESH_WORKSTATION_DIR}/scripts/data/dx-profiles.yaml" ]]; then
        printf '%s\n' "$MESH_WORKSTATION_DIR"
        return 0
    fi
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    printf '%s\n' "$here"
}

dx_profiles_load() {
    [[ "${_DX_PROFILES_LOADED:-0}" == "1" ]] && return 0
    local root parser file parsed body
    root="$(dx_profiles_root)"
    parser="$root/scripts/lib/yaml-parse.sh"
    file="$root/scripts/data/dx-profiles.yaml"
    parsed="$(bash "$parser" < "$file")" || return 1
    body="${parsed//BUNDLE_/DXB_}"
    body="${body//__YAML_PARSE_OK/_DX_YAML_OK}"
    eval "$body"
    [[ "${_DX_YAML_OK:-0}" == "1" ]] || return 1
    _DX_PROFILES_LOADED=1
}

# Print the requires_bundles of one section, one id per line.
dx_profiles_section() {
    local want="$1" n i name_v name count_v count j item_v
    dx_profiles_load || return 1
    n="${DXB_COUNT:-0}"
    i=0
    while [[ "$i" -lt "$n" ]]; do
        name_v="DXB_${i}_NAME"
        name="${!name_v:-}"
        if [[ "$name" == "$want" ]]; then
            count_v="DXB_${i}_REQUIRES_BUNDLES_COUNT"
            count="${!count_v:-0}"
            j=0
            while [[ "$j" -lt "$count" ]]; do
                item_v="DXB_${i}_REQUIRES_BUNDLES_${j}"
                printf '%s\n' "${!item_v}"
                j=$((j + 1))
            done
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

dx_profile_name() {
    if [[ "${MESH_PROFILE:-workstation}" == "server" ]]; then
        printf '%s\n' server
    else
        printf '%s\n' workstation
    fi
}

dx_profile_defaults() {
    dx_profiles_section "$(dx_profile_name)-default"
}

dx_profile_optional() {
    dx_profiles_section "$(dx_profile_name)-optional"
}

# Both profiles reject identity-only bundles. Server also rejects its
# forbidden list and every removed id.
dx_profile_forbidden() {
    local profile
    profile="$(dx_profile_name)"
    dx_profiles_section identity-only
    if [[ "$profile" == "server" ]]; then
        dx_profiles_section server-forbidden
        dx_profiles_section removed
    fi
}

dx_profile_contains() {
    local id="$1" line
    shift
    while IFS= read -r line; do
        [[ "$line" == "$id" ]] && return 0
    done
    return 1
}

# Print a forbidden id from the argument list. Return 0 when one is found.
dx_profile_first_forbidden() {
    local id forbidden
    forbidden="$(dx_profile_forbidden)"
    for id in "$@"; do
        [[ -n "$id" ]] || continue
        if printf '%s\n' "$forbidden" | grep -qx "$id"; then
            printf '%s\n' "$id"
            return 0
        fi
    done
    return 1
}

# Retired flag. Exits before any install. Used by setup, the menu, and the engine.
dx_retire_no_mesh() {
    if [[ "${MESH_NO_MESH:-0}" == "1" ]]; then
        printf '%s\n' \
            '--no-mesh was removed. setup.sh is DX and does not join identity.' \
            'For a headless Linux server: setup.sh --server' >&2
        exit 1
    fi
}

# Called only from `mesh identity enable`, after a real checkout exists.
# DX setup seeds the workstation repo and does not write this path.
dx_persist_identity_for_update() {
    local dir="$1" config
    [[ -d "$dir/.git" ]] || return 0
    config="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/config.env"
    mkdir -p "$(dirname "$config")"
    [[ -f "$config" ]] || : > "$config"
    if ! grep -q '^MESH_IDENTITY_DIR=' "$config"; then
        printf 'MESH_IDENTITY_DIR=%q\n' "$dir" >> "$config"
    fi
    if ! grep -F -q "$dir" "$config"; then
        printf 'AUTO_UPDATE_REPOS+=(\n    %q\n)\n' "$dir" >> "$config"
    fi
}

# Print the two conflict ids when both are in the argument list.
dx_profile_conflict_hit() {
    local left right id seen_left=0 seen_right=0
    left="$(dx_profiles_section conflicts | awk 'NR==1 { print; exit }')"
    right="$(dx_profiles_section conflicts | awk 'NR==2 { print; exit }')"
    [[ -n "$left" && -n "$right" ]] || return 1
    for id in "$@"; do
        [[ "$id" == "$left" ]] && seen_left=1
        [[ "$id" == "$right" ]] && seen_right=1
    done
    if [[ "$seen_left" == 1 && "$seen_right" == 1 ]]; then
        printf '%s\n%s\n' "$left" "$right"
        return 0
    fi
    return 1
}

# Abort before apply when the resolved ids contain a forbidden bundle or
# both sides of a conflicts pair. Prints the bundle id. Mutates nothing.
dx_guard_selection_args() {
    local hit
    if hit="$(dx_profile_conflict_hit "$@")"; then
        printf 'setup.sh: conflict, refusing to apply both: %s\n' "$(printf '%s' "$hit" | tr '\n' ' ')" >&2
        exit 1
    fi
    if hit="$(dx_profile_first_forbidden "$@")"; then
        printf 'setup.sh: forbidden bundle for %s profile: %s\n' "$(dx_profile_name)" "$hit" >&2
        exit 1
    fi
}

dx_guard_selection_file() {
    local file="$1" line ids=()
    [[ -f "$file" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        ids+=("$line")
    done < "$file"
    dx_guard_selection_args ${ids[@]+"${ids[@]}"}
}
