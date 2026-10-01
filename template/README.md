# template/ — mesh-workstation identity scaffold

`mesh init --create-identity` copies this directory verbatim to
`$MESH_IDENTITY_DIR` (default `$HOME/mesh-identity`), then:

1. Strips the `.example` suffix from every regular file (`install.sh.example` → `install.sh`, etc.).
2. Substitutes three placeholders across all text files:
   - `__USER_NAME__`
   - `__USER_EMAIL__`
   - `__GH_USERNAME__`
3. Optionally runs `gh repo create $GH_USERNAME/mesh-identity --private --source ... --push`.
4. Runs `bash $MESH_IDENTITY_DIR/install.sh` to deploy files to `$HOME`.

## Parity contract (C16)

Every regular file in this directory **MUST** end in `.example` (lint
L11 enforces). Allowed exceptions: this README and any `.keep`
placeholder.

Structural drift between `template/` and an identity repo is detected by
`mesh template-check` (Phase 6 Task 6.4). The pre-commit hook installed
by `--install-hook` blocks identity commits that diverge from template
structure.

## Inventory (C13.4 — K4 rich curated content)

| File | Mode | Purpose |
|---|---|---|
| `install.sh.example` | deploy script | thin glue; calls `deploy_map deploy.map .` |
| `deploy.map.example` | deploy data | editable `src\|dst\|mode\|perms` set (add files here, not in code) |
| `CLAUDE.md.example` | agent rules | hard gate for template parity + repo routing |
| `shell/aliases.sh.example` | personal shell | git/ls/nav aliases (overwrite mode) |
| `git/gitconfig.local.example` | identity config | `[user]` block with placeholders (once mode) |
| `ssh/authorized_keys.example` | secrets | managed_block markers (0600) |
| `ssh/peers.list.example` | identity config | SSH aliases to verify after enrollment |
| `iterm2/font.json.example` | identity config | preferred terminal font size and ligatures |
| `config/tuios-hosts.json.example` | identity config | empty per-host browser terminal profile; no domain, email or credential |
| `.ai/memory/MEMORY.md.example` | agent memory index | empty index template |
| `.ai/memory/PROJECT_STATUS.md.example` | rollup dashboard | §1-§5 skeleton |

Add new template files only when introducing a corresponding identity
slot; the parity hook will reject identity changes that lack a template
counterpart.
