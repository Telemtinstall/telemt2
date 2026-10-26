#!/usr/bin/env python3
"""Build local-only installer bundle; no credentials or caches."""
from pathlib import Path
import hashlib
import os
import tarfile
root = Path(__file__).resolve().parents[1]
bot = root / 'bots/vpn-manager_awg'
files = sorted(p for p in root.rglob('*') if p.is_file() and '__pycache__' not in p.parts
               and '.git' not in p.parts and p.suffix not in {'.pyc', '.sqlite3', '.db'} and p.name != '.env')
manifest = bot / 'SHA256SUMS'
manifest.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + os.path.relpath(p, bot) + '\n'
                            for p in files if p != manifest))
output = root.parent / 'global-releases'
output.mkdir(exist_ok=True)
version = (bot / 'INSTALLER_VERSION').read_text().strip()
archive = output / ('vpnbot-' + version + '.tar.gz')
with tarfile.open(archive, 'w:gz') as tar:
    for p in files:
        tar.add(p, arcname='global-vpnbot/' + p.relative_to(root).as_posix(), recursive=False)
archive.with_suffix(archive.suffix + '.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n')
print(archive)
