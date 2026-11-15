#!/usr/bin/env python3
"""Separate HY2 controller. JSON interface; no installer-time profile output."""
import base64
import fcntl
import hashlib
import hmac
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import urllib.parse
import urllib.request

ROOT=Path(os.environ.get('HYSTERIA_STATE_DIR','/etc/hysteria'))

class NoChangeError(ValueError):
    """Rejected before any change to users or server state."""
    pass

def write_json(path,data):
    tmp=path.with_suffix('.tmp')
    fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w') as f:json.dump(data,f);f.flush();os.fsync(f.fileno())
    os.replace(tmp,path)

def authenticate(argv):
    try:
        name,password=argv[1].split(':',1)
        users=json.loads((ROOT/'users.json').read_text())
        if not hmac.compare_digest(users.get(name,{}).get('password','').encode(),password.encode()) or not password:return 1
        print(name);return 0
    except (ValueError,IndexError,KeyError,OSError):return 1

def api(settings,path,data=None):
    req=urllib.request.Request('http://127.0.0.1:'+str(settings['stats_port'])+path,
      data=json.dumps(data).encode() if data is not None else None,
      headers={'Authorization':settings['stats_secret'],'Content-Type':'application/json'})
    opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
    with opener.open(req,timeout=10) as response:
        raw=response.read()
        return json.loads(raw) if raw else {}

def profile(settings,users,name,qr=False):
    item=users[name]
    query={'sni':settings['domain']}
    obfs=settings['obfs']
    if obfs!='none':query.update({'obfs':obfs,'obfs-password':settings['obfs_password']})
    auth=urllib.parse.quote(name+':'+item['password'],safe='')
    link='hysteria2://'+auth+'@'+settings['domain']+':'+str(settings['port'])+'/?'+urllib.parse.urlencode(query)+'#'+urllib.parse.quote(name)
    proxy={'name':name,'type':'hysteria2','server':settings['domain'],'port':settings['port'],
      'password':name+':'+item['password'],'sni':settings['domain'],'skip-cert-verify':False}
    if obfs!='none':proxy.update({'obfs':obfs,'obfs-password':settings['obfs_password']})
    if obfs=='gecko':proxy.update({'obfs-min-packet-size':settings['min_packet'],'obfs-max-packet-size':settings['max_packet']})
    # JSON is a valid YAML representation, avoiding a YAML dependency in the CLI.
    clash=json.dumps({'proxies':[proxy],'proxy-groups':[{'name':'Proxy','type':'select','proxies':[name]}],'rules':['MATCH,Proxy']},ensure_ascii=False,indent=2)+'\n'
    result={'name':name,'uuid':item['identity'],'link':link,'config':clash,'clash_yaml':clash,'obfs':obfs}
    if qr:
        png=subprocess.check_output(['qrencode','-t','PNG','-s','8','-m','4','-l','L','-o','-'],input=link.encode(),timeout=15)
        result['qr_png_base64']=base64.b64encode(png).decode()
    return result

def execute(args):
    if args and args[0] in ('-j','--json'):args=args[1:]
    command=args[0] if args else 'help'
    if command=='help':return {'commands':['add','delete','list','show','qr','traffic','online','status']}
    if not ROOT.is_dir():raise NoChangeError('Hysteria 2 не установлен')
    with (ROOT/'.controller.lock').open('a') as lock:
        os.chmod(lock.name,0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        settings=json.loads((ROOT/'settings.json').read_text());users=json.loads((ROOT/'users.json').read_text())
        name=args[1] if len(args)>1 else ''
        if command=='add':
            name=name or 'vpn-'+secrets.token_hex(4)
            if not re.fullmatch(r'[A-Za-z0-9_.-]{1,32}',name):raise NoChangeError('Некорректное имя')
            if name in users:raise NoChangeError('Пользователь уже существует; автоматическая замена запрещена')
            users[name]={'password':secrets.token_urlsafe(32),'identity':secrets.token_hex(32)}
            write_json(ROOT/'users.json',users)
            return profile(settings,users,name) # QR only on explicit qr command, never during install.
        if command=='delete':
            if name not in users:raise NoChangeError('Пользователь не найден')
            del users[name];write_json(ROOT/'users.json',users)
            api(settings,'/kick',[name])
            return {'name':name,'deleted':True}
        if command in {'show','qr','yaml','link'}:
            if name not in users:raise NoChangeError('Пользователь не найден')
            return profile(settings,users,name,command=='qr')
        if command=='list':return {'clients':[{'name':n,'num':i+1} for i,n in enumerate(users)]}
        if command=='status':return {'clients_count':len(users),'obfs':settings['obfs']}
        if command in {'traffic','online'}:
            counters=api(settings,'/traffic');online=api(settings,'/online')
            clients=[]
            for n in users:
                entry=counters.get(n,{})
                # /traffic tx/rx are server-perspective: rx is client upload.
                up=int(entry.get('rx',0));down=int(entry.get('tx',0))
                clients.append({'name':n,'upload_bytes':up,'download_bytes':down,'uplink_bytes':up,'downlink_bytes':down,'total_bytes':up+down,
                  'online':bool(online.get(n)),'status':'online' if online.get(n) else 'offline'})
            return {'clients':clients,'total_bytes':sum(c['total_bytes'] for c in clients)}
        raise NoChangeError('Неизвестная команда')

if __name__=='__main__':
    if len(sys.argv)>1 and sys.argv[1]=='authenticate':sys.exit(authenticate(sys.argv[2:]))
    try:print(json.dumps(dict(ok=True,**execute(sys.argv[1:])),ensure_ascii=False))
    except NoChangeError as exc:
        print(json.dumps({'ok':False,'changed':False,'error':str(exc)},ensure_ascii=False));sys.exit(1)
    except Exception:
        # Do not include arguments, URLs, or credentials in errors.
        print(json.dumps({'ok':False,'error':'Операция Hysteria 2 не завершена. Проверьте состояние и журнал службы.'},ensure_ascii=False));sys.exit(1)
