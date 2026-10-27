import contextlib
from concurrent.futures import ThreadPoolExecutor
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from app.job_queue import JobQueue, QueuedActions, request_context
from app.servers import VpnServer, load_server_config
from app import keyboards
from worker import CaptureTelegram, process, deliver

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'installer'))
sys.path.insert(0,str(ROOT/'vpn/hysteria2'))
from ports import validate, occupied_ports
from install import selected_valid, kernel_ready, kernel_preflight, atomic_json
import hysteria2ctl as hy
from install_hysteria2 import build_config

class QueueTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.path=Path(self.temp.name)/'jobs.sqlite3';self.q=JobQueue(self.path)
    def test_twenty_concurrent_requests_survive_reopen_fifo(self):
        with ThreadPoolExecutor(max_workers=10) as pool:
            ids=list(pool.map(lambda n:self.q.enqueue(str(n),'1',1,'create_client',[1,'hy',str(n)],{}),range(20)))
        self.assertEqual(len(set(ids)),20)
        q=JobQueue(self.path)
        for expected in range(1,21):
            job=q.claim();self.assertEqual(job['id'],expected)
            self.assertIsNone(q.claim())
            q.finish(expected,'done')
        self.assertIsNone(q.claim())
        self.assertEqual(self.path.stat().st_mode&0o777,0o600)
    def test_deduplication(self):
        first=self.q.enqueue('u1','1',1,'show_list',[1,'hy'],{})
        self.assertEqual(first,self.q.enqueue('u1','1',1,'show_list',[1,'hy'],{}))
        self.assertEqual(len(self.q.recent()),1)
    def test_recovery_never_replays_running_change(self):
        first=self.q.enqueue('a','1',1,'create_client',[],{})
        self.q.enqueue('b','1',1,'delete_client',[],{})
        self.q.claim();self.q.recover();self.assertIsNone(self.q.claim())
        self.assertEqual(self.q.recent()[-1]['state'],'needs_review')
        self.q.resolve(first,'done');self.assertEqual(self.q.claim()['token'],'b')
    def test_enqueue_does_not_call_cli(self):
        base=SimpleNamespace(telegram=Mock(),create_client=Mock())
        proxy=QueuedActions(base,self.q)
        ctx=request_context.set(('1',44))
        try:name=proxy.create_client(1,'hy')
        finally:request_context.reset(ctx)
        base.create_client.assert_not_called();self.assertTrue(name.startswith('vpn-'))
        self.assertEqual(self.q.claim()['method'],'create_client')
    def test_worker_rechecks_revoked_permissions(self):
        self.q.enqueue('a','2',2,'create_client',[2,'hy','anna'],{})
        actions=SimpleNamespace(settings=SimpleNamespace(allowed_users={'1'}),access_store=SimpleNamespace(is_dynamic_admin=lambda _:False))
        capture=CaptureTelegram(Mock())
        self.assertTrue(process(self.q,actions,capture))
        self.assertEqual(self.q.recent()[0]['state'],'failed')
    def test_worker_failure_marks_mutation_uncertain(self):
        self.q.enqueue('a','1',1,'create_client',[1,'hy','anna'],{})
        actions=SimpleNamespace(settings=SimpleNamespace(allowed_users={'1'}),access_store=None,create_client=Mock(side_effect=RuntimeError()))
        process(self.q,actions,CaptureTelegram(Mock()))
        self.assertEqual(self.q.recent()[0]['state'],'needs_review')
    def test_outbox_retry_does_not_repeat_server_change(self):
        self.q.enqueue('a','1',1,'create_client',[1,'hy','anna'],{})
        real=Mock();capture=CaptureTelegram(real)
        def create(*_):capture.send_message(1,'created')
        actions=SimpleNamespace(settings=SimpleNamespace(allowed_users={'1'}),access_store=None,create_client=Mock(side_effect=create))
        process(self.q,actions,capture)
        real.send_message.side_effect=RuntimeError('offline')
        deliver(self.q,real,actions);self.assertEqual(len(self.q.pending_messages()),1)
        real.send_message.side_effect=None;deliver(self.q,real,actions)
        self.assertEqual(len(self.q.pending_messages()),0);actions.create_client.assert_called_once()
        with self.q.db() as db:self.assertEqual(db.execute('SELECT payload FROM outbox').fetchone()[0],'{}')

class InstallerTests(unittest.TestCase):
    def test_exclusive_protocols_and_duplicates(self):
        with self.assertRaises(ValueError):selected_valid(['vless','hysteria2'])
        self.assertEqual(selected_valid(['amnezia31','amnezia31']),['amnezia31'])
        with self.assertRaises(ValueError):selected_valid([])
    def test_tcp_and_udp_same_number_are_allowed(self):
        validate([('tcp',443,'vless'),('udp',443,'awg')])
    def test_conflicts_and_invalid_port_rejected(self):
        for plan,occupied in [([('udp',443,'a'),('udp',443,'b')],[]),([('tcp',80,'acme')],[('tcp',80)]),([('udp',65536,'a')],[])]:
            with self.assertRaises(ValueError):validate(plan,occupied)
    def test_kernel_preflight_precedes_questionnaire(self):
        self.assertTrue(kernel_ready('6.12.1-amd64',True))
        self.assertFalse(kernel_ready('6.1.0',True));self.assertFalse(kernel_ready('6.12.1',False))
    def test_good_kernel_no_package_changes_or_questions(self):
        with patch('platform.release',return_value='6.12.1-amd64'),patch.object(Path,'exists',return_value=True),patch('install.run') as run,patch('builtins.input',side_effect=AssertionError('question')):
            kernel_preflight();run.assert_not_called()
    def test_atomic_answers_are_private_and_persisted(self):
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'answers.json';atomic_json(path,{'answers':{'BOT_TOKEN':'fixture'}})
            self.assertEqual(path.stat().st_mode&0o777,0o600)
            self.assertEqual(json.loads(path.read_text())['answers']['BOT_TOKEN'],'fixture')
    def test_existing_protocol_scripts_are_identical(self):
        import hashlib
        expected=json.loads((Path(__file__).parent/'preserved_protocol_sha256.json').read_text())['sha256']
        for relative, digest in expected.items():
            self.assertEqual(hashlib.sha256((ROOT/relative).read_bytes()).hexdigest(),digest,relative)

class HysteriaTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.root=Path(self.temp.name)
        self.patch=patch.object(hy,'ROOT',self.root);self.patch.start();self.addCleanup(self.patch.stop)
        self.settings={'domain':'vpn.example.org','port':443,'bind_ip':'203.0.113.10','obfs':'none','masquerade':'https://example.org','stats_port':19090,'stats_secret':'fixture','obfs_password':'obfs secret','min_packet':512,'max_packet':1200}
        hy.write_json(self.root/'settings.json',self.settings);hy.write_json(self.root/'users.json',{})
    def test_add_does_not_generate_qr_and_keeps_individual_credentials(self):
        with patch.object(hy.subprocess,'check_output',side_effect=AssertionError('installer QR')):
            a=hy.execute(['-j','add','anna']);b=hy.execute(['-j','add','bob'])
        self.assertNotEqual(a['link'],b['link']);self.assertNotIn('qr_png_base64',a)
        self.assertEqual(hy.execute(['show','anna'])['uuid'],a['uuid'])
        with self.assertRaises(ValueError):hy.execute(['add','anna'])
    def test_authentication_and_rejection(self):
        hy.execute(['add','anna']);users=json.loads((self.root/'users.json').read_text())
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(hy.authenticate(['address','anna:'+users['anna']['password'],'0']),0)
        self.assertEqual(output.getvalue().strip(),'anna')
        self.assertEqual(hy.authenticate(['address','anna:wrong','0']),1)
    def test_modes_match_server_uri_and_yaml(self):
        hy.execute(['add','anna'])
        for mode in ['none','salamander','gecko']:
            self.settings['obfs']=mode;hy.write_json(self.root/'settings.json',self.settings)
            data=hy.execute(['show','anna']);config=build_config(self.settings)
            clash=json.loads(data['clash_yaml'])['proxies'][0]
            if mode=='none':
                self.assertNotIn('obfs',config);self.assertNotIn('obfs=',data['link']);self.assertIn('masquerade',config)
            else:
                self.assertEqual(config['obfs']['type'],mode);self.assertIn('obfs='+mode,data['link']);self.assertEqual(clash['obfs'],mode)
            self.assertFalse(clash['skip-cert-verify'])
    def test_qr_encodes_same_uri(self):
        hy.execute(['add','anna'])
        with patch.object(hy.subprocess,'check_output',return_value=b'png') as command:
            data=hy.execute(['qr','anna'])
        self.assertEqual(command.call_args.kwargs['input'],data['link'].encode())
    def test_delete_removes_auth_and_kicks(self):
        hy.execute(['add','anna'])
        with patch.object(hy,'api') as api:hy.execute(['delete','anna']);api.assert_called_once_with(self.settings,'/kick',['anna'])
        self.assertEqual(hy.execute(['list'])['clients'],[])
    def test_api_is_loopback_and_key_protected(self):
        config=build_config(self.settings)
        self.assertEqual(config['trafficStats']['listen'],'127.0.0.1:19090')
        self.assertEqual(config['acme']['type'],'http')
        self.assertEqual(config['outbounds'][0]['direct']['bindIPv4'],self.settings['bind_ip'])
    def test_bot_buttons_have_all_three_exports(self):
        for builder in [keyboards.client_actions,keyboards.user_client_actions]:
            rows=builder('hysteria2','hysteria2','anna')['inline_keyboard']
            values={b['callback_data'].split(':')[0] for row in rows for b in row}
            self.assertTrue({'qr','link','conffile'}<=values)
        server=VpnServer(load_server_config({'id':'hysteria2','protocol':'hysteria2','command':'/usr/local/sbin/hysteria2ctl'}))
        self.assertEqual(server.service,'hysteria2.service')


class IniTests(unittest.TestCase):
    def write(self,text):
        temp=tempfile.TemporaryDirectory();self.addCleanup(temp.cleanup)
        path=Path(temp.name)/'install.ini';path.write_text(text);path.chmod(0o600);return path
    def test_commented_example_loads_and_selects_only_hysteria_and_awg31(self):
        from ini_config import load_ini, validate_answers
        answers,selected=load_ini(ROOT/'silent.example.ini')
        self.assertEqual(selected,['amnezia31','hysteria2']);self.assertEqual(answers['HY_OBFS'],'salamander')
        validate_answers(answers,selected)
    def test_conflicting_cli_choice_rejected(self):
        from ini_config import merge_protocols
        with self.assertRaisesRegex(ValueError,'Конфликт'):merge_protocols(['hysteria2'],['vless'])
        self.assertEqual(merge_protocols(['hysteria2'],['hysteria2','hysteria2']),['hysteria2'])
    def test_protocol_choice_requires_one_or_two(self):
        from ini_config import load_ini
        for value in ['','0','1,2','vless']:
            path=self.write('[protocols]\namnezia20=no\namnezia31=yes\nvless_or_hysteria2='+value)
            with self.assertRaisesRegex(ValueError,'1 или 2'):load_ini(path)
    def test_duplicate_and_unknown_options_rejected(self):
        from ini_config import load_ini
        for text in ['[server]\npublic_ip=1\npublic_ip=2','[server]\npublc_ip=1','[unknown]\na=b','[DEFAULT]\na=b']:
            with self.assertRaises(ValueError):load_ini(self.write(text))
    def test_secrets_are_literal_and_need_private_permissions(self):
        from ini_config import load_ini
        path=self.write('[telegram]\nbot_token=123:abc%foo#bar;baz\n')
        self.assertEqual(load_ini(path)[0]['BOT_TOKEN'],'123:abc%foo#bar;baz')
        path.chmod(0o644)
        with self.assertRaisesRegex(ValueError,'0600'):load_ini(path)
    def test_selected_port_conflict_rejected_before_install(self):
        from ini_config import validate_answers
        with self.assertRaisesRegex(ValueError,'Конфликт'):validate_answers({'AWG31_PORT':'443','HY_PORT':'443'},['amnezia31','hysteria2'])
        validate_answers({'AWG31_PORT':'443','VLESS_PORT':'443'},['amnezia31','vless'])
    def test_unused_protocol_settings_do_not_reserve_ports(self):
        from ini_config import validate_answers
        validate_answers({'VLESS_PORT':'443','HY_PORT':'invalid'},['vless'])

    def test_silent_missing_answers_and_example_token_fail_before_kernel(self):
        from ini_config import validate_silent
        with self.assertRaisesRegex(ValueError,'[Нн]е заполнены'):validate_silent({},['hysteria2'])
        with self.assertRaisesRegex(ValueError,'BOT_TOKEN'):
            validate_silent({'VPN_PUBLIC_HOST':'8.8.8.8','ADMIN_BOT':'1','BOT_TOKEN':'REPLACE_BOT_TOKEN'},['amnezia31'])

if __name__=='__main__':unittest.main()
