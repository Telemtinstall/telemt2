"""Strict INI answers; no interpolation, shell sourcing, or implicit protocol choice."""
import configparser
import os
from pathlib import Path
import stat

FIELDS={
 'server':{'public_ip':'VPN_PUBLIC_HOST','initial_client':'VPN_INITIAL_CLIENT','channel_mbit':'SERVER_CHANNEL_MBIT'},
 'telegram':{'bot_token':'BOT_TOKEN','admin_ids':'ADMIN_BOT'},
 'amnezia20':{'port':'AWG20_PORT'},
 'amnezia31':{'port':'AWG31_PORT'},
 'vless':{'port':'VLESS_PORT','mode':'VLESS_MODE','domain':'VLESS_DOMAIN','reality_target':'REALITY_TARGET','reality_sni':'REALITY_SERVER_NAME'},
 'hysteria2':{'port':'HY_PORT','domain':'HY_DOMAIN','obfs':'HY_OBFS','obfs_password':'HY_OBFS_PASSWORD',
   'masquerade_mode':'HY_MASQUERADE_MODE','masquerade_url':'HY_MASQUERADE','version':'HY_VERSION','min_packet_size':'HY_MIN_PACKET','max_packet_size':'HY_MAX_PACKET'},
}

def load_ini(path):
    path=Path(path)
    metadata=path.lstat()
    if not stat.S_ISREG(metadata.st_mode):raise ValueError('INI должен быть обычным файлом, без символьной ссылки')
    parser=configparser.ConfigParser(interpolation=None,strict=True)
    try:
        with path.open(encoding='utf-8') as stream:parser.read_file(stream)
    except (configparser.Error,UnicodeError):raise ValueError('Некорректный INI: проверьте секции, переменные и повторы') from None
    if parser.defaults():raise ValueError('Секция DEFAULT запрещена: указывайте ответы в соответствующих секциях')
    answers={};protocols=None
    for section in parser.sections():
        allowed={'amnezia20','amnezia31','vless_or_hysteria2'} if section=='protocols' else FIELDS.get(section)
        if allowed is None:raise ValueError('Неизвестная секция INI: '+section)
        for key in parser[section]:
            if key not in allowed:raise ValueError('Неизвестная переменная INI: '+section+'.'+key)
        if section=='protocols':
            protocols=[]
            for name in ('amnezia20','amnezia31'):
                value=parser[section].get(name,'').strip().lower()
                if value not in {'yes','no'}:raise ValueError('protocols.'+name+': требуется yes или no')
                if value=='yes':protocols.append(name)
            alternative=parser[section].get('vless_or_hysteria2','').strip()
            if alternative not in {'1','2'}:raise ValueError('VLESS / Hysteria 2? Укажите protocols.vless_or_hysteria2 = 1 или 2')
            protocols.append({'1':'vless','2':'hysteria2'}[alternative])
        else:
            for key,env in FIELDS[section].items():
                value=parser[section].get(key,'').strip()
                if value:answers[env]=value
    secrets=[answers.get('BOT_TOKEN'),answers.get('HY_OBFS_PASSWORD')]
    if any(value and not value.startswith('REPLACE_') for value in secrets):
        owners={os.geteuid()}
        if os.environ.get('SUDO_UID','').isdigit():owners.add(int(os.environ['SUDO_UID']))
        if metadata.st_uid not in owners or stat.S_IMODE(metadata.st_mode)&0o077:
            raise ValueError('INI с секретами должен принадлежать текущему пользователю и иметь права 0600 (chmod 600)')
    return answers,protocols

def merge_protocols(configured,cli):
    if configured is not None and cli is not None and set(configured)!=set(cli):
        raise ValueError('Конфликт: --onlyprotocol противоречит выбору VPN в INI; укажите один согласованный набор')
    return list(dict.fromkeys(cli)) if cli else configured


def selected_valid(values):
    allowed = {'amnezia20', 'amnezia31', 'vless', 'hysteria2'}
    if not values:
        raise ValueError('Нужно выбрать хотя бы один VPN')
    if set(values) - allowed:
        raise ValueError('Неизвестный протокол')
    if {'vless', 'hysteria2'} <= set(values):
        raise ValueError('VLESS и Hysteria 2 одновременно запрещены')
    return list(dict.fromkeys(values))


def build_plan(answers, protocols):
    if not protocols:
        return []
    plan = []
    ports = {'amnezia20': ('AWG20_PORT', 1234, 'udp'), 'amnezia31': ('AWG31_PORT', 1235, 'udp'),
             'vless': ('VLESS_PORT', 443, 'tcp'), 'hysteria2': ('HY_PORT', 443, 'udp')}
    for name in selected_valid(protocols):
        key, default, transport = ports[name]
        try:
            port = int(answers.get(key, default))
        except (ValueError, TypeError):
            raise ValueError(key + ': требуется целый номер порта') from None
        plan.append((transport, port, name))
    if 'vless' in protocols:
        plan.append(('tcp', 10085, 'vless:api'))
        if answers.get('VLESS_MODE') == 'mask':
            plan.extend([('tcp', 80, 'vless:acme'), ('tcp', 12710, 'vless:backend')])
    if 'hysteria2' in protocols:
        plan.extend([('tcp', 80, 'hysteria2:acme'), ('tcp', 19090, 'hysteria2:api')])
        if answers.get('HY_OBFS') == 'none' and answers.get('HY_MASQUERADE_MODE') == 'local':
            from masquerade import normalize_url
            from urllib.parse import urlsplit
            raw = answers.get('HY_MASQUERADE') or answers.get('HY_DOMAIN')
            port = (urlsplit(normalize_url(raw)).port or 443) if raw else 443
            plan.append(('tcp', port, 'hysteria2:https'))
    return plan


def validate_answers(answers, protocols):
    """Validate selected modes and all port reservations before system changes."""
    if not protocols:
        return
    from ports import validate
    if 'vless' in protocols:
        mode = answers.get('VLESS_MODE')
        if mode and mode not in {'reality', 'direct', 'mask'}:
            raise ValueError('[vless] mode: reality / direct / mask')
    if 'hysteria2' in protocols:
        mode = answers.get('HY_OBFS')
        if mode and mode not in {'none', 'salamander', 'gecko'}:
            raise ValueError('[hysteria2] obfs: none / salamander / gecko')
        if mode == 'gecko':
            try:
                lo, hi = int(answers.get('HY_MIN_PACKET', 512)), int(answers.get('HY_MAX_PACKET', 1200))
            except (ValueError, TypeError):
                raise ValueError('Размеры Gecko должны быть целыми числами') from None
            if not 1 <= lo <= hi <= 2048:
                raise ValueError('Gecko: требуется 1 <= min_packet_size <= max_packet_size <= 2048')
    validate(build_plan(answers, protocols))


def domain_name(value):
    import ipaddress
    import re
    try:
        ipaddress.ip_address(value)
    except ValueError:
        pass
    else:
        raise ValueError('Нужно DNS-имя, а не IP')
    try:
        ascii_name = value.encode('idna').decode('ascii').lower()
    except UnicodeError:
        raise ValueError('Некорректное DNS-имя') from None
    labels = ascii_name.split('.')
    if (len(ascii_name) > 253 or len(labels) < 2
            or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', label) for label in labels)):
        raise ValueError('Некорректное DNS-имя')
    return ascii_name


def validate_common(answers, protocols=None, require=False):
    import ipaddress
    import math
    import re
    from urllib.parse import urlsplit
    protocols = protocols or []
    required = ['VPN_PUBLIC_HOST', 'BOT_TOKEN', 'ADMIN_BOT']
    if 'vless' in protocols:
        required.append('VLESS_MODE')
        if answers.get('VLESS_MODE') == 'mask':
            required.append('VLESS_DOMAIN')
    if 'hysteria2' in protocols:
        required.extend(['HY_DOMAIN', 'HY_OBFS'])
        if answers.get('HY_OBFS') == 'none' and answers.get('HY_MASQUERADE_MODE', 'proxy') != 'local':
            required.append('HY_MASQUERADE')
    missing = [key for key in required if not answers.get(key)]
    if require and missing:
        raise ValueError('Не заполнены обязательные ответы: ' + ', '.join(missing))
    value = answers.get('VPN_PUBLIC_HOST')
    if value and value != 'auto':
        try:
            address = ipaddress.IPv4Address(value)
        except ipaddress.AddressValueError:
            raise ValueError('[server] public_ip: нужен публичный IPv4 или auto') from None
        if not address.is_global:
            raise ValueError('[server] public_ip: замените адрес примера публичным IPv4 сервера')
    value = answers.get('SERVER_CHANNEL_MBIT')
    if value and value != 'auto':
        try:
            speed = float(value)
        except ValueError:
            raise ValueError('[server] channel_mbit: положительное число или auto') from None
        if not math.isfinite(speed) or speed <= 0:
            raise ValueError('[server] channel_mbit: положительное конечное число или auto')
    value = answers.get('BOT_TOKEN')
    if value and not re.fullmatch(r'[0-9]+:[^\s]+', value):
        # Permit the published placeholder only in non-installing/partial checks.
        if require or value != 'REPLACE_BOT_TOKEN':
            raise ValueError('BOT_TOKEN: замените пример реальным токеном BotFather')
    value = answers.get('ADMIN_BOT')
    if value and not re.fullmatch(r'[0-9]+(,[0-9]+)*', value):
        raise ValueError('ADMIN_BOT: числовые ID через запятую без пробелов')
    value = answers.get('VPN_INITIAL_CLIENT')
    if value and not re.fullmatch(r'[A-Za-z0-9_.-]{1,32}', value):
        raise ValueError('[server] initial_client: 1–32 символа, латиница, цифры, точка, _, -')
    domains = []
    if 'vless' in protocols and answers.get('VLESS_MODE') == 'mask':
        domains.append('VLESS_DOMAIN')
    if 'hysteria2' in protocols:
        domains.append('HY_DOMAIN')
        version = answers.get('HY_VERSION', 'app/v2.13.0')
        if not re.fullmatch(r'app/v2\.\d+\.\d+', version):
            raise ValueError('[hysteria2] version: нужен точный тег app/v2.x.y')
        if answers.get('HY_OBFS') == 'gecko' and tuple(map(int, version[5:].split('.'))) < (2, 9, 2):
            raise ValueError('Gecko требует Hysteria 2.9.2+')
        if answers.get('HY_MASQUERADE_MODE', 'proxy') not in {'proxy', 'local'}:
            raise ValueError('[hysteria2] masquerade_mode: proxy / local')
        if answers.get('HY_OBFS') == 'none' and answers.get('HY_MASQUERADE'):
            from masquerade import normalize_url
            normalize_url(answers['HY_MASQUERADE'])
    for key in domains:
        if answers.get(key):
            domain_name(answers[key])


def validate_silent(answers, protocols):
    if not protocols:
        raise ValueError('Для --silent требуется --onlyprotocol или секция protocols в --config')
    selected_valid(protocols)
    try:
        validate_common(answers, protocols, require=True)
    except ValueError as error:
        raise ValueError('Тихий режим: ' + str(error)) from None
    validate_answers(answers, protocols)
