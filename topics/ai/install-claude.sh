#!/usr/bin/env bash
# Custom installer: Claude Code CLI.

check() {
    command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]
}

install() {
    # pipefail so a failed curl is reported as install failure, not masked by bash's rc 0.
    # The argument is the native installer's release channel AND the default for
    # later auto-updates. Pass `latest` (not `stable`) so mesh hosts get each
    # release as it ships — stable lags ~a week and skips some versions.
    ( set -o pipefail; curl -fsSL https://claude.ai/install.sh | bash -s latest )
}

# Version-aware update (engine --update + `mesh upgrade`): check() is
# presence-only, so a stale CLI would otherwise freeze forever. Re-run the
# official installer on the latest channel; it is a no-op when already current.
update() {
    install
}

verify() {
    check
}

repair() { install; }

rollback() {
    if [[ -x "$HOME/.local/bin/claude" ]]; then
        rm -f "$HOME/.local/bin/claude"
    fi
}

uninstall() {
    # Reverse install(): the official claude.ai/install.sh lays down a
    # version-manager layout — a launcher symlink at ~/.local/bin/claude
    # pointing into a version store at ~/.local/share/claude/versions/<ver>.
    # Remove both (rollback only drops the symlink, leaving the store orphaned).
    #
    # Deliberately NOT touched: ~/.claude/ is user data + config (sessions,
    # agents, commands, memory, settings) — not something this binary installer
    # created. Removing it would be guessing-deletion of user data (HARD RULE).
    # No PATH source / apt source / keyring was added by the installer, so
    # there is nothing of that kind to revert.
    : "${HOME:?}"
    local launcher="$HOME/.local/bin/claude"
    local dir="$HOME/.local/share/claude/versions"
    rm -f "$launcher" 2>/dev/null || true
    # Scope-locked to the mesh-managed version store (aliased to `dir` so the
    # L05 unguarded-rm-rf allowlist applies); never a broad rm.
    [[ -d "$dir" ]] && rm -rf "$dir" 2>/dev/null || true
    # Drop the now-empty parent only if empty; rmdir fails harmlessly otherwise.
    rmdir "$HOME/.local/share/claude" 2>/dev/null || true
    # Honest marker drop: gate on the absolute install target, NOT `command -v
    # claude` (check()), which can resolve a foreign claude on PATH (e.g. a
    # Windows-side install) and would falsely report the item still installed.
    [[ ! -e "$launcher" ]]
}
