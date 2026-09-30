#!/usr/bin/env python3
"""Publish this host's public key to the identity trust list, then report peers."""
import argparse
import base64
import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import tempfile

class EnrollmentError(Exception):
    pass

def run(argv, cwd=None, timeout=45, check=True):
    env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
    result = subprocess.run(argv, cwd=cwd, env=env, capture_output=True, text=True, timeout=timeout)
    if check and result.returncode:
        raise EnrollmentError(f'{argv[0]} {argv[1]} failed: {result.stderr.strip()}')
    return result

def git(repo, *args, check=True):
    return run(['git', '-C', str(repo), *args], check=check).stdout.strip()

def followup(level, message):
    print(f'[ssh-enroll] {message}', flush=True)
    target = os.environ.get('MESH_FOLLOWUP_FILE')
    if target:
        with open(target, 'a') as out:
            out.write(level + '\x1f' + message + '\x1e')

def key_presence(text, key):
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        try:
            tokens = shlex.split(line)
        except ValueError:
            continue
        for index in range(len(tokens) - 1):
            if tokens[index:index + 2] == key:
                return 'plain' if index == 0 else 'restricted'
    return 'missing'

def public_key(path):
    lines = path.read_text().strip().splitlines()
    if len(lines) != 1 or len(lines[0].split()) < 2:
        raise EnrollmentError('expected exactly one public SSH key')
    key = lines[0].split()[:2]
    if not (key[0].startswith('ssh-') or key[0].startswith('ecdsa-') or key[0].startswith('sk-')):
        raise EnrollmentError('unsupported public key format; private keys are never enrolled')
    run(['ssh-keygen', '-lf', str(path)])
    return key

def atomic_write(path, text):
    fd, staging = tempfile.mkstemp(prefix='.mesh-enroll-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as out:
            out.write(text)
        os.chmod(staging, 0o600)
        os.replace(staging, path)
    finally:
        if os.path.exists(staging):
            os.unlink(staging)

def author_options(repo):
    if (run(['git', '-C', str(repo), '-c', 'user.useConfigOnly=true', 'var', 'GIT_AUTHOR_IDENT'], check=False).returncode == 0
            and run(['git', '-C', str(repo), '-c', 'user.useConfigOnly=true', 'var', 'GIT_COMMITTER_IDENT'], check=False).returncode == 0):
        return []
    # On fresh hosts personal/apply precedes the git bundle. Read only the
    # personalized author values, without sourcing arbitrary shell/config hooks.
    identity_config = repo / 'git/gitconfig.local'
    values = []
    for field in ('name', 'email'):
        value = git(repo, 'config', '--file', str(identity_config), '--get', 'user.' + field, check=False)
        if not value or '\n' in value or re.search(r'__[A-Z_]+__', value):
            raise EnrollmentError('Git author identity is not configured; set user.name/user.email or personalize git/gitconfig.local before retrying')
        values += ['-c', 'user.' + field + '=' + value]
    return values

def select_public_key(home):
    for name in ('id_ed25519.pub', 'id_rsa.pub'):
        candidate = home / '.ssh' / name
        if candidate.is_file():
            return candidate
    return home / '.ssh/id_ed25519.pub'

def enroll(repo, pub, host):
    repo = repo.resolve()
    key = public_key(pub)
    target = repo / 'ssh/authorized_keys'
    if target.is_symlink() or not target.is_file():
        raise EnrollmentError('identity must contain a regular ssh/authorized_keys file')
    gitdir = Path(git(repo, 'rev-parse', '--absolute-git-dir'))
    with open(gitdir / 'mesh-ssh-enroll.lock', 'a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise EnrollmentError('another SSH enrollment is running; retry when it finishes')
        branch = git(repo, 'symbolic-ref', '--quiet', '--short', 'HEAD')
        remote = git(repo, 'config', '--get', f'branch.{branch}.remote')
        merge = git(repo, 'config', '--get', f'branch.{branch}.merge')
        if remote in ('', '.') or remote.startswith('-') or not merge.startswith('refs/heads/'):
            raise EnrollmentError('identity branch needs a writable remote upstream')
        git(repo, 'fetch', remote)
        upstream = git(repo, 'rev-parse', '--symbolic-full-name', '@{upstream}')
        remote_head = git(repo, 'rev-parse', upstream)
        head = git(repo, 'rev-parse', 'HEAD')
        text = target.read_text()
        local_state = key_presence(text, key)
        remote_text = git(repo, 'show', f'{upstream}:ssh/authorized_keys')
        remote_state = key_presence(remote_text, key)
        if 'restricted' in (local_state, remote_state):
            raise EnrollmentError('this public key has authorization options; refusing to broaden its permissions automatically')
        has_placeholder = '__REPLACE_WITH_YOUR_PUBLIC_KEY__' in text
        if local_state == remote_state == 'plain' and not has_placeholder:
            followup('info', 'Current public key is already enrolled and confirmed on the identity upstream.')
            return
        if git(repo, 'status', '--porcelain'):
            raise EnrollmentError('identity checkout has pending changes; commit/stash them before retrying enrollment (nothing was published)')
        pending = gitdir / 'mesh-ssh-enroll-pending.json'
        if local_state == 'plain' and not has_placeholder:
            state = json.loads(pending.read_text()) if pending.exists() else {}
            if state.get('commit') != head or state.get('remote') != remote or state.get('ref') != merge:
                raise EnrollmentError('local key is not published and HEAD is not the recorded enrollment commit; publish the reviewed identity changes first')
            if git(repo, 'rev-parse', 'HEAD^') != remote_head:
                raise EnrollmentError('upstream changed after enrollment; reconcile the identity branch, then retry')
        else:
            if head != remote_head:
                raise EnrollmentError('identity branch is ahead/behind upstream; reconcile it before automatic enrollment')
            author = author_options(repo)
            safe_host = re.sub(r'[^A-Za-z0-9._-]', '-', host)[:100] or 'host'
            cleaned = '\n'.join(line for line in text.splitlines()
                                if line.split()[:2] != ['ssh-ed25519', 'AAAA__REPLACE_WITH_YOUR_PUBLIC_KEY__'])
            if '__REPLACE_WITH_YOUR_PUBLIC_KEY__' in cleaned:
                raise EnrollmentError('unexpected SSH placeholder format; refusing to publish an uninitialized trust list')
            suffix = '' if local_state == 'plain' else f'\n# mesh-host: {safe_host}\n' + ' '.join(key) + f' mesh:{safe_host}\n'
            proposed = cleaned.rstrip('\n') + '\n' + suffix
            atomic_write(target, proposed)
            followup('manual', 'Added/initialized the current host key; all previous real keys were retained. After a reinstall, review obsolete keys in ssh/authorized_keys before revoking them.')
            # The original checkout was clean. If our commit fails, undo only
            # our unchanged edit; preserve any additional edits made by hooks.
            try:
                git(repo, 'add', '--', 'ssh/authorized_keys')
                git(repo, *author, 'commit', '--only', '-m', f'feat(ssh): enroll {safe_host} public key', '--', 'ssh/authorized_keys')
            except EnrollmentError:
                if git(repo, 'rev-parse', 'HEAD') == head and target.read_text() == proposed:
                    git(repo, 'restore', '--staged', '--', 'ssh/authorized_keys')
                    atomic_write(target, text)
                raise
            head = git(repo, 'rev-parse', 'HEAD')
            atomic_write(pending, json.dumps({'commit': head, 'remote': remote, 'ref': merge}))
        git(repo, 'push', remote, f'{head}:{merge}')
        git(repo, 'fetch', remote)
        if key_presence(git(repo, 'show', f'{upstream}:ssh/authorized_keys'), key) != 'plain':
            raise EnrollmentError('push completed but upstream key readback failed; enrollment remains unconfirmed')
        if pending.exists():
            pending.unlink()
        followup('info', 'Current public key was committed, published and confirmed on the identity upstream.')

def report_peers(repo, pub):
    inventory = repo / 'ssh/peers.list'
    if not inventory.exists():
        followup('manual', 'Peer delivery is unconfirmed: run mesh update -o mesh-identity on each destination. Optional ssh/peers.list (one SSH alias per line) enables access checks.')
        return
    peers = []
    for line in inventory.read_text().splitlines():
        alias = line.split('#', 1)[0].strip()
        if not alias:
            continue
        if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', alias):
            raise EnrollmentError('ssh/peers.list contains an invalid SSH alias')
        if alias not in peers:
            peers.append(alias)
    if len(peers) > 32:
        raise EnrollmentError('ssh/peers.list exceeds 32 peers')
    if not peers:
        followup('manual', 'No peers listed; destination enrollment is unconfirmed.')
    private_path = str(pub)[:-4] if str(pub).endswith('.pub') else ''
    if not private_path or not Path(private_path).is_file():
        followup('manual', 'Cannot verify peers without the matching local identity file; no remote access was tested.')
        return
    key = public_key(pub)
    expected_fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(base64.b64decode(key[1])).digest()).decode().rstrip('=')
    for alias in peers:
        try:
            result = run(['ssh', '-v', '-oBatchMode=yes', '-oConnectTimeout=4', '-oConnectionAttempts=1',
                          '-oStrictHostKeyChecking=yes', '-oIdentitiesOnly=yes', '-oIdentityAgent=none',
                          '-oPreferredAuthentications=publickey', '-oPasswordAuthentication=no',
                          '-oControlMaster=no', '-oControlPath=none', '-i', private_path,
                          alias, 'true'], timeout=8, check=False)
            # IdentityFile options accumulate across config and CLI. A successful
            # connection alone can therefore prove the wrong key; inspect the
            # final accepted-key fingerprint from OpenSSH's authentication log.
            accepted_lines = [line for line in result.stderr.splitlines() if 'Server accepts key:' in line]
            accepted = (result.returncode == 0 and bool(accepted_lines)
                        and expected_fingerprint in accepted_lines[-1].split())
        except subprocess.TimeoutExpired:
            accepted = False
        if accepted:
            followup('info', f'{alias}: SSH access with the current host key is confirmed.')
        else:
            followup('critical', f'{alias}: SSH access with the current key is NOT confirmed. On that device, run mesh update -o mesh-identity using local access or another authorized session; then retry. Offline hosts, unknown host keys and policy restrictions can also prevent verification.')

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--repo', type=Path, required=True)
    parser.add_argument('--public-key', type=Path, default=select_public_key(Path.home()))
    parser.add_argument('--host', default=socket.gethostname().split('.')[0])
    parser.add_argument('--report-peers', action='store_true')
    args = parser.parse_args()
    if os.environ.get('NO_MESH') == '1' or os.environ.get('MESH_NO_MESH') == '1' or os.environ.get('DRY_RUN') == '1':
        print('[ssh-enroll] skipped (no-mesh or dry-run)')
        return 0
    try:
        if args.report_peers:
            report_peers(args.repo, args.public_key)
        else:
            enroll(args.repo, args.public_key, args.host)
    except (EnrollmentError, OSError, ValueError, subprocess.SubprocessError) as error:
        followup('critical', f'SSH mesh onboarding incomplete: {error}. Re-run setup after resolving this condition.')
        return 1
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
