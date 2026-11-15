import json, shutil, subprocess, tempfile, unittest
from pathlib import Path

CONTROLLER = Path(__file__).resolve().parents[3] / 'vpn/vless/vlessctl.sh'

@unittest.skipUnless(shutil.which('jq'), 'jq required')
class RealityControllerTests(unittest.TestCase):
    def test_render_preserves_legacy_modes_and_reality_key(self):
        source=CONTROLLER.read_text().rsplit('main "$@"',1)[0]
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'users.json').write_text(json.dumps([{'name':'test','uuid':'11111111-1111-4111-8111-111111111111'}]))
            (root/'key').write_text('rnTestKey\n')
            for mode, bind_ip in ((mode, ip) for mode in ('mask','direct','reality') for ip in ('', '192.0.2.2')):
                script=source+'''
install() { cp "${@: -2:1}" "${@: -1}"; }
FRONTEND_MODE="$1"
VPN_BIND_IP="$3"
USERS_FILE="$2/users.json"
CONFIG_FILE="$2/config.json"
REALITY_PRIVATE_KEY_FILE="$2/key"
REALITY_TARGET=example.com:443
REALITY_SERVER_NAME=example.com
REALITY_SHORT_ID=abcd1234
PUBLIC_HOST=192.0.2.1
CONNECT_HOST=192.0.2.2
REALITY_PUBLIC_KEY=public-test-key
HTTPS_PORT=443
LOCAL_PORT=12710
VLESS_PATH=/test
XRAY_API_LISTEN=127.0.0.1:10085
XRAY_FORCE_IPV4=1
ENABLE_ACCESS_LOGS=0
render_config
print_link_for test
'''
                proc=subprocess.run(['bash','-c',script,'test',mode,str(root),bind_ip],capture_output=True,text=True,check=True)
                self.assertIn('@192.0.2.2:443?',proc.stdout)
                config=json.loads((root/'config.json').read_text()); inbound=config['inbounds'][0]
                if bind_ip:
                    self.assertEqual(config['outbounds'][0]['sendThrough'], bind_ip)
                    self.assertEqual(config['outbounds'][0]['settings']['domainStrategy'], 'UseIPv4')
                if mode=='reality':
                    self.assertEqual('reality',inbound['streamSettings']['security'])
                    self.assertEqual('rnTestKey',inbound['streamSettings']['realitySettings']['privateKey'])
                    self.assertEqual('xtls-rprx-vision',inbound['settings']['clients'][0]['flow'])
                    self.assertIn('security=reality',proc.stdout)
                    self.assertIn('pbk=public-test-key',proc.stdout)
                    self.assertNotIn('rnTestKey',proc.stdout)
                else:
                    self.assertEqual('ws',inbound['streamSettings']['network'])
                    self.assertEqual('127.0.0.1' if mode=='mask' else (bind_ip or '0.0.0.0'),inbound['listen'])
                    self.assertIn('security=tls' if mode=='mask' else 'security=none',proc.stdout)
