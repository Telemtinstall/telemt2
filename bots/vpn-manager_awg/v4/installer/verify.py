#!/usr/bin/env python3
"""Verify only the selected protocol controllers/services after deployment."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
from runtime_safety import verify_conntrack

IDS = {'amnezia20': 'amneziawg', 'amnezia31': 'amneziawg3', 'vless': 'vless', 'hysteria2': 'hysteria2'}


def expected_enabled(database, server_id):
    if not database.exists():
        return True
    with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE name='protocol_states'").fetchone():
            return True
        row = db.execute('SELECT enabled FROM protocol_states WHERE server_id=?', (server_id,)).fetchone()
        return row is None or bool(row[0])



def verify_egress(address):
    for url in ['https://api.ipify.org','https://checkip.amazonaws.com']:
        result = subprocess.run(['curl','--noproxy','*','--interface',address,'-4','--fail','--silent','--show-error',
                                 '--connect-timeout','4','--max-time','8',url],capture_output=True,text=True,timeout=10)
        if result.returncode == 0 and result.stdout.strip() == address:
            return
    raise ValueError('Не подтверждён выход в Интернет с выбранного IP. Проверьте маршруты, conntrack и NAT провайдера; этап можно повторить')


def verify_network(directory, registry):
    verify_conntrack()
    sys.path.insert(0, '/usr/local/sbin')
    from vpn_ip_switch import GlobalManager
    manager = GlobalManager(registry=str(directory/'servers.json'))
    state = manager.status()
    address = state.get('egress_ip')
    if not address or address not in {item['ip'] for item in state['addresses']}:
        raise ValueError('Не подтверждён назначенный исходящий IP')
    actual = manager.nft_snapshot()
    if 'ip daddr !=' in actual or 'udp sport' in actual or ('snat ip to '+address not in actual and any(e['protocol']=='amneziawg' for e in registry)):
        raise ValueError('Правила не соответствуют all-ingress/fixed-egress')
    verify_egress(address)
    for target in manager.targets():
        if target['protocol']=='vless':
            cfg=json.loads(manager.path(target['env'].get('CONFIG_FILE','/usr/local/etc/xray/config.json')).read_text())
            out=[x for x in cfg.get('outbounds',[]) if x.get('protocol')=='freedom']
            if not out or any(x.get('sendThrough')!=address for x in out):
                raise ValueError('VLESS не использует выбранный исходящий IP')
        if target['protocol']=='hysteria2':
            cfg=json.loads(manager.path(target['env']['CONFIG_FILE']).read_text())
            if cfg['listen'].split(':',1)[0]!='0.0.0.0' or cfg['outbounds'][0].get('direct',{}).get('bindIPv4')!=address:
                raise ValueError('Hysteria не использует all-ingress/fixed-egress')


def verify(directory, selected):
    registry = json.loads((directory / 'servers.json').read_text())
    expected = {IDS[name] for name in selected}
    if {entry['id'] for entry in registry} != expected or len(registry) != len(expected):
        raise ValueError('Реестр бота не совпадает с выбранными VPN')
    for entry in registry:
        result = subprocess.run([entry['command'], '-j', 'list'], check=True, capture_output=True, text=True, timeout=120)
        if not json.loads(result.stdout).get('ok'):
            raise ValueError('Контроллер не подтвердил готовность: ' + entry['id'])
        active = subprocess.run(['systemctl', 'is-active', '--quiet', entry['service']],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=15).returncode == 0
        if active != expected_enabled(directory / 'access.sqlite3', entry['id']):
            raise ValueError('Состояние службы не совпадает с настройками бота: ' + entry['service'])
    verify_network(directory, registry)
    for name, iface in [('amnezia20','awg0'),('amnezia31','awg3')]:
        if name in selected:
            subprocess.run(['/usr/bin/python3','/usr/local/sbin/vpnbot-kernel-check.py',iface,'--all-boot'],check=True,timeout=120)
    for service in ('vpnbot.service', 'vpnbot-worker.service', 'vpnbot-traffic.timer', 'vpnbot-channel.timer'):
        subprocess.run(['systemctl', 'is-active', '--quiet', service], check=True, timeout=15)
    print('Выбранные CLI, службы, бот, worker и таймеры проверены.')


if __name__ == '__main__':
    try:
        verify(Path(os.environ.get('INSTALL_DIR', '/root/vpnbot')).resolve(), os.environ['V3_SELECTED'].split(','))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('Ошибка проверки установки: ' + str(error), file=sys.stderr)
        sys.exit(1)
