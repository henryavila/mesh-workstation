#!/usr/bin/env bash
# Fetch cloudflared by exact GitHub asset digest, without touching the live connector.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
INSTALLER="$ROOT/topics/remote-access/tuios/install-cloudflared.sh"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"
if [[ ! -f "$INSTALLER" ]]; then fail "cloudflared installer exists"; summary; fi

SANDBOX="$(mktemp -d -t mesh-tuios-cloudflared.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export TUIOS_CLOUDFLARED_BIN_DIR="$SANDBOX/bin"
export TUIOS_CLOUDFLARED_STATE_DIR="$SANDBOX/state"
export TUIOS_CLOUDFLARED_RELEASE_JSON="file://$SANDBOX/release.json"
export TUIOS_TEST_OS=Linux TUIOS_TEST_ARCH=x86_64
mkdir -p "$SANDBOX/assets"
cat > "$SANDBOX/assets/cloudflared-linux-amd64" <<'SH'
#!/bin/sh
printf '%s\n' 'cloudflared version 2026.9.3'
SH
chmod +x "$SANDBOX/assets/cloudflared-linux-amd64"
digest="$(sha256sum "$SANDBOX/assets/cloudflared-linux-amd64" | awk '{print $1}')"
jq -n --arg url "file://$SANDBOX/assets/cloudflared-linux-amd64" --arg digest "sha256:$digest" \
    '{tag_name:"2026.9.3",assets:[{name:"cloudflared-linux-amd64",browser_download_url:$url,digest:$digest}]}' > "$SANDBOX/release.json"

# shellcheck source=/dev/null
source "$INSTALLER"
if check; then fail "missing cloudflared fails check"; else pass "missing cloudflared fails check"; fi
if install && verify; then pass "installs digest-verified cloudflared"; else fail "installs digest-verified cloudflared"; fi
assert_eq "$("$TUIOS_CLOUDFLARED_BIN_DIR/cloudflared" --version)" 'cloudflared version 2026.9.3' "installed Linux release runs"

printf 'tamper\n' >> "$SANDBOX/assets/cloudflared-linux-amd64"
rm -f "$TUIOS_CLOUDFLARED_BIN_DIR/cloudflared"
if install; then fail "tampered asset is rejected"; else pass "tampered asset is rejected"; fi
if [[ ! -e "$TUIOS_CLOUDFLARED_BIN_DIR/cloudflared" ]]; then pass "failed digest leaves install path absent"; else fail "failed digest leaves install path absent"; fi

cat > "$SANDBOX/assets/cloudflared" <<'SH'
#!/bin/sh
printf '%s\n' 'cloudflared version 2026.9.3'
SH
chmod +x "$SANDBOX/assets/cloudflared"
tar -czf "$SANDBOX/assets/cloudflared-darwin-arm64.tgz" -C "$SANDBOX/assets" cloudflared
digest="$(sha256sum "$SANDBOX/assets/cloudflared-darwin-arm64.tgz" | awk '{print $1}')"
jq -n --arg url "file://$SANDBOX/assets/cloudflared-darwin-arm64.tgz" --arg digest "sha256:$digest" \
    '{tag_name:"2026.9.3",assets:[{name:"cloudflared-darwin-arm64.tgz",browser_download_url:$url,digest:$digest}]}' > "$SANDBOX/release.json"
export TUIOS_TEST_OS=Darwin TUIOS_TEST_ARCH=arm64
export TUIOS_CLOUDFLARED_BIN_DIR="$SANDBOX/mac-bin"
export TUIOS_CLOUDFLARED_STATE_DIR="$SANDBOX/mac-state"
if install && verify; then pass "installs digest-verified Mac archive"; else fail "installs digest-verified Mac archive"; fi
assert_eq "$("$TUIOS_CLOUDFLARED_BIN_DIR/cloudflared" --version)" 'cloudflared version 2026.9.3' "installed Mac asset runs"

export TUIOS_TEST_OS=Linux TUIOS_SERVICE_DRY_RUN=1
export TUIOS_SYSTEMD_DIR="$SANDBOX/public-units"
mkdir -p "$TUIOS_SYSTEMD_DIR"
printf '# Managed by mesh-workstation: tuios-tunnel-testbox\n' > "$TUIOS_SYSTEMD_DIR/tuios-tunnel-testbox.service"
printf '# Managed by mesh-workstation: tuios-web-remote\n' > "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service"
if uninstall; then pass "cloudflared uninstall succeeds"; else fail "cloudflared uninstall succeeds"; fi
if [[ ! -e "$TUIOS_SYSTEMD_DIR/tuios-tunnel-testbox.service" && ! -e "$TUIOS_SYSTEMD_DIR/tuios-web-remote.service" ]]; then
    pass "uninstall stops Mesh-owned public services"
else
    fail "uninstall stops Mesh-owned public services"
fi

summary
