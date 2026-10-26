MAIN_MENU = "🏠 Главная"
VPN_MENU = "VPN"
JOBS = "Задания"
MONITOR = "Монитор"
SITES_LIST = "Скачать список сайтов"
STATS = "Трафик и сеть"
BACK = "← Назад"
CANCEL = "Отмена"
CREATE_USER = "Создать пользователя"
ENTER_NAME = "Указать имя"
CREATE_DEFAULT = "Создать автоматически"
USER_LIST = "Список пользователей"
ONLINE = "Кто онлайн"
TRAFFIC = "Трафик"
REFRESH = "Обновить"
DOWNLOAD_CSV = "Скачать CSV"
DOWNLOAD_USER_CSV = "Скачать CSV пользователя"
ADMIN = "Администрирование"
SETTINGS = "Настройки"
CHANGE_IP = "Смена IP"
DOMAIN_SETTINGS = "Настройка домена"
PROTOCOLS = "Протоколы"
ADMINISTRATORS = "Администраторы"
ADD_ADMIN = "Добавить администратора"
DELETE_ADMIN = "Удалить администратора"
ADMIN_LIST = "Список администраторов"
SERVER_STATUS = "Состояние сервера"
SPEEDTEST = "Замер скорости"
CHANNEL_LOAD = "Загрузка канала"
CHANNEL_1H = "1 час"
CHANNEL_24H = "24 часа"
CHANNEL_7D = "7 дней"
CHANNEL_30D = "30 дней"


def protocol_label(server) -> str:
    return server.title


def reply_keyboard(rows: list[list[str]], placeholder: str | None = None) -> dict:
    # Keep navigation in the last row, as requested by the user.
    buttons = [button for row in rows for button in row]
    if BACK in buttons and MAIN_MENU in buttons:
        rows = compact_rows([
            button for button in buttons if button not in {BACK, MAIN_MENU}
        ]) + [[BACK, MAIN_MENU]]
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
    return reply_keyboard([[VPN_MENU, ADMIN]], "Главная")


def browsing(rows):
    return reply_keyboard(rows + [[BACK, MAIN_MENU]])


def operation_navigation():
    return reply_keyboard([[CANCEL]], "Отмена — выйти без применения")


def vpn_menu(servers):
    return browsing([[protocol_label(server)] for server in servers])


def protocol_picker(servers: list) -> dict:
    buttons = [protocol_label(server) for server in servers]
    buttons.append(CANCEL)
    return reply_keyboard(compact_rows(buttons), "Выберите протокол")


def admin_menu() -> dict:
    return reply_keyboard(
        [[BACK, MAIN_MENU], [SETTINGS, MONITOR]],
        "Администрирование",
    )


def monitor_menu() -> dict:
    return browsing([[SERVER_STATUS, TRAFFIC], [JOBS, SITES_LIST]])


def traffic_admin_menu() -> dict:
    return reply_keyboard(
        [[BACK, MAIN_MENU], [TRAFFIC, ONLINE], [SPEEDTEST, CHANNEL_LOAD]],
        "Трафик и сеть",
    )


def settings_menu() -> dict:
    return reply_keyboard(
        [[BACK, MAIN_MENU], [CHANGE_IP, PROTOCOLS], [DOMAIN_SETTINGS, ADMINISTRATORS]],
        "Настройки",
    )


def protocols_menu(servers: list, enabled) -> dict:
    buttons = [
        f"{'🟢' if enabled(server.id) else '🔴'} {protocol_label(server)}"
        for server in servers
    ]
    buttons.extend([BACK, MAIN_MENU])
    return reply_keyboard(compact_rows(buttons), "Включение протоколов")


def administrators_menu() -> dict:
    return reply_keyboard(
        [[ADD_ADMIN, DELETE_ADMIN], [ADMIN_LIST], [BACK, MAIN_MENU]],
        "Администраторы",
    )


def admin_add_navigation() -> dict:
    return operation_navigation()


def protocol_toggle_confirm(server_id: str, enabled: bool) -> dict:
    action = "включить" if enabled else "отключить"
    return {
        "inline_keyboard": [[
            {"text": f"Да, {action}", "callback_data": f"ptoggle:{server_id}:{1 if enabled else 0}"},
            {"text": "Отмена", "callback_data": "protocolsettings"},
        ]]
    }


def admin_add_confirm(telegram_user_id: str) -> dict:
    return {
        "inline_keyboard": [[
            {"text": "Да, добавить", "callback_data": f"adminadd:{telegram_user_id}"},
            {"text": "Отмена", "callback_data": "admins"},
        ]]
    }


def admin_delete_list(admins: list[dict]) -> dict:
    rows = []
    for admin in admins:
        user_id = str(admin["telegram_user_id"])
        username = admin.get("telegram_username")
        label = f"@{username} · {user_id}" if username else user_id
        rows.append([{"text": label[:60], "callback_data": f"admindel:{user_id}"}])
    return {"inline_keyboard": rows}


def admin_delete_confirm(telegram_user_id: str) -> dict:
    return {
        "inline_keyboard": [[
            {"text": "Да, удалить", "callback_data": f"admindelyes:{telegram_user_id}"},
            {"text": "Отмена", "callback_data": "admins"},
        ]]
    }


def channel_period_menu() -> dict:
    return reply_keyboard(
        compact_rows([CHANNEL_1H, CHANNEL_24H, CHANNEL_7D, CHANNEL_30D]) + [[BACK, MAIN_MENU]],
        "Период графика",
    )


def protocol_menu(_server) -> dict:
    return reply_keyboard(
        [[USER_LIST, CREATE_USER], [ONLINE], [BACK, MAIN_MENU]],
        "Выберите действие",
    )


def create_method_menu() -> dict:
    return reply_keyboard(
        [[ENTER_NAME, CREATE_DEFAULT], [CANCEL]],
        "Выберите способ создания",
    )


def create_navigation() -> dict:
    return reply_keyboard(
        [[CANCEL]],
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
    if protocol == "amneziawg" and server_id == "amneziawg3":
        rows.insert(3, [{"text": "QR AmneziaVPN · Split Tunneling", "callback_data": f"testsplit:{server_id}:{ref}"}])
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
    rows.append([{"text": SITES_LIST, "callback_data": "sitesdownload"}])
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
    if protocol == "amneziawg" and server_id == "amneziawg3":
        rows.insert(3, [{"text": "QR AmneziaVPN · Split Tunneling", "callback_data": f"testsplit:{server_id}:{ref}"}])
    rows.append([{"text": SITES_LIST, "callback_data": "sitesdownload"}])
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
