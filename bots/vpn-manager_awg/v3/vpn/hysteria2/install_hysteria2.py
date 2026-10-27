#!/usr/bin/env python3
"""Install official pinned binary, command authentication and built-in ACME."""
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import secrets
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from hysteria2ctl import write_json

def build_config(s):
    config={'listen':s['bind_ip']+':'+str(s['port']),
      'acme':{'domains':[s['domain']],'ca':'letsencrypt','type':'http','listenHost':s['bind_ip'],'dir':'/etc/hysteria/acme'},
      'auth':{'type':'command','command':'/usr/local/sbin/hysteria2-auth'},
      'trafficStats':{'listen':'127.0.0.1:'+str(s['stats_port']),'secret':s['stats_secret']},
      'outbounds':[{'name':'direct','type':'direct','direct':{'mode':'4','bindIPv4':s['bind_ip']}}]}
    if s['obfs']=='none':
        if s.get('masquerade_mode','proxy')=='local':
            target=urllib.parse.urlsplit(s['masquerade'])
            if target.hostname not in config['acme']['domains']:config['acme']['domains'].append(target.hostname)
            config['masquerade']={'type':'string','string':{'content':'<!doctype html><html><head><title>Welcome</title></head><body><h1>Welcome</h1></body></html>',
              'headers':{'content-type':'text/html; charset=utf-8'},'statusCode':200},
              'listenHTTPS':s['bind_ip']+':'+str(target.port or 443)}
        else:
            config['masquerade']={'type':'proxy','proxy':{'url':s['masquerade'],'rewriteHost':True}}
    else:
        fields={'password':s['obfs_password']}
        if s['obfs']=='gecko':fields.update(minPacketSize=s['min_packet'],maxPacketSize=s['max_packet'])
        config['obfs']={'type':s['obfs'],s['obfs']:fields}
    return config

def main():
    if os.geteuid()!=0 or sys.platform!='linux':raise ValueError('root/Linux required')
    root=Path('/etc/hysteria')
    if root.exists():raise ValueError('/etc/hysteria already exists; refusing overwrite')
    domain=os.environ['HY_DOMAIN'].encode('idna').decode().lower()
    if not re.fullmatch(r'(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}',domain):raise ValueError('Некорректный домен')
    ip=os.environ['VPN_PUBLIC_HOST']
    addresses={a[4][0] for a in socket.getaddrinfo(domain,None,socket.AF_INET)}
    if addresses!={ip}:raise ValueError('Все A-записи домена Hysteria должны совпадать с выбранным IPv4')
    # A wrong AAAA can cause ACME validation to fail; do not alter DNS automatically.
    try:ipv6=socket.getaddrinfo(domain,None,socket.AF_INET6)
    except socket.gaierror:ipv6=[]
    if ipv6:raise ValueError('Для этой IPv4-сборки удалите AAAA домена Hysteria либо используйте отдельный домен без AAAA')
    obfs=os.environ['HY_OBFS']
    if obfs not in {'none','salamander','gecko'}:raise ValueError('Invalid obfuscation')
    masquerade=os.environ.get('HY_MASQUERADE','')
    if obfs=='none' and urllib.parse.urlsplit(masquerade).scheme not in {'http','https'}:raise ValueError('Нужен HTTP/HTTPS URL маскировки')
    site_mode=os.environ.get('HY_MASQUERADE_MODE','proxy')
    if site_mode not in {'proxy','local'}:raise ValueError('Некорректный режим сайта-маскировки')
    if obfs=='none' and site_mode=='local':
        site_host=urllib.parse.urlsplit(masquerade).hostname
        if not site_host:raise ValueError('Не указан домен локального HTTPS-сайта')
        if {item[4][0] for item in socket.getaddrinfo(site_host,None,socket.AF_INET)}!={ip}:
            raise ValueError('Домен локального HTTPS-сайта должен указывать на выбранный IP сервера')
        try:site_v6=socket.getaddrinfo(site_host,None,socket.AF_INET6)
        except socket.gaierror:site_v6=[]
        if site_v6:raise ValueError('Для IPv4-сборки нужен домен локального HTTPS-сайта без AAAA')
    version=os.environ['HY_VERSION']
    if not re.fullmatch(r'app/v2\.\d+\.\d+',version):raise ValueError('Нужен точный тег app/v2.x.y')
    if obfs=='gecko' and tuple(map(int,version[5:].split('.')))<(2,9,2):raise ValueError('Gecko требует Hysteria 2.9.2+')
    arch={'x86_64':'amd64','aarch64':'arm64'}.get(platform.machine())
    if not arch:raise ValueError('Поддерживаются amd64 и arm64')
    asset='hysteria-linux-'+arch
    url='https://github.com/HyNetworks/hysteria/releases/download/'+version+'/'
    with tempfile.TemporaryDirectory() as td:
        binary=Path(td)/asset
        urllib.request.urlretrieve(url+asset,binary)
        with urllib.request.urlopen(url+'hashes.txt',timeout=30) as response:hashes=response.read().decode()
        expected=None
        for line in hashes.splitlines():
            parts=line.split()
            if len(parts)==2 and parts[1].lstrip('*')==asset:expected=parts[0]
        if not expected or hashlib.sha256(binary.read_bytes()).hexdigest()!=expected:raise ValueError('SHA256 Hysteria не совпадает')
        shutil.copyfile(binary,'/usr/local/bin/hysteria');os.chmod('/usr/local/bin/hysteria',0o755)
    # No stopping other web servers; TCP 80 must have passed central preflight.
    root.mkdir(mode=0o700)
    settings={'domain':domain,'bind_ip':ip,'port':int(os.environ['HY_PORT']),'obfs':obfs,
      'obfs_password':os.environ.get('HY_OBFS_PASSWORD',''),'min_packet':int(os.environ.get('HY_MIN_PACKET','512')),
      'max_packet':int(os.environ.get('HY_MAX_PACKET','1200')),'masquerade':masquerade,'masquerade_mode':site_mode,
      'stats_port':19090,'stats_secret':secrets.token_urlsafe(32),'version':version}
    write_json(root/'settings.json',settings);write_json(root/'users.json',{})
    write_json(root/'config.yaml',build_config(settings))
    shutil.copyfile(Path(__file__).with_name('hysteria2ctl.py'),'/usr/local/sbin/hysteria2ctl');os.chmod('/usr/local/sbin/hysteria2ctl',0o755)
    auth_path=Path('/usr/local/sbin/hysteria2-auth')
    auth_path.write_text('#!/bin/sh\nexec /usr/local/sbin/hysteria2ctl authenticate "$@"\n');auth_path.chmod(0o755)
    Path('/etc/systemd/system/hysteria2.service').write_text('''[Unit]
Description=Global v3 Hysteria 2
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=/usr/local/bin/hysteria server -c /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
UMask=0077
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
''')
    # Output contains only success/name; profiles remain available through CLI to bot.
    result=subprocess.run(['/usr/local/sbin/hysteria2ctl','-j','add',os.environ['VPN_INITIAL_CLIENT']],capture_output=True,text=True)
    if result.returncode:raise ValueError('Не создан первый пользователь Hysteria')
    subprocess.run(['systemctl','daemon-reload'],check=True)
    if shutil.which('ufw'):
        status=subprocess.run(['ufw','status'],capture_output=True,text=True,check=True,env=dict(os.environ,LC_ALL='C')).stdout
        if 'Status: active' in status:
            subprocess.run(['ufw','allow',str(settings['port'])+'/udp'],check=True)
            subprocess.run(['ufw','allow','80/tcp'],check=True)
            if obfs=='none' and site_mode=='local':
                subprocess.run(['ufw','allow',str(urllib.parse.urlsplit(masquerade).port or 443)+'/tcp'],check=True)
    subprocess.run(['systemctl','enable','--now','hysteria2.service'],check=True)
    deadline=time.monotonic()+180
    while time.monotonic()<deadline:
        try:
            from hysteria2ctl import api
            api(settings,'/online')
            if obfs=='none' and site_mode=='local':
                target=urllib.parse.urlsplit(masquerade)
                with socket.create_connection((target.hostname,target.port or 443),timeout=5) as connection:
                    with ssl.create_default_context().wrap_socket(connection,server_hostname=target.hostname):pass
            print('Hysteria 2: служба и API готовы.' + (' Сертификат и локальный HTTPS проверены.' if obfs=='none' and site_mode=='local' else ''))
            return
        except Exception:time.sleep(2)
    raise ValueError('Hysteria не готова: проверьте DNS, TCP 80, UDP порт и journalctl -u hysteria2')

if __name__=='__main__':
    try:main()
    except Exception as exc:print('Ошибка установки Hysteria: '+str(exc),file=sys.stderr);sys.exit(1)
