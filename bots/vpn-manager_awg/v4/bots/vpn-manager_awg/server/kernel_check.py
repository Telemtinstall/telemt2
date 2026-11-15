#!/usr/bin/python3
"""Fail explicitly instead of silently falling back to amneziawg-go."""
from pathlib import Path
import argparse
import json
import platform
import re
import subprocess


def run(args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=90).stdout.strip()


def required_boot_kernels(release=None, boot=None):
    """Keep current/newest boot targets safe without requiring all old fallbacks."""
    release = release or platform.release()
    boot = boot or Path('/boot')
    kernels = [p.name.removeprefix('vmlinuz-') for p in boot.glob('vmlinuz-*')]
    supported = [k for k in kernels if tuple(map(int,re.findall(r'\d+',k)[:2])) >= (6,7)]
    required = {release}
    if supported:
        required.add(max(supported,key=lambda k:tuple(map(int,re.findall(r'\d+',k)))))
    for link in (boot/'vmlinuz', Path('/vmlinuz') if boot == Path('/boot') else boot/'default-vmlinuz'):
        if link.is_symlink():
            target = link.resolve().name
            if target.startswith('vmlinuz-'):
                required.add(target.removeprefix('vmlinuz-'))
    return sorted(required)


def check(iface=None, prepare=False, all_boot=False):
    release = platform.release()
    headers = Path('/lib/modules') / release / 'build/Makefile'
    if not headers.exists():
        raise ValueError('Нет headers текущего ядра '+release+'; установите linux-headers-'+release)
    if prepare:
        run(['modprobe','amneziawg'])
    version = run(['modinfo','-k',release,'-F','version','amneziawg'])
    loaded = Path('/sys/module/amneziawg/version')
    if prepare and loaded.exists(): version = loaded.read_text().strip()
    match = re.match(r'(\d+)\.(\d+)', version)
    if not match or (iface == 'awg3' and tuple(map(int,match.groups())) < (3,1)):
        raise ValueError('Модуль AWG не поддерживает требуемую версию: '+version)
    if iface and not prepare:
        data = json.loads(run(['ip','-j','-d','link','show',iface]))
        if not data or data[0].get('linkinfo',{}).get('info_kind') != 'amneziawg':
            raise ValueError(iface+' не работает через модуль ядра. Go fallback не считается успешной установкой')
    if all_boot:
        for kernel in required_boot_kernels(release):
            if not (Path('/lib/modules')/kernel/'build/Makefile').exists():
                raise ValueError('Перед reboot установите headers загрузочного ядра '+kernel)
            run(['modinfo','-k',kernel,'amneziawg'])
            initrd = Path('/boot')/('initrd.img-'+kernel)
            if not initrd.is_file() or initrd.stat().st_size < 1024*1024:
                raise ValueError('Не найден initramfs ядра '+kernel+'; перезагрузка небезопасна')
    return {'ok':True, 'kernel':release, 'module_version':version, 'implementation':'kernel'}


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('interface',nargs='?')
    parser.add_argument('--prepare',action='store_true')
    parser.add_argument('--all-boot',action='store_true')
    args=parser.parse_args()
    try: print(json.dumps(check(args.interface,args.prepare,args.all_boot)))
    except (ValueError,OSError,subprocess.SubprocessError) as exc:
        print(json.dumps({'ok':False,'error':str(exc)}));raise SystemExit(1)
