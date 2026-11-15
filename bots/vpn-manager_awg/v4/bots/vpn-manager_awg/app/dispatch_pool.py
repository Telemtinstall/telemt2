"""Bounded dispatch pool, preserving message order within each private chat."""
import threading
from collections import deque
from concurrent.futures import ThreadPoolExecutor
import logging

log = logging.getLogger('vpnbot.dispatch')


class DispatchPool:
    def __init__(self, store, handle, workers=4, capacity=64):
        self.store, self.handle = store, handle
        self.executor = ThreadPoolExecutor(max_workers=workers)
        self.slots = threading.Semaphore(capacity)
        self.guard = threading.Lock()
        self.queues = {}

    def submit(self, update, recovered=False):
        self.slots.acquire()
        try:
            accepted = recovered or self.store.accept(update)
        except Exception:
            self.slots.release()
            raise
        if not accepted:
            self.slots.release()
            return
        message = update.get('message') or (update.get('callback_query') or {}).get('message') or {}
        key = (message.get('chat') or {}).get('id', 0)
        with self.guard:
            if key in self.queues:
                self.queues[key].append(update)
            else:
                self.queues[key] = deque([update])
                self.executor.submit(self._drain, key)

    def _drain(self, key):
        while True:
            with self.guard:
                if not self.queues[key]:
                    del self.queues[key]
                    return
                update = self.queues[key].popleft()
            try:
                if self.store.start(update['update_id']):
                    self.handle(update)
                    self.store.finish(update['update_id'])
            except Exception:
                log.exception('dispatch interrupted: update_id=%s', update['update_id'])
            finally:
                self.slots.release()

    def close(self):
        self.executor.shutdown(wait=True)
