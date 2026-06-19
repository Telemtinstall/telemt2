#!/usr/bin/env python3
import logging
import signal
import sys
import time

from app.actions import Actions
from app.awgctl import Awgctl
from app.config import load_settings
from app.handlers import Handlers
from app.state import BotState
from app.telegram_api import TelegramAPI


logging.basicConfig(
    level="CRITICAL",
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("vpnbotawg")
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
    awgctl = Awgctl(settings.awgctl)
    state = BotState()
    actions = Actions(settings, telegram, awgctl, state)
    handlers = Handlers(settings, telegram, actions, state)

    log.info("vpnbotawg started, admins=%s, awgctl=%s", len(settings.allowed_users), settings.awgctl)

    try:
        telegram.set_bot_commands()
    except Exception as exc:
        log.warning("could not set bot commands: %s", exc)

    offset = None
    while running:
        try:
            for update in telegram.get_updates(offset):
                offset = update["update_id"] + 1
                handlers.handle_update(update)
        except Exception as exc:
            log.warning("polling error: %s", exc)
            time.sleep(5)

    log.info("vpnbotawg stopped")


if __name__ == "__main__":
    register_signals()
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
