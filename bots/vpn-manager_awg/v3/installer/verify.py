#!/usr/bin/env python3
"""Verify only the selected protocol controllers/services after deployment."""
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys

IDS = {'amnezia20': 'amneziawg', 'amnezia31': 'amneziawg3', 'vless': 'vless', 'hysteria2': 'hysteria2'}


def expected_enabled(database, server_id):
    if not database.exists():
        return True
    with sqlite3.connect(database.as_uri() + '?mode=ro', uri=True) as db:
        if not db.execute("SELECT 1 FROM sqlite_master WHERE name='protocol_states'").fetchone():
            return True
        row = db.execute('SELECT enabled FROM protocol_states WHERE server_id=?', (server_id,)).fetchone()
        return row is None or bool(row[0])


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
    for service in ('vpnbot.service', 'vpnbot-worker.service', 'vpnbot-traffic.timer', 'vpnbot-channel.timer'):
        subprocess.run(['systemctl', 'is-active', '--quiet', service], check=True, timeout=15)
    print('Выбранные CLI, службы, бот, worker и таймеры проверены.')


if __name__ == '__main__':
    try:
        verify(Path(os.environ.get('INSTALL_DIR', '/root/vpnbot')).resolve(), os.environ['V3_SELECTED'].split(','))
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print('Ошибка проверки установки: ' + str(error), file=sys.stderr)
        sys.exit(1)
