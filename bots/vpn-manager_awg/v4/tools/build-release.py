#!/usr/bin/env python3
"""Build isolated Global v4; reject private integrations and embedded credentials."""
from pathlib import Path
import hashlib
import os
import re
import tarfile

ROOT=Path(__file__).resolve().parents[1]
BOT=ROOT/'bots/vpn-manager_awg'
BANNED_NAMES={'private_dns.py','domeny_api.py','netnum_personal_api.py','domeny.env','netnum.env','README_PRIVATE_RU.md'}
BANNED_TEXT=('sec.vpnbot.dev','domeny_api','netnum_personal_api','DOMENY_PASSWORD','NETNUM_API_TOKEN')
ROOT_NAMES={'README.md','AGENTS.md','README_RU.md','INSTALL_DEBIAN13_RU.txt','install-global.sh','install-v4.sh','check-server.sh','silent.example.ini','VALIDATION_RU.txt','PROFILE_FORMAT_CONTRACT_RU.md'}

def files():
    result=[]
    for p in ROOT.rglob('*'):
        if not p.is_file():continue
        rel=p.relative_to(ROOT)
        if p.is_symlink():raise ValueError('Symlink is not allowed in release: '+str(rel))
        if any(x.startswith('._') or x in {'__pycache__','.git','.DS_Store','.pytest_cache'} for x in rel.parts):continue
        if p.name in BANNED_NAMES:raise ValueError('Private file in Global v4: '+str(rel))
        if len(rel.parts)==1 and p.name not in ROOT_NAMES:continue
        if len(rel.parts)>1 and rel.parts[0] not in {'bots','vpn','installer','tools'}:continue
        if p.suffix in {'.pyc','.sqlite3','.sqlite','.db','.log','.key','.pem'} or p.name=='.env':continue
        if p.suffix=='.ini' and p.name!='silent.example.ini':continue
        if '.local.' in p.name or p.name.endswith('.local'):continue
        if 'tests' not in rel.parts and p.suffix in {'.py','.sh','.ini','.json'}:
            text=p.read_text()
            if p != Path(__file__).resolve() and any(value in text for value in BANNED_TEXT):raise ValueError('Private integration in '+str(rel))
            if re.search(r'\b\d{6,}:[A-Za-z0-9_-]{25,}\b',text):raise ValueError('Possible embedded bot token in '+str(rel))
        result.append(p)
    return sorted(result)


def build():
    selected=files();manifest=BOT/'SHA256SUMS'
    manifest.write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest()+'  '+os.path.relpath(p,BOT)+'\n' for p in selected if p!=manifest))
    if manifest not in selected:selected.append(manifest)
    output=ROOT.parent/'global-releases';output.mkdir(exist_ok=True)
    version=(BOT/'INSTALLER_VERSION').read_text().strip();archive=output/('vpnbot-'+version+'.tar.gz')
    with tarfile.open(archive,'w:gz') as tar:
        for p in sorted(selected):tar.add(p,arcname=ROOT.name+'/'+p.relative_to(ROOT).as_posix(),recursive=False)
    archive.with_suffix(archive.suffix+'.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n')
    print(archive)

if __name__=='__main__':build()
