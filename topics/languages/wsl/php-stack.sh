#!/usr/bin/env bash
# Custom: PHP multi-version + PECL extensions + Composer + Python (wsl).
# Bundles ~200 LOC of the original install.wsl.sh verbatim, wrapped in
# the engine contract.

_php_versions_for_stack() {
    local PHP_VERSIONS_FILE versions
    PHP_VERSIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/data/php-versions.conf"
    versions="${PHP_VERSIONS:-}"
    if [[ -z "$versions" && -f "$PHP_VERSIONS_FILE" ]]; then
        versions="$(grep -vE '^\s*(#|$)' "$PHP_VERSIONS_FILE" | xargs)"
    fi
    [[ -n "$versions" ]] || return 1
    printf '%s\n' "$versions"
}

_php_pecl_extensions_for_stack() {
    local PECL_EXTENSIONS_FILE line ext
    PECL_EXTENSIONS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/data/php-extensions-pecl.txt"
    [[ -f "$PECL_EXTENSIONS_FILE" ]] || return 1
    while IFS= read -r line; do
        case "$line" in
            ""|\#*) continue ;;
        esac
        IFS=':' read -r ext _ _ <<< "$line"
        [[ -n "$ext" ]] && printf '%s\n' "$ext"
    done < "$PECL_EXTENSIONS_FILE"
}

_php_bin_for_version() {
    local ver="$1"
    printf '%s/php%s\n' "${PHP_CLI_BIN_DIR:-/usr/bin}" "$ver"
}

_php_cli_starts_clean() {
    local ver="$1"
    local php_bin
    php_bin="$(_php_bin_for_version "$ver")"
    [[ -x "$php_bin" ]] || {
        echo "php${ver}: php binary missing at $php_bin" >&2
        return 1
    }

    local tmp rc
    tmp="$(mktemp -d -t mesh-php-verify.XXXXXX)" || return 1
    "$php_bin" -v >"$tmp/out" 2>"$tmp/err"; rc=$?
    cat "$tmp/out" "$tmp/err" > "$tmp/all"
    if [[ "$rc" -ne 0 ]]; then
        sed -n '1,4p' "$tmp/all" >&2
        rm -rf "$tmp"
        return 1
    fi
    if [[ -s "$tmp/err" ]]; then
        sed -n '1,4p' "$tmp/err" >&2
        rm -rf "$tmp"
        return 1
    fi
    rm -rf "$tmp"
    return 0
}

_php_module_loaded_for_version() {
    local ver="$1" ext="$2"
    local php_bin
    php_bin="$(_php_bin_for_version "$ver")"
    [[ -x "$php_bin" ]] || {
        echo "php${ver}: php binary missing at $php_bin" >&2
        return 1
    }

    local mods
    mods="$("$php_bin" -m 2>/dev/null)" || return 1
    grep -qiE "^${ext}\$|^${ext//pdo_/PDO_}\$" <<< "$mods"
}

_php_extension_dir_for_version() {
    local ver="$1" bin_dir php_config ext_dir api
    bin_dir="${PHP_CLI_BIN_DIR:-/usr/bin}"
    php_config="${bin_dir}/php-config${ver}"
    [[ -x "$php_config" ]] || return 1
    ext_dir="$("$php_config" --extension-dir 2>/dev/null || true)"
    if [[ -n "$ext_dir" ]]; then
        printf '%s\n' "$ext_dir"
        return 0
    fi
    api="$("$php_config" --phpapi 2>/dev/null || true)"
    [[ -n "$api" ]] || return 1
    printf '%s/%s\n' "${PHP_EXTENSION_ROOT:-/usr/lib/php}" "$api"
}

_mesh_php_state_dir() {
    if declare -F mesh_state_dir >/dev/null 2>&1; then
        mesh_state_dir
    else
        printf '%s' "${MESH_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/mesh}"
    fi
}

_mesh_owns_pecl_ext() {
    local wanted="$1" ext
    while IFS= read -r ext; do
        [[ "$ext" == "$wanted" ]] && return 0
    done < <(_php_pecl_extensions_for_stack)
    return 1
}

_ini_declares_extension() {
    local ini="$1" ext="$2" ext_value ext_name
    [[ -f "$ini" ]] || return 1
    ext_value="$(awk -F= '/^[[:space:]]*extension[[:space:]]*=/{print $2; exit}' "$ini" | tr -d ' "')"
    [[ "$ext_value" == *.so ]] || return 1
    ext_name="$(basename "$ext_value" .so)"
    [[ "$ext_name" == "$ext" ]]
}

_quarantine_wsl_php_ini() {
    local ini="$1" quarantine_root="$2" php_etc_root="$3"
    local rel dest
    rel="${ini#"${php_etc_root}/"}"
    [[ "$rel" == "$ini" ]] && rel="${ini#/}"
    rel="${rel//\//__}"
    dest="${quarantine_root}/${rel}"
    sudo mkdir -p "$quarantine_root"
    if sudo mv "$ini" "$dest"; then
        echo "[orphan-ini] moved $ini -> $dest" >&2
        return 0
    fi
    return 1
}

_quarantine_stale_wsl_pecl_inis() {
    local versions pecl_exts php_etc_root quarantine_root moved=0 failed=0
    versions="$(_php_versions_for_stack)" || return 1
    pecl_exts="$(_php_pecl_extensions_for_stack)" || return 1
    php_etc_root="${PHP_ETC_ROOT:-/etc/php}"
    quarantine_root="$(_mesh_php_state_dir)/orphan-ini-quarantine"

    local ver ext ext_dir ini_dir ini
    for ver in $versions; do
        ext_dir="$(_php_extension_dir_for_version "$ver" 2>/dev/null || true)"
        [[ -n "$ext_dir" ]] || continue
        for ext in $pecl_exts; do
            _mesh_owns_pecl_ext "$ext" || continue
            [[ -f "${ext_dir}/${ext}.so" ]] && continue
            for ini_dir in \
                "${php_etc_root}/${ver}/cli/conf.d" \
                "${php_etc_root}/${ver}/fpm/conf.d" \
                "${php_etc_root}/${ver}/mods-available"; do
                [[ -d "$ini_dir" ]] || continue
                for ini in "$ini_dir"/*.ini; do
                    [[ -e "$ini" ]] || continue
                    _ini_declares_extension "$ini" "$ext" || continue
                    warn "php${ver}: quarantining stale PECL ini -> $ini (${ext}.so not found at ${ext_dir})"
                    if _quarantine_wsl_php_ini "$ini" "$quarantine_root" "$php_etc_root"; then
                        moved=1
                    else
                        failed=1
                    fi
                done
            done
        done
    done

    if [[ "$moved" -eq 1 ]] && declare -F followup >/dev/null 2>&1; then
        followup info "orphan PECL .ini files were quarantined to $quarantine_root — review and remove once satisfied."
    fi
    [[ "$failed" -eq 0 ]]
}

check() {
    command -v composer >/dev/null 2>&1 || return 1
    command -v python3 >/dev/null 2>&1 || return 1
    # Codex review 2026-05-19 (E-F002): the previous check only required
    # ANY php on PATH. That passed on the system php while skipping
    # multi-PHP install. Now require all declared PHP_VERSIONS installed
    # via dpkg. Empty PHP_VERSIONS = no version constraint (initial install).
    local versions
    versions="$(_php_versions_for_stack)" || return 1
    local ver
    for ver in $versions; do
        dpkg -s "php${ver}-fpm" >/dev/null 2>&1 || return 1
    done
    return 0
}

install() {
    local HERE
    HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    HERE="$HERE/.."
    # shellcheck disable=SC1091
    . "${MESH_WORKSTATION_DIR:-$(cd "$HERE/../.." && pwd)}/scripts/lib/log.sh"
    export DEBIAN_FRONTEND=noninteractive
    # Track non-fatal failures of load-bearing steps so a partial install
    # surfaces as a real install failure at the end, instead of the trailing
    # `ok` (rc 0) masking it as success. PECL extension failures are
    # deliberately tolerated by lib/pecl-install.sh and excluded here.
    local _phpstack_fail=0

# ─── PHP versions (multi) ──────────────────────────────────────────────
# PHP_VERSIONS can come from env (menu or automation). If unset, install all
# supported versions from data/php-versions.conf.
PHP_VERSIONS_FILE="$HERE/data/php-versions.conf"
if [[ -z "${PHP_VERSIONS:-}" ]]; then
    PHP_VERSIONS="$(grep -vE '^\s*(#|$)' "$PHP_VERSIONS_FILE" | xargs)"
    info "PHP_VERSIONS unset — defaulting to all supported ($PHP_VERSIONS)"
fi

# PHP default = highest version (version-sorted, last)
PHP_DEFAULT="${PHP_DEFAULT:-$(echo "$PHP_VERSIONS" | tr ' ' '\n' | sort -V | tail -1)}"
info "PHP versions to install: $PHP_VERSIONS (default: $PHP_DEFAULT)"
export PHP_DEFAULT

# Ensure ondrej/php PPA is enabled (once — all versions share it)
if ! grep -Rq 'ondrej/php' /etc/apt/sources.list.d/ 2>/dev/null; then
    info "enabling ondrej/php PPA"
    sudo add-apt-repository -y ppa:ondrej/php
    sudo apt-get update -qq
fi

# Read extension lists once (while-read for bash 3.2 compat — see Mac notes)
APT_EXTS=()
while IFS= read -r _line; do
    APT_EXTS+=("$_line")
done < <(grep -vE '^\s*(#|$)' "$HERE/data/php-extensions-apt.txt")
unset _line

install_php_version() {
    local ver="$1"
    local pkgs=("php${ver}" "php${ver}-cli" "php${ver}-common" "php${ver}-fpm")
    for ext in "${APT_EXTS[@]}"; do
        pkgs+=("php${ver}-${ext}")
    done

    local missing=()
    for p in "${pkgs[@]}"; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done

    if [[ "${#missing[@]}" -eq 0 ]]; then
        ok "PHP $ver and all baseline extensions already installed"
        return 0
    fi

    info "apt install PHP $ver + extensions (${#missing[@]} pkgs)"
    # `--no-install-recommends`: the `phpX.Y` meta-package on Sury PPA carries
    #   Recommends: libapache2-mod-phpX.Y | phpX.Y-fpm
    # When BOTH are absent at install time apt picks the FIRST option (the
    # mod_php shim), which Depends: apache2 + apache2-bin + apache2-data +
    # apache2-utils. apache2 then starts on :80 by default, blocking nginx.
    # On crc 2026-04-24 this dragged apache2 onto the corporate machine and
    # left nginx in `failed` for 22h. Our pkgs[] is exhaustive — Recommends
    # only ADD packages we did not request, so suppressing them is safe.
    if ! sudo apt-get install -y -qq --no-install-recommends "${missing[@]}"; then
        fail "PHP $ver: apt install failed"
        return 1
    fi
    ok "PHP $ver installed"
}

for ver in $PHP_VERSIONS; do
    install_php_version "$ver" || _phpstack_fail=1
done

# ─── PHP default via update-alternatives ──────────────────────────────
# The `php` symlink (and phar/phpize/pecl helpers) follows the alternatives
# group. Setting one auto-sets the rest. Safe to run on every bootstrap —
# noop if already pointing at the desired version.
info "setting PHP default = $PHP_DEFAULT"
for bin in php phar phar.phar phpize php-config; do
    target="/usr/bin/${bin}${PHP_DEFAULT}"
    if [[ -x "$target" ]]; then
        sudo update-alternatives --set "$bin" "$target" >/dev/null 2>&1 || true
    fi
done
ok "PHP CLI default: $(php -r 'echo PHP_VERSION;' 2>/dev/null || echo '?')"

# ─── PECL extensions (per version) ────────────────────────────────────
# Each major PHP has an ABI-distinct .so; we install the same extension
# once per version of PHP_VERSIONS. Build deps in the second colon-column
# of data/php-extensions-pecl.txt apply to all versions (installed once).
info "installing PECL extensions for each PHP version"

PECL_LINES=()
while IFS= read -r _line; do
    PECL_LINES+=("$_line")
done < <(grep -vE '^\s*(#|$)' "$HERE/data/php-extensions-pecl.txt")
unset _line

# Collect the union of linux build deps across all pecl lines
pecl_build_deps=()
for line in "${PECL_LINES[@]}"; do
    # line format: ext[:linux-deps[:mac-deps]]
    IFS=':' read -r _ linux_deps _ <<< "$line"
    if [[ -n "$linux_deps" ]]; then
        # shellcheck disable=SC2206
        pecl_build_deps+=($linux_deps)
    fi
done
# unixodbc-dev not in PECL list but needed for MSSQL add-on later; leave out here.

# Always need the dev toolchain for PECL builds. Install once.
core_build_deps=(build-essential pkg-config autoconf)
combined_deps=("${core_build_deps[@]}" "${pecl_build_deps[@]+"${pecl_build_deps[@]}"}")
missing_deps=()
for p in "${combined_deps[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing_deps+=("$p")
done
if [[ "${#missing_deps[@]}" -gt 0 ]]; then
    info "installing PECL build deps: ${missing_deps[*]}"
    sudo apt-get install -y -qq --no-install-recommends "${missing_deps[@]}" \
        || { fail "PECL build deps: apt install failed"; _phpstack_fail=1; }
fi

# Also need per-version dev headers to compile .so for that PHP
for ver in $PHP_VERSIONS; do
    if ! dpkg -s "php${ver}-dev" >/dev/null 2>&1; then
        info "installing php${ver}-dev (headers for PECL build)"
        sudo apt-get install -y -qq --no-install-recommends "php${ver}-dev" \
            || { fail "php${ver}-dev: apt install failed"; _phpstack_fail=1; }
    fi
done


# pecl_install_for_version_linux is provided by lib/pecl-install.sh —
# single source of truth for the 4-env-var PECL fix. See its header
# for the 5-commit bug saga and each env var's role.
# shellcheck disable=SC1091
source "${MESH_WORKSTATION_DIR:-$(cd "$HERE/../.." && pwd)}/scripts/lib/pecl-install.sh"

for line in "${PECL_LINES[@]}"; do
    IFS=':' read -r ext _ _ <<< "$line"
    for ver in $PHP_VERSIONS; do
        pecl_install_for_version_linux "$ver" "$ext"
    done
done
_quarantine_stale_wsl_pecl_inis || _phpstack_fail=1

# ─── Composer (bound to PHP default) ─────────────────────────────────
# Guard on the FUNCTIONAL probe verify() uses (`composer --version` runs),
# not mere presence: a present-but-broken composer (corrupt phar, or the
# default PHP changed under it) must be re-fetched during `mesh doctor --fix`
# / repair() → install(). A presence-only guard would skip it and the engine
# re-probe would report "still broken after repair".
if ! command -v composer >/dev/null 2>&1 || ! composer --version >/dev/null 2>&1; then
    info "installing Composer (with checksum verification)"
    expected_checksum="$(curl -fsSL https://composer.github.io/installer.sig)"
    php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
    actual_checksum="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
    if [[ "$expected_checksum" != "$actual_checksum" ]]; then
        fail "Composer installer checksum mismatch"
        rm -f /tmp/composer-setup.php
        exit 1
    fi
    if ! sudo php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet; then
        fail "Composer install failed"
        _phpstack_fail=1
    fi
    rm -f /tmp/composer-setup.php
else
    ok "Composer already installed ($(composer --version --no-ansi 2>/dev/null | head -1 || true))"
fi

# ─── Per-version composer wrappers ──────────────────────────────────
# `composer` (no suffix) always uses $PHP_DEFAULT (via update-alternatives
# → `php`). Generate `composer<maj.min>` for each NON-default version so
# `composer8.4 install` works from an 8.5-default environment without
# calling `php-use 8.4` globally.
#
# WSL installs php binaries at /usr/bin/php<maj.min>; composer lives at
# /usr/local/bin/composer. Wrappers land in ~/.local/bin (user-writable,
# in PATH by dotfiles/mesh-workstation convention).
_compose_wrapper_dir="$HOME/.local/bin"
mkdir -p "$_compose_wrapper_dir"
for ver in $PHP_VERSIONS; do
    [[ "$ver" == "$PHP_DEFAULT" ]] && continue
    _php_bin="/usr/bin/php${ver}"
    _wrapper="$_compose_wrapper_dir/composer${ver}"
    if [[ ! -x "$_php_bin" ]]; then
        warn "composer${ver}: php${ver} not installed at $_php_bin — skipping wrapper"
        continue
    fi
    # Resolve composer at wrapper RUN time via an explicit priority list.
    # Same reasoning as the Mac side (see install.mac.sh for full rationale):
    # user-local > /usr/local > PATH-fallback. On WSL the common install
    # path is /usr/local/bin/composer (written by the installer above), but
    # a user may have overriden with ~/.local/bin/composer for specific
    # version control — honor that.
    cat > "$_wrapper" <<EOF
#!/usr/bin/env bash
# composer${ver} — Managed by mesh-workstation / 10-languages.
# Runs Composer with PHP ${ver} instead of the machine's default PHP.
# Generated once per non-default version in PHP_VERSIONS; safe to delete
# (bootstrap re-creates) but not safe to edit (overwritten on next run).
set -e
_composer_bin=""
for c in "\$HOME/.local/bin/composer" "/usr/local/bin/composer"; do
    if [[ -x "\$c" ]]; then _composer_bin="\$c"; break; fi
done
if [[ -z "\$_composer_bin" ]]; then
    _self_dir="\$(cd "\$(dirname "\$0")" && pwd)"
    _composer_bin="\$(PATH="\${PATH//\$_self_dir:/}\${PATH//:\$_self_dir/}" command -v composer 2>/dev/null || true)"
fi
if [[ -z "\$_composer_bin" ]]; then
    echo "composer${ver}: no composer binary found (checked ~/.local/bin, /usr/local/bin, PATH)" >&2
    exit 127
fi
exec "${_php_bin}" "\$_composer_bin" "\$@"
EOF
    chmod +x "$_wrapper"
    ok "composer${ver} → php${ver}"
done
unset _compose_wrapper_dir _php_bin _wrapper

# ─── Python ────────────────────────────────────────────────────────────
if ! command -v python3 >/dev/null 2>&1; then
    info "installing python3"
    sudo apt-get install -y -qq python3 python3-pip python3-venv \
        || { fail "python3 install failed"; _phpstack_fail=1; }
else
    ok "python3 already installed ($(python3 --version))"
fi

if [[ "$_phpstack_fail" -ne 0 ]]; then
    fail "10-languages: one or more install steps failed (see above) — reporting install failure"
    return 1
fi
ok "10-languages done — PHP default: $PHP_DEFAULT"
}

verify() {
    # Mirror check() (composer + python3 + every declared php${ver}-fpm via
    # dpkg) so post-verify and the next run's idempotency pre-check agree on
    # what "installed" means — a partial install (missing version / PECL) no
    # longer reads as done. Also assert composer actually runs.
    check || return 1
    local versions pecl_exts ver ext
    versions="$(_php_versions_for_stack)" || return 1
    pecl_exts="$(_php_pecl_extensions_for_stack)" || return 1
    for ver in $versions; do
        _php_cli_starts_clean "$ver" || return 1
        for ext in $pecl_exts; do
            if ! _php_module_loaded_for_version "$ver" "$ext"; then
                echo "php${ver}: required PECL extension $ext is not loaded" >&2
                return 1
            fi
        done
    done
    composer --version >/dev/null 2>&1
}

repair() { install; }

rollback() {
    :
}
