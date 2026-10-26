import base64
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
import zlib


CONTROLLER = Path(__file__).resolve().parents[3] / 'vpn/amneziawg/awgctl.sh'


class AmneziaPayloadTests(unittest.TestCase):
    def test_fresh_installer_copies_current_generator(self):
        installer = CONTROLLER.with_name('install_amneziawg.sh').read_text()
        function = 'install_awgctl() {' + installer.split('install_awgctl() {', 1)[1].split('\n}', 1)[0] + '\n}\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            script = 'set -eu\n' + function + '''
SCRIPT_DIR="$1"
CTL_PATH="$2/sbin/awg3ctl"
CTL_BIN_PATH="$2/bin/awg3ctl"
install_awgctl
'''
            subprocess.run(['bash', '-c', script, 'test', str(CONTROLLER.parent), str(root)], check=True)
            self.assertEqual(((root / 'sbin/awg3ctl').resolve()).read_bytes(), CONTROLLER.read_bytes())
            self.assertEqual((root / 'bin/awg3ctl').resolve(), (root / 'sbin/awg3ctl').resolve())

    def test_upgrade_installer_replaces_stale_generator(self):
        repo = CONTROLLER.parents[2]
        installer = (repo / 'bots/vpn-manager_awg/install.sh').read_text()
        function = 'ensure_awg3() {' + installer.split('ensure_awg3() {', 1)[1].split('\n}', 1)[0] + '\n}\n'
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            destination = root / 'awg3ctl'
            destination.write_text('# stale generator\n')
            script = 'set -eu\n' + function + '''
REPO_DIR="$1"
AWG3CTL_PATH="$2/awg3ctl"
TEST_ROOT="$2"
valid_ctl() { test -f "$1"; }
die() { exit 1; }
ln() { command ln -sfn "$AWG3CTL_PATH" "$TEST_ROOT/bin-link"; }
ensure_awg3
'''
            subprocess.run(['bash', '-c', script, 'test', str(repo), str(root)], check=True, capture_output=True)
            self.assertEqual(destination.read_bytes(), CONTROLLER.read_bytes())
            self.assertEqual((root / 'bin-link').resolve(), destination.resolve())

    def test_native_payload_roundtrip_preserves_client_config(self):
        source = CONTROLLER.read_text()
        function = source.split('make_amnezia_vpn_payload_files() {', 1)[1].split('\nPY\n}', 1)[0] + '\nPY'
        script = 'make_amnezia_vpn_payload_files() {' + function + '\n}\nmake_amnezia_vpn_payload_files "$@"\n'
        base = '''[Interface]
PrivateKey = test-private-key
Address = 10.8.0.2/32
DNS = 1.1.1.1, 8.8.8.8
Jc = 4
Jmin = 10
Jmax = 50
S1 = 20
S2 = 30
H1 = 1
H2 = 2
H3 = 3
H4 = 4
{extra}
[Peer]
PublicKey = test-public-key
PresharedKey = test-psk
Endpoint = 192.0.2.1:1235
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
'''
        for extra, version, container in [
            ('', None, 'amnezia-awg'),
            ('I1 = <b 0x01>', '1.5', 'amnezia-awg'),
            ('S3 = 10\nS4 = 20', '2', 'amnezia-awg'),
            ('S3 = 10\nS4 = 20\nHeaderProtectionKey = test-header-key\nContentPaddingAddition = 0',
             '3.1', 'amnezia-awg2'),
        ]:
            with self.subTest(version=version), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                conf = base.format(extra=extra)
                (root / 'client.conf').write_text(conf)
                outputs = [root / name for name in ('profile.json', 'profile.bin', 'profile.key')]
                subprocess.run(['bash', '-c', script, 'test', str(root / 'client.conf'),
                                'Android test', *map(str, outputs)], check=True)
                key = outputs[2].read_text().removeprefix('vpn://')
                compressed = base64.urlsafe_b64decode(key + '=' * (-len(key) % 4))
                self.assertEqual(compressed, outputs[1].read_bytes())
                raw = zlib.decompress(compressed[4:])
                self.assertEqual(len(raw), struct.unpack('>I', compressed[:4])[0])
                payload = json.loads(raw)
                self.assertEqual(payload, json.loads(outputs[0].read_text()))
                self.assertEqual(payload['defaultContainer'], container)
                entry = payload['containers'][0]
                self.assertEqual(entry['container'], container)
                self.assertEqual(entry['awg'].get('protocol_version'), version)
                self.assertTrue(entry['awg']['isThirdPartyConfig'])
                client = json.loads(entry['awg']['last_config'])
                self.assertEqual(client['config'], conf)
                self.assertEqual(client['psk_key'], 'test-psk')
                self.assertEqual(client['port'], 1235)
                self.assertEqual((root / 'client.conf').read_text(), conf)
                if version == '3.1':
                    self.assertEqual(client['HeaderProtectionKey'], 'test-header-key')
                    self.assertEqual(client['ContentPaddingAddition'], '0')
