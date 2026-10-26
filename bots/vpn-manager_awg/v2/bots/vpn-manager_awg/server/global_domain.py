"""Domain endpoint configuration, independent of DNS and registrar APIs."""
import json
from domain_host import hostname, lookup


class GlobalMixin:
    def domain_path(self):
        return self.path('/etc/vpnbot-global/domain.json')

    def domain_config(self):
        path = self.domain_path()
        return json.loads(path.read_text()) if path.exists() else {'domain': ''}

    def profile_host(self, address):
        name = getattr(self, '_selected_domain', None)
        if name is None: name = self.domain_config().get('domain', '')
        return hostname(name) if name else address

    def domain_status(self):
        state = self.path('/etc/vpnbot/public-ip.json')
        active = json.loads(state.read_text()).get('ip') if state.exists() else None
        if not active:
            currents = {t['current'] for t in self.targets()}
            assigned = {a['ip'] for a in self.addresses()}
            if len(currents) == 1 and next(iter(currents)) in assigned:
                active = next(iter(currents))
        return {'ok': True, 'domain': self.domain_config().get('domain', ''), 'active_ip': active}

    def domain_check(self):
        status = self.domain_status()
        if not status['domain']:
            return dict(status, a_records=[], matches=False, lookup_ok=False, error='Домен ещё не задан')
        result = lookup(status['domain'])
        # Transport succeeds even when DNS does not: show a diagnostic, never block settings.
        return dict(result, ok=True, lookup_ok=result['ok'], active_ip=status['active_ip'],
                    matches=bool(status['active_ip']) and set(result['a_records']) == {status['active_ip']})

    def domain_set(self, name, address=None):
        name = hostname(name)
        address = address or self.domain_status()['active_ip']
        if not address: raise ValueError('Сначала выберите IP сервера')
        return self.apply(address, 'domain-settings', domain=name)

    def plan(self, address):
        changes, titles = super().plan(address)
        if getattr(self, '_selected_domain', None) is not None:
            data = (json.dumps({'domain': self._selected_domain}) + '\n').encode()
            path = self.domain_path()
            if not path.exists() or path.read_bytes() != data: changes[path] = data
        return changes, titles

    def apply(self, address, actor='cli', domain=None):
        self._selected_domain = hostname(domain) if domain is not None else None
        try:
            result = super().apply(address, actor)
            return dict(result, domain=self.domain_config().get('domain', ''), dns_changed=False)
        finally:
            self._selected_domain = None
