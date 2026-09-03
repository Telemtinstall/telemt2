#!/usr/bin/env python3
import logging

from app.config import load_settings
from app.access_store import AccessStore
from app.servers import ServerRegistry
from app.traffic_store import TrafficStore


def main() -> None:
    settings = load_settings()
    registry = ServerRegistry.from_file(settings.servers_path)
    access_store = AccessStore(settings.access_db_path, settings.access_invite_hours)
    registry.servers = [
        server for server in registry.servers if access_store.protocol_enabled(server.id)
    ]
    registry.by_id = {server.id: server for server in registry.servers}
    store = TrafficStore(settings.traffic_db_dir, settings.traffic_timezone)
    count = store.capture_all(registry) if registry.servers else 0
    print(f"traffic snapshots captured: {count}")


if __name__ == "__main__":
    logging.basicConfig(level="WARNING")
    main()
