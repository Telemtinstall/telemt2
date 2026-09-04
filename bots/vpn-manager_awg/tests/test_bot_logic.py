import unittest
from unittest import mock
import json
import sqlite3
import tempfile
from datetime import datetime, timezone
from types import SimpleNamespace
from pathlib import Path

from app import formatters, keyboards
from app.access_store import AccessStore
from app.channel_store import ChannelStore
from app.actions import Actions
from app.handlers import Handlers, callback_parts
from app.servers import ServerRegistry, VpnServer, load_server_config
from app.state import BotState
from app.telegram_api import TelegramAPI
from app.traffic_store import TrafficStore


class FakeTelegram:
    def __init__(self):
        self.messages = []
        self.callbacks = []

    def send_message(self, chat_id, text, markup=None):
        self.messages.append((chat_id, text, markup))

    def answer_callback(self, callback_id, text="", show_alert=False):
        self.callbacks.append((callback_id, text, show_alert))


class FakeActions:
    def __init__(self):
        self.calls = []
        self.servers = SimpleNamespace(
            servers=[
                SimpleNamespace(id="awg", title="AmneziaWG", protocol="amneziawg"),
                SimpleNamespace(id="vless", title="VLESS", protocol="vless"),
            ]
        )

    def __getattr__(self, name):
        def record(*args, **kwargs):
            self.calls.append((name, args, kwargs))

        return record


def message(text, chat_id=10, user_id=1):
    return {
        "chat": {"id": chat_id, "type": "private"},
        "from": {"id": user_id},
        "text": text,
    }


def callback(data, chat_id=10, user_id=1, message_id=3):
    return {
        "id": "cb-1",
        "from": {"id": user_id},
        "data": data,
        "message": {
            "message_id": message_id,
            "chat": {"id": chat_id, "type": "private"},
        },
    }


class HandlerLogicTests(unittest.TestCase):
    def setUp(self):
        self.settings = SimpleNamespace(allowed_users={"1"}, private_only=True)
        self.telegram = FakeTelegram()
        self.actions = FakeActions()
        self.state = BotState()
        self.handlers = Handlers(self.settings, self.telegram, self.actions, self.state)

    def test_invalid_name_keeps_creation_pending(self):
        self.state.set_pending_create("1", 10, "server-a")

        self.handlers.handle_message(message("имя с пробелом"))

        self.assertTrue(self.state.is_pending_create("1", 10))
        self.assertEqual([], self.actions.calls)
        self.assertIn("Введите другое имя", self.telegram.messages[-1][1])

    def test_navigation_command_cancels_pending_creation(self):
        self.state.set_context("1", 10, "create", "server-a")
        self.state.set_pending_create("1", 10, "server-a")

        self.handlers.handle_message(message("/list"))

        self.assertFalse(self.state.is_pending_create("1"))
        self.assertEqual("show_list", self.actions.calls[-1][0])
        self.assertEqual("server-a", self.actions.calls[-1][1][1])

    def test_back_is_handled_before_pending_user_name(self):
        self.state.set_context("1", 10, "create", "awg")
        self.state.set_pending_create("1", 10, "awg")

        self.handlers.handle_message(message(keyboards.BACK))

        self.assertFalse(self.state.is_pending_create("1", 10))
        self.assertEqual("show_protocol_menu", self.actions.calls[-1][0])
        self.assertFalse(any(call[0] == "create_client" for call in self.actions.calls))

    def test_cancel_is_handled_before_pending_user_name(self):
        self.state.set_context("1", 10, "create", "awg")
        self.state.set_pending_create("1", 10, "awg")

        self.handlers.handle_message(message(keyboards.CANCEL))

        self.assertFalse(self.state.is_pending_create("1", 10))
        self.assertEqual("show_protocol_menu", self.actions.calls[-1][0])
        self.assertFalse(any(call[0] == "create_client" for call in self.actions.calls))

    def test_pending_creation_is_scoped_to_chat(self):
        self.state.set_pending_create("1", 10, "server-a")

        self.handlers.handle_message(message("valid_name", chat_id=20))

        self.assertTrue(self.state.is_pending_create("1", 10))
        self.assertFalse(any(call[0] == "create_client" for call in self.actions.calls))

    def test_unauthorized_callback_is_answered(self):
        callback = {
            "id": "cb-1",
            "from": {"id": 2},
            "data": "menu",
            "message": {"message_id": 3, "chat": {"id": 10, "type": "private"}},
        }

        self.handlers.handle_callback(callback)

        self.assertEqual(("cb-1", "Нет доступа.", True), self.telegram.callbacks[-1])

    def test_unauthorized_user_can_claim_one_time_link(self):
        class Access:
            def __init__(self):
                self.tokens = []

            def claim(self, token, telegram_user):
                self.tokens.append((token, telegram_user["id"]))
                return {
                    "server_id": "awg",
                    "protocol": "amneziawg",
                    "vpn_user_name": "alice",
                    "telegram_user_id": str(telegram_user["id"]),
                    "telegram_username": telegram_user.get("username"),
                    "telegram_first_name": telegram_user.get("first_name"),
                    "telegram_last_name": telegram_user.get("last_name"),
                    "granted_at": "2026-08-09 20:00:00",
                }

            def has_access(self, _user_id):
                return True

        access = Access()
        handlers = Handlers(self.settings, self.telegram, self.actions, self.state, access)
        claim_message = message("/start claim_secret", user_id=2)
        claim_message["from"].update({"first_name": "Ivan", "username": "ivan"})

        handlers.handle_message(claim_message)

        self.assertEqual([("secret", 2)], access.tokens)
        self.assertEqual("show_user_menu", self.actions.calls[-1][0])
        self.assertEqual((10, "2"), self.actions.calls[-1][1])
        self.assertTrue(any(chat_id == 1 and "Telegram ID" in text for chat_id, text, _ in self.telegram.messages))

    def test_regular_user_can_only_call_owned_profile_actions(self):
        class Access:
            def has_access(self, user_id):
                return str(user_id) == "2"

            def owns(self, user_id, server_id, ref):
                return (str(user_id), server_id, ref) == ("2", "awg", "alice")

        handlers = Handlers(self.settings, self.telegram, self.actions, self.state, Access())

        handlers.handle_callback(callback("qr:awg:alice:iphone", user_id=2))
        self.assertEqual("send_qr_for_client", self.actions.calls[-1][0])
        self.assertEqual((10, "awg", "alice", "iphone"), self.actions.calls[-1][1])

        handlers.handle_callback(callback("vpnkey:awg:alice", user_id=2))
        self.assertEqual("send_vpn_key_for_client", self.actions.calls[-1][0])
        self.assertEqual((10, "awg", "alice"), self.actions.calls[-1][1])

        handlers.handle_callback(callback("mytraffic:awg:alice", user_id=2))
        self.assertEqual("send_client_traffic_reports", self.actions.calls[-1][0])
        self.assertEqual((10, "awg", "alice"), self.actions.calls[-1][1])

        handlers.handle_callback(callback("qr:awg:bob:iphone", user_id=2))
        owned_calls = [call for call in self.actions.calls if call[0] == "send_qr_for_client"]
        self.assertEqual(1, len(owned_calls))

    def test_malformed_callback_is_rejected(self):
        with self.assertRaises(ValueError):
            callback_parts("client:server", "client", 2)

    def test_reply_protocol_then_list_sets_navigation_context(self):
        self.handlers.handle_message(message("AmneziaWG"))
        self.handlers.handle_message(message(keyboards.USER_LIST))

        self.assertEqual(
            {"screen": "list", "server_id": "awg", "ref": None},
            self.state.context("1", 10),
        )
        self.assertEqual("show_list", self.actions.calls[-1][0])

    def test_create_command_remembers_action_across_protocol_choice(self):
        self.handlers.handle_message(message("/create"))

        self.assertEqual(
            {"screen": "choose_protocol", "server_id": None, "ref": "create"},
            self.state.context("1", 10),
        )
        self.assertEqual("show_protocol_picker", self.actions.calls[-1][0])

        self.handlers.handle_message(message("AmneziaWG"))

        self.assertEqual("create_method", self.state.context("1", 10)["screen"])
        self.assertEqual("awg", self.state.context("1", 10)["server_id"])
        self.assertEqual("show_create_method", self.actions.calls[-1][0])
        self.assertEqual((10, "awg"), self.actions.calls[-1][1])

        self.handlers.handle_message(message(keyboards.ENTER_NAME))

        self.assertEqual("create", self.state.context("1", 10)["screen"])
        self.assertEqual("prompt_create", self.actions.calls[-1][0])
        self.assertEqual((10, "1", "awg"), self.actions.calls[-1][1])

    def test_list_command_opens_list_immediately_after_protocol_choice(self):
        self.handlers.handle_message(message("/list"))
        self.handlers.handle_message(message("VLESS"))

        self.assertEqual("list", self.state.context("1", 10)["screen"])
        self.assertEqual("vless", self.state.context("1", 10)["server_id"])
        self.assertEqual("show_list", self.actions.calls[-1][0])
        self.assertEqual((10, "vless"), self.actions.calls[-1][1])

    def test_cancel_from_protocol_picker_returns_to_main_menu(self):
        self.handlers.handle_message(message("/create"))
        self.handlers.handle_message(message(keyboards.CANCEL))

        self.assertEqual("main", self.state.context("1", 10)["screen"])
        self.assertEqual("show_menu", self.actions.calls[-1][0])

    def test_back_from_create_method_cancels_and_returns_to_protocol(self):
        self.state.set_context("1", 10, "protocol", "awg")
        self.handlers.handle_message(message(keyboards.CREATE_USER))
        self.assertEqual("create_method", self.state.context("1", 10)["screen"])

        self.handlers.handle_message(message(keyboards.BACK))

        self.assertEqual("protocol", self.state.context("1", 10)["screen"])
        self.assertEqual("show_protocol_menu", self.actions.calls[-1][0])
        self.assertFalse(self.state.is_pending_create("1", 10))

    def test_automatic_creation_is_available_from_create_method(self):
        self.state.set_context("1", 10, "protocol", "awg")
        self.handlers.handle_message(message(keyboards.CREATE_USER))
        self.handlers.handle_message(message(keyboards.CREATE_DEFAULT))

        self.assertEqual("create_client", self.actions.calls[-1][0])
        self.assertEqual((10, "awg"), self.actions.calls[-1][1])

    def test_inline_user_selection_then_reply_back_returns_to_list(self):
        self.state.set_context("1", 10, "list", "awg")

        self.handlers.handle_callback(callback("client:awg:alice"))
        self.handlers.handle_message(message(keyboards.BACK))

        self.assertEqual("list", self.state.context("1", 10)["screen"])
        self.assertEqual("show_list", self.actions.calls[-1][0])

    def test_main_menu_reply_always_resets_navigation(self):
        self.state.set_context("1", 10, "client", "awg", "alice")
        self.state.set_pending_create("1", 10, "awg")

        self.handlers.handle_message(message(keyboards.MAIN_MENU))

        self.assertEqual("main", self.state.context("1", 10)["screen"])
        self.assertFalse(self.state.is_pending_create("1", 10))
        self.assertEqual("show_menu", self.actions.calls[-1][0])

    def test_admin_status_reply_and_back_navigation(self):
        self.handlers.handle_message(message(keyboards.ADMIN))
        self.assertEqual("admin", self.state.context("1", 10)["screen"])
        self.assertEqual("show_admin_menu", self.actions.calls[-1][0])

        self.handlers.handle_message(message(keyboards.SERVER_STATUS))
        self.assertEqual("admin_status", self.state.context("1", 10)["screen"])
        self.assertEqual("show_server_status", self.actions.calls[-1][0])

        self.handlers.handle_message(message(keyboards.REFRESH))
        self.assertEqual("show_server_status", self.actions.calls[-1][0])

        self.handlers.handle_message(message(keyboards.BACK))
        self.assertEqual("admin", self.state.context("1", 10)["screen"])
        self.assertEqual("show_admin_menu", self.actions.calls[-1][0])

    def test_admin_speedtest_reply_refresh_and_back(self):
        self.handlers.handle_message(message(keyboards.ADMIN))
        self.handlers.handle_message(message(keyboards.TRAFFIC))
        self.handlers.handle_message(message(keyboards.SPEEDTEST))

        self.assertEqual("admin_speedtest", self.state.context("1", 10)["screen"])
        self.assertEqual("show_speedtest", self.actions.calls[-1][0])

        self.handlers.handle_message(message(keyboards.REFRESH))
        self.assertEqual("show_speedtest", self.actions.calls[-1][0])

        self.handlers.handle_message(message(keyboards.BACK))
        self.assertEqual("admin_traffic", self.state.context("1", 10)["screen"])
        self.assertEqual("show_admin_traffic_menu", self.actions.calls[-1][0])

    def test_admin_traffic_sends_all_reports_and_keeps_admin_menu(self):
        self.handlers.handle_message(message(keyboards.ADMIN))
        self.handlers.handle_message(message(keyboards.TRAFFIC))

        self.assertEqual("admin_traffic", self.state.context("1", 10)["screen"])
        self.assertEqual("send_all_traffic_reports", self.actions.calls[-2][0])
        self.assertEqual((10,), self.actions.calls[-2][1])
        self.assertEqual("show_admin_traffic_menu", self.actions.calls[-1][0])

    def test_online_command_shows_all_protocols_without_selected_server(self):
        self.handlers.handle_message(message("/online"))

        self.assertEqual("admin_online", self.state.context("1", 10)["screen"])
        self.assertEqual("show_all_online", self.actions.calls[-1][0])
        self.assertEqual((10,), self.actions.calls[-1][1])

    def test_admin_online_reply_shows_all_protocols_and_supports_refresh(self):
        self.handlers.handle_message(message(keyboards.ADMIN))
        self.handlers.handle_message(message(keyboards.TRAFFIC))
        self.handlers.handle_message(message(keyboards.ONLINE))

        self.assertEqual("admin_online", self.state.context("1", 10)["screen"])
        self.assertEqual("show_all_online", self.actions.calls[-1][0])

        self.handlers.handle_message(message(keyboards.REFRESH))
        self.assertEqual("show_all_online", self.actions.calls[-1][0])

        self.handlers.handle_message(message(keyboards.BACK))
        self.assertEqual("admin_traffic", self.state.context("1", 10)["screen"])
        self.assertEqual("show_admin_traffic_menu", self.actions.calls[-1][0])

    def test_admin_channel_period_and_back_navigation(self):
        self.handlers.handle_message(message(keyboards.ADMIN))
        self.handlers.handle_message(message(keyboards.TRAFFIC))
        self.handlers.handle_message(message(keyboards.CHANNEL_LOAD))

        self.assertEqual("admin_channel", self.state.context("1", 10)["screen"])
        self.assertEqual("24", self.state.context("1", 10)["ref"])
        self.assertEqual("show_channel_load", self.actions.calls[-1][0])

        self.handlers.handle_message(message(keyboards.CHANNEL_7D))
        self.assertEqual("168", self.state.context("1", 10)["ref"])
        self.assertEqual((10, "168"), self.actions.calls[-1][1])

        self.handlers.handle_message(message(keyboards.BACK))
        self.assertEqual("admin_traffic", self.state.context("1", 10)["screen"])
        self.assertEqual("show_admin_traffic_menu", self.actions.calls[-1][0])

    def test_forwarded_user_can_be_confirmed_as_admin(self):
        self.handlers.handle_message(message(keyboards.ADMIN))
        self.handlers.handle_message(message(keyboards.SETTINGS))
        self.handlers.handle_message(message(keyboards.ADMINISTRATORS))
        self.handlers.handle_message(message(keyboards.ADD_ADMIN))

        forwarded = message("forwarded")
        forwarded["forward_origin"] = {
            "type": "user",
            "sender_user": {"id": 777, "username": "newadmin", "first_name": "Ivan"},
        }
        self.handlers.handle_message(forwarded)
        candidate = self.state.pending_admin_candidate("1", 10)
        self.assertEqual("777", candidate["id"])
        self.assertEqual("show_admin_candidate", self.actions.calls[-1][0])

        self.handlers.handle_callback(callback("adminadd:777"))
        self.assertIsNone(self.state.pending_admin_candidate("1", 10))
        self.assertEqual("add_admin", self.actions.calls[-1][0])

    def test_protocol_toggle_confirmation_uses_all_protocols(self):
        self.handlers.handle_message(message(keyboards.ADMIN))
        self.handlers.handle_message(message(keyboards.SETTINGS))
        self.handlers.handle_message(message(keyboards.PROTOCOLS))
        self.handlers.handle_message(message("🟢 AmneziaWG"))
        self.assertEqual("ask_protocol_toggle", self.actions.calls[-1][0])
        self.assertEqual((10, "awg"), self.actions.calls[-1][1])

        self.handlers.handle_callback(callback("ptoggle:awg:0"))
        self.assertEqual("toggle_protocol", self.actions.calls[-1][0])

    def test_client_traffic_csv_reply_uses_selected_user(self):
        self.state.set_context("1", 10, "client_traffic", "awg", "alice")

        self.handlers.handle_message(message(keyboards.DOWNLOAD_USER_CSV))

        self.assertEqual("send_client_traffic_reports", self.actions.calls[-1][0])
        self.assertEqual((10, "awg", "alice"), self.actions.calls[-1][1])


class MenuAndStatusTests(unittest.TestCase):
    @staticmethod
    def reply_texts(markup):
        return {button["text"] for row in markup["keyboard"] for button in row}

    @staticmethod
    def reply_rows(markup):
        return [[button["text"] for button in row] for row in markup["keyboard"]]

    def test_compact_rows_use_two_columns_and_odd_last_row(self):
        self.assertEqual([["1", "2"], ["3", "4"]], keyboards.compact_rows(["1", "2", "3", "4"]))
        self.assertEqual([["1", "2"], ["3"]], keyboards.compact_rows(["1", "2", "3"]))

    def test_main_menu_exposes_protocols_as_reply_buttons(self):
        servers = [
            SimpleNamespace(id="awg", title="Local AWG", protocol="amneziawg"),
            SimpleNamespace(id="vless", title="Local VLESS", protocol="vless"),
        ]
        markup = keyboards.main_menu(servers)
        self.assertEqual({"Local AWG", "Local VLESS", keyboards.ADMIN}, self.reply_texts(markup))
        self.assertEqual(
            [["Local AWG", "Local VLESS"], [keyboards.ADMIN]],
            self.reply_rows(markup),
        )
        self.assertTrue(markup["resize_keyboard"])
        self.assertTrue(markup["is_persistent"])

    def test_protocol_picker_has_protocols_and_cancel(self):
        servers = [
            SimpleNamespace(id="awg", title="Local AWG", protocol="amneziawg"),
            SimpleNamespace(id="vless", title="Local VLESS", protocol="vless"),
        ]
        markup = keyboards.protocol_picker(servers)
        self.assertEqual(
            [["Local AWG", "Local VLESS"], [keyboards.CANCEL]],
            self.reply_rows(markup),
        )

    def test_packaged_main_menu_is_two_by_two_during_awg3_transition(self):
        registry = ServerRegistry.from_file(Path(__file__).resolve().parents[1] / "servers.json")
        self.assertEqual(
            [
                ["AmneziaWG 2.0", "AmneziaWG 3.1"],
                ["VLESS", keyboards.ADMIN],
            ],
            self.reply_rows(keyboards.main_menu(registry.servers)),
        )

    def test_protocol_menu_exposes_primary_reply_actions(self):
        server = SimpleNamespace(id="vless")
        markup = keyboards.protocol_menu(server)
        texts = self.reply_texts(markup)
        self.assertEqual(
            {
                keyboards.CREATE_USER,
                keyboards.USER_LIST,
                keyboards.ONLINE,
                keyboards.MAIN_MENU,
            },
            texts,
        )
        self.assertEqual(
            [
                [keyboards.CREATE_USER, keyboards.USER_LIST],
                [keyboards.ONLINE, keyboards.MAIN_MENU],
            ],
            self.reply_rows(markup),
        )

    def test_section_reply_keyboard_has_refresh_back_and_main(self):
        markup = keyboards.section_navigation()
        texts = self.reply_texts(markup)
        self.assertEqual(
            {keyboards.REFRESH, keyboards.BACK, keyboards.MAIN_MENU},
            texts,
        )
        self.assertEqual(
            [[keyboards.REFRESH, keyboards.BACK], [keyboards.MAIN_MENU]],
            self.reply_rows(markup),
        )

    def test_create_method_menu_offers_named_or_automatic_creation(self):
        self.assertEqual(
            [
                [keyboards.ENTER_NAME, keyboards.CREATE_DEFAULT],
                [keyboards.BACK],
            ],
            self.reply_rows(keyboards.create_method_menu()),
        )

    def test_create_name_input_has_single_cancel_button(self):
        self.assertEqual([[keyboards.BACK]], self.reply_rows(keyboards.create_navigation()))

    def test_traffic_reply_keyboard_has_csv_download(self):
        markup = keyboards.section_navigation(download=True)
        texts = self.reply_texts(markup)
        self.assertIn(keyboards.DOWNLOAD_CSV, texts)
        self.assertEqual(
            [
                [keyboards.REFRESH, keyboards.DOWNLOAD_CSV],
                [keyboards.BACK, keyboards.MAIN_MENU],
            ],
            self.reply_rows(markup),
        )

    def test_client_traffic_keyboard_has_filtered_csv_download(self):
        markup = keyboards.client_traffic_navigation()
        texts = self.reply_texts(markup)
        self.assertEqual(
            {
                keyboards.REFRESH,
                keyboards.DOWNLOAD_USER_CSV,
                keyboards.BACK,
                keyboards.MAIN_MENU,
            },
            texts,
        )
        self.assertEqual(
            [
                [keyboards.REFRESH, keyboards.DOWNLOAD_USER_CSV],
                [keyboards.BACK, keyboards.MAIN_MENU],
            ],
            self.reply_rows(markup),
        )

    def test_user_list_is_inline_only(self):
        markup = keyboards.client_list(
            "awg",
            [{"ref": "alice", "name": "alice", "status": "online"}],
        )
        self.assertIn("inline_keyboard", markup)
        self.assertNotIn("keyboard", markup)
        self.assertEqual("client:awg:alice", markup["inline_keyboard"][0][0]["callback_data"])

    def test_admin_menu_and_status_format(self):
        markup = keyboards.admin_menu()
        self.assertEqual(
            {
                keyboards.SERVER_STATUS,
                keyboards.TRAFFIC,
                keyboards.SETTINGS,
                keyboards.BACK,
            },
            self.reply_texts(markup),
        )
        self.assertEqual(
            [
                [keyboards.SERVER_STATUS, keyboards.TRAFFIC],
                [keyboards.SETTINGS, keyboards.BACK],
            ],
            self.reply_rows(markup),
        )
        self.assertEqual(
            [[keyboards.SPEEDTEST, keyboards.CHANNEL_LOAD], [keyboards.ONLINE, keyboards.BACK]],
            self.reply_rows(keyboards.traffic_admin_menu()),
        )
        self.assertEqual(
            [
                [keyboards.ADD_ADMIN, keyboards.DELETE_ADMIN],
                [keyboards.ADMIN_LIST, keyboards.BACK],
            ],
            self.reply_rows(keyboards.administrators_menu()),
        )
        text = formatters.server_status_text(
            {
                "timestamp_utc": "2026-08-09T18:45:21Z",
                "hostname": "vpn-server",
                "uptime_seconds": 123456,
                "cpu": {
                    "cores": 4,
                    "usage_percent": 18.4,
                    "load_1m": 0.31,
                    "load_5m": 0.26,
                    "load_15m": 0.19,
                },
                "memory": {
                    "total_bytes": 4 * 1024**3,
                    "used_bytes": 2 * 1024**3,
                    "available_bytes": 2 * 1024**3,
                    "usage_percent": 50,
                },
                "disks": [
                    {
                        "mountpoint": "/",
                        "total_bytes": 50 * 1024**3,
                        "used_bytes": 30 * 1024**3,
                        "free_bytes": 20 * 1024**3,
                        "usage_percent": 60,
                    }
                ],
                "network": {
                    "interface": "eth0",
                    "rx_bytes_per_second": 1_250_000,
                    "tx_bytes_per_second": 625_000,
                    "rx_total_bytes": 1000,
                    "tx_total_bytes": 500,
                },
            },
            1000,
        )
        self.assertIn("CPU:</b> <code>18.4%", text)
        self.assertIn("Диск /:</b>", text)
        self.assertIn("10.00 Мбит/с — 1.0% канала", text)
        self.assertIn("2026-08-09 18:45:21 UTC", text)
        self.assertNotIn("За текущий замер", text)

    def test_server_status_shows_only_errors_from_current_sample(self):
        text = formatters.server_status_text(
            {
                "network": {
                    "interface": "eth0",
                    "rx_errors": 1,
                    "tx_errors": 2,
                    "rx_dropped": 3,
                    "tx_dropped": 4,
                },
                "disks": [{}],
            },
            200,
        )
        self.assertIn("За текущий замер", text)
        self.assertIn("ошибки RX/TX <code>1/2</code>", text)
        self.assertIn("отброшено RX/TX <code>3/4</code>", text)

    def test_speedtest_format_includes_capacity_and_server(self):
        text = formatters.speedtest_text(
            {
                "timestamp_utc": "2026-08-09T18:56:00Z",
                "download_bps": 175_400_000,
                "upload_bps": 133_600_000,
                "ping_ms": 23.754,
                "bytes_sent": 1000,
                "bytes_received": 2000,
                "server": {
                    "sponsor": "Test ISP",
                    "name": "London",
                    "country": "United Kingdom",
                },
                "client": {"isp": "VPS Provider"},
            },
            200,
        )
        self.assertIn("175.4 Мбит/с — 87.7% канала", text)
        self.assertIn("133.6 Мбит/с — 66.8% канала", text)
        self.assertIn("23.8 мс", text)
        self.assertIn("Test ISP", text)

    def test_future_handshake_is_not_online(self):
        peer = {"latest_handshake_epoch": 110}
        self.assertFalse(formatters.is_peer_online(peer, now_epoch=100, window_seconds=180))

    def test_amnezia_profile_controls_are_absent(self):
        markup = keyboards.client_actions("awg", "amneziawg", "alice")
        callbacks = {
            button["callback_data"]
            for row in markup["inline_keyboard"]
            for button in row
        }
        self.assertFalse(any(value.startswith("profile") for value in callbacks))
        self.assertIn("vpnkey:awg:alice", callbacks)

    def test_user_amnezia_profile_has_vpn_key_button(self):
        markup = keyboards.user_client_actions("awg", "amneziawg", "alice")
        callbacks = {
            button["callback_data"]
            for row in markup["inline_keyboard"]
            for button in row
        }
        self.assertIn("vpnkey:awg:alice", callbacks)
        self.assertIn("mytraffic:awg:alice", callbacks)


class ConfigurationAndTelegramTests(unittest.TestCase):
    def test_vpn_key_is_sent_as_copyable_code(self):
        server = SimpleNamespace(
            id="awg",
            protocol="amneziawg",
            title="AmneziaWG",
            is_amneziawg=True,
            vpn_key=lambda _ref: {
                "name": "alice",
                "vpn_key": "vpn://copy-me_123",
            },
            show=lambda _ref: {
                "name": "alice",
                "ip": "10.88.88.2",
                "config": "[Peer]\nEndpoint = 194.87.148.23:1234\n",
            },
        )
        telegram = FakeTelegram()
        actions = Actions(
            None,
            telegram,
            SimpleNamespace(get=lambda _server_id: server),
            None,
        )

        actions.send_vpn_key_for_client(10, "awg", "alice")

        text = telegram.messages[-1][1]
        self.assertIn("Пользователь: <b>alice</b>", text)
        self.assertIn("IP сервера: <code>194.87.148.23</code>", text)
        self.assertIn("Протокол: <b>AmneziaWG</b>", text)
        self.assertIn("Подходит для:", text)
        self.assertIn("<code>vpn://copy-me_123</code>", text)
        self.assertNotIn("Сервер:", text)

    def test_vless_link_has_full_profile_details_without_server_name(self):
        server = SimpleNamespace(title="VLESS", is_amneziawg=False, is_vless=True)
        data = {
            "name": "alice",
            "link": "vless://copy-me@194.87.148.23:443?security=reality",
        }

        text = formatters.vless_link_text(server, data)

        self.assertIn("Пользователь: <b>alice</b>", text)
        self.assertIn("VPN-IP: <code>не назначается (VLESS)</code>", text)
        self.assertIn("IP сервера: <code>194.87.148.23</code>", text)
        self.assertIn("Протокол: <b>VLESS</b>", text)
        self.assertIn("v2rayNG", text)
        self.assertIn("<code>vless://copy-me@194.87.148.23:443", text)
        self.assertNotIn("Сервер:", text)

    def test_config_file_caption_has_profile_details_without_server_name(self):
        server = SimpleNamespace(
            id="amneziawg3",
            title="AmneziaWG 3.1",
            is_amneziawg=True,
            show=lambda _ref: {
                "name": "pavel",
                "ip": "10.89.89.2",
                "config": (
                    "[Interface]\nAddress = 10.89.89.2/32\n"
                    "[Peer]\nEndpoint = 194.87.148.23:1235\n"
                ),
            },
        )

        class Telegram:
            def __init__(self):
                self.file = None

            def send_config_file(self, *args):
                self.file = args

        telegram = Telegram()
        actions = Actions(None, telegram, SimpleNamespace(get=lambda _server_id: server), None)

        actions.send_config_file_for_client(10, "amneziawg3", "pavel")

        caption = telegram.file[3]
        self.assertIn("Пользователь: pavel", caption)
        self.assertIn("VPN-IP: 10.89.89.2", caption)
        self.assertIn("IP сервера: 194.87.148.23", caption)
        self.assertIn("Протокол: AmneziaWG 3.1", caption)
        self.assertIn("Подходит для:", caption)
        self.assertNotIn("Сервер:", caption)

    def test_access_invite_uses_bot_deep_link(self):
        server = SimpleNamespace(
            id="awg",
            protocol="amneziawg",
            title="AmneziaWG",
            show=lambda _ref: {"name": "alice"},
        )
        registry = SimpleNamespace(get=lambda _server_id: server)

        class Telegram:
            def __init__(self):
                self.messages = []

            def get_bot_username(self):
                return "vpn_test_bot"

            def send_message(self, *args):
                self.messages.append(args)

        access_store = SimpleNamespace(
            create_invite=lambda *_args, **_kwargs: {
                "token": "secret-token",
                "expires_at": "2026-08-10 20:00:00",
            }
        )
        telegram = Telegram()
        actions = Actions(None, telegram, registry, None, None, access_store)

        actions.create_access_invite(10, "1", "awg", "alice")

        self.assertIn(
            "https://t.me/vpn_test_bot?start=claim_secret-token",
            telegram.messages[0][1],
        )

    def test_admin_traffic_sends_daily_and_monthly_for_each_protocol(self):
        class Server:
            def __init__(self, server_id, title):
                self.id = server_id
                self.title = title

            def traffic(self):
                return {}

        class Registry:
            def __init__(self):
                self.servers = [Server("amneziawg", "AmneziaWG"), Server("vless", "VLESS")]

            def get(self, server_id):
                return next(server for server in self.servers if server.id == server_id)

        class Telegram:
            def __init__(self):
                self.documents = []

            def send_document(self, _chat_id, filename, *_args):
                self.documents.append(filename)

        telegram = Telegram()
        traffic_store = SimpleNamespace(
            report_files=lambda _server, _data: (b"daily", b"monthly"),
            chart_series=lambda _server, **_kwargs: ([], []),
        )
        actions = Actions(None, telegram, Registry(), None, traffic_store)
        actions.send_traffic_charts = lambda *_args, **_kwargs: None

        actions.send_all_traffic_reports(10)

        self.assertEqual(
            [
                "traffic_amneziawg_daily.csv",
                "traffic_amneziawg_monthly.csv",
                "traffic_vless_daily.csv",
                "traffic_vless_monthly.csv",
            ],
            telegram.documents,
        )

    def test_all_online_combines_protocols_and_isolates_controller_errors(self):
        class Server:
            def __init__(self, server_id, title, protocol, fails=False):
                self.id = server_id
                self.title = title
                self.protocol = protocol
                self.fails = fails

            @property
            def is_amneziawg(self):
                return self.protocol == "amneziawg"

            @property
            def is_vless(self):
                return self.protocol == "vless"

            def traffic(self):
                if self.fails:
                    raise RuntimeError("controller failed")
                return {"peers": []}

            def online(self, _seconds):
                if self.fails:
                    raise RuntimeError("controller failed")
                return {"clients": []}

        class Telegram:
            def __init__(self):
                self.messages = []

            def send_message(self, *args):
                self.messages.append(args)

        servers = SimpleNamespace(
            servers=[
                Server("awg", "AmneziaWG", "amneziawg"),
                Server("vless", "VLESS", "vless", fails=True),
            ]
        )
        settings = SimpleNamespace(
            vless_online_interval_seconds=3,
            online_window_seconds=180,
        )
        telegram = Telegram()
        actions = Actions(settings, telegram, servers, None)

        actions.show_all_online(10)

        text = telegram.messages[-1][1]
        self.assertIn("все протоколы", text)
        self.assertIn("AmneziaWG", text)
        self.assertIn("Пиров пока нет", text)
        self.assertIn("VLESS", text)
        self.assertIn("controller failed", text)

    def test_delete_client_purges_traffic_database(self):
        class Server:
            id = "vless"
            title = "VLESS"

            def delete(self, ref):
                self.deleted_ref = ref
                return {"name": "alice"}

        class Registry:
            server = Server()

            def get(self, _server_id):
                return self.server

        class Telegram:
            def __init__(self):
                self.edits = []

            def edit_message(self, *args):
                self.edits.append(args)

        purged = []
        traffic_store = SimpleNamespace(
            delete_user=lambda server_id, name: purged.append((server_id, name))
        )
        access_purged = []
        access_store = SimpleNamespace(
            purge_profile=lambda server_id, name: access_purged.append((server_id, name))
        )
        telegram = Telegram()
        actions = Actions(None, telegram, Registry(), None, traffic_store, access_store)
        actions.show_list = lambda *_args: None

        actions.delete_client(10, "vless", "client-id", 20)

        self.assertEqual([("vless", "alice")], purged)
        self.assertEqual([("vless", "alice")], access_purged)
        self.assertIn("База трафика, доступ к боту", telegram.edits[0][2])

    def test_amnezia_qr_uses_plain_awg_config(self):
        actions = Actions(None, None, None, None)
        server = SimpleNamespace(is_amneziawg=True)
        items = actions.qr_items_for_server(
            server,
            {
                "android_qr_png_base64": "android-current",
                "ios_qr_png_base64": "ios-current",
                "vpn_qr_png_base64_items": ["android-old"],
                "qr_png_base64": "ios-old",
            },
        )
        self.assertEqual(
            {
                "iphone": "ios-current",
                "android": "ios-current",
                "vpn": "android-current",
            },
            {item["suffix"]: item["base64"] for item in items},
        )

    def test_amnezia_vpn_qr_uses_native_payload(self):
        actions = Actions(None, None, None, None)
        server = SimpleNamespace(is_amneziawg=True)
        items = actions.qr_items_for_server(
            server,
            {
                "qr_png_base64": "plain-conf",
                "android_qr_png_base64": "native-vpn",
            },
        )
        vpn = next(item for item in items if item["suffix"] == "vpn")
        self.assertEqual("native-vpn", vpn["base64"])
        self.assertIn("AmneziaVPN", vpn["note"])

    def test_amnezia_qr_caption_contains_profile_details_without_server(self):
        class Server:
            id = "awg"
            title = "Test AmneziaWG"
            is_amneziawg = True

            def qr(self, _ref):
                return {
                    "name": "alice",
                    "ip": "10.89.89.2",
                    "qr_png_base64": "image",
                    "config": "[Peer]\nEndpoint = 194.87.148.23:1234\n",
                }

        class Registry:
            def __init__(self):
                self.server = Server()

            def get(self, _server_id):
                return self.server

        class Telegram:
            def __init__(self):
                self.caption = None

            def send_qr(self, _chat_id, _name, _data, caption):
                self.caption = caption

        telegram = Telegram()
        actions = Actions(None, telegram, Registry(), None)
        actions.send_qr_for_client(1, "awg", "alice", "android")
        self.assertIn("Пользователь: <b>alice</b>", telegram.caption)
        self.assertIn("VPN-IP: <code>10.89.89.2</code>", telegram.caption)
        self.assertIn("IP сервера: <code>194.87.148.23</code>", telegram.caption)
        self.assertIn("Протокол: <b>Test AmneziaWG</b>", telegram.caption)
        self.assertIn("Формат: <b>QR-код для Android</b>", telegram.caption)
        self.assertIn("Подходит для:", telegram.caption)
        self.assertNotIn("Сервер:", telegram.caption)

    def test_duplicate_server_ids_are_rejected(self):
        config = load_server_config(
            {
                "id": "server-a",
                "protocol": "amneziawg",
                "transport": "local",
                "command": "/usr/local/sbin/awgctl",
            }
        )
        with self.assertRaisesRegex(RuntimeError, "duplicate ids"):
            ServerRegistry([VpnServer(config), VpnServer(config)])

    def test_protocol_switch_uses_systemd_without_deleting_configuration(self):
        config = load_server_config(
            {
                "id": "vless",
                "protocol": "vless",
                "transport": "local",
                "command": "/usr/local/sbin/vlessctl",
                "service": "xray.service",
            }
        )
        completed = SimpleNamespace(returncode=0, stdout="", stderr="")
        with mock.patch("app.servers.subprocess.run", return_value=completed) as run:
            VpnServer(config).set_enabled(False)
        self.assertEqual(
            ["systemctl", "disable", "--now", "xray.service"],
            run.call_args.args[0],
        )

    def test_unsafe_server_id_is_rejected(self):
        with self.assertRaisesRegex(RuntimeError, "server id"):
            load_server_config(
                {
                    "id": "server:with:colons",
                    "protocol": "amneziawg",
                    "command": "/usr/local/sbin/awgctl",
                }
            )

    def test_longest_client_callback_fits_telegram_limit(self):
        markup = keyboards.client_actions("s" * 20, "amneziawg", "c" * 32)
        callbacks = [
            button["callback_data"]
            for row in markup["inline_keyboard"]
            for button in row
        ]
        self.assertLessEqual(max(len(value.encode("utf-8")) for value in callbacks), 64)

    def test_admin_client_card_changes_access_buttons_by_state(self):
        none_callbacks = {
            button["callback_data"]
            for row in keyboards.client_actions("awg", "amneziawg", "alice", {"state": "none"})["inline_keyboard"]
            for button in row
        }
        active_callbacks = {
            button["callback_data"]
            for row in keyboards.client_actions("awg", "amneziawg", "alice", {"state": "active"})["inline_keyboard"]
            for button in row
        }
        self.assertIn("ga:awg:alice", none_callbacks)
        self.assertIn("ra:awg:alice", active_callbacks)
        self.assertIn("ta:awg:alice", active_callbacks)

        text = formatters.access_status_text(
            {
                "state": "active",
                "telegram_user_id": "2",
                "telegram_username": "ivan",
                "telegram_first_name": "Иван",
                "telegram_last_name": "Петров",
                "granted_at": "2026-08-09 20:00:00",
            }
        )
        self.assertIn("Иван Петров (@ivan)", text)
        self.assertIn("Telegram ID: <code>2</code>", text)


class AccessStoreTests(unittest.TestCase):
    def test_dynamic_admins_and_protocol_states_persist(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "access.sqlite3"
            store = AccessStore(path)
            store.add_admin(
                {"id": 777, "username": "newadmin", "first_name": "Ivan"},
                "1",
            )
            store.set_protocol_enabled("vless", False, "1")

            reopened = AccessStore(path)
            self.assertTrue(reopened.is_dynamic_admin("777"))
            self.assertEqual("newadmin", reopened.list_admins()[0]["telegram_username"])
            self.assertFalse(reopened.protocol_enabled("vless"))
            self.assertEqual({"vless"}, reopened.disabled_protocol_ids())
            self.assertTrue(reopened.remove_admin("777"))
            self.assertFalse(reopened.is_dynamic_admin("777"))

    def test_invite_claim_is_one_time_and_profile_shows_recipient(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "access.sqlite3"
            store = AccessStore(path)
            invite = store.create_invite("awg", "amneziawg", "alice", "1")

            self.assertEqual("pending", store.profile_status("awg", "alice")["state"])
            self.assertLessEqual(len(f"claim_{invite['token']}"), 64)
            self.assertNotIn(invite["token"].encode(), path.read_bytes())

            grant = store.claim(
                invite["token"],
                {"id": 2, "username": "ivan", "first_name": "Иван", "last_name": "Петров"},
            )

            self.assertEqual("2", grant["telegram_user_id"])
            self.assertTrue(store.owns("2", "awg", "alice"))
            status = store.profile_status("awg", "alice")
            self.assertEqual("active", status["state"])
            self.assertEqual("ivan", status["telegram_username"])
            with self.assertRaisesRegex(ValueError, "недействительна"):
                store.claim(invite["token"], {"id": 3})

    def test_same_telegram_user_can_own_awg_and_vless(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = AccessStore(Path(tmp) / "access.sqlite3")
            for server_id, protocol, name in (
                ("awg", "amneziawg", "alice"),
                ("vless", "vless", "alice"),
            ):
                invite = store.create_invite(server_id, protocol, name, "1")
                store.claim(invite["token"], {"id": 2, "first_name": "Иван"})

            grants = store.grants_for_user("2")
            self.assertEqual({"awg", "vless"}, {grant["server_id"] for grant in grants})

    def test_transfer_revokes_old_owner_and_purge_removes_all_traces(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = AccessStore(Path(tmp) / "access.sqlite3")
            first = store.create_invite("vless", "vless", "alice", "1")
            store.claim(first["token"], {"id": 2})

            with self.assertRaisesRegex(ValueError, "уже выдан"):
                store.create_invite("vless", "vless", "alice", "1")
            transfer = store.create_invite("vless", "vless", "alice", "1", transfer=True)
            self.assertFalse(store.owns("2", "vless", "alice"))
            store.claim(transfer["token"], {"id": 3})
            self.assertTrue(store.owns("3", "vless", "alice"))

            store.purge_profile("vless", "alice")
            self.assertEqual({"state": "none"}, store.profile_status("vless", "alice"))
            self.assertEqual([], store.grants_for_user("3"))

    def test_long_edit_is_split_without_truncation(self):
        settings = SimpleNamespace(token="token", request_timeout=1, max_message=7)
        telegram = TelegramAPI(settings)
        calls = []
        telegram.call = lambda method, data=None, files=None: calls.append((method, data)) or {}

        telegram.edit_message(10, 20, "first\nsecond", {"inline_keyboard": []})

        self.assertEqual("first", calls[0][1]["text"])
        self.assertEqual("second", calls[1][1]["text"])
        self.assertIn("reply_markup", calls[1][1])

class TrafficStoreTests(unittest.TestCase):
    class VlessServer:
        id = "vless"
        protocol = "vless"
        is_amneziawg = False
        is_vless = True

    def test_daily_bytes_and_counter_reset_are_recorded(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TrafficStore(Path(tmp))
            server = self.VlessServer()
            first = {
                "clients": [
                    {"name": "alice", "uplink_bytes": 100, "downlink_bytes": 200}
                ]
            }
            second = {
                "clients": [
                    {"name": "alice", "uplink_bytes": 150, "downlink_bytes": 260}
                ]
            }
            reset = {
                "clients": [
                    {"name": "alice", "uplink_bytes": 10, "downlink_bytes": 20}
                ]
            }
            store.capture_server(server, first)
            store.capture_server(server, second)
            store.capture_server(server, reset)
            rows = store.stored_daily_rows("vless")

            self.assertEqual(160, rows[0]["upload_bytes"])
            self.assertEqual(280, rows[0]["download_bytes"])
            self.assertEqual(440, rows[0]["total_bytes"])

    def test_schema_uses_timestamp_and_integer_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TrafficStore(Path(tmp))
            path = store.ensure_user("vless", "vless", "alice")
            db = sqlite3.connect(path)
            columns = {
                row[1]: row[2]
                for row in db.execute("PRAGMA table_info(daily_usage)")
            }
            db.close()

            self.assertEqual("TIMESTAMP", columns["captured_at"])
            self.assertEqual("INTEGER", columns["upload_bytes"])
            self.assertEqual("INTEGER", columns["download_bytes"])
            self.assertEqual("INTEGER", columns["total_bytes"])

    def test_delete_user_removes_database_and_sqlite_sidecars(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TrafficStore(Path(tmp))
            path = store.ensure_user("vless", "vless", "alice")
            sidecars = [Path(f"{path}-wal"), Path(f"{path}-shm"), Path(f"{path}-journal")]
            for sidecar in sidecars:
                sidecar.touch()

            self.assertTrue(store.delete_user("vless", "alice"))
            self.assertFalse(path.exists())
            self.assertTrue(all(not sidecar.exists() for sidecar in sidecars))
            self.assertFalse(store.delete_user("vless", "alice"))

    def test_report_csv_contains_daily_and_monthly_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TrafficStore(Path(tmp))
            server = self.VlessServer()
            data = {
                "clients": [
                    {"name": "alice", "uplink_bytes": 100, "downlink_bytes": 200}
                ]
            }
            daily, monthly = store.report_files(server, data)

            self.assertTrue(daily.startswith(b"\xef\xbb\xbf"))
            self.assertIn(b"upload_mb", daily)
            self.assertIn(b"total_mb", monthly)
            self.assertNotIn(b"upload_bytes", daily)

    def test_user_report_csv_is_filtered_to_selected_user(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TrafficStore(Path(tmp))
            server = self.VlessServer()
            data = {
                "clients": [
                    {"name": "alice", "uplink_bytes": 100, "downlink_bytes": 200},
                    {"name": "bob", "uplink_bytes": 300, "downlink_bytes": 400},
                ]
            }
            daily, monthly = store.user_report_files(server, "alice", data)

            self.assertIn(b"alice", daily)
            self.assertIn(b"alice", monthly)
            self.assertNotIn(b"bob", daily)
            self.assertNotIn(b"bob", monthly)

    def test_chart_series_uses_daily_mb_monthly_gb_and_user_filter(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TrafficStore(Path(tmp))
            store.now = lambda: datetime(2026, 8, 15, 12, 0, tzinfo=timezone.utc)
            server = self.VlessServer()
            data = {
                "clients": [
                    {
                        "name": "alice",
                        "uplink_bytes": 1048576,
                        "downlink_bytes": 2097152,
                    },
                    {
                        "name": "bob",
                        "uplink_bytes": 4194304,
                        "downlink_bytes": 0,
                    },
                ]
            }

            daily, monthly = store.chart_series(server, user_name="alice", data=data)

            self.assertEqual(15, len(daily))
            self.assertEqual(3.0, daily[-1]["value"])
            self.assertTrue(daily[0]["tick"])
            self.assertTrue(daily[4]["tick"])
            self.assertEqual(12, len(monthly))
            self.assertAlmostEqual(3 / 1024, monthly[-1]["value"])

    def test_prune_removes_only_absent_users_when_sources_agree(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TrafficStore(Path(tmp))
            store.ensure_user("vless", "vless", "alice")
            stale = store.ensure_user("vless", "vless", "old-user")

            class Server(self.VlessServer):
                def list_clients(self):
                    return [{"name": "alice"}]

            data = {
                "clients": [
                    {"name": "alice", "uplink_bytes": 0, "downlink_bytes": 0}
                ]
            }

            self.assertEqual(1, store.prune_absent_users(Server(), data))
            self.assertFalse(stale.exists())
            self.assertTrue(store.db_path("vless", "alice").exists())

    def test_prune_is_skipped_when_list_and_counters_disagree(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = TrafficStore(Path(tmp))
            stale = store.ensure_user("vless", "vless", "old-user")

            class Server(self.VlessServer):
                def list_clients(self):
                    return [{"name": "alice"}]

            self.assertEqual(0, store.prune_absent_users(Server(), {"clients": []}))
            self.assertTrue(stale.exists())


class ChannelStoreTests(unittest.TestCase):
    def test_minute_counter_delta_is_stored_in_bytes(self):
        with tempfile.TemporaryDirectory() as tmp:
            class Store(ChannelStore):
                current = {
                    "rx_bytes": 1000,
                    "tx_bytes": 2000,
                    "rx_packets": 10,
                    "tx_packets": 20,
                    "rx_errors": 0,
                    "tx_errors": 0,
                    "rx_dropped": 0,
                    "tx_dropped": 0,
                }

                def detect_interface(self):
                    return "eth0"

                @staticmethod
                def boot_id():
                    return "boot-test"

                def read_counters(self, _interface):
                    return dict(self.current)

            store = Store(Path(tmp) / "metrics.sqlite3")
            first = store.capture(epoch=1_800_000_000)
            store.current.update(
                rx_bytes=7000,
                tx_bytes=5000,
                rx_packets=70,
                tx_packets=50,
            )
            second = store.capture(epoch=1_800_000_060)

            self.assertEqual("baseline", first["status"])
            self.assertEqual("captured", second["status"])
            self.assertEqual(6000, second["rx_bytes"])
            self.assertEqual(3000, second["tx_bytes"])
            db = sqlite3.connect(store.path)
            row = db.execute(
                "SELECT interval_seconds, rx_bytes, tx_bytes FROM network_samples"
            ).fetchone()
            db.close()
            self.assertEqual((60.0, 6000, 3000), row)
            self.assertEqual(0, store.path.stat().st_mode & 0o077)

    def test_counter_reset_creates_new_baseline(self):
        with tempfile.TemporaryDirectory() as tmp:
            class Store(ChannelStore):
                value = 100

                def detect_interface(self):
                    return "eth0"

                @staticmethod
                def boot_id():
                    return "boot-test"

                def read_counters(self, _interface):
                    return {
                        key: self.value for key in (
                            "rx_bytes", "tx_bytes", "rx_packets", "tx_packets",
                            "rx_errors", "tx_errors", "rx_dropped", "tx_dropped"
                        )
                    }

            store = Store(Path(tmp) / "metrics.sqlite3")
            store.capture(epoch=1_800_000_000)
            store.value = 10
            result = store.capture(epoch=1_800_000_060)
            self.assertEqual("baseline", result["status"])

    def test_vacuum_reclaims_pages_after_retention_delete(self):
        with tempfile.TemporaryDirectory() as tmp:
            store = ChannelStore(Path(tmp) / "metrics.sqlite3")
            db = sqlite3.connect(store.path)
            rows = [
                (
                    f"2025-01-{(index % 28) + 1:02d} {index % 24:02d}:{index % 60:02d}:{index % 60:02d}",
                    "eth0",
                    60.0,
                    index,
                    index,
                    index,
                    index,
                    0,
                    0,
                    0,
                    0,
                )
                for index in range(5000)
            ]
            db.executemany(
                "INSERT OR REPLACE INTO network_samples VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                rows,
            )
            db.commit()
            db.execute("DELETE FROM network_samples")
            db.commit()
            free_before = db.execute("PRAGMA freelist_count").fetchone()[0]
            db.close()

            result = store.maintain(epoch=1_800_000_000, force_vacuum=True)

            db = sqlite3.connect(store.path)
            free_after = db.execute("PRAGMA freelist_count").fetchone()[0]
            db.close()
            self.assertGreater(free_before, 0)
            self.assertEqual(0, free_after)
            self.assertTrue(result["vacuumed"])


if __name__ == "__main__":
    unittest.main()
