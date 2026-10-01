#!/usr/bin/env bash
# scripts/runners/ai.sh — `mesh ai`: open an AI agent in the right repo via herdr.
#
# herdr (the agent multiplexer) only knows already-OPEN workspaces and has no
# fuzzy discovery of the repos on disk across roots. This verb fills that gap:
# it discovers your repos (multi-root), then hands the chosen project to herdr —
# focus its workspace if already open, else create one at its dir and launch the
# agent in it.
#
# Usage:
#   mesh ai [term]            Open the project matching <term>; single match opens
#                             directly, multiple → picker, none → error.
#   mesh ai                   No term → searchable picker (open workspaces + repos).
#                             Picker keys: Enter = saved default · Tab = actions
#                             for the highlighted repo · Ctrl-P = local prefs.
#   mesh ai <term> --agent X  Use agent X (grok|claude|codex|gemini); remembered per project.
#   mesh ai <term> --grok     Shortcut for --agent grok.
#   mesh ai <term> --codex    Shortcut for --agent codex.
#   mesh ai <term> --shell    Open the project directory without running an agent.
#   mesh ai <term> --files    Open Yazi as a herdr overlay picker on the project.
#   mesh ai --list            Print the merged catalogue (discovered + pinned) and exit.
#   mesh ai add <path> [name] Pin a dir to the catalogue (non-git OK; idempotent).
#                            If the manifest is in git, offers to commit+push.
#   mesh ai remove <name>     Unpin by name; also offers commit+push when in git.
#   mesh ai list              Show pinned projects resolvable on this host.
# Flags: --agent <name>, --grok, --claude, --codex, --shell/--dir, --files, --list, -h/--help.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/log.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/ai-discover.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/ai-herdr.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/ai-agent.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/ai-pinned.sh"
# shellcheck disable=SC1091
. "$REPO/scripts/lib/ai-prefs.sh"
# Honor per-host config (CODE_DIR, optional AI_ROOTS) so discovery roots match
# what the interactive shell uses.
if [[ -r "$HOME/.config/mesh/config.env" ]]; then
    # shellcheck disable=SC1091
    . "$HOME/.config/mesh/config.env"
fi
ai_prefs_load

# ─── merged catalogue: discovered (auto) + pinned (explicit) ────────────────
# Pinned entries (read from $MESH_AI_PINNED via ai_pinned) come FIRST so a pin
# WINS on a name collision with a discovered repo — it is the explicit override.
# Dedup is by name (col 1). Optional substring filter on the name, mirroring
# ai_match. Emits `name<TAB>path`.
ai_catalogue() {
    local term="${1:-}" lc=""
    [[ -n "$term" ]] && lc="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
    { ai_pinned; ai_discover; } | awk -F'\t' -v lc="$lc" \
        '!seen[$1]++ && (lc == "" || index(tolower($1), lc))'
}

# ─── pinned-manifest editor verbs ────────────────────────────────────────────
# Generic edit logic over whatever path $MESH_AI_PINNED resolves to; knows no
# personal paths (the default mirrors personal-clone.sh's identity fallback).
_ai_pinned_file() {
    printf '%s' "${MESH_AI_PINNED:-${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/shell/ai-pinned.list}"
}

_ai_pin_git_root() {
    local file="$1" dir
    dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || return 1
    git -C "$dir" rev-parse --show-toplevel 2>/dev/null
}

_ai_pin_relpath() {
    local repo="$1" file="$2" dir abs
    dir="$(cd "$(dirname "$file")" 2>/dev/null && pwd -P)" || return 1
    abs="$dir/$(basename "$file")"
    case "$abs" in
        "$repo"/*) printf '%s' "${abs#"$repo"/}" ;;
        *) return 1 ;;
    esac
}

_ai_pin_has_local_change() {
    local repo="$1" rel="$2"
    if ! git -C "$repo" diff --quiet -- "$rel" 2>/dev/null; then
        return 0
    fi
    if ! git -C "$repo" diff --cached --quiet -- "$rel" 2>/dev/null; then
        return 0
    fi
    [[ -z "$(git -C "$repo" ls-files --others --exclude-standard -- "$rel" 2>/dev/null)" ]] && return 1
    return 0
}

_ai_pin_quote_sq() {
    printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

_ai_pin_commit_msg() {
    local action="$1" name="$2"
    case "$action" in
        add)    printf 'chore(identity): pin %s for mesh ai' "$name" ;;
        update) printf 'chore(identity): update mesh ai pin %s' "$name" ;;
        remove) printf 'chore(identity): unpin %s from mesh ai' "$name" ;;
        *)      printf 'chore(identity): update mesh ai pins' ;;
    esac
}

_ai_pin_commit_and_push() {
    local repo="$1" rel="$2" msg="$3" remote staged_other
    staged_other="$(git -C "$repo" diff --cached --name-only -- . 2>/dev/null | awk -v rel="$rel" '$0 != rel { print; exit }')"
    if [[ -n "$staged_other" ]]; then
        log_warn "ai: cannot auto-commit because the identity index already has staged changes ($staged_other)."
        log_warn "ai: saved only locally; commit/push it manually after handling the staged work."
        return 3
    fi

    git -C "$repo" add -- "$rel" || { log_error "ai: git add failed for $rel"; return 1; }
    if git -C "$repo" diff --cached --quiet -- "$rel"; then
        log_info "ai: pin manifest already committed"
        return 0
    fi
    git -C "$repo" commit -q -m "$msg" -- "$rel" || { log_error "ai: commit failed"; return 1; }

    remote="$(git -C "$repo" remote get-url origin 2>/dev/null || true)"
    if git -C "$repo" push -q 2>/dev/null; then
        log_info "ai: pin manifest committed and pushed to ${remote:-origin}"
        return 0
    fi

    log_warn "ai: committed locally, but PUSH FAILED — it is NOT yet replicated."
    log_warn "ai: fix connectivity/auth, then run: git -C $(_ai_pin_quote_sq "$repo") push"
    return 3
}

_ai_pin_offer_persist() {
    local action="$1" name="$2" file="$3" repo rel msg repo_q rel_q
    repo="$(_ai_pin_git_root "$file")" || return 0
    rel="$(_ai_pin_relpath "$repo" "$file")" || return 0
    _ai_pin_has_local_change "$repo" "$rel" || return 0

    msg="$(_ai_pin_commit_msg "$action" "$name")"
    repo_q="$(_ai_pin_quote_sq "$repo")"
    rel_q="$(_ai_pin_quote_sq "$rel")"

    log_warn "ai: $rel saved only locally in $repo; it is not replicated yet."
    log_info "ai: Commitar e enviar '$rel' agora?"
    if confirm "Commitar e enviar '$rel' agora?" n; then
        _ai_pin_commit_and_push "$repo" "$rel" "$msg"
        return $?
    fi

    log_warn "ai: saved only locally. To replicate later, run:"
    log_warn "    git -C $repo_q add $rel_q"
    log_warn "    git -C $repo_q commit -m $(_ai_pin_quote_sq "$msg")"
    log_warn "    git -C $repo_q push"
    return 0
}

_ai_verb_add() {
    local path="${1:-}" name="${2:-}"
    [[ -n "$path" ]] || { log_error "ai add: missing <path> (usage: mesh ai add <path> [name])"; return 2; }
    path="${path/#\~/$HOME}"
    path="$(cd "$path" 2>/dev/null && pwd)" || { log_error "ai add: path not found: $1"; return 2; }
    [[ -n "$name" ]] || name="$(basename "$path")"
    local file; file="$(_ai_pinned_file)"
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        # shellcheck disable=SC2016  # \n is printf syntax, not shell expansion
        printf '# shell/ai-pinned.list — manually pinned projects for `mesh ai`.\n# Format: <name>|<path[:alt-path[:...]]>\n\n' > "$file"
    fi
    local existed=0 tmp
    awk -F'|' -v n="$name" '$1==n{f=1} END{exit f?0:1}' "$file" && existed=1
    tmp="$(mktemp -t mesh-ai-pin.XXXXXX)"
    # Upsert: the line for this name appears exactly once with the new path, in
    # its first original position (or appended if new). String-exact field match.
    awk -F'|' -v n="$name" -v p="$path" '
        $1==n { if (!e) { print n "|" p; e=1 } next }
        { print }
        END { if (!e) print n "|" p }
    ' "$file" > "$tmp"
    mv "$tmp" "$file"
    if (( existed )); then
        log_info "ai: updated pin '$name' → $path"
        _ai_pin_offer_persist update "$name" "$file"
    else
        log_info "ai: pinned '$name' → $path"
        _ai_pin_offer_persist add "$name" "$file"
    fi
}

_ai_verb_remove() {
    local name="${1:-}"
    [[ -n "$name" ]] || { log_error "ai remove: missing <name>"; return 2; }
    local file; file="$(_ai_pinned_file)"
    [[ -f "$file" ]] || { log_error "ai remove: manifest not found: $file"; return 2; }
    local existed=0 tmp
    awk -F'|' -v n="$name" '$1==n{f=1} END{exit f?0:1}' "$file" && existed=1
    (( existed )) || { log_error "ai remove: no pin named '$name'"; return 1; }
    tmp="$(mktemp -t mesh-ai-pin.XXXXXX)"
    awk -F'|' -v n="$name" '$1!=n' "$file" > "$tmp"
    mv "$tmp" "$file"
    log_info "ai: removed pin '$name'"
    _ai_pin_offer_persist remove "$name" "$file"
}

_ai_verb_list() {
    ai_pinned
}

# Sub-verbs routed BEFORE the flag loop so `mesh ai add …` isn't parsed as a
# search term. `mesh ai -- add` still searches literally for "add" (the `--`
# handler below sets TERM_ARG after this block falls through).
case "${1:-}" in
    add)    shift; _ai_verb_add "$@"; exit $? ;;
    remove) shift; _ai_verb_remove "$@"; exit $? ;;
    list)   shift; _ai_verb_list "$@"; exit $? ;;
esac

AGENT_OVERRIDE=""; FORCE_SHELL=0; FORCE_FILES=0; LIST=0; CANDIDATES=0; TERM_ARG=""
while (( $# > 0 )); do
    case "$1" in
        --agent)      shift; AGENT_OVERRIDE="${1:-}" ;;
        --agent=*)    AGENT_OVERRIDE="${1#*=}" ;;
        --grok)       AGENT_OVERRIDE="grok" ;;
        --claude)     AGENT_OVERRIDE="claude" ;;
        --codex)      AGENT_OVERRIDE="codex" ;;
        --shell|--dir) FORCE_SHELL=1 ;;
        --files)      FORCE_FILES=1 ;;
        --list)       LIST=1 ;;
        --candidates) CANDIDATES=1 ;;   # debug: dump the merged candidate set
        -h|--help)    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        --)         shift; [[ $# -gt 0 ]] && TERM_ARG="$1" ;;
        -*)         log_error "ai: unknown flag '$1' (try --agent <name> --grok --codex --shell --files --list --help)"; exit 2 ;;
        *)          TERM_ARG="$1" ;;
    esac
    shift
done

if (( LIST )); then
    ai_catalogue "$TERM_ARG"
    exit 0
fi

# Open a disk repo (name+path) with the resolved agent; remember --agent choices.
_ai_open_repo() {
    local name="$1" path="$2" agent agent_cmd
    agent="$(ai_agent_resolve "$name" "$AGENT_OVERRIDE")"
    [[ -n "$AGENT_OVERRIDE" ]] && ai_agent_set "$name" "$agent"
    agent_cmd="$(ai_agent_cmd "$agent")"
    ai_herdr_open "$name" "$path" "$agent_cmd"
}

_ai_open_agent_explicit() {
    local name="$1" path="$2" wsid="$3" agent="$4" remember="${5:-0}" agent_cmd
    (( remember )) && ai_agent_set "$name" "$agent"
    agent_cmd="$(ai_agent_cmd "$agent")"
    if [[ -n "$wsid" ]]; then
        ai_herdr_new_tab "$wsid" "$path" "$name" "$agent_cmd"
    else
        ai_herdr_open "$name" "$path" "$agent_cmd"
    fi
}

_ai_open_shell() {
    local name="$1" path="$2" wsid="$3"
    if [[ -n "$wsid" ]]; then
        ai_herdr_new_tab "$wsid" "$path" "$name" ""
    else
        ai_herdr_open "$name" "$path" ""
    fi
}

_ai_open_files() {
    local name="$1" path="$2" wsid="$3"
    ai_herdr_open_files "$name" "$path" "$wsid"
}

# Build the MERGED candidate set, one `label<TAB>path<TAB>wsid<TAB>status<TAB>tabid`
# row:
#   • an open herdr workspace whose label matches a discovered repo → ONE row
#     carrying the repo path + the workspace id + status (no duplicate);
#   • an open workspace with no matching repo (e.g. a branch-named workspace in a
#     git worktree) → its pane cwd as the path, so you still see WHICH project;
#   • for a workspace with >1 tab, ALSO one `<ws> › <tab>` row per tab carrying
#     its tab_id — so you can search a task name and jump straight to that tab;
#   • a discovered repo with no open workspace → path only, empty wsid.
# tabid set ⇒ focus that tab; else wsid set ⇒ focus workspace; else ⇒ create.
_ai_candidates() {
    local repos open_ws label wsid status path name tabs ntabs tid tlabel tstatus
    repos="$(ai_catalogue)"
    open_ws=""
    ai_herdr_ready 2>/dev/null && open_ws="$(ai_herdr_workspaces)"

    # Open workspaces (deduped against disk by label), each optionally expanded
    # into its tabs.
    while IFS=$'\t' read -r label wsid status; do
        [[ -n "$label" ]] || continue
        path="$(printf '%s\n' "$repos" | awk -F'\t' -v n="$label" '$1 == n { print $2; exit }')"
        [[ -n "$path" ]] || path="$(ai_herdr_workspace_cwd "$wsid")"
        printf '%s\t%s\t%s\t%s\t\n' "$label" "$path" "$wsid" "$status"

        tabs="$(ai_herdr_tabs "$wsid")"
        ntabs="$(printf '%s' "$tabs" | awk 'NF{n++} END{print n+0}')"
        if (( ntabs > 1 )); then
            while IFS=$'\t' read -r tid tlabel tstatus; do
                [[ -n "$tid" ]] || continue
                printf '%s › %s\t%s\t%s\t%s\t%s\n' "$label" "$tlabel" "$path" "$wsid" "$tstatus" "$tid"
            done <<<"$tabs"
        fi
    done <<<"$open_ws"

    # Discovered repos with no open workspace of the same name.
    while IFS=$'\t' read -r name path; do
        [[ -n "$name" ]] || continue
        printf '%s\n' "$open_ws" | awk -F'\t' -v n="$name" '$1 == n { found = 1 } END { exit !found }' \
            || printf '%s\t%s\t\t\t\n' "$name" "$path"
    done <<<"$repos"
}

# Filter merged rows by a case-insensitive substring on the label (col 1). Empty
# term passes everything through.
_ai_filter() {
    local term="${1:-}" lc label
    if [[ -z "$term" ]]; then cat; return 0; fi
    lc="$(printf '%s' "$term" | tr '[:upper:]' '[:lower:]')"
    while IFS= read -r line; do
        label="${line%%$'\t'*}"
        case "$(printf '%s' "$label" | tr '[:upper:]' '[:lower:]')" in
            *"$lc"*) printf '%s\n' "$line" ;;
        esac
    done
}

# Open a NEW agent for a chosen row: a fresh tab inside the project's workspace
# when one is open, else a freshly-created workspace (same as opening a closed
# repo). Honors --agent + the remember-last memory, exactly like _ai_open_repo.
_ai_open_new() {
    local name="$1" path="$2" wsid="$3" agent agent_cmd
    agent="$(ai_agent_resolve "$name" "$AGENT_OVERRIDE")"
    [[ -n "$AGENT_OVERRIDE" ]] && ai_agent_set "$name" "$agent"
    agent_cmd="$(ai_agent_cmd "$agent")"
    if [[ -n "$wsid" ]]; then
        ai_herdr_new_tab "$wsid" "$path" "$name" "$agent_cmd"
    else
        ai_herdr_open "$name" "$path" "$agent_cmd"
    fi
}

# Persist a picker preference action (`pref:<field>:<value>`). Preferences are
# intentionally local to this user+machine.
_ai_apply_pref() {
    local action="$1" field value key label
    IFS=':' read -r _pref field value <<<"$action"
    case "$field:$value" in
        agent:*)  key="MESH_AI_DEFAULT_AGENT"; label="default agent" ;;
        action:agent|action:shell)
                  key="MESH_AI_DEFAULT_ACTION"; label="default action" ;;
        open:focus|open:new)
                  key="MESH_AI_OPEN_EXISTING"; label="open existing" ;;
        *)        log_error "ai: invalid preference action '$action'"; return 2 ;;
    esac
    ai_prefs_set "$key" "$value" || { log_error "ai: failed to save preference '$key'"; return 1; }
    log_info "ai: saved $label = $value in $(ai_prefs_file)"
}

# Route a chosen `action<TAB>label<TAB>path<TAB>wsid<TAB>status<TAB>tabid` line.
# action ∈ {open,new,shell,agent:<name>,pref:<field>:<value>}:
#   open → focus the exact tab if it carries one, else focus the workspace,
#          else create+launch (a closed repo);
#   new  → open ANOTHER agent in the project (a fresh tab in its open workspace,
#          else a freshly-created workspace) — Enter focuses, Ctrl-N opens new.
#   shell → open the project directory without running an agent.
#   agent:<name> → guarantee a fresh agent when already open, else create+run.
# Project name = the workspace label (a tab row's `<ws> › <tab>` collapses to
# `<ws>`) so agent memory + the new tab's label track the project, not the tab.
_ai_route() {
    local action label path wsid _status tabid name
    IFS=$'\t' read -r action label path wsid _status tabid <<<"$1"
    name="${label%% › *}"

    if [[ "$action" == pref:* ]]; then
        _ai_apply_pref "$action"
        return $?
    fi

    if [[ "$action" == agent:* ]]; then
        _ai_open_agent_explicit "$name" "$path" "$wsid" "${action#agent:}" 0
        return $?
    fi

    if [[ "$action" == shell ]]; then
        _ai_open_shell "$name" "$path" "$wsid"
        return $?
    fi

    if [[ "$action" == new ]]; then
        _ai_open_new "$name" "$path" "$wsid"
        return $?
    fi

    if (( FORCE_SHELL )); then
        _ai_open_shell "$name" "$path" "$wsid"
        return $?
    fi

    if (( FORCE_FILES )); then
        _ai_open_files "$name" "$path" "$wsid"
        return $?
    fi

    if [[ -n "$AGENT_OVERRIDE" ]]; then
        _ai_open_agent_explicit "$name" "$path" "$wsid" "$AGENT_OVERRIDE" 1
        return $?
    fi

    if [[ "$(ai_pref_default_action)" == shell ]]; then
        _ai_open_shell "$name" "$path" "$wsid"
        return $?
    fi

    if [[ -n "$wsid" && "$(ai_pref_open_existing)" == new ]]; then
        _ai_open_new "$name" "$path" "$wsid"
        return $?
    fi

    if [[ -n "$tabid" ]]; then
        log_info "ai: focusing tab '$label'"
        ai_herdr_focus_tab "$wsid" "$tabid"
    elif [[ -n "$wsid" ]]; then
        log_info "ai: focusing open workspace '$label'"
        herdr workspace focus "$wsid" >/dev/null
    else
        _ai_open_repo "$label" "$path"
    fi
}

# Blink picker (preferred): feed candidates, read the chosen line back. Exit
# codes mirror ai-pick-main so the caller can tell cancel from unavailable:
#   0   → chosen line printed
#   130 → user pressed Esc (cancel): open nothing, do NOT fall back
#   1   → menu app/runtime unavailable: caller may fall back to the bash picker
_ai_pick_blink() {
    local menu="$REPO/scripts/menu/index.js" cand="$1" out rc
    [[ "${MESH_AI_PICKER:-}" == "bash" ]] && return 1
    command -v node >/dev/null 2>&1 || return 1
    [[ -f "$menu" ]] || return 1
    out="$(mktemp -t mesh-ai-pick.XXXXXX)" || return 1
    node "$menu" ai-pick --in "$cand" --out "$out" </dev/tty >/dev/tty 2>/dev/null
    rc=$?
    if (( rc == 0 )); then
        cat "$out"; rm -f "$out"; return 0
    fi
    rm -f "$out"
    (( rc == 130 )) && return 130   # Esc → cancel, never fall through to bash
    return 1                        # anything else → blink unavailable
}

# Bash fallback picker: a plain numbered chooser on the tty (used when blink is
# unavailable, or MESH_AI_PICKER=bash). Prints the chosen raw line.
_ai_pick_bash() {
    local cand="$1" n=0 sel line label path wsid status tabid
    local -a lines=()
    while IFS= read -r line; do [[ -n "$line" ]] && lines+=("$line"); done < "$cand"
    (( ${#lines[@]} > 0 )) || { log_error "ai: nothing to open"; return 1; }
    for line in "${lines[@]}"; do
        n=$((n + 1))
        IFS=$'\t' read -r label path wsid status tabid <<<"$line"
        if [[ -n "$wsid" ]]; then
            printf '  %2d) %-38s herdr · %-7s %s\n' "$n" "$label" "${status:-?}" "$path" >&2
        else
            printf '  %2d) %-38s %s\n' "$n" "$label" "$path" >&2
        fi
    done
    printf "ai> pick a number ('n'<num> = new agent, 's'<num> = shell, q = cancel): " >&2
    IFS= read -r sel </dev/tty || return 1
    [[ "$sel" == q || -z "$sel" ]] && return 1
    local act=open idx
    if [[ "$sel" =~ ^n([0-9]+)$ ]]; then
        act=new; idx="${BASH_REMATCH[1]}"
    elif [[ "$sel" =~ ^s([0-9]+)$ ]]; then
        act=shell; idx="${BASH_REMATCH[1]}"
    elif [[ "$sel" =~ ^[0-9]+$ ]]; then
        idx="$sel"
    else
        log_error "ai: invalid choice"; return 1
    fi
    (( idx >= 1 && idx <= ${#lines[@]} )) || { log_error "ai: invalid choice"; return 1; }
    printf '%s\t%s' "$act" "${lines[$((idx - 1))]}"
}

# Build the merged set once, then filter by the (optional) term.
CAND_FILE="$(mktemp -t mesh-ai-cand.XXXXXX)" || exit 1
FILT_FILE="$(mktemp -t mesh-ai-filt.XXXXXX)" || exit 1
trap 'rm -f "${CAND_FILE:-}" "${FILT_FILE:-}"' EXIT
_ai_candidates > "$CAND_FILE"

if (( CANDIDATES )); then
    cat "$CAND_FILE"
    exit 0
fi

_ai_filter "$TERM_ARG" < "$CAND_FILE" > "$FILT_FILE"
N_FILTERED="$(grep -c . "$FILT_FILE" 2>/dev/null || true)"
N_FILTERED="${N_FILTERED:-0}"

# A term that matches nothing is a hard miss.
if [[ -n "$TERM_ARG" ]] && (( N_FILTERED == 0 )); then
    log_error "ai: no project or workspace matches '$TERM_ARG' (try \`mesh ai --list\`)"
    exit 1
fi
# Nothing to open at all (no repos under AI_ROOTS, no open workspaces).
if (( N_FILTERED == 0 )); then
    log_error "ai: nothing to open — no open herdr workspaces and no repos under AI_ROOTS"
    log_info  "ai: roots searched: $(ai_roots | tr '\n' ' ')"
    exit 1
fi

# Fast path: an explicit term that resolves to exactly one row opens directly
# (always the "open" action — focus-or-create the single match).
if [[ -n "$TERM_ARG" ]] && (( N_FILTERED == 1 )); then
    _ai_route "open"$'\t'"$(cat "$FILT_FILE")"
    exit $?
fi

# Otherwise (no term, or an ambiguous term) → the picker over the filtered set.
# Esc in the blink picker (rc 130) cancels outright; only an *unavailable* blink
# (rc 1) falls back to the bash picker.
while :; do
    CHOICE="$(_ai_pick_blink "$FILT_FILE")"; PICK_RC=$?
    if (( PICK_RC == 130 )); then
        exit 0
    elif (( PICK_RC != 0 )); then
        CHOICE="$(_ai_pick_bash "$FILT_FILE")" || exit 0
    fi
    [[ -n "$CHOICE" ]] || exit 0

    if [[ "$CHOICE" == pref:*$'\t'* ]]; then
        _ai_route "$CHOICE" || exit $?
        ai_prefs_load
        continue
    fi

    _ai_route "$CHOICE"
    exit $?
done
