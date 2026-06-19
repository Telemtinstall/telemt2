import logging

from app import auth, formatters


log = logging.getLogger("vpnbotawg.handlers")


class Handlers:
    def __init__(self, settings, telegram, actions, state):
        self.settings = settings
        self.telegram = telegram
        self.actions = actions
        self.state = state

    def handle_update(self, update: dict) -> None:
        if "message" in update:
            self.handle_message(update["message"])
        elif "callback_query" in update:
            self.handle_callback(update["callback_query"])

    def handle_message(self, message: dict) -> None:
        chat_id = message.get("chat", {}).get("id")
        if not chat_id:
            return
        if not auth.is_authorized(self.settings, message):
            return
        if self.settings.private_only and not auth.is_private_chat(message):
            self.telegram.send_message(
                chat_id,
                "Откройте бота в личном чате, чтобы не показывать VPN-ключи в группе.",
            )
            return

        user_id = auth.user_id_from_update(message)
        text = (message.get("text") or "").strip()
        if not text:
            return

        try:
            if self.state.is_pending_create(user_id) and not text.startswith("/"):
                name = formatters.normalize_client_name(text)
                self.state.clear_pending_create(user_id)
                self.actions.create_client(chat_id, name)
                return

            command, *_rest = text.split()
            command = command.split("@", 1)[0].lower()

            if command in {"/start", "/help", "/menu"}:
                self.state.clear_pending_create(user_id)
                self.actions.show_menu(chat_id)
            elif command in {"/create", "/add", "/new"}:
                self.actions.prompt_create(chat_id, user_id)
            elif command in {"/list", "/clients"}:
                self.actions.show_list(chat_id)
            elif command == "/traffic":
                self.actions.show_traffic(chat_id)
            elif command == "/online" or text.lower() in {"кто онлайн", "онлайн", "online"}:
                self.actions.show_online(chat_id)
            elif command == "/cancel":
                self.state.clear_pending_create(user_id)
                self.actions.show_menu(chat_id)
            else:
                self.actions.show_menu(chat_id)
        except Exception as exc:
            log.exception("message command failed")
            self.state.clear_pending_create(user_id)
            self.telegram.send_message(chat_id, f"Ошибка: <code>{formatters.h(exc)}</code>")
            self.actions.show_menu(chat_id)

    def handle_callback(self, callback: dict) -> None:
        callback_id = callback["id"]
        message = callback.get("message") or {}
        chat_id = message.get("chat", {}).get("id")
        message_id = message.get("message_id")
        user_id = auth.user_id_from_update(callback)
        data = callback.get("data") or ""

        if not chat_id or not message_id:
            self.telegram.answer_callback(callback_id)
            return
        if not auth.is_authorized(self.settings, callback):
            return
        if self.settings.private_only and message.get("chat", {}).get("type") != "private":
            self.telegram.answer_callback(callback_id, "Откройте бота в личном чате.", True)
            return

        try:
            self.telegram.answer_callback(callback_id)
            if data == "menu":
                self.state.clear_pending_create(user_id)
                self.actions.show_menu(chat_id, message_id)
            elif data == "create":
                self.actions.prompt_create(chat_id, user_id, message_id)
            elif data == "create_default":
                self.state.clear_pending_create(user_id)
                self.telegram.edit_message(chat_id, message_id, "Создаю клиента с именем по умолчанию...")
                self.actions.create_client(chat_id)
            elif data == "cancel":
                self.state.clear_pending_create(user_id)
                self.actions.show_menu(chat_id, message_id)
            elif data == "list":
                self.state.clear_pending_create(user_id)
                self.actions.show_list(chat_id, message_id)
            elif data == "traffic":
                self.state.clear_pending_create(user_id)
                self.actions.show_traffic(chat_id, message_id)
            elif data == "online":
                self.state.clear_pending_create(user_id)
                self.actions.show_online(chat_id, message_id)
            elif data.startswith("client:"):
                self.state.clear_pending_create(user_id)
                ref = data.split(":", 1)[1]
                self.actions.show_client(chat_id, ref, message_id)
            elif data.startswith("qr:"):
                _, ref, platform = data.split(":", 2)
                self.actions.send_qr_for_client(chat_id, ref, platform)
            elif data.startswith("conffile:"):
                ref = data.split(":", 1)[1]
                self.actions.send_config_file_for_client(chat_id, ref)
            elif data.startswith("conftext:"):
                ref = data.split(":", 1)[1]
                self.actions.send_router_config_for_client(chat_id, ref)
            elif data.startswith("ctraffic:"):
                ref = data.split(":", 1)[1]
                self.actions.show_client_traffic(chat_id, ref, message_id)
            elif data.startswith("delask:"):
                ref = data.split(":", 1)[1]
                self.actions.ask_delete(chat_id, ref, message_id)
            elif data.startswith("delyes:"):
                ref = data.split(":", 1)[1]
                self.actions.delete_client(chat_id, ref, message_id)
            else:
                self.actions.show_menu(chat_id, message_id)
        except Exception as exc:
            log.exception("callback failed: %s", data)
            self.telegram.send_message(chat_id, f"Ошибка: <code>{formatters.h(exc)}</code>")
            self.actions.show_menu(chat_id)

