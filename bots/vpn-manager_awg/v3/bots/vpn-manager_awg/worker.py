#!/usr/bin/env python3
"""One worker owns server changes; an outbox retries delivery without redoing changes."""
import argparse
import base64
import fcntl
import inspect
import json
import logging
from pathlib import Path
import signal
import time
from app import auth
from app.job_queue import JobQueue, DEFERRED, USER_PROFILE_METHODS, MUTATING_METHODS
from app.config import load_settings
from app.queued_actions import WorkerActions as Actions
from app.access_store import AccessStore
from app.callback_store import CallbackStore
from app.channel_store import ChannelStore
from app.servers import ServerRegistry
from app.state import BotState
from app.reconciliation import enqueue_reconciliation
from app.telegram_api import TelegramAPI
from app.traffic_store import TrafficStore

running=True

def encode(value):
    if isinstance(value,bytes):return {'__bytes__':base64.b64encode(value).decode()}
    if isinstance(value,(tuple,list)):return [encode(v) for v in value]
    if isinstance(value,dict):return {k:encode(v) for k,v in value.items()}
    return value

def decode(value):
    if isinstance(value,dict) and set(value)=={'__bytes__'}:return base64.b64decode(value['__bytes__'])
    if isinstance(value,dict):return {k:decode(v) for k,v in value.items()}
    if isinstance(value,list):return [decode(v) for v in value]
    return value

class CaptureTelegram:
    def __init__(self,real):self.real=real;self.messages=[]
    def __getattr__(self,name):
        if name.startswith('send_') or name=='edit_message':
            def record(*args,**kwargs):self.messages.append((name,encode({'args':args,'kwargs':kwargs})))
            return record
        return getattr(self.real,name)

def authorize(actions,job,args,kwargs):
    actor=job['actor']
    if str(job['chat'])!=actor:raise PermissionError('Only private chat tasks')
    if job['method'] not in DEFERRED:raise PermissionError('Unknown action')
    if auth.is_admin_id(actions.settings,actor,actions.access_store):return
    if job['method'] not in USER_PROFILE_METHODS:raise PermissionError('Administrator access revoked')
    bound=inspect.signature(getattr(actions,job['method'])).bind(*args,**kwargs).arguments
    server_id,ref=bound.get('server_id'),bound.get('ref')
    if not server_id or not ref:raise PermissionError('Missing profile identity')
    actions.check_user_profile(actor,server_id,ref)

def process(queue,actions,capture):
    job=queue.claim()
    if not job:return False
    args=json.loads(job['args']);kwargs=json.loads(job['kwargs']);capture.messages=[]
    try:
        authorize(actions,job,args,kwargs)
    except Exception:
        queue.finish(job['id'],'failed','Права доступа изменились',[
          ('send_message',encode({'args':[job['chat'],f"Задача №{job['id']}: доступ не подтверждён."],'kwargs':{}}))]);return True
    try:
        getattr(actions,job['method'])(*args,**kwargs)
        queue.finish(job['id'],'done',messages=capture.messages)
    except Exception as exc:
        mutation=job['method'] in MUTATING_METHODS and not getattr(exc, 'unchanged', False)
        state='needs_review' if mutation else 'failed'
        text=f"Задача №{job['id']}: "+('требуется сверка состояния сервера.' if mutation else 'не выполнена. Можно запросить повторно.')
        queue.finish(job['id'],state,text,[('send_message',encode({'args':[job['chat'],text],'kwargs':{}}))])
    return True

def deliver(queue,telegram,actions):
    for row in queue.pending_messages():
        # Recheck access before delivering stored credentials/results.
        with queue.db() as db:job=dict(db.execute('SELECT * FROM jobs WHERE id=?',(row['job_id'],)).fetchone())
        try:
            if job['state']=='done':authorize(actions,job,json.loads(job['args']),json.loads(job['kwargs']))
        except Exception:
            queue.delivered(row['id']);continue
        try:
            payload=decode(json.loads(row['payload']))
            getattr(telegram,row['method'])(*payload['args'],**payload['kwargs'])
            queue.delivered(row['id'])
        except Exception:return

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--resolve',type=int,help='Only after manually verifying real server state')
    parser.add_argument('--result',choices=['done','failed'])
    args=parser.parse_args()
    settings=load_settings();queue=JobQueue(Path(settings.servers_path).parent/'jobs.sqlite3')
    if args.resolve:
        if not args.result:parser.error('--result is required')
        queue.resolve(args.resolve,args.result);return
    lock=open(Path(settings.servers_path).parent/'.worker.lock','a');fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
    telegram=TelegramAPI(settings);telegram.callback_store=CallbackStore(settings.access_db_path)
    capture=CaptureTelegram(telegram)
    actions=Actions(settings,capture,ServerRegistry.from_file(settings.servers_path),BotState(),
      TrafficStore(settings.traffic_db_dir,settings.traffic_timezone),AccessStore(settings.access_db_path,settings.access_invite_hours),
      ChannelStore(settings.channel_db_path,settings.channel_interface,settings.channel_retention_days))
    queue.recover()
    enqueue_reconciliation(queue, actions)
    def stop(*_):
        global running
        running=False
    signal.signal(signal.SIGTERM,stop);signal.signal(signal.SIGINT,stop)
    while running:
        try:
            deliver(queue,telegram,actions)
            if not process(queue,actions,capture):time.sleep(0.5)
        except Exception:
            logging.exception('Worker iteration failed');time.sleep(2)

if __name__=='__main__':main()
