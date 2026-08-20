#!/usr/bin/env bash
# diagnose-wsl-interop.sh — pinpoint why `powershell.exe` / `pwsh.exe`
# isn't reachable from WSL, which blocks the Windows CA import step
# (Chrome/Edge on Windows won't trust *.localhost HTTPS without it).
#
# Run this when Windows Chrome/Edge shows NET::ERR_CERT_AUTHORITY_INVALID
# on https://*.localhost, or when setup printed a "Windows CA import
# skipped" follow-up. It checks 6 interop points and always prints the
# exact Windows PowerShell command that imports the mkcert CA (Lane B).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/lib/log.sh" 2>/dev/null || {
    ok()   { printf "✓ %s\n" "$*"; }
    info() { printf "→ %s\n" "$*"; }
    warn() { printf "! %s\n" "$*" >&2; }
    fail() { printf "✗ %s\n" "$*" >&2; }
}

banner() {
    printf '\n── %s ──\n' "$1"
}

# Summary tracking: first check that fails points at the root cause.
FIRST_FAIL=""
record_fail() {
    [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="$1"
}

# ─── 1. Are we actually in WSL? ───────────────────────────────────────
banner "1. Is this WSL?"
if grep -qi microsoft /proc/version 2>/dev/null; then
    ok "kernel identifies as WSL: $(uname -r)"
else
    fail "not running under WSL — nothing to diagnose here"
    exit 1
fi

# WSL1 vs WSL2 matters for interop: WSL1's /mnt/c is a real mount,
# WSL2's is a 9P server that can break independently.
if [[ -f /proc/wsl/version ]]; then
    ok "WSL version file present: /proc/wsl/version"
elif [[ -n "${WSL_DISTRO_NAME:-}" ]] || [[ -n "${WSL_INTEROP:-}" ]]; then
    ok "WSL env vars set: WSL_DISTRO_NAME=${WSL_DISTRO_NAME:-<unset>} WSL_INTEROP=${WSL_INTEROP:-<unset>}"
fi

# ─── 2. /mnt/c mount health ───────────────────────────────────────────
banner "2. /mnt/c mount"
if ls -d /mnt/c >/dev/null 2>&1; then
    ok "/mnt/c accessible"
    if ls /mnt/c/Windows/System32/ >/dev/null 2>&1; then
        ok "/mnt/c/Windows/System32 listable (9P responding)"
    else
        fail "/mnt/c/Windows/System32 NOT listable — 9P server side appears broken"
        record_fail "mnt-c-9p-broken"
    fi
else
    fail "/mnt/c inaccessible: $(ls -d /mnt/c 2>&1 | head -1)"
    record_fail "mnt-c-unavailable"
fi

# ─── 3. binfmt_misc WSLInterop registration ──────────────────────────
banner "3. binfmt_misc WSLInterop"
# Interop (running Windows .exe from inside WSL) relies on binfmt_misc
# registering the WSLInterop handler at boot. WSL usually registers it
# at startup via /init, but a broken systemd unit, a wsl.conf edit with
# a syntax error, or a half-initialized session can skip it.
if [[ -f /proc/sys/fs/binfmt_misc/WSLInterop ]]; then
    if grep -q '^enabled' /proc/sys/fs/binfmt_misc/WSLInterop; then
        ok "WSLInterop registered and enabled"
    else
        fail "WSLInterop registered but NOT enabled"
        record_fail "binfmt-disabled"
    fi
elif [[ -f /proc/sys/fs/binfmt_misc/WSLInterop-late ]]; then
    ok "WSLInterop-late registered (systemd-based WSL — newer pattern)"
else
    fail "binfmt WSLInterop NOT registered in /proc/sys/fs/binfmt_misc"
    record_fail "binfmt-missing"
fi

# ─── 4. WSL_INTEROP env var ───────────────────────────────────────────
banner "4. WSL_INTEROP socket"
if [[ -n "${WSL_INTEROP:-}" ]] && [[ -S "$WSL_INTEROP" ]]; then
    ok "WSL_INTEROP socket exists: $WSL_INTEROP"
else
    fail "WSL_INTEROP socket missing: ${WSL_INTEROP:-<unset>}"
    record_fail "interop-socket-missing"
fi

# ─── 5. /etc/wsl.conf — any interop disable flags? ───────────────────
banner "5. /etc/wsl.conf flags"
if [[ -f /etc/wsl.conf ]]; then
    ok "/etc/wsl.conf exists"
    interop_enabled="$(grep -E '^\s*enabled' /etc/wsl.conf 2>/dev/null | head -1)"
    path_append="$(grep -E '^\s*appendWindowsPath' /etc/wsl.conf 2>/dev/null | head -1)"
    if [[ -n "$interop_enabled" ]]; then
        info "interop explicit setting: $interop_enabled"
        [[ "$interop_enabled" =~ false ]] && {
            fail "interop disabled in /etc/wsl.conf"
            record_fail "wsl-conf-interop-false"
        }
    fi
    if [[ -n "$path_append" ]]; then
        info "PATH append setting: $path_append"
    fi
else
    info "/etc/wsl.conf not present (defaults apply)"
fi

# ─── 6. Can we actually invoke powershell.exe? ───────────────────────
banner "6. powershell.exe execution"
PWSH_CANDIDATES=(
    powershell.exe
    pwsh.exe
    "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    "/mnt/c/Program Files/PowerShell/7/pwsh.exe"
)

PWSH_FOUND=""
PWSH_RUNS=""
for cand in "${PWSH_CANDIDATES[@]}"; do
    # Can we locate it?
    if command -v "$cand" >/dev/null 2>&1 || [[ -x "$cand" ]]; then
        PWSH_FOUND="$cand"
        # Can we actually run it?
        if out="$("$cand" -NoProfile -Command 'Write-Output ok' 2>&1)" && [[ "$out" == "ok"* ]]; then
            PWSH_RUNS="$cand"
            break
        fi
    fi
done

if [[ -n "$PWSH_RUNS" ]]; then
    ok "can locate AND execute: $PWSH_RUNS"
elif [[ -n "$PWSH_FOUND" ]]; then
    fail "found $PWSH_FOUND but execution failed"
    record_fail "pwsh-found-but-cannot-run"
else
    fail "no powershell.exe or pwsh.exe found in PATH or standard Windows paths"
    record_fail "pwsh-not-found"
fi

# ─── Diagnosis ────────────────────────────────────────────────────────
banner "Diagnosis"

# Windows-side fallback ALWAYS works, independent of anything we check
# above — `wsl.exe` calls from Windows go through the VM host channel,
# not through binfmt_misc. We print it first so the user always has a
# working path, regardless of which check failed.
DISTRO_NAME="${WSL_DISTRO_NAME:-$(lsb_release -si 2>/dev/null || echo Ubuntu)}"
# $HERE is already an absolute WSL path, so the UNC is valid even when this
# script was invoked with a relative path (bash topics/web/scripts/...).
SCRIPT_UNC="\\\\wsl.localhost\\${DISTRO_NAME}$(printf '%s' "$HERE" | sed 's|/|\\|g')\\import-mkcert-from-windows.ps1"

echo
info "ROBUST SOLUTION — Windows CA import (works even when WSL interop is dead):"
info "  Open Windows PowerShell (on Windows side) and run:"
info "    powershell -ExecutionPolicy Bypass -File '${SCRIPT_UNC}'"
info "  -ExecutionPolicy Bypass is scoped to THIS invocation only —"
info "  needed because PowerShell refuses unsigned scripts over UNC by default."
info "  The script uses 'wsl.exe cat' which bypasses binfmt/interop"
info "  entirely — it reaches the WSL VM through a different channel."
info "  Then fully quit Chrome/Edge and reopen before retrying https://*.localhost."
echo

if [[ -n "$FIRST_FAIL" ]]; then
    fail "Interop check '${FIRST_FAIL}' failed."
    echo
    info "Optional first-aid (fixes the interop itself, but recurrence is possible):"
fi

case "$FIRST_FAIL" in
    "")
        ok "All checks passed — interop looks healthy. If Windows browsers still"
        ok "reject *.localhost TLS, run the PowerShell command above (do not re-run"
        ok "setup just for the cert). To re-apply the web bundle from the clone:"
        ok "  bash setup.sh --bundle web/nginx-php-fpm"
        ;;
    "mnt-c-9p-broken"|"mnt-c-unavailable")
        fail "  /mnt/c 9P mount is broken in this WSL session."
        fail "  First-aid:  wsl --shutdown (from Windows), reopen WSL."
        fail "  Persistent? Could be: Hyper-V dyn-mem ballooning, AppArmor"
        fail "  profile conflict on 24.04, Windows 9P server crash — all reset"
        fail "  on wsl --shutdown but also recur. Use the robust solution above."
        ;;
    "binfmt-missing"|"binfmt-disabled")
        fail "  binfmt_misc WSLInterop not registered — .exe calls from WSL fail."
        fail "  First-aid:  wsl --shutdown (from Windows), reopen WSL."
        fail "  If systemd enabled, verify systemd-binfmt.service is active:"
        fail "    systemctl --no-pager status systemd-binfmt.service"
        fail "  Ensure /etc/wsl.conf [interop] enabled = true (default)."
        ;;
    "interop-socket-missing")
        fail "  WSL_INTEROP socket missing — /init didn't create /run/WSL/<pid>_interop."
        fail "  First-aid:  wsl --shutdown, reopen WSL."
        ;;
    "wsl-conf-interop-false")
        fail "  /etc/wsl.conf explicitly disables interop."
        fail "  Remove the 'enabled = false' line under [interop], then wsl --shutdown."
        ;;
    "pwsh-found-but-cannot-run")
        fail "  powershell.exe is on disk but fails to execute — binfmt/interop broken."
        fail "  First-aid:  wsl --shutdown, reopen WSL."
        ;;
    "pwsh-not-found")
        fail "  PATH doesn't include Windows System32 AND /mnt/c abs paths don't work."
        fail "  Check:  cat /etc/wsl.conf   (appendWindowsPath = false?)"
        fail "  First-aid:  wsl --shutdown, reopen WSL."
        ;;
esac

# Exit non-zero when anything failed, so callers (CI, etc.) can detect it.
[[ -z "$FIRST_FAIL" ]] && exit 0 || exit 1
