#!/usr/bin/env bash
# Install the cloudflared connector from an official release asset + API digest.

_tuios_cf_bin_dir() { printf '%s' "${TUIOS_CLOUDFLARED_BIN_DIR:-$HOME/.local/bin}"; }
_tuios_cf_state_dir() { printf '%s' "${TUIOS_CLOUDFLARED_STATE_DIR:-$HOME/.local/state/mesh/tuios-cloudflared}"; }

_tuios_cf_version() {
    [[ -x "$1" ]] || return 1
    "$1" --version 2>/dev/null | awk '$2 == "version" {print $3; exit}'
}

check() {
    local version
    version="$(_tuios_cf_version "$(_tuios_cf_bin_dir)/cloudflared")" || return 1
    [[ -n "$version" ]]
}

verify() { check; }

_tuios_cf_asset() {
    local os arch
    os="${TUIOS_TEST_OS:-$(uname -s)}"
    arch="${TUIOS_TEST_ARCH:-$(uname -m)}"
    case "$arch" in x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;; *) return 1 ;; esac
    case "$os" in
        Linux) printf 'cloudflared-linux-%s' "$arch" ;;
        Darwin) printf 'cloudflared-darwin-%s.tgz' "$arch" ;;
        *) return 1 ;;
    esac
}

_tuios_cf_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf 'cloudflared: sha256 tool missing\n' >&2
        return 1
    fi
}

install() (
    set -euo pipefail
    local dir state stage asset count url digest want got version dest temp_file
    dir="$(_tuios_cf_bin_dir)"
    state="$(_tuios_cf_state_dir)"
    asset="$(_tuios_cf_asset)" || { printf 'cloudflared: unsupported platform\n' >&2; return 1; }
    mkdir -p "$dir" "$state"
    stage="$(mktemp -d "${TMPDIR:-/tmp}/mesh-cloudflared.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT
    curl -fsSL --retry 2 --connect-timeout 8 --max-time 60 -o "$stage/release.json" \
        "${TUIOS_CLOUDFLARED_RELEASE_JSON:-https://api.github.com/repos/cloudflare/cloudflared/releases/latest}"
    count="$(jq --arg asset "$asset" '[.assets[] | select(.name == $asset)] | length' "$stage/release.json")"
    [[ "$count" == 1 ]] || { printf 'cloudflared: expected one release asset %s\n' "$asset" >&2; return 1; }
    version="$(jq -er '.tag_name' "$stage/release.json")"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    url="$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .browser_download_url' "$stage/release.json")"
    digest="$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest' "$stage/release.json")"
    [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]] || { printf 'cloudflared: no SHA-256 digest for %s\n' "$asset" >&2; return 1; }
    curl -fsSL --retry 2 --connect-timeout 8 --max-time 120 -o "$stage/$asset" "$url"
    got="$(_tuios_cf_sha256 "$stage/$asset")"
    want="${digest#sha256:}"
    [[ "$got" == "$(printf '%s' "$want" | tr 'A-F' 'a-f')" ]] || {
        printf 'cloudflared: SHA-256 mismatch for %s\n' "$asset" >&2; return 1;
    }
    if [[ "$asset" == *.tgz ]]; then
        tar -xOzf "$stage/$asset" cloudflared > "$stage/cloudflared"
    else
        cp "$stage/$asset" "$stage/cloudflared"
    fi
    chmod 0755 "$stage/cloudflared"
    [[ "$(_tuios_cf_version "$stage/cloudflared")" == "$version" ]] || {
        printf 'cloudflared: binary version differs from release metadata\n' >&2; return 1;
    }

    dest="$dir/cloudflared"
    if [[ -L "$dest" ]]; then
        printf 'cloudflared: refusing to replace unmanaged symlink %s\n' "$dest" >&2
        return 1
    fi
    if [[ -e "$dest" && ! -f "$state/managed-sha256" && ! -e "$state/original" ]]; then
        cp -p "$dest" "$state/original"
    fi
    temp_file="$dir/.cloudflared.new.$$"
    cp "$stage/cloudflared" "$temp_file"
    chmod 0755 "$temp_file"
    mv -f "$temp_file" "$dest"
    _tuios_cf_sha256 "$dest" > "$state/managed-sha256"
    verify
)

repair() { install; }

uninstall() {
    local dir state dest expected current temp_file
    dir="$(_tuios_cf_bin_dir)"
    state="$(_tuios_cf_state_dir)"
    dest="$dir/cloudflared"
    [[ -f "$state/managed-sha256" ]] || return 0
    expected="$(cat "$state/managed-sha256")"
    current="$(_tuios_cf_sha256 "$dest")" || return 1
    [[ "$current" == "$expected" ]] || {
        printf 'cloudflared: installed binary changed outside Mesh; preserving it\n' >&2
        return 1
    }
    if [[ -f "$state/original" ]]; then
        temp_file="$dir/.cloudflared.restore.$$"
        cp -p "$state/original" "$temp_file" || return 1
        mv -f "$temp_file" "$dest" || return 1
    else
        rm -f "$dest"
    fi
    rm -f "$state/managed-sha256"
}

rollback() { uninstall; }
