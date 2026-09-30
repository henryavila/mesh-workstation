# 20-terminal-ux

Modern terminal, **fully themed out of the box** — font, color scheme, and shell plugins installed and wired so a new machine boots into the intended look immediately.

## What's installed

**CLI stack (both platforms):** `fzf bat eza zoxide ripgrep fd starship lazygit git-delta tmux neovim`
**Modern-CLI replacements:** `btop duf gping sd tealdeer dust xh procs`
**zsh plugins:** completions, autosuggestions, syntax-highlighting, history-substring-search, fzf-tab, forgit, alias-tips, zsh-abbr, **Powerlevel10k** (+ zinit for turbo loading)
**History engine:** Atuin (cross-machine sync requires an account password and encryption key; see below).

## Atuin account and key backup

After Atuin installation, Mesh displays key-backup guidance and repeats it in
the final follow-up summary. This also runs when login is deferred, when Atuin
is already installed, or when only `shell-terminal/cli-tools` is selected.
`--no-mesh` skips sync onboarding.

For an existing account, run `atuin key` on a machine that already syncs.
Save the key in a protected field in **Keeper** (or another password manager),
alongside your username and password. On the new machine:

```bash
atuin login -u YOUR_USERNAME
atuin sync
```

Enter the password and the **same encryption key** at the prompts. Login does
not use browser OAuth. Avoid passing secrets as command-line arguments.

For a first account only, run `atuin register -u YOUR_USERNAME -e YOUR_EMAIL`,
then `atuin key` and save the key immediately. Do not register a new account
for each machine. Atuin stores the key locally; Mesh does not back it up or
replicate it automatically. Never put the key in Git, chat or installation
logs. If all copies are lost, the server cannot recover it.

Reference: [Atuin sync setup](https://docs.atuin.sh/guide/sync/).

## Terminal emulator auto-config

Bootstrap prepares terminal configuration and makes **Mesh — Nerd Font** the default iTerm2 profile. If iTerm2 is open, a one-shot user LaunchAgent applies the default after you fully quit it normally (checks every 10 seconds); reopen afterward. Mesh never closes sessions.

| Platform | Emulator | Font | Color scheme | Config script |
|---|---|---|---|---|
| macOS | iTerm2 | CaskaydiaCove Nerd Font Mono | Inherits the default profile | `scripts/configure-iterm2-font.sh` (managed dynamic profile; verifies macOS font registration) |
| WSL (Windows) | Windows Terminal | CaskaydiaCove Nerd Font (user-level install via PowerShell) | **Catppuccin Mocha** (appended to `schemes[]`, set via `profiles.defaults`) | `scripts/configure-windows-terminal.sh` + `install-nerd-font.ps1` |

Both scripts are **idempotent** and **non-destructive**:
- The font installer checks the HKCU registry before downloading.
- The Windows Terminal config does a surgical `jq` merge — existing user profiles, keybindings, and custom schemes are preserved.
- A timestamped backup is written next to `settings.json` whenever a change is applied.

Native-Linux users outside WSL: no terminal emulator config runs. Use whatever terminal you prefer and point it at the fonts/themes shipped under `~/.local/share/`.

## Shell wiring

- `bashrc.d-20-terminal-ux.sh` / `zshrc.d-20-terminal-ux.sh` — initialize starship (bash only), zoxide, fzf keybindings, and register `ls→eza`, `cat→bat`, `fd→fdfind` (WSL). zsh prompt is p10k via `zshrc.d/90-prompt.sh` (works under `--no-mesh`; no identity `~/.zshrc.local` required).
- `zsh-site-functions/_mesh` — managed zsh completion for the `mesh` command.
  Top-level `mesh <TAB>` shows supported subcommands, and
  `mesh topic <TAB>` reads the official topic list from `mesh topic list` when
  available, with a static fallback for fresh installs.
- Fzf shortcuts: `Ctrl+R` (history), `Ctrl+T` (file finder), `Alt+C` (cd fuzzy).
- **tmux:** the prefix is **`Ctrl-a`** (not the upstream `Ctrl-b`). Full keybindings
  cheat-sheet — splits, panes, resize, windows, copy-mode, and per-client (PC/Mac/Moshi)
  notes — in [`docs/TMUX.md`](../../docs/TMUX.md). Session aliases (`tl`/`ta`/`tn`/`tm`) in
  [`docs/ALIASES.md`](../../docs/ALIASES.md).
- `BAT_THEME=Catppuccin-mocha` exported so `bat` renders in the same palette as the terminal.
- **Herdr remote clipboard (macOS):** installs `~/.local/bin/pbcopy` (item
  `pbcopy-osc52`) which forwards to `/usr/bin/pbcopy` and, when `HERDR_ENV=1`,
  also emits OSC 52 so `herdr --remote` clients receive agent/shell copies.
  Override with `MESH_PBCOPY_OSC52=0|1`. Source: `bin/pbcopy`.

The `shell-terminal/zsh` bundle adds `~/.local/share/zsh/site-functions` to
`fpath` before `compinit` and owns the completion files deployed into that
directory. If `mesh <TAB>` falls back to files, re-apply with
`bash setup.sh --non-interactive --bundle shell-terminal/zsh` (or select the
bundle in the Blink menu / `selections.list`), then open a new shell.

## Customization

- **Theme change:** edit `templates/cli-tools/starship.toml` (bash prompt) or your personal `~/.p10k.zsh` (zsh prompt) and re-apply with `bash setup.sh --non-interactive --bundle shell-terminal/cli-tools` (and `--bundle shell-terminal/zsh` if you also changed zsh/p10k wiring).
- **Different font:** export `NF_PS_NAME` with the installed PostScript font name before running the iTerm2 configurator; Windows Terminal uses `font.face` in `scripts/wt-settings-fragment.json`.
- **Skip terminal auto-config:** the two scripts are each gated by `-x` checks in `install.*.sh`; remove the corresponding block if you prefer to manage the emulator by hand.

### iTerm2 font verification

Mesh writes only `~/Library/Application Support/iTerm2/DynamicProfiles/mesh-font.json`.
It inherits the default profile and preserves its font size, while selecting
`CaskaydiaCoveNFM-Regular` for ASCII and other glyphs. Existing profiles and open
sessions are not rewritten or closed. CoreText must resolve the exact font name;
a fallback such as Helvetica is an error, even if the font file exists.
The managed profile and saved default are validated separately from active sessions.
The setup summary distinguishes an applied default from a deferred update.
The one-shot helper lives under `~/.local/lib/mesh/`; its LaunchAgent removes itself
after preference readback succeeds. Errors retry and log to
`~/.local/state/mesh/iterm2-default.err`. `--check` is read-only: it verifies either the saved default or the exact
managed helper and loaded one-shot job, explicitly reporting pending activation. Custom iTerm2 preference folders are rejected
explicitly rather than silently changing an unused local domain.
This replaces direct plist edits that could race iTerm2's in-memory preferences.

Personal iTerm2 preferences can be stored in `${MESH_IDENTITY_DIR:-$HOME/mesh-identity}/iterm2/font.json`:

```json
{"font_size": 20, "ligatures": true}
```

Both settings are optional; font size must be 6–96 points and ligatures a boolean.
They affect the managed Mesh profile, including ASCII and non-ASCII font settings.
