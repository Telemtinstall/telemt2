import re
import time
from datetime import datetime


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
        raise ValueError(
            "имя должно быть 1-32 символа: латиница, цифры, точка, дефис или _"
        )
    return name


def menu_text(title: str, allowed_users: set[str], stats: dict | None = None) -> str:
    users = ", ".join(sorted(allowed_users)) or "-"
    lines = [
        f"<b>{h(title)}</b>",
        "",
        f"Ботом управляют TGID, <code>{h(users)}</code>.",
    ]
    if stats:
        lines.append(menu_stats_text(stats))
    lines.extend(["", "Выберите протокол или раздел администрирования."])
    return "\n".join(lines)


def menu_stats_text(stats: dict) -> str:
    servers = stats.get("servers") or []
    if len(servers) == 1:
        item = servers[0]
        return (
            f"На сервере <b>{h(item.get('users', 0))}</b> пользователей "
            f"прокачали <b>{h(item.get('traffic', '0 B'))}</b> трафика."
        )
    total_users = sum(int(item.get("users", 0) or 0) for item in servers)
    total_bytes = sum(int(item.get("bytes", 0) or 0) for item in servers)
    return (
        f"На серверах <b>{h(total_users)}</b> пользователей "
        f"прокачали <b>{h(human_bytes(total_bytes))}</b> трафика."
    )


def create_prompt_text() -> str:
    raise RuntimeError("create_prompt_text requires server title")


def server_select_text(action: str) -> str:
    titles = {
        "create": "Выберите сервер, где создать клиента.",
        "list": "Выберите сервер, чей список клиентов открыть.",
        "traffic": "Выберите сервер для просмотра трафика.",
        "online": "Выберите сервер для проверки онлайн-клиентов.",
    }
    return titles.get(action, "Выберите сервер.")


def create_prompt_text_for_server(server_title: str) -> str:
    return "\n".join(
        [
            "<b>Создание клиента</b>",
            f"Сервер: <b>{h(server_title)}</b>",
            "",
            "",
            "Напишите имя клиента одним сообщением или нажмите кнопку ниже, чтобы создать имя автоматически.",
            "Можно использовать латиницу, цифры, точку, дефис и нижнее подчеркивание.",
            "Пример: <code>home_router</code>",
        ]
    )


def client_text(server, client: dict, access_status: dict | None = None) -> str:
    lines = [
        f"<b>{h(client.get('name'))}</b>",
        f"Сервер: <b>{h(server.title)}</b>",
    ]
    if server.is_amneziawg:
        lines.extend(
            [
                f"IP: <code>{h(client.get('ip'))}</code>",
                f"Public key: <code>{h(client.get('public_key'))}</code>",
            ]
        )
    elif server.is_vless:
        lines.append(f"UUID: <code>{h(client.get('uuid'))}</code>")
    if client.get("created_at"):
        lines.append(f"Создан: <code>{h(client.get('created_at'))}</code>")
    if server.is_amneziawg:
        lines.extend(["", "Для подключения выберите QR под свое устройство: iPhone или Android."])
    if access_status is not None:
        lines.extend(["", access_status_text(access_status)])
    lines.extend(["", "Выберите операцию."])
    return "\n".join(lines)


def telegram_person(data: dict) -> str:
    full_name = " ".join(
        part for part in (data.get("telegram_first_name"), data.get("telegram_last_name")) if part
    ).strip()
    username = str(data.get("telegram_username") or "").strip()
    if username:
        username = f"@{username.lstrip('@')}"
    if full_name and username:
        return f"{h(full_name)} ({h(username)})"
    return h(full_name or username or "без имени")


def access_status_text(status: dict) -> str:
    state = status.get("state")
    if state == "active":
        return "\n".join(
            [
                "<b>Доступ к боту: выдан</b>",
                f"Получатель: {telegram_person(status)}",
                f"Telegram ID: <code>{h(status.get('telegram_user_id'))}</code>",
                f"Активирован: <code>{h(status.get('granted_at'))} UTC</code>",
            ]
        )
    if state == "pending":
        return "\n".join(
            [
                "<b>Доступ к боту: ожидает активации</b>",
                f"Ссылка действует до: <code>{h(status.get('expires_at'))} UTC</code>",
            ]
        )
    return "<b>Доступ к боту: не выдан</b>"


def user_client_text(server, client: dict) -> str:
    lines = [
        "<b>Мой VPN</b>",
        f"Протокол: <b>{h(server.title)}</b>",
        f"Пользователь: <b>{h(client.get('name'))}</b>",
        "",
        "Выберите, какие настройки получить.",
    ]
    return "\n".join(lines)


def created_caption(data: dict) -> str:
    caption = f"Создан <b>{h(data.get('name'))}</b>\nIP: <code>{h(data.get('ip', ''))}</code>"
    if data.get("auto_incremented"):
        caption += "\nИмя было занято, выбран следующий свободный клиент."
    return caption


def created_caption_for_server(server, data: dict) -> str:
    lines = [f"Создан <b>{h(data.get('name'))}</b>", f"Сервер: <b>{h(server.title)}</b>"]
    if server.is_amneziawg and data.get("ip"):
        lines.append(f"IP: <code>{h(data.get('ip'))}</code>")
    if server.is_vless and data.get("uuid"):
        lines.append(f"UUID: <code>{h(data.get('uuid'))}</code>")
    if data.get("auto_incremented"):
        lines.append("Имя было занято, выбран следующий свободный клиент.")
    return "\n".join(lines)


def vless_link_text(server, data: dict) -> str:
    return "\n".join(
        [
            f"<b>VLESS-ссылка: {h(data.get('name'))}</b>",
            f"Сервер: <b>{h(server.title)}</b>",
            "",
            f"<code>{h(data.get('link'))}</code>",
        ]
    )


def vpn_key_text(server, data: dict, vpn_key: str) -> str:
    return "\n".join(
        [
            f"<b>VPN-ключ: {h(data.get('name'))}</b>",
            f"Сервер: <b>{h(server.title)}</b>",
            "",
            "Нажмите на строку ниже, чтобы скопировать:",
            f"<code>{h(vpn_key)}</code>",
        ]
    )


def router_config_text(name: str, config: str) -> str:
    return f"<b>Настройки для роутера: {h(name)}</b>\n\n<pre>{h(config)}</pre>"


def channel_summary_text(summary: dict, period_title: str, capacity_mbit: float) -> str:
    percent = lambda value: (float(value) / capacity_mbit * 100) if capacity_mbit > 0 else 0
    return "\n".join(
        [
            f"<b>Загрузка канала · {h(period_title)}</b>",
            f"Точек: <code>{int(summary.get('samples') or 0)}</code>",
            "",
            f"↓ Сейчас: <b>{float(summary.get('current_rx_mbit') or 0):.2f} Мбит/с</b> — "
            f"{percent(summary.get('current_rx_mbit') or 0):.1f}%",
            f"↑ Сейчас: <b>{float(summary.get('current_tx_mbit') or 0):.2f} Мбит/с</b> — "
            f"{percent(summary.get('current_tx_mbit') or 0):.1f}%",
            f"Среднее: ↓ {float(summary.get('average_rx_mbit') or 0):.2f} / "
            f"↑ {float(summary.get('average_tx_mbit') or 0):.2f} Мбит/с",
            f"Максимум: ↓ {float(summary.get('maximum_rx_mbit') or 0):.2f} / "
            f"↑ {float(summary.get('maximum_tx_mbit') or 0):.2f} Мбит/с",
            f"p95: ↓ {float(summary.get('p95_rx_mbit') or 0):.2f} / "
            f"↑ {float(summary.get('p95_tx_mbit') or 0):.2f} Мбит/с",
            f"Ошибки/потери за период: <code>{int(summary.get('errors') or 0)}/"
            f"{int(summary.get('dropped') or 0)}</code>",
        ]
    )


def traffic_text(data: dict) -> str:
    peers = data.get("peers") or []
    if not peers:
        return "Пиров пока нет."

    lines = [f"<b>Трафик</b> <code>{h(data.get('interface', 'awg0'))}</code>"]
    for peer in peers:
        lines.append(peer_traffic_text(peer))
    return "\n\n".join(lines)


def server_traffic_text(server, data: dict) -> str:
    if server.is_amneziawg:
        text = traffic_text(data)
    elif server.is_vless:
        text = vless_traffic_text(data)
    else:
        text = "Трафик для этого протокола пока не поддержан."
    return f"<b>{h(server.title)}</b>\n\n{text}"


def monthly_traffic_text(server, rows: list[dict], now: datetime) -> str:
    lines = [
        f"<b>{h(server.title)}</b>",
        f"<b>Трафик за {h(now.strftime('%Y-%m'))}</b>",
    ]
    if not rows:
        lines.extend(["", "Данных по пользователям пока нет."])
        return "\n".join(lines)

    total_upload = 0
    total_download = 0
    for row in rows:
        upload = int(row.get("upload_bytes") or 0)
        download = int(row.get("download_bytes") or 0)
        total = int(row.get("total_bytes") or upload + download)
        total_upload += upload
        total_download += download
        lines.extend(
            [
                "",
                f"<b>{h(row.get('user'))}</b>",
                f"Отправлено: <code>{h(human_bytes(upload))}</code>",
                f"Получено: <code>{h(human_bytes(download))}</code>",
                f"Всего: <code>{h(human_bytes(total))}</code>",
            ]
        )
    lines.extend(
        [
            "",
            "<b>Итого за месяц</b>",
            f"Отправлено: <code>{h(human_bytes(total_upload))}</code>",
            f"Получено: <code>{h(human_bytes(total_download))}</code>",
            f"Всего: <code>{h(human_bytes(total_upload + total_download))}</code>",
        ]
    )
    return "\n".join(lines)


def vless_traffic_text(data: dict) -> str:
    clients = data.get("clients") or []
    if not clients:
        return "Клиентов пока нет."

    lines = ["<b>Трафик VLESS</b>"]
    for client in clients:
        lines.append(
            "\n".join(
                [
                    f"<b>{h(client.get('name'))}</b>",
                    f"Up: <code>{h(client.get('uplink', human_bytes(client.get('uplink_bytes', 0))))}</code>",
                    f"Down: <code>{h(client.get('downlink', human_bytes(client.get('downlink_bytes', 0))))}</code>",
                    f"Total: <code>{h(client.get('total', human_bytes(client.get('total_bytes', 0))))}</code>",
                ]
            )
        )
    total = data.get("total") or {}
    if total:
        lines.append(
            "\n".join(
                [
                    "<b>Итого</b>",
                    f"Up: <code>{h(total.get('uplink', human_bytes(total.get('uplink_bytes', 0))))}</code>",
                    f"Down: <code>{h(total.get('downlink', human_bytes(total.get('downlink_bytes', 0))))}</code>",
                    f"Total: <code>{h(total.get('total', human_bytes(total.get('total_bytes', 0))))}</code>",
                ]
            )
        )
    return "\n\n".join(lines)


def server_online_text(server, data: dict, window_seconds: int) -> str:
    if server.is_amneziawg:
        return f"<b>{h(server.title)}</b>\n\n{online_text(data, window_seconds)}"
    if server.is_vless:
        return f"<b>{h(server.title)}</b>\n\n{vless_online_text(data)}"
    return "Онлайн для этого протокола пока не поддержан."


def vless_online_text(data: dict) -> str:
    clients = data.get("clients") or []
    if not clients:
        return "Клиентов пока нет."

    has_online = any("online" in client for client in clients)
    decorated = []
    for client in clients:
        status, rank = vless_status(client, has_online)
        decorated.append(with_status(client, status, vless_status_details(client, status), rank))
    decorated = sort_status_clients(decorated)
    online = [client for client in decorated if client.get("status") == "online"]
    active = [client for client in decorated if client.get("active")]
    interval = data.get("interval_seconds") or "-"
    tcp_connections = data.get("tcp_connections")
    if has_online:
        lines = [
            "<b>Кто онлайн</b>",
            f"Онлайн: <b>{len(online)}</b> из <b>{len(clients)}</b>",
            f"Передавали трафик за замер: <b>{len(active)}</b>",
        ]
        if data.get("observed_at"):
            lines.append(f"Проверено: <code>{h(data.get('observed_at'))}</code>")
    else:
        lines = [
            "<b>Кто активен</b>",
            f"Замер передачи трафика за <code>{h(interval)}</code> сек.",
            "Старый формат vlessctl не показывает надежно факт idle-подключения; здесь видны только клиенты, у которых изменились счетчики.",
            "",
            f"Передавали трафик: <b>{len(active)}</b> из <b>{len(clients)}</b>",
        ]
    if tcp_connections is not None:
        lines.append(f"TCP-соединений на сервере: <code>{h(tcp_connections)}</code>")
    lines.append("")
    lines.append("<b>Клиенты</b>")
    for client in decorated:
        lines.append(vless_online_client_line(client, has_online))
    return "\n".join(lines)


def vless_online_client_line(client: dict, has_online: bool) -> str:
    parts = [f"- <b>{h(client.get('name'))}</b> [{h(client.get('status'))}]"]
    if client.get("last_seen"):
        parts.append(f"last seen <code>{h(client.get('last_seen'))}</code>")
    elif client.get("status_details"):
        parts.append(f"<code>{h(client.get('status_details'))}</code>")
    if has_online and client.get("online_source"):
        parts.append(f"source <code>{h(client.get('online_source'))}</code>")
    if client.get("active"):
        parts.append(f"traffic <code>{h(client.get('total', human_bytes(client.get('total_bytes', 0))))}</code>")
    return ", ".join(parts)


def list_status_note(server, interval_seconds: int) -> str:
    if server.is_amneziawg:
        return "online = свежий handshake; в кнопке показано, когда был последний handshake."
    if server.is_vless:
        return (
            "online = статус vlessctl; active = была передача трафика за короткий замер. "
            "В кнопке показан last_seen, если сервер его отдает."
        )
    return ""


def list_status_summary(server, clients: list[dict]) -> str:
    total = len(clients)
    online = sum(1 for client in clients if client.get("status") == "online")
    if server.is_vless:
        active = sum(1 for client in clients if client.get("active"))
        return (
            f"Онлайн сейчас: <b>{online}</b> из <b>{total}</b>. "
            f"Active за замер: <b>{active}</b>."
        )
    return f"Онлайн сейчас: <b>{online}</b> из <b>{total}</b>."


def apply_list_statuses(server, clients: list[dict], data: dict, window_seconds: int) -> list[dict]:
    if server.is_amneziawg:
        return apply_amneziawg_list_statuses(clients, data, window_seconds)
    if server.is_vless:
        return apply_vless_list_statuses(clients, data)
    return [with_status(client, "unknown") for client in clients]


def apply_amneziawg_list_statuses(clients: list[dict], data: dict, window_seconds: int) -> list[dict]:
    now = int(time.time())
    peers = data.get("peers") or []
    result = []
    for client in clients:
        peer = find_peer(peers, client)
        online = bool(peer and is_peer_online(peer, now, window_seconds))
        status = "online" if online else "offline"
        rank = 0 if online else 2
        result.append(with_status(client, status, amneziawg_status_details(peer, online), rank))
    return sort_status_clients(result)


def apply_vless_list_statuses(clients: list[dict], data: dict) -> list[dict]:
    status_by_name = {}
    has_online = any("online" in client for client in data.get("clients") or [])
    for client in data.get("clients") or []:
        name = str(client.get("name"))
        status, rank = vless_status(client, has_online)
        status_by_name[name] = {
            "status": status,
            "details": vless_status_details(client, status),
            "rank": rank,
            "online": client.get("online"),
            "active": client.get("active"),
            "last_seen": client.get("last_seen"),
            "last_seen_at": client.get("last_seen_at"),
            "last_seen_epoch": client.get("last_seen_epoch"),
        }
    result = []
    for client in clients:
        status_data = status_by_name.get(str(client.get("name")))
        if status_data:
            item = with_status(
                client,
                status_data["status"],
                status_data["details"],
                status_data["rank"],
            )
            for key in ("online", "active", "last_seen", "last_seen_at", "last_seen_epoch"):
                if key in status_data:
                    item[key] = status_data[key]
            result.append(item)
        else:
            result.append(with_status(client, "offline", "нет данных", 2))
    return sort_status_clients(result)


def with_status(client: dict, status: str, details: str = "", rank: int | None = None) -> dict:
    item = dict(client)
    item["status"] = status
    item["status_rank"] = status_rank(status) if rank is None else rank
    if details:
        item["status_details"] = details
    return item


def status_rank(status: str) -> int:
    return {
        "online": 0,
        "active": 1,
        "offline": 2,
        "idle/offline": 2,
    }.get(status, 9)


def sort_status_clients(clients: list[dict]) -> list[dict]:
    return sorted(clients, key=status_sort_key)


def status_sort_key(client: dict) -> tuple[int, str]:
    try:
        rank = int(client.get("status_rank", 9))
    except (TypeError, ValueError):
        rank = 9
    return rank, str(client.get("name") or "").lower()


def amneziawg_status_details(peer: dict | None, online: bool) -> str:
    if not peer:
        return "нет данных"
    handshake = str(peer.get("handshake") or "never")
    if handshake == "never":
        return "never"
    if online:
        return f"сейчас, {handshake}"
    return f"был {handshake}"


def vless_status(client: dict, has_online: bool) -> tuple[str, int]:
    if has_online:
        if client.get("online"):
            return "online", 0
        if client.get("active"):
            return "active", 1
        return "offline", 2
    if client.get("active"):
        return "active", 1
    return "idle/offline", 2


def vless_status_details(client: dict, status: str) -> str:
    last_seen = str(client.get("last_seen") or "").strip()
    if last_seen:
        if last_seen == "never":
            return "never"
        if status == "online":
            return f"сейчас, {last_seen}"
        return f"был {last_seen}"
    if status == "active":
        return "трафик сейчас"
    return ""


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
        lines.append("")
        lines.append("Сейчас нет клиентов со свежим handshake.")

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


def server_client_traffic_text(server, client: dict, traffic: dict) -> str:
    if server.is_amneziawg:
        peer = find_peer(traffic.get("peers") or [], client)
        return client_traffic_text(client, peer)
    if server.is_vless:
        item = find_vless_traffic(traffic.get("clients") or [], client)
        if not item:
            return (
                f"<b>Трафик клиента</b>\n\n"
                f"<b>{h(client.get('name'))}</b>\n"
                "Клиент не найден в выводе traffic."
            )
        return "\n".join(
            [
                "<b>Трафик клиента</b>",
                "",
                f"<b>{h(item.get('name'))}</b>",
                f"Up: <code>{h(item.get('uplink', human_bytes(item.get('uplink_bytes', 0))))}</code>",
                f"Down: <code>{h(item.get('downlink', human_bytes(item.get('downlink_bytes', 0))))}</code>",
                f"Total: <code>{h(item.get('total', human_bytes(item.get('total_bytes', 0))))}</code>",
            ]
        )
    return "Трафик клиента для этого протокола пока не поддержан."


def find_vless_traffic(clients: list[dict], client: dict) -> dict | None:
    name = str(client.get("name") or "")
    for item in clients:
        if item.get("name") == name:
            return item
    return None


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
    age = now_epoch - latest_epoch
    return 0 <= age <= window_seconds


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


def server_status_text(data: dict, channel_mbit: float) -> str:
    cpu = data.get("cpu") or {}
    memory = data.get("memory") or {}
    disks = data.get("disks") or []
    disk = disks[0] if disks else {}
    network = data.get("network") or {}
    cpu_percent = float(cpu.get("usage_percent") or 0)
    memory_percent = float(memory.get("usage_percent") or 0)
    disk_percent = float(disk.get("usage_percent") or 0)
    rx_mbit = float(network.get("rx_bytes_per_second") or 0) * 8 / 1_000_000
    tx_mbit = float(network.get("tx_bytes_per_second") or 0) * 8 / 1_000_000
    lines = [
        "<b>🖥 Состояние сервера</b>",
        f"Хост: <code>{h(data.get('hostname', '-'))}</code>",
        "",
        f"{load_icon(cpu_percent)} <b>CPU:</b> <code>{cpu_percent:.1f}%</code>",
        f"Ядра: <code>{h(cpu.get('cores', '-'))}</code>",
        "Load average: "
        f"<code>{float(cpu.get('load_1m') or 0):.2f} / "
        f"{float(cpu.get('load_5m') or 0):.2f} / "
        f"{float(cpu.get('load_15m') or 0):.2f}</code>",
        "",
        f"{load_icon(memory_percent)} <b>Память:</b> "
        f"<code>{human_bytes(memory.get('used_bytes', 0))} / "
        f"{human_bytes(memory.get('total_bytes', 0))} — {memory_percent:.1f}%</code>",
        f"Доступно: <code>{human_bytes(memory.get('available_bytes', 0))}</code>",
        "",
        f"{load_icon(disk_percent)} <b>Диск {h(disk.get('mountpoint', '/'))}:</b> "
        f"<code>{human_bytes(disk.get('used_bytes', 0))} / "
        f"{human_bytes(disk.get('total_bytes', 0))} — {disk_percent:.1f}%</code>",
        f"Свободно: <code>{human_bytes(disk.get('free_bytes', 0))}</code>",
        "",
        f"🌐 <b>Канал:</b> <code>{h(network.get('interface', '-'))}</code>",
        network_rate_line("↓ Приём", rx_mbit, channel_mbit),
        network_rate_line("↑ Передача", tx_mbit, channel_mbit),
        "Всего с запуска: "
        f"↓ <code>{human_bytes(network.get('rx_total_bytes', 0))}</code> / "
        f"↑ <code>{human_bytes(network.get('tx_total_bytes', 0))}</code>",
    ]
    rx_errors = int(network.get("rx_errors") or 0)
    tx_errors = int(network.get("tx_errors") or 0)
    rx_dropped = int(network.get("rx_dropped") or 0)
    tx_dropped = int(network.get("tx_dropped") or 0)
    if rx_errors or tx_errors or rx_dropped or tx_dropped:
        lines.append(
            "⚠️ За текущий замер: "
            f"ошибки RX/TX <code>{rx_errors}/{tx_errors}</code>, "
            f"отброшено RX/TX <code>{rx_dropped}/{tx_dropped}</code>"
        )
    lines.extend(
        [
            "",
            f"⏱ Аптайм: <code>{format_uptime(data.get('uptime_seconds', 0))}</code>",
            f"🕓 Обновлено: <code>{format_utc(data.get('timestamp_utc'))}</code>",
        ]
    )
    return "\n".join(lines)


def load_icon(percent: float) -> str:
    if percent >= 85:
        return "🔴"
    if percent >= 60:
        return "🟡"
    return "🟢"


def network_rate_line(label: str, mbit: float, capacity_mbit: float) -> str:
    if capacity_mbit > 0:
        percent = mbit * 100 / capacity_mbit
        return f"{label}: <code>{mbit:.2f} Мбит/с — {percent:.1f}% канала</code>"
    return f"{label}: <code>{mbit:.2f} Мбит/с</code>"


def format_uptime(value: object) -> str:
    seconds = max(0, int(value or 0))
    days, seconds = divmod(seconds, 86400)
    hours, seconds = divmod(seconds, 3600)
    minutes = seconds // 60
    parts = []
    if days:
        parts.append(f"{days} дн.")
    if hours or days:
        parts.append(f"{hours} ч.")
    parts.append(f"{minutes} мин.")
    return " ".join(parts)


def format_utc(value: object) -> str:
    raw = str(value or "-")
    if raw.endswith("Z"):
        raw = raw[:-1].replace("T", " ") + " UTC"
    return raw


def speedtest_text(data: dict, channel_mbit: float) -> str:
    download = float(data.get("download_bps") or 0) / 1_000_000
    upload = float(data.get("upload_bps") or 0) / 1_000_000
    ping = float(data.get("ping_ms") or 0)
    server = data.get("server") or {}
    client = data.get("client") or {}
    lines = [
        "<b>🚀 Результат замера скорости</b>",
        "",
        speedtest_rate_line("↓ Download", download, channel_mbit),
        speedtest_rate_line("↑ Upload", upload, channel_mbit),
        f"🏓 Ping: <code>{ping:.1f} мс</code>",
        "",
        f"Узел: <code>{h(server.get('sponsor') or '-')}</code>",
        f"Город: <code>{h(server.get('name') or '-')}</code>",
        f"Страна: <code>{h(server.get('country') or '-')}</code>",
    ]
    if client.get("isp"):
        lines.append(f"Провайдер: <code>{h(client.get('isp'))}</code>")
    lines.extend(
        [
            "",
            "Передано за тест: "
            f"↑ <code>{human_bytes(data.get('bytes_sent', 0))}</code> / "
            f"↓ <code>{human_bytes(data.get('bytes_received', 0))}</code>",
            f"🕓 Завершено: <code>{format_utc(data.get('timestamp_utc'))}</code>",
        ]
    )
    return "\n".join(lines)


def speedtest_rate_line(label: str, mbit: float, capacity_mbit: float) -> str:
    if capacity_mbit > 0:
        percent = mbit * 100 / capacity_mbit
        return f"{label}: <code>{mbit:.1f} Мбит/с — {percent:.1f}% канала</code>"
    return f"{label}: <code>{mbit:.1f} Мбит/с</code>"
