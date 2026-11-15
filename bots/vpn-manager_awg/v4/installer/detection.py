"""Resolve explicit auto settings once; keep the result in installer checkpoints."""
import ipaddress
import json
import math
import shutil
import subprocess

FALLBACK_MBIT = 100
SPEEDTEST_WARNING = ('Speedtest недоступен или заблокирован.\n'
                     'Установлена скорость по умолчанию: 100 Мбит/с.\n'
                     'Установка продолжается.')


def assigned_ipv4():
    output = subprocess.check_output(['ip', '-j', '-4', 'address', 'show'], text=True, timeout=15)
    addresses = set()
    for interface in json.loads(output):
        for entry in interface.get('addr_info', []):
            try:
                address = ipaddress.IPv4Address(entry['local'])
            except (KeyError, ValueError):
                continue
            if address.is_global:
                addresses.add(str(address))
    return addresses


def public_ipv4():
    addresses = assigned_ipv4()
    if not addresses:
        raise ValueError('public_ip=auto: публичный IPv4 не найден на интерфейсах сервера')
    try:
        result = subprocess.run(['ip', '-j', '-4', 'route', 'get', '1.1.1.1'],
                                check=True, capture_output=True, text=True, timeout=15)
        for route in json.loads(result.stdout):
            source = route.get('prefsrc') or route.get('src')
            if source in addresses:
                return source
    except (subprocess.SubprocessError, OSError, ValueError):
        pass
    if len(addresses) == 1:
        return next(iter(addresses))
    raise ValueError('public_ip=auto: найдено несколько публичных IPv4, основной не определён. '
                     'Укажите [server] public_ip явно')


def channel_speed(report=print):
    """speedtest-cli reports bits/s. No secrets or full client metadata are logged."""
    try:
        executable = shutil.which('speedtest-cli')
        if not executable:
            raise ValueError('speedtest-cli unavailable')
        result = subprocess.run([executable, '--json', '--secure'], check=True,
                                capture_output=True, text=True, timeout=90)
        data = json.loads(result.stdout)
        down, up = float(data['download']), float(data['upload'])
        if any(not math.isfinite(value) or value <= 0 for value in (down, up)):
            raise ValueError('invalid speed measurement')
        mbit = max(1, math.ceil(max(down, up) / 1_000_000))
        report(f'Speedtest: download={down / 1_000_000:.1f}, upload={up / 1_000_000:.1f} Мбит/с. '
               f'Установлена скорость: {mbit} Мбит/с.')
        return str(mbit), 'speedtest'
    except (subprocess.SubprocessError, OSError, ValueError, KeyError, TypeError):
        report(SPEEDTEST_WARNING)
        return str(FALLBACK_MBIT), 'fallback'


def resolve_auto(state, report=print, include_speed=True):
    answers = state.data['answers']
    resolved = state.data.setdefault('resolved', {})
    if answers.get('VPN_PUBLIC_HOST') == 'auto' and 'VPN_PUBLIC_HOST' not in resolved:
        resolved['VPN_PUBLIC_HOST'] = public_ipv4()
        state.save()
        report('Автоматически выбран IPv4: ' + resolved['VPN_PUBLIC_HOST'])
    if include_speed and answers.get('SERVER_CHANNEL_MBIT') == 'auto' and 'SERVER_CHANNEL_MBIT' not in resolved:
        value, source = channel_speed(report)
        resolved['SERVER_CHANNEL_MBIT'] = value
        state.data.setdefault('detection', {})['channel_source'] = source
        state.save()
    return dict(answers, **resolved)
