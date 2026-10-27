"""Explicit protocol choices; every accepted answer is checkpointed immediately."""
import getpass
import secrets
from masquerade import normalize_url
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

    def yes_no(self, key, label):
        # Keep already accepted answers from the first v3 builds after a restart.
        previous = self.state.data['selection'].get(key)
        if previous in {'да', 'нет'}:
            self.state.data['selection'][key] = {'да': 'y', 'нет': 'n'}[previous]
            self.state.save()
        return self.choose(key, label + '? y/n', {'y', 'n'}) == 'y'

    def select_protocols(self):
        if self.state.data.get('protocols'):
            return selected_valid(self.state.data['protocols'])
        all_awg = self.yes_no('all', 'Установить все совместимые VPN (оба AWG и один из VLESS/Hysteria 2)')
        chosen = []
        for name in PROTOCOLS[:2]:
            if all_awg or self.yes_no(name, 'Установить ' + LABELS[name]):
                chosen.append(name)
        if not self.silent and 'alternative' not in self.state.data['selection']:
            print('1 — VLESS')
            print('2 — Hysteria 2')
        alternative = self.choose('alternative', 'Выберите 1/2', {'1', '2'})
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
                transport = 'TCP' if name == 'vless' else 'UDP'
                self.ask(key, LABELS[name] + ': внешний ' + transport + '-порт VPN', default)
        if 'vless' in chosen:
            mode = self.ask('VLESS_MODE', 'Режим VLESS: reality / direct / mask', choices={'reality', 'direct', 'mask'})
            if mode == 'mask':
                self.ask('VLESS_DOMAIN', 'Домен VLESS для HTTPS-маскировки')
            if mode == 'reality':
                self.ask('REALITY_TARGET', 'Reality target', 'www.google.com:443')
                self.ask('REALITY_SERVER_NAME', 'Reality SNI', 'www.google.com')
        if 'hysteria2' in chosen:
            if not self.silent and not self.answers.get('HY_DOMAIN'):
                print('Домен нужен для TLS-сертификата во всех режимах Hysteria 2.')
                print('A-запись должна вести на IPv4 сервера; получение и продление сертификата используют TCP-порт 80.')
            self.ask('HY_DOMAIN', 'Домен Hysteria 2 (A-запись должна вести на сервер)')
            mode = self.hysteria_mode()
            if mode == 'none':
                self.answers.setdefault('HY_MASQUERADE_MODE', 'proxy')
                if self.answers['HY_MASQUERADE_MODE'] == 'local' and not self.answers.get('HY_MASQUERADE'):
                    self.answers['HY_MASQUERADE'] = normalize_url(self.answers['HY_DOMAIN'])
                self.ask_site_url()
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

    def hysteria_mode(self):
        mode = self.answers.get('HY_OBFS')
        if mode:
            if mode not in {'none', 'salamander', 'gecko'}:
                raise ValueError('HY_OBFS: none / salamander / gecko')
            return mode
        if not self.silent:
            print('Режим Hysteria:')
            print('1 — none — обычный HTTP/3 с сайтом-маскировкой.')
            print('2 — salamander — пакеты выглядят как случайные данные; нужен пароль обфускации.')
            print('3 — gecko — экспериментальный: Salamander с фрагментацией и дополнением пакетов рукопожатия.')
        choice = self.choose('hysteria_obfs', 'Выберите 1/2/3', {'1', '2', '3'})
        mode = {'1': 'none', '2': 'salamander', '3': 'gecko'}[choice]
        self.answers['HY_OBFS'] = mode
        self.state.save()
        return mode

    def ask_site_url(self):
        while True:
            value = self.answers.get('HY_MASQUERADE')
            if not value:
                if self.silent:
                    raise ValueError('Для --silent требуется [hysteria2] masquerade_url')
                value = input('Сайт-маскировка (домен или HTTPS-адрес): ').strip()
            try:
                url = normalize_url(value)
            except ValueError as error:
                if self.silent:
                    raise
                print(str(error))
                self.answers.pop('HY_MASQUERADE', None)
                self.state.save()
                continue
            self.answers['HY_MASQUERADE'] = url
            self.state.save()
            return url
