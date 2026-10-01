#!/usr/bin/env bash
# Parse the optional, non-secret per-host TUIOS profile from a private identity.

tuios_profile_path() {
    printf '%s' "${MESH_TUIOS_PROFILE:-${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/config/tuios-hosts.json}"
}

tuios_profile_validate() {
    local file
    file="$(tuios_profile_path)"
    [[ -r "$file" ]] || { printf 'mesh tuios: profile missing: %s (run mesh tuios setup)\n' "$file" >&2; return 1; }
    jq -e '
      .schema == 1 and
      ((keys - ["schema", "hosts"]) | length == 0) and
      (.hosts | type == "object") and
      all(.hosts | to_entries[];
        (.key | test("^[a-z][a-z0-9_-]*$")) and
        (.value | type == "object") and
        (.value | (keys - ["access_aud", "access_email", "access_team", "local_port", "public_hostname", "remote_port", "session", "system_hostname", "tunnel_id"]) | length == 0) and
        (.value.system_hostname | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9.-]*$")) and
        (.value.public_hostname | type == "string" and test("^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]*[a-z0-9])?)+$")) and
        (.value.access_email | type == "string" and test("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,}$")) and
        (.value.session | type == "string" and test("^[A-Za-z0-9._-]+$")) and
        (.value.local_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        (.value.remote_port | type == "number" and floor == . and . >= 1 and . <= 65535) and
        ((.value.access_aud == null and .value.access_team == null) or
          ((.value.access_aud | type == "string" and test("^[0-9a-fA-F]{64}$")) and
           (.value.access_team | type == "string" and test("^[a-z0-9][a-z0-9-]*$")))) and
        (.value.tunnel_id == null or (.value.tunnel_id | type == "string" and test("^[0-9a-fA-F-]{36}$")))
      )
    ' "$file" >/dev/null 2>&1 || {
        printf 'mesh tuios: invalid non-secret profile: %s\n' "$file" >&2
        return 1
    }
}

tuios_profile_alias() {
    local requested="${1:-}" file alias physical
    tuios_profile_validate || return 1
    file="$(tuios_profile_path)"
    if [[ -n "$requested" ]]; then
        alias="$requested"
    elif [[ -n "${MESH_HOST_ALIAS:-}" ]]; then
        alias="$MESH_HOST_ALIAS"
    else
        physical="$(hostname -s 2>/dev/null || hostname)"
        alias="$(jq -er --arg physical "$physical" '
          first(.hosts | to_entries[] | select(.value.system_hostname == $physical) | .key) // empty
        ' "$file" 2>/dev/null)" || alias=""
    fi
    if [[ -z "$alias" ]] || ! jq -e --arg alias "$alias" '.hosts[$alias] != null' "$file" >/dev/null 2>&1; then
        printf 'mesh tuios: no profile for this host; use --host ALIAS or run mesh tuios setup\n' >&2
        return 1
    fi
    printf '%s' "$alias"
}

tuios_profile_get() {
    local alias="$1" field="$2" file
    file="$(tuios_profile_path)"
    jq -er --arg alias "$alias" --arg field "$field" '.hosts[$alias][$field] // empty' "$file"
}

tuios_access_redirect_ok() {
    tuios_access_team "$1" >/dev/null
}

tuios_access_team() {
    local hostname="$1" headers status location
    headers="$(curl -sSI --connect-timeout 8 --max-time 15 "https://$hostname/")" || return 1
    status="$(printf '%s\n' "$headers" | awk 'toupper($1) ~ /^HTTP\// {code=$2} END {print code}' | tr -d '\r')"
    location="$(printf '%s\n' "$headers" | awk 'tolower($1)=="location:" {print $2; exit}' | tr -d '\r')"
    [[ "$status" == 302 && "$location" =~ ^https://([a-z0-9][a-z0-9-]*)\.cloudflareaccess\.com/ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}
