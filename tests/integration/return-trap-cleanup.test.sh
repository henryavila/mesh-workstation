#!/usr/bin/env bash
# tests/integration/return-trap-cleanup.test.sh
#
# Guards a whole class of bug: a `trap 'rm -rf "$tmp"' RETURN` set inside a
# HELPER function LEAKS — the RETURN trap stays armed after that helper returns
# and fires AGAIN when the caller (or any later function) returns, at which point
# the helper's local `$tmp` is out of scope. Under the engine's `set -u` that
# aborts with "tmp: unbound variable" — which is exactly what killed the bootstrap
# at mysql/mysql-wsl once the rust-bins hang ahead of it was removed. The fix is a
# self-clearing trap: `trap 'rm -rf "$tmp"; trap - RETURN' RETURN`.
#
# Part A reproduces the failure + proves the fix behaviourally (pure bash, no
# network/sudo). Part B asserts every known leak-prone site adopted the disarm.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"

passed=0; failed=0
ok()  { passed=$((passed+1)); echo "  ✓ $1"; }
bad() { failed=$((failed+1)); echo "  ✗ $1" >&2; }

ROOT="$(mktemp -d)"; trap 'rm -rf "$ROOT"' EXIT

# ── A. behavioural: the leak aborts under set -u; the disarm survives ──
# A bare RETURN trap in a helper must blow up when the caller returns (proving the
# scenario is real); the self-clearing form must survive. Run in a child bash so
# the set -u abort is contained.
cat > "$ROOT/bare.sh" <<'SH'
set -u
helper() { local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN; }
caller() { helper; return 0; }   # caller's return re-fires the leaked trap
caller
echo SURVIVED
SH
cat > "$ROOT/fixed.sh" <<'SH'
set -u
helper() { local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"; trap - RETURN' RETURN; }
caller() { helper; return 0; }
caller
echo SURVIVED
SH

out="$(bash "$ROOT/bare.sh" 2>&1)"; rc=$?
{ [[ "$rc" -ne 0 ]] && ! grep -q SURVIVED <<<"$out" && grep -qi "unbound variable" <<<"$out"; } \
  && ok "a bare helper RETURN trap leaks → set -u abort (scenario reproduced)" \
  || bad "bare RETURN trap did not reproduce the leak (rc=$rc: $out)"

out="$(bash "$ROOT/fixed.sh" 2>&1)"; rc=$?
{ [[ "$rc" -eq 0 ]] && grep -q SURVIVED <<<"$out"; } \
  && ok "the self-clearing trap (trap - RETURN) does NOT leak under set -u" \
  || bad "self-clearing trap still failed (rc=$rc: $out)"

# ── B. static: every leak-prone site disarms its RETURN trap ──
for f in \
    scripts/lib/installers/github-release.sh \
    scripts/lib/pecl-install.sh; do
    if grep -qE "trap - RETURN' RETURN" "$WS/$f"; then
        ok "$f disarms its RETURN trap (trap - RETURN)"
    else
        bad "$f still uses a leak-prone bare RETURN trap"
    fi
done

echo "Results: $passed passed, $failed failed"
[[ $failed -eq 0 ]]
