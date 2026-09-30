# remote-access (opt-in)

Select bundles in Blink / `selections.list` or pass `--bundle` (e.g.
`remote-access/ssh`, `remote-access/mosh`, `remote-access/tailscale`,
`remote-access/code-server`). `remote-access/tailscale` and
`remote-access/code-server` are tagged `membership: mesh` — under `--no-mesh`
they are **omitted from the catalog**.

**Installs:** `openssh-server` + `mosh` + `tailscale`. Activates sshd, enables systemd on WSL (`/etc/wsl.conf`).

**Legacy NOPASSWD removal** (since v2026-04-22): earlier versions of this topic created `/etc/sudoers.d/10-${USER}-nopasswd` with `NOPASSWD: ALL` as a convenience during bootstrap. That was unnecessary permanent attack surface — the main `setup.sh` now runs `sudo -v` at startup (cache warmup, ~5–15 min), covering the whole bootstrap duration with a single prompt. Forks that already had the file: this topic removes it automatically on the next run.

**Applies (WSL):** systemd drop-in to fix the tailscale0 MTU — see the "Tailscale MTU gotcha" section below.

**Applies (macOS, non-standard `BREW_PREFIX`):** when Homebrew lives somewhere other than `/opt/homebrew` or `/usr/local` (e.g. an external SSD at `/Volumes/External/homebrew`), this topic writes `/etc/paths.d/60-extbrew` with `$BREW_PREFIX/bin` + `$BREW_PREFIX/sbin` so `path_helper` injects them into the PATH of every shell — **including the non-interactive sshd-exec shell** that `mosh`/Moshi uses to bootstrap `mosh-server`. Without this, Moshi silently falls back to plain SSH (no roaming, no mobile-resilience). It also symlinks `mosh-server` into `/usr/local/bin` as a belt-and-suspenders fallback. See the "Moshi silently falls back to SSH" section below.

**Deploys:**
- `/etc/ssh/sshd_config.d/99-${USER}.conf` with hardening (PasswordAuth off, PubkeyAuth on, AllowUsers restricted).
  `envsubst` expands `${USER}`. `lib/deploy.sh` detects the path sits outside `$HOME` and elevates via sudo automatically.
- **(WSL)** `/etc/systemd/system/tailscaled.service.d/mtu.conf` — drop-in that runs `ip link set tailscale0 mtu 1200` at every `tailscaled` start. Idempotent: only rewrites if content differs.

**Post-install:**
1. Exit and run `wsl --shutdown` (Windows) to apply systemd.
2. `sudo tailscale up` to authenticate.
3. Copy your public key into the user's `~/.ssh/authorized_keys`.

---

## Tailscale MTU gotcha (post-quantum SSH KEX)

### Symptom

`ssh <host>` over Tailscale hangs forever at `SSH2_MSG_KEX_ECDH_REPLY`, even with `tailscale ping` returning in <10 ms. Only affects connections with OpenSSH 9.6+ (which negotiates post-quantum KEX by default).

### Cause

Bug pipeline:

1. Tailscale uses WireGuard with a default MTU of 1280.
2. OpenSSH 9.6+ negotiates `sntrup761x25519-sha512@openssh.com` → KEX messages of ~3–4 KB.
3. Inside an MTU-1280 tunnel, without reliable Path MTU Discovery, large fragments are silently dropped.
4. The client waits on a `KEX_ECDH_REPLY` that never arrives → timeout after ~2 min.

Reducing MTU **client-side via `~/.ssh/config` (`KexAlgorithms curve25519`) alone does NOT fix it** — host keys, banners, and other handshake messages can also exceed MTU.

### Fix applied (WSL — automated)

This topic writes `/etc/systemd/system/tailscaled.service.d/mtu.conf`:

```ini
[Service]
ExecStartPost=/usr/sbin/ip link set tailscale0 mtu 1200
```

The drop-in runs **every time** `tailscaled` starts, so it survives reboots and Tailscale reinstalls. Theoretical throughput cost inside the tunnel: ~6%. Imperceptible for SSH/mosh usage.

Idempotency: `install.wsl.sh` reads the file before writing — if content matches exactly, it doesn't touch it. If it differs, it rewrites + `daemon-reload` + (if `tailscaled` is active) `restart tailscaled`.

### Fix on macOS (manual)

Tailscale on Mac ships as a `.app` (via `brew install --cask tailscale`). The daemon is managed by the app itself; no equivalent systemd drop-in. The interface is `utun<N>` with variable N.

The topic installs `scripts/mac-tailscale-mtu-fix.sh`, which:
1. Detects the current Tailscale interface (via `tailscale ip -4` + `ifconfig` scan of `utun*`).
2. Runs `ifconfig <utun> mtu 1200`.

**On-demand usage** (when SSH hangs via Tailscale):

```bash
sudo bash ~/dev-bootstrap/topics/70-remote-access/scripts/mac-tailscale-mtu-fix.sh
```

Does not persist reboots — re-run after boot or re-login. For persistent automation, add a custom LaunchDaemon that runs the script at startup (TODO — not automated to avoid being invasive with the user-managed app).

### Verification

- **WSL**: `ip link show tailscale0` should report `mtu 1200`. The topic's `verify.sh` checks the drop-in + the applied MTU if the interface is up.
- **Mac**: `ifconfig utun<N> | grep mtu` where `<N>` is the current Tailscale interface.

### References

Detailed diagnostics + known variations in `ssh-tailscale-mtu-gotcha.md` (memory file in the personal dotfiles).

---

## Moshi silently falls back to SSH (non-standard brew prefix on Mac)

### Symptom

Moshi (iOS) or `mosh user@mac` from another machine connects — but the session dies on every network blip, iPhone background, or Wi-Fi ↔ cellular switch. The Moshi UI hints "SSH" instead of "Mosh" in the session header. No error is ever shown.

### Cause

Moshi always begins with an SSH invocation to execute `mosh-server new …` on the remote. That invocation runs in a **non-interactive, non-login** sshd-exec shell whose PATH comes from `path_helper` reading `/etc/paths` + `/etc/paths.d/*`. Default macOS PATH for that context is roughly:

```
/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin
```

When Homebrew lives in a non-standard prefix (e.g. `/Volumes/External/homebrew` because the user moved brew to an external SSD for space reasons), `mosh-server` is on disk at `$BREW_PREFIX/bin/mosh-server` but **invisible** to that PATH. The SSH-exec returns "command not found"; Moshi has no fallback telemetry, stays on SSH, no error surfaces to the user.

### Fix applied (macOS — automated)

This topic writes `/etc/paths.d/60-extbrew`:

```
/Volumes/External/homebrew/bin
/Volumes/External/homebrew/sbin
```

`path_helper` auto-reads `/etc/paths.d/*` on every new shell init (including sshd-exec via `/etc/zprofile` and friends). After this, `ssh mac 'which mosh-server'` from another host returns the right path, and Moshi's bootstrap finds `mosh-server`.

Additionally, a safety-net symlink: `/usr/local/bin/mosh-server → $BREW_PREFIX/bin/mosh-server`. `/usr/local/bin` is always on the default PATH, so even if `path_helper` hasn't been invoked yet in an edge-case shell, the binary is still findable.

Skipped when `BREW_PREFIX` is `/opt/homebrew` (arm64 default) or `/usr/local` (x86_64 default) — those are already on every standard PATH.

### Manual validation

From another machine (WSL, another Mac, etc.):

```bash
ssh user@mac 'which mosh-server'
# expected: /Volumes/External/homebrew/bin/mosh-server (or /usr/local/bin/mosh-server)
# if empty: path_helper/zprofile misconfigured; check /etc/zprofile exists and calls path_helper
```

Then reopen Moshi — the header should now show "Mosh" and the connection survives network roaming.

### References

The broader pattern: non-interactive SSH on macOS (`ssh user@mac '<cmd>'`) doesn't source `.zshrc`/`.bashrc`, so any brew-installed binary outside `/usr/bin` requires `/etc/paths.d/` or `/etc/zprofile` to call `path_helper`. This affects any brew binary accessed via SSH, not just mosh.

---

## Skip

If you don't use Tailscale or mosh, leave those bundles unchecked in Blink (or
omit `--bundle remote-access/*`). Guests using `--no-mesh` never see the
membership Tailscale/code-server rows.

## macOS code-server port and Tailscale CLI

The installer reuses the loopback port saved in `~/.config/code-server/config.yaml`.
If another process owns that port, it chooses the first free port in the next
100-port range (up to 65535), saves it, and preserves the password and other
settings with a private backup. Port probing requires Python 3; listener
ownership verification requires `lsof`. The default for a new config is 8080.
An existing config is authoritative; `CODE_SERVER_REWRITE_CONFIG=1` remains
an explicit full-config rewrite, including password configuration.

The health check verifies that the listener belongs to the managed LaunchAgent
or its descendants before configuring Tailscale Serve. An unrelated application
is never stopped. A competing bind after port selection fails validation; rerun
the installer to select again. A saved, dedicated Mesh Serve route on HTTPS 443
can follow the new port; unrelated Serve routes are preserved.

When the macOS app is installed without CLI integration, Mesh creates
`~/.local/bin/tailscale`, a wrapper around the app executable with
`TAILSCALE_BE_CLI=1`. Mesh shell profiles already include that directory in PATH;
the installer also adds it to its current environment. Existing executable CLIs
are preserved. This works for `/Applications/Tailscale.app` and the user's
`~/Applications/Tailscale.app`. See the [official CLI documentation](https://tailscale.com/docs/reference/tailscale-cli?tab=macos).
