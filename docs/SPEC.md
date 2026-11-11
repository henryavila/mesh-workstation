# mesh-workstation — Specification

**Version:** 1.0 (contract evolved in place; see §4 for live selection / `--no-mesh was removed`)
**Date:** 2026-04-19 (base); membership / Blink contract current as of 2026-08
**Status:** living — §4 Interface + `membership: mesh` / `MESH_NO_MESH was removed` is authoritative

> **Historical v1 runner:** numbered `00-*` topic inventory (§3 layout, §6 “The 12
> topics”), flow steps that gate `INCLUDE_*` and run per-topic `install.$OS.sh`
> with “no abort on partial error” (§4 Flow steps 5–7, §11), and `dev-bootstrap`
> naming elsewhere in this file describe the **pre-engine** bootstrap. The live
> product contract is §4: Blink menu / `selections.list` / `--bundle`, plus the
> `membership: mesh` + `MESH_NO_MESH was removed` matrix. Membership apply is **fail-closed**
> (abort nonzero if a membership bundle reappears under `--no-mesh was removed`); that
> supersedes the old “single-topic failure does not abort” wording for the
> membership guard only.

## 1. Context and purpose

### Problem

There's no reproducible process for setting up development machines (personal or outsourced devs) across Henry's work ecosystem. The earlier project (`wsl-dev-setup`) grew complex (Node + Ink + React + 94 KB of monolithic bash), broke, and only covers WSL.

### Goal

Public `mesh-workstation` repo (historically `dev-bootstrap`) that:

1. **Configures new machines** across 3 environments: Windows (WSL bootstrap), native WSL2/Ubuntu, macOS.
2. **Installs a reproducible stack**: git, Node, PHP 8.4, current Python, Claude Code, modern terminal UX, tmux, optional Laravel stack, optional remote access.
3. **Serves outsourced devs**: nobody needs to understand a heavy framework. Readable bash, clear documentation.
4. **Integrates personal dotfiles** (private repo per dev) via an env var — without mixing personal configs into the public repo.

### Non-goals

- Fleet configuration management — if we scale, consider Ansible/Nix.
- Native Windows support for development (no WSL).
- Non-Ubuntu Linux (Arch, Fedora) in the MVP.
- Multi-version language management via mise (fnm alone is enough for Node in the current stack).

## 2. Architecture of the 3 repos

| Repo | Visibility | Purpose | Owner |
|------|------------|---------|-------|
| `henryavila/mesh-workstation` | public | Reproducible machine setup (software + opinionated configs); includes `template/` for identity scaffolding | Henry |
| `<user>/mesh-identity` | **private** | Personal identity + overrides (created from workstation `template/` or an existing fork) | Each user |

### Usage flow

Authoritative operator guide: [`INSTALL-WINDOWS-WSL.md`](INSTALL-WINDOWS-WSL.md).

```
┌─────────────────────────────────────────────────────┐
│ 0. Windows Admin → irm …/windows/install-wsl.ps1
│    (WSL features, Git + Windows Terminal, Ubuntu-24.04;
│     exit 2 ⇒ reboot + re-run; fonts NOT on host)
│ 1. Ubuntu first launch → create Linux user
│ 2. Phase 0: apt install git curl ca-certificates
│ 3. git clone …/mesh-workstation && bash setup.sh
│    (1st run: lean bootstrap if Node missing;
│     new shell + 2nd run: full Blink menu)
│ 4. personal via TTY prompt or MESH_IDENTITY_REPO=
│ 5. shell-terminal/fonts → CaskaydiaCove + WT theme
│ 6. If systemd enabled: wsl --shutdown from Windows
└─────────────────────────────────────────────────────┘
```

## 3. Topic pattern

### Convention

Each **topic** is a folder under `topics/` with a numeric prefix (execution order):

```
topics/NN-<name>/
├── install.wsl.sh          # WSL/Ubuntu-specific
├── install.mac.sh          # macOS-specific
├── install.sh              # OR OS-agnostic (fallback if no install.$OS.sh)
├── verify.sh               # verifies correct install (used by CI)
├── templates/              # files to deploy (optional)
│   └── <any-file>
├── packages.txt            # apt list (WSL only, optional)
├── Brewfile                # brew list (Mac only, optional)
└── README.md               # purpose, dependencies, customization
```

### Runner resolves the installer like this

```bash
if [ -f "$topic/install.$OS.sh" ]; then
    installer="$topic/install.$OS.sh"
elif [ -f "$topic/install.sh" ]; then
    installer="$topic/install.sh"
else
    # topic with no install (templates only)
    skip
fi
```

### Topic contracts

Every `install.*.sh` MUST:

1. `set -euo pipefail` at the top
2. **Be idempotent**: run twice without changing state (second run = no-op or skip messages)
3. Check prerequisites (`command -v X` before using X) and fail with a clear message if missing
4. Log actions to stdout: `echo "→ installing X"`, `echo "✓ X already installed"`
5. Never modify files outside `$HOME` without explicit `sudo`
6. Never permanently change `cwd` (use subshells when needed)

Every `verify.sh` MUST:

1. Return exit 0 if all OK, exit 1 if something is missing
2. Print one line per checked item: `  ✓ xxx` or `  ✗ xxx MISSING`

## 4. Runner — `setup.sh`

### Interface

```bash
bash setup.sh                          # interactive Blink menu → engine apply
bash setup.sh --list-bundles           # list topic/bundle + default mark
bash setup.sh --no-mesh was removed                # omit membership: mesh from the catalog
bash setup.sh --no-mesh was removed --bundle removed-bundle
SKIP_TOPICS="identity personal" bash setup.sh   # CI hatch only
DRY_RUN=1 bash setup.sh                # print what the engine would do
bash setup.sh --help                   # usage
```

> **Legacy:** `ONLY_TOPICS=…` is **not** a working v2 selection API in `setup.sh`.
> Selection is `~/.config/mesh/selections.list`, the Blink menu, and/or repeated
> `--bundle topic/bundle` flags. `scripts/commands/topic.sh` may still export
> `ONLY_TOPICS` for older wrappers — do not document it as the product path.

### `membership: mesh` and `MESH_NO_MESH was removed`

Manifest bundles may declare `membership: mesh` (schema enum). The five
membership bundles are: `personal/personal`, `identity/identity`,
`syncthing/syncthing`, `remote-access/tailscale`, `remote-access/code-server`.

| Mode | Behavior |
|------|----------|
| Unflagged | Membership bundles stay in the catalog; `personal` and `identity` remain required locks alongside `foundation/base`, `git/config`, `shell-terminal/cli-tools`, `shell-terminal/zsh`. |
| `--no-mesh was removed` / `MESH_NO_MESH was removed=1` | Catalog omits membership bundles (remove, do not grey). Unlock list (`git/config`, `shell-terminal/cli-tools`, `shell-terminal/zsh`) loses required locks and starts unchecked. Headless default without `--bundle` is **only** `foundation/base`. Engine apply **aborts nonzero** if any membership bundle appears in the resolved selection/closure. `atuin-login` is a no-op. |

`mesh menu --no-mesh was removed` exports the same `MESH_NO_MESH was removed=1` before launching the TUI.

### Recognized env vars

| Var | Effect |
|-----|--------|
| `SKIP_TOPICS` | CI hatch: space-separated topic ids dropped from the resolved selection |
| `ONLY_TOPICS` | **Legacy / dead in v2 `setup.sh`** — not a working selection API |
| `MESH_NO_MESH was removed=1` | Same as `--no-mesh was removed` (exported by the flag before menu/apply) |
| `DRY_RUN=1` | don't execute, just list |
| `MESH_IDENTITY_REPO` | URL of the personal dotfiles repo (used by topic `95-dotfiles-personal`) |
| `MESH_IDENTITY_DIR` | clone destination (default: `~/mesh-identity`) |
| `MESH_NPM_GLOBAL=1` | tell the dotfiles installer to configure npm globals under `~/.npm-global` and persist `~/.npm-global/bin` on PATH |
| `GIT_NAME`, `GIT_EMAIL` | identity for `50-git` |
| `CODE_DIR` | dev root — where repos live (default: `~/code`; per-host override example — Henry's Mac: `/Volumes/External/code`). Asked in the menu's dev-root screen; persisted to `~/.config/mesh/config.env` for the shell |
| `INCLUDE_WEBSTACK=1` | enable topic `60-web-stack` (default: skip) |
| `INCLUDE_REMOTE=1` | enable topic `70-remote-access` (default: skip) |
| `INCLUDE_EDITOR=1` | enable topic `90-editor` (default: skip) |
| `INCLUDE_POSTGRES=1` | install PostgreSQL inside `60-web-stack` (default: ON in interactive menu, OFF when `WEBSTACK` is opt-in via env) |
| `POSTGRES_VERSION=17` | PostgreSQL major version pin when `INCLUDE_POSTGRES=1` (default 17) |
| `NO_COLOR=1` | disable colored output (auto when not a TTY) |

### Flow

**Current (v2 engine):** resolve selection from Blink / `selections.list` /
`--bundle`; under `MESH_NO_MESH was removed=1` omit membership + demote unlock list; engine
apply is fail-closed on membership leakage; item failures are summarized per
engine policy.

**Historical v1 topic-runner** (kept for archaeology — do not implement new
work against this):

```
1. OS=$(bash lib/detect-os.sh); export OS
2. if OS=mac: eval "$(bash lib/detect-brew.sh)"; export BREW_BIN BREW_PREFIX
   (if brew isn't installed yet on the first run, that's fine — topic 00-core
    doesn't depend on brew; detection re-runs after 00-core if needed)
3. list topics/*/ in alphabetical order
4. resolve selection from Blink menu, `selections.list`, and/or repeated `--bundle` flags; apply `SKIP_TOPICS` CI hatch if set; under `MESH_NO_MESH was removed=1` omit `membership: mesh` and demote the unlock list
5. for opt-in topics, check the corresponding env var:
     60-web-stack    requires INCLUDE_WEBSTACK=1    (skip with message otherwise)
     70-remote-access    requires INCLUDE_REMOTE=1
     90-editor           requires INCLUDE_EDITOR=1
     95-dotfiles-personal requires MESH_IDENTITY_REPO set
6. for each unfiltered topic:
   a. if DRY_RUN: print "would run: <installer>" and continue
   b. resolve installer: prefer install.$OS.sh, fall back to install.sh
   c. bash $installer 2>&1 | tee -a $LOG   (inherits $OS, $BREW_PREFIX, $CODE_DIR, $GIT_NAME, etc.)
   d. if $topic/templates/ exists: bash lib/deploy.sh $topic/templates
   e. capture exit code; mark failure but keep going (no abort on partial error)
      NOTE: under MESH_NO_MESH was removed, membership leakage still aborts (fail-closed) —
      that guard overrides this “no abort” sentence.
7. print summary (passed/failed/skipped)
8. exit 0 if everything passed, 1 otherwise
```


**Variables exported by the runner** (inherited by all installers and deploy.sh):
`OS`, `BREW_BIN`, `BREW_PREFIX` (on Mac), `USER`, `HOME`, `MESH_IDENTITY_REPO`, `MESH_IDENTITY_DIR`, `MESH_NPM_GLOBAL`, `CODE_DIR`, `GIT_NAME`, `GIT_EMAIL`, `INCLUDE_WEBSTACK`, `INCLUDE_REMOTE`, `INCLUDE_EDITOR`, `INCLUDE_POSTGRES`, `POSTGRES_VERSION`, `NGINX_CONF_DIR` (derived by topic 60 before deploy), `NO_COLOR`.

### Log

`/tmp/dev-bootstrap-<os>-<timestamp>.log` with stdout+stderr from every topic.

## 5. `lib/` — shared utilities

### `lib/detect-os.sh`

Outputs a single string to stdout: `wsl`, `mac`, `linux`, `unknown`.

```bash
case "$(uname -s)" in
    Darwin) echo "mac" ;;
    Linux)
        if grep -qi microsoft /proc/version 2>/dev/null; then
            echo "wsl"
        else
            echo "linux"
        fi
        ;;
    *) echo "unknown" ;;
esac
```

### `lib/detect-brew.sh`

Detects the Homebrew prefix in **any known location** (avoids failures when brew is on an external drive or in a custom path). Used mostly by macOS topics but harmless to run on WSL/Linux (silent exit 1 if brew is missing).

**Contract:** prints `KEY=VALUE` lines to stdout, consumable by `eval`. Exit 0 if brew found, 1 otherwise.

**Caller usage:**
```bash
if out=$(bash lib/detect-brew.sh); then
    eval "$out"    # populates BREW_BIN and BREW_PREFIX in the current shell
fi
```

**Implementation:**
```bash
# search order: PATH → ARM default → Intel default → custom → linuxbrew
for cand in "$(command -v brew 2>/dev/null)" \
            "/opt/homebrew/bin/brew" \
            "/usr/local/bin/brew" \
            "/Volumes/External/homebrew/bin/brew" \
            "/home/linuxbrew/.linuxbrew/bin/brew"; do
    if [ -n "$cand" ] && [ -x "$cand" ]; then
        echo "BREW_BIN=$cand"
        echo "BREW_PREFIX=$("$cand" --prefix)"
        exit 0
    fi
done
exit 1
```

### `lib/deploy.sh`

Takes a templates directory, applies each file to a destination derived from its name. Idempotent with timestamped backup, CRLF stripping, keep-5-backups. Supports variable substitution via `envsubst` when the file has a `.template` suffix. Detects destinations outside `$HOME` and switches to `sudo` automatically.

```bash
# Usage: bash lib/deploy.sh <templates-dir>
# The directory may contain an optional DEPLOY file with non-convention mappings.
```

**Automatic mapping convention** (no DEPLOY file needed if the name matches). **Any file in the table can have a `.template` suffix**; the suffix is stripped in the destination after envsubst.

| Template name (with or without `.template`) | Destination |
|-----------------------------------------------|-------------|
| `bashrc` | `~/.bashrc` |
| `zshrc` | `~/.zshrc` |
| `inputrc` | `~/.inputrc` |
| `tmux.conf` | `~/.tmux.conf` |
| `starship.toml` | `~/.config/starship.toml` |
| `bashrc.d-NN-<name>.sh` | `~/.bashrc.d/NN-<name>.sh` |
| `zshrc.d-NN-<name>.sh` | `~/.zshrc.d/NN-<name>.sh` |
| `bin/<name>` | `~/.local/bin/<name>` (executable, chmod +x) |

Examples: `starship.toml.template` → `~/.config/starship.toml` (envsubst'd). `bin/link-project.template` → `~/.local/bin/link-project`.

### `DEPLOY` file format (optional)

For mappings outside the convention (e.g. destinations in `/etc/`, paths with substitution), the topic provides `templates/DEPLOY`:

```
# Format: <src-relative-to-templates-dir>=<absolute-or-tildeified-destination>
# Blank lines and lines starting with # are ignored.
# ${VAR} in the destination is expanded by deploy.sh.
# If src has a .template suffix, envsubst is applied to the CONTENT before copying.

sshd-snippet.template=/etc/ssh/sshd_config.d/99-${USER}.conf
nginx-catchall.conf=${NGINX_CONF_DIR}/catchall.conf
```

`lib/deploy.sh` picks up the `DEPLOY` file if present; otherwise it falls back to the automatic convention above.

### Variable substitution (`.template` suffix)

Files with a `.template` suffix go through `envsubst` during deploy. Variables from the runner's environment (`$USER`, `$HOME`, `$BREW_PREFIX`, `$CODE_DIR`, `$NGINX_CONF_DIR`, etc.) are expanded. The `.template` suffix is **stripped at the destination** (e.g. `bin/link-project.template` → `~/.local/bin/link-project`, not `~/.local/bin/link-project.template`).

### Elevated privileges for destinations outside `$HOME`

When the resolved destination starts with `/etc/`, `/usr/local/etc/`, or any path outside `$HOME`, `lib/deploy.sh`:

1. Asks for confirmation **once** at the start of the deploy (avoids repeated prompts).
2. Refreshes the sudo cache (`sudo -v`).
3. Uses `sudo cp`, `sudo mv`, `sudo chmod` to write the destination.
4. Fails with a clear message if sudo is denied.

Topics that write under `/etc/` (e.g. `70-remote-access` sshd snippet, `60-web-stack` nginx config) depend on this logic. Never call deploy.sh in a non-interactive context without having validated `sudo -n` beforehand.

### `lib/log.sh`

Colored output helpers: `info`, `ok`, `warn`, `fail`, `banner`. Loaded via `source` by scripts.

## 6. The 12 topics

> **Historical inventory.** Numbered `00-core` … `95-dotfiles-personal` names
> below are the v1 topic-runner layout. Live catalog dirs are unnumbered
> (`topics/foundation`, `topics/shell-terminal`, `topics/web`, …) with bundles
> in each `manifest.yaml`. Prefer `bash setup.sh --list-bundles` and §4 for
> selection / membership rules.

### `00-core`


**Purpose:** minimum tools every dev needs, plus the runner's own dependencies (envsubst).

**Contents:**
- WSL: `git curl wget ca-certificates gnupg build-essential jq unzip gettext-base` (the last one provides `envsubst`, used by `lib/deploy.sh`)
- Mac: `git curl wget gnupg jq unzip gettext` (`build-essential` ≈ xcode-select, already present; brew's `gettext` provides a compatible `envsubst`)

**Templates:** none.

**Circular-dependency note:** `00-core` is the one topic that **cannot** depend on `lib/deploy.sh` (which uses envsubst), since it's the topic that installs envsubst. That's why `00-core` has no templates.

### `10-languages`

**Purpose:** Node (via fnm), PHP 8.4 (+ common extensions), Composer, current Python.

**Contents:**
- WSL: fnm (installer), Node LTS, `add-apt-repository ppa:ondrej/php`, php8.4 + ext, composer (official installer with checksum), python3 (apt)
- Mac: fnm (brew), Node LTS, `brew install php@8.4 composer python@3.13`

**Templates:**
- `bashrc.d-10-languages.sh` — fnm init (`eval "$(fnm env --use-on-cd)"`), PATH for `$HOME/.composer/vendor/bin`
- `zshrc.d-10-languages.sh` — zsh equivalent

**Env vars:** none.

### `20-terminal-ux`

**Purpose:** modern terminal, ready out-of-the-box.

**Contents:**
- WSL: `fzf bat eza zoxide ripgrep fd-find` via apt; `starship lazygit git-delta` via installer (not in the default apt); Nerd Font (CaskaydiaCove) via `shell-terminal/fonts` → `install-nerd-font.ps1` (Windows user-level, from WSL)
- Mac: all via brew + `brew tap homebrew/cask-fonts` + `brew install --cask font-caskaydia-cove-nerd-font`

**Templates:**
- `starship.toml` with **Catppuccin Mocha** baked in (full palette, Nerd Font glyphs)
- `bashrc.d-20-terminal-ux.sh` with: `eval "$(starship init bash)"`, fzf keybindings (`Ctrl+R`, `Ctrl+T`), `eval "$(zoxide init bash)"`, aliases `ls='eza'`, `cat='bat'` (conditional)
- `zshrc.d-20-terminal-ux.sh` — zsh equivalent

### `30-shell`

**Purpose:** modular bashrc/zshrc with `~/.bashrc.d/` and `~/.zshrc.d/` loaders.

**Contents:**
- WSL: default shell = bash, but also configures zsh if preferred
- Mac: default shell = zsh (macOS default)

**Templates:**
- `bashrc` — minimal: shell options, history, base PATH, loads `~/.bashrc.d/*.sh`, sources `~/.bashrc.local` at the end
- `zshrc` — zsh equivalent, loads `~/.zshrc.d/*.sh` and `~/.zshrc.local`
- `inputrc` — readline keybindings (Ctrl+←/→, history search)

### `40-tmux`

**Purpose:** tmux + config with Ctrl+A prefix, mouse, intuitive splits.

**Contents:**
- WSL: `apt install tmux`
- Mac: `brew install tmux`

**Templates:**
- `tmux.conf` with: prefix C-a, mouse on, `|` and `-` splits, clean status bar, reload config

### `45-docker` (opt-in)

**Purpose:** Docker Engine for containerised dev workflows — dev containers, local smoke tests, experiment isolation.

**Activation:** `INCLUDE_DOCKER=1 bash setup.sh` (or tick "docker" in the interactive menu).

**Contents:**
- WSL: `apt install docker.io docker-compose-v2`, add `$USER` to the `docker` group, enable `docker.service` via systemd (when available — falls through on non-systemd WSL).
- Mac: `brew install colima docker docker-compose`. Colima chosen over Docker Desktop — no licence, no GUI, no forced login, headless VM. Installed but **not started** automatically (VM idles at ~2 GB RAM); user runs `colima start` on demand.

**Templates:** none.

**Env vars:** none.

**Not required by any other topic** — `80-claude-code` doesn't use Docker, `60-web-stack` runs MySQL/nginx natively. The smoke test in `ci/smoke-test.sh` needs Docker, but that's developer-side CI tooling, not a runtime dependency.

### `50-git`

**Purpose:** gitconfig with delta as pager, `merge.conflictstyle=zdiff3`, `init.defaultBranch=main`, common aliases.

**Contents:**
- WSL/Mac: configures via `git config --global` reading `gitconfig.keys` (one key=value per line)
- Preserves existing `[user]` and `[credential]` (never overwrites email/name)

**Templates:**
- `gitconfig.keys` — 20–30 lines with `core.pager=delta`, `delta.side-by-side=false`, aliases (`alias.co=checkout`, `alias.br=branch`, etc.)

### `60-web-stack` (opt-in)

**Purpose:** local Web + DB stack for Laravel-style dev — MySQL, Redis, Nginx with a `*.localhost` catch-all, PHP-FPM, mkcert. PostgreSQL as opt-in sub-flag.

**Activation:** `INCLUDE_WEBSTACK=1 bash setup.sh`

**Contents:**
- WSL: `apt install mysql-server redis-server nginx php8.4-fpm`, `curl | bash` mkcert
- Mac: `brew install mysql redis nginx mkcert` + `brew services start`

**Sub-opt-ins (gated on `INCLUDE_WEBSTACK=1`):**
- `INCLUDE_MAILPIT=1` — local SMTP catcher (`scripts/install-mailpit.sh`)
- `INCLUDE_NGROK=1` — public tunnel + `share-project` wrapper (`scripts/install-ngrok.sh`)
- `INCLUDE_MSSQL=1` — Microsoft SQL Server ODBC + sqlsrv/pdo_sqlsrv PECL (`scripts/install-mssql-driver.sh`, Linux only; Mac is documented-but-manual)
- `INCLUDE_POSTGRES=1` — PostgreSQL server + role/db for `$USER` (`scripts/install-postgres.sh`, Mac + Linux). Major version controlled by `POSTGRES_VERSION` (default `17`). Mac uses `lib/launch-wrapper.sh` when the brew prefix is non-canonical (TCC sandbox workaround per D43); Linux uses the PGDG APT repo (`apt.postgresql.org`) with `signed-by` keyring under `/etc/apt/keyrings/`. Pristine-only role/db creation (`createuser -s $USER` + `createdb $USER` only when both are absent, so existing custom setups aren't disturbed).

**Templates:**
- `nginx-catchall.conf.template` — deployed via the `DEPLOY` file:
  - WSL: `$NGINX_CONF_DIR=/etc/nginx/sites-enabled`
  - Mac: `$NGINX_CONF_DIR=$BREW_PREFIX/etc/nginx/servers` (uses `lib/detect-brew.sh`)
- `bin/link-project.template` — script that wires `$CODE_DIR/<name>/public` → `<name>.localhost` (uses env var `CODE_DIR`, default `~/code`)

**Env vars used:** `CODE_DIR`, `BREW_PREFIX` (via detect-brew on Mac), `POSTGRES_VERSION` (when `INCLUDE_POSTGRES=1`).

**Post-install:** print `start-services.sh` as a reference.

### `70-remote-access` (opt-in)

**Purpose:** remote access via SSH + Tailscale + mosh + tmux, sudoers NOPASSWD.

**Activation:** `INCLUDE_REMOTE=1 bash setup.sh`

**Contents:**
- WSL: enable sshd, install Tailscale, mosh, configure `.wslconfig` with systemd, sudoers NOPASSWD
- Mac: enable Remote Login (sshd), install Tailscale, mosh

**Templates:**
- `sshd-snippet.template` deployed via the `DEPLOY` file as `/etc/ssh/sshd_config.d/99-${USER}.conf` (basic hardening — `envsubst` expands `$USER`)

### `80-claude-code`

**Purpose:** install Claude Code CLI.

**Contents:**
- Cross-OS: `curl -fsSL https://claude.ai/install.sh | bash` (both WSL and Mac)
- Validate `claude --version` after installing

**Templates:** none.

### `90-editor` (opt-in)

**Purpose:** `typora-wait` wrapper to use Typora as `$EDITOR` (Henry's preference, documented in memory).

**Activation:** `INCLUDE_EDITOR=1 bash setup.sh`

**Contents:** no install (Typora is a GUI, installed separately by the user).

**Templates:**
- `bin/typora-wait` — wrapper that waits for the window to close before returning (used as `EDITOR=typora-wait git commit`)

### `95-dotfiles-personal`

**Purpose:** apply the dev's personal dotfiles (opt-in via env var).

**Activation:** `MESH_IDENTITY_REPO=git@github.com:user/dotfiles.git bash setup.sh`

Optional npm-global activation: add `MESH_NPM_GLOBAL=1` or tick `npm-global` in the interactive menu. This delegates prefix/PATH persistence to the dotfiles installer.

**Contents:**
1. If `MESH_IDENTITY_REPO` isn't set → skip with message.
2. Otherwise:
   - Clone into `~/mesh-identity` (or `$MESH_IDENTITY_DIR` if set)
   - If `~/mesh-identity/install.sh` exists: `MESH_NPM_GLOBAL="${MESH_NPM_GLOBAL:-0}" bash ~/mesh-identity/install.sh`

**Templates:** none.

## 7. Shell rc fragments (`.bashrc.d/`, `.zshrc.d/`)

### Pattern

```bash
# ~/.bashrc (created by topic 30-shell)
# ... basic shell options ...
for f in ~/.bashrc.d/*.sh; do [ -r "$f" ] && source "$f"; done
[ -f ~/.bashrc.local ] && source ~/.bashrc.local
```

### Naming

Fragments under `~/.bashrc.d/` follow the same numeric prefix as the topics:
- `10-languages.sh` (fnm env, composer PATH)
- `20-terminal-ux.sh` (starship init, fzf keybindings, zoxide init, aliases)
- `60-web-stack.sh` (laravel aliases, if opt-in)

Load order = alphabetical (enforces dependencies).

### Order vs loader note

Topic `30-shell` creates the `~/.bashrc` and `~/.zshrc` loaders that iterate `~/.bashrc.d/*.sh`. Earlier topics (`10-languages`, `20-terminal-ux`) already drop fragments under `~/.bashrc.d/` **before** `30-shell` runs.

This is intentional and bug-free:
- During bootstrap: installers don't need the fragments to function (each `install.sh` runs without needing the shell rc).
- After bootstrap: `30-shell` creates the loader; the user opens a new shell → everything loads in the right order.

The only case where nothing would load is if the user runs `source ~/.bashrc` mid-bootstrap — the recommendation is to wait until the end and open a new shell.

## 8. `dotfiles-template` — specification

### Structure

```
dotfiles-template/
├── README.md                    # "Use this template" workflow
├── install.sh                   # self-contained: diff + backup + symlink
├── .gitignore                   # secrets, system files, backups
├── ssh/
│   └── config.example
├── git/
│   └── gitconfig.local.example
├── shell/
│   ├── bashrc.local.example
│   └── zshrc.local.example
└── docs/README.md
```

### `.example` convention

Files with the `.example` suffix are commented placeholders. `install.sh` **skips** `.example` files and only processes files without the suffix. The user renames them (`cp config.example config`) and customizes.

### Template `install.sh`

Self-contained (does NOT depend on `dev-bootstrap`'s `lib/deploy.sh`). Duplicates ~40 lines of deploy logic. Reason: the template should work standalone.

Behavior:
- For each non-`.example` file under `ssh/`, `git/`, `shell/`:
  - Compute destination (`ssh/config` → `~/.ssh/config`)
  - If it differs: backup + symlink
  - If it matches: skip

### GitHub template marker

After the initial push: `gh repo edit henryavila/dotfiles-template --template` (or via UI → Settings → check "Template repository").

## 9. CI/CD

### Workflows

**`.github/workflows/lint.yml` — Tier 1 (every push)**

```yaml
on: [push, pull_request]
jobs:
  shellcheck:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ludeeus/action-shellcheck@master
        with:
          ignore_paths: docs windows
      - name: bash syntax
        run: find topics lib -name "*.sh" -exec bash -n {} \;
```

**`.github/workflows/integration.yml` — Tier 2 (PRs to main)**

```yaml
on:
  pull_request:
    branches: [main]
jobs:
  test-wsl:
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-22.04, ubuntu-24.04]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - name: bootstrap (safe topics)
        run: |
          bash setup.sh --non-interactive \
            --bundle foundation/base \
            --bundle removed-bundle \
            --bundle shell-terminal/cli-tools \
            --bundle shell-terminal/zsh \
            --bundle git/config
      - name: idempotency check (2nd run)
        run: |
          bash setup.sh --non-interactive \
            --bundle foundation/base \
            --bundle removed-bundle \
            --bundle shell-terminal/cli-tools \
            --bundle shell-terminal/zsh \
            --bundle git/config
      - name: verify
        run: for t in topics/{00-core,10-languages,20-terminal-ux,30-shell,40-tmux,50-git,80-claude-code}; do
               [ -x "$t/verify.sh" ] && bash "$t/verify.sh"; done

  test-mac:
    runs-on: macos-latest    # macOS 26 when available
    steps:
      - uses: actions/checkout@v4
      - name: bootstrap
        run: |
          bash setup.sh --non-interactive \
            --bundle foundation/base \
            --bundle removed-bundle \
            --bundle shell-terminal/cli-tools \
            --bundle shell-terminal/zsh \
            --bundle git/config
      - name: idempotency check
        run: |
          bash setup.sh --non-interactive \
            --bundle foundation/base \
            --bundle removed-bundle \
            --bundle shell-terminal/cli-tools \
            --bundle shell-terminal/zsh \
            --bundle git/config
      - name: verify
        run: for t in topics/{00-core,10-languages,20-terminal-ux,30-shell,40-tmux,50-git,80-claude-code}; do
               [ -x "$t/verify.sh" ] && bash "$t/verify.sh"; done
```

**Tier 3 (daily E2E):** disabled initially. Turn on once stable — schedule `cron: '0 6 * * *'` with coverage for `60-web-stack` and `70-remote-access`.

### Estimated costs

- Tier 1: ~30 s per push. Free on public repos.
- Tier 2: ~15–25 min wall-clock per PR (3 parallel jobs). Free on public repos.
- Tier 3: ~30–45 min per run. Enable after Tier 2 stabilizes.

## 10. Code conventions

### Bash

- Shebang: `#!/usr/bin/env bash`
- Prologue: `set -euo pipefail`
- Double-quote every expansion: `"$var"`, never bare `$var`
- Arrays for lists: `local pkgs=(a b c); "${pkgs[@]}"`
- Use `[[ ]]` for conditionals (not `[ ]`)
- Functions: snake_case, locals: `local x="..."`
- Indent: 4 spaces (not tabs)

### Output

- `→` for in-progress action
- `✓` for success
- `!` for warning
- `✗` for error
- Colors via ANSI in `lib/log.sh`; disable when `NO_COLOR=1` or not a TTY

### Idempotency

Before installing anything:

```bash
if command -v X >/dev/null 2>&1; then
    echo "✓ X already installed"
    return 0
fi
```

Before modifying a file:

```bash
if grep -qF 'MARKER_LINE' "$file"; then
    echo "✓ $file already configured"
    return 0
fi
```

## 11. Error handling

- **Membership guard (current):** under `--no-mesh was removed` / `MESH_NO_MESH was removed=1`, if any
  `membership: mesh` bundle appears in the resolved selection/closure, apply
  **aborts nonzero** (fail-closed). This overrides the historical “keep going”
  rule for that guard only — see §4.
- **Historical v1 topic-runner:** a single-topic install failure did not abort
  `setup.sh` — it continued with the rest; the final summary listed failures;
  final exit code was 0 if everything OK, 1 if any failed.
- `run_cmd()` helper for sudo with retry: if `sudo` fails due to timeout, retry once after refreshing the cache (`sudo -v`)

## 12. Acceptance criteria

MVP accepted when:

- [ ] `dev-bootstrap` contains 12 topics + `setup.sh` + `lib/` + README
- [ ] `dotfiles-template` contains a working skeleton + self-contained `install.sh` + marked as template on GitHub
- [ ] `henryavila/dotfiles` private repo created from the template, containing the current `ssh/config` migrated
- [ ] Running `bash setup.sh` on the current (already configured) WSL returns "all topics skipped" or an equivalent (idempotency)
- [ ] CI Tier 1 (lint) passes on both repos
- [ ] CI Tier 2 (integration) passes on ubuntu-22.04, ubuntu-24.04, macos-latest
- [ ] README explains the full flow (Windows → WSL → bootstrap → dotfiles-template → dotfiles)
- [ ] Legacy `wsl-dev-setup` archived on GitHub with a deprecation notice

## 13. Out of scope (this version)

- Non-Ubuntu Linux support (Arch, Fedora, Debian)
- Native Windows as a dev environment (WSL bootstrap only)
- mise/asdf (fnm is enough for the current stack)
- Ansible/Nix
- CI Tier 3 end-to-end (planned for v1.1)
- Roles/profiles per dev type (e.g. "frontend-only" vs "fullstack") — every dev is fullstack by default
- Auto-update of dev-bootstrap (`dev-bootstrap update` command)
- Multiple PHP or Node versions at once (fnm covers Node; PHP stays pinned at 8.4)

## 14. Post-MVP roadmap

**v1.1 (backlog, no commitment):**
- CI Tier 3 (daily E2E with `60-web-stack` + `70-remote-access`)
- `dev-bootstrap update` command — pull + re-run bootstrap
- Detector for changes in the local `~/.zshrc` vs template (warn before overwriting)

**v1.2:**
- Native Linux support (non-WSL)
- Optional profiles (`--profile minimal`, `--profile laravel`, `--profile devops`)
- Migrate from fnm to mise if the stack grows

## 15. References

- Original wsl-dev-setup: https://github.com/henryavila/wsl-dev-setup (to be archived)
- Topic-based pattern: inspired by `holman/dotfiles`
- `.d/` folder pattern: systemd, `/etc/profile.d/`, oh-my-zsh plugins
- Idempotent deploy.sh with diff/backup: adapted from wsl-dev-setup's `deploy-dotfiles.sh`

## 16. Sign-off

- [x] Topic-based architecture (vs 3-layer / single-script / chezmoi)
- [x] Auto-installed Nerd Font
- [x] Catppuccin Mocha baked into starship.toml
- [x] fnm for Node (not mise)
- [x] PHP 8.4 via ondrej/brew
- [x] CI Tier 1 + Tier 2 active since MVP
- [x] CI Tier 3 deferred to post-stabilization
- [x] Matrix: ubuntu-22.04, ubuntu-24.04, macos-latest
- [x] Ansible discarded
- [x] `dotfiles-template` public, marked as template
- [x] Personal `dotfiles` private, created from the template
- [x] Archive legacy `wsl-dev-setup`

**Ready for implementation.**
