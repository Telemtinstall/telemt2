"""HTTPS repair choices must preserve answers and never configure a foreign host."""
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'installer'))
sys.path.insert(0,str(ROOT/'vpn/hysteria2'))
from ini_config import build_plan, validate_silent
from masquerade import normalize_url, prepare_site
from questionnaire import Questionnaire
from state import InstallState
from install_hysteria2 import build_config


class MasqueradeTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.state=InstallState(Path(self.temp.name)/'state.json')
        self.state.data['answers']={'VPN_PUBLIC_HOST':'8.8.8.8','SERVER_CHANNEL_MBIT':'100',
          'BOT_TOKEN':'123:fixture','ADMIN_BOT':'1','HY_DOMAIN':'vpn.example.org','HY_OBFS':'none',
          'HY_MASQUERADE':'https://vpn.example.org','HY_MASQUERADE_MODE':'proxy'}
        self.state.data['protocols']=['hysteria2'];self.state.save()
    def test_domain_and_http_input_become_https_without_user_typing_scheme(self):
        self.assertEqual(normalize_url('example.org'),'https://example.org')
        self.assertEqual(normalize_url('http://example.org:80/path?a=1'),'https://example.org/path?a=1')
        self.assertEqual(normalize_url('example.org:8443/path'),'https://example.org:8443/path')
        for value in ['file:///etc/passwd','https://user:pass@example.org','', 'example.org/a b']:
            with self.assertRaises(ValueError):normalize_url(value)
    def test_malformed_interactive_input_retries_only_site_question(self):
        self.state.data['answers'].pop('HY_MASQUERADE')
        with patch('builtins.input',side_effect=['ftp://example.org','example.org']), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(Questionnaire(self.state).ask_site_url(),'https://example.org')
        self.assertEqual(self.state.data['answers']['BOT_TOKEN'],'123:fixture')
    def test_foreign_domain_without_https_repeats_question_and_keeps_other_answers(self):
        with patch('masquerade.https_available',side_effect=[False,True]), patch('masquerade.points_to_server',return_value=False), patch('builtins.input',return_value='other.example.org') as ask, contextlib.redirect_stdout(io.StringIO()) as output:
            prepare_site(Questionnaire(self.state),'8.8.8.8')
        self.assertIn('Выберите другой домен с HTTPS',output.getvalue())
        ask.assert_called_once_with('Сайт-маскировка (домен или HTTPS-адрес): ')
        self.assertEqual(self.state.data['answers']['HY_MASQUERADE'],'https://other.example.org')
        self.assertEqual(self.state.data['answers']['BOT_TOKEN'],'123:fixture')
        self.assertEqual(self.state.data['protocols'],['hysteria2'])
    def test_owned_domain_offers_certificate_and_reserves_https_port(self):
        with patch('masquerade.https_available',return_value=False), patch('masquerade.points_to_server',return_value=True), patch('builtins.input',return_value='y') as ask, contextlib.redirect_stdout(io.StringIO()):
            prepare_site(Questionnaire(self.state),'8.8.8.8')
        self.assertIn('Настроить сертификат и HTTPS-страницу для vpn.example.org? y/n',ask.call_args.args[0])
        self.assertEqual(self.state.data['answers']['HY_MASQUERADE_MODE'],'proxy')
        self.assertEqual(self.state.data['resolved']['HY_MASQUERADE_MODE'],'local')
        effective=dict(self.state.data['answers'],**self.state.data['resolved'])
        self.assertIn(('tcp',443,'hysteria2:https'),build_plan(effective,['hysteria2']))
    def test_declining_local_certificate_allows_another_https_site(self):
        with patch('masquerade.https_available',side_effect=[False,True]), patch('masquerade.points_to_server',return_value=True), patch('builtins.input',side_effect=['n','other.example.org']), contextlib.redirect_stdout(io.StringIO()):
            prepare_site(Questionnaire(self.state),'8.8.8.8')
        self.assertNotIn('HY_MASQUERADE_MODE',self.state.data['resolved'])
        self.assertEqual(self.state.data['answers']['HY_MASQUERADE'],'https://other.example.org')
    def test_silent_foreign_https_failure_never_prompts_or_installs_a_certificate(self):
        with patch('masquerade.https_available',return_value=False), patch('masquerade.points_to_server',return_value=False), patch('builtins.input',side_effect=AssertionError('silent prompt')), contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(ValueError,'другой домен'):prepare_site(Questionnaire(self.state,True),'8.8.8.8')
        self.assertNotIn('HY_MASQUERADE_MODE',self.state.data['resolved'])
    def test_silent_local_mode_is_explicit_consent_and_does_not_need_existing_https(self):
        self.state.data['answers']['HY_MASQUERADE_MODE']='local'
        validate_silent(self.state.data['answers'],['hysteria2'])
        with patch('masquerade.https_available') as probe, patch('masquerade.points_to_server',return_value=True), patch('builtins.input',side_effect=AssertionError('silent prompt')):
            prepare_site(Questionnaire(self.state,True),'8.8.8.8')
        probe.assert_not_called()
        self.assertEqual(self.state.data['resolved']['HY_MASQUERADE_MODE'],'local')
    def test_valid_remote_https_needs_no_extra_question(self):
        with patch('masquerade.https_available',return_value=True), patch('masquerade.points_to_server') as lookup, patch('builtins.input',side_effect=AssertionError('extra question')):
            prepare_site(Questionnaire(self.state),'8.8.8.8')
        lookup.assert_not_called()
    def test_local_https_uses_shared_acme_certificate_and_no_reverse_proxy_loop(self):
        settings={'domain':'vpn.example.org','bind_ip':'8.8.8.8','port':443,'obfs':'none',
          'stats_port':19090,'stats_secret':'fixture','masquerade_mode':'local','masquerade':'https://site.example.org:8443'}
        config=build_config(settings)
        self.assertEqual(config['acme']['domains'],['vpn.example.org','site.example.org'])
        self.assertEqual(config['masquerade']['type'],'string')
        self.assertEqual(config['masquerade']['listenHTTPS'],'8.8.8.8:8443')
        self.assertNotIn('proxy',config['masquerade'])
    def test_changing_site_invalidates_previous_resolved_local_mode(self):
        self.state.data['resolved']['HY_MASQUERADE_MODE']='local'
        self.state.merge({'HY_MASQUERADE':'https://other.example.org'},['hysteria2'])
        self.assertNotIn('HY_MASQUERADE_MODE',self.state.data['resolved'])



class MasqueradeResumeTests(unittest.TestCase):
    def test_unchanged_ini_does_not_erase_interactive_site_correction(self):
        with tempfile.TemporaryDirectory() as directory:
            state=InstallState(Path(directory)/'state.json')
            source={'HY_MASQUERADE':'https://bad.example.org'}
            state.merge(source,['hysteria2'],force_keys=set())
            state.data['answers']['HY_MASQUERADE']='https://working.example.org'
            state.data['done']=['hysteria2'];state.save()
            resumed=InstallState(state.path)
            resumed.merge(source,['hysteria2'],force_keys=set())
            self.assertEqual(resumed.data['answers']['HY_MASQUERADE'],'https://working.example.org')
    def test_explicit_cli_override_can_replace_site_before_install(self):
        with tempfile.TemporaryDirectory() as directory:
            state=InstallState(Path(directory)/'state.json')
            source={'HY_MASQUERADE':'https://first.example.org'}
            state.merge(source,['hysteria2'],force_keys=set())
            state.data['answers']['HY_MASQUERADE']='https://second.example.org'
            state.merge(source,['hysteria2'],force_keys={'HY_MASQUERADE'})
            self.assertEqual(state.data['answers']['HY_MASQUERADE'],'https://first.example.org')

if __name__=='__main__':unittest.main()
