#!/usr/bin/env bash
# scripts/lib/uninstall-handlers.sh — shared uninstall verb handlers.
#
# Single source of truth for all uninstall operations. Consumed by:
#   - topic-cleanup.sh (verb:arg manifest format, topic-level drift)
#   - uninstall-engine.sh (YAML-driven, item-level removal from menu)
#
# Each handler is idempotent: silent when the artifact is absent,
# emits an `info` line only when it actually removes something, and
# downgrades any sub-failure to a `warn` (never aborts the caller).
#
# Depends on: log.sh (info, warn) already sourced by callers.

# shellcheck shell=bash

# ─── Sandbox helper ─────────────────────────────────────────────────
_sandbox_name() {
    local verb="$1" arg="$2"
    case "$arg" in
        */*|*..*|"")
            warn "uninstall-handlers: $verb:$arg rejected by sandbox (no slashes, no '..')"
            return 1 ;;
    esac
    return 0
}

# ─── Package manager handlers (migrated from topic-cleanup.sh) ──────

_uninstall_apt() {
    [[ "$(uname -s)" == Linux* ]] || return 0
    local pkg="$1"
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        info "uninstall apt:$pkg (purge + autoremove)"
        sudo apt-get purge -y -qq "$pkg" 2>&1 \
            | sed 's/^/    /' \
            || warn "apt purge $pkg failed"
        sudo apt-get autoremove -y -qq 2>&1 \
            | sed 's/^/    /' \
            || true
    fi
}

_uninstall_brew() {
    [[ "$(uname -s)" == Darwin* ]] || return 0
    local formula="$1"
    local brew_bin="${BREW_BIN:-$(command -v brew 2>/dev/null || true)}"
    [[ -n "$brew_bin" ]] || { warn "uninstall brew:$formula skipped — brew not found"; return 0; }
    if "$brew_bin" list --formula "$formula" >/dev/null 2>&1; then
        info "uninstall brew:$formula (--ignore-dependencies)"
        "$brew_bin" uninstall --ignore-dependencies "$formula" 2>&1 \
            | sed 's/^/    /' \
            || warn "brew uninstall $formula failed"
    fi
}

_uninstall_brew_cask() {
    [[ "$(uname -s)" == Darwin* ]] || return 0
    local cask="$1"
    local brew_bin="${BREW_BIN:-$(command -v brew 2>/dev/null || true)}"
    [[ -n "$brew_bin" ]] || { warn "uninstall brew-cask:$cask skipped — brew not found"; return 0; }
    if "$brew_bin" list --cask "$cask" >/dev/null 2>&1; then
        info "uninstall brew-cask:$cask"
        "$brew_bin" uninstall --cask "$cask" 2>&1 \
            | sed 's/^/    /' \
            || warn "brew uninstall --cask $cask failed"
    fi
}

# ─── Filesystem handlers (migrated from topic-cleanup.sh) ───────────

_uninstall_clone() {
    local name="$1"
    _sandbox_name "clone" "$name" || return 0
    local dir="$HOME/.local/share/$name"
    if [[ -d "$dir" ]]; then
        info "uninstall clone:$name ($dir)"
        rm -rf "$dir"
    fi
}

_uninstall_zinit() {
    local spec="$1"
    case "$spec" in
        */*) ;;
        *)
            warn "uninstall-handlers: zinit:$spec malformed (expected owner/repo)"
            return 0 ;;
    esac
    case "$spec" in
        *..*|*//*|/*)
            warn "uninstall-handlers: zinit:$spec rejected by sandbox"
            return 0 ;;
    esac
    local mangled="${spec//\//---}"
    local dir="$HOME/.local/share/zinit/plugins/$mangled"
    if [[ -d "$dir" ]]; then
        info "uninstall zinit:$spec ($dir)"
        rm -rf "$dir"
    fi
}

_uninstall_user_bin() {
    local name="$1"
    _sandbox_name "user-bin" "$name" || return 0
    local f="$HOME/.local/bin/$name"
    if [[ -e "$f" ]]; then
        info "uninstall user-bin:$name ($f)"
        rm -f "$f"
    fi
}

_uninstall_sys_bin() {
    local name="$1"
    _sandbox_name "sys-bin" "$name" || return 0
    local f="/usr/local/bin/$name"
    if [[ -e "$f" ]]; then
        info "uninstall sys-bin:$name ($f) — needs sudo"
        sudo rm -f "$f" || warn "sudo rm $f failed"
    fi
}

# ─── New handlers (for menu item-level uninstall) ────────────────────

_uninstall_npm_global() {
    local pkg="$1"
    if npm list -g "$pkg" >/dev/null 2>&1; then
        info "uninstall npm-global:$pkg"
        npm uninstall -g "$pkg" 2>&1 \
            | sed 's/^/    /' \
            || warn "npm uninstall -g $pkg failed"
    fi
}

_uninstall_cargo() {
    local pkg="$1"
    # here-string (not `cargo install --list | grep -q`): the uninstall engine
    # runs under `set -o pipefail` and cargo is a Rust binary that panics (exit
    # 101) on EPIPE once grep -q closes the pipe on the match — a false "not
    # installed" that skips the uninstall. The substitution captures cargo's
    # full output first, so cargo is never piped to grep. (L21; same class as F-D.)
    if grep -q "^${pkg} " <<<"$(cargo install --list 2>/dev/null)"; then
        info "uninstall cargo:$pkg"
        cargo uninstall "$pkg" 2>&1 \
            | sed 's/^/    /' \
            || warn "cargo uninstall $pkg failed"
    fi
}

_uninstall_pip() {
    local pkg="$1"
    if pip show "$pkg" >/dev/null 2>&1; then
        info "uninstall pip:$pkg"
        pip uninstall -y "$pkg" 2>&1 \
            | sed 's/^/    /' \
            || warn "pip uninstall $pkg failed"
    fi
}

_uninstall_npx() {
    local spec="$1"
    local pkg="${spec%% *}"
    info "uninstall npx:$pkg"
    if command -v npx >/dev/null 2>&1; then
        npx -y "$pkg" uninstall </dev/null >/dev/null 2>&1 || true
    fi
    case "$pkg" in
        *claude-mem*)
            if command -v claude >/dev/null 2>&1; then
                claude plugin uninstall claude-mem@thedotmack </dev/null >/dev/null 2>&1 || true
                claude plugin marketplace remove thedotmack </dev/null >/dev/null 2>&1 || true
            fi
            pkill -f "worker-service.cjs" 2>/dev/null || true
            pkill -f "chroma-mcp.*claude-mem" 2>/dev/null || true
            pkill -f "mcp-server.cjs" 2>/dev/null || true
            local dir="$HOME/.claude-mem"
            [[ -d "$dir" ]] && rm -rf "$dir" 2>/dev/null || true
            rm -f "$HOME/.local/bin/claude-mem" 2>/dev/null || true
            ;;
    esac
}
