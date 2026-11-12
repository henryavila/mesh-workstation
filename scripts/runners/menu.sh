#!/usr/bin/env bash
# scripts/runners/menu.sh — run the Node.js interactive menu.
#
# Usage:
#   bash menu.sh [--apply]
#   bash menu.sh help
#
# Without --apply: runs the selector, writes selections.list + params.env.
# With --apply: runs the selector, then executes the install/uninstall delta
# via install-engine.sh and uninstall-engine.sh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# shellcheck disable=SC1091
. "$ROOT/scripts/lib/log.sh"
# shellcheck source=../lib/dx-profiles.sh
. "$ROOT/scripts/lib/dx-profiles.sh"
# shellcheck source=../lib/menu-node.sh
. "$ROOT/scripts/lib/menu-node.sh"
dx_retire_no_mesh
# detect-os.sh PRINTS the platform (mac|wsl|linux|unknown) to stdout — it does
# NOT set an $OS variable. Run it and capture stdout, exactly as the engines do
# (install-engine.sh / uninstall-engine.sh). Sourcing it and reading $OS tripped
# `set -u` ("OS: unbound variable") and crashed `mesh menu` before launch.
PLATFORM="$(bash "$ROOT/scripts/lib/detect-os.sh" 2>/dev/null || echo unknown)"

APPLY=0
MODE="wizard"
while [[ $# -gt 0 ]]; do
    case "$1" in
        help) MODE="help"; shift ;;
        --apply) APPLY=1; shift ;;
        *) log_error "unknown arg: $1"; exit 64 ;;
    esac
done

if [[ "$MODE" == "help" && "$APPLY" -eq 1 ]]; then
    log_error "help cannot be combined with --apply"
    exit 64
fi

ensure_menu_node
if ! command -v node >/dev/null 2>&1; then
    log_error "Node.js is required for the interactive menu."
    log_error "Re-run from a TTY so setup can download the private menu runtime:"
    log_error "  bash setup.sh"
    exit 1
fi

MENU_DIR="$ROOT/scripts/menu"
# Dependency provisioning lives in the launcher (scripts/menu/index.js): it is
# the single entry every path runs, so it `npm ci`s against the committed
# lockfile on a missing OR drifted node_modules — no guard duplicated here. If
# it cannot provision (offline), index.js exits non-zero, propagated below.
if [[ "$MODE" == "help" ]]; then
    node "$MENU_DIR/index.js" help
else
    node "$MENU_DIR/index.js" "$@"
fi
menu_exit=$?

if (( menu_exit != 0 )); then
    exit $menu_exit
fi

if (( APPLY == 0 )); then
    exit 0
fi

SELECTIONS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list"
REMOVALS_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/mesh/removals.list"
if [[ ! -f "$SELECTIONS_FILE" ]]; then
    log_error "No selections file found after menu run."
    exit 1
fi

info "Applying selections..."

# The TUI writes bundles deselected since the previous apply to removals.list.
# Compute the final install closure first so a bundle re-selected directly or
# still required by another selected bundle is never removed by a stale
# removals.list entry.
uninstall_rc=0
if [[ -s "$REMOVALS_FILE" ]] && grep -qvE '^[[:space:]]*(#|$)' "$REMOVALS_FILE"; then
    MENU_APPLY_WORKDIR="$(mktemp -d "${TMPDIR:-/tmp}/mesh-menu-apply.XXXXXX")"
    trap 'rm -rf "$MENU_APPLY_WORKDIR"' EXIT
    CLOSURE_FILE="$MENU_APPLY_WORKDIR/closure.list"
    FILTERED_REMOVALS_FILE="$MENU_APPLY_WORKDIR/removals.list"

    if ! bash "$ROOT/scripts/lib/install-engine.sh" \
        --selections "$SELECTIONS_FILE" \
        --platform "$PLATFORM" \
        --print-closure > "$CLOSURE_FILE"
    then
        log_error "failed to compute selected bundle closure"
        exit 1
    fi

    : > "$FILTERED_REMOVALS_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue

        if grep -Fxq -- "$line" "$CLOSURE_FILE"; then
            log_warn "skipping removal for $line; still selected or required"
            continue
        fi
        printf '%s\n' "$line" >> "$FILTERED_REMOVALS_FILE"
    done < "$REMOVALS_FILE"

    if [[ -s "$FILTERED_REMOVALS_FILE" ]]; then
        info "Applying removals..."
        bash "$ROOT/scripts/lib/uninstall-engine.sh" \
            --selections "$FILTERED_REMOVALS_FILE" \
            --platform "$PLATFORM" || uninstall_rc=$?
        if [[ "$uninstall_rc" -ne 0 ]]; then
            log_warn "uninstall pass exited rc=$uninstall_rc; continuing to install"
        else
            rm -f "$REMOVALS_FILE"
        fi
    else
        info "No removals to apply after dependency closure."
        rm -f "$REMOVALS_FILE"
    fi
fi

# Manifest v2: the engine consumes the whole selections.list (topic/bundle
# entries), computes the requires_bundles closure + topological order, and
# applies them. No per-topic --manifest loop.
bash "$ROOT/scripts/lib/install-engine.sh" \
    --selections "$SELECTIONS_FILE" \
    --platform "$PLATFORM"

if [[ "$uninstall_rc" -ne 0 ]]; then
    log_error "uninstall pass failed; pending removals kept at $REMOVALS_FILE"
    exit "$uninstall_rc"
fi

info "All selections applied."
