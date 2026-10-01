#!/usr/bin/env bash
# Operator CLI for the opt-in TUIOS browser-access bundle.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MESH_WORKSTATION_DIR:=$(cd "$HERE/../.." && pwd)}"
# shellcheck source=/dev/null
. "$MESH_WORKSTATION_DIR/scripts/lib/env.sh"
# shellcheck source=/dev/null
. "$MESH_WORKSTATION_DIR/topics/remote-access/tuios/profile.sh"

usage() {
    cat <<'EOF'
Usage: mesh tuios <setup|status|doctor> [--host ALIAS]

  setup   Configure a private host profile and protected Cloudflare publication
  status  Show this host's browser URL, shared session and service state
  doctor  Check local services and Access redirect without changing state
EOF
}

die() { printf 'mesh tuios: %s\n' "$*" >&2; exit 1; }

verb="${1:---help}"
shift 2>/dev/null || true
case "$verb" in -h|--help|help) usage; exit 0 ;; setup|status|doctor) ;; *) usage >&2; die "unknown verb: $verb" ;; esac

host="" confirm_email=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) [[ $# -ge 2 ]] || die '--host needs an alias'; host="$2"; shift 2 ;;
        --confirm-access-email) [[ $# -ge 2 ]] || die '--confirm-access-email needs an address'; confirm_email="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown option: $1" ;;
    esac
done

if [[ "$verb" == setup ]]; then
    script="${MESH_TUIOS_SETUP_SCRIPT:-$MESH_WORKSTATION_DIR/topics/remote-access/tuios/publish.sh}"
    [[ -r "$script" ]] || die "setup helper missing: $script"
    args=()
    if [[ -n "$host" ]]; then args=(--host "$host"); fi
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

[[ "$verb" == status ]] && exit 0

# Doctor is read-only; the publish helper adds deeper tunnel checks later.
if [[ "${TUIOS_SERVICE_DRY_RUN:-0}" == 1 ]]; then exit 0; fi
case "$(uname -s)" in
    Linux)
        systemctl --user is-active tuios-web-local.service >/dev/null 2>&1 || die 'local TUIOS web service is not active'
        systemctl --user is-active tuios-web-remote.service >/dev/null 2>&1 || die 'remote TUIOS web service is not active'
        if ! systemctl --user is-active "tuios-tunnel-$alias_name.service" >/dev/null 2>&1; then
            systemctl --user is-active "cloudflared-tuios-$alias_name.service" >/dev/null 2>&1 || die 'Cloudflare tunnel service is not active'
        fi
        ;;
    Darwin)
        launchctl print "gui/$(id -u)/com.mesh.tuios-web-local" >/dev/null 2>&1 || die 'local TUIOS web LaunchAgent is not loaded'
        launchctl print "gui/$(id -u)/com.mesh.tuios-web-remote" >/dev/null 2>&1 || die 'remote TUIOS web LaunchAgent is not loaded'
        ;;
esac
printf 'services: active\n'
tuios_access_redirect_ok "$hostname" || die 'Access redirect missing; remote origin may be exposed — run mesh tuios setup'
printf 'Access: protected\n'
