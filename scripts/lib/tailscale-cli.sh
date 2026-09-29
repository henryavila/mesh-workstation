#!/usr/bin/env bash
# Make the macOS app CLI available to scripts and Mesh shell profiles.
mesh_tailscale_app() {
    local app
    for app in /Applications/Tailscale.app/Contents/MacOS/Tailscale "$HOME/Applications/Tailscale.app/Contents/MacOS/Tailscale"; do
        if [[ -x "$app" ]]; then printf '%s\n' "$app"; return 0; fi
    done
    return 1
}

mesh_tailscale_cli() {
    local app target tmp found
    export PATH="$HOME/.local/bin:$PATH"
    found="$(type -P tailscale 2>/dev/null || true)"
    [[ -n "$found" && -x "$found" ]] && return 0
    target="$HOME/.local/bin/tailscale"
    if [[ -e "$target" || -L "$target" ]]; then
        echo "tailscale: refusing to replace existing non-executable $target" >&2
        return 1
    fi
    if app="$(mesh_tailscale_app)"; then
        mkdir -p "$HOME/.local/bin" || return 1
        tmp="$(mktemp "$HOME/.local/bin/.tailscale.XXXXXX")" || return 1
        {
            printf '#!/bin/bash\n# managed-by mesh-workstation: tailscale app CLI\n'
            printf 'export TAILSCALE_BE_CLI=1\nexec %q "$@"\n' "$app"
        } > "$tmp"
        chmod 0755 "$tmp" && mv "$tmp" "$target" || { rm -f "$tmp"; return 1; }
        echo "tailscale: CLI available at $target" >&2
        return 0
    fi
    echo 'tailscale: no CLI or Tailscale.app executable found' >&2
    return 1
}
