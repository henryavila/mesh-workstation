#!/usr/bin/env bash
# Custom installer: shell bootstrap (C14 — generic shell logic moved from
# identity to workstation).
#
# Three side-effects bundled because they share a setup story for users:
#   1. Prepare ~/.bashrc.d, ~/.zshrc.d, ~/.config, ~/.local/bin
#   2. Symlink shell-files/{auto-update,mesh-guard}.zsh → ~/.zshrc.d/
#   3. Merge shell-files/gitignore_global into the file referenced by git's
#      core.excludesfile (or our default ~/.gitignore_global if unset).
#
# CP4 chunk C C-F-004 (resolved 2026-05-23): the previous form unconditionally
# overwrote ~/.gitignore_global and reset git core.excludesfile to point at
# it. Users who already had a custom excludesfile (e.g. $HOME/.config/git/ignore
# with hand-curated rules) lost the registration AND ended up with two
# competing files. Now:
#   - Our content lives between managed_block markers (mesh-managed:
#     gitignore_global) so it can coexist with user-authored rules.
#   - When `git config --global core.excludesfile` is empty, we set it to
#     our default ($HOME/.gitignore_global) and write the block there.
#   - When it is set to a custom path, we leave the git config alone and
#     write the managed_block into the user's existing file.
#   - Audit confirmed (2026-05-23): no other workstation code reads
#     ~/.gitignore_global by absolute path, so honoring the user's chosen
#     path breaks nothing downstream.

# Resolve the target file for the gitignore_global managed_block.
# Echoes the absolute path. Falls back to our default when:
#   - git is not on PATH (still pick the canonical so install() has a
#     deterministic target; user can adopt later via `git config --global`).
#   - core.excludesfile is unset.
# Expands a leading `~` in the user's config value to $HOME for downstream
# file operations.
_resolve_gitignore_target() {
    local current default
    default="$HOME/.gitignore_global"
    if ! command -v git >/dev/null 2>&1; then
        printf '%s' "$default"
        return 0
    fi
    current="$(git config --global --get core.excludesfile 2>/dev/null || true)"
    if [[ -n "$current" ]]; then
        printf '%s' "${current/#\~/$HOME}"
    else
        printf '%s' "$default"
    fi
}

# Source managed-block helpers. Set MB_LOADED guard since check() and
# install() both may need them and we don't want to re-source if already in.
_load_managed_block() {
    local ws_lib here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
        ws_lib="${MESH_WORKSTATION_DIR}/scripts/lib"
    else
        ws_lib="$(cd "$here/../.." && pwd)/scripts/lib"
    fi
    if ! declare -f managed_block_apply >/dev/null 2>&1; then
        # shellcheck disable=SC1091
        . "$ws_lib/managed-block.sh"
    fi
}

check() {
    local here src dst hooks_ok=1
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    for shellfile in auto-update.zsh mesh-guard.zsh; do
        src="$here/shell-files/$shellfile"
        dst="$HOME/.zshrc.d/$shellfile"
        # CP4 chunk C finding C-F-003: require source to exist AND the
        # dst symlink to point at it. Previous version accepted a
        # dangling symlink as "healthy" after the source file was
        # removed (branch swap / partial sync / sparse checkout).
        if [[ ! -f "$src" ]] || [[ ! -L "$dst" ]] || \
           [[ "$(readlink "$dst")" != "$src" ]]; then
            hooks_ok=0
            break
        fi
    done
    [[ "$hooks_ok" -eq 1 ]] || return 1

    # gitignore_global: managed_block_in_sync against whichever file is
    # currently registered (or our default if registration is empty).
    local gi_target gi_src
    gi_target="$(_resolve_gitignore_target)"
    gi_src="$here/shell-files/gitignore_global"
    [[ -f "$gi_target" ]] || return 1
    _load_managed_block
    managed_block_in_sync "$gi_src" "$gi_target" "gitignore_global" 2>/dev/null
}

install() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    mkdir -p "$HOME/.bashrc.d" "$HOME/.zshrc.d" "$HOME/.config" "$HOME/.local/bin"

    # Cleanup stale fragments from the env rename (dev-bootstrap → mesh).
    for stale in "$HOME/.bashrc.d/00-dev-bootstrap-env.sh" "$HOME/.zshrc.d/00-dev-bootstrap-env.sh"; do
        [[ -f "$stale" ]] && rm -f "$stale"
    done

    # Shell-file symlinks. CP4 chunk C finding C-F-003: refuse to
    # create dangling links — fail loud if a required hook source is
    # missing (partial workstation checkout).
    for shellfile in auto-update.zsh mesh-guard.zsh; do
        local src="$here/shell-files/$shellfile"
        local dst="$HOME/.zshrc.d/$shellfile"
        if [[ ! -f "$src" ]]; then
            warn "30-shell: required hook source missing: $src"
            return 1
        fi
        if [[ ! -L "$dst" ]] || [[ "$(readlink "$dst")" != "$src" ]]; then
            ln -sf "$src" "$dst"
        fi
    done

    # gitignore_global merge via managed_block (CP4 C-F-004).
    _load_managed_block
    local gi_src gi_target gi_default current
    gi_src="$here/shell-files/gitignore_global"
    gi_default="$HOME/.gitignore_global"
    gi_target="$(_resolve_gitignore_target)"

    mkdir -p "$(dirname "$gi_target")"
    managed_block_apply "$gi_target" gitignore_global < "$gi_src"

    # Register core.excludesfile ONLY when the user has no value set. If
    # the user already pointed it at a custom path we just merged into,
    # respect the existing registration and do not rewrite git config.
    if command -v git >/dev/null 2>&1; then
        current="$(git config --global --get core.excludesfile 2>/dev/null || true)"
        if [[ -z "$current" ]]; then
            git config --global core.excludesfile "$gi_default"
        fi
    fi
}

verify() {
    check
}

repair() { install; }

rollback() {
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # Remove the 2 zsh-hook symlinks if they point at our sources.
    for shellfile in auto-update.zsh mesh-guard.zsh; do
        local dst="$HOME/.zshrc.d/$shellfile"
        if [[ -L "$dst" ]] && [[ "$(readlink "$dst")" == "$here/shell-files/$shellfile" ]]; then
            rm -f "$dst"
        fi
    done
    # Strip the gitignore_global managed_block from whichever file we
    # wrote into. Leave any user-authored content (above/below the
    # markers) intact. Skip silently when target is missing or python3
    # is unavailable — rollback is best-effort and the residual block
    # is harmless.
    local gi_target
    gi_target="$(_resolve_gitignore_target)"
    if [[ -f "$gi_target" ]] && command -v python3 >/dev/null 2>&1; then
        python3 - "$gi_target" "gitignore_global" <<'PY' 2>/dev/null || true
import re, sys, pathlib
target, slot = pathlib.Path(sys.argv[1]), sys.argv[2]
text = target.read_text()
pattern = re.compile(
    r'^# >>> BEGIN (?:dotfiles|mesh)-managed: ' + re.escape(slot) +
    r' >>>.*?^# <<< END (?:dotfiles|mesh)-managed: ' + re.escape(slot) +
    r' <<<\n?',
    re.IGNORECASE | re.MULTILINE | re.DOTALL,
)
new = pattern.sub('', text)
# Don't delete the file if it had only our block (could be user-empty
# but registered); just leave it empty so git config remains valid.
target.write_text(new)
PY
    fi
}
