#!/usr/bin/env bash
# Install both TUIOS release assets from one verified tag into an isolated HOME.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
INSTALLER="$ROOT/topics/remote-access/tuios/install-binaries.sh"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"

if [[ ! -f "$INSTALLER" ]]; then
    fail "paired TUIOS installer exists"
    summary
fi

SANDBOX="$(mktemp -d -t mesh-tuios-binaries.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export TUIOS_BIN_DIR="$SANDBOX/home/.local/bin"
export TUIOS_INSTALL_ROOT="$SANDBOX/home/.local/share/mesh/tuios"
export TUIOS_RELEASE_BASE="file://$SANDBOX/releases"
mkdir -p "$SANDBOX/home" "$SANDBOX/releases"

hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}

make_release() {
    local version="$1" os="$2" arch="$3" dir bin asset
    dir="$SANDBOX/releases/v$version"
    mkdir -p "$dir" "$SANDBOX/build"
    : > "$dir/checksums.txt"
    for bin in tuios tuios-web; do
        cat > "$SANDBOX/build/$bin" <<EOF
#!/bin/sh
printf '%s\\n' '$bin version $version'
EOF
        chmod +x "$SANDBOX/build/$bin"
        asset="${bin}_${version}_${os}_${arch}.tar.gz"
        tar -czf "$dir/$asset" -C "$SANDBOX/build" "$bin"
        printf '%s  %s\n' "$(hash_file "$dir/$asset")" "$asset" >> "$dir/checksums.txt"
    done
}

make_release 1.2.3 Linux x86_64
make_release 1.2.4 Linux x86_64

export TUIOS_TEST_OS=Linux TUIOS_TEST_ARCH=x86_64 TUIOS_VERSION=v1.2.3
# shellcheck source=/dev/null
source "$INSTALLER"

if rg -q '\$\{[^}]*,,' "$INSTALLER"; then
    fail "installer avoids Bash 4 case conversion (macOS Bash 3.2)"
else
    pass "installer avoids Bash 4 case conversion (macOS Bash 3.2)"
fi

if check; then fail "missing pair fails check"; else pass "missing pair fails check"; fi
if install && verify; then pass "installs a matching verified pair"; else fail "installs a matching verified pair"; fi
assert_eq "$("$TUIOS_BIN_DIR/tuios" --version 2>/dev/null)" "tuios version 1.2.3" "CLI has release version"
assert_eq "$("$TUIOS_BIN_DIR/tuios-web" --version 2>/dev/null)" "tuios-web version 1.2.3" "web binary has same release version"

export TUIOS_VERSION=v1.2.4
update_rc=0
update || update_rc=$?
assert_eq "$update_rc" "10" "new release signals engine change"
assert_eq "$("$TUIOS_BIN_DIR/tuios" --version 2>/dev/null)" "tuios version 1.2.4" "CLI switched to new release"
assert_eq "$("$TUIOS_BIN_DIR/tuios-web" --version 2>/dev/null)" "tuios-web version 1.2.4" "web switched to new release"

update_rc=0
update || update_rc=$?
assert_eq "$update_rc" "0" "same release does not trigger restart"

make_release 1.2.5 Linux x86_64
mkdir -p "$TUIOS_INSTALL_ROOT/releases/1.2.5"
for bin in tuios tuios-web; do
    cat > "$TUIOS_INSTALL_ROOT/releases/1.2.5/$bin" <<EOF
#!/bin/sh
printf '%s\\n' '$bin version 9.9.9'
EOF
    chmod +x "$TUIOS_INSTALL_ROOT/releases/1.2.5/$bin"
done
export TUIOS_VERSION=v1.2.5
update_rc=0
update || update_rc=$?
assert_ne "$update_rc" "0" "rejects a stale cached release with the wrong version"
assert_eq "$("$TUIOS_BIN_DIR/tuios" --version 2>/dev/null)" "tuios version 1.2.4" "failed cached release preserves prior CLI"
assert_eq "$("$TUIOS_BIN_DIR/tuios-web" --version 2>/dev/null)" "tuios-web version 1.2.4" "failed cached release preserves prior web"

make_release 1.2.6 Linux x86_64
printf 'tamper\n' >> "$SANDBOX/releases/v1.2.6/tuios-web_1.2.6_Linux_x86_64.tar.gz"
export TUIOS_VERSION=v1.2.6
update_rc=0
update || update_rc=$?
assert_ne "$update_rc" "0" "rejects asset whose checksum differs"
assert_eq "$("$TUIOS_BIN_DIR/tuios" --version 2>/dev/null)" "tuios version 1.2.4" "checksum failure preserves prior pair"

make_release 1.2.7 Linux x86_64
cat > "$SANDBOX/external-tuios" <<'EOF'
#!/bin/sh
printf '%s\n' 'tuios version 0.0.0'
EOF
chmod +x "$SANDBOX/external-tuios"
rm "$TUIOS_BIN_DIR/tuios"
ln -s "$SANDBOX/external-tuios" "$TUIOS_BIN_DIR/tuios"
export TUIOS_VERSION=v1.2.7
update_rc=0
update || update_rc=$?
assert_eq "$update_rc" "1" "does not take over an unmanaged executable symlink"
assert_eq "$(readlink "$TUIOS_BIN_DIR/tuios")" "$SANDBOX/external-tuios" "foreign symlink remains untouched"
assert_eq "$("$TUIOS_BIN_DIR/tuios-web" --version 2>/dev/null)" "tuios-web version 1.2.4" "other binary remains on prior release"

export TUIOS_BIN_DIR="$SANDBOX/adopt-home/.local/bin"
export TUIOS_INSTALL_ROOT="$SANDBOX/adopt-home/.local/share/mesh/tuios"
mkdir -p "$TUIOS_BIN_DIR"
for bin in tuios tuios-web; do
    cat > "$TUIOS_BIN_DIR/$bin" <<EOF
#!/bin/sh
printf '%s\\n' '$bin version 0.9.9'
EOF
    chmod +x "$TUIOS_BIN_DIR/$bin"
done
export TUIOS_VERSION=v1.2.3
if install; then pass "adopts hand-installed regular files with backup"; else fail "adopts hand-installed regular files with backup"; fi
rollback
assert_eq "$("$TUIOS_BIN_DIR/tuios" --version 2>/dev/null)" "tuios version 0.9.9" "rollback restores prior CLI"
assert_eq "$("$TUIOS_BIN_DIR/tuios-web" --version 2>/dev/null)" "tuios-web version 0.9.9" "rollback restores prior web binary"

make_release 3.0.0 Darwin arm64
export TUIOS_BIN_DIR="$SANDBOX/darwin-home/.local/bin"
export TUIOS_INSTALL_ROOT="$SANDBOX/darwin-home/.local/share/mesh/tuios"
export TUIOS_TEST_OS=Darwin TUIOS_TEST_ARCH=arm64 TUIOS_VERSION=v3.0.0
if [[ "$(uname -s)" == Linux ]]; then
    mkdir -p "$SANDBOX/mac-mv-shim"
    cat > "$SANDBOX/mac-mv-shim/mv" <<'EOF'
#!/bin/sh
if [ "$1" = -fh ]; then shift; exec /usr/bin/mv -fT "$@"; fi
exec /usr/bin/mv "$@"
EOF
    chmod +x "$SANDBOX/mac-mv-shim/mv"
    export PATH="$SANDBOX/mac-mv-shim:$PATH"
fi
if install && verify; then pass "Darwin arm64 selects the paired Mac release assets"; else fail "Darwin arm64 selects the paired Mac release assets"; fi
assert_eq "$("$TUIOS_BIN_DIR/tuios-web" --version 2>/dev/null)" "tuios-web version 3.0.0" "Mac web binary has matching version"

export PATH="${PATH#"$SANDBOX/mac-mv-shim:"}"
export TUIOS_BIN_DIR="$SANDBOX/managed-home/.local/bin"
export TUIOS_INSTALL_ROOT="$SANDBOX/managed-home/.local/share/mesh/tuios"
export TUIOS_TEST_OS=Linux TUIOS_TEST_ARCH=x86_64 TUIOS_VERSION=v1.2.3
if install; then pass "install for managed rollback fixture"; else fail "install for managed rollback fixture"; fi
export TUIOS_VERSION=v1.2.4
update_rc=0
update || update_rc=$?
assert_eq "$update_rc" "10" "managed fixture advances to newer release"
rollback
assert_eq "$("$TUIOS_BIN_DIR/tuios" --version 2>/dev/null)" "tuios version 1.2.3" "rollback returns CLI to prior managed release"
assert_eq "$("$TUIOS_BIN_DIR/tuios-web" --version 2>/dev/null)" "tuios-web version 1.2.3" "rollback returns web to prior managed release"

summary
