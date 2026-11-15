import importlib.util,json,tempfile,unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
spec=importlib.util.spec_from_file_location('obfuscationctl',ROOT/'vpn/obfuscation/obfuscationctl.py')
m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
class Transactions(unittest.TestCase):
 def setUp(self):
  self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
  self.root=Path(self.tmp.name);self.runtime={'RandomTrailers':'off','DisableCookies':'off'};self.fail=False
  def runner(args):
   if 'show' in args:return self.runtime[{'random-trailers':'RandomTrailers','disable-cookies':'DisableCookies'}[args[-1]]]
   if 'set' in args:
    if self.fail:self.fail=False;raise RuntimeError('test failure')
    self.runtime={'RandomTrailers':args[-3],'DisableCookies':args[-1]};return ''
   raise AssertionError(args)
  self.ctl=m.Controller(self.root,runner)
  self.write('/usr/bin/awg','fixture')
  self.write('/etc/amnezia/amneziawg/awg3ctl.env','AWG_IFACE=awg3\nAWG_DIR=/etc/amnezia/amneziawg\nCLIENT_OUT_DIR=/root/clients\nAWG_HEADER_PROTECTION_KEY=unchanged\n')
  self.conf='[Interface]\nPrivateKey = secret\nHeaderProtectionKey = header\nListenPort = 1235\n[Peer]\nPublicKey = peer\nPresharedKey = psk\nAllowedIPs = 10.0.0.2/32\n'
  self.write('/etc/amnezia/amneziawg/awg3.conf',self.conf);self.write('/root/clients/alice.conf',self.conf)
 def write(self,name,text):
  p=self.ctl.path(name);p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)
 def apply(self,choice):return self.ctl.apply('awg31',choice,self.ctl.status('awg31')['revision'])
 def test_flags_preserve_keys_peers_ports_and_rollback(self):
  before={p:p.read_bytes() for p in self.ctl.files('awg31')};self.apply('both-on')
  self.assertEqual(self.runtime,{'RandomTrailers':'on','DisableCookies':'on'})
  for p in (self.ctl.files('awg31')[0],self.ctl.files('awg31')[2]):
   stripped='\n'.join(l for l in p.read_text().splitlines() if not l.startswith(('RandomTrailers','DisableCookies')))+'\n'
   self.assertEqual(stripped.encode(),before[p])
  self.assertIn('AWG_RANDOM_TRAILERS=on',self.ctl.files('awg31')[1].read_text())
  self.apply('rollback');self.assertEqual({p:p.read_bytes() for p in before},before)
  self.assertEqual(self.runtime,{'RandomTrailers':'off','DisableCookies':'off'})
 def test_failed_activation_restores_files_and_runtime(self):
  before={p:p.read_bytes() for p in self.ctl.files('awg31')};self.fail=True
  with self.assertRaises(m.Rejected):self.apply('both-on')
  self.assertEqual({p:p.read_bytes() for p in before},before)
  self.assertEqual(self.ctl.latest('awg31')['status'],'rolled_back')
 def test_stale_revision_and_new_profiles_block_rollback(self):
  rev=self.ctl.status('awg31')['revision'];self.apply('both-on')
  with self.assertRaises(m.Rejected):self.ctl.apply('awg31','both-off',rev)
  self.write('/root/clients/bob.conf',self.conf)
  self.assertFalse(self.ctl.status('awg31')['rollback'])
  with self.assertRaises(m.Rejected):self.apply('rollback')
 def test_pending_transaction_blocks_changes(self):
  self.ctl.save_latest('awg31',{'status':'prepared'})
  with self.assertRaises(m.Rejected):self.apply('both-on')
 def test_one_switch_does_not_change_other(self):
  self.apply('trailers-on');self.assertEqual(self.runtime,{'RandomTrailers':'on','DisableCookies':'off'})
 def test_hysteria_preserves_listener_users_and_secrets(self):
  s={'obfs':'none','version':'app/v2.13.0','obfs_password':'existing','min_packet':512,'max_packet':1200}
  cfg={'listen':'203.0.113.1:443','acme':{'domains':['vpn.example.org']},'masquerade':{'type':'proxy'},'auth':{'type':'command'}}
  for name,data in [('settings.json',s),('config.yaml',cfg),('users.json',{'alice':{'password':'secret'}})]:self.write('/etc/hysteria/'+name,json.dumps(data))
  for choice in ('salamander','gecko','none'):
   changes,_=self.ctl.plan('hy2',choice,self.ctl.status('hy2'))
   self.assertNotIn(self.ctl.path('/etc/hysteria/users.json'),changes)
   new=json.loads(changes[self.ctl.path('/etc/hysteria/config.yaml')])
   for k,v in cfg.items():self.assertEqual(new[k],v)
   if choice!='none':self.assertEqual(new['obfs'][choice]['password'],'existing')
   else:self.assertNotIn('obfs',new)
 def test_invalid_choice_rejected(self):
  with self.assertRaises(m.Rejected):self.apply('both-on; reboot')
class QueueTests(unittest.TestCase):
 def test_mutations_have_review_barrier(self):
  from app.job_queue import MUTATING_METHODS,DEFERRED,USER_PROFILE_METHODS
  self.assertIn('apply_obfuscation',MUTATING_METHODS);self.assertIn('apply_obfuscation',DEFERRED)
  self.assertNotIn('apply_obfuscation',USER_PROFILE_METHODS)
 def test_navigation_is_last(self):
  from app import keyboards
  rows=keyboards.settings_menu()['keyboard']
  self.assertEqual([b['text'] for b in rows[-1]],[keyboards.BACK,keyboards.MAIN_MENU])
  self.assertIn([{'text':'Обфускация'}],rows)
