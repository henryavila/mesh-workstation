#!/usr/bin/env bash
# Set up one protected, host-local TUIOS browser route. Never enables a public
# no-auth origin until Access redirects anonymous requests and the operator
# confirms the exact-email policy configured in Cloudflare's Dashboard.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${MESH_WORKSTATION_DIR:=$(cd "$HERE/../../.." && pwd)}"
# shellcheck source=/dev/null
. "$HERE/profile.sh"
# shellcheck source=/dev/null
. "$HERE/services.sh"

_tuios_publish_fail() { printf 'mesh tuios setup: %s\n' "$*" >&2; exit 1; }
_tuios_cf_dir() { printf '%s' "${TUIOS_CLOUDFLARED_DIR:-$HOME/.cloudflared}"; }
_tuios_cf_bin() { printf '%s' "${TUIOS_CLOUDFLARED_BIN_DIR:-$HOME/.local/bin}/cloudflared"; }
_tuios_password_file() { printf '%s' "${TUIOS_WEB_PASSWORD_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/tuios/web-password}"; }

_tuios_setup_input() {
    local label="$1" value="${2:-}"
    if [[ -n "$value" ]]; then printf '%s' "$value"; return 0; fi
    [[ "${NON_INTERACTIVE:-0}" != 1 && -e /dev/tty ]] || return 1
    printf '%s: ' "$label" >/dev/tty
    IFS= read -r value </dev/tty || return 1
    [[ -n "$value" ]] || return 1
    printf '%s' "$value"
}

_tuios_profile_seed() {
    local requested="$1" file alias_name hostname email system_hostname local_port remote_port session tmp
    file="$(tuios_profile_path)"
    if [[ -f "$file" ]]; then
        tuios_profile_validate || return 1
        if tuios_profile_alias "$requested" >/dev/null 2>&1; then return 0; fi
    else
        mkdir -p "$(dirname "$file")"
        printf '{"schema":1,"hosts":{}}\n' > "$file"
    fi
    alias_name="$(_tuios_setup_input 'Mesh host alias' "${requested:-${MESH_TUIOS_SETUP_ALIAS:-}}")" || _tuios_publish_fail 'host alias required (use --host ALIAS)'
    hostname="$(_tuios_setup_input 'Public codename hostname' "${MESH_TUIOS_SETUP_HOSTNAME:-}")" || _tuios_publish_fail 'public hostname required'
    email="$(_tuios_setup_input 'Allowed Access email' "${MESH_TUIOS_SETUP_EMAIL:-}")" || _tuios_publish_fail 'allowed email required'
    [[ "$alias_name" =~ ^[a-z][a-z0-9_-]*$ ]] || _tuios_publish_fail 'host alias may contain lowercase letters, digits, underscore and dash'
    _tuios_service_validate_host "$hostname" || _tuios_publish_fail 'invalid public hostname'
    [[ "$email" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || _tuios_publish_fail 'invalid Access email'
    system_hostname="$(hostname -s 2>/dev/null || hostname)"
    local_port="${TUIOS_LOCAL_PORT:-7681}"
    remote_port="${TUIOS_REMOTE_PORT:-7685}"
    session="${TUIOS_SESSION:-web}"
    if ! _tuios_service_validate_port "$local_port" || ! _tuios_service_validate_port "$remote_port"; then
        _tuios_publish_fail 'invalid web port'
    fi
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    jq --arg alias "$alias_name" --arg system "$system_hostname" --arg hostname "$hostname" --arg email "$email" \
        --arg session "$session" --argjson local_port "$local_port" --argjson remote_port "$remote_port" \
        '.hosts[$alias] = {system_hostname:$system,public_hostname:$hostname,access_email:$email,session:$session,local_port:$local_port,remote_port:$remote_port}' \
        "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    MESH_TUIOS_PROFILE="$tmp" tuios_profile_validate || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp"
    mv -f "$tmp" "$file"
}

_tuios_profile_set_tunnel_id() {
    local file="$1" alias_name="$2" id="$3" tmp
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    jq --arg alias "$alias_name" --arg id "$id" '.hosts[$alias].tunnel_id = $id' "$file" > "$tmp" || {
        rm -f "$tmp"; return 1;
    }
    MESH_TUIOS_PROFILE="$tmp" tuios_profile_validate || { rm -f "$tmp"; return 1; }
    chmod 0644 "$tmp"
    mv -f "$tmp" "$file"
}

_tuios_tunnel_id_by_name() {
    local bin="$1" name="$2" listing
    listing="$("$bin" tunnel list --output json --name "$name")" || return 1
    printf '%s' "$listing" | jq -er --arg name "$name" '
      [.[] | select(.name == $name)] | if length == 1 then .[0].id else empty end
    '
}

_tuios_publish_password() {
    local file="$1"
    if [[ ! -f "$file" ]]; then
        mkdir -p "$(dirname "$file")"
        (umask 077; openssl rand -hex 24 > "$file") || return 1
    fi
    chmod 0600 "$file" || return 1
    [[ -s "$file" ]]
}

_tuios_publish_config() {
    local file="$1" id="$2" hostname="$3" port="$4" creds="$5" tmp
    tmp="$(mktemp "${file}.XXXXXX")" || return 1
    cat > "$tmp" <<EOF
# Managed by mesh-workstation: TUIOS browser access
tunnel: $id
credentials-file: $creds

ingress:
  - hostname: $hostname
    service: http://127.0.0.1:$port
  - service: http_status:404
EOF
    chmod 0600 "$tmp"
    if [[ -f "$file" ]] && cmp -s "$file" "$tmp"; then rm -f "$tmp"; return 0; fi
    if [[ -f "$file" ]] && ! grep -qF '# Managed by mesh-workstation: TUIOS browser access' "$file"; then
        rm -f "$tmp"
        printf 'mesh tuios setup: refusing to replace unmanaged tunnel config %s\n' "$file" >&2
        return 1
    fi
    mv -f "$tmp" "$file"
}

host_arg="" confirm_email=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host) [[ $# -ge 2 ]] || _tuios_publish_fail '--host needs an alias'; host_arg="$2"; shift 2 ;;
        --confirm-access-email) [[ $# -ge 2 ]] || _tuios_publish_fail '--confirm-access-email needs an address'; confirm_email="$2"; shift 2 ;;
        -h|--help)
            printf 'Usage: mesh tuios setup [--host ALIAS] [--confirm-access-email EMAIL]\n'
            exit 0
            ;;
        *) _tuios_publish_fail "unknown option $1" ;;
    esac
done

_tuios_profile_seed "$host_arg" || exit 1
alias_name="$(tuios_profile_alias "${host_arg:-${MESH_TUIOS_SETUP_ALIAS:-}}")" || exit 1
hostname="$(tuios_profile_get "$alias_name" public_hostname)"
email="$(tuios_profile_get "$alias_name" access_email)"
session="$(tuios_profile_get "$alias_name" session)"
local_port="$(tuios_profile_get "$alias_name" local_port)"
remote_port="$(tuios_profile_get "$alias_name" remote_port)"
tunnel_id="$(tuios_profile_get "$alias_name" tunnel_id 2>/dev/null || true)"
[[ -z "$confirm_email" || "$confirm_email" == "$email" ]] || _tuios_publish_fail "confirmed email does not match profile for $alias_name"

cf_dir="$(_tuios_cf_dir)"
cf_bin="$(_tuios_cf_bin)"
web_bin="${TUIOS_BIN_DIR:-$HOME/.local/bin}/tuios-web"
[[ -x "$cf_bin" && -x "$web_bin" ]] || _tuios_publish_fail 'install remote-access/tuios and remote-access/tuios-cloudflare first'
mkdir -p "$cf_dir"
chmod 0700 "$cf_dir"
if [[ -z "$tunnel_id" ]]; then
    if [[ ! -f "$cf_dir/cert.pem" ]]; then
        [[ "${NON_INTERACTIVE:-0}" != 1 ]] || _tuios_publish_fail 'Cloudflare account login required; run interactively'
        printf 'Authorize cloudflared for your DNS zone in the browser it opens.\n'
        "$cf_bin" tunnel login || _tuios_publish_fail 'Cloudflare login failed'
    fi
    tunnel_name="mesh-tuios-$alias_name"
    tunnel_id="$(_tuios_tunnel_id_by_name "$cf_bin" "$tunnel_name" 2>/dev/null || true)"
    if [[ -z "$tunnel_id" ]]; then
        "$cf_bin" tunnel create "$tunnel_name" || _tuios_publish_fail 'named tunnel creation failed'
        tunnel_id="$(_tuios_tunnel_id_by_name "$cf_bin" "$tunnel_name")" || _tuios_publish_fail 'created tunnel ID could not be found'
    fi
    _tuios_profile_set_tunnel_id "$(tuios_profile_path)" "$alias_name" "$tunnel_id" || exit 1
fi
credentials="$cf_dir/$tunnel_id.json"
[[ -r "$credentials" ]] || _tuios_publish_fail "tunnel credential missing: $credentials"
credential_mode="$(stat -c %a "$credentials" 2>/dev/null || stat -f %Lp "$credentials" 2>/dev/null)" || _tuios_publish_fail 'cannot inspect tunnel credential permissions'
case "$credential_mode" in
    400|600) ;;
    *) _tuios_publish_fail 'tunnel credential must have owner-only mode 0400 or 0600' ;;
esac
config="$cf_dir/mesh-tuios-$alias_name.yml"
route_marker="$cf_dir/mesh-tuios-$alias_name.route"
ready_marker="$cf_dir/mesh-tuios-$alias_name.access-ready"
password_file="$(_tuios_password_file)"
export TUIOS_WEB_PASSWORD_FILE="$password_file"
export TUIOS_SESSION="$session" TUIOS_LOCAL_PORT="$local_port"
mkdir -p "$cf_dir"

if [[ -f "$ready_marker" ]]; then
    [[ "$(cat "$ready_marker")" == "$tunnel_id $hostname $email" ]] || _tuios_publish_fail 'Access marker conflicts with profile'
    if tuios_access_redirect_ok "$hostname"; then
        mode=access
    else
        # Revoke the no-auth origin before returning: a removed Access app
        # must not make the already-published tunnel an open shell.
        rm -f "$ready_marker"
        _tuios_publish_password "$password_file" || _tuios_publish_fail 'cannot restore origin password'
        tuios_service_apply_remote "$hostname" "$remote_port" password || exit 1
        _tuios_publish_fail 'Cloudflare Access redirect disappeared; restored the origin password gate'
    fi
else
    mode=password
    _tuios_publish_password "$password_file" || _tuios_publish_fail 'cannot create protected origin password'
fi
tuios_service_apply_remote "$hostname" "$remote_port" "$mode" || exit 1
_tuios_publish_config "$config" "$tunnel_id" "$hostname" "$remote_port" "$credentials" || exit 1
tuios_service_apply_tunnel "$alias_name" "$config" "$tunnel_id" || exit 1

if [[ -f "$route_marker" ]]; then
    [[ "$(cat "$route_marker")" == "$tunnel_id $hostname" ]] || _tuios_publish_fail 'DNS route marker conflicts with profile'
else
    "$cf_bin" tunnel info "$tunnel_id" >/dev/null || _tuios_publish_fail 'named tunnel unavailable; check Cloudflare login'
    "$cf_bin" tunnel route dns "$tunnel_id" "$hostname" || _tuios_publish_fail 'DNS route failed; origin remains password-protected'
    printf '%s %s\n' "$tunnel_id" "$hostname" > "$route_marker"
    chmod 0600 "$route_marker"
fi

if [[ -n "$confirm_email" ]]; then
    tuios_access_redirect_ok "$hostname" || _tuios_publish_fail 'anonymous HTTPS does not redirect to Cloudflare Access; password remains active'
    tuios_service_apply_remote "$hostname" "$remote_port" access || exit 1
    printf '%s %s %s\n' "$tunnel_id" "$hostname" "$email" > "$ready_marker"
    chmod 0600 "$ready_marker"
    printf 'Access ready: https://%s/ (allowed email: %s)\n' "$hostname" "$email"
else
    printf 'Protected origin staged at https://%s/\n' "$hostname"
    printf 'In Cloudflare Access, allow only %s for this exact hostname.\n' "$email"
    printf 'After saving the policy, run: mesh tuios setup --host %s --confirm-access-email %s\n' "$alias_name" "$email"
fi
