from __future__ import annotations

import csv
import io
import logging
import re
import sqlite3
from contextlib import closing
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo


SAFE_NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")
log = logging.getLogger("vpnbot.traffic")


@dataclass(frozen=True)
class Counter:
    name: str
    upload_bytes: int
    download_bytes: int


class TrafficStore:
    def __init__(self, root: Path, timezone_name: str = "UTC"):
        self.root = Path(root)
        self.timezone = ZoneInfo(timezone_name)
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)

    def now(self) -> datetime:
        return datetime.now(self.timezone)

    @staticmethod
    def timestamp(value: datetime) -> str:
        return value.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    def db_path(self, server_id: str, user_name: str) -> Path:
        if not SAFE_NAME_RE.fullmatch(server_id) or not SAFE_NAME_RE.fullmatch(user_name):
            raise ValueError("unsafe server or user name for traffic database")
        return self.root / f"{server_id}__{user_name}.sqlite3"

    def connect(self, server_id: str, protocol: str, user_name: str) -> sqlite3.Connection:
        path = self.db_path(server_id, user_name)
        db = sqlite3.connect(path, timeout=30)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA busy_timeout=30000")
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS identity (
                singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                server_id TEXT NOT NULL,
                protocol TEXT NOT NULL,
                user_name TEXT NOT NULL,
                created_at TIMESTAMP NOT NULL
            );
            CREATE TABLE IF NOT EXISTS state (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS daily_usage (
                day DATE PRIMARY KEY,
                upload_bytes INTEGER NOT NULL DEFAULT 0,
                download_bytes INTEGER NOT NULL DEFAULT 0,
                total_bytes INTEGER NOT NULL DEFAULT 0,
                captured_at TIMESTAMP NOT NULL
            );
            """
        )
        db.execute(
            """
            INSERT OR IGNORE INTO identity
                (singleton, server_id, protocol, user_name, created_at)
            VALUES (1, ?, ?, ?, ?)
            """,
            (server_id, protocol, user_name, self.timestamp(self.now())),
        )
        db.commit()
        path.chmod(0o600)
        return db

    def ensure_user(self, server_id: str, protocol: str, user_name: str) -> Path:
        with closing(self.connect(server_id, protocol, user_name)):
            pass
        return self.db_path(server_id, user_name)

    def delete_user(self, server_id: str, user_name: str) -> bool:
        """Delete a user's traffic database and any SQLite sidecar files."""
        path = self.db_path(server_id, user_name)
        removed = False
        for candidate in (
            path,
            Path(f"{path}-wal"),
            Path(f"{path}-shm"),
            Path(f"{path}-journal"),
        ):
            try:
                candidate.unlink()
                removed = True
            except FileNotFoundError:
                pass
        return removed

    @staticmethod
    def counters_for(server, data: dict) -> list[Counter]:
        result = []
        if server.is_amneziawg:
            for item in data.get("peers") or []:
                name = str(item.get("name") or "")
                if name:
                    result.append(
                        Counter(
                            name,
                            int(item.get("rx_bytes") or 0),
                            int(item.get("tx_bytes") or 0),
                        )
                    )
        elif server.is_vless:
            for item in data.get("clients") or []:
                name = str(item.get("name") or "")
                if name:
                    result.append(
                        Counter(
                            name,
                            int(item.get("uplink_bytes") or 0),
                            int(item.get("downlink_bytes") or 0),
                        )
                    )
        return result

    @staticmethod
    def delta(current: int, previous: int) -> int:
        return current - previous if current >= previous else current

    @staticmethod
    def state_int(db: sqlite3.Connection, key: str) -> int:
        row = db.execute("SELECT value FROM state WHERE key = ?", (key,)).fetchone()
        return int(row[0]) if row else 0

    @staticmethod
    def set_state(db: sqlite3.Connection, key: str, value: int | str) -> None:
        db.execute(
            "INSERT INTO state(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            (key, str(value)),
        )

    def capture_server(self, server, data: dict | None = None, at: datetime | None = None) -> int:
        at = at or self.now()
        data = data or server.traffic()
        captured = 0
        for counter in self.counters_for(server, data):
            with closing(self.connect(server.id, server.protocol, counter.name)) as db:
                with db:
                    previous_up = self.state_int(db, "last_upload_bytes")
                    previous_down = self.state_int(db, "last_download_bytes")
                    upload = self.delta(counter.upload_bytes, previous_up)
                    download = self.delta(counter.download_bytes, previous_down)
                    db.execute(
                        """
                        INSERT INTO daily_usage
                            (day, upload_bytes, download_bytes, total_bytes, captured_at)
                        VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(day) DO UPDATE SET
                            upload_bytes = daily_usage.upload_bytes + excluded.upload_bytes,
                            download_bytes = daily_usage.download_bytes + excluded.download_bytes,
                            total_bytes = daily_usage.total_bytes + excluded.total_bytes,
                            captured_at = excluded.captured_at
                        """,
                        (
                            at.astimezone(timezone.utc).date().isoformat(),
                            upload,
                            download,
                            upload + download,
                            self.timestamp(at),
                        ),
                    )
                    self.set_state(db, "last_upload_bytes", counter.upload_bytes)
                    self.set_state(db, "last_download_bytes", counter.download_bytes)
                    self.set_state(db, "last_capture_at", self.timestamp(at))
            captured += 1
        return captured

    def capture_all(self, registry, at: datetime | None = None) -> int:
        captured = 0
        for server in registry.servers:
            data = server.traffic()
            captured += self.capture_server(server, data=data, at=at)
            self.prune_absent_users(server, data)
        return captured

    def prune_absent_users(self, server, data: dict | None = None) -> int:
        """Remove stale databases only when list and traffic sources fully agree."""
        data = data or server.traffic()
        configured = {
            str(item.get("name"))
            for item in server.list_clients()
            if item.get("name")
        }
        counters = {counter.name for counter in self.counters_for(server, data)}
        if configured != counters:
            log.warning(
                "skip stale traffic database cleanup for %s: list=%s counters=%s",
                server.id,
                len(configured),
                len(counters),
            )
            return 0

        removed = 0
        for path in sorted(self.root.glob(f"{server.id}__*.sqlite3")):
            db = sqlite3.connect(path, timeout=30)
            try:
                identity = db.execute(
                    "SELECT server_id, user_name FROM identity WHERE singleton = 1"
                ).fetchone()
            finally:
                db.close()
            if not identity or str(identity[0]) != server.id:
                log.warning("skip traffic database with mismatched identity: %s", path.name)
                continue
            user_name = str(identity[1])
            if user_name not in configured and self.delete_user(server.id, user_name):
                removed += 1
        return removed

    def live_rows(self, server, data: dict | None = None, at: datetime | None = None) -> list[dict]:
        at = at or self.now()
        data = data or server.traffic()
        rows = []
        for counter in self.counters_for(server, data):
            with closing(self.connect(server.id, server.protocol, counter.name)) as db:
                upload = self.delta(counter.upload_bytes, self.state_int(db, "last_upload_bytes"))
                download = self.delta(
                    counter.download_bytes,
                    self.state_int(db, "last_download_bytes"),
                )
            rows.append(
                {
                    "date": at.astimezone(timezone.utc).date().isoformat(),
                    "server_id": server.id,
                    "protocol": server.protocol,
                    "user": counter.name,
                    "upload_bytes": upload,
                    "download_bytes": download,
                    "total_bytes": upload + download,
                }
            )
        return rows

    def stored_daily_rows(self, server_id: str | None = None) -> list[dict]:
        rows = []
        for path in sorted(self.root.glob("*.sqlite3")):
            db = sqlite3.connect(path, timeout=30)
            try:
                identity = db.execute(
                    "SELECT server_id, protocol, user_name FROM identity WHERE singleton = 1"
                ).fetchone()
                if not identity or (server_id and identity[0] != server_id):
                    continue
                for day, upload, download, total in db.execute(
                    "SELECT day, upload_bytes, download_bytes, total_bytes "
                    "FROM daily_usage ORDER BY day"
                ):
                    rows.append(
                        {
                            "date": day,
                            "server_id": identity[0],
                            "protocol": identity[1],
                            "user": identity[2],
                            "upload_bytes": int(upload),
                            "download_bytes": int(download),
                            "total_bytes": int(total),
                        }
                    )
            finally:
                db.close()
        return rows

    @staticmethod
    def merge_daily(rows: list[dict]) -> list[dict]:
        merged = {}
        for row in rows:
            key = (row["date"], row["server_id"], row["protocol"], row["user"])
            item = merged.setdefault(
                key,
                {
                    "date": row["date"],
                    "server_id": row["server_id"],
                    "protocol": row["protocol"],
                    "user": row["user"],
                    "upload_bytes": 0,
                    "download_bytes": 0,
                    "total_bytes": 0,
                },
            )
            for field in ("upload_bytes", "download_bytes", "total_bytes"):
                item[field] += int(row[field])
        return sorted(merged.values(), key=lambda x: (x["date"], x["user"]))

    def daily_rows_with_live(self, server, data: dict | None = None) -> list[dict]:
        return self.merge_daily(self.stored_daily_rows(server.id) + self.live_rows(server, data))

    def current_month_rows(self, server, data: dict | None = None) -> list[dict]:
        month = self.now().strftime("%Y-%m")
        rows = [row for row in self.daily_rows_with_live(server, data) if row["date"].startswith(month)]
        totals = {}
        for row in rows:
            item = totals.setdefault(
                row["user"],
                {
                    "user": row["user"],
                    "upload_bytes": 0,
                    "download_bytes": 0,
                    "total_bytes": 0,
                },
            )
            for field in ("upload_bytes", "download_bytes", "total_bytes"):
                item[field] += int(row[field])
        return sorted(totals.values(), key=lambda x: x["user"])

    @staticmethod
    def monthly_rows(daily_rows: list[dict]) -> list[dict]:
        totals = {}
        for row in daily_rows:
            month = row["date"][:7]
            key = (month, row["server_id"], row["protocol"], row["user"])
            item = totals.setdefault(
                key,
                {
                    "month": month,
                    "server_id": row["server_id"],
                    "protocol": row["protocol"],
                    "user": row["user"],
                    "upload_bytes": 0,
                    "download_bytes": 0,
                    "total_bytes": 0,
                },
            )
            for field in ("upload_bytes", "download_bytes", "total_bytes"):
                item[field] += int(row[field])
        return sorted(totals.values(), key=lambda x: (x["month"], x["user"]))

    @staticmethod
    def csv_bytes(rows: list[dict], fieldnames: list[str]) -> bytes:
        output = io.StringIO(newline="")
        writer = csv.DictWriter(output, fieldnames=fieldnames, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
        return ("\ufeff" + output.getvalue()).encode("utf-8")

    @staticmethod
    def rows_in_megabytes(rows: list[dict]) -> list[dict]:
        result = []
        for row in rows:
            converted = {
                key: value
                for key, value in row.items()
                if key not in {"upload_bytes", "download_bytes", "total_bytes"}
            }
            converted.update(
                {
                    "upload_mb": round(int(row.get("upload_bytes") or 0) / 1048576, 3),
                    "download_mb": round(int(row.get("download_bytes") or 0) / 1048576, 3),
                    "total_mb": round(int(row.get("total_bytes") or 0) / 1048576, 3),
                }
            )
            result.append(converted)
        return result

    def report_files(self, server, data: dict | None = None) -> tuple[bytes, bytes]:
        daily = self.daily_rows_with_live(server, data)
        return self.report_bytes(daily)

    def chart_series(
        self,
        server,
        user_name: str | None = None,
        data: dict | None = None,
    ) -> tuple[list[dict], list[dict]]:
        rows = self.daily_rows_with_live(server, data)
        if user_name is not None:
            rows = [row for row in rows if row.get("user") == user_name]

        totals_by_day: dict[str, int] = {}
        for row in rows:
            day = str(row["date"])
            totals_by_day[day] = totals_by_day.get(day, 0) + int(row.get("total_bytes") or 0)

        today = self.now().astimezone(timezone.utc).date()
        daily = []
        for day_number in range(1, today.day + 1):
            day = today.replace(day=day_number)
            day_key = day.isoformat()
            daily.append(
                {
                    "label": str(day_number),
                    "tick": day_number == 1 or day_number % 5 == 0 or day_number == today.day,
                    "value": totals_by_day.get(day_key, 0) / 1048576,
                }
            )

        monthly_totals: dict[str, int] = {}
        for day, total in totals_by_day.items():
            month = day[:7]
            monthly_totals[month] = monthly_totals.get(month, 0) + total

        months = []
        year, month = today.year, today.month
        for offset in range(11, -1, -1):
            absolute = year * 12 + month - 1 - offset
            item_year, item_month_zero = divmod(absolute, 12)
            item_month = item_month_zero + 1
            key = f"{item_year:04d}-{item_month:02d}"
            months.append(
                {
                    "label": f"{item_month:02d}.{str(item_year)[2:]}",
                    "tick": True,
                    "value": monthly_totals.get(key, 0) / 1073741824,
                }
            )

        return daily, months

    def user_report_files(
        self,
        server,
        user_name: str,
        data: dict | None = None,
    ) -> tuple[bytes, bytes]:
        daily = [
            row
            for row in self.daily_rows_with_live(server, data)
            if row.get("user") == user_name
        ]
        return self.report_bytes(daily)

    def report_bytes(self, daily: list[dict]) -> tuple[bytes, bytes]:
        monthly = self.monthly_rows(daily)
        dimensions = ["server_id", "protocol", "user"]
        metrics = ["upload_mb", "download_mb", "total_mb"]
        return (
            self.csv_bytes(self.rows_in_megabytes(daily), ["date", *dimensions, *metrics]),
            self.csv_bytes(
                self.rows_in_megabytes(monthly),
                ["month", *dimensions, *metrics],
            ),
        )
