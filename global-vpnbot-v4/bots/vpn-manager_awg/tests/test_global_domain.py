import unittest
from unittest.mock import patch, Mock
from pathlib import Path
import test_ip_switch as fixtures
module = fixtures.module
from domain_host import hostname, lookup


class DomainHostTests(unittest.TestCase):
    def test_rejects_injection_and_options(self):
        for name in ['*', '*.example.com', '-t', 'example.com;id', 'example.com\n', 'https://example.com', 'a..com', '1.2.3.4', 'x'*64+'.com']:
            with self.subTest(name=name), self.assertRaises(ValueError): hostname(name)
    def test_deep_idna_and_safe_argv(self):
        self.assertEqual('a.b.xn--e1afmkfd.xn--p1ai',hostname('a.b.пример.рф'))
        with patch('domain_host.subprocess.run',return_value=Mock(returncode=0,stdout='a.b.example.org has address 1.2.3.4\n')) as run:
            self.assertEqual(['1.2.3.4'],lookup('a.b.example.org')['a_records'])
            self.assertEqual(['/usr/bin/host','-W','3','-R','1','-t','A','a.b.example.org.'],run.call_args.args[0])
            self.assertNotIn('shell',run.call_args.kwargs)
    def test_missing_tool_and_timeout(self):
        import subprocess
        for error in [FileNotFoundError(),subprocess.TimeoutExpired('host',10)]:
            with patch('domain_host.subprocess.run',side_effect=error):self.assertFalse(lookup('example.org')['ok'])


class GlobalTransactions(unittest.TestCase):
    def setUp(self):
        self.fixture=fixtures.TransactionTests();self.fixture.setUp();self.addCleanup(self.fixture.doCleanups)
        self.manager=module.GlobalManager(self.fixture.root,self.fixture.run_command)
    def test_save_without_dns_and_rollback(self):
        with patch('global_domain.lookup',side_effect=AssertionError('DNS must not run')):
            result=self.manager.domain_set('a.b.example.org','1.1.1.1')
        self.assertEqual('a.b.example.org',self.manager.domain_config()['domain'])
        self.assertIn('Endpoint = a.b.example.org:',self.manager.path('/clients/alice.conf').read_text())
        self.manager.rollback(Path(result['backup']).name)
        self.assertFalse(self.manager.domain_path().exists())
        self.assertEqual(self.fixture.profile,self.manager.path('/clients/alice.conf').read_text())
    def test_failure_rolls_back_domain(self):
        self.fixture.fail_nft=True
        with self.assertRaises(RuntimeError):self.manager.domain_set('bad-dns.example.org','1.1.1.1')
        self.assertFalse(self.manager.domain_path().exists())
    def test_ip_change_preserves_domain_without_dns(self):
        self.manager.domain_set('example.org','1.1.1.1')
        with patch('global_domain.lookup',side_effect=AssertionError('DNS must not run')):
            self.assertEqual('example.org',self.manager.apply('1.1.1.1')['domain'])
    def test_mismatch_is_diagnostic(self):
        self.manager.domain_set('example.org','1.1.1.1')
        with patch('global_domain.lookup',return_value={'ok':True,'domain':'example.org','a_records':['8.8.8.8']}):
            result=self.manager.domain_check()
        self.assertTrue(result['ok']);self.assertFalse(result['matches'])
        self.assertEqual('example.org',self.manager.domain_config()['domain'])
