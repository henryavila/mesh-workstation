#!/usr/bin/env bash
# Custom: MySQL 9 on macOS.
#
# Install strategy, decided by the brew prefix:
#
#   1. Pre-existing Oracle install at /usr/local/mysql (user put it there via
#      the .dmg/.pkg, or we did via path 3) → respect it: register PATH +
#      ensure the run layer. Never re-download.
#
#   2. Canonical brew prefix (/opt/homebrew, /usr/local) → `brew install mysql`.
#      The unversioned `mysql` formula is the 9.x GA and its bottle's cellar
#      matches, so the prebuilt bottle pours. Run via `brew services`.
#
#   3. Non-canonical brew prefix (e.g. /Volumes/External/homebrew) → Oracle
#      binary tarball to /usr/local/mysql, GPG-verified. Rationale: the mysql
#      bottle is pinned to /opt/homebrew/Cellar (non-relocatable), so on any
#      other prefix brew force-builds from source — which currently FAILS
#      (protobuf 35 / abseil link in the mysqlxtest test binary, an upstream
#      Homebrew formula bug). Oracle's tarball is a prebuilt binary, so it
#      sidesteps the broken build entirely. It lands on rootfs (/usr/local),
#      so the TCC launch-wrapper workaround isn't strictly required, but we
#      still drive the run layer through lib/launch-wrapper.sh for a uniform,
#      idempotent LaunchAgent + teardown (same as redis/postgres).
#
# Run layer: a user-scope LaunchAgent running `mysqld_safe --datadir=<dir>`.
# verify()/check() require the server to actually be running, not just present.

# ---- Pinned coordinates (bump these to move the Oracle-tarball version) ----
MYSQL_VER="9.7.0"                       # 9.7 LTS — parity with WSL (mysql-9.7-lts)
MYSQL_SERIES="9.7"
MYSQL_OS_TAG="macos15"                  # Oracle's current macOS build target
# MySQL Release Engineering <mysql-build@oss.oracle.com> — the signing key is
# the real trust anchor (stable across the 2023/2025 key-file renewals). The
# key FILE url may need bumping over time; the FINGERPRINT must always match.
MYSQL_GPG_FPR="BCA43417C3B485DD128EC6D4B7B3B788A8D3785C"
MYSQL_GPG_KEY_URL="https://repo.mysql.com/RPM-GPG-KEY-mysql-2025"
# Optional second integrity gate: pin the tarball SHA256 (per arch) and it is
# checked after the GPG verify. Empty = skip (GPG signature is authoritative).
MYSQL_SHA256_arm64="81d0c55227093e2ebdffb424452c458b0b4a39ddff76c5bcc25e93085ab7a912"
MYSQL_SHA256_x86_64=""

ORACLE_PREFIX="${MYSQL_ORACLE_PREFIX:-/usr/local/mysql}"
ORACLE_MYSQL_BIN="${ORACLE_PREFIX}/bin/mysql"
ORACLE_DATADIR="${ORACLE_PREFIX}/data"
MYSQL_SVC="mysql"
MYSQL_LABEL="com.${USER}.mysql"

# ---------------------------------------------------------------- predicates
_prefix_is_canonical() {
    case "${BREW_PREFIX:-}" in
        /opt/homebrew|/usr/local) return 0 ;;
        *) return 1 ;;
    esac
}

# A running server: a live mysqld(_safe), our managed unit, or brew services.
_server_running() {
    pgrep -u "$USER" -f 'mysqld' >/dev/null 2>&1 && return 0
    # Capture then bash-match — NOT `launchctl print | grep -q`: under the engine's
    # pipefail, grep -q closing the pipe early SIGPIPE-kills launchctl (141) → a
    # false "not running". See feedback_engine_pipefail_grep_q_broken_pipe (lint L21).
    local _lc; _lc="$(launchctl print "gui/$(id -u)/${MYSQL_LABEL}" 2>/dev/null)"
    [[ "$_lc" =~ state[[:space:]]*=[[:space:]]*running ]] && return 0
    "${BREW_BIN:-brew}" services list 2>/dev/null \
        | awk -v s="$MYSQL_SVC" '$1==s{print $2}' | grep -qx 'started'
}

# Poll _server_running for ~3s. A freshly-started daemon (first-boot datadir
# init, slow socket bind) can lag behind `brew services start` returning — so a
# single check right after start races and misreads it as not-running.
_wait_server_running() {
    for _ in 1 2 3 4 5 6; do
        _server_running && return 0
        sleep 0.5
    done
    return 1
}

_source_launch_wrapper() {
    local root
    if [[ -n "${MESH_WORKSTATION_DIR:-}" && -d "${MESH_WORKSTATION_DIR}/scripts/lib" ]]; then
        root="${MESH_WORKSTATION_DIR}"
    else
        root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
    fi
    # shellcheck disable=SC1091
    . "${root}/scripts/lib/launch-wrapper.sh"
}

# --------------------------------------------------------------- run layer
# Install/refresh the user LaunchAgent that runs the given mysqld_safe with the
# given datadir. Idempotent — launch_wrapper regenerates + re-bootstraps.
_run_layer_install() {
    local exec_bin="$1" basedir="$2" datadir="$3"
    _source_launch_wrapper
    launch_wrapper_install_extbrew \
        --svc "$MYSQL_SVC" \
        --label "$MYSQL_LABEL" \
        --brew-bin "$exec_bin" \
        --workdir "$basedir" \
        -- --datadir="$datadir"
}

# ---------------------------------------------------- Oracle-tarball helpers
_oracle_file() {
    printf 'mysql-%s-%s-%s.tar.gz' "$MYSQL_VER" "$MYSQL_OS_TAG" "$(uname -m)"
}

# Register /usr/local/mysql/bin on the system PATH (needs sudo).
_register_oracle_path() {
    local paths_file="/etc/paths.d/61-oracle-mysql"
    if ! sudo grep -q "^${ORACLE_PREFIX}/bin$" "$paths_file" 2>/dev/null; then
        echo "${ORACLE_PREFIX}/bin" | sudo tee "$paths_file" >/dev/null
    fi
}

# Download tarball + .asc into outdir and verify. No sudo, no extraction — so
# this is independently testable. Echoes the verified tarball path on success.
_fetch_verify_oracle() {
    local outdir="$1"
    local file url keyfile arch sha_pin got
    file="$(_oracle_file)"
    # CDN serves both the tarball and the detached .asc at a version-pinned
    # path. (The dev.mysql.com/get/ redirector only fronts the tarball — its
    # .asc 404s — so we hit the CDN directly: deterministic, no redirect hop.)
    url="https://cdn.mysql.com/Downloads/MySQL-${MYSQL_SERIES}/${file}"

    echo "mysql(mac): downloading ${file}" >&2
    curl -fL --retry 3 --connect-timeout 30 -o "${outdir}/${file}" "$url" \
        || { echo "mysql: download failed: $url" >&2; return 1; }
    curl -fL --retry 3 --connect-timeout 30 -o "${outdir}/${file}.asc" "${url}.asc" \
        || { echo "mysql: signature download failed: ${url}.asc" >&2; return 1; }

    # GPG: import the published key into a throwaway keyring, assert its
    # fingerprint matches the pinned one, then verify the detached signature.
    keyfile="${outdir}/mysql-release.key"
    curl -fsSL "$MYSQL_GPG_KEY_URL" -o "$keyfile" \
        || { echo "mysql: GPG key download failed" >&2; return 1; }
    export GNUPGHOME="${outdir}/gnupg"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
    gpg --batch --import "$keyfile" 2>/dev/null \
        || { echo "mysql: GPG key import failed" >&2; return 1; }
    if ! gpg --batch --list-keys --with-colons 2>/dev/null | grep -q "$MYSQL_GPG_FPR"; then
        echo "mysql: imported key fingerprint != pinned ${MYSQL_GPG_FPR} — refusing" >&2
        return 1
    fi
    if ! gpg --batch --verify "${outdir}/${file}.asc" "${outdir}/${file}" 2>/dev/null; then
        echo "mysql: GPG signature verification FAILED for ${file}" >&2
        return 1
    fi
    echo "mysql(mac): GPG signature OK (MySQL Release Engineering)" >&2

    # Optional pinned-SHA256 gate (per arch).
    arch="$(uname -m)"
    case "$arch" in
        arm64)  sha_pin="$MYSQL_SHA256_arm64" ;;
        x86_64) sha_pin="$MYSQL_SHA256_x86_64" ;;
        *)      sha_pin="" ;;
    esac
    if [[ -n "$sha_pin" ]]; then
        got="$(shasum -a 256 "${outdir}/${file}" | cut -d' ' -f1)"
        [[ "$got" == "$sha_pin" ]] \
            || { echo "mysql: SHA256 mismatch (${got} != ${sha_pin})" >&2; return 1; }
        echo "mysql(mac): SHA256 OK" >&2
    fi

    printf '%s/%s\n' "$outdir" "$file"
}

# Initialize the datadir once, owned by $USER (the LaunchAgent runs as $USER).
_oracle_datadir_init() {
    [[ -f "${ORACLE_DATADIR}/auto.cnf" ]] && return 0   # already initialized
    sudo mkdir -p "$ORACLE_DATADIR" || return 1
    sudo chown "$USER" "$ORACLE_DATADIR" || return 1
    echo "mysql(mac): initializing datadir ${ORACLE_DATADIR}" >&2
    "${ORACLE_PREFIX}/bin/mysqld" --initialize-insecure \
        --basedir="$ORACLE_PREFIX" --datadir="$ORACLE_DATADIR" \
        || { echo "mysql: datadir initialize failed" >&2; return 1; }
}

# Full path-3 install: fetch+verify → extract to /usr/local → symlink → datadir.
_install_oracle_tarball() {
    local tmp tarball dir arch
    tmp="$(mktemp -d)" || return 1
    # Self-clearing: a bare RETURN trap leaks past this helper and re-fires on the
    # caller's return where `tmp` is out of scope → `set -u` abort. Disarm after.
    trap 'rm -rf "$tmp"; trap - RETURN' RETURN

    tarball="$(_fetch_verify_oracle "$tmp")" || return 1

    arch="$(uname -m)"
    dir="mysql-${MYSQL_VER}-${MYSQL_OS_TAG}-${arch}"
    echo "mysql(mac): extracting to /usr/local/${dir} (sudo)" >&2
    sudo tar -xzf "$tarball" -C /usr/local \
        || { echo "mysql: extraction failed" >&2; return 1; }
    sudo ln -sfn "/usr/local/${dir}" "$ORACLE_PREFIX" || return 1

    _oracle_datadir_init || return 1
}

# ---------------------------------------------------------------- contract
check() {
    if [[ -x "$ORACLE_MYSQL_BIN" ]]; then
        # Installed at /usr/local/mysql. If a user LaunchDaemon/.pkg manages
        # it, that's their server — presence is enough. Otherwise require our
        # run layer to be live so install() (re)bootstraps a stopped agent.
        [[ -f /Library/LaunchDaemons/com.oracle.oss.mysql.mysqld.plist ]] && return 0
        _server_running
        return
    fi
    if _prefix_is_canonical; then
        "${BREW_BIN:-brew}" list --formula "$MYSQL_SVC" >/dev/null 2>&1 || return 1
        _server_running
        return
    fi
    return 1   # non-canonical prefix, no Oracle install yet
}

install() {
    # Path 1 — pre-existing Oracle install.
    if [[ -x "$ORACLE_MYSQL_BIN" ]]; then
        _register_oracle_path
        # Respect a .pkg/.dmg system daemon; otherwise drive our run layer.
        if [[ ! -f /Library/LaunchDaemons/com.oracle.oss.mysql.mysqld.plist ]]; then
            _oracle_datadir_init || return 1
            _run_layer_install "${ORACLE_PREFIX}/bin/mysqld_safe" "$ORACLE_PREFIX" "$ORACLE_DATADIR"
        fi
        return 0
    fi

    # Path 2 — canonical brew prefix: the bottle pours.
    if _prefix_is_canonical; then
        "${BREW_BIN:-brew}" list --formula "$MYSQL_SVC" >/dev/null 2>&1 \
            || "${BREW_BIN:-brew}" install "$MYSQL_SVC" || return 1
        # Start (non-fatal: brew returns non-zero when already started), then
        # WAIT for the server to actually come up: check() requires
        # _server_running, and a single check right after start races a daemon
        # still doing first-boot datadir init. The readiness wait is the real
        # gate — a server that never comes up is surfaced here as a clean
        # install-failed rather than letting post-verify abort with rc67.
        "${BREW_BIN:-brew}" services start "$MYSQL_SVC" >/dev/null 2>&1 || true
        _wait_server_running \
            || { echo "mysql: brew service did not come up" >&2; return 1; }
        return 0
    fi

    # Path 3 — non-canonical prefix: Oracle tarball (brew would build & fail).
    _install_oracle_tarball || return 1
    _register_oracle_path
    _run_layer_install "${ORACLE_PREFIX}/bin/mysqld_safe" "$ORACLE_PREFIX" "$ORACLE_DATADIR"
}

verify() {
    check
}

repair() { install; }

rollback() {
    # Stop/teardown the run layer only — never uninstall the formula, remove
    # /usr/local/mysql, or touch the datadir (data-loss risk).
    if _prefix_is_canonical && [[ ! -x "$ORACLE_MYSQL_BIN" ]]; then
        "${BREW_BIN:-brew}" services stop "$MYSQL_SVC" 2>/dev/null || true
    else
        _source_launch_wrapper
        launch_wrapper_teardown "$MYSQL_LABEL" 2>/dev/null || true
    fi
}

uninstall() {
    # Reverse install(), per the path install() would have taken (no state file
    # is recorded, so re-derive it the same way check()/install() do):
    #
    #   Path 2 (canonical brew prefix, no Oracle binary) — install() did
    #     `brew install mysql` + `brew services start`. REVERSE IT FOR REAL:
    #     stop the service, then `brew uninstall mysql` (formula, matching the
    #     install verb). Success is gated on the formula actually being gone, so
    #     the engine's marker drop is honest (the ngrok pattern). brew owns its
    #     own datadir teardown for the formula, so this is data-safe.
    #
    #   Path 1 / Path 3 (Oracle install at /usr/local/mysql) — the only
    #     mesh-managed, data-safe artifacts are the run layer (user LaunchAgent +
    #     wrapper script) and the /etc/paths.d PATH fragment install() wrote.
    #     We deliberately do NOT remove /usr/local/mysql, its symlink target, or
    #     the datadir: Path 1 may be a user's pre-existing .dmg/.pkg install we
    #     only registered, and on Path 3 the datadir lives *inside* the extracted
    #     tree (/usr/local/mysql/data) — rm -rf would be data loss. This mirrors
    #     rollback()'s documented refusal. The binary therefore stays, so success
    #     here is gated on the mesh-managed artifacts being gone, not on the
    #     mysql binary disappearing.
    local rc=0

    # ---- Path 2: canonical brew prefix, formula install (no Oracle binary) ----
    if _prefix_is_canonical && [[ ! -x "$ORACLE_MYSQL_BIN" ]]; then
        local brew_bin="${BREW_BIN:-brew}"
        # If brew is unavailable we can't have removed the formula and can't
        # confirm it's gone — keep the marker (return 1), never a false "removed"
        # (the ngrok dishonest-marker class). Mirrors redis.sh.
        command -v "$brew_bin" >/dev/null 2>&1 || return 1
        if "$brew_bin" list --formula "$MYSQL_SVC" >/dev/null 2>&1; then
            "$brew_bin" services stop "$MYSQL_SVC" >/dev/null 2>&1 || true
            # --ignore-dependencies matches the engine brew handler + sibling
            # redis.sh: a legitimate uninstall must not fail just because an
            # unrelated formula declares mysql as a dependency.
            "$brew_bin" uninstall --ignore-dependencies --formula "$MYSQL_SVC" >/dev/null 2>&1 || rc=$?
        fi
        # Honest gate: success only when the formula is actually gone.
        if "$brew_bin" list --formula "$MYSQL_SVC" >/dev/null 2>&1; then
            echo "mysql(mac): brew formula '${MYSQL_SVC}' still present after uninstall" >&2
            return 1
        fi
        return 0
    fi

    # ---- Path 1 / Path 3: Oracle install at /usr/local/mysql ----
    # Tear down the mesh run layer (user LaunchAgent + wrapper). Skipped by
    # install() when a .pkg/.dmg system daemon manages mysql, so a teardown
    # no-op there is correct (nothing of ours was installed).
    _source_launch_wrapper
    launch_wrapper_teardown "$MYSQL_LABEL" 2>/dev/null || true

    # Remove ONLY the PATH fragment install()/_register_oracle_path added.
    # Never the binary tree or the datadir (data-loss / pre-existing-install).
    local paths_file="/etc/paths.d/61-oracle-mysql"
    if [[ -e "$paths_file" ]]; then
        sudo rm -f "$paths_file" 2>/dev/null || rc=$?
    fi

    # The default uninstall is data-safe. A confirmed engine purge may remove
    # the exact Oracle tree addressed by this owner, never an arbitrary path.
    if [[ "${MESH_PURGE_DATA:-0}" == "1" ]]; then
        [[ ! -f /Library/LaunchDaemons/com.oracle.oss.mysql.mysqld.plist ]] \
            || { echo "mysql(mac): refusing to purge a system-managed Oracle install" >&2; return 1; }
        # A completed purge has neither the symlink nor target. Treat that as
        # success so a second Mesh run verifies the clean state instead of
        # rejecting the absence as an unsafe unknown target.
        if [[ -e "$ORACLE_PREFIX" || -L "$ORACLE_PREFIX" ]]; then
            local link_target=""
            [[ -L "$ORACLE_PREFIX" ]] && link_target="$(readlink "$ORACLE_PREFIX")"
            case "$link_target" in
                "${ORACLE_PREFIX}-"*) ;;
                *) echo "mysql(mac): refusing unsafe purge target: ${link_target:-<not a managed symlink>}" >&2; return 1 ;;
            esac
            # `target` is L05-allowlisted after the managed-symlink guard above.
            local target="$link_target"
            sudo rm -rf "$target" || return 1
            sudo rm -f -- "$ORACLE_PREFIX" || return 1
        fi
    fi

    # Gate on the mesh-managed artifacts being gone (the binary intentionally
    # stays — see header). A non-zero rc from the PATH-file removal is the only
    # thing that can fail the honest marker drop here.
    [[ "$rc" -eq 0 ]] && [[ ! -e "$paths_file" ]] \
        && { [[ "${MESH_PURGE_DATA:-0}" != "1" ]] || [[ ! -e "$ORACLE_PREFIX" ]]; }
}
