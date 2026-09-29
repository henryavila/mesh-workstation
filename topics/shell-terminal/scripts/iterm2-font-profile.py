#!/usr/bin/env python3
"""Manage an iTerm2 dynamic font profile without touching its cached plist."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import tempfile

GUID = "4e986b58-462f-5cbb-9506-aef64a908b48"
NAME = "Mesh — Nerd Font"
OWNER = "mesh-workstation/iterm2-font"
FONT = "CaskaydiaCoveNFM-Regular"

def resolve_font(name):
    cf = ctypes.CDLL('/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation')
    ct = ctypes.CDLL('/System/Library/Frameworks/CoreText.framework/CoreText')
    cf.CFStringCreateWithCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32]
    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
    cf.CFStringGetCString.restype = ctypes.c_bool
    cf.CFRelease.argtypes = [ctypes.c_void_p]
    ct.CTFontCreateWithName.argtypes = [ctypes.c_void_p, ctypes.c_double, ctypes.c_void_p]
    ct.CTFontCreateWithName.restype = ctypes.c_void_p
    ct.CTFontCopyPostScriptName.argtypes = [ctypes.c_void_p]
    ct.CTFontCopyPostScriptName.restype = ctypes.c_void_p
    string = cf.CFStringCreateWithCString(None, name.encode(), 0x08000100)
    font = ct.CTFontCreateWithName(string, 12, None)
    actual = ct.CTFontCopyPostScriptName(font)
    try:
        buf = ctypes.create_string_buffer(1024)
        if not cf.CFStringGetCString(actual, buf, len(buf), 0x08000100):
            raise ValueError('cannot read registered font name')
        return buf.value.decode()
    finally:
        for value in (actual, font, string):
            if value:
                cf.CFRelease(value)

def desired_profile(preferences, font, existing=None, settings=None):
    profiles = preferences.get('New Bookmarks', [])
    default = preferences.get('Default Bookmark Guid')
    parent = next((p for p in profiles if p.get('Guid') == default and p.get('Guid') != GUID), {})
    if default == GUID:
        previous = next((p for p in (existing or {}).get('Profiles', []) if p.get('Guid') == GUID), {})
        if not previous:
            previous = next((p for p in profiles if p.get('Guid') == GUID), {})
        parent = {'Normal Font': previous.get('Normal Font', '')}
        original_parent = previous.get('Dynamic Profile Parent GUID')
        if original_parent and original_parent != GUID:
            parent['Guid'] = original_parent
    size = re.search(r' ([0-9]+(?:\.[0-9]+)?)$', parent.get('Normal Font', ''))
    size = size.group(1) if size else '14'
    settings = settings or {}
    if 'font_size' in settings:
        value = settings['font_size']
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 6 <= value <= 96:
            raise ValueError('font_size must be a number between 6 and 96')
        size = format(value, 'g')
    if 'ligatures' in settings and not isinstance(settings['ligatures'], bool):
        raise ValueError('ligatures must be true or false')
    profile = {'Name': NAME, 'Guid': GUID, 'Normal Font': f'{font} {size}',
               'Non Ascii Font': f'{font} {size}', 'Use Non-ASCII Font': False}
    if 'ligatures' in settings:
        profile['ASCII Ligatures'] = settings['ligatures']
        profile['Non-ASCII Ligatures'] = settings['ligatures']
    if parent.get('Guid'):
        profile['Dynamic Profile Parent GUID'] = parent['Guid']
    return {'Mesh Managed': OWNER, 'Profiles': [profile]}

def configure(home, check=False, font=FONT, resolver=resolve_font):
    actual = resolver(font)
    if actual != font:
        raise ValueError(f'font {font} is not registered (macOS resolves it to {actual}); install font-caskaydia-cove-nerd-font first')
    prefs_path = home / 'Library/Preferences/com.googlecode.iterm2.plist'
    preferences = plistlib.loads(prefs_path.read_bytes()) if prefs_path.exists() else {}
    target = home / 'Library/Application Support/iTerm2/DynamicProfiles/mesh-font.json'
    if target.is_symlink():
        raise ValueError(f'refusing to replace symlink: {target}')
    exists = target.exists()
    existing = json.loads(target.read_text()) if exists else None
    known_profile = (isinstance(existing, dict) and list(existing) == ['Profiles']
                     and isinstance(existing.get('Profiles'), list) and len(existing['Profiles']) == 1
                     and isinstance(existing['Profiles'][0], dict)
                     and existing['Profiles'][0].get('Guid') == GUID
                     and existing['Profiles'][0].get('Name') == NAME)
    if exists and (not isinstance(existing, dict) or (existing.get('Mesh Managed') != OWNER and not known_profile)):
        raise ValueError(f'refusing to replace unmanaged profile: {target}')
    identity = Path(os.environ.get('MESH_IDENTITY_DIR', str(home / 'mesh-identity')))
    settings_path = identity / 'iterm2/font.json'
    settings = json.loads(settings_path.read_text()) if settings_path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError('iterm2/font.json must be a JSON object')
    expected = desired_profile(preferences, font, existing, settings)
    if existing and isinstance(existing.get('Profiles'), list):
        previous = next((p for p in existing['Profiles'] if p.get('Guid') == GUID), {})
        preserved = {k: v for k, v in previous.items() if k not in ('Dynamic Profile Parent GUID', 'Dynamic Profile Parent Name')}
        expected['Profiles'][0] = dict(preserved, **expected['Profiles'][0])
    if existing == expected:
        return target
    if check:
        raise ValueError('Mesh dynamic font profile is missing or out of date')
    target.parent.mkdir(parents=True, exist_ok=True)
    # Stage outside DynamicProfiles: iTerm2 parses every file in that directory.
    fd, staging = tempfile.mkstemp(prefix='.mesh-font-', dir=target.parent.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            json.dump(expected, out, ensure_ascii=False, indent=2)
            out.write('\n')
        os.chmod(staging, 0o644)
        os.replace(staging, target)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)
    return target

DEFAULT_LABEL = "com.mesh-workstation.iterm2-default"
DEFAULT_DOMAIN = "com.googlecode.iterm2"
DEFAULT_KEY = "Default Bookmark Guid"

# Runs from the user's root volume, never from an external repository mount.
DEFAULT_WORKER = r'''#!/bin/bash
# managed-by mesh-workstation: deferred iTerm2 default
set -euo pipefail
uid="$(id -u)"
if /usr/bin/pgrep -u "$uid" -x 'iTerm2|iTerm' >/dev/null; then
    exit 0
else
    rc=$?
    [[ "$rc" == 1 ]] || exit "$rc"
fi
/usr/bin/defaults write com.googlecode.iterm2 'Default Bookmark Guid' -string 4e986b58-462f-5cbb-9506-aef64a908b48 || exit $?
actual="$(/usr/bin/defaults read com.googlecode.iterm2 'Default Bookmark Guid')" || exit $?
[[ "$actual" == 4e986b58-462f-5cbb-9506-aef64a908b48 ]] || exit 1
# Remove the one-shot job only after readback succeeds. Failures retry next tick.
/bin/rm -f "$HOME/Library/LaunchAgents/com.mesh-workstation.iterm2-default.plist" || exit $?
/bin/launchctl bootout "gui/$uid/com.mesh-workstation.iterm2-default"
'''

def command(args):
    return subprocess.run(args, capture_output=True, text=True, timeout=10)

def atomic_managed_write(path, content, mode):
    if path.is_symlink():
        raise ValueError(f'refusing to replace symlink: {path}')
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, staging = tempfile.mkstemp(prefix='.mesh-default-', dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as out:
            out.write(content)
        os.chmod(staging, mode)
        os.replace(staging, path)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)

def ensure_default(home, check=False, run=command):
    prefs = home / 'Library/Preferences/com.googlecode.iterm2.plist'
    data = plistlib.loads(prefs.read_bytes()) if prefs.exists() else {}
    if data.get('LoadPrefsFromCustomFolder'):
        raise ValueError('custom iTerm2 preference folder is enabled; cannot manage its default via the local preference domain')
    current = run(['/usr/bin/defaults', 'read', DEFAULT_DOMAIN, DEFAULT_KEY])
    if current.returncode == 0 and current.stdout.strip() == GUID:
        return 'default'
    if check:
        worker = home / '.local/lib/mesh/iterm2-default.sh'
        agent = home / ('Library/LaunchAgents/' + DEFAULT_LABEL + '.plist')
        if worker.is_file() and not worker.is_symlink() and agent.is_file() and not agent.is_symlink():
            job = plistlib.loads(agent.read_bytes())
            expected = {'Label': DEFAULT_LABEL, 'ProgramArguments': ['/bin/bash', str(worker)],
                        'RunAtLoad': True, 'StartInterval': 10,
                        'EnvironmentVariables': {'HOME': str(home)},
                        'StandardErrorPath': str(home / '.local/state/mesh/iterm2-default.err')}
            if job == expected and worker.read_text() == DEFAULT_WORKER:
                loaded = run(['/bin/launchctl', 'print', 'gui/' + str(os.getuid()) + '/' + DEFAULT_LABEL])
                if loaded.returncode == 0:
                    return 'pending'
        raise ValueError('Mesh is neither the saved default nor scheduled by a valid loaded deferred job')
    running = run(['/usr/bin/pgrep', '-u', str(os.getuid()), '-x', 'iTerm2|iTerm'])
    if running.returncode not in (0, 1):
        raise ValueError('could not determine whether iTerm2 is running; no preference write attempted')
    if running.returncode == 1:
        result = run(['/usr/bin/defaults', 'write', DEFAULT_DOMAIN, DEFAULT_KEY, '-string', GUID])
        if result.returncode:
            raise ValueError('could not set the default iTerm2 profile: ' + result.stderr.strip())
        actual = run(['/usr/bin/defaults', 'read', DEFAULT_DOMAIN, DEFAULT_KEY])
        if actual.returncode or actual.stdout.strip() != GUID:
            raise ValueError('default iTerm2 profile did not pass readback verification')
        return 'default'
    worker = home / '.local/lib/mesh/iterm2-default.sh'
    agent = home / ('Library/LaunchAgents/' + DEFAULT_LABEL + '.plist')
    if worker.exists() and '# managed-by mesh-workstation: deferred iTerm2 default' not in worker.read_text():
        raise ValueError(f'refusing to replace unmanaged helper: {worker}')
    if agent.exists() and plistlib.loads(agent.read_bytes()).get('Label') != DEFAULT_LABEL:
        raise ValueError(f'refusing to replace unmanaged LaunchAgent: {agent}')
    state = home / '.local/state/mesh'
    state.mkdir(parents=True, exist_ok=True)
    atomic_managed_write(worker, DEFAULT_WORKER.encode(), 0o700)
    job = {'Label': DEFAULT_LABEL, 'ProgramArguments': ['/bin/bash', str(worker)],
           'RunAtLoad': True, 'StartInterval': 10,
           'EnvironmentVariables': {'HOME': str(home)},
           'StandardErrorPath': str(state / 'iterm2-default.err')}
    atomic_managed_write(agent, plistlib.dumps(job), 0o600)
    domain = 'gui/' + str(os.getuid())
    loaded = run(['/bin/launchctl', 'print', domain + '/' + DEFAULT_LABEL])
    if loaded.returncode:
        result = run(['/bin/launchctl', 'bootstrap', domain, str(agent)])
        if result.returncode:
            raise ValueError('could not schedule default profile update: ' + result.stderr.strip())
    return 'pending'

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    try:
        target = configure(Path.home(), args.check, os.environ.get('NF_PS_NAME', FONT))
        status = ensure_default(Path.home(), args.check)
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        parser.exit(1, f'iterm2-font: {error}\n')
    if args.check and status == 'pending':
        print('iTerm2: verified deferred default update; waiting for iTerm2 to close')
    if not args.check:
        print(f'iTerm2: verified font and wrote {target}')
        if status == 'pending':
            print(f'iTerm2: {NAME} will become the default automatically after iTerm2 is fully closed. The one-shot job checks every 10 seconds; no sessions are closed by Mesh.')
        else:
            print(f'iTerm2: {NAME} is now the saved default for new sessions (verified).')
        print('iTerm2: saved profile is ready; the active session font has not been verified or changed.')

if __name__ == '__main__':
    main()
