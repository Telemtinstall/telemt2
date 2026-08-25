#!/usr/bin/env python3
import importlib.util
import io
import pathlib
import tempfile
import urllib.error

project = pathlib.Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("collector", project / "analytics" / "collector.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class Response:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return b'{"country":"US","city":"Mountain View","region":"California","org":"AS15169 Google LLC"}'


with tempfile.TemporaryDirectory() as directory:
    module.DB = str(pathlib.Path(directory) / "analytics.sqlite3")
    db = module.connect()

    module.ipinfo_token = lambda: ""
    module.prepare_token_state(db)
    assert module.runtime_geo_state(db) == {
        "enabled": False, "status": "disabled", "error": "", "city_available": None
    }

    module.ipinfo_token = lambda: "valid_token_123"
    module.prepare_token_state(db)
    db.execute("INSERT INTO geo(remote) VALUES('8.8.8.8')")
    db.commit()
    module.urllib.request.urlopen = lambda *args, **kwargs: Response()
    module.enrich_one(db)
    state = module.runtime_geo_state(db)
    assert state["status"] == "active" and state["city_available"] is True

    module.ipinfo_token = lambda: "revoked_token_123"
    module.prepare_token_state(db)
    db.execute("INSERT OR REPLACE INTO geo(remote,status,next_lookup) VALUES('1.1.1.1','pending',0)")
    db.execute("UPDATE geo SET next_lookup=9999999999 WHERE remote='8.8.8.8'")
    db.commit()

    def rejected(*args, **kwargs):
        raise urllib.error.HTTPError("https://ipinfo.io", 401, "Unauthorized", {}, io.BytesIO())

    module.urllib.request.urlopen = rejected
    module.check_token_health(db)
    state = module.runtime_geo_state(db)
    assert state["status"] == "invalid"
    assert state["error"] == "IPinfo отклонил токен (HTTP 401). Укажите другой токен."
    db.close()

print("OK: collector geolocation state tests passed")
