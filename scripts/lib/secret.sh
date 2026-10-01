#!/usr/bin/env bash
# shellcheck shell=bash
# secret.sh — `mesh secret` CLI: the human interface to the secrets layer.
#
# Adding/managing a secret is ONE guided command — never hand-wiring install.sh,
# perms, .gitattributes, or git-crypt internals (see the human-manageable rule).
#
# Verbs:
#   mesh secret init                 first machine: install+init git-crypt, write
#                                    the .gitattributes rule, export the root key.
#   mesh secret unlock <keyfile>     new machine: decrypt the repo with the key.
#   mesh secret add                  wizard: add an integration (login | file | token).
#   mesh secret set <id>             update a stored value.
#   mesh secret rm <id>              remove an integration.
#   mesh secret list                 integrations + per-machine + replication status.
#   mesh secret doctor               drift / health checks.
#   mesh secret deploy               decrypt+place all enabled Tier-2 files; run logins.
#   mesh secret push                 push pending commits (after a failed auto-push).
#
# "Saved" means "replicated": add/set/rm commit AND push, and say so up front.
#
# Run via `bash secret.sh <verb> …` (mesh dispatch execs it). Bash 3.2 floor.

set -uo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$LIB_DIR/env.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/log.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/secrets-resolve.sh"
# shellcheck source=/dev/null
. "$LIB_DIR/secrets-crypt.sh"

ID_DIR="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"
SECRETS_DIR="$ID_DIR/secrets"
MANIFEST="$SECRETS_DIR/manifest.yaml"
ENV_SRC="$SECRETS_DIR/secrets.env"     # encrypted env-token store (Tier 2)
# Runtime path the install engine sources (install-engine.sh SECRETS_FILE_NEW).
ENV_DST="${XDG_STATE_HOME:-$HOME/.local/state}/mesh/secrets.env"

# ── helpers ──────────────────────────────────────────────────────────────────

_machine_id() {
    if [ -n "${MESH_MACHINE:-}" ]; then printf '%s' "$MESH_MACHINE"; return; fi
    local h; h="$(hostname -s 2>/dev/null || hostname 2>/dev/null)"
    printf '%s' "${h:-unknown}"
}

# git-crypt files begin with the magic "\0GITCRYPT\0".
_is_ciphertext() {
    [ -f "$1" ] || return 1
    [ "$(head -c 9 "$1" 2>/dev/null | tr -d '\000')" = "GITCRYPT" ]
}

# Load + eval the manifest into INTEGRATION_* vars. Empty manifest → 0 entries.
_manifest_load() {
    # shellcheck disable=SC2034  # part of the manifest data contract
    if [ ! -f "$MANIFEST" ]; then INTEGRATION_COUNT=0; MANIFEST_VERSION=0; return 0; fi
    local parsed
    parsed="$(bash "$LIB_DIR/secrets-manifest.sh" < "$MANIFEST")" \
        || { fail "manifest parse failed: $MANIFEST"; return 1; }
    eval "$parsed"
    [ "${__SECRETS_MANIFEST_OK:-0}" = "1" ] || { fail "manifest parse incomplete (no sentinel)"; return 1; }
}

# field <idx> <FIELD> → echo INTEGRATION_<idx>_<FIELD> (empty if unset)
_f() { eval "printf '%s' \"\${INTEGRATION_${1}_${2}:-}\""; }

# rc0 if integration <idx> applies to this machine (no machines: list → all).
_applies_here() {
    local i="$1" cnt j m
    cnt="$(_f "$i" MACHINES_COUNT)"
    [ -z "$cnt" ] && return 0
    j=0
    while [ "$j" -lt "$cnt" ]; do
        m="$(eval "printf '%s' \"\${INTEGRATION_${i}_MACHINES_${j}}\"")"
        [ "$m" = "$(_machine_id)" ] && return 0
        j=$((j + 1))
    done
    return 1
}

_remote_url() { git -C "$ID_DIR" remote get-url origin 2>/dev/null; }

# echo "<ahead>" commits the identity repo is ahead of its upstream (0 if none).
_unpushed_count() {
    git -C "$ID_DIR" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0
}

_require_git_crypt_ready() {
    if ! secrets_crypt_available; then
        fail "git-crypt is not installed. Run: mesh secret init"
        return 1
    fi
    if ! secrets_crypt_initialized "$ID_DIR"; then
        fail "git-crypt not set up in $ID_DIR. Run 'mesh secret init' (first machine) or 'mesh secret unlock <keyfile>'."
        return 1
    fi
    return 0
}

# Commit staged changes in the identity repo and PUSH. "Saved" = replicated:
# a push failure is loud and recoverable, never silently reported as success.
# _commit_and_push <commit-msg>
_commit_and_push() {
    local msg="$1" remote
    remote="$(_remote_url)"
    git -C "$ID_DIR" commit -q -m "$msg" || { fail "commit failed"; return 1; }
    if git -C "$ID_DIR" push -q 2>/dev/null; then
        ok "encrypted, committed, and pushed to ${remote:-origin}"
        return 0
    fi
    warn "Saved + committed LOCALLY, but PUSH FAILED — it is NOT yet replicated."
    warn "Fix connectivity/auth, then run:  mesh secret push"
    return 3
}

# ── verbs ────────────────────────────────────────────────────────────────────

secret_init() {
    info "Setting up git-crypt for the secrets layer in $ID_DIR"
    if ! secrets_crypt_available; then
        info "git-crypt not found — installing…"
        secrets_crypt_install || { fail "could not install git-crypt"; return 1; }
    fi
    secrets_crypt_attr_ensure "$ID_DIR" || return 1
    mkdir -p "$SECRETS_DIR"
    if secrets_crypt_initialized "$ID_DIR"; then
        ok "git-crypt already initialized"
    else
        # No lingering key file: the key lives in the repo keystore and is
        # retrievable via `mesh secret export-key` whenever needed.
        secrets_crypt_init "$ID_DIR" || return 1
        ok "git-crypt initialized."
        warn "SAVE YOUR ROOT KEY NOW — it unlocks every secret on every machine."
        warn "Most password managers are text-only, so store the base64 form:"
        warn "    mesh secret export-key       # prints one base64 line to copy"
        warn "On a new machine:  mesh secret unlock   (paste that base64 key)"
    fi
    [ -f "$MANIFEST" ] || printf 'version: 1\nintegrations:\n' > "$MANIFEST"
    git -C "$ID_DIR" add .gitattributes secrets/manifest.yaml 2>/dev/null || true
    if ! git -C "$ID_DIR" diff --cached --quiet 2>/dev/null; then
        _commit_and_push "secret(init): enable git-crypt secrets layer" || true
    fi
    ok "Secrets layer ready. Add your first secret with: mesh secret add"
}

# Portable base64 decode (BSD/macOS + GNU).
_b64_decode() {
    base64 -d 2>/dev/null || base64 --decode 2>/dev/null || base64 -D 2>/dev/null
}

secret_unlock() {
    local arg="${1:-}"
    if ! secrets_crypt_available; then
        info "git-crypt not found — installing…"
        secrets_crypt_install || { fail "could not install git-crypt"; return 1; }
    fi
    local keyfile cleanup=0
    if [ -n "$arg" ] && [ -f "$arg" ]; then
        # A real key file was given.
        keyfile="$arg"
    else
        # Base64 key (text-friendly for password managers): take it as the arg,
        # or prompt for a hidden paste. Decoded to a temp file, used, shredded.
        local b64="$arg"
        if [ -z "$b64" ]; then
            [ -e /dev/tty ] || { fail "usage: mesh secret unlock <keyfile> | <base64> (or run interactively to paste)"; return 1; }
            # Required field: a blank Enter must not slip past silently — confirm
            # the skip, otherwise re-prompt (ask_secret_or_skip handles the loop).
            if ! b64="$(ask_secret_or_skip 'Paste the base64 git-crypt key (from your password manager)' 'No key entered — skip unlocking this machine for now?')"; then
                warn "skipped — repo stays locked. Run 'mesh secret unlock' when you have the key."
                return 1
            fi
        fi
        keyfile="$(mktemp)"; cleanup=1
        if ! printf '%s' "$b64" | _b64_decode > "$keyfile" 2>/dev/null || [ ! -s "$keyfile" ]; then
            rm -f "$keyfile"; fail "could not decode base64 key (paste the full string)"; return 1
        fi
    fi
    if ! secrets_crypt_unlock "$ID_DIR" "$keyfile"; then
        [ "$cleanup" = 1 ] && rm -f "$keyfile"
        fail "unlock failed"; return 1
    fi
    [ "$cleanup" = 1 ] && rm -f "$keyfile"
    ok "Repo unlocked. Replicate secrets to this machine with: mesh secret deploy"
}

# Print the root key as a single base64 line for storage in a (text-only)
# password manager. Run in a PRIVATE terminal — it prints a secret.
secret_export_key() {
    _require_git_crypt_ready || return 1
    secrets_crypt_unlocked "$ID_DIR" || { fail "repo is locked — nothing to export"; return 1; }
    warn "This prints the ROOT KEY (base64). Anyone with it can decrypt every secret."
    warn "Copy it into your password manager as a secure note; do NOT paste it anywhere shared."
    local tmp; tmp="$(mktemp)"
    if ! ( cd "$ID_DIR" && git-crypt export-key "$tmp" ); then rm -f "$tmp"; fail "export failed"; return 1; fi
    base64 < "$tmp" | tr -d '\n'; printf '\n'
    rm -f "$tmp"
}

secret_push() {
    local remote; remote="$(_remote_url)"
    if [ "$(_unpushed_count)" = "0" ]; then ok "nothing to push (up to date)"; return 0; fi
    if git -C "$ID_DIR" push -q 2>/dev/null; then
        ok "pushed to ${remote:-origin}"
    else
        fail "push failed — check connectivity/auth and retry"
        return 1
    fi
}

_deploy_file() {
    local i="$1" id src perms resolver destfile destpath abs dst
    id="$(_f "$i" ID)"; src="$(_f "$i" SOURCE)"; perms="$(_f "$i" PERMS)"
    resolver="$(_f "$i" DEST_RESOLVER)"; destfile="$(_f "$i" DEST_FILE)"; destpath="$(_f "$i" DEST_PATH)"
    [ -n "$perms" ] || perms=0600
    [ -n "$src" ] || { warn "$id: no source declared"; return 1; }
    abs="$ID_DIR/$src"
    if [ ! -f "$abs" ]; then warn "$id: source missing ($src) — set it with 'mesh secret add'"; return 0; fi
    if _is_ciphertext "$abs"; then warn "$id: source still encrypted — run 'mesh secret unlock' first"; return 0; fi
    dst="$(secrets_dest_path "$destpath" "$resolver" "$destfile")" || { warn "$id: cannot resolve destination"; return 1; }
    deploy_one "$src|$dst|overwrite|$perms" "$ID_DIR" && ok "$id → $dst"
}

_deploy_login() {
    local i="$1" id check login
    id="$(_f "$i" ID)"; check="$(_f "$i" CHECK)"; login="$(_f "$i" LOGIN)"
    if [ -n "$check" ] && sh -c "$check" >/dev/null 2>&1; then ok "$id: already authenticated"; return 0; fi
    if [ -n "$login" ] && [ "${NON_INTERACTIVE:-0}" != "1" ] && [ -e /dev/tty ]; then
        info "$id: launching login → $login"
        sh -c "$login" </dev/tty || warn "$id: login did not complete"
    else
        warn "$id: not authenticated — run: ${login:-<no login command declared>}"
    fi
}

# Count applicable file/env-token sources whose committed blob is still
# ciphertext — i.e. the repo is locked HERE and they cannot be deployed.
# >0 means deploy can't complete until `mesh secret unlock` runs.
_secret_locked_count() {
    local i type src n=0
    i=0
    while [ "$i" -lt "${INTEGRATION_COUNT:-0}" ]; do
        if _applies_here "$i"; then
            type="$(_f "$i" TYPE)"
            if [ "$type" = "file" ]; then
                src="$(_f "$i" SOURCE)"
                [ -n "$src" ] && _is_ciphertext "$ID_DIR/$src" && n=$((n + 1))
            fi
        fi
        i=$((i + 1))
    done
    # The env-token store is a single encrypted file shared by all env-tokens.
    [ -n "${ENV_SRC:-}" ] && _is_ciphertext "$ENV_SRC" && n=$((n + 1))
    printf '%s' "$n"
}

secret_deploy() {
    _manifest_load || return 1
    # shellcheck source=/dev/null
    . "$LIB_DIR/deploy.sh"

    # A machine that HAS replicated secrets but is LOCKED must not be skipped in
    # silence — that is the "install looks green, deployed nothing" trap. When a
    # TTY is available, configure it now by asking for the key (secret_unlock
    # auto-installs git-crypt and decrypts the working tree in place).
    local locked
    locked="$(_secret_locked_count)"
    if [ "$locked" -gt 0 ] && [ "${NON_INTERACTIVE:-0}" != "1" ] && [ -e /dev/tty ]; then
        warn "This machine has $locked replicated secret(s) but the repo is LOCKED here."
        info "Paste the git-crypt key to configure them now (or press Enter to skip)."
        secret_unlock || warn "still locked — encrypted secrets will not be deployed"
    fi

    local i type
    i=0
    while [ "$i" -lt "${INTEGRATION_COUNT:-0}" ]; do
        type="$(_f "$i" TYPE)"
        if _applies_here "$i"; then
            case "$type" in
                file)  _deploy_file "$i" ;;
                login) _deploy_login "$i" ;;
                env-token) : ;;  # deployed as a set via _deploy_env_store below
                *) warn "$(_f "$i" ID): unknown type '$type'" ;;
            esac
        fi
        i=$((i + 1))
    done
    _deploy_env_store

    # Don't report success while encrypted secrets were left undeployed: fail
    # loudly so the rc is non-zero (install.sh's `|| log_warn` fires) and the
    # user sees an actionable banner instead of a silent green install.
    locked="$(_secret_locked_count)"
    if [ "$locked" -gt 0 ]; then
        warn "──────────────────────────────────────────────────────────────"
        warn " $locked secret(s) NOT deployed — the repo is LOCKED on this machine."
        warn " Configure replication with your git-crypt key:"
        warn "     mesh secret unlock        # paste the base64 key, then:"
        warn "     mesh secret deploy"
        warn "──────────────────────────────────────────────────────────────"
        return 1
    fi
    return 0
}

# Offer to unlock replicated secrets on this machine.
#
# Called at the END of setup.sh, after the engine has been piped through tee:
# personal/apply runs `secret deploy` early (topic order 30) under that pipe,
# so a prompt there is easy to miss, and NON_INTERACTIVE / a missing TTY skips
# it entirely. Asking here uses the controlling terminal again.
#
# rc0: nothing to unlock, or unlock+deploy succeeded.
# rc1: still locked (headless → critical follow-up; interactive skip → same).
secret_offer_unlock() {
    if [ ! -d "$SECRETS_DIR" ]; then
        return 0
    fi
    if [ ! -f "$MANIFEST" ] && [ ! -f "$ENV_SRC" ]; then
        return 0
    fi

    # Ciphertext manifest still lets _secret_locked_count see secrets.env.
    _manifest_load || true
    local locked
    locked="$(_secret_locked_count)"
    if [ -f "$MANIFEST" ] && _is_ciphertext "$MANIFEST"; then
        locked=$((locked + 1))
    fi
    [ "$locked" -gt 0 ] || return 0

    if [ "${NON_INTERACTIVE:-0}" != "1" ] && [ -e /dev/tty ]; then
        warn "This machine has $locked replicated secret(s) but the identity repo is LOCKED here."
        info "Paste the git-crypt key (from your password manager) to unlock them now."
        if secret_unlock; then
            secret_deploy || return 1
            _secret_retry_moshi_pair
            return 0
        fi
        warn "skipped — secrets stay locked on this machine."
    fi

    followup critical "Replicated secrets are LOCKED on this machine. Run:
    mesh secret unlock
    mesh secret deploy"
    warn "──────────────────────────────────────────────────────────────"
    warn " $locked secret(s) NOT deployed — the repo is LOCKED on this machine."
    warn " Configure replication with your git-crypt key:"
    warn "     mesh secret unlock        # paste the base64 key, then:"
    warn "     mesh secret deploy"
    warn "──────────────────────────────────────────────────────────────"
    return 1
}

# After a late unlock, moshi-hook may already be running unpaired (it installs
# after personal/apply). Best-effort pair from the just-deployed env-token store.
_secret_retry_moshi_pair() {
    [ -r "$ENV_DST" ] || return 0
    set -a
    # shellcheck disable=SC1090
    . "$ENV_DST"
    set +a
    command -v moshi-hook >/dev/null 2>&1 || return 0
    [ -n "${MOSHI_PAIRING_TOKEN:-}" ] || return 0
    if moshi-hook status 2>/dev/null | grep -qi "paired\|connected"; then
        return 0
    fi
    info "pairing moshi-hook with token from secrets.env"
    moshi-hook pair --token "$MOSHI_PAIRING_TOKEN" \
        || followup manual "moshi-hook pairing failed. From the Moshi app (Settings → Integrations): moshi-hook pair --token <TOKEN>"
}

# Deploy the encrypted env-token store to the runtime path the install engine
# sources, so env-token secrets actually reach the tools that read them.
_deploy_env_store() {
    [ -f "$ENV_SRC" ] || return 0
    if _is_ciphertext "$ENV_SRC"; then
        warn "secrets.env still encrypted — run 'mesh secret unlock' first"; return 0
    fi
    mkdir -p "$(dirname "$ENV_DST")"
    # deploy_one needs a repo-relative source; ENV_SRC is "$ID_DIR/secrets/secrets.env".
    deploy_one "secrets/secrets.env|$ENV_DST|overwrite|0600" "$ID_DIR" && ok "env-tokens → $ENV_DST"
}

secret_list() {
    _manifest_load || return 1
    local n="${INTEGRATION_COUNT:-0}"
    if [ "$n" = "0" ]; then info "no integrations declared yet — add one with 'mesh secret add'"; return 0; fi
    printf '%-18s %-5s %-10s %-7s %s\n' "ID" "TIER" "TYPE" "HERE?" "STATUS"
    local i id tier type here src abs status
    i=0
    while [ "$i" -lt "$n" ]; do
        id="$(_f "$i" ID)"; tier="$(_f "$i" TIER)"; type="$(_f "$i" TYPE)"
        if _applies_here "$i"; then here="yes"; else here="no"; fi
        status="-"
        case "$type" in
            file)
                src="$(_f "$i" SOURCE)"; abs="$ID_DIR/$src"
                if [ ! -f "$abs" ]; then status="MISSING"
                elif _is_ciphertext "$abs"; then status="locked"
                else status="ready"; fi ;;
            login)
                if [ -n "$(_f "$i" CHECK)" ] && sh -c "$(_f "$i" CHECK)" >/dev/null 2>&1; then status="authed"; else status="not-authed"; fi ;;
            env-token)
                if [ -f "$ENV_SRC" ] && ! _is_ciphertext "$ENV_SRC" && grep -q "^export $(_f "$i" KEY)=" "$ENV_SRC" 2>/dev/null; then status="set"; else status="unset"; fi ;;
        esac
        printf '%-18s %-5s %-10s %-7s %s\n' "$id" "$tier" "$type" "$here" "$status"
        i=$((i + 1))
    done
    local ahead; ahead="$(_unpushed_count)"
    if [ "$ahead" != "0" ]; then
        warn "$ahead local commit(s) NOT pushed — run 'mesh secret push' to replicate"
    fi
    return 0
}

secret_doctor() {
    local issues=0
    _manifest_load || { return 1; }
    # git-crypt state
    if secrets_crypt_available; then ok "git-crypt installed"; else warn "git-crypt NOT installed (run 'mesh secret init')"; issues=$((issues+1)); fi
    if secrets_crypt_attr_ok "$ID_DIR"; then ok ".gitattributes git-crypt rule present"; else warn ".gitattributes git-crypt rule MISSING"; issues=$((issues+1)); fi
    if secrets_crypt_initialized "$ID_DIR"; then
        if secrets_crypt_unlocked "$ID_DIR"; then ok "repo unlocked (key present)"; else warn "repo LOCKED — run 'mesh secret unlock <keyfile>'"; issues=$((issues+1)); fi
    else
        warn "git-crypt not initialized in $ID_DIR"; issues=$((issues+1))
    fi
    # per-integration drift
    local i type id src abs
    i=0
    while [ "$i" -lt "${INTEGRATION_COUNT:-0}" ]; do
        id="$(_f "$i" ID)"; type="$(_f "$i" TYPE)"
        if _applies_here "$i"; then
            case "$type" in
                file)
                    src="$(_f "$i" SOURCE)"; abs="$ID_DIR/$src"
                    if [ ! -f "$abs" ]; then warn "$id: source file missing ($src)"; issues=$((issues+1));
                    elif _is_ciphertext "$abs"; then warn "$id: source locked (unlock the repo)"; issues=$((issues+1)); fi ;;
                env-token)
                    if [ ! -f "$ENV_SRC" ] || _is_ciphertext "$ENV_SRC" || ! grep -q "^export $(_f "$i" KEY)=" "$ENV_SRC" 2>/dev/null; then
                        warn "$id: env-token $(_f "$i" KEY) declared but not stored/readable"; issues=$((issues+1)); fi ;;
            esac
        fi
        i=$((i + 1))
    done
    local ahead; ahead="$(_unpushed_count)"
    [ "$ahead" != "0" ] && { warn "$ahead commit(s) not pushed (run 'mesh secret push')"; issues=$((issues+1)); }
    if [ "$issues" = "0" ]; then ok "secrets layer healthy"; return 0; fi
    warn "$issues issue(s) found"; return 1
}

# ── wizards (add / set / rm) ─────────────────────────────────────────────────

# Thin wrappers over the standardized prompt module in log.sh (blink-styled,
# reusable). Kept so the wizard call sites stay terse.
_ask() { ask_line "$1" "${2:-}"; }
_ask_secret() { ask_secret "$1"; }
_yn() { confirm "$1"; }

# Append a manifest entry from KEY=VALUE pairs passed as args (id first).
# _manifest_append <id> <field:value>...
_manifest_append() {
    local id="$1"; shift
    { printf '  %s:\n' "$id"
      local kv k v
      for kv in "$@"; do k="${kv%%:*}"; v="${kv#*:}"; printf '    %s: %s\n' "$k" "$v"; done
    } >> "$MANIFEST"
}

secret_add() {
    [ -t 0 ] || [ -e /dev/tty ] || { fail "mesh secret add is interactive (needs a terminal)"; return 1; }
    _manifest_load || return 1
    local id
    id="$(_ask 'Integration id (kebab-case): ')"
    case "$id" in ''|*[!a-zA-Z0-9_-]*) fail "invalid id"; return 1;; esac
    local i=0
    while [ "$i" -lt "${INTEGRATION_COUNT:-0}" ]; do
        [ "$(_f "$i" ID)" = "$id" ] && { fail "'$id' already exists (use 'mesh secret set $id')"; return 1; }
        i=$((i + 1))
    done

    if _yn 'Is there a login screen that generates the token for you?'; then
        # Tier 1 — native login, nothing stored.
        local check login
        check="$(_ask 'Check command (exit 0 = configured), e.g. "gh auth status": ')"
        login="$(_ask 'Login command, e.g. "gh auth login": ')"
        [ -f "$MANIFEST" ] || printf 'version: 1\nintegrations:\n' > "$MANIFEST"
        _manifest_append "$id" "tier:1" "type:login" "check:$check" "login:$login"
        git -C "$ID_DIR" add secrets/manifest.yaml
        info "Tier-1 (login) entry — no secret stored. This will be committed + pushed to $(_remote_url)."
        _yn 'Continue?' || { git -C "$ID_DIR" restore --staged secrets/manifest.yaml 2>/dev/null; warn "aborted"; return 1; }
        _commit_and_push "secret(add): $id (login)"
        return $?
    fi

    # Tier 2 — must be encrypted + replicated.
    _require_git_crypt_ready || return 1
    secrets_crypt_unlocked "$ID_DIR" || { fail "repo is locked — run 'mesh secret unlock' first"; return 1; }

    local kind
    kind="$(_ask 'Type — (1) env token  or  (2) config file? [1/2]: ' 1)"
    if [ "$kind" = "2" ]; then
        # file
        local seed dst_kind resolver destfile destpath src perms
        seed="$(_ask 'Path to the existing local file to import (blank = create empty): ')"
        local relsub; relsub="$(_ask "Store under secrets/ as (e.g. composer/auth.json): ")"
        case "$relsub" in ''|/*|*..*) fail "invalid relative path"; return 1;; esac
        src="secrets/$relsub"
        mkdir -p "$ID_DIR/$(dirname "$src")"
        if [ -n "$seed" ]; then
            [ -f "$seed" ] || { fail "no such file: $seed"; return 1; }
            cp "$seed" "$ID_DIR/$src" || { fail "copy failed"; return 1; }
        else
            : > "$ID_DIR/$src"
        fi
        perms="$(_ask 'File perms [0600]: ' 0600)"
        dst_kind="$(_ask 'Destination — (1) named resolver  or  (2) absolute path? [1/2]: ' 1)"
        if [ "$dst_kind" = "2" ]; then
            destpath="$(_ask 'Absolute dest path (e.g. ~/.npmrc): ')"
            _manifest_append "$id" "tier:2" "type:file" "source:$src" "dest_path:$destpath" "perms:\"$perms\""
        else
            info "Known resolvers: $(secrets_resolver_list | tr '\n' ' ')"
            resolver="$(_ask 'Resolver [composer-home]: ' composer-home)"
            destfile="$(_ask 'Dest filename (e.g. auth.json): ')"
            _manifest_append "$id" "tier:2" "type:file" "source:$src" "dest_resolver:$resolver" "dest_file:$destfile" "perms:\"$perms\""
        fi
        chmod "$perms" "$ID_DIR/$src" 2>/dev/null || true
        git -C "$ID_DIR" add -f "$src" secrets/manifest.yaml .gitattributes 2>/dev/null
    else
        # env token
        local key val
        key="$(_ask 'Env var name (e.g. ANTHROPIC_API_KEY): ')"
        case "$key" in ''|*[!A-Za-z0-9_]*) fail "invalid env var name"; return 1;; esac
        val="$(_ask_secret "Value for $key (hidden): ")"
        [ -n "$val" ] || { fail "empty value"; return 1; }
        mkdir -p "$SECRETS_DIR"
        [ -f "$ENV_SRC" ] || printf '# mesh secrets env-token store (git-crypt encrypted)\n' > "$ENV_SRC"
        # upsert: drop any existing line, append the new one.
        grep -v "^export $key=" "$ENV_SRC" 2>/dev/null > "$ENV_SRC.tmp" || true
        printf 'export %s=%q\n' "$key" "$val" >> "$ENV_SRC.tmp"
        mv "$ENV_SRC.tmp" "$ENV_SRC"; chmod 600 "$ENV_SRC"
        _manifest_append "$id" "tier:2" "type:env-token" "key:$key"
        git -C "$ID_DIR" add -f secrets/secrets.env secrets/manifest.yaml .gitattributes 2>/dev/null
    fi

    info "This secret will be ENCRYPTED with git-crypt and PUSHED to $(_remote_url)."
    if ! secret_guard_staged; then return 1; fi
    _yn 'Continue?' || { warn "aborted — staged changes left in place (review with 'git -C $ID_DIR diff --cached')"; return 1; }
    _commit_and_push "secret(add): $id"
}

# Re-check the fail-closed guard against what is staged (defense in depth before commit).
secret_guard_staged() {
    if secrets_crypt_guard "$ID_DIR"; then return 0; fi
    fail "encryption guard refused the staged secrets — NOT committing (see message above)"
    return 1
}

# Pre-commit guard entry: rc0 safe, rc1 block. Used by the identity pre-commit
# hook so a misconfiguration can never commit a Tier-2 secret in cleartext.
secret_guard() {
    secrets_crypt_guard "$ID_DIR"
}

secret_set() {
    local id="${1:-}"
    [ -n "$id" ] || { fail "usage: mesh secret set <id>"; return 1; }
    [ -e /dev/tty ] || { fail "mesh secret set is interactive (needs a terminal)"; return 1; }
    _manifest_load || return 1
    local i found=-1 type
    i=0
    while [ "$i" -lt "${INTEGRATION_COUNT:-0}" ]; do
        [ "$(_f "$i" ID)" = "$id" ] && { found="$i"; break; }
        i=$((i + 1))
    done
    [ "$found" -ge 0 ] || { fail "no such integration: $id (add it with 'mesh secret add')"; return 1; }
    type="$(_f "$found" TYPE)"
    [ "$type" = "login" ] && { fail "'$id' is a login integration — no stored value (use 'mesh secret rm' + 'add' to change commands)"; return 1; }
    _require_git_crypt_ready || return 1
    secrets_crypt_unlocked "$ID_DIR" || { fail "repo is locked — run 'mesh secret unlock' first"; return 1; }
    if [ "$type" = "env-token" ]; then
        local key val
        key="$(_f "$found" KEY)"
        val="$(_ask_secret "New value for $key (hidden): ")"
        [ -n "$val" ] || { fail "empty value"; return 1; }
        [ -f "$ENV_SRC" ] || printf '# mesh secrets env-token store (git-crypt encrypted)\n' > "$ENV_SRC"
        grep -v "^export $key=" "$ENV_SRC" 2>/dev/null > "$ENV_SRC.tmp" || true
        printf 'export %s=%q\n' "$key" "$val" >> "$ENV_SRC.tmp"
        mv "$ENV_SRC.tmp" "$ENV_SRC"; chmod 600 "$ENV_SRC"
        git -C "$ID_DIR" add -f secrets/secrets.env
    else
        local src seed
        src="$(_f "$found" SOURCE)"
        seed="$(_ask 'Path to the new file contents: ')"
        [ -f "$seed" ] || { fail "no such file: $seed"; return 1; }
        cp "$seed" "$ID_DIR/$src" || { fail "copy failed"; return 1; }
        git -C "$ID_DIR" add -f "$src"
    fi
    info "Updated '$id'. This will be ENCRYPTED with git-crypt and PUSHED to $(_remote_url)."
    secret_guard_staged || return 1
    _yn 'Continue?' || { warn "aborted (staged changes left in place)"; return 1; }
    _commit_and_push "secret(set): $id"
}

secret_rm() {
    local id="${1:-}"
    [ -n "$id" ] || { fail "usage: mesh secret rm <id>"; return 1; }
    _manifest_load || return 1
    local i found=-1 type src
    i=0
    while [ "$i" -lt "${INTEGRATION_COUNT:-0}" ]; do
        [ "$(_f "$i" ID)" = "$id" ] && { found="$i"; break; }
        i=$((i + 1))
    done
    [ "$found" -ge 0 ] || { fail "no such integration: $id"; return 1; }
    type="$(_f "$found" TYPE)"; src="$(_f "$found" SOURCE)"
    # Delete the integration's YAML block: its '  <id>:' line + all indent-4
    # fields until the next indent-2 key (or EOF).
    awk -v id="$id" '
        /^  [A-Za-z0-9_-]+:[ \t]*$/ { skip = ($0 == "  " id ":") ? 1 : 0 }
        skip != 1 { print }
    ' "$MANIFEST" > "$MANIFEST.tmp" && mv "$MANIFEST.tmp" "$MANIFEST"
    git -C "$ID_DIR" add secrets/manifest.yaml 2>/dev/null
    if [ "$type" = "file" ] && [ -n "$src" ] && [ -f "$ID_DIR/$src" ]; then
        git -C "$ID_DIR" rm -q -f "$src" 2>/dev/null || rm -f "$ID_DIR/$src"
    fi
    [ "$type" = "env-token" ] && warn "note: the value of $(_f "$found" KEY) remains in secrets/secrets.env (edit by hand to purge)"
    info "Removing '$id'. This will be committed + pushed to $(_remote_url)."
    _yn 'Continue?' || { warn "aborted (manifest already edited locally — restore with 'git -C $ID_DIR checkout secrets/')"; return 1; }
    _commit_and_push "secret(rm): $id"
}

_usage() {
    cat <<'EOF'
Usage: mesh secret <verb>

  init                 Set up git-crypt + the secrets layer (first machine).
  unlock [keyfile|b64] Decrypt this machine's repo. Pass a key file, a base64
                       key string, or run with no arg to paste the base64 key.
  export-key           Print the root key as base64 (text) for a password
                       manager. Run in a private terminal — prints a secret.
  add                  Add an integration (guided: login | file | env token).
  set <id>             Update a stored value.
  rm <id>              Remove an integration.
  list                 Show integrations + per-machine + replication status.
  doctor               Health / drift checks.
  deploy               Place all enabled Tier-2 files; run pending logins.
  offer-unlock         If secrets exist but are still locked here, ask for the
                       git-crypt key (used at the end of setup.sh). Headless
                       runs record a critical follow-up instead of prompting.
  push                 Push pending commits (after a failed auto-push).

Saved means replicated: add/set/rm commit AND push (and tell you where).
EOF
}

# ── dispatch ─────────────────────────────────────────────────────────────────
verb="${1:-list}"
[ $# -gt 0 ] && shift || true
case "$verb" in
    init)    secret_init "$@" ;;
    unlock)  secret_unlock "$@" ;;
    add)     secret_add "$@" ;;
    set)     secret_set "$@" ;;
    rm)      secret_rm "$@" ;;
    list)    secret_list "$@" ;;
    doctor)  secret_doctor "$@" ;;
    deploy)  secret_deploy "$@" ;;
    offer-unlock) secret_offer_unlock "$@" ;;
    push)    secret_push "$@" ;;
    guard)   secret_guard "$@" ;;
    export-key) secret_export_key "$@" ;;
    -h|--help|help) _usage ;;
    *) fail "unknown verb '$verb'"; _usage; exit 1 ;;
esac
