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

    def show(self, chat_id, user_id):
        data = self.command("list")
        token = secrets.token_hex(8)
        self.pending[(str(user_id), chat_id)] = {
            "token": token, "expires": time.monotonic() + 300,
            "addresses": data["addresses"], "phase": "choose",
        }
        self.state.set_context(user_id, chat_id, "admin_ip")
        current = {p["ip"] for p in data["protocols"]}
        active_ip = self.command("domain-status").get("active_ip") if self.queue is not None else None
        if active_ip:
            current = {active_ip}
        lines = ["<b>Смена IP VPN</b>", "", "Основные адреса VPN:"]
        lines += [f"{formatters.h(p['title'])}: <code>{formatters.h(p['ip'])}</code>" for p in data["protocols"]]
        if active_ip:
            lines += ["", "Активный IP: " + formatters.h(active_ip)]
        lines += ["", "Выберите публичный IPv4 внешнего интерфейса. Если используется домен, измените его A-запись у регистратора самостоятельно; выбранный IP будет использован для подключения и выхода в Интернет всех локальных VPN-протоколов. Остальные IP останутся в резерве с закрытыми VPN-портами."]
        self.telegram.send_message(chat_id, "\n".join(lines), keyboards.operation_navigation())
        rows = [[{
            "text": ("✓ " if current == {item["ip"]} else "") + item["ip"] + " · " + item["interface"],
            "callback_data": f"ipchoose:{token}:{index}",
        }] for index, item in enumerate(data["addresses"])]
        rows.append([{"text": "Обновить список", "callback_data": "ipsettings"}, {"text": "Отмена", "callback_data": "ipcancel"}])
        self.telegram.send_message(chat_id, "Доступные адреса:" if data["addresses"] else "Публичные IPv4 не найдены.", {"inline_keyboard": rows})

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
                f"<b>Переключить VPN на {formatters.h(address)}?</b>\n\n"
                "Если задан домен, он сохранится в профилях. Его A-запись нужно самостоятельно изменить у регистратора на этот IP. "
                "Старый IP перестанет принимать VPN-подключения. Профили с доменом требуют переподключения после обновления DNS-кеша; старые профили с IP нужно получить заново. Текущие соединения будут прерваны.",
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
            text = 'Смена IP на ' + address + ' поставлена в очередь. Задание №' + str(number) + '. Переключу VPN без проверки DNS. A-запись домена измените у регистратора самостоятельно. Результат пришлю отдельно.'
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
            "Подключение и выход в Интернет используют этот адрес. VPN на резервных IP закрыт. Получите профили заново.\n"
            + "Протоколы: " + formatters.h(", ".join(result["protocols"])),
            keyboards.settings_menu(),
        )
