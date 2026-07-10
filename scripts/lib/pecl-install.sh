#!/usr/bin/env bash
# shellcheck shell=bash
# lib/pecl-install.sh — canonical per-version PECL install for Linux/WSL.
# Source this file; do NOT execute. Exposes:
#
#   pecl_install_for_version_linux  VER  EXT  [CONTEXT_LABEL]
#
# Why a shared lib:
#   ondrej's `/usr/bin/pecl` is a single shell script bound to whatever
#   PHP `update-alternatives` points at. Building an extension for a
#   non-default PHP version requires four complementary env-var overrides
#   (PHP binary, bin_dir for PATH lookup, ext_dir for install target,
#   metadata_dir for registry isolation). This fix is non-trivial and
#   MUST be applied identically everywhere we install a PECL extension
#   — install.wsl.sh for the base extensions, install-mssql-driver.sh
#   for sqlsrv/pdo_sqlsrv, and any future topic that adds PECL extras.
#   Duplicating the implementation invites the next regression.
#
# The fix overrides four PEAR env vars (PHP_PEAR_PHP_BIN, BIN_DIR,
# EXTENSION_DIR, METADATA_DIR) to pin pecl to the target PHP version,
# covering every known failure mode from the 2026-04-23 saga.

# Guard against double-source
if declare -F pecl_install_for_version_linux >/dev/null 2>&1; then
    return 0 2>/dev/null || true
fi

# pecl_install_for_version_linux — build + enable $ext for PHP $ver.
#
# Args:
#   $1  PHP version     e.g. "8.3"
#   $2  extension name  e.g. "igbinary" / "sqlsrv"
#   $3  (optional) failure-message suffix — appended to warn() on a
#       build failure so topic-specific context is preserved (e.g.
#       "SQL Server support won't work on this PHP"). Defaults to
#       empty string.
#
# Contract:
#   - Idempotent: returns 0 fast when `php${ver} -m` already lists $ext.
#   - Skips cleanly (returns 0) if required per-version binaries are
#     missing; the caller decides whether that's a critical failure.
#   - Never exits nonzero on install failure by default — emits a warn() + log
#     tail and reports the outcome through PECL_INSTALL_RESULT /
#     PECL_INSTALL_CONVERGED, so legacy callers under `set -e` keep running
#     while stricter callers can fail on the recorded status.
#
# Environment dependencies:
#   - `info`, `warn`, `ok`  (from lib/log.sh)
#   - sudo (bootstrap warms the ticket upfront; this function does not
#     re-warm it — a single missed extension is acceptable, a stalled
#     bootstrap is not)
PECL_INSTALL_RESULT="not-run"
PECL_INSTALL_CONVERGED=0
PECL_INSTALL_DETAIL=""
PECL_INSTALL_SO_PATH=""

_pecl_install_set_status() {
    # shellcheck disable=SC2034
    PECL_INSTALL_RESULT="$1"
    # shellcheck disable=SC2034
    PECL_INSTALL_CONVERGED="$2"
    # shellcheck disable=SC2034
    PECL_INSTALL_DETAIL="${3:-}"
    # shellcheck disable=SC2034
    PECL_INSTALL_SO_PATH="${4:-}"
}

pecl_install_for_version_linux() {
    local ver="$1" ext="$2" fail_suffix="${3:-}"
    _pecl_install_set_status "not-run" 0 "" ""

    # ondrej does NOT ship per-version pecl binaries — only /usr/bin/pecl
    # plus phpize${ver} and php-config${ver}. See the feedback memory
    # for the full analysis. Below we override the four relevant stages
    # (shell, PEAR Builder, installer, registry) to pin everything to
    # the target version.
    local bin_dir="${PECL_INSTALL_BIN_DIR:-/usr/bin}"
    local extension_root="${PECL_INSTALL_EXTENSION_ROOT:-/usr/lib/php}"
    local php_etc_root="${PECL_INSTALL_ETC_ROOT:-/etc/php}"
    local pecl_bin="${bin_dir}/pecl"
    local php_bin="${bin_dir}/php${ver}"
    local phpize_bin="${bin_dir}/phpize${ver}"
    local php_config_bin="${bin_dir}/php-config${ver}"

    for _b in "$pecl_bin" "$php_bin" "$phpize_bin" "$php_config_bin"; do
        if [[ ! -x "$_b" ]]; then
            warn "PHP $ver: required binary $_b missing — skipping $ext"
            _pecl_install_set_status "skipped-missing-binary" 0 "$_b" ""
            return 0
        fi
    done

    local api
    api="$("$php_config_bin" --phpapi 2>/dev/null)"
    if [[ -z "$api" ]]; then
        warn "PHP $ver: could not resolve PHP API from $php_config_bin — skipping $ext"
        _pecl_install_set_status "skipped-no-api" 0 "$php_config_bin" ""
        return 0
    fi
    local target_ext_dir="${extension_root}/${api}"
    local so_path="${target_ext_dir}/${ext}.so"

    # Already loaded? Fast path — `pdo_sqlsrv` loads as `pdo_sqlsrv` but
    # appears in `php -m` as `PDO_SQLSRV`, so match both cases via the
    # `pdo_`→`PDO_` substitution.
    if "$php_bin" -m 2>/dev/null \
        | grep -qiE "^${ext}\$|^${ext//pdo_/PDO_}\$"; then
        ok "PHP $ver: $ext already loaded"
        _pecl_install_set_status "already-loaded" 1 "" "$so_path"
        return 0
    fi

    # Four scratch-state env vars + sudo env:
    #   PHP_PEAR_PHP_BIN        → /usr/bin/pecl's `exec` target
    #   PHP_PEAR_BIN_DIR        → dir PEAR prepends to PATH; our shim
    #                             has phpize/php-config → per-version
    #   PHP_PEAR_EXTENSION_DIR  → where .so lands
    #   PHP_PEAR_METADATA_DIR   → isolated registry per-call; without
    #                             this, the next -f install uninstalls
    #                             the previous version's .so first
    local tmpbin tmpmeta
    tmpbin="$(mktemp -d -t mesh-workstation-pecl-bin.XXXXXX)"
    tmpmeta="$(mktemp -d -t mesh-workstation-pecl-meta.XXXXXX)"
    ln -s "$phpize_bin"      "$tmpbin/phpize"
    ln -s "$php_config_bin"  "$tmpbin/php-config"
    ln -s "$php_bin"         "$tmpbin/php"
    # sudo rm + ||true: pecl runs as root and writes root-owned files
    # into $tmpmeta (.registry/*, .channels/*). Plain `rm` as user
    # fails → under `set -e` the trap aborts the topic loop.
    # Self-clearing: a bare RETURN trap leaks past this per-(version,ext) helper
    # and re-fires on a later function's return where the local tmpbin/tmpmeta are
    # out of scope — and `set -u` errors on the unbound expansion BEFORE the
    # `|| true` can swallow it. `trap - RETURN` disarms it right after cleanup.
    trap 'sudo rm -rf "$tmpbin" "$tmpmeta" 2>/dev/null || true; trap - RETURN' RETURN

    info "PHP $ver: pecl install $ext (target: $so_path)"
    local pecl_out="" pecl_rc=0
    pecl_out=$(printf '\n' | sudo env \
        PHP_PEAR_PHP_BIN="$php_bin" \
        PHP_PEAR_BIN_DIR="$tmpbin" \
        PHP_PEAR_METADATA_DIR="$tmpmeta" \
        PHP_PEAR_EXTENSION_DIR="$target_ext_dir" \
        "$pecl_bin" install -f "$ext" 2>&1) || pecl_rc=$?

    if [[ "$pecl_rc" -ne 0 ]] || [[ ! -f "$so_path" ]]; then
        local msg="PHP $ver: pecl install $ext failed (exit=$pecl_rc, .so not at $so_path)"
        [[ -n "$fail_suffix" ]] && msg="$msg — $fail_suffix"
        warn "$msg"
        if [[ -n "$pecl_out" ]]; then
                printf '%s\n' "$pecl_out" | tail -6 | sed 's/^/      /' >&2
        fi
        if [[ "$pecl_rc" -ne 0 ]]; then
            _pecl_install_set_status "failed-build" 0 "exit=$pecl_rc" "$so_path"
        else
            _pecl_install_set_status "failed-missing-so" 0 "$so_path" "$so_path"
        fi
        return 0
    fi

    local ini_dir="${php_etc_root}/${ver}/mods-available"
    local ini_file="${ini_dir}/${ext}.ini"
    if [[ ! -f "$ini_file" ]]; then
        sudo mkdir -p "$ini_dir"
        echo "extension=${ext}.so" | sudo tee "$ini_file" >/dev/null
    fi
    local phpenmod_rc=0
    sudo phpenmod -v "$ver" "$ext" >/dev/null 2>&1 || phpenmod_rc=$?
    if [[ "$phpenmod_rc" -ne 0 ]]; then
        warn "PHP $ver: phpenmod failed for $ext (exit=$phpenmod_rc)"
        _pecl_install_set_status "failed-phpenmod" 0 "exit=$phpenmod_rc" "$so_path"
        return 0
    fi

    local modules="" module_rc=0
    modules="$("$php_bin" -m 2>/dev/null)" || module_rc=$?
    if [[ "$module_rc" -ne 0 ]] \
        || ! grep -qiE "^${ext}\$|^${ext//pdo_/PDO_}\$" <<< "$modules"; then
        warn "PHP $ver: $ext is not loaded after phpenmod (php -m exit=$module_rc)"
        _pecl_install_set_status "failed-not-loaded" 0 "php-m-exit=$module_rc" "$so_path"
        return 0
    fi

    ok "PHP $ver: $ext enabled"
    _pecl_install_set_status "installed" 1 "" "$so_path"
}
