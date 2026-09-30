import importlib.util,os,pathlib,subprocess,sys,tempfile,unittest,json,shutil
from unittest.mock import patch
ROOT=pathlib.Path(__file__).resolve().parents[2];sys.dont_write_bytecode=True
spec=importlib.util.spec_from_file_location('enroll',ROOT/'scripts/lib/ssh-enroll.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class EnrollmentTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.base=pathlib.Path(self.tmp.name);self.repo=self.base/'repo';self.remote=self.base/'remote.git';self.messages=[]
  self.env=patch.dict(os.environ,{'GIT_CONFIG_GLOBAL':'/dev/null','GIT_CONFIG_NOSYSTEM':'1','GIT_TERMINAL_PROMPT':'0'});self.env.start()
  self.mock=patch.object(m,'followup',side_effect=lambda level,message:self.messages.append((level,message)));self.mock.start()
  self.call('git','init','--bare','--initial-branch=main',str(self.remote));self.call('git','clone',str(self.remote),str(self.repo))
  self.git('config','user.name','Test');self.git('config','user.email','test@example.invalid');self.git('config','commit.gpgsign','false')
  (self.repo/'ssh').mkdir();(self.repo/'ssh/authorized_keys').write_text('# existing trust list\n')
  self.git('add','.');self.git('commit','-m','initial');self.git('push','-u','origin','main')
  self.key=self.base/'id_ed25519';self.call('ssh-keygen','-q','-t','ed25519','-N','','-f',str(self.key));self.pub=pathlib.Path(str(self.key)+'.pub')
 def tearDown(self):self.mock.stop();self.tmp.cleanup();self.env.stop()
 def call(self,*args):return subprocess.run(args,capture_output=True,text=True,check=True).stdout.strip()
 def git(self,*args):return self.call('git','-C',str(self.repo),*args)
 def enroll(self):m.enroll(self.repo,self.pub,'test-host')
 def test_publish_and_idempotence(self):
  self.enroll();head=self.git('rev-parse','HEAD');self.enroll();self.assertEqual(self.git('rev-parse','HEAD'),head)
  self.assertEqual(self.git('status','--porcelain'),'');self.assertIn(self.pub.read_text().split()[1],self.git('show','origin/main:ssh/authorized_keys'))
  self.assertTrue(any('confirmed' in message for _,message in self.messages))
 def test_preserve_old_key_on_rotation(self):
  self.enroll();old=self.pub.read_text().split()[1]
  other=self.base/'other';self.call('ssh-keygen','-q','-t','ed25519','-N','','-f',str(other));self.pub=pathlib.Path(str(other)+'.pub');self.enroll()
  self.assertIn(old,(self.repo/'ssh/authorized_keys').read_text());self.assertIn(self.pub.read_text().split()[1],(self.repo/'ssh/authorized_keys').read_text())
 def test_dirty_and_staged_changes_block_publication(self):
  (self.repo/'other').write_text('unrelated');self.git('add','other');head=self.git('rev-parse','HEAD')
  with self.assertRaises(m.EnrollmentError):self.enroll()
  self.assertEqual(head,self.git('rev-parse','HEAD'));self.assertEqual(self.git('diff','--cached','--name-only'),'other')
 def test_unrelated_unpushed_commit_blocked(self):
  (self.repo/'other').write_text('unrelated');self.git('add','other');self.git('commit','-m','unpublished')
  with self.assertRaises(m.EnrollmentError):self.enroll()
 def test_push_failure_retry(self):
  hook=self.remote/'hooks/pre-receive';hook.write_text('#!/bin/sh\nexit 1\n');hook.chmod(0o755)
  with self.assertRaises(m.EnrollmentError):self.enroll()
  head=self.git('rev-parse','HEAD');self.assertTrue((self.repo/'.git/mesh-ssh-enroll-pending.json').exists())
  hook.unlink();self.enroll();self.assertEqual(self.git('rev-parse','HEAD'),head);self.assertFalse((self.repo/'.git/mesh-ssh-enroll-pending.json').exists())
 def test_restricted_key_not_widened(self):
  key=' '.join(self.pub.read_text().split()[:2]);target=self.repo/'ssh/authorized_keys';target.write_text('restrict '+key+'\n')
  self.git('add','.');self.git('commit','-m','restricted');self.git('push')
  with self.assertRaises(m.EnrollmentError):self.enroll()
  self.assertEqual(target.read_text(),'restrict '+key+'\n')
 def test_malformed_and_missing_key_fail(self):
  self.pub.write_text('not a key')
  with self.assertRaises(m.EnrollmentError):self.enroll()
  self.pub.unlink()
  with self.assertRaises(OSError):self.enroll()
 def test_symlink_trust_file_refused(self):
  target=self.repo/'ssh/authorized_keys';target.unlink();target.symlink_to(self.pub)
  with self.assertRaises(m.EnrollmentError):self.enroll()
 def test_report_peers_is_honest_and_does_not_update_remote(self):
  (self.repo/'ssh/peers.list').write_text('first\nsecond\n')
  calls=[]
  def fake(argv,**kw):
   if argv[0]=='ssh-keygen':return subprocess.CompletedProcess(argv,0,'','')
   calls.append(argv)
   fp='SHA256:'+m.base64.b64encode(m.hashlib.sha256(m.base64.b64decode(self.pub.read_text().split()[1])).digest()).decode().rstrip('=')
   return subprocess.CompletedProcess(argv,0,'','debug1: Server accepts key: ED25519 '+(fp if argv[-2]=='first' else 'SHA256:wrong')+' explicit')
  with patch.object(m,'run',side_effect=fake):m.report_peers(self.repo,self.pub)
  self.assertEqual([c[-1] for c in calls],['true','true']);self.assertTrue(any(level=='critical' and 'second' in msg for level,msg in self.messages))
 def test_scaffold_key_is_initialized_and_deployable(self):
  target=self.repo/'ssh/authorized_keys'
  target.write_text((ROOT/'template/ssh/authorized_keys.example').read_text())
  self.git('add','.');self.git('commit','-m','scaffold');self.git('push');self.enroll()
  self.assertNotIn('__REPLACE_WITH_YOUR_PUBLIC_KEY__',target.read_text())
  dest=self.base/'authorized_keys'
  self.call('/bin/bash','-c','. "$1"; deploy_one "ssh/authorized_keys|$3|managed_block|0600" "$2"','test',str(ROOT/'scripts/lib/deploy.sh'),str(self.repo),str(dest))
  self.assertIn(self.pub.read_text().split()[1],dest.read_text())
 def test_fresh_author_uses_personalized_config(self):
  (self.repo/'git').mkdir();(self.repo/'git/gitconfig.local').write_text('[user]\n name = New Host Owner\n email = new@example.invalid\n')
  self.git('add','.');self.git('commit','-m','identity');self.git('push')
  self.git('config','--unset','user.name');self.git('config','--unset','user.email');self.enroll()
  self.assertEqual(self.git('log','-1','--format=%an <%ae>'),'New Host Owner <new@example.invalid>')
 def test_missing_author_does_not_dirty_repo(self):
  self.git('config','--unset','user.name');self.git('config','--unset','user.email')
  with self.assertRaises(m.EnrollmentError):self.enroll()
  self.assertEqual(self.git('status','--porcelain'),'')
 def test_commit_failure_can_retry_without_dirty_checkout(self):
  hook=self.repo/'.git/hooks/pre-commit';hook.write_text('#!/bin/sh\nexit 1\n');hook.chmod(0o755)
  with self.assertRaises(m.EnrollmentError):self.enroll()
  self.assertEqual(self.git('status','--porcelain'),'');hook.unlink();self.enroll()
 def test_rsa_only_selection(self):
  home=self.base/'rsa-home';(home/'.ssh').mkdir(parents=True)
  key=home/'.ssh/id_rsa';self.call('ssh-keygen','-q','-t','rsa','-b','2048','-N','','-f',str(key))
  pub=m.select_public_key(home);self.assertEqual(pub.name,'id_rsa.pub');m.enroll(self.repo,pub,'rsa-host')
  self.assertIn(pub.read_text().split()[1],self.git('show','origin/main:ssh/authorized_keys'))
 def test_personal_apply_enrolls_before_deploy_without_gh_setup(self):
  installer=self.repo/'install.sh'
  installer.write_text('#!/bin/bash\nset -euo pipefail\n. "$MESH_WORKSTATION_DIR/scripts/lib/deploy.sh"\ndeploy_one "ssh/authorized_keys|$HOME/.ssh/authorized_keys|managed_block|0600" "$MESH_IDENTITY_DIR"\n')
  self.git('add','.');self.git('commit','-m','installer');self.git('push')
  home=self.base/'home';(home/'.ssh').mkdir(parents=True);shutil.copyfile(self.pub,home/'.ssh/id_ed25519.pub')
  env=dict(os.environ,HOME=str(home),MESH_IDENTITY_DIR=str(self.repo),MESH_WORKSTATION_DIR=str(ROOT),NON_INTERACTIVE='1',CREATE_IDENTITY_FROM_TEMPLATE='0',MESH_IDENTITY_REPO=str(self.remote),MESH_FOLLOWUP_FILE=str(self.base/'followup'))
  result=subprocess.run(['/bin/bash','-c','. "$1"; uninstall_apply() { :; }; install','test',str(ROOT/'topics/personal/apply.sh')],env=env,capture_output=True,text=True)
  self.assertEqual(result.returncode,0,result.stdout+result.stderr)
  self.assertIn(self.pub.read_text().split()[1],(home/'.ssh/authorized_keys').read_text())
  self.assertIn(self.pub.read_text().split()[1],self.git('show','origin/main:ssh/authorized_keys'))
  self.assertIn('Peer delivery is unconfirmed',(self.base/'followup').read_text())
 def test_dry_run_is_noop(self):
  with patch.dict(os.environ,{'DRY_RUN':'1'}),patch.object(sys,'argv',['enroll','--repo',str(self.repo)]):self.assertEqual(m.main(),0)
  self.assertEqual(self.git('status','--porcelain'),'')
unittest.main()
