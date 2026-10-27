import tempfile
import unittest
from pathlib import Path
from app.domain_queue import DomainQueue

class QueueTests(unittest.TestCase):
 def test_fifo_dedup_failure_and_persistence(self):
  with tempfile.TemporaryDirectory() as d:
   calls=[];messages=[]
   class Telegram:
    def send_message(self,*args):messages.append(args)
   def command(action,domain,*args):
    calls.append(domain)
    if domain=='bad.example.org':raise RuntimeError('API отказ; домен не изменён')
    return {'domain':domain,'ip':args[-1]}
   path=Path(d)/'queue.db';q=DomainQueue(path,command,Telegram())
   n=q.enqueue('token',1,'bad.example.org','1.1.1.1')
   self.assertEqual(q.enqueue('token',1,'bad.example.org','1.1.1.1'),n)
   q.enqueue('next',1,'good.example.org','8.8.8.8')
   # Reopen the queue as after a restart: pending jobs are retained.
   q=DomainQueue(path,command,Telegram())
   self.assertTrue(q.process_one());self.assertTrue(q.process_one());self.assertFalse(q.process_one())
   self.assertEqual(calls,['bad.example.org','good.example.org'])
   q.notify();q.notify();self.assertEqual(len(messages),2)
 def test_running_job_is_never_replayed(self):
  with tempfile.TemporaryDirectory() as d:
   class Telegram:
    def send_message(self,*a):pass
   q=DomainQueue(Path(d)/'queue.db',lambda *a:self.fail('replay'),Telegram())
   q.enqueue('token',1,'a.example.org','1.1.1.1')
   with q.db() as db:db.execute("UPDATE jobs SET state='running'")
   q.start();q.close()
   with q.db() as db:self.assertEqual(db.execute('SELECT state FROM jobs').fetchone()[0],'interrupted')
   self.assertFalse(q.process_one())

class SharedQueueTests(unittest.TestCase):
 def test_domain_then_ip_share_fifo(self):
  with tempfile.TemporaryDirectory() as d:
   calls=[]
   class Telegram:
    def send_message(self,*a):pass
   def command(action,*args):
    calls.append((action,args));return {'domain':'new.example.org','ip':args[-1]}
   q=DomainQueue(Path(d)/'queue.db',command,Telegram())
   q.enqueue('domain',1,'new.example.org','1.1.1.1')
   q.enqueue('ip',1,'','8.8.8.8',kind='ip')
   q.process_one();q.process_one()
   self.assertEqual(calls,[('domain-set',('new.example.org','--address','1.1.1.1')),('apply',('8.8.8.8',))])
 def test_ip_click_queues_once_without_synchronous_apply(self):
  from app.ip_admin import IpAdmin
  from app.state import BotState
  with tempfile.TemporaryDirectory() as d:
   class Telegram:
    def send_message(self,*a):pass
    def edit_message(self,*a):pass
   def command(action,*a):
    if action=='list':return {'addresses':[{'ip':'1.1.1.1','interface':'eth0'}],'protocols':[{'title':'AWG','ip':'nat.netnum.ru'}]}
    if action=='domain-status':return {'active_ip':'8.8.8.8'}
    self.fail('Synchronous mutation')
   ui=IpAdmin(Telegram(),BotState(),command)
   ui.queue=DomainQueue(Path(d)/'queue.db',command,Telegram())
   ui.show(1,'10');token=ui.pending[('10',1)]['token']
   ui.handle(1,'10','ipchoose:'+token+':0');ui.handle(1,'10','ipapply:'+token,message_id=22)
   ui.handle(1,'10','ipapply:'+token,message_id=22)
   with ui.queue.db() as db:self.assertEqual(db.execute('SELECT kind,ip,state FROM jobs').fetchall(),[('ip','1.1.1.1','queued')])
 def test_migrates_existing_domain_jobs(self):
  import sqlite3
  with tempfile.TemporaryDirectory() as d:
   path=Path(d)/'queue.db';db=sqlite3.connect(path)
   db.execute('CREATE TABLE jobs (id INTEGER PRIMARY KEY, token TEXT UNIQUE, chat INTEGER, domain TEXT, ip TEXT, state TEXT, result TEXT, notified INTEGER DEFAULT 0)')
   db.execute("INSERT INTO jobs(token,state) VALUES ('old','done')");db.commit();db.close()
   q=DomainQueue(path,None,None)
   with q.db() as db:self.assertEqual(db.execute('SELECT token,kind,state FROM jobs').fetchall(),[('old','domain','done')])
