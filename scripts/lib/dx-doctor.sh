#!/usr/bin/env bash
# Profile probes from scripts/data/dx-profiles.yaml. Names only:
# foundation/base, herdr-on-path, flyenv-present, flock-absent,
# flock-present, flyenv-absent.
# shellcheck shell=bash

dx_doctor_selected() {
    local file="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list" line
    [[ -f "$file" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        printf '%s\n' "$line"
    done < "$file"
}

dx_doctor_has() {
    local id="$1" line
    while IFS= read -r line; do
        [[ "$line" == "$id" ]] && return 0
    done
    return 1
}

dx_doctor_foundation_bins() {
    local b
    for b in git curl jq; do
        command -v "$b" >/dev/null 2>&1 || return 1
    done
    return 0
}

dx_doctor_flyenv_present() {
    [[ -d /Applications/FlyEnv.app ]] && return 0
    if command -v dpkg >/dev/null 2>&1; then
        dpkg -s flyenv >/dev/null 2>&1 && return 0
    fi
    if command -v rpm >/dev/null 2>&1; then
        rpm -q flyenv >/dev/null 2>&1 && return 0
    fi
    [[ -d /opt/FlyEnv || -d /usr/lib/flyenv ]] && return 0
    [[ -e "/mnt/c/Program Files/FlyEnv/FlyEnv.exe" ]] && return 0
    [[ -e "/mnt/c/Program Files/FlyEnv/flyenv.exe" ]] && return 0
    return 1
}

dx_doctor_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
}

dx_doctor_flock_present() {
    [[ -d /Applications/Flock.app ]] && return 0
    command -v flk >/dev/null 2>&1 && return 0
    return 1
}

# Print one line per probe. Return 1 when a selected probe fails.
dx_doctor_probes() {
    local selected rc=0
    selected="$(dx_doctor_selected 2>/dev/null || true)"
    [[ -n "$selected" ]] || return 0

    if printf '%s\n' "$selected" | dx_doctor_has foundation/base; then
        if dx_doctor_foundation_bins; then
            printf 'probe foundation/base ok\n'
        else
            printf 'probe foundation/base missing\n' >&2
            rc=1
        fi
    fi
    if printf '%s\n' "$selected" | dx_doctor_has apps/herdr; then
        if command -v herdr >/dev/null 2>&1; then
            printf 'probe herdr-on-path ok\n'
        else
            printf 'probe herdr-on-path missing\n' >&2
            rc=1
        fi
    fi
    if printf '%s\n' "$selected" | dx_doctor_has apps/flock; then
        if dx_doctor_flock_present && ! dx_doctor_flyenv_present; then
            printf 'probe flock-present ok\n'
            printf 'probe flyenv-absent ok\n'
        else
            printf 'probe flock-present failed\n' >&2
            rc=1
        fi
    elif printf '%s\n' "$selected" | dx_doctor_has apps/flyenv; then
        if dx_doctor_flyenv_present && ! dx_doctor_flock_present; then
            printf 'probe flyenv-present ok\n'
            printf 'probe flock-absent ok\n'
        elif dx_doctor_wsl && ! dx_doctor_flyenv_present; then
            printf 'probe flyenv-present deferred (Windows installer, not in-distro)\n'
        else
            printf 'probe flyenv-present failed\n' >&2
            rc=1
        fi
    fi
    return "$rc"
}
