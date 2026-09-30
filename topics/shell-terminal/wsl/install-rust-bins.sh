#!/usr/bin/env bash
_rust_bins_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _rust_bins_ws="${MESH_WORKSTATION_DIR}"
else
    _rust_bins_ws="$(cd "$_rust_bins_here/../../.." && pwd)"
fi
# shellcheck source=/dev/null
. "$_rust_bins_ws/scripts/lib/github-api.sh"
# dust + xh + procs — single-file Rust binaries not in apt 24.04.
# Installed to ~/.local/bin via GitHub release tarballs. Idempotent.
#
# Marked soft_fail in the manifest: a CDN stall must not abort bootstrap.
#
# Fail-fast (CRC hang root cause): nested gh_api retries × curl --retry ×
# three binaries looked like an endless "resolving/downloading dust tag"
# loop on corporate networks. One shot per binary, no curl retries, short
# API budget, and a circuit breaker that refuses a second attempt.

# Single attempt — no --retry / --retry-all-errors (those re-entered the
# resolve/download cycle under flaky proxies and burned the soft_fail budget).
_RB_CURL=(curl -fsSL --connect-timeout 8 --max-time 45)
# Cap GitHub API attempts for this installer (honoured by github-api.sh).
: "${MESH_GH_API_ATTEMPTS:=2}"
export MESH_GH_API_ATTEMPTS

_rb_log() { printf '[rust-bins-wsl] %s\n' "$*" >&2; }

# Per-source in-process counters (do not inherit a parent shell's leftovers).
_RB_TRIED_dust=0
_RB_TRIED_xh=0
_RB_TRIED_procs=0

# --- Cross-entry circuit breaker (option A) ---------------------------------
# custom_install runs `( . "$script"; install )`, so in-process `_RB_TRIED_*`
# reset on every engine entry. Persist a short-lived stamp under TMPDIR so a
# re-sourced install in the same bootstrap refuses a second download of the
# same binary. repair() clears stamps for an intentional doctor --fix retry.
# TTL default 120s (overridable via MESH_RUST_BINS_ATTEMPT_TTL).
_RB_ATTEMPT_TTL_SECS="${MESH_RUST_BINS_ATTEMPT_TTL:-120}"

_rb_attempt_stamp() {
    printf '%s/mesh-rust-bins-attempt.%s' "${TMPDIR:-/tmp}" "$1"
}

# Pending write marker: set immediately before installing the final binary,
# cleared on success. rollback() removes only still-pending bins so a soft_fail
# timeout mid-binary-2/3 cannot wipe siblings that already completed.
_rb_pending_stamp() {
    printf '%s/mesh-rust-bins-pending.%s' "${TMPDIR:-/tmp}" "$1"
}

_rb_stamp_mtime() {
    # WSL/Linux installer — GNU stat.
    stat -c %Y "$1" 2>/dev/null || echo 0
}

_rb_clear_attempt_stamps() {
    local b
    for b in dust xh procs; do
        rm -f "$(_rb_attempt_stamp "$b")"
    done
}

# Circuit breaker: each binary is attempted at most once per TTL window
# (cross re-source) and at most once per sourced shell (in-process).
_rb_guard() {
    local name="$1"
    local var="_RB_TRIED_${name}"
    local stamp now mtime age
    stamp="$(_rb_attempt_stamp "$name")"

    if [[ "${!var:-0}" -ge 1 ]]; then
        _rb_log "circuit breaker: ${name} already attempted — refusing loop"
        return 1
    fi

    if [[ -f "$stamp" ]]; then
        now="$(date +%s)"
        mtime="$(_rb_stamp_mtime "$stamp")"
        age=$((now - mtime))
        if [[ "$age" -ge 0 && "$age" -lt "$_RB_ATTEMPT_TTL_SECS" ]]; then
            _rb_log "circuit breaker: ${name} already attempted — refusing loop"
            printf -v "$var" '%s' 1
            return 1
        fi
    fi

    printf -v "$var" '%s' 1
    # Record attempt before any network I/O so a kill mid-download still
    # suppresses re-entry within the TTL.
    : > "$stamp"
    return 0
}

_rb_mark_pending() {
    : > "$(_rb_pending_stamp "$1")"
}

_rb_clear_pending() {
    rm -f "$(_rb_pending_stamp "$1")"
}

_install_dust() {
    _rb_guard dust || return 1
    local ver tmp
    _rb_log "resolving latest dust release tag"
    ver="$(gh_latest_tag bootandy/dust)"
    [[ -n "$ver" && "$ver" != "null" ]] || { _rb_log "dust: could not resolve tag"; return 1; }
    tmp="$(mktemp -d)"
    _rb_log "downloading dust ${ver} (one-shot)"
    if ! "${_RB_CURL[@]}" -o "$tmp/dust.tgz" \
        "https://github.com/bootandy/dust/releases/download/${ver}/dust-${ver}-x86_64-unknown-linux-gnu.tar.gz"
    then
        _rb_log "dust: download failed"
        rm -rf "$tmp"
        return 1
    fi
    tar -C "$tmp" -xzf "$tmp/dust.tgz" --strip-components=1 || { rm -rf "$tmp"; return 1; }
    _rb_mark_pending dust
    # `command install` — the script defines install(), which would shadow
    # /usr/bin/install and recurse into the mesh installer.
    if ! command install -m 0755 "$tmp/dust" "$HOME/.local/bin/dust"; then
        _rb_clear_pending dust
        rm -rf "$tmp"
        return 1
    fi
    _rb_clear_pending dust
    rm -rf "$tmp"
    [[ -x "$HOME/.local/bin/dust" ]]
}

_install_xh() {
    _rb_guard xh || return 1
    local ver tmp
    _rb_log "resolving latest xh release tag"
    ver="$(gh_latest_tag ducaale/xh)"
    [[ -n "$ver" && "$ver" != "null" ]] || { _rb_log "xh: could not resolve tag"; return 1; }
    tmp="$(mktemp -d)"
    _rb_log "downloading xh ${ver} (one-shot)"
    if ! "${_RB_CURL[@]}" -o "$tmp/xh.tgz" \
        "https://github.com/ducaale/xh/releases/download/${ver}/xh-${ver}-x86_64-unknown-linux-musl.tar.gz"
    then
        _rb_log "xh: download failed"
        rm -rf "$tmp"
        return 1
    fi
    tar -C "$tmp" -xzf "$tmp/xh.tgz" --strip-components=1 || { rm -rf "$tmp"; return 1; }
    _rb_mark_pending xh
    if ! command install -m 0755 "$tmp/xh" "$HOME/.local/bin/xh"; then
        _rb_clear_pending xh
        rm -rf "$tmp"
        return 1
    fi
    _rb_clear_pending xh
    rm -rf "$tmp"
    [[ -x "$HOME/.local/bin/xh" ]]
}

_install_procs() {
    _rb_guard procs || return 1
    local ver tmp
    _rb_log "resolving latest procs release tag"
    ver="$(gh_latest_tag dalance/procs)"
    [[ -n "$ver" && "$ver" != "null" ]] || { _rb_log "procs: could not resolve tag"; return 1; }
    tmp="$(mktemp -d)"
    _rb_log "downloading procs ${ver} (one-shot)"
    if ! "${_RB_CURL[@]}" -o "$tmp/procs.zip" \
        "https://github.com/dalance/procs/releases/download/${ver}/procs-${ver}-x86_64-linux.zip"
    then
        _rb_log "procs: download failed"
        rm -rf "$tmp"
        return 1
    fi
    unzip -q -o "$tmp/procs.zip" -d "$tmp" || { rm -rf "$tmp"; return 1; }
    _rb_mark_pending procs
    if ! command install -m 0755 "$tmp/procs" "$HOME/.local/bin/procs"; then
        _rb_clear_pending procs
        rm -rf "$tmp"
        return 1
    fi
    _rb_clear_pending procs
    rm -rf "$tmp"
    [[ -x "$HOME/.local/bin/procs" ]]
}

# Verify by absolute path: install targets ~/.local/bin, which is not on the
# engine item-subshell PATH on WSL, so a bare `command -v` would fail post-verify
# even after a correct install (mirrors rollback() below).
check() {
    ( command -v dust  >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/dust" ]] ) \
        && ( command -v xh    >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/xh" ]] ) \
        && ( command -v procs >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/procs" ]] )
}

install() {
    mkdir -p "$HOME/.local/bin"
    PATH="$HOME/.local/bin:$PATH"
    # One pass only. On first binary failure keep going once for the others so
    # a single CDN blip does not skip siblings — but each binary is guarded
    # against re-entry (circuit breaker). Never retry a failed binary here;
    # soft_fail on the item is the recovery path for the whole bootstrap.
    local _rc=0
    if ! command -v dust  >/dev/null 2>&1; then
        _install_dust  || { _rb_log "dust install failed — not retrying"; _rc=1; }
    fi
    if ! command -v xh    >/dev/null 2>&1; then
        _install_xh    || { _rb_log "xh install failed — not retrying"; _rc=1; }
    fi
    if ! command -v procs >/dev/null 2>&1; then
        _install_procs || { _rb_log "procs install failed — not retrying"; _rc=1; }
    fi
    return "$_rc"
}

verify() { check; }

repair() {
    # Fresh attempt window for doctor --fix / repair sweeps.
    _RB_TRIED_dust=0
    _RB_TRIED_xh=0
    _RB_TRIED_procs=0
    _rb_clear_attempt_stamps
    install
}

rollback() {
    # Selective: only remove binaries still marked pending (incomplete write).
    # Successfully installed siblings must survive aggregate soft_fail / timeout
    # mid-binary-2/3 — a full wipe destroyed partial success.
    local b stamp
    for b in dust xh procs; do
        stamp="$(_rb_pending_stamp "$b")"
        if [[ -f "$stamp" ]]; then
            rm -f "$HOME/.local/bin/$b" "$stamp"
        fi
    done
}
