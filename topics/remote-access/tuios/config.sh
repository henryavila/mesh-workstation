#!/usr/bin/env bash
# Canonical locally managed tunnel config. Exact comparison prevents comments
# or a different ingress rule from masquerading as an Access JWT gate.

tuios_config_render() {
    local id="$1" hostname="$2" port="$3" creds="$4" mode="$5" team="$6" aud="$7"
    case "$mode" in
        jwt) [[ "$team" =~ ^[a-z0-9][a-z0-9-]*$ && "$aud" =~ ^[0-9a-fA-F]{64}$ ]] || return 1 ;;
        password) ;;
        *) return 1 ;;
    esac
    cat <<EOF
# Managed by mesh-workstation: TUIOS browser access
tunnel: $id
credentials-file: $creds

ingress:
  - hostname: $hostname
    service: http://127.0.0.1:$port
EOF
    if [[ "$mode" == jwt ]]; then
        cat <<EOF
    originRequest:
      access:
        required: true
        teamName: $team
        audTag:
          - $aud
EOF
    fi
    printf '  - service: http_status:404\n'
}

tuios_config_matches() {
    local file="$1"
    shift
    [[ -f "$file" ]] && cmp -s "$file" <(tuios_config_render "$@")
}
