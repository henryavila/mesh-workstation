# foundation

Installs the minimum tools every later topic assumes and that the runner itself depends on.

**WSL packages:** `git curl wget ca-certificates gnupg build-essential jq unzip gettext-base`
**macOS packages:** `git curl wget gnupg jq unzip gettext`, plus Homebrew when no `brew` binary exists yet.

**Homebrew prefix (macOS).** `bash setup.sh` asks before the menu, as soon as it sees that no `brew` binary exists, and exports `BREW_CUSTOM_PREFIX` (separate path, or `/opt/homebrew` when the answer is no). This topic reads that variable. Set `BREW_CUSTOM_PREFIX` yourself to skip the question — a non-interactive run with it unset uses `/opt/homebrew`. An existing `brew` binary is kept.

The prefix `scripts/lib/detect-brew.sh` finds with an empty `PATH` is `/Volumes/External/homebrew` (also `/opt/homebrew`, `/usr/local`, and `/Volumes/External*/homebrew`). The full decision table is in the root README, section "Homebrew prefix (macOS)" / "Prefixo do Homebrew (macOS)".

**No templates** — this topic cannot depend on `lib/deploy.sh`, because `deploy.sh` uses `envsubst`, which this topic installs. Any corresponding shell configuration lives in `shell-terminal`.

**Customization:** edit `mac/core.sh` or `wsl/core.sh` to add minimum packages used everywhere.
