#!/usr/bin/env bash
# 60-web-stack verify — checks every piece of the optional stack
# and reports which opt-in extras landed successfully.
set -euo pipefail

fail_count=0

check() {
    local name="$1"
    if command -v "$name" >/dev/null 2>&1; then
        echo "  ✓ $name"
    else
        echo "  ✗ $name MISSING"
        fail_count=$((fail_count + 1))
    fi
}

# ─── Core services ──────────────────────────────────────────────────
check mysql
check redis-cli
check nginx
check mkcert

# ─── PHP (multi-version aware) ──────────────────────────────────────
# List every php8.X binary we find; the installer accepts none as a hard
# fail via 10-languages' own verify, but reporting here is useful.
php_versions_found=""
case "$(uname -s)" in
    Darwin)
        while IFS= read -r v; do
            php_versions_found+="$v "
        done < <(brew list --formula 2>/dev/null | grep -oE '^php@[0-9]+\.[0-9]+$' | sed 's/^php@//' | sort -V)
        ;;
    Linux)
        for bin in /usr/bin/php[0-9].[0-9]; do
            [[ -x "$bin" ]] || continue
            php_versions_found+="$(basename "$bin" | sed 's/^php//') "
        done
        ;;
esac
php_versions_found="${php_versions_found% }"

if [[ -n "$php_versions_found" ]]; then
    echo "  ✓ PHP versions installed: $php_versions_found"
    if command -v php >/dev/null 2>&1; then
        echo "  ✓ PHP default: $(php -r 'echo PHP_VERSION;' 2>/dev/null)"
    fi
else
    echo "  ✗ no PHP versions installed"
    fail_count=$((fail_count + 1))
fi

# ─── Nginx site configs ─────────────────────────────────────────────
for site in catchall-php.conf catchall-proxy.conf; do
    linked=""
    for dir in /etc/nginx/sites-enabled "${BREW_PREFIX:-/opt/homebrew}/etc/nginx/servers"; do
        if [[ -e "$dir/$site" ]]; then
            linked="$dir/$site"
            break
        fi
    done
    if [[ -n "$linked" ]]; then
        echo "  ✓ site enabled: $linked"
    else
        # Only fail for catchall-php (proxy is considered extra).
        if [[ "$site" == "catchall-php.conf" ]]; then
            echo "  ! $site not enabled yet (run install, then reload nginx)"
        fi
    fi
done

# ─── mkcert wildcard cert ───────────────────────────────────────────
if [[ -f /etc/nginx/certs/wildcard-localhost.pem ]]; then
    echo "  ✓ wildcard cert present"
else
    echo "  ! wildcard cert missing — run: bash setup.sh --bundle web/nginx-php-fpm"
fi

# ─── Opt-in extras (only report if intended/installed) ───────────────
# We don't hard-fail these; absence is the default. Presence is a green.
if command -v mailpit >/dev/null 2>&1; then
    echo "  ✓ mailpit (optional extra)"
fi
if command -v ngrok >/dev/null 2>&1; then
    echo "  ✓ ngrok (optional extra)"
fi
# Capture then grep a here-string — NOT `php -m | grep -q` (php exits non-zero on
# the EPIPE when grep -q closes early under pipefail). See lint L21.
php_mods="$(php -m 2>/dev/null)"
if grep -qiE '^sqlsrv$|^pdo_sqlsrv$' <<<"$php_mods"; then
    echo "  ✓ sqlsrv + pdo_sqlsrv PHP extensions (optional extra)"
fi

# ─── Mac: Valet ─────────────────────────────────────────────────────
if [[ "$(uname -s)" == "Darwin" ]] && [[ -x "$HOME/.composer/vendor/bin/valet" ]]; then
    echo "  ✓ Valet installed"
fi

[[ "$fail_count" -eq 0 ]]
