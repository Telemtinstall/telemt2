MAIN_MENU = "Главное меню"
BACK = "Назад"
CANCEL = "Отмена"
CREATE_USER = "Создать пользователя"
CREATE_DEFAULT = "Создать автоматически"
USER_LIST = "Список пользователей"
ONLINE = "Кто онлайн"
TRAFFIC = "Трафик"
REFRESH = "Обновить"
DOWNLOAD_CSV = "Скачать CSV"
DOWNLOAD_USER_CSV = "Скачать CSV пользователя"
ADMIN = "Админ"
SERVER_STATUS = "Состояние сервера"
SPEEDTEST = "Замер скорости"
CHANNEL_LOAD = "Загрузка канала"
CHANNEL_1H = "1 час"
CHANNEL_24H = "24 часа"
CHANNEL_7D = "7 дней"
CHANNEL_30D = "30 дней"


def protocol_label(server) -> str:
    if server.protocol == "amneziawg":
        return "AmneziaWG"
    if server.protocol == "vless":
        return "VLESS"
    return server.title


def reply_keyboard(rows: list[list[str]], placeholder: str | None = None) -> dict:
    markup = {
        "keyboard": [[{"text": text} for text in row] for row in rows],
        "resize_keyboard": True,
        "is_persistent": True,
    }
    if placeholder:
        markup["input_field_placeholder"] = placeholder
    return markup


def compact_rows(buttons: list[str]) -> list[list[str]]:
    """Arrange reply buttons in two columns, leaving an odd button below."""
    return [buttons[index : index + 2] for index in range(0, len(buttons), 2)]


def main_menu(servers: list) -> dict:
    buttons = [protocol_label(server) for server in servers]
    buttons.append(ADMIN)
    return reply_keyboard(compact_rows(buttons), "Выберите раздел")


def protocol_picker(servers: list) -> dict:
    buttons = [protocol_label(server) for server in servers]
    buttons.append(CANCEL)
    return reply_keyboard(compact_rows(buttons), "Выберите протокол")


def admin_menu() -> dict:
    return reply_keyboard(
        compact_rows([SERVER_STATUS, SPEEDTEST, TRAFFIC, CHANNEL_LOAD, ONLINE, BACK]),
        "Администрирование",
    )


def channel_period_menu() -> dict:
    return reply_keyboard(
        compact_rows([CHANNEL_1H, CHANNEL_24H, CHANNEL_7D, CHANNEL_30D, BACK]),
        "Период графика",
    )


def protocol_menu(_server) -> dict:
    return reply_keyboard(
        compact_rows([CREATE_USER, USER_LIST, ONLINE, MAIN_MENU]),
        "Выберите действие",
    )


def create_navigation() -> dict:
    return reply_keyboard(
        compact_rows([CREATE_DEFAULT, CANCEL, BACK, MAIN_MENU]),
        "Введите имя пользователя",
    )


def section_navigation(download: bool = False) -> dict:
    buttons = [REFRESH]
    if download:
        buttons.append(DOWNLOAD_CSV)
    buttons.extend([BACK, MAIN_MENU])
    return reply_keyboard(compact_rows(buttons))


def client_traffic_navigation() -> dict:
    return reply_keyboard(compact_rows([REFRESH, DOWNLOAD_USER_CSV, BACK, MAIN_MENU]))


def client_list(server_id: str, clients: list[dict]) -> dict:
    rows = []
    for item in clients:
        ref = item.get("ref")
        details = item.get("status_details") or item.get("details")
        status = item.get("status")
        prefix = f"[{status}] " if status else ""
        label = f"{prefix}{item.get('name')}"
        if details:
            label += f" - {details}"
        rows.append([{"text": label[:60], "callback_data": f"client:{server_id}:{ref}"}])
    return {"inline_keyboard": rows}


def client_actions(server_id: str, protocol: str, ref: str, access_status: dict | None = None) -> dict:
    if protocol == "amneziawg":
        rows = [
            [{"text": "QR для iPhone", "callback_data": f"qr:{server_id}:{ref}:iphone"}],
            [{"text": "QR для Android", "callback_data": f"qr:{server_id}:{ref}:android"}],
            [{"text": "QR AmneziaVPN", "callback_data": f"qr:{server_id}:{ref}:vpn"}],
            [{"text": "Получить VPN-ключ", "callback_data": f"vpnkey:{server_id}:{ref}"}],
            [{"text": "Прислать .conf", "callback_data": f"conffile:{server_id}:{ref}"}],
            [{"text": "Текст .conf для роутера", "callback_data": f"conftext:{server_id}:{ref}"}],
        ]
    elif protocol == "vless":
        rows = [
            [{"text": "Показать QR", "callback_data": f"qr:{server_id}:{ref}"}],
            [{"text": "Прислать VLESS-ссылку", "callback_data": f"link:{server_id}:{ref}"}],
        ]
    else:
        rows = [[{"text": "Показать QR", "callback_data": f"qr:{server_id}:{ref}"}]]
    rows.extend(
        [
            [{"text": "Трафик пользователя", "callback_data": f"ctraffic:{server_id}:{ref}"}],
            [{"text": "Удалить", "callback_data": f"delask:{server_id}:{ref}"}],
        ]
    )
    access_state = (access_status or {}).get("state")
    if access_state == "active":
        rows.extend(
            [
                [{"text": "Отозвать доступ к боту", "callback_data": f"ra:{server_id}:{ref}"}],
                [{"text": "Передать другому", "callback_data": f"ta:{server_id}:{ref}"}],
            ]
        )
    else:
        label = "Создать новую ссылку" if access_state == "pending" else "Предоставить доступ"
        rows.append([{"text": label, "callback_data": f"ga:{server_id}:{ref}"}])
    return {"inline_keyboard": rows}


def access_revoke_confirm(server_id: str, ref: str) -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "Да, отозвать", "callback_data": f"ray:{server_id}:{ref}"},
                {"text": "Отмена", "callback_data": f"client:{server_id}:{ref}"},
            ]
        ]
    }


def access_transfer_confirm(server_id: str, ref: str) -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "Да, передать", "callback_data": f"tay:{server_id}:{ref}"},
                {"text": "Отмена", "callback_data": f"client:{server_id}:{ref}"},
            ]
        ]
    }


def user_profiles(grants: list[dict], servers) -> dict:
    rows = []
    for grant in grants:
        try:
            server = servers.get(grant["server_id"])
            title = protocol_label(server)
        except Exception:
            title = grant.get("protocol") or grant.get("server_id")
        name = grant.get("vpn_user_name")
        rows.append(
            [{"text": f"{title} · {name}", "callback_data": f"my:{grant['server_id']}:{name}"}]
        )
    return {"inline_keyboard": rows}


def user_client_actions(server_id: str, protocol: str, ref: str) -> dict:
    if protocol == "amneziawg":
        rows = [
            [{"text": "QR для iPhone", "callback_data": f"qr:{server_id}:{ref}:iphone"}],
            [{"text": "QR для Android", "callback_data": f"qr:{server_id}:{ref}:android"}],
            [{"text": "QR AmneziaVPN", "callback_data": f"qr:{server_id}:{ref}:vpn"}],
            [{"text": "Получить VPN-ключ", "callback_data": f"vpnkey:{server_id}:{ref}"}],
            [{"text": "Прислать .conf", "callback_data": f"conffile:{server_id}:{ref}"}],
            [{"text": "Текст .conf для роутера", "callback_data": f"conftext:{server_id}:{ref}"}],
        ]
    elif protocol == "vless":
        rows = [
            [{"text": "Показать QR", "callback_data": f"qr:{server_id}:{ref}"}],
            [{"text": "Прислать VLESS-ссылку", "callback_data": f"link:{server_id}:{ref}"}],
        ]
    else:
        rows = []
    rows.append([{"text": "Мой трафик", "callback_data": f"mytraffic:{server_id}:{ref}"}])
    rows.append([{"text": "Мои VPN", "callback_data": "mymenu"}])
    return {"inline_keyboard": rows}


def delete_confirm(server_id: str, ref: str) -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "Да, удалить", "callback_data": f"delyes:{server_id}:{ref}"},
                {"text": "Отмена", "callback_data": f"client:{server_id}:{ref}"},
            ]
        ]
    }
