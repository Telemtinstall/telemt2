"""Read-only A lookup. One validated domain argument; no shell or caller options."""
import ipaddress
import json
import re
import subprocess
import sys


def hostname(value):
    if not isinstance(value, str) or not value or value != value.strip():
        raise ValueError('Введите только доменное имя без пробелов')
    try:
        name = value.removesuffix('.').encode('idna').decode('ascii').lower()
    except UnicodeError:
        raise ValueError('Некорректное доменное имя') from None
    labels = name.split('.')
    if len(name) > 253 or len(labels) < 2 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels):
        raise ValueError('Введите только доменное имя, например vpn.example.org')
    try:
        ipaddress.ip_address(name)
    except ValueError:
        return name
    raise ValueError('Нужен домен, а не IP-адрес')


def lookup(value):
    name = hostname(value)
    base = {'domain': name, 'a_records': [], 'read_only': True}
    try:
        result = subprocess.run(['/usr/bin/host', '-W', '3', '-R', '1', '-t', 'A', name + '.'],
            stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10,
            env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C'})
    except FileNotFoundError:
        return dict(base, ok=False, error='Установите пакет bind9-host на сервере')
    except subprocess.TimeoutExpired:
        return dict(base, ok=False, error='Проверка DNS превысила время ожидания')
    addresses = set()
    for line in result.stdout.splitlines():
        match = re.fullmatch(r'\S+ has address (\S+)', line)
        if match:
            try: addresses.add(str(ipaddress.IPv4Address(match[1])))
            except ValueError: pass
    return dict(base, ok=result.returncode == 0, a_records=sorted(addresses),
                error='' if result.returncode == 0 else 'Не удалось получить A-запись')


if __name__ == '__main__':
    try:
        if len(sys.argv) != 2: raise ValueError('Требуется ровно один аргумент: домен')
        result = lookup(sys.argv[1])
    except ValueError as exc:
        result = {'ok': False, 'error': str(exc)}
    print(json.dumps(result, ensure_ascii=False))
    sys.exit(0 if result['ok'] else 1)
