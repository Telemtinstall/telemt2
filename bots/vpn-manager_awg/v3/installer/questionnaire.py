"""Explicit protocol choices; every accepted answer is checkpointed immediately."""
import getpass
import secrets
from ini_config import selected_valid, validate_answers, validate_common

PROTOCOLS = ('amnezia20', 'amnezia31', 'vless', 'hysteria2')
LABELS = dict(zip(PROTOCOLS, ('AmneziaWG 2.0', 'AmneziaWG 3.1', 'VLESS', 'Hysteria 2')))


class Questionnaire:
    def __init__(self, state, silent=False):
        self.state, self.silent = state, silent
        self.answers = state.data['answers']

    def ask(self, key, label, default=None, secret=False, choices=None):
        value = self.answers.get(key)
        if not value:
            if self.silent:
                if default is None:
                    raise ValueError('Для --silent требуется ' + key)
                value = default() if callable(default) else default
            else:
                hint = f' [{default}]' if default is not None and not secret and not callable(default) else ''
                value = (getpass.getpass(label + hint + ': ') if secret else input(label + hint + ': ')).strip()
                if not value and default is not None:
                    value = default() if callable(default) else default
            if not value:
                raise ValueError('Не заполнено: ' + label)
            if choices and value not in choices:
                raise ValueError(key + ': допустимо ' + ', '.join(sorted(choices)))
            self.answers[key] = str(value)
            self.state.save()
        if choices and value not in choices:
            raise ValueError(key + ': допустимо ' + ', '.join(sorted(choices)))
        return str(value)

    def choose(self, key, label, choices):
        saved = self.state.data['selection'].get(key)
        if saved is not None:
            if saved not in choices:
                raise ValueError('Повреждён сохранённый выбор: ' + key)
            return saved
        if self.silent:
            raise ValueError('Для --silent задайте --onlyprotocol или секцию [protocols] в INI')
        while True:
            value = input(label + ': ').strip().lower()
            if value in choices:
                self.state.data['selection'][key] = value
                self.state.save()
                return value
            print('Нужно явно выбрать: ' + ', '.join(sorted(choices)))

    def select_protocols(self):
        if self.state.data.get('protocols'):
            return selected_valid(self.state.data['protocols'])
        all_awg = self.choose('all', 'Установить все совместимые VPN (оба AWG и один из VLESS/Hysteria 2)? да/нет', {'да', 'нет'}) == 'да'
        chosen = []
        for name in PROTOCOLS[:2]:
            if all_awg or self.choose(name, 'Установить ' + LABELS[name] + '? да/нет', {'да', 'нет'}) == 'да':
                chosen.append(name)
        alternative = self.choose('alternative', 'VLESS / Hysteria 2? 1 — VLESS, 2 — Hysteria 2', {'1', '2'})
        chosen.append({'1': 'vless', '2': 'hysteria2'}[alternative])
        self.state.data['protocols'] = selected_valid(chosen)
        self.state.save()
        return chosen

    def collect(self, chosen):
        self.ask('VPN_PUBLIC_HOST', 'Публичный IPv4 сервера или auto', 'auto')
        self.ask('VPN_INITIAL_CLIENT', 'Имя первого VPN-пользователя', 'vpnuser1')
        self.ask('ADMIN_BOT', 'Telegram ID администраторов через запятую')
        self.ask('BOT_TOKEN', 'Токен Telegram-бота', secret=True)
        self.ask('SERVER_CHANNEL_MBIT', 'Скорость канала, Мбит/с, или auto (Speedtest)', 'auto')
        for name, key, default in [('amnezia20', 'AWG20_PORT', '1234'), ('amnezia31', 'AWG31_PORT', '1235'),
                                   ('vless', 'VLESS_PORT', '443'), ('hysteria2', 'HY_PORT', '443')]:
            if name in chosen:
                self.ask(key, LABELS[name] + ': внешний порт', default)
        if 'vless' in chosen:
            mode = self.ask('VLESS_MODE', 'Режим VLESS: reality / direct / mask', choices={'reality', 'direct', 'mask'})
            if mode == 'mask':
                self.ask('VLESS_DOMAIN', 'Домен VLESS для HTTPS-маскировки')
            if mode == 'reality':
                self.ask('REALITY_TARGET', 'Reality target', 'www.google.com:443')
                self.ask('REALITY_SERVER_NAME', 'Reality SNI', 'www.google.com')
        if 'hysteria2' in chosen:
            self.ask('HY_DOMAIN', 'Домен Hysteria 2 (A-запись должна вести на сервер)')
            mode = self.ask('HY_OBFS', 'Режим Hysteria: none / salamander / gecko', choices={'none', 'salamander', 'gecko'})
            if mode == 'none':
                self.ask('HY_MASQUERADE', 'URL сайта-маскировки')
            else:
                self.ask('HY_OBFS_PASSWORD', 'Пароль обфускации (Enter — сгенерировать)',
                         lambda: secrets.token_urlsafe(32), secret=True)
            if mode == 'gecko':
                self.ask('HY_MIN_PACKET', 'Gecko: минимальный размер', '512')
                self.ask('HY_MAX_PACKET', 'Gecko: максимальный размер', '1200')
            self.answers.setdefault('HY_VERSION', 'app/v2.13.0')
            self.state.save()
        validate_common(self.answers, chosen, require=True)
        validate_answers(self.answers, chosen)
