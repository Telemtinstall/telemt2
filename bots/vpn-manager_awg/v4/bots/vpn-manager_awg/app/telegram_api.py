import base64
import json
import logging
import urllib.error
import urllib.parse
import urllib.request
import uuid
import time
import socket
import ssl
import http.client
import math

from app.formatters import split_text


log = logging.getLogger("vpnbot.telegram")


class TelegramTemporaryError(RuntimeError):
    """Retry budget exhausted; keep transport details out of customer messages."""


class TelegramAPI:
    def __init__(self, settings):
        self.callback_store = None
        self.settings = settings
        self.api_base = f"https://api.telegram.org/bot{settings.token}/"
        self._bot_username: str | None = None

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

        attempts = 2 if method == 'answerCallbackQuery' else 6
        for attempt in range(attempts):
            delay = min(2 ** attempt, 8)
            reason = 'network'
            try:
                with urllib.request.urlopen(req, timeout=self.settings.request_timeout) as resp:
                    payload = resp.read().decode('utf-8')
                result = json.loads(payload)
                if result.get('ok'):
                    return result
                code = result.get('error_code')
                if code not in {429, 500, 502, 503, 504}:
                    raise RuntimeError(f'Telegram API error: {result}')
                reason = 'HTTP ' + str(code)
                if code == 429:
                    delay = self.retry_delay(result)
            except urllib.error.HTTPError as exc:
                try:
                    body = exc.read().decode('utf-8', errors='replace')
                finally:
                    exc.close()
                if exc.code not in {429, 500, 502, 503, 504}:
                    raise RuntimeError(f'Telegram HTTP {exc.code}: {body}') from None
                reason = 'HTTP ' + str(exc.code)
                if exc.code == 429:
                    try:
                        result = json.loads(body)
                    except ValueError:
                        result = {}
                    delay = self.retry_delay(result)
            except (urllib.error.URLError, ConnectionError, TimeoutError, socket.gaierror,
                    ssl.SSLError, http.client.HTTPException) as exc:
                # A broken trust chain is not a transient connection problem.
                cause = exc.reason if isinstance(exc, urllib.error.URLError) else exc
                if isinstance(cause, ssl.SSLCertVerificationError):
                    raise RuntimeError('Не удалось проверить сертификат Telegram') from None
                reason = type(cause).__name__
            except (json.JSONDecodeError, UnicodeDecodeError):
                reason = 'invalid response'
            # Do not log request URLs/tokens, chat IDs, captions, keys or file data.
            if attempt + 1 == attempts or delay is None:
                log.warning('Telegram %s delivery unavailable after %s attempt(s): %s', method, attempt + 1, reason)
                raise TelegramTemporaryError('Telegram временно недоступен') from None
            log.warning('Telegram %s temporary failure (%s), retry %s/%s in %ss',
                        method, reason, attempt + 2, attempts, delay)
            time.sleep(delay)

    @staticmethod
    def retry_delay(result):
        parameters = result.get('parameters')
        value = parameters.get('retry_after', 1) if isinstance(parameters, dict) else 1
        try:
            value = float(value)
        except (TypeError, ValueError):
            return 1
        # Never retry before Telegram's deadline; do not block a chat for minutes.
        return value if math.isfinite(value) and 0 <= value <= 60 else None

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
                data["reply_markup"] = reply_markup(self.callback_store.markup(chat_id, markup) if self.callback_store else markup)
            self.call("sendMessage", data)

    def edit_message(self, chat_id: int, message_id: int, text: str, markup: dict | None = None) -> None:
        parts = split_text(text, self.settings.max_message)
        data = {
            "chat_id": chat_id,
            "message_id": message_id,
            "text": parts[0],
            "parse_mode": "HTML",
            "disable_web_page_preview": "true",
        }
        if len(parts) == 1 and markup:
            data["reply_markup"] = reply_markup(self.callback_store.markup(chat_id, markup) if self.callback_store else markup)
        try:
            self.call("editMessageText", data)
        except RuntimeError as exc:
            if "message is not modified" not in str(exc):
                raise
        for index, part in enumerate(parts[1:], start=1):
            part_markup = markup if index == len(parts) - 1 else None
            self.send_message(chat_id, part, part_markup)

    def answer_callback(self, callback_id: str, text: str = "", show_alert: bool = False) -> None:
        data = {"callback_query_id": callback_id, "show_alert": "true" if show_alert else "false"}
        if text:
            data["text"] = text[:200]
        try:
            self.call("answerCallbackQuery", data)
        except TelegramTemporaryError:
            # A lost acknowledgement must not cancel the requested operation.
            log.warning('Telegram callback acknowledgement unavailable; continuing action')
        except RuntimeError as exc:
            message = str(exc).lower()
            if 'query is too old' not in message and 'query id is invalid' not in message and 'query_id_invalid' not in message:
                raise


    def send_qr(self, chat_id: int, name: str, qr_base64: str, caption: str) -> None:
        image = base64.b64decode(qr_base64)
        self.send_photo(chat_id, f"{name}.png", image, caption)

    def send_photo(self, chat_id: int, filename: str, image: bytes, caption: str) -> None:
        self.call(
            "sendPhoto",
            {"chat_id": chat_id, "caption": split_text(caption, 1024)[0], "parse_mode": "HTML"},
            {"photo": (filename, image, "image/png")},
        )

    def send_config_file(
        self,
        chat_id: int,
        name: str,
        config: str,
        caption: str | None = None,
    ) -> None:
        self.send_document(
            chat_id,
            f"{name}.conf",
            config.encode("utf-8"),
            caption or f"{name}.conf",
            "text/plain",
        )

    def send_document(
        self,
        chat_id: int,
        filename: str,
        content: bytes,
        caption: str,
        mime: str = "application/octet-stream",
    ) -> None:
        self.call(
            "sendDocument",
            {"chat_id": chat_id, "caption": caption[:1024]},
            {"document": (filename, content, mime)},
        )

    def get_updates(self, offset: int | None) -> list[dict]:
        data = {
            "timeout": self.settings.poll_timeout,
            "allowed_updates": json.dumps(["message", "callback_query"]),
        }
        if offset is not None:
            data["offset"] = offset
        return self.call("getUpdates", data).get("result", [])

    def get_bot_username(self) -> str:
        if not self._bot_username:
            username = str((self.call("getMe").get("result") or {}).get("username") or "")
            if not username:
                raise RuntimeError("Telegram не вернул username бота")
            self._bot_username = username
        return self._bot_username

    def set_bot_commands(self) -> None:
        user_commands = [
            {"command": "start", "description": "Мои VPN"},
        ]
        admin_commands = [
            {"command": "start", "description": "Главное меню"},
            {"command": "create", "description": "Создать клиента"},
            {"command": "list", "description": "Список клиентов"},
            {"command": "online", "description": "Кто онлайн"},
            {"command": "traffic", "description": "Трафик"},
            {"command": "cancel", "description": "Отмена"},
        ]
        user_commands_json = json.dumps(user_commands, ensure_ascii=False)
        admin_commands_json = json.dumps(admin_commands, ensure_ascii=False)
        self.call("setMyCommands", {"commands": user_commands_json})
        self.call(
            "setMyCommands",
            {
                "commands": user_commands_json,
                "scope": json.dumps({"type": "all_private_chats"}),
            },
        )
        self.call("setChatMenuButton", {"menu_button": json.dumps({"type": "commands"})})

        for user_id in self.settings.allowed_users:
            self._set_private_chat_commands(user_id, admin_commands_json)

    def set_admin_commands(self, user_id: str) -> None:
        commands = [
            {"command": "start", "description": "Главное меню"},
            {"command": "create", "description": "Создать клиента"},
            {"command": "list", "description": "Список клиентов"},
            {"command": "online", "description": "Кто онлайн"},
            {"command": "traffic", "description": "Трафик"},
            {"command": "cancel", "description": "Отмена"},
        ]
        self._set_private_chat_commands(
            str(user_id),
            json.dumps(commands, ensure_ascii=False),
        )

    def set_user_commands(self, user_id: str) -> None:
        commands = [{"command": "start", "description": "Мои VPN"}]
        self._set_private_chat_commands(
            str(user_id),
            json.dumps(commands, ensure_ascii=False),
        )

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
    boundary = "----vpnbot-" + uuid.uuid4().hex
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
