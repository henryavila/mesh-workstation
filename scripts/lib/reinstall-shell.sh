#!/usr/bin/env bash
# scripts/lib/reinstall-shell.sh — source-only helpers for `mesh reinstall shell`.
#
# Reapplies the shell layer (rc files, CLI DX tools, tmux/nvim/fonts, git
# aliases) without touching PHP/web/databases/docker and without rewriting
# ~/.config/mesh/selections.list. The engine is invoked as a normal apply
# (idempotent items run) — not --repair, which skips those items.

reinstall_shell_bundles() {
    printf '%s\n' \
        foundation/base \
        git/config \
        git/lazygit \
        shell-terminal/cli-tools \
        shell-terminal/zsh \
        shell-terminal/tmux \
        shell-terminal/nvim \
        shell-terminal/fonts
}

# Unmanaged rc files do not block apply. deploy.sh backs them up and
# installs the managed file.
reinstall_shell_rc_is_blocking() {
    return 1
}

reinstall_shell_rc_paths() {
    printf '%s\n' \
        "$HOME/.bashrc" \
        "$HOME/.zshrc" \
        "$HOME/.tmux.conf"
}

reinstall_shell_print_unmanaged_help() {
    local f
    cat <<'EOF'
refusing to overwrite a user-authored rc file (no 'managed by mesh-workstation' marker).
This file has content the shell reinstall will not merge. Options:

EOF
    for f in "$@"; do
        [[ -n "$f" ]] || continue
        cat <<EOF
  $f
    cp $f ${f}.local.rescue
    # move personal snippets into ${f}.local
    mv $f ${f}.unmanaged.bak

EOF
    done
    cat <<'EOF'
Then re-run:

  mesh reinstall shell

Custom config belongs in ~/.bashrc.local / ~/.zshrc.local (never overwritten).
EOF
}

reinstall_shell_collect_blocking() {
    local f
    while IFS= read -r f || [[ -n "${f:-}" ]]; do
        [[ -n "$f" ]] || continue
        if reinstall_shell_rc_is_blocking "$f"; then
            printf '%s\n' "$f"
        fi
    done < <(reinstall_shell_rc_paths)
}

reinstall_shell_print_plan() {
    echo "mesh reinstall shell — plan"
    echo "  apply (normal, not --repair):"
    reinstall_shell_bundles | sed 's/^/    /'
    echo "  does not rewrite ~/.config/mesh/selections.list"
    echo "  does not uninstall deselected bundles"
    echo "  does not touch PHP, nginx, databases, docker, Node, identity/personal"
}

reinstall_shell_print_followup() {
    cat <<'EOF'

Next:
  close every terminal tab for this distro, then open a new one.
  if tmux is running: tmux kill-server
EOF
}

reinstall_shell_resolve_repo() {
    local here
    if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/topics" ]]; then
        printf '%s' "$MESH_WORKSTATION_DIR"
        return 0
    fi
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -d "$here/../../topics" ]]; then
        printf '%s' "$(cd "$here/../.." && pwd)"
        return 0
    fi
    return 1
}

reinstall_shell_resolve_engine() {
    local repo
    if [[ -n "${MESH_REINSTALL_ENGINE:-}" ]]; then
        printf '%s' "$MESH_REINSTALL_ENGINE"
        return 0
    fi
    repo="$(reinstall_shell_resolve_repo)" || return 1
    printf '%s' "$repo/scripts/lib/install-engine.sh"
}

reinstall_shell_resolve_platform() {
    local repo detect
    if [[ -n "${MESH_OS:-}" ]]; then
        printf '%s' "$MESH_OS"
        return 0
    fi
    repo="$(reinstall_shell_resolve_repo)" || { printf 'unknown'; return 0; }
    detect="$repo/scripts/lib/detect-os.sh"
    if [[ -r "$detect" ]]; then
        bash "$detect" 2>/dev/null || printf 'unknown'
        return 0
    fi
    printf 'unknown'
}

# Run the preflight + optional engine apply.
# Usage: reinstall_shell_run [--dry-run]
# rc 0 ok, 65 unmanaged rc, 64 usage, 1 engine/repo failure.
reinstall_shell_run() {
    local dry=0 blocking="" f engine sel platform rc=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) dry=1; shift ;;
            *) echo "reinstall_shell_run: unknown arg: $1" >&2; return 64 ;;
        esac
    done

    blocking="$(reinstall_shell_collect_blocking || true)"
    if [[ -n "$blocking" ]]; then
        echo "mesh reinstall shell: unmanaged rc file(s) — no 'managed by mesh-workstation' marker." >&2
        set --
        while IFS= read -r f || [[ -n "${f:-}" ]]; do
            [[ -n "${f:-}" ]] && set -- "$@" "$f"
        done <<< "$blocking"
        reinstall_shell_print_unmanaged_help "$@" >&2
        return 65
    fi

    reinstall_shell_print_plan
    if [[ "$dry" -eq 1 ]]; then
        echo "dry-run: engine not invoked"
        return 0
    fi

    engine="$(reinstall_shell_resolve_engine)" || {
        echo "mesh reinstall shell: install-engine.sh not found (set MESH_WORKSTATION_DIR)" >&2
        return 1
    }
    [[ -x "$engine" || -f "$engine" ]] || {
        echo "mesh reinstall shell: engine not found: $engine" >&2
        return 1
    }

    sel="$(mktemp "${TMPDIR:-/tmp}/mesh-reinstall-shell.XXXXXX")" || return 1
    {
        echo "# mesh reinstall shell — ephemeral selection; do not persist"
        reinstall_shell_bundles
    } > "$sel"

    platform="$(reinstall_shell_resolve_platform)"
    echo "applying via $engine (platform=$platform)"
    if bash "$engine" \
        --selections "$sel" \
        --non-interactive \
        --platform "$platform"; then
        rc=0
    else
        rc=$?
    fi
    rm -f "$sel"
    if [[ "$rc" -ne 0 ]]; then
        echo "mesh reinstall shell: engine exited $rc" >&2
        return "$rc"
    fi
    echo "mesh reinstall shell: apply finished"
    reinstall_shell_print_followup
    return 0
}
