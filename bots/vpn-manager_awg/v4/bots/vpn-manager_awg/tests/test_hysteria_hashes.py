import hashlib
from pathlib import Path
import sys
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'vpn/hysteria2'))
from install_hysteria2 import expected_sha256, verify_binary


class HysteriaHashesTests(unittest.TestCase):
    def test_actual_official_release_manifest_build_prefix(self):
        hashes=(Path(__file__).parent/'fixtures/hysteria-v2.13.0-hashes.txt').read_text()
        self.assertEqual(expected_sha256(hashes,'hysteria-linux-amd64'),
                         '907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691')
        self.assertEqual(len(expected_sha256(hashes,'hysteria-linux-arm64')),64)
    def test_supported_sha256sum_path_and_binary_markers(self):
        digest=hashlib.sha256(b'fixture').hexdigest()
        for name in ['hysteria-linux-amd64','build/hysteria-linux-amd64','./build/hysteria-linux-amd64','*build/hysteria-linux-amd64']:
            self.assertEqual(expected_sha256(digest+'  '+name+'\n','hysteria-linux-amd64'),digest)
    def test_missing_entry_has_its_own_diagnostic(self):
        with self.assertRaisesRegex(ValueError,'не найдена'):
            expected_sha256('a'*64+'  build/hysteria-linux-arm64','hysteria-linux-amd64')
    def test_ambiguous_invalid_and_traversal_names_fail_closed(self):
        for text in ['a'*64+' build/hysteria-linux-amd64\n'+'b'*64+' hysteria-linux-amd64',
                     'invalid build/hysteria-linux-amd64','a'*64+' ../hysteria-linux-amd64']:
            with self.assertRaises(ValueError):expected_sha256(text,'hysteria-linux-amd64')
    def test_binary_bytes_must_match_the_selected_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            binary=Path(directory)/'hysteria-linux-amd64';binary.write_bytes(b'fixture')
            digest=hashlib.sha256(b'fixture').hexdigest()
            hashes=digest+'  build/hysteria-linux-amd64\n'
            self.assertEqual(verify_binary(binary,hashes,binary.name),digest)
            binary.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'не совпадает'):verify_binary(binary,hashes,binary.name)



class HysteriaPreparationRecoveryTests(unittest.TestCase):
    def test_checksum_rejection_does_not_leave_uncertain_stage_marker(self):
        from unittest.mock import patch
        import sys
        sys.path.insert(0,str(ROOT/'installer'))
        from state import InstallState
        from execution import StageRunner
        with tempfile.TemporaryDirectory() as directory:
            state=InstallState(Path(directory)/'state.json')
            with patch.object(StageRunner,'_protocol',return_value=78):
                with self.assertRaisesRegex(ValueError,'ещё не начиналась'):
                    StageRunner(state,{}).run('hysteria2',['fixture'],protocol=True)
            self.assertNotIn('running',InstallState(state.path).data)
            self.assertNotIn('hysteria2',state.data['done'])
    def test_recovery_requires_no_files_and_no_loaded_service(self):
        from unittest.mock import patch
        from types import SimpleNamespace
        import sys
        sys.path.insert(0,str(ROOT/'installer'))
        from recovery import hysteria_untouched
        with patch('recovery.Path.exists',return_value=False),patch('recovery.Path.is_symlink',return_value=False),patch('recovery.subprocess.run',return_value=SimpleNamespace(stdout='not-found\n')):
            self.assertTrue(hysteria_untouched())
        with patch('recovery.Path.exists',return_value=True),patch('recovery.subprocess.run') as probe:
            self.assertFalse(hysteria_untouched());probe.assert_not_called()
        with patch('recovery.Path.exists',return_value=False),patch('recovery.Path.is_symlink',return_value=False),patch('recovery.subprocess.run',return_value=SimpleNamespace(stdout='loaded\n')):
            self.assertFalse(hysteria_untouched())

if __name__=='__main__':unittest.main()
