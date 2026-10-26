"""Offline endpoint transactions; no real network, service or VPN changes."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import sys

BOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BOT))
spec = importlib.util.spec_from_file_location('vpn_ip_switch', BOT / 'server/vpn_ip_switch.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
from app.ip_admin import IpAdmin
from app.state import BotState


class TransactionTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.calls = []
        self.fail_nginx = False
        self.nft_rules = ''
        self.fail_nft = False
        self.manager = module.Manager(self.root, self.run_command)
        self.write('/root/vpnbot/servers.json', json.dumps([
            {'id': 'awg', 'title': 'AWG', 'protocol': 'amneziawg', 'command': '/usr/local/sbin/awgctl'},
            {'id': 'vless', 'title': 'VLESS', 'protocol': 'vless', 'command': '/usr/local/sbin/vlessctl'},
        ]))
        self.write('/usr/local/sbin/awgctl', '# /run/lock/vpn-endpoint.lock')
        self.write('/usr/local/sbin/vlessctl', '# /run/lock/vpn-endpoint.lock\n${CONNECT_HOST:-$PUBLIC_HOST} VPN_BIND_IP')
        self.write('/etc/amnezia/amneziawg/awgctl.env', 'PUBLIC_ENDPOINT=8.8.8.8\nCLIENT_OUT_DIR=/clients\nAWG_IFACE=awg0\nAWG_SUBNET=10.8.0.0/24\nAWG_PORT=1234\n')
        self.profile = '[Interface]\nPrivateKey = unchanged-secret\nHeaderProtectionKey = same\n[Peer]\nPresharedKey = same-psk\nEndpoint = 8.8.8.8:1235\n'
        self.write('/clients/alice.conf', self.profile)
        self.write('/usr/local/etc/xray/vless.env', 'PUBLIC_HOST=example.com\nFRONTEND_MODE=reality\nHTTPS_PORT=443\n')

        self.write('/usr/local/etc/xray/config.json', json.dumps({'inbounds': [{'protocol': 'vless', 'listen': '0.0.0.0'}], 'outbounds': [{'protocol': 'freedom', 'settings': {}}]}))

    def write(self, path, text):
        path = self.manager.path(path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)
        path.chmod(0o600)

    def run_command(self, args):
        self.calls.append(args)
        if args == ['nft', '-j', 'list', 'tables']:
            return json.dumps({'nftables': [{'table': {'family': 'inet', 'name': 'vpnbot_ip'}}] if self.nft_rules else []})
        if args[:4] == ['nft', '-s', 'list', 'table']:
            return self.nft_rules
        if args[:3] == ['nft', '-c', '-f'] and self.fail_nft:
            self.fail_nft = False
            raise RuntimeError('invalid nft rules')
        if args[:2] == ['nft', '-f']:
            self.nft_rules = Path(args[2]).read_text().removeprefix('delete table inet vpnbot_ip\n')
            return ''
        if args[:5] == ['ip', '-j', '-4', 'route', 'show']:
            return json.dumps([{'dev': 'eth0'}])
        if args[:4] == ['ip', '-j', '-4', 'address']:
            return json.dumps([
                {'ifname': 'eth0', 'flags': ['UP'], 'addr_info': [{'local': '1.1.1.1'}, {'local': '10.0.0.1'}]},
                {'ifname': 'awg0', 'flags': ['UP'], 'addr_info': [{'local': '9.9.9.9'}]},
            ])
        if args == ['nginx', '-t'] and self.fail_nginx:
            self.fail_nginx = False
            raise RuntimeError('invalid nginx fixture')
        return ''

    def test_apply_preserves_credentials_and_reality_then_manual_rollback(self):
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        result = self.manager.apply('1.1.1.1', 'admin')
        self.assertTrue(result['changed'])
        self.assertEqual(self.profile.replace('8.8.8.8', '1.1.1.1'), self.manager.path('/clients/alice.conf').read_text())
        env = module.read_env(self.manager.path('/usr/local/etc/xray/vless.env'))
        self.assertEqual(env['PUBLIC_HOST'], 'example.com')
        self.assertEqual(env['CONNECT_HOST'], '1.1.1.1')
        self.assertNotIn(['systemctl', 'restart', 'xray'], self.calls)
        self.assertIn('snat ip to 1.1.1.1', self.nft_rules)
        self.assertFalse(self.manager.apply('1.1.1.1')['changed'])
        self.manager.rollback(Path(result['backup']).name)
        for path, content in before.items(): self.assertEqual(path.read_bytes(), content)
        self.assertFalse(self.manager.path('/etc/vpnbot/public-ip.json').exists())
        self.assertEqual(self.manager.path('/clients/alice.conf').stat().st_mode & 0o777, 0o600)

    def test_ingress_egress_and_reboot_restore(self):
        self.manager.apply('1.1.1.1')
        self.assertIn('ip saddr 10.8.0.0/24 oifname "eth0" counter snat ip to 1.1.1.1', self.nft_rules)
        self.assertIn('udp dport 1234 ip daddr != 1.1.1.1 counter drop', self.nft_rules)
        self.assertIn('tcp dport 443 ip daddr != 1.1.1.1 counter drop', self.nft_rules)
        self.assertIn('meta nfproto ipv6', self.nft_rules)
        cfg = json.loads(self.manager.path('/usr/local/etc/xray/config.json').read_text())
        self.assertEqual(cfg['outbounds'][0]['sendThrough'], '1.1.1.1')
        self.assertEqual(cfg['inbounds'][0]['listen'], '1.1.1.1')
        original = self.nft_rules
        self.nft_rules = ''
        self.manager.enforce()
        self.assertEqual(self.nft_rules, original)
        self.assertTrue(any(c[0] == 'sh' and 'conntrack -D' in c[2] for c in self.calls))

    def test_nft_failure_rolls_back_and_success_can_be_rolled_back(self):
        self.fail_nft = True
        with self.assertRaisesRegex(RuntimeError, 'восстановлены'):
            self.manager.apply('1.1.1.1')
        self.assertEqual(self.manager.path('/clients/alice.conf').read_text(), self.profile)
        self.assertEqual(self.nft_rules, '')
        result = self.manager.apply('1.1.1.1')
        self.manager.rollback(Path(result['backup']).name)
        self.assertEqual(self.nft_rules, '')
        self.assertEqual(self.manager.path('/clients/alice.conf').read_text(), self.profile)

    def test_invalid_or_unassigned_ip_leaves_profiles_unchanged(self):
        for address in ['10.0.0.1', '9.9.9.9', '::1', '1.1.1.1;reboot']:
            with self.assertRaises(ValueError): self.manager.apply(address)
        self.assertEqual(self.manager.path('/clients/alice.conf').read_text(), self.profile)
        self.assertFalse(self.manager.path('/root/vpn-endpoint-backups').exists())

    def test_old_controller_rejected_before_mutation(self):
        self.write('/usr/local/sbin/awgctl', '# old controller')
        with self.assertRaisesRegex(RuntimeError, 'контроллер'): self.manager.apply('1.1.1.1')
        self.assertEqual(self.manager.path('/clients/alice.conf').read_text(), self.profile)

    def test_nginx_failure_automatically_restores_every_file(self):
        self.write('/usr/local/etc/xray/vless.env', 'PUBLIC_HOST=example.com\nFRONTEND_MODE=mask\nHTTPS_PORT=443\n')
        site = '/etc/nginx/sites-available/vless-example.com.conf'
        self.write(site, 'server {\n listen 8.8.8.8:443 ssl;\n}\n')
        before = {p: p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        self.fail_nginx = True
        with self.assertRaisesRegex(RuntimeError, 'восстановлены'): self.manager.apply('1.1.1.1')
        for path, content in before.items(): self.assertEqual(path.read_bytes(), content)
        manifest = next(self.root.glob('root/vpn-endpoint-backups/*/manifest.json'))
        self.assertEqual(json.loads(manifest.read_text())['status'], 'rolled_back')

    def test_mask_preserves_old_listener_and_adds_new_one(self):
        self.write('/usr/local/etc/xray/vless.env', 'PUBLIC_HOST=example.com\nFRONTEND_MODE=mask\nHTTPS_PORT=443\n')
        site = '/etc/nginx/sites-available/vless-example.com.conf'
        self.write(site, 'server {\n listen 8.8.8.8:443 ssl;\n}\n')
        self.manager.apply('1.1.1.1')
        text = self.manager.path(site).read_text()
        self.assertIn('8.8.8.8:443 ssl;', text)
        self.assertIn('1.1.1.1:443 ssl;', text)
        self.assertIn(['nginx', '-t'], self.calls)

    def test_rollback_refuses_later_edits_and_corrupted_backup(self):
        result = self.manager.apply('1.1.1.1')
        path = self.manager.path('/clients/alice.conf')
        applied = path.read_text()
        path.write_text(applied + '# later change\n')
        with self.assertRaisesRegex(RuntimeError, 'изменился'): self.manager.rollback(Path(result['backup']).name)
        path.write_text(applied)
        (Path(result['backup']) / 'clients/alice.conf').write_text('corrupt')
        with self.assertRaisesRegex(RuntimeError, 'Повреждена'): self.manager.rollback(Path(result['backup']).name)
        self.assertEqual(path.read_text(), applied)

    def test_interrupted_transaction_can_be_rolled_back(self):
        result = self.manager.apply('1.1.1.1')
        manifest_path = Path(result['backup']) / 'manifest.json'
        manifest = json.loads(manifest_path.read_text()); manifest['status'] = 'pending'
        manifest_path.write_text(json.dumps(manifest))
        self.manager.rollback(Path(result['backup']).name)
        self.assertEqual(self.manager.path('/clients/alice.conf').read_text(), self.profile)


class UiTests(unittest.TestCase):
    def test_confirmation_bound_to_user_and_consumed_once(self):
        class Telegram:
            def send_message(self, *args): pass
        calls = []
        def command(action, *args):
            calls.append((action, args))
            if action == 'list': return {'addresses': [{'ip': '1.1.1.1', 'interface': 'eth0'}], 'protocols': [{'title': 'AWG', 'ip': '8.8.8.8'}]}
            return {'ip': args[0], 'protocols': ['AWG']}
        ui = IpAdmin(Telegram(), BotState(), command)
        ui.show(1, '10'); token = ui.pending[('10', 1)]['token']
        with self.assertRaises(ValueError): ui.handle(1, '11', 'ipchoose:' + token + ':0')
        with self.assertRaises(ValueError): ui.handle(1, '10', 'ipapply:' + token)
        ui.handle(1, '10', 'ipchoose:' + token + ':0')
        ui.handle(1, '10', 'ipapply:' + token)
        ui.handle(1, '10', 'ipapply:' + token)
        self.assertEqual(sum(action == 'apply' for action, _ in calls), 1)

class InstallerTests(unittest.TestCase):
    def test_payload_install_includes_ip_ui_and_executable_helper(self):
        import subprocess
        import os
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            env = dict(os.environ, INSTALL_DIR=str(root/'bot'),
                       SERVER_STATUS_PATH=str(root/'server-status'),
                       SPEEDTEST_PATH=str(root/'speedtest'),
                       IP_SWITCH_PATH=str(root/'ip-switch'))
            source = (BOT/'install.sh').read_text().rsplit('main "$@"', 1)[0]
            # BASH_SOURCE is empty with -c; set SCRIPT_DIR explicitly after definitions.
            result = subprocess.run(['bash', '-c', source + '\nSCRIPT_DIR="$1"\nrequire_sources\ninstall_bot_files\n', 'test', str(BOT)],
                                    env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((root/'bot/app/ip_admin.py').read_bytes(), (BOT/'app/ip_admin.py').read_bytes())
            self.assertEqual((root/'ip-switch').read_bytes(), (BOT/'server/vpn_ip_switch.py').read_bytes())
            self.assertTrue(os.access(root/'ip-switch', os.X_OK))
