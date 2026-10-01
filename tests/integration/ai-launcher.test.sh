#!/usr/bin/env bash
# tests/integration/ai-launcher.test.sh
#
# Contract suite for `mesh ai` P0 — the disk project launcher with herdr handoff
# (initiative mesh-ai-launcher).
#
# Covers the two source-only libs against fakes (no real herdr, no real repos):
#   • scripts/lib/ai-discover.sh — multi-root disk discovery + substring match,
#     driven against a fake roots tree;
#   • scripts/lib/ai-herdr.sh    — focus-or-create routing, driven against a
#     stub `herdr` on PATH that records its args and emits canned JSON (real jq).
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SELF_DIR/../.." && pwd)"
# shellcheck source=../../scripts/lib/log.sh
source "$REPO_ROOT/scripts/lib/log.sh"
# shellcheck source=../../scripts/lib/ai-discover.sh
source "$REPO_ROOT/scripts/lib/ai-discover.sh"
# shellcheck source=../../scripts/lib/ai-herdr.sh
source "$REPO_ROOT/scripts/lib/ai-herdr.sh"
# shellcheck source=../../scripts/lib/ai-agent.sh
source "$REPO_ROOT/scripts/lib/ai-agent.sh"
# assert.sh LAST, on purpose: log.sh defines a non-counting fail()/ok() that
# would otherwise SHADOW assert.sh's counting pass()/fail() — masking failures
# (they print ✗ but never increment FAIL, so the suite stays green). Sourcing
# assert.sh after the libs makes its fail() win so failures actually fail.
# shellcheck source=../lib/assert.sh
source "$SELF_DIR/../lib/assert.sh"
RUNNER="$REPO_ROOT/scripts/runners/ai.sh"

SANDBOX="$(mktemp -d -t mesh-ai.XXXXXX)"
trap '[[ -d "$SANDBOX" ]] && rm -rf "$SANDBOX"' EXIT

# ── Discovery fixture ────────────────────────────────────────────────────────
# root1: two git repos (dir .git) + one plain dir (no .git, must be ignored)
# root2: one git repo + a mixed-case repo (substring match must be case-insens.)
#        + a repo whose .git is a FILE (gitfile — submodule/worktree, must count)
R1="$SANDBOX/root1"; R2="$SANDBOX/root2"
mkdir -p "$R1/repoA/.git" "$R1/repoB/.git" "$R1/plaindir/src" \
         "$R1/atomic-skills/.git" \
         "$R2/repoC/.git" "$R2/MyApp/.git" "$R2/linked"
echo "gitdir: /elsewhere" > "$R2/linked/.git"   # gitfile, not a dir

echo "── ai-discover ──"
CAT="$(AI_ROOTS="$R1:$R2" ai_discover)"
assert_contains "$CAT" $'repoA\t'"$R1/repoA" "discovers repoA in root1"
assert_contains "$CAT" $'repoB\t'"$R1/repoB" "discovers repoB in root1"
assert_contains "$CAT" $'repoC\t'"$R2/repoC" "discovers repoC in root2"
assert_contains "$CAT" $'MyApp\t'"$R2/MyApp" "discovers MyApp in root2"
assert_contains "$CAT" $'linked\t'"$R2/linked" "counts a gitfile (.git as file)"
assert_not_contains "$CAT" "plaindir" "ignores a non-git dir"

# Missing root contributes nothing, no error.
assert_exit_code 0 'AI_ROOTS="$SANDBOX/nope:$R1" ai_discover' "missing root is not an error"
MISS="$(AI_ROOTS="$SANDBOX/nope:$R1" ai_discover)"
assert_contains "$MISS" "repoA" "still discovers from the existing root"
assert_not_contains "$MISS" "$SANDBOX/nope" "missing root yields no rows"

echo "── ai-roots / defaults ──"
# `~` expansion + `:`/newline split. The literal ~ is intentional — it
# exercises ai_roots' own tilde expansion, so it must NOT pre-expand here.
# shellcheck disable=SC2088
ROOTS_OUT="$(AI_ROOTS="~/foo:~/bar" ai_roots)"
assert_contains "$ROOTS_OUT" "$HOME/foo" "expands ~ in AI_ROOTS"
assert_contains "$ROOTS_OUT" "$HOME/bar" "splits AI_ROOTS on :"
# Default roots always include \$HOME as a root.
DEF="$(unset AI_ROOTS; ai_roots)"
assert_contains "$DEF" "$HOME" "default roots include \$HOME"

echo "── ai-match (substring, case-insensitive) ──"
M_APP="$(AI_ROOTS="$R1:$R2" ai_match app)"
assert_contains "$M_APP" "MyApp" "matches 'app' against 'MyApp' (case-insensitive, mid-string)"
assert_not_contains "$M_APP" "repoA" "does not match unrelated repos"
M_REPO="$(AI_ROOTS="$R1:$R2" ai_match repo)"
assert_contains "$M_REPO" "repoA" "'repo' matches repoA"
assert_contains "$M_REPO" "repoC" "'repo' matches repoC"
assert_not_contains "$M_REPO" "MyApp" "'repo' does not match MyApp"
# Empty term → everything.
assert_eq "$(AI_ROOTS="$R1:$R2" ai_match | wc -l | tr -d ' ')" \
          "$(AI_ROOTS="$R1:$R2" ai_discover | wc -l | tr -d ' ')" \
          "empty term returns the full catalogue"

# ── herdr handoff (stub on PATH, real jq) ────────────────────────────────────
if ! command -v jq >/dev/null 2>&1; then
    echo "── ai-herdr: SKIPPED (jq absent) ──"
else
    echo "── ai-herdr: focus-or-create ──"
    BIN="$SANDBOX/bin"; mkdir -p "$BIN"
    export HERDR_LOG="$SANDBOX/herdr.log"; : > "$HERDR_LOG"
    cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "workspace list")
    printf '%s' '{"result":{"workspaces":[{"label":"mesh-identity","workspace_id":"w123","agent_status":"blocked"},{"label":"atomic-skills","workspace_id":"w456","agent_status":"done"}]}}' ;;
  "workspace create")
    printf '%s' '{"result":{"root_pane":{"pane_id":"wNEW-1"},"workspace":{"workspace_id":"wNEW"}}}' ;;
  "pane list")
    printf '%s' '{"result":{"panes":[{"cwd":"/home/henry/arch/.worktrees/feature"},{"cwd":"/other"}]}}' ;;
  "tab list")
    printf '%s' '{"result":{"tabs":[{"tab_id":"w123:1","label":"Design Brief","agent_status":"idle"},{"tab_id":"w123:2","label":"Dashboard","agent_status":"working"}]}}' ;;
  "tab create")
    printf '%s' '{"result":{"root_pane":{"pane_id":"wTAB-1"},"tab":{"tab_id":"w123:9"}}}' ;;
  *) : ;;
esac
STUB
    chmod +x "$BIN/herdr"
    OLD_PATH="$PATH"; export PATH="$BIN:$PATH"

    assert_true 'ai_herdr_ready' "ai_herdr_ready true when herdr+jq present"
    assert_eq "$(ai_herdr_workspace_id mesh-identity)" "w123" "resolves workspace_id by label"
    assert_eq "$(ai_herdr_workspace_id ghost)" "" "empty for an unopened label"
    assert_eq "$(ai_herdr_workspace_cwd w123)" "/home/henry/arch/.worktrees/feature" "workspace cwd = first pane cwd"
    assert_eq "$(ai_herdr_tabs w123 | wc -l | tr -d ' ')" "2" "lists a workspace's tabs"
    assert_contains "$(ai_herdr_tabs w123)" "$(printf 'w123:2\tDashboard\tworking')" "tab row = tab_id+label+status"
    : > "$HERDR_LOG"
    ai_herdr_focus_tab w123 w123:2 >/dev/null 2>&1
    FT="$(cat "$HERDR_LOG")"
    assert_contains "$FT" "workspace focus w123" "focus_tab brings the workspace to front"
    assert_contains "$FT" "tab focus w123:2" "focus_tab focuses the exact tab"

    # Case 1: label already open → FOCUS, never create.
    : > "$HERDR_LOG"
    ai_herdr_open "mesh-identity" "/whatever" "claude" >/dev/null 2>&1
    LOG1="$(cat "$HERDR_LOG")"
    assert_contains "$LOG1" "workspace focus w123" "open project → workspace focus <id>"
    assert_not_contains "$LOG1" "workspace create" "open project → no create"

    # Case 2: not open → CREATE at path + run agent in the new root pane.
    : > "$HERDR_LOG"
    ai_herdr_open "newproj" "/abs/path" "claude --dangerously-skip-permissions" >/dev/null 2>&1
    LOG2="$(cat "$HERDR_LOG")"
    assert_contains "$LOG2" "workspace create --cwd /abs/path --label newproj --focus" "new project → create with cwd+label"
    assert_contains "$LOG2" "pane run wNEW-1 claude --dangerously-skip-permissions" "new project → run agent in new root pane"

    # Case 3: "open new" in an ALREADY-open workspace → new TAB in it + run agent
    # in the tab's fresh pane (NOT a focus, NOT a second workspace).
    : > "$HERDR_LOG"
    ai_herdr_new_tab w123 "/proj/dir" "myproj" "claude --dangerously-skip-permissions" >/dev/null 2>&1
    LOG3="$(cat "$HERDR_LOG")"
    assert_contains "$LOG3" "tab create --workspace w123 --cwd /proj/dir --label myproj --focus" "new tab → tab create in the open workspace"
    assert_contains "$LOG3" "pane run wTAB-1 claude --dangerously-skip-permissions" "new tab → run agent in the new tab's pane"
    assert_not_contains "$LOG3" "workspace create" "new tab → does NOT spawn a second workspace"
    assert_not_contains "$LOG3" "workspace focus" "new tab → is not a plain focus"

    export PATH="$OLD_PATH"
fi

# ── herdr readiness guard (herdr absent) ─────────────────────────────────────
echo "── ai-herdr: readiness guard ──"
assert_false 'PATH="/nonexistent" ai_herdr_ready' "ai_herdr_ready false when herdr missing"

# ── ai-agent: resolution + per-project memory ────────────────────────────────
echo "── ai-agent ──"
export XDG_STATE_HOME="$SANDBOX/state"
assert_eq "$(ai_agent_cmd claude)" "claude" "bare agent cmd when no flags env"
assert_eq "$(MESH_AI_FLAGS_CLAUDE='--dangerously-skip-permissions' ai_agent_cmd claude)" \
          "claude --dangerously-skip-permissions" "flags env appended to agent cmd"
assert_eq "$(ai_agent_resolve repoA 'codex')" "codex" "override wins in resolve"
assert_eq "$(MESH_AI_AGENT=gemini ai_agent_resolve repoA '')" "gemini" "MESH_AI_AGENT default when no override/memory"
assert_eq "$(MESH_AI_DEFAULT_AGENT=codex MESH_AI_AGENT=claude ai_agent_resolve repoA '')" "codex" "local preference wins over identity default"
assert_eq "$(ai_agent_resolve repoA '')" "claude" "falls back to 'claude' with nothing set"
ai_agent_set repoA codex
assert_eq "$(ai_agent_get repoA)" "codex" "remembers agent per project"
assert_eq "$(ai_agent_resolve repoA '')" "codex" "remembered agent wins over MESH_AI_AGENT default"
ai_agent_set repoA claude   # idempotent upsert (not append)
assert_eq "$(ai_agent_get repoA)" "claude" "upsert replaces, not appends"
assert_eq "$(grep -c '^repoA=' "$(ai_agent_state_file)")" "1" "only one line per project"
unset XDG_STATE_HOME

# ── runner end-to-end (stub herdr, isolated $HOME) ───────────────────────────
if command -v jq >/dev/null 2>&1; then
    echo "── runner: mesh ai ──"
    RBIN="$SANDBOX/rbin"; mkdir -p "$RBIN"
    RHOME="$SANDBOX/rhome"; mkdir -p "$RHOME/.config"
    # Pin XDG so GHA/setup-node's XDG_CONFIG_HOME=$runner_home/.config cannot
    # steal ai.env away from the sandbox.
    export XDG_CONFIG_HOME="$RHOME/.config"
    export HERDR_LOG="$SANDBOX/runner-herdr.log"
    cat > "$RBIN/herdr" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$HERDR_LOG"
case "$1 $2" in
  "workspace list")   printf '%s' '{"result":{"workspaces":[{"label":"atomic-skills","workspace_id":"w456","agent_status":"done"},{"label":"ghostws","workspace_id":"w999","agent_status":"working"},{"label":"multi","workspace_id":"w777","agent_status":"working"}]}}' ;;
  "workspace create") printf '%s' '{"result":{"root_pane":{"pane_id":"wNEW-1"},"workspace":{"workspace_id":"wNEW"}}}' ;;
  "tab create")       printf '%s' '{"result":{"root_pane":{"pane_id":"wTAB-1"},"tab":{"tab_id":"w456:9"}}}' ;;
  "pane list")        printf '%s' '{"result":{"panes":[{"cwd":"/srv/ghost/work"}]}}' ;;
  "tab list")
    # $4 = the --workspace id; only `multi` (w777) has several tabs.
    if [[ "$4" == w777 ]]; then
      printf '%s' '{"result":{"tabs":[{"tab_id":"w777:1","label":"Alpha","agent_status":"idle"},{"tab_id":"w777:2","label":"Beta","agent_status":"working"},{"tab_id":"w777:3","label":"Gamma","agent_status":"blocked"}]}}'
    else
      printf '%s' '{"result":{"tabs":[{"tab_id":"'"$4"':1","label":"main","agent_status":"done"}]}}'
    fi ;;
  *) : ;;
esac
STUB
    chmod +x "$RBIN/herdr"

    run_ia() {  # run the real runner in an isolated env
        # Pin XDG_CONFIG_HOME under RHOME: GHA/setup-node often exports
        # XDG_CONFIG_HOME=$HOME/.config of the runner, so ai.env written
        # to $RHOME/.config/mesh would never be loaded.
        HOME="$RHOME" \
        XDG_CONFIG_HOME="$RHOME/.config" \
        XDG_STATE_HOME="$SANDBOX/rstate" \
        AI_ROOTS="$R1:$R2" \
        MESH_AI_PICKER=bash PATH="$RBIN:$PATH" \
        MESH_AI_AGENT=claude MESH_AI_FLAGS_CLAUDE='--dangerously-skip-permissions' \
            env -u MESH_AI_DEFAULT_ACTION -u MESH_AI_DEFAULT_AGENT \
                -u MESH_AI_OPEN_EXISTING -u MESH_AI_PREFS \
                bash "$RUNNER" "$@"
    }

    # --list: disk catalogue only, never touches herdr.
    : > "$HERDR_LOG"
    LIST_OUT="$(run_ia --list 2>/dev/null)"
    assert_contains "$LIST_OUT" "repoA" "--list prints the disk catalogue"
    assert_eq "$(cat "$HERDR_LOG")" "" "--list never touches herdr"

    # --candidates: the MERGED, deduped set (open workspaces + disk repos).
    CANDS="$(run_ia --candidates 2>/dev/null)"
    assert_eq "$(printf '%s\n' "$CANDS" | awk -F'\t' '$1=="atomic-skills"' | grep -c .)" "1" \
        "open + disk repo of the same name dedupe to ONE row"
    assert_contains "$CANDS" "$(printf 'atomic-skills\t%s\tw456\tdone' "$R1/atomic-skills")" \
        "deduped row carries the disk path + wsid + status"
    assert_contains "$CANDS" "$(printf 'ghostws\t/srv/ghost/work\tw999\tworking')" \
        "open-only workspace shows its pane cwd (which project)"
    assert_contains "$CANDS" "$(printf 'repoB\t%s\t\t' "$R1/repoB")" \
        "closed repo: path with empty wsid"

    # Tabs: a multi-tab workspace keeps its bare row AND gains one row per tab.
    assert_eq "$(printf '%s\n' "$CANDS" | awk -F'\t' '$1=="multi"' | grep -c .)" "1" \
        "multi-tab workspace still has exactly one bare workspace row"
    assert_contains "$CANDS" "$(printf 'multi › Beta\t/srv/ghost/work\tw777\tworking\tw777:2')" \
        "each tab becomes a searchable row carrying its tab_id"
    # A single-tab workspace is NOT expanded.
    assert_eq "$(printf '%s\n' "$CANDS" | awk -F'\t' '$1 ~ /^atomic-skills › /' | grep -c .)" "0" \
        "single-tab workspace is not expanded into tab rows"

    # Fast path: a unique tab-name term jumps straight to that tab.
    : > "$HERDR_LOG"
    run_ia Gamma >/dev/null 2>&1
    RLOGT="$(cat "$HERDR_LOG")"
    assert_contains "$RLOGT" "workspace focus w777" "tab term brings the workspace to front"
    assert_contains "$RLOGT" "tab focus w777:3" "tab term focuses the exact tab"

    # Fast path: unique closed repo → create + launch resolved agent.
    : > "$HERDR_LOG"
    run_ia repoB >/dev/null 2>&1
    RLOG="$(cat "$HERDR_LOG")"
    assert_contains "$RLOG" "workspace create --cwd $R1/repoB --label repoB --focus" "term→single repo creates at its path"
    assert_contains "$RLOG" "pane run wNEW-1 claude --dangerously-skip-permissions" "launches the identity-default agent+flags"

    # Fast path: term matching an open workspace that is also a disk repo → focus.
    : > "$HERDR_LOG"
    run_ia atomic-skills >/dev/null 2>&1
    RLOG2="$(cat "$HERDR_LOG")"
    assert_contains "$RLOG2" "workspace focus w456" "open+disk term → focus"
    assert_not_contains "$RLOG2" "workspace create" "open+disk term → no create"

    # Fast path: term matching an OPEN-ONLY workspace (not on disk) → focus.
    : > "$HERDR_LOG"
    run_ia ghostws >/dev/null 2>&1
    assert_contains "$(cat "$HERDR_LOG")" "workspace focus w999" "open-only term → focus (matched by label, not disk)"

    # --agent override is remembered for the project.
    : > "$HERDR_LOG"
    run_ia repoA --agent codex >/dev/null 2>&1
    assert_eq "$(grep '^repoA=' "$SANDBOX/rstate/mesh/ai-agents.env" 2>/dev/null)" "repoA=codex" "--agent override is remembered"

    # --agent/--codex are explicit launch intents: on an already-open workspace,
    # they open a fresh tab with that agent instead of merely focusing.
    : > "$HERDR_LOG"
    run_ia atomic-skills --codex >/dev/null 2>&1
    CODLOG="$(cat "$HERDR_LOG")"
    assert_contains "$CODLOG" "tab create --workspace w456 --cwd $R1/atomic-skills --label atomic-skills --focus" "--codex on open repo → new tab"
    assert_contains "$CODLOG" "pane run wTAB-1 codex" "--codex on open repo → launches codex"
    assert_not_contains "$CODLOG" "workspace focus w456" "--codex does not just focus the existing workspace"

    # --shell opens the directory in herdr without running an agent command.
    : > "$HERDR_LOG"
    run_ia repoC --shell >/dev/null 2>&1
    SHELL_CLOSED="$(cat "$HERDR_LOG")"
    assert_contains "$SHELL_CLOSED" "workspace create --cwd $R2/repoC --label repoC --focus" "--shell on closed repo → create workspace"
    assert_not_contains "$SHELL_CLOSED" "pane run" "--shell on closed repo → no agent run"
    : > "$HERDR_LOG"
    run_ia atomic-skills --shell >/dev/null 2>&1
    SHELL_OPEN="$(cat "$HERDR_LOG")"
    assert_contains "$SHELL_OPEN" "tab create --workspace w456 --cwd $R1/atomic-skills --label atomic-skills --focus" "--shell on open repo → new shell tab"
    assert_not_contains "$SHELL_OPEN" "pane run" "--shell on open repo → no agent run"

    # --files opens Yazi overlay (F0 argv) after ensuring the workspace exists.
    : > "$HERDR_LOG"
    run_ia repoC --files >/dev/null 2>&1
    FILES_CLOSED="$(cat "$HERDR_LOG")"
    assert_contains "$FILES_CLOSED" "workspace create --cwd $R2/repoC --label repoC --focus" "--files on closed repo → create workspace"
    assert_contains "$FILES_CLOSED" "plugin pane open" "--files uses herdr plugin pane open"
    assert_contains "$FILES_CLOSED" "--plugin mesh.yazi" "--files names plugin mesh.yazi"
    assert_contains "$FILES_CLOSED" "--entrypoint picker" "--files names picker entrypoint"
    assert_contains "$FILES_CLOSED" "--placement overlay" "--files requests overlay"
    assert_contains "$FILES_CLOSED" "--cwd $R2/repoC" "--files overlay cwd is the repo"
    assert_not_contains "$FILES_CLOSED" "tab create" "--files on closed repo → no tab create"
    : > "$HERDR_LOG"
    run_ia atomic-skills --files >/dev/null 2>&1
    FILES_OPEN="$(cat "$HERDR_LOG")"
    assert_contains "$FILES_OPEN" "plugin pane open" "--files on open repo → yazi overlay"
    assert_contains "$FILES_OPEN" "--plugin mesh.yazi" "--files on open repo names mesh.yazi"
    assert_contains "$FILES_OPEN" "--placement overlay" "--files on open repo requests overlay"
    assert_not_contains "$FILES_OPEN" "tab create" "--files on open repo → no new tab"
    HELP="$(sed -n '2,25p' "$RUNNER")"
    assert_contains "$HELP" "--files" "usage header lists --files"
    assert_exit_code 2 'run_ia repoC --not-a-real-flag' "unknown flags still exit 2"

    # Local preferences are sourced from ~/.config/mesh/ai.env. A shell default
    # makes Enter/fast-path open the directory without an agent.
    mkdir -p "$RHOME/.config/mesh"
    printf 'MESH_AI_DEFAULT_ACTION=shell\n' > "$RHOME/.config/mesh/ai.env"
    : > "$HERDR_LOG"
    run_ia repoC >/dev/null 2>&1
    PREF_SHELL="$(cat "$HERDR_LOG")"
    assert_contains "$PREF_SHELL" "workspace create --cwd $R2/repoC --label repoC --focus" "local shell default → create workspace"
    assert_not_contains "$PREF_SHELL" "pane run" "local shell default → no agent run"
    rm -f "$RHOME/.config/mesh/ai.env"

    # Unknown term → exit 1; a read-only list is fine, but NEVER a mutation.
    : > "$HERDR_LOG"
    assert_exit_code 1 'run_ia no-such-repo-xyz' "unknown term exits 1"
    NLOG="$(cat "$HERDR_LOG")"
    assert_not_contains "$NLOG" "workspace create" "unknown term never creates"
    assert_not_contains "$NLOG" "workspace focus" "unknown term never focuses"

    # Esc in the blink picker (node exits 130) cancels outright — it must NOT
    # fall through to the bash numbered-list picker, and must open nothing.
    # Needs a real /dev/tty (the picker redirects from it); skip if headless.
    if ( exec </dev/tty >/dev/tty ) 2>/dev/null; then
        NBIN="$SANDBOX/nbin"; mkdir -p "$NBIN"
        cat > "$NBIN/node" <<'STUB'
#!/usr/bin/env bash
# Stub: emulate ai-pick-main's Esc-cancel path (exit 130, write nothing).
exit 130
STUB
        chmod +x "$NBIN/node"
        : > "$HERDR_LOG"
        ESC_OUT="$(HOME="$RHOME" XDG_STATE_HOME="$SANDBOX/rstate" AI_ROOTS="$R1:$R2" \
            PATH="$NBIN:$RBIN:$PATH" MESH_AI_AGENT=claude \
            bash "$RUNNER" 2>&1; echo "rc=$?")"
        assert_contains "$ESC_OUT" "rc=0" "Esc in blink picker exits 0 (cancel)"
        assert_not_contains "$ESC_OUT" "pick a number" "Esc never falls back to the bash numbered picker"
        ELOG="$(cat "$HERDR_LOG")"   # read-only discovery calls are fine; a mutation is not
        assert_not_contains "$ELOG" "workspace create" "Esc opens nothing (no create)"
        assert_not_contains "$ELOG" "workspace focus" "Esc opens nothing (no focus)"
    else
        echo "── Esc-cancel: SKIPPED (no /dev/tty) ──"
    fi

    # Picker "new" action: choosing a row with the "new" verb opens a FRESH agent
    # — a new TAB when the project's workspace is already open (atomic-skills/w456),
    # instead of just focusing it. Driven by a node stub that emulates ai-pick-main
    # writing `new<TAB><row>` to --out.
    rm -f "$SANDBOX/rstate/mesh/ai-agents.env"
    if ( exec </dev/tty >/dev/tty ) 2>/dev/null; then
        NNEW="$SANDBOX/nnew"; mkdir -p "$NNEW"
        cat > "$NNEW/node" <<'STUB'
#!/usr/bin/env bash
in=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in --in) shift; in="$1" ;; --out) shift; out="$1" ;; esac
  shift
done
row="$(awk -F'\t' '$1=="atomic-skills"{print; exit}' "$in")"
printf 'new\t%s' "$row" > "$out"
exit 0
STUB
        chmod +x "$NNEW/node"
        : > "$HERDR_LOG"
        HOME="$RHOME" XDG_STATE_HOME="$SANDBOX/rstate" AI_ROOTS="$R1:$R2" \
            PATH="$NNEW:$RBIN:$PATH" MESH_AI_AGENT=claude MESH_AI_FLAGS_CLAUDE='--dangerously-skip-permissions' \
            bash "$RUNNER" >/dev/null 2>&1
        NEWLOG="$(cat "$HERDR_LOG")"
        assert_contains "$NEWLOG" "tab create --workspace w456 --cwd $R1/atomic-skills --label atomic-skills --focus" "picker 'new' on an open repo → new tab in its workspace"
        assert_contains "$NEWLOG" "pane run wTAB-1 claude --dangerously-skip-permissions" "picker 'new' → launch agent in the new tab"
        assert_not_contains "$NEWLOG" "workspace focus w456" "picker 'new' does NOT just focus the existing workspace"
    else
        echo "── picker-new: SKIPPED (no /dev/tty) ──"
    fi

    # Picker one-off actions can force shell/agent, and prefs actions persist to
    # the local config file without touching mesh-identity.
    if ( exec </dev/tty >/dev/tty ) 2>/dev/null; then
        NACTION="$SANDBOX/naction"; mkdir -p "$NACTION"
        cat > "$NACTION/node" <<'STUB'
#!/usr/bin/env bash
in=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in --in) shift; in="$1" ;; --out) shift; out="$1" ;; esac
  shift
done
row="$(awk -F'\t' '$1=="atomic-skills"{print; exit}' "$in")"
case "${MESH_TEST_PICK_ACTION:-shell}" in
  agent-codex) printf 'agent:codex\t%s' "$row" > "$out" ;;
  pref-codex)  printf 'pref:agent:codex\t%s' "$row" > "$out" ;;
  pref-codex-once)
    count_file="${MESH_TEST_PICK_COUNT:?}"
    count=0
    [ -r "$count_file" ] && count="$(cat "$count_file")"
    count=$((count + 1))
    printf '%s\n' "$count" > "$count_file"
    if [ "$count" -eq 1 ]; then
      printf 'pref:agent:codex\t%s' "$row" > "$out"
    else
      exit 130
    fi
    ;;
  *)           printf 'shell\t%s' "$row" > "$out" ;;
esac
exit 0
STUB
        chmod +x "$NACTION/node"

        : > "$HERDR_LOG"
        HOME="$RHOME" XDG_STATE_HOME="$SANDBOX/rstate" AI_ROOTS="$R1:$R2" \
            PATH="$NACTION:$RBIN:$PATH" MESH_AI_AGENT=claude \
            bash "$RUNNER" >/dev/null 2>&1
        PICK_SHELL="$(cat "$HERDR_LOG")"
        assert_contains "$PICK_SHELL" "tab create --workspace w456 --cwd $R1/atomic-skills --label atomic-skills --focus" "picker 'shell' → new tab in open workspace"
        assert_not_contains "$PICK_SHELL" "pane run" "picker 'shell' → no agent run"

        : > "$HERDR_LOG"
        HOME="$RHOME" XDG_STATE_HOME="$SANDBOX/rstate" AI_ROOTS="$R1:$R2" \
            PATH="$NACTION:$RBIN:$PATH" MESH_TEST_PICK_ACTION=agent-codex MESH_AI_AGENT=claude \
            bash "$RUNNER" >/dev/null 2>&1
        PICK_CODEX="$(cat "$HERDR_LOG")"
        assert_contains "$PICK_CODEX" "pane run wTAB-1 codex" "picker 'agent:codex' → launches codex"

        rm -f "$RHOME/.config/mesh/ai.env"
        PREF_COUNT="$SANDBOX/pref-count"
        HOME="$RHOME" XDG_STATE_HOME="$SANDBOX/rstate" AI_ROOTS="$R1:$R2" \
            PATH="$NACTION:$RBIN:$PATH" MESH_TEST_PICK_ACTION=pref-codex-once MESH_TEST_PICK_COUNT="$PREF_COUNT" MESH_AI_AGENT=claude \
            bash "$RUNNER" >/dev/null 2>&1
        assert_contains "$(cat "$RHOME/.config/mesh/ai.env")" "MESH_AI_DEFAULT_AGENT=codex" "picker preference action saves local default agent"

        NREOPEN="$SANDBOX/nreopen"; mkdir -p "$NREOPEN"
        cat > "$NREOPEN/node" <<'STUB'
#!/usr/bin/env bash
in=""; out=""
while [ $# -gt 0 ]; do
  case "$1" in --in) shift; in="$1" ;; --out) shift; out="$1" ;; esac
  shift
done
count_file="${MESH_TEST_PICK_COUNT:?}"
count=0
[ -r "$count_file" ] && count="$(cat "$count_file")"
count=$((count + 1))
printf '%s\n' "$count" > "$count_file"
row="$(awk -F'\t' '$1=="atomic-skills"{print; exit}' "$in")"
case "$count" in
  1) printf 'pref:agent:codex\t%s' "$row" > "$out" ;;
  *)
    printf '%s\n' "${MESH_AI_DEFAULT_AGENT:-}" > "${MESH_TEST_PICK_ENV:?}"
    printf 'open\t%s' "$row" > "$out"
    ;;
esac
exit 0
STUB
        chmod +x "$NREOPEN/node"
        rm -f "$RHOME/.config/mesh/ai.env"
        PICK_COUNT="$SANDBOX/pick-count"
        PICK_ENV="$SANDBOX/pick-env"
        : > "$HERDR_LOG"
        HOME="$RHOME" XDG_STATE_HOME="$SANDBOX/rstate" AI_ROOTS="$R1:$R2" \
            PATH="$NREOPEN:$RBIN:$PATH" MESH_TEST_PICK_COUNT="$PICK_COUNT" MESH_TEST_PICK_ENV="$PICK_ENV" MESH_AI_AGENT=claude \
            bash "$RUNNER" >/dev/null 2>&1
        assert_eq "$(cat "$PICK_COUNT")" "2" "picker preference action returns to mesh ai picker"
        assert_eq "$(cat "$PICK_ENV")" "codex" "reopened picker sees the saved default agent"
        assert_contains "$(cat "$RHOME/.config/mesh/ai.env")" "MESH_AI_DEFAULT_AGENT=codex" "reopened picker keeps saved default agent"
        assert_contains "$(cat "$HERDR_LOG")" "workspace focus w456" "second picker choice routes after saving preference"
    else
        echo "── picker-actions: SKIPPED (no /dev/tty) ──"
    fi
else
    echo "── runner: SKIPPED (jq absent) ──"
fi

summary
