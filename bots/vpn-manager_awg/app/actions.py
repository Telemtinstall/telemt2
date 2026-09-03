from __future__ import annotations

import re

from app import formatters, keyboards
from app.server_status import collect_status
from app.speedtest_status import run_speedtest
from app.traffic_chart import render_channel_chart, render_traffic_chart


class Actions:
    def __init__(
        self,
        settings,
        telegram,
        servers,
        state,
        traffic_store=None,
        access_store=None,
        channel_store=None,
    ):
        self.settings = settings
        self.telegram = telegram
        self.servers = servers
        self.state = state
        self.traffic_store = traffic_store
        self.access_store = access_store
        self.channel_store = channel_store

    def protocol_enabled(self, server_id: str) -> bool:
        return not self.access_store or self.access_store.protocol_enabled(server_id)

    def enabled_servers(self) -> list:
        return [server for server in self.servers.servers if self.protocol_enabled(server.id)]

    def require_protocol_enabled(self, server_id: str) -> None:
        if not self.protocol_enabled(server_id):
            raise RuntimeError("этот VPN-протокол временно отключён администратором")

    def show_menu(self, chat_id: int, message_id: int | None = None) -> None:
        admin_ids = set(self.settings.allowed_users)
        if self.access_store:
            admin_ids.update(item["telegram_user_id"] for item in self.access_store.list_admins())
        text = formatters.menu_text(
            self.settings.bot_title,
            admin_ids,
            self.menu_stats(),
        )
        markup = keyboards.main_menu(self.enabled_servers())
        self.telegram.send_message(chat_id, text, markup)

    def show_protocol_menu(
        self,
        chat_id: int,
        server_id: str,
        message_id: int | None = None,
    ) -> None:
        self.require_protocol_enabled(server_id)
        server = self.servers.get(server_id)
        text = (
            f"<b>{formatters.h(server.title)}</b>\n\n"
            "Выберите действие:"
        )
        markup = keyboards.protocol_menu(server)
        self.telegram.send_message(chat_id, text, markup)

    def show_protocol_picker(self, chat_id: int, action: str) -> None:
        labels = {
            "create": "создания пользователя",
            "list": "просмотра списка пользователей",
        }
        purpose = labels.get(action, "продолжения")
        self.telegram.send_message(
            chat_id,
            f"<b>Выберите протокол</b>\n\nПротокол для {purpose}:",
            keyboards.protocol_picker(self.enabled_servers()),
        )

    def show_admin_menu(self, chat_id: int) -> None:
        self.telegram.send_message(
            chat_id,
            "<b>Администрирование</b>\n\nВыберите действие:",
            keyboards.admin_menu(),
        )

    def show_admin_traffic_menu(self, chat_id: int) -> None:
        self.telegram.send_message(
            chat_id,
            "<b>Трафик и сеть</b>\n\n"
            "Графики и CSV отправляются при входе через кнопку «Трафик». "
            "Выберите действие:",
            keyboards.traffic_admin_menu(),
        )

    def show_settings_menu(self, chat_id: int) -> None:
        self.telegram.send_message(
            chat_id,
            "<b>Настройки</b>\n\nВыберите раздел:",
            keyboards.settings_menu(),
        )

    def show_protocol_settings(self, chat_id: int) -> None:
        lines = ["<b>Протоколы</b>", "", "🟢 включён · 🔴 отключён", "Нажмите протокол для изменения состояния."]
        self.telegram.send_message(
            chat_id,
            "\n".join(lines),
            keyboards.protocols_menu(self.servers.servers, self.protocol_enabled),
        )

    def ask_protocol_toggle(self, chat_id: int, server_id: str) -> None:
        server = self.servers.get(server_id)
        currently_enabled = self.protocol_enabled(server_id)
        target = not currently_enabled
        action = "включить" if target else "отключить"
        note = (
            "После включения все ранее выданные профили снова заработают."
            if target
            else "Новые и текущие VPN-соединения перестанут работать. Пользователи и конфиги сохранятся."
        )
        self.telegram.send_message(
            chat_id,
            f"<b>{action.capitalize()} {formatters.h(server.title)}?</b>\n\n{note}",
            keyboards.protocol_toggle_confirm(server_id, target),
        )

    def toggle_protocol(self, chat_id: int, server_id: str, enabled: bool, changed_by: str) -> None:
        if not self.access_store:
            raise RuntimeError("хранилище настроек не настроено")
        server = self.servers.get(server_id)
        previous = self.protocol_enabled(server_id)
        try:
            server.set_enabled(enabled)
            self.access_store.set_protocol_enabled(server_id, enabled, changed_by)
        except Exception:
            try:
                server.set_enabled(previous)
            except Exception:
                pass
            raise
        status = "включён" if enabled else "отключён"
        self.telegram.send_message(
            chat_id,
            f"<b>{formatters.h(server.title)}</b> {status}.\n"
            + ("Ранее выданные профили снова работают." if enabled else "Конфиги и пользователи сохранены."),
        )
        self.show_protocol_settings(chat_id)

    def show_administrators_menu(self, chat_id: int) -> None:
        self.telegram.send_message(
            chat_id,
            "<b>Администраторы</b>\n\nАдминистраторы из .env защищены от удаления.",
            keyboards.administrators_menu(),
        )

    def prompt_add_admin(self, chat_id: int) -> None:
        self.telegram.send_message(
            chat_id,
            "<b>Добавление администратора</b>\n\n"
            "Введите числовой Telegram ID или перешлите сообщение нужного пользователя.\n"
            "Если Telegram скрыл автора пересылки, потребуется ввести ID вручную.",
            keyboards.admin_add_navigation(),
        )

    def show_admin_candidate(self, chat_id: int, candidate: dict) -> None:
        details = formatters.telegram_person({
            "telegram_user_id": candidate.get("id"),
            "telegram_username": candidate.get("username"),
            "telegram_first_name": candidate.get("first_name"),
            "telegram_last_name": candidate.get("last_name"),
        })
        self.telegram.send_message(
            chat_id,
            "<b>Добавить администратора?</b>\n\n"
            f"Пользователь: {details}\n"
            f"Telegram ID: <code>{formatters.h(candidate.get('id'))}</code>",
            keyboards.admin_add_confirm(str(candidate.get("id"))),
        )

    def add_admin(self, chat_id: int, candidate: dict, added_by: str) -> None:
        if not self.access_store:
            raise RuntimeError("хранилище настроек не настроено")
        if str(candidate.get("id")) in self.settings.allowed_users:
            raise ValueError("этот пользователь уже является администратором из .env")
        admin = self.access_store.add_admin(candidate, added_by)
        self.telegram.set_admin_commands(admin["telegram_user_id"])
        self.telegram.send_message(
            chat_id,
            f"Администратор <code>{formatters.h(admin['telegram_user_id'])}</code> добавлен.",
        )
        self.show_administrators_menu(chat_id)

    def all_admins(self) -> list[dict]:
        protected = [
            {"telegram_user_id": user_id, "source": "env"}
            for user_id in sorted(self.settings.allowed_users, key=int)
        ]
        dynamic = self.access_store.list_admins() if self.access_store else []
        return protected + [{**item, "source": "sqlite"} for item in dynamic]

    def show_admin_list(self, chat_id: int) -> None:
        admins = self.all_admins()
        lines = ["<b>Администраторы</b>", ""]
        for admin in admins:
            marker = "🔒" if admin["source"] == "env" else "👤"
            username = admin.get("telegram_username")
            suffix = f" · @{formatters.h(username)}" if username else ""
            lines.append(f"{marker} <code>{formatters.h(admin['telegram_user_id'])}</code>{suffix}")
        self.telegram.send_message(chat_id, "\n".join(lines), keyboards.administrators_menu())

    def show_admin_delete_list(self, chat_id: int) -> None:
        admins = self.access_store.list_admins() if self.access_store else []
        if not admins:
            self.telegram.send_message(
                chat_id,
                "Удаляемых администраторов нет. Администраторы из .env защищены.",
                keyboards.administrators_menu(),
            )
            return
        self.telegram.send_message(
            chat_id,
            "<b>Удалить администратора</b>\n\nВыберите пользователя:",
            keyboards.admin_delete_list(admins),
        )

    def ask_delete_admin(self, chat_id: int, telegram_user_id: str) -> None:
        if telegram_user_id in self.settings.allowed_users:
            raise ValueError("администратора из .env удалить через бот нельзя")
        self.telegram.send_message(
            chat_id,
            f"Удалить администратора <code>{formatters.h(telegram_user_id)}</code>?",
            keyboards.admin_delete_confirm(telegram_user_id),
        )

    def delete_admin(self, chat_id: int, telegram_user_id: str, current_user_id: str) -> None:
        if telegram_user_id in self.settings.allowed_users:
            raise ValueError("администратора из .env удалить через бот нельзя")
        if str(telegram_user_id) == str(current_user_id):
            raise ValueError("нельзя удалить самого себя; попросите другого администратора")
        if not self.access_store or not self.access_store.remove_admin(telegram_user_id):
            raise ValueError("администратор уже удалён или не найден")
        self.telegram.set_user_commands(telegram_user_id)
        self.telegram.send_message(chat_id, f"Администратор <code>{formatters.h(telegram_user_id)}</code> удалён.")
        self.show_administrators_menu(chat_id)

    def show_server_status(self, chat_id: int) -> None:
        data = collect_status(self.settings.server_status_command)
        text = formatters.server_status_text(data, self.settings.server_channel_mbit)
        self.telegram.send_message(chat_id, text, keyboards.section_navigation())

    def show_speedtest(self, chat_id: int) -> None:
        self.telegram.send_message(
            chat_id,
            "<b>🚀 Замер скорости запущен</b>\n\n"
            "Тест временно загрузит канал и обычно занимает 20–60 секунд.",
            keyboards.section_navigation(),
        )
        try:
            data = run_speedtest(
                self.settings.speedtest_command,
                self.settings.speedtest_timeout,
            )
            text = formatters.speedtest_text(data, self.settings.server_channel_mbit)
        except Exception as exc:
            text = f"<b>Ошибка замера скорости</b>\n\n<code>{formatters.h(exc)}</code>"
        self.telegram.send_message(chat_id, text, keyboards.section_navigation())

    def show_channel_load(self, chat_id: int, period: str = "24") -> None:
        if not self.channel_store:
            raise RuntimeError("хранилище загрузки канала не настроено")
        periods = {
            "1": (1, "1 час"),
            "24": (24, "24 часа"),
            "168": (168, "7 дней"),
            "720": (720, "30 дней"),
        }
        hours, title = periods.get(str(period), periods["24"])
        points = self.channel_store.samples(hours)
        summary = self.channel_store.summary(points)
        image = render_channel_chart(points, title, self.settings.server_channel_mbit)
        self.telegram.send_photo(
            chat_id,
            f"channel_load_{hours}h.png",
            image,
            f"Загрузка канала VDS · {title} · UTC",
        )
        self.telegram.send_message(
            chat_id,
            formatters.channel_summary_text(
                summary,
                title,
                self.settings.server_channel_mbit,
            ),
            keyboards.channel_period_menu(),
        )

    def menu_stats(self) -> dict | None:
        servers = []
        for server in self.enabled_servers():
            try:
                traffic = server.traffic()
                servers.append(self.server_menu_stats(server, traffic))
            except Exception:
                continue
        if not servers:
            return None
        return {"servers": servers}

    def server_menu_stats(self, server, traffic: dict) -> dict:
        if server.is_amneziawg:
            peers = traffic.get("peers") or []
            total_bytes = sum(
                int(peer.get("rx_bytes") or 0) + int(peer.get("tx_bytes") or 0)
                for peer in peers
            )
            users = len(peers)
        elif server.is_vless:
            clients = traffic.get("clients") or []
            total_bytes = sum(int(client.get("total_bytes") or 0) for client in clients)
            users = len(clients)
        else:
            total_bytes = 0
            users = 0
        return {
            "server_id": server.id,
            "server_title": server.title,
            "users": users,
            "bytes": total_bytes,
            "traffic": formatters.human_bytes(total_bytes),
        }

    def prompt_create(self, chat_id: int, user_id: str, server_id: str, message_id: int | None = None) -> None:
        self.require_protocol_enabled(server_id)
        server = self.servers.get(server_id)
        self.state.set_pending_create(user_id, chat_id, server_id)
        text = formatters.create_prompt_text_for_server(server.title)
        self.telegram.send_message(chat_id, text, keyboards.create_navigation())

    def show_list(self, chat_id: int, server_id: str, message_id: int | None = None) -> None:
        self.require_protocol_enabled(server_id)
        server = self.servers.get(server_id)
        clients = server.list_clients()
        if clients:
            clients = self.apply_list_statuses(server, clients)
            note = formatters.list_status_note(server, self.settings.vless_online_interval_seconds)
            summary = formatters.list_status_summary(server, clients)
            text = (
                f"<b>Клиенты</b>\n"
                f"Сервер: <b>{formatters.h(server.title)}</b>\n\n"
                f"{summary}\n"
                f"{formatters.h(note)}\n\n"
                "Нажмите на клиента, чтобы открыть операции."
            )
            markup = keyboards.client_list(server.id, clients)
        else:
            text = f"<b>{formatters.h(server.title)}</b>\n\nКлиентов пока нет."
            markup = {"inline_keyboard": []}

        self.telegram.send_message(
            chat_id,
            f"<b>{formatters.h(server.title)}</b> · список пользователей",
            keyboards.section_navigation(),
        )
        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def apply_list_statuses(self, server, clients: list[dict]) -> list[dict]:
        if server.is_vless:
            data = server.online(self.settings.vless_online_interval_seconds)
        else:
            data = server.traffic()
        return formatters.apply_list_statuses(
            server,
            clients,
            data,
            self.settings.online_window_seconds,
        )

    def show_client(self, chat_id: int, server_id: str, ref: str, message_id: int | None = None) -> None:
        server = self.servers.get(server_id)
        client = server.show(ref)
        actual_ref = str(client.get("name") or ref)
        access_status = (
            self.access_store.profile_status(server.id, actual_ref)
            if self.access_store
            else {"state": "none"}
        )
        text = formatters.client_text(server, client, access_status)
        markup = keyboards.client_actions(server.id, server.protocol, actual_ref, access_status)
        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def show_user_menu(self, chat_id: int, telegram_user_id: str) -> None:
        if not self.access_store:
            raise RuntimeError("хранилище доступа не настроено")
        grants = [
            grant
            for grant in self.access_store.grants_for_user(telegram_user_id)
            if self.protocol_enabled(grant["server_id"])
        ]
        if not grants:
            self.telegram.send_message(
                chat_id,
                "Доступные VPN-профили отсутствуют. Возможно, протокол временно отключён.",
            )
            return
        self.telegram.send_message(
            chat_id,
            "<b>Мои VPN</b>\n\nВыберите свой профиль:",
            keyboards.user_profiles(grants, self.servers),
        )

    def show_user_client(
        self,
        chat_id: int,
        telegram_user_id: str,
        server_id: str,
        ref: str,
        message_id: int | None = None,
    ) -> None:
        self.require_protocol_enabled(server_id)
        if not self.access_store or not self.access_store.owns(telegram_user_id, server_id, ref):
            raise PermissionError("нет доступа к этому VPN-профилю")
        server = self.servers.get(server_id)
        client = server.show(ref)
        actual_ref = str(client.get("name") or ref)
        if not self.access_store.owns(telegram_user_id, server_id, actual_ref):
            raise PermissionError("нет доступа к этому VPN-профилю")
        text = formatters.user_client_text(server, client)
        markup = keyboards.user_client_actions(server.id, server.protocol, actual_ref)
        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def create_access_invite(
        self,
        chat_id: int,
        admin_user_id: str,
        server_id: str,
        ref: str,
        transfer: bool = False,
    ) -> str:
        if not self.access_store:
            raise RuntimeError("хранилище доступа не настроено")
        server = self.servers.get(server_id)
        client = server.show(ref)
        name = str(client.get("name") or ref)
        invite = self.access_store.create_invite(
            server.id,
            server.protocol,
            name,
            admin_user_id,
            transfer=transfer,
        )
        username = self.telegram.get_bot_username()
        link = f"https://t.me/{username}?start=claim_{invite['token']}"
        action = "Передача доступа" if transfer else "Доступ к боту"
        self.telegram.send_message(
            chat_id,
            f"<b>{action}: {formatters.h(server.title)} · {formatters.h(name)}</b>\n\n"
            f"Одноразовая ссылка действует до "
            f"<code>{formatters.h(invite['expires_at'])} UTC</code>:\n\n{link}\n\n"
            "После первого успешного запуска ссылка станет недействительной.",
        )
        return name

    def ask_revoke_access(self, chat_id: int, server_id: str, ref: str, message_id: int) -> None:
        server = self.servers.get(server_id)
        client = server.show(ref)
        name = str(client.get("name") or ref)
        self.telegram.edit_message(
            chat_id,
            message_id,
            f"Отозвать доступ к <b>{formatters.h(server.title)} · {formatters.h(name)}</b>?",
            keyboards.access_revoke_confirm(server.id, name),
        )

    def revoke_access(self, chat_id: int, server_id: str, ref: str, message_id: int) -> None:
        if not self.access_store:
            raise RuntimeError("хранилище доступа не настроено")
        server = self.servers.get(server_id)
        client = server.show(ref)
        name = str(client.get("name") or ref)
        self.access_store.revoke(server.id, name)
        self.telegram.edit_message(
            chat_id,
            message_id,
            f"Доступ к <b>{formatters.h(server.title)} · {formatters.h(name)}</b> отозван.",
            {"inline_keyboard": []},
        )
        self.show_client(chat_id, server.id, name)

    def ask_transfer_access(self, chat_id: int, server_id: str, ref: str, message_id: int) -> None:
        server = self.servers.get(server_id)
        client = server.show(ref)
        name = str(client.get("name") or ref)
        self.telegram.edit_message(
            chat_id,
            message_id,
            f"Передать доступ к <b>{formatters.h(server.title)} · {formatters.h(name)}</b> "
            "другому человеку? Текущий доступ будет немедленно отозван.",
            keyboards.access_transfer_confirm(server.id, name),
        )

    def create_client(self, chat_id: int, server_id: str, name: str | None = None) -> str:
        self.require_protocol_enabled(server_id)
        server = self.servers.get(server_id)
        data = server.add(name)
        client_name = data["name"]
        if self.traffic_store:
            self.traffic_store.ensure_user(server.id, server.protocol, client_name)
        caption = formatters.created_caption_for_server(server, data)

        if server.is_amneziawg:
            self.telegram.send_message(
                chat_id,
                f"{caption}\n\nВыберите QR под свое устройство: iPhone или Android.",
                keyboards.section_navigation(),
            )
            self.telegram.send_message(
                chat_id,
                "Действия пользователя:",
                keyboards.client_actions(server.id, server.protocol, client_name),
            )
            return client_name
        else:
            self.send_qr_images(chat_id, server, client_name, data, caption)
            if server.is_vless and data.get("link"):
                self.telegram.send_message(chat_id, formatters.vless_link_text(server, data))
        self.telegram.send_message(
            chat_id,
            "Клиент готов. Что сделать дальше?",
            keyboards.section_navigation(),
        )
        self.telegram.send_message(
            chat_id,
            "Действия пользователя:",
            keyboards.client_actions(server.id, server.protocol, client_name),
        )
        return client_name

    def send_qr_for_client(self, chat_id: int, server_id: str, ref: str, platform: str | None = None) -> None:
        self.require_protocol_enabled(server_id)
        server = self.servers.get(server_id)
        data = server.qr(ref)
        name = data["name"]
        qr_server_title = self.qr_server_title(server, data)
        caption = f"QR-код\nСервер: <b>{formatters.h(qr_server_title)}</b>"
        if platform:
            footer = None
            if server.is_amneziawg:
                footer = f"Пользователь: <b>{formatters.h(name)}</b>"
            self.send_qr_image_for_platform(
                chat_id,
                server,
                name,
                data,
                caption,
                platform,
                footer,
            )
        else:
            self.send_qr_images(chat_id, server, name, data, caption)

    @staticmethod
    def qr_server_title(server, data: dict) -> str:
        title = str(server.title)
        if not server.is_amneziawg:
            return title

        config = str(data.get("config") or "")
        match = re.search(
            r"(?m)^Endpoint\s*=\s*(\[[^\]]+\]|[^:\s]+):\d+\s*$",
            config,
        )
        if not match:
            return title

        endpoint_host = match.group(1).strip("[]")
        if endpoint_host in title:
            return title
        first, separator, remainder = title.partition(" ")
        if separator:
            return f"{first} {endpoint_host} {remainder}"
        return f"{title} {endpoint_host}"

    def send_qr_image_for_platform(
        self,
        chat_id: int,
        server,
        name: str,
        data: dict,
        caption: str,
        platform: str,
        footer: str | None = None,
    ) -> None:
        for item in self.qr_items_for_server(server, data):
            if item.get("suffix") == platform:
                image_name = f"{name}-{item['suffix']}"
                image_caption = caption
                if item.get("note"):
                    image_caption = f"{image_caption}\n{item['note']}"
                if footer:
                    image_caption = f"{image_caption}\n\n{footer}"
                self.telegram.send_qr(chat_id, image_name, item["base64"], image_caption)
                return
        raise RuntimeError(f"QR для {platform} не найден в ответе сервера")

    def send_qr_images(self, chat_id: int, server, name: str, data: dict, caption: str) -> None:
        if server.is_amneziawg:
            raise RuntimeError("Выберите отдельную кнопку: QR для iPhone или QR для Android.")
        qr_items = self.qr_items_for_server(server, data)
        for item in qr_items:
            image_name = f"{name}-{item['suffix']}" if item.get("suffix") else name
            image_caption = caption
            if item.get("note"):
                image_caption = f"{image_caption}\n{item['note']}"
            qr_base64 = item["base64"]
            self.telegram.send_qr(chat_id, image_name, qr_base64, image_caption)

    def qr_items_for_server(self, server, data: dict) -> list[dict]:
        if server.is_amneziawg:
            result = []
            config_qr = str(
                data.get("ios_qr_png_base64") or data.get("qr_png_base64") or ""
            )
            if config_qr:
                result.append(
                    {
                        "suffix": "iphone",
                        "base64": config_qr,
                        "note": "iPhone: QR .conf для приложения AmneziaWG.",
                    }
                )
                result.append(
                    {
                        "suffix": "android",
                        "base64": config_qr,
                        "note": "Android: QR .conf для приложения AmneziaWG.",
                    }
                )

            vpn_qr = str(data.get("android_qr_png_base64") or "")
            if not vpn_qr:
                vpn_items = [
                    str(item)
                    for item in (data.get("vpn_qr_png_base64_items") or [])
                    if item
                ]
                if len(vpn_items) > 1:
                    raise RuntimeError(
                        "QR AmneziaVPN слишком большой: сервер вернул несколько частей."
                    )
                vpn_qr = vpn_items[0] if vpn_items else ""
            if vpn_qr:
                result.append(
                    {
                        "suffix": "vpn",
                        "base64": vpn_qr,
                        "note": "Native QR для полного приложения AmneziaVPN.",
                    }
                )

            if result:
                return result

        fallback = data.get("qr_png_base64")
        if fallback:
            return [{"suffix": "", "base64": str(fallback), "note": None}]
        raise RuntimeError("QR-картинка не найдена в ответе сервера")

    def send_config_file_for_client(self, chat_id: int, server_id: str, ref: str) -> None:
        server = self.servers.get(server_id)
        if not server.is_amneziawg:
            self.telegram.send_message(chat_id, "Файл .conf доступен только для AmneziaWG.")
            return
        data = server.show(ref)
        self.telegram.send_config_file(chat_id, data["name"], data["config"])

    def send_vpn_key_for_client(self, chat_id: int, server_id: str, ref: str) -> None:
        server = self.servers.get(server_id)
        if not server.is_amneziawg:
            self.telegram.send_message(chat_id, "VPN-ключ доступен только для AmneziaWG.")
            return
        data = server.vpn_key(ref)
        vpn_key = str(data.get("vpn_key") or "").strip()
        if not vpn_key.startswith("vpn://"):
            raise RuntimeError("awgctl не вернул корректный VPN-ключ")
        self.telegram.send_message(
            chat_id,
            formatters.vpn_key_text(server, data, vpn_key),
        )

    def send_router_config_for_client(self, chat_id: int, server_id: str, ref: str) -> None:
        server = self.servers.get(server_id)
        if not server.is_amneziawg:
            self.telegram.send_message(chat_id, "Текст .conf для роутера доступен только для AmneziaWG.")
            return
        data = server.show(ref)
        self.send_router_config(chat_id, data["name"], data["config"])

    def send_vless_link_for_client(self, chat_id: int, server_id: str, ref: str) -> None:
        server = self.servers.get(server_id)
        if not server.is_vless:
            self.telegram.send_message(chat_id, "VLESS-ссылка доступна только для VLESS-сервера.")
            return
        data = server.show(ref)
        self.telegram.send_message(chat_id, formatters.vless_link_text(server, data))

    def send_router_config(self, chat_id: int, name: str, config: str) -> None:
        text = formatters.router_config_text(name, config)
        if len(text) > self.settings.max_message:
            self.telegram.send_message(
                chat_id,
                f"Конфиг <b>{formatters.h(name)}</b> слишком большой для сообщения. Используйте кнопку <b>Прислать .conf</b>.",
            )
            return
        self.telegram.send_message(chat_id, text)

    def show_traffic(self, chat_id: int, server_id: str, message_id: int | None = None) -> None:
        server = self.servers.get(server_id)
        data = server.traffic()
        if self.traffic_store:
            rows = self.traffic_store.current_month_rows(server, data)
            text = formatters.monthly_traffic_text(server, rows, self.traffic_store.now())
        else:
            text = formatters.server_traffic_text(server, data)
        self.telegram.send_message(chat_id, text, keyboards.section_navigation(download=True))

    def send_traffic_reports(self, chat_id: int, server_id: str) -> None:
        if not self.traffic_store:
            raise RuntimeError("хранилище трафика не настроено")
        server = self.servers.get(server_id)
        data = server.traffic() if self.protocol_enabled(server_id) else {}
        daily_chart, monthly_chart = self.traffic_store.chart_series(server, data=data)
        self.send_traffic_charts(chat_id, server, daily_chart, monthly_chart)
        daily, monthly = self.traffic_store.report_files(server, data)
        self.telegram.send_document(
            chat_id,
            f"traffic_{server.id}_daily.csv",
            daily,
            f"{server.title}: трафик по дням",
            "text/csv",
        )
        self.telegram.send_document(
            chat_id,
            f"traffic_{server.id}_monthly.csv",
            monthly,
            f"{server.title}: трафик по месяцам",
            "text/csv",
        )

    def send_all_traffic_reports(self, chat_id: int) -> None:
        if not self.traffic_store:
            raise RuntimeError("хранилище трафика не настроено")
        for server in self.servers.servers:
            self.send_traffic_reports(chat_id, server.id)

    def send_client_traffic_reports(self, chat_id: int, server_id: str, ref: str) -> None:
        if not self.traffic_store:
            raise RuntimeError("хранилище трафика не настроено")
        server = self.servers.get(server_id)
        client = server.show(ref)
        name = str(client.get("name") or ref)
        data = server.traffic()
        daily_chart, monthly_chart = self.traffic_store.chart_series(
            server,
            user_name=name,
            data=data,
        )
        self.send_traffic_charts(chat_id, server, daily_chart, monthly_chart, name)
        daily, monthly = self.traffic_store.user_report_files(server, name, data)
        self.telegram.send_document(
            chat_id,
            f"traffic_{server.id}_{name}_daily.csv",
            daily,
            f"{server.title} · {name}: трафик по дням",
            "text/csv",
        )
        self.telegram.send_document(
            chat_id,
            f"traffic_{server.id}_{name}_monthly.csv",
            monthly,
            f"{server.title} · {name}: трафик по месяцам",
            "text/csv",
        )

    def send_traffic_charts(
        self,
        chat_id: int,
        server,
        daily: list[dict],
        monthly: list[dict],
        user_name: str | None = None,
    ) -> None:
        subject = user_name or "все пользователи"
        title = f"{server.title} · {subject}"
        daily_png = render_traffic_chart(
            title,
            "Трафик по дням за текущий месяц",
            daily,
            "МБ",
        )
        monthly_png = render_traffic_chart(
            title,
            "Трафик по месяцам за последние 12 месяцев",
            monthly,
            "ГБ",
        )
        safe_subject = user_name or "all"
        self.telegram.send_photo(
            chat_id,
            f"traffic_{server.id}_{safe_subject}_daily.png",
            daily_png,
            f"{server.title} · {subject}: график по дням (МБ)",
        )
        self.telegram.send_photo(
            chat_id,
            f"traffic_{server.id}_{safe_subject}_monthly.png",
            monthly_png,
            f"{server.title} · {subject}: график по месяцам (ГБ)",
        )

    def show_online(self, chat_id: int, server_id: str, message_id: int | None = None) -> None:
        server = self.servers.get(server_id)
        if server.is_vless:
            data = server.online(self.settings.vless_online_interval_seconds)
        else:
            data = server.traffic()
        text = formatters.server_online_text(server, data, self.settings.online_window_seconds)
        self.telegram.send_message(chat_id, text, keyboards.section_navigation())

    def show_all_online(self, chat_id: int) -> None:
        blocks = ["<b>Кто онлайн · все протоколы</b>"]
        for server in self.servers.servers:
            if not self.protocol_enabled(server.id):
                blocks.append(f"<b>{formatters.h(server.title)}</b>\n\n🔴 Протокол отключён")
                continue
            try:
                if server.is_vless:
                    data = server.online(self.settings.vless_online_interval_seconds)
                else:
                    data = server.traffic()
                blocks.append(
                    formatters.server_online_text(
                        server,
                        data,
                        self.settings.online_window_seconds,
                    )
                )
            except Exception as exc:
                blocks.append(
                    f"<b>{formatters.h(server.title)}</b>\n\n"
                    f"⚠️ Не удалось получить онлайн: <code>{formatters.h(exc)}</code>"
                )
        self.telegram.send_message(
            chat_id,
            "\n\n────────\n\n".join(blocks),
            keyboards.section_navigation(),
        )

    def show_client_traffic(self, chat_id: int, server_id: str, ref: str, message_id: int | None = None) -> None:
        server = self.servers.get(server_id)
        client = server.show(ref)
        traffic = server.traffic()
        text = formatters.server_client_traffic_text(server, client, traffic)
        actual_ref = str(client.get("name") or ref)
        if message_id:
            self.telegram.send_message(
                chat_id,
                f"<b>{formatters.h(server.title)}</b> · {formatters.h(actual_ref)} · отчёты",
                keyboards.client_traffic_navigation(),
            )
            self.telegram.edit_message(chat_id, message_id, text, {"inline_keyboard": []})
        else:
            self.telegram.send_message(chat_id, text, keyboards.client_traffic_navigation())

    def ask_delete(self, chat_id: int, server_id: str, ref: str, message_id: int) -> None:
        server = self.servers.get(server_id)
        client = server.show(ref)
        actual_ref = str(client.get("name") or ref)
        text = (
            f"Удалить клиента <b>{formatters.h(client.get('name'))}</b> "
            f"на сервере <b>{formatters.h(server.title)}</b>?"
        )
        self.telegram.edit_message(chat_id, message_id, text, keyboards.delete_confirm(server.id, actual_ref))

    def delete_client(self, chat_id: int, server_id: str, ref: str, message_id: int) -> None:
        server = self.servers.get(server_id)
        deleted = server.delete(ref)
        deleted_name = str(deleted.get("name") or ref)
        if self.traffic_store:
            self.traffic_store.delete_user(server.id, deleted_name)
        if self.access_store:
            self.access_store.purge_profile(server.id, deleted_name)
        text = (
            f"Удален <b>{formatters.h(deleted_name)}</b> "
            f"на сервере <b>{formatters.h(server.title)}</b>.\n"
            "База трафика, доступ к боту и ожидающие приглашения также удалены."
        )
        self.telegram.edit_message(chat_id, message_id, text, {"inline_keyboard": []})
        self.show_list(chat_id, server_id)
