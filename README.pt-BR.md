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

### B. Linux / WSL, ou macOS

**Fase 0** — só o necessário para clonar este repo. O Homebrew entra depois, pelo `foundation`, dentro do `setup.sh`.

| Plataforma | Pré-req único |
|---|---|
| WSL2 / Linux nativo | `sudo apt-get update && sudo apt-get install -y git curl ca-certificates` |
| macOS | Command Line Tools, que trazem o `git`. O primeiro comando `git` abre o instalador da Apple quando elas faltam. |

```bash
git clone https://github.com/henryavila/mesh-workstation ~/mesh-workstation
cd ~/mesh-workstation
bash setup.sh
```

O clone pode ficar em outro volume. Entre nesse diretório e rode `bash setup.sh` de lá. O `~/.local/bin` entra no `PATH` no tópico de shell, então a primeira execução é `bash setup.sh`.

**O que acontece**

1. Num Mac sem Homebrew, um TTY pergunta se a instalação vai para um path separado. **Sim:** pede o path (Enter aceita `/Volumes/External/homebrew` quando esse volume está montado) e exporta `BREW_CUSTOM_PREFIX`. **Não:** exporta `BREW_CUSTOM_PREFIX=/opt/homebrew`. O foundation instala o Homebrew nesse prefixo mais tarde, na mesma execução. O `gh` ainda não existe nesse momento, então um aviso de API anônima do GitHub é esperado; o tópico `identity` instala o `gh` depois do Homebrew e abre o browser para o login.
2. Uma senha de `sudo` (`sudo -v`) aparece antes do menu. As chamadas seguintes ficam quietas na janela do cache (~5–15 min).
3. **Sem Node no PATH:** lean bootstrap — `foundation`, `identity`, `git/config`, `shell-terminal` (incl. fonts), `languages/node`, `personal`. A frota default-on inteira (bancos, web, AI, …) fica de fora até você marcar.
4. **Com Node já no PATH:** o menu Blink abre nesta primeira execução.
5. **Abra um shell novo** para carregar os fragments de PATH do fnm e do Homebrew.
6. **Próxima execução:** `bash setup.sh` abre o menu Blink — escolha bundles (`web/valet`, `databases/mysql`, `ai/claude-code`, …), confirme, aplique.

Uma workstation da mesh mantém `identity` e `personal` marcados. O menu pede `MESH_IDENTITY_REPO` (URL ou `owner/name`) e o dev root, `CODE_DIR` (default `~/code`). Aponte `CODE_DIR` para o diretório onde os repos devem morar — num disco externo, o diretório de código desse disco (por exemplo `/Volumes/External/code`).

> Nota histórica: releases antigas usavam checklist `whiptail` sobre topics
> numerados `00-*` / `60-web-stack`. Essa UX sumiu; não trate ids numerados nem
> `INCLUDE_*=1` como o caminho de produto atual.

#### Prefixo do Homebrew (macOS)

Num TTY, o `setup.sh` pergunta antes do menu e exporta `BREW_CUSTOM_PREFIX`. O foundation lê essa variável na hora de instalar. Defina a variável você mesmo para pular a pergunta — uma execução não interativa precisa disso, porque ela não pergunta.

| Situação | Prefixo |
|---|---|
| Interativo, nada definido, ainda sem `brew` | Pergunta "path separado?". Sim → pede o path e exporta. Não, ou resposta vazia/relativa → exporta `/opt/homebrew`. |
| `BREW_CUSTOM_PREFIX` já definido, ainda sem `brew` | Esse caminho. A pergunta é pulada. |
| Não interativo, variável ausente, ainda sem `brew` | `/opt/homebrew`. |
| Já existe um binário `brew` | Essa instalação. As execuções seguintes ficam nela. |

Path separado sem responder a pergunta — o prefixo que `scripts/lib/detect-brew.sh` reencontra mesmo com `brew` fora do `PATH`:

```bash
cd /caminho/do/mesh-workstation
BREW_CUSTOM_PREFIX=/Volumes/External/homebrew bash setup.sh
```

O último componente do caminho tem que ser `homebrew`, num volume montado em `/Volumes/External` (ou `/Volumes/External 1`, `/Volumes/External 2`, … quando o macOS desambigua o mount). O detector também olha `/opt/homebrew` e `/usr/local`. Um prefixo num volume cujo nome não começa com `External` fica invisível até o `brew` já estar no `PATH`; a execução seguinte tenta reinstalar e para porque o diretório não está vazio.

O instalador upstream do Homebrew sempre grava em `/opt/homebrew` (Apple Silicon) ou `/usr/local` (Intel). Um binário em qualquer um desses lugares vira o prefixo de todas as execuções seguintes, então o caminho externo se escolhe nesta primeira execução.

Prefixo custom compila a maior parte das formulae do fonte, porque os bottles não se relocam. A primeira workstation completa demora mais do que em `/opt/homebrew`. Num volume montado sem owners, LaunchAgents de usuário (Redis, Mailpit, Postgres, Syncthing) sobem pelo launch-wrapper no rootfs quando esses tópicos rodam. A pergunta impressa antes do menu lista os dois.

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

No macOS, coloque `BREW_CUSTOM_PREFIX` no mesmo comando. Uma execução não interativa sem a variável instala o Homebrew em `/opt/homebrew`:

```bash
BREW_CUSTOM_PREFIX=/Volumes/External/homebrew bash setup.sh --non-interactive
```

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
| `CODE_DIR` | dev root — onde seus repos ficam (default `~/code`; o menu pergunta na primeira execução). Auto-cd no shell + raiz de sites do web stack. Num disco externo, use o diretório de código desse disco (por exemplo `/Volumes/External/code`) |
| `BREW_CUSTOM_PREFIX` | macOS, só quando ainda não existe binário `brew`. Prefixo absoluto, por exemplo `/Volumes/External/homebrew`. O diretório tem que se chamar `homebrew` direto sob `/Volumes/External` (ou `/Volumes/External 1`, …) para a próxima execução achar o brew com o `PATH` vazio. Num TTY, o `setup.sh` pergunta e exporta essa variável. Defina-a para pular a pergunta. Não interativo sem a variável usa `/opt/homebrew`. Um `brew` já instalado vence essa variável |
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
