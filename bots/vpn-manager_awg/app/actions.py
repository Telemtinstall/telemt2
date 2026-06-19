from __future__ import annotations

from app import formatters, keyboards


class Actions:
    def __init__(self, settings, telegram, awgctl, state):
        self.settings = settings
        self.telegram = telegram
        self.awgctl = awgctl
        self.state = state

    def show_menu(self, chat_id: int, message_id: int | None = None) -> None:
        text = formatters.menu_text(
            self.settings.bot_title,
            self.settings.allowed_users,
            self.menu_stats(),
        )
        markup = keyboards.main_menu()
        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def menu_stats(self) -> dict | None:
        try:
            traffic = self.awgctl.traffic()
        except Exception:
            return None
        peers = traffic.get("peers") or []
        total_bytes = sum(
            int(peer.get("rx_bytes") or 0) + int(peer.get("tx_bytes") or 0)
            for peer in peers
        )
        return {
            "users": len(peers),
            "bytes": total_bytes,
            "traffic": formatters.human_bytes(total_bytes),
        }

    def prompt_create(self, chat_id: int, user_id: str, message_id: int | None = None) -> None:
        self.state.set_pending_create(user_id)
        text = formatters.create_prompt_text()
        markup = keyboards.create_prompt()
        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def show_list(self, chat_id: int, message_id: int | None = None) -> None:
        clients = self.normalized_clients()
        if clients:
            traffic = self.awgctl.traffic()
            clients = formatters.apply_list_statuses(
                clients,
                traffic,
                self.settings.online_window_seconds,
            )
            text = (
                "<b>Клиенты</b>\n\n"
                f"{formatters.list_status_summary(clients)}\n"
                f"{formatters.h(formatters.list_status_note(self.settings.online_window_seconds))}\n\n"
                "Нажмите на клиента, чтобы открыть операции."
            )
            markup = keyboards.client_list(clients)
        else:
            text = "Клиентов пока нет."
            markup = keyboards.empty_list()

        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def normalized_clients(self) -> list[dict]:
        return [
            formatters.normalize_client(item, index + 1)
            for index, item in enumerate(self.awgctl.list_clients())
        ]

    def show_client(self, chat_id: int, ref: str, message_id: int | None = None) -> None:
        client = self.awgctl.show(ref)
        text = formatters.client_text(client)
        actual_ref = str(client.get("name") or ref)
        markup = keyboards.client_actions(actual_ref)
        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def create_client(self, chat_id: int, name: str | None = None) -> None:
        data = self.awgctl.add(name)
        client_name = data["name"]
        caption = formatters.created_caption(data)
        self.telegram.send_message(
            chat_id,
            f"{caption}\n\nВыберите QR под свое устройство: iPhone или Android.",
            keyboards.client_actions(client_name),
        )

    def send_qr_for_client(self, chat_id: int, ref: str, platform: str) -> None:
        data = self.awgctl.qr(ref)
        name = data["name"]
        caption = f"QR для <b>{formatters.h(name)}</b>"
        item = self.qr_item_for_platform(data, platform)
        image_caption = f"{caption}\n{item['note']}"
        self.telegram.send_qr(chat_id, f"{name}-{item['suffix']}", item["base64"], image_caption)

    def qr_item_for_platform(self, data: dict, platform: str) -> dict:
        if platform == "android":
            qr_items = [str(item) for item in (data.get("vpn_qr_png_base64_items") or []) if item]
            if len(qr_items) > 1:
                raise RuntimeError(
                    "Android QR слишком большой: awgctl вернул несколько частей, "
                    "а Amnezia не умеет импортировать серию QR."
                )
            qr_base64 = qr_items[0] if qr_items else ""
            note = "Android: AmneziaVPN native QR для приложения Amnezia."
        elif platform == "iphone":
            qr_base64 = str(data.get("qr_png_base64") or "")
            note = "iPhone: .conf QR для приложения AmneziaWG или ручного импорта."
        else:
            raise RuntimeError(f"неизвестная платформа QR: {platform}")

        if not qr_base64:
            raise RuntimeError(f"QR для {platform} не найден в ответе awgctl")
        return {"suffix": platform, "base64": qr_base64, "note": note}

    def send_config_file_for_client(self, chat_id: int, ref: str) -> None:
        data = self.awgctl.show(ref)
        self.telegram.send_config_file(chat_id, data["name"], data["config"])

    def send_router_config_for_client(self, chat_id: int, ref: str) -> None:
        data = self.awgctl.show(ref)
        self.send_router_config(chat_id, data["name"], data["config"])

    def send_router_config(self, chat_id: int, name: str, config: str) -> None:
        text = formatters.router_config_text(name, config)
        if len(text) > self.settings.max_message:
            self.telegram.send_message(
                chat_id,
                f"Конфиг <b>{formatters.h(name)}</b> слишком большой для сообщения. Используйте кнопку <b>Прислать .conf</b>.",
            )
            return
        self.telegram.send_message(chat_id, text)

    def show_traffic(self, chat_id: int, message_id: int | None = None) -> None:
        data = self.awgctl.traffic()
        text = formatters.traffic_text(data)
        markup = keyboards.traffic()
        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def show_online(self, chat_id: int, message_id: int | None = None) -> None:
        data = self.awgctl.traffic()
        text = formatters.online_text(data, self.settings.online_window_seconds)
        markup = keyboards.online()
        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def show_client_traffic(self, chat_id: int, ref: str, message_id: int | None = None) -> None:
        client = self.awgctl.show(ref)
        traffic = self.awgctl.traffic()
        peer = formatters.find_peer(traffic.get("peers") or [], client)
        text = formatters.client_traffic_text(client, peer)
        actual_ref = str(client.get("name") or ref)
        markup = keyboards.client_traffic(actual_ref)

        if message_id:
            self.telegram.edit_message(chat_id, message_id, text, markup)
        else:
            self.telegram.send_message(chat_id, text, markup)

    def ask_delete(self, chat_id: int, ref: str, message_id: int) -> None:
        client = self.awgctl.show(ref)
        actual_ref = str(client.get("name") or ref)
        text = f"Удалить клиента <b>{formatters.h(client.get('name'))}</b>?"
        self.telegram.edit_message(chat_id, message_id, text, keyboards.delete_confirm(actual_ref))

    def delete_client(self, chat_id: int, ref: str, message_id: int) -> None:
        deleted = self.awgctl.delete(ref)
        text = f"Удален <b>{formatters.h(deleted.get('name'))}</b>."
        self.telegram.edit_message(chat_id, message_id, text, keyboards.deleted())
