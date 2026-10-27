"""Run the v3 coordinator against fake system commands and real private checkpoints."""
import contextlib
import io
import json
import subprocess
import tempfile
from pathlib import Path
from types import SimpleNamespace
import sys
import unittest
from unittest.mock import Mock, mock_open, patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'installer'))
import detection
import install
from ini_config import build_plan, validate_common, validate_silent
from questionnaire import Questionnaire
from state import InstallState
from execution import StageRunner, safe_output


class AutoTests(unittest.TestCase):
    def test_route_source_selects_assigned_public_ip(self):
        addresses = [{'addr_info': [{'local': '8.8.8.8'}, {'local': '9.9.9.9'}, {'local': '10.0.0.1'}]}]
        with patch('detection.subprocess.check_output', return_value=json.dumps(addresses)), patch('detection.subprocess.run', return_value=SimpleNamespace(stdout='[{"prefsrc":"9.9.9.9"}]')):
            self.assertEqual(detection.public_ipv4(), '9.9.9.9')
    def test_single_ip_without_route_and_ambiguous_ips(self):
        with patch('detection.assigned_ipv4', return_value={'8.8.8.8'}), patch('detection.subprocess.run', side_effect=subprocess.CalledProcessError(1, 'ip')):
            self.assertEqual(detection.public_ipv4(), '8.8.8.8')
        with patch('detection.assigned_ipv4', return_value={'8.8.8.8', '9.9.9.9'}), patch('detection.subprocess.run', return_value=SimpleNamespace(stdout='[]')):
            with self.assertRaisesRegex(ValueError, 'несколько'): detection.public_ipv4()
    def test_speedtest_units_and_rounding(self):
        report = Mock()
        with patch('detection.shutil.which', return_value='/usr/bin/speedtest-cli'), patch('detection.subprocess.run', return_value=SimpleNamespace(stdout='{"download":249300000,"upload":99000000}')) as command:
            self.assertEqual(detection.channel_speed(report), ('250', 'speedtest'))
        self.assertEqual(command.call_args.kwargs['timeout'], 90)
    def test_every_speedtest_failure_falls_back_to_100(self):
        errors = [FileNotFoundError(), subprocess.TimeoutExpired('speedtest-cli', 90), subprocess.CalledProcessError(1, 'speedtest-cli')]
        for error in errors:
            report = Mock()
            with patch('detection.shutil.which', return_value='/usr/bin/speedtest-cli'), patch('detection.subprocess.run', side_effect=error):
                self.assertEqual(detection.channel_speed(report), ('100', 'fallback'))
            report.assert_called_once_with(detection.SPEEDTEST_WARNING)
        for payload in ['', '{}', '{"download":0,"upload":100}', '{"download":NaN,"upload":100}', '{"download":100,"upload":Infinity}']:
            with patch('detection.shutil.which', return_value='speedtest-cli'), patch('detection.subprocess.run', return_value=SimpleNamespace(stdout=payload)):
                self.assertEqual(detection.channel_speed(lambda _: None), ('100', 'fallback'))
        with patch('detection.shutil.which', return_value=None):
            self.assertEqual(detection.channel_speed(lambda _: None), ('100', 'fallback'))
    def test_explicit_settings_do_not_run_detection_or_speedtest(self):
        state = SimpleNamespace(data={'answers': {'VPN_PUBLIC_HOST': '8.8.8.8', 'SERVER_CHANNEL_MBIT': '200'}, 'resolved': {}}, save=Mock())
        with patch('detection.public_ipv4') as ip, patch('detection.channel_speed') as speed:
            self.assertEqual(detection.resolve_auto(state)['SERVER_CHANNEL_MBIT'], '200')
            ip.assert_not_called(); speed.assert_not_called()
    def test_auto_is_valid_and_invalid_speeds_rejected(self):
        answers = {'VPN_PUBLIC_HOST': 'auto', 'SERVER_CHANNEL_MBIT': 'auto', 'BOT_TOKEN': '123:fixture', 'ADMIN_BOT': '1', 'HY_DOMAIN': 'vpn.example.org', 'HY_OBFS': 'salamander'}
        validate_silent(answers, ['hysteria2'])
        for value in ['0', '-1', 'nan', 'inf', 'wrong']:
            with self.assertRaises(ValueError): validate_common(dict(answers, SERVER_CHANNEL_MBIT=value))


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(); self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'state.json'
        self.answers = {'VPN_PUBLIC_HOST': 'auto', 'SERVER_CHANNEL_MBIT': 'auto', 'BOT_TOKEN': '123:fixture', 'ADMIN_BOT': '1', 'HY_DOMAIN': 'vpn.example.org', 'HY_OBFS': 'salamander'}
        self.args = install.parser().parse_args(['--silent', '--state-file', str(self.path)])

    @contextlib.contextmanager
    def fake_system(self, events, kernel=None):
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch('install.require_platform'))
            stack.enter_context(patch('install.open', mock_open()))
            stack.enter_context(patch('install.fcntl.flock'))
            stack.enter_context(patch('install.Path', side_effect=lambda p: SimpleNamespace(exists=lambda: False) if str(p) == '/root/vpnbot' else Path(p)))
            stack.enter_context(patch('install.reject_opposite'))
            stack.enter_context(patch('install.occupied_ports', return_value=set()))
            stack.enter_context(patch('install.assigned_ipv4', return_value={'8.8.8.8'}))
            stack.enter_context(patch('install.install_speedtest'))
            stack.enter_context(patch('detection.public_ipv4', return_value='8.8.8.8'))
            speed = stack.enter_context(patch('detection.channel_speed', return_value=('100', 'fallback')))
            stack.enter_context(patch('install.kernel_preflight', side_effect=kernel or (lambda *a: events.append('kernel'))))
            stack.enter_context(patch('execution.subprocess.run', side_effect=lambda command, **kw: events.append(command)))
            protocol = stack.enter_context(patch.object(StageRunner, '_protocol', side_effect=lambda command: events.append(str(command[-1])) or 0))
            stack.enter_context(patch('builtins.input', side_effect=AssertionError('unexpected question')))
            stack.enter_context(patch('getpass.getpass', side_effect=AssertionError('unexpected secret question')))
            stack.enter_context(contextlib.redirect_stdout(io.StringIO()))
            yield speed, protocol

    def test_full_silent_install_and_resume_preserve_auto_and_skip_completed_modules(self):
        events = []
        with self.fake_system(events) as (speed, protocol):
            install.install(self.args, self.answers, ['amnezia31', 'hysteria2'])
            install.install(self.args, self.answers, ['hysteria2', 'amnezia31'])
        self.assertEqual(events[0], 'kernel')
        speed.assert_called_once(); self.assertEqual(protocol.call_count, 2)
        data = json.loads(self.path.read_text())
        self.assertEqual(data['answers']['VPN_PUBLIC_HOST'], 'auto')
        self.assertEqual(data['resolved']['VPN_PUBLIC_HOST'], '8.8.8.8')
        self.assertEqual(data['resolved']['SERVER_CHANNEL_MBIT'], '100')
        self.assertEqual(data['answers']['SERVER_CHANNEL_MBIT'], 'auto')
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertIn('bot', data['done']); self.assertNotIn('running', data)
        self.assertNotIn('vless', data['done']); self.assertNotIn('amnezia20', data['done'])

    def test_reboot_happens_before_any_question_or_package_stage(self):
        events = []
        def reboot(*_): raise SystemExit(75)
        with self.fake_system(events, reboot), patch('install.Questionnaire') as questions:
            with self.assertRaises(SystemExit) as caught:
                install.install(self.args, self.answers, ['amnezia31', 'hysteria2'])
            self.assertEqual(caught.exception.code, 75); questions.assert_not_called()
        self.assertEqual(events, [])
        data = json.loads(self.path.read_text())
        self.assertEqual(data['answers']['HY_DOMAIN'], 'vpn.example.org'); self.assertEqual(data['done'], [])

    def test_busy_port_prevents_any_protocol_change(self):
        events = []
        with self.fake_system(events) as (_, protocol), patch('install.occupied_ports', return_value={('udp', 443)}):
            with self.assertRaisesRegex(ValueError, 'уже занят'):
                install.install(self.args, self.answers, ['hysteria2'])
            protocol.assert_not_called()
        self.assertNotIn('backup', json.loads(self.path.read_text())['done'])

    def test_missing_silent_answer_prevents_kernel_and_all_commands(self):
        events = []
        with self.fake_system(events), patch('install.kernel_preflight') as kernel:
            with self.assertRaisesRegex(ValueError, 'BOT_TOKEN'):
                install.install(self.args, {}, ['amnezia31'])
            kernel.assert_not_called()
        self.assertEqual(events, [])

    def test_interrupted_questionnaire_does_not_repeat_accepted_choices(self):
        state = InstallState(self.path)
        with patch('builtins.input', side_effect=['n', 'n', KeyboardInterrupt()]):
            with self.assertRaises(KeyboardInterrupt): Questionnaire(state).select_protocols()
        reloaded = InstallState(self.path)
        with patch('builtins.input', side_effect=['y', '2']) as ask:
            self.assertEqual(Questionnaire(reloaded).select_protocols(), ['amnezia31', 'hysteria2'])
        self.assertEqual(ask.call_count, 2)

    def test_protocol_crash_requires_explicit_resolution(self):
        state = InstallState(self.path); state.data['running'] = 'hysteria2'; state.save()
        runner = StageRunner(state, {})
        with patch('execution.subprocess.run') as command:
            with self.assertRaisesRegex(ValueError, 'сверьте'): runner.run('bot', ['echo', 'never'])
            command.assert_not_called()
        state.resolve_stage('hysteria2', 'retry')
        self.assertNotIn('running', InstallState(self.path).data)
        self.assertNotIn('hysteria2', state.data['done'])

    def test_safe_package_failure_can_resume_without_editing_state(self):
        state = InstallState(self.path)
        with patch('execution.subprocess.run', side_effect=subprocess.CalledProcessError(1, 'apt')):
            with self.assertRaises(subprocess.CalledProcessError): StageRunner(state, {}).run('packages', ['apt'])
        self.assertNotIn('running', InstallState(self.path).data)
        with patch('execution.subprocess.run'): StageRunner(state, {}).run('packages', ['apt'])
        self.assertIn('packages', state.data['done'])

    def test_output_filter_suppresses_profiles_and_credentials(self):
        for text in ['vless://fixture', 'PrivateKey = abc', 'PresharedKey = abc', 'Password: abc', 'secret=abc', '\x1b[0m QR', '█▀▄', 'fixture-sensitive']:
            self.assertFalse(safe_output(text, ['fixture-sensitive']))
        self.assertTrue(safe_output('Служба запущена.'))

    def test_checkpoint_command_keeps_custom_state_path_without_secrets(self):
        command = install.resume_command(self.path)
        self.assertIn('--state-file', command); self.assertIn(str(self.path), command)
        self.assertNotIn('fixture', command)



class MutationTests(unittest.TestCase):
    def test_failed_server_delete_keeps_bot_records(self):
        from app.queued_actions import WorkerActions
        server = Mock(id='hy', title='Hysteria 2')
        server.show.return_value = {'name': 'anna'}
        server.delete.side_effect = RuntimeError('server failure')
        access, traffic = Mock(), Mock()
        actions = WorkerActions(SimpleNamespace(), Mock(), SimpleNamespace(get=lambda _: server), Mock(), traffic, access)
        actions.verify_profile = Mock()
        with self.assertRaises(RuntimeError): actions.delete_client(1, 'hy', 'anna', 5)
        access.purge_profile.assert_not_called(); traffic.delete_user.assert_not_called()
    def test_delete_checks_server_before_purging_records(self):
        from app.queued_actions import WorkerActions
        events = []
        server = Mock(id='hy', title='Hysteria 2')
        server.show.return_value = {'name': 'anna'}
        server.delete.side_effect = lambda _: events.append('delete') or {'name': 'anna'}
        server.list_clients.side_effect = lambda: events.append('verify') or []
        access, traffic = Mock(), Mock()
        access.purge_profile.side_effect = lambda *_: events.append('purge')
        traffic.delete_user.side_effect = lambda *_: events.append('traffic')
        actions = WorkerActions(SimpleNamespace(), Mock(), SimpleNamespace(get=lambda _: server), Mock(), traffic, access)
        actions.verify_profile = Mock(); actions.show_list = Mock()
        actions.delete_client(1, 'hy', 'anna', 5)
        self.assertEqual(events, ['delete', 'verify', 'purge', 'traffic'])
    def test_interrupted_read_requeues_but_mutation_requires_review(self):
        from app.job_queue import JobQueue
        with tempfile.TemporaryDirectory() as directory:
            queue = JobQueue(Path(directory) / 'jobs.sqlite3')
            queue.enqueue('read', '1', 1, 'show_list', [1, 'hy'], {})
            queue.claim(); queue.recover()
            self.assertEqual(queue.claim()['token'], 'read')
            queue.finish(1, 'done')
            queue.enqueue('change', '1', 1, 'create_client', [1, 'hy', 'anna'], {})
            queue.claim(); queue.recover()
            self.assertIsNone(queue.claim())
            self.assertEqual(queue.recent()[0]['state'], 'needs_review')


class KernelAndVerificationTests(unittest.TestCase):
    def test_kernel_pause_records_no_questions_and_prints_resume_path(self):
        from system_prepare import kernel_preflight
        new = Path('/lib/modules/6.12.1/build/Makefile')
        with patch('system_prepare.platform.release', return_value='6.1.0-amd64'), patch('system_prepare.platform.freedesktop_os_release', return_value={'ID':'debian'}), patch('system_prepare.platform.machine', return_value='x86_64'), patch.object(Path, 'exists', lambda p: str(p) == '/boot/vmlinuz-6.12.1'), patch.object(Path, 'glob', return_value=[new]), patch('system_prepare.run') as command, patch('builtins.input', side_effect=AssertionError('question')), contextlib.redirect_stdout(io.StringIO()) as output:
            with self.assertRaises(SystemExit) as paused:
                kernel_preflight('bash /package/install-global.sh --state-file /root/custom.json')
        self.assertEqual(paused.exception.code, 75)
        self.assertIn('/root/custom.json', output.getvalue())
        self.assertEqual(command.call_count, 2)
        self.assertIn('linux-image-amd64', command.call_args.args[0])
    def test_verification_checks_only_selected_cli_and_every_required_service(self):
        from verify import verify
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root/'servers.json').write_text(json.dumps([{'id':'hysteria2','command':'/ctl/hy','service':'hysteria2.service'}]))
            commands = []
            def run(command, **kwargs):
                commands.append(command)
                return SimpleNamespace(returncode=0, stdout='{"ok":true,"clients":[]}')
            with patch('verify.subprocess.run', side_effect=run), contextlib.redirect_stdout(io.StringIO()):
                verify(root, ['hysteria2'])
            self.assertIn(['/ctl/hy','-j','list'], commands)
            for name in ['hysteria2.service','vpnbot.service','vpnbot-worker.service','vpnbot-traffic.timer','vpnbot-channel.timer']:
                self.assertIn(['systemctl','is-active','--quiet',name],commands)
            self.assertFalse(any('awgctl' in str(c) or 'vlessctl' in str(c) for c in commands))
    def test_optional_speedtest_package_failure_is_nonfatal(self):
        from system_prepare import install_speedtest
        with patch('system_prepare.shutil.which', return_value=None), patch('system_prepare.subprocess.run', side_effect=subprocess.CalledProcessError(100,'apt')), contextlib.redirect_stdout(io.StringIO()) as output:
            install_speedtest({})
        self.assertIn('100 Мбит/с',output.getvalue())
    def test_changing_auto_before_vpn_resets_resolution_but_after_vpn_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            state=InstallState(Path(directory)/'state.json')
            state.merge({'SERVER_CHANNEL_MBIT':'auto'}, ['hysteria2'])
            state.data['resolved']['SERVER_CHANNEL_MBIT']='100'
            state.data['done']=['packages']
            state.merge({'SERVER_CHANNEL_MBIT':'200'}, ['hysteria2'])
            self.assertNotIn('SERVER_CHANNEL_MBIT', state.data['resolved'])
            state.data['done'].append('hysteria2');state.save()
            with self.assertRaisesRegex(ValueError,'нельзя менять'):
                state.merge({'SERVER_CHANNEL_MBIT':'auto'}, ['hysteria2'])


class ControllerFailureTests(unittest.TestCase):
    def test_controller_proven_no_change_does_not_block_following_jobs(self):
        from app.job_queue import JobQueue
        from app.servers import ControllerError
        from worker import process, CaptureTelegram
        with tempfile.TemporaryDirectory() as directory:
            queue = JobQueue(Path(directory)/'jobs.sqlite3')
            queue.enqueue('first','1',1,'create_client',[1,'hy','anna'],{})
            queue.enqueue('next','1',1,'show_list',[1,'hy'],{})
            actions = SimpleNamespace(settings=SimpleNamespace(allowed_users={'1'}), access_store=None,
                                      create_client=Mock(side_effect=ControllerError('already exists',unchanged=True)))
            process(queue, actions, CaptureTelegram(Mock()))
            self.assertEqual(queue.recent()[-1]['state'],'failed')
            self.assertEqual(queue.claim()['token'],'next')
    def test_hysteria_duplicate_is_explicitly_unchanged(self):
        import os
        script=ROOT/'vpn/hysteria2/hysteria2ctl.py'
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)
            (path/'settings.json').write_text(json.dumps({'domain':'vpn.example.org','port':443,'obfs':'none'}))
            (path/'users.json').write_text(json.dumps({'anna':{'password':'fixture','identity':'fixture-id'}}))
            result=subprocess.run([sys.executable,str(script),'-j','add','anna'],env=dict(os.environ,HYSTERIA_STATE_DIR=directory),text=True,capture_output=True)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse(json.loads(result.stdout)['changed'])
            self.assertEqual(json.loads((path/'users.json').read_text())['anna']['password'],'fixture')
    def test_queued_creation_refresh_does_not_open_a_preexisting_name(self):
        from app.handlers import Handlers
        from app.state import BotState
        from app import keyboards
        state=BotState();state.set_context('1',1,'create_method','hy')
        actions=SimpleNamespace(is_queued=True,create_client=Mock(return_value='anna'),traffic_store=None,
                                enabled_servers=lambda: [],servers=SimpleNamespace(servers=[]))
        settings=SimpleNamespace(private_only=True,allowed_users={'1'},servers_path=None)
        access=SimpleNamespace(has_access=lambda _: True)
        handler=Handlers(settings,Mock(),actions,state,access)
        handler.handle_message({'chat':{'id':1,'type':'private'},'from':{'id':1},'text':keyboards.CREATE_DEFAULT})
        actions.create_client.assert_called_once_with(1,'hy')
        self.assertEqual(state.context('1',1)['screen'],'protocol')
        self.assertIsNone(state.context('1',1)['ref'])


class ReconciliationTests(unittest.TestCase):
    def test_startup_uses_queue_instead_of_direct_service_change(self):
        from app.reconciliation import enqueue_reconciliation
        server=Mock();server.is_active.return_value=False
        actions=SimpleNamespace(settings=SimpleNamespace(allowed_users={'1'}),
            access_store=SimpleNamespace(protocol_states=lambda:{'hy':True}),
            servers=SimpleNamespace(get=lambda _:server))
        queue=Mock()
        enqueue_reconciliation(queue,actions)
        server.set_enabled.assert_not_called()
        queue.enqueue.assert_called_once()
        self.assertEqual(queue.enqueue.call_args.args[3], 'toggle_protocol')
        self.assertEqual(queue.enqueue.call_args.args[4], [1,'hy',True,'1'])


class QuestionnaireUXTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.state=InstallState(Path(self.temp.name)/'state.json')
    def test_yes_no_and_numbered_protocol_prompt_have_no_default(self):
        with patch('builtins.input',side_effect=['','y','2']) as prompt, contextlib.redirect_stdout(io.StringIO()) as output:
            chosen=Questionnaire(self.state).select_protocols()
        self.assertEqual(chosen,['amnezia20','amnezia31','hysteria2'])
        self.assertTrue(prompt.call_args_list[0].args[0].endswith('? y/n: '))
        self.assertEqual(prompt.call_args.args[0],'Выберите 1/2: ')
        self.assertIn('1 — VLESS\n2 — Hysteria 2\n',output.getvalue())
    def test_saved_russian_answers_resume_without_repeating_questions(self):
        self.state.data['selection']={'all':'да'};self.state.save()
        with patch('builtins.input',return_value='1') as prompt, contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(Questionnaire(self.state).select_protocols(),['amnezia20','amnezia31','vless'])
        prompt.assert_called_once_with('Выберите 1/2: ')
        self.assertEqual(self.state.data['selection']['all'],'y')
    def test_hysteria_modes_are_explained_before_input(self):
        self.state.data['answers']={'VPN_PUBLIC_HOST':'8.8.8.8','VPN_INITIAL_CLIENT':'vpnuser1',
            'SERVER_CHANNEL_MBIT':'100','ADMIN_BOT':'1','BOT_TOKEN':'123:fixture','HY_PORT':'443',
            'HY_DOMAIN':'vpn.example.org','HY_MASQUERADE':'https://example.org'}
        with patch('builtins.input',return_value='1') as prompt, contextlib.redirect_stdout(io.StringIO()) as output:
            Questionnaire(self.state).collect(['hysteria2'])
        prompt.assert_called_once_with('Выберите 1/2/3: ')
        self.assertIn('none — обычный HTTP/3',output.getvalue())
        self.assertIn('salamander — пакеты выглядят как случайные данные',output.getvalue())
        self.assertIn('gecko — экспериментальный',output.getvalue())
        self.assertEqual(self.state.data['answers']['HY_OBFS'],'none')

if __name__ == '__main__': unittest.main()
