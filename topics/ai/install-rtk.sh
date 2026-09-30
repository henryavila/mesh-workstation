#!/usr/bin/env bash
_rtk_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _rtk_ws="${MESH_WORKSTATION_DIR}"
else
    _rtk_ws="$(cd "$_rtk_here/../.." && pwd)"
fi
# shellcheck source=/dev/null
. "$_rtk_ws/scripts/lib/github-api.sh"
# Custom installer for rtk (Rust Token Killer).
# Engine sources this file inside a subshell and calls install(), check(),
# verify(), rollback() via the custom driver contract.
#
# CP4 A3-F-007: replaces `curl raw.githubusercontent.com/.../master/install.sh
# | sh` with an in-process release-based fetch that:
#   - resolves the latest tag via /releases/latest 302 redirect (no API rate
#     limit; falls back to API on parse failure; env RTK_VERSION overrides)
#   - downloads checksums.txt + the platform tarball from the immutable
#     release URL (release artifacts cannot be edited after publish — only
#     a new version can be pushed)
#   - verifies the tarball sha256 against checksums.txt before extracting
#   - rejects archives containing absolute paths or `..` (CWE-22 guard)
#   - extracts to a tmp dir, then atomically mv-fs into $RTK_INSTALL_DIR/rtk
#
# CP4 A3-F-009: install() records the canonical install path + binary
# sha256 + release tag in $RTK_STATE_FILE; rollback() refuses to delete a
# binary whose hash no longer matches the recorded one (likely another
# vendor's `rtk` — reachingforthejack/rtk Rust Type Kit, or a user-replaced
# binary).

readonly RTK_REPO="rtk-ai/rtk"
readonly RTK_INSTALL_DIR="${RTK_INSTALL_DIR:-$HOME/.local/bin}"
readonly RTK_BINARY="${RTK_INSTALL_DIR}/rtk"
readonly RTK_STATE_FILE="${XDG_STATE_HOME:-$HOME/.local/state}/mesh/rtk-installed.env"

check() {
    # Collision guard: the real rtk responds to `rtk gain` (Rust Type Kit
    # does not). Re-checked after install via verify().
    # ~/.local/bin is not on the engine item-subshell PATH on a fresh
    # bootstrap, so fall back to the absolute binary (bun/claude do the same)
    # and run the guard against it to avoid a spurious rc67 whole-run abort.
    command -v rtk >/dev/null 2>&1 || [[ -x "$RTK_BINARY" ]] || return 1
    "$RTK_BINARY" gain >/dev/null 2>&1 || rtk gain >/dev/null 2>&1
}

verify() {
    check
}

_rtk_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf 'install-rtk: no sha256 tool available (sha256sum or shasum required)\n' >&2
        return 1
    fi
}

_rtk_latest_tag() {
    if [[ -n "${RTK_VERSION:-}" ]]; then
        printf '%s' "$RTK_VERSION"
        return 0
    fi
    local v
    # awk IGNORECASE is gawk-only; match case-insensitively for BSD awk too so
    # the no-rate-limit redirect path works on macOS (curl -sSI emits `Location:`).
    v="$(curl -fsSI --connect-timeout 8 --max-time 45 \
        "https://github.com/${RTK_REPO}/releases/latest" 2>/dev/null \
        | awk 'tolower($0) ~ /^location:/' \
        | sed -E 's|.*/tag/([^[:space:]]+).*|\1|' \
        | tr -d '\r')"
    if [[ -z "$v" ]]; then
        v="$(gh_api_curl "https://api.github.com/repos/${RTK_REPO}/releases/latest" 2>/dev/null \
            | sed -nE 's/.*"tag_name":[[:space:]]*"([^"]+)".*/\1/p' \
            | head -1)"
    fi
    [[ -n "$v" ]] || return 1
    printf '%s' "$v"
}

_rtk_target() {
    local os arch
    case "$(uname -s)" in
        Linux*)  os=linux ;;
        Darwin*) os=darwin ;;
        *) return 1 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64)  arch=x86_64 ;;
        arm64|aarch64) arch=aarch64 ;;
        *) return 1 ;;
    esac
    case "$os" in
        linux)
            if [[ "$arch" == "x86_64" ]]; then
                printf 'x86_64-unknown-linux-musl'
            else
                printf 'aarch64-unknown-linux-gnu'
            fi
            ;;
        darwin) printf '%s-apple-darwin' "$arch" ;;
    esac
}

install() {
    local tag target tarball_name checksums_url tarball_url
    local tmp archive sums expected actual binary_sha

    tag="$(_rtk_latest_tag)" || {
        printf 'install-rtk: failed to resolve rtk release tag\n' >&2
        return 1
    }
    target="$(_rtk_target)" || {
        printf 'install-rtk: unsupported platform: %s %s\n' "$(uname -s)" "$(uname -m)" >&2
        return 1
    }
    tarball_name="rtk-${target}.tar.gz"
    checksums_url="https://github.com/${RTK_REPO}/releases/download/${tag}/checksums.txt"
    tarball_url="https://github.com/${RTK_REPO}/releases/download/${tag}/${tarball_name}"

    tmp="$(mktemp -d -t rtk-install.XXXXXX)" || return 1
    archive="$tmp/$tarball_name"
    sums="$tmp/checksums.txt"

    if ! curl -fsSL --connect-timeout 8 --max-time 45 "$checksums_url" -o "$sums"; then
        printf 'install-rtk: failed to fetch checksums.txt for %s\n' "$tag" >&2
        rm -rf "$tmp"; return 1
    fi
    if ! curl -fsSL --connect-timeout 8 --max-time 45 "$tarball_url" -o "$archive"; then
        printf 'install-rtk: failed to fetch %s for %s\n' "$tarball_name" "$tag" >&2
        rm -rf "$tmp"; return 1
    fi

    # checksums.txt format: `<sha256>  <filename>` (sha256sum -b uses `*`).
    expected="$(awk -v f="$tarball_name" '
        $2 == f || $2 == "*"f { print $1; exit }
    ' "$sums")"
    if [[ -z "$expected" ]]; then
        printf 'install-rtk: %s not listed in checksums.txt for %s\n' "$tarball_name" "$tag" >&2
        rm -rf "$tmp"; return 1
    fi
    actual="$(_rtk_sha256 "$archive")" || { rm -rf "$tmp"; return 1; }
    if [[ "$expected" != "$actual" ]]; then
        printf 'install-rtk: sha256 mismatch for %s\n  expected: %s\n  got:      %s\n' \
            "$tarball_name" "$expected" "$actual" >&2
        rm -rf "$tmp"; return 1
    fi

    # CWE-22 guard: refuse archives with absolute paths or `..` components.
    if tar -tzf "$archive" | grep -qE '^/|(^|/)\.\.(/|$)'; then
        printf 'install-rtk: archive contains unsafe paths — refusing to extract\n' >&2
        rm -rf "$tmp"; return 1
    fi

    tar -xzf "$archive" -C "$tmp"
    if [[ ! -f "$tmp/rtk" ]]; then
        printf 'install-rtk: rtk binary not found in archive\n' >&2
        rm -rf "$tmp"; return 1
    fi

    mkdir -p "$RTK_INSTALL_DIR" "$(dirname "$RTK_STATE_FILE")"
    chmod 0755 "$tmp/rtk"
    mv -f "$tmp/rtk" "$RTK_BINARY"

    binary_sha="$(_rtk_sha256 "$RTK_BINARY")" || { rm -rf "$tmp"; return 1; }

    {
        printf 'RTK_PATH=%s\n'   "$RTK_BINARY"
        printf 'RTK_SHA256=%s\n' "$binary_sha"
        printf 'RTK_TAG=%s\n'    "$tag"
        printf 'RTK_INSTALLED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$RTK_STATE_FILE"
    chmod 0644 "$RTK_STATE_FILE"

    rm -rf "$tmp"

    PATH="$RTK_INSTALL_DIR:$PATH"
    export PATH
}

# Version-aware update (engine --update + `mesh upgrade`): rtk ships as GitHub
# releases, so compare the latest published tag against the one recorded in the
# state file and only re-run install() (download + checksum + swap) when they
# differ. install() always fetches latest, so this guard is what makes the
# autoupdate path cheap when already current.
update() {
    local latest current=""
    latest="$(_rtk_latest_tag)" || {
        printf 'install-rtk: update — could not resolve latest rtk tag\n' >&2
        return 1
    }
    if [[ -r "$RTK_STATE_FILE" ]]; then
        current="$(sed -nE 's/^RTK_TAG=(.*)$/\1/p' "$RTK_STATE_FILE" | head -1)"
    fi
    if [[ -n "$current" && "$current" == "$latest" ]]; then
        printf 'install-rtk: rtk already latest (%s)\n' "$current" >&2
        return 0
    fi
    printf 'install-rtk: updating rtk %s -> %s\n' "${current:-none}" "$latest" >&2
    install
}

repair() { install; }

rollback() {
    # A3-F-009: only delete the binary we installed, identified by both
    # recorded path AND sha256 match. Refuse if hash drifted (user may have
    # upgraded rtk via another mechanism, or replaced it with a different
    # vendor's `rtk` like reachingforthejack/rtk).
    if [[ ! -f "$RTK_STATE_FILE" ]]; then
        # No install metadata — nothing we wrote, nothing to remove.
        return 0
    fi
    local recorded_path="" recorded_sha="" current_sha
    # shellcheck disable=SC1090
    . "$RTK_STATE_FILE" 2>/dev/null || return 0
    recorded_path="${RTK_PATH:-}"
    recorded_sha="${RTK_SHA256:-}"
    if [[ -z "$recorded_path" || ! -f "$recorded_path" ]]; then
        rm -f "$RTK_STATE_FILE"
        return 0
    fi
    current_sha="$(_rtk_sha256 "$recorded_path" 2>/dev/null)" || return 1
    if [[ -z "$recorded_sha" || "$current_sha" != "$recorded_sha" ]]; then
        printf 'install-rtk: refusing to delete %s — sha256 differs from recorded install (likely another vendor or external upgrade)\n' \
            "$recorded_path" >&2
        return 1
    fi
    rm -f "$recorded_path" "$RTK_STATE_FILE"
}

uninstall() {
    # Bundle deselection / `mesh uninstall`: same removal as rollback (binary +
    # state file), keeping the sha256 guard so we never delete a different
    # vendor's `rtk` or an externally-upgraded binary.
    rollback
}
