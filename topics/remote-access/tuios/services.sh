#!/usr/bin/env bash
# Supervise the local TUIOS web client and an optional Access-protected origin.
# This file is sourced by Mesh's custom driver and by `mesh tuios setup`.

_tuios_service_os() { printf '%s' "${TUIOS_TEST_OS:-$(uname -s)}"; }
_tuios_service_bin() {
    local bin="${TUIOS_BIN_DIR:-$HOME/.local/bin}/tuios-web"
    [[ -x "$bin" ]] || { printf 'tuios: binary missing: %s\n' "$bin" >&2; return 1; }
    printf '%s' "$bin"
}
_tuios_service_systemd_dir() { printf '%s' "${TUIOS_SYSTEMD_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"; }
_tuios_service_launchd_dir() { printf '%s' "${TUIOS_LAUNCHD_DIR:-$HOME/Library/LaunchAgents}"; }
_tuios_service_session() { printf '%s' "${TUIOS_SESSION:-web}"; }

_tuios_service_validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

_tuios_service_validate_host() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9.-]*[a-z0-9]$ && "$1" == *.* && "$1" != *..* ]]
}

_tuios_service_port_busy() {
    local port="$1"
    if command -v lsof >/dev/null 2>&1; then
        lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1
    elif command -v ss >/dev/null 2>&1; then
        [[ -n "$(ss -H -ltn "( sport = :$port )" 2>/dev/null)" ]]
    else
        printf 'tuios: cannot check port %s (lsof or ss required)\n' "$port" >&2
        return 2
    fi
}

_tuios_service_new_port_available() {
    local path="$1" port="$2" rc
    [[ -e "$path" ]] && return 0
    if [[ "${TUIOS_SERVICE_DRY_RUN:-0}" == 1 && "${TUIOS_SERVICE_CHECK_PORTS_IN_DRY_RUN:-0}" != 1 ]]; then
        return 0
    fi
    _tuios_service_port_busy "$port" && rc=0 || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        printf 'tuios: port %s is in use; choose another port without stopping its owner\n' "$port" >&2
        return 1
    fi
    [[ "$rc" -eq 1 ]]
}

_tuios_service_unit_arg() {
    local value="$1"
    if [[ "$value" =~ ^[A-Za-z0-9_./:@=-]+$ ]]; then printf '%s' "$value"; return; fi
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '"%s"' "$value"
}

_tuios_service_xml() {
    printf '%s' "$1" | sed -e 's/\&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'
}

_tuios_service_render_systemd() {
    local name="$1" bin="$2" arg
    shift 2
    printf '# Managed by mesh-workstation: %s\n' "$name"
    printf '[Unit]\nDescription=TUIOS web terminal (%s)\nAfter=network.target\n\n' "$name"
    printf '[Service]\nType=simple\nExecStart='
    _tuios_service_unit_arg "$bin"
    for arg in "$@"; do printf ' '; _tuios_service_unit_arg "$arg"; done
    printf '\nRestart=on-failure\nRestartSec=3\n\n[Install]\nWantedBy=default.target\n'
}

_tuios_service_render_launchd() {
    local name="$1" bin="$2" label="com.mesh.$1" arg
    shift 2
    printf '<!-- Managed by mesh-workstation: %s -->\n' "$name"
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0"><dict>\n'
    printf '<key>Label</key><string>%s</string>\n' "$label"
    printf '<key>ProgramArguments</key><array>\n<string>%s</string>\n' "$(_tuios_service_xml "$bin")"
    for arg in "$@"; do printf '<string>%s</string>\n' "$(_tuios_service_xml "$arg")"; done
    printf '</array>\n<key>RunAtLoad</key><true/>\n<key>KeepAlive</key><true/>\n</dict></plist>\n'
}

_tuios_service_apply() {
    local name="$1" bin="$2" os dir path tmp desired_line label changed=0 port="" previous="" arg
    shift 2
    for arg in "$@"; do
        if [[ "$previous" == --port ]]; then port="$arg"; break; fi
        previous="$arg"
    done
    [[ -n "$port" ]] || return 1
    os="$(_tuios_service_os)"
    case "$os" in
        Linux)
            dir="$(_tuios_service_systemd_dir)"
            path="$dir/$name.service"
            _tuios_service_new_port_available "$path" "$port" || return 1
            mkdir -p "$dir"
            tmp="$(mktemp "$dir/.${name}.XXXXXX")" || return 1
            _tuios_service_render_systemd "$name" "$bin" "$@" > "$tmp"
            if [[ -f "$path" ]] && cmp -s "$path" "$tmp"; then
                rm -f "$tmp"
            elif [[ -f "$path" ]] && ! grep -qF "# Managed by mesh-workstation: $name" "$path"; then
                desired_line="$(grep '^ExecStart=' "$tmp" || true)"
                if ! grep -qxF "$desired_line" "$path"; then
                    rm -f "$tmp"
                    printf 'tuios: refusing to replace foreign unit %s\n' "$path" >&2
                    return 1
                fi
                rm -f "$tmp" # Exact legacy pilot command: adopt without rewriting.
            else
                mv -f "$tmp" "$path"
                changed=1
            fi
            [[ "${TUIOS_SERVICE_DRY_RUN:-0}" == 1 ]] && return 0
            systemctl --user show-environment >/dev/null 2>&1 || {
                printf 'tuios: systemd user manager unavailable; enable systemd in WSL, restart WSL, then rerun Mesh\n' >&2
                return 1
            }
            systemctl --user daemon-reload || return 1
            systemctl --user enable --now "$name.service" || return 1
            if [[ "$changed" -eq 1 ]]; then systemctl --user restart "$name.service" || return 1; fi
            ;;
        Darwin)
            dir="$(_tuios_service_launchd_dir)"
            label="com.mesh.$name"
            path="$dir/$label.plist"
            _tuios_service_new_port_available "$path" "$port" || return 1
            mkdir -p "$dir"
            tmp="$(mktemp "$dir/.${name}.XXXXXX")" || return 1
            _tuios_service_render_launchd "$name" "$bin" "$@" > "$tmp"
            if [[ -f "$path" ]] && cmp -s "$path" "$tmp"; then
                rm -f "$tmp"
            elif [[ -f "$path" ]] && ! grep -qF "Managed by mesh-workstation: $name" "$path"; then
                rm -f "$tmp"
                printf 'tuios: refusing to replace foreign LaunchAgent %s\n' "$path" >&2
                return 1
            else
                mv -f "$tmp" "$path"
                changed=1
            fi
            [[ "${TUIOS_SERVICE_DRY_RUN:-0}" == 1 ]] && return 0
            if [[ "$changed" -eq 1 ]]; then
                launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
            fi
            if ! launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
                launchctl bootstrap "gui/$(id -u)" "$path" || return 1
            fi
            ;;
        *) printf 'tuios: unsupported service platform %s\n' "$os" >&2; return 1 ;;
    esac
}

tuios_service_apply_local() {
    local bin port session
    bin="$(_tuios_service_bin)" || return 1
    port="${TUIOS_LOCAL_PORT:-7681}"
    session="$(_tuios_service_session)"
    _tuios_service_validate_port "$port" || return 1
    [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    _tuios_service_apply tuios-web-local "$bin" --host 127.0.0.1 --port "$port" --default-session "$session"
}

tuios_service_apply_remote() {
    local hostname="$1" port="$2" mode="$3" bin session password_file
    bin="$(_tuios_service_bin)" || return 1
    session="$(_tuios_service_session)"
    _tuios_service_validate_host "$hostname" || return 1
    _tuios_service_validate_port "$port" || return 1
    [[ "$session" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    case "$mode" in
        access)
            _tuios_service_apply tuios-web-remote "$bin" --host 127.0.0.1 --port "$port" \
                --allow-host "$hostname" --no-auth --default-session "$session" --max-connections 2 --touch on
            ;;
        password)
            password_file="${TUIOS_WEB_PASSWORD_FILE:-$HOME/.config/tuios/web-password}"
            [[ -r "$password_file" ]] || { printf 'tuios: password file missing: %s\n' "$password_file" >&2; return 1; }
            _tuios_service_apply tuios-web-remote "$bin" --host 127.0.0.1 --port "$port" \
                --allow-host "$hostname" --password-file "$password_file" --default-session "$session" --max-connections 2 --touch on
            ;;
        *) printf 'tuios: unknown remote auth mode %s\n' "$mode" >&2; return 1 ;;
    esac
}

check() {
    local os name path bin port session expected
    os="$(_tuios_service_os)"
    name=tuios-web-local
    bin="$(_tuios_service_bin)" || return 1
    port="${TUIOS_LOCAL_PORT:-7681}"
    session="$(_tuios_service_session)"
    case "$os" in
        Linux)
            path="$(_tuios_service_systemd_dir)/$name.service"
            expected="ExecStart=$bin --host 127.0.0.1 --port $port --default-session $session"
            [[ -f "$path" ]] && grep -qxF "$expected" "$path" || return 1
            [[ "${TUIOS_SERVICE_DRY_RUN:-0}" == 1 ]] && return 0
            systemctl --user is-enabled "$name.service" >/dev/null 2>&1 &&
                systemctl --user is-active "$name.service" >/dev/null 2>&1
            ;;
        Darwin)
            path="$(_tuios_service_launchd_dir)/com.mesh.$name.plist"
            [[ -f "$path" ]] || return 1
            grep -qF "Managed by mesh-workstation: $name" "$path" || return 1
            grep -qF "<string>$(_tuios_service_xml "$bin")</string>" "$path" || return 1
            grep -qF '<string>127.0.0.1</string>' "$path" || return 1
            grep -qF "<string>$port</string>" "$path" || return 1
            grep -qF "<string>$(_tuios_service_xml "$session")</string>" "$path" || return 1
            [[ "${TUIOS_SERVICE_DRY_RUN:-0}" == 1 ]] && return 0
            launchctl print "gui/$(id -u)/com.mesh.$name" >/dev/null 2>&1
            ;;
        *) return 1 ;;
    esac
}

install() { tuios_service_apply_local; }
verify() { check; }
repair() { install; }

restart() {
    local os name label
    os="$(_tuios_service_os)"
    [[ "${TUIOS_SERVICE_DRY_RUN:-0}" == 1 ]] && return 0
    for name in tuios-web-local tuios-web-remote; do
        if [[ "$os" == Linux ]]; then
            if systemctl --user is-active "$name.service" >/dev/null 2>&1; then
                systemctl --user restart "$name.service" || return 1
            fi
        elif [[ "$os" == Darwin ]]; then
            label="com.mesh.$name"
            if launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1; then
                launchctl kickstart -k "gui/$(id -u)/$label" || return 1
            fi
        fi
    done
}

uninstall() {
    local os name path marker
    local names=(tuios-web-local tuios-web-remote)
    if [[ $# -gt 0 ]]; then names=("$@"); fi
    os="$(_tuios_service_os)"
    for name in "${names[@]}"; do
        if [[ "$os" == Linux ]]; then
            path="$(_tuios_service_systemd_dir)/$name.service"
            marker="# Managed by mesh-workstation: $name"
            if [[ ! -f "$path" ]] || ! grep -qFx "$marker" "$path"; then continue; fi
            if [[ "${TUIOS_SERVICE_DRY_RUN:-0}" != 1 ]]; then
                systemctl --user disable --now "$name.service" || return 1
            fi
            rm -f "$path"
        elif [[ "$os" == Darwin ]]; then
            path="$(_tuios_service_launchd_dir)/com.mesh.$name.plist"
            marker="Managed by mesh-workstation: $name"
            if [[ ! -f "$path" ]] || ! grep -qF "$marker" "$path"; then continue; fi
            if [[ "${TUIOS_SERVICE_DRY_RUN:-0}" != 1 ]]; then
                launchctl bootout "gui/$(id -u)/com.mesh.$name" >/dev/null 2>&1 || true
            fi
            rm -f "$path"
        fi
    done
    if [[ "$os" == Linux && "${TUIOS_SERVICE_DRY_RUN:-0}" != 1 ]]; then
        systemctl --user daemon-reload || return 1
    fi
}

rollback() { uninstall tuios-web-local; }
