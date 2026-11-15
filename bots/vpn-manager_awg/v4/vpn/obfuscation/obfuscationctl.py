#!/usr/bin/env python3
"""Global v4 obfuscation transactions. Never changes keys, peers, ports or DNS."""
import argparse
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shlex
import shutil
import subprocess
import time

FLAGS = {'RandomTrailers': 'random-trailers', 'DisableCookies': 'disable-cookies'}
ENV_FLAGS = {'RandomTrailers': 'AWG_RANDOM_TRAILERS', 'DisableCookies': 'AWG_DISABLE_COOKIES'}

class Rejected(RuntimeError):
    pass

def run(args):
    p = subprocess.run(args, capture_output=True, text=True, timeout=35)
    if p.returncode: raise RuntimeError('Команда протокола не подтвердила операцию')
    return p.stdout.strip()

def atomic(path, data):
    path = Path(path)
    tmp = path.with_name('.' + path.name + '.' + secrets.token_hex(6))
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(fd, 'wb') as out: out.write(data); out.flush(); os.fsync(out.fileno())
        os.replace(tmp, path)
    finally:
        if tmp.exists(): tmp.unlink()

def encode(value): return (json.dumps(value, ensure_ascii=False, indent=2)+'\n').encode()

def patch_interface(text, values):
    lines = text.splitlines(keepends=True)
    starts = [i for i,l in enumerate(lines) if l.strip().lower() == '[interface]']
    if len(starts) != 1: raise Rejected('Некорректный конфиг AWG')
    start = starts[0]+1
    end = next((i for i in range(start,len(lines)) if lines[i].strip().startswith('[')),len(lines))
    kept = [l for l in lines[start:end] if l.split('=',1)[0].strip() not in values]
    if kept and not kept[-1].endswith('\n'): kept[-1]+='\n'
    return ''.join(lines[:start]+kept+[f'{k} = {v}\n' for k,v in values.items()]+lines[end:])

def patch_env(text, values):
    lines = [l for l in text.splitlines() if l.split('=',1)[0].strip() not in values]
    return '\n'.join(lines+[f'{k}={v}' for k,v in values.items()])+'\n'

class Controller:
    def __init__(self, root=Path('/'), runner=run):
        self.root=Path(root); self.run=runner
    def path(self, value): return self.root / str(value).lstrip('/')
    def awg_binary(self):
        for p in ('/opt/amneziawg3/bin/awg','/usr/bin/awg','/usr/local/bin/awg'):
            if self.path(p).exists(): return str(self.path(p))
        raise Rejected('AWG tools не найдены')
    def files(self, protocol):
        if protocol=='awg31':
            env=self.path('/etc/amnezia/amneziawg/awg3ctl.env')
            if not env.is_file(): raise Rejected('AmneziaWG 3.1 не установлен')
            values={}
            for line in env.read_text().splitlines():
                if '=' not in line: continue
                k,v=line.split('=',1)
                if k in ('AWG_DIR','CLIENT_OUT_DIR','CLIENT_DIR','AWG_IFACE'):
                    tokens=shlex.split(v); values[k]=tokens[0] if len(tokens)==1 else ''
            if values.get('AWG_IFACE')!='awg3': raise Rejected('Ожидался интерфейс awg3')
            conf=self.path(values['AWG_DIR']+'/awg3.conf')
            out=self.path(values['CLIENT_OUT_DIR'])
            profiles=sorted(out.glob('*.conf'))
            if not conf.is_file() or not out.is_dir(): raise Rejected('Нет конфигурации AWG 3.1')
            return [conf,env]+profiles
        if protocol=='hy2':
            files=[self.path('/etc/hysteria/'+n) for n in ('settings.json','config.yaml','users.json')]
            if not all(p.is_file() for p in files): raise Rejected('Hysteria 2 не установлена')
            return files
        raise Rejected('Неизвестный протокол')
    def revision(self, files):
        digest=hashlib.sha256()
        for p in files: digest.update(str(p).encode()+b'\0'+p.read_bytes()+b'\0')
        return digest.hexdigest()
    def runtime_awg(self):
        binary=self.awg_binary()
        result={k:self.run([binary,'show','awg3',arg]) for k,arg in FLAGS.items()}
        if any(v not in ('on','off') for v in result.values()): raise Rejected('AWG не поддерживает новые флаги')
        return result
    def status(self, protocol):
        files=self.files(protocol)
        if protocol=='awg31':
            try: current=self.runtime_awg()
            except Exception: raise Rejected('Сначала обновите AWG tools/ядро: новые флаги не поддерживаются') from None
            if 'HeaderProtectionKey' not in files[0].read_text(): raise Rejected('Не подтверждён профиль AWG 3.1')
            choices=['both-off','both-on','trailers-on','trailers-off','cookies-on','cookies-off']
        else:
            settings=json.loads(files[0].read_text());current={'mode':settings['obfs']}
            choices=['none','salamander']
            match=re.fullmatch(r'app/v(\d+)\.(\d+)\.(\d+)',settings.get('version',''))
            if match and tuple(map(int,match.groups())) >= (2,9,2): choices.append('gecko')
        latest=self.latest(protocol)
        return {'protocol':protocol,'current':current,'choices':choices,'revision':self.revision(files),
                'rollback':bool(latest and latest.get('status')=='committed' and latest.get('after')==self.revision(files))}
    def latest(self, protocol):
        path=self.path('/var/lib/vpnbot-obfuscation/'+protocol+'/latest.json')
        return json.loads(path.read_text()) if path.exists() else None
    def save_latest(self, protocol, data):
        directory=self.path('/var/lib/vpnbot-obfuscation/'+protocol)
        directory.mkdir(parents=True,exist_ok=True,mode=0o700);directory.chmod(0o700)
        atomic(directory/'latest.json',encode(data))
    def plan(self, protocol, choice, status):
        files=self.files(protocol)
        if choice not in status['choices']: raise Rejected('Неподдерживаемый режим')
        if protocol=='awg31':
            flags=dict(status['current'])
            if choice.startswith('both-'): flags={k:choice[5:] for k in FLAGS}
            elif choice.startswith('trailers-'): flags['RandomTrailers']=choice[9:]
            elif choice.startswith('cookies-'): flags['DisableCookies']=choice[8:]
            changes={p:patch_interface(p.read_text(),flags).encode() for p in [files[0]]+files[2:]}
            changes[files[1]]=patch_env(files[1].read_text(),{ENV_FLAGS[k]:v for k,v in flags.items()}).encode()
            return changes, flags
        settings=json.loads(files[0].read_text());config=json.loads(files[1].read_text())
        settings['obfs']=choice
        # Retain HTTP/3 masquerade configuration while enabling obfuscation.
        # Switching back therefore requires no new listener or port reservation.
        if choice=='none': config.pop('obfs',None)
        else:
            settings['obfs_password']=settings.get('obfs_password') or secrets.token_urlsafe(32)
            params={'password':settings['obfs_password']}
            if choice=='gecko':
                lo=int(settings.get('min_packet',512));hi=int(settings.get('max_packet',1200))
                if not 1<=lo<=hi<=2048: raise Rejected('Некорректный диапазон Gecko')
                params.update(minPacketSize=lo,maxPacketSize=hi)
            config['obfs']={'type':choice,choice:params}
        return {files[0]:encode(settings),files[1]:encode(config)}, {'mode':choice}
    def activate(self, protocol, values):
        if protocol=='awg31':
            args=[self.awg_binary(),'set','awg3']
            for k,v in values.items(): args += [FLAGS[k],v]
            self.run(args)
            if self.runtime_awg()!=values: raise RuntimeError('AWG не подтвердил параметры')
        else:
            self.run(['systemctl','restart','hysteria2.service'])
            # Poll local traffic API instead of mistaking "active" for readiness.
            settings=json.loads(self.path('/etc/hysteria/settings.json').read_text())
            import urllib.request
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
            for attempt in range(15):
                try:
                    req=urllib.request.Request('http://127.0.0.1:'+str(settings['stats_port'])+'/traffic',headers={'Authorization':settings['stats_secret']})
                    with opener.open(req,timeout=2) as response: json.load(response)
                    return
                except Exception:
                    if attempt==14: raise RuntimeError('Hysteria не подтвердила запуск') from None
                    time.sleep(1)
    def apply(self, protocol, choice, expected):
        status=self.status(protocol)
        if status['revision']!=expected: raise Rejected('Настройки изменились. Откройте меню заново')
        latest=self.latest(protocol)
        if latest and latest['status'] not in ('committed','rolled_back'): raise Rejected('Предыдущая операция требует ручной сверки')
        if choice=='rollback':
            if not status['rollback']: raise Rejected('Настройки изменились после операции; откат остановлен')
            folder=self.path(latest['backup'])
            before=json.loads((folder/'manifest.json').read_text())
            changes={self.path(p): (folder/str(i)).read_bytes() for i,p in enumerate(before['paths'])}
            values=before['current']
        else: changes,values=self.plan(protocol,choice,status)
        folder=self.path('/var/lib/vpnbot-obfuscation/'+protocol+'/'+str(time.time_ns()))
        folder.mkdir(parents=True,mode=0o700)
        originals={p:p.read_bytes() for p in changes}
        paths=[str(p.relative_to(self.root)) for p in changes]
        for i,data in enumerate(originals.values()):atomic(folder/str(i),data)
        atomic(folder/'manifest.json',encode({'paths':paths,'current':status['current']}))
        record={'status':'prepared','backup':'/'+str(folder.relative_to(self.root)),'before':expected}
        self.save_latest(protocol,record)
        try:
            for p,data in changes.items(): atomic(p,data)
            self.activate(protocol,values)
            record.update(status='committed',after=self.revision(self.files(protocol)))
            self.save_latest(protocol,record)
            return {'changed':True,'backup':record['backup'],'current':values}
        except Exception:
            try:
                for p,data in originals.items(): atomic(p,data)
                self.activate(protocol,status['current'])
                record['status']='rolled_back'; self.save_latest(protocol,record)
            except Exception:
                record['status']='needs_review'; self.save_latest(protocol,record)
                raise RuntimeError('Откат не подтверждён; требуется сверка журнала обфускации') from None
            raise Rejected('Применение не удалось; прежние настройки восстановлены') from None

@contextlib.contextmanager
def locks(protocol):
    with contextlib.ExitStack() as stack:
        paths=['/run/lock/vpn-endpoint.lock']
        if protocol=='hy2': paths.append('/etc/hysteria/.controller.lock')
        for name in paths:
            if not Path(name).parent.is_dir(): raise Rejected('Протокол не установлен')
            handle=stack.enter_context(open(name,'a'));os.chmod(name,0o600)
            try: fcntl.flock(handle,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError: raise Rejected('Другая операция выполняется; повторите позже') from None
        yield

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('command',choices=['status','apply'])
    parser.add_argument('protocol',choices=['awg31','hy2'])
    parser.add_argument('choice',nargs='?');parser.add_argument('revision',nargs='?')
    args=parser.parse_args()
    try:
        if os.geteuid()!=0: raise Rejected('Нужны права root')
        with locks(args.protocol):
            ctl=Controller()
            result=ctl.status(args.protocol) if args.command=='status' else ctl.apply(args.protocol,args.choice,args.revision)
        print(json.dumps({'ok':True,**result},ensure_ascii=False))
    except Rejected as exc:
        print(json.dumps({'ok':False,'changed':False,'error':str(exc)},ensure_ascii=False));raise SystemExit(1)
    except Exception:
        print(json.dumps({'ok':False,'error':'Операция не подтверждена. Проверьте журнал обфускации.'},ensure_ascii=False));raise SystemExit(1)

if __name__=='__main__': main()
