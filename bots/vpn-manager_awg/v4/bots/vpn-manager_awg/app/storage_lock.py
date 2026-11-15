"""Reentrant process/thread lock shared by bot and traffic collector."""
import fcntl
import threading
from contextlib import contextmanager, nullcontext
from functools import wraps
from pathlib import Path

_guard = threading.Lock()
_locks = {}


@contextmanager
def storage_lock(root):
    path = str(Path(root).resolve() / '.traffic.lock')
    with _guard:
        lock, local = _locks.setdefault(path, (threading.RLock(), threading.local()))
    with lock:
        if getattr(local, 'depth', 0):
            local.depth += 1
            try:
                yield
            finally:
                local.depth -= 1
            return
        with open(path, 'a') as stream:
            Path(path).chmod(0o600)
            fcntl.flock(stream, fcntl.LOCK_EX)
            local.depth = 1
            try:
                yield
            finally:
                local.depth = 0
                fcntl.flock(stream, fcntl.LOCK_UN)


def synchronized(method):
    @wraps(method)
    def wrapped(self, *args, **kwargs):
        store = getattr(self, 'traffic_store', self)
        root = getattr(store, 'root', None)
        with storage_lock(root) if root is not None else nullcontext():
            return method(self, *args, **kwargs)
    return wrapped
