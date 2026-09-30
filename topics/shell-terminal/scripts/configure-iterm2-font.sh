#!/usr/bin/env bash
# Dynamic profiles avoid racing iTerm2's in-memory preferences.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -d /Applications/iTerm.app && ! -d "$HOME/Applications/iTerm.app" ]]; then
    echo 'iTerm2 not installed — skipping font config'
    exit 0
fi
python3 "$HERE/iterm2-font-profile.py" "$@"
if [[ "${1:-}" != "--check" ]]; then
    . "$HERE/../../../scripts/lib/log.sh"
    followup info 'iTerm2: Mesh manages the default profile automatically. If iTerm2 is open, the update waits until you fully quit it normally (up to 10 seconds); reopen afterward. Existing sessions are preserved.'
fi
