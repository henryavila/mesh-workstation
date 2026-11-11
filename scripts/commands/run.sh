# shellcheck shell=bash

_run_config_is_array() {
    declare -p "$1" 2>/dev/null | grep -q 'declare \-[^ ]*a'
}

_load_mesh_run_config() {
    local conf="${MESH_STATUS_CONF:-$HOME/.config/mesh/mesh-status.conf}"
    if [[ -r "$conf" ]]; then
        # shellcheck source=/dev/null
        . "$conf" 2>/dev/null || true
    fi

    if ! _run_config_is_array MESH_RUN_HOSTS; then
        MESH_RUN_HOSTS=("ultron=ultron-wsl" "mac=mac" "crc=crc")
    fi
}

_lower() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

_first_label() {
    local name="$1"
    name="${name%%.*}"
    printf '%s' "$name"
}

_mesh_alias_for_name() {
    local name="$1"
    local key mapped
    key="$(_first_label "$name")"

    if [[ -n "${MESH_TAILSCALE_ALIAS_MAP:-}" ]] && command -v jq >/dev/null 2>&1; then
        mapped=$(jq -er --arg k "$key" '.[$k] // empty' <<<"$MESH_TAILSCALE_ALIAS_MAP" 2>/dev/null) && {
            printf '%s' "$mapped"
            return
        }
        mapped=$(jq -er --arg k "$(_lower "$key")" '.[$k] // empty' <<<"$MESH_TAILSCALE_ALIAS_MAP" 2>/dev/null) && {
            printf '%s' "$mapped"
            return
        }
    fi

    printf '%s' "$key"
}

RUN_HOST_ALIASES=()
RUN_HOST_TARGETS=()
RUN_ONLINE_ALIASES=()
RUN_SELECTED_ALIASES=()
RUN_SELECTED_TARGETS=()

_mesh_load_run_hosts() {
    _load_mesh_run_config
    RUN_HOST_ALIASES=()
    RUN_HOST_TARGETS=()

    local spec alias target
    for spec in "${MESH_RUN_HOSTS[@]+"${MESH_RUN_HOSTS[@]}"}"; do
        [[ -n "$spec" ]] || continue
        if [[ "$spec" == *=* ]]; then
            alias="${spec%%=*}"
            target="${spec#*=}"
        else
            alias="$spec"
            target="$spec"
        fi
        [[ -n "$alias" && -n "$target" ]] || _die "run: invalid MESH_RUN_HOSTS entry '$spec'"
        RUN_HOST_ALIASES+=("$alias")
        RUN_HOST_TARGETS+=("$target")
    done

    (( ${#RUN_HOST_ALIASES[@]} > 0 )) || _die "run: no hosts configured in MESH_RUN_HOSTS"
}

_mesh_known_hosts_display() {
    local i out=""
    for (( i=0; i<${#RUN_HOST_ALIASES[@]}; i++ )); do
        out="${out:+$out, }${RUN_HOST_ALIASES[$i]}"
    done
    printf '%s' "$out"
}

_mesh_find_host_index() {
    local wanted="$1"
    local i
    for (( i=0; i<${#RUN_HOST_ALIASES[@]}; i++ )); do
        if [[ "$wanted" == "${RUN_HOST_ALIASES[$i]}" || "$wanted" == "${RUN_HOST_TARGETS[$i]}" ]]; then
            printf '%s' "$i"
            return 0
        fi
    done
    return 1
}

_mesh_add_selected_index() {
    local idx="$1"
    local alias="${RUN_HOST_ALIASES[$idx]}"
    local existing
    for existing in "${RUN_SELECTED_ALIASES[@]+"${RUN_SELECTED_ALIASES[@]}"}"; do
        [[ "$existing" == "$alias" ]] && return
    done
    RUN_SELECTED_ALIASES+=("$alias")
    RUN_SELECTED_TARGETS+=("${RUN_HOST_TARGETS[$idx]}")
}

_mesh_select_all_hosts() {
    RUN_SELECTED_ALIASES=()
    RUN_SELECTED_TARGETS=()
    local i
    for (( i=0; i<${#RUN_HOST_ALIASES[@]}; i++ )); do
        _mesh_add_selected_index "$i"
    done
}

_mesh_alias_in_list() {
    local needle="$1"
    shift || true
    local item
    for item in "$@"; do
        [[ "$item" == "$needle" ]] && return 0
    done
    return 1
}

_mesh_alias_is_configured() {
    local wanted="$1"
    local alias
    for alias in "${RUN_HOST_ALIASES[@]+"${RUN_HOST_ALIASES[@]}"}"; do
        [[ "$alias" == "$wanted" ]] && return 0
    done
    return 1
}

_mesh_preferred_alias_for_names() {
    local fallback="" name alias
    for name in "$@"; do
        [[ -n "$name" && "$name" != "null" ]] || continue
        alias="$(_mesh_alias_for_name "$name")"
        [[ -n "$alias" ]] || continue
        [[ -n "$fallback" ]] || fallback="$alias"
        if _mesh_alias_is_configured "$alias"; then
            printf '%s' "$alias"
            return 0
        fi
    done
    [[ -n "$fallback" ]] || return 1
    printf '%s' "$fallback"
}

_mesh_select_online_hosts() {
    RUN_SELECTED_ALIASES=()
    RUN_SELECTED_TARGETS=()
    local i
    for (( i=0; i<${#RUN_HOST_ALIASES[@]}; i++ )); do
        if _mesh_alias_in_list "${RUN_HOST_ALIASES[$i]}" "${RUN_ONLINE_ALIASES[@]+"${RUN_ONLINE_ALIASES[@]}"}"; then
            _mesh_add_selected_index "$i"
        fi
    done
}

_mesh_command_available() {
    local cmd="$1"
    [[ -n "$cmd" ]] || return 1
    if [[ "$cmd" == */* ]]; then
        [[ -x "$cmd" ]]
    else
        command -v "$cmd" >/dev/null 2>&1
    fi
}

_mesh_has_ctty() {
    [[ -t 0 && -t 1 && -r /dev/tty && -w /dev/tty ]]
}

_mesh_load_prompt_lib() {
    declare -F ask_line >/dev/null 2>&1 && return 0
    declare -F _resolve_companion >/dev/null 2>&1 || return 1

    local lib
    lib="$(_resolve_companion "lib/log.sh")"
    [[ -n "$lib" && -r "$lib" ]] || return 1
    # shellcheck source=/dev/null
    . "$lib"
    declare -F ask_line >/dev/null 2>&1
}

_mesh_text_selector_available() {
    _mesh_has_ctty || return 1
    _mesh_load_prompt_lib
}

_mesh_select_from_spec() {
    local spec="$1"
    local token idx
    RUN_SELECTED_ALIASES=()
    RUN_SELECTED_TARGETS=()

    spec="${spec//,/ }"
    for token in $spec; do
        [[ -n "$token" ]] || continue
        if [[ "$token" =~ ^[0-9]+$ ]]; then
            idx=$(( token - 1 ))
            if (( idx < 0 || idx >= ${#RUN_HOST_ALIASES[@]} )); then
                _die "run: host number '$token' is outside the selector range"
            fi
        else
            idx="$(_mesh_find_host_index "$token")" || _die "run: unknown host '$token' (known: $(_mesh_known_hosts_display))"
        fi
        _mesh_add_selected_index "$idx"
    done
}

_mesh_online_count() {
    local count=0
    local alias
    for alias in "${RUN_HOST_ALIASES[@]+"${RUN_HOST_ALIASES[@]}"}"; do
        if _mesh_alias_in_list "$alias" "${RUN_ONLINE_ALIASES[@]+"${RUN_ONLINE_ALIASES[@]}"}"; then
            count=$((count + 1))
        fi
    done
    printf '%s' "$count"
}

_mesh_fzf_start_bind() {
    local count="$1"
    local i actions=""
    (( count > 0 )) || return 1
    for (( i=0; i<count; i++ )); do
        actions="${actions:+$actions+}select+down"
    done
    printf 'start:%s+first' "$actions"
}

_mesh_emit_fzf_rows() {
    local pass i alias target status local_mark self
    self="$(_mesh_self_alias)"
    for pass in online offline; do
        for (( i=0; i<${#RUN_HOST_ALIASES[@]}; i++ )); do
            alias="${RUN_HOST_ALIASES[$i]}"
            target="${RUN_HOST_TARGETS[$i]}"
            status="offline"
            if _mesh_alias_in_list "$alias" "${RUN_ONLINE_ALIASES[@]+"${RUN_ONLINE_ALIASES[@]}"}"; then
                status="online"
            fi
            [[ "$status" == "$pass" ]] || continue
            local_mark=""
            [[ "$alias" == "$self" ]] && local_mark="local"
            printf '%s\t%s\t%s\tssh:%s\n' "$alias" "$status" "$local_mark" "$target"
        done
    done
}

_mesh_select_from_lines() {
    local lines="$1"
    local line alias idx
    RUN_SELECTED_ALIASES=()
    RUN_SELECTED_TARGETS=()

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        alias="${line%%$'\t'*}"
        idx="$(_mesh_find_host_index "$alias")" || _die "run: selector returned unknown host '$alias'"
        _mesh_add_selected_index "$idx"
    done <<<"$lines"
}

_mesh_select_fzf() {
    local fzf_bin="${MESH_RUN_FZF:-fzf}"
    _mesh_command_available "$fzf_bin" || return 1
    if [[ "${MESH_RUN_SELECTOR:-}" != "fzf" ]] && ! _mesh_has_ctty; then
        return 1
    fi

    local rows selected rc bind
    rows="$(_mesh_emit_fzf_rows)"
    bind="$(_mesh_fzf_start_bind "$(_mesh_online_count)" 2>/dev/null || printf '')"

    if [[ -n "$bind" ]]; then
        selected=$(printf '%s\n' "$rows" | "$fzf_bin" \
            --multi \
            --sync \
            --no-sort \
            --delimiter=$'\t' \
            --with-nth='1,2,3,4' \
            --header='Tab marca/desmarca; Enter confirma' \
            --prompt='hosts> ' \
            --bind "$bind")
        rc=$?
    else
        selected=$(printf '%s\n' "$rows" | "$fzf_bin" \
            --multi \
            --no-sort \
            --delimiter=$'\t' \
            --with-nth='1,2,3,4' \
            --header='Tab marca/desmarca; Enter confirma' \
            --prompt='hosts> ')
        rc=$?
    fi

    case "$rc" in
        0)
            _mesh_select_from_lines "$selected"
            ;;
        1|130)
            RUN_SELECTED_ALIASES=()
            RUN_SELECTED_TARGETS=()
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

_mesh_select_whiptail() {
    local whiptail_bin="${MESH_RUN_WHIPTAIL:-whiptail}"
    _mesh_command_available "$whiptail_bin" || return 1
    if [[ "${MESH_RUN_SELECTOR:-}" != "whiptail" ]] && ! _mesh_has_ctty; then
        return 1
    fi

    local self i alias target status desc selected rc
    local items=()
    self="$(_mesh_self_alias)"

    for (( i=0; i<${#RUN_HOST_ALIASES[@]}; i++ )); do
        alias="${RUN_HOST_ALIASES[$i]}"
        target="${RUN_HOST_TARGETS[$i]}"
        status="OFF"
        desc="offline ssh:$target"
        if _mesh_alias_in_list "$alias" "${RUN_ONLINE_ALIASES[@]+"${RUN_ONLINE_ALIASES[@]}"}"; then
            status="ON"
            desc="online ssh:$target"
        fi
        [[ "$alias" == "$self" ]] && desc="$desc local"
        items+=("$alias" "$desc" "$status")
    done

    selected=$("$whiptail_bin" \
        --separate-output \
        --title "mesh run" \
        --checklist "Selecione os hosts:" \
        20 78 10 \
        "${items[@]+"${items[@]}"}" \
        3>&1 1>&2 2>&3)
    rc=$?

    case "$rc" in
        0)
            _mesh_select_from_spec "$selected"
            ;;
        1|255)
            RUN_SELECTED_ALIASES=()
            RUN_SELECTED_TARGETS=()
            ;;
        *)
            return 1
            ;;
    esac
    return 0
}

_mesh_add_online_alias() {
    local alias="$1"
    local existing
    [[ -n "$alias" ]] || return
    for existing in "${RUN_ONLINE_ALIASES[@]+"${RUN_ONLINE_ALIASES[@]}"}"; do
        [[ "$existing" == "$alias" ]] && return
    done
    RUN_ONLINE_ALIASES+=("$alias")
}

_mesh_self_alias() {
    local name alias self_fields self_host self_dns
    if [[ -n "${MESH_RUN_SELF_ALIAS:-}" ]]; then
        printf '%s' "$MESH_RUN_SELF_ALIAS"
        return
    fi
    if [[ -n "${MESH_HOST_ALIAS:-}" ]]; then
        printf '%s' "$MESH_HOST_ALIAS"
        return
    fi

    if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        self_fields=$(tailscale status --json 2>/dev/null | jq -r '[.Self.HostName // "", .Self.DNSName // ""] | @tsv' 2>/dev/null)
        if [[ -n "$self_fields" ]]; then
            IFS=$'\t' read -r self_host self_dns <<<"$self_fields"
            alias="$(_mesh_preferred_alias_for_names "$self_host" "$self_dns")" && {
                printf '%s' "$alias"
                return
            }
        fi
    fi

    name=$(hostname -s 2>/dev/null || hostname 2>/dev/null || printf '')
    if [[ -n "$name" ]]; then
        alias="$(_mesh_preferred_alias_for_names "$name")" && {
            printf '%s' "$alias"
            return
        }
    fi
}

_mesh_collect_online_aliases() {
    RUN_ONLINE_ALIASES=()

    local item raw self alias peers peer_host peer_dns peer_key
    if [[ -n "${MESH_RUN_ONLINE_HOSTS:-}" ]]; then
        raw="${MESH_RUN_ONLINE_HOSTS//,/ }"
        for item in $raw; do
            _mesh_add_online_alias "$(_mesh_alias_for_name "$item")"
        done
        return
    fi

    self="$(_mesh_self_alias)"
    _mesh_add_online_alias "$self"

    if command -v tailscale >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
        peers=$(tailscale status --json 2>/dev/null | jq -r '
            .Peer // {} | to_entries[] |
            select(.value.Online == true) |
            [(.value.HostName // ""), (.value.DNSName // ""), .key] |
            @tsv
        ' 2>/dev/null)
        while IFS=$'\t' read -r peer_host peer_dns peer_key; do
            [[ -n "$peer_host$peer_dns$peer_key" ]] || continue
            alias="$(_mesh_preferred_alias_for_names "$peer_host" "$peer_dns" "$peer_key")" || continue
            _mesh_add_online_alias "$alias"
        done <<<"$peers"
    fi
}

_mesh_print_selector() {
    local self
    self="$(_mesh_self_alias)"
    local i alias target marker status local_mark
    printf 'mesh run: selecione hosts para executar o comando.\n' >&2
    printf 'Enter usa o padrão [online]; também aceita números, aliases, all, none.\n\n' >&2
    for (( i=0; i<${#RUN_HOST_ALIASES[@]}; i++ )); do
        alias="${RUN_HOST_ALIASES[$i]}"
        target="${RUN_HOST_TARGETS[$i]}"
        marker=" "
        status="offline"
        local_mark=""
        if _mesh_alias_in_list "$alias" "${RUN_ONLINE_ALIASES[@]+"${RUN_ONLINE_ALIASES[@]}"}"; then
            marker="x"
            status="online"
        fi
        [[ "$alias" == "$self" ]] && local_mark=", local"
        printf '  %2d. [%s] %-10s ssh:%-14s %s%s\n' "$((i+1))" "$marker" "$alias" "$target" "$status" "$local_mark" >&2
    done
    printf '\n' >&2
}

_mesh_select_text() {
    local default_display="" alias answer lowered
    _mesh_text_selector_available || _die "run: no interactive selector available; pass --hosts, --online, or --all"
    _mesh_print_selector

    for alias in "${RUN_HOST_ALIASES[@]+"${RUN_HOST_ALIASES[@]}"}"; do
        if _mesh_alias_in_list "$alias" "${RUN_ONLINE_ALIASES[@]+"${RUN_ONLINE_ALIASES[@]}"}"; then
            default_display="${default_display:+$default_display,}$alias"
        fi
    done
    [[ -n "$default_display" ]] || default_display="none"

    answer="$(ask_line "Hosts [$default_display]")"

    lowered="$(_lower "$answer")"
    case "$lowered" in
        "")
            _mesh_select_online_hosts
            ;;
        all)
            _mesh_select_all_hosts
            ;;
        none|q|quit|cancel)
            RUN_SELECTED_ALIASES=()
            RUN_SELECTED_TARGETS=()
            ;;
        *)
            _mesh_select_from_spec "$answer"
            ;;
    esac
}

_mesh_select_interactive() {
    case "${MESH_RUN_SELECTOR:-auto}" in
        fzf)
            _mesh_select_fzf || _mesh_select_text
            ;;
        whiptail)
            _mesh_select_whiptail || _mesh_select_text
            ;;
        text)
            _mesh_select_text
            ;;
        auto|"")
            _mesh_select_fzf || _mesh_select_whiptail || _mesh_select_text
            ;;
        *)
            _die "run: unknown selector '${MESH_RUN_SELECTOR}' (expected auto | fzf | whiptail | text)"
            ;;
    esac
}

_mesh_quote_args() {
    local out="" q arg
    for arg in "$@"; do
        printf -v q '%q' "$arg"
        out="${out:+$out }$q"
    done
    printf '%s' "$out"
}

_mesh_fanout_validate_any() {
    return 0
}

_run_update_args_are_interactive() {
    local arg
    for arg in "$@"; do
        case "$arg" in
            -i|--interactive) return 0 ;;
        esac
    done
    return 1
}

_mesh_fanout_validate_update() {
    if _run_update_args_are_interactive "$@"; then
        _die "run: update -i/--interactive is not supported across hosts; run it on one host at a time"
    fi
}

_mesh_fanout_validate_syncthing() {
    case "${1:-}" in
        pair|status) ;;
        *) _die "run: only \`syncthing pair\` and \`syncthing status\` can fan out (got '${1:-}')" ;;
    esac
}

_mesh_fanout_env_noninteractive() {
    printf 'NON_INTERACTIVE=1\n'
}

_mesh_collect_fanout_env() {
    local provider="$1" out line
    shift || true
    [[ -n "$provider" ]] || return 0

    out="$("$provider" "$@")" || _die "run: fanout env provider failed: $provider"
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        if [[ ! "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
            _die "run: fanout env provider $provider emitted malformed record: $line"
        fi
    done <<<"$out"
    [[ -n "$out" ]] && printf '%s\n' "$out"
}

_mesh_env_records_to_remote_prefix() {
    local records="$1" line key value q out=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        printf -v q '%q' "$value"
        out="${out}${key}=${q}; export ${key}; "
    done <<<"$records"
    printf '%s' "$out"
}

_mesh_remote_command() {
    local env_records="$1"
    shift || true
    local quoted env_prefix=""
    quoted="$(_mesh_quote_args "$@")"
    env_prefix="$(_mesh_env_records_to_remote_prefix "$env_records")"
    printf "%sDEV_BOOTSTRAP_TMUX_AUTO_MAIN=0; export DEV_BOOTSTRAP_TMUX_AUTO_MAIN; if command -v mesh >/dev/null 2>&1; then mesh %s; elif [ -x \"\$HOME/.local/bin/mesh\" ]; then \"\$HOME/.local/bin/mesh\" %s; else echo \"mesh: remote mesh command not found\" >&2; exit 127; fi" "$env_prefix" "$quoted" "$quoted"
}

_mesh_command_display() {
    printf 'mesh %s' "$(_mesh_quote_args "$@")"
}

_mesh_run_local_with_env() {
    local env_records="$1"
    shift || true
    (
        local line
        DEV_BOOTSTRAP_TMUX_AUTO_MAIN=0
        export DEV_BOOTSTRAP_TMUX_AUTO_MAIN
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            # line is a validated KEY=value record from fanout_env.
            # shellcheck disable=SC2163
            export "$line"
        done <<<"$env_records"
        bash "$HERE/mesh" "$@"
    )
}

_print_run_help() {
    cat <<'EOF'
Usage:
  mesh run [--hosts A,B | --online | --all] [--dry-run] <subcommand> [args...]

Default with no host flag opens a multi-select when fzf/whiptail is available.
Online configured hosts are preselected; Tab toggles, Enter confirms. A text
prompt is used only as fallback when no interactive selector is available.

Supported subcommands: status, snap, update, syncthing pair|status.

Examples:
  mesh run update -f
  mesh run --hosts mac,crc update -f
  mesh run --online snap --quiet
  mesh run --all status --write
  mesh run --all syncthing pair          Reconcile every host from one place
EOF
}

cmd_run_run() {
    local mode="select"
    local host_spec=""
    local dry_run=0
    local value

    while (( $# > 0 )); do
        case "$1" in
            -h|--help)
                _print_run_help
                return 0
                ;;
            --hosts)
                [[ "$mode" == "select" ]] || _die "run: choose only one host selector (--hosts, --online, --all)"
                shift
                value="${1:-}"
                [[ -n "$value" && "$value" != -* ]] || _die "run: --hosts requires a comma-separated host list"
                host_spec="$value"
                mode="hosts"
                shift
                ;;
            --hosts=*)
                [[ "$mode" == "select" ]] || _die "run: choose only one host selector (--hosts, --online, --all)"
                host_spec="${1#*=}"
                [[ -n "$host_spec" ]] || _die "run: --hosts requires a comma-separated host list"
                mode="hosts"
                shift
                ;;
            --online)
                [[ "$mode" == "select" ]] || _die "run: choose only one host selector (--hosts, --online, --all)"
                mode="online"
                shift
                ;;
            --all)
                [[ "$mode" == "select" ]] || _die "run: choose only one host selector (--hosts, --online, --all)"
                mode="all"
                shift
                ;;
            --dry-run)
                dry_run=1
                shift
                ;;
            --)
                shift
                break
                ;;
            --*|-*)
                _die "run: unknown flag '$1'"
                ;;
            *)
                break
                ;;
        esac
    done

    (( $# > 0 )) || _die "run: missing mesh subcommand (status | snap | update | syncthing pair|status)"
    local mesh_subcommand="$1"
    shift
    local mesh_args=("$@")
    local fanout validator env_provider fanout_env_records
    if ! mesh_command_registered "$mesh_subcommand"; then
        _die "run: unsupported mesh subcommand '$mesh_subcommand' (supported commands are registered with fanout validators)"
    fi
    fanout="$(mesh_command_get "$mesh_subcommand" fanout)" || _die "run: command has no fanout metadata: $mesh_subcommand"
    validator="$(mesh_command_get "$mesh_subcommand" fanout_validator)" || _die "run: command has no fanout validator metadata: $mesh_subcommand"
    env_provider="$(mesh_command_get "$mesh_subcommand" fanout_env_provider)" || _die "run: command has no fanout env metadata: $mesh_subcommand"

    if [[ "$fanout" != "allowed" || -z "$validator" ]]; then
        _die "run: unsupported mesh subcommand '$mesh_subcommand' (no registered fanout validator)"
    fi
    "$validator" "${mesh_args[@]+"${mesh_args[@]}"}" || return $?
    fanout_env_records="$(_mesh_collect_fanout_env "$env_provider" "${mesh_args[@]+"${mesh_args[@]}"}")" || return $?

    _mesh_load_run_hosts
    _mesh_collect_online_aliases

    case "$mode" in
        select) _mesh_select_interactive ;;
        hosts)  _mesh_select_from_spec "$host_spec" ;;
        online) _mesh_select_online_hosts ;;
        all)    _mesh_select_all_hosts ;;
    esac

    if (( ${#RUN_SELECTED_ALIASES[@]} == 0 )); then
        printf 'mesh run: no hosts selected\n' >&2
        return 0
    fi

    local self_alias
    self_alias="$(_mesh_self_alias)"
    local display
    display="$(_mesh_command_display "$mesh_subcommand" "${mesh_args[@]+"${mesh_args[@]}"}")"
    printf 'mesh run: %s\n' "$display" >&2

    local failed=0
    local i alias target rc remote_cmd
    for (( i=0; i<${#RUN_SELECTED_ALIASES[@]}; i++ )); do
        alias="${RUN_SELECTED_ALIASES[$i]}"
        target="${RUN_SELECTED_TARGETS[$i]}"

        if [[ "$alias" == "$self_alias" ]]; then
            if (( dry_run )); then
                printf 'DRY-RUN: %s (local): %s\n' "$alias" "$display" >&2
                continue
            fi
            printf '\n== %s (local) ==\n' "$alias" >&2
            _mesh_run_local_with_env "$fanout_env_records" "$mesh_subcommand" "${mesh_args[@]+"${mesh_args[@]}"}"
            rc=$?
        else
            if (( dry_run )); then
                printf 'DRY-RUN: %s (ssh %s): %s\n' "$alias" "$target" "$display" >&2
                continue
            fi
            printf '\n== %s (ssh %s) ==\n' "$alias" "$target" >&2
            remote_cmd="$(_mesh_remote_command "$fanout_env_records" "$mesh_subcommand" "${mesh_args[@]+"${mesh_args[@]}"}")"
            "${MESH_RUN_SSH:-ssh}" -tt "$target" "$remote_cmd"
            rc=$?
        fi

        if (( rc != 0 )); then
            failed=1
            printf 'mesh run: %s failed (rc=%d)\n' "$alias" "$rc" >&2
        fi
    done

    return "$failed"
}

sub_run() {
    cmd_run_run "$@"
}

mesh_register_command \
    --name run \
    --summary "Fan out mesh subcommands across hosts" \
    --group core \
    --origin core \
    --visibility public \
    --fanout none \
    --handler cmd_run_run
