#!/usr/bin/env bash
# diagnose-wsl-interop.sh always prints a Lane-B Windows CA import command
# with an absolute UNC (so `bash topics/web/scripts/...` still works).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

DIAG="$WS/topics/web/scripts/diagnose-wsl-interop.sh"
assert_file_exists "$DIAG" "diagnose-wsl-interop.sh exists"

assert_pattern_present "$DIAG" 'SCRIPT_UNC=.*\$HERE' \
    "UNC is built from \$HERE (absolute), not dirname \$0"
assert_pattern_absent "$DIAG" 'ONLY_TOPICS=60-web-stack' \
    "does not revive dead ONLY_TOPICS=60-web-stack"
assert_pattern_absent "$DIAG" 'dirname "\$0"' \
    "does not use dirname \$0 for the UNC"
assert_pattern_present "$DIAG" 'import-mkcert-from-windows\.ps1' \
    "points at import-mkcert-from-windows.ps1"
assert_pattern_present "$DIAG" 'bash setup\.sh --bundle web/nginx-php-fpm' \
    "healthy-path reapply uses current --bundle API"

# The PowerShell command must print even when interop checks pass.
robust_line="$(grep -n 'ROBUST SOLUTION' "$DIAG" | head -1 | cut -d: -f1)"
fail_if_line="$(grep -n 'if \[\[ -n "\$FIRST_FAIL" \]\]' "$DIAG" | head -1 | cut -d: -f1)"
if [[ -n "$robust_line" && -n "$fail_if_line" ]] && (( robust_line < fail_if_line )); then
    pass "ROBUST SOLUTION is printed before the FIRST_FAIL gate"
else
    fail "ROBUST SOLUTION must print even when interop checks pass (before FIRST_FAIL if)"
fi

summary
