#!/usr/bin/env bash
# doctor.sh — status + drift detector for the identity deploy surface.
#
# What it checks:
#   1. For each mapping in install.sh (src|dst[|mode]):
#        ✓ src matches dst byte-for-byte (deploy up to date)
#        ! dst missing (install.sh never ran, or user deleted)
#        ✗ dst drifted (content differs from src)
#   2. Identity git state:
#        ✗ uncommitted changes or unpushed commits (config exists only locally)
#   3. For mesh-workstation-managed files (~/.bashrc, ~/.zshrc, ~/.tmux.conf):
#        ✓ header "managed by mesh-workstation" present
#        ! marker absent (hand-edited or deployed by another tool)
#   4. Optional fragment inventory (--fragments):
#        Lists active files in ~/.bashrc.d/ and ~/.zshrc.d/.
#
# Exit codes:
#   0  everything in sync
#   1  drift / missing files detected
#
# Usage:
#   bash scripts/runners/doctor.sh            # human-readable report
#   bash scripts/runners/doctor.sh --quiet    # only drift/missing lines
#   bash scripts/runners/doctor.sh --json     # structured output (for automation)
#   bash scripts/runners/doctor.sh --fix      # re-sync drifted/missing mappings
#   bash scripts/runners/doctor.sh --fragments       # include active fragment inventory
#   bash scripts/runners/doctor.sh --all-fragments   # include backups too
#
# Override knobs (forks using a non-mesh-workstation installer):
#   DOCTOR_MARKER_FILES   space-separated list of files to check for the
#                         "managed by" marker. Default: ~/.bashrc ~/.zshrc
#                         ~/.tmux.conf (the three files mesh-workstation manages).
#   DOCTOR_MARKER_STRING  the substring to look for. Default:
#                         "managed by mesh-workstation".
#   Example: DOCTOR_MARKER_FILES="$HOME/.zshrc" DOCTOR_MARKER_STRING="managed by chezmoi" bash doctor.sh

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Workstation root: $HERE = scripts/runners/, so two levels up.
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/managed-block.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/deploy.sh"   # deploy_map_emit() — shared deploy.map parser
# shellcheck disable=SC1091
. "$REPO/scripts/lib/external-brew-mount.sh"   # ebm_detect/ebm_report_line (mac-only)
# The deploy set lives in identity's deploy.map data file (post-restructure:
# workstation has no top-level install.sh; the set is identity-owned DATA per
# spec D-B3 / §C18, and as of audit T-001 is a deploy.map, not a MAPPINGS array
# in install.sh). Resolve identity via MESH_IDENTITY_DIR with the usual fallback.
IDENTITY="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"
DEPLOY_MAP="$IDENTITY/deploy.map"

QUIET=0
JSON=0
FIX=0
SHOW_FRAGMENTS=0
ALL_FRAGMENTS=0
for a in "$@"; do
    case "$a" in
        --quiet|-q)      QUIET=1 ;;
        --json)          JSON=1  ;;
        --fix)           FIX=1   ;;
        --fragments|--verbose)
                         SHOW_FRAGMENTS=1 ;;
        --all-fragments) SHOW_FRAGMENTS=1; ALL_FRAGMENTS=1 ;;
        --help|-h)
            sed -n '2,34p' "$0"
            exit 0
            ;;
    esac
done

# ─── Colors ────────────────────────────────────────────────────────
if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    C_OK=$'\e[32m'; C_WARN=$'\e[33m'; C_ERR=$'\e[31m'; C_DIM=$'\e[2m'; C_RESET=$'\e[0m'
else
    C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RESET=""
fi

# ─── Accumulators ──────────────────────────────────────────────────
count_ok=0 count_drift=0 count_missing=0 count_marker_miss=0
count_launchd_phantom=0 count_composer_phar=0 count_ext_brew_mount=0
count_engine_health=0 count_engine_fixed=0
count_local_only=0 count_fixed=0
drift_items=() missing_items=() marker_miss_items=()
launchd_phantom_items=() composer_phar_items=() fixed_items=()
engine_health_items=() engine_fixed_items=()
local_only_items=()
ext_brew_mount_desc=""

# ─── Parse the deploy.map (shared parser) ──────────────────────────
# Emits one normalized "src|dst|mode|perms" row per entry via deploy_map_emit —
# the SAME parser deploy.sh uses to deploy, so the drift check can never disagree
# with what install actually wrote (audit T-001: single source of truth for the
# grammar). dst arrives already expanded + trimmed.
parse_mappings() {
    # Silent when the map is absent (clean install or identity not deployed);
    # downstream loop sees zero rows, exits at the JSON/text rendering step.
    [[ -f "$DEPLOY_MAP" ]] || return 0
    deploy_map_emit "$DEPLOY_MAP" 2>/dev/null
}

# In --fix mode, re-deploy one mapping from the identity tree to heal a drifted
# or missing dst. deploy_one (sourced from deploy.sh above) re-applies the exact
# entry install.sh would. On failure the item stays visible under its original
# category so the run still exits non-zero.
_fix_mapping() {
    local raw="$1" dst="$2" src="$3" kind="$4"   # kind: drift | missing
    if deploy_one "$raw" "$IDENTITY" >/dev/null 2>&1; then
        count_fixed=$((count_fixed + 1))
        fixed_items+=("$dst  (src=$src)")
        return 0
    fi
    if [[ "$kind" == "missing" ]]; then
        count_missing=$((count_missing + 1))
        missing_items+=("$dst  (src=$src) — fix FAILED")
    else
        count_drift=$((count_drift + 1))
        drift_items+=("$dst  (src=$src) — fix FAILED")
    fi
    return 1
}

check_mapping() {
    local raw="$1"
    local src dst mode
    IFS='|' read -r src dst mode _ <<< "$raw"
    mode="${mode:-overwrite}"
    # dst is already expanded + trimmed by deploy_map_emit (shared parser).
    local src_abs="$IDENTITY/$src"

    # Skip entries whose src is a placeholder we haven't filled in
    [[ ! -f "$src_abs" ]] && return 0

    if [[ ! -e "$dst" ]]; then
        if [[ "$FIX" == "1" ]]; then
            _fix_mapping "$raw" "$dst" "$src" missing
        else
            count_missing=$((count_missing + 1))
            missing_items+=("$dst  (src=$src)")
        fi
        return 0
    fi

    if [[ "$mode" == "once" ]]; then
        # "once" entries are user-editable after deploy — drift is expected
        # and fine. We only report that the file exists.
        count_ok=$((count_ok + 1))
        return 0
    fi

    if [[ "$mode" == "managed_block" ]]; then
        # `managed_block` deploys splice the src content between marker
        # lines, preserving anything outside the markers (user-owned
        # ad-hoc entries — CI runners' SSH keys, temp devices, etc.).
        # `cmp` against src would always disagree because dst has those
        # extra lines on purpose. Compare just the marker-bounded slice.
        if managed_block_in_sync "$src_abs" "$dst" "$src"; then
            count_ok=$((count_ok + 1))
        elif [[ "$FIX" == "1" ]]; then
            _fix_mapping "$raw" "$dst" "$src" drift
        else
            count_drift=$((count_drift + 1))
            drift_items+=("$dst  (src=$src)")
        fi
        return 0
    fi

    if cmp -s "$src_abs" "$dst"; then
        count_ok=$((count_ok + 1))
    elif [[ "$FIX" == "1" ]]; then
        _fix_mapping "$raw" "$dst" "$src" drift
    else
        count_drift=$((count_drift + 1))
        drift_items+=("$dst  (src=$src)")
    fi
}

# ─── Managed-by marker check ───────────────────────────────────────
# Defaults match the mesh-workstation convention. Override via env if your
# fork uses a different installer that writes its own marker string.
DOCTOR_MARKER_STRING="${DOCTOR_MARKER_STRING:-managed by mesh-workstation}"
if [[ -n "${DOCTOR_MARKER_FILES:-}" ]]; then
    # Word-split the env value (space-separated paths, no globbing).
    read -r -a MARKER_FILES <<< "$DOCTOR_MARKER_FILES"
else
    MARKER_FILES=(
        "$HOME/.bashrc"
        "$HOME/.zshrc"
        "$HOME/.tmux.conf"
    )
fi
check_markers() {
    local f
    for f in "${MARKER_FILES[@]}"; do
        [[ ! -f "$f" ]] && continue
        if ! grep -qiE "managed by (mesh-workstation|dev-bootstrap)" "$f" 2>/dev/null; then
            count_marker_miss=$((count_marker_miss + 1))
            marker_miss_items+=("$f")
        fi
    done
}

# ─── Identity local-only git state ─────────────────────────────────
# The identity repo is the persisted config source. A file changed but not
# committed, or a commit not pushed to the upstream, exists only on this machine.
check_identity_local_only() {
    git -C "$IDENTITY" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0

    local line path ahead
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" ]] || continue
        path="${line#???}"
        count_local_only=$((count_local_only + 1))
        local_only_items+=("uncommitted: $path")
    done < <(git -C "$IDENTITY" status --porcelain=v1 --untracked-files=all 2>/dev/null)

    ahead="$(git -C "$IDENTITY" rev-list --count '@{upstream}..HEAD' 2>/dev/null || printf '0')"
    if [[ "$ahead" != "0" ]]; then
        count_local_only=$((count_local_only + 1))
        local_only_items+=("unpushed: $ahead commit(s) ahead of upstream")
    fi
}

# ─── LaunchDaemon volume-path check (Mac only) ─────────────────────
# Detects `homebrew.mxcl.*.plist` files in /Library/LaunchDaemons/ that
# have Standard{Error,Out}Path inside /Volumes/* — these create a phantom
# `mkdir -p` of the parent path on rootfs at boot if launchd loads the
# daemon before the external volume mounts. The phantom collides with
# the real mount point, causing diskarbitrationd to disambiguate the
# mount path (e.g. `/Volumes/External 1`), breaking everything on the
# external volume.
#
# Plists in /Library/LaunchDaemons/ are mode 0644 (world-readable), so
# this check needs no sudo. We use grep -A1 to find the key + adjacent
# string-line, then assert no /Volumes/ in the value.
#
# DOCTOR_LAUNCHD_DIR env override exists for tests — production uses the
# system path. No effect outside Darwin.
check_launchd_volume_paths() {
    [[ "$(uname -s)" != "Darwin" ]] && return 0
    local launchd_dir="${DOCTOR_LAUNCHD_DIR:-/Library/LaunchDaemons}"
    [[ ! -d "$launchd_dir" ]] && return 0
    # CP4 D-F-008: parse the plist semantically via plutil instead of relying
    # on `grep -A1 <key>` adjacency. The previous form worked because Homebrew
    # emits `<key>...</key>\n<string>...</string>` back-to-back; comments,
    # blank lines, or third-party plist generators with attribute lists would
    # silently miss a phantom path. `plutil -extract KEY raw` is macOS-bundled
    # and returns the string value (rc=0) or fails clean (rc=1) when absent.
    local plist key val
    for plist in "$launchd_dir"/homebrew.mxcl.*.plist; do
        [[ -f "$plist" ]] || continue
        for key in StandardErrorPath StandardOutPath; do
            val="$(plutil -extract "$key" raw -o - "$plist" 2>/dev/null || true)"
            if [[ "$val" == /Volumes/* ]]; then
                count_launchd_phantom=$((count_launchd_phantom + 1))
                launchd_phantom_items+=("$plist")
                break  # don't double-count when both Err and Out are phantom
            fi
        done
    done
}

# ─── Composer PHAR integrity check ─────────────────────────────────
# Homebrew bottle relocation can rewrite `/usr/local` bytes inside
# Composer's PHAR when Homebrew lives under a non-default prefix such as
# /Volumes/External/homebrew. That invalidates the embedded SHA512 PHAR
# signature and leaves `composer` installed but unusable.
check_composer_phar() {
    local composer_bin out tmo_bin
    composer_bin="$(command -v composer 2>/dev/null || true)"
    [[ -n "$composer_bin" ]] || return 0

    # CP4 D-F-006: hanging composer (broken plugin / first-run network probe
    # / corrupt jenv shim) would block doctor → mesh-snap → shell-start
    # precmd. Cap the probe at 10s when a timeout binary is available.
    # Linux ships `timeout` in coreutils by default; macOS ships `gtimeout`
    # via `brew install coreutils`. If neither exists we still run the probe
    # un-bounded (preserves the historical check for hosts without either).
    if command -v timeout >/dev/null 2>&1; then
        tmo_bin="timeout"
    elif command -v gtimeout >/dev/null 2>&1; then
        tmo_bin="gtimeout"
    else
        tmo_bin=""
    fi

    if [[ -n "$tmo_bin" ]]; then
        if out="$("$tmo_bin" 10s "$composer_bin" --version 2>&1)"; then
            return 0
        fi
    else
        if out="$("$composer_bin" --version 2>&1)"; then
            return 0
        fi
    fi

    case "$out" in
        *"SHA512 signature could not be verified: broken signature"*|*"PharException"*broken*signature*)
            count_composer_phar=$((count_composer_phar + 1))
            composer_phar_items+=("$composer_bin")
            ;;
    esac
}

# ─── External-brew mount-disambiguation check (Mac only) ───────────
# Detects the *materialized* failure (distinct from check_launchd_volume_paths,
# which flags the racy PLISTS that cause it): brew's prefix volume is mounted
# at a disambiguated path (e.g. "/Volumes/External 1") because a phantom dir
# occupies its canonical mount point. Read-only here; `mesh doctor --fix` heals
# it via scripts/runners/heal-external-brew-mount.sh. Generic + name-agnostic
# (the volume name is read from diskutil, never hardcoded). No-op off Darwin.
check_external_brew_mount() {
    ebm_supported || return 0
    if ebm_detect; then
        count_ext_brew_mount=1
        ext_brew_mount_desc="$(ebm_report_line)"
    fi
}

# ─── Engine health check (selected installed items) ─────────────────────────
# Read-only doctor reports marker-present selected items whose strongest probe
# fails. Both read-only health and `--fix` delegate to install-engine so bundle
# platforms, item when gates, params/secrets/options, and driver dispatch stay
# identical to normal apply.
_engine_topics_dir() {
    printf '%s' "${MESH_DOCTOR_TOPICS_DIR:-$REPO/topics}"
}

_engine_selections_file() {
    printf '%s' "${MESH_DOCTOR_SELECTIONS_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/mesh/selections.list}"
}

_engine_platform() {
    if [[ -n "${MESH_OS:-}" ]]; then
        printf '%s' "$MESH_OS"
    elif [[ -r "$REPO/scripts/lib/detect-os.sh" ]]; then
        bash "$REPO/scripts/lib/detect-os.sh" 2>/dev/null || printf 'unknown'
    else
        printf 'unknown'
    fi
}

_engine_scope_ready() {
    [[ -d "$(_engine_topics_dir)" && -r "$(_engine_selections_file)" && -r "$REPO/scripts/lib/install-engine.sh" ]]
}

_engine_collect_broken() {
    _engine_scope_ready || return 0
    local topics_dir selections engine platform out rc
    topics_dir="$(_engine_topics_dir)"
    selections="$(_engine_selections_file)"
    engine="$REPO/scripts/lib/install-engine.sh"
    platform="$(_engine_platform)"
    rc=0
    out="$(bash "$engine" \
        --topics-dir "$topics_dir" \
        --selections "$selections" \
        --platform "$platform" \
        --non-interactive \
        --health 2>/dev/null)" || rc=$?
    case "$rc" in
        0|67) printf '%s\n' "$out" ;;
        *) return 0 ;;
    esac
}

_list_contains_line() {
    local haystack="$1" needle="$2"
    grep -Fxq -- "$needle" <<< "$haystack"
}

check_engine_health() {
    local broken item
    broken="$(_engine_collect_broken)"
    [[ -n "$broken" ]] || return 0
    while IFS= read -r item || [[ -n "$item" ]]; do
        [[ -n "$item" ]] || continue
        count_engine_health=$((count_engine_health + 1))
        engine_health_items+=("$item")
    done <<< "$broken"
}

fix_engine_health() {
    _engine_scope_ready || return 0
    local before after item engine topics_dir selections platform repair_out repair_rc=0
    before="$(_engine_collect_broken)"
    [[ -n "$before" ]] || return 0
    engine="$REPO/scripts/lib/install-engine.sh"
    topics_dir="$(_engine_topics_dir)"
    selections="$(_engine_selections_file)"
    platform="$(_engine_platform)"
    repair_out="$(bash "$engine" \
        --topics-dir "$topics_dir" \
        --selections "$selections" \
        --platform "$platform" \
        --non-interactive \
        --repair 2>&1)" || repair_rc=$?
    after="$(_engine_collect_broken)"
    while IFS= read -r item || [[ -n "$item" ]]; do
        [[ -n "$item" ]] || continue
        if ! _list_contains_line "$after" "$item"; then
            count_engine_fixed=$((count_engine_fixed + 1))
            engine_fixed_items+=("$item")
        fi
    done <<< "$before"
    if [[ "$repair_rc" -ne 0 && -n "$repair_out" && -z "$after" ]]; then
        engine_health_items+=("install-engine --repair rc=$repair_rc: ${repair_out//$'\n'/ }")
        count_engine_health=$((count_engine_health + 1))
    fi
}

# ─── Fragments listing ─────────────────────────────────────────────
list_fragments() {
    local pair dir label entries name backup_count
    for pair in "$HOME/.bashrc.d:bash" "$HOME/.zshrc.d:zsh"; do
        dir="${pair%%:*}"
        label="${pair##*:}"
        [[ ! -d "$dir" ]] && continue
        if [[ "$QUIET" == 0 ]] && [[ "$JSON" == 0 ]]; then
            entries="$(ls -1 "$dir" 2>/dev/null || true)"
            [[ -n "$entries" ]] || continue
            echo
            echo "${C_DIM}Fragments in $dir ($label):${C_RESET}"
            backup_count=0
            while IFS= read -r name || [[ -n "$name" ]]; do
                [[ -n "$name" ]] || continue
                if [[ "$name" == *.bak || "$name" == *.bak-* ]]; then
                    backup_count=$((backup_count + 1))
                    (( ALL_FRAGMENTS == 1 )) || continue
                fi
                printf '  %s\n' "$name"
            done <<< "$entries"
            if (( ALL_FRAGMENTS == 0 && backup_count > 0 )); then
                printf '  %s\n' "... $backup_count backup fragment(s) hidden (use --all-fragments)"
            fi
        fi
    done
}

# ─── Run ───────────────────────────────────────────────────────────
while IFS= read -r line; do
    check_mapping "$line"
done < <(parse_mappings)

check_markers
check_identity_local_only
check_launchd_volume_paths
check_composer_phar
check_external_brew_mount
if [[ "$FIX" == "1" ]]; then
    fix_engine_health
fi
check_engine_health

# ─── Output ────────────────────────────────────────────────────────
if [[ "$JSON" == 1 ]]; then
    # Minimal JSON without jq (so the script has no runtime deps)
    printf '{"ok":%d,"drift":%d,"missing":%d,"marker_miss":%d,"launchd_phantom":%d,"composer_phar":%d,"ext_brew_mount":%d,"engine_health":%d,"engine_fixed":%d,"local_only":%d,"fixed":%d,' \
        "$count_ok" "$count_drift" "$count_missing" "$count_marker_miss" "$count_launchd_phantom" "$count_composer_phar" "$count_ext_brew_mount" "$count_engine_health" "$count_engine_fixed" "$count_local_only" "$count_fixed"
    printf '"drift_items":['
    sep=""
    # bash 3.2 + set -u: empty `"${arr[@]}"` is unbound; guard with size.
    if (( ${#drift_items[@]} > 0 )); then
        for d in "${drift_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf '],"missing_items":['
    sep=""
    if (( ${#missing_items[@]} > 0 )); then
        for d in "${missing_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf '],"marker_miss_items":['
    sep=""
    if (( ${#marker_miss_items[@]} > 0 )); then
        for d in "${marker_miss_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf '],"launchd_phantom_items":['
    sep=""
    if (( ${#launchd_phantom_items[@]} > 0 )); then
        for d in "${launchd_phantom_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf '],"composer_phar_items":['
    sep=""
    if (( ${#composer_phar_items[@]} > 0 )); then
        for d in "${composer_phar_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf '],"engine_health_items":['
    sep=""
    if (( ${#engine_health_items[@]} > 0 )); then
        for d in "${engine_health_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf '],"engine_fixed_items":['
    sep=""
    if (( ${#engine_fixed_items[@]} > 0 )); then
        for d in "${engine_fixed_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf '],"local_only_items":['
    sep=""
    if (( ${#local_only_items[@]} > 0 )); then
        for d in "${local_only_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf '],"fixed_items":['
    sep=""
    if (( ${#fixed_items[@]} > 0 )); then
        for d in "${fixed_items[@]}"; do
            printf '%s"%s"' "$sep" "${d//\"/\\\"}"
            sep=","
        done
    fi
    printf ']}\n'
else
    if [[ "$QUIET" == 0 ]]; then
        echo "${C_DIM}mesh doctor :: $REPO${C_RESET}"
        echo "  ${C_OK}✓${C_RESET} up-to-date     : $count_ok"
        echo "  ${C_WARN}!${C_RESET} missing        : $count_missing"
        echo "  ${C_ERR}✗${C_RESET} drift          : $count_drift"
        echo "  ${C_WARN}!${C_RESET} marker miss    : $count_marker_miss"
        echo "  ${C_ERR}✗${C_RESET} launchd phantom: $count_launchd_phantom"
        echo "  ${C_ERR}✗${C_RESET} composer PHAR  : $count_composer_phar"
        echo "  ${C_ERR}✗${C_RESET} ext-brew mount : $count_ext_brew_mount"
        echo "  ${C_ERR}✗${C_RESET} engine health  : $count_engine_health"
        echo "  ${C_ERR}✗${C_RESET} local-only cfg : $count_local_only"
    fi

    # The `(( count_* > 0 ))` guards already imply array non-empty (only the
    # JSON branch needed the explicit size check because it iterates even
    # when count==0 to emit `[]`). Keep these blocks unchanged.
    if (( count_missing > 0 )); then
        echo
        echo "${C_WARN}Missing (install.sh never ran, or user deleted):${C_RESET}"
        for m in "${missing_items[@]}"; do echo "  ! $m"; done
    fi
    if (( count_fixed > 0 )); then
        echo
        echo "${C_OK}Re-synced (deploy refreshed from src — was drifted/missing):${C_RESET}"
        for f in "${fixed_items[@]}"; do echo "  ✓ $f"; done
    fi
    if (( count_drift > 0 )); then
        echo
        echo "${C_ERR}Drifted (dst differs from src — run 'mesh doctor --fix' to sync):${C_RESET}"
        for d in "${drift_items[@]}"; do echo "  ✗ $d"; done
    fi
    if (( count_marker_miss > 0 )); then
        echo
        echo "${C_WARN}Missing '$DOCTOR_MARKER_STRING' marker (hand-edited? not from your installer?):${C_RESET}"
        for m in "${marker_miss_items[@]}"; do echo "  ! $m"; done
        echo "  ${C_DIM}next: mesh reinstall shell${C_RESET}"
        echo "  ${C_DIM}    (doctor --fix does not rewrite shell rc files)${C_RESET}"
        echo "  ${C_DIM}    move personal snippets to ~/.zshrc.local / ~/.bashrc.local, then:${C_RESET}"
        echo "  ${C_DIM}      mv ~/.zshrc ~/.zshrc.unmanaged.bak   # if unmarked${C_RESET}"
        echo "  ${C_DIM}      mv ~/.bashrc ~/.bashrc.unmanaged.bak # if unmarked${C_RESET}"
        echo "  ${C_DIM}      mesh reinstall shell${C_RESET}"
    fi
    if (( count_launchd_phantom > 0 )); then
        echo
        echo "${C_ERR}LaunchDaemon Standard*Path inside /Volumes/* — phantoms on next boot:${C_RESET}"
        for p in "${launchd_phantom_items[@]}"; do echo "  ✗ $p"; done
        echo "  ${C_DIM}fix: re-run setup.sh (web hardens the plists), or${C_RESET}"
        echo "  ${C_DIM}     manually rewrite Standard*Path → /var/log/homebrew/<svc>.log${C_RESET}"
    fi
    if (( count_composer_phar > 0 )); then
        echo
        echo "${C_ERR}Composer PHAR has a broken signature:${C_RESET}"
        for p in "${composer_phar_items[@]}"; do echo "  ✗ $p"; done
        echo "  ${C_DIM}fix: brew reinstall --build-from-source composer${C_RESET}"
    fi
    if (( count_engine_fixed > 0 )); then
        echo
        echo "${C_OK}Engine items repaired and reverified:${C_RESET}"
        for p in "${engine_fixed_items[@]}"; do
            echo "  ✓ $p  owner=${p%%/*}; action=install-engine --repair"
        done
    fi
    if (( count_engine_health > 0 )); then
        echo
        if [[ "$FIX" == "1" ]]; then
            echo "${C_ERR}Engine health unresolved after repair:${C_RESET}"
        else
            echo "${C_ERR}Engine health broken (selected installed items):${C_RESET}"
        fi
        for p in "${engine_health_items[@]}"; do
            if [[ "$p" =~ ^[^[:space:]/]+/[^[:space:]/]+$ ]]; then
                if [[ "$FIX" == "1" ]]; then
                    echo "  ✗ $p  owner=${p%%/*}; attempted=install-engine --repair; next=inspect topics/${p%%/*}/manifest.yaml and rerun mesh doctor --fix"
                else
                    echo "  ✗ $p  owner=${p%%/*}; attempted=read-only verify; next=run mesh doctor --fix"
                fi
            else
                echo "  ✗ $p"
            fi
        done
    fi
    if (( count_ext_brew_mount > 0 )); then
        echo
        echo "${C_ERR}External-brew volume mounted at a disambiguated path (phantom collision):${C_RESET}"
        echo "  ✗ $ext_brew_mount_desc"
        echo "  ${C_DIM}fix: mesh doctor --fix  (heals the mount, then repairs the stack)${C_RESET}"
    fi
    if (( count_local_only > 0 )); then
        echo
        echo "${C_ERR}Local-only identity config (not replicated to the mesh):${C_RESET}"
        for p in "${local_only_items[@]}"; do echo "  ✗ $p"; done
        echo "  ${C_DIM}fix: commit and push the identity repo, or rerun the command and accept its push prompt${C_RESET}"
    fi

    if (( SHOW_FRAGMENTS == 1 )); then
        list_fragments
    fi
fi

# Exit code: 0 iff no drift/missing/phantom/unresolved health finding
# shellcheck disable=SC1091
. "$REPO/scripts/lib/dx-doctor.sh"
if ! dx_doctor_probes; then
    count_engine_health=$((count_engine_health + 1))
fi
if (( count_drift > 0 || count_missing > 0 || count_marker_miss > 0 || count_launchd_phantom > 0 || count_composer_phar > 0 || count_ext_brew_mount > 0 || count_engine_health > 0 || count_local_only > 0 )); then
    exit 1
fi
exit 0
