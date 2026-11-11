#!/usr/bin/env bash
# tests/integration/zsh-completion-doc-preview.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

if ! command -v zsh >/dev/null 2>&1; then
    echo "zsh not installed; skipping zsh completion preview checks"
    summary
    exit 0
fi

TESTROOT="$(mktemp -d /tmp/mesh-workstation-zsh-preview.XXXXXX)"
trap 'rm -rf "$TESTROOT"' EXIT INT TERM

cat > "$TESTROOT/doctool" <<'TOOL'
#!/usr/bin/env bash
if [ "$1" = "serve" ] && [ "$2" = "--help" ]; then
    printf '%s\n' 'DOC doctool serve --help'
    exit 0
fi
if [ "$1" = "--help" ]; then
    printf '%s\n' 'DOC doctool --help'
    exit 0
fi
exit 1
TOOL
chmod +x "$TESTROOT/doctool"

preview_out="$(
    PATH="$TESTROOT:$PATH" FZF_TAB_HELP_TIMEOUT=2 zsh -fic "
        source '$REPO_ROOT/topics/shell-terminal/templates/cli-tools/zshrc.d-20-terminal-ux.sh.template'
        zstyle -s ':fzf-tab:complete:*:*' fzf-preview preview
        words=(doctool '')
        word=serve
        desc='serve:Serve requests'
        eval \"\$preview\"
    " 2>/dev/null
)"

assert_contains "$preview_out" "serve:Serve requests" \
    "fzf-tab preview includes completer description"
assert_contains "$preview_out" "DOC doctool serve --help" \
    "fzf-tab preview executes subcommand --help"

git_alias_out="$(
    zsh -fic "
        autoload -Uz compinit
        compinit -i
        source '$REPO_ROOT/topics/git/templates/config/zshrc.d-50-git.sh'
        print -r -- \"g=\${_comps[g]-MISSING} gs=\${_comps[gs]-MISSING} gco=\${_comps[gco]-MISSING}\"
    " 2>/dev/null
)"

assert_contains "$git_alias_out" "g=_git" \
    "git alias g maps to _git"
assert_contains "$git_alias_out" "gs=_git" \
    "git alias gs maps to _git"
assert_contains "$git_alias_out" "gco=_git" \
    "git alias gco maps to _git"

fpath_out="$(
    HOME="$TESTROOT/home" zsh -fic "
        mkdir -p \"\$HOME/.local/share/zsh/site-functions\"
        source '$REPO_ROOT/topics/shell-terminal/templates/zsh/zshrc.template'
        print -r -- \${fpath[(I)\$HOME/.local/share/zsh/site-functions]}
    " 2>/dev/null
)"

if [[ "$fpath_out" =~ ^[1-9][0-9]*$ ]]; then
    pass "30-shell adds user site-functions to fpath before compinit"
else
    fail "30-shell did not add user site-functions to fpath"
fi

deploy_home="$TESTROOT/deploy-home"
mkdir -p "$deploy_home"
HOME="$deploy_home" BREW_PREFIX="" \
    bash "$REPO_ROOT/scripts/lib/deploy.sh" "$REPO_ROOT/topics/shell-terminal/templates/zsh" >/dev/null

assert_file_contains "$deploy_home/.local/share/zsh/site-functions/_mesh" "_mesh_command_specs" \
    "shell-terminal deploys registry-backed mesh completion into zsh site-functions"
assert_file_contains "$deploy_home/.local/share/zsh/site-functions/_mesh" "managed by mesh-workstation" \
    "mesh completion is marked as mesh-workstation-managed for future deploys"
assert_file_contains "$deploy_home/.local/share/zsh/site-functions/_mesh" "no-install" \
    "mesh config completion keeps --no-install flag"
assert_file_contains "$deploy_home/.local/share/zsh/site-functions/_mesh" "no-diff" \
    "mesh config completion keeps --no-diff flag"

mkdir -p "$TESTROOT/mesh-bin"
cat > "$TESTROOT/mesh-bin/mesh" <<'MESH'
#!/usr/bin/env bash
if [ "$1" = "__commands" ]; then
    if [ -n "${MESH_COMMANDS_LOG:-}" ]; then
        printf 'x' >> "$MESH_COMMANDS_LOG"
    fi
    printf '%s\n' \
        'config	Edit personal config from mesh-identity	core	core	public	none' \
        'status	Show cross-mesh status	core	core	public	allowed' \
        'topic	List or apply mesh topics	core	core	public	none' \
        'run	Fan out mesh subcommands across hosts	core	core	public	none' \
        'zeta-public	Zeta public command	zeta	core	public	allowed'
    exit 0
fi
if [ "$1" = "topic" ] && [ "$2" = "list" ]; then
    printf '%s\n' \
        '20  20-terminal-ux' \
        '25  25-dynamic-test  opt-in: INCLUDE_DYNAMIC=1' \
        '95  95-dotfiles-personal  opt-in: INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=<url>'
    exit 0
fi
exit 1
MESH
chmod +x "$TESTROOT/mesh-bin/mesh"

mesh_completion_out="$(
    PATH="$TESTROOT/mesh-bin:/usr/bin:/bin" HOME="$deploy_home" zsh -fic "
        source '$REPO_ROOT/topics/shell-terminal/templates/zsh/zshrc.template'
        words=(mesh '')
        CURRENT=2
        curcontext=''
        _arguments() {
            state=subcommand
            return 0
        }
        _describe() {
            local array_name=\"\${@[-1]}\"
            print -rl -- \"\${(@P)array_name}\"
        }
        _files() { print -r -- FILE_FALLBACK; }
        autoload -Uz _mesh
        _mesh
    " 2>/dev/null
)"

assert_contains "$mesh_completion_out" "status:Show cross-mesh status" \
    "mesh completion offers registry status command after deploy"
assert_contains "$mesh_completion_out" "zeta-public:Zeta public command" \
    "mesh completion offers public registry module command after deploy"
assert_not_contains "$mesh_completion_out" "hidden-cmd" \
    "mesh completion omits hidden commands from registry output"
assert_not_contains "$mesh_completion_out" "FILE_FALLBACK" \
    "mesh completion does not fall back to file listing when command data is available"

mesh_commands_log="$TESTROOT/mesh-commands.log"
mesh_completion_cache_out="$(
    PATH="$TESTROOT/mesh-bin:/usr/bin:/bin" HOME="$deploy_home" MESH_COMMANDS_LOG="$mesh_commands_log" zsh -fic "
        source '$REPO_ROOT/topics/shell-terminal/templates/zsh/zshrc.template'
        words=(mesh '')
        CURRENT=2
        curcontext=''
        _arguments() {
            state=subcommand
            return 0
        }
        _describe() {
            local array_name=\"\${@[-1]}\"
            print -rl -- \"\${(@P)array_name}\"
        }
        _files() { print -r -- FILE_FALLBACK; }
        autoload -Uz _mesh
        _mesh
        _mesh
    " 2>/dev/null
)"
assert_contains "$mesh_completion_cache_out" "zeta-public:Zeta public command" \
    "mesh completion cache returns registry commands on second call"
mesh_commands_calls=$(wc -c < "$mesh_commands_log" | tr -d ' ')
assert_eq "$mesh_commands_calls" "1" \
    "mesh completion memoizes mesh __commands within one zsh process"

mesh_topic_completion_out="$(
    PATH="$TESTROOT/mesh-bin:/usr/bin:/bin" HOME="$deploy_home" zsh -fic "
        source '$REPO_ROOT/topics/shell-terminal/templates/zsh/zshrc.template'
        words=(mesh topic '')
        CURRENT=3
        curcontext=''
        _arguments() {
            state=topic_arg
            return 0
        }
        _describe() {
            local array_name=\"\${@[-1]}\"
            print -rl -- \"\${(@P)array_name}\"
        }
        _files() { print -r -- FILE_FALLBACK; }
        autoload -Uz _mesh
        _mesh
    " 2>/dev/null
)"

assert_contains "$mesh_topic_completion_out" "list:list mesh-workstation topics" \
    "mesh topic completion offers list command"
assert_contains "$mesh_topic_completion_out" "20:20-terminal-ux" \
    "mesh topic completion offers numeric topic selectors"
assert_contains "$mesh_topic_completion_out" "25:25-dynamic-test" \
    "mesh topic completion reads topic selectors from mesh topic list"
assert_contains "$mesh_topic_completion_out" "25:25-dynamic-test  opt-in: INCLUDE_DYNAMIC=1" \
    "mesh topic completion preserves topic list detail text"
assert_contains "$mesh_topic_completion_out" "95:95-dotfiles-personal  opt-in: INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=<url>" \
    "mesh topic completion preserves literal angle-bracket detail from topic list"
assert_not_contains "$mesh_topic_completion_out" "FILE_FALLBACK" \
    "mesh topic completion does not fall back to file listing"

mkdir -p "$TESTROOT/fake-mesh-workstation"
cat > "$TESTROOT/fake-mesh-workstation/setup.sh" <<'BOOTSTRAP'
#!/usr/bin/env bash
if [ "$1" = "--list-topics" ]; then
    printf '%s\n' \
        '60  60-web-stack  opt-in: INCLUDE_WEBSTACK=1' \
        '82  82-ai-tools  opt-in: INCLUDE_AI_TOOLS=1' \
        '88  88-future-topic  opt-in: INCLUDE_FUTURE=1' \
        '95  95-dotfiles-personal  opt-in: INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=<url>'
    exit 0
fi
exit 1
BOOTSTRAP
chmod +x "$TESTROOT/fake-mesh-workstation/setup.sh"

mesh_topic_repo_fallback_out="$(
    PATH="/usr/bin:/bin" HOME="$deploy_home" MESH_WORKSTATION_ROOT="$TESTROOT/fake-mesh-workstation" zsh -fic "
        source '$REPO_ROOT/topics/shell-terminal/templates/zsh/zshrc.template'
        words=(mesh topic '')
        CURRENT=3
        curcontext=''
        _arguments() {
            state=topic_arg
            return 0
        }
        _describe() {
            local array_name=\"\${@[-1]}\"
            print -rl -- \"\${(@P)array_name}\"
        }
        _files() { print -r -- FILE_FALLBACK; }
        autoload -Uz _mesh
        _mesh
    " 2>/dev/null
)"

assert_contains "$mesh_topic_repo_fallback_out" "82:82-ai-tools" \
    "mesh topic completion falls back to MESH_WORKSTATION_ROOT topic catalog when mesh is unavailable"
assert_contains "$mesh_topic_repo_fallback_out" "82:82-ai-tools  opt-in: INCLUDE_AI_TOOLS=1" \
    "mesh topic completion repo fallback preserves opt-in detail text"
assert_contains "$mesh_topic_repo_fallback_out" "88:88-future-topic" \
    "mesh topic completion repo fallback is not a stale hard-coded topic list"
assert_contains "$mesh_topic_repo_fallback_out" "95:95-dotfiles-personal  opt-in: INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=<url>" \
    "mesh topic completion repo fallback preserves literal angle-bracket detail text"

mesh_topic_static_fallback_out="$(
    PATH="/usr/bin:/bin" HOME="$deploy_home" MESH_WORKSTATION_ROOT="$TESTROOT/missing-mesh-workstation" zsh -fic "
        source '$REPO_ROOT/topics/shell-terminal/templates/zsh/zshrc.template'
        words=(mesh topic '')
        CURRENT=3
        curcontext=''
        _arguments() {
            state=topic_arg
            return 0
        }
        _describe() {
            local array_name=\"\${@[-1]}\"
            print -rl -- \"\${(@P)array_name}\"
        }
        _files() { print -r -- FILE_FALLBACK; }
        autoload -Uz _mesh
        _mesh
    " 2>/dev/null
)"

assert_contains "$mesh_topic_static_fallback_out" "82:82-ai-tools" \
    "mesh topic completion static fallback includes current topic 82"
assert_contains "$mesh_topic_static_fallback_out" "82:82-ai-tools  opt-in: INCLUDE_AI_TOOLS=1" \
    "mesh topic completion static fallback preserves topic 82 detail text"
assert_contains "$mesh_topic_static_fallback_out" "82:82-ai-tools  opt-in: INCLUDE_AI_TOOLS=1 MESH_IDENTITY_REPO=<url>  AI review prompts + token-saving CLI tools" \
    "mesh topic completion static fallback describes topic 82"
assert_contains "$mesh_topic_static_fallback_out" "85:85-code-server" \
    "mesh topic completion static fallback includes current topic 85"
assert_contains "$mesh_topic_static_fallback_out" "95:95-dotfiles-personal  opt-in: INCLUDE_IDENTITY=1 MESH_IDENTITY_REPO=<url>" \
    "mesh topic completion static fallback preserves literal angle-bracket detail text"

mkdir -p "$TESTROOT/completion-bin" "$TESTROOT/site-functions"
cat > "$TESTROOT/completion-bin/gh" <<'GH'
#!/usr/bin/env bash
if [ "$1" = "completion" ] && [ "$2" = "-s" ] && [ "$3" = "zsh" ]; then
    printf '%s\n' '#compdef gh' '_gh() { _files }'
    exit 0
fi
exit 1
GH
cat > "$TESTROOT/completion-bin/uv" <<'UV'
#!/usr/bin/env bash
if [ "$1" = "generate-shell-completion" ] && [ "$2" = "zsh" ]; then
    printf '%s\n' '#compdef uv' '_uv() { _files }'
    exit 0
fi
exit 1
UV
cat > "$TESTROOT/completion-bin/atuin" <<'ATUIN'
#!/usr/bin/env bash
if [ "$1" = "gen-completions" ] && [ "$2" = "--shell" ] && [ "$3" = "zsh" ]; then
    printf '%s\n' '#compdef atuin' '_atuin() { _files }'
    exit 0
fi
exit 1
ATUIN
cat > "$TESTROOT/completion-bin/pip" <<'PIP'
#!/usr/bin/env bash
if [ "$1" = "completion" ] && [ "$2" = "--zsh" ]; then
    printf '%s\n' '#compdef pip' '_pip() { _files }'
    exit 0
fi
exit 1
PIP
chmod +x "$TESTROOT/completion-bin/"*

PATH="$TESTROOT/completion-bin:$PATH" \
ZSH_COMPLETION_TARGET_DIR="$TESTROOT/site-functions" \
    bash "$REPO_ROOT/topics/shell-terminal/scripts/generate-zsh-completions.sh" >/dev/null

assert_file_contains "$TESTROOT/site-functions/_gh" "#compdef gh" \
    "completion generator writes gh completion"
assert_file_contains "$TESTROOT/site-functions/_uv" "#compdef uv" \
    "completion generator writes uv completion"
assert_file_contains "$TESTROOT/site-functions/_atuin" "#compdef atuin" \
    "completion generator writes atuin completion"
assert_file_contains "$TESTROOT/site-functions/_pip" "#compdef pip" \
    "completion generator writes pip completion"

summary
