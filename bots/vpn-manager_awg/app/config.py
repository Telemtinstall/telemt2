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
    admin_ids: set[str]
    awgctl: str
    bot_title: str
    private_only: bool
    poll_timeout: int
    request_timeout: int
    max_message: int
    online_window_seconds: int
    log_level: str

    @property
    def allowed_users(self) -> set[str]:
        return self.admin_ids


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


def parse_bool(value: str, default: bool = False) -> bool:
    if value == "":
        return default
    return value.lower() not in {"0", "false", "no", "off"}


def parse_admin_ids(raw: str) -> set[str]:
    return {item.strip() for item in raw.replace(";", ",").split(",") if item.strip()}


def load_settings(env_path: Path = ENV_PATH) -> Settings:
    env = {**load_env(env_path), **os.environ}
    token = env.get("BOT_TOKEN") or env.get("TOKEN_BOT") or env.get("token_bot")
    admin_ids = parse_admin_ids(
        env.get("ADMIN_IDS")
        or env.get("ADMIN_BOT")
        or env.get("ADMIN_ID")
        or env.get("ALLOWED_USERS")
        or env.get("USERID")
        or env.get("userid")
        or ""
    )

    if not token:
        raise SystemExit("BOT_TOKEN is missing. Copy .env.example to .env and set BOT_TOKEN.")
    if not admin_ids:
        raise SystemExit("ADMIN_IDS/ADMIN_BOT is missing. Set one or more Telegram user IDs in .env.")

    return Settings(
        base_dir=BASE_DIR,
        env_path=env_path,
        token=token,
        admin_ids=admin_ids,
        awgctl=env.get("AWGCTL", "/usr/local/sbin/awgctl"),
        bot_title=env.get("BOT_TITLE", "AmneziaWG VPN Bot"),
        private_only=parse_bool(env.get("PRIVATE_ONLY", "1"), True),
        poll_timeout=int(env.get("POLL_TIMEOUT", "45")),
        request_timeout=int(env.get("REQUEST_TIMEOUT", "75")),
        max_message=int(env.get("MAX_MESSAGE", "3900")),
        online_window_seconds=int(env.get("ONLINE_WINDOW_SECONDS", "180")),
        log_level=env.get("LOG_LEVEL", "CRITICAL").upper(),
    )
