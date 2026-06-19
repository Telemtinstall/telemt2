def user_id_from_update(update_part: dict) -> str:
    return str(update_part.get("from", {}).get("id", ""))


def is_authorized(settings, update_part: dict) -> bool:
    return user_id_from_update(update_part) in settings.allowed_users


def is_private_chat(message: dict) -> bool:
    return message.get("chat", {}).get("type") == "private"

