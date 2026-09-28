# mesh-workstation

[![smoke-test](https://github.com/henryavila/mesh-workstation/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/henryavila/mesh-workstation/actions/workflows/smoke-test.yml)
[![lint](https://github.com/henryavila/mesh-workstation/actions/workflows/lint.yml/badge.svg)](https://github.com/henryavila/mesh-workstation/actions/workflows/lint.yml)

Reproducible dev-machine setup for WSL2/Ubuntu, macOS, and Windows (via WSL).

> **Languages:** English (this file) · [Português](README.pt-BR.md)

One of two repos in a layered architecture:

| Repo | Role | Visibility |
|------|------|------------|
| **mesh-workstation** (this) | Installs tools and applies opinionated global configs. Contains `template/` for new identity scaffolding. | public |
| `<user>/mesh-identity` | Personal dotfiles (identity + overrides) | **private** (per user) |

**Separation of concerns:** the workstation installs CLI/daemons/stack and writes universal configs (bashrc, inputrc, global gitconfig, fragments in `~/.bashrc.d/`); the identity repo applies personal config + overrides on top.

## Quickstart

Full Windows → WSL walkthrough (exit codes, fonts, systemd, troubleshooting):
**[docs/INSTALL-WINDOWS-WSL.md](docs/INSTALL-WINDOWS-WSL.md)**.

### A. Windows host (Admin PowerShell) → Ubuntu

On a virgin PC (no Git yet):

```powershell
irm https://raw.githubusercontent.com/henryavila/mesh-workstation/main/windows/install-wsl.ps1 -OutFile $env:TEMP\install-wsl.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-wsl.ps1
```

If Git is already installed:

```powershell
git clone https://github.com/henryavila/mesh-workstation "$env:USERPROFILE\mesh-workstation"
cd "$env:USERPROFILE\mesh-workstation"
powershell -ExecutionPolicy Bypass -File .\windows\install-wsl.ps1
```

| Exit | Meaning |
|------|---------|
| `0` | WSL features OK, Git + Windows Terminal installed, Ubuntu-24.04 registered |
| `2` | Reboot required — reboot Windows, re-run the same command, then continue |
| `1` | Hard failure (often missing winget — see the install guide) |

Then open **Ubuntu** from the Start menu and create your Linux user. Host script
does **not** install the Nerd Font; that happens inside Ubuntu during setup
(`shell-terminal/fonts` → CaskaydiaCove + Catppuccin in Windows Terminal).

### B. Linux / WSL, or macOS

**Phase 0** — only what is needed to clone this repo. Homebrew is installed later, by `foundation`, inside `setup.sh`.

| Platform | One-time prereq |
|---|---|
| WSL2 / native Linux | `sudo apt-get update && sudo apt-get install -y git curl ca-certificates` |
| macOS | Command Line Tools, which provide `git`. The first `git` command opens Apple's installer when they are missing. |

```bash
git clone https://github.com/henryavila/mesh-workstation ~/mesh-workstation
cd ~/mesh-workstation
bash setup.sh
```

The checkout can live on another volume. `cd` there and run `bash setup.sh` from that directory. `~/.local/bin` is added to `PATH` by the shell topic, so the first run is `bash setup.sh`.

**What happens**

1. On a Mac with no Homebrew, a TTY asks whether to install it on a separate path. **Yes:** it asks for the path (Enter accepts `/Volumes/External/homebrew` when that volume is mounted) and exports `BREW_CUSTOM_PREFIX`. **No:** it exports `BREW_CUSTOM_PREFIX=/opt/homebrew`. Foundation installs Homebrew at that prefix later in the same run. `gh` is still missing at this point, so a warning about anonymous GitHub API access is expected; the `identity` topic installs `gh` after Homebrew and opens the browser to log in.
2. One `sudo` password prompt (`sudo -v`) runs before the menu. Later `sudo` calls stay quiet for the cache window (~5–15 min).
3. **No Node on PATH:** lean bootstrap — `foundation`, `identity`, `git/config`, `shell-terminal` (incl. fonts), `languages/node`, `personal`. The full default-on fleet (databases, web, AI, …) stays uninstalled until you pick it.
4. **Node already on PATH:** the Blink menu opens on this first run.
5. **Open a new shell** so the fnm and Homebrew `PATH` fragments load.
6. **Next run:** `bash setup.sh` opens the Blink menu — pick bundles (`web/valet`, `databases/mysql`, `ai/claude-code`, …), confirm, apply.

A mesh workstation keeps `identity` and `personal` selected. The menu asks for `MESH_IDENTITY_REPO` (URL or `owner/name`) and for the dev root, `CODE_DIR` (default `~/code`). Point `CODE_DIR` at the directory that should hold repos — on an external disk, that disk's code directory (for example `/Volumes/External/code`).

> Historical note: early releases used a `whiptail` checklist over numbered
> `00-*` / `60-web-stack` topics. That UX is gone; do not treat numbered topic
> ids or `INCLUDE_*=1` as the current product path.

#### Homebrew prefix (macOS)

On a TTY, `setup.sh` asks before the menu and exports `BREW_CUSTOM_PREFIX`. Foundation reads that variable when it installs. Set the variable yourself to skip the question — a non-interactive run needs that, because it never asks.

| Situation | Prefix |
|---|---|
| Interactive, nothing set, no `brew` yet | Asks "separate path?". Yes → asks for the path and exports it. No, or a blank/relative answer → exports `/opt/homebrew`. |
| `BREW_CUSTOM_PREFIX` already set, no `brew` yet | That path. The question is skipped. |
| Non-interactive, variable unset, no `brew` yet | `/opt/homebrew`. |
| A `brew` binary already exists | That install. Later runs keep it. |

Separate path without answering the question — the prefix `scripts/lib/detect-brew.sh` finds again even when `brew` is not on `PATH`:

```bash
cd /path/to/mesh-workstation
BREW_CUSTOM_PREFIX=/Volumes/External/homebrew bash setup.sh
```

The last path component has to be `homebrew`, on a volume mounted at `/Volumes/External` (or `/Volumes/External 1`, `/Volumes/External 2`, … when macOS disambiguates the mount). The detector also looks at `/opt/homebrew` and `/usr/local`. A prefix on a volume whose name does not start with `External` stays invisible until `brew` is already on `PATH`; the next run then tries to reinstall and stops because the directory is not empty.

The upstream Homebrew install script always writes `/opt/homebrew` (Apple Silicon) or `/usr/local` (Intel). A binary in either place is the prefix every later run keeps, so the external path has to be chosen on this first run.

A custom prefix builds most formulae from source, because bottles are not relocatable. The first full workstation install takes longer than `/opt/homebrew`. On a volume mounted with owners disabled, user LaunchAgents (Redis, Mailpit, Postgres, Syncthing) start through the rootfs launch-wrapper when those topics run. The question printed before the menu lists both.

**Guest / server mode (`--no-mesh`)** — install tools without joining the mesh:

```bash
# interactive picker without membership bundles
bash setup.sh --no-mesh
mesh menu --no-mesh

# headless: only foundation/base (then add bundles explicitly)
NON_INTERACTIVE=1 bash setup.sh --no-mesh
bash setup.sh --no-mesh --non-interactive --bundle languages/php

# inspect the filtered catalog
bash setup.sh --no-mesh --list-bundles
```

Under `--no-mesh` / `MESH_NO_MESH=1`:

- Five `membership: mesh` bundles are **omitted from the catalog** (removed, not
  greyed): `personal/personal`, `identity/identity`, `syncthing/syncthing`,
  `remote-access/tailscale`, `remote-access/code-server`.
- Unlock list (`git/config`, `shell-terminal/cli-tools`, `shell-terminal/zsh`)
  loses required locks and starts **unchecked**.
- Headless default without `--bundle` is **only** `foundation/base`.
- Engine apply **aborts nonzero** (fail-closed) if any membership bundle
  reappears in the resolved selection/closure.
- `atuin-login` is a **no-op**.
- The **unflagged** path still keeps `personal` / `identity` as required locks
  alongside `foundation/base` and the unlock list.

**Automation / CI mode** (no menu — env vars and flags):

```bash
# preview the plan without executing
bash setup.sh --dry-run

# skip the menu even on a TTY
NON_INTERACTIVE=1 bash setup.sh
bash setup.sh --non-interactive

# list every topic/bundle + default mark
bash setup.sh --list-bundles

# headless selection without the menu (repeatable)
bash setup.sh --non-interactive --bundle languages/php --bundle databases/mysql
```

The menu is automatically skipped when any of these is true: (a) `NON_INTERACTIVE=1` or `--non-interactive`; (b) stdin/stdout isn't a TTY (pipe, cron, CI); (c) one or more `--bundle` flags were passed.

On macOS, put `BREW_CUSTOM_PREFIX` on the same command. A non-interactive run with the variable unset installs Homebrew at `/opt/homebrew`:

```bash
BREW_CUSTOM_PREFIX=/Volumes/External/homebrew bash setup.sh --non-interactive
```

### After the bootstrap finishes

The bootstrap **prints at the end everything that still needs a human touch** — you don't need to remember a list. The post-run advisories cover:

- `chsh` — the bootstrap **tries `sudo chsh` automatically** using the warm sudo ticket (`sudo usermod -s` as a Linux fallback). Falls back to an advisory only on LDAP/SSSD-managed corporate accounts, restricted PAM, or missing sudo cache. Opt out with `CHSH_AUTO=0`.
- `atuin login` — the bootstrap **runs it inline** when you're on a TTY and not already logged in. Opens the system browser to atuin.sh for OAuth, polls for the code, writes the credential into atuin's daemon. Opt out with `ATUIN_LOGIN_AUTO=0` (or `NON_INTERACTIVE=1`); in that case you'll see the advisory and can run `atuin login` manually later. **Skipped entirely** when `MESH_NO_MESH=1` / `--no-mesh` (`atuin-login` is a no-op). Detection uses `atuin status` exit code (atuin v18 stopped creating the legacy `session` file).
- `newgrp docker` / log out+in, when 45-docker just added you to the `docker` group.
- `ngrok config add-authtoken <token>`, when `INCLUDE_NGROK=1` ran without a token available. The bootstrap **prompts for the token in the interactive menu** and stores it to `~/.local/state/mesh/secrets.env` (mode 0600), so it's only asked once per machine. Automation mode: export `NGROK_AUTHTOKEN=<token>` before running.
- Manual `mailpit &` / `docker` service start, when systemd isn't available (rare).
- `gpg --full-generate-key`, when `GPG_SIGN=1` ran without an existing key.

If you see a `!` line in the bootstrap output, it's pointing at a next step. Read the advisory instead of re-running the topic.

## Runtime repair and update recovery

Use the command that matches the condition; the update flags are not aliases
for runtime repair.

| Condition | Supported command | What it does |
|---|---|---|
| Broken PHP, Valet, nginx, or php-fpm runtime | `mesh doctor --fix` | Verifies installed owners with their strongest probes, repairs broken owners, and returns nonzero if any remain unresolved. |
| Messy bash/zsh, unmanaged `~/.zshrc` / `~/.bashrc`, login-shell mismatch | `mesh reinstall shell` | Reapplies the shell layer (zsh/bash rc, CLI tools, tmux, nvim, fonts, git aliases) without rewriting `selections.list` and without touching PHP, databases, nginx, or docker. Unmarked rc files are refused — move personal snippets to `~/.zshrc.local` / `~/.bashrc.local` first. Windows e2e gate: `powershell -ExecutionPolicy Bypass -File tests\e2e\reinstall-shell-wsl-gate.ps1` (throwaway distro; not in `run-all.sh`). |
| Windows Chrome/Edge rejects `*.localhost` TLS (`NET::ERR_CERT_AUTHORITY_INVALID`) | From the clone root: `bash topics/web/scripts/diagnose-wsl-interop.sh` | Probes WSL interop and prints the exact Windows PowerShell command to import the mkcert CA (works when interop is broken). Run that printed line on Windows, then restart the browser. |
| New owner on an upgraded marker-owned bundle | `mesh doctor --fix` | Adopts the owner if its probe is already healthy; otherwise repairs, re-verifies, and records it. This is the supported upgrade path on an existing host. |
| Complete reapply of the saved selection after pulling changes | `mesh update --full` | Runs the full apply instead of only the last-applied diff. |
| Update while intentionally tracking a non-`main` branch | `mesh update --force` | Bypasses only the branch gate; dirty trees and unpushed commits are still refused. |

The `--force` flag is branch authorization only; it is not repair and does not
imply `--full`. For a broken PHP/web runtime, use `mesh doctor --fix`.

## Topics

Live catalog dirs under `topics/<id>/` (unnumbered). Select bundles in Blink,
`selections.list`, or `--bundle topic/bundle`. Full list: `bash setup.sh --list-bundles`.

| Topic | Example bundles | Notes |
|-------|-----------------|-------|
| `foundation` | `foundation/base` | Core packages (git, curl, jq, envsubst, …) |
| `languages` | `languages/node`, `languages/php` | Node via fnm, multi-PHP, Python |
| `shell-terminal` | `shell-terminal/cli-tools`, `shell-terminal/zsh`, `shell-terminal/tmux` | fzf/bat/eza/starship/atuin, zsh+completions, tmux |
| `git` | `git/config`, `git/lazygit`, `git/gpg-signing` | Global gitconfig + shell aliases |
| `web` | `web/valet`, `web/nginx-php-fpm`, `web/mailpit`, `web/ngrok` | Local HTTPS / nginx+PHP-FPM stack |
| `databases` | `databases/mysql`, `databases/redis`, `databases/postgresql` | DB servers + drivers |
| `containers` | `containers/docker` | Docker / Colima |
| `remote-access` | `remote-access/ssh`, `remote-access/mosh`, `remote-access/tailscale`, `remote-access/code-server` | `tailscale` + `code-server` are `membership: mesh` |
| `syncthing` | `syncthing/syncthing` | P2P sync — `membership: mesh` |
| `identity` | `identity/identity` | gh + SSH machine identity — `membership: mesh` |
| `personal` | `personal/personal` | Clone/apply mesh-identity — `membership: mesh` |
| `ai` | `ai/claude-code`, `ai/mdprobe`, `ai/atomic-skills`, `ai/rtk` | Agent CLI + workflow tools |

Full alias inventory: [`docs/ALIASES.md`](docs/ALIASES.md).

Every topic has its own `README.md` (except thin membership-only dirs that point
at the manifest). Bundles declare items in `topics/*/manifest.yaml`; the engine
applies selected items and deploys templates under `topics/<id>/templates/`.

## Env vars and CLI flags

Primarily for automation / CI — the interactive menu fills these in for human use. Any pre-existing env var wins over menu defaults.

| Var / flag | Effect |
|------------|--------|
| `--non-interactive` / `NON_INTERACTIVE=1` | Skip the menu even on a TTY |
| `--dry-run` / `DRY_RUN=1` | Print what would run without executing (also skips `sudo -v`) |
| `--list-bundles` | List every `topic/bundle` and its default mark (required / default on / opt-in) |
| `--no-mesh` / `MESH_NO_MESH=1` | Omit the five `membership: mesh` bundles (remove, do not grey); unlock `git/config` + `shell-terminal/cli-tools` + `shell-terminal/zsh` (unchecked); headless default `foundation/base` only; fail-closed apply; `atuin-login` no-op |
| `--bundle topic/bundle` | Add a bundle to the headless selection (repeatable; implies non-interactive) |
| `--help` / `-h` | Usage message |
| `SKIP_TOPICS` | CI hatch: space-separated **topic ids** dropped from the resolved selection (not a product catalog mode) |
| `ONLY_TOPICS` | **Legacy / dead in v2 `setup.sh`** — not a working selection API; use `--bundle`, the Blink menu, or a saved `selections.list` |
| `MESH_IDENTITY_REPO` | URL/path of the dotfiles repo used by `82-ai-tools` and `95-dotfiles-personal` (accepts `file://` for local testing) |
| `MESH_IDENTITY_DIR` | clone destination (default `~/mesh-identity`) |
| `MESH_NPM_GLOBAL=1` | pass opt-in to the dotfiles installer to set npm global prefix to `~/.npm-global` and persist `~/.npm-global/bin` on shell PATH |
| `INCLUDE_AI_TOOLS=1` | enable `82-ai-tools`; installs AI review prompts + token-saving CLI tools from the dotfiles manifest without applying personal dotfiles |
| `INCLUDE_IDENTITY=1` | enable `95-dotfiles-personal`; `MESH_IDENTITY_REPO=<url>` alone is still accepted as a legacy shorthand |
| `MESH_AI_PACKAGES=1` | legacy alias for `INCLUDE_AI_TOOLS=1` |
| `GIT_NAME` / `GIT_EMAIL` | identity — applied only when `user.name` / `user.email` aren't set yet (topic 50-git preserves existing values) |
| `CODE_DIR` | dev root — where your repos live (default `~/code`; the menu asks on first run). Shell auto-cd + web-stack site root. On an external disk, set the disk's code directory (for example `/Volumes/External/code`) |
| `BREW_CUSTOM_PREFIX` | macOS, only when no `brew` binary exists yet. Absolute prefix, for example `/Volumes/External/homebrew`. The directory must be named `homebrew` directly under `/Volumes/External` (or `/Volumes/External 1`, …) so the next run can find it with an empty `PATH`. On a TTY, `setup.sh` asks and exports this itself. Set it to skip that question. Non-interactive runs with it unset use `/opt/homebrew`. An existing `brew` binary wins over this variable |
| `INCLUDE_WEBSTACK` / `INCLUDE_REMOTE` / `INCLUDE_AI_TOOLS` / `INCLUDE_EDITOR` / `INCLUDE_DOCKER` | enable opt-in topics |
| `INCLUDE_MAILPIT=1` / `INCLUDE_NGROK=1` / `INCLUDE_MSSQL=1` / `INCLUDE_POSTGRES=1` | 60-web-stack extras (when `INCLUDE_WEBSTACK=1`) |
| `POSTGRES_VERSION=17` | PostgreSQL major version when `INCLUDE_POSTGRES=1` (default 17; menu prompts on first run, env var pre-seeds for automation) |
| `NGROK_AUTHTOKEN` | ngrok token auto-configured during install; if unset, the menu prompts (passwordbox) and persists to `~/.local/state/mesh/secrets.env` (mode 0600) |
| `CHSH_AUTO=0` | skip the auto-`sudo chsh` attempt in 20-terminal-ux (defaults to 1 — tries to set zsh as default login shell using the cached sudo ticket, falls back to an advisory if refused) |
| `ATUIN_LOGIN_AUTO=0` | skip the inline `atuin login` in 20-terminal-ux (defaults to 1 on TTY; opens browser for atuin.sh OAuth) |
| `GPG_SIGN=1` (+ `GPG_KEY_ID=<id>`) | enable GPG commit signing in 50-git |
| `PHP_VERSIONS="8.4 8.5"` (+ `PHP_DEFAULT=8.5`) | pin PHP versions installed by 10-languages (defaults to all in `data/php-versions.conf`) |
| `DEV_DEFAULT_PORT=3000` | default port for `*.front.localhost` proxy in 60-web-stack |
| `NO_COLOR=1` | disable colored output (auto when not a TTY) |

## MySQL 8 notes

- **WSL**: installs `mysql-server-8.0` explicitly — not the meta `mysql-server` package, which can resolve to MariaDB on some Debian derivatives.
- **Mac**: brew formula `mysql@8.0` (the default `mysql` formula tracks 9.x). Because `mysql@8.0` is keg-only, the installer runs `brew link --force --overwrite mysql@8.0` so `mysql` / `mysqladmin` / `mysqldump` end up on `$PATH`.
- **Mac escape hatch**: if `brew install mysql@8.0` fails for any reason, install via Oracle's [DMG installer](https://dev.mysql.com/downloads/mysql/) (it drops binaries in `/usr/local/mysql`). The bootstrap detects that path and skips brew automatically.

## Logs

Full output of every run is written to `/tmp/mesh-workstation-<os>-<timestamp>.log`. The path is printed near the top of the output.

## mesh ai — open a project in your AI agent

`mesh ai` is the project launcher that sits between your dev roots and your AI
agent multiplexer (`herdr`). It discovers the git repos on your disk — one level
under `AI_ROOTS` — lets you pick one, and hands it off: focusing `herdr`'s
workspace if that project is already open, else creating one at its directory
and launching the agent.

- `mesh ai`                    → searchable picker of every open workspace + on-disk repo.
                                 `Enter` uses your saved default · `Tab` opens
                                 an action menu · `Ctrl-P` edits local defaults.
- `mesh ai <term>`             → open the project matching `<term>`; a single match opens
                                 directly, several open the picker, none errors out.
- `mesh ai --list`             → print the full catalogue (discovered + pinned) and exit.
- `mesh ai <term> --agent X`   → use agent `X` for this launch (grok | claude | codex | gemini);
                                 the choice is remembered per project.
- `mesh ai <term> --grok`      → shortcut for `--agent grok`.
- `mesh ai <term> --codex`     → shortcut for `--agent codex`.
- `mesh ai <term> --shell`     → open the project directory in herdr without
                                 starting an agent.

Picker preferences are local to the current user+machine and live in
`~/.config/mesh/ai.env`. They are not committed to mesh-identity. The current
preferences cover the default agent, whether Enter opens an agent or a shell,
and whether an already-open workspace is focused or receives a new tab.

### Pinned projects

Discovery only sees git repos **one level** under a root, so a deep subdir, a
non-git folder, or a project you want under a custom label won't appear. Pin it
— pinned entries merge with discovery, and a pin wins on a name clash.

- `mesh ai add <path> [name]`  → pin a directory (non-git is fine). Idempotent:
                                 re-adding the same name updates its path.
- `mesh ai remove <name>`      → unpin by name.
- `mesh ai list`               → show the pins resolvable on this machine.

Pins live in a versioned manifest (`shell/ai-pinned.list` in mesh-identity,
synced across machines). Each line is `name|path`, and a path may list
**alternates** separated by `:` — the engine uses the first one that exists, so
one file serves machines with different layouts:

```
mesh-workstation|/Volumes/External/code/mesh-workstation:~/mesh-workstation
finance-app|/Volumes/External/Code/finance-app:/home/henry/code/finance-app
scratch-kb|~/notes/knowledge-base          # non-git, custom label
```

A pin whose paths don't exist on a given machine is skipped silently (never an
error) — so a mac-only project simply doesn't appear on WSL.

> The engine, the verbs, and the reader live in mesh-workstation; the manifest
> file and the path to it (`MESH_AI_PINNED`) live in mesh-identity — the same
> engine/data split as `AI_ROOTS`.

## Project structure

```
mesh-workstation/
├── setup.sh                  # runner — Blink menu / --bundle / engine apply
├── scripts/lib/              # detect-os, deploy, catalog, init, …
├── schema/manifest.schema.json
├── topics/<id>/              # unnumbered topics (foundation, git, web, …)
│   ├── manifest.yaml         # bundles + items
│   ├── templates/            # deployed when selected
│   ├── verify.sh
│   └── README.md
├── windows/install-wsl.ps1   # Windows bootstrap → WSL2 + Git + Windows Terminal
├── docs/SPEC.md              # technical specification
└── .github/workflows/        # CI
```

## Releases

| Tag | Highlights |
|-----|------------|
| `v2026-04-19` | Enriched `~/.inputrc` (word-kill, completion niceties) + new `topics/50-git/templates/bashrc.d-50-git.sh` with aliases `g`/`gs`/`gco`/`whoops`/`gmm` + `__git_complete` (bash). |
| `v2026-04-20` | Topic `80-claude-code` split into `install.wsl.sh` / `install.mac.sh`; **installs Syncthing daemon** for cross-machine Claude Sync (the `claude/` folder in dotfiles-template uses `.stignore` to control what replicates). |
| `v2026-04-21` | Topic `70-remote-access` automates the Tailscale MTU fix via drop-in `/etc/systemd/system/tailscaled.service.d/mtu.conf` (Linux). Mac ships an on-demand `scripts/mac-tailscale-mtu-fix.sh`. Hotfixes: starship TOML scope bug fix, `sudo -v` warmup on bootstrap start, removal of legacy `/etc/sudoers.d/10-${USER}-nopasswd`. |
| `v2026-04-22` | **Interactive whiptail menu is the new default** (opt-in topic selection + git identity + paths); `--non-interactive` and `--dry-run` CLI flags. MySQL 8 pinned explicitly (`mysql-server-8.0` WSL / `mysql@8.0` Mac) with Oracle DMG escape hatch. Topic `90-editor` repositioned: `typora-wait` handles WSL→Windows Typora via `wslpath -w` interop and uses `open -W -a Typora` on macOS (LaunchServices-based discovery). |
| (untagged, 2026-04-23) | Massive UX day — **auto-chsh** + **inline `atuin login`** + **`lib/secrets.sh` scaffold** (NGROK_AUTHTOKEN prompted via menu passwordbox, persisted to `~/.local/state/dev-bootstrap/secrets.env`). `_has_ctty()` via `/dev/tty` fixes TTY detection under `\| tee` pipe (all interactive fallbacks were dead code before). **PECL per-version install** cascade fixed across 6 commits + extracted to `lib/pecl-install.sh` (shared by 10-languages base + 60-web-stack MSSQL). `tmux.conf` resolves `default-shell` via `getent passwd`/`dscl` instead of stale `$SHELL`. **CI green** — `PHP_VERSIONS="8.4 8.5"` in smoke-test, all shellcheck warnings cleared. Major **alias migration** from private dotfiles to public topic fragments (30-shell/20-terminal-ux/40-tmux/60-web-stack/70-remote-access each got its shell fragment). |
| `v2026-04-30` | **Generic uninstall mechanism** — `lib/uninstall.sh` (7 verbs: apt/brew/brew-cask/clone/zinit/user-bin/sys-bin with OS guards + sandbox in 3 rm-based verbs) + per-topic `data/uninstall.list` manifest. Lets a topic retire artifacts (apt pkg, brew formula, zinit plugin, ~/.local/bin/ binary…) with a 1-line manifest entry instead of bespoke cleanup code. First consumer: `topics/20-terminal-ux/data/uninstall.list` drops `zsh-you-should-use` (overlapped with alias-tips). Cross-mesh propagation comes free via auto-update re-running affected topic install scripts. 24/24 tests in `tests/integration/uninstall-mechanism.test.sh`. |
| `v2026-05-02` | **LaunchDaemon /Volumes phantom-mkdir hardening** (Mac, non-standard `BREW_PREFIX`) — `topics/60-web-stack/install.mac.sh` post-`valet install` now PlistBuddies `Standard{Error,Out}Path` of the 3 brew system daemons (php/nginx/dnsmasq) to `/var/log/homebrew/<svc>.log` so early-boot launchd never `mkdir -p`s `/Volumes/External/homebrew/var/log/` before the disk mounts (which collides → `/Volumes/External 1` mount disambiguation, breaking every cached PATH and repo path). Companion `lib/detect-brew.sh` glob `/Volumes/External*/homebrew/bin/brew` lets recovery scripts find brew when the disambiguation already happened. Plus **mesh-cli convergence cleanup**: `topics/95-dotfiles-personal/data/uninstall.list` drops `bup`/`dotup`/`mesh-snap`/`mesh-status` from `~/.local/bin/` on machines that bootstrapped before the unified `mesh` dispatcher landed in `dotfiles-template` (release v2026-05-02 there). 19/19 tests in `tests/integration/launchdaemon-volume-paths.test.sh` + 21/21 still green in uninstall-mechanism. Forensic: `dotfiles/docs/2026-05-02-volumes-external-phantom-analysis.md`. |
| `v2026-05-03` | **Camada 4 — brew custom prefix first-class** (Mac, two PRs, closes the §4.7.5 / D43 follow-up to v2026-05-02). PR #5 (`5f1dd64`): `lib/launch-wrapper.sh` (294 LOC) — generates user-scope LaunchAgents that wrap brew binaries living in non-canonical (e.g. `/Volumes/External/homebrew`) prefixes via a rootfs shim script that `exec`s the external binary. Workaround for the macOS TCC sandbox bug that rejects user-scope LaunchAgents whose `ProgramArguments[0]` is in a `noowners` volume (exit 78 EX_CONFIG); empirical mechanism: TCC entitlement granted at spawn is preserved across `execve`, so a wrapper-in-rootfs that exec's the external binary works (validated side-by-side: `homebrew.mxcl.redis` direct → exit 78 vs `com.henry.test-extbrew-wrapper` rootfs-→-exec → state=running, +PONG on :16399). Wired up Syncthing in `topics/80-claude-code/install.mac.sh` (replaces the old `warn` text instructing manual plist creation, which never worked anyway). PR #6 (`0061564`): `lib/state.sh` (`~/.config/dev-bootstrap/state.env`, mode 0600, shell-sourceable `KEY="VALUE"`) + decision-ladder in `topics/00-core/install.mac.sh` (5 rungs: `detected_existing` → `state_replay` → `env_var` → `prompt` → `default`) + untar-anywhere via `git clone Homebrew/brew` for custom prefixes (the official `curl|bash` installer ignores `--prefix`) + structural bottle-less warning enumerating D31 + D32 + D34 + D42 + launch-wrapper trade-offs (TTY blocks on y/N, non-TTY logs and proceeds — CI-safe) + `BREW_CUSTOM_PREFIX` env var override + redis + mailpit also wrapped via `lib/launch-wrapper.sh`. **Bug fix tangentially caught in the same PR**: bash 3.2's `"${arr[@]+"${arr[@]}"}"` expands to one empty arg when the array is empty (vs zero args in bash 4+), which leaked into the plist as `<key></key><string></string>` inside `EnvironmentVariables` — malformed XML, EX_CONFIG=78, the very thing this lib exists to prevent. Fixed with explicit `${#arr[@]}` guard; regression-tested. **Hygiene**: `lib/uninstall.sh:159` shellcheck SC2221/SC2222 cleared (redundant `/*` pattern subsumed by `*/*`). M2 production validation: `com.henry.{syncthing,redis,mailpit}` all running with PIDs, liveness probes alive on :8384/:6379/:8025. 59/59 launch-wrapper + 29/29 brew-prefix-firstclass + 19/19 state tests green; no regressions. |
| `v2026-05-04` | **Bootstrap "create from template" UX** (D45) — `lib/menu.sh` adds a 4-screen whiptail flow (yes/no "create from template?" + template repo + new owner + new name + private/public) before the legacy URL prompt. Sets `CREATE_IDENTITY_FROM_TEMPLATE=1` + `*_NEW_REPO_*` exports. ESC=255 captured at every step (yesno prompts must NOT silently flip to "No" on ESC). `topics/95-dotfiles-personal/install.sh` adds a `gh repo create --template … --clone --directory $MESH_IDENTITY_DIR` block gated on the env flag, with 3-stage gh validation (`command -v gh` + `gh auth status` + `gh api user -q .login` for scope verification — `gh auth status` exits 0 even with missing scopes). Failures emit `followup critical` + `exit 1`. Preserves D40 drift cleanup (`source lib/uninstall.sh` + `uninstall_apply data/uninstall.list`). bash 3.2 hygiene: split `local var=$(cmd) \|\| handler` into separate declare + assign lines (D44 family bug — `local`'s rc masks cmd's rc on bash 3.2). Visibility flag uses an array (no SC2086 disable). 84/84 lint + 26/26 uninstall-mechanism + 12/12 deploy-manifest + 196/196 regression tests green. |
| `v2026-05-05` | **PostgreSQL opt-in** in `60-web-stack`. New `INCLUDE_POSTGRES=1` flag (sub-opt-in alongside `INCLUDE_MAILPIT`/`MSSQL`/`NGROK`), default-ON checkbox in the menu, dedicated screen for `POSTGRES_VERSION` (default 17, env-pre-seedable). New `topics/60-web-stack/scripts/install-postgres.sh` (Mac + Linux) — Mac path uses brew + `launch_wrapper_install_extbrew` for custom prefixes (TCC-safe per D43), Linux path uses the PGDG APT repo (`apt.postgresql.org`) with modern `signed-by` keyring under `/etc/apt/keyrings/`. Pre-flight `:5432` port-conflict check (mirrors web-stack-port-conflict pattern for nginx :80) — foreign owner triggers warn + skip service start, role/db pristine-only (queries `pg_roles` / `pg_database` before `createuser`/`createdb` so existing setups aren't disturbed). Cross-major guard: detecting an existing different `postgresql@<v>` install warns + skips reinstall (no auto-migration). Linux uses `--no-install-recommends` (defends against the PHP-recommends infection family from D43). Topic UI label updated `60-web-stack: multi-PHP + nginx + MySQL + mkcert + reverse proxy` → `Web + DB stack (PHP + nginx + MySQL + Postgres + mkcert)`. New `tests/integration/postgres-install.test.sh` — 30 contract assertions covering version validation, port detection, pristine-only role creation, launch-wrapper integration, PGDG repo setup, install/menu wiring. 30/30 + 570/570 full suite green. |
| (untagged, 2026-05-11) | **code-server opt-in** in `85-code-server` for macOS. Installs upstream standalone under `~/.local`, writes a user LaunchAgent `com.${USER}.code-server`, binds only to `127.0.0.1:${CODE_SERVER_PORT}`, keeps password auth and `config.yaml` mode `0600`, and exposes through Tailscale Serve by default (`CODE_SERVER_TAILSCALE_SERVE=1`; disable with `0`). Interactive installs prompt for a hidden password; non-interactive installs generate one and show it only in the final bootstrap summary. If missed, the password remains in `~/.config/code-server/config.yaml`; hashed-password configs cannot be recovered and should be reset with `CODE_SERVER_REWRITE_CONFIG=1`. Re-running the topic does not upgrade an existing binary by surprise: it checks the latest upstream release and prints an explicit `CODE_SERVER_UPGRADE=1 CODE_SERVER_VERSION=<latest> bash setup.sh --non-interactive --bundle remote-access/code-server` command when newer code-server is available. |

### Release discipline

Structural changes (new topic, changes in `lib/`, `install.sh`, `setup.sh`) go through:

1. Commit with a **migration note** in the body — *forks that already ran X should Y*. Estimated time, affected files, command to apply.
2. Dated tag: `git tag -a v2026-MM-DD -m "summary"`.
3. `gh release create v2026-MM-DD --notes-from-tag` after pushing.

Hotfixes with no structural change (template bug, README typo) use regular commits without a tag.

## CI

- `.github/workflows/lint.yml` (Tier 1) — shellcheck `-S warning` + `bash -n` on every push/PR. Fast (<20s).
- `.github/workflows/smoke-test.yml` (Tier 2) — green on `ubuntu-24.04` as of 2026-04-23. Builds a Docker image that mimics a fresh WSL Ubuntu, runs `setup.sh` non-interactively with `PHP_VERSIONS="8.4 8.5"` (two-version matrix to exercise the per-version ABI isolation without overshooting the 600s timeout — the full 4-version matrix stays for Tier 3). Uploads the run log as artifact on failure.
- Tier 3 E2E (planned, v1.1) — daily matrix across `ubuntu-22.04` / `ubuntu-24.04` / `macos-latest` with full PHP version set + idempotency check (2nd run = noop) + each topic's `verify.sh`.

## Personal dotfiles

This repo **never** versions personal configs (SSH, git identity, project-specific aliases). For that, use [dotfiles-template](https://github.com/henryavila/dotfiles-template): click *Use this template* on GitHub, mark the new repo **private**, and either let the interactive menu collect `MESH_IDENTITY_REPO` or set the env var before running `setup.sh`.

## Contributing

1. Adding a new topic: copy the structure of an existing dir under `topics/` (e.g. `topics/foundation/`) and register bundles in `manifest.yaml`.
2. Idempotency required: a second run must be a no-op (`already installed`, `up to date`). CI enforces this.
3. Before opening a PR: `shellcheck` on topic scripts must pass.

## See also

- [`docs/SPEC.md`](docs/SPEC.md) — technical specification (architecture, acceptance criteria, roadmap).
- [`docs/ALIASES.md`](docs/ALIASES.md) — inventory of universal aliases (shell + git) that every dev who ran the bootstrap receives.
- [`docs/SERVICES.md`](docs/SERVICES.md) — `mesh services`: cross-platform control of mesh-owned daemons (active × enabled, install ≠ auto-enable).
- `topics/<topic>/README.md` — per-topic customization and gotchas.
- [`dotfiles-template`](https://github.com/henryavila/dotfiles-template) — the flip side of the layer: personal overrides.
