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
    payload = b'{"country":"US","city":"Mountain View","region":"California","org":"AS15169 Google LLC"}'

    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def read(self):
        return self.payload


class IpinfoWithoutCityResponse(Response):
    payload = b'{"country":"US","org":"AS13335 Cloudflare, Inc."}'


class IpwhoCityResponse(Response):
    payload = b'{"success":true,"country":"United States","country_code":"US","region":"California","city":"Los Angeles"}'


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
    geo = db.execute("SELECT asn,provider FROM geo WHERE remote='8.8.8.8'").fetchone()
    assert geo == ("AS15169", "Google LLC")

    requested = []
    db.execute("INSERT OR REPLACE INTO geo(remote,status,next_lookup) VALUES('1.1.1.1','pending',0)")
    db.execute("UPDATE geo SET next_lookup=9999999999 WHERE remote='8.8.8.8'")
    db.commit()

    def without_paid_city(request, **kwargs):
        requested.append(request.full_url)
        if request.full_url.startswith(module.IPWHO_API):
            return IpwhoCityResponse()
        return IpinfoWithoutCityResponse()

    module.urllib.request.urlopen = without_paid_city
    module.enrich_one(db)
    geo = db.execute("SELECT country_code,city_name,region_name,asn,provider,status FROM geo WHERE remote='1.1.1.1'").fetchone()
    assert geo == ("US", "Los Angeles", "California", "AS13335", "Cloudflare, Inc.", "ok")
    assert any(url.startswith("https://ipinfo.io/") for url in requested)
    assert any(url.startswith("https://ipwho.is/") for url in requested)
    assert module.state_value(db, "ipwho_usage_count") == "1"

    module.ipinfo_token = lambda: "revoked_token_123"
    module.prepare_token_state(db)
    db.execute("INSERT OR REPLACE INTO geo(remote,status,next_lookup) VALUES('9.9.9.9','pending',0)")
    db.execute("UPDATE geo SET next_lookup=9999999999 WHERE remote IN ('8.8.8.8','1.1.1.1')")
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
