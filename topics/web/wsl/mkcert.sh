#!/usr/bin/env bash
_mkcert_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _mkcert_ws="${MESH_WORKSTATION_DIR}"
else
    _mkcert_ws="$(cd "$_mkcert_here/../../.." && pwd)"
fi
# shellcheck source=/dev/null
. "$_mkcert_ws/scripts/lib/github-api.sh"
# Custom: mkcert + wildcard cert + Windows trust store import.

CERT_DIR="${CERT_DIR:-/etc/nginx/certs}"
WILDCARD_PEM="$CERT_DIR/wildcard-localhost.pem"
WILDCARD_KEY="$CERT_DIR/wildcard-localhost-key.pem"
# Known install path + soft_fail marker: rollback removes only a binary we
# placed this run. Never auto-untrust system/NSS/Windows CAs.
MKCERT_BIN="${MKCERT_BIN:-/usr/local/bin/mkcert}"
MKCERT_BIN_MARKER="${XDG_STATE_HOME:-$HOME/.local/state}/mesh/mkcert-bin-installed"

check() {
    # `test -f` only needs stat() on the file path, which requires +x on
    # every parent dir but NOT read on the file itself. /etc/nginx/certs/
    # is created mode 0755 by `mkdir -p` (default umask), so the test
    # works as any user even though wildcard-localhost-key.pem is mode
    # 0640 root:root. Keeping check() sudo-free lets the menu scanner
    # probe state with zero password friction.
    command -v mkcert >/dev/null 2>&1 || return 1
    test -f "$WILDCARD_PEM" || return 1
    test -f "$WILDCARD_KEY" || return 1
    # Content sentinel: the rootCA that `mkcert -install` creates and that
    # signed the wildcard above MUST exist, else the certs are present but
    # untrusted (NSS/Windows browsers reject *.localhost) — a half-installed
    # state the bare file-existence checks above would falsely KEEP. CAROOT
    # is a per-user dir (~/.local/share/mkcert), so this stays sudo-free.
    # Guard against an empty CAROOT (mkcert error) collapsing to /rootCA.pem.
    local caroot
    caroot="$(mkcert -CAROOT 2>/dev/null)" || return 1
    [[ -n "$caroot" ]] || return 1
    test -f "$caroot/rootCA.pem" || return 1
    return 0
}

install() {
    sudo -n -v >/dev/null 2>&1 || true
    export DEBIAN_FRONTEND=noninteractive

    # Install mkcert binary if missing.
    if ! command -v mkcert >/dev/null 2>&1; then
        sudo apt-get install -y -q libnss3-tools
        local ver tmp
        ver="$(gh_latest_tag FiloSottile/mkcert)"
        tmp="$(mktemp -d)"
        if ! curl -fsSL --connect-timeout 8 --max-time 45 -o "$tmp/mkcert" \
            "https://github.com/FiloSottile/mkcert/releases/download/${ver}/mkcert-${ver}-linux-amd64"; then
            echo "[mkcert] download failed (curl non-zero)" >&2
            rm -rf "$tmp"
            return 1
        fi
        # shellcheck disable=SC2033  # coreutils install, not the engine install() fn
        sudo install -m 0755 "$tmp/mkcert" "$MKCERT_BIN"
        mkdir -p "$(dirname "$MKCERT_BIN_MARKER")"
        : > "$MKCERT_BIN_MARKER"
        rm -rf "$tmp"
    fi

    # Snapshot whether a trusted CA already exists BEFORE (re)installing. If it
    # is missing, any wildcard PEMs on disk were signed by a now-lost CA and are
    # orphaned — browsers reject them — so they must be regenerated against the
    # CA that `mkcert -install` (re)creates below, not left in place. verify()
    # rejects a missing rootCA, so a repair that skipped this would loop the
    # engine to "still broken after repair".
    local _caroot_before rootca_existed=0
    _caroot_before="$(mkcert -CAROOT 2>/dev/null)"
    [[ -n "$_caroot_before" && -f "$_caroot_before/rootCA.pem" ]] && rootca_existed=1

    # Install rootCA into WSL trust stores. The NSS/Firefox trust step may need a
    # TTY (best-effort), but CREATING the CA files in CAROOT does not — so after
    # this we hard-assert rootCA.pem exists. That converts a silently-unfixable
    # smoke-screen (verify keeps failing on a missing rootCA while repair returns
    # 0) into a loud, actionable failure.
    mkcert -install \
        || echo "[mkcert] mkcert -install had issues — Firefox profile may need a TTY" >&2

    local _caroot
    _caroot="$(mkcert -CAROOT 2>/dev/null)"
    if [[ -z "$_caroot" || ! -f "$_caroot/rootCA.pem" ]]; then
        echo "[mkcert] rootCA.pem missing after 'mkcert -install' (CAROOT='$_caroot') — CAROOT unwritable or mkcert broken; cannot establish a trust root" >&2
        return 1
    fi

    # Generate wildcard cert if missing OR orphaned (CA was just recreated, so
    # any pre-existing PEMs no longer chain to the trusted root).
    # This block is load-bearing for verify()=check() (asserts both PEMs
    # exist). Guard each step and return 1 on real failure so the engine
    # reports a clean 'mkcert install failed' instead of a confusing rc67
    # post-verify abort that masks the real cause.
    sudo mkdir -p "$CERT_DIR"
    if [[ "$rootca_existed" -eq 0 ]] || ! sudo test -f "$WILDCARD_PEM" || ! sudo test -f "$WILDCARD_KEY"; then
        local tmp
        tmp="$(mktemp -d)"
        if ! ( cd "$tmp" && mkcert \
            -cert-file "wildcard-localhost.pem" \
            -key-file  "wildcard-localhost-key.pem" \
            "*.localhost" "localhost" "*.front.localhost" "127.0.0.1" "::1" ); then
            echo "[mkcert] wildcard cert generation failed" >&2
            rm -rf "$tmp"
            return 1
        fi
        # shellcheck disable=SC2033  # coreutils install, not the engine install() fn
        if ! sudo install -m 0644 -o root -g root "$tmp/wildcard-localhost.pem"     "$WILDCARD_PEM" \
           || ! sudo install -m 0640 -o root -g root "$tmp/wildcard-localhost-key.pem" "$WILDCARD_KEY"; then
            echo "[mkcert] failed to install wildcard cert into $CERT_DIR" >&2
            rm -rf "$tmp"
            return 1
        fi
        rm -rf "$tmp"
    fi

    # Windows trust import — best-effort with Lane B fallback noted on failure.
    local rootca pwsh here scripts_dir lane_b
    rootca="$(mkcert -CAROOT)/rootCA.pem"
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    scripts_dir="$(cd "$here/../scripts" && pwd)"
    # shellcheck source=/dev/null
    . "$scripts_dir/mkcert-windows-unc.sh"
    lane_b="$(mesh_mkcert_from_windows_ps_cmd "$scripts_dir")"
    pwsh=""
    for cand in powershell.exe pwsh.exe \
                "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe" \
                "/mnt/c/Program Files/PowerShell/7/pwsh.exe"; do
        if command -v "$cand" >/dev/null 2>&1 || [[ -x "$cand" ]]; then
            pwsh="$cand"; break
        fi
    done

    if [[ ! -f "$rootca" ]]; then
        echo "[mkcert] rootCA missing at $rootca — Windows browsers will distrust *.localhost" >&2
        echo "[mkcert] retry: rerun this topic after 'mkcert -CAROOT' shows a directory" >&2
        echo "[mkcert] after rootCA exists, on Windows: $lane_b" >&2
    elif [[ -n "$pwsh" ]]; then
        local ps_src win_tmp_win win_tmp_unix stamp rootca_win ps_win
        ps_src="$scripts_dir/import-mkcert-windows.ps1"
        # Copy CA + importer onto a native Windows path. powershell.exe spawned
        # from WSL deadlocks if it then reads `\\wsl.localhost\...` (9P reentry).
        win_tmp_win="$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')"
        if [[ -n "$win_tmp_win" ]] && win_tmp_unix="$(wslpath -u "$win_tmp_win" 2>/dev/null)" \
            && [[ -d "$win_tmp_unix" && -f "$ps_src" ]]; then
            stamp="mesh-mkcert-$$"
            cp "$rootca" "$win_tmp_unix/${stamp}-rootCA.pem"
            cp "$ps_src" "$win_tmp_unix/${stamp}-import.ps1"
            rootca_win="${win_tmp_win}\\${stamp}-rootCA.pem"
            ps_win="${win_tmp_win}\\${stamp}-import.ps1"
            # Wrap in `timeout 45` — Root CA import can still raise a Windows
            # confirmation dialog that nobody will click from this side.
            # shellcheck disable=SC2016
            timeout --kill-after=5 45 \
                "$pwsh" -NoProfile -ExecutionPolicy Bypass -Command \
                "\$env:ROOTCA_PATH = '$rootca_win'; & '$ps_win'" 2>&1 \
                | sed 's/^/    /' \
                || {
                    echo "[mkcert] interop import failed (or hit 45s timeout) — on Windows: $lane_b" >&2
                    if declare -F followup >/dev/null 2>&1; then
                        followup manual "Windows does not yet trust *.localhost HTTPS. In Windows PowerShell (click Yes on the security dialog): $lane_b"
                    fi
                }
            rm -f "$win_tmp_unix/${stamp}-rootCA.pem" "$win_tmp_unix/${stamp}-import.ps1"
        else
            echo "[mkcert] could not stage CA on Windows TEMP — on Windows: $lane_b" >&2
        fi
    else
        echo "[mkcert] powershell.exe unreachable — on Windows: $lane_b" >&2
        if declare -F followup >/dev/null 2>&1; then
            followup manual "Windows does not yet trust *.localhost HTTPS. In Windows PowerShell (click Yes on the security dialog): $lane_b"
        fi
    fi

    # Successful full install — drop the soft_fail binary marker so a later
    # unrelated rollback does not remove a completed mkcert.
    rm -f "$MKCERT_BIN_MARKER"
}

verify() {
    # Fail closed: check() requires binary + wildcard PEMs + rootCA.pem.
    # Partial trust (binary only / missing CAROOT) must not write an install marker.
    check
}

repair() { install; }

rollback() {
    # Best-effort: remove a binary we placed this run. Do not untrust CAs.
    if [[ -f "$MKCERT_BIN_MARKER" ]]; then
        [[ -e "$MKCERT_BIN" ]] && sudo rm -f "$MKCERT_BIN"
        rm -f "$MKCERT_BIN_MARKER"
    fi
}
