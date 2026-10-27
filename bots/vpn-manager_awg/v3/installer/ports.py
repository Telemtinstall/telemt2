"""Conservative port preflight; wildcard and IPv6 binds reserve the port too."""
import subprocess

def validate(plan, occupied=()):
    seen = {}
    for transport, port, owner in plan:
        port = int(port)
        if not 1 <= port <= 65535:
            raise ValueError(f'{owner}: invalid port {port}')
        key = transport, port
        if key in seen:
            raise ValueError(f'Конфликт выбранных модулей: {seen[key]} и {owner} используют {transport}/{port}; измените порт в INI')
        seen[key] = owner
        if key in occupied:
            raise ValueError(f'{owner}: {transport}/{port} уже занят; выберите другой порт')

def occupied_ports():
    result = set()
    for transport, flag in [('tcp', '-lntH'), ('udp', '-lnuH')]:
        output = subprocess.check_output(['ss', flag], text=True)
        for line in output.splitlines():
            fields = line.split()
            if len(fields) >= 4:
                value = fields[3].rsplit(':', 1)[-1]
                if value.isdigit():
                    result.add((transport, int(value)))
    # Include published Docker ports and existing NAT port rules conservatively.
    nft = subprocess.run(['nft', '-j', 'list', 'ruleset'], capture_output=True, text=True)
    if nft.returncode:
        raise RuntimeError('Не удалось проверить nftables: установка остановлена')
    import json
    def walk(obj):
        if isinstance(obj, dict):
            match = obj.get('match', {})
            payload = match.get('left', {}).get('payload', {}) if isinstance(match.get('left'), dict) else {}
            if payload.get('field') == 'dport' and payload.get('protocol') in {'tcp','udp'}:
                right = match.get('right')
                def reserve(value):
                    if isinstance(value,int):result.add((payload['protocol'],value))
                    elif isinstance(value,list):
                        for item in value:reserve(item)
                    elif isinstance(value,dict):
                        if 'range' in value:
                            lo,hi=value['range']
                            result.update((payload['protocol'],p) for p in range(int(lo),int(hi)+1))
                        elif 'set' in value:reserve(value['set'])
                reserve(right)
            for value in obj.values(): walk(value)
        elif isinstance(obj, list):
            for value in obj: walk(value)
    # Only NAT rules reserve ports; filter/allow rules alone do not occupy a port.
    data=json.loads(nft.stdout)
    for item in data.get('nftables', []):
        rule=item.get('rule', {})
        if any(isinstance(e,dict) and any(k in e for k in ('dnat','redirect')) for e in rule.get('expr', [])):
            walk(rule)
    import shutil, re
    if shutil.which('iptables-legacy-save'):
        legacy=subprocess.run(['iptables-legacy-save','-t','nat'],capture_output=True,text=True)
        if legacy.returncode:raise RuntimeError('Не удалось проверить legacy NAT')
        for line in legacy.stdout.splitlines():
            if not re.search(r'-j (?:DNAT|REDIRECT)\b',line):continue
            protocol=re.search(r'-p (tcp|udp)\b',line)
            ports=re.search(r'--dports? ([0-9,:-]+)',line)
            if not protocol or not ports:raise RuntimeError('Неизвестная legacy NAT-резервация; проверьте вручную')
            for value in ports[1].split(','):
                bounds=re.split('[:-]',value);lo=int(bounds[0]);hi=int(bounds[-1])
                result.update((protocol[1],p) for p in range(lo,hi+1))
    return result
