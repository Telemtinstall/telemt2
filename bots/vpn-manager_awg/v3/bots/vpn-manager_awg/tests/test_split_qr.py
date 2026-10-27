import base64,json,zlib,unittest
from types import SimpleNamespace
from unittest.mock import Mock,patch
from app.actions import test_split_payload,Actions
from app import keyboards

def encode(p):
 raw=json.dumps(p,separators=(',',':')).encode();return 'vpn://'+base64.urlsafe_b64encode(len(raw).to_bytes(4,'big')+zlib.compress(raw,8)).decode().rstrip('=')
def decode(s):
 b=base64.urlsafe_b64decode(s+'='*(-len(s)%4));raw=zlib.decompress(b[4:]);assert len(raw)==int.from_bytes(b[:4],'big');return json.loads(raw)
def profile(version='3.1'):
 c={'allowed_ips':['0.0.0.0/0'],'config':'[Interface]\nPrivateKey = unchanged\n[Peer]\nAllowedIPs = 0.0.0.0/0\nEndpoint = nat.netnum.ru:1235\n','client_priv_key':'unchanged','psk_key':'unchanged','HeaderProtectionKey':'unchanged'}
 return {'description':'test','containers':[{'container':'amnezia-awg2','awg':{'protocol_version':version,'last_config':json.dumps(c),'isThirdPartyConfig':True}}],'defaultContainer':'amnezia-awg2'}
class SplitQrTests(unittest.TestCase):
 def test_only_routes_change_and_source_unchanged(self):
  p=profile();key=encode(p);result=test_split_payload(key);out=decode(result)
  self.assertEqual(p,decode(key[6:]))
  old=json.loads(p['containers'][0]['awg']['last_config']);new=json.loads(out['containers'][0]['awg']['last_config'])
  self.assertEqual(new['allowed_ips'],['0.0.0.0/0','::/0'])
  self.assertIn('AllowedIPs = 0.0.0.0/0, ::/0\n',new['config'])
  new['allowed_ips']=old['allowed_ips'];new['config']=old['config'];self.assertEqual(old,new)
  out['containers'][0]['awg']['last_config']=p['containers'][0]['awg']['last_config'];self.assertEqual(p,out)
 def test_other_versions_and_custom_routes_rejected(self):
  with self.assertRaises(ValueError):test_split_payload(encode(profile('2')))
  p=profile();c=json.loads(p['containers'][0]['awg']['last_config']);c['allowed_ips']=['10.0.0.0/8'];p['containers'][0]['awg']['last_config']=json.dumps(c)
  with self.assertRaises(ValueError):test_split_payload(encode(p))
 def test_button_only_for_awg31_admin_card(self):
  for sid in ['amneziawg','amneziawg3','vless']:
   buttons=[b['callback_data'] for row in keyboards.client_actions(sid,'amneziawg','alice')['inline_keyboard'] for b in row]
   self.assertEqual(sid=='amneziawg3',any(b.startswith('testsplit:') for b in buttons))
 def test_qr_uses_stdin_and_never_persists_payload(self):
  obj=Actions.__new__(Actions);obj.require_protocol_enabled=Mock();obj.verify_profile=Mock();obj.telegram=Mock()
  server=SimpleNamespace(id='amneziawg3',title='AmneziaWG 3.1',protocol='amneziawg',is_amneziawg=True,qr=Mock(return_value={'name':'alice','vpn_key':encode(profile())}))
  obj.servers=Mock();obj.servers.get.return_value=server
  with patch('app.actions.subprocess.run',return_value=SimpleNamespace(returncode=0,stdout=b'\x89PNG\r\n\x1a\nTEST')) as run:
   obj.send_test_split_qr(10,'amneziawg3','alice')
   self.assertEqual(run.call_args.args[0],['qrencode','-t','PNG','-s','12','-m','4','-l','L','-o','-'])
   self.assertNotIn('vpn://',run.call_args.kwargs['input'].decode())
   self.assertEqual(1,obj.telegram.send_qr.call_count)
