import json, os, pathlib, re, socket, subprocess, sys, tempfile, unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
class RemoteAuto(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = pathlib.Path(self.tmp.name)
        self.config = self.home/'config.yaml'
        self.original = 'bind-addr: 127.0.0.1:{port}\nauth: password\npassword: keep-this\ncert: false\n# keep comment\n'
    def tearDown(self): self.tmp.cleanup()
    def bash(self, code):
        env = dict(os.environ, HOME=str(self.home), ROOT=str(ROOT), CONFIG=str(self.config))
        return subprocess.run(['/bin/bash','-euo','pipefail','-c',code],env=env,capture_output=True,text=True,timeout=10)
    def allocate(self, port):
        return self.bash('source "$ROOT/scripts/lib/code-server-port.sh"; info() { echo "$*" >&2; }; code_server_owns_listener() { return 1; }; CODE_SERVER_CONFIG_FILE="$CONFIG"; CODE_SERVER_PORT='+str(port)+'; code_server_allocate_port; echo "$CODE_SERVER_PORT"')
    def test_busy_port_persists_preserves_password_and_reuses(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); listener.listen(); port=listener.getsockname()[1]
            self.config.write_text(self.original.format(port=port))
            r=self.allocate(port); self.assertEqual(r.returncode,0,r.stderr)
            selected=int(r.stdout.strip()); self.assertGreater(selected,port)
            expected=self.original.format(port=selected)
            self.assertEqual(self.config.read_text(),expected)
            self.assertEqual(self.config.stat().st_mode & 0o777,0o600)
            backups=list(self.home.glob('config.yaml.bak-port-*')); self.assertEqual(len(backups),1)
            self.assertEqual(backups[0].stat().st_mode & 0o777,0o600)
            self.assertEqual(backups[0].read_text(),self.original.format(port=port))
            self.assertEqual(self.allocate(selected).stdout.strip(),str(selected))
            self.assertEqual(self.config.read_text(),expected)
    def test_invalid_port_keeps_config(self):
        self.config.write_text('unchanged')
        r=self.allocate(70000); self.assertNotEqual(r.returncode,0); self.assertEqual(self.config.read_text(),'unchanged')
    def test_non_loopback_config_not_rewritten(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0)); listener.listen(); port=listener.getsockname()[1]
            self.config.write_text('bind-addr: 0.0.0.0:'+str(port))
            r=self.allocate(port); self.assertNotEqual(r.returncode,0); self.assertIn('0.0.0.0',self.config.read_text())
    def ownership(self,pids,parent):
        return self.bash('source "$ROOT/scripts/lib/code-server-port.sh"; CODE_SERVER_PORT=8080; CODE_SERVER_LABEL=test; launchctl() { echo "pid = 100"; }; lsof() { printf "%s\\n" "'+pids+'"; }; ps() { echo '+parent+'; }; code_server_owns_listener')
    def test_owned_listener_and_child(self):
        self.assertEqual(self.ownership('100','1').returncode,0)
        self.assertEqual(self.ownership('101','100').returncode,0)
    def test_foreign_or_mixed_listener_refused(self):
        self.assertNotEqual(self.ownership('200','1').returncode,0)
        self.assertNotEqual(self.ownership('100\n200','1').returncode,0)
    def test_missing_launchagent_refused(self):
        r=self.bash('source "$ROOT/scripts/lib/code-server-port.sh"; CODE_SERVER_LABEL=test; launchctl() { return 1; }; code_server_owns_listener'); self.assertNotEqual(r.returncode,0)
    def test_app_wrapper_forwards_args_and_cli_mode(self):
        app=self.home/'Fake App'; app.write_text('#!/bin/bash\nprintf "%s\\n" "$TAILSCALE_BE_CLI" "$@"\n');app.chmod(0o755)
        r=self.bash('source "$ROOT/scripts/lib/tailscale-cli.sh"; mesh_tailscale_app() { echo "$HOME/Fake App"; }; PATH=/usr/bin:/bin; mesh_tailscale_cli; tailscale "two words" --version; mesh_tailscale_cli')
        self.assertEqual(r.returncode,0,r.stderr); self.assertEqual(r.stdout,'1\ntwo words\n--version\n')
        self.assertEqual(len(list((self.home/'.local/bin').glob('tailscale'))),1)
    def test_existing_cli_and_unmanaged_file_preserved(self):
        target=self.home/'.local/bin/tailscale'; target.parent.mkdir(parents=True);target.write_text('custom');target.chmod(0o644)
        r=self.bash('source "$ROOT/scripts/lib/tailscale-cli.sh"; PATH=/usr/bin:/bin; mesh_tailscale_cli');self.assertNotEqual(r.returncode,0);self.assertEqual(target.read_text(),'custom')
        target.chmod(0o755);r=self.bash('source "$ROOT/scripts/lib/tailscale-cli.sh"; PATH=/usr/bin:/bin; mesh_tailscale_cli');self.assertEqual(r.returncode,0);self.assertEqual(target.read_text(),'custom')
    def test_serve_migration_requires_dedicated_443(self):
        data={'TCP': {'443': {'HTTPS': True}}, 'Web': {'host:443': {'Handlers': {'/': {'Proxy': 'http://127.0.0.1:8080'}}}}}
        status=self.home/'status.json'
        def check(value):
            status.write_text(json.dumps(value))
            return self.bash('source "$ROOT/scripts/lib/code-server-port.sh"; code_server_managed_serve_matches "$(cat "$HOME/status.json")" 8080').returncode
        self.assertEqual(check(data),0)
        data['Web']['host:8443']=data['Web'].pop('host:443')
        self.assertNotEqual(check(data),0)
        data['Web']['host:443']={'Handlers': {'/': {'Proxy': 'http://127.0.0.1:9000'}}}
        self.assertNotEqual(check(data),0)
        data['Web'].pop('host:443');data['Web']['host:443']=data['Web'].pop('host:8443')
        data['AllowFunnel']={'host:443': True}
        self.assertNotEqual(check(data),0)
    def test_uninstall_keeps_recorded_serve_state_on_status_failure(self):
        state=self.home/'.local/state/code-server';state.mkdir(parents=True);(state/'serve-port').write_text('8081')
        r=self.bash('source "$ROOT/topics/remote-access/mac/code-server.sh"; tailscale() { return 1; }; _code_server_uninstall_clear_tailscale_serve 8081')
        self.assertNotEqual(r.returncode,0)
        self.assertEqual((state/'serve-port').read_text(),'8081')
    def test_runtime_verify_uses_saved_port_and_health(self):
        config=self.home/'.config/code-server/config.yaml';config.parent.mkdir(parents=True)
        config.write_text('  bind-addr: 127.0.0.1:8091\n  auth: password\n')
        harness='source "$ROOT/topics/remote-access/mac/code-server.sh"; check() { return 0; }; launchctl() { echo "pid = 100"; }; lsof() { echo 100; }; curl() { [[ "$*" == *"127.0.0.1:8091/healthz"* ]]; }; verify'
        r=self.bash(harness);self.assertEqual(r.returncode,0,r.stderr)
        r=self.bash(harness.replace('curl() { [[ "$*" == *"127.0.0.1:8091/healthz"* ]]; }','curl() { return 1; }'))
        self.assertNotEqual(r.returncode,0)
    def test_port_rewrite_preserves_yaml_indentation(self):
        with socket.socket() as listener:
            listener.bind(('127.0.0.1',0));listener.listen();port=listener.getsockname()[1]
            original='  bind-addr: 127.0.0.1:'+str(port)+'\n  auth: password\n  password: keep\n'
            self.config.write_text(original)
            r=self.allocate(port);self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(self.config.read_text(),original.replace(str(port),r.stdout.strip(),1))
unittest.main()
