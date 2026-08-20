# Install guide — Windows host → WSL2 Ubuntu → mesh setup

End-to-end path for a **fresh Windows machine** (nothing installed) through a
working mesh workstation inside Ubuntu. macOS-only installs can skip §1–§2 and
start at §3 using the mac row in the Phase 0 table.

Companion quickstarts: [README.md](../README.md) · [README.pt-BR.md](../README.pt-BR.md).  
Script: [`windows/install-wsl.ps1`](../windows/install-wsl.ps1).

---

## Overview

```text
Windows (Admin PowerShell)
  └─ install-wsl.ps1
       ├─ enable WSL + VirtualMachinePlatform
       ├─ winget: Git.Git + Microsoft.WindowsTerminal
       └─ wsl --install -d Ubuntu-24.04
            │
            ▼  (reboot if script exits 2, then re-run)
Ubuntu (first launch → create Linux user)
  └─ Phase 0 apt: git curl ca-certificates
       └─ clone mesh-workstation → bash setup.sh
            ├─ 1st run (no Node): lean bootstrap
            │    foundation + git/config + shell-terminal + languages/node + personal
            └─ 2nd run (new shell): full Blink menu
```

**Ownership split**

| Layer | What it installs |
|-------|------------------|
| Host script (`install-wsl.ps1`) | WSL features, Git for Windows, Windows Terminal, Ubuntu-24.04 |
| WSL `shell-terminal/fonts` (during setup) | CaskaydiaCove Nerd Font + Catppuccin merge into WT `settings.json` |
| WSL `languages/node` | fnm + Node LTS + shell PATH fragments |
| WSL `personal` | private `mesh-identity` (prompt, or `MESH_IDENTITY_REPO=…`) |

There is **no** supported “native Windows IDE/dev stack without WSL” path.

---

## 1. Windows host bootstrap

### Requirements

- Windows 10/11 with WSL2 support
- PowerShell **Run as Administrator**
- Network (winget sources + Ubuntu download)
- `winget` available, or recoverable via Desktop App Installer registration

### Virgin machine (no Git yet)

```powershell
irm https://raw.githubusercontent.com/henryavila/mesh-workstation/main/windows/install-wsl.ps1 -OutFile $env:TEMP\install-wsl.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-wsl.ps1
```

`-ExecutionPolicy Bypass` avoids Restricted-policy blocks on unsigned scripts.

Optional auto-reboot when features were just enabled:

```powershell
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-wsl.ps1 -Reboot
```

### Already have Git

```powershell
git clone https://github.com/henryavila/mesh-workstation "$env:USERPROFILE\mesh-workstation"
cd "$env:USERPROFILE\mesh-workstation"
powershell -ExecutionPolicy Bypass -File .\windows\install-wsl.ps1
```

### What the script does

1. Enables optional features `Microsoft-Windows-Subsystem-Linux` and `VirtualMachinePlatform` (`-NoRestart`).
2. If features were just enabled (or a reboot is pending): **exits `2`** and tells you to reboot, then re-run. With `-Reboot`, restarts immediately.
3. Ensures `winget` (tries App Installer family registration if missing; otherwise fail-closed with Store/`aka.ms/getwinget` instructions).
4. Installs `Git.Git` and `Microsoft.WindowsTerminal` via winget (**fail-closed** — no silent “Done.” on failure).
5. Runs `wsl --install -d Ubuntu-24.04 --no-launch` (falls back to `Ubuntu` if needed), sets default version 2, prints `wsl -l -v`.

It does **not** install a Nerd Font on the host. Fonts are applied later from inside Ubuntu.

### Exit codes

| Code | Meaning |
|------|---------|
| `0` | Host bootstrap finished; Ubuntu registered (or already present) |
| `1` | Hard failure (winget missing/unrecoverable, package or `wsl` install failed) |
| `2` | Reboot required before distro install can proceed — re-run after reboot |

### After exit 0

1. Open **Ubuntu** / **Ubuntu 24.04** from the Start menu.
2. Create your Linux username/password on first launch.
3. Continue in that Ubuntu shell with §2.

---

## 2. WSL Phase 0 (inside Ubuntu)

Needed so HTTPS `git clone` works on a blank distro:

```bash
sudo apt-get update && sudo apt-get install -y git curl ca-certificates
```

Then:

```bash
git clone https://github.com/henryavila/mesh-workstation ~/mesh-workstation
cd ~/mesh-workstation
bash setup.sh
```

Curl-pipe alternative (also clones `mesh-workstation`):

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/henryavila/mesh-workstation/main/install)
```

---

## 3. What `bash setup.sh` does on a virgin WSL box

### First run (Node not on PATH yet)

Blink cannot open without Node. Setup does **not** flip `NON_INTERACTIVE=1`
(that flag means you asked for headless). Instead it applies a **lean bootstrap**
selection:

- `foundation/base`
- `identity/identity`
- `git/config`
- `shell-terminal/cli-tools`
- `shell-terminal/zsh`
- `shell-terminal/fonts` ← CaskaydiaCove + WT theme
- `languages/node` ← fnm + LTS + `~/.bashrc.d` / `~/.zshrc.d` fragments
- `personal/personal` ← TTY prompt for identity repo if needed

This avoids silently installing the full default-on fleet (databases, web, AI, …)
before you can pick bundles.

### Second run (new shell)

Open a **new** Ubuntu / Windows Terminal tab so fnm PATH fragments load, then:

```bash
cd ~/mesh-workstation
bash setup.sh
```

Blink should open. Pick the rest of the catalog, confirm, apply.

### Headless / identity tips

```bash
# Supply identity without the menu
MESH_IDENTITY_REPO=you/mesh-identity bash setup.sh

# Guest / server — no mesh membership bundles
bash setup.sh --no-mesh
NON_INTERACTIVE=1 bash setup.sh --no-mesh --bundle languages/php

# Explicit headless bundles (implies non-interactive)
bash setup.sh --non-interactive --bundle languages/node --bundle web/valet
```

Under explicit `--non-interactive` with no `MESH_IDENTITY_REPO` and no existing
`~/mesh-identity` checkout, `personal` **soft-skips** with a critical followup
instead of aborting the whole engine run.

---

## 4. Fonts and Windows Terminal

| Step | Owner |
|------|--------|
| Install Windows Terminal | `install-wsl.ps1` (winget) |
| Install CaskaydiaCove Nerd Font (user-level, no Admin) | `shell-terminal/fonts` → `install-nerd-font.ps1` |
| Merge Catppuccin + font into `settings.json` | `configure-windows-terminal.sh` |

If WT never created its package folder, setup seeds a minimal `settings.json`
under the Store package path when possible. If that still fails, the followup
summary tells you to launch Terminal once and re-run:

```bash
bash setup.sh --bundle shell-terminal/fonts
```

No manual **Settings → Appearance → font** step is required when fonts land.

---

## 5. Systemd (services)

Selecting remote-access SSH enablement writes `systemd=true` into `/etc/wsl.conf`.
Activation needs a full WSL restart from **Windows** PowerShell:

```powershell
wsl --shutdown
```

Then reopen Ubuntu. Until then, `docker` / `mesh services` / user linger may stay
degraded. Setup records this as a **critical followup** in the end-of-run summary.

---

## 6. Local HTTPS (`*.localhost`)

The web bundle's mkcert step is supposed to import the CA into the Windows
store so Chrome/Edge trust `https://<name>.localhost`. That import is
best-effort over WSL interop; a green WSL install can still leave Windows
browsers at `NET::ERR_CERT_AUTHORITY_INVALID`.

Canonical write-up: [topics/web/README.md — HTTPS that works](../topics/web/README.md#https-that-works--including-from-windows-browsers).

From this clone:

```bash
bash topics/web/scripts/diagnose-wsl-interop.sh
```

Run the printed PowerShell command **on Windows**, then fully quit and reopen
the browser. Do not install a certificate by hand.

---

## 7. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Script exits 1: winget not found | App Installer missing / Store blocked | Install from https://aka.ms/getwinget or Store “App Installer”, re-run as Admin |
| Script exits 2 | Features enabled, reboot pending | Reboot Windows, re-run the same `.ps1` |
| `git clone` TLS errors in Ubuntu | Phase 0 skipped | `sudo apt-get install -y ca-certificates` (and `git` `curl`) |
| Blink menu never opens | Node/fnm not on PATH in this shell | Finish lean bootstrap; **open a new tab**; re-run `bash setup.sh` |
| Glyphs broken in Terminal | Fonts bundle not applied yet | `bash setup.sh --bundle shell-terminal/fonts` |
| `mesh services` / docker odd on WSL | systemd not live yet | `wsl --shutdown` from Windows, reopen Ubuntu |
| Personal identity missing after headless run | Soft-skip without `MESH_IDENTITY_REPO` | `MESH_IDENTITY_REPO=you/repo bash setup.sh` or interactive re-run |
| Windows Chrome/Edge: `NET::ERR_CERT_AUTHORITY_INVALID` on `https://*.localhost` | mkcert CA missing from the Windows store (WSL interop import skipped or failed) | From the clone: `bash topics/web/scripts/diagnose-wsl-interop.sh`. Run the printed PowerShell command **on Windows**, then fully quit and reopen the browser. Do not install a cert by hand. |

---

## 8. Related docs

- [SPEC.md](SPEC.md) §2 usage flow, §4 selection / `--no-mesh`
- [SERVICES.md](SERVICES.md) — `mesh services` backends (systemd on WSL)
- [CLEAN.md](CLEAN.md) — disk reclaim + WSL VHDX compaction handoff
- [TMUX.md](TMUX.md) — terminal multiplexer cheat-sheet (after shell-terminal lands)
- [topics/web/README.md](../topics/web/README.md) — `*.localhost` HTTPS, mkcert, Windows CA import / `diagnose-wsl-interop.sh`
