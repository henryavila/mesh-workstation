#!/usr/bin/env bash
# runners/reinstall.sh — `mesh reinstall <target>`
#
# First target: `shell` — reapply the shell/DX layer without touching
# PHP/web/databases/docker and without rewriting selections.list.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
. "$HERE/../lib/reinstall-shell.sh"

usage() {
    cat <<'EOF'
Usage:
  mesh reinstall shell [--dry-run]
  mesh reinstall --help

Reapply the shell layer (zsh/bash rc, modern CLI, tmux, Neovim, fonts,
git aliases/lazygit) on an existing machine.

Does:
  - normal engine apply of the shell allowlist (idempotent items run)
  - back up ~/.bashrc ~/.zshrc ~/.tmux.conf that lack the mesh marker,
    then install the managed file. Extra lines go to the matching *.local

Does not:
  - rewrite ~/.config/mesh/selections.list
  - uninstall bundles missing from the allowlist
  - touch PHP, nginx, Valet, databases, docker, Node, identity/personal
  - unregister or reinstall the WSL distro

--dry-run prints the plan and does not invoke the engine.

After a successful apply: close every tab for this distro; if tmux is
running, `tmux kill-server`.
EOF
}

DRY=0
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --dry-run)
            DRY=1
            shift
            ;;
        shell)
            if [[ -n "$TARGET" ]]; then
                echo "mesh reinstall: unexpected extra target '$1' (already '$TARGET')" >&2
                exit 64
            fi
            TARGET="shell"
            shift
            ;;
        *)
            echo "mesh reinstall: unknown target '$1' (supported: shell)" >&2
            echo "Try: mesh reinstall shell" >&2
            exit 64
            ;;
    esac
done

if [[ -z "$TARGET" ]]; then
    usage >&2
    echo "mesh reinstall: missing target (supported: shell)" >&2
    exit 64
fi

if [[ "$DRY" -eq 1 ]]; then
    reinstall_shell_run --dry-run
else
    reinstall_shell_run
fi
