"""Admin-only UI; the privileged endpoint transaction lives in vpn_ip_switch.py."""
import json
import secrets
import subprocess
import time
import threading
from pathlib import Path
from functools import partial

from app import formatters, keyboards


def switch_command(action, *args, registry=None):
    result = subprocess.run(
        ["/usr/bin/python3", "/usr/local/sbin/vpn_ip_switch.py", action, *args,
         "--registry", str(registry or Path(__file__).resolve().parents[1] / "servers.json")],
        capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=600,
    )
    try:
        data = json.loads(result.stdout)
    except ValueError:
        raise RuntimeError("Скрипт смены IP не вернул результат. Проверьте состояние сервера.") from None
    if result.returncode or not data.get("ok"):
        raise RuntimeError(data.get("error", "Не удалось сменить IP."))
    return data


class IpAdmin:
    def __init__(self, telegram, state, command=None, registry=None):
        self.telegram, self.state = telegram, state
        self.command = command or partial(switch_command, registry=registry)
        self.pending = {}
        self.queue = None
        self.consumed = set()
        self.lock = threading.RLock()

    def begin(self, chat_id, user_id):
        self.cancel(chat_id, user_id)
        self.state.set_context(user_id, chat_id, 'admin_ip_probe')
        self.telegram.send_message(chat_id,
            'Введите домен внешнего проверочного сервера, например check.example.org.\n\n'
            'На проверочном сервере должны быть запущены SSH на TCP 22 и HTTPS на TCP 443 '
            'с действительным сертификатом для этого домена. Порты должны быть открыты для всех проверяемых IP.\n'
            'Это отдельный проверочный сервер, а не домен VPN. Логин, пароль и API-ключи не нужны.',
            keyboards.operation_navigation())

    def input(self, chat_id, user_id, text):
        if self.state.context(user_id, chat_id).get('screen') != 'admin_ip_probe':
            raise ValueError('Откройте «Смена IP» заново')
        self.command('probe-set', text)
        self.show(chat_id, user_id)

    def show(self, chat_id, user_id):
        self.telegram.send_message(chat_id, 'Проверяю SSH и HTTPS с каждого IP…')
        data = self.command('list', '--probe')
        dns = self.command('domain-status')
        token = secrets.token_hex(8)
        self.pending[(str(user_id), chat_id)] = {
            'token': token, 'expires': time.monotonic() + 300,
            'addresses': data['addresses'], 'phase': 'choose',
        }
        self.state.set_context(user_id, chat_id, 'admin_ip')
        lines = ['<b>Смена исходящего IP VPN</b>', '',
                 'Выход VPN: <code>' + formatters.h(data.get('egress_ip') or 'ещё не выбран') + '</code>',
                 'VPN принимает подключения на всех публичных IPv4.',
                 'Служебный маршрут самого сервера не меняется.', '',
                 'Проверочный домен: <code>' + formatters.h(data['domain']) + '</code>',
                 'Проверяется один адрес: <code>' + formatters.h(data['destination_ip']) + '</code>',
                 'SSH :22 и HTTPS :443 проверяются отдельно. Это проверка доступности внешнего сервера, не проверка VPN.', '',
                 'Домен VPN: <code>' + formatters.h(dns.get('domain') or 'не задан') + '</code>',
                 'После смены IP просьба вручную изменить A-запись домена VPN на выбранный IP. Бот не имеет API для DNS.']
        reasons = {'timeout':'нет ответа','refused':'соединение отклонено','tls_error':'ошибка сертификата/TLS',
                   'invalid_response':'неверный ответ службы','network_error':'ошибка сети'}
        for item in data['addresses']:
            if not item.get('available'):
                detail = []
                for service in ['ssh','https']:
                    if not item.get(service): detail.append(service.upper()+': '+reasons.get(item.get(service+'_reason'),'нет ответа'))
                lines.append(formatters.h(item['ip']+' — '+', '.join(detail)))
        self.telegram.send_message(chat_id, '\n'.join(lines), keyboards.operation_navigation())
        rows = []
        for index, item in enumerate(data['addresses']):
            ssh, https = bool(item.get('ssh')), bool(item.get('https'))
            icon = '🟢' if ssh and https else ('🟡' if ssh or https else '🔴')
            text = f"{icon} {'✓ ' if item['ip']==data.get('egress_ip') else ''}{item['ip']} · SSH {'✓' if ssh else '✗'} HTTPS {'✓' if https else '✗'}"
            rows.append([{'text': text, 'callback_data': f'ipchoose:{token}:{index}'}])
        rows.append([{'text': 'Обновить проверку', 'callback_data': 'iprefresh'},
                     {'text': 'Другой проверочный домен', 'callback_data': 'ipsettings'}])
        rows.append([{'text':'Отмена','callback_data':'ipcancel'}])
        self.telegram.send_message(chat_id, 'Выберите исходящий IP:' if rows else 'Публичные IPv4 не найдены.', {'inline_keyboard':rows})

    def cancel(self, chat_id, user_id):
        self.pending.pop((str(user_id), chat_id), None)

    def handle(self, chat_id, user_id, data, message_id=None):
        with self.lock:
            return self._handle(chat_id, user_id, data, message_id)

    def _handle(self, chat_id, user_id, data, message_id=None):
        parts = data.split(":")
        key = (str(user_id), chat_id, parts[1] if len(parts) > 1 else "")
        if parts[0] == "ipapply" and key in self.consumed:
            return
        pending = self.pending.get((str(user_id), chat_id))
        if (not pending or len(parts) < 2 or parts[1] != pending["token"]
                or pending["expires"] < time.monotonic()
                or self.state.context(user_id, chat_id).get("screen") != "admin_ip"):
            raise ValueError("Выбор IP устарел. Откройте «Смена IP» заново.")
        if parts[0] == "ipchoose" and len(parts) == 3:
            if pending["phase"] != "choose" or not parts[2].isdigit():
                raise ValueError("Обновите список IP.")
            index = int(parts[2])
            if index >= len(pending["addresses"]):
                raise ValueError("Неизвестный адрес.")
            address = pending["addresses"][index]["ip"]
            if address not in {a["ip"] for a in self.command("list")["addresses"]}:
                raise ValueError("Адрес больше не назначен интерфейсу. Обновите список.")
            pending.update(phase="confirm", ip=address)
            self.telegram.send_message(
                chat_id,
                f"<b>Использовать {formatters.h(address)} для выхода VPN?</b>\n\n"
                'Все публичные IP продолжат принимать VPN. Изменится только исходящий IP VPN-трафика. '
                'Служебный маршрут сервера не меняется. Если задан домен, он сохранится в профилях. '
                'Просьба вручную изменить A-запись домена VPN на этот IP. '
                'При профилях с IP вместо домена получите их заново. Существующие VPN-соединения могут переподключиться.',
                {"inline_keyboard": [[
                    {"text": "Переключить", "callback_data": f"ipapply:{pending['token']}"},
                    {"text": "Отмена", "callback_data": "ipcancel"},
                ]]},
            )
            return
        if parts[0] != "ipapply" or len(parts) != 2 or pending["phase"] != "confirm":
            raise ValueError("Сначала выберите IP и подтвердите переключение.")
        address = pending["ip"]
        self.consumed.add(key)
        if len(self.consumed) > 512:
            self.consumed = {key}
        self.cancel(chat_id, user_id)  # Consume once; replays cannot start another transaction.
        if self.queue is not None:
            number = self.queue.enqueue('ip:' + str(user_id) + ':' + str(chat_id) + ':' + pending['token'],
                                        chat_id, '', address, kind='ip')
            text = 'Смена исходящего IP на ' + address + ' поставлена в очередь. Задание №' + str(number) + '. Результат пришлю отдельно. A-запись нужно изменить вручную.'
            if message_id is not None:
                try:
                    self.telegram.edit_message(chat_id, message_id, text, {'inline_keyboard': []})
                except Exception:
                    self.telegram.send_message(chat_id, text)
            else:
                self.telegram.send_message(chat_id, text)
            self.state.set_context(user_id, chat_id, 'admin_settings')
            self.telegram.send_message(chat_id, 'Настройки. Задание продолжает выполняться в очереди.', keyboards.settings_menu())
            return
        self.telegram.send_message(chat_id, f"Переключаю VPN на {formatters.h(address)}…")
        result = self.command("apply", address, "--actor", str(user_id))
        self.state.set_context(user_id, chat_id, "admin_settings")
        self.telegram.send_message(
            chat_id,
            f"<b>Основной IP VPN: {formatters.h(result['ip'])}</b>\n\n"
            'Все публичные IP принимают VPN. Выход VPN использует выбранный адрес. Просьба вручную изменить A-запись домена VPN на этот IP.\n'
            + "Протоколы: " + formatters.h(", ".join(result["protocols"])),
            keyboards.settings_menu(),
        )
