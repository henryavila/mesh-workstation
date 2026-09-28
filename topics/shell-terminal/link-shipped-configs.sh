#!/usr/bin/env bash
# C15: 5 shipped default configs (p10k, btop, btop theme, eza, htop).
# Identity overrides win on conflict (the personal topic's deploy.map runs later).

_pairs() {
    cat <<'EOF'
configs/p10k.zsh|$HOME/.p10k.zsh
configs/btop/btop.conf|$HOME/.config/btop/btop.conf
configs/btop/themes/catppuccin_mocha.theme|$HOME/.config/btop/themes/catppuccin_mocha.theme
configs/eza/theme.yml|$HOME/.config/eza/theme.yml
configs/htoprc|$HOME/.config/htop/htoprc
EOF
}

check() {
    local here dst rel
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while IFS='|' read -r rel dst; do
        [[ -z "$rel" ]] && continue
        dst="${dst//\$HOME/$HOME}"
        # Aligned with link_default_config "first-writer-wins": any
        # existing destination (real file, our symlink, identity-shipped
        # foreign symlink — stow-style workflows) counts as satisfied.
        # CP4 chunk C finding C-F-001.
        if [[ -e "$dst" ]] || [[ -L "$dst" ]]; then continue; fi
        return 1
    done < <(_pairs)
    return 0
}

install() {
    local here ws_lib
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
        ws_lib="${MESH_WORKSTATION_DIR}/scripts/lib"
    else
        ws_lib="$(cd "$here/../.." && pwd)/scripts/lib"
    fi
    # shellcheck disable=SC1091
    . "$ws_lib/topic-configs.sh"
    local rel dst
    while IFS='|' read -r rel dst; do
        [[ -z "$rel" ]] && continue
        dst="${dst//\$HOME/$HOME}"
        link_default_config "$here/$rel" "$dst"
    done < <(_pairs)
}

verify() {
    check
}

repair() { install; }

rollback() {
    local here src dst rel
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while IFS='|' read -r rel dst; do
        [[ -z "$rel" ]] && continue
        src="$here/$rel"
        dst="${dst//\$HOME/$HOME}"
        if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$src" ]]; then
            rm -f "$dst"
        fi
    done < <(_pairs)
}
