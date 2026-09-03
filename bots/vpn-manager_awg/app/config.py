from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


BASE_DIR = Path(__file__).resolve().parent.parent
ENV_PATH = BASE_DIR / ".env"


@dataclass(frozen=True)
class Settings:
    base_dir: Path
    env_path: Path
    token: str
    bot_title: str
    allowed_users: set[str]
    awgctl: str
    servers_path: Path
    poll_timeout: int
    request_timeout: int
    private_only: bool
    max_message: int
    online_window_seconds: int
    vless_online_interval_seconds: int
    traffic_db_dir: Path
    traffic_timezone: str
    access_db_path: Path
    access_invite_hours: int
    server_status_command: str
    server_channel_mbit: float
    speedtest_command: str
    speedtest_timeout: int
    channel_db_path: Path
    channel_interface: str
    channel_retention_days: int
    log_level: str


def load_env(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env

    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def load_settings(env_path: Path = ENV_PATH) -> Settings:
    env = {**load_env(env_path), **os.environ}
    token = env.get("BOT_TOKEN") or env.get("TOKEN_BOT") or env.get("token_bot")
    users_raw = (
        env.get("ALLOWED_USERS")
        or env.get("ADMIN_BOT")
        or env.get("ADMIN_IDS")
        or env.get("ADMIN_ID")
        or env.get("USERID")
        or env.get("userid")
        or ""
    )
    allowed_users = {x.strip() for x in users_raw.replace(";", ",").split(",") if x.strip()}

    if not token:
        raise SystemExit("BOT_TOKEN/token_bot is missing in .env")
    if not allowed_users:
        raise SystemExit("ALLOWED_USERS/ADMIN_BOT/ADMIN_IDS/userid is missing in .env")

    return Settings(
        base_dir=BASE_DIR,
        env_path=env_path,
        token=token,
        bot_title=env.get("BOT_TITLE", "VPN-бот"),
        allowed_users=allowed_users,
        awgctl=env.get("AWGCTL", "/usr/local/sbin/awgctl"),
        servers_path=Path(env.get("SERVERS_CONFIG", str(BASE_DIR / "servers.json"))),
        poll_timeout=int(env.get("POLL_TIMEOUT", "45")),
        request_timeout=int(env.get("REQUEST_TIMEOUT", "75")),
        private_only=str(env.get("PRIVATE_ONLY", "1")).lower() not in {"0", "false", "no"},
        max_message=int(env.get("MAX_MESSAGE", "3900")),
        online_window_seconds=int(env.get("ONLINE_WINDOW_SECONDS", "180")),
        vless_online_interval_seconds=int(env.get("VLESS_ONLINE_INTERVAL_SECONDS", "3")),
        traffic_db_dir=Path(env.get("TRAFFIC_DB_DIR", str(BASE_DIR / "traffic-data"))),
        traffic_timezone=env.get("TRAFFIC_TIMEZONE", "UTC"),
        access_db_path=Path(env.get("ACCESS_DB_PATH", str(BASE_DIR / "access.sqlite3"))),
        access_invite_hours=int(env.get("ACCESS_INVITE_HOURS", "24")),
        server_status_command=env.get("SERVER_STATUS_COMMAND", "/usr/local/sbin/server-status"),
        server_channel_mbit=float(env.get("SERVER_CHANNEL_MBIT", "200")),
        speedtest_command=env.get("SPEEDTEST_COMMAND", "/usr/local/sbin/vpn-speedtest"),
        speedtest_timeout=int(env.get("SPEEDTEST_TIMEOUT", "210")),
        channel_db_path=Path(
            env.get("CHANNEL_DB_PATH", str(BASE_DIR / "server-metrics.sqlite3"))
        ),
        channel_interface=env.get("CHANNEL_INTERFACE", "auto"),
        channel_retention_days=int(env.get("CHANNEL_RETENTION_DAYS", "90")),
        log_level=env.get("LOG_LEVEL", "WARNING").upper(),
    )
