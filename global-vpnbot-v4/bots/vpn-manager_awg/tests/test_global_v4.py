"""V4 behavior: no DNS-provider writes, safe probes, fixed egress and kernel readiness."""
import importlib.util
import json
from pathlib import Path
import socket
import ssl
import sys
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import Mock, patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'installer'))
sys.path.insert(0,str(ROOT/'bots/vpn-manager_awg/server'))
import source_ip_probe as probe
import runtime_safety
import kernel_check
import network_setup
import test_ip_switch as fixtures
from app.ip_admin import IpAdmin
from app.state import BotState
from app.telegram_api import TelegramAPI, TelegramTemporaryError


class ProbeTests(unittest.TestCase):
    def test_rejects_options_shell_urls_and_private_targets_before_socket(self):
        for name in ['-h','x.org;id','x.org$(id)','https://x.org','1.1.1.1','x.org:22','x.org y.org','*.x.org','x.org\n']:
            with self.subTest(name=name),patch.object(probe,'lookup') as lookup:
                with self.assertRaises(ValueError):probe.resolve_target(name)
                lookup.assert_not_called()
        with patch.object(probe,'lookup',return_value={'ok':True,'a_records':['127.0.0.1']}):
            with self.assertRaises(ValueError):probe.resolve_target('x.org')

    def test_resolves_once_and_pins_same_destination_for_every_source(self):
        rows=[{'ip':'1.1.1.1'},{'ip':'8.8.8.8'}]
        with patch.object(probe,'lookup',return_value={'ok':True,'a_records':['9.9.9.9','9.9.9.10']}) as lookup,patch.object(probe,'probe_source',return_value={'ssh':True,'https':True,'available':True}) as test:
            data=probe.check_addresses(rows,'CHECK.EXAMPLE.ORG')
        lookup.assert_called_once_with('check.example.org')
        self.assertEqual(data['destination_ip'],'9.9.9.9')
        self.assertEqual({c.args[2] for c in test.call_args_list},{'9.9.9.9'})
        self.assertEqual({c.args[0] for c in test.call_args_list},{'1.1.1.1','8.8.8.8'})

    def test_source_bound_ssh_banner_and_verified_https_no_login(self):
        ssh=Mock();ssh.__enter__=Mock(return_value=ssh);ssh.__exit__=Mock(return_value=False);ssh.recv.return_value=b'SSH-2.0-OpenSSH\r\n'
        sock=Mock();sock.__enter__=Mock(return_value=sock);sock.__exit__=Mock(return_value=False)
        tls=Mock();tls.__enter__=Mock(return_value=tls);tls.__exit__=Mock(return_value=False);tls.recv.return_value=b'HTTP/1.1 401 Unauthorized\r\n'
        context=Mock();context.wrap_socket.return_value=tls
        with patch.object(probe.socket,'create_connection',side_effect=[ssh,sock]) as connect,patch.object(probe.ssl,'create_default_context',return_value=context):
            data=probe.probe_source('1.1.1.1','check.example.org','9.9.9.9')
        self.assertTrue(data['available']);ssh.sendall.assert_not_called()
        self.assertEqual(connect.call_args_list[0].kwargs['source_address'],('1.1.1.1',0))
        self.assertEqual(connect.call_args_list[1].args[0],('9.9.9.9',443))
        context.wrap_socket.assert_called_once_with(sock,server_hostname='check.example.org')
        self.assertIn(b'Host: check.example.org',tls.sendall.call_args.args[0])

    def test_timeout_and_bad_tls_are_separate_results(self):
        sock=Mock();sock.__enter__=Mock(return_value=sock);sock.__exit__=Mock(return_value=False)
        context=Mock();context.wrap_socket.side_effect=ssl.SSLCertVerificationError('bad cert')
        with patch.object(probe.socket,'create_connection',side_effect=[socket.timeout(),sock]),patch.object(probe.ssl,'create_default_context',return_value=context):
            data=probe.probe_source('1.1.1.1','check.example.org','9.9.9.9')
        self.assertEqual(data['ssh_reason'],'timeout');self.assertEqual(data['https_reason'],'tls_error');self.assertFalse(data['available'])


class MenuTests(unittest.TestCase):
    def test_requests_probe_domain_before_network_tests(self):
        tg=Mock();command=Mock();state=BotState();ui=IpAdmin(tg,state,command)
        ui.begin(1,'10');command.assert_not_called()
        self.assertEqual(state.context('10',1)['screen'],'admin_ip_probe')
        text=tg.send_message.call_args.args[1]
        self.assertIn('SSH на TCP 22',text);self.assertIn('HTTPS на TCP 443',text);self.assertIn('API-ключи не нужны',text)
        with patch.object(ui,'show') as show:
            ui.input(1,'10','check.example.org')
        command.assert_called_once_with('probe-set','check.example.org');show.assert_called_once_with(1,'10')


class HyNetworkTests(unittest.TestCase):
    def setUp(self):
        self.f=fixtures.TransactionTests();self.f.setUp();self.addCleanup(self.f.doCleanups)
        self.m=fixtures.module.GlobalManager(self.f.root,self.f.run_command)
        self.f.write('/root/vpnbot/servers.json',json.dumps([{'id':'hy','title':'Hysteria','protocol':'hysteria2','command':'/usr/local/sbin/hysteria2ctl'}]))
        self.settings={'domain':'vpn.example.org','bind_ip':'8.8.8.8','port':443,'obfs':'salamander','obfs_password':'preserved'}
        self.config={'listen':'8.8.8.8:443','acme':{'domains':['vpn.example.org'],'listenHost':'8.8.8.8'},'obfs':{'type':'salamander','salamander':{'password':'preserved'}},'outbounds':[{'type':'direct','name':'direct','direct':{'mode':'4','bindIPv4':'8.8.8.8'}}]}
        self.f.write('/etc/hysteria/settings.json',json.dumps(self.settings));self.f.write('/etc/hysteria/config.yaml',json.dumps(self.config))
    def test_egress_change_keeps_tls_domain_and_obfuscation_then_rollback(self):
        result=self.m.apply('1.1.1.1')
        cfg=json.loads(self.m.path('/etc/hysteria/config.yaml').read_text())
        self.assertEqual(cfg['listen'],'0.0.0.0:443');self.assertEqual(cfg['outbounds'][0]['direct']['bindIPv4'],'1.1.1.1')
        self.assertEqual(cfg['acme']['domains'],['vpn.example.org']);self.assertEqual(cfg['obfs'],self.config['obfs'])
        self.assertNotIn('ip daddr !=',self.f.nft_rules)
        self.m.rollback(Path(result['backup']).name)
        self.assertEqual(json.loads(self.m.path('/etc/hysteria/settings.json').read_text()),self.settings)
    def test_domain_change_is_rejected_before_mutation(self):
        with self.assertRaises(ValueError):self.m.domain_set('different.example.org','1.1.1.1')
        self.assertFalse(self.m.domain_path().exists())
        self.assertEqual(json.loads(self.m.path('/etc/hysteria/config.yaml').read_text()),self.config)


class SafetyTests(unittest.TestCase):
    def test_small_ram_without_swap_requires_build_swap(self):
        self.assertTrue(runtime_safety.memory_swap_required('MemTotal: 967000 kB\nSwapTotal: 0 kB\n'))
        self.assertFalse(runtime_safety.memory_swap_required('MemTotal: 464000 kB\nSwapTotal: 1048576 kB\n'))
    def test_headers_meta_converges_even_when_already_installed(self):
        run=Mock()
        with patch.object(runtime_safety,'headers_meta',return_value=['linux-headers-amd64']),patch.object(runtime_safety.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout='install ok installed')):
            runtime_safety.ensure_headers_meta(run,{})
        run.assert_called_once_with(['apt-get','install','-y','linux-headers-amd64'],env={})
    def test_flags_preserve_keys_peer_and_all_other_parameters(self):
        text='[Interface]\nPrivateKey = preserved\nS1 = 48\nRandomTrailers = off\n[Peer]\nPublicKey = preserved\n'
        iface,sep,peer=text.partition('[Peer]');new=network_setup.set_flags(iface)+sep+peer
        self.assertIn('RandomTrailers = on',new);self.assertIn('DisableCookies = on',new)
        self.assertTrue(new.endswith('[Peer]'+peer));self.assertIn('PrivateKey = preserved',new);self.assertIn('S1 = 48',new)
    def test_kernel_readiness_rejects_go_interface(self):
        def command(args):
            if args[0]=='modinfo':return '3.1.20260812'
            if args[0]=='ip':return json.dumps([{'linkinfo':{'info_kind':'tun'}}])
        with patch.object(kernel_check.Path,'exists',return_value=True),patch.object(kernel_check,'run',side_effect=command):
            with self.assertRaisesRegex(ValueError,'Go fallback'):kernel_check.check('awg3')


class TransportTests(unittest.TestCase):
    def test_temporary_dns_retries_same_request_without_replaying_action(self):
        import app.telegram_api as transport
        settings=SimpleNamespace(token='123:fixture',request_timeout=1)
        api=TelegramAPI(settings);response=Mock();response.__enter__=Mock(return_value=response);response.__exit__=Mock(return_value=False);response.read.return_value=b'{"ok":true}'
        with patch.object(transport.urllib.request,'urlopen',side_effect=[socket.gaierror(-3,'temporary'),ConnectionResetError(),response]) as call,patch.object(transport.time,'sleep'):
            self.assertTrue(api.call('getMe')['ok'])
        self.assertEqual(call.call_count,3);self.assertIs(call.call_args_list[0].args[0],call.call_args_list[2].args[0])

class FinalVerificationTests(unittest.TestCase):
    def test_egress_is_source_bound_and_wrong_public_ip_is_failure(self):
        import verify
        with patch.object(verify.subprocess,'run',return_value=SimpleNamespace(returncode=0,stdout='8.8.8.8')) as call:
            with self.assertRaisesRegex(ValueError,'Не подтверждён выход'):verify.verify_egress('1.1.1.1')
        self.assertEqual(call.call_count,2)
        self.assertIn('1.1.1.1',call.call_args.args[0])
    def test_old_fallback_without_headers_does_not_block_boot_targets(self):
        import tempfile
        with tempfile.TemporaryDirectory() as directory:
            boot=Path(directory)
            for k in ('6.12.85+deb13-amd64','6.12.117+deb13-amd64','6.12.99+deb13-amd64'):
                (boot/('vmlinuz-'+k)).touch()
            self.assertEqual(kernel_check.required_boot_kernels('6.12.99+deb13-amd64',boot),
                             ['6.12.117+deb13-amd64','6.12.99+deb13-amd64'])
            (boot/'vmlinuz').symlink_to('vmlinuz-6.12.85+deb13-amd64')
            self.assertIn('6.12.85+deb13-amd64',kernel_check.required_boot_kernels('6.12.99+deb13-amd64',boot))

    def test_egress_uses_independent_fallback(self):
        import verify
        with patch.object(verify.subprocess,'run',side_effect=[SimpleNamespace(returncode=28,stdout=''),SimpleNamespace(returncode=0,stdout='1.1.1.1\n')]) as call:
            verify.verify_egress('1.1.1.1')
        self.assertEqual(call.call_count,2)
    def test_conntrack_pressure_stops_installation(self):
        with patch.object(runtime_safety.Path,'read_text',side_effect=['65536','60000','30']):
            with self.assertRaisesRegex(ValueError,'80%'):runtime_safety.verify_conntrack()
