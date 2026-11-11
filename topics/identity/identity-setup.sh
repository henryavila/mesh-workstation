#!/usr/bin/env bash
# Custom installer: delegates to the existing 178-LOC interactive
# scripts/setup-identity.sh (gh auth + SSH key + GitHub registration).
# Wrapper avoids rewriting the procedural script during mass migration.

# Identity setup needs either a non-interactive GitHub PAT (GITHUB_TOKEN) or a
# usable /dev/tty for the interactive `gh auth login`. With NEITHER — e.g. a
# piped `setup.sh --non-interactive` and no token — scripts/setup-identity.sh
# exits 1, which the engine's fail-fast turns into a WHOLE-RUN abort, taking
# down every later bundle for an item that cannot run headless. Treat that
# non-runnable case as a clean SKIP so the rest of the bootstrap proceeds;
# identity is deferred to a later interactive `mesh setup` (or a run that sets
# GITHUB_TOKEN). Mirrors the gpg-signing skip (4252d81): "cannot act here" is
# not a failure. check() keeps its honest meaning; install()/verify() tolerate
# the skip so a non-runnable headless run neither aborts nor false-succeeds.
# shellcheck source=/dev/null
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../scripts/lib/shared-image.sh"

_identity_runnable() {
    mesh_shared_image && return 1
    [[ -n "${GITHUB_TOKEN:-}" ]] && return 0
    : </dev/tty >/dev/null 2>&1
}

check() {
    # Considered "installed" when gh is authenticated AND an SSH key
    # exists. We don't verify the GitHub-side registration here — that's
    # an interactive concern best left to the procedural script.
    command -v gh >/dev/null 2>&1 \
        && gh auth status >/dev/null 2>&1 \
        && { [[ -f "$HOME/.ssh/id_ed25519" ]] || [[ -f "$HOME/.ssh/id_rsa" ]]; }
}

install() {
    if mesh_shared_image; then
        echo "identity: shared image — not creating a personal GitHub login or SSH key." >&2
        return 0
    fi
    if ! _identity_runnable; then
        echo "identity: no GITHUB_TOKEN and no /dev/tty — skipping identity setup;" \
             "run \`mesh setup\` interactively (or set GITHUB_TOKEN) to complete it" >&2
        return 0
    fi
    local here
    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    bash "$here/scripts/setup-identity.sh"
}

verify() {
    # When the item was skipped (non-runnable headless), nothing was attempted,
    # so post-verify must not assert gh-auth — it would rc=67 the whole run.
    _identity_runnable || return 0
    check
}

repair() { install; }

rollback() {
    # Identity setup is irreversible by design (we don't auto-revoke
    # GitHub OAuth tokens or delete SSH keys on rollback). No-op.
    :
}
