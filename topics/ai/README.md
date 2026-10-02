# 80-claude-code

Installs the three tools that make up the cross-machine "Claude stack":

## 1. Bun runtime

Via the official installer: `curl -fsSL https://bun.sh/install | bash`. Binary lands at `~/.bun/bin/bun`; `~/.bun/bin` is added to shell rc automatically.

**Why here:** the `claude-mem@thedotmack` plugin (installed by the `claude-mem` bundle below — opt-in) runs a **worker service** on port 37777 that is managed by Bun. The plugin ships a `smart-install.js` hook that auto-installs Bun if missing, but that only fires on the first Claude session with the plugin active — a fragile dependency chain. Installing Bun explicitly in the bootstrap removes that timing/connectivity coupling and guarantees claude-mem works from the first session.

If you don't select the `claude-mem` bundle, Bun is unused but harmless.

## 2. Claude Code CLI

Via the official installer: `curl -fsSL https://claude.ai/install.sh | bash -s latest`. Binary lands at `~/.local/bin/claude` (the `PATH` is already covered by topic `30-shell`). The `latest` argument is the native release channel (not `stable`, which lags). `mesh upgrade` re-runs this installer because `check()` is presence-only.

**Login:** after installing, run `claude` and authenticate once per machine (OAuth with Anthropic — not transferable).

## 3. Syncthing (P2P file sync daemon)

Used to sync a curated subset of `~/.claude/` and `~/.claude-mem/` across N personal machines, **with no intermediate cloud**. The daemon runs as a user-level service and discovers peers via LAN + STUN/relay.

**Install:**

- **WSL / Linux**: `sudo apt-get install syncthing`; enables `systemctl --user enable --now syncthing.service` + `loginctl enable-linger $USER` (so it runs after logout).
- **macOS**: `brew install syncthing`; started via `brew services start syncthing`.

**Web UI:** http://localhost:8384 — first-use steps:
1. Set an admin password under *Settings → GUI* (even for localhost-only access).
2. Grab the device ID: `syncthing --device-id`.
3. Pair with other machines + accept shared folders.

**Pairing + folders flow** (what to sync, with which `.stignore`): documented in `~/dotfiles/claude/scripts/syncthing-setup.md` once the user's dotfiles are cloned (topic `95-dotfiles-personal`).

## 4. `claude-hook-env` wrapper (for settings.json hooks)

`templates/bin/claude-hook-env` deploys to `~/.local/bin/claude-hook-env` and is used as a prefix for hook commands in `~/.claude/settings.json` to replay `brew shellenv` and restore `~/.local/bin` on `PATH`.

**Why needed:** Claude Code runs hook commands via `/bin/sh`, which reads neither `.bashrc` nor `.zshrc`. If Claude was launched from a GUI context (Dock/Spotlight on macOS) or from a shell that predates `brew shellenv` being active, hook commands like `node`, `bun`, or `git` can hit "command not found" even when those binaries exist on disk. The wrapper injects the proper environment before `exec "$@"`.

**Why a wrapper instead of LaunchAgent:** a wrapper is scoped to the Claude process — LaunchAgent `launchctl setenv PATH` leaks into every GUI app, which is broad blast radius. The wrapper is also path-stable across machines, which matters for Phase 6 of the Claude convergence plan (`~/.claude/settings.json` synced via Syncthing): machine-specific absolute paths inside `settings.json` would break convergence, but `claude-hook-env node -e …` works identically everywhere.

**Example `settings.json` entry:**

```json
{
  "hooks": {
    "SessionStart": [{
      "type": "command",
      "command": "claude-hook-env node -e 'console.log(\"ready\")'"
    }]
  }
}
```

The `${BREW_PREFIX}` inside the wrapper is substituted at bootstrap deploy time (`lib/deploy.sh` envsubst allowlist) with the prefix detected by `lib/detect-brew.sh` — so each machine gets its own resolved path baked in.

## Separation of concerns

This topic installs **tools** (CLI + daemon + hook wrapper). The *content* (what to sync, how to configure the daemon, which `.stignore` to use, which hooks to register in `settings.json`) comes from the **personal dotfiles** via `95-dotfiles-personal`.

## Skip

If you don't use Claude Code or prefer to handle syncthing outside the bootstrap:

```bash
SKIP_TOPICS="80-claude-code" bash setup.sh
```
