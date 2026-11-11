#!/usr/bin/env bash
# Behavioural tests for yaml-parse.sh v2 (manifest.yaml 3-level schema).
# Bash 3.2 compatible (runs on macOS default bash).
#
# Covers spec §10.2 mandates: nested counts, when: passthrough (named + option),
# requires_bundles lists, indent-6 routing, graceful skip of the
# choices/derive_from/source sub-trees (default mode) + their META-mode emission,
# per-item platform gating, the success sentinel, and rejection of every
# unsupported construct the parser must reject.
#
# The two reference manifests (topics/web, topics/databases) double as valid
# fixtures — the parser must keep them green (handoff step 1 / T-200).

set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
PARSER="$WS/scripts/lib/yaml-parse.sh"
FIX="$HERE/fixtures/yaml-parse-v2"
TOPICS="$WS/topics"

pass=0
fail=0
fails=""

# run_valid <file> <inline assertions> [META=1]
run_valid() {
    local file="$1" code="$2" meta="${3:-0}"
    local out rc
    out=$(MESH_YAML_META="$meta" "$PARSER" < "$file" 2>&1); rc=$?
    if [ $rc -ne 0 ]; then
        fail=$((fail + 1))
        fails="$fails\n  FAIL: $file parser exited $rc: $out"
        return
    fi
    if ( eval "$out"; eval "$code" ); then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        fails="$fails\n  FAIL: $file assertions failed\n----\n$out\n----"
    fi
}

# run_invalid <file> <expected substring>
run_invalid() {
    local file="$1" needle="$2" out rc
    out=$("$PARSER" < "$file" 2>&1); rc=$?
    if [ $rc -eq 0 ]; then
        fail=$((fail + 1))
        fails="$fails\n  FAIL: $file parsed OK but should reject"
        return
    fi
    case "$out" in
        *"$needle"*) ;;
        *) fail=$((fail + 1)); fails="$fails\n  FAIL: $file stderr missing '$needle' (got: $out)"; return;;
    esac
    case "$out" in
        *line*[Cc]olumn*) pass=$((pass + 1));;
        *) fail=$((fail + 1)); fails="$fails\n  FAIL: $file stderr missing 'line N column N' (got: $out)";;
    esac
}

echo "=== reference manifest: topics/web ==="
run_valid "$FIX/reference-web.yaml" '
    [ "${__YAML_PARSE_OK:-0}" = 1 ] || exit 1
    [ "$TOPIC_LABEL" = "Web" ] || exit 1
    [ "$TOPIC_ORDER" = 70 ] || exit 1
    [ "$TOPIC_REQUIRED" = 0 ] || exit 1
    # topic.description is UI-only — must NOT be emitted.
    [ -z "${TOPIC_DESCRIPTION:-}" ] || exit 1
    [ "$BUNDLE_COUNT" = 4 ] || exit 1
    # valet bundle: platforms + requires_bundles lists, 4 items, idempotent flag.
    [ "$BUNDLE_0_NAME" = "valet" ] || exit 1
    [ "$BUNDLE_0_PLATFORMS_COUNT" = 1 ] || exit 1
    [ "$BUNDLE_0_PLATFORMS_0" = "mac" ] || exit 1
    [ "$BUNDLE_0_REQUIRES_BUNDLES_COUNT" = 3 ] || exit 1
    [ "$BUNDLE_0_REQUIRES_BUNDLES_0" = "languages/php" ] || exit 1
    [ "$BUNDLE_0_REQUIRES_BUNDLES_1" = "databases/mysql" ] || exit 1
    [ "$BUNDLE_0_REQUIRES_BUNDLES_2" = "databases/redis" ] || exit 1
    [ "$BUNDLE_0_ITEM_COUNT" = 5 ] || exit 1
    [ "$BUNDLE_0_ITEM_3_IDEMPOTENT" = 1 ] || exit 1
    # serve-config: deploy-type item (template render) appended to valet.
    [ "$BUNDLE_0_ITEM_4_NAME" = "serve-config" ] || exit 1
    [ "$BUNDLE_0_ITEM_4_TYPE" = "deploy" ] || exit 1
    [ "$BUNDLE_0_ITEM_4_SPEC" = "./templates/serve" ] || exit 1
    [ "$BUNDLE_0_ITEM_4_IDEMPOTENT" = 1 ] || exit 1
    [ "$BUNDLE_0_OPTION_COUNT" = 0 ] || exit 1
    # ngrok bundle: secret option scalars only (description skipped).
    [ "$BUNDLE_3_OPTION_COUNT" = 1 ] || exit 1
    [ "$BUNDLE_3_OPTION_0_NAME" = "authtoken" ] || exit 1
    [ "$BUNDLE_3_OPTION_0_TYPE" = "secret" ] || exit 1
    [ "$BUNDLE_3_OPTION_0_ENV" = "NGROK_AUTHTOKEN" ] || exit 1
    [ "$BUNDLE_3_OPTION_0_REQUIRED" = 0 ] || exit 1
'

echo "=== reference manifest: topics/databases ==="
run_valid "$FIX/reference-databases.yaml" '
    [ "$BUNDLE_COUNT" = 4 ] || exit 1
    # per-item platforms (inline) + uninstall_tier.
    [ "$BUNDLE_0_ITEM_0_NAME" = "mysql-mac" ] || exit 1
    [ "$BUNDLE_0_ITEM_0_PLATFORMS_0" = "mac" ] || exit 1
    [ "$BUNDLE_0_ITEM_0_UNINSTALL_TIER" = 3 ] || exit 1
    [ "$BUNDLE_0_ITEM_1_PLATFORMS_0" = "wsl" ] || exit 1
    # postgresql: select option, default scalar; choices sub-tree skipped.
    [ "$BUNDLE_2_OPTION_0_TYPE" = "select" ] || exit 1
    [ "$BUNDLE_2_OPTION_0_DEFAULT" = "17" ] || exit 1
    [ -z "${BUNDLE_2_OPTION_0_HAS_CHOICES:-}" ] || exit 1
'

echo "=== databases META mode: choice meta emitted ==="
run_valid "$FIX/reference-databases.yaml" '
    [ "$BUNDLE_2_OPTION_0_HAS_CHOICES" = 1 ] || exit 1
    [ "$BUNDLE_2_OPTION_0_CHOICE_COUNT" = 3 ] || exit 1
    [ "$BUNDLE_2_OPTION_0_CHOICE_DEFAULT_COUNT" = 0 ] || exit 1
' 1

echo "=== edge fixture: when:, options, default-skip ==="
run_valid "$FIX/valid-edge.yaml" '
    [ "$TOPIC_ORDER" = 60 ] || exit 1
    [ -z "${TOPIC_DESCRIPTION:-}" ] || exit 1
    [ "$BUNDLE_COUNT" = 1 ] || exit 1
    [ "$BUNDLE_0_REQUIRES_BUNDLES_COUNT" = 1 ] || exit 1
    [ "$BUNDLE_0_REQUIRES_BUNDLES_0" = "foundation/base" ] || exit 1
    [ "$BUNDLE_0_OPTION_COUNT" = 3 ] || exit 1
    # multiselect versions: source/derive skipped in default mode; inline-list default.
    [ "$BUNDLE_0_OPTION_0_TYPE" = "multiselect" ] || exit 1
    [ "$BUNDLE_0_OPTION_0_REQUIRED_MIN" = 1 ] || exit 1
    [ "$BUNDLE_0_OPTION_0_DEFAULT_COUNT" = 1 ] || exit 1
    [ "$BUNDLE_0_OPTION_0_DEFAULT_0" = "8.4" ] || exit 1
    [ -z "${BUNDLE_0_OPTION_0_SOURCE:-}" ] || exit 1
    [ -z "${BUNDLE_0_OPTION_1_DERIVE_FROM:-}" ] || exit 1
    # item when: passthrough — both inline-option and named forms.
    [ "$BUNDLE_0_ITEM_COUNT" = 3 ] || exit 1
    [ "$BUNDLE_0_ITEM_1_WHEN" = "option.enable-composer" ] || exit 1
    [ "$BUNDLE_0_ITEM_2_WHEN" = "brew_prefix_custom" ] || exit 1
    [ "$BUNDLE_0_ITEM_2_PLATFORMS_0" = "mac" ] || exit 1
    # soft_fail: emitted only when present; default absent items stay unset.
    [ -z "${BUNDLE_0_ITEM_0_SOFT_FAIL:-}" ] || exit 1
    [ "$BUNDLE_0_ITEM_2_SOFT_FAIL" = 1 ] || exit 1
'

echo "=== edge fixture META: source + derive_from emitted ==="
run_valid "$FIX/valid-edge.yaml" '
    [ "$BUNDLE_0_OPTION_0_SOURCE" = "./data/php-versions.conf" ] || exit 1
    [ "$BUNDLE_0_OPTION_1_DERIVE_FROM" = "versions" ] || exit 1
' 1

echo "=== invalid fixtures (must reject) ==="
run_invalid "$FIX/invalid-tab-indent.yaml"      "tab"
run_invalid "$FIX/invalid-bare-under-items.yaml" "bare value not allowed"
run_invalid "$FIX/invalid-anchor.yaml"          "anchor"
run_invalid "$FIX/invalid-multidoc.yaml"        "multi-document"
run_invalid "$FIX/invalid-unknown-item-key.yaml" "unknown item key"

echo "=== sentinel discipline ==="
# Present on success (last line).
out_ok=$("$PARSER" < "$FIX/reference-web.yaml")
if printf '%s' "$out_ok" | tail -1 | grep -q '^__YAML_PARSE_OK=1$'; then
    pass=$((pass + 1)); echo "  PASS: sentinel last line on success"
else
    fail=$((fail + 1)); fails="$fails\n  FAIL: sentinel not last line"; echo "  FAIL: sentinel not last line"
fi
# Absent on rejection (partial emit then error).
out_bad=$("$PARSER" < "$FIX/invalid-unknown-item-key.yaml" 2>/dev/null)
if printf '%s' "$out_bad" | grep -q '__YAML_PARSE_OK=1'; then
    fail=$((fail + 1)); fails="$fails\n  FAIL: sentinel emitted on rejected parse"; echo "  FAIL: sentinel on rejected parse"
else
    pass=$((pass + 1)); echo "  PASS: sentinel absent on rejected parse"
fi

echo "=== shell_escape mutation (identity → special-char value leaks) ==="
# valet's desc contains an em-dash + the ngrok URL has no metachar, so use a
# crafted value: shell_escape must neutralize $ ` \ ". Mutate to identity and
# confirm the consumer pattern breaks.
MUT=$(mktemp -t mesh-yaml-noescape-XXXXXX.sh)
python3 - "$PARSER" "$MUT" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.find('shell_escape() {')
end = src.find('\n}\n', start)
if start < 0 or end < 0:
    print("MUTATION_TARGET_MISSING", file=sys.stderr); sys.exit(2)
identity = 'shell_escape() {\n    printf %s "$1"\n'
open(sys.argv[2], "w").write(src[:start] + identity + src[end+1:])
PY
if [ $? -ne 0 ]; then
    fail=$((fail + 1)); fails="$fails\n  FAIL: could not build shell_escape mutant"; echo "  FAIL: mutant build"
else
    printf 'topic:\n  label: "X"\n  order: 1\nbundles:\n  - name: b\n    label: "B"\n    desc: "d"\n    items:\n      - name: i\n        type: brew-formula\n        spec: "lit-$HOME-`x`-end"\n' > "$MUT.yaml"
    base_spec=$(MESH_YAML_META=0 "$PARSER" < "$MUT.yaml" | grep '^BUNDLE_0_ITEM_0_SPEC=')
    mut_spec=$(MESH_YAML_META=0 bash "$MUT" < "$MUT.yaml" | grep '^BUNDLE_0_ITEM_0_SPEC=')
    if [ "$base_spec" != "$mut_spec" ]; then
        pass=$((pass + 1)); echo "  PASS: identity shell_escape changes emitted SPEC (escape is load-bearing)"
    else
        fail=$((fail + 1)); fails="$fails\n  FAIL: shell_escape mutation survived"; echo "  FAIL: mutation survived"
    fi
    rm -f "$MUT.yaml"
fi
rm -f "$MUT"

total=$((pass + fail))
echo ""
echo "yaml-parse v2 tests: $pass / $total passed"
loc=$(grep -cvE '^\s*(#|$)' "$PARSER" 2>/dev/null || echo "?")
echo "Parser size: $loc non-comment-non-blank LOC"
if [ $fail -gt 0 ]; then
    printf '%b\n' "$fails"
    exit 1
fi
echo "OK"
