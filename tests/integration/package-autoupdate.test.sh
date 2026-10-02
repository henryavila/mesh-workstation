#!/usr/bin/env bash
# tests/integration/package-autoupdate.test.sh
#
# Regression suite for the per-item `autoupdate: true` flag + per-host override
# (initiative package-autoupdate). The flag lets a curated leaf item self-update
# via the engine's version-aware --update pass REGARDLESS of the three global
# MESH_UPDATE_* category switches (whose UI was deferred, so all default OFF) —
# the reason a fast-mover like moshi-hook stayed install-once-frozen.
#
# Synthetic temp topic of `custom` items (no brew/network) so it runs anywhere.
# Each item's update() drops a sentinel, so "did the update pass run for this
# item?" = "does its sentinel exist?". Covers:
#   - flag ON  + categories OFF + no policy → update runs   (the core unfreeze)
#   - flag OFF + categories OFF             → update skipped (no churn)
#   - per-host DENY suppresses a flagged item; ALLOW opts a non-flagged one in
#   - a flagged-but-not-installed item is never updated (only-if-installed)
#   - a flagged custom item with no update() is a graceful no-op (no updater)
#   - category ON still updates its topic's items (autoupdate is additive)
#   - --dry-run lists candidates and changes nothing
#   - autoupdate-policy.sh parses bare=DENY / +name=ALLOW / comments
#   - the curl/release installers (moshi-hook-linux, rtk) define update()
#   - yaml-parse emits _AUTOUPDATE for the real ai manifest
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
ENGINE="$WS/scripts/lib/install-engine.sh"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT
export TOPICS="$ROOT/topics" STATE="$ROOT/state" SENT="$ROOT/sentinels"
mkdir -p "$TOPICS/demo" "$STATE" "$SENT"

cat > "$TOPICS/demo/manifest.yaml" <<'YAML'
topic:
  label: "Demo"
  order: 10
bundles:
  - name: b
    items:
      - name: flagged
        type: custom
        script: ./flagged.sh
        autoupdate: true
      - name: plain
        type: custom
        script: ./plain.sh
      - name: denied
        type: custom
        script: ./denied.sh
        autoupdate: true
      - name: allowed
        type: custom
        script: ./allowed.sh
      - name: notinstalled
        type: custom
        script: ./notinstalled.sh
        autoupdate: true
      - name: noupdater
        type: custom
        script: ./noupdater.sh
        autoupdate: true
YAML

# installed items: check()=0; update() drops a sentinel proving the pass ran.
for n in flagged plain denied allowed; do
  cat > "$TOPICS/demo/$n.sh" <<SH
check()  { return 0; }
update() { : > "$SENT/$n-UPDATE-RAN"; }
SH
done
# flagged but NOT installed (check fails) → update must be skipped.
cat > "$TOPICS/demo/notinstalled.sh" <<SH
check()  { return 1; }
update() { : > "$SENT/notinstalled-UPDATE-RAN"; }
SH
# flagged + installed but defines NO update() → graceful no-op (custom_update
# logs "defines no update()"); no sentinel, no error.
cat > "$TOPICS/demo/noupdater.sh" <<SH
check()  { return 0; }
SH

export MESH_INSTALL_STATE_DIR="$STATE"
ran()    { [[ -f "$SENT/$1-UPDATE-RAN" ]]; }
clean()  { rm -f "$SENT"/* 2>/dev/null; }
# engine() runs --update with categories forced OFF unless the caller pre-set
# them; --bundle scopes to our synthetic bundle.
engine() { bash "$ENGINE" --topics-dir "$TOPICS" --platform mac --bundle demo/b --update "$@" > "$ROOT/log" 2>&1; }

# ── 1. manifest flag: ON self-updates, OFF stays quiet (categories all OFF) ──
clean
( unset MESH_UPDATE_AGENT_CLIS MESH_UPDATE_CLI_TOOLS MESH_UPDATE_RUNTIMES_DBS \
        MESH_AUTOUPDATE_FILE MESH_AUTOUPDATE_ALIAS; engine ); rc=$?
[[ "$rc" -eq 0 ]]  && ok "update pass exits 0 (categories off, flagged items present)" || bad "update pass rc=$rc"
ran flagged        && ok "flagged item updates with all categories OFF (the unfreeze)" || bad "flagged item did NOT update"
ran denied         && ok "second flagged item updates (no policy yet)"                 || bad "denied item did not update pre-policy"
! ran plain        && ok "unflagged item NOT updated (category off → no churn)"         || bad "unflagged item wrongly updated"
! ran allowed      && ok "unflagged item NOT updated without an ALLOW"                  || bad "allowed item updated without ALLOW"
! ran notinstalled && ok "flagged-but-not-installed item NOT updated (only-if-installed)" || bad "not-installed item wrongly updated"
! ran noupdater    && ok "flagged item with no update() is a no-op (no sentinel)"       || bad "noupdater wrongly produced a sentinel"
grep -q "noupdater" "$ROOT/log" && grep -qi "no update" "$ROOT/log" \
                   && ok "no-updater item logged a graceful skip"                       || bad "no-updater skip not logged"

# ── 2. per-host policy: DENY suppresses flagged, ALLOW opts a plain item in ──
clean
cat > "$ROOT/policy" <<'POL'
# corporate-style override
denied            # deny this flagged item on this host
+allowed          # allow this non-flagged item here
POL
( unset MESH_UPDATE_AGENT_CLIS MESH_UPDATE_CLI_TOOLS MESH_UPDATE_RUNTIMES_DBS
  export MESH_AUTOUPDATE_FILE="$ROOT/policy"; engine ); rc=$?
[[ "$rc" -eq 0 ]] && ok "update pass exits 0 with a per-host policy file"   || bad "policy run rc=$rc"
ran flagged       && ok "flagged item still updates (not denied)"            || bad "flagged item suppressed without a deny"
! ran denied      && ok "DENY suppresses a manifest-flagged item on this host" || bad "denied item updated despite DENY"
ran allowed       && ok "ALLOW opts a non-flagged item into auto-update here" || bad "allowed item did not update despite ALLOW"
! ran plain       && ok "a plain item not in ALLOW still does not update"     || bad "plain item updated without ALLOW"

# ── 3. category opt-in still works, additive to the flag ──
clean
( unset MESH_AUTOUPDATE_FILE MESH_AUTOUPDATE_ALIAS
  export MESH_UPDATE_CLI_TOOLS=1; engine ); rc=$?
[[ "$rc" -eq 0 ]] && ok "update pass exits 0 with a category enabled"        || bad "category run rc=$rc"
ran plain         && ok "category ON updates its topic's unflagged items"    || bad "category-on item did not update"
ran flagged       && ok "flagged item still updates under a category too"    || bad "flagged item lost under category-on"
! ran notinstalled && ok "not-installed item still skipped under category"   || bad "not-installed updated under category"

# ── 4. --dry-run lists candidates, mutates nothing ──
clean
( unset MESH_UPDATE_AGENT_CLIS MESH_UPDATE_CLI_TOOLS MESH_UPDATE_RUNTIMES_DBS \
        MESH_AUTOUPDATE_FILE MESH_AUTOUPDATE_ALIAS; engine --dry-run ); rc=$?
[[ "$rc" -eq 0 ]] && ok "--dry-run exits 0"                                  || bad "--dry-run rc=$rc"
! ls "$SENT"/* >/dev/null 2>&1 && ok "--dry-run dropped NO sentinels (no mutation)" || bad "--dry-run mutated state"
grep -q "\[dry-run\]" "$ROOT/log" && grep -q "would check for update" "$ROOT/log" \
                  && ok "--dry-run logs the upgrade candidates"               || bad "--dry-run did not log candidates"
grep -q "flagged: would check for update" "$ROOT/log" \
                  && ok "--dry-run names the flagged candidate"               || bad "--dry-run missed the flagged candidate"

# ── 5. autoupdate-policy.sh parse: bare=DENY, +name=ALLOW, comments stripped ──
# shellcheck source=/dev/null
( . "$WS/scripts/lib/autoupdate-policy.sh"
  export MESH_AUTOUPDATE_FILE="$ROOT/policy"
  autoupdate_policy_export
  [[ "$MESH_AUTOUPDATE_DENY" == "denied" && "$MESH_AUTOUPDATE_ALLOW" == "allowed" ]] ) \
  && ok "policy lib parses DENY='denied' ALLOW='allowed' (comments stripped)" \
  || bad "policy lib parsed deny/allow wrong"
# missing file ⇒ both empty (manifest defaults honored)
( . "$WS/scripts/lib/autoupdate-policy.sh"
  export MESH_AUTOUPDATE_FILE="$ROOT/does-not-exist"
  autoupdate_policy_export
  [[ -z "$MESH_AUTOUPDATE_DENY" && -z "$MESH_AUTOUPDATE_ALLOW" ]] ) \
  && ok "policy lib: missing file ⇒ empty override (manifest defaults)" \
  || bad "policy lib did not default-empty on a missing file"

# ── 6. the release/curl installers define update() (else the flag is a no-op) ──
grep -qE '^update\(\)' "$WS/topics/ai/install-moshi-hook.sh" \
  && ok "install-moshi-hook.sh (WSL) defines update()"   || bad "moshi-hook-linux has no update() — flag is a no-op there"
grep -qE '^update\(\)' "$WS/topics/ai/install-rtk.sh" \
  && ok "install-rtk.sh defines update()"                || bad "install-rtk.sh has no update()"
grep -qE '^update\(\)' "$WS/topics/ai/install-claude.sh" \
  && ok "install-claude.sh defines update()"             || bad "install-claude.sh has no update() — flag is a no-op there"
grep -qE '^update\(\)' "$WS/topics/ai/install-bun.sh" \
  && ok "install-bun.sh defines update()"                || bad "install-bun.sh has no update() — flag is a no-op there"

# ── 7. the real ai manifest emits _AUTOUPDATE for the flagged leaf set ──
au_count="$(bash "$WS/scripts/lib/yaml-parse.sh" < "$WS/topics/ai/manifest.yaml" 2>/dev/null | grep -c '_AUTOUPDATE=1')"
[[ "${au_count:-0}" -ge 3 ]] \
  && ok "yaml-parse emits _AUTOUPDATE=1 for the flagged ai items ($au_count found)" \
  || bad "yaml-parse emitted _AUTOUPDATE=1 for only ${au_count:-0} items (expected ≥3)"

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
