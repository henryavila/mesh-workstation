#!/usr/bin/env bash
# End-of-install secret unlock: if identity secrets exist but are still
# ciphertext on this machine, setup must ask for the git-crypt key after the
# engine (which runs under tee) instead of burying/skipping the prompt.
# Bash 3.2 compatible. Isolates $HOME so we never touch the real secrets store.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
SECRET="$WS/scripts/lib/secret.sh"

pass=0; fail=0; fails=""
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); fails="$fails
  FAIL: $1"; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAKE_HOME="$TMP/home"; mkdir -p "$FAKE_HOME"
GITDIR="$(dirname "$(command -v git)")"
PATH_SAFE="/usr/bin:/bin:$GITDIR"

run() {
    HOME="$FAKE_HOME" MESH_IDENTITY_DIR="$ID" PATH="$PATH_SAFE" \
        NON_INTERACTIVE="${NON_INTERACTIVE:-1}" \
        MESH_FOLLOWUP_FILE="${MESH_FOLLOWUP_FILE:-}" \
        bash "$SECRET" "$@"
}

# --- setup.sh asks AFTER the engine tee, before the follow-up summary ---
# The engine is piped through tee, so a prompt inside personal/apply is easy to
# miss or skip. The controlling terminal is free again at the end of setup.sh.
setup="$WS/setup.sh"
awk '
    /install-engine\.sh/ { engine=NR }
    /secret offer-unlock/ { offer=NR }
    /render_followup_summary/ { summary=NR }
    END {
        if (engine == 0) { print "missing-engine"; exit 1 }
        if (offer == 0) { print "missing-offer"; exit 1 }
        if (summary == 0) { print "missing-summary"; exit 1 }
        if (!(engine < offer && offer < summary)) {
            print "order:" engine "," offer "," summary
            exit 1
        }
        print "ok"
    }
' "$setup" | grep -qx ok && ok || no "setup.sh runs secret offer-unlock after the engine tee and before the follow-up summary"

grep -q 'secret offer-unlock' "$setup" && ok || no "setup.sh invokes mesh secret offer-unlock"

# --- offer-unlock: no secrets → success, no prompt ---
ID="$TMP/empty"; mkdir -p "$ID"
out="$(run offer-unlock 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || no "offer-unlock with no secrets dir returns rc0 (got rc=$rc)"
printf '%s' "$out" | grep -qi "unlock" && no "offer-unlock with no secrets must not mention unlock" || ok

# --- offer-unlock: unlocked plaintext secrets → success ---
ID="$TMP/plain"; mkdir -p "$ID/secrets"
printf 'version: 1\nintegrations:\n  ngrok:\n    tier: 2\n    type: env-token\n    key: NGROK_AUTHTOKEN\n' \
    > "$ID/secrets/manifest.yaml"
printf 'export NGROK_AUTHTOKEN=test\n' > "$ID/secrets/secrets.env"
out="$(run offer-unlock 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && ok || no "offer-unlock with plaintext secrets returns rc0 (got rc=$rc)"

# --- offer-unlock: locked env-token store, headless → rc!=0 + followup ---
# Matches the Mac reinstall: plaintext manifest, ciphertext secrets.env,
# git-crypt not installed, engine ran under tee / NON_INTERACTIVE.
ID="$TMP/locked"; mkdir -p "$ID/secrets"
printf 'version: 1\nintegrations:\n  moshi:\n    tier: 2\n    type: env-token\n    key: MOSHI_PAIRING_TOKEN\n' \
    > "$ID/secrets/manifest.yaml"
printf '\000GITCRYPT\000ciphertextblob' > "$ID/secrets/secrets.env"
FOLLOW="$TMP/followup"
: > "$FOLLOW"
out="$(HOME="$FAKE_HOME" MESH_IDENTITY_DIR="$ID" PATH="$PATH_SAFE" \
    NON_INTERACTIVE=1 MESH_FOLLOWUP_FILE="$FOLLOW" \
    bash "$SECRET" offer-unlock 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && ok || no "offer-unlock locked+headless returns rc!=0 (got rc=$rc)"
printf '%s' "$out" | grep -qi "LOCKED" && ok || no "offer-unlock locked+headless says the repo is LOCKED"
grep -q $'critical\x1f' "$FOLLOW" && ok || no "offer-unlock locked+headless records a critical follow-up"
grep -qi "mesh secret unlock" "$FOLLOW" && ok || no "critical follow-up names mesh secret unlock"

# --- help lists the verb used by setup.sh ---
run --help 2>&1 | grep -q "offer-unlock" && ok || no "help lists offer-unlock"

# --- summary ---
total=$((pass + fail))
if [ "$fail" -eq 0 ]; then
    printf 'secret-unlock-offer.test.sh: %d/%d PASS\n' "$pass" "$total"
    exit 0
else
    printf 'secret-unlock-offer.test.sh: %d/%d PASS, %d FAIL%b\n' "$pass" "$total" "$fail" "$fails"
    exit 1
fi
