#!/usr/bin/env bash
# tests/integration/yazi-install.test.sh — Yazi WSL installer, no live network.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
mkdir -p "$HOME/.local/bin" "$SANDBOX/releases"

# Fake curl: last -o dest is the output file; copy the fixture zip.
mkdir -p "$SANDBOX/bin"
cat > "$SANDBOX/bin/curl" <<'EOF'
#!/usr/bin/env bash
dest=""
while (( $# )); do
  case "$1" in
    -o) shift; dest="$1" ;;
    *) ;;
  esac
  shift
done
[[ -n "$dest" ]] || exit 1
cp "${YAZI_FIXTURE_ZIP:?}" "$dest"
EOF
chmod +x "$SANDBOX/bin/curl"

# Minimal zip: yazi + ya at archive root (installer also accepts named-dir).
mkdir -p "$SANDBOX/payload"
printf '#!/bin/sh\necho yazi-fake\n' > "$SANDBOX/payload/yazi"
printf '#!/bin/sh\necho ya-fake\n' > "$SANDBOX/payload/ya"
chmod +x "$SANDBOX/payload/yazi" "$SANDBOX/payload/ya"
python3 - "$SANDBOX/payload" "$SANDBOX/releases/yazi.zip" <<'PY'
import os, sys, zipfile
root, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, "w") as zf:
    for name in ("yazi", "ya"):
        zf.write(os.path.join(root, name), name)
PY
export YAZI_FIXTURE_ZIP="$SANDBOX/releases/yazi.zip"

mkdir -p "$SANDBOX/ws/scripts/lib"
cat > "$SANDBOX/ws/scripts/lib/github-api.sh" <<'EOF'
gh_latest_tag() { printf 'v99.0.0\n'; }
EOF
export MESH_WORKSTATION_DIR="$SANDBOX/ws"
export PATH="$SANDBOX/bin:$HOME/.local/bin:$PATH"
export UNAME_M="${UNAME_M:-x86_64}"

INSTALL="$REPO_ROOT/topics/shell-terminal/wsl/install-yazi.sh"
assert_file_exists "$INSTALL" "install-yazi.sh exists"

# shellcheck source=/dev/null
source "$INSTALL"
install
assert_file_exists "$HOME/.local/bin/yazi" "yazi landed in ~/.local/bin"
assert_file_exists "$HOME/.local/bin/ya" "ya landed in ~/.local/bin"
assert_eq "$(yazi)" "yazi-fake" "yazi is executable from PATH"
if grep -vE '^\s*(#|$)' "$INSTALL" | grep -qw sudo; then
  fail "install-yazi.sh uses sudo — write to ~/.local/bin without sudo"
else
  pass "install-yazi.sh has no sudo"
fi
if grep -vE '^\s*(#|$)' "$INSTALL" | grep -q 'installers/github-release.sh'; then
  fail "install-yazi.sh uses generic github-release driver"
else
  pass "install-yazi.sh is a custom installer"
fi

# Named-directory layout (F0 evidence: yazi-<triple>/{yazi,ya}).
mkdir -p "$SANDBOX/named/yazi-x86_64-unknown-linux-gnu"
printf '#!/bin/sh\necho yazi-named\n' > "$SANDBOX/named/yazi-x86_64-unknown-linux-gnu/yazi"
printf '#!/bin/sh\necho ya-named\n' > "$SANDBOX/named/yazi-x86_64-unknown-linux-gnu/ya"
chmod +x "$SANDBOX/named/yazi-x86_64-unknown-linux-gnu/yazi" \
  "$SANDBOX/named/yazi-x86_64-unknown-linux-gnu/ya"
python3 - "$SANDBOX/named" "$SANDBOX/releases/named.zip" <<'PY'
import os, sys, zipfile
root, dest = sys.argv[1], sys.argv[2]
with zipfile.ZipFile(dest, "w") as zf:
    for dirpath, _, files in os.walk(root):
        for name in files:
            full = os.path.join(dirpath, name)
            zf.write(full, os.path.relpath(full, root))
PY
export YAZI_FIXTURE_ZIP="$SANDBOX/releases/named.zip"
rm -f "$HOME/.local/bin/yazi" "$HOME/.local/bin/ya"
install
assert_eq "$(yazi)" "yazi-named" "named-dir zip unpacks yazi"
assert_eq "$(ya)" "ya-named" "named-dir zip unpacks ya"

summary
