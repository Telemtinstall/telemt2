"""V4 stays local until explicitly published; it never downloads a v3 package."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[3]

class LauncherTests(unittest.TestCase):
    def test_standalone_launcher_refuses_missing_bundle_without_network(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);script=root/'install-v4.sh';script.write_bytes((ROOT/'install-v4.sh').read_bytes())
            result=subprocess.run(['bash',str(script),'--check'],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0)
            self.assertIn('Распакуйте полный архив Global v4',result.stderr)
            self.assertNotIn('curl',script.read_text())
    def test_local_launcher_checks_package_and_never_fetches_other_version(self):
        result=subprocess.run(['bash',str(ROOT/'install-v4.sh'),'--check'],capture_output=True,text=True,timeout=20)
        self.assertEqual(result.returncode,0,result.stderr);self.assertIn('Global v4',result.stdout)
