"""Friendly HTTPS preflight and explicit consent for a local certificate/site."""
import ipaddress
import socket
import ssl
from progress import activity
from urllib.parse import urlsplit, urlunsplit


def normalize_url(value):
    value = value.strip()
    if not value or any(c.isspace() for c in value):
        raise ValueError('Укажите домен или HTTPS-адрес без пробелов')
    if '://' not in value:
        value = 'https://' + value
    try:
        parts = urlsplit(value)
        if parts.scheme not in {'http', 'https'} or not parts.hostname or parts.username or parts.password:
            raise ValueError()
        host = parts.hostname.encode('idna').decode('ascii').lower()
        port = parts.port
        if port is not None and not 1 <= port <= 65535:
            raise ValueError()
        if parts.scheme == 'http' and port == 80:
            port = None
        authority = '[' + host + ']' if ':' in host else host
        if port is not None and port != 443:
            authority += ':' + str(port)
        return urlunsplit(('https', authority, parts.path, parts.query, ''))
    except (ValueError, UnicodeError):
        raise ValueError('Укажите домен или HTTPS-адрес без логина и пароля') from None


def https_available(url):
    parts = urlsplit(url)
    try:
        context = ssl.create_default_context()
        with socket.create_connection((parts.hostname, parts.port or 443), timeout=6) as connection:
            with context.wrap_socket(connection, server_hostname=parts.hostname):
                return True
    except (OSError, ValueError):
        return False


def points_to_server(host, ip):
    try:
        addresses = {item[4][0] for item in socket.getaddrinfo(host, None, socket.AF_INET)}
        return addresses == {ip}
    except OSError:
        return False


def certificate_domains(answers):
    domains = [answers['HY_DOMAIN'].encode('idna').decode('ascii').lower()]
    if answers.get('HY_MASQUERADE_MODE') == 'local':
        host = urlsplit(normalize_url(answers.get('HY_MASQUERADE') or domains[0])).hostname
        if host not in domains:
            domains.append(host)
    return domains


def prepare_site(questionnaire, ip):
    state, answers = questionnaire.state, questionnaire.answers
    if answers.get('HY_OBFS') != 'none':
        return
    resolved = state.data.setdefault('resolved', {})
    while True:
        url = answers.get('HY_MASQUERADE')
        if not url:
            url = questionnaire.ask_site_url()
        url = normalize_url(url)
        answers['HY_MASQUERADE'] = url
        state.save()
        host = urlsplit(url).hostname
        local = resolved.get('HY_MASQUERADE_MODE', answers.get('HY_MASQUERADE_MODE', 'proxy')) == 'local'
        with activity('Идёт проверка HTTPS сайта-маскировки'):
            available = not local and https_available(url)
            owned = False if available else points_to_server(host, ip)
        if available:
            return
        # A local certificate is only possible for a name verified by ACME on this server.
        try:
            ipaddress.ip_address(host)
            owned = False
        except ValueError:
            pass
        if local and owned:
            resolved['HY_MASQUERADE_MODE'] = 'local'
            state.save()
            return
        if owned:
            print('HTTPS для ' + host + ' пока недоступен. Домен указывает на этот сервер.')
            print('Можно получить сертификат Let’s Encrypt и включить локальную HTTPS-страницу в Hysteria.')
            if questionnaire.silent:
                raise ValueError('Для настройки сертификата задайте [hysteria2] masquerade_mode=local; '
                                 'либо выберите другой домен с работающим HTTPS')
            if questionnaire.yes_no('certificate:' + host, 'Настроить сертификат и HTTPS-страницу для ' + host):
                resolved['HY_MASQUERADE_MODE'] = 'local'
                state.save()
                return
        else:
            print('HTTPS для ' + host + ' недоступен, а домен не указывает на выбранный IP этого сервера.')
            print('Установить сертификат на чужом сервере этот установщик не может. Выберите другой домен с HTTPS.')
            if questionnaire.silent:
                raise ValueError('Выберите другой домен с работающим HTTPS в [hysteria2] masquerade_url')
        answers.pop('HY_MASQUERADE', None)
        resolved.pop('HY_MASQUERADE_MODE', None)
        # Explicit local mode applies to the previous site only; the next entry is a new choice.
        if answers.get('HY_MASQUERADE_MODE') == 'local':
            answers['HY_MASQUERADE_MODE'] = 'proxy'
        state.save()
