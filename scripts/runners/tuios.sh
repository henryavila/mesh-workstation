#!/usr/bin/env bash
# Operator CLI for the opt-in TUIOS browser-access bundle.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER_ROOT="$(cd "$HERE/../.." && pwd)"
MESH_WORKSTATION_DIR="$RUNNER_ROOT"
export MESH_WORKSTATION_DIR
# shellcheck source=/dev/null
. "$RUNNER_ROOT/scripts/lib/env.sh"
# shellcheck source=/dev/null
. "$RUNNER_ROOT/topics/remote-access/tuios/profile.sh"

usage() {
    cat <<'EOF'
Usage: mesh tuios <setup|status|doctor|disable> [--host ALIAS]

  setup   Configure a private host profile and protected Cloudflare publication
  status  Show this host's browser URL, shared session and service state
  doctor  Check local services and Access redirect without changing state
  disable Stop Mesh-managed public services; preserve DNS and credentials
EOF
}

die() { printf 'mesh tuios: %s\n' "$*" >&2; exit 1; }
launch_agent_running() {
    local state
    state="$(launchctl print "gui/$(id -u)/com.mesh.$1" 2>/dev/null)" || return 1
    grep -qE 'state[[:space:]]*=[[:space:]]*running' <<< "$state"
}

verb="${1:---help}"
shift 2>/dev/null || true
case "$verb" in -h|--help|help) usage; exit 0 ;; setup|status|doctor|disable) ;; *) usage >&2; die "unknown verb: $verb" ;; esac

host="" confirm_email=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) [[ $# -ge 2 ]] || die '--host needs an alias'; host="$2"; shift 2 ;;
        --confirm-access-email) [[ $# -ge 2 ]] || die '--confirm-access-email needs an address'; confirm_email="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

if [[ "$verb" == setup || "$verb" == disable ]]; then
    script="${MESH_TUIOS_SETUP_SCRIPT:-$RUNNER_ROOT/topics/remote-access/tuios/publish.sh}"
    [[ -r "$script" ]] || die "setup helper missing: $script"
    args=()
    if [[ -n "$host" ]]; then args=(--host "$host"); fi
    if [[ "$verb" == disable ]]; then
        [[ -z "$confirm_email" ]] || die '--confirm-access-email applies only to setup'
        args+=(--disable)
    fi
    if [[ -n "$confirm_email" ]]; then args+=(--confirm-access-email "$confirm_email"); fi
    exec bash "$script" "${args[@]}"
fi
[[ -z "$confirm_email" ]] || die '--confirm-access-email applies only to setup'

alias_name="$(tuios_profile_alias "$host")" || exit 1
hostname="$(tuios_profile_get "$alias_name" public_hostname)" || exit 1
session="$(tuios_profile_get "$alias_name" session)" || exit 1
local_port="$(tuios_profile_get "$alias_name" local_port)" || exit 1
remote_port="$(tuios_profile_get "$alias_name" remote_port)" || exit 1
printf 'host: %s\nurl: https://%s\nsession: %s\nlocal port: %s\nremote port: %s\n' \
    "$alias_name" "$hostname" "$session" "$local_port" "$remote_port"

if [[ "${TUIOS_SERVICE_DRY_RUN:-0}" == 1 ]]; then exit 0; fi

tuios_cli="${TUIOS_BIN_DIR:-$HOME/.local/bin}/tuios"
tuios_web="${TUIOS_BIN_DIR:-$HOME/.local/bin}/tuios-web"
cloudflared="${TUIOS_CLOUDFLARED_BIN_DIR:-$HOME/.local/bin}/cloudflared"
cli_version="$("$tuios_cli" --version 2>/dev/null | awk '$2 == "version" {print $3; exit}')"
web_version="$("$tuios_web" --version 2>/dev/null | awk '$2 == "version" {print $3; exit}')"
cloudflared_version="$("$cloudflared" --version 2>/dev/null | awk '$2 == "version" {print $3; exit}')"
printf 'versions: tuios=%s tuios-web=%s cloudflared=%s\n' \
    "${cli_version:-missing}" "${web_version:-missing}" "${cloudflared_version:-missing}"
healthy=1
if [[ -z "$cli_version" || "$cli_version" != "$web_version" || -z "$cloudflared_version" ]]; then healthy=0; fi

service_running() {
    local name="$1"
    case "${TUIOS_TEST_OS:-$(uname -s)}" in
        Linux) systemctl --user is-active "$name.service" >/dev/null 2>&1 ;;
        Darwin) launch_agent_running "$name" ;;
        *) return 1 ;;
    esac
}

for name in tuios-web-local tuios-web-remote; do
    if service_running "$name"; then
        printf '%s: active\n' "$name"
    else
        printf '%s: inactive\n' "$name"
        healthy=0
    fi
done
if service_running "tuios-tunnel-$alias_name" ||
    { [[ "${TUIOS_TEST_OS:-$(uname -s)}" == Linux ]] && service_running "cloudflared-tuios-$alias_name"; }; then
    printf 'tunnel service: active\n'
else
    printf 'tunnel service: inactive\n'
    healthy=0
fi

local_http="$(curl -sS --noproxy '*' -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 "http://127.0.0.1:$local_port/" 2>/dev/null)" || local_http=""
remote_http="$(curl -sS --noproxy '*' -H "Host: $hostname" -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 6 "http://127.0.0.1:$remote_port/" 2>/dev/null)" || remote_http=""
if [[ "$local_http" == 200 && ( "$remote_http" == 200 || "$remote_http" == 401 ) ]]; then
    printf 'origins: reachable\n'
else
    printf 'origins: unhealthy (local=%s remote=%s)\n' "${local_http:-?}" "${remote_http:-?}"
    healthy=0
fi

tunnel_id="$(tuios_profile_get "$alias_name" tunnel_id 2>/dev/null || true)"
tunnel_json=""
if [[ -n "$tunnel_id" && -x "$cloudflared" ]]; then
    tunnel_json="$("$cloudflared" tunnel info --output json "$tunnel_id" 2>/dev/null)" || tunnel_json=""
fi
if [[ -n "$tunnel_json" ]] && jq -e --arg id "$tunnel_id" \
    '.id == $id and any(.conns[]?; any(.conns[]?; .is_pending_reconnect == false))' \
    <<< "$tunnel_json" >/dev/null 2>&1; then
    printf 'tunnel: connected\n'
else
    printf 'tunnel: disconnected\n'
    healthy=0
fi

if tuios_access_redirect_ok "$hostname"; then
    printf 'Access: protected\n'
else
    printf 'Access: redirect missing\n'
    healthy=0
fi
if [[ "$verb" == doctor && "$healthy" -ne 1 ]]; then
    die "health check failed; run bash setup.sh --bundle remote-access/tuios --bundle remote-access/tuios-cloudflare, then mesh tuios setup --host $alias_name"
fi
