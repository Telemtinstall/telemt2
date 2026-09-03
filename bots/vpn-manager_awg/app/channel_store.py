from __future__ import annotations

import math
import sqlite3
import time
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path


COUNTERS = (
    "rx_bytes",
    "tx_bytes",
    "rx_packets",
    "tx_packets",
    "rx_errors",
    "tx_errors",
    "rx_dropped",
    "tx_dropped",
)


class ChannelStore:
    def __init__(
        self,
        path: Path,
        interface: str = "auto",
        retention_days: int = 90,
    ):
        self.path = Path(path)
        self.interface = interface
        self.retention_days = max(1, int(retention_days))
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.initialize()

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=30)
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA busy_timeout=30000")
        db.execute("PRAGMA journal_size_limit=1048576")
        return db

    def initialize(self) -> None:
        with closing(self.connect()) as db:
            db.executescript(
                """
                CREATE TABLE IF NOT EXISTS state (
                    key TEXT PRIMARY KEY,
                    value TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS network_samples (
                    captured_at TIMESTAMP PRIMARY KEY,
                    interface TEXT NOT NULL,
                    interval_seconds REAL NOT NULL,
                    rx_bytes INTEGER NOT NULL,
                    tx_bytes INTEGER NOT NULL,
                    rx_packets INTEGER NOT NULL,
                    tx_packets INTEGER NOT NULL,
                    rx_errors INTEGER NOT NULL,
                    tx_errors INTEGER NOT NULL,
                    rx_dropped INTEGER NOT NULL,
                    tx_dropped INTEGER NOT NULL
                );
                CREATE INDEX IF NOT EXISTS network_samples_time
                    ON network_samples(captured_at);
                """
            )
            db.commit()
        self.path.chmod(0o600)

    @staticmethod
    def timestamp(epoch: float) -> str:
        return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    @staticmethod
    def boot_id() -> str:
        path = Path("/proc/sys/kernel/random/boot_id")
        return path.read_text(encoding="utf-8").strip() if path.is_file() else "unknown"

    def detect_interface(self) -> str:
        if self.interface and self.interface != "auto":
            name = self.interface
        else:
            name = ""
            route = Path("/proc/net/route")
            if route.is_file():
                for raw in route.read_text(encoding="utf-8").splitlines()[1:]:
                    fields = raw.split()
                    if len(fields) >= 4 and fields[1] == "00000000" and int(fields[3], 16) & 2:
                        name = fields[0]
                        break
            if not name:
                candidates = sorted(
                    path.name
                    for path in Path("/sys/class/net").iterdir()
                    if path.name != "lo"
                )
                if candidates:
                    name = candidates[0]
        if not name or not (Path("/sys/class/net") / name / "statistics").is_dir():
            raise RuntimeError("не найден сетевой интерфейс для мониторинга")
        return name

    @staticmethod
    def read_counters(interface: str) -> dict[str, int]:
        root = Path("/sys/class/net") / interface / "statistics"
        return {
            key: int((root / key).read_text(encoding="utf-8").strip())
            for key in COUNTERS
        }

    @staticmethod
    def state(db: sqlite3.Connection) -> dict[str, str]:
        return {str(key): str(value) for key, value in db.execute("SELECT key, value FROM state")}

    @staticmethod
    def write_state(db: sqlite3.Connection, values: dict[str, str | int | float]) -> None:
        db.executemany(
            "INSERT INTO state(key, value) VALUES(?, ?) "
            "ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            [(key, str(value)) for key, value in values.items()],
        )

    def capture(self, epoch: float | None = None) -> dict:
        epoch = float(epoch if epoch is not None else time.time())
        interface = self.detect_interface()
        current = self.read_counters(interface)
        boot_id = self.boot_id()

        with closing(self.connect()) as db, db:
            previous = self.state(db)
            state_values = {
                "epoch": epoch,
                "interface": interface,
                "boot_id": boot_id,
                **current,
            }
            baseline = (
                not previous
                or previous.get("interface") != interface
                or previous.get("boot_id") != boot_id
            )
            elapsed = epoch - float(previous.get("epoch", epoch))
            reset = any(current[key] < int(previous.get(key, current[key])) for key in COUNTERS)
            if baseline or reset or elapsed < 1:
                self.write_state(db, state_values)
                return {
                    "ok": True,
                    "status": "baseline",
                    "interface": interface,
                    "captured_at": self.timestamp(epoch),
                }

            delta = {key: current[key] - int(previous[key]) for key in COUNTERS}
            captured_at = self.timestamp(epoch)
            db.execute(
                """
                INSERT OR REPLACE INTO network_samples
                    (captured_at, interface, interval_seconds,
                     rx_bytes, tx_bytes, rx_packets, tx_packets,
                     rx_errors, tx_errors, rx_dropped, tx_dropped)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    captured_at,
                    interface,
                    elapsed,
                    *(delta[key] for key in COUNTERS),
                ),
            )
            self.write_state(db, state_values)
            cutoff = self.timestamp(epoch - self.retention_days * 86400)
            deleted = db.execute(
                "DELETE FROM network_samples WHERE captured_at < ?", (cutoff,)
            ).rowcount
            if deleted > 0:
                self.write_state(db, {"vacuum_required": 1})

        self.maintain(epoch)

        return {
            "ok": True,
            "status": "captured",
            "captured_at": captured_at,
            "interface": interface,
            "interval_seconds": elapsed,
            **delta,
        }

    def maintain(self, epoch: float | None = None, force_vacuum: bool = False) -> dict:
        """Checkpoint WAL daily and compact the file after retention deletes."""
        epoch = float(epoch if epoch is not None else time.time())
        day = datetime.fromtimestamp(epoch, timezone.utc).date().isoformat()
        with closing(self.connect()) as db:
            current_state = self.state(db)
            if current_state.get("last_maintenance_day") == day and not force_vacuum:
                return {"maintained": False, "vacuumed": False}
            vacuum_required = current_state.get("vacuum_required") == "1"
            db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            vacuumed = bool(force_vacuum or vacuum_required)
            if vacuumed:
                db.execute("VACUUM")
            with db:
                self.write_state(
                    db,
                    {
                        "last_maintenance_day": day,
                        "vacuum_required": 0,
                    },
                )
        return {"maintained": True, "vacuumed": vacuumed}

    def samples(self, hours: int, max_points: int = 240) -> list[dict]:
        since = datetime.now(timezone.utc) - timedelta(hours=max(1, int(hours)))
        with closing(self.connect()) as db:
            rows = db.execute(
                """
                SELECT captured_at, interval_seconds, rx_bytes, tx_bytes,
                       rx_errors, tx_errors, rx_dropped, tx_dropped
                FROM network_samples
                WHERE captured_at >= ?
                ORDER BY captured_at
                """,
                (since.strftime("%Y-%m-%d %H:%M:%S"),),
            ).fetchall()

        raw = [
            {
                "timestamp": row[0],
                "rx_mbit": int(row[2]) * 8 / float(row[1]) / 1_000_000,
                "tx_mbit": int(row[3]) * 8 / float(row[1]) / 1_000_000,
                "rx_errors": int(row[4]),
                "tx_errors": int(row[5]),
                "rx_dropped": int(row[6]),
                "tx_dropped": int(row[7]),
            }
            for row in rows
            if float(row[1]) > 0
        ]
        if len(raw) <= max_points:
            return raw

        bucket_size = math.ceil(len(raw) / max_points)
        result = []
        for start in range(0, len(raw), bucket_size):
            bucket = raw[start : start + bucket_size]
            result.append(
                {
                    "timestamp": bucket[-1]["timestamp"],
                    "rx_mbit": sum(item["rx_mbit"] for item in bucket) / len(bucket),
                    "tx_mbit": sum(item["tx_mbit"] for item in bucket) / len(bucket),
                    "rx_errors": sum(item["rx_errors"] for item in bucket),
                    "tx_errors": sum(item["tx_errors"] for item in bucket),
                    "rx_dropped": sum(item["rx_dropped"] for item in bucket),
                    "tx_dropped": sum(item["tx_dropped"] for item in bucket),
                }
            )
        return result

    @staticmethod
    def percentile(values: list[float], percentile: float) -> float:
        if not values:
            return 0.0
        ordered = sorted(values)
        index = min(len(ordered) - 1, max(0, math.ceil(len(ordered) * percentile) - 1))
        return ordered[index]

    def summary(self, points: list[dict]) -> dict:
        rx = [float(point["rx_mbit"]) for point in points]
        tx = [float(point["tx_mbit"]) for point in points]
        return {
            "samples": len(points),
            "current_rx_mbit": rx[-1] if rx else 0.0,
            "current_tx_mbit": tx[-1] if tx else 0.0,
            "average_rx_mbit": sum(rx) / len(rx) if rx else 0.0,
            "average_tx_mbit": sum(tx) / len(tx) if tx else 0.0,
            "maximum_rx_mbit": max(rx, default=0.0),
            "maximum_tx_mbit": max(tx, default=0.0),
            "p95_rx_mbit": self.percentile(rx, 0.95),
            "p95_tx_mbit": self.percentile(tx, 0.95),
            "errors": sum(int(p["rx_errors"]) + int(p["tx_errors"]) for p in points),
            "dropped": sum(int(p["rx_dropped"]) + int(p["tx_dropped"]) for p in points),
        }
