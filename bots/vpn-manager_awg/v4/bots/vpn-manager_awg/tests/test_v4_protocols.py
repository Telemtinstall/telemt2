"""AWG 2.0 must not be installed or silently removed from an old plan."""
import contextlib
import io
from pathlib import Path
import sys,tempfile,unittest
from unittest.mock import patch
ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'installer'))
from ini_config import selected_valid,load_ini,build_plan
from questionnaire import Questionnaire,PROTOCOLS
from state import InstallState
import install

class V4ProtocolTests(unittest.TestCase):
 def test_removed_from_cli_modules_and_registry(self):
  import json
  self.assertNotIn('amnezia20',PROTOCOLS)
  self.assertFalse((ROOT/'installer/modules/amnezia20.sh').exists())
  self.assertNotIn('amneziawg',{s['id'] for s in json.loads((ROOT/'bots/vpn-manager_awg/servers.json').read_text())})
  with contextlib.redirect_stderr(io.StringIO()),self.assertRaises(SystemExit):install.parser().parse_args(['--onlyprotocol','amnezia20'])
 def test_old_plan_is_rejected_not_silently_changed(self):
  for selected in [['amnezia20'],['amnezia20','amnezia31']]:
   with self.assertRaisesRegex(ValueError,'удалена'):selected_valid(selected)
 def test_ini_zero_installs_only_awg31_and_old_option_is_rejected(self):
  with tempfile.TemporaryDirectory() as tmp:
   p=Path(tmp)/'install.ini';p.write_text('[protocols]\namnezia31=yes\nvless_or_hysteria2=0\n');p.chmod(0o600)
   answers,chosen=load_ini(p);self.assertEqual(chosen,['amnezia31']);self.assertEqual(build_plan(answers,chosen),[('udp',1235,'amnezia31')])
   p.write_text('[protocols]\namnezia20=yes\namnezia31=yes\nvless_or_hysteria2=0\n')
   with self.assertRaises(ValueError):load_ini(p)
 def test_interactive_vless_only_and_awg_only(self):
  for replies,want in [(['n','n','1'],['vless']),(['n','y','0'],['amnezia31']),(['y','2'],['amnezia31','hysteria2'])]:
   with tempfile.TemporaryDirectory() as tmp,patch('builtins.input',side_effect=replies) as ask,contextlib.redirect_stdout(io.StringIO()):
    state=InstallState(Path(tmp)/'state');self.assertEqual(Questionnaire(state).select_protocols(),want)
    self.assertFalse(any('2.0' in call.args[0] for call in ask.call_args_list))
