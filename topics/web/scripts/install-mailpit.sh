#!/usr/bin/env bash
_mailpit_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
    _mailpit_ws="${MESH_WORKSTATION_DIR}"
else
    _mailpit_ws="$(cd "$_mailpit_here/../../.." && pwd)"
fi
# shellcheck source=/dev/null
. "$_mailpit_ws/scripts/lib/github-api.sh"
# install-mailpit.sh — local mail catcher for dev.
# Gated by INCLUDE_MAILPIT=1 (set via menu or env).
#
# Mailpit provides a fake SMTP server on :1025 and a web UI on :8025.
# Laravel config snippet for .env:
#   MAIL_MAILER=smtp
#   MAIL_HOST=127.0.0.1
#   MAIL_PORT=1025
#   MAIL_USERNAME=null
#   MAIL_PASSWORD=null
#   MAIL_ENCRYPTION=null
#
# Install strategy:
#   Linux/WSL: download official binary from GitHub release → /usr/local/bin.
#              systemd user service installed; user kicks it off with
#              `systemctl --user start mailpit` (requires wsl.conf
#              [boot] systemd=true).
#   macOS:     brew install mailpit; brew services start mailpit.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../../scripts/lib/launch-wrapper.sh"

OS=""
case "$(uname -s)" in
    Darwin) OS="mac" ;;
    Linux)  OS="$(grep -qi microsoft /proc/version 2>/dev/null && echo wsl || echo linux)" ;;
    *)      fail "unsupported OS"; exit 1 ;;
esac

if command -v mailpit >/dev/null 2>&1; then
    ok "mailpit already installed ($(mailpit version 2>/dev/null | head -1 || echo '?'))"
else
    case "$OS" in
        mac)
            : "${BREW_BIN:?BREW_BIN not set}"
            info "brew install mailpit"
            "$BREW_BIN" install mailpit
            ;;
        wsl|linux)
            info "downloading mailpit from GitHub releases"
            mp_ver="$(gh_latest_tag axllent/mailpit)"
            tmp="$(mktemp -d)"
            arch="amd64"
            [[ "$(uname -m)" == "aarch64" ]] && arch="arm64"
            url="https://github.com/axllent/mailpit/releases/download/${mp_ver}/mailpit-linux-${arch}.tar.gz"
            curl -fsSL --connect-timeout 8 --max-time 45 -o "$tmp/mp.tgz" "$url"
            tar -xzf "$tmp/mp.tgz" -C "$tmp" mailpit
            sudo install -m 0755 "$tmp/mailpit" /usr/local/bin/mailpit
            rm -rf "$tmp"
            ;;
    esac
    ok "mailpit installed"
fi

# ─── Service / launch wiring ─────────────────────────────────────────
case "$OS" in
    mac)
        # Decide between brew services (canonical prefix) and launch-wrapper
        # (custom prefix; user-scope LaunchAgents in /Volumes/* hit TCC exit 78).
        : "${BREW_PREFIX:?BREW_PREFIX not set}"
        case "$BREW_PREFIX" in
            /opt/homebrew|/usr/local) mp_use_wrapper=0 ;;
            *)                        mp_use_wrapper=1 ;;
        esac
        if [[ "$mp_use_wrapper" == "1" ]]; then
            info "starting mailpit via launch-wrapper (custom BREW_PREFIX = $BREW_PREFIX)"
            launch_wrapper_install_extbrew \
                --svc mailpit \
                --label "com.${USER}.mailpit" \
                --brew-bin "$BREW_PREFIX/opt/mailpit/bin/mailpit" \
                || warn "launch-wrapper for mailpit failed (non-fatal — service can be started manually)"
        elif "$BREW_BIN" services list 2>/dev/null | awk '$1=="mailpit" && $2=="started"{found=1} END{exit !found}'; then
            ok "mailpit brew service already started"
        else
            info "starting mailpit via brew services"
            "$BREW_BIN" services start mailpit >/dev/null 2>&1 || warn "brew services start mailpit failed"
        fi
        ;;
    wsl|linux)
        # systemd user service — works if WSL has systemd=true in /etc/wsl.conf
        SVC_DIR="$HOME/.config/systemd/user"
        SVC_FILE="$SVC_DIR/mailpit.service"
        if [[ ! -f "$SVC_FILE" ]]; then
            info "creating systemd user unit → $SVC_FILE"
            mkdir -p "$SVC_DIR"
            cat > "$SVC_FILE" <<'EOF'
[Unit]
Description=Mailpit (local SMTP + web UI)
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/mailpit --smtp 127.0.0.1:1025 --listen 127.0.0.1:8025
Restart=on-failure
RestartSec=3

[Install]
WantedBy=default.target
EOF
        fi

        # Enable + start if systemd user session is usable (requires linger
        # or an active login session). `loginctl enable-linger $USER` keeps
        # it alive across logouts.
        if systemctl --user daemon-reload 2>/dev/null; then
            systemctl --user enable mailpit.service >/dev/null 2>&1 || true
            systemctl --user start mailpit.service >/dev/null 2>&1 \
                && ok "mailpit started (systemd --user)" \
                || warn "systemctl --user start mailpit failed — start manually: mailpit &"
        else
            warn "systemd --user not available — run manually: mailpit &"
        fi
        ;;
esac

ok "Mailpit ready:"
ok "  SMTP:  127.0.0.1:1025  (use in Laravel .env)"
ok "  UI:    http://127.0.0.1:8025"
