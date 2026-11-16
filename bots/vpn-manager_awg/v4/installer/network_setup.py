#!/usr/bin/python3
"""Finish the selected protocols with the same routing and kernel policy as USA."""
from pathlib import Path
import hashlib
import importlib.util
import json
import os
import platform
import re
import shutil
import subprocess
import sys

from runtime_safety import configure_conntrack, verify_conntrack

ROOT = Path(__file__).resolve().parents[1]


def load_kernel_checker(path):
    spec = importlib.util.spec_from_file_location('vpnbot_installed_kernel_check', path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def set_flags(text):
    # New v4 installation only. Keep every other profile line byte-for-byte.
    for key in ['RandomTrailers','DisableCookies']:
        text = re.sub(r'(?m)^'+key+r'\s*=.*\n?', '', text)
    return text.replace('[Interface]\n','[Interface]\nRandomTrailers = on\nDisableCookies = on\n',1)


def configure_awg31_flags():
    path=Path('/etc/amnezia/amneziawg/awg3.conf')
    if not path.exists(): return
    original=path.read_text()
    if 'HeaderProtectionKey' not in original:
        raise ValueError('AWG 3.1 не содержит HeaderProtectionKey; не меняю неподтверждённый формат')
    interface, sep, peers=original.partition('[Peer]')
    path.write_text(set_flags(interface)+sep+peers)
    for client in Path('/root/amneziawg3-clients').glob('*.conf'):
        interface,sep,peers=client.read_text().partition('[Peer]')
        client.write_text(set_flags(interface)+sep+peers)
    sys.path.insert(0,'/usr/local/sbin')
    from vpn_ip_switch import set_env
    env=Path('/etc/amnezia/amneziawg/awg3ctl.env')
    env.write_text(set_env(set_env(env.read_text(),'AWG_RANDOM_TRAILERS','on'),'AWG_DISABLE_COOKIES','on'))
    subprocess.run(['awg','set','awg3','random-trailers','on','disable-cookies','on'],check=True)


def main():
    if os.geteuid()!=0 or sys.platform!='linux':raise ValueError('root/Linux required')
    configure_conntrack();verify_conntrack()
    selected=os.environ['V3_SELECTED'].split(',')
    awg = [('amnezia31','awg3')]
    if any(name in selected for name,_ in awg):
        checker=Path('/usr/local/sbin/vpnbot-kernel-check.py')
        shutil.copy2(ROOT/'bots/vpn-manager_awg/server/kernel_check.py',checker);checker.chmod(0o755)
        kernel_checker = load_kernel_checker(checker)
        for kernel in kernel_checker.required_boot_kernels():
            if not (Path('/lib/modules')/kernel/'build/Makefile').exists():
                subprocess.run(['apt-get','install','-y','linux-headers-'+kernel],check=True)
            if not (Path('/lib/modules')/kernel/'build/Makefile').exists():
                raise ValueError('Нет headers обязательного ядра '+kernel+'; не перезагружайте до исправления')
            subprocess.run(['dkms','autoinstall','-k',kernel],check=True)
        for name,iface in awg:
            if name not in selected:continue
            subprocess.run(['/usr/bin/python3',str(checker),iface,'--prepare','--all-boot'],check=True)
            directory=Path('/etc/systemd/system')/('awg-quick@'+iface+'.service.d')
            directory.mkdir(parents=True,exist_ok=True)
            (directory/'40-v4-kernel.conf').write_text(
                '[Service]\nExecStartPre=/usr/bin/python3 /usr/local/sbin/vpnbot-kernel-check.py '+iface+' --prepare\n')
        configure_awg31_flags()
    # No registrar configuration or credentials are installed.
    domain=os.environ.get('VPN_ENDPOINT_DOMAIN','').strip()
    if domain=='-':domain=''
    if not domain and 'hysteria2' in selected:domain=os.environ['HY_DOMAIN']
    if not domain and 'vless' in selected and os.environ.get('VLESS_MODE')=='mask':domain=os.environ['VLESS_DOMAIN']
    if domain:
        sys.path.insert(0,'/usr/local/sbin')
        from domain_host import hostname
        domain=hostname(domain)
        directory=Path('/etc/vpnbot-global');directory.mkdir(mode=0o700,exist_ok=True)
        path=directory/'domain.json';path.write_text(json.dumps({'domain':domain})+'\n');path.chmod(0o600)
    registry=str(Path(os.environ.get('INSTALL_DIR','/root/vpnbot'))/'servers.json')
    command=['/usr/bin/python3','/usr/local/sbin/vpn_ip_switch.py','apply',os.environ['VPN_PUBLIC_HOST'],'--registry',registry]
    result=subprocess.run(command,check=True,capture_output=True,text=True,timeout=180)
    if not json.loads(result.stdout).get('ok'):raise ValueError('Локальная сетевая политика не подтверждена')
    subprocess.run(['systemctl','daemon-reload'],check=True)
    subprocess.run(['systemctl','start','vpnbot-ip-policy.service'],check=True)
    print('Вход VPN: все публичные IPv4. Выход VPN: '+os.environ['VPN_PUBLIC_HOST'])
    if domain:print('Просьба вручную установить A-запись '+domain+' -> '+os.environ['VPN_PUBLIC_HOST'])


if __name__=='__main__':main()
