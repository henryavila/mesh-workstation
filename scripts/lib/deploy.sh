#!/usr/bin/env bash
# scripts/lib/deploy.sh — dual-mode deploy library.
#
# STANDALONE (executed):  bash lib/deploy.sh <templates-dir>
#   Deploys files from a topic's templates/ directory (old DEPLOY-file / auto-map system).
#
# SOURCE (sourced by install-engine):  . lib/deploy.sh
#   Provides the C6 deploy_one() dispatcher + deploy_map()/deploy_map_emit(), the
#   data-file front end identity's install.sh uses (deploy.map → deploy_one).
#   Entry format: "src-rel|dst-abs|mode|perms"  (mode: overwrite | once | managed_block)
#
# Standalone behavior:
#   - If <dir>/DEPLOY exists, reads explicit mappings from it.
#   - Else, uses automatic name-convention mapping.
#   - Files with .template suffix pass through envsubst (requires gettext).
#   - CRLF is stripped from template content.
#   - Existing destination is diffed: no-op if identical, backup-then-overwrite otherwise.
#   - Keeps the 5 most recent backups per destination, pruning older ones.
#   - Destinations outside $HOME trigger sudo (confirmed once at start).

DEPLOY_LIB_DIR="${DEPLOY_LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# shellcheck disable=SC1091
. "$DEPLOY_LIB_DIR/managed-block.sh"
# shellcheck disable=SC1091
. "$DEPLOY_LIB_DIR/perms.sh"

# ---------- C6 source-only API (used when sourced by install-engine) ----------
# deploy_one <entry> <src_base>
#   entry format: "src-rel|dst-abs|mode|perms"  (perms optional, defaults to 0644)
#   mode: overwrite | once | managed_block
deploy_one() {
    local entry="$1" src_base="$2"
    local src dst mode perms
    IFS='|' read -r src dst mode perms <<< "$entry"
    : "${mode:=overwrite}"
    : "${perms:=0644}"
    local src_path="$src_base/$src"
    [[ -r "$src_path" ]] || { echo "[deploy] missing source: $src_path" >&2; return 1; }

    # Refuse to deploy a half-scaffolded source. init.sh substitutes the user
    # tokens (__USER_NAME__/__USER_EMAIL__/__GH_USERNAME__) but leaves the SSH
    # pubkey sentinel for the human to fill in by hand. Deploying it would
    # splice a dead placeholder over real content — e.g. overwrite a live
    # ~/.ssh/authorized_keys and lock every real key out (2026-06-17: a parity
    # init leaked exactly this into a deployed host). Refuse here so no scaffold
    # can clobber a deployed host; the next deploy from a filled source heals it.
    if grep -q '__REPLACE_WITH_YOUR_PUBLIC_KEY__' "$src_path" 2>/dev/null; then
        echo "[deploy] $src_path contains an unfilled scaffold placeholder (__REPLACE_WITH_YOUR_PUBLIC_KEY__); refusing to deploy to $dst" >&2
        return 2
    fi

    mkdir -p "$(dirname "$dst")" || return $?
    case "$mode" in
        overwrite)
            # Reject destination types we cannot safely handle BEFORE any
            # no-op decision (CP4 F-004 + F-005):
            #   - directory: `mv tmp dst` would move tmp INSIDE dst, leaving
            #     the intended file uncreated while reporting success.
            #   - symlink: backup loses the link target and atomic mv would
            #     silently replace the link with a regular file.
            #   - exists but not a regular file (FIFO/socket/device): same
            #     atomic-mv hazard as symlink.
            if [[ -e "$dst" && ! -L "$dst" && ! -f "$dst" ]]; then
                echo "[deploy] $dst exists and is not a regular file (likely directory or special); refusing overwrite" >&2
                return 2
            fi
            if [[ -L "$dst" ]]; then
                echo "[deploy] $dst is a symlink; refusing overwrite (remove or repoint first)" >&2
                return 2
            fi
            # Skip if content already identical — preserves user edits + saves IO.
            # Safe to run AFTER type checks: $dst is now guaranteed regular-file-or-absent.
            if [[ -f "$dst" ]] && cmp -s "$src_path" "$dst" 2>/dev/null; then
                return 0
            fi
            # Backup if dst exists and differs.
            if [[ -f "$dst" ]]; then
                local ts backup
                ts="$(date +%Y%m%d-%H%M%S)"
                backup="${dst}.bak-${ts}"
                cp -p "$dst" "$backup" \
                    || { echo "[deploy] backup failed: $dst → $backup" >&2; return 1; }
            fi
            # Atomic install: write to same-dir temp + rename so concurrent reads
            # never observe a partial file.
            local tmp
            tmp="$(mktemp "$(dirname "$dst")/.deploy.tmp.XXXXXX")" || return 1
            if ! cp "$src_path" "$tmp"; then
                rm -f "$tmp"
                return 1
            fi
            apply_perms "$tmp" "$perms" || { rm -f "$tmp"; return 1; }
            mv "$tmp" "$dst" || { rm -f "$tmp"; return 1; }
            ;;
        once)
            # CP4 F-005: same dst-type guard as overwrite — `cp src dst` where
            # dst is a directory copies into the directory instead of creating
            # the requested file.
            if [[ -e "$dst" && ! -L "$dst" && ! -f "$dst" ]]; then
                echo "[deploy] $dst exists and is not a regular file (likely directory or special); refusing once" >&2
                return 2
            fi
            if [[ -f "$dst" ]]; then
                echo "[deploy] $dst exists; skipping (mode=once)"
            else
                cp "$src_path" "$dst" || return $?
                apply_perms "$dst" "$perms" || return $?
            fi
            ;;
        managed_block)
            # CP4 F-005: same dst-type guard. managed_block_apply operates on
            # a regular file; targeting a directory or special would error in
            # confusing ways downstream.
            if [[ -e "$dst" && ! -L "$dst" && ! -f "$dst" ]]; then
                echo "[deploy] $dst exists and is not a regular file (likely directory or special); refusing managed_block" >&2
                return 2
            fi
            # managed_block edits the destination in-place; symlinks would mutate
            # the target file (often a system file), which is never what's wanted.
            if [[ -L "$dst" ]]; then
                echo "[deploy] $dst is a symlink; refusing managed_block edit" >&2
                return 2
            fi
            local slot="$src"
            managed_block_apply "$dst" "$slot" < "$src_path" || return $?
            apply_perms "$dst" "$perms" || return $?
            ;;
        *)
            echo "[deploy] unknown mode: $mode" >&2; return 64
            ;;
    esac
}

# Trim leading + trailing whitespace (bash 3.2-safe; no ${v//} surprises).
_deploy_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# deploy_map_emit <map-file>
#   Parse a `deploy.map` data file and emit one normalized entry per valid line
#   as "src|dst|mode|perms" (empty mode/perms → deploy_one applies its defaults;
#   dst is fully expanded; all fields trimmed). Blank lines and #-comments are
#   skipped; a malformed line is warned + skipped.
#
#   This is the SINGLE SOURCE OF TRUTH for the deploy.map grammar. Both consumers
#   read through it so the parse can never fork: deploy_map() (deploys) and
#   doctor.sh (drift-checks). The sourced deploy_one expects a pre-expanded dst
#   (unlike the standalone expand_dst path), so this expands the tokens a human
#   naturally writes in a data file: `~`, `$HOME`/`${HOME}`, `$USER`/`${USER}`.
#   Destinations live under $HOME, so that set suffices; extend here if needed.
deploy_map_emit() {
    local map="$1"
    [[ -r "$map" ]] || { echo "[deploy] deploy.map not readable: $map" >&2; return 1; }
    local line trimmed src dst mode perms
    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        trimmed="${line#"${line%%[![:space:]]*}"}"
        [[ -z "$trimmed" || "$trimmed" == '#'* ]] && continue
        IFS='|' read -r src dst mode perms <<< "$line"
        src="$(_deploy_trim "$src")";   dst="$(_deploy_trim "$dst")"
        mode="$(_deploy_trim "$mode")"; perms="$(_deploy_trim "$perms")"
        if [[ -z "$src" || -z "$dst" ]]; then
            echo "[deploy] malformed deploy.map line (need at least src|dst): $line" >&2
            continue
        fi
        dst="${dst/#\~/$HOME}"
        dst="${dst//\$\{HOME\}/$HOME}"; dst="${dst//\$HOME/$HOME}"
        dst="${dst//\$\{USER\}/$USER}"; dst="${dst//\$USER/$USER}"
        printf '%s|%s|%s|%s\n' "$src" "$dst" "$mode" "$perms"
    done < "$map"
}

# deploy_map <map-file> <src-base>
#   Data-file front end to deploy_one: deploy every entry in a deploy.map. This
#   is what lets a human add a replicated file by editing DATA, never code
#   (human-without-AI rule, [[human-manageable-manifest-default]]): identity's
#   install.sh reduces to `deploy_map deploy.map .`.
#
#   Returns non-zero if the map is unreadable, or if ANY entry failed (every
#   entry is still attempted, so one bad line never silently skips the rest).
deploy_map() {
    local map="$1" src_base="$2" rc=0 entry
    [[ -r "$map" ]] || { echo "[deploy] deploy.map not readable: $map" >&2; return 1; }
    while IFS= read -r entry; do
        deploy_one "$entry" "$src_base" || rc=1
    done < <(deploy_map_emit "$map")
    return "$rc"
}

# Return when sourced — do not execute standalone script logic.
[[ "${BASH_SOURCE[0]}" != "${0}" ]] && return 0

# ---------- Standalone script mode (executed directly) ----------
set -euo pipefail

SCRIPT_DIR="$DEPLOY_LIB_DIR"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/log.sh"

templates_dir="${1:-}"
if [[ -z "$templates_dir" ]] || [[ ! -d "$templates_dir" ]]; then
    fail "deploy.sh: templates dir missing or not a directory: $templates_dir"
    exit 1
fi

# Ensure envsubst is available for .template files
if ! command -v envsubst >/dev/null 2>&1; then
    fail "envsubst not found (install gettext / gettext-base before running topics with templates)"
    exit 1
fi

sudo_needed=0
# Explicit empty init rather than `declare -a mapping_src mapping_dst` because
# bash 3.2 (macOS default) leaves `declare -a foo` as "declared but unbound",
# and the first `"${#mapping_src[@]}"` check at line ~145 would trip set -u.
mapping_src=()
mapping_dst=()

# Variables allowed in template substitution. Restricting the set keeps
# envsubst from mangling unrelated $tokens (e.g. nginx's $project capture,
# shell positional $1, php's $_SERVER). Add here if a new topic needs more.
ENVSUBST_ALLOWLIST='${USER} ${HOME} ${BREW_PREFIX} ${CODE_DIR} ${MESH_IDENTITY_DIR} ${NGINX_CONF_DIR} ${NGINX_AVAILABLE_DIR} ${NGINX_ENABLED_DIR} ${NGINX_SNIPPET_DIR} ${NGINX_MAP_DIR} ${CERT_DIR} ${PHP_DEFAULT} ${DEV_DEFAULT_PORT}'

# ---------- Build mapping list ----------

expand_dst() {
    # Resolve ~ and allowlisted ${VARS} in the destination path only.
    local raw="$1"
    raw="${raw/#\~/$HOME}"
    printf '%s' "$raw" | envsubst "$ENVSUBST_ALLOWLIST"
}

check_no_empty_refs() {
    # Returns 1 and logs if $raw references any ${VAR} that is currently empty.
    # Used to avoid catastrophic destinations like "/catchall.conf" from an unset var.
    local raw="$1" src_label="$2"
    local rest="$raw" vname missing=0
    while [[ "$rest" =~ \$\{([A-Za-z_][A-Za-z0-9_]*)\} ]]; do
        vname="${BASH_REMATCH[1]}"
        if [[ -z "${!vname:-}" ]]; then
            fail "deploy.sh: DEPLOY references \${$vname} but it is empty (src=$src_label, raw=$raw)"
            missing=1
        fi
        rest="${rest//${BASH_REMATCH[0]}/}"
    done
    return "$missing"
}

refuse_local_suffix() {
    # Invariant: *.local FILENAMES are reserved for user overrides — they
    # are loaded last by the rc files and are **never** managed by the
    # bootstrap. A template or DEPLOY destination whose BASENAME ends in
    # .local would silently clobber user customizations on every re-run.
    #
    # Gotcha the earlier pattern hit: `*/.local/*` matched the XDG-standard
    # directory `~/.local/bin/` and rejected legitimate CLI deploy targets
    # (link-project, php-use, share-project). The rule is about filename
    # suffix, NOT about the presence of a `.local` path component.
    #
    # Implementation: strip everything up to the last `/` and match only
    # the basename. This cleanly separates:
    #   REFUSE: ~/.bashrc.local       (basename .bashrc.local)
    #   REFUSE: ~/config.local.example (basename config.local.example)
    #   REFUSE: ~/.local               (basename .local — destination file)
    #   ALLOW:  ~/.local/bin/foo       (basename foo)
    #   ALLOW:  ~/.local/share/fnm/fnm (basename fnm)
    local what="$1" value="$2"
    local base="${value##*/}"
    case "$base" in
        *.local|*.local.*)
            # `*.local` covers `.local` too (glob `*` matches empty), so
            # no separate `.local` arm is needed (shellcheck SC2221/2222).
            fail "deploy.sh: refusing $what '$value' with .local-suffix filename."
            fail "  The basename ($base) ends in .local, which is reserved for"
            fail "  user overrides (loaded last, never managed by mesh-workstation)."
            fail "  Rename the template, or use a non-.local destination name."
            exit 1
            ;;
    esac
}

auto_map_name() {
    # Given a filename inside templates/ (no dir prefix, .template already stripped),
    # return absolute destination path or empty string if no auto-match.
    local name="$1"
    case "$name" in
        bashrc)                         printf '%s/.bashrc' "$HOME" ;;
        zshrc)                          printf '%s/.zshrc' "$HOME" ;;
        inputrc)                        printf '%s/.inputrc' "$HOME" ;;
        tmux.conf)                      printf '%s/.tmux.conf' "$HOME" ;;
        starship.toml)                  printf '%s/.config/starship.toml' "$HOME" ;;
        bashrc.d-*.sh)
            local rest="${name#bashrc.d-}"
            printf '%s/.bashrc.d/%s' "$HOME" "$rest"
            ;;
        zshrc.d-*.sh)
            local rest="${name#zshrc.d-}"
            printf '%s/.zshrc.d/%s' "$HOME" "$rest"
            ;;
        bin/*)
            local rest="${name#bin/}"
            printf '%s/.local/bin/%s' "$HOME" "$rest"
            ;;
        zsh-site-functions/*)
            local rest="${name#zsh-site-functions/}"
            printf '%s/.local/share/zsh/site-functions/%s' "$HOME" "$rest"
            ;;
        *)
            printf ''
            ;;
    esac
}

if [[ -f "$templates_dir/DEPLOY" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim trailing whitespace
        line="${line%$'\r'}"
        # Skip blank lines and comments
        [[ -z "${line// }" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue

        src="${line%%=*}"
        dst="${line#*=}"
        src="${src#"${src%%[![:space:]]*}"}"
        src="${src%"${src##*[![:space:]]}"}"
        dst="${dst#"${dst%%[![:space:]]*}"}"
        dst="${dst%"${dst##*[![:space:]]}"}"

        if [[ -z "$src" ]] || [[ -z "$dst" ]]; then
            warn "deploy.sh: malformed DEPLOY line: $line"
            continue
        fi

        if [[ ! -f "$templates_dir/$src" ]]; then
            warn "deploy.sh: DEPLOY src not found: $src"
            continue
        fi

        if ! check_no_empty_refs "$dst" "$src"; then
            exit 1
        fi

        refuse_local_suffix "DEPLOY src" "$src"
        refuse_local_suffix "DEPLOY dst" "$dst"

        expanded_dst="$(expand_dst "$dst")"
        mapping_src+=("$src")
        mapping_dst+=("$expanded_dst")
    done < "$templates_dir/DEPLOY"
else
    while IFS= read -r -d '' src_path; do
        rel="${src_path#"$templates_dir"/}"
        # Skip DEPLOY itself even if absent (defensive)
        [[ "$rel" == "DEPLOY" ]] && continue
        refuse_local_suffix "template" "$rel"
        # Derive destination name (strip .template suffix if present)
        name="${rel%.template}"
        dst="$(auto_map_name "$name")"
        if [[ -z "$dst" ]]; then
            warn "deploy.sh: no auto-mapping for '$rel' (add DEPLOY file or rename)"
            continue
        fi
        mapping_src+=("$rel")
        mapping_dst+=("$dst")
    done < <(find "$templates_dir" -mindepth 1 -type f -print0)
fi

if [[ "${#mapping_src[@]}" -eq 0 ]]; then
    info "deploy.sh: nothing to deploy from $templates_dir"
    exit 0
fi

# ---------- Detect if sudo will be needed ----------

# A destination needs sudo only when the current user cannot write it — NOT
# merely because it lives outside $HOME. Homebrew prefixes (custom paths like
# /Volumes/External/homebrew, or canonical /opt/homebrew on Apple Silicon) are
# user-owned, so valet's nginx config under $BREW_PREFIX/etc deploys without
# sudo; genuine system paths (/etc/nginx on WSL) still escalate. Tests the
# target file if it exists, else its nearest existing ancestor directory.
# Returns 0 (true) when sudo IS needed, 1 (false) otherwise.
_dst_needs_sudo() {
    local d="$1"
    if [[ -e "$d" ]]; then
        [[ -w "$d" ]] && return 1 || return 0
    fi
    d="$(dirname "$d")"
    while [[ ! -e "$d" ]]; do
        local parent; parent="$(dirname "$d")"
        [[ "$parent" == "$d" ]] && break
        d="$parent"
    done
    [[ -w "$d" ]] && return 1 || return 0
}

for dst in "${mapping_dst[@]}"; do
    if _dst_needs_sudo "$dst"; then
        sudo_needed=1
        break
    fi
done

if [[ "$sudo_needed" -eq 1 ]]; then
    info "deploy.sh: destinations outside \$HOME detected — sudo required"
    # Prefer `sudo -n true` (actual command). Bare `sudo -v` hangs on WSL pts
    # when %sudo requires a password (verifypw=all), even with NOPASSWD:ALL.
    if sudo -n true >/dev/null 2>&1; then
        :
    elif [[ "${NON_INTERACTIVE:-0}" == "1" ]]; then
        fail "deploy.sh: sudo authentication required, but NON_INTERACTIVE=1 disables password prompts"
        fail "Run sudo -v in your terminal, then re-run the installation in that same terminal."
        exit 1
    elif ( : </dev/tty ) 2>/dev/null; then
        # setup.sh pipes the engine through tee: stdout is not a TTY even
        # when an operator is present. Use the controlling terminal for sudo.
        if ! sudo -v </dev/tty; then
            fail "deploy.sh: sudo authentication failed or was cancelled; re-run and authorize sudo to deploy system files"
            exit 1
        fi
    else
        fail "deploy.sh: sudo authentication required, but no controlling terminal is available"
        fail "Run the installation from an interactive terminal and authorize sudo when prompted."
        exit 1
    fi
fi

# ---------- Deploy each file ----------

tmp_staging="$(mktemp -d)"
trap 'rm -rf "$tmp_staging"' EXIT

deploy_one() {
    local src_rel="$1" dst="$2"
    local src_abs="$templates_dir/$src_rel"
    local staged
    staged="$tmp_staging/$(basename "$src_rel")"

    # Read, strip CRLF, and optionally run envsubst (allowlist only)
    if [[ "$src_rel" == *.template ]]; then
        tr -d '\r' < "$src_abs" | envsubst "$ENVSUBST_ALLOWLIST" > "$staged"
    else
        tr -d '\r' < "$src_abs" > "$staged"
    fi

    local dst_dir
    dst_dir="$(dirname "$dst")"

    local needs_sudo=0
    if _dst_needs_sudo "$dst"; then
        needs_sudo=1
    fi

    # Ensure target dir exists
    if [[ ! -d "$dst_dir" ]]; then
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo mkdir -p "$dst_dir"
        else
            mkdir -p "$dst_dir"
        fi
    fi

    # Diff or place
    if [[ -e "$dst" ]]; then
        if cmp -s "$staged" "$dst"; then
            ok "$dst up to date"
            return 0
        fi

        # Safety check: refuse to overwrite user-facing rc files that lack
        # our 'managed by mesh-workstation' marker. Fragments in *.d/ dirs and
        # scripts in .local/bin/ are considered bootstrap-owned by convention
        # and skip the check. Escape hatch: ALLOW_OVERWRITE_UNMANAGED=1.
        # Context: prevents the shell-terminal regression where a user's handcrafted
        # .zshrc with a custom Homebrew block was overwritten by the template
        # on first bootstrap run, silently losing the override.
        local needs_header_check=1
        case "$dst" in
            */.bashrc.d/*|*/.zshrc.d/*|*/.local/bin/*)
                needs_header_check=0 ;;
        esac

        # "Safe to replace" bypass — two heuristics for detecting that $dst has
        # no user-authored content to preserve, so the missing marker is not a
        # red flag. Both live here so the user never needs to know about
        # ALLOW_OVERWRITE_UNMANAGED for the fresh-machine install path.
        #
        #   (a) /etc/skel identity (Linux/WSL): useradd seeds $HOME from
        #       /etc/skel. Those copies carry no marker — they never will,
        #       they're distro defaults. Byte-identical to the skel original
        #       ⇒ nothing of the user's is at risk.
        #
        #   (b) Empty file (Mac + fallback for any OS): macOS has no /etc/skel
        #       and useradd writes nothing into $HOME, but Terminal.app
        #       sometimes auto-creates an empty ~/.zshrc on first launch. A
        #       zero-byte file has trivially nothing to preserve regardless
        #       of which process touched it.
        local looks_unowned=0
        if [[ "$needs_header_check" == "1" ]]; then
            if [[ -d /etc/skel ]] && [[ "$dst" == "$HOME"/* ]]; then
                local skel_equiv="/etc/skel/${dst#"$HOME"/}"
                if [[ -f "$skel_equiv" ]] && cmp -s "$dst" "$skel_equiv"; then
                    looks_unowned=1
                    info "$dst matches /etc/skel default — safe to replace"
                fi
            fi
            if [[ "$looks_unowned" != "1" ]] && [[ ! -s "$dst" ]]; then
                looks_unowned=1
                info "$dst is empty — safe to replace"
            fi
        fi

        if [[ "$needs_header_check" == "1" ]] \
             && [[ "$looks_unowned" != "1" ]] \
             && [[ "${ALLOW_OVERWRITE_UNMANAGED:-0}" != "1" ]] \
             && ! grep -qiE "managed by (mesh-workstation|dev-bootstrap)" "$dst" 2>/dev/null; then
            # Persist the staged content so the user can diff it. tmp_staging/
            # is cleared when deploy.sh exits; /tmp survives until reboot.
            local inspect_path
            inspect_path="/tmp/mesh-workstation-would-overwrite-$(basename "$dst")-$$"
            cp "$staged" "$inspect_path" 2>/dev/null || true
            fail "refusing to overwrite $dst — no 'managed by mesh-workstation' marker."
            fail "This file has user-authored content. Options:"
            fail "  1. Move custom blocks to ${dst}.local (never overwritten), delete $dst, re-run."
            fail "  2. Review the template that would replace it:"
            fail "       diff -u \"$dst\" \"$inspect_path\""
            return 1
        fi

        local ts
        ts="$(date +%Y%m%d-%H%M%S)"
        local backup="${dst}.bak-${ts}"
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo cp -p "$dst" "$backup"
        else
            cp -p "$dst" "$backup"
        fi
        info "backed up previous $dst → $backup"
        prune_backups "$dst" "$needs_sudo"
    fi

    if [[ "$needs_sudo" -eq 1 ]]; then
        sudo cp "$staged" "$dst"
    else
        cp "$staged" "$dst"
    fi

    # Make scripts under ~/.local/bin/ and bin/ executable
    if [[ "$dst" == "$HOME/.local/bin/"* ]] || [[ "$src_rel" == bin/* ]]; then
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo chmod +x "$dst"
        else
            chmod +x "$dst"
        fi
    fi

    ok "deployed $dst"
}

prune_backups() {
    local dst="$1" needs_sudo="$2"
    local dir base pattern
    dir="$(dirname "$dst")"
    base="$(basename "$dst")"
    pattern="${base}.bak-*"

    # Retention: keep the 5 newest backups + the single oldest. The oldest
    # is protected because it typically captures the pre-bootstrap state
    # (the user's handwritten config from before mesh-workstation managed this
    # file) — losing it means losing the only restore point for customizations
    # that predate the migration. Re-runs of bootstrap churn the middle of
    # the backup stack; newest+oldest retention keeps both recent history
    # and the archaeological root.
    local all_files
    # shellcheck disable=SC2012
    all_files="$(ls -1t "$dir"/$pattern 2>/dev/null || true)"
    if [[ -z "$all_files" ]]; then
        return 0
    fi
    local total
    total="$(printf '%s\n' "$all_files" | wc -l | tr -d ' ')"
    # Nothing to prune if total ≤ 6 (5 newest + oldest already covered)
    if [[ "$total" -le 6 ]]; then
        return 0
    fi
    # Delete indices 6 through (total-1) — preserves 1..5 (newest) and total (oldest)
    local old_files
    old_files="$(printf '%s\n' "$all_files" | sed -n "6,$((total-1))p")"
    if [[ -z "$old_files" ]]; then
        return 0
    fi
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        if [[ "$needs_sudo" -eq 1 ]]; then
            sudo rm -f "$f"
        else
            rm -f "$f"
        fi
    done <<< "$old_files"
}

for i in "${!mapping_src[@]}"; do
    deploy_one "${mapping_src[$i]}" "${mapping_dst[$i]}"
done
