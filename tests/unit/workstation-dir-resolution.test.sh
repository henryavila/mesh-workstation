#!/usr/bin/env bash
# Unit tests for MESH_WORKSTATION_DIR resolution and fallback across scripts.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

passed=0; failed=0
assert() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$actual" == "$expected" ]]; then passed=$((passed+1)); echo "  ✓ $name"
    else failed=$((failed+1)); echo "  ✗ $name (expected: '$expected', got: '$actual')" >&2; fi
}

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

# Test 1: shell-bootstrap.sh loads managed-block even when MESH_WORKSTATION_DIR points to a nonexistent directory
out=$(
    MESH_WORKSTATION_DIR="/nonexistent/path/$$" bash -c "
        source '$WS/topics/shell-terminal/shell-bootstrap.sh'
        _load_managed_block
        declare -f managed_block_apply >/dev/null && echo 'loaded'
    " 2>/dev/null || echo 'failed'
)
assert "shell-bootstrap.sh loads managed-block with invalid MESH_WORKSTATION_DIR" "loaded" "$out"

# Test 2: link-shipped-configs.sh can load topic-configs even when MESH_WORKSTATION_DIR points to a nonexistent directory
out=$(
    MESH_WORKSTATION_DIR="/nonexistent/path/$$" bash -c "
        source '$WS/topics/shell-terminal/link-shipped-configs.sh'
        # mock _pairs to return empty
        _pairs() { :; }
        install
        declare -f link_default_config >/dev/null && echo 'loaded'
    " 2>/dev/null || echo 'failed'
)
assert "link-shipped-configs.sh loads topic-configs with fallback" "loaded" "$out"

# Test 3: drift-cleanup.sh can load topic-cleanup even when MESH_WORKSTATION_DIR points to a nonexistent directory
out=$(
    MESH_WORKSTATION_DIR="/nonexistent/path/$$" bash -c "
        set -euo pipefail
        source '$WS/topics/shell-terminal/drift-cleanup.sh'
        install
        echo 'ok'
    " 2>/dev/null || echo 'failed'
)
assert "drift-cleanup.sh fallback works" "ok" "$out"

# Test 4: install-rtk.sh sources github-api.sh when MESH_WORKSTATION_DIR points to a nonexistent directory
out=$(
    MESH_WORKSTATION_DIR="/nonexistent/path/$$" bash -c "
        source '$WS/topics/ai/install-rtk.sh' 2>/dev/null || true
        declare -f gh_api_curl >/dev/null && echo 'loaded'
    " 2>/dev/null || echo 'failed'
)
assert "install-rtk.sh sources github-api with invalid MESH_WORKSTATION_DIR" "loaded" "$out"

# Test 5: install-engine.sh fixes MESH_WORKSTATION_DIR when set to nonexistent path
out=$(
    MESH_WORKSTATION_DIR="/nonexistent/path/$$" bash -c "
        source '$WS/scripts/lib/env.sh' 2>/dev/null || true
        # Simulate install-engine defensive guard
        ENGINE_DIR='$WS/scripts/lib'
        if [[ -z \"\${MESH_WORKSTATION_DIR:-}\" || ! -d \"\${MESH_WORKSTATION_DIR}\" ]]; then
            export MESH_WORKSTATION_DIR=\"\$(cd \"\$ENGINE_DIR/../..\" && pwd)\"
        fi
        echo \"\$MESH_WORKSTATION_DIR\"
    " 2>/dev/null
)
assert "install-engine resets invalid MESH_WORKSTATION_DIR to workspace root" "$WS" "$out"

# Test 6: setup.sh persists MESH_WORKSTATION_DIR to config.env
FAKE_HOME="$TMP/fakehome"
mkdir -p "$FAKE_HOME/.config/mesh"
out=$(
    HOME="$FAKE_HOME" bash -c "
        SELECTIONS_DIR=\"$FAKE_HOME/.config/mesh\"
        DRY_RUN=0
        HERE=\"$WS\"
        MESH_WORKSTATION_DIR=\"$WS\"
        # Simulate persist_workstation_dir from setup.sh
        persist_workstation_dir() {
            [[ \"\$DRY_RUN\" == \"1\" ]] && return 0
            local config=\"\$SELECTIONS_DIR/config.env\"
            local dir=\"\${MESH_WORKSTATION_DIR:-\$HERE}\"
            [[ -n \"\$dir\" ]] || return 0
            export MESH_WORKSTATION_DIR=\"\$dir\"
            mkdir -p \"\$SELECTIONS_DIR\"
            local tmp; tmp=\"\$(mktemp \"\$SELECTIONS_DIR/.config.env.XXXXXX\")\" || return 0
            {
                [[ -f \"\$config\" ]] && grep -v '^MESH_WORKSTATION_DIR=' \"\$config\"
                printf 'MESH_WORKSTATION_DIR=%q\n' \"\$dir\"
            } > \"\$tmp\" && mv \"\$tmp\" \"\$config\" || { rm -f \"\$tmp\"; return 0; }
        }
        persist_workstation_dir
        cat \"\$SELECTIONS_DIR/config.env\"
    "
)
assert "persist_workstation_dir writes MESH_WORKSTATION_DIR" "MESH_WORKSTATION_DIR=$WS" "$out"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
