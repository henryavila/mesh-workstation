#!/usr/bin/env bash
# tests/integration/doctor-shell.test.sh
#
# Unmanaged mesh rc files are a doctor failure, not a warning. The recovery
# command is `mesh reinstall shell` (not doctor --fix).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
source "$HERE/../lib/assert.sh"

DOCTOR="$REPO_ROOT/scripts/runners/doctor.sh"
SANDBOX="$(mktemp -d -t mesh-doctor-shell.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT

assert_file_exists "$DOCTOR" "doctor runner exists"
doctor_src="$(cat "$DOCTOR")"
assert_contains "$doctor_src" 'count_marker_miss > 0' "marker_miss contributes to doctor exit"
assert_contains "$doctor_src" 'mesh reinstall shell' "doctor recovery names mesh reinstall shell"
assert_contains "$doctor_src" 'doctor --fix does not rewrite shell rc files' \
    "doctor --fix is not the shell recovery"

HOME_SANDBOX="$SANDBOX/home"
ID="$SANDBOX/identity"
mkdir -p "$HOME_SANDBOX" "$ID"
printf '# empty deploy map\n' > "$ID/deploy.map"

run_doctor() {
    HOME="$HOME_SANDBOX" \
        MESH_IDENTITY_DIR="$ID" \
        DOCTOR_LAUNCHD_DIR="$SANDBOX/no-launchd" \
        EBM_BREW_PREFIX_OVERRIDE="/usr/local" \
        PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
        NO_COLOR=1 \
        bash "$DOCTOR" "$@"
}

if grep -q $'\r' "$REPO_ROOT/scripts/lib/deploy.sh" 2>/dev/null; then
    echo "── skip live doctor (deploy.sh has CRLF in this checkout; CI is LF) ──"
    summary
    if [[ "$FAIL" -ne 0 ]]; then
        exit 1
    fi
    exit 0
fi

echo "── unmarked zshrc fails doctor and points at mesh reinstall shell ──"
printf '# oh-my-zsh leftover\n' > "$HOME_SANDBOX/.zshrc"
set +e
out="$(run_doctor 2>&1)"
rc=$?
set -e
assert_eq "$rc" "1" "unmanaged zshrc makes doctor exit 1"
assert_contains "$out" "marker miss" "doctor reports marker miss"
assert_contains "$out" "mesh reinstall shell" "doctor recovery is mesh reinstall shell"
assert_not_contains "$out" "mesh doctor --fix" "shell recovery is not doctor --fix"

echo "── json counts marker_miss ──"
json_rc=0
json="$(run_doctor --json 2>&1)" || json_rc=$?
assert_eq "$json_rc" "1" "JSON mode preserves the unhealthy doctor exit code"
assert_contains "$json" '"marker_miss":1' "json reports marker_miss 1"

echo "── mesh-managed zshrc is healthy ──"
printf '# managed by mesh-workstation\n' > "$HOME_SANDBOX/.zshrc"
set +e
clean_out="$(run_doctor --quiet 2>&1)"
clean_rc=$?
set -e
assert_eq "$clean_rc" "0" "managed zshrc exits 0"
assert_not_contains "$clean_out" "mesh reinstall shell" "healthy doctor does not advertise reinstall"

summary
