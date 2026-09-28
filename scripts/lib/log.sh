# shellcheck shell=bash
# scripts/lib/log.sh — central logger. Source-only (no top-level execution).
# Functions: log_info / log_warn / log_error / log_debug.
# All write to stderr (so stdout is reserved for data piped between commands).
# log_debug is suppressed unless MESH_DEBUG=1 in the environment.

log_info()  { printf '[INFO] %s\n'  "$*" >&2; }
log_warn()  { printf '[WARN] %s\n'  "$*" >&2; }
log_error() { printf '[ERROR] %s\n' "$*" >&2; }
log_debug() { [[ "${MESH_DEBUG:-0}" == "1" ]] && printf '[DEBUG] %s\n' "$*" >&2 || true; }

# ─── Compat block — legacy symbols used by callers pre-C19 refactor ──────────
# These are preserved so existing scripts/topics continue to work unchanged.
# Do NOT add new callers; migrate to log_info/log_warn/log_error/log_debug.

if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
    _C_RED=$'\033[31m'
    _C_GRN=$'\033[32m'
    _C_YEL=$'\033[33m'
    _C_BLU=$'\033[34m'
    _C_BLD=$'\033[1m'
    _C_BLK=$'\033[5m'   # blink — reserved for "this field is waiting for you"
    _C_RST=$'\033[0m'
else
    _C_RED=""; _C_GRN=""; _C_YEL=""; _C_BLU=""; _C_BLD=""; _C_BLK=""; _C_RST=""
fi

info()   { printf '%s→%s %s\n' "$_C_BLU" "$_C_RST" "$*"; }
ok()     { printf '%s✓%s %s\n' "$_C_GRN" "$_C_RST" "$*"; }
warn()   { printf '%s!%s %s\n' "$_C_YEL" "$_C_RST" "$*" >&2; }
fail()   { printf '%s✗%s %s\n' "$_C_RED" "$_C_RST" "$*" >&2; }
banner() { printf '\n%s== %s ==%s\n' "$_C_BLD" "$*" "$_C_RST"; }

# ─── Interactive prompts (standardized, reusable) ────────────────────────────
# ONE interface for every interaction: the blink-tui engine (the same one the
# menu uses for CODE_DIR / identity onboarding). ask_line / ask_secret / confirm
# render a single blink-tui field when it can run here, and fall back to a bash
# prompt otherwise (early bootstrap before node, CI, MESH_PROMPT_TUI=off). The
# bridge lives below in _prompt_tui_ok / _prompt_tui.
#
# The bash FALLBACK writes to the CONTROLLING TERMINAL (/dev/tty), not stdout or
# stderr — `mesh setup` runs the engine under `… 2>&1 | tee LOG`, so neither fd1
# nor fd2 is a tty there. Keying colour off `-t 1` (as the palette above does)
# would silently drop it; the prompt colours itself whenever a /dev/tty exists,
# and going straight to /dev/tty keeps escape codes out of the log. A bold mauve
# `❯` caret marks the field; the label never blinks (it fights typing). Input
# comes from $MESH_PROMPT_IN, output to $MESH_PROMPT_OUT (both default to
# /dev/tty; tests/automation point them at files to pin this bash path).

# Input source / output sink for every prompt (override for tests).
_prompt_src() { printf '%s' "${MESH_PROMPT_IN:-/dev/tty}"; }
_prompt_out() {
    if [ -n "${MESH_PROMPT_OUT:-}" ]; then printf '%s' "$MESH_PROMPT_OUT"; return; fi
    if [ -e /dev/tty ]; then printf '/dev/tty'; else printf '/dev/stderr'; fi
}

# Colour the prompt whenever a human terminal will see it (a /dev/tty exists or
# fd2 is a tty) and the user hasn't opted out. Independent of fd1 — see above.
_prompt_colored() {
    [ -z "${NO_COLOR:-}" ] || return 1
    [ -n "${MESH_PROMPT_OUT:-}" ] && return 1   # explicit redirect (file) → plain
    [ -e /dev/tty ] || [ -t 2 ]
}

# _prompt_styled <on|off> <label> — PURE: build the bash-fallback prompt string.
# A bold mauve `❯` caret (matching the p10k/blink-tui prompt char + Catppuccin
# palette) marks the waiting field; the LABEL stays plain so it is readable while
# typing — NO blink (a blinking label fights the cursor). Separated from I/O so
# the visual contract is unit-testable without a TTY.
_prompt_styled() {
    if [ "$1" = on ]; then
        printf '\033[1;38;2;203;166;247m❯\033[0m %s ' "$2"
    else
        printf '❯ %s ' "$2"
    fi
}

# prompt_field <label> — write the standard prompt to the terminal. The single
# place the bash-fallback "awaiting input" look is defined; reuse it.
prompt_field() {
    local on=off
    _prompt_colored && on=on
    _prompt_styled "$on" "$*" > "$(_prompt_out)"
}

# ── blink-tui bridge — the SAME engine as the menu (CODE_DIR / onboarding) ────
# Interactions render through the blink-tui menu app when it can actually run
# here; otherwise they fall back to the bash prompt above (early bootstrap before
# node, CI, or `MESH_PROMPT_TUI=off`). The menu app lives next to this lib.
_MESH_MENU_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]:-$0}")/../menu" 2>/dev/null && pwd -P || true)"

# rc0 when the blink-tui prompt can run: interactive, node + the app + its deps
# already present (never trigger an `npm ci` just for a prompt), not disabled and
# not redirected to a file (tests / automation pin the bash path that way).
_prompt_tui_ok() {
    [ "${MESH_PROMPT_TUI:-auto}" != off ] || return 1
    [ "${NON_INTERACTIVE:-0}" != 1 ] || return 1
    [ -z "${MESH_PROMPT_OUT:-}" ] && [ -z "${MESH_PROMPT_IN:-}" ] || return 1
    [ -e /dev/tty ] || return 1
    command -v node >/dev/null 2>&1 || return 1
    [ -n "${_MESH_MENU_DIR:-}" ] && [ -f "$_MESH_MENU_DIR/index.js" ] || return 1
    [ -d "$_MESH_MENU_DIR/node_modules/@henryavila/blink-tui" ] || return 1
}

# _prompt_tui <type> <label> [default] [choices] → value on stdout (rc0); rc1 =
# cancel or unavailable. The TUI draws on /dev/tty; the value comes back via a
# temp file (--out) so Ink's stdout rendering never collides with the captured
# value. `choices` (newline-joined id=label) is passed only when non-empty.
_prompt_tui() {
    local type="$1" label="$2" def="${3:-}" choices="${4:-}" out rc
    out="$(mktemp)" || return 1
    if [ -n "$choices" ]; then
        node "$_MESH_MENU_DIR/index.js" prompt \
            --type "$type" --label "$label" --default "$def" --choices "$choices" --out "$out" \
            </dev/tty >/dev/tty 2>/dev/tty
    else
        node "$_MESH_MENU_DIR/index.js" prompt \
            --type "$type" --label "$label" --default "$def" --out "$out" \
            </dev/tty >/dev/tty 2>/dev/tty
    fi
    rc=$?
    # Clean up terminal state after Ink / Node exits
    if [ -w /dev/tty ] && [ -r /dev/tty ]; then
        stty sane </dev/tty 2>/dev/null || true
        printf '\e[?2004l\e[?1l' >/dev/tty 2>/dev/null || true
        while read -r -t 0.05 -n 10000 _ < /dev/tty 2>/dev/null; do :; done
    fi
    [ "$rc" -eq 0 ] || { rm -f "$out"; return 1; }
    cat "$out"; rm -f "$out"
}

# ask_line <label> [default] — visible input; echoes value (or default) to stdout.
ask_line() {
    local label="$1" def="${2:-}" ans
    if _prompt_tui_ok; then
        ans="$(_prompt_tui text "$label" "$def")" || ans=""   # Esc → default
        printf '%s' "${ans:-$def}"
        return 0
    fi
    prompt_field "$label"
    IFS= read -r ans < "$(_prompt_src)" || true
    printf '%s' "${ans:-$def}"
}

# ask_secret <label> — hidden input; echoes value to stdout.
ask_secret() {
    local label="$1" ans
    if _prompt_tui_ok; then
        ans="$(_prompt_tui secret "$label" "")" || ans=""     # Esc → empty
        printf '%s' "$ans"
        return 0
    fi
    prompt_field "$label"
    IFS= read -r -s ans < "$(_prompt_src)" || true
    printf '\n' > "$(_prompt_out)"
    printf '%s' "$ans"
}

# _confirm_decide <answer> <default:y|n> — pure y/N resolution. rc0=yes, rc1=no.
# Factored out so the decision is unit-testable without a TTY.
_confirm_decide() {
    local ans="$1" def="$2"
    [ -z "$ans" ] && ans="$def"
    case "$ans" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# confirm <label> [default:y|n] — y/N prompt. rc0=yes, rc1=no (Esc → no).
confirm() {
    local label="$1" def="${2:-n}" ans hint
    if _prompt_tui_ok; then
        ans="$(_prompt_tui confirm "$label" "$def")" || return 1
        _confirm_decide "$ans" "$def"
        return
    fi
    case "$def" in [yY]*) hint="[Y/n]" ;; *) hint="[y/N]" ;; esac
    prompt_field "$label $hint"
    IFS= read -r ans < "$(_prompt_src)" || true
    _confirm_decide "$ans" "$def"
}

# pause <message> — ACKNOWLEDGE, not input: block until the user presses Enter
# ("approve this device on the hub, then continue"). A blink-tui waiting Dialog
# (Spinner + Enter to continue), or a bash read fallback. Always rc0 — a pause
# never aborts the caller (Esc just stops waiting).
pause() {
    local label="$1"
    if _prompt_tui_ok; then
        _prompt_tui pause "$label" "" >/dev/null || true
        return 0
    fi
    prompt_field "$label"
    IFS= read -r _ < "$(_prompt_src)" || true
    printf '\n' > "$(_prompt_out)"
}

# ask_select <label> <default-id> <id=label>… — single choice; echoes the chosen
# id to stdout. Esc / invalid input → the default id (always rc0, like ask_line).
# A blink-tui select when available, else a numbered bash menu on the terminal.
ask_select() {
    local label="$1" def="$2"; shift 2
    local choices ans
    choices="$(printf '%s\n' "$@")"
    if _prompt_tui_ok; then
        ans="$(_prompt_tui select "$label" "$def" "$choices")" || ans=""   # Esc → default
        printf '%s' "${ans:-$def}"
        return 0
    fi
    # bash fallback: numbered menu (1-based), mapping the number back to its id.
    local i=1 id lbl menu
    local ids=()
    menu="$label:"$'\n'
    for pair in "$@"; do
        id="${pair%%=*}"; lbl="${pair#*=}"
        ids[$i]="$id"
        menu="$menu  $i) $lbl"$'\n'
        i=$((i + 1))
    done
    printf '%s' "$menu" > "$(_prompt_out)"
    prompt_field "choose [1-$((i - 1))]"
    IFS= read -r ans < "$(_prompt_src)" || true
    case "$ans" in
        ''|*[!0-9]*) printf '%s' "$def"; return 0 ;;
    esac
    if [ "$ans" -ge 1 ] && [ "$ans" -lt "$i" ]; then printf '%s' "${ids[$ans]}"; return 0; fi
    printf '%s' "$def"
}

# ask_secret_or_skip <label> [skip-question] — hidden input that refuses a silent
# empty: on a blank entry it asks to confirm the skip, then re-prompts until a
# value is given OR the skip is confirmed. rc0 = value on stdout; rc1 = the user
# confirmed the skip (no value). Use for required-but-skippable secrets.
ask_secret_or_skip() {
    local label="$1" skipq="${2:-Skip this step?}" val
    while :; do
        val="$(ask_secret "$label")"
        if [ -n "$val" ]; then printf '%s' "$val"; return 0; fi
        confirm "$skipq" && return 1
    done
}

# followup — record a post-bootstrap action that needs human attention.
# Writes one line per entry to $MESH_FOLLOWUP_FILE (setup.sh
# creates this file at start and prints a consolidated summary at the
# end). Each entry has a severity that shapes how the summary renders.
#
# Severities:
#   critical  — feature is broken until resolved (e.g. Windows CA skip)
#   manual    — routine manual step (atuin login, ngrok token, chsh, …)
#   info      — optional tweak worth mentioning
#
# Usage:
#   followup critical "Windows CA import skipped — HTTPS localhost
#                      won't work in Chrome/Edge. Diagnose with:
#                      bash ~/mesh-workstation/topics/web/scripts/diagnose-wsl-interop.sh"
#
# The message can be multi-line (actual newlines); the summary will
# indent continuation lines for readability.
followup() {
    local severity="$1"
    shift
    local msg="$*"

    # Also echo inline so the topic still prints the warning as it
    # happens (keeps existing UX). Severity controls the prefix char.
    case "$severity" in
        critical) fail "$msg" ;;
        manual)   warn "$msg" ;;
        info)     info "$msg" ;;
        *)        warn "$msg" ;;
    esac

    # Persist to the follow-up file if setup.sh set one up. Topics
    # invoked directly (ONLY_TOPICS) or outside the runner get the
    # inline output but no consolidated summary — that's fine.
    if [[ -n "${MESH_FOLLOWUP_FILE:-}" ]]; then
        # Use a unit separator + record separator so multi-line messages
        # round-trip cleanly through a single file.
        printf '%s\x1f%s\x1e' "$severity" "$msg" >> "$MESH_FOLLOWUP_FILE" 2>/dev/null || true
    fi
}

# render_followup_summary — read $MESH_FOLLOWUP_FILE and print
# a grouped, human-readable summary. Called by setup.sh right
# before exit so the user sees all pending actions in one place,
# not scattered across topic output.
render_followup_summary() {
    local f="${MESH_FOLLOWUP_FILE:-}"
    [[ -z "$f" ]] && return 0
    [[ ! -s "$f" ]] && return 0

    # Parse records separated by \x1e (record sep). Each record is
    # severity\x1fmsg. Split into arrays by severity.
    local -a crit_msgs manual_msgs info_msgs
    crit_msgs=() manual_msgs=() info_msgs=()

    local IFS=$'\x1e'
    local record sev msg
    while IFS= read -r -d $'\x1e' record; do
        [[ -z "$record" ]] && continue
        sev="${record%%$'\x1f'*}"
        msg="${record#*$'\x1f'}"
        case "$sev" in
            critical) crit_msgs+=("$msg") ;;
            manual)   manual_msgs+=("$msg") ;;
            info)     info_msgs+=("$msg") ;;
        esac
    done < "$f"

    # Nothing to show? quick exit.
    local total=$(( ${#crit_msgs[@]} + ${#manual_msgs[@]} + ${#info_msgs[@]} ))
    [[ "$total" -eq 0 ]] && return 0

    banner "follow-up — manual steps that finish the setup"

    if [[ "${#crit_msgs[@]}" -gt 0 ]]; then
        printf '\n%sCritical%s — these BLOCK functionality until resolved:\n' \
            "$_C_RED$_C_BLD" "$_C_RST"
        local i
        for ((i=0; i<${#crit_msgs[@]}; i++)); do
            _render_followup_item "${_C_RED}✗${_C_RST}" "${crit_msgs[$i]}"
        done
    fi

    if [[ "${#manual_msgs[@]}" -gt 0 ]]; then
        printf '\n%sManual config%s — non-blocking, but things stay inert until done:\n' \
            "$_C_YEL$_C_BLD" "$_C_RST"
        for ((i=0; i<${#manual_msgs[@]}; i++)); do
            _render_followup_item "$_C_YEL!$_C_RST" "${manual_msgs[$i]}"
        done
    fi

    if [[ "${#info_msgs[@]}" -gt 0 ]]; then
        printf '\n%sOptional / info%s:\n' "$_C_BLU$_C_BLD" "$_C_RST"
        for ((i=0; i<${#info_msgs[@]}; i++)); do
            _render_followup_item "${_C_BLU}→${_C_RST}" "${info_msgs[$i]}"
        done
    fi
    echo
}

# Private — renders a single follow-up entry with hanging indent so
# multi-line messages read cleanly.
_render_followup_item() {
    local prefix="$1" msg="$2"
    local first=1 line
    while IFS= read -r line; do
        if [[ "$first" -eq 1 ]]; then
            printf '  %s %s\n' "$prefix" "$line"
            first=0
        else
            printf '    %s\n' "$line"
        fi
    done <<< "$msg"
}
