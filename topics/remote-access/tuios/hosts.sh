#!/usr/bin/env bash
# Reconcile Mesh peer aliases with TUIOS remote hosts.
set -euo pipefail

peers_file="${MESH_TUIOS_PEERS:-${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/config/tuios-peers.json}"
state_file="${MESH_TUIOS_HOSTS_STATE:-$HOME/.local/state/mesh/tuios-hosts.json}"
if [[ -n "${TUIOS_BIN_DIR:-}" ]]; then
    tuios_bin="$TUIOS_BIN_DIR/tuios"
elif [[ -x "$HOME/.local/bin/tuios" ]]; then
    tuios_bin="$HOME/.local/bin/tuios"
else
    tuios_bin="$(command -v tuios 2>/dev/null || printf '%s' "$HOME/.local/bin/tuios")"
fi

die() { printf 'mesh tuios hosts: %s\n' "$*" >&2; exit 1; }

validate_peers() {
    [[ -r "$peers_file" ]] || die "peer roster missing: $peers_file"
    jq -e '
      .schema == 1 and ((keys - ["schema", "hosts"]) | length == 0) and
      (.hosts | type == "object") and
      all(.hosts | to_entries[];
        (.key | test("^[a-z][a-z0-9_-]*$")) and
        (.value | type == "object") and
        (.value | (keys - ["ssh_alias", "session", "system_hostnames"]) | length == 0) and
        (.value.ssh_alias | type == "string" and test("^[A-Za-z][A-Za-z0-9_.-]*$")) and
        (.value.session == null or (.value.session | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]*$"))) and
        (.value.system_hostnames | type == "array" and length > 0 and
          all(.[]; type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]*$")))
      )
    ' "$peers_file" >/dev/null 2>&1 || die "invalid peer roster: $peers_file"
}

self_alias() {
    if jq -e '.hosts | length == 0' "$peers_file" >/dev/null; then
        printf ''
        return
    fi
    if [[ -n "${MESH_HOST_ALIAS:-}" ]]; then
        jq -er --arg name "$MESH_HOST_ALIAS" '.hosts[$name] | select(. != null) | $name' "$peers_file" || die "unknown local Mesh alias: $MESH_HOST_ALIAS"
        return
    fi
    local physical result tailnet
    physical="$(hostname -s 2>/dev/null || hostname)"
    result="$(jq -er --arg physical "$physical" '
      [.hosts | to_entries[] | select(any(.value.system_hostnames[]; ascii_downcase == ($physical | ascii_downcase))) | .key]
      | if length == 1 then .[0] else empty end
    ' "$peers_file" 2>/dev/null)" || result=""
    if [[ -n "$result" ]]; then printf '%s' "$result"; return; fi
    if command -v tailscale >/dev/null 2>&1; then
        tailnet="$(tailscale status --json 2>/dev/null | jq -er '.Self.HostName // (.Self.DNSName | split(".")[0]) // empty' 2>/dev/null)" || tailnet=""
        if [[ -n "$tailnet" ]]; then
            result="$(jq -er --arg physical "$tailnet" '
              [.hosts | to_entries[] | select(any(.value.system_hostnames[]; ascii_downcase == ($physical | ascii_downcase))) | .key]
              | if length == 1 then .[0] else empty end
            ' "$peers_file" 2>/dev/null)" || result=""
            if [[ -n "$result" ]]; then printf '%s' "$result"; return; fi
        fi
    fi
    die "cannot identify this Mesh host ($physical); set MESH_HOST_ALIAS"
}

save_owner() {
    local name="$1" addr="$2" tmp
    tmp="$(mktemp "${state_file}.XXXXXX")"
    jq --arg name "$name" --arg addr "$addr" '.hosts[$name] = $addr' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
}

delete_owner() {
    local name="$1" tmp
    tmp="$(mktemp "${state_file}.XXXXXX")"
    jq --arg name "$name" 'del(.hosts[$name])' "$state_file" > "$tmp"
    mv "$tmp" "$state_file"
}

# TUIOS writes these tables in a stable, simple shape. Unknown syntax is
# treated as occupied, so Mesh cannot overwrite a table it cannot inspect.
config_addr() {
    local config="$1" name="$2"
    [[ -f "$config" ]] || { printf '@absent\n'; return; }
    awk -v wanted="$name" '
      /^[[:space:]]*\[/ {
        active=0
        header=$0
        sub(/[[:space:]]*#.*/, "", header)
        gsub(/[[:space:]]/, "", header)
        quote=sprintf("%c", 39)
        sub(/^\["hosts"\./, "[hosts.", header)
        sub("^\\[" quote "hosts" quote "\\.", "[hosts.", header)
        sub(/^\["hosts"\]$/, "[hosts]", header)
        sub("^\\[" quote "hosts" quote "\\]$", "[hosts]", header)
        if (header == "[hosts]") { unsupported=1; next }
        if (header !~ /^\[hosts\./) next
        if (header !~ /\]$/) { unsupported=1; next }
        key=header
        sub(/^\[hosts\./, "", key)
        sub(/\]$/, "", key)
        if (key ~ /^".*"$/) key=substr(key, 2, length(key)-2)
        quote=sprintf("%c", 39)
        if (substr(key, 1, 1) == quote && substr(key, length(key), 1) == quote)
          key=substr(key, 2, length(key)-2)
        active=(key == wanted)
        if (active) count++
        next
      }
      /^[[:space:]]*hosts[[:space:]]*(\.|=)/ { unsupported=1 }
      /^[[:space:]]*"hosts"[[:space:]]*(\.|=)/ { unsupported=1 }
      {
        keyline=$0
        sub(/^[[:space:]]*/, "", keyline)
        quote=sprintf("%c", 39)
        if (substr(keyline, 1, 7) == quote "hosts" quote &&
            substr(keyline, 8) ~ /^[[:space:]]*(\.|=)/) unsupported=1
      }
      active && /^[[:space:]]*addr[[:space:]]*=/ {
        value=$0
        sub(/^[[:space:]]*addr[[:space:]]*=[[:space:]]*"/, "", value)
        sub(/"[[:space:]]*$/, "", value)
        addr=value
      }
      END {
        if (unsupported) print "@invalid"
        else if (count == 0) print "@absent"
        else if (count != 1 || addr == "") print "@invalid"
        else print addr
      }
    ' "$config"
}

sync_hosts() {
    local self name addr session config current owned changed=0
    validate_peers
    [[ -x "$tuios_bin" ]] || die "TUIOS binary missing: $tuios_bin"
    self="$(self_alias)"
    config="$("$tuios_bin" config path)" || die 'could not resolve TUIOS config path'
    [[ -n "$config" ]] || die 'TUIOS returned an empty config path'
    mkdir -p "$(dirname "$state_file")"
    if [[ ! -e "$state_file" ]]; then printf '{"schema":1,"hosts":{}}\n' > "$state_file"; fi
    jq -e '.schema == 1 and (.hosts | type == "object") and
      all(.hosts | to_entries[]; (.key | test("^[a-z][a-z0-9_-]*$")) and
        (.value | type == "string" and test("^[A-Za-z][A-Za-z0-9_.-]*$")))' \
      "$state_file" >/dev/null || die "invalid ownership record: $state_file"

    # Check every collision before changing any entry.
    while IFS=$'\t' read -r name addr session; do
        [[ "$name" == "$self" ]] && continue
        current="$(config_addr "$config" "$name")"
        owned="$(jq -r --arg name "$name" '.hosts[$name] // empty' "$state_file")"
        if [[ -z "$owned" && "$current" != @absent ]]; then
            die "host $name already exists outside Mesh; choose another name or remove it manually"
        fi
        if [[ -n "$owned" && "$current" != @absent && "$current" != "$owned" && "$current" != "$addr" ]]; then
            die "host $name was changed outside Mesh; leaving it untouched"
        fi
    done < <(jq -r '.hosts | to_entries[] | [.key, .value.ssh_alias, (.value.session // "")] | @tsv' "$peers_file")

    while IFS=$'\t' read -r name addr; do
        [[ -n "$name" ]] || continue
        if [[ "$name" == "$self" ]] || ! jq -e --arg name "$name" '.hosts[$name] != null' "$peers_file" >/dev/null; then
            current="$(config_addr "$config" "$name")"
            if [[ "$current" != @absent && "$current" != "$addr" ]]; then
                die "formerly owned host $name was edited outside Mesh; leaving it untouched"
            fi
        fi
    done < <(jq -r '.hosts | to_entries[] | [.key, .value] | @tsv' "$state_file")

    while IFS=$'\t' read -r name addr; do
        [[ -n "$name" ]] || continue
        if [[ "$name" == "$self" ]] || ! jq -e --arg name "$name" '.hosts[$name] != null' "$peers_file" >/dev/null; then
            current="$(config_addr "$config" "$name")"
            if [[ "$current" != @absent && "$current" != "$addr" ]]; then
                die "formerly owned host $name was edited outside Mesh; leaving it untouched"
            fi
            if [[ "$current" != @absent ]]; then "$tuios_bin" hosts remove "$name"; fi
            delete_owner "$name"
            changed=1
        fi
    done < <(jq -r '.hosts | to_entries[] | [.key, .value] | @tsv' "$state_file")

    while IFS=$'\t' read -r name addr session; do
        [[ "$name" == "$self" ]] && continue
        current="$(config_addr "$config" "$name")"
        owned="$(jq -r --arg name "$name" '.hosts[$name] // empty' "$state_file")"
        if [[ "$current" == "$addr" && "$owned" == "$addr" ]]; then continue; fi
        "$tuios_bin" hosts add "$name" "$addr" --connect-timeout 3
        [[ "$(config_addr "$config" "$name")" == "$addr" ]] || die "TUIOS did not save host $name"
        save_owner "$name" "$addr"
        changed=1
    done < <(jq -r '.hosts | to_entries[] | [.key, .value.ssh_alias, (.value.session // "")] | @tsv' "$peers_file")
    if [[ "$changed" == 1 && -n "${TUIOS_PANE_ID:-}" ]]; then
        printf 'New TUIOS hosts may wait until you run tuios config apply from a terminal outside TUIOS.\n'
    fi
}

show_status() {
    local self name addr session config current
    validate_peers
    [[ -x "$tuios_bin" ]] || die "TUIOS binary missing: $tuios_bin"
    self="$(self_alias)"
    config="$("$tuios_bin" config path)" || die 'could not resolve TUIOS config path'
    while IFS=$'\t' read -r name addr session; do
        [[ "$name" == "$self" ]] && continue
        current="$(config_addr "$config" "$name")"
        if [[ "$current" == "$addr" ]]; then
            printf '%s → %s (%s): configured\n' "$name" "$addr" "${session:-latest}"
        else
            printf '%s → %s (%s): missing or changed\n' "$name" "$addr" "${session:-latest}"
        fi
    done < <(jq -r '.hosts | to_entries[] | [.key, .value.ssh_alias, (.value.session // "")] | @tsv' "$peers_file")
    "$tuios_bin" hosts || printf 'TUIOS daemon is not running; use mesh tuios hosts doctor for a direct link test.\n'
}

doctor_hosts() {
    local self name addr session config current failed=0
    validate_peers
    [[ -x "$tuios_bin" ]] || die "TUIOS binary missing: $tuios_bin"
    self="$(self_alias)"
    config="$("$tuios_bin" config path)" || die 'could not resolve TUIOS config path'
    while IFS=$'\t' read -r name addr session; do
        [[ "$name" == "$self" ]] && continue
        current="$(config_addr "$config" "$name")"
        if [[ "$current" != "$addr" ]]; then
            printf '%s: missing or changed; run mesh tuios hosts sync\n' "$name" >&2
            failed=1
            continue
        fi
        if ! "$tuios_bin" hosts test "$name"; then
            printf '%s: link failed; verify SSH alias, key, host-key trust and TUIOS versions\n' "$name" >&2
            failed=1
        fi
    done < <(jq -r '.hosts | to_entries[] | [.key, .value.ssh_alias, (.value.session // "")] | @tsv' "$peers_file")
    return "$failed"
}

attach_host() {
    local name="${1:-}" session self addr config
    [[ "$name" =~ ^[a-z][a-z0-9_-]*$ ]] || die 'attach needs a Mesh peer name'
    validate_peers
    addr="$(jq -er --arg name "$name" '.hosts[$name].ssh_alias // empty' "$peers_file")" || die "unknown Mesh peer: $name"
    session="${2:-$(jq -r --arg name "$name" '.hosts[$name].session // empty' "$peers_file")}"
    if [[ -n "$session" ]]; then
        [[ "$session" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die 'invalid TUIOS session name'
    fi
    self="$(self_alias)"
    [[ "$name" != "$self" ]] || die 'this is the current Mesh machine; use tuios attach locally'
    [[ -x "$tuios_bin" ]] || die "TUIOS binary missing: $tuios_bin"
    config="$("$tuios_bin" config path)" || die 'could not resolve TUIOS config path'
    [[ "$(config_addr "$config" "$name")" == "$addr" ]] || die "host $name is not configured; run mesh tuios hosts sync"
    if [[ -n "$session" ]]; then
        exec "$tuios_bin" attach --host "$name" "$session" -c
    fi
    exec "$tuios_bin" attach --host "$name"
}

verb="${1:-}"
shift 2>/dev/null || true
if [[ "$verb" == hosts ]]; then verb="${1:-}"; shift 2>/dev/null || true; fi
case "$verb" in
    sync) [[ $# == 0 ]] || die 'sync takes no arguments'; sync_hosts ;;
    status) [[ $# == 0 ]] || die 'status takes no arguments'; show_status ;;
    doctor) [[ $# == 0 ]] || die 'doctor takes no arguments'; doctor_hosts ;;
    attach) [[ $# -ge 1 && $# -le 2 ]] || die 'usage: mesh tuios attach NAME [SESSION]'; attach_host "$@" ;;
    *) die "usage: mesh tuios hosts <sync|status|doctor> or mesh tuios attach NAME [SESSION]" ;;
esac
