#!/usr/bin/env python3
import json

from app.channel_store import ChannelStore
from app.config import load_settings


def main() -> None:
    settings = load_settings()
    store = ChannelStore(
        settings.channel_db_path,
        settings.channel_interface,
        settings.channel_retention_days,
    )
    print(json.dumps(store.capture(), ensure_ascii=False, separators=(",", ":")))


if __name__ == "__main__":
    main()
