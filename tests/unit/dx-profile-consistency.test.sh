#!/usr/bin/env bash
# dx-profile-consistency.test.sh — one classification, checked in phase order.
# Active sections must stay green. A later phase turns a skipped section on
# by replacing its body. Do not weaken an earlier assertion.
# Bash 3.2: no mapfile, readarray, or ${var^^}.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1091
source "$WS/tests/lib/assert.sh"

PARSER="$WS/scripts/lib/yaml-parse.sh"
CONTRACT="$WS/scripts/data/dx-profiles.yaml"

dx_skip() {
    printf '  - SKIP %s (on in %s)\n' "$1" "$2"
}

# Print requires_bundles for the named section, one id per line. Return 1
# when the section is absent.
dx_section() {
    local want="$1"
    local n i name_v name count_v count j item_v
    n="${BUNDLE_COUNT:-0}"
    i=0
    while [ "$i" -lt "$n" ]; do
        name_v="BUNDLE_${i}_NAME"
        name="${!name_v:-}"
        if [ "$name" = "$want" ]; then
            count_v="BUNDLE_${i}_REQUIRES_BUNDLES_COUNT"
            count="${!count_v:-0}"
            j=0
            while [ "$j" -lt "$count" ]; do
                item_v="BUNDLE_${i}_REQUIRES_BUNDLES_${j}"
                printf '%s\n' "${!item_v}"
                j=$((j + 1))
            done
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

dx_expect_section() {
    local name="$1" expected="$2" got
    if ! got="$(dx_section "$name")"; then
        fail "$name section is missing from dx-profiles.yaml"
        return
    fi
    if [ "$got" = "$expected" ]; then
        pass "$name matches the contract"
    else
        fail "$name drifted from the contract"
        printf '      expected:\n%s\n      actual:\n%s\n' "$expected" "$got" >&2
    fi
}

# contract-shape — on in F0
contract_shape() {
    local parsed rc names
    parsed="$(bash "$PARSER" < "$CONTRACT" 2>"$HERE/dx-profile-parse.err")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "yaml-parse.sh rejected dx-profiles.yaml (rc=$rc)"
        cat "$HERE/dx-profile-parse.err" >&2
        rm -f "$HERE/dx-profile-parse.err"
        return
    fi
    rm -f "$HERE/dx-profile-parse.err"
    # shellcheck disable=SC2163
    eval "$parsed"
    if [ "${__YAML_PARSE_OK:-0}" = "1" ]; then
        pass "yaml-parse.sh loaded dx-profiles.yaml"
    else
        fail "yaml-parse.sh output missing sentinel"
        return
    fi

    names=""
    local n i name_v name
    n="${BUNDLE_COUNT:-0}"
    i=0
    while [ "$i" -lt "$n" ]; do
        name_v="BUNDLE_${i}_NAME"
        name="${!name_v:-}"
        names="${names}${name}"$'\n'
        i=$((i + 1))
    done
    names="${names%$'\n'}"
    local expected_names
    expected_names="$(printf '%s\n' \
        removed \
        removed-commands \
        workstation-default \
        workstation-optional \
        server-default \
        server-optional \
        server-forbidden \
        identity-only \
        conflicts \
        doctor-workstation \
        doctor-workstation-flock \
        doctor-server \
        doctor-retired \
        denylist \
        flag-retirement)"
    if [ "$names" = "$expected_names" ]; then
        pass "section names match the contract"
    else
        fail "section names drifted"
        printf '      expected:\n%s\n      actual:\n%s\n' "$expected_names" "$names" >&2
    fi

    dx_expect_section removed "$(printf '%s\n' \
        languages/node \
        languages/php \
        databases/mysql \
        databases/redis \
        databases/postgresql \
        databases/mssql-driver \
        web/valet \
        web/nginx-php-fpm \
        web/mailpit \
        web/ngrok \
        containers/docker \
        remote-access/tuios \
        remote-access/tuios-cloudflare)"

    dx_expect_section removed-commands "$(printf '%s\n' tuios services)"

    dx_expect_section workstation-default "$(printf '%s\n' \
        foundation/base \
        shell-terminal/cli-tools \
        shell-terminal/zsh \
        shell-terminal/tmux \
        shell-terminal/nvim \
        shell-terminal/fonts \
        git/config \
        git/lazygit \
        apps/herdr \
        apps/herdr-app \
        apps/flyenv)"

    dx_expect_section workstation-optional "$(printf '%s\n' \
        apps/flock \
        git/gpg-signing \
        ai/claude-code \
        ai/moshi-hook \
        ai/mdprobe \
        ai/atomic-skills \
        ai/rtk \
        ai/claude-mem \
        remote-access/ssh \
        remote-access/mosh \
        remote-access/tailscale \
        remote-access/code-server)"

    dx_expect_section server-default "$(printf '%s\n' \
        foundation/base \
        shell-terminal/cli-tools \
        shell-terminal/zsh \
        shell-terminal/tmux \
        shell-terminal/nvim \
        git/config \
        git/lazygit \
        apps/herdr)"

    dx_expect_section server-optional "$(printf '%s\n' git/gpg-signing)"

    dx_expect_section server-forbidden "$(printf '%s\n' \
        shell-terminal/fonts \
        apps/flyenv \
        apps/flock \
        apps/herdr-app \
        ai/claude-code \
        ai/moshi-hook \
        ai/mdprobe \
        ai/atomic-skills \
        ai/rtk \
        ai/claude-mem \
        remote-access/ssh \
        remote-access/mosh \
        remote-access/tailscale \
        remote-access/code-server \
        identity/identity \
        personal/personal \
        syncthing/syncthing)"

    dx_expect_section identity-only "$(printf '%s\n' \
        identity/identity \
        personal/personal \
        syncthing/syncthing)"

    dx_expect_section conflicts "$(printf '%s\n' apps/flyenv apps/flock)"

    dx_expect_section doctor-workstation "$(printf '%s\n' \
        foundation/base \
        herdr-on-path \
        flyenv-present \
        flock-absent)"

    dx_expect_section doctor-workstation-flock "$(printf '%s\n' \
        flock-present \
        flyenv-absent)"

    dx_expect_section doctor-server "$(printf '%s\n' \
        foundation/base \
        herdr-on-path)"

    dx_expect_section doctor-retired "$(printf '%s\n' \
        php-stack \
        valet \
        nginx-php-fpm \
        mysql \
        redis \
        postgresql \
        tuios)"

    dx_expect_section denylist "$(printf '%s\n' \
        shell/completions/_artisan \
        shell/completions/_php_with_artisan \
        config/tuios-peers.json \
        config/tuios-hosts.json)"

    dx_expect_section flag-retirement "$(printf '%s\n' \
        "--no-mesh was removed. setup.sh is DX and does not join identity." \
        "For a headless Linux server: setup.sh --server")"
}

# on in F1
removed_bundles() { dx_skip "removed-bundles" "F1"; }

# on in F1
removed_commands() { dx_skip "removed-commands" "F1"; }

# on in F2
profiles() { dx_skip "profiles" "F2"; }

# on in F2
conflicts() { dx_skip "conflicts" "F2"; }

# on in F2
linux_platform() { dx_skip "linux-platform" "F2"; }

# on in F2
menu_node() { dx_skip "menu-node" "F2"; }

# on in F3
identity_gate() { dx_skip "identity-gate" "F3"; }

# on in F3
identity_denylist() { dx_skip "identity-denylist" "F3"; }

# on in F4
docs() { dx_skip "docs" "F4"; }

# on in F4
doctor() { dx_skip "doctor" "F4"; }

echo "=== contract-shape ==="
contract_shape
echo "=== removed-bundles ==="
removed_bundles
echo "=== removed-commands ==="
removed_commands
echo "=== profiles ==="
profiles
echo "=== conflicts ==="
conflicts
echo "=== linux-platform ==="
linux_platform
echo "=== menu-node ==="
menu_node
echo "=== identity-gate ==="
identity_gate
echo "=== identity-denylist ==="
identity_denylist
echo "=== docs ==="
docs
echo "=== doctor ==="
doctor
summary
