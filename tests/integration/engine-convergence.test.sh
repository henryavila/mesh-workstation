#!/usr/bin/env bash
# tests/integration/engine-convergence.test.sh
#
# Red regression suite for setup/doctor convergence. Normal apply must stop
# treating check() as convergence when verify() proves the installed item is
# broken: it should repair through the owner lifecycle, re-verify, and only then
# let downstream bundles continue.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$WS/tests/lib/assert.sh"

ROOT="$(mktemp -d -t engine-convergence.XXXXXX)"
cleanup() { rm -rf "$ROOT"; }
trap cleanup EXIT

TOPICS="$ROOT/topics"
STATE="$ROOT/state"
SENT="$ROOT/sentinels"
LOG="$ROOT/engine.log"
mkdir -p "$TOPICS/demo" "$TOPICS/languages" "$TOPICS/web" "$STATE" "$SENT"

seed_marker() {
    local topic="$1" name="$2" type="$3" spec="$4"
    cat > "$STATE/${topic}__${name}.env" <<EOF
MESH_ITEM_TOPIC="$topic"
MESH_ITEM_NAME="$name"
MESH_ITEM_TYPE="$type"
MESH_ITEM_SPEC="$spec"
MESH_ITEM_INSTALLED_AT="fixture"
EOF
}

clean_state() {
    rm -f "$STATE"/*.env "$SENT"/* "$LOG" 2>/dev/null || true
}

run_engine() {
    MESH_INSTALL_STATE_DIR="$STATE" bash "$ENGINE" --topics-dir "$TOPICS" --platform mac "$@" >"$LOG" 2>&1
}

cat > "$TOPICS/demo/manifest.yaml" <<'YAML'
topic:
  label: "Demo"
  order: 10
bundles:
  - name: fixable
    items:
      - name: repairable
        type: custom
        script: ./repairable.sh
  - name: no-safe-repair
    items:
      - name: blocked
        type: custom
        script: ./blocked.sh
  - name: post-repair
    items:
      - name: posty
        type: custom
        script: ./posty.sh
        post: "touch ./post-ran"
YAML

cat > "$TOPICS/demo/repairable.sh" <<SH
SENT_DIR="$SENT"
check()  { : > "\$SENT_DIR/repairable-check"; return 0; }
verify() { : > "\$SENT_DIR/repairable-verify"; [[ -f "\$SENT_DIR/repairable-repaired" ]]; }
install(){ : > "\$SENT_DIR/repairable-install"; }
repair() { : > "\$SENT_DIR/repairable-repaired"; }
SH

cat > "$TOPICS/demo/blocked.sh" <<SH
SENT_DIR="$SENT"
check()  { : > "\$SENT_DIR/blocked-check"; return 0; }
verify() { : > "\$SENT_DIR/blocked-verify"; return 1; }
install(){ : > "\$SENT_DIR/blocked-install"; }
SH

cat > "$TOPICS/demo/posty.sh" <<SH
SENT_DIR="$SENT"
check()  { : > "\$SENT_DIR/posty-check"; return 0; }
verify() { : > "\$SENT_DIR/posty-verify"; [[ -f "\$SENT_DIR/posty-repaired" ]]; }
install(){ : > "\$SENT_DIR/posty-install"; }
repair() { : > "\$SENT_DIR/posty-repaired"; }
SH

cat > "$TOPICS/languages/manifest.yaml" <<'YAML'
topic:
  label: "Languages"
  order: 20
bundles:
  - name: php
    items:
      - name: php-stack
        type: custom
        script: ./php-stack.sh
YAML

cat > "$TOPICS/languages/php-stack.sh" <<SH
SENT_DIR="$SENT"
ORDER_FILE="$SENT/order"
check() { return 0; }
verify() {
    if [[ -f "\$SENT_DIR/php-repaired" ]]; then
        : > "\$SENT_DIR/php-verified-after-repair"
        return 0
    fi
    printf 'Warning: PHP Startup: Unable to load dynamic library redis.so\n' >&2
    : > "\$SENT_DIR/php-verify-failed"
    return 1
}
install() { : > "\$SENT_DIR/php-install"; }
repair() {
    printf 'php-repair\n' >> "\$ORDER_FILE"
    : > "\$SENT_DIR/php-repaired"
}
SH

cat > "$TOPICS/web/manifest.yaml" <<'YAML'
topic:
  label: "Web"
  order: 70
bundles:
  - name: valet
    requires_bundles:
      - languages/php
    items:
      - name: valet
        type: custom
        script: ./valet.sh
YAML

cat > "$TOPICS/web/valet.sh" <<SH
SENT_DIR="$SENT"
ORDER_FILE="$SENT/order"
check() { return 1; }
install() {
    printf 'valet-install\n' >> "\$ORDER_FILE"
    [[ -f "\$SENT_DIR/php-repaired" ]] || {
        printf 'web/valet: PHP Startup warning made Composer unreliable\n' >&2
        return 67
    }
    : > "\$SENT_DIR/valet-installed"
}
verify() {
    [[ -f "\$SENT_DIR/php-repaired" ]] && [[ -f "\$SENT_DIR/valet-installed" ]]
}
SH

echo "normal apply repairs a check-present but verify-broken custom item"
clean_state
seed_marker demo repairable custom ./repairable.sh
run_engine --bundle demo/fixable
rc=$?
assert_eq "$rc" "0" "normal apply exits 0 after repairing the broken installed item"
assert_file_exists "$SENT/repairable-verify" "normal apply runs verify before accepting check() success"
assert_file_exists "$SENT/repairable-repaired" "normal apply repairs through repair() when verify fails"
assert_false "[ -f '$SENT/repairable-install' ]"

echo
echo "normal apply reports installed custom items that have no safe repair"
clean_state
seed_marker demo blocked custom ./blocked.sh
run_engine --bundle demo/no-safe-repair
rc=$?
assert_eq "$rc" "67" "normal apply exits 67 when a selected broken item has no safe repair"
assert_file_exists "$SENT/blocked-verify" "normal apply verifies before deciding no-safe-repair"
assert_contains "$(cat "$LOG" 2>/dev/null)" "no safe auto-repair" \
    "normal apply output names the no-safe-repair contract"

echo
echo "normal apply runs post hooks after repairing a check-present item"
clean_state
seed_marker demo posty custom ./posty.sh
run_engine --bundle demo/post-repair
rc=$?
assert_eq "$rc" "0" "normal apply exits 0 after repair and post hook"
assert_file_exists "$SENT/posty-repaired" "repair() ran for the post-hook fixture"
assert_file_exists "$TOPICS/demo/post-ran" "post hook runs after successful repair"
assert_false "[ -f '$SENT/posty-install' ]"

echo
echo "dependency closure repairs languages/php before web/valet is verified"
clean_state
seed_marker languages php-stack custom ./php-stack.sh
run_engine --bundle web/valet
rc=$?
order="$(cat "$SENT/order" 2>/dev/null || true)"
assert_eq "$rc" "0" "web/valet apply exits 0 after repairing PHP first"
assert_file_exists "$SENT/php-verify-failed" "PHP verify captured the startup-warning failure before repair"
assert_file_exists "$SENT/php-verified-after-repair" "PHP was re-verified after repair"
assert_eq "$(printf '%s\n' "$order" | sed -n '1p')" "php-repair" "PHP repair runs before Valet install"
assert_eq "$(printf '%s\n' "$order" | sed -n '2p')" "valet-install" "Valet install runs after PHP repair"

summary
