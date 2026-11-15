"""Durable FIFO for domain changes. Uncertain jobs are never replayed automatically."""
from contextlib import contextmanager
import sqlite3
import threading
import time
from pathlib import Path
from app import formatters


class DomainQueue:
    def __init__(self, path, command, telegram):
        self.path = Path(path)
        self.command, self.telegram = command, telegram
        self.stop_event = threading.Event()
        self.wake = threading.Event()
        self.thread = None
        self.path.parent.mkdir(parents=True, exist_ok=True)
        with self.db() as db:
            db.execute('CREATE TABLE IF NOT EXISTS jobs (id INTEGER PRIMARY KEY, token TEXT UNIQUE, chat INTEGER, domain TEXT, ip TEXT, state TEXT, result TEXT, notified INTEGER DEFAULT 0)')
            if 'kind' not in {row[1] for row in db.execute('PRAGMA table_info(jobs)')}:
                db.execute("ALTER TABLE jobs ADD COLUMN kind TEXT NOT NULL DEFAULT 'domain'")
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=15)
        try:
            with db:
                yield db
        finally:
            db.close()

    def enqueue(self, token, chat, domain, ip, kind='domain'):
        if kind not in {'domain', 'ip'}:
            raise ValueError('Unknown queue job kind')
        with self.db() as db:
            db.execute('INSERT OR IGNORE INTO jobs(token,chat,domain,ip,state,kind) VALUES (?,?,?,?,?,?)',
                       (token, chat, domain, ip, 'queued', kind))
            row = db.execute('SELECT id FROM jobs WHERE token=?', (token,)).fetchone()
        self.wake.set()
        return row[0]

    def recent(self):
        with self.db() as db:
            return db.execute('SELECT id,kind,domain,ip,state,result FROM jobs ORDER BY id DESC LIMIT 8').fetchall()

    def start(self):
        # A killed helper may have changed VPN settings: do not retry it after restarting.
        with self.db() as db:
            db.execute("UPDATE jobs SET state='interrupted', result=? WHERE state='running'",
                       ('Процесс прерван. Требуется сверка настроек сервера; повтор автоматически не запускается.',))
        self.thread = threading.Thread(target=self.run, name='domain-queue', daemon=True)
        self.thread.start()

    def close(self):
        self.stop_event.set(); self.wake.set()
        if self.thread:
            self.thread.join(timeout=5)

    def notify(self):
        with self.db() as db:
            rows = db.execute("SELECT id,chat,state,result,kind FROM jobs WHERE state IN ('done','failed','interrupted') AND notified=0 ORDER BY id").fetchall()
        for number, chat, state, result, kind in rows:
            try:
                self.telegram.send_message(chat, 'Задание смены ' + ('IP' if kind == 'ip' else 'домена') + ' №' + str(number) + '\n' + formatters.h(result))
            except Exception:
                continue
            with self.db() as db:
                db.execute('UPDATE jobs SET notified=1 WHERE id=?', (number,))

    def process_one(self):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            if db.execute("SELECT 1 FROM jobs WHERE state IN ('running','interrupted') LIMIT 1").fetchone():
                return False
            row = db.execute("SELECT id,domain,ip,kind FROM jobs WHERE state='queued' ORDER BY id LIMIT 1").fetchone()
            if not row:
                return False
            number, domain, ip, kind = row
            db.execute("UPDATE jobs SET state='running' WHERE id=?", (number,))
        try:
            result = self.command('apply', ip) if kind == 'ip' else self.command('domain-set', domain, '--address', ip)
            state = 'done'
            message = ('Настройки VPN сохранены. Домен: ' + result['domain'] +
                       '\nIP: ' + result['ip'] + ('\nСамостоятельно измените A-запись у регистратора на выбранный IP, затем переподключите VPN.' if kind == 'ip' else '\nПолучите новые профили на каждом устройстве. A-запись настройте у регистратора самостоятельно.'))
        except Exception as exc:
            state = 'failed'
            message = 'Смена ' + ('IP' if kind == 'ip' else 'домена') + ' не завершена: ' + str(exc)
        with self.db() as db:
            db.execute('UPDATE jobs SET state=?,result=? WHERE id=?', (state, message, number))
        return True

    def run(self):
        while not self.stop_event.is_set():
            try:
                self.notify()
                if self.process_one():
                    continue
            except Exception:
                # Preserve persisted state on unexpected worker/database failures.
                pass
            self.wake.wait(2); self.wake.clear()
