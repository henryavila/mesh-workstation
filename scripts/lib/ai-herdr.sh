# shellcheck shell=bash
# scripts/lib/ai-herdr.sh — herdr handoff for `mesh ai`.
# Source-only (no top-level execution).
#
# Once a project is chosen, `mesh ai` does NOT multiplex or track state itself —
# herdr owns that. This lib is the thin bridge: route the chosen project to an
# already-open herdr workspace (focus) or a fresh one (create + launch agent).
#
# Contract observed on herdr 0.6.8 (see mesh-identity
# .ai/analysis/2026-06-17-herdr-cli-contract.md):
#   herdr workspace list   → JSON .result.workspaces[] {label, workspace_id, agent_status}
#   herdr workspace create --cwd P --label L --focus → JSON .result.root_pane.pane_id
#   herdr pane run <pane_id> "<cmd>"  → run agent command + Enter
#   HERDR_ENV=1 when inside a herdr pane.
#
# jq is required (herdr emits clean JSON); absence is a clear, non-silent error.

# rc0 iff we are running inside a herdr pane.
ai_in_herdr() { [[ -n "${HERDR_ENV:-}" ]]; }

# rc0 iff the herdr CLI + jq are both available; logs which is missing.
ai_herdr_ready() {
    if ! command -v herdr >/dev/null 2>&1; then
        log_error "ai: herdr not found on PATH — install herdr (https://herdr.dev) or run the agent directly"
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        log_error "ai: jq not found on PATH — required to parse herdr JSON"
        return 1
    fi
    return 0
}

# Emit open workspaces as `label<TAB>workspace_id<TAB>agent_status`, one per line.
ai_herdr_workspaces() {
    herdr workspace list 2>/dev/null \
        | jq -r '.result.workspaces[]? | [.label, .workspace_id, .agent_status] | @tsv' 2>/dev/null
}

# workspace_id of the open workspace whose label == $1, or empty. First match wins.
ai_herdr_workspace_id() {
    local name="$1"
    ai_herdr_workspaces | awk -F'\t' -v n="$name" '$1 == n { print $2; exit }'
}

# First pane's cwd for a workspace (its project dir), or empty. Used to label an
# open workspace whose name doesn't match a discovered repo (e.g. a workspace
# named after a branch, sitting in a git worktree) so the picker can still show
# WHICH project it is.
ai_herdr_workspace_cwd() {
    local wsid="$1"
    herdr pane list --workspace "$wsid" 2>/dev/null \
        | jq -r '.result.panes[0].cwd // empty' 2>/dev/null
}

# Tabs of a workspace as `tab_id<TAB>label<TAB>agent_status`, one per line. A tab
# is where an agent actually lives, so this is what lets `mesh ai` jump to a
# specific task inside a multi-tab workspace.
ai_herdr_tabs() {
    local wsid="$1"
    herdr tab list --workspace "$wsid" 2>/dev/null \
        | jq -r '.result.tabs[]? | [.tab_id, .label, .agent_status] | @tsv' 2>/dev/null
}

# Focus a specific tab (bringing its workspace to front first, so the jump works
# regardless of which workspace is currently active).
ai_herdr_focus_tab() {
    local wsid="$1" tabid="$2"
    herdr workspace focus "$wsid" >/dev/null 2>&1
    herdr tab focus "$tabid" >/dev/null
}

# Route a chosen project into herdr: focus its workspace if already open, else
# create a workspace at its dir (labelled by name) and launch the agent in the
# new root pane.
#   $1 name   — project name (used as the workspace label)
#   $2 path   — absolute project directory
#   $3 agent  — agent command to run in a freshly-created workspace (optional;
#               on focus of an existing workspace nothing is launched)
ai_herdr_open() {
    local name="$1" path="$2" agent="${3:-}"
    ai_herdr_ready || return 1

    local wid
    wid="$(ai_herdr_workspace_id "$name")"
    if [[ -n "$wid" ]]; then
        log_info "ai: focusing open workspace '$name'"
        herdr workspace focus "$wid" >/dev/null
        return $?
    fi

    log_info "ai: creating workspace '$name' at $path"
    local create_json pane_id
    create_json="$(herdr workspace create --cwd "$path" --label "$name" --focus 2>/dev/null)"
    pane_id="$(printf '%s' "$create_json" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
    if [[ -z "$pane_id" ]]; then
        log_error "ai: herdr workspace create failed for '$name' ($path)"
        return 1
    fi

    if [[ -n "$agent" ]]; then
        herdr pane run "$pane_id" "$agent" >/dev/null
    fi
}

# Open a NEW agent tab inside an ALREADY-open workspace: create a tab at the
# project dir, then launch the agent in its fresh root pane. This backs the
# "open new" action for a project whose workspace is already open — where a
# plain focus would only switch to the agents already running there.
#   $1 wsid   — target workspace id (must already exist)
#   $2 path   — absolute project directory (the new tab's cwd)
#   $3 label  — label for the new tab
#   $4 agent  — agent command to run in the new tab's root pane (optional)
ai_herdr_new_tab() {
    local wsid="$1" path="$2" label="$3" agent="${4:-}"
    ai_herdr_ready || return 1

    log_info "ai: opening a new agent tab in workspace '$label'"
    local create_json pane_id
    create_json="$(herdr tab create --workspace "$wsid" --cwd "$path" --label "$label" --focus 2>/dev/null)"
    pane_id="$(printf '%s' "$create_json" | jq -r '.result.root_pane.pane_id // empty' 2>/dev/null)"
    if [[ -z "$pane_id" ]]; then
        log_error "ai: herdr tab create failed in workspace '$wsid' ($path)"
        return 1
    fi

    [[ -n "$agent" ]] && herdr pane run "$pane_id" "$agent" >/dev/null
}

# Open Yazi as a herdr plugin overlay on a project. Ensures the workspace
# exists (create if closed, focus if open) then:
#   herdr plugin pane open --plugin mesh.yazi --entrypoint picker --placement overlay --cwd PATH
# F0 evidence on herdr 0.7.0. Does not open a new tab.
ai_herdr_open_files() {
    local name="$1" path="$2" wsid="${3:-}"
    ai_herdr_ready || return 1

    if [[ -n "$wsid" ]]; then
        log_info "ai: focusing workspace '$name' for Yazi overlay"
        herdr workspace focus "$wsid" >/dev/null || return $?
    else
        ai_herdr_open "$name" "$path" "" || return $?
    fi

    herdr plugin pane open \
        --plugin mesh.yazi \
        --entrypoint picker \
        --placement overlay \
        --cwd "$path" >/dev/null
}
