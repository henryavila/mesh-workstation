#!/usr/bin/env bash
# personal/apply: clone $MESH_IDENTITY_REPO + run its install.sh.
# Custom item contract — engine sources this and calls check()/install()/verify().
# Marked idempotent in the manifest: the identity repo is re-applied on every run
# (identity_ensure_repo pulls, the fork's install.sh is itself idempotent).

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/log.sh"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/identity-repo.sh"
# shellcheck disable=SC1091
source "$HERE/../../scripts/lib/topic-cleanup.sh"

# True when a controlling terminal is reachable (works even under the engine's
# `... | tee LOG` pipe, where [ -t 1 ] is false — see tty_detection_under_tee_pipe).
_has_tty() { : </dev/tty >/dev/null 2>&1; }

# Interactive onboarding when no identity repo is configured AND none is cloned.
# Either collects an existing repo URL, or the inputs for a create-from-template
# (the backend in identity-repo.sh does the gh-auth check + `gh repo create`).
# Sets MESH_IDENTITY_REPO and/or CREATE_IDENTITY_FROM_TEMPLATE + MESH_IDENTITY_NEW_REPO_*.
_prompt_identity_repo() {
    local tmpl owner name def_owner
    printf '\n' >/dev/tty
    info "No mesh-identity repo is configured for this machine."

    if confirm 'Create a new private repo from a GitHub template?'; then
        tmpl="$(ask_line 'Template repo (owner/name, e.g. henryavila/dotfiles-template)')"
        if [[ -z "$tmpl" ]]; then
            warn "no template given — skipping identity create"
            return 0
        fi
        def_owner="$(gh api user -q .login 2>/dev/null || true)"
        owner="$(ask_line "New repo owner [${def_owner:-your-gh-login}]" "$def_owner")"
        name="$(ask_line 'New repo name [mesh-identity]' 'mesh-identity')"

        export CREATE_IDENTITY_FROM_TEMPLATE=1
        export MESH_IDENTITY_TEMPLATE_REPO="$tmpl"
        export MESH_IDENTITY_NEW_REPO_OWNER="$owner"
        export MESH_IDENTITY_NEW_REPO_NAME="$name"
        if confirm 'Private?' y; then export MESH_IDENTITY_NEW_REPO_PRIVATE=1; else export MESH_IDENTITY_NEW_REPO_PRIVATE=0; fi
        export MESH_IDENTITY_REPO="$owner/$name"   # satisfies downstream + records the new repo
    else
        local url; url="$(ask_line 'Existing mesh-identity repo (URL or owner/name), blank to skip')"
        [[ -n "$url" ]] && export MESH_IDENTITY_REPO="$url"
    fi
}

check() {
    # Idempotent apply — always run (manifest idempotent: true). The identity
    # fork's own install.sh handles the "already applied" fast paths.
    return 1
}

install() { (
    set -euo pipefail

    : "${MESH_IDENTITY_DIR:=$HOME/mesh-identity}"

    # Resolve the identity repo, in priority order:
    #   1. MESH_IDENTITY_REPO set (menu option / env / default_from) → clone+pull.
    #   2. An existing checkout at $MESH_IDENTITY_DIR → reuse it (derive the URL).
    #   3. Interactive TTY → onboarding prompt (existing URL, or create-from-template).
    #   4. Headless with nothing configured → skip with a critical followup (do not
    #      abort the whole engine run — foundation/languages must still land).
    #   5. Interactive with nothing after prompt → fail actionable.
    if [[ -z "${MESH_IDENTITY_REPO:-}" ]]; then
        if [[ -d "$MESH_IDENTITY_DIR/.git" ]]; then
            MESH_IDENTITY_REPO="$(git -C "$MESH_IDENTITY_DIR" remote get-url origin 2>/dev/null || true)"
            info "using the existing identity checkout at $MESH_IDENTITY_DIR"
        elif [[ "${NON_INTERACTIVE:-0}" != "1" ]] && _has_tty; then
            _prompt_identity_repo
        fi
    fi

    if [[ -z "${MESH_IDENTITY_REPO:-}" && "${CREATE_IDENTITY_FROM_TEMPLATE:-0}" != "1" && ! -d "$MESH_IDENTITY_DIR/.git" ]]; then
        if [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
            followup critical "Personal identity skipped (headless, no MESH_IDENTITY_REPO). Re-run with MESH_IDENTITY_REPO=owner/repo or interactively: bash setup.sh"
            warn "personal/personal: skipping — no identity repo in non-interactive mode"
            return 0
        fi
        fail "no mesh-identity repo: set it in the 'Personal identity' options, export MESH_IDENTITY_REPO, or run setup.sh interactively to create one"
        return 1
    fi

    identity_ensure_repo "${MESH_IDENTITY_REPO:-}" "$MESH_IDENTITY_DIR"

    # Public-key enrollment belongs after the private repo exists and before
    # deployment: recipients consume this committed trust list on identity update.
    # Never silently call onboarding complete when publication failed.
    local enroll_lib="$HERE/../../scripts/lib/ssh-enroll.py"
    python3 "$enroll_lib" --repo "$MESH_IDENTITY_DIR" || return 1

    if [[ -f "$MESH_IDENTITY_DIR/install.sh" ]]; then
        info "running $MESH_IDENTITY_DIR/install.sh"
        MESH_NPM_GLOBAL="${MESH_NPM_GLOBAL:-0}" bash "$MESH_IDENTITY_DIR/install.sh"
    else
        warn "$MESH_IDENTITY_DIR/install.sh not found — identity repo cloned but not applied"
    fi

    # Drift cleanup: artifacts the identity fork used to install but no longer
    # does. Reads data/uninstall.list and removes each entry. Idempotent.
    uninstall_apply "$HERE/data/uninstall.list"

    python3 "$enroll_lib" --repo "$MESH_IDENTITY_DIR" --report-peers || return 1
    ok "personal identity done (see SSH peer delivery follow-ups)"
) }

verify() {
    [ -d "${MESH_IDENTITY_DIR:-$HOME/mesh-identity}" ]
}

rollback() {
    # Never auto-remove the user's applied identity layer.
    :
}
