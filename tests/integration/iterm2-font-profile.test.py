import importlib.util,json,pathlib,plistlib,sys,tempfile,unittest,subprocess,os
from types import SimpleNamespace
sys.dont_write_bytecode=True
root=pathlib.Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('profile',root/'topics/shell-terminal/scripts/iterm2-font-profile.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class ProfileTests(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.home=pathlib.Path(self.tmp.name)
  self.old_identity=os.environ.get('MESH_IDENTITY_DIR');os.environ['MESH_IDENTITY_DIR']=str(self.home/'mesh-identity')
  self.prefs=self.home/'Library/Preferences/com.googlecode.iterm2.plist';self.prefs.parent.mkdir(parents=True)
  self.prefs.write_bytes(plistlib.dumps({'Default Bookmark Guid':'user-default','New Bookmarks':[{'Name':'Custom','Guid':'user-default','Normal Font':'Menlo-Regular 13.5','Custom Command':'Yes','Command':'do-not-change'}]}))
 def tearDown(self):
  if self.old_identity is None:os.environ.pop('MESH_IDENTITY_DIR',None)
  else:os.environ['MESH_IDENTITY_DIR']=self.old_identity
  self.tmp.cleanup()
 def run_config(self,**kw): return m.configure(self.home,resolver=lambda n:n,**kw)
 def test_parent_size_and_prefs_preserved(self):
  old=self.prefs.read_bytes();target=self.run_config();p=json.loads(target.read_text())['Profiles'][0]
  self.assertEqual(p['Normal Font'],'CaskaydiaCoveNFM-Regular 13.5');self.assertEqual(p['Dynamic Profile Parent GUID'],'user-default')
  self.assertFalse(p['Use Non-ASCII Font']);self.assertEqual(p['Non Ascii Font'],p['Normal Font']);self.assertEqual(old,self.prefs.read_bytes())
 def test_check_and_idempotence(self):
  with self.assertRaises(ValueError): self.run_config(check=True)
  target=self.run_config();mtime=target.stat().st_mtime_ns
  self.run_config();self.run_config(check=True);self.assertEqual(mtime,target.stat().st_mtime_ns)
  self.assertEqual(len(list(target.parent.iterdir())),1)
 def test_font_fallback_refused(self):
  with self.assertRaisesRegex(ValueError,'not registered'):m.configure(self.home,resolver=lambda n:'Helvetica')
  self.assertFalse((self.home/'Library/Application Support').exists())
 def test_unmanaged_and_symlink_refused(self):
  target=self.run_config();target.write_text('{"Profiles": []}')
  with self.assertRaisesRegex(ValueError,'unmanaged'):self.run_config()
  target.unlink();target.symlink_to(self.prefs)
  with self.assertRaisesRegex(ValueError,'symlink'):self.run_config()
 def test_default_dynamic_preserves_original_parent_and_size(self):
  target=self.run_config();original=json.loads(target.read_text())
  data=plistlib.loads(self.prefs.read_bytes());data['Default Bookmark Guid']=m.GUID
  data['New Bookmarks'].append(original['Profiles'][0]);self.prefs.write_bytes(plistlib.dumps(data))
  self.run_config();self.assertEqual(json.loads(target.read_text()),original)
  self.assertEqual(original['Profiles'][0]['Dynamic Profile Parent GUID'],'user-default')
 def test_unmanaged_null_preserved(self):
  target=self.run_config();target.write_text('null')
  with self.assertRaisesRegex(ValueError,'unmanaged'):self.run_config()
  self.assertEqual(target.read_text(),'null')
 def test_missing_prefs_supported(self):
  self.prefs.unlink();p=json.loads(self.run_config().read_text())['Profiles'][0];self.assertEqual(p['Normal Font'],m.FONT+' 14')
class FontSettingsTests(ProfileTests):
 def test_exported_managed_profile_preserves_other_settings(self):
  target=self.run_config();data=json.loads(target.read_text());data.pop('Mesh Managed')
  data['Profiles'][0]['Cursor Type']=2;target.write_text(json.dumps(data))
  self.run_config();updated=json.loads(target.read_text())
  self.assertEqual(updated['Profiles'][0]['Cursor Type'],2);self.assertEqual(updated['Mesh Managed'],m.OWNER)

 def test_personal_size_and_ligatures(self):
  config=self.home/'mesh-identity/iterm2/font.json';config.parent.mkdir(parents=True)
  config.write_text('{"font_size":20,"ligatures":true}')
  profile=json.loads(self.run_config().read_text())['Profiles'][0]
  self.assertEqual(profile['Normal Font'],m.FONT+' 20');self.assertEqual(profile['Non Ascii Font'],m.FONT+' 20')
  self.assertTrue(profile['ASCII Ligatures']);self.assertTrue(profile['Non-ASCII Ligatures'])
  self.run_config(check=True)
 def test_invalid_settings_rejected(self):
  for settings in ({'font_size': True},{'font_size': 0},{'ligatures':'yes'}):
   with self.assertRaises(ValueError):m.desired_profile({},m.FONT,settings=settings)

class DefaultTests(ProfileTests):
 def runner(self,running=1,write_fails=False,bootstrap_fails=False):
  calls=[];state={'guid':'old','loaded':False}
  def run(args):
   calls.append(args);rc=0;out=''
   if args[0]=='/usr/bin/defaults':
    if args[1]=='read':out=state['guid']
    elif write_fails:rc=1
    else:state['guid']=args[-1]
   elif args[0]=='/usr/bin/pgrep':rc=running
   elif args[1]=='print':rc=0 if state['loaded'] else 1
   elif args[1]=='bootstrap':
    rc=int(bootstrap_fails);state['loaded']=not bootstrap_fails
   return SimpleNamespace(returncode=rc,stdout=out,stderr='mock failure' if rc else '')
  return run,calls,state
 def test_closed_sets_default_and_preserves_profiles(self):
  run,calls,state=self.runner();old=self.prefs.read_bytes()
  self.assertEqual(m.ensure_default(self.home,run=run),'default');self.assertEqual(state['guid'],m.GUID)
  self.assertEqual(old,self.prefs.read_bytes());self.assertFalse(any(c[0]=='/bin/launchctl' for c in calls))
 def test_running_defers_without_preference_write(self):
  run,calls,state=self.runner(running=0)
  self.assertEqual(m.ensure_default(self.home,run=run),'pending');self.assertEqual(state['guid'],'old')
  agent=self.home/('Library/LaunchAgents/'+m.DEFAULT_LABEL+'.plist');job=plistlib.loads(agent.read_bytes())
  self.assertEqual(m.ensure_default(self.home,check=True,run=run),'pending')
  self.assertEqual(job['StartInterval'],10);self.assertTrue(job['RunAtLoad']);self.assertEqual(job['ProgramArguments'][0],'/bin/bash')
  self.assertTrue(any(c[1]=='bootstrap' for c in calls));self.assertFalse(any(c[0]=='/usr/bin/defaults' and c[1]=='write' for c in calls))
 def test_check_never_writes_or_schedules(self):
  run,calls,state=self.runner(running=0)
  with self.assertRaises(ValueError):m.ensure_default(self.home,check=True,run=run)
  self.assertEqual(len(calls),1);self.assertFalse((self.home/'Library/LaunchAgents').exists())
 def test_already_default_no_changes(self):
  run,calls,state=self.runner();state['guid']=m.GUID
  self.assertEqual(m.ensure_default(self.home,run=run),'default');self.assertEqual(len(calls),1)
 def test_detection_write_and_schedule_errors(self):
  for kw in ({'running':2},{'write_fails':True},{'running':0,'bootstrap_fails':True}):
   run,_,_=self.runner(**kw)
   with self.assertRaises(ValueError):m.ensure_default(self.home,run=run)
 def test_custom_preferences_refused(self):
  self.prefs.write_bytes(plistlib.dumps({'LoadPrefsFromCustomFolder':True}));run,calls,_=self.runner()
  with self.assertRaises(ValueError):m.ensure_default(self.home,run=run)
  self.assertEqual(calls,[])
 def test_worker_waits_then_writes_and_unloads(self):
  # Substitute only command paths in a fixture; never invoke real defaults/launchctl.
  worker=m.DEFAULT_WORKER.replace('/usr/bin/pgrep','fake_pgrep').replace('/usr/bin/defaults','fake_defaults').replace('/bin/rm','fake_rm').replace('/bin/launchctl','fake_launchctl')
  funcs='fake_pgrep() { return "$MOCK_RUNNING"; }\nfake_defaults() { echo "defaults $*" >> "$TEST_LOG"; if [[ "$1" == read ]]; then echo "$MOCK_GUID"; fi; }\nfake_rm() { echo "rm $*" >> "$TEST_LOG"; }\nfake_launchctl() { echo "launchctl $*" >> "$TEST_LOG"; }\n'
  funcs=funcs.replace(r'\n', '\n')
  log=self.home/'calls';env=dict(os.environ,HOME=str(self.home),TEST_LOG=str(log),MOCK_GUID=m.GUID)
  for running in ('0','1'):
   log.write_text('');env['MOCK_RUNNING']=running
   result=subprocess.run(['/bin/bash','-c',funcs+worker],env=env,capture_output=True,text=True)
   self.assertEqual(result.returncode,0,result.stderr)
   if running=='0':self.assertEqual(log.read_text(),'')
   else:self.assertIn('write com.googlecode.iterm2',log.read_text());self.assertIn('bootout',log.read_text())
  log.write_text('');env['MOCK_GUID']='wrong'
  result=subprocess.run(['/bin/bash','-c',funcs+worker],env=env,capture_output=True,text=True)
  self.assertNotEqual(result.returncode,0);self.assertNotIn('bootout',log.read_text());self.assertNotIn('rm ',log.read_text())

unittest.main()
