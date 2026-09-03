def user_id_from_update(update_part: dict) -> str:
    return str(update_part.get("from", {}).get("id", ""))


def is_authorized(settings, update_part: dict) -> bool:
    return user_id_from_update(update_part) in settings.allowed_users


def is_admin_id(settings, user_id: str, access_store=None) -> bool:
    if str(user_id) in settings.allowed_users:
        return True
    checker = getattr(access_store, "is_dynamic_admin", None)
    return bool(checker and checker(str(user_id)))


def is_private_chat(message: dict) -> bool:
    return message.get("chat", {}).get("type") == "private"
