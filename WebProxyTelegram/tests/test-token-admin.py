#!/usr/bin/env python3
import http.client
import importlib.util
import json
import os
import pathlib
import threading
import tempfile

project = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("token_admin", project / "analytics" / "token_admin.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Completed:
    returncode = 0


with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    module.TOKEN_FILE = root / "ipinfo.token"
    module.DOMAIN_FILE = root / "domain"
    module.DOMAIN_FILE.write_text("proxy.example.com\n")
    module.subprocess.run = lambda *args, **kwargs: Completed()
    module.validate_token = lambda token: {"country": "US", "city_available": True}
    server = module.ThreadingHTTPServer(("127.0.0.1", 0), module.Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)

    body = json.dumps({"token": "valid_token_123"})
    connection.request("POST", "/token", body, {"Content-Type": "application/json"})
    response = connection.getresponse()
    assert response.status == 403
    response.read()

    connection.request("POST", "/token", json.dumps({"token": "short"}),
                       {"Content-Type": "application/json", "Origin": "https://proxy.example.com"})
    response = connection.getresponse()
    assert response.status == 400
    response.read()

    connection.request("POST", "/token", body,
                       {"Content-Type": "application/json", "Origin": "https://proxy.example.com"})
    response = connection.getresponse()
    payload = json.loads(response.read())
    assert response.status == 200 and payload["ok"] is True
    assert payload["city_available"] is True
    assert "valid_token_123" not in json.dumps(payload)
    assert module.TOKEN_FILE.read_text() == "valid_token_123"
    assert os.stat(module.TOKEN_FILE).st_mode & 0o777 == 0o600

    module.validate_token = lambda token: {"country": "US", "city_available": False}
    connection.request("POST", "/token", json.dumps({"token": "fallback_token_123"}),
                       {"Content-Type": "application/json", "Origin": "https://proxy.example.com"})
    response = connection.getresponse()
    payload = json.loads(response.read())
    assert response.status == 200 and payload["city_available"] is True
    assert payload["ipinfo_city_available"] is False and "ipwho.is" in payload["message"]
    assert module.TOKEN_FILE.read_text() == "fallback_token_123"

    connection.request("GET", "/status")
    response = connection.getresponse()
    payload = json.loads(response.read())
    assert response.status == 200 and payload == {"ok": True, "configured": True}

    module.validate_token = lambda token: (_ for _ in ()).throw(ValueError("IPinfo отклонил токен (HTTP 401). Укажите другой токен."))
    connection.request("POST", "/token", json.dumps({"token": "another_token_123"}),
                       {"Content-Type": "application/json", "Origin": "https://proxy.example.com"})
    response = connection.getresponse()
    payload = json.loads(response.read())
    assert response.status == 422 and "HTTP 401" in payload["error"]
    assert module.TOKEN_FILE.read_text() == "fallback_token_123"

    connection.close()
    server.shutdown()
    server.server_close()

print("OK: token admin security tests passed")
