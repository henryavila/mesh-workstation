#!/usr/bin/env bash
# Regression: sudo prompts must work through setup.sh's tee pipeline.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WS="$(cd "$HERE/../.." && pwd)"
python3 - "$WS" <<'PYTHON'
import os, pty, subprocess, tempfile
from pathlib import Path
import sys
s=(Path(sys.argv[1])/'scripts/lib/deploy.sh').read_text()
block=s[s.index('if [[ "$sudo_needed" -eq 1 ]]; then'):s.index('# ---------- Deploy each file ----------')]
harness='''set -euo pipefail
info() { echo "$*"; }
fail() { echo "$*" >&2; }
sudo() {
  printf '%s\\n' "$*" >> "$CALLS"
  case "$*" in
    '-n true') return "$FAST" ;;
    '-v') [[ -t 0 ]] || return 98; return "$AUTH" ;;
    *) return 99 ;;
  esac
}
sudo_needed=1
'''+block+'\necho DEPLOY_ALLOWED\n'
cases=[('cached headless',False,'0','0','0',0,False,''),('piped interactive',True,'0','1','0',0,True,''),('denied interactive',True,'0','1','1',1,True,'failed or was cancelled'),('noninteractive tty',True,'1','1','0',1,False,'NON_INTERACTIVE=1'),('no terminal',False,'0','1','0',1,False,'no controlling terminal'),('cached noninteractive',False,'1','0','0',0,False,'')]
with tempfile.TemporaryDirectory() as td:
  for name,tty,ni,fast,auth,expected,prompt,diagnostic in cases:
    calls=Path(td)/'calls'; calls.write_text('')
    env=dict(os.environ,NON_INTERACTIVE=ni,FAST=fast,AUTH=auth,CALLS=str(calls))
    if tty:
      # Parent has a controlling PTY; nested subprocess pipes stdout exactly
      # like the installer logger, while retaining that controlling terminal.
      out=Path(td)/'out'
      pid,master=pty.fork()
      if pid==0:
        r=subprocess.run(['/bin/bash','-c',harness],env=env,capture_output=True,text=True,timeout=5)
        out.write_text(r.stdout+r.stderr)
        os._exit(r.returncode)
      _,status=os.waitpid(pid,0); os.close(master)
      rc=os.waitstatus_to_exitcode(status); output=out.read_text()
    else:
      r=subprocess.run(['/bin/bash','-c',harness],env=env,capture_output=True,text=True,start_new_session=True,timeout=5)
      rc=r.returncode; output=r.stdout+r.stderr
    assert rc==expected,(name,rc,output)
    assert ('-v' in calls.read_text().splitlines())==prompt,(name,calls.read_text())
    assert ('DEPLOY_ALLOWED' in output)==(expected==0),(name,output)
    assert diagnostic in output,(name,output)
    print('PASS:',name)

PYTHON
