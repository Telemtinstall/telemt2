#!/usr/bin/env python3
import logging

from app.config import load_settings
from app.servers import ServerRegistry
from app.traffic_store import TrafficStore


def main() -> None:
    settings = load_settings()
    registry = ServerRegistry.from_file(settings.servers_path)
    store = TrafficStore(settings.traffic_db_dir, settings.traffic_timezone)
    count = store.capture_all(registry)
    print(f"traffic snapshots captured: {count}")


if __name__ == "__main__":
    logging.basicConfig(level="WARNING")
    main()
