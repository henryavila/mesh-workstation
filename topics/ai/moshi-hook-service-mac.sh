#!/usr/bin/env bash
# Custom installer: launch moshi-hook daemon on macOS.
#
# Two paths:
#   - canonical brew prefix (/opt/homebrew or /usr/local): brew services start
#   - custom prefix (e.g. /Volumes/External/homebrew): launch-wrapper for TCC
#
# Also handles first-time pairing + agent hook installation.

_moshi_resolve_ws_dir() {
    if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
        printf '%s' "${MESH_WORKSTATION_DIR}"
    else
        printf '%s' "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
    fi
}
_MOSHI_WS_DIR="$(_moshi_resolve_ws_dir)"
# shellcheck disable=SC1091
. "$_MOSHI_WS_DIR/scripts/lib/log.sh"

_use_wrapper() {
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local|"") return 1 ;;
        *) return 0 ;;
    esac
}

_is_running() {
    # Authoritative signal = the service-manager state install() actually
    # establishes (launchd wrapper, or `brew services`), NOT a loose
    # `pgrep -f 'moshi-hook serve'` substring (which any unrelated process —
    # a tail/editor/log line — could satisfy, and which would let an
    # unmanaged hand-started daemon masquerade as the supervised service).
    # All probes below are sudo-free.
    if ! _use_wrapper; then
        "${BREW_BIN:-brew}" services list 2>/dev/null \
            | awk '$1=="moshi-hook"{print $2}' | grep -qx 'started' && return 0
        return 1
    fi
    # Custom prefix: assert the launchd job is loaded AND in the running state.
    if launchctl print "gui/$(id -u)/com.${USER}.moshi-hook" 2>/dev/null \
        | grep -qE 'state[[:space:]]*=[[:space:]]*running'; then
        return 0
    fi
    # Fallback only when launchctl cannot answer (e.g. invoked outside a GUI
    # session, where `gui/<uid>` is unreachable): corroborate via pgrep so we
    # don't false-fail a genuinely-running daemon in that narrow context.
    if ! launchctl print "gui/$(id -u)/com.${USER}.moshi-hook" >/dev/null 2>&1; then
        pgrep -u "$USER" -f 'moshi-hook serve' >/dev/null 2>&1 && return 0
    fi
    return 1
}

_is_paired() {
    [[ -f "$HOME/.config/moshi/config.json" ]] \
        && moshi-hook status 2>/dev/null | grep -qi "paired\|connected" && return 0
    return 1
}

check() {
    _is_running
}

install() {
    local ws_dir
    ws_dir="$(_moshi_resolve_ws_dir)" || return 1

    # Teardown conflicting homebrew plists (both system + user scope)
    # before installing our wrapper — prevents dual-plist exit 78 loop.
    # shellcheck disable=SC1091
    . "$ws_dir/scripts/lib/launch-wrapper.sh"
    launch_wrapper_teardown_homebrew_plist moshi-hook 2>/dev/null || true

    if _use_wrapper; then
        local bin="${BREW_PREFIX}/opt/moshi-hook/bin/moshi-hook"
        [[ -x "$bin" ]] || { echo "[moshi-hook-service-mac] $bin not executable" >&2; return 1; }
        launch_wrapper_install_extbrew \
            --svc moshi-hook \
            --label "com.${USER}.moshi-hook" \
            --brew-bin "$bin" \
            -- serve
    else
        "${BREW_BIN:-brew}" services start moshi-hook \
            || { echo "[moshi-hook-service-mac] brew services start failed" >&2; return 1; }
    fi

    sleep 2

    # Pair if not already (one-shot, token from secrets.env)
    if ! _is_paired; then
        if [[ -n "${MOSHI_PAIRING_TOKEN:-}" ]]; then
            info "pairing moshi-hook with token from secrets.env"
            moshi-hook pair --token "$MOSHI_PAIRING_TOKEN" || true
        else
            followup manual "Run: moshi-hook pair --token <TOKEN> (from Moshi app → Settings → Integrations)"
        fi
    fi

    # Install agent hooks (idempotent)
    moshi-hook install 2>/dev/null || true
}

verify() {
    # Confirm the supervised service-manager state install() establishes
    # (launchd job loaded+running, or `brew services started`) — the same
    # authoritative probe as check(), now hardened away from the loose
    # `pgrep -f` substring.
    #
    # Pairing is deliberately NOT asserted here. install() only *attempts*
    # pairing (`pair || true`) and otherwise emits a manual followup when no
    # MOSHI_PAIRING_TOKEN is present — "service up, awaiting manual pairing"
    # is a legitimate, expected post-install state. Gating verify() on
    # _is_paired would make the engine treat that healthy state as a failure,
    # run rollback() (tearing the service back down) and exit 67. That is the
    # exact false-fail this hardening must avoid (repair plan §3.D risk note),
    # so functional pairing stays a manual/followup concern, not a verify gate.
    _is_running
}

repair() { install; }

rollback() {
    local ws_dir
    ws_dir="$(_moshi_resolve_ws_dir)" || return 1
    # shellcheck disable=SC1091
    . "$ws_dir/scripts/lib/launch-wrapper.sh"
    if _use_wrapper; then
        launch_wrapper_teardown "com.${USER}.moshi-hook" 2>/dev/null || true
    else
        "${BREW_BIN:-brew}" services stop moshi-hook 2>/dev/null || true
    fi
}

# restart() — bounce the supervised daemon so it reloads a freshly-upgraded
# binary. Invoked by the engine's --update pass when the moshi-hook formula
# actually changed (manifest restart_service: moshi-hook-mac-service). Gated on
# _is_running: if the daemon is already down we do NOTHING (never start a
# service the user deliberately stopped — autoupdate must not resurrect it).
# Both service-manager paths keep the same opt symlink target across versions,
# so an in-place bounce is enough; no teardown/reinstall (which would re-pair).
restart() {
    if ! _is_running; then
        info "moshi-hook service not running — skip restart (autoupdate)"
        return 0
    fi
    if _use_wrapper; then
        info "restarting moshi-hook (launchd wrapper) to load the upgraded binary"
        launchctl kickstart -k "gui/$(id -u)/com.${USER}.moshi-hook" 2>/dev/null \
            || { echo "[moshi-hook-service-mac] launchctl kickstart failed" >&2; return 1; }
    else
        info "restarting moshi-hook (brew services) to load the upgraded binary"
        "${BREW_BIN:-brew}" services restart moshi-hook >/dev/null 2>&1 \
            || { echo "[moshi-hook-service-mac] brew services restart failed" >&2; return 1; }
    fi
    sleep 1
    _is_running
}

uninstall() {
    # Reverse what install() established — the SERVICE-MANAGER state, not the
    # moshi-hook binary. install() asserts the binary is already present
    # (`[[ -x "$bin" ]] || return 1`); it never installs it. The binary is a
    # brew formula owned by a *different* bundle item, so `brew uninstall
    # moshi-hook` here would yank a shared dependency — out of scope. We remove
    # only the launchd wrapper job (custom prefix) or the `brew services`
    # registration (canonical prefix), plus the agent hooks install() added via
    # `moshi-hook install`. Pairing data (~/.config/moshi/config.json) is
    # user-owned credential/config — never deleted.
    #
    # errexit is OFF in custom verbs and `set +e` is L03-banned, so every step
    # is best-effort via `|| true` / captured rc; success is gated on the
    # service being gone (! _is_running), mirroring ngrok's honest marker drop.
    local ws_dir
    ws_dir="$(_moshi_resolve_ws_dir)" || return 1
    # shellcheck disable=SC1091
    . "$ws_dir/scripts/lib/launch-wrapper.sh"

    # 1. Remove the agent hooks install() registered (idempotent, best-effort).
    #    Only attempt when the binary is still present and exposes `uninstall`;
    #    capture rc rather than letting a non-zero exit propagate.
    if command -v moshi-hook >/dev/null 2>&1; then
        local _hrc=0
        moshi-hook uninstall >/dev/null 2>&1 || _hrc=$?
        # _hrc is advisory only (subcommand may not exist on older builds);
        # the marker drop is gated on service teardown below, not on this.
    fi

    # 2. Tear down the service-manager registration on whichever path install()
    #    used. Both teardown helpers are idempotent and no-op when absent.
    if _use_wrapper; then
        launch_wrapper_teardown "com.${USER}.moshi-hook" 2>/dev/null || true
    else
        "${BREW_BIN:-brew}" services stop moshi-hook 2>/dev/null || true
    fi

    # 3. Honest success gate: the supervised service must actually be gone, so
    #    the engine only drops the install marker when teardown really took.
    if _is_running; then
        echo "[moshi-hook-service-mac] uninstall: service still running after teardown" >&2
        return 1
    fi
    return 0
}
