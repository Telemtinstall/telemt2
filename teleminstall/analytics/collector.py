#!/usr/bin/env python3
import hashlib
import ipaddress
import json
import os
import signal
import sqlite3
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone

DB = "/var/lib/webproxy-analytics/analytics.sqlite3"
OUTPUT = "/var/lib/webproxy-analytics/data.json"
LOG = "/var/log/tproxy/access.log"
METRICS = "http://127.0.0.1:8081/metrics"
IPINFO_TOKEN_FILE = "/run/credentials/webproxy-analytics.service/ipinfo_token"
WINDOWS = {"15m": 900, "1h": 3600, "24h": 86400, "7d": 604800}
ENDPOINTS = {"/api/v1/session", "/api/v1/up", "/api/v1/down", "/api/v1/ws"}
SCHEMA_VERSION = "2"
running = True


def stop(*_):
    global running
    running = False


def ipinfo_token():
    try:
        return open(IPINFO_TOKEN_FILE, encoding="utf-8").read().strip()
    except OSError:
        return ""


def connect():
    db = sqlite3.connect(DB, timeout=10)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript("""
      CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS seen_events(hash TEXT PRIMARY KEY,occurred INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS minute_stats(
        bucket INTEGER NOT NULL,endpoint TEXT NOT NULL,class TEXT NOT NULL,reason TEXT NOT NULL,status INTEGER NOT NULL,
        requests INTEGER NOT NULL DEFAULT 0,request_bytes INTEGER NOT NULL DEFAULT 0,response_bytes INTEGER NOT NULL DEFAULT 0,
        total_ms INTEGER NOT NULL DEFAULT 0,max_ms INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(bucket,endpoint,class,reason,status));
      CREATE TABLE IF NOT EXISTS ip_minute_stats(
        bucket INTEGER NOT NULL,remote TEXT NOT NULL,class TEXT NOT NULL,
        requests INTEGER NOT NULL DEFAULT 0,request_bytes INTEGER NOT NULL DEFAULT 0,response_bytes INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(bucket,remote,class));
      CREATE INDEX IF NOT EXISTS ip_stats_time ON ip_minute_stats(bucket);
      CREATE INDEX IF NOT EXISTS ip_stats_remote ON ip_minute_stats(remote,bucket);
      CREATE TABLE IF NOT EXISTS geo(
        remote TEXT PRIMARY KEY,country_code TEXT NOT NULL DEFAULT 'ZZ',country_name TEXT NOT NULL DEFAULT 'Неизвестно',
        region_name TEXT NOT NULL DEFAULT '',city_name TEXT NOT NULL DEFAULT '',asn TEXT NOT NULL DEFAULT '',
        provider TEXT NOT NULL DEFAULT '',status TEXT NOT NULL DEFAULT 'pending',updated INTEGER NOT NULL DEFAULT 0,
        next_lookup INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS geo_lookup ON geo(status,next_lookup);
      CREATE TABLE IF NOT EXISTS errors(
        hash TEXT PRIMARY KEY,occurred INTEGER NOT NULL,remote TEXT NOT NULL,endpoint TEXT NOT NULL,method TEXT NOT NULL,
        status INTEGER NOT NULL,reason TEXT NOT NULL,request_bytes INTEGER NOT NULL,response_bytes INTEGER NOT NULL,request_ms INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS errors_time ON errors(occurred);
      CREATE TABLE IF NOT EXISTS metrics(
        occurred INTEGER PRIMARY KEY,sessions_live INTEGER,streams_live INTEGER,backend_dials_in_flight INTEGER,
        pending_bytes INTEGER,pending_items INTEGER,sessions_created_total INTEGER,sessions_closed_total INTEGER,
        streams_opened_total INTEGER,streams_rejected_total INTEGER,backend_dial_failures_total INTEGER,
        bytes_up_total INTEGER,bytes_down_total INTEGER,limit_hits_total INTEGER);
    """)
    version = db.execute("SELECT value FROM state WHERE key='schema_version'").fetchone()
    if not version or version[0] != SCHEMA_VERSION:
        # Re-read the current transport log once so older events receive IP aggregates.
        db.executescript("DELETE FROM seen_events; DELETE FROM minute_stats; DELETE FROM ip_minute_stats; DELETE FROM errors; DELETE FROM state WHERE key='log_position';")
        db.execute("INSERT INTO state(key,value) VALUES('schema_version',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", (SCHEMA_VERSION,))
        db.commit()
    return db


def classify(endpoint, method, status):
    expected = {
        ("/api/v1/session", "POST"): {200}, ("/api/v1/session", "DELETE"): {204},
        ("/api/v1/up", "POST"): {204}, ("/api/v1/down", "POST"): {200, 204, 499},
        ("/api/v1/ws", "GET"): {101},
    }
    if status in expected.get((endpoint, method), set()):
        if endpoint == "/api/v1/session":
            return "good", "session_created" if method == "POST" else "session_closed"
        if status == 499:
            return "good", "poll_replaced"
        return "good", "request_ok"
    if status == 503:
        return "failed", "capacity_or_backpressure"
    if status == 404:
        return "failed", "rejected_request"
    if status >= 500:
        return "failed", "server_error"
    return "failed", "unexpected_status"


def event_from_line(raw, identity):
    item = json.loads(raw)
    endpoint = str(item.get("endpoint", ""))
    if endpoint not in ENDPOINTS:
        return None
    method = str(item.get("method", ""))[:8]
    status = int(item.get("status", 0))
    stamp = int(datetime.fromisoformat(str(item["time"])).timestamp())
    class_name, reason = classify(endpoint, method, status)
    return {
        "hash": hashlib.sha256((identity + raw.rstrip()).encode()).hexdigest(), "occurred": stamp,
        "bucket": stamp - stamp % 60, "remote": str(item.get("remote_addr") or "unknown")[:45],
        "endpoint": endpoint, "method": method, "status": status, "class": class_name, "reason": reason,
        "request_bytes": max(0, int(item.get("request_bytes", 0))),
        "response_bytes": max(0, int(item.get("response_bytes", 0))),
        "request_ms": max(0, int(round(float(item.get("request_time", 0)) * 1000))),
    }


def import_log(db):
    if not os.path.isfile(LOG):
        return
    stat = os.stat(LOG)
    row = db.execute("SELECT value FROM state WHERE key='log_position'").fetchone()
    inode, offset = stat.st_ino, 0
    if row:
        try:
            old_inode, old_offset = map(int, row[0].split(":", 1))
            if old_inode == inode and old_offset <= stat.st_size:
                offset = old_offset
        except ValueError:
            pass
    with open(LOG, encoding="utf-8", errors="replace") as stream:
        stream.seek(offset)
        while True:
            line_offset = stream.tell()
            raw = stream.readline()
            if not raw:
                break
            try:
                event = event_from_line(raw, f"{inode}:{line_offset}:")
                if not event:
                    continue
                inserted = db.execute("INSERT OR IGNORE INTO seen_events(hash,occurred) VALUES(?,?)",
                                      (event["hash"], event["occurred"])).rowcount
                if not inserted:
                    continue
                db.execute("INSERT OR IGNORE INTO geo(remote) VALUES(?)", (event["remote"],))
                db.execute("""INSERT INTO minute_stats
                  (bucket,endpoint,class,reason,status,requests,request_bytes,response_bytes,total_ms,max_ms)
                  VALUES(?,?,?,?,?,1,?,?,?,?) ON CONFLICT(bucket,endpoint,class,reason,status) DO UPDATE SET
                  requests=requests+1,request_bytes=request_bytes+excluded.request_bytes,
                  response_bytes=response_bytes+excluded.response_bytes,total_ms=total_ms+excluded.total_ms,
                  max_ms=MAX(max_ms,excluded.max_ms)""",
                  (event["bucket"], event["endpoint"], event["class"], event["reason"], event["status"],
                   event["request_bytes"], event["response_bytes"], event["request_ms"], event["request_ms"]))
                db.execute("""INSERT INTO ip_minute_stats
                  (bucket,remote,class,requests,request_bytes,response_bytes) VALUES(?,?,?,1,?,?)
                  ON CONFLICT(bucket,remote,class) DO UPDATE SET requests=requests+1,
                  request_bytes=request_bytes+excluded.request_bytes,response_bytes=response_bytes+excluded.response_bytes""",
                  (event["bucket"], event["remote"], event["class"], event["request_bytes"], event["response_bytes"]))
                if event["class"] == "failed":
                    db.execute("""INSERT OR IGNORE INTO errors
                      (hash,occurred,remote,endpoint,method,status,reason,request_bytes,response_bytes,request_ms)
                      VALUES(?,?,?,?,?,?,?,?,?,?)""",
                      (event["hash"], event["occurred"], event["remote"], event["endpoint"], event["method"],
                       event["status"], event["reason"], event["request_bytes"], event["response_bytes"], event["request_ms"]))
            except Exception as exc:
                print(json.dumps({"event": "parse_error", "error": str(exc)}), flush=True)
        offset = stream.tell()
    db.execute("INSERT INTO state(key,value) VALUES('log_position',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
               (f"{inode}:{offset}",))
    db.commit()


def enrich_one(db):
    token = ipinfo_token()
    if not token:
        return
    now = int(time.time())
    row = db.execute("SELECT remote FROM geo WHERE next_lookup<=? AND status IN ('pending','retry') ORDER BY next_lookup,remote LIMIT 1", (now,)).fetchone()
    if not row:
        return
    remote = row[0]
    try:
        address = ipaddress.ip_address(remote)
        if not address.is_global:
            db.execute("""UPDATE geo SET country_code='LO',country_name='Локальная сеть',city_name='Локальный адрес',
              provider='Внутренний адрес',status='ok',updated=?,next_lookup=? WHERE remote=?""", (now, now + 15552000, remote))
            db.commit()
            return
    except ValueError:
        db.execute("UPDATE geo SET status='retry',updated=?,next_lookup=? WHERE remote=?", (now, now + 604800, remote))
        db.commit()
        return
    url = "https://ipinfo.io/" + urllib.parse.quote(remote, safe="") + "/json?token=" + urllib.parse.quote(token, safe="")
    request = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": "Teleminstall-WEB-Proxy/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=8) as response:
            payload = json.loads(response.read().decode())
        geo_payload = payload.get("geo") if isinstance(payload.get("geo"), dict) else payload
        as_payload = payload.get("as") if isinstance(payload.get("as"), dict) else payload.get("asn")
        if not isinstance(as_payload, dict):
            as_payload = {}
        country_code = str(geo_payload.get("country_code") or "")
        country_value = str(geo_payload.get("country") or "")
        if not country_code and len(country_value) == 2:
            country_code = country_value.upper()
        country_name = country_value if len(country_value) > 2 else country_code
        if not country_code:
            raise RuntimeError("country is absent in IPinfo response")
        asn = str(as_payload.get("asn") or "")
        provider = str(as_payload.get("name") or as_payload.get("organization") or "")
        db.execute("""UPDATE geo SET country_code=?,country_name=?,region_name=?,city_name=?,asn=?,provider=?,
          status='ok',updated=?,next_lookup=? WHERE remote=?""",
          (country_code[:2], country_name[:96], str(geo_payload.get("region") or "")[:128],
           str(geo_payload.get("city") or "")[:128], asn[:24], provider[:255],
           now, now + 5184000, remote))
    except Exception as exc:
        db.execute("UPDATE geo SET status='retry',updated=?,next_lookup=? WHERE remote=?", (now, now + 86400, remote))
        print(json.dumps({"event": "geo_error", "ip_hash": hashlib.sha256(remote.encode()).hexdigest()[:12],
                          "error_type": type(exc).__name__}), flush=True)
    db.commit()


def collect_metrics(db):
    with urllib.request.urlopen(METRICS, timeout=3) as response:
        values = {}
        for line in response.read().decode().splitlines():
            name, value = line.split(None, 1)
            values[name] = int(float(value))
    names = ["sessions_live", "streams_live", "backend_dials_in_flight", "pending_bytes", "pending_items",
             "sessions_created_total", "sessions_closed_total", "streams_opened_total", "streams_rejected_total",
             "backend_dial_failures_total", "bytes_up_total", "bytes_down_total", "limit_hits_total"]
    db.execute("INSERT OR REPLACE INTO metrics VALUES(" + ",".join(["?"] * 14) + ")",
               (int(time.time()), *[values.get("tproxy_" + name, 0) for name in names]))
    db.commit()


def geo_data(db, since, geo_enabled):
    countries = {"good": [], "failed": []}
    if geo_enabled:
        for class_name in countries:
            rows = db.execute("""SELECT COALESCE(NULLIF(g.country_code,''),'ZZ'),COALESCE(NULLIF(g.country_name,''),'Неизвестно'),
              SUM(s.requests),SUM(s.request_bytes),SUM(s.response_bytes),COUNT(DISTINCT s.remote)
              FROM ip_minute_stats s LEFT JOIN geo g ON g.remote=s.remote
              WHERE s.class=? AND s.bucket>=? GROUP BY 1,2 ORDER BY 3 DESC""", (class_name, since)).fetchall()
            countries[class_name] = [{"code": r[0], "country": r[1], "connections": r[2] or 0,
                                      "bytes_in": r[3] or 0, "bytes_out": r[4] or 0, "unique_ips": r[5] or 0} for r in rows]
    cities = []
    if geo_enabled:
        for r in db.execute("""SELECT COALESCE(NULLIF(g.city_name,''),'Город не определён'),COALESCE(NULLIF(g.region_name,''),''),
          COALESCE(NULLIF(g.country_name,''),'Неизвестно'),COALESCE(NULLIF(g.country_code,''),'ZZ'),
          SUM(s.requests),SUM(s.request_bytes+s.response_bytes),COUNT(DISTINCT s.remote)
          FROM ip_minute_stats s LEFT JOIN geo g ON g.remote=s.remote WHERE s.bucket>=?
          GROUP BY 1,2,3,4 ORDER BY 5 DESC LIMIT 48""", (since,)).fetchall():
            cities.append({"city": r[0], "region": r[1], "country": r[2], "code": r[3],
                           "connections": r[4] or 0, "traffic": r[5] or 0, "unique_ips": r[6] or 0})
    ips = []
    for r in db.execute("""SELECT s.remote,COALESCE(NULLIF(g.country_code,''),'ZZ'),COALESCE(NULLIF(g.country_name,''),'Неизвестно'),
      COALESCE(NULLIF(g.city_name,''),'Город не определён'),COALESCE(NULLIF(g.region_name,''),''),
      COALESCE(NULLIF(g.asn,''),''),COALESCE(NULLIF(g.provider,''),'Провайдер не определён'),
      SUM(s.requests),SUM(s.request_bytes+s.response_bytes),MAX(s.bucket),SUM(CASE WHEN s.class='failed' THEN s.requests ELSE 0 END)
      FROM ip_minute_stats s LEFT JOIN geo g ON g.remote=s.remote WHERE s.bucket>=?
      GROUP BY s.remote ORDER BY 8 DESC LIMIT 100""", (since,)).fetchall():
        ips.append({"ip": r[0], "code": r[1], "country": r[2], "city": r[3], "region": r[4], "asn": r[5],
                    "provider": r[6], "connections": r[7] or 0, "traffic": r[8] or 0,
                    "last_seen": datetime.fromtimestamp(r[9], timezone.utc).isoformat(), "errors": r[10] or 0})
    return {"countries": countries, "cities": cities, "ips": ips}


def window_data(db, since, geo_enabled):
    endpoint_rows = {"good": [], "failed": []}
    for class_name in endpoint_rows:
        rows = db.execute("""SELECT endpoint,SUM(requests),SUM(request_bytes),SUM(response_bytes),MAX(max_ms)
          FROM minute_stats WHERE class=? AND bucket>=? GROUP BY endpoint ORDER BY SUM(requests) DESC""",
          (class_name, since)).fetchall()
        endpoint_rows[class_name] = [{"endpoint": r[0], "requests": r[1] or 0, "bytes_in": r[2] or 0,
                                      "bytes_out": r[3] or 0, "max_ms": r[4] or 0} for r in rows]
    reasons = {row[0]: row[1] for row in db.execute(
        "SELECT reason,SUM(requests) FROM minute_stats WHERE class='failed' AND bucket>=? GROUP BY reason ORDER BY 2 DESC",
        (since,)).fetchall()}
    errors = [{"time": datetime.fromtimestamp(r[0], timezone.utc).isoformat(), "ip": r[1], "endpoint": r[2],
               "method": r[3], "status": r[4], "reason": r[5], "bytes_in": r[6], "bytes_out": r[7], "ms": r[8],
               "code": r[9], "country": r[10], "city": r[11], "asn": r[12], "provider": r[13]}
              for r in db.execute("""SELECT e.occurred,e.remote,e.endpoint,e.method,e.status,e.reason,e.request_bytes,
                e.response_bytes,e.request_ms,COALESCE(g.country_code,'ZZ'),COALESCE(g.country_name,'Неизвестно'),
                COALESCE(g.city_name,''),COALESCE(g.asn,''),COALESCE(g.provider,'')
                FROM errors e LEFT JOIN geo g ON g.remote=e.remote WHERE e.occurred>=? ORDER BY e.occurred DESC LIMIT 50""",
                (since,)).fetchall()]
    latest = db.execute("SELECT * FROM metrics ORDER BY occurred DESC LIMIT 1").fetchone()
    first = db.execute("SELECT * FROM metrics WHERE occurred>=? ORDER BY occurred LIMIT 1", (since,)).fetchone()
    names = ["occurred", "sessions_live", "streams_live", "backend_dials_in_flight", "pending_bytes", "pending_items",
             "sessions_created_total", "sessions_closed_total", "streams_opened_total", "streams_rejected_total",
             "backend_dial_failures_total", "bytes_up_total", "bytes_down_total", "limit_hits_total"]
    latest_map = dict(zip(names, latest or [0] * len(names)))
    first_map = dict(zip(names, first or latest or [0] * len(names)))
    period = {key: max(0, latest_map[key] - first_map[key]) for key in names[6:]}
    created = db.execute("SELECT COALESCE(SUM(requests),0) FROM minute_stats WHERE class='good' AND reason='session_created' AND bucket>=?", (since,)).fetchone()[0]
    period["sessions_created_total"] = created
    return {"endpoints": endpoint_rows, "reasons": reasons, "errors": errors, "geo": geo_data(db, since, geo_enabled),
            "metrics": {"latest": {key: latest_map[key] for key in names[1:]}, "period": period}}


def publish(db):
    now = int(time.time())
    geo_enabled = bool(ipinfo_token())
    payload = {"generated_at": datetime.now(timezone.utc).isoformat(), "geo_enabled": geo_enabled, "windows": {}}
    for name, seconds in WINDOWS.items():
        payload["windows"][name] = window_data(db, now - seconds, geo_enabled)
    temporary = OUTPUT + ".tmp"
    with open(temporary, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"))
    os.chmod(temporary, 0o640)
    os.replace(temporary, OUTPUT)


def cleanup(db):
    cutoff = int(time.time()) - WINDOWS["7d"] - 3600
    for table, column in (("seen_events", "occurred"), ("minute_stats", "bucket"), ("ip_minute_stats", "bucket"),
                          ("errors", "occurred"), ("metrics", "occurred")):
        db.execute(f"DELETE FROM {table} WHERE {column}<?", (cutoff,))
    db.execute("DELETE FROM geo WHERE remote NOT IN (SELECT DISTINCT remote FROM ip_minute_stats)")
    db.commit()


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    db = connect()
    last_metrics = last_publish = last_cleanup = last_geo = 0
    while running:
        try:
            import_log(db)
            now = time.monotonic()
            if now - last_metrics >= 10:
                collect_metrics(db); last_metrics = now
            if now - last_geo >= 2:
                enrich_one(db); last_geo = now
            if now - last_publish >= 5:
                publish(db); last_publish = now
            if now - last_cleanup >= 3600:
                cleanup(db); last_cleanup = now
        except Exception as exc:
            print(json.dumps({"event": "collector_error", "error": str(exc)}), flush=True)
            try:
                db.rollback()
            except Exception:
                pass
        time.sleep(2)
    db.close()


if __name__ == "__main__":
    main()
