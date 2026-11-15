"""Private-chat callback handles: bounded size, expiry and one-shot mutations."""
import json
import secrets
import sqlite3
import time
from contextlib import closing

MUTATIONS = {'delyes', 'ray', 'tay', 'ga', 'ptoggle', 'adminadd', 'admindelyes', 'create_default'}


class CallbackStore:
    def __init__(self, path):
        self.path = path
        with closing(sqlite3.connect(path)) as db, db:
            db.execute('CREATE TABLE IF NOT EXISTS profile_identity (server_id TEXT NOT NULL, name TEXT NOT NULL, fingerprint TEXT NOT NULL, PRIMARY KEY(server_id,name))')
            db.execute('CREATE TABLE IF NOT EXISTS callback_handles (token TEXT PRIMARY KEY, chat_id INTEGER NOT NULL, payload TEXT NOT NULL, expires REAL NOT NULL, single_use INTEGER NOT NULL, used INTEGER NOT NULL DEFAULT 0, fingerprint TEXT)')

    def markup(self, chat_id, markup):
        result = json.loads(json.dumps(markup))
        now = time.time()
        with closing(sqlite3.connect(self.path, timeout=30)) as db, db:
            db.execute('DELETE FROM callback_handles WHERE expires < ?', (now,))
            for row in result.get('inline_keyboard', []):
                for button in row:
                    payload = button.get('callback_data')
                    if not payload:
                        continue
                    single = payload.split(':', 1)[0] in MUTATIONS
                    components = payload.split(':')
                    identity = db.execute('SELECT fingerprint FROM profile_identity WHERE server_id=? AND name=?', tuple(components[1:3])).fetchone() if len(components) >= 3 else None
                    token = secrets.token_urlsafe(18)
                    db.execute('INSERT INTO callback_handles(token, chat_id, payload, expires, single_use, fingerprint) VALUES(?,?,?,?,?,?)', (token, chat_id, payload, now + (600 if single else 86400), int(single), identity[0] if identity else None))
                    button['callback_data'] = 'h:' + token
        return result

    def resolve(self, chat_id, value):
        if not value.startswith('h:'):
            raise ValueError('Кнопка устарела. Откройте /menu и выберите действие заново.')
        with closing(sqlite3.connect(self.path, timeout=30)) as db, db:
            db.execute('BEGIN IMMEDIATE')
            row = db.execute('SELECT payload, expires, single_use, used, fingerprint FROM callback_handles WHERE token=? AND chat_id=?', (value[2:], chat_id)).fetchone()
            if not row or row[1] < time.time() or row[3]:
                raise ValueError('Кнопка истекла или уже использована. Откройте /menu.')
            components = row[0].split(':')
            if row[4] and len(components) >= 3:
                identity = db.execute('SELECT fingerprint FROM profile_identity WHERE server_id=? AND name=?', tuple(components[1:3])).fetchone()
                if not identity or identity[0] != row[4]:
                    raise ValueError('Профиль изменился. Откройте /menu.')
            if row[2]:
                db.execute('UPDATE callback_handles SET used=1 WHERE token=?', (value[2:],))
            return row[0]
