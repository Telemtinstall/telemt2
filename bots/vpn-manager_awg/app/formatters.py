from __future__ import annotations

import re
import time


CLIENT_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,32}$")


def h(value: object) -> str:
    return (
        str(value)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def split_text(text: str, max_message: int) -> list[str]:
    if len(text) <= max_message:
        return [text]

    parts = []
    while text:
        cut = text.rfind("\n", 0, max_message)
        if cut < 1:
            cut = max_message
        parts.append(text[:cut])
        text = text[cut:].lstrip()
    return parts


def normalize_client_name(text: str) -> str:
    name = text.strip()
    if not CLIENT_NAME_RE.fullmatch(name):
        raise ValueError("имя должно быть 1-32 символа: латиница, цифры, точка, дефис или _")
    return name


def normalize_client(item: dict, fallback_num: int) -> dict:
    name = str(item.get("name") or item.get("num") or fallback_num)
    ref = str(item.get("num") or name)
    details = item.get("ip") or ""
    normalized = dict(item)
    normalized.update({"ref": ref, "name": name, "details": details})
    return normalized


def menu_text(title: str, admin_ids: set[str], stats: dict | None = None) -> str:
    admins = ", ".join(sorted(admin_ids)) or "-"
    lines = [
        f"<b>{h(title)}</b>",
        "",
        f"Ботом управляют TGID: <code>{h(admins)}</code>.",
    ]
    if stats:
        lines.append(menu_stats_text(stats))
    lines.extend(["", "Выберите действие."])
    return "\n".join(lines)


def menu_stats_text(stats: dict) -> str:
    return (
        f"На сервере <b>{h(stats.get('users', 0))}</b> пользователей "
        f"прокачали <b>{h(stats.get('traffic', '0 B'))}</b> трафика."
    )


def create_prompt_text() -> str:
    return "\n".join(
        [
            "<b>Создание клиента</b>",
            "",
            "Напишите имя клиента одним сообщением или нажмите кнопку ниже, чтобы создать имя автоматически.",
            "Можно использовать латиницу, цифры, точку, дефис и нижнее подчеркивание.",
            "Пример: <code>home_router</code>",
        ]
    )


def created_caption(data: dict) -> str:
    lines = [f"Создан <b>{h(data.get('name'))}</b>"]
    if data.get("ip"):
        lines.append(f"IP: <code>{h(data.get('ip'))}</code>")
    if data.get("auto_incremented"):
        lines.append("Имя было занято, выбран следующий свободный клиент.")
    return "\n".join(lines)


def client_text(client: dict) -> str:
    lines = [f"<b>{h(client.get('name'))}</b>"]
    if client.get("ip"):
        lines.append(f"IP: <code>{h(client.get('ip'))}</code>")
    if client.get("public_key"):
        lines.append(f"Public key: <code>{h(client.get('public_key'))}</code>")
    if client.get("created_at"):
        lines.append(f"Создан: <code>{h(client.get('created_at'))}</code>")
    lines.extend(
        [
            "",
            "Для подключения выберите QR под свое устройство: iPhone или Android.",
            "",
            "Выберите операцию.",
        ]
    )
    return "\n".join(lines)


def router_config_text(name: str, config: str) -> str:
    return f"<b>Настройки для роутера: {h(name)}</b>\n\n<pre>{h(config)}</pre>"


def list_status_note(window_seconds: int) -> str:
    return f"online = свежий handshake за последние {window_seconds} сек.; в кнопке показано время последнего handshake."


def list_status_summary(clients: list[dict]) -> str:
    total = len(clients)
    online = sum(1 for client in clients if client.get("status") == "online")
    return f"Онлайн сейчас: <b>{online}</b> из <b>{total}</b>."


def apply_list_statuses(clients: list[dict], data: dict, window_seconds: int) -> list[dict]:
    now = int(time.time())
    peers = data.get("peers") or []
    result = []
    for client in clients:
        peer = find_peer(peers, client)
        online = bool(peer and is_peer_online(peer, now, window_seconds))
        status = "online" if online else "offline"
        rank = 0 if online else 2
        result.append(with_status(client, status, status_details(peer, online), rank))
    return sort_status_clients(result)


def with_status(client: dict, status: str, details: str = "", rank: int = 9) -> dict:
    item = dict(client)
    item["status"] = status
    item["status_rank"] = rank
    if details:
        item["status_details"] = details
    return item


def sort_status_clients(clients: list[dict]) -> list[dict]:
    return sorted(clients, key=status_sort_key)


def status_sort_key(client: dict) -> tuple[int, str]:
    try:
        rank = int(client.get("status_rank", 9))
    except (TypeError, ValueError):
        rank = 9
    return rank, str(client.get("name") or "").lower()


def status_details(peer: dict | None, online: bool) -> str:
    if not peer:
        return "нет данных"
    handshake = str(peer.get("handshake") or "never")
    if handshake == "never":
        return "never"
    if online:
        return f"сейчас, {handshake}"
    return f"был {handshake}"


def traffic_text(data: dict) -> str:
    peers = data.get("peers") or []
    if not peers:
        return "Пиров пока нет."

    lines = [f"<b>Трафик</b> <code>{h(data.get('interface', 'awg0'))}</code>"]
    for peer in peers:
        lines.append(peer_traffic_text(peer))
    return "\n\n".join(lines)


def online_text(data: dict, window_seconds: int, now_epoch: int | None = None) -> str:
    peers = data.get("peers") or []
    if not peers:
        return "Пиров пока нет."

    now = int(now_epoch if now_epoch is not None else time.time())
    online = []
    offline = []
    for peer in peers:
        if is_peer_online(peer, now, window_seconds):
            online.append(peer)
        else:
            offline.append(peer)

    lines = [
        "<b>Кто онлайн</b>",
        f"Порог: свежий handshake за последние <code>{window_seconds}</code> сек.",
        "",
        f"Онлайн: <b>{len(online)}</b> из <b>{len(peers)}</b>",
    ]

    if online:
        lines.append("")
        for peer in online:
            lines.append(online_peer_line(peer, now))
    else:
        lines.extend(["", "Сейчас нет клиентов со свежим handshake."])

    if offline:
        lines.append("")
        lines.append("<b>Не онлайн</b>")
        for peer in offline:
            lines.append(offline_peer_line(peer))

    return "\n".join(lines)


def client_traffic_text(client: dict, peer: dict | None) -> str:
    if peer:
        return "<b>Трафик клиента</b>\n\n" + peer_traffic_text(peer)
    return (
        f"<b>Трафик клиента</b>\n\n"
        f"<b>{h(client.get('name'))}</b> <code>{h(client.get('ip'))}</code>\n"
        "Peer не найден в выводе traffic."
    )


def peer_traffic_text(peer: dict) -> str:
    handshake = peer.get("handshake") or "never"
    rx = human_bytes(peer.get("rx_bytes", 0))
    tx = human_bytes(peer.get("tx_bytes", 0))
    endpoint = peer.get("endpoint") or "-"
    return "\n".join(
        [
            f"<b>{h(peer.get('name'))}</b> <code>{h(peer.get('vpn_ip'))}</code>",
            f"RX: <code>{rx}</code>",
            f"TX: <code>{tx}</code>",
            f"Handshake: <code>{h(handshake)}</code>",
            f"Endpoint: <code>{h(endpoint)}</code>",
        ]
    )


def is_peer_online(peer: dict, now_epoch: int, window_seconds: int) -> bool:
    latest = peer.get("latest_handshake_epoch")
    try:
        latest_epoch = int(latest)
    except (TypeError, ValueError):
        return False
    if latest_epoch <= 0:
        return False
    return now_epoch - latest_epoch <= window_seconds


def online_peer_line(peer: dict, now_epoch: int) -> str:
    latest = int(peer.get("latest_handshake_epoch") or 0)
    age = max(0, now_epoch - latest)
    endpoint = peer.get("endpoint") or "-"
    return (
        f"- <b>{h(peer.get('name'))}</b> <code>{h(peer.get('vpn_ip'))}</code>, "
        f"handshake <code>{age}s ago</code>, endpoint <code>{h(endpoint)}</code>"
    )


def offline_peer_line(peer: dict) -> str:
    handshake = peer.get("handshake") or "never"
    return (
        f"- <b>{h(peer.get('name'))}</b> <code>{h(peer.get('vpn_ip'))}</code>, "
        f"handshake: <code>{h(handshake)}</code>"
    )


def find_peer(peers: list[dict], client: dict) -> dict | None:
    name = str(client.get("name") or "")
    ip = str(client.get("ip") or "")
    public_key = str(client.get("public_key") or "")
    for peer in peers:
        if peer.get("name") == name:
            return peer
        if peer.get("vpn_ip") == ip:
            return peer
        if peer.get("peer_public_key") == public_key:
            return peer
    return None


def human_bytes(value: object) -> str:
    try:
        num = float(value)
    except (TypeError, ValueError):
        return "0 B"

    units = ["B", "KB", "MB", "GB", "TB"]
    idx = 0
    while num >= 1024 and idx < len(units) - 1:
        num /= 1024
        idx += 1
    if idx == 0:
        return f"{int(num)} {units[idx]}"
    return f"{num:.1f} {units[idx]}"
