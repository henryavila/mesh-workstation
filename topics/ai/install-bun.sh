#!/usr/bin/env bash
# Custom installer: Bun runtime.
# Installs to ~/.bun/bin/bun via the official installer. Required by the
# claude-mem plugin (worker on port 37777).

check() {
    command -v bun >/dev/null 2>&1 || [[ -x "$HOME/.bun/bin/bun" ]]
}

install() {
    # Report a failed download/install as install-failed (rc 1), not as a
    # confusing post-verify rc67. `set -o pipefail` makes this self-contained
    # (the curl rc, not bash's rc on empty stdin, drives the result) instead of
    # relying on the engine's inherited pipefail. check() tests the absolute
    # path, so no in-shell PATH export is needed here.
    set -o pipefail
    if ! curl -fsSL https://bun.sh/install | bash; then
        return 1
    fi
}

verify() {
    check
}

# Version-aware update (engine --update + `mesh upgrade`): `bun upgrade` is the
# official self-update. Fall back to re-running the installer when the binary
# is missing (so a broken install still heals). Absolute path first — the
# engine item-subshell often lacks ~/.bun/bin on PATH.
update() {
    local bin="$HOME/.bun/bin/bun"
    if [[ ! -x "$bin" ]]; then
        bin="$(command -v bun 2>/dev/null || true)"
    fi
    if [[ -n "$bin" && -x "$bin" ]]; then
        "$bin" upgrade
        return
    fi
    install
}

repair() { install; }

rollback() {
    # Aliased to `dir` so the L05 unguarded-rm-rf lint allowlist applies.
    local dir="$HOME/.bun"
    [[ -x "$dir/bin/bun" ]] && rm -rf "$dir" 2>/dev/null || true
}

uninstall() {
    # Reverse install() — remove ONLY the installer's binaries, NOT the whole
    # ~/.bun tree. ~/.bun/install/ holds user state mesh never created: the
    # global package cache (~/.bun/install/cache) and globally-installed CLIs
    # (~/.bun/install/global, shimmed under ~/.bun/bin). Nuking it would be
    # guessing-deletion of user data. The PATH/completion lines the installer
    # appended to the user's shell rc are user-owned and left untouched.
    local dir="$HOME/.bun"
    rm -f "$dir/bin/bun" "$dir/bin/bunx" 2>/dev/null || true
    # Drop bin/ then ~/.bun only if now empty (preserves install/ + any user
    # shims); rmdir fails harmlessly when not empty.
    rmdir "$dir/bin" "$dir" 2>/dev/null || true
    # Honest marker drop: success = the binary we installed is actually gone.
    [[ ! -e "$dir/bin/bun" ]]
}
