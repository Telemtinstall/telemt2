"""Durable single-consumer queue. Never blindly replay an uncertain server action."""
from contextlib import contextmanager
from contextvars import ContextVar
import json
import os
from pathlib import Path
import sqlite3
import time

request_context=ContextVar('vpn_job_request',default=None)
MUTATING_METHODS = {'endpoint_apply', 'create_client', 'delete_client', 'toggle_protocol', 'revoke_access', 'create_access_invite'}

class JobQueue:
    def __init__(self,path):
        self.path=Path(path);self.path.parent.mkdir(parents=True,exist_ok=True)
        # SQLite sidecars inherit restrictive permissions too.
        fd=os.open(self.path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600);os.close(fd);self.path.chmod(0o600)
        with self.db() as db:
            db.executescript('''
CREATE TABLE IF NOT EXISTS jobs (
 id INTEGER PRIMARY KEY, token TEXT UNIQUE NOT NULL, actor TEXT NOT NULL, chat INTEGER NOT NULL,
 method TEXT NOT NULL, args TEXT NOT NULL, kwargs TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'queued',
 created REAL NOT NULL, finished REAL, error TEXT);
CREATE TABLE IF NOT EXISTS outbox (
 id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, method TEXT NOT NULL, payload TEXT NOT NULL,
 sent INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS jobs_pending ON jobs(state,id);
''')
    @contextmanager
    def db(self):
        db=sqlite3.connect(self.path,timeout=3);db.row_factory=sqlite3.Row
        try:
            db.execute('PRAGMA busy_timeout=3000')
            with db:yield db
        finally:db.close()
    def enqueue(self,token,actor,chat,method,args,kwargs):
        with self.db() as db:
            db.execute('INSERT OR IGNORE INTO jobs(token,actor,chat,method,args,kwargs,created) VALUES(?,?,?,?,?,?,?)',
              (token,str(actor),chat,method,json.dumps(args),json.dumps(kwargs),time.time()))
            return db.execute('SELECT id FROM jobs WHERE token=?',(token,)).fetchone()['id']
    def recover(self):
        with self.db() as db:
            # A previous worker could have completed a CLI command before dying.
            marks = ','.join('?' for _ in MUTATING_METHODS)
            db.execute(f"UPDATE jobs SET state='needs_review',error='Процесс прерван; требуется сверка сервера' WHERE state='running' AND method IN ({marks})", tuple(MUTATING_METHODS))
            db.execute("UPDATE jobs SET state='queued' WHERE state='running'")
    def claim(self):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            # Conservative global barrier: do not let later commands overtake uncertainty.
            if db.execute("SELECT 1 FROM jobs WHERE state IN ('running','needs_review')").fetchone():return None
            row=db.execute("SELECT * FROM jobs WHERE state='queued' ORDER BY id LIMIT 1").fetchone()
            if row:db.execute("UPDATE jobs SET state='running' WHERE id=?",(row['id'],))
            return dict(row) if row else None
    def finish(self,number,state,error=None,messages=()):
        with self.db() as db:
            db.execute('UPDATE jobs SET state=?,error=?,finished=? WHERE id=?',(state,error,time.time(),number))
            for method,payload in messages:
                db.execute('INSERT INTO outbox(job_id,method,payload) VALUES(?,?,?)',(number,method,json.dumps(payload)))
    def recent(self,actor=None):
        with self.db() as db:
            return [dict(row) for row in db.execute('SELECT id,method,state,error FROM jobs '+('WHERE actor=? ' if actor else '')+'ORDER BY id DESC LIMIT 10', (str(actor),) if actor else ())]
    def pending_messages(self):
        with self.db() as db:return [dict(r) for r in db.execute('SELECT * FROM outbox WHERE sent=0 ORDER BY id LIMIT 20')]
    def delivered(self,number):
        with self.db() as db:db.execute('UPDATE outbox SET sent=1,payload=? WHERE id=?',('{}',number))
    def resolve(self,number,state):
        if state not in {'done','failed'}:raise ValueError('Only done/failed after manual server verification')
        with self.db() as db:
            row=db.execute('SELECT chat FROM jobs WHERE id=? AND state=?',(number,'needs_review')).fetchone()
            if not row:raise ValueError('Not a task requiring review')
            db.execute('UPDATE jobs SET state=?,finished=? WHERE id=?',(state,time.time(),number))

DEFERRED={
 'endpoint_apply','create_client','delete_client','toggle_protocol','send_qr_for_client','send_test_split_qr',
 'send_config_file_for_client','send_vpn_key_for_client','send_router_config_for_client','send_vless_link_for_client',
 'show_server_status','show_speedtest','show_channel_load','show_list','show_client','show_online','show_all_online',
 'show_traffic','send_traffic_reports','send_all_traffic_reports','send_client_traffic_reports','show_client_traffic',
 'show_user_client','ask_delete','create_access_invite','ask_revoke_access','revoke_access','ask_transfer_access'}
USER_PROFILE_METHODS={'show_user_client','send_qr_for_client','send_test_split_qr','send_config_file_for_client',
 'send_vpn_key_for_client','send_router_config_for_client','send_vless_link_for_client','send_client_traffic_reports'}

class QueuedActions:
    is_queued = True
    def __init__(self,actions,queue):self.base,self.queue=actions,queue
    def __getattr__(self,name):
        if name=='check_user_profile':
            def local_check(user_id,server_id,ref):
                if not self.base.access_store.owns(user_id,server_id,ref):raise PermissionError('Нет доступа')
            return local_check
        if name=='menu_stats':return lambda:None # Navigation never waits for a live CLI snapshot.
        if name not in DEFERRED:return getattr(self.base,name)
        def submit(*args,**kwargs):
            context=request_context.get()
            if not context:raise RuntimeError('Missing authenticated request context')
            actor,update_id=context
            args=list(args)
            if name=='create_client':
                import hashlib
                generated='vpn-'+hashlib.sha256(str(update_id).encode()).hexdigest()[:10]
                if len(args)<3:args.append(generated)
                elif not args[2]:args[2]=generated
            token=str(update_id)+':'+name
            number=self.queue.enqueue(token,actor,int(args[0]),name,args,kwargs)
            self.base.telegram.send_message(args[0],f'Задача №{number} принята. Результат придёт отдельным сообщением.')
            return args[2] if name=='create_client' else None
        return submit
