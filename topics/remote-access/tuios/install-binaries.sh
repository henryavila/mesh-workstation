#!/usr/bin/env bash
# Install tuios and tuios-web from one checked upstream release.
# Sourced by Mesh's custom-item driver; all paths are user-owned.

_tuios_bin_dir() { printf '%s' "${TUIOS_BIN_DIR:-$HOME/.local/bin}"; }
_tuios_root() { printf '%s' "${TUIOS_INSTALL_ROOT:-$HOME/.local/share/mesh/tuios}"; }

_tuios_version_of() {
    [[ -x "$1" ]] || return 1
    "$1" --version 2>/dev/null | awk '$2 == "version" {print $3; exit}'
}

check() {
    local dir cli web
    dir="$(_tuios_bin_dir)"
    cli="$(_tuios_version_of "$dir/tuios")" || return 1
    web="$(_tuios_version_of "$dir/tuios-web")" || return 1
    [[ -n "$cli" && "$cli" == "$web" ]]
}

verify() { check; }

_tuios_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf 'tuios: sha256sum or shasum is required\n' >&2
        return 1
    fi
}

_tuios_tag() {
    if [[ -n "${TUIOS_VERSION:-}" ]]; then
        printf '%s' "$TUIOS_VERSION"
        return 0
    fi
    local headers tag
    headers="$(curl -fsSI --connect-timeout 8 --max-time 30 \
        https://github.com/Gaurav-Gosain/tuios/releases/latest)" || return 1
    tag="$(printf '%s\n' "$headers" | awk 'tolower($0) ~ /^location:/ {print $2}' \
        | sed -nE 's|.*/tag/(v[0-9][0-9A-Za-z.-]*)|\1|p' | tr -d '\r' | tail -1)"
    [[ -n "$tag" ]] || { printf 'tuios: could not resolve latest release\n' >&2; return 1; }
    printf '%s' "$tag"
}

_tuios_platform() {
    local os arch
    os="${TUIOS_TEST_OS:-$(uname -s)}"
    arch="${TUIOS_TEST_ARCH:-$(uname -m)}"
    case "$os" in Linux|Darwin) ;; *) printf 'tuios: unsupported OS %s\n' "$os" >&2; return 1 ;; esac
    case "$arch" in x86_64|arm64) ;; aarch64) arch=arm64 ;; *) printf 'tuios: unsupported architecture %s\n' "$arch" >&2; return 1 ;; esac
    printf '%s %s\n' "$os" "$arch"
}

_tuios_replace_current() {
    local from="$1" dest="$2" os="$3"
    if [[ "$os" == Darwin ]]; then
        mv -fh "$from" "$dest"
    else
        mv -fT "$from" "$dest"
    fi
}

_tuios_install_tag() (
    set -euo pipefail
    local tag="$1" version os arch base root bin_dir stage binary asset want got count release temp_link dest backup prior
    [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || {
        printf 'tuios: invalid release tag %s\n' "$tag" >&2; return 1;
    }
    version="${tag#v}"
    read -r os arch <<< "$(_tuios_platform)"
    base="${TUIOS_RELEASE_BASE:-https://github.com/Gaurav-Gosain/tuios/releases/download}/$tag"
    root="$(_tuios_root)"
    bin_dir="$(_tuios_bin_dir)"
    mkdir -p "$root/releases" "$bin_dir"
    stage="$(mktemp -d "$root/.stage.XXXXXX")"
    trap 'rm -rf "$stage"' EXIT

    curl -fsSL --retry 2 --connect-timeout 8 --max-time 120 -o "$stage/checksums.txt" "$base/checksums.txt"
    for binary in tuios tuios-web; do
        asset="${binary}_${version}_${os}_${arch}.tar.gz"
        count="$(awk -v f="$asset" '$2 == f {n++} END {print n+0}' "$stage/checksums.txt")"
        [[ "$count" == 1 ]] || { printf 'tuios: missing/duplicate checksum for %s\n' "$asset" >&2; return 1; }
        want="$(awk -v f="$asset" '$2 == f {print $1}' "$stage/checksums.txt")"
        [[ "$want" =~ ^[0-9a-fA-F]{64}$ ]] || { printf 'tuios: invalid checksum for %s\n' "$asset" >&2; return 1; }
        curl -fsSL --retry 2 --connect-timeout 8 --max-time 120 -o "$stage/$asset" "$base/$asset"
        got="$(_tuios_sha256 "$stage/$asset")"
        [[ "$got" == "$(printf '%s' "$want" | tr 'A-F' 'a-f')" ]] || {
            printf 'tuios: checksum mismatch for %s\n' "$asset" >&2; return 1;
        }
        tar -xOzf "$stage/$asset" "$binary" > "$stage/$binary"
        chmod 0755 "$stage/$binary"
        [[ "$(_tuios_version_of "$stage/$binary")" == "$version" ]] || {
            printf 'tuios: binary version mismatch for %s\n' "$binary" >&2; return 1;
        }
    done

    release="$root/releases/$version"
    if [[ ! -e "$release" ]]; then
        mkdir "$stage/release"
        mv "$stage/tuios" "$stage/tuios-web" "$stage/release/"
        mv "$stage/release" "$release"
    else
        [[ -d "$release" && ! -L "$release" ]] || return 1
        for binary in tuios tuios-web; do
            [[ -f "$release/$binary" && ! -L "$release/$binary" && -x "$release/$binary" ]] || return 1
            if [[ "$(_tuios_sha256 "$release/$binary")" != "$(_tuios_sha256 "$stage/$binary")" ]]; then
                printf 'tuios: cached release differs from verified asset: %s\n' "$binary" >&2
                return 1
            fi
        done
    fi

    # Preserve pre-existing hand-installed binaries before adopting their paths.
    backup="$root/original"
    for binary in tuios tuios-web; do
        dest="$bin_dir/$binary"
        if [[ -L "$dest" && "$(readlink "$dest")" != "$root/current/$binary" ]]; then
            printf 'tuios: refusing to replace unmanaged symlink %s\n' "$dest" >&2
            return 1
        fi
        if [[ -d "$dest" ]]; then
            printf 'tuios: executable path is a directory: %s\n' "$dest" >&2
            return 1
        fi
        if [[ -e "$dest" && ! -L "$dest" ]]; then
            mkdir -p "$backup"
            if [[ ! -e "$backup/$binary" ]]; then cp -p "$dest" "$backup/$binary"; fi
        fi
    done

    prior=""
    if [[ -L "$root/current" ]]; then prior="$(readlink "$root/current")"; fi
    if [[ "$prior" != "releases/$version" ]]; then
        if [[ -n "$prior" ]]; then
            printf '%s\n' "$prior" > "$root/rollback-target"
        else
            rm -f "$root/rollback-target"
        fi
        temp_link="$root/.current.$$"
        ln -s "releases/$version" "$temp_link"
        _tuios_replace_current "$temp_link" "$root/current" "$os"
    fi
    for binary in tuios tuios-web; do
        dest="$bin_dir/$binary"
        if [[ ! -L "$dest" || "$(readlink "$dest")" != "$root/current/$binary" ]]; then
            temp_link="$bin_dir/.${binary}.new.$$"
            ln -s "$root/current/$binary" "$temp_link"
            mv -f "$temp_link" "$dest"
        fi
    done
    printf '%s\n' "$tag" > "$root/managed-release"
    verify
)

install() {
    local tag
    tag="$(_tuios_tag)" || return 1
    _tuios_install_tag "$tag" || return 1
    local roster helper
    roster="${MESH_TUIOS_PEERS:-${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/config/tuios-peers.json}"
    helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/hosts.sh"
    if [[ -r "$roster" && -f "$helper" ]]; then
        bash "$helper" sync || printf 'tuios: peer sync needs attention; run mesh tuios hosts doctor\n' >&2
    fi
}

repair() { install; }

update() {
    local tag version before
    tag="$(_tuios_tag)" || return 1
    version="${tag#v}"
    before="$(_tuios_version_of "$(_tuios_bin_dir)/tuios")" || before=""
    if check && [[ "$before" == "$version" ]]; then return 0; fi
    _tuios_install_tag "$tag" || return 1
    return 10
}

uninstall() {
    local root dir binary dest temp_file
    root="$(_tuios_root)"
    dir="$(_tuios_bin_dir)"
    [[ -f "$root/managed-release" ]] || return 0
    for binary in tuios tuios-web; do
        dest="$dir/$binary"
        if [[ -L "$dest" && "$(readlink "$dest")" == "$root/current/$binary" ]]; then
            if [[ -f "$root/original/$binary" && ! -L "$root/original/$binary" ]]; then
                temp_file="$dir/.${binary}.restore.$$"
                cp -p "$root/original/$binary" "$temp_file" || return 1
                mv -f "$temp_file" "$dest" || return 1
            else
                rm -f "$dest"
            fi
        fi
    done
    rm -f "$root/current" "$root/managed-release" "$root/rollback-target"
}

rollback() {
    local root prior os arch temp_link
    root="$(_tuios_root)"
    if [[ ! -f "$root/rollback-target" ]]; then uninstall; return; fi
    prior="$(cat "$root/rollback-target")"
    [[ "$prior" =~ ^releases/[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || return 1
    [[ -x "$root/$prior/tuios" && -x "$root/$prior/tuios-web" ]] || return 1
    read -r os arch <<< "$(_tuios_platform)"
    temp_link="$root/.rollback.$$"
    ln -s "$prior" "$temp_link" || return 1
    _tuios_replace_current "$temp_link" "$root/current" "$os" || return 1
    printf 'v%s\n' "${prior#releases/}" > "$root/managed-release"
    rm -f "$root/rollback-target"
    verify
}
