"""Exercise the standalone downloader offline against a tag-shaped source archive."""
import io
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[3]
VERSION=(ROOT/'bots/vpn-manager_awg/INSTALLER_VERSION').read_text().strip()
PREFIX='telemt2-'+VERSION+'/bots/vpn-manager_awg/v3/'


@unittest.skipUnless(shutil.which('sha256sum') and shutil.which('python3'), 'download runtime required')
class DownloaderTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.addCleanup(self.temp.cleanup)
        self.directory=Path(self.temp.name)
        self.script=self.directory/'install-v3.sh';self.script.write_bytes((ROOT/'install-v3.sh').read_bytes())
        self.archive=self.directory/'source.tar.gz'
        self.cache=self.directory/'downloaded'
        binary=self.directory/'bin';binary.mkdir()
        self.curl=binary/'curl'
        self.curl.write_text('#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\n if [ "$1" = -o ]; then cp "$V3_TEST_ARCHIVE" "$2"; exit $?; fi\n shift\ndone\nexit 2\n')
        self.curl.chmod(0o755)
        self.env=dict(os.environ,PATH=str(binary)+os.pathsep+os.environ['PATH'],
                      V3_TEST_ARCHIVE=str(self.archive),VPNBOT_V3_DOWNLOAD_DIR=str(self.cache))
    def run_downloader(self,*args):
        return subprocess.run(['bash',str(self.script),*args],env=self.env,text=True,capture_output=True,timeout=45)
    def test_download_verifies_package_and_second_run_uses_cache(self):
        manifest=ROOT/'bots/vpn-manager_awg/SHA256SUMS'
        files=[manifest]+[(manifest.parent/line.split(None,1)[1]).resolve() for line in manifest.read_text().splitlines()]
        with tarfile.open(self.archive,'w:gz') as bundle:
            for path in files:bundle.add(path,arcname=PREFIX+path.relative_to(ROOT).as_posix(),recursive=False)
        first=self.run_downloader('--check')
        self.assertEqual(first.returncode,0,first.stderr)
        self.assertTrue((self.cache/'installer/install.py').exists())
        self.assertFalse((self.cache/'v2').exists())
        self.assertEqual(list(self.directory.glob('.vpnbot-v3.*')),[])
        self.curl.write_text('#!/bin/sh\nexit 99\n');self.curl.chmod(0o755)
        second=self.run_downloader('--check')
        self.assertEqual(second.returncode,0,second.stderr)
        self.assertIn('DRY RUN',second.stdout)
    def test_unsafe_archive_is_rejected_without_escaping_or_leaving_cache(self):
        with tarfile.open(self.archive,'w:gz') as bundle:
            member=tarfile.TarInfo(PREFIX+'../escape')
            member.size=4;bundle.addfile(member,io.BytesIO(b'test'))
        result=self.run_downloader('--check')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Unsafe',result.stderr)
        self.assertFalse((self.directory/'escape').exists())
        self.assertFalse(self.cache.exists())
        self.assertEqual(list(self.directory.glob('.vpnbot-v3.*')),[])


if __name__=='__main__':unittest.main()
