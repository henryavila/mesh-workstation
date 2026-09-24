#!/usr/bin/env bash
# Custom: code-server (mac) — bundles the original 697-LOC install.mac.sh
# verbatim under the engine contract.

_code_server_workstation_root() {
    local here root
    if [[ -n "${MESH_WORKSTATION_DIR:-}" ]]; then
        [[ -d "$MESH_WORKSTATION_DIR/scripts/lib" ]] || return 1
        (cd "$MESH_WORKSTATION_DIR" && pwd -P)
        return
    fi

    here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
    root="$(cd "$here/../../.." && pwd -P)" || return 1
    [[ -d "$root/scripts/lib" ]] || return 1
    printf '%s\n' "$root"
}

_code_server_load_github_api() {
    declare -f gh_api_curl >/dev/null 2>&1 && return 0

    local root
    root="$(_code_server_workstation_root)" || return 1
    # shellcheck source=/dev/null
    . "$root/scripts/lib/github-api.sh"
}

check() {
    # Idempotency requires all 3 pieces present, not just the binary.
    # Codex review 2026-05-19 (E-F001): the previous check matched any
    # code-server binary on disk, even with no config/LaunchAgent/listener.
    local bin="${HOME}/.local/bin/code-server"
    local alt="${HOME}/.local/lib/code-server/bin/code-server"
    local label="${CODE_SERVER_LABEL:-com.${USER}.code-server}"
    local plist="${HOME}/Library/LaunchAgents/${label}.plist"
    local config="${HOME}/.config/code-server/config.yaml"
    local user_data="${HOME}/.local/share/code-server"
    local user_dir="${user_data}/User"
    local global_storage="${user_dir}/globalStorage"

    # F9.6 §D filesystem hardening (2026-06-03): `[[ -x ]]` on the
    # ~/.local/bin/code-server symlink follows the link, but a present exec
    # bit on a half-installed / corrupt standalone bundle (e.g. an aborted
    # version-dir swap, a wrong-arch binary, or a broken bundled node) still
    # passed the bare check — the engine then KEEPs an unrunnable install.
    # Content sentinel: assert the binary actually executes `--version`,
    # exactly the success gate install_code_server_standalone() already uses
    # (line "$CODE_SERVER_BIN" --version >/dev/null). sudo-free, bash-3.2
    # safe; a healthy install runs --version in well under a second.
    local found=""
    if [[ -x "$bin" ]]; then
        found="$bin"
    elif [[ -x "$alt" ]]; then
        found="$alt"
    fi
    [[ -n "$found" ]] || return 1
    "$found" --version >/dev/null 2>&1 || return 1

    [[ -f "$plist" ]] || return 1
    [[ -f "$config" ]] || return 1
    [[ -d "$user_data" && -d "$user_dir" && -d "$global_storage" ]] || return 1
    [[ -w "$user_data" && -w "$user_dir" && -w "$global_storage" ]] || return 1
    return 0
}

_code_server_uninstall_clear_tailscale_serve() {
    local port="$1" status state reset_rc=0

    [[ "${CODE_SERVER_TAILSCALE_SERVE:-1}" == "1" ]] || return 0
    command -v tailscale >/dev/null 2>&1 || return 0

    status="$(tailscale serve status --json 2>/dev/null)" || return 0
    [[ -n "$status" ]] || return 0

    if ! command -v python3 >/dev/null 2>&1; then
        printf 'code-server uninstall: python3 unavailable; leaving Tailscale Serve config untouched\n' >&2
        return 0
    fi

    state="$(CODE_SERVER_PORT="$port" TS_STATUS_JSON="$status" python3 - <<'PY'
import json
import os
import sys

want = f"http://127.0.0.1:{os.environ['CODE_SERVER_PORT']}"
try:
    data = json.loads(os.environ["TS_STATUS_JSON"])
except Exception:
    print("unknown")
    sys.exit(0)

web = data.get("Web") if isinstance(data, dict) else {}
tcp = data.get("TCP") if isinstance(data, dict) else {}
proxies = []

if isinstance(web, dict):
    for host, cfg in web.items():
        if not isinstance(cfg, dict):
            continue
        handlers = cfg.get("Handlers")
        if not isinstance(handlers, dict):
            continue
        for path, handler in handlers.items():
            if isinstance(handler, dict) and handler.get("Proxy"):
                proxies.append((host, path, handler.get("Proxy")))

if not proxies:
    print("empty")
    sys.exit(0)

tcp_ok = not tcp
if isinstance(tcp, dict) and set(tcp.keys()) == {"443"}:
    v = tcp.get("443")
    tcp_ok = isinstance(v, dict) and v.get("HTTPS") is True and len(v) == 1

if len(proxies) == 1 and proxies[0][1] == "/" and proxies[0][2] == want and tcp_ok:
    print("dedicated")
elif any(proxy == want for _, _, proxy in proxies):
    print("mixed")
else:
    print("other")
PY
)" || state="unknown"

    case "$state" in
        dedicated)
            tailscale serve reset >/dev/null 2>&1 || reset_rc=$?
            if [[ "$reset_rc" -ne 0 ]]; then
                printf 'code-server uninstall: tailscale serve reset failed (rc=%s)\n' "$reset_rc" >&2
                return "$reset_rc"
            fi
            ;;
        mixed)
            printf 'code-server uninstall: Tailscale Serve has other handlers; leaving Serve config untouched\n' >&2
            ;;
    esac
    return 0
}

_code_server_uninstall_user_data_size() {
    local dir="$1" size
    size="$(du -sh "$dir" 2>/dev/null | awk '{print $1}' || true)"
    printf '%s' "${size:-unknown size}"
}

_code_server_uninstall_load_log_lib() {
    declare -f confirm >/dev/null 2>&1 && return 0
    local root
    root="$(_code_server_workstation_root)" || return 1
    # shellcheck disable=SC1091
    . "$root/scripts/lib/log.sh"
}

_code_server_uninstall_prompt_purge_user_data() {
    local dir="$1" size answer="${CODE_SERVER_PURGE_USER_DATA:-ask}"
    [[ -d "$dir" ]] || return 1

    case "$answer" in
        1|yes|true|on) return 0 ;;
        0|no|false|off) return 1 ;;
    esac

    size="$(_code_server_uninstall_user_data_size "$dir")"
    if [[ "${NON_INTERACTIVE:-0}" == "1" || ! -e "${MESH_PROMPT_IN:-/dev/tty}" ]]; then
        printf 'code-server uninstall: preserving user data at %s (%s). Remove that directory manually if you do not want to keep personal code-server data.\n' "$dir" "$size" >&2
        return 1
    fi

    _code_server_uninstall_load_log_lib
    confirm "Remove code-server user data at $dir ($size)?" n
}

uninstall() {
    # Remove only the runtime footprint installed by this bundle. Preserve
    # VS Code user data (extensions, globalStorage, sessions) unless the user
    # confirms the destructive purge.
    [[ "$(uname -s)" == "Darwin" ]] || return 0

    local label="${CODE_SERVER_LABEL:-com.${USER}.code-server}"
    local port="${CODE_SERVER_PORT:-8091}"
    local prefix="${CODE_SERVER_INSTALL_PREFIX:-$HOME/.local}"
    local plist="$HOME/Library/LaunchAgents/${label}.plist"
    local wrapper="${prefix}/bin/code-server-service"
    local bin="${prefix}/bin/code-server"
    local config_dir="$HOME/.config/code-server"
    local state_dir="$HOME/.local/state/code-server"
    local user_data_dir="$HOME/.local/share/code-server"
    local uid dir rc=0

    if [[ "$prefix" != "$HOME/.local" ]]; then
        printf 'code-server uninstall: refusing unsupported CODE_SERVER_INSTALL_PREFIX=%s\n' "$prefix" >&2
        return 1
    fi

    uid="$(id -u)"
    if command -v launchctl >/dev/null 2>&1; then
        if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
            local i
            launchctl bootout "gui/${uid}/${label}" >/dev/null 2>&1 || return 1
            for i in 1 2 3 4 5; do
                launchctl print "gui/${uid}/${label}" >/dev/null 2>&1 || break
                sleep 1
            done
            if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
                printf 'code-server uninstall: LaunchAgent still loaded after bootout: %s\n' "$label" >&2
                return 1
            fi
        fi
    fi

    _code_server_uninstall_clear_tailscale_serve "$port" || rc=$?

    rm -f "$plist" "$wrapper" "$bin" 2>/dev/null || rc=1
    for dir in "$prefix/lib/code-server" "$prefix"/lib/code-server-* "$config_dir" "$state_dir"; do
        if [[ -e "$dir" ]]; then
            rm -rf "$dir" 2>/dev/null || rc=1
        fi
    done

    if _code_server_uninstall_prompt_purge_user_data "$user_data_dir"; then
        dir="$user_data_dir"
        if [[ -e "$dir" ]]; then
            rm -rf "$dir" 2>/dev/null || rc=1
        fi
    fi

    [[ "$rc" -eq 0 ]] || return "$rc"
    ! check
}

remove_legacy_codex_compat_shim() {
    # Until 2026-07 a generated ~/.local/bin/code-server-codex-compat script
    # patched installed extension bundles (openai.chatgpt / anthropic.claude-code)
    # to work around the Node navigator global (PendingMigrationError) and
    # webview preload issues under code-server. That approach broke on every
    # extension auto-update. Replaced by the official VS Code setting
    # "extensions.supportNodeGlobalNavigator": true written by
    # write_code_server_machine_settings(). This migration restores patched
    # bundles from their backups and removes the shim so already-provisioned
    # machines heal on the next run.
    local shim="${CODE_SERVER_INSTALL_PREFIX}/bin/code-server-codex-compat"
    local extensions_root="${CODE_SERVER_USER_DATA_DIR}/extensions"
    local bak orig cleaned=0

    if [[ -d "$extensions_root" ]]; then
        # Restore .bak-mesh-navigator LAST: it is the pristine copy taken
        # before any other patch layered on top (.bak-mesh-webview-cache holds
        # an already navigator-patched bundle of the same file).
        while IFS= read -r -d '' bak; do
            orig="${bak%.bak-mesh-*}"
            cp -p "$bak" "$orig" && rm -f "$bak" && cleaned=1
        done < <(find "$extensions_root" -name '*.bak-mesh-*' ! -name '*.bak-mesh-navigator' -type f -print0 2>/dev/null)
        while IFS= read -r -d '' bak; do
            orig="${bak%.bak-mesh-navigator}"
            cp -p "$bak" "$orig" && rm -f "$bak" && cleaned=1
        done < <(find "$extensions_root" -name '*.bak-mesh-navigator' -type f -print0 2>/dev/null)
        while IFS= read -r -d '' bak; do
            rm -f "$bak" && cleaned=1
        done < <(find "$extensions_root" \( -name '*.mesh-preload-css.js' -o -name '*.mesh-cache.js' -o -name '*.mesh-cache.css' \) -type f -print0 2>/dev/null)
    fi

    if [[ -e "$shim" ]]; then
        rm -f "$shim"
        cleaned=1
    fi

    if [[ "$cleaned" -eq 1 ]]; then
        ok "removed legacy code-server-codex-compat shim and restored patched extension bundles"
    fi
}

write_code_server_machine_settings() {
    # Agent extensions (Claude Code, OpenAI Codex) touch the Node navigator
    # global; without supportNodeGlobalNavigator the extension host throws
    # PendingMigrationError on activation and their webviews hang. The SERVER
    # side configuration service reads REMOTE MACHINE settings
    # (<user-data>/Machine/settings.json) when forking the extension host —
    # NOT <user-data>/User/settings.json (verified against server-main.js:
    # `new ...(a.machineSettingsResource, ...)` feeds the getValue that pushes
    # the flag). So the setting must live here to take effect.
    # remote.autoForwardPorts is merged on every run so a later flag cannot
    # be skipped just because supportNodeGlobalNavigator is already true.
    local machine_dir="${CODE_SERVER_USER_DATA_DIR}/Machine"
    local machine_settings="${machine_dir}/settings.json"
    local merge_state

    mkdir -p "$machine_dir"

    if [[ ! -f "$machine_settings" ]] || ! grep -q '[^[:space:]]' "$machine_settings"; then
        printf '{\n  "extensions.supportNodeGlobalNavigator": true,\n  "remote.autoForwardPorts": false\n}\n' > "$machine_settings"
        ok "wrote code-server machine settings (supportNodeGlobalNavigator, remote.autoForwardPorts off)"
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        merge_state="$(python3 - "$machine_settings" <<'PY'
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    data = json.load(f)
if not isinstance(data, dict):
    sys.exit(1)
changed = False
if data.get("extensions.supportNodeGlobalNavigator") is not True:
    data["extensions.supportNodeGlobalNavigator"] = True
    changed = True
if data.get("remote.autoForwardPorts") is not False:
    data["remote.autoForwardPorts"] = False
    changed = True
if not changed:
    print("unchanged")
    sys.exit(0)
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
os.replace(tmp, path)
print("merged")
PY
)" && case "$merge_state" in
            unchanged)
                ok "code-server machine settings already include supportNodeGlobalNavigator and remote.autoForwardPorts off"
                return 0
                ;;
            merged)
                ok "merged supportNodeGlobalNavigator and remote.autoForwardPorts into code-server machine settings"
                return 0
                ;;
        esac
    fi

    followup manual "could not merge extensions.supportNodeGlobalNavigator and remote.autoForwardPorts into $machine_settings — set \"extensions.supportNodeGlobalNavigator\": true and \"remote.autoForwardPorts\": false manually and restart code-server, or agent extensions (Claude/Codex) will fail with PendingMigrationError."
    return 0
}

decode_detect_brew_value() {
    local raw="$1"
    raw="${raw//\\ / }"
    printf '%s' "$raw"
}

append_extra_path() {
    local entry="$1"
    [[ -z "$entry" ]] && return 0
    : "${CODE_SERVER_EXTRA_PATH:=}"
    case ":$CODE_SERVER_EXTRA_PATH:" in
        *":$entry:"*) ;;
        *)
            if [[ -z "$CODE_SERVER_EXTRA_PATH" ]]; then
                CODE_SERVER_EXTRA_PATH="$entry"
            else
                CODE_SERVER_EXTRA_PATH="${CODE_SERVER_EXTRA_PATH}:$entry"
            fi
            ;;
    esac
}

detect_code_server_env() {
    : "${CODE_SERVER_EXTRA_PATH:=}"
    if [[ "$CODE_SERVER_INSTALL_METHOD" != "standalone" ]]; then
        followup critical "CODE_SERVER_INSTALL_METHOD=$CODE_SERVER_INSTALL_METHOD is not supported yet. Use CODE_SERVER_INSTALL_METHOD=standalone."
        exit 1
    fi

    if [[ "$CODE_SERVER_INSTALL_PREFIX" != "$HOME/.local" ]]; then
        followup critical "CODE_SERVER_INSTALL_PREFIX must be $HOME/.local in this release. External prefixes need a separate wrapper design."
        exit 1
    fi

    if [[ ! -d "$CODE_SERVER_WORKDIR" ]]; then
        followup critical "CODE_SERVER_WORKDIR does not exist: $CODE_SERVER_WORKDIR"
        exit 1
    fi
    CODE_SERVER_WORKDIR="$(cd "$CODE_SERVER_WORKDIR" && pwd -P)"

    CODE_SERVER_BIN="${CODE_SERVER_INSTALL_PREFIX}/bin/code-server"
    CODE_SERVER_SERVICE_WRAPPER="${CODE_SERVER_INSTALL_PREFIX}/bin/code-server-service"
    CODE_SERVER_CONFIG_DIR="${HOME}/.config/code-server"
    CODE_SERVER_CONFIG_FILE="${CODE_SERVER_CONFIG_DIR}/config.yaml"
    CODE_SERVER_STATE_DIR="${HOME}/.local/state/code-server"
    CODE_SERVER_USER_DATA_DIR="${HOME}/.local/share/code-server"
    CODE_SERVER_PLIST="${HOME}/Library/LaunchAgents/${CODE_SERVER_LABEL}.plist"

    if [[ -z "${BREW_PREFIX:-}" ]]; then
        local detect_out line
        if detect_out="$(bash "$HERE/../../scripts/lib/detect-brew.sh" 2>/dev/null)"; then
            while IFS= read -r line; do
                case "$line" in
                    BREW_BIN=*) BREW_BIN="$(decode_detect_brew_value "${line#BREW_BIN=}")" ;;
                    BREW_PREFIX=*) BREW_PREFIX="$(decode_detect_brew_value "${line#BREW_PREFIX=}")" ;;
                    "") ;;
                    *) followup manual "unexpected output from detect-brew.sh while preparing code-server PATH; ignoring line: $line" ;;
                esac
            done <<< "$detect_out"
        fi
    fi

    if [[ -n "${BREW_PREFIX:-}" ]]; then
        append_extra_path "$BREW_PREFIX/bin"
        append_extra_path "$BREW_PREFIX/sbin"
    fi
    append_extra_path "/opt/homebrew/bin"
    append_extra_path "/usr/local/bin"
    append_extra_path "/usr/bin"
    append_extra_path "/bin"
    append_extra_path "/usr/sbin"
    append_extra_path "/sbin"
}

# Exactly one uncommented auth line, and that line must be `auth: password`.
# `auth: none` plus a stale hash is not a healthy config.
_code_server_effective_auth_is_password() {
    local file="$1" password_lines auth_lines
    [[ -f "$file" ]] || return 1
    password_lines="$(grep -Ec '^[[:space:]]*auth:[[:space:]]*password[[:space:]]*$' "$file" || true)"
    auth_lines="$(grep -Ec '^[[:space:]]*auth:' "$file" || true)"
    [[ "$password_lines" == "1" && "$auth_lines" == "1" ]]
}

install() {
    local HERE
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    HERE="$HERE/.."
    # shellcheck disable=SC1091
    . "${MESH_WORKSTATION_DIR:-$(cd "$HERE/../.." && pwd)}/scripts/lib/log.sh"
    # shellcheck disable=SC1091
    . "${MESH_WORKSTATION_DIR:-$(cd "$HERE/../.." && pwd)}/scripts/lib/launch-wrapper.sh"

    # Env defaults (preserved from original install.mac.sh header)
    : "${CODE_SERVER_PORT:=8091}"
    : "${CODE_SERVER_LABEL:=com.${USER}.code-server}"
    : "${CODE_SERVER_TAILSCALE_SERVE:=0}"
    : "${CODE_SERVER_INSTALL_PREFIX:=$HOME/.local}"
    : "${CODE_SERVER_INSTALL_METHOD:=standalone}"
    : "${CODE_SERVER_UPGRADE:=0}"
    : "${CODE_SERVER_CHECK_UPDATES:=1}"

CODE_SERVER_BIN=""
CODE_SERVER_SERVICE_WRAPPER=""
CODE_SERVER_CONFIG_DIR=""
CODE_SERVER_CONFIG_FILE=""
CODE_SERVER_STATE_DIR=""
CODE_SERVER_USER_DATA_DIR=""
CODE_SERVER_PLIST=""
CODE_SERVER_WORKDIR="${CODE_SERVER_WORKDIR:-$HOME}"
CODE_SERVER_EXTRA_PATH=""
CODE_SERVER_GENERATED_PASSWORD=""
BREW_BIN="${BREW_BIN:-}"
BREW_PREFIX="${BREW_PREFIX:-}"

    # Resolved port. 8080 is the retired code-server default; refuse it before
    # any config, plist, or tailscale command.
    if [[ "$CODE_SERVER_PORT" == "8080" ]]; then
        followup critical "refusing CODE_SERVER_PORT=8080; code-server listens on 127.0.0.1:8091."
        exit 1
    fi

require_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        followup critical "85-code-server is macOS-only in this release; skipping $(uname -s)."
        exit 1
    fi
}

plist_escape() {
    local value="$1"
    value="${value//&/&amp;}"
    value="${value//</&lt;}"
    value="${value//>/&gt;}"
    value="${value//\"/&quot;}"
    value="${value//\'/&apos;}"
    printf '%s' "$value"
}

has_ctty() {
    [[ -t 0 && -t 1 && -r /dev/tty && -w /dev/tty ]]
}

normalize_code_server_version() {
    local raw="$1" version
    version="$(printf '%s\n' "$raw" | awk '{
        value=$1
        sub(/^v/, "", value)
        if (match(value, /^[0-9]+(\.[0-9]+)?(\.[0-9]+)?/)) {
            print substr(value, RSTART, RLENGTH)
        }
    }')"
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

code_server_current_version() {
    [[ -x "$CODE_SERVER_BIN" ]] || return 1
    "$CODE_SERVER_BIN" --version 2>/dev/null | sed -n '1p' | awk '{ print $1; exit }'
}

semver_gt() {
    local left right
    left="$(normalize_code_server_version "$1")" || return 1
    right="$(normalize_code_server_version "$2")" || return 1

    awk -v left="$left" -v right="$right" '
        function split_version(version, parts,    n, i) {
            n = split(version, parts, ".")
            for (i = n + 1; i <= 3; i++) {
                parts[i] = 0
            }
        }
        BEGIN {
            split_version(left, a)
            split_version(right, b)
            for (i = 1; i <= 3; i++) {
                if ((a[i] + 0) > (b[i] + 0)) exit 0
                if ((a[i] + 0) < (b[i] + 0)) exit 1
            }
            exit 1
        }
    '
}

fetch_latest_code_server_version() {
    local body tag

    if [[ -n "${CODE_SERVER_LATEST_VERSION:-}" ]]; then
        normalize_code_server_version "$CODE_SERVER_LATEST_VERSION"
        return
    fi

    command -v curl >/dev/null 2>&1 || return 1
    _code_server_load_github_api || return 1
    body="$(gh_api_curl "https://api.github.com/repos/coder/code-server/releases/latest" 2>/dev/null)" || return 1
    tag="$(printf '%s\n' "$body" | awk -F'"' '/"tag_name"[[:space:]]*:/ { print $4; exit }')"
    normalize_code_server_version "$tag"
}

record_code_server_final_info() {
    local msg="$1"
    if [[ -n "${MESH_FOLLOWUP_FILE:-}" ]]; then
        printf '%s\x1f%s\x1e' "info" "$msg" >> "$MESH_FOLLOWUP_FILE" 2>/dev/null || true
    else
        info "$msg"
    fi
}

maybe_report_code_server_update() {
    [[ "$CODE_SERVER_CHECK_UPDATES" == "1" ]] || return 0
    [[ "$CODE_SERVER_UPGRADE" != "1" ]] || return 0

    local current latest bootstrap_path command
    current="$(code_server_current_version 2>/dev/null || true)"
    current="$(normalize_code_server_version "$current" 2>/dev/null || true)"
    [[ -n "$current" ]] || return 0

    if ! latest="$(fetch_latest_code_server_version 2>/dev/null)"; then
        info "code-server update check skipped (latest upstream release unavailable)"
        return 0
    fi

    if semver_gt "$latest" "$current"; then
        bootstrap_path="$(cd "$HERE/../.." && pwd -P)/setup.sh"
        command="INCLUDE_CODE_SERVER=1 CODE_SERVER_UPGRADE=1 CODE_SERVER_VERSION=$latest ONLY_TOPICS=85 bash \"$bootstrap_path\" --non-interactive"
        record_code_server_final_info "code-server update available: $current -> $latest

Update when ready:
    $command"
    fi
}

install_code_server_standalone() {
    if [[ "$CODE_SERVER_INSTALL_METHOD" != "standalone" || "$CODE_SERVER_INSTALL_PREFIX" != "$HOME/.local" ]]; then
        followup critical "code-server standalone install preconditions failed; rerun with CODE_SERVER_INSTALL_METHOD=standalone and CODE_SERVER_INSTALL_PREFIX=$HOME/.local."
        exit 1
    fi

    local current_version=""
    current_version="$(code_server_current_version 2>/dev/null || true)"
    if [[ -n "$current_version" && "$CODE_SERVER_UPGRADE" != "1" ]]; then
        ok "code-server already installed at $CODE_SERVER_BIN ($("$CODE_SERVER_BIN" --version 2>/dev/null | head -1))"
        maybe_report_code_server_update
        return 0
    fi

    mkdir -p "$CODE_SERVER_INSTALL_PREFIX/bin"
    if [[ -n "${CODE_SERVER_VERSION:-}" ]]; then
        info "installing code-server standalone $CODE_SERVER_VERSION under $CODE_SERVER_INSTALL_PREFIX"
        curl -fsSL https://code-server.dev/install.sh \
            | env -u OS -u ARCH -u DISTRO sh -s -- --method=standalone --prefix "$CODE_SERVER_INSTALL_PREFIX" --version "$CODE_SERVER_VERSION"
    else
        info "installing latest stable code-server standalone under $CODE_SERVER_INSTALL_PREFIX"
        curl -fsSL https://code-server.dev/install.sh \
            | env -u OS -u ARCH -u DISTRO sh -s -- --method=standalone --prefix "$CODE_SERVER_INSTALL_PREFIX"
    fi

    "$CODE_SERVER_BIN" --version >/dev/null
    ok "code-server installed at $CODE_SERVER_BIN ($("$CODE_SERVER_BIN" --version 2>/dev/null | head -1))"
}

record_generated_password_final() {
    [[ -n "$CODE_SERVER_GENERATED_PASSWORD" ]] || return 0

    local msg
    msg="Generated code-server password for this first install:
    $CODE_SERVER_GENERATED_PASSWORD

$CODE_SERVER_CONFIG_FILE (mode 0600) stores the hash. The plaintext cannot be recovered from it."

    if [[ -n "${MESH_FOLLOWUP_FILE:-}" ]]; then
        # Deliberately bypass followup(): that helper prints inline while the
        # topic is piped through tee into /tmp/mesh-workstation-*.log. The final
        # summary is rendered after the topic pipeline, so the generated
        # password appears only at the end of this run, not in the topic log.
        printf '%s\x1f%s\x1e' "info" "$msg" >> "$MESH_FOLLOWUP_FILE" 2>/dev/null || true
    else
        info "$msg"
    fi
}

read_interactive_password() {
    local first="" second=""

    printf '\n85-code-server password\n' >/dev/tty
    first="$(ask_secret 'Enter a password for code-server (blank = generate one)')"

    if [[ -z "$first" ]]; then
        return 1
    fi

    second="$(ask_secret 'Confirm code-server password')"

    if [[ "$first" != "$second" ]]; then
        followup critical "code-server passwords did not match; rerun the topic and try again."
        exit 1
    fi

    printf '%s' "$first"
}

_code_server_discard_password_file() {
    local path="$1"
    [[ -n "$path" && -f "$path" ]] || return 0
    if command -v shred >/dev/null 2>&1 && shred -u -- "$path" 2>/dev/null; then
        return 0
    fi
    rm -f -- "$path"
}

choose_code_server_password() {
    local password generated

    # Only the generate branch fills CODE_SERVER_GENERATED_PASSWORD_FILE.
    # Interactive entry and CODE_SERVER_PASSWORD leave it empty so the final
    # summary is not a second copy of a password the operator already has.
    # The assignment cannot live in this function: write_code_server_config
    # captures stdout in a subshell, which would drop it.
    if [[ -n "${CODE_SERVER_PASSWORD:-}" ]]; then
        printf '%s' "$CODE_SERVER_PASSWORD"
        return 0
    fi

    if [[ "${NON_INTERACTIVE:-0}" != "1" && -z "${CI:-}" ]] && has_ctty; then
        if password="$(read_interactive_password)"; then
            printf '%s' "$password"
            unset password
            return 0
        fi
    fi

    generated="$(/usr/bin/openssl rand -hex 24)" || return 1
    [[ -n "$generated" ]] || return 1
    if [[ -n "${CODE_SERVER_GENERATED_PASSWORD_FILE:-}" ]]; then
        printf '%s' "$generated" > "$CODE_SERVER_GENERATED_PASSWORD_FILE" || return 1
    fi
    printf '%s' "$generated"
    unset generated
}

# Hash argv is exactly: npx --yes argon2-cli -e
# stdin is the password with no trailing newline (echo -n). Tests shadow npx.
hash_code_server_password() {
    local pw="$1" hash rc=0
    hash="$(echo -n "$pw" | npx --yes argon2-cli -e)" || rc=$?
    [[ "$rc" -eq 0 ]] || return 1
    case "$hash" in
        \$argon2*) printf '%s' "$hash" ;;
        *) return 1 ;;
    esac
}

_code_server_write_hashed_config() {
    local hashed="$1" tmp old_umask preserved=""
    case "$hashed" in
        \$argon2*) ;;
        *) return 1 ;;
    esac
    # Migrate in place: drop only the keys this installer owns. A new file
    # (no previous content) stays the four canonical lines.
    if [[ -f "$CODE_SERVER_CONFIG_FILE" ]]; then
        preserved="$(awk '
            /^[[:space:]]*(bind-addr|auth|hashed-password|password|cert):/ { next }
            { print }
        ' "$CODE_SERVER_CONFIG_FILE")" || return 1
    fi
    old_umask="$(umask)"
    umask 077
    tmp="${CODE_SERVER_CONFIG_FILE}.tmp.$$"
    {
        printf 'bind-addr: 127.0.0.1:%s\n' "$CODE_SERVER_PORT"
        printf 'auth: password\n'
        printf 'hashed-password: %s\n' "$hashed"
        printf 'cert: false\n'
        if [[ -n "$preserved" ]]; then
            printf '%s\n' "$preserved"
        fi
    } > "$tmp"
    umask "$old_umask"
    mv "$tmp" "$CODE_SERVER_CONFIG_FILE"
}

write_code_server_config() {
    local password hashed pwfile choose_rc=0
    # Parent-owned path. choose_code_server_password runs in a command
    # substitution, so a variable set there would not survive.
    pwfile="$(mktemp "${TMPDIR:-/tmp}/cs-gen-pw.XXXXXX")" || {
        followup critical "code-server could not store a generated password outside the hasher subshell."
        exit 1
    }
    chmod 0600 "$pwfile" || true
    password="$(
        CODE_SERVER_GENERATED_PASSWORD_FILE="$pwfile" choose_code_server_password
    )" || choose_rc=$?
    if [[ -s "$pwfile" ]]; then
        password="$(cat "$pwfile")"
        CODE_SERVER_GENERATED_PASSWORD="$password"
    else
        CODE_SERVER_GENERATED_PASSWORD=""
    fi
    _code_server_discard_password_file "$pwfile"
    unset pwfile
    if [[ "$choose_rc" -ne 0 || -z "$password" ]]; then
        unset password hashed
        CODE_SERVER_GENERATED_PASSWORD=""
        followup critical "code-server password generation failed."
        exit 1
    fi
    if ! hashed="$(hash_code_server_password "$password")"; then
        unset password hashed
        CODE_SERVER_GENERATED_PASSWORD=""
        followup critical "code-server password hash failed or did not start with \$argon2 (npx --yes argon2-cli -e)."
        exit 1
    fi
    unset password
    if ! _code_server_write_hashed_config "$hashed"; then
        unset hashed
        CODE_SERVER_GENERATED_PASSWORD=""
        followup critical "code-server password hash failed or did not start with \$argon2 (npx --yes argon2-cli -e)."
        exit 1
    fi
    unset hashed
}

_code_server_backup_config() {
    local backup
    backup="${CODE_SERVER_CONFIG_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
    cp -p "$CODE_SERVER_CONFIG_FILE" "$backup"
    info "backed up existing code-server config to $backup"
}

_code_server_config_bind_ok() {
    grep -Eq "^[[:space:]]*bind-addr:[[:space:]]*127\\.0\\.0\\.1:${CODE_SERVER_PORT}[[:space:]]*$" "$1"
}

_code_server_config_has_plaintext_password() {
    grep -Eq '^[[:space:]]*password:[[:space:]]*' "$1"
}

_code_server_config_has_hashed_password() {
    grep -Eq '^[[:space:]]*hashed-password:[[:space:]]*[^[:space:]]' "$1"
}

_code_server_extract_plaintext_password() {
    awk '
        /^[[:space:]]*password:[[:space:]]*/ {
            sub(/^[[:space:]]*password:[[:space:]]*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if (($0 ~ /^".*"$/) || ($0 ~ /^'\''.*'\''$/)) {
                $0 = substr($0, 2, length($0) - 2)
            }
            print
            exit
        }
    ' "$1"
}

_code_server_extract_hashed_password() {
    awk '
        /^[[:space:]]*hashed-password:[[:space:]]*/ {
            sub(/^[[:space:]]*hashed-password:[[:space:]]*/, "", $0)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
            if (($0 ~ /^".*"$/) || ($0 ~ /^'\''.*'\''$/)) {
                $0 = substr($0, 2, length($0) - 2)
            }
            print
            exit
        }
    ' "$1"
}

_code_server_note_password_saved() {
    if [[ -n "$CODE_SERVER_GENERATED_PASSWORD" ]]; then
        record_generated_password_final
    else
        followup info "code-server password hash was saved in $CODE_SERVER_CONFIG_FILE (mode 0600). The plaintext cannot be recovered from it."
    fi
}

_code_server_rewrite_preserving_secret() {
    local plain hashed
    if _code_server_config_has_plaintext_password "$CODE_SERVER_CONFIG_FILE"; then
        plain="$(_code_server_extract_plaintext_password "$CODE_SERVER_CONFIG_FILE")"
        if [[ -z "$plain" ]]; then
            followup critical "code-server config has an empty password line; refusing to hash it."
            exit 1
        fi
        if ! hashed="$(hash_code_server_password "$plain")"; then
            unset plain hashed
            followup critical "code-server password hash failed or did not start with \$argon2 (npx --yes argon2-cli -e)."
            exit 1
        fi
        unset plain
    else
        hashed="$(_code_server_extract_hashed_password "$CODE_SERVER_CONFIG_FILE")"
        case "$hashed" in
            \$argon2*) ;;
            *)
                unset hashed
                _code_server_backup_config
                write_code_server_config
                _code_server_note_password_saved
                return 0
                ;;
        esac
    fi
    _code_server_backup_config
    if ! _code_server_write_hashed_config "$hashed"; then
        unset hashed
        followup critical "code-server config must bind only to 127.0.0.1:${CODE_SERVER_PORT}. Re-run with CODE_SERVER_REWRITE_CONFIG=1 after reviewing $CODE_SERVER_CONFIG_FILE."
        exit 1
    fi
    unset hashed
    ok "rewrote code-server config to hashed-password on 127.0.0.1:${CODE_SERVER_PORT}"
}

ensure_code_server_config() {
    mkdir -p "$CODE_SERVER_CONFIG_DIR" "$CODE_SERVER_USER_DATA_DIR/User/globalStorage"
    chmod 0700 \
        "$CODE_SERVER_CONFIG_DIR" \
        "$CODE_SERVER_USER_DATA_DIR" \
        "$CODE_SERVER_USER_DATA_DIR/User" \
        "$CODE_SERVER_USER_DATA_DIR/User/globalStorage"

    if [[ -f "$CODE_SERVER_CONFIG_FILE" && "${CODE_SERVER_REWRITE_CONFIG:-0}" == "1" ]]; then
        _code_server_backup_config
        write_code_server_config
        _code_server_note_password_saved
    elif [[ ! -f "$CODE_SERVER_CONFIG_FILE" ]]; then
        write_code_server_config
        _code_server_note_password_saved
    elif _code_server_config_has_plaintext_password "$CODE_SERVER_CONFIG_FILE" \
        || ! _code_server_config_bind_ok "$CODE_SERVER_CONFIG_FILE"; then
        _code_server_rewrite_preserving_secret
    elif _code_server_config_has_hashed_password "$CODE_SERVER_CONFIG_FILE" \
        && _code_server_effective_auth_is_password "$CODE_SERVER_CONFIG_FILE"; then
        ok "code-server config already exists at $CODE_SERVER_CONFIG_FILE"
    else
        if ! _code_server_effective_auth_is_password "$CODE_SERVER_CONFIG_FILE"; then
            followup critical "code-server config must keep auth: password. Re-run with CODE_SERVER_REWRITE_CONFIG=1 after reviewing $CODE_SERVER_CONFIG_FILE."
            exit 1
        fi
        if ! grep -Eq '^[[:space:]]*(password|hashed-password):[[:space:]]*.+' "$CODE_SERVER_CONFIG_FILE"; then
            followup critical "code-server config is missing password/hashed-password. Re-run with CODE_SERVER_REWRITE_CONFIG=1 after reviewing $CODE_SERVER_CONFIG_FILE."
            exit 1
        fi
        followup critical "code-server config must bind only to 127.0.0.1:${CODE_SERVER_PORT}. Re-run with CODE_SERVER_REWRITE_CONFIG=1 after reviewing $CODE_SERVER_CONFIG_FILE."
        exit 1
    fi

    chmod 0700 "$CODE_SERVER_CONFIG_DIR"
    chmod 0600 "$CODE_SERVER_CONFIG_FILE"
}

write_code_server_service_wrapper() {
    local help
    help="$("$CODE_SERVER_BIN" --help 2>&1 || true)"
    case "$help" in
        *--disable-proxy*) ;;
        *)
            followup critical "code-server at $CODE_SERVER_BIN does not list --disable-proxy in --help; refusing to write the service wrapper."
            exit 1
            ;;
    esac

    mkdir -p "$(dirname "$CODE_SERVER_SERVICE_WRAPPER")" "$CODE_SERVER_STATE_DIR"
    chmod 0700 "$CODE_SERVER_STATE_DIR"

    local tmp
    tmp="${CODE_SERVER_SERVICE_WRAPPER}.tmp.$$"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Generated by mesh-workstation/topics/85-code-server/install.mac.sh.\n'
        printf 'set -euo pipefail\n\n'
        printf 'export HOME=%q\n' "$HOME"
        printf 'export PATH=%q\n' "${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}"
        printf '[[ -f /etc/ssl/cert.pem ]] && export NODE_EXTRA_CA_CERTS=/etc/ssl/cert.pem\n\n'
        printf 'token=""\n'
        printf 'if command -v gh >/dev/null 2>&1; then\n'
        printf '    gh_bin="$(command -v gh 2>/dev/null || true)"\n'
        printf '    case "$gh_bin" in\n'
        printf '        /Volumes/*)\n'
        printf '            : # launchd can hang spawning binaries from noowners external volumes\n'
        printf '            ;;\n'
        printf '        *)\n'
        printf '            if command -v perl >/dev/null 2>&1; then\n'
        printf '                token="$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 perl -e '\''alarm shift @ARGV; exec @ARGV'\'' 5 gh auth token </dev/null 2>/dev/null || true)"\n'
        printf '            else\n'
        printf '                token="$(GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh auth token </dev/null 2>/dev/null || true)"\n'
        printf '            fi\n'
        printf '            ;;\n'
        printf '    esac\n'
        printf 'fi\n'
        printf 'if [[ -z "$token" && -r "$HOME/.config/gh/hosts.yml" ]]; then\n'
        printf '    token="$(awk '\''/^[[:space:]]*oauth_token:[[:space:]]*/ { sub(/^[[:space:]]*oauth_token:[[:space:]]*/, "", $0); gsub(/^"|"$/, "", $0); if ($0 != "") { print; exit } }'\'' "$HOME/.config/gh/hosts.yml" 2>/dev/null || true)"\n'
        printf 'fi\n'
        printf 'if [[ -n "$token" ]]; then\n'
        printf '    export GITHUB_TOKEN="$token"\n'
        printf 'fi\n'
        printf 'unset token\n'
        printf 'unset gh_bin\n'
        printf '\n'
        printf 'exec %q --disable-proxy\n' "$CODE_SERVER_BIN"
    } > "$tmp"
    mv "$tmp" "$CODE_SERVER_SERVICE_WRAPPER"
    chmod 0700 "$CODE_SERVER_SERVICE_WRAPPER"
    ok "wrote code-server service wrapper at $CODE_SERVER_SERVICE_WRAPPER"

    if PATH="${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}" command -v gh >/dev/null 2>&1; then
        if ! PATH="${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}" GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 gh auth token >/dev/null 2>&1; then
            followup manual "gh is installed but no token is available. Run 'gh auth login' if CLI/subprocess GitHub access inside code-server should inherit GITHUB_TOKEN. VS Code GitHub OAuth remains a separate browser login stored in code-server user data."
        fi
    else
        followup manual "gh was not found in the code-server service PATH, so CLI/subprocess GitHub access inside code-server will not inherit GITHUB_TOKEN. VS Code GitHub OAuth remains a separate browser login stored in code-server user data."
    fi
}

backup_launchagent_if_present() {
    local label="$1" plist="$2"
    local uid backup
    uid="$(id -u)"

    if launchctl print "gui/${uid}/${label}" >/dev/null 2>&1; then
        launchctl bootout "gui/${uid}/${label}" 2>/dev/null || true
    fi

    if [[ -f "$plist" ]]; then
        backup="${plist}.bak-$(date +%Y%m%d-%H%M%S)"
        mv "$plist" "$backup"
        info "moved legacy LaunchAgent $plist to $backup"
    fi
}

migrate_legacy_launchagents() {
    local launchagents_dir="$HOME/Library/LaunchAgents"
    backup_launchagent_if_present "homebrew.mxcl.code-server" "$launchagents_dir/homebrew.mxcl.code-server.plist"

    if [[ "$CODE_SERVER_LABEL" != "com.henry.code-server" ]]; then
        backup_launchagent_if_present "com.henry.code-server" "$launchagents_dir/com.henry.code-server.plist"
    fi
}

write_launchagent_plist() {
    mkdir -p "$(dirname "$CODE_SERVER_PLIST")" "$CODE_SERVER_STATE_DIR"
    chmod 0700 "$CODE_SERVER_STATE_DIR"

    local label wrapper workdir stdout_path stderr_path tmp
    label="$(plist_escape "$CODE_SERVER_LABEL")"
    wrapper="$(plist_escape "$CODE_SERVER_SERVICE_WRAPPER")"
    workdir="$(plist_escape "$CODE_SERVER_WORKDIR")"
    stdout_path="$(plist_escape "$CODE_SERVER_STATE_DIR/launchd.log")"
    stderr_path="$(plist_escape "$CODE_SERVER_STATE_DIR/launchd.err")"

    # CP4 C-F-010: atomic write — partial plist must never be visible to
    # launchd (which file-watches LaunchAgents) nor to plutil. Write to a
    # same-dir tmp, lint that tmp, then rename in place.
    tmp="$(mktemp "$(dirname "$CODE_SERVER_PLIST")/.${CODE_SERVER_LABEL}.plist.XXXXXX")" \
        || { fail "mktemp failed for LaunchAgent plist"; return 1; }

    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" '
        printf '"http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        printf '<plist version="1.0">\n<dict>\n'
        printf '    <key>Label</key>\n    <string>%s</string>\n' "$label"
        printf '    <key>ProgramArguments</key>\n    <array>\n'
        printf '        <string>%s</string>\n' "$wrapper"
        printf '    </array>\n'
        printf '    <key>RunAtLoad</key>\n    <true/>\n'
        printf '    <key>KeepAlive</key>\n    <true/>\n'
        printf '    <key>WorkingDirectory</key>\n    <string>%s</string>\n' "$workdir"
        printf '    <key>StandardOutPath</key>\n    <string>%s</string>\n' "$stdout_path"
        printf '    <key>StandardErrorPath</key>\n    <string>%s</string>\n' "$stderr_path"
        printf '</dict>\n</plist>\n'
    } > "$tmp"

    if ! /usr/bin/plutil -lint "$tmp" >/dev/null; then
        rm -f "$tmp"
        fail "plist failed plutil -lint at $tmp"
        return 1
    fi
    mv -f "$tmp" "$CODE_SERVER_PLIST"
    ok "wrote LaunchAgent $CODE_SERVER_PLIST"
}

bootstrap_launchagent() {
    local uid i
    uid="$(id -u)"

    launchctl bootout "gui/${uid}/${CODE_SERVER_LABEL}" 2>/dev/null || true
    for i in 1 2 3 4 5; do
        launchctl print "gui/${uid}/${CODE_SERVER_LABEL}" >/dev/null 2>&1 || break
        sleep 1
    done

    launchctl bootstrap "gui/${uid}" "$CODE_SERVER_PLIST"
    ok "bootstrapped LaunchAgent $CODE_SERVER_LABEL"
}

wait_for_healthz() {
    local url i
    url="http://127.0.0.1:${CODE_SERVER_PORT}/healthz"
    info "waiting for code-server healthz at $url"
    for i in $(seq 1 30); do
        if curl -fsS --max-time 2 "$url" >/dev/null 2>&1; then
            ok "code-server healthz is responding"
            return 0
        fi
        sleep 1
    done

    followup critical "code-server LaunchAgent bootstrapped, but $url did not respond within 30s. Inspect $CODE_SERVER_STATE_DIR/launchd.err."
    return 1
}

verify_local_only_listener() {
    if ! command -v lsof >/dev/null 2>&1; then
        followup manual "lsof is not available; could not verify the code-server listener is loopback-only."
        return 0
    fi

    local listeners
    listeners="$(lsof -nP -iTCP:"$CODE_SERVER_PORT" -sTCP:LISTEN 2>/dev/null || true)"
    if [[ -z "$listeners" ]]; then
        followup critical "code-server healthz responded, but no TCP listener was found on port $CODE_SERVER_PORT."
        return 1
    fi

    if printf '%s\n' "$listeners" | awk -v port="$CODE_SERVER_PORT" '
        NR == 1 { next }
        $0 !~ ("TCP 127\\.0\\.0\\.1:" port " \\(LISTEN\\)$") { bad=1 }
        END { exit bad ? 0 : 1 }
    '; then
        printf '%s\n' "$listeners" >&2
        followup critical "code-server must listen only on 127.0.0.1:${CODE_SERVER_PORT}; refusing to treat this setup as protected by Tailscale."
        return 1
    fi

    ok "code-server listener is loopback-only on 127.0.0.1:${CODE_SERVER_PORT}"
}

tailscale_serve_state() {
    local status_out="$1" parsed

    if [[ -z "$status_out" || "$status_out" == *"No serve config"* ]]; then
        printf 'empty\n'
        return 0
    fi

    if command -v python3 >/dev/null 2>&1; then
        if parsed="$(TS_STATUS_JSON="$status_out" python3 - "$CODE_SERVER_PORT" 2>/dev/null <<'PY'
import json
import os
import sys

port = sys.argv[1]
want = f"http://127.0.0.1:{port}"
data = json.loads(os.environ["TS_STATUS_JSON"])
found_handlers = False
root_desired = False

def walk(obj):
    global found_handlers, root_desired
    if isinstance(obj, dict):
        handlers = obj.get("Handlers")
        if isinstance(handlers, dict):
            for path, handler in handlers.items():
                if isinstance(handler, dict) and handler.get("Proxy"):
                    found_handlers = True
                    if path == "/" and handler.get("Proxy") == want:
                        root_desired = True
        for value in obj.values():
            walk(value)
    elif isinstance(obj, list):
        for value in obj:
            walk(value)

walk(data)
if root_desired:
    print("desired")
elif found_handlers:
    print("other")
else:
    print("empty")
PY
)"; then
            printf '%s\n' "$parsed"
            return 0
        fi
    fi

    if printf '%s' "$status_out" | grep -qF "http://127.0.0.1:${CODE_SERVER_PORT}"; then
        printf 'desired\n'
    elif printf '%s' "$status_out" | grep -Eq '"Handlers"|"Proxy"'; then
        printf 'other\n'
    else
        printf 'invalid\n'
    fi
}

print_tailscale_code_server_url() {
    local status url
    status="$(PATH="${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}" tailscale serve status 2>/dev/null || true)"
    url="$(printf '%s\n' "$status" | awk '/^https:\/\// { print $1; exit }')"
    if [[ -n "$url" ]]; then
        ok "code-server URL: $url"
    else
        info "code-server URL: run 'tailscale serve status' and open the HTTPS URL that proxies 127.0.0.1:${CODE_SERVER_PORT}"
    fi
}

maybe_configure_tailscale_serve() {
    [[ "$CODE_SERVER_TAILSCALE_SERVE" == "1" ]] || return 0

    if ! PATH="${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}" command -v tailscale >/dev/null 2>&1; then
        followup manual "CODE_SERVER_TAILSCALE_SERVE=1, but tailscale is not on PATH. Configure Serve manually after Tailscale is installed."
        return 0
    fi

    if ! PATH="${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}" tailscale status --self >/dev/null 2>&1; then
        followup manual "CODE_SERVER_TAILSCALE_SERVE=1, but this node is not authenticated in Tailscale. Launch Tailscale, log in, then run: tailscale serve --bg --yes $CODE_SERVER_PORT"
        return 0
    fi

    local status_out status_rc state
    status_out="$(PATH="${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}" tailscale serve status --json 2>&1)" || status_rc=$?
    status_rc="${status_rc:-0}"
    state="$(tailscale_serve_state "$status_out")"

    case "$state" in
        desired)
            ok "Tailscale Serve already proxies / to 127.0.0.1:$CODE_SERVER_PORT"
            print_tailscale_code_server_url
            return 0
            ;;
        empty)
            ;;
        other)
            followup manual "Tailscale Serve already has handlers; not overwriting automatically. Review 'tailscale serve status' and add code-server manually if appropriate."
            return 0
            ;;
        *)
            followup manual "Could not parse 'tailscale serve status --json' (rc=$status_rc); not changing Serve config automatically."
            return 0
            ;;
    esac

    info "configuring Tailscale Serve for code-server on local port $CODE_SERVER_PORT"
    PATH="${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}" tailscale serve --bg --yes "$CODE_SERVER_PORT"

    status_out="$(PATH="${CODE_SERVER_INSTALL_PREFIX}/bin:${CODE_SERVER_EXTRA_PATH}" tailscale serve status --json 2>&1 || true)"
    state="$(tailscale_serve_state "$status_out")"
    if [[ "$state" == "desired" ]]; then
        ok "Tailscale Serve proxies / to 127.0.0.1:$CODE_SERVER_PORT"
        print_tailscale_code_server_url
    else
        followup manual "Tailscale Serve command finished, but validation did not find the expected root proxy. Check 'tailscale serve status'."
    fi
}

deploy_user_settings_from_identity() {
    # Identity owns the settings seed. Copy only when the code-server User
    # settings file does not exist yet. An existing destination is left
    # byte-for-byte: no compare, no backup, no overwrite. The copy forces
    # remote.autoForwardPorts off; the identity source is not rewritten.
    local identity_dir="${MESH_IDENTITY_DIR:-$HOME/mesh-identity}"
    local src="$identity_dir/code-server/settings.json"
    local user_dir="$HOME/.local/share/code-server/User"
    local dst="$user_dir/settings.json"

    [[ -f "$src" ]] || { dbg "code-server settings: no source at $src (skipping)"; return 0; }

    if [[ -e "$dst" ]]; then
        ok "code-server settings already present; leaving $dst unchanged"
        return 0
    fi

    mkdir -p "$user_dir"
    chmod 0700 "$(dirname "$user_dir")" "$user_dir" 2>/dev/null || true

    if ! command -v python3 >/dev/null 2>&1; then
        warn "code-server settings: python3 is required to seed remote.autoForwardPorts"
        return 1
    fi

    local tmp
    tmp="$(mktemp "${user_dir}/.settings.json.XXXXXX")" || {
        warn "code-server settings: failed to mktemp under $user_dir"
        return 1
    }
    if ! python3 - "$src" "$tmp" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
with open(src) as f:
    data = json.load(f)
if not isinstance(data, dict):
    sys.exit(1)
data["remote.autoForwardPorts"] = False
with open(dst, "w") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
    then
        rm -f "$tmp"
        warn "code-server settings: failed to seed $dst from $src"
        return 1
    fi
    chmod 0644 "$tmp"
    mv -f "$tmp" "$dst"
    ok "deployed code-server settings from identity: $src → $dst"
}

require_macos
detect_code_server_env
install_code_server_standalone
ensure_code_server_config
remove_legacy_codex_compat_shim
write_code_server_machine_settings
write_code_server_service_wrapper
migrate_legacy_launchagents
write_launchagent_plist
bootstrap_launchagent

# Runtime-health gate. wait_for_healthz / verify_local_only_listener `return 1`
# (not exit) on failure; without set -e the original flat sequence let a
# non-listening / non-loopback server fall straight through to `ok` and be
# recorded as a SUCCESSFUL install (the files on disk that check()/verify()
# assert are all written before this point). Capture their result and report a
# real install failure at the end so the engine surfaces "install failed"
# (not a misleading post-verify rc=67, and not a false success). Best-effort
# config steps still run so they are not skipped on a transient health blip.
local _cs_fail=0
wait_for_healthz || _cs_fail=1
verify_local_only_listener || _cs_fail=1

deploy_user_settings_from_identity
maybe_configure_tailscale_serve

if [[ "$_cs_fail" -ne 0 ]]; then
    warn "85-code-server: server did not come up healthy and loopback-only — reporting install failure (see the messages above)"
    return 1
fi
ok "85-code-server done"
}

_code_server_launchagent_pid() {
    local uid out pid
    command -v launchctl >/dev/null 2>&1 || return 1
    uid="$(id -u)"
    out="$(launchctl print "gui/${uid}/${CODE_SERVER_LABEL}" 2>/dev/null)" || return 1
    pid="$(printf '%s\n' "$out" | awk '
        /^[[:space:]]*pid = [0-9]+[[:space:]]*$/ {
            sub(/^[[:space:]]*pid = /, "")
            sub(/[[:space:]]*$/, "")
            print
            exit
        }
    ')"
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    printf '%s\n' "$pid"
}

verify() {
    # Separate subshell from install(). Resolve paths here; do not read
    # CODE_SERVER_PORT out of install()'s scope. detect_code_server_env runs
    # before any lsof.
    local root HERE listeners agent_pid listener_pid
    root="$(_code_server_workstation_root)" || {
        printf 'code-server verify: mesh-workstation root not found\n' >&2
        return 1
    }
    # shellcheck disable=SC1091
    . "$root/scripts/lib/log.sh"

    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    HERE="$HERE/.."
    : "${CODE_SERVER_PORT:=8091}"
    : "${CODE_SERVER_LABEL:=com.${USER}.code-server}"
    : "${CODE_SERVER_INSTALL_PREFIX:=$HOME/.local}"
    : "${CODE_SERVER_INSTALL_METHOD:=standalone}"
    : "${CODE_SERVER_WORKDIR:=$HOME}"
    CODE_SERVER_EXTRA_PATH="${CODE_SERVER_EXTRA_PATH:-}"

    detect_code_server_env

    if ! command -v lsof >/dev/null 2>&1; then
        followup critical "lsof is not available; cannot verify the code-server listener."
        return 1
    fi

    listeners="$(lsof -nP -iTCP:"$CODE_SERVER_PORT" -sTCP:LISTEN 2>/dev/null || true)"
    listener_pid="$(printf '%s\n' "$listeners" | awk -v port="$CODE_SERVER_PORT" '
        $0 !~ /\(LISTEN\)/ { next }
        {
            if ($0 !~ ("TCP 127\\.0\\.0\\.1:" port " \\(LISTEN\\)")) bad=1
            else {
                if (pid != "" && pid != $2) bad=1
                pid=$2
                seen=1
            }
        }
        END {
            if (bad || !seen) exit 1
            print pid
        }
    ')" || {
        printf '%s\n' "$listeners" >&2
        followup critical "code-server must listen only on 127.0.0.1:${CODE_SERVER_PORT}; refusing a listener that is not the code-server LaunchAgent."
        return 1
    }

    agent_pid="$(_code_server_launchagent_pid)" || {
        followup critical "code-server LaunchAgent ${CODE_SERVER_LABEL} is not running."
        return 1
    }
    if [[ "$listener_pid" != "$agent_pid" ]]; then
        followup critical "listener PID ${listener_pid} on 127.0.0.1:${CODE_SERVER_PORT} is not LaunchAgent ${CODE_SERVER_LABEL} (pid ${agent_pid})."
        return 1
    fi

    if [[ ! -f "$CODE_SERVER_SERVICE_WRAPPER" ]] || ! grep -q -- '--disable-proxy' "$CODE_SERVER_SERVICE_WRAPPER"; then
        followup critical "code-server service wrapper must contain --disable-proxy."
        return 1
    fi
    if [[ ! -f "$CODE_SERVER_CONFIG_FILE" ]] \
        || ! grep -Eq '^[[:space:]]*hashed-password:[[:space:]]*[^[:space:]]' "$CODE_SERVER_CONFIG_FILE" \
        || ! grep -Eq '^[[:space:]]*cert:[[:space:]]*false[[:space:]]*$' "$CODE_SERVER_CONFIG_FILE"; then
        followup critical "code-server config must contain hashed-password and cert: false."
        return 1
    fi
    if ! _code_server_effective_auth_is_password "$CODE_SERVER_CONFIG_FILE"; then
        followup critical "code-server config must keep auth: password. Re-run with CODE_SERVER_REWRITE_CONFIG=1 after reviewing $CODE_SERVER_CONFIG_FILE."
        return 1
    fi

    ok "code-server listener is loopback-only on 127.0.0.1:${CODE_SERVER_PORT}"
}
repair() { install; }

rollback() {
    :   # code-server carries user state (workspace settings); no auto-uninstall
}
