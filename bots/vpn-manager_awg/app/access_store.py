from __future__ import annotations

import hashlib
import secrets
import sqlite3
from contextlib import closing
from datetime import datetime, timedelta, timezone
from pathlib import Path


class AccessStore:
    def __init__(self, path: Path, invite_hours: int = 24):
        self.path = Path(path)
        self.invite_hours = max(1, int(invite_hours))
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        with closing(self.connect()) as db:
            self.initialize(db)
        self.path.chmod(0o600)

    @staticmethod
    def now() -> datetime:
        return datetime.now(timezone.utc)

    @staticmethod
    def timestamp(value: datetime) -> str:
        return value.astimezone(timezone.utc).strftime("%Y-%m-%d %H:%M:%S")

    @staticmethod
    def token_hash(token: str) -> str:
        return hashlib.sha256(token.encode("ascii")).hexdigest()

    def connect(self) -> sqlite3.Connection:
        db = sqlite3.connect(self.path, timeout=30)
        db.row_factory = sqlite3.Row
        db.execute("PRAGMA journal_mode=WAL")
        db.execute("PRAGMA busy_timeout=30000")
        db.execute("PRAGMA foreign_keys=ON")
        db.execute("PRAGMA secure_delete=ON")
        return db

    @staticmethod
    def initialize(db: sqlite3.Connection) -> None:
        db.executescript(
            """
            CREATE TABLE IF NOT EXISTS access_grants (
                server_id TEXT NOT NULL,
                protocol TEXT NOT NULL,
                vpn_user_name TEXT NOT NULL,
                telegram_user_id TEXT NOT NULL,
                telegram_username TEXT,
                telegram_first_name TEXT,
                telegram_last_name TEXT,
                granted_at TIMESTAMP NOT NULL,
                granted_by TEXT NOT NULL,
                revoked_at TIMESTAMP,
                PRIMARY KEY (server_id, vpn_user_name)
            );

            CREATE INDEX IF NOT EXISTS access_grants_telegram_active
            ON access_grants (telegram_user_id, revoked_at);

            CREATE TABLE IF NOT EXISTS invite_tokens (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                token_hash TEXT NOT NULL UNIQUE,
                server_id TEXT NOT NULL,
                protocol TEXT NOT NULL,
                vpn_user_name TEXT NOT NULL,
                created_by TEXT NOT NULL,
                created_at TIMESTAMP NOT NULL,
                expires_at TIMESTAMP NOT NULL,
                used_at TIMESTAMP,
                used_by_telegram_id TEXT,
                revoked_at TIMESTAMP
            );

            CREATE INDEX IF NOT EXISTS invite_tokens_profile
            ON invite_tokens (server_id, vpn_user_name, created_at);

            CREATE TABLE IF NOT EXISTS bot_admins (
                telegram_user_id TEXT PRIMARY KEY,
                telegram_username TEXT,
                telegram_first_name TEXT,
                telegram_last_name TEXT,
                added_at TIMESTAMP NOT NULL,
                added_by TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS protocol_states (
                server_id TEXT PRIMARY KEY,
                enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
                changed_at TIMESTAMP NOT NULL,
                changed_by TEXT NOT NULL
            );
            """
        )
        db.commit()

    def is_dynamic_admin(self, telegram_user_id: str) -> bool:
        with closing(self.connect()) as db:
            row = db.execute(
                "SELECT 1 FROM bot_admins WHERE telegram_user_id = ?",
                (str(telegram_user_id),),
            ).fetchone()
        return bool(row)

    def add_admin(self, telegram_user: dict, added_by: str) -> dict:
        telegram_user_id = str(telegram_user.get("id") or "").strip()
        if not telegram_user_id.isdigit():
            raise ValueError("нужен числовой Telegram ID")
        added_at = self.timestamp(self.now())
        values = (
            telegram_user_id,
            telegram_user.get("username"),
            telegram_user.get("first_name"),
            telegram_user.get("last_name"),
            added_at,
            str(added_by),
        )
        with closing(self.connect()) as db:
            with db:
                db.execute(
                    """
                    INSERT INTO bot_admins (
                        telegram_user_id, telegram_username, telegram_first_name,
                        telegram_last_name, added_at, added_by
                    ) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(telegram_user_id) DO UPDATE SET
                        telegram_username = excluded.telegram_username,
                        telegram_first_name = excluded.telegram_first_name,
                        telegram_last_name = excluded.telegram_last_name,
                        added_at = excluded.added_at,
                        added_by = excluded.added_by
                    """,
                    values,
                )
        return {
            "telegram_user_id": telegram_user_id,
            "telegram_username": telegram_user.get("username"),
            "telegram_first_name": telegram_user.get("first_name"),
            "telegram_last_name": telegram_user.get("last_name"),
            "added_at": added_at,
            "added_by": str(added_by),
        }

    def list_admins(self) -> list[dict]:
        with closing(self.connect()) as db:
            rows = db.execute(
                "SELECT * FROM bot_admins ORDER BY added_at, telegram_user_id"
            ).fetchall()
        return [dict(row) for row in rows]

    def remove_admin(self, telegram_user_id: str) -> bool:
        with closing(self.connect()) as db:
            with db:
                cursor = db.execute(
                    "DELETE FROM bot_admins WHERE telegram_user_id = ?",
                    (str(telegram_user_id),),
                )
        return cursor.rowcount > 0

    def protocol_enabled(self, server_id: str) -> bool:
        with closing(self.connect()) as db:
            row = db.execute(
                "SELECT enabled FROM protocol_states WHERE server_id = ?",
                (server_id,),
            ).fetchone()
        return True if row is None else bool(row["enabled"])

    def set_protocol_enabled(self, server_id: str, enabled: bool, changed_by: str) -> None:
        with closing(self.connect()) as db:
            with db:
                db.execute(
                    """
                    INSERT INTO protocol_states (server_id, enabled, changed_at, changed_by)
                    VALUES (?, ?, ?, ?)
                    ON CONFLICT(server_id) DO UPDATE SET
                        enabled = excluded.enabled,
                        changed_at = excluded.changed_at,
                        changed_by = excluded.changed_by
                    """,
                    (
                        server_id,
                        1 if enabled else 0,
                        self.timestamp(self.now()),
                        str(changed_by),
                    ),
                )

    def disabled_protocol_ids(self) -> set[str]:
        with closing(self.connect()) as db:
            rows = db.execute(
                "SELECT server_id FROM protocol_states WHERE enabled = 0"
            ).fetchall()
        return {str(row["server_id"]) for row in rows}

    def create_invite(
        self,
        server_id: str,
        protocol: str,
        vpn_user_name: str,
        created_by: str,
        transfer: bool = False,
    ) -> dict:
        token = secrets.token_urlsafe(32)
        created_at = self.now()
        expires_at = created_at + timedelta(hours=self.invite_hours)
        with closing(self.connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            active = db.execute(
                "SELECT telegram_user_id FROM access_grants "
                "WHERE server_id = ? AND vpn_user_name = ? AND revoked_at IS NULL",
                (server_id, vpn_user_name),
            ).fetchone()
            if active and not transfer:
                db.rollback()
                raise ValueError("доступ уже выдан; сначала отзовите его или используйте передачу")
            if active and transfer:
                db.execute(
                    "UPDATE access_grants SET revoked_at = ? "
                    "WHERE server_id = ? AND vpn_user_name = ? AND revoked_at IS NULL",
                    (self.timestamp(created_at), server_id, vpn_user_name),
                )
            db.execute(
                "UPDATE invite_tokens SET revoked_at = ? "
                "WHERE server_id = ? AND vpn_user_name = ? "
                "AND used_at IS NULL AND revoked_at IS NULL",
                (self.timestamp(created_at), server_id, vpn_user_name),
            )
            db.execute(
                """
                INSERT INTO invite_tokens (
                    token_hash, server_id, protocol, vpn_user_name, created_by,
                    created_at, expires_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    self.token_hash(token),
                    server_id,
                    protocol,
                    vpn_user_name,
                    str(created_by),
                    self.timestamp(created_at),
                    self.timestamp(expires_at),
                ),
            )
            db.commit()
        return {
            "token": token,
            "server_id": server_id,
            "protocol": protocol,
            "vpn_user_name": vpn_user_name,
            "created_at": self.timestamp(created_at),
            "expires_at": self.timestamp(expires_at),
        }

    def claim(self, token: str, telegram_user: dict) -> dict:
        claimed_at = self.now()
        telegram_user_id = str(telegram_user.get("id") or "")
        if not telegram_user_id:
            raise ValueError("Telegram ID получателя отсутствует")
        with closing(self.connect()) as db:
            db.execute("BEGIN IMMEDIATE")
            invite = db.execute(
                """
                SELECT * FROM invite_tokens
                WHERE token_hash = ? AND used_at IS NULL AND revoked_at IS NULL
                  AND expires_at > ?
                ORDER BY id DESC LIMIT 1
                """,
                (self.token_hash(token), self.timestamp(claimed_at)),
            ).fetchone()
            if not invite:
                db.rollback()
                raise ValueError("ссылка недействительна, уже использована или истекла")

            active = db.execute(
                "SELECT telegram_user_id FROM access_grants "
                "WHERE server_id = ? AND vpn_user_name = ? AND revoked_at IS NULL",
                (invite["server_id"], invite["vpn_user_name"]),
            ).fetchone()
            if active:
                db.rollback()
                raise ValueError("доступ к этому VPN-профилю уже выдан")

            values = (
                invite["protocol"],
                telegram_user_id,
                telegram_user.get("username"),
                telegram_user.get("first_name"),
                telegram_user.get("last_name"),
                self.timestamp(claimed_at),
                invite["created_by"],
                invite["server_id"],
                invite["vpn_user_name"],
            )
            db.execute(
                """
                INSERT INTO access_grants (
                    protocol, telegram_user_id, telegram_username,
                    telegram_first_name, telegram_last_name, granted_at,
                    granted_by, server_id, vpn_user_name, revoked_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)
                ON CONFLICT(server_id, vpn_user_name) DO UPDATE SET
                    protocol = excluded.protocol,
                    telegram_user_id = excluded.telegram_user_id,
                    telegram_username = excluded.telegram_username,
                    telegram_first_name = excluded.telegram_first_name,
                    telegram_last_name = excluded.telegram_last_name,
                    granted_at = excluded.granted_at,
                    granted_by = excluded.granted_by,
                    revoked_at = NULL
                """,
                values,
            )
            db.execute(
                "UPDATE invite_tokens SET used_at = ?, used_by_telegram_id = ? WHERE id = ?",
                (self.timestamp(claimed_at), telegram_user_id, invite["id"]),
            )
            db.commit()

        return {
            "server_id": invite["server_id"],
            "protocol": invite["protocol"],
            "vpn_user_name": invite["vpn_user_name"],
            "telegram_user_id": telegram_user_id,
            "telegram_username": telegram_user.get("username"),
            "telegram_first_name": telegram_user.get("first_name"),
            "telegram_last_name": telegram_user.get("last_name"),
            "granted_at": self.timestamp(claimed_at),
            "granted_by": invite["created_by"],
        }

    def owns(self, telegram_user_id: str, server_id: str, vpn_user_name: str) -> bool:
        with closing(self.connect()) as db:
            row = db.execute(
                "SELECT 1 FROM access_grants WHERE telegram_user_id = ? "
                "AND server_id = ? AND vpn_user_name = ? AND revoked_at IS NULL",
                (str(telegram_user_id), server_id, vpn_user_name),
            ).fetchone()
        return bool(row)

    def grants_for_user(self, telegram_user_id: str) -> list[dict]:
        with closing(self.connect()) as db:
            rows = db.execute(
                "SELECT * FROM access_grants WHERE telegram_user_id = ? "
                "AND revoked_at IS NULL ORDER BY protocol, vpn_user_name",
                (str(telegram_user_id),),
            ).fetchall()
        return [dict(row) for row in rows]

    def has_access(self, telegram_user_id: str) -> bool:
        with closing(self.connect()) as db:
            row = db.execute(
                "SELECT 1 FROM access_grants WHERE telegram_user_id = ? "
                "AND revoked_at IS NULL LIMIT 1",
                (str(telegram_user_id),),
            ).fetchone()
        return bool(row)

    def profile_status(self, server_id: str, vpn_user_name: str) -> dict:
        now = self.timestamp(self.now())
        with closing(self.connect()) as db:
            grant = db.execute(
                "SELECT * FROM access_grants WHERE server_id = ? "
                "AND vpn_user_name = ? AND revoked_at IS NULL",
                (server_id, vpn_user_name),
            ).fetchone()
            if grant:
                return {"state": "active", **dict(grant)}
            invite = db.execute(
                "SELECT * FROM invite_tokens WHERE server_id = ? AND vpn_user_name = ? "
                "AND used_at IS NULL AND revoked_at IS NULL AND expires_at > ? "
                "ORDER BY id DESC LIMIT 1",
                (server_id, vpn_user_name, now),
            ).fetchone()
            if invite:
                return {"state": "pending", **dict(invite)}
        return {"state": "none"}

    def revoke(self, server_id: str, vpn_user_name: str) -> bool:
        revoked_at = self.timestamp(self.now())
        with closing(self.connect()) as db:
            with db:
                cursor = db.execute(
                    "UPDATE access_grants SET revoked_at = ? WHERE server_id = ? "
                    "AND vpn_user_name = ? AND revoked_at IS NULL",
                    (revoked_at, server_id, vpn_user_name),
                )
                db.execute(
                    "UPDATE invite_tokens SET revoked_at = ? WHERE server_id = ? "
                    "AND vpn_user_name = ? AND used_at IS NULL AND revoked_at IS NULL",
                    (revoked_at, server_id, vpn_user_name),
                )
        return cursor.rowcount > 0

    def purge_profile(self, server_id: str, vpn_user_name: str) -> None:
        with closing(self.connect()) as db:
            with db:
                db.execute(
                    "DELETE FROM invite_tokens WHERE server_id = ? AND vpn_user_name = ?",
                    (server_id, vpn_user_name),
                )
                db.execute(
                    "DELETE FROM access_grants WHERE server_id = ? AND vpn_user_name = ?",
                    (server_id, vpn_user_name),
                )
            db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
