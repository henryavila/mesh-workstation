#!/usr/bin/env bash
# Private Node for the workstation menu. Not a catalog bundle, not fnm,
# and not written into shell rc. Callers source dx-profiles.sh first.
# shellcheck shell=bash

ensure_menu_node() {
    [[ "$(dx_profile_name)" == "workstation" ]] || return 0
    [[ "${NON_INTERACTIVE:-0}" == "1" ]] && return 0
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    command -v node >/dev/null 2>&1 && return 0
    local dest="$HOME/.local/share/mesh/menu-node"
    if [[ -x "$dest/bin/node" ]]; then
        export PATH="$dest/bin:$PATH"
        return 0
    fi
    command -v curl >/dev/null 2>&1 || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local ver arch osname tar url tmp
    ver="$(curl -fsSL --connect-timeout 8 --max-time 30 https://nodejs.org/dist/index.json \
        | python3 -c 'import json,sys
rels=json.load(sys.stdin)
for r in rels:
    if r.get("lts"):
        print(r["version"])
        break')" || return 0
    [[ -n "$ver" ]] || return 0
    case "$(uname -s)" in
        Linux) osname=linux ;;
        Darwin) osname=darwin ;;
        *) return 0 ;;
    esac
    case "$(uname -m)" in
        x86_64|amd64) arch=x64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) return 0 ;;
    esac
    tar="node-${ver}-${osname}-${arch}.tar.gz"
    url="https://nodejs.org/dist/${ver}/${tar}"
    tmp="$(mktemp -d)"
    if ! curl -fsSL --connect-timeout 8 --max-time 120 -o "$tmp/node.tgz" "$url"; then
        rm -rf "$tmp"
        return 0
    fi
    tar -xzf "$tmp/node.tgz" -C "$tmp" || { rm -rf "$tmp"; return 0; }
    rm -rf "$dest"
    mkdir -p "$(dirname "$dest")"
    mv "$tmp"/node-* "$dest"
    rm -rf "$tmp"
    export PATH="$dest/bin:$PATH"
}
