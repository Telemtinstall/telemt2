"""Persist dispatch boundaries to avoid replaying mutations after a restart.

An interrupted dispatch is deliberately not retried: an external controller may
have completed it. Such records remain visible for operator reconciliation.
"""
import json
import sqlite3
from contextlib import closing


class UpdateStore:
    def __init__(self, path):
        self.path = path
        with closing(sqlite3.connect(path)) as db, db:
            db.execute('CREATE TABLE IF NOT EXISTS update_dispatch (update_id INTEGER PRIMARY KEY, status TEXT NOT NULL, payload TEXT)')

    def offset(self):
        with closing(sqlite3.connect(self.path)) as db:
            row = db.execute('SELECT MAX(update_id) FROM update_dispatch').fetchone()
            return None if row[0] is None else row[0] + 1

    def interrupted(self):
        with closing(sqlite3.connect(self.path)) as db:
            return [row[0] for row in db.execute("SELECT update_id FROM update_dispatch WHERE status='started'")]

    def start(self, update_id):
        with closing(sqlite3.connect(self.path, timeout=30)) as db, db:
            db.execute('BEGIN IMMEDIATE')
            changed = db.execute("UPDATE update_dispatch SET status='started' WHERE update_id=? AND status='queued'", (update_id,)).rowcount
            if changed:
                return True
            return db.execute("INSERT OR IGNORE INTO update_dispatch(update_id,status) VALUES (?, 'started')", (update_id,)).rowcount == 1

    def finish(self, update_id):
        with closing(sqlite3.connect(self.path, timeout=30)) as db, db:
            db.execute("UPDATE update_dispatch SET status='finished', payload=NULL WHERE update_id=?", (update_id,))
            db.execute("DELETE FROM update_dispatch WHERE status='finished' AND update_id < ?", (update_id - 10000,))

    def accept(self, update):
        with closing(sqlite3.connect(self.path, timeout=30)) as db, db:
            return db.execute("INSERT OR IGNORE INTO update_dispatch VALUES (?, 'queued', ?)", (update['update_id'], json.dumps(update))).rowcount == 1

    def pending(self):
        with closing(sqlite3.connect(self.path, timeout=30)) as db:
            return [json.loads(row[0]) for row in db.execute("SELECT payload FROM update_dispatch WHERE status='queued' ORDER BY update_id")]
