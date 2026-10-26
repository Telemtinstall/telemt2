#!/usr/bin/env python3
import logging
import signal
import sys
import time
from pathlib import Path
from app.domain_queue import DomainQueue

from app.dispatch_pool import DispatchPool
from app.update_store import UpdateStore
from app.callback_store import CallbackStore
from app.actions import Actions
from app.access_store import AccessStore
from app.config import load_settings
from app.channel_store import ChannelStore
from app.handlers import Handlers
from app.servers import ServerRegistry
from app.state import BotState
from app.telegram_api import TelegramAPI
from app.traffic_store import TrafficStore


logging.basicConfig(
    level="CRITICAL",
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("vpnbot")
running = True


def stop(_signum, _frame):
    global running
    running = False


def register_signals() -> None:
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)


def main() -> None:
    settings = load_settings()
    logging.getLogger().setLevel(settings.log_level)

    telegram = TelegramAPI(settings)
    servers = ServerRegistry.from_file(settings.servers_path)
    state = BotState()
    traffic_store = TrafficStore(settings.traffic_db_dir, settings.traffic_timezone)
    access_store = AccessStore(settings.access_db_path, settings.access_invite_hours)
    telegram.callback_store = CallbackStore(settings.access_db_path)
    for server_id, enabled in access_store.protocol_states().items():
        try:
            server = servers.get(server_id)
            if server.is_active() != enabled:
                server.set_enabled(enabled)
        except Exception as exc:
            log.error("could not reconcile protocol %s: %s", server_id, exc)
    channel_store = ChannelStore(
        settings.channel_db_path,
        settings.channel_interface,
        settings.channel_retention_days,
    )
    actions = Actions(
        settings,
        telegram,
        servers,
        state,
        traffic_store,
        access_store,
        channel_store,
    )
    handlers = Handlers(settings, telegram, actions, state, access_store)

    log.info(
        "vpnbot started, allowed_users=%s, servers=%s",
        len(settings.allowed_users),
        ",".join(server.id for server in servers.servers),
    )

    try:
        telegram.set_bot_commands()
        for admin in access_store.list_admins():
            telegram.set_admin_commands(admin["telegram_user_id"])
    except Exception as exc:
        log.warning("could not set bot commands: %s", exc)

    updates = UpdateStore(settings.access_db_path)
    if updates.interrupted():
        log.error("Interrupted Telegram dispatches require review: %s", updates.interrupted())
    domain_queue = DomainQueue(Path(settings.servers_path).parent / 'domain-jobs.sqlite3', handlers.domain_admin.command, telegram)
    handlers.domain_admin.queue = domain_queue
    handlers.ip_admin.queue = domain_queue
    domain_queue.start()
    pool = DispatchPool(updates, handlers.handle_update)
    for update in updates.pending():
        pool.submit(update, recovered=True)
    offset = updates.offset()
    while running:
        try:
            for update in telegram.get_updates(offset):
                pool.submit(update)
                offset = update["update_id"] + 1
        except Exception as exc:
            log.warning("polling error: %s", exc)
            time.sleep(5)

    pool.close()
    domain_queue.close()
    log.info("vpnbot stopped")


if __name__ == "__main__":
    register_signals()
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
