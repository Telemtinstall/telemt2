import logging

from app import auth, formatters, keyboards


log = logging.getLogger("vpnbot.handlers")


class Handlers:
    def __init__(self, settings, telegram, actions, state, access_store=None):
        self.settings = settings
        self.telegram = telegram
        self.actions = actions
        self.state = state
        self.access_store = access_store

    def handle_update(self, update: dict) -> None:
        if "message" in update:
            self.handle_message(update["message"])
        elif "callback_query" in update:
            self.handle_callback(update["callback_query"])

    def handle_message(self, message: dict) -> None:
        chat_id = message.get("chat", {}).get("id")
        if not chat_id:
            return
        if self.settings.private_only and not auth.is_private_chat(message):
            self.telegram.send_message(
                chat_id,
                "Откройте бота в личном чате, чтобы не показывать VPN-ключи в группе.",
            )
            return

        user_id = auth.user_id_from_update(message)
        text = (message.get("text") or "").strip()
        command = text.split()[0].split("@", 1)[0].lower() if text else ""

        if command == "/start" and len(text.split(maxsplit=1)) == 2:
            payload = text.split(maxsplit=1)[1].strip()
            if payload.startswith("claim_"):
                self.claim_access(message, chat_id, user_id, payload[6:])
                return

        is_admin = auth.is_admin_id(self.settings, user_id, self.access_store)
        has_user_access = bool(self.access_store and self.access_store.has_access(user_id))
        if not is_admin and not has_user_access:
            self.telegram.send_message(chat_id, "Доступ к боту не выдан.")
            return
        if not is_admin:
            if not text:
                return
            self.handle_user_message(chat_id, user_id, command, text)
            return

        try:
            context = self.state.context(user_id, chat_id)
            if context.get("screen") == "admin_add" and text not in {
                keyboards.BACK,
                keyboards.MAIN_MENU,
            }:
                self.accept_admin_candidate(message, chat_id, user_id, text)
                return
            if not text:
                return
            if command in {"/start", "/help", "/menu"} or text == keyboards.MAIN_MENU:
                self.show_main(chat_id, user_id)
                return

            server = self.server_for_reply(text)
            if server:
                pending_action = context.get("ref") if context.get("screen") == "choose_protocol" else None
                if pending_action == "create":
                    self.show_create_method(chat_id, user_id, server.id)
                elif pending_action == "list":
                    self.open_list(chat_id, user_id, server.id)
                else:
                    self.show_protocol(chat_id, user_id, server.id)
                return

            if command == "/admin" or text == keyboards.ADMIN:
                self.show_admin(chat_id, user_id)
                return

            if command == "/cancel" or text == keyboards.CANCEL:
                self.cancel_or_back(chat_id, user_id)
                return
            if text == keyboards.BACK:
                self.go_back(chat_id, user_id)
                return

            server_id = context.get("server_id")

            if text == keyboards.SERVER_STATUS:
                if context.get("screen") != "admin":
                    self.show_admin(chat_id, user_id)
                    return
                self.show_server_status(chat_id, user_id)
                return

            if text == keyboards.SETTINGS:
                if context.get("screen") != "admin":
                    self.show_admin(chat_id, user_id)
                    return
                self.show_settings(chat_id, user_id)
                return

            if text == keyboards.PROTOCOLS:
                if context.get("screen") != "admin_settings":
                    self.show_settings(chat_id, user_id)
                    return
                self.show_protocol_settings(chat_id, user_id)
                return

            protocol_server = self.server_for_protocol_setting(text)
            if protocol_server:
                if context.get("screen") != "admin_protocols":
                    self.show_protocol_settings(chat_id, user_id)
                    return
                self.actions.ask_protocol_toggle(chat_id, protocol_server.id)
                return

            if text == keyboards.ADMINISTRATORS:
                if context.get("screen") != "admin_settings":
                    self.show_settings(chat_id, user_id)
                    return
                self.show_administrators(chat_id, user_id)
                return

            if text == keyboards.ADD_ADMIN:
                if context.get("screen") != "admin_administrators":
                    self.show_administrators(chat_id, user_id)
                    return
                self.state.set_context(user_id, chat_id, "admin_add")
                self.actions.prompt_add_admin(chat_id)
                return

            if text == keyboards.DELETE_ADMIN:
                if context.get("screen") != "admin_administrators":
                    self.show_administrators(chat_id, user_id)
                    return
                self.actions.show_admin_delete_list(chat_id)
                return

            if text == keyboards.ADMIN_LIST:
                if context.get("screen") != "admin_administrators":
                    self.show_administrators(chat_id, user_id)
                    return
                self.actions.show_admin_list(chat_id)
                return

            if text == keyboards.SPEEDTEST:
                if context.get("screen") != "admin_traffic":
                    self.show_admin_traffic(chat_id, user_id, send_reports=False)
                    return
                self.show_speedtest(chat_id, user_id)
                return

            if text == keyboards.CHANNEL_LOAD:
                if context.get("screen") != "admin_traffic":
                    self.show_admin_traffic(chat_id, user_id, send_reports=False)
                    return
                self.show_channel_load(chat_id, user_id, "24")
                return

            channel_periods = {
                keyboards.CHANNEL_1H: "1",
                keyboards.CHANNEL_24H: "24",
                keyboards.CHANNEL_7D: "168",
                keyboards.CHANNEL_30D: "720",
            }
            if text in channel_periods:
                if context.get("screen") != "admin_channel":
                    self.show_admin(chat_id, user_id)
                    return
                self.show_channel_load(chat_id, user_id, channel_periods[text])
                return

            if command in {"/create", "/add", "/new"} or text == keyboards.CREATE_USER:
                if not server_id:
                    self.choose_protocol(chat_id, user_id, "create")
                    return
                self.show_create_method(chat_id, user_id, server_id)
                return

            if text == keyboards.ENTER_NAME:
                if not server_id or context.get("screen") != "create_method":
                    self.show_main(chat_id, user_id)
                    return
                self.state.set_context(user_id, chat_id, "create", server_id)
                self.actions.prompt_create(chat_id, user_id, server_id)
                return

            if text == keyboards.CREATE_DEFAULT:
                if not server_id or context.get("screen") != "create_method":
                    self.show_main(chat_id, user_id)
                    return
                self.state.clear_pending_create(user_id, chat_id)
                name = self.actions.create_client(chat_id, server_id)
                self.state.set_context(user_id, chat_id, "client", server_id, name)
                return

            if command in {"/list", "/clients"} or text == keyboards.USER_LIST:
                if not server_id:
                    self.choose_protocol(chat_id, user_id, "list")
                else:
                    self.open_list(chat_id, user_id, server_id)
                return

            if command == "/online":
                self.show_all_online(chat_id, user_id)
                return

            if text.casefold() in {
                keyboards.ONLINE.casefold(),
                "онлайн",
                "online",
            }:
                if context.get("screen") in {"admin", "admin_traffic"}:
                    self.show_all_online(chat_id, user_id)
                else:
                    self.open_online(chat_id, user_id, server_id)
                return

            if command == "/traffic" or text == keyboards.TRAFFIC:
                self.show_admin_traffic(chat_id, user_id, send_reports=True)
                return

            if text == keyboards.DOWNLOAD_CSV:
                if server_id and context.get("screen") == "traffic":
                    self.actions.send_traffic_reports(chat_id, server_id)
                else:
                    self.show_main(chat_id, user_id)
                return

            if text == keyboards.DOWNLOAD_USER_CSV:
                if server_id and context.get("screen") == "client_traffic" and context.get("ref"):
                    self.actions.send_client_traffic_reports(
                        chat_id,
                        server_id,
                        context["ref"],
                    )
                else:
                    self.show_main(chat_id, user_id)
                return

            if text == keyboards.REFRESH:
                self.refresh(chat_id, user_id, context)
                return

            # Navigation replies must be handled before this block so that
            # "Назад" or "Отмена" can never become a VPN user name.
            if self.state.is_pending_create(user_id, chat_id) and not text.startswith("/"):
                server_id = self.state.pending_create_server(user_id, chat_id)
                if not server_id:
                    raise RuntimeError("протокол для создания не выбран")
                try:
                    requested_name = formatters.normalize_client_name(text)
                except ValueError as exc:
                    self.telegram.send_message(
                        chat_id,
                        f"Не удалось принять имя: <code>{formatters.h(exc)}</code>\n\n"
                        "Введите другое имя или нажмите Отмена.",
                        keyboards.create_navigation(),
                    )
                    return
                self.state.clear_pending_create(user_id, chat_id)
                actual_name = self.actions.create_client(chat_id, server_id, requested_name)
                self.state.set_context(
                    user_id,
                    chat_id,
                    "client",
                    server_id,
                    actual_name or requested_name,
                )
                return

            if server_id and context.get("screen") == "create_method":
                self.actions.show_create_method(chat_id, server_id)
            elif server_id:
                self.show_protocol(chat_id, user_id, server_id)
            else:
                self.show_main(chat_id, user_id)
        except Exception as exc:
            log.exception("message command failed")
            self.state.clear_pending_create(user_id, chat_id)
            self.telegram.send_message(chat_id, f"Ошибка: <code>{formatters.h(exc)}</code>")
            self.show_main(chat_id, user_id)

    def show_main(self, chat_id: int, user_id: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "main")
        if auth.is_admin_id(self.settings, user_id, self.access_store):
            self.actions.show_menu(chat_id)
        else:
            self.actions.show_user_menu(chat_id, user_id)

    def show_create_method(self, chat_id: int, user_id: str, server_id: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "create_method", server_id)
        self.actions.show_create_method(chat_id, server_id)

    def handle_user_message(self, chat_id: int, user_id: str, command: str, text: str) -> None:
        if command in {"/start", "/help", "/menu"} or text in {
            keyboards.MAIN_MENU,
            keyboards.BACK,
            keyboards.REFRESH,
        }:
            self.show_main(chat_id, user_id)
            return
        self.telegram.send_message(chat_id, "Доступны только ваши VPN-профили и их настройки.")
        self.show_main(chat_id, user_id)

    def claim_access(self, message: dict, chat_id: int, user_id: str, token: str) -> None:
        if not self.access_store:
            self.telegram.send_message(chat_id, "Выдача доступа временно недоступна.")
            return
        try:
            grant = self.access_store.claim(token, message.get("from") or {})
        except ValueError as exc:
            self.telegram.send_message(chat_id, f"Не удалось активировать доступ: {formatters.h(exc)}")
            return
        self.telegram.send_message(
            chat_id,
            f"Доступ активирован: <b>{formatters.h(grant['protocol'])} · "
            f"{formatters.h(grant['vpn_user_name'])}</b>.",
        )
        notification = (
            "<b>Доступ к VPN активирован</b>\n"
            f"Протокол: <b>{formatters.h(grant['protocol'])}</b>\n"
            f"VPN-пользователь: <b>{formatters.h(grant['vpn_user_name'])}</b>\n"
            f"Получатель: {formatters.telegram_person(grant)}\n"
            f"Telegram ID: <code>{formatters.h(grant['telegram_user_id'])}</code>\n"
            f"Активирован: <code>{formatters.h(grant['granted_at'])} UTC</code>"
        )
        list_admins = getattr(self.access_store, "list_admins", None)
        dynamic_admins = (
            {item["telegram_user_id"] for item in list_admins()} if list_admins else set()
        )
        for admin_id in self.settings.allowed_users | dynamic_admins:
            try:
                self.telegram.send_message(int(admin_id), notification)
            except Exception as exc:
                log.warning("could not notify admin %s about access claim: %s", admin_id, exc)
        self.state.set_context(user_id, chat_id, "user_menu")
        self.actions.show_user_menu(chat_id, user_id)

    def show_protocol(self, chat_id: int, user_id: str, server_id: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "protocol", server_id)
        self.actions.show_protocol_menu(chat_id, server_id)

    def show_admin(self, chat_id: int, user_id: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "admin")
        self.actions.show_admin_menu(chat_id)

    def show_admin_traffic(self, chat_id: int, user_id: str, send_reports: bool) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "admin_traffic")
        if send_reports:
            self.actions.send_all_traffic_reports(chat_id)
        self.actions.show_admin_traffic_menu(chat_id)

    def show_settings(self, chat_id: int, user_id: str) -> None:
        self.state.clear_pending_admin(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "admin_settings")
        self.actions.show_settings_menu(chat_id)

    def show_protocol_settings(self, chat_id: int, user_id: str) -> None:
        self.state.set_context(user_id, chat_id, "admin_protocols")
        self.actions.show_protocol_settings(chat_id)

    def show_administrators(self, chat_id: int, user_id: str) -> None:
        self.state.clear_pending_admin(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "admin_administrators")
        self.actions.show_administrators_menu(chat_id)

    def show_server_status(self, chat_id: int, user_id: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "admin_status")
        self.actions.show_server_status(chat_id)

    def show_speedtest(self, chat_id: int, user_id: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "admin_speedtest")
        self.actions.show_speedtest(chat_id)

    def show_channel_load(self, chat_id: int, user_id: str, period: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "admin_channel", ref=period)
        self.actions.show_channel_load(chat_id, period)

    def show_all_online(self, chat_id: int, user_id: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "admin_online")
        self.actions.show_all_online(chat_id)

    def choose_protocol(self, chat_id: int, user_id: str, action: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "choose_protocol", ref=action)
        self.actions.show_protocol_picker(chat_id, action)

    def server_for_reply(self, text: str):
        checker = getattr(type(self.actions), "protocol_enabled", None)
        for server in self.actions.servers.servers:
            if checker and not self.actions.protocol_enabled(server.id):
                continue
            if text.casefold() == keyboards.protocol_label(server).casefold():
                return server
        return None

    def server_for_protocol_setting(self, text: str):
        normalized = text.strip()
        if normalized.startswith(("🟢 ", "🔴 ")):
            normalized = normalized[2:]
        for server in self.actions.servers.servers:
            if normalized.casefold() == keyboards.protocol_label(server).casefold():
                return server
        return None

    @staticmethod
    def forwarded_user(message: dict) -> dict | None:
        legacy = message.get("forward_from")
        if isinstance(legacy, dict) and legacy.get("id"):
            return legacy
        origin = message.get("forward_origin") or {}
        sender = origin.get("sender_user") if origin.get("type") == "user" else None
        if isinstance(sender, dict) and sender.get("id"):
            return sender
        return None

    def accept_admin_candidate(self, message: dict, chat_id: int, user_id: str, text: str) -> None:
        candidate = self.forwarded_user(message)
        if not candidate and text.isdigit():
            candidate = {"id": text}
        if not candidate:
            self.telegram.send_message(
                chat_id,
                "Не удалось определить Telegram ID. Введите числовой ID вручную или перешлите сообщение без скрытия автора.",
                keyboards.admin_add_navigation(),
            )
            return
        candidate = dict(candidate)
        candidate["id"] = str(candidate.get("id"))
        self.state.set_pending_admin(user_id, chat_id, candidate)
        self.actions.show_admin_candidate(chat_id, candidate)

    def open_list(self, chat_id: int, user_id: str, server_id: str | None) -> None:
        if not server_id:
            self.show_main(chat_id, user_id)
            return
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "list", server_id)
        self.actions.show_list(chat_id, server_id)

    def open_online(self, chat_id: int, user_id: str, server_id: str | None) -> None:
        if not server_id:
            self.show_main(chat_id, user_id)
            return
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "online", server_id)
        self.actions.show_online(chat_id, server_id)

    def open_traffic(self, chat_id: int, user_id: str, server_id: str | None) -> None:
        if not server_id:
            self.show_main(chat_id, user_id)
            return
        self.state.clear_pending_create(user_id, chat_id)
        self.state.set_context(user_id, chat_id, "traffic", server_id)
        self.actions.show_traffic(chat_id, server_id)

    def refresh(self, chat_id: int, user_id: str, context: dict) -> None:
        server_id = context.get("server_id")
        screen = context.get("screen")
        ref = context.get("ref")
        if screen == "list" and server_id:
            self.actions.show_list(chat_id, server_id)
        elif screen == "client" and server_id and ref:
            self.actions.show_client(chat_id, server_id, ref)
        elif screen == "client_traffic" and server_id and ref:
            self.actions.show_client_traffic(chat_id, server_id, ref)
        elif screen == "online" and server_id:
            self.actions.show_online(chat_id, server_id)
        elif screen == "traffic" and server_id:
            self.actions.show_traffic(chat_id, server_id)
        elif screen == "admin_status":
            self.actions.show_server_status(chat_id)
        elif screen == "admin_speedtest":
            self.actions.show_speedtest(chat_id)
        elif screen == "admin_channel":
            self.actions.show_channel_load(chat_id, ref or "24")
        elif screen == "admin_online":
            self.actions.show_all_online(chat_id)
        elif screen == "admin_traffic":
            self.actions.show_admin_traffic_menu(chat_id)
        elif screen == "admin_settings":
            self.actions.show_settings_menu(chat_id)
        elif screen == "admin_protocols":
            self.actions.show_protocol_settings(chat_id)
        elif screen == "admin_administrators":
            self.actions.show_administrators_menu(chat_id)
        elif screen == "admin":
            self.actions.show_admin_menu(chat_id)
        elif server_id:
            self.show_protocol(chat_id, user_id, server_id)
        else:
            self.show_main(chat_id, user_id)

    def cancel_or_back(self, chat_id: int, user_id: str) -> None:
        context = self.state.context(user_id, chat_id)
        if self.state.is_pending_create(user_id, chat_id):
            self.state.clear_pending_create(user_id, chat_id)
            server_id = context.get("server_id")
            if server_id:
                self.show_protocol(chat_id, user_id, server_id)
                return
        self.go_back(chat_id, user_id)

    def go_back(self, chat_id: int, user_id: str) -> None:
        self.state.clear_pending_create(user_id, chat_id)
        context = self.state.context(user_id, chat_id)
        screen = context.get("screen")
        server_id = context.get("server_id")
        ref = context.get("ref")
        if screen in {"admin_speedtest", "admin_channel", "admin_online"}:
            self.show_admin_traffic(chat_id, user_id, send_reports=False)
        elif screen == "admin_status":
            self.show_admin(chat_id, user_id)
        elif screen in {"admin_protocols", "admin_administrators"}:
            self.show_settings(chat_id, user_id)
        elif screen == "admin_add":
            self.show_administrators(chat_id, user_id)
        elif screen == "admin_settings":
            self.show_admin(chat_id, user_id)
        elif screen == "admin_traffic":
            self.show_admin(chat_id, user_id)
        elif screen == "choose_protocol":
            self.show_main(chat_id, user_id)
        elif screen == "admin":
            self.show_main(chat_id, user_id)
        elif screen == "protocol" or not server_id:
            self.show_main(chat_id, user_id)
        elif screen in {"create_method", "create", "list", "online", "traffic"}:
            self.show_protocol(chat_id, user_id, server_id)
        elif screen == "client":
            self.open_list(chat_id, user_id, server_id)
        elif screen == "client_traffic" and ref:
            self.state.set_context(user_id, chat_id, "client", server_id, ref)
            self.actions.show_client(chat_id, server_id, ref)
        else:
            self.show_protocol(chat_id, user_id, server_id)

    def handle_callback(self, callback: dict) -> None:
        callback_id = callback.get("id")
        if not callback_id:
            return
        message = callback.get("message") or {}
        chat_id = message.get("chat", {}).get("id")
        message_id = message.get("message_id")
        user_id = auth.user_id_from_update(callback)
        data = callback.get("data") or ""

        if not chat_id or not message_id:
            self.telegram.answer_callback(callback_id)
            return
        if self.settings.private_only and message.get("chat", {}).get("type") != "private":
            self.telegram.answer_callback(callback_id, "Откройте бота в личном чате.", True)
            return

        is_admin = auth.is_admin_id(self.settings, user_id, self.access_store)
        has_user_access = bool(self.access_store and self.access_store.has_access(user_id))
        if not is_admin and not has_user_access:
            self.telegram.answer_callback(callback_id, "Нет доступа.", True)
            return
        if not is_admin:
            try:
                self.telegram.answer_callback(callback_id)
                self.handle_user_callback(chat_id, message_id, user_id, data)
            except Exception as exc:
                log.warning("user callback failed: %s: %s", data, exc)
                self.telegram.send_message(chat_id, f"Ошибка: <code>{formatters.h(exc)}</code>")
                self.show_main(chat_id, user_id)
            return

        try:
            self.telegram.answer_callback(callback_id)
            if data == "menu":
                self.show_main(chat_id, user_id)
            elif data == "protocolsettings":
                self.show_protocol_settings(chat_id, user_id)
            elif data == "admins":
                self.show_administrators(chat_id, user_id)
            elif data.startswith("ptoggle:"):
                _, server_id, enabled_raw = callback_parts(data, "ptoggle", 2)
                if enabled_raw not in {"0", "1"}:
                    raise ValueError("некорректное состояние протокола")
                self.state.set_context(user_id, chat_id, "admin_protocols")
                self.actions.toggle_protocol(chat_id, server_id, enabled_raw == "1", user_id)
            elif data.startswith("adminadd:"):
                _, candidate_id = callback_parts(data, "adminadd", 1)
                candidate = self.state.pending_admin_candidate(user_id, chat_id)
                if not candidate or str(candidate.get("id")) != candidate_id:
                    raise ValueError("подтверждение устарело; начните добавление заново")
                self.state.clear_pending_admin(user_id, chat_id)
                self.state.set_context(user_id, chat_id, "admin_administrators")
                self.actions.add_admin(chat_id, candidate, user_id)
            elif data.startswith("admindel:"):
                _, target_id = callback_parts(data, "admindel", 1)
                self.actions.ask_delete_admin(chat_id, target_id)
            elif data.startswith("admindelyes:"):
                _, target_id = callback_parts(data, "admindelyes", 1)
                self.state.set_context(user_id, chat_id, "admin_administrators")
                self.actions.delete_admin(chat_id, target_id, user_id)
            elif data.startswith("protocol:"):
                _, server_id = callback_parts(data, "protocol", 1)
                self.show_protocol(chat_id, user_id, server_id)
            elif data.startswith("server:"):
                _, action, server_id = callback_parts(data, "server", 2)
                if action == "create":
                    self.show_create_method(chat_id, user_id, server_id)
                elif action == "list":
                    self.open_list(chat_id, user_id, server_id)
                elif action == "online":
                    self.open_online(chat_id, user_id, server_id)
                elif action == "traffic":
                    self.open_traffic(chat_id, user_id, server_id)
            elif data.startswith("create_default:"):
                _, server_id = callback_parts(data, "create_default", 1)
                self.state.clear_pending_create(user_id, chat_id)
                name = self.actions.create_client(chat_id, server_id)
                self.state.set_context(user_id, chat_id, "client", server_id, name)
            elif data.startswith("trafficreport:"):
                _, server_id = callback_parts(data, "trafficreport", 1)
                self.actions.send_traffic_reports(chat_id, server_id)
            elif data.startswith("client:"):
                _, server_id, ref = callback_parts(data, "client", 2)
                self.state.clear_pending_create(user_id, chat_id)
                self.state.set_context(user_id, chat_id, "client", server_id, ref)
                self.actions.show_client(chat_id, server_id, ref, message_id)
            elif data.startswith("qr:"):
                parts = data.split(":")
                if len(parts) == 4:
                    _, server_id, ref, platform = parts
                    if platform not in {"iphone", "android", "vpn"}:
                        raise ValueError("неизвестный тип QR")
                    self.actions.send_qr_for_client(chat_id, server_id, ref, platform)
                else:
                    _, server_id, ref = callback_parts(data, "qr", 2)
                    self.actions.send_qr_for_client(chat_id, server_id, ref)
            elif data.startswith("conffile:"):
                _, server_id, ref = callback_parts(data, "conffile", 2)
                self.actions.send_config_file_for_client(chat_id, server_id, ref)
            elif data.startswith("vpnkey:"):
                _, server_id, ref = callback_parts(data, "vpnkey", 2)
                self.actions.send_vpn_key_for_client(chat_id, server_id, ref)
            elif data.startswith("conftext:"):
                _, server_id, ref = callback_parts(data, "conftext", 2)
                self.actions.send_router_config_for_client(chat_id, server_id, ref)
            elif data.startswith("link:"):
                _, server_id, ref = callback_parts(data, "link", 2)
                self.actions.send_vless_link_for_client(chat_id, server_id, ref)
            elif data.startswith("ctraffic:"):
                _, server_id, ref = callback_parts(data, "ctraffic", 2)
                self.state.set_context(user_id, chat_id, "client_traffic", server_id, ref)
                self.actions.show_client_traffic(chat_id, server_id, ref, message_id)
            elif data.startswith("delask:"):
                _, server_id, ref = callback_parts(data, "delask", 2)
                self.state.set_context(user_id, chat_id, "client", server_id, ref)
                self.actions.ask_delete(chat_id, server_id, ref, message_id)
            elif data.startswith("delyes:"):
                _, server_id, ref = callback_parts(data, "delyes", 2)
                self.state.set_context(user_id, chat_id, "list", server_id)
                self.actions.delete_client(chat_id, server_id, ref, message_id)
            elif data.startswith("ga:"):
                _, server_id, ref = callback_parts(data, "ga", 2)
                name = self.actions.create_access_invite(chat_id, user_id, server_id, ref)
                self.actions.show_client(chat_id, server_id, name, message_id)
            elif data.startswith("ra:"):
                _, server_id, ref = callback_parts(data, "ra", 2)
                self.actions.ask_revoke_access(chat_id, server_id, ref, message_id)
            elif data.startswith("ray:"):
                _, server_id, ref = callback_parts(data, "ray", 2)
                self.actions.revoke_access(chat_id, server_id, ref, message_id)
            elif data.startswith("ta:"):
                _, server_id, ref = callback_parts(data, "ta", 2)
                self.actions.ask_transfer_access(chat_id, server_id, ref, message_id)
            elif data.startswith("tay:"):
                _, server_id, ref = callback_parts(data, "tay", 2)
                name = self.actions.create_access_invite(
                    chat_id,
                    user_id,
                    server_id,
                    ref,
                    transfer=True,
                )
                self.actions.show_client(chat_id, server_id, name, message_id)
            else:
                self.telegram.send_message(chat_id, "Эта кнопка устарела. Откройте меню ещё раз.")
                self.show_main(chat_id, user_id)
        except Exception as exc:
            log.exception("callback failed: %s", data)
            self.telegram.send_message(chat_id, f"Ошибка: <code>{formatters.h(exc)}</code>")
            self.show_main(chat_id, user_id)

    def handle_user_callback(
        self,
        chat_id: int,
        message_id: int,
        user_id: str,
        data: str,
    ) -> None:
        if data == "mymenu":
            self.state.set_context(user_id, chat_id, "user_menu")
            self.actions.show_user_menu(chat_id, user_id)
            return
        if data.startswith("my:"):
            _, server_id, ref = callback_parts(data, "my", 2)
            self.state.set_context(user_id, chat_id, "user_client", server_id, ref)
            self.actions.show_user_client(chat_id, user_id, server_id, ref, message_id)
            return

        server_id = ""
        ref = ""
        platform = None
        action = ""
        if data.startswith("qr:"):
            parts = data.split(":")
            if len(parts) not in {3, 4}:
                raise ValueError("некорректная кнопка QR")
            _, server_id, ref = parts[:3]
            platform = parts[3] if len(parts) == 4 else None
            if platform and platform not in {"iphone", "android", "vpn"}:
                raise ValueError("неизвестный тип QR")
            action = "qr"
        elif data.startswith("conffile:"):
            _, server_id, ref = callback_parts(data, "conffile", 2)
            action = "conffile"
        elif data.startswith("vpnkey:"):
            _, server_id, ref = callback_parts(data, "vpnkey", 2)
            action = "vpnkey"
        elif data.startswith("conftext:"):
            _, server_id, ref = callback_parts(data, "conftext", 2)
            action = "conftext"
        elif data.startswith("link:"):
            _, server_id, ref = callback_parts(data, "link", 2)
            action = "link"
        elif data.startswith("mytraffic:"):
            _, server_id, ref = callback_parts(data, "mytraffic", 2)
            action = "mytraffic"
        else:
            raise PermissionError("эта операция недоступна")

        self.actions.require_protocol_enabled(server_id)
        if not self.access_store or not self.access_store.owns(user_id, server_id, ref):
            raise PermissionError("нет доступа к этому VPN-профилю")
        if action == "qr":
            self.actions.send_qr_for_client(chat_id, server_id, ref, platform)
        elif action == "conffile":
            self.actions.send_config_file_for_client(chat_id, server_id, ref)
        elif action == "vpnkey":
            self.actions.send_vpn_key_for_client(chat_id, server_id, ref)
        elif action == "conftext":
            self.actions.send_router_config_for_client(chat_id, server_id, ref)
        elif action == "link":
            self.actions.send_vless_link_for_client(chat_id, server_id, ref)
        elif action == "mytraffic":
            self.actions.send_client_traffic_reports(chat_id, server_id, ref)


def callback_parts(data: str, prefix: str, value_count: int) -> list[str]:
    parts = data.split(":")
    if len(parts) != value_count + 1 or parts[0] != prefix or any(not part for part in parts[1:]):
        raise ValueError(f"некорректная кнопка {prefix}")
    return parts
