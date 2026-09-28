# mesh-workstation

[![smoke-test](https://github.com/henryavila/mesh-workstation/actions/workflows/smoke-test.yml/badge.svg)](https://github.com/henryavila/mesh-workstation/actions/workflows/smoke-test.yml)
[![lint](https://github.com/henryavila/mesh-workstation/actions/workflows/lint.yml/badge.svg)](https://github.com/henryavila/mesh-workstation/actions/workflows/lint.yml)

Configuração reproduzível de máquinas de desenvolvimento em WSL2/Ubuntu, macOS e Windows (via WSL).

> **Idiomas:** [English](README.md) · Português (este arquivo)

Um dos dois repos de uma arquitetura em camadas:

| Repo | Papel | Visibilidade |
|------|-------|--------------|
| **mesh-workstation** (este) | Instala ferramentas e aplica configs opinionadas globais. Contém `template/` para scaffolding de identity. | público |
| `<user>/mesh-identity` | Dotfiles pessoais (identidade + overrides) | **privado** (por usuário) |

**Separação de responsabilidades:** o workstation instala CLI/daemons/stack e grava configs universais (bashrc, inputrc, gitconfig global, fragments em `~/.bashrc.d/`); o repo de identity aplica config pessoal + overrides em cima.

## Quickstart

Guia completo Windows → WSL (códigos de saída, fontes, systemd, troubleshooting):
**[docs/INSTALL-WINDOWS-WSL.md](docs/INSTALL-WINDOWS-WSL.md)** (em inglês).

### A. Host Windows (PowerShell como Admin) → Ubuntu

Máquina zerada (sem Git):

```powershell
irm https://raw.githubusercontent.com/henryavila/mesh-workstation/main/windows/install-wsl.ps1 -OutFile $env:TEMP\install-wsl.ps1
powershell -ExecutionPolicy Bypass -File $env:TEMP\install-wsl.ps1
```

Se o Git já existir:

```powershell
git clone https://github.com/henryavila/mesh-workstation "$env:USERPROFILE\mesh-workstation"
cd "$env:USERPROFILE\mesh-workstation"
powershell -ExecutionPolicy Bypass -File .\windows\install-wsl.ps1
```

| Saída | Significado |
|-------|-------------|
| `0` | Features WSL OK, Git + Windows Terminal instalados, Ubuntu-24.04 registrado |
| `2` | Precisa reboot — reinicie o Windows, rode o mesmo comando de novo |
| `1` | Falha dura (muitas vezes winget ausente — ver o guia de install) |

Abra o **Ubuntu** no menu Iniciar e crie o usuário Linux. O script do host **não**
instala a Nerd Font; isso acontece dentro do Ubuntu no setup
(`shell-terminal/fonts` → CaskaydiaCove + Catppuccin no Windows Terminal).

### B. Dentro do Ubuntu (ou Linux nativo / macOS)

**Fase 0** — só o necessário para clonar este repo:

| Plataforma | Pré-req único |
|---|---|
| WSL2 / Linux nativo | `sudo apt-get update && sudo apt-get install -y git curl ca-certificates` |
| macOS | Nada — Xcode CLT sob demanda na primeira chamada a `git` pelo `setup.sh` |

```bash
git clone https://github.com/henryavila/mesh-workstation ~/mesh-workstation
cd ~/mesh-workstation
bash setup.sh
```

**O que acontece**

1. **Primeira run (sem Node no PATH):** lean bootstrap — `foundation`, `git/config`,
   `shell-terminal` (incl. fonts), `languages/node`, `personal`. **Não** instala
   silenciosamente a frota default-on inteira. Identity ainda pode perguntar no TTY.
2. **Abra um shell novo** (para carregar os fragments do fnm no PATH).
3. **Segunda run:** `bash setup.sh` abre o menu **Blink** — escolha bundles
   (`web/valet`, `databases/mysql`, `ai/claude-code`, …), confirme, aplique.

> Nota histórica: releases antigas usavam checklist `whiptail` sobre topics
> numerados `00-*` / `60-web-stack`. Essa UX sumiu; não trate ids numerados nem
> `INCLUDE_*=1` como o caminho de produto atual.

**Modo convidado / servidor (`--no-mesh`)** — instalar ferramentas sem entrar na mesh:

```bash
# picker interativo sem bundles de membership
bash setup.sh --no-mesh
mesh menu --no-mesh

# headless: só foundation/base (depois adicione bundles explicitamente)
NON_INTERACTIVE=1 bash setup.sh --no-mesh
bash setup.sh --no-mesh --non-interactive --bundle languages/php

# inspecionar o catálogo filtrado
bash setup.sh --no-mesh --list-bundles
```

Sob `--no-mesh` / `MESH_NO_MESH=1`:

- Cinco bundles `membership: mesh` são **omitidos do catálogo** (removidos, não
  acinzentados): `personal/personal`, `identity/identity`, `syncthing/syncthing`,
  `remote-access/tailscale`, `remote-access/code-server`.
- Lista de unlock (`git/config`, `shell-terminal/cli-tools`, `shell-terminal/zsh`)
  perde locks required e começa **desmarcada**.
- Default headless sem `--bundle` é **só** `foundation/base`.
- O apply do engine **aborta com nonzero** (fail-closed) se algum bundle de
  membership reaparecer na seleção/closure resolvida.
- `atuin-login` é **no-op**.
- O caminho **sem flag** ainda mantém `personal` / `identity` como locks
  required junto de `foundation/base` e da lista de unlock.

**Atuin: guarde a chave de criptografia.** Após instalar o Atuin, o Mesh mostra
essa orientação e a repete no resumo final, mesmo se o login ficar para depois.
Na máquina que já sincroniza, execute `atuin key` e guarde a chave em um campo
protegido no **Keeper** (ou outro gerenciador de senhas), junto do usuário e da
senha. Na máquina nova, execute `atuin login -u SEU_USUARIO`, informe a senha e
**a mesma chave** nos prompts e rode `atuin sync`. O login não usa OAuth pelo
navegador. Apenas para uma primeira conta, use `atuin register -u SEU_USUARIO
-e SEU_EMAIL` e depois `atuin key`, guardando a chave imediatamente. O Mesh não
faz backup automático dessa chave; se todas as cópias forem perdidas, o servidor
não poderá recuperá-la. Não coloque a chave no Git, em chats ou logs de instalação.
`--no-mesh` pula essa orientação de sincronização.

**Modo automação / CI** (sem menu — env vars e flags):

```bash
# ver plano sem executar
bash setup.sh --dry-run

# pular menu mesmo em TTY
NON_INTERACTIVE=1 bash setup.sh
bash setup.sh --non-interactive

# listar todo topic/bundle + marca default
bash setup.sh --list-bundles

# seleção headless sem menu (repetível)
bash setup.sh --non-interactive --bundle languages/php --bundle databases/mysql
```

O menu é pulado automaticamente quando: (a) `NON_INTERACTIVE=1` ou `--non-interactive`; (b) stdin/stdout não é TTY (pipe, cron, CI); (c) um ou mais `--bundle` foram passados.
Logo após o menu (ou imediatamente, quando pulado), o bootstrap roda `sudo -v` pra warmup do cache — uma única prompt de senha, e as chamadas `sudo` subsequentes dentro da janela do cache (~5–15min) são silenciosas.

## Topics

Catálogo vivo em `topics/<id>/` (sem numeração). Selecione bundles no Blink,
`selections.list`, ou `--bundle topic/bundle`. Lista completa:
`bash setup.sh --list-bundles`.

| Topic | Bundles de exemplo | Notas |
|-------|--------------------|-------|
| `foundation` | `foundation/base` | Pacotes core (git, curl, jq, envsubst, …) |
| `languages` | `languages/node`, `languages/php` | Node via fnm, multi-PHP, Python |
| `shell-terminal` | `shell-terminal/cli-tools`, `shell-terminal/zsh`, `shell-terminal/tmux` | fzf/bat/eza/starship/atuin, zsh+completions, tmux |
| `git` | `git/config`, `git/lazygit`, `git/gpg-signing` | gitconfig global + aliases de shell |
| `web` | `web/valet`, `web/nginx-php-fpm`, `web/mailpit`, `web/ngrok` | Stack HTTPS local / nginx+PHP-FPM |
| `databases` | `databases/mysql`, `databases/redis`, `databases/postgresql` | Servidores DB + drivers |
| `containers` | `containers/docker` | Docker / Colima |
| `remote-access` | `remote-access/ssh`, `remote-access/mosh`, `remote-access/tailscale`, `remote-access/code-server` | `tailscale` + `code-server` são `membership: mesh` |
| `syncthing` | `syncthing/syncthing` | Sync P2P — `membership: mesh` |
| `identity` | `identity/identity` | gh + identidade SSH da máquina — `membership: mesh` |
| `personal` | `personal/personal` | Clone/apply mesh-identity — `membership: mesh` |
| `ai` | `ai/claude-code`, `ai/mdprobe`, `ai/atomic-skills`, `ai/rtk` | CLI de agente + ferramentas de workflow |

Cada topic tem o próprio `README.md` (exceto dirs finos de membership que
apontam pro manifesto). Bundles em `topics/*/manifest.yaml`; o engine aplica
itens selecionados e faz deploy de `topics/<id>/templates/`.

## HTTPS `*.localhost` no Windows

Bloco canônico (sintoma / causa / fix):
[`topics/web/README.md` — HTTPS that works](topics/web/README.md#https-that-works).

**Sintoma:** Chrome/Edge no Windows com `NET::ERR_CERT_AUTHORITY_INVALID` em
`https://<projeto>.localhost` depois do install. Não instale o certificado à
mão.

**Fix** — na raiz do clone:

```bash
bash topics/web/scripts/diagnose-wsl-interop.sh
```

Imprime o comando exato de PowerShell (lado Windows) para importar a CA mkcert.
Rode essa linha no Windows, feche o browser por completo e reabra.

## Env vars e flags CLI

Primariamente para automação / CI — o menu interativo preenche essas vars pro uso humano. Qualquer env var pré-existente vence os defaults do menu.

| Var / flag | Efeito |
|------------|--------|
| `--non-interactive` / `NON_INTERACTIVE=1` | Pula menu mesmo em TTY |
| `--dry-run` / `DRY_RUN=1` | Imprime o que rodaria sem executar (também pula `sudo -v`) |
| `--list-bundles` | Lista cada `topic/bundle` e sua marca default (required / default on / opt-in) |
| `--no-mesh` / `MESH_NO_MESH=1` | Omite os cinco bundles `membership: mesh` (remove, não acinzenta); unlock `git/config` + `shell-terminal/cli-tools` + `shell-terminal/zsh` (desmarcados); default headless só `foundation/base`; apply fail-closed; `atuin-login` no-op |
| `--bundle topic/bundle` | Adiciona um bundle à seleção headless (repetível; implica non-interactive) |
| `--help` / `-h` | Mensagem de uso |
| `SKIP_TOPICS` | hatch de CI: ids de topic separados por espaço removidos da seleção resolvida |
| `ONLY_TOPICS` | **Legacy / dead no v2 `setup.sh`** — não é API de seleção; use `--bundle`, o menu Blink ou `selections.list` |
| `MESH_IDENTITY_REPO` | URL/path do repo dotfiles pessoal (aceita `file://` para testes locais) |
| `MESH_IDENTITY_DIR` | destino do clone (default `~/mesh-identity`) |
| `GIT_NAME` / `GIT_EMAIL` | identidade — aplicada só se `user.name` / `user.email` ainda não existem |
| `CODE_DIR` | dev root — onde seus repos ficam (default `~/code`); auto-cd no shell + raiz de sites do web stack |
| `INCLUDE_WEBSTACK` / `INCLUDE_REMOTE` / `INCLUDE_EDITOR` | **Legacy** — preferir Blink / `--bundle` / `selections.list` |
| `NO_COLOR=1` | desabilita output colorido (auto se não for TTY) |

## Notas sobre MySQL 8

- **WSL**: instala `mysql-server-8.0` explicitamente — não o meta `mysql-server`, que pode resolver pra MariaDB em alguns derivados do Debian.
- **Mac**: formula `mysql@8.0` do brew (a formula `mysql` default acompanha 9.x). Como `mysql@8.0` é keg-only, o installer roda `brew link --force --overwrite mysql@8.0` pra colocar `mysql` / `mysqladmin` / `mysqldump` no `$PATH`.
- **Escape hatch no Mac**: se `brew install mysql@8.0` falhar por qualquer razão, instale via [instalador DMG da Oracle](https://dev.mysql.com/downloads/mysql/) (os binários vão pra `/usr/local/mysql`). O bootstrap detecta esse path e pula o brew automaticamente.

## Logs

Saída completa de cada execução vai pra `/tmp/mesh-workstation-<os>-<timestamp>.log`. O bootstrap imprime o path no início.

## Estrutura do projeto

```
mesh-workstation/
├── setup.sh                  # runner — OS detect, menu Blink, sudo warmup, engine
├── scripts/lib/              # detect-os, deploy, log, install-engine, …
├── topics/<nome>/            # unidades idempotentes (manifest.yaml + scripts)
│   ├── manifest.yaml
│   ├── templates/            # arquivos deployados via deploy driver
│   └── README.md
├── windows/install-wsl.ps1   # bootstrap Windows → WSL2 + Git + Windows Terminal
├── docs/SPEC.md              # especificação técnica
└── .github/workflows/        # CI
```

## Releases

| Tag | Destaques |
|-----|-----------|
| `v2026-04-19` | Enriqueceu `~/.inputrc` (word-kill, completion niceties) + novo `topics/50-git/templates/bashrc.d-50-git.sh` com aliases `g`/`gs`/`gco`/`whoops`/`gmm` + `__git_complete` (bash). |
| `v2026-04-20` | Topic `80-claude-code` split em `install.wsl.sh` / `install.mac.sh`; **instala Syncthing daemon** pro Claude Sync cross-machine (folder `claude/` no dotfiles-template usa `.stignore` pra controlar o que replica). |
| `v2026-04-21` | Topic `70-remote-access` automatiza o fix Tailscale MTU via drop-in `/etc/systemd/system/tailscaled.service.d/mtu.conf` (Linux). Mac tem `scripts/mac-tailscale-mtu-fix.sh` on-demand. Hotfixes: fix TOML scope do starship, `sudo -v` warmup no início do bootstrap, remoção de legacy `/etc/sudoers.d/10-${USER}-nopasswd`. |
| `v2026-04-22` | **Menu interativo whiptail vira o novo default** (seleção de topics opt-in + git identity + paths); flags CLI `--non-interactive` e `--dry-run`. MySQL 8 pinado explicitamente (`mysql-server-8.0` WSL / `mysql@8.0` Mac) com escape hatch DMG Oracle. Topic `90-editor` repositioned: `typora-wait` faz interop WSL→Windows Typora via `wslpath -w` e usa `open -W -a Typora` no macOS (discovery via LaunchServices). |

### Disciplina de release

Mudanças estruturais (novo topic, mudança em `lib/`, `install.sh`, `setup.sh`) passam por:

1. Commit com **migration note** no corpo — *forks existentes que já rodaram X devem Y*. Tempo estimado, arquivos afetados, comando para aplicar.
2. Tag datada: `git tag -a v2026-MM-DD -m "resumo"`.
3. `gh release create v2026-MM-DD --notes-from-tag` pós-push.

Hotfixes sem mudança estrutural (bug em template, typo em README) usam commit normal sem tag.

## CI

- `.github/workflows/lint.yml` (Tier 1) — shellcheck + `bash -n` em todo push/PR.
- `.github/workflows/integration.yml` (Tier 2, previsto em v1.1) — roda `setup.sh` em matrix `ubuntu-22.04`, `ubuntu-24.04`, `macos-latest`, valida idempotência (2º run = noop) e executa `verify.sh` de cada topic.

## Dotfiles pessoais

Este repo **nunca** versiona configs pessoais (SSH, identidade git, aliases project-specific). Para isso, use [dotfiles-template](https://github.com/henryavila/dotfiles-template): clique *Use this template* no GitHub, marque o repo novo como **privado**, e deixe o menu interativo coletar `MESH_IDENTITY_REPO` ou seta via env var antes de rodar `setup.sh`.

## Contribuir

1. Adicionar topic novo: copiar a estrutura de `topics/00-core/`.
2. Idempotência obrigatória: segunda execução = no-op (`already installed`, `up to date`). CI valida.
3. Antes de abrir PR: `shellcheck topics/<topic>/*.sh` deve passar.

## Veja também

- [`docs/SPEC.md`](docs/SPEC.md) — especificação técnica (arquitetura, critérios de aceitação, roadmap).
- [`docs/ALIASES.md`](docs/ALIASES.md) — inventário dos aliases universais (shell + git) que todo dev que rodou o bootstrap recebe.
- `topics/<topic>/README.md` — customização e gotchas por topic.
- [`dotfiles-template`](https://github.com/henryavila/dotfiles-template) — o outro lado da camada: overrides pessoais.
