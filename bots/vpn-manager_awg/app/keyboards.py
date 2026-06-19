def main_menu() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "Создать клиента", "callback_data": "create"}],
            [{"text": "Список клиентов", "callback_data": "list"}],
            [
                {"text": "Кто онлайн", "callback_data": "online"},
                {"text": "Трафик", "callback_data": "traffic"},
            ],
        ]
    }


def create_prompt() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "Создать по умолчанию", "callback_data": "create_default"}],
            [{"text": "Главное меню", "callback_data": "menu"}],
        ]
    }


def empty_list() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "Создать клиента", "callback_data": "create"}],
            [{"text": "Главное меню", "callback_data": "menu"}],
        ]
    }


def client_list(clients: list[dict]) -> dict:
    rows = []
    for item in clients:
        ref = item.get("ref")
        details = item.get("status_details") or item.get("details")
        status = item.get("status")
        prefix = f"[{status}] " if status else ""
        if details:
            label = f"{prefix}{item.get('name')} - {details}"
        else:
            label = f"{prefix}{item.get('name')}"
        rows.append([{"text": label[:60], "callback_data": f"client:{ref}"}])
    rows.append([{"text": "Обновить", "callback_data": "list"}])
    rows.append([{"text": "Главное меню", "callback_data": "menu"}])
    return {"inline_keyboard": rows}


def client_actions(ref: str) -> dict:
    return {
        "inline_keyboard": [
            [{"text": "QR для iPhone", "callback_data": f"qr:{ref}:iphone"}],
            [{"text": "QR для Android", "callback_data": f"qr:{ref}:android"}],
            [{"text": "Прислать .conf", "callback_data": f"conffile:{ref}"}],
            [{"text": "Текст .conf для роутера", "callback_data": f"conftext:{ref}"}],
            [{"text": "Трафик клиента", "callback_data": f"ctraffic:{ref}"}],
            [{"text": "Удалить", "callback_data": f"delask:{ref}"}],
            [
                {"text": "Назад к списку", "callback_data": "list"},
                {"text": "Главное меню", "callback_data": "menu"},
            ],
        ]
    }


def delete_confirm(ref: str) -> dict:
    return {
        "inline_keyboard": [
            [
                {"text": "Да, удалить", "callback_data": f"delyes:{ref}"},
                {"text": "Отмена", "callback_data": f"client:{ref}"},
            ],
            [{"text": "Назад к списку", "callback_data": "list"}],
        ]
    }


def deleted() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "Назад к списку", "callback_data": "list"}],
            [{"text": "Главное меню", "callback_data": "menu"}],
        ]
    }


def traffic() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "Обновить трафик", "callback_data": "traffic"}],
            [{"text": "Главное меню", "callback_data": "menu"}],
        ]
    }


def online() -> dict:
    return {
        "inline_keyboard": [
            [{"text": "Обновить онлайн", "callback_data": "online"}],
            [{"text": "Список клиентов", "callback_data": "list"}],
            [{"text": "Главное меню", "callback_data": "menu"}],
        ]
    }


def client_traffic(ref: str) -> dict:
    return {
        "inline_keyboard": [
            [{"text": "Обновить", "callback_data": f"ctraffic:{ref}"}],
            [{"text": "Назад к клиенту", "callback_data": f"client:{ref}"}],
        ]
    }

