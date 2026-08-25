#!/usr/bin/env python3
import json
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LISTEN = ("127.0.0.1", 8083)
TOKEN_FILE = Path("/etc/webproxy-analytics/ipinfo.token")
DOMAIN_FILE = Path("/etc/webproxy-analytics/domain")
TOKEN_RE = re.compile(r"^[A-Za-z0-9._-]{8,256}$")


def domain():
    return DOMAIN_FILE.read_text(encoding="utf-8").strip().lower()


def validate_token(token):
    url = "https://ipinfo.io/8.8.8.8/json?token=" + urllib.parse.quote(token, safe="")
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "WebProxyTelegram/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            payload = json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        if exc.code in (401, 403):
            raise ValueError(f"IPinfo отклонил токен (HTTP {exc.code}). Укажите другой токен.") from None
        if exc.code == 429:
            raise ValueError("IPinfo сообщил о превышении лимита (HTTP 429). Проверьте тариф или укажите другой токен.") from None
        raise ValueError(f"IPinfo временно вернул ошибку HTTP {exc.code}. Попробуйте ещё раз.") from None
    except (OSError, ValueError, json.JSONDecodeError):
        raise ValueError("Не удалось проверить токен через IPinfo. Проверьте соединение и повторите.") from None
    geo = payload.get("geo") if isinstance(payload.get("geo"), dict) else payload
    country = str(geo.get("country_code") or geo.get("country") or "")
    if not country:
        raise ValueError("IPinfo принял запрос, но не вернул страну. Проверьте токен и его тариф.")
    return {"country": country, "city_available": bool(geo.get("city"))}


def save_token(token):
    TOKEN_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="ipinfo.token.", dir=TOKEN_FILE.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(token)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        if os.geteuid() == 0:
            os.chown(temporary, 0, 0)
        os.replace(temporary, TOKEN_FILE)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


class Handler(BaseHTTPRequestHandler):
    server_version = "WebProxyTelegramTokenAdmin/1"

    def log_message(self, *_):
        return

    def reply(self, status, payload):
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def valid_origin(self):
        expected = "https://" + domain()
        return self.headers.get("Origin", "").rstrip("/").lower() == expected

    def do_GET(self):
        if self.path != "/status":
            self.reply(404, {"ok": False, "error": "not_found"})
            return
        self.reply(200, {"ok": True, "configured": TOKEN_FILE.is_file() and bool(TOKEN_FILE.read_text().strip())})

    def do_POST(self):
        if self.path != "/token":
            self.reply(404, {"ok": False, "error": "not_found"})
            return
        if not self.valid_origin():
            self.reply(403, {"ok": False, "error": "Запрос отклонён: неверный Origin."})
            return
        if self.headers.get_content_type() != "application/json":
            self.reply(415, {"ok": False, "error": "Ожидается application/json."})
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            length = 0
        if length < 2 or length > 1024:
            self.reply(400, {"ok": False, "error": "Некорректный размер запроса."})
            return
        try:
            payload = json.loads(self.rfile.read(length))
            token = str(payload.get("token") or "").strip()
        except (ValueError, AttributeError, json.JSONDecodeError):
            self.reply(400, {"ok": False, "error": "Некорректный JSON."})
            return
        if not TOKEN_RE.fullmatch(token):
            self.reply(400, {"ok": False, "error": "Токен содержит недопустимые символы или слишком короткий."})
            return
        try:
            result = validate_token(token)
            save_token(token)
            subprocess.run(["systemctl", "restart", "webproxy-analytics.service"], check=True, timeout=20,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except ValueError as exc:
            self.reply(422, {"ok": False, "error": str(exc)})
            return
        except (OSError, subprocess.SubprocessError):
            self.reply(500, {"ok": False, "error": "Токен сохранён, но сервис аналитики не перезапустился."})
            return
        message = "Токен принят. География обновляется."
        if not result["city_available"]:
            message += " IPinfo не возвращает города; они будут дополнены через ipwho.is."
        self.reply(200, {"ok": True, "message": message, "city_available": True,
                         "ipinfo_city_available": result["city_available"]})


def main():
    server = ThreadingHTTPServer(LISTEN, Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
