# personal (required on mesh nodes)

Clones your private **mesh-identity** repo and applies it — the layer that makes
the machine *yours* (SSH config, git identity, shell overrides, personal aliases,
secrets deploy, etc.). Runs last, on top of the stack the earlier topics install.

`personal/personal` is tagged `membership: mesh` — under `--no-mesh` /
`MESH_NO_MESH=1` it is **omitted from the catalog** (not available for guests).

On a mesh node, select it in Blink / `selections.list` or pass
`--bundle personal/personal`. `MESH_IDENTITY_REPO` is collected by the menu (or
pre-seed for automation):

```bash
MESH_IDENTITY_REPO=git@github.com:youruser/mesh-identity.git \
  bash setup.sh --non-interactive --bundle personal/personal
```

Optional: `MESH_NPM_GLOBAL=1` to also configure npm globals. AI tooling is a
separate topic (`ai`), not part of this personal layer.

## Behavior (`apply.sh`)

1. `identity_ensure_repo`: if `$MESH_IDENTITY_DIR/.git` exists, `git pull --ff-only`;
   otherwise clone `$MESH_IDENTITY_REPO` into `$MESH_IDENTITY_DIR`
   (default `~/mesh-identity`).
2. If `$MESH_IDENTITY_DIR/install.sh` exists, run it (the identity repo's own thin
   deploy script — see its `deploy.map`).
3. Drift cleanup: read `data/uninstall.list` and remove artifacts the identity fork
   used to install but no longer ships (apt packages, brew casks, clones, plugin
   caches, binaries). Idempotent — see `data/uninstall.list` for syntax.

Marked `idempotent: true`: re-applied on every run; the fork's own `install.sh`
handles "already applied" fast paths. `verify` only checks the repo dir exists;
`rollback` is a no-op (never auto-removes your applied identity).

## SSH mesh enrollment

During mesh onboarding, after the identity repository is available, Mesh validates
`~/.ssh/id_ed25519.pub`, adds it to `ssh/authorized_keys` if absent, and commits and
pushes only that trust-list change to the identity branch's configured upstream.
Existing keys are never automatically revoked. Reinstalled hosts keep the old key
until the operator reviews/revokes it explicitly; a follow-up reports this policy.

New publication requires a clean identity checkout at its upstream HEAD. Dirty
files, unrelated unpublished commits, missing keys, restricted existing key entries,
and Git/auth/network failures produce a critical follow-up and fail this onboarding
step. A failed push keeps a recorded enrollment commit for a safe retry; concurrent
remote edits must be reconciled normally. No force push or automatic conflict
resolution occurs. No private keys are read or copied by the enrollment helper.

Recipients still need to pull/apply identity (`mesh update -o mesh-identity`).
An optional `ssh/peers.list` contains one SSH alias per line. After local identity
application, Mesh tests access using the local identity, without an agent, reused
connection or password fallback, and with strict host-key verification. Unknown
host keys, offline peers and unpropagated keys are explicitly **unconfirmed** in
the summary; the installer never claims remote delivery from a successful push.
Without an inventory it reports all peer delivery as unconfirmed. It does not
mutate remote hosts or disable SSH authentication to solve first-access bootstrap.

The `personal` bundle remains mesh-only. Engine dry-run does not execute it; the
helper also guards no-mesh/dry-run when called directly.
