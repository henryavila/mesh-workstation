#!/usr/bin/env bash
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
# shellcheck disable=SC1091
source "$HERE/../lib/assert.sh"

SANDBOX="$(mktemp -d -t mesh-tuios-hosts.XXXXXX)"
trap 'rm -rf "$SANDBOX"' EXIT
export HOME="$SANDBOX/home"
export MESH_IDENTITY_DIR="$SANDBOX/identity"
export MESH_TUIOS_PEERS="$MESH_IDENTITY_DIR/config/tuios-peers.json"
export MESH_TUIOS_HOSTS_STATE="$SANDBOX/state/managed.json"
export MESH_HOST_ALIAS=localbox
export TUIOS_BIN_DIR="$SANDBOX/bin"
export TUIOS_FAKE_CONFIG="$HOME/.config/tuios/config.toml"
export TUIOS_FAKE_LOG="$SANDBOX/tuios.log"
export MESH_HOME="$ROOT" MESH_WORKSTATION_DIR="$ROOT"
mkdir -p "$MESH_IDENTITY_DIR/config" "$TUIOS_BIN_DIR" "$(dirname "$TUIOS_FAKE_CONFIG")"

cat > "$MESH_TUIOS_PEERS" <<'JSON'
{"schema":1,"hosts":{"laptop":{"ssh_alias":"laptop-ssh","session":"web","system_hostnames":["tailnet-laptop"]},"build":{"ssh_alias":"build-ssh","session":"web","system_hostnames":["build"]},"localbox":{"ssh_alias":"localbox","session":"web","system_hostnames":["fixture-local"]}}}
JSON

cat > "$TUIOS_BIN_DIR/tuios" <<'SH'
#!/usr/bin/env bash
if [[ "$1 $2" == 'config path' ]]; then printf '%s\n' "$TUIOS_FAKE_CONFIG"; exit 0; fi
if [[ "$1 $2" == 'hosts add' ]]; then
    printf 'add %s %s\n' "$3" "$4" >> "$TUIOS_FAKE_LOG"
    if [[ -f "$TUIOS_FAKE_CONFIG" ]]; then
        awk -v target="[hosts.$3]" '
          /^\[/ { skip = ($0 == target) }
          !skip { print }
        ' "$TUIOS_FAKE_CONFIG" > "$TUIOS_FAKE_CONFIG.next"
        mv "$TUIOS_FAKE_CONFIG.next" "$TUIOS_FAKE_CONFIG"
    fi
    printf '\n[hosts.%s]\naddr = "%s"\n' "$3" "$4" >> "$TUIOS_FAKE_CONFIG"
    printf '%s  %s  unreachable\n' "$3" "$4"
    exit 0
fi
if [[ "$1 $2" == 'hosts remove' ]]; then
    printf 'remove %s\n' "$3" >> "$TUIOS_FAKE_LOG"
    awk -v target="[hosts.$3]" '
      /^\[/ { skip = ($0 == target) }
      !skip { print }
    ' "$TUIOS_FAKE_CONFIG" > "$TUIOS_FAKE_CONFIG.next"
    mv "$TUIOS_FAKE_CONFIG.next" "$TUIOS_FAKE_CONFIG"
    exit 0
fi
if [[ "$1 $2" == 'hosts test' ]]; then
    printf 'test %s\n' "$3" >> "$TUIOS_FAKE_LOG"
    printf '%s  up\n' "$3"
    exit 0
fi
if [[ "$1" == 'hosts' ]]; then
    printf 'laptop  laptop-ssh-new  up\n'
    exit 0
fi
if [[ "$1" == 'attach' ]]; then
    printf 'attach %s\n' "$*" >> "$TUIOS_FAKE_LOG"
    exit 0
fi
printf 'unexpected tuios call: %s\n' "$*" >&2
exit 2
SH
chmod +x "$TUIOS_BIN_DIR/tuios"

out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
rc=$?
assert_eq "$rc" 0 "sync accepts an offline peer after TUIOS saved it"
assert_contains "$(cat "$TUIOS_FAKE_LOG" 2>/dev/null)" 'add laptop laptop-ssh' "sync adds friendly laptop name using Mesh SSH alias"
assert_contains "$(cat "$TUIOS_FAKE_LOG" 2>/dev/null)" 'add build build-ssh' "sync adds WSL target"
assert_not_contains "$(cat "$TUIOS_FAKE_LOG" 2>/dev/null)" 'add localbox localbox' "sync omits the current machine"
assert_eq "$(jq -r '.hosts.laptop' "$MESH_TUIOS_HOSTS_STATE" 2>/dev/null)" 'laptop-ssh' "sync records ownership"
assert_eq "$(jq -r '.hosts.build' "$MESH_TUIOS_HOSTS_STATE" 2>/dev/null)" 'build-ssh' "sync records the second owned peer"

before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_eq "$?" 0 "unchanged sync succeeds"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "unchanged sync does not redial or rewrite TUIOS"

jq '.hosts.laptop.ssh_alias = "laptop-ssh-new"' "$MESH_TUIOS_PEERS" > "$MESH_TUIOS_PEERS.next"
mv "$MESH_TUIOS_PEERS.next" "$MESH_TUIOS_PEERS"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_eq "$?" 0 "owned peer address can change"
assert_contains "$(cat "$TUIOS_FAKE_LOG")" 'add laptop laptop-ssh-new' "changed alias is applied"
assert_eq "$(jq -r '.hosts.laptop' "$MESH_TUIOS_HOSTS_STATE")" 'laptop-ssh-new' "ownership record follows changed alias"

cp "$TUIOS_FAKE_CONFIG" "$SANDBOX/config-before-takeover"
sed -i 's/^addr = "laptop-ssh-new"/addr = "manual-target"/' "$TUIOS_FAKE_CONFIG"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "manual takeover of a formerly owned name is refused"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "takeover never reaches TUIOS add"
cp "$SANDBOX/config-before-takeover" "$TUIOS_FAKE_CONFIG"

printf '\n[hosts.friend]\naddr = "friend"\n' >> "$TUIOS_FAKE_CONFIG"
jq 'del(.hosts.build)' "$MESH_TUIOS_PEERS" > "$MESH_TUIOS_PEERS.next"
mv "$MESH_TUIOS_PEERS.next" "$MESH_TUIOS_PEERS"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_eq "$?" 0 "removed Mesh peer is reconciled"
assert_contains "$(cat "$TUIOS_FAKE_LOG")" 'remove build' "only formerly owned peer is removed"
assert_contains "$(cat "$TUIOS_FAKE_CONFIG")" '[hosts.friend]' "unrelated manual host stays"
assert_eq "$(jq -r '.hosts.build // "absent"' "$MESH_TUIOS_HOSTS_STATE")" 'absent' "removed peer leaves ownership record"

mv "$MESH_TUIOS_HOSTS_STATE" "$MESH_TUIOS_HOSTS_STATE.prior"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "unmanaged name collision is refused"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "collision does not overwrite a host"
mv "$MESH_TUIOS_HOSTS_STATE.prior" "$MESH_TUIOS_HOSTS_STATE"

cp "$TUIOS_FAKE_CONFIG" "$SANDBOX/config-before-adversarial"
sed -i 's/^\[hosts.laptop\]/  [hosts."laptop"]/' "$TUIOS_FAKE_CONFIG"
mv "$MESH_TUIOS_HOSTS_STATE" "$MESH_TUIOS_HOSTS_STATE.prior"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "quoted, indented unmanaged TOML host is also protected"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "TOML formatting cannot bypass collision protection"
mv "$MESH_TUIOS_HOSTS_STATE.prior" "$MESH_TUIOS_HOSTS_STATE"
cp "$SANDBOX/config-before-adversarial" "$TUIOS_FAKE_CONFIG"

for header in '[hosts.laptop] # manually maintained' '[hosts . laptop]'; do
    cp "$SANDBOX/config-before-adversarial" "$TUIOS_FAKE_CONFIG"
    sed -i "s/^\[hosts.laptop\]/$header/" "$TUIOS_FAKE_CONFIG"
    mv "$MESH_TUIOS_HOSTS_STATE" "$MESH_TUIOS_HOSTS_STATE.prior"
    before="$(cat "$TUIOS_FAKE_LOG")"
    out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
    assert_ne "$?" 0 "TOML header $header cannot bypass unmanaged collision"
    assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "ambiguous host syntax leaves TUIOS unchanged"
    mv "$MESH_TUIOS_HOSTS_STATE.prior" "$MESH_TUIOS_HOSTS_STATE"
done
cp "$SANDBOX/config-before-adversarial" "$TUIOS_FAKE_CONFIG"

cat > "$TUIOS_FAKE_CONFIG" <<'TOML'
[hosts]
laptop = { addr = "manual" }
[hosts.friend]
addr = "friend"
TOML
mv "$MESH_TUIOS_HOSTS_STATE" "$MESH_TUIOS_HOSTS_STATE.prior"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "inline TOML hosts are refused before mutation"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "inline host stays intact"
mv "$MESH_TUIOS_HOSTS_STATE.prior" "$MESH_TUIOS_HOSTS_STATE"
cp "$SANDBOX/config-before-adversarial" "$TUIOS_FAKE_CONFIG"

cat > "$TUIOS_FAKE_CONFIG" <<'TOML'
hosts.laptop.addr = "manual"
[hosts.friend]
addr = "friend"
TOML
mv "$MESH_TUIOS_HOSTS_STATE" "$MESH_TUIOS_HOSTS_STATE.prior"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "dotted TOML hosts are refused before mutation"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "dotted host stays intact"
mv "$MESH_TUIOS_HOSTS_STATE.prior" "$MESH_TUIOS_HOSTS_STATE"
cp "$SANDBOX/config-before-adversarial" "$TUIOS_FAKE_CONFIG"

cat > "$TUIOS_FAKE_CONFIG" <<'TOML'
["hosts".laptop]
addr = "manual"
TOML
mv "$MESH_TUIOS_HOSTS_STATE" "$MESH_TUIOS_HOSTS_STATE.prior"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "quoted TOML root hosts table is protected"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "quoted root host stays intact"
mv "$MESH_TUIOS_HOSTS_STATE.prior" "$MESH_TUIOS_HOSTS_STATE"
cp "$SANDBOX/config-before-adversarial" "$TUIOS_FAKE_CONFIG"

cat > "$TUIOS_FAKE_CONFIG" <<'TOML'
"hosts".laptop.addr = "manual"
TOML
mv "$MESH_TUIOS_HOSTS_STATE" "$MESH_TUIOS_HOSTS_STATE.prior"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "quoted dotted TOML root is refused before mutation"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "quoted dotted host stays intact"
mv "$MESH_TUIOS_HOSTS_STATE.prior" "$MESH_TUIOS_HOSTS_STATE"
cp "$SANDBOX/config-before-adversarial" "$TUIOS_FAKE_CONFIG"

jq '.hosts.laptop.ssh_alias = "bad;alias"' "$MESH_TUIOS_PEERS" > "$MESH_TUIOS_PEERS.next"
mv "$MESH_TUIOS_PEERS.next" "$MESH_TUIOS_PEERS"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "malformed roster is rejected"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "malformed roster makes no changes"

jq '.hosts.laptop.ssh_alias = "laptop-ssh-new"' "$MESH_TUIOS_PEERS" > "$MESH_TUIOS_PEERS.next"
mv "$MESH_TUIOS_PEERS.next" "$MESH_TUIOS_PEERS"
out="$(bash "$ROOT/bin/mesh" tuios hosts status 2>&1)"
assert_eq "$?" 0 "Mesh exposes TUIOS host status"
assert_contains "$out" 'laptop' "status names the friendly peer"
assert_contains "$out" 'laptop-ssh-new' "status shows the SSH alias"
out="$(bash "$ROOT/bin/mesh" tuios hosts doctor 2>&1)"
assert_eq "$?" 0 "Mesh doctor tests configured peers"
assert_contains "$(cat "$TUIOS_FAKE_LOG")" 'test laptop' "doctor invokes upstream link test"
out="$(bash "$ROOT/bin/mesh" tuios attach laptop 2>&1)"
assert_eq "$?" 0 "Mesh attaches to a named peer"
assert_contains "$(cat "$TUIOS_FAKE_LOG")" 'attach attach --host laptop web -c' "attach defaults to shared web session"
out="$(bash "$ROOT/bin/mesh" tuios attach laptop project 2>&1)"
assert_eq "$?" 0 "Mesh accepts an explicit remote session"
assert_contains "$(cat "$TUIOS_FAKE_LOG")" 'attach attach --host laptop project -c' "attach forwards the requested session"
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/bin/mesh" tuios attach stranger 2>&1)"
assert_ne "$?" 0 "unknown peer is rejected"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "unknown peer never reaches TUIOS"
out="$(bash "$ROOT/bin/mesh" tuios attach laptop -bad 2>&1)"
assert_ne "$?" 0 "session names beginning with a dash are rejected"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "invalid session is never passed as a TUIOS flag"

jq 'del(.hosts.laptop.session)' "$MESH_TUIOS_PEERS" > "$MESH_TUIOS_PEERS.next"
mv "$MESH_TUIOS_PEERS.next" "$MESH_TUIOS_PEERS"
out="$(bash "$ROOT/bin/mesh" tuios attach laptop 2>&1)"
assert_eq "$?" 0 "a peer without preferred session opens its current TUIOS session"
assert_contains "$(cat "$TUIOS_FAKE_LOG")" 'attach attach --host laptop' "Mesh delegates session selection to TUIOS"
assert_not_contains "$(tail -1 "$TUIOS_FAKE_LOG")" 'web -c' "Mesh does not create an unrelated web session"

assert_file_exists "$ROOT/template/config/tuios-peers.json.example" "new identities get an empty TUIOS peer roster"
if [[ -f "$ROOT/template/config/tuios-peers.json.example" ]]; then
    empty_roster="$ROOT/template/config/tuios-peers.json.example"
    out="$(MESH_TUIOS_PEERS="$empty_roster" bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
    assert_eq "$?" 0 "empty roster is a valid no-op on a new identity"
fi

cat > "$SANDBOX/bin/hostname" <<'SH'
#!/bin/sh
printf 'Laptop-host\n'
SH
cat > "$SANDBOX/bin/tailscale" <<'SH'
#!/bin/sh
printf '{"Self":{"HostName":"tailnet-laptop"}}\n'
SH
chmod +x "$SANDBOX/bin/hostname" "$SANDBOX/bin/tailscale"
unset MESH_HOST_ALIAS
out="$(PATH="$SANDBOX/bin:$PATH" bash "$ROOT/topics/remote-access/tuios/hosts.sh" status 2>&1)"
assert_eq "$?" 0 "laptop identifies itself from its tailnet name"
assert_not_contains "$out" 'laptop → laptop-ssh-new' "laptop does not offer itself as a peer"
assert_contains "$out" 'localbox → localbox' "laptop still sees another peer"

export MESH_HOST_ALIAS=localbox
jq '.hosts.laptop.ssh_alias = "laptop-ssh-install"' "$MESH_TUIOS_PEERS" > "$MESH_TUIOS_PEERS.next"
mv "$MESH_TUIOS_PEERS.next" "$MESH_TUIOS_PEERS"
install_log_before="$(cat "$TUIOS_FAKE_LOG")"
out="$(
    source "$ROOT/topics/remote-access/tuios/install-binaries.sh"
    _tuios_tag() { printf 'v0.8.3'; }
    _tuios_install_tag() { return 0; }
    install
)"
assert_eq "$?" 0 "TUIOS bundle install succeeds with a peer roster"
assert_contains "$(cat "$TUIOS_FAKE_LOG")" 'add laptop laptop-ssh-install' "first TUIOS install syncs Mesh peers"
assert_ne "$(cat "$TUIOS_FAKE_LOG")" "$install_log_before" "first install actually changes TUIOS hosts"

jq '.hosts.laptop.ssh_alias = "laptop-ssh-pane"' "$MESH_TUIOS_PEERS" > "$MESH_TUIOS_PEERS.next"
mv "$MESH_TUIOS_PEERS.next" "$MESH_TUIOS_PEERS"
out="$(TUIOS_PANE_ID=fixture bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_eq "$?" 0 "sync from a TUIOS pane records the new host"
assert_contains "$out" 'tuios config apply' "sync inside a pane explains the deferred apply"

out="$(unset TUIOS_BIN_DIR; PATH="$SANDBOX/bin:$PATH" bash "$ROOT/topics/remote-access/tuios/hosts.sh" status 2>&1)"
assert_eq "$?" 0 "Mesh also finds a manually installed TUIOS in PATH"

cat > "$MESH_TUIOS_PEERS" <<'JSON'
{"schema":1,"hosts":{"localbox":{"ssh_alias":"localbox","session":"web","system_hostnames":["fixture-local"]}}}
JSON
cat > "$MESH_TUIOS_HOSTS_STATE" <<'JSON'
{"schema":1,"hosts":{"alpha":"alpha-ts","beta":"beta-ts"}}
JSON
cat > "$TUIOS_FAKE_CONFIG" <<'TOML'
[hosts.alpha]
addr = "alpha-ts"
[hosts.beta]
addr = "manual-takeover"
TOML
before="$(cat "$TUIOS_FAKE_LOG")"
out="$(bash "$ROOT/topics/remote-access/tuios/hosts.sh" sync 2>&1)"
assert_ne "$?" 0 "stale owned-name takeover blocks reconciliation"
assert_eq "$(cat "$TUIOS_FAKE_LOG")" "$before" "preflight detects the takeover before removing other peers"

summary
