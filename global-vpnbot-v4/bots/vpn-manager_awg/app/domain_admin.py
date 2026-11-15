"""Global edition: admin-only domain settings; secrets are entered only on server."""
import re
import secrets
import time
import threading
from functools import partial
from app import formatters, keyboards
from app.ip_admin import switch_command


class DomainAdmin:
    def __init__(self, telegram, state, registry=None, command=None):
        self.telegram, self.state = telegram, state
        self.command = command or partial(switch_command, registry=registry)
        self.queue = None
        self.pending = {}
        self.consumed = {}
        self.lock = threading.RLock()

    def begin(self, chat_id, user_id):
        self.pending[(str(user_id), chat_id)] = {'token': secrets.token_hex(8), 'expires': time.monotonic() + 300, 'phase': 'edit'}
        self.state.set_context(user_id, chat_id, 'admin_domain_edit')
        self.telegram.send_message(chat_id, 'Введите новый домен. После его смены потребуется получить новые профили на каждом устройстве.', keyboards.operation_navigation())

    def show(self, chat_id, user_id):
        data = self.command('domain-status')
        token = secrets.token_hex(8)
        self.pending[(str(user_id), chat_id)] = {'token': token, 'expires': time.monotonic() + 300, 'phase': 'show'}
        self.state.set_context(user_id, chat_id, 'admin_domain')
        check = self.command('domain-check')
        addresses = ', '.join(check.get('a_records', [])) or 'не найдена'
        if check.get('matches'):
            notice = 'A-запись соответствует выбранному IP VPN.'
        elif not check.get('lookup_ok', True):
            notice = 'Не удалось проверить A-запись. Проверьте DNS у регистратора. ' + str(check.get('error', ''))
        else:
            notice = 'A-запись не соответствует выбранному IP сервера. Просьба изменить A-запись у регистратора на ' + str(data.get('active_ip') or 'выбранный IP сервера') + '.'
        self.telegram.send_message(chat_id,
            '<b>Глобал · Настройка домена</b>\n\nДомен: <code>' + formatters.h(data['domain'] or 'не задан') + '</code>\n'
            'IP VPN: ' + formatters.h(data.get('active_ip') or 'ещё не выбран') + '\n'
            'A-запись: ' + formatters.h(addresses) + '\n\n' + formatters.h(notice) + '\n'
            'Проверка через host справочная. Бот не меняет DNS; сохранение домена не зависит от результата проверки.',
            {'inline_keyboard': [[{'text': 'Сменить домен', 'callback_data': 'domainedit:' + token},
                                  {'text': 'Проверить A-запись', 'callback_data': 'domainsync:' + token}]]})

    def input(self, chat_id, user_id, text):
        pending = self.pending.get((str(user_id), chat_id))
        if not pending or pending['phase'] != 'edit' or pending['expires'] < time.monotonic():
            raise ValueError('Откройте настройки домена заново')
        name = text.strip().lower().rstrip('.').encode('idna').decode('ascii')
        if len(name) > 253 or len(name.split('.')) < 2 or any(not re.fullmatch(r'[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?', p) for p in name.split('.')):
            raise ValueError('Введите только DNS-имя, например vpn.example.org')
        pending.update(domain=name)
        self.state.set_context(user_id, chat_id, 'admin_domain')
        self.choose_address(chat_id, pending)

    def choose_address(self, chat_id, pending):
        addresses = self.command('list')['addresses']
        pending.update(phase='choose', addresses=addresses)
        rows = [[{'text': item['ip'], 'callback_data': f"domainip:{pending['token']}:{index}"}] for index, item in enumerate(addresses)]
        rows.append([{'text': 'Отмена', 'callback_data': 'ipcancel'}])
        self.telegram.send_message(chat_id, 'Выберите IP сервера для домена ' + formatters.h(pending['domain']) + ' :' if addresses else 'Публичные IPv4 не найдены.', {'inline_keyboard': rows})

    def confirm(self, chat_id, pending):
        warning = (
            '⚠️ <b>После смены домена необходимо заново настроить VPN на каждом устройстве.</b>\n'
            'Получите в боте новые профили или QR-коды и импортируйте их на всех телефонах, планшетах и компьютерах. '
            'Старые профили автоматически не обновятся.\n\n'
            if pending['domain'] != self.command('domain-status')['domain'] else ''
        )
        self.telegram.send_message(chat_id,
            warning +
            'Использовать домен <b>' + formatters.h(pending['domain']) + '</b> с IP VPN <b>' + formatters.h(pending['ip']) + '</b> в VPN-профилях? '
            'DNS не проверяется и не изменяется. Укажите выбранный IP в A-записи у регистратора самостоятельно.',
            {'inline_keyboard': [[{'text': 'Подтвердить', 'callback_data': 'domainapply:' + pending['token']},
                                  {'text': 'Отмена', 'callback_data': 'ipcancel'}]]})

    def handle(self, chat_id, user_id, data, message_id=None):
        with self.lock:
            return self._handle(chat_id, user_id, data, message_id)

    def _handle(self, chat_id, user_id, data, message_id=None):
        parts = data.split(':')
        key = (str(user_id), chat_id, parts[1] if len(parts) > 1 else '')
        with self.lock:
            if parts[0] == 'domainapply' and key in self.consumed:
                return  # A queued second click must not produce another operation or error.
        pending = self.pending.get((str(user_id), chat_id))
        if len(parts) not in (2, 3) or not pending or pending['token'] != parts[1] or pending['expires'] < time.monotonic() or self.state.context(user_id, chat_id).get('screen') not in {'admin_domain', 'admin_domain_edit'}:
            raise ValueError('Выбор домена устарел')
        if parts[0] == 'domainip' and len(parts) == 3 and pending['phase'] == 'choose':
            if not parts[2].isdigit() or int(parts[2]) >= len(pending['addresses']):
                raise ValueError('Неизвестный IP')
            address = pending['addresses'][int(parts[2])]['ip']
            if address not in {a['ip'] for a in self.command('list')['addresses']}:
                raise ValueError('IP больше не назначен серверу; откройте настройки заново')
            pending.update(phase='confirm', ip=address)
            self.confirm(chat_id, pending)
        elif len(parts) != 2:
            raise ValueError('Неверная кнопка')
        elif parts[0] == 'domainedit' and pending['phase'] == 'show':
            pending['phase'] = 'edit'
            self.state.set_context(user_id, chat_id, 'admin_domain_edit')
            self.telegram.send_message(chat_id, 'Введите домен, например vpn.example.org. Пароль не отправляйте.', keyboards.operation_navigation())
        elif parts[0] == 'domainsync' and pending['phase'] == 'show':
            self.show(chat_id, user_id)
        elif parts[0] == 'domainapply' and pending['phase'] == 'confirm':
            with self.lock:
                if key in self.consumed:
                    return
                self.consumed[key] = time.monotonic()
                if len(self.consumed) > 512:
                    self.consumed.pop(next(iter(self.consumed)))
                self.pending.pop((str(user_id), chat_id), None)
            progress = 'Запрос принят. Применяю настройки VPN… Повторно нажимать не нужно.'
            if message_id is not None:
                try:
                    self.telegram.edit_message(chat_id, message_id, progress, {'inline_keyboard': []})
                except Exception:
                    pass  # Telegram timeout must never make the consumed operation retryable.
            else:
                self.telegram.send_message(chat_id, progress)
            if self.queue is not None:
                number = self.queue.enqueue(str(user_id) + ':' + str(chat_id) + ':' + pending['token'],
                                            chat_id, pending['domain'], pending['ip'])
                self.state.set_context(user_id, chat_id, 'admin_settings')
                self.telegram.send_message(chat_id, 'Смена домена поставлена в очередь. Задание №' + str(number) +
                    '. Применю домен в VPN без проверки DNS. A-запись измените у регистратора самостоятельно. Результат пришлю отдельно.', keyboards.settings_menu())
                return
            result = self.command('domain-set', pending['domain'], '--address', pending['ip'])
            self.state.set_context(user_id, chat_id, 'admin_settings')
            self.telegram.send_message(chat_id, 'Домен сохранён: ' + formatters.h(result['domain']) + '\nIP: ' + formatters.h(result['ip']), keyboards.settings_menu())
        else:
            raise ValueError('Откройте настройки домена заново')
