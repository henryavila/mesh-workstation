#!/usr/bin/env bash
set -euo pipefail

# Ensure brew-managed binaries are visible when verify runs from a
# non-interactive shell (SSH, CI) where ~/.zshrc / ~/.bashrc aren't loaded.
# brew prefix varies by host: /opt/homebrew (Apple Silicon), /usr/local (Intel),
# or a custom location like /Volumes/External/homebrew. Probe all candidates.
for _brew_prefix in /opt/homebrew /usr/local /Volumes/External/homebrew; do
    [[ -d "$_brew_prefix/bin" ]] && export PATH="$_brew_prefix/bin:$PATH"
done

fail_count=0
check() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "  ✓ $1"
    else
        echo "  ✗ $1 MISSING"
        fail_count=$((fail_count + 1))
    fi
}

selections_file="${MESH_SELECTIONS_FILE:-$HOME/.config/mesh/selections.list}"
selected_or_legacy() {
    [[ ! -r "$selections_file" ]] || grep -qFx "$1" "$selections_file"
}
if selected_or_legacy remote-access/ssh; then check ssh; fi
if selected_or_legacy remote-access/mosh; then check mosh; fi

if [[ -r "$selections_file" ]] && grep -qE '^remote-access/tuios(-cloudflare)?$' "$selections_file"; then
    tuios_bin="${TUIOS_BIN_DIR:-$HOME/.local/bin}/tuios"
    tuios_web_bin="${TUIOS_BIN_DIR:-$HOME/.local/bin}/tuios-web"
    if [[ ! -x "$tuios_bin" ]]; then tuios_bin="$(command -v tuios 2>/dev/null || true)"; fi
    if [[ ! -x "$tuios_web_bin" ]]; then tuios_web_bin="$(command -v tuios-web 2>/dev/null || true)"; fi
    if [[ -n "$tuios_bin" && -x "$tuios_bin" ]]; then
        echo "  ✓ tuios"
    else
        echo "  ✗ tuios MISSING"
        fail_count=$((fail_count + 1))
    fi
    if [[ -n "$tuios_web_bin" && -x "$tuios_web_bin" ]]; then
        echo "  ✓ tuios-web"
    else
        echo "  ✗ tuios-web MISSING"
        fail_count=$((fail_count + 1))
    fi
    if [[ -n "$tuios_bin" && -x "$tuios_bin" && -n "$tuios_web_bin" && -x "$tuios_web_bin" ]]; then
        tuios_version="$("$tuios_bin" --version 2>/dev/null | awk '$2 == "version" {print $3; exit}' || true)"
        tuios_web_version="$("$tuios_web_bin" --version 2>/dev/null | awk '$2 == "version" {print $3; exit}' || true)"
        if [[ -n "$tuios_version" && "$tuios_version" == "$tuios_web_version" ]]; then
            echo "  ✓ tuios + tuios-web version $tuios_version"
        else
            echo "  ✗ tuios version mismatch (CLI=${tuios_version:-?}, web=${tuios_web_version:-?})"
            fail_count=$((fail_count + 1))
        fi
    fi
fi

if [[ -r "$selections_file" ]] && grep -qFx 'remote-access/tuios-cloudflare' "$selections_file"; then
    if [[ -x "$HOME/.local/bin/cloudflared" ]]; then
        echo "  ✓ cloudflared"
    else
        check cloudflared
    fi
fi

# Tailscale: on Mac the .app binary lives inside /Applications and the
# CLI isn't added to PATH by default. Accept either presence as installed.
if selected_or_legacy remote-access/tailscale; then
    if command -v tailscale >/dev/null 2>&1; then
        echo "  ✓ tailscale (CLI in PATH)"
    elif [[ "$(uname -s)" == "Darwin" ]] && [[ -d "/Applications/Tailscale.app" ]]; then
        echo "  ✓ Tailscale.app (add '/Applications/Tailscale.app/Contents/MacOS' to PATH to get CLI)"
    else
        echo "  ✗ tailscale MISSING"
        fail_count=$((fail_count + 1))
    fi
fi

# Tailscale MTU drop-in (WSL/Linux only)
# Presence check — we don't fail if absent (topic may have been run before this fix existed).
if selected_or_legacy remote-access/tailscale && [[ "$(uname -s)" == "Linux" ]]; then
    mtu_dropin="/etc/systemd/system/tailscaled.service.d/mtu.conf"
    if [[ -f "$mtu_dropin" ]]; then
        if grep -q 'mtu 1200' "$mtu_dropin" 2>/dev/null; then
            echo "  ✓ tailscale MTU drop-in present (mtu=1200)"
        else
            echo "  ! tailscale MTU drop-in present but content unexpected — inspect $mtu_dropin"
        fi
        # If tailscale0 is up, verify actual MTU applied
        if ip link show tailscale0 >/dev/null 2>&1; then
            actual_mtu="$(ip link show tailscale0 | awk '/mtu/ {for(i=1;i<=NF;i++) if($i=="mtu") print $(i+1)}')"
            if [[ "$actual_mtu" == "1200" ]]; then
                echo "  ✓ tailscale0 MTU = $actual_mtu (applied)"
            else
                echo "  ! tailscale0 MTU = $actual_mtu (expected 1200 — drop-in may not have run; restart tailscaled)"
            fi
        fi
    else
        echo "  ! tailscale MTU drop-in ABSENT — SSH via Tailscale may hang. Re-run: ONLY_TOPICS=70-remote-access bash setup.sh"
    fi
fi

[[ "$fail_count" -eq 0 ]]
