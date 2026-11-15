"""Public-domain SSH/HTTPS reachability, bound to each assigned source IPv4."""
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import re
import socket
import ssl

from domain_host import hostname, lookup


def resolve_target(domain):
    name = hostname(domain)
    answer = lookup(name)
    if not answer['ok'] or not answer['a_records']:
        raise ValueError('Не удалось получить A-запись проверочного домена')
    addresses = [ipaddress.IPv4Address(value) for value in answer['a_records']]
    if any(not ip.is_global or ip.is_multicast for ip in addresses):
        raise ValueError('Проверочный домен должен указывать только на публичные IPv4')
    return name, str(min(addresses))


def error_code(exc):
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return 'timeout'
    if isinstance(exc, ConnectionRefusedError):
        return 'refused'
    if isinstance(exc, ssl.SSLError):
        return 'tls_error'
    return 'network_error'


def probe_source(source, domain, destination, timeout=3):
    source = str(ipaddress.IPv4Address(source))
    destination = str(ipaddress.IPv4Address(destination))
    name = hostname(domain)
    result = {'ssh': False, 'https': False, 'ssh_reason': '', 'https_reason': ''}
    try:
        with socket.create_connection((destination, 22), timeout=timeout,
                                      source_address=(source, 0)) as connection:
            banner = connection.recv(1024)
            result['ssh'] = bool(re.search(rb'(?m)^SSH-(?:2\.0|1\.99)-', banner))
            result['ssh_reason'] = 'ok' if result['ssh'] else 'invalid_response'
    except OSError as exc:
        result['ssh_reason'] = error_code(exc)
    try:
        with socket.create_connection((destination, 443), timeout=timeout,
                                      source_address=(source, 0)) as connection:
            with ssl.create_default_context().wrap_socket(connection, server_hostname=name) as tls:
                tls.sendall(('HEAD / HTTP/1.1\r\nHost: ' + name + '\r\nConnection: close\r\n\r\n').encode('ascii'))
                response = tls.recv(4096)
                result['https'] = bool(re.match(rb'HTTP/1\.[01] [1-5][0-9]{2}(?: |\r)', response))
                result['https_reason'] = 'ok' if result['https'] else 'invalid_response'
    except OSError as exc:
        result['https_reason'] = error_code(exc)
    result['available'] = result['ssh'] and result['https']
    return result


def check_addresses(addresses, domain):
    # Resolve once and pin the same destination in every source-IP test.
    name, destination = resolve_target(domain)
    def check(item):
        return dict(item, **probe_source(item['ip'], name, destination))
    with ThreadPoolExecutor(max_workers=min(8, max(1, len(addresses)))) as pool:
        rows = list(pool.map(check, addresses))
    return {'domain': name, 'destination_ip': destination, 'addresses': rows,
            'ssh_port': 22, 'https_port': 443, 'read_only': True}
