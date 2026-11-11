#!/usr/bin/env bash
# Install docs for Windows → WSL stay aligned with the closed-loop product path.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
# shellcheck source=../lib/assert.sh
. "$HERE/../lib/assert.sh"

GUIDE="$WS/docs/INSTALL-WINDOWS-WSL.md"
README="$WS/README.md"
README_PT="$WS/README.pt-BR.md"
PS1="$WS/windows/install-wsl.ps1"

assert_file_exists "$GUIDE" "docs/INSTALL-WINDOWS-WSL.md exists"
assert_file_contains "$GUIDE" 'install-wsl.ps1' "guide documents host script"
assert_file_contains "$GUIDE" 'Ubuntu-24.04' "guide pins Ubuntu-24.04"
assert_file_contains "$GUIDE" 'lean bootstrap' "guide documents lean bootstrap"
assert_file_contains "$GUIDE" 'CaskaydiaCove' "guide documents CaskaydiaCove font ownership"
assert_file_contains "$GUIDE" 'git curl ca-certificates' "guide documents Phase 0 apt"
assert_file_contains "$GUIDE" 'wsl --shutdown' "guide documents systemd activation"
assert_file_contains "$GUIDE" 'MESH_IDENTITY_REPO' "guide documents identity env"

assert_file_contains "$README" 'docs/INSTALL-WINDOWS-WSL.md' "README links the install guide"
assert_file_contains "$README_PT" 'docs/INSTALL-WINDOWS-WSL.md' "README.pt-BR links the install guide"
assert_file_contains "$README" 'lean bootstrap' "README mentions lean bootstrap"
assert_file_contains "$README_PT" 'lean bootstrap' "README.pt-BR mentions lean bootstrap"

# Entrypoint next-steps must not resurrect the renamed repo / entrypoint.
if grep -nE 'dev-bootstrap|bootstrap\.sh' "$PS1" >/dev/null 2>&1; then
    fail "windows/install-wsl.ps1 must not mention dev-bootstrap or bootstrap.sh"
    grep -nE 'dev-bootstrap|bootstrap\.sh' "$PS1" | sed 's/^/      /' >&2
else
    pass "windows/install-wsl.ps1 has no stale bootstrap entrypoints"
fi
assert_file_contains "$PS1" 'INSTALL-WINDOWS-WSL.md' "PS1 next-steps point at the install guide"

summary
