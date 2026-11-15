"""Real PNG generation when qrencode is installed; not a device connectivity test."""
import base64
import io
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch
try:
    from PIL import Image
except ImportError:
    Image = None

ROOT=Path(__file__).resolve().parents[3]
sys.path.insert(0,str(ROOT/'vpn/hysteria2'))
import hysteria2ctl as hy


@unittest.skipUnless(shutil.which('qrencode') and Image is not None, 'qrencode and Pillow required for real PNG generation')
class RealHysteriaQR(unittest.TestCase):
    def test_every_obfuscation_mode_produces_a_valid_png(self):
        for mode in ('none','salamander','gecko'):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory, patch.object(hy,'ROOT',Path(directory)):
                hy.write_json(hy.ROOT/'settings.json',{'domain':'vpn.example.org','port':443,'obfs':mode,
                    'obfs_password':'fixture-password','min_packet':512,'max_packet':1200})
                hy.write_json(hy.ROOT/'users.json',{})
                created=hy.execute(['add','fixture'])
                profile=hy.execute(['qr','fixture'])
                self.assertEqual(profile['link'],created['link'])
                png=base64.b64decode(profile['qr_png_base64'])
                with Image.open(io.BytesIO(png)) as image:
                    self.assertEqual(image.format,'PNG')
                    self.assertGreater(image.width,100)
                    image.verify()


if __name__=='__main__':unittest.main()
