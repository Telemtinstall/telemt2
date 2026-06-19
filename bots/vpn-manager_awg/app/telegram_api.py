import base64
import json
import logging
import urllib.error
import urllib.parse
import urllib.request
import uuid

from app.formatters import split_text


log = logging.getLogger("vpnbotawg.telegram")


class TelegramAPI:
    def __init__(self, settings):
        self.settings = settings
        self.api_base = f"https://api.telegram.org/bot{settings.token}/"

    def call(self, method: str, data: dict | None = None, files: dict | None = None) -> dict:
        url = self.api_base + method
        if files:
            body, content_type = encode_multipart(data or {}, files)
            req = urllib.request.Request(
                url,
                data=body,
                headers={"Content-Type": content_type},
                method="POST",
            )
        else:
            encoded = urllib.parse.urlencode(data or {}).encode()
            req = urllib.request.Request(url, data=encoded, method="POST")

        try:
            with urllib.request.urlopen(req, timeout=self.settings.request_timeout) as resp:
                payload = resp.read().decode("utf-8")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"Telegram HTTP {exc.code}: {body}") from exc
        except urllib.error.URLError as exc:
            raise RuntimeError(f"Telegram network error: {exc}") from exc

        result = json.loads(payload)
        if not result.get("ok"):
            raise RuntimeError(f"Telegram API error: {result}")
        return result

    def send_message(self, chat_id: int, text: str, markup: dict | None = None) -> None:
        parts = split_text(text, self.settings.max_message)
        for index, part in enumerate(parts):
            data = {
                "chat_id": chat_id,
                "text": part,
                "parse_mode": "HTML",
                "disable_web_page_preview": "true",
            }
            if index == len(parts) - 1 and markup:
                data["reply_markup"] = reply_markup(markup)
            self.call("sendMessage", data)

    def edit_message(self, chat_id: int, message_id: int, text: str, markup: dict | None = None) -> None:
        data = {
            "chat_id": chat_id,
            "message_id": message_id,
            "text": text[: self.settings.max_message],
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }
        if markup:
            data["reply_markup"] = reply_markup(markup)
        try:
            self.call("editMessageText", data)
        except RuntimeError as exc:
            if "message is not modified" not in str(exc):
                raise

    def answer_callback(self, callback_id: str, text: str = "", show_alert: bool = False) -> None:
        data = {"callback_query_id": callback_id, "show_alert": "true" if show_alert else "false"}
        if text:
            data["text"] = text[:200]
        self.call("answerCallbackQuery", data)

    def send_qr(self, chat_id: int, name: str, qr_base64: str, caption: str) -> None:
        image = base64.b64decode(qr_base64)
        self.call(
            "sendPhoto",
            {"chat_id": chat_id, "caption": caption[:1024], "parse_mode": "HTML"},
            {"photo": (f"{name}.png", image, "image/png")},
        )

    def send_config_file(self, chat_id: int, name: str, config: str) -> None:
        self.call(
            "sendDocument",
            {"chat_id": chat_id, "caption": f"{name}.conf"},
            {"document": (f"{name}.conf", config.encode("utf-8"), "text/plain")},
        )

    def get_updates(self, offset: int | None) -> list[dict]:
        data = {
            "timeout": self.settings.poll_timeout,
            "allowed_updates": json.dumps(["message", "callback_query"]),
        }
        if offset is not None:
            data["offset"] = offset
        return self.call("getUpdates", data).get("result", [])

    def set_bot_commands(self) -> None:
        commands = [
            {"command": "start", "description": "Главное меню"},
            {"command": "create", "description": "Создать клиента"},
            {"command": "list", "description": "Список клиентов"},
            {"command": "online", "description": "Кто онлайн"},
            {"command": "traffic", "description": "Трафик"},
            {"command": "cancel", "description": "Отмена"},
        ]
        commands_json = json.dumps(commands, ensure_ascii=False)
        self.call("setMyCommands", {"commands": commands_json})
        self.call(
            "setMyCommands",
            {
                "commands": commands_json,
                "scope": json.dumps({"type": "all_private_chats"}),
            },
        )
        self.call("setChatMenuButton", {"menu_button": json.dumps({"type": "commands"})})

        for user_id in self.settings.allowed_users:
            self._set_private_chat_commands(user_id, commands_json)

    def _set_private_chat_commands(self, user_id: str, commands_json: str) -> None:
        try:
            chat_id = int(user_id)
        except ValueError:
            return

        try:
            self.call(
                "setMyCommands",
                {
                    "commands": commands_json,
                    "scope": json.dumps({"type": "chat", "chat_id": chat_id}),
                },
            )
            self.call(
                "setChatMenuButton",
                {
                    "chat_id": chat_id,
                    "menu_button": json.dumps({"type": "commands"}),
                },
            )
        except Exception as exc:
            log.warning("could not set private command menu for %s: %s", user_id, exc)


def reply_markup(markup: dict | None) -> str | None:
    if markup is None:
        return None
    return json.dumps(markup, ensure_ascii=False, separators=(",", ":"))


def encode_multipart(fields: dict, files: dict) -> tuple[bytes, str]:
    boundary = "----vpnbotawg-" + uuid.uuid4().hex
    chunks: list[bytes] = []

    for name, value in fields.items():
        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode())
        chunks.append(str(value).encode("utf-8"))
        chunks.append(b"\r\n")

    for name, file_info in files.items():
        filename, content, mime = file_info
        chunks.append(f"--{boundary}\r\n".encode())
        chunks.append(
            (
                f'Content-Disposition: form-data; name="{name}"; '
                f'filename="{filename}"\r\n'
                f"Content-Type: {mime}\r\n\r\n"
            ).encode()
        )
        chunks.append(content)
        chunks.append(b"\r\n")

    chunks.append(f"--{boundary}--\r\n".encode())
    return b"".join(chunks), f"multipart/form-data; boundary={boundary}"

