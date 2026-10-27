"""Three-line terminal status and private, filtered child-process diagnostics."""
from contextlib import contextmanager
from collections import deque
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import threading

SENSITIVE = re.compile(r'(?i)(?:vless://|vpn://|hysteria2://|hy2://|private.?key|preshared.?key|password|token|secret|uuid|BEGIN .*KEY)')
LABELS = {'dependencies':'Идёт обновление списка пакетов', 'packages':'Идёт установка системных пакетов',
          'backup':'Идёт сохранение резервной копии', 'amnezia20':'Идёт установка AmneziaWG 2.0',
          'amnezia31':'Идёт установка AmneziaWG 3.1', 'vless':'Идёт установка VLESS',
          'hysteria2':'Идёт установка Hysteria 2', 'bot':'Идёт установка бота и очереди задач',
          'verification':'Идёт проверка VPN, бота и служб'}


def safe_output(line, secrets=()):
    return not (SENSITIVE.search(line) or '\x1b' in line
                or any(0x2580 <= ord(c) <= 0x259f for c in line)
                or any(value and value in line for value in secrets))


class Dashboard:
    def __init__(self, stream=None):
        self.stream = stream or sys.stderr
        self.tty = self.stream.isatty() and os.environ.get('TERM') != 'dumb'
        self.drawn = False
        self.tick = 0

    def draw(self, title, detail):
        if not self.tty:
            if not self.drawn:
                self.stream.write(title + '\n' + detail + '\n'); self.stream.flush()
                self.drawn = True
            return
        width = max(10, shutil.get_terminal_size((80, 24)).columns - 1)
        title = title[:max(0, width - 3)] + '  ' + '|/-\\'[self.tick % 4]
        rows = ['Global v3 · установка', title, detail]
        if self.drawn: self.stream.write('\x1b[3A')
        for row in rows:
            self.stream.write('\r\x1b[2K' + row[:width] + '\n')
        self.stream.flush(); self.drawn = True; self.tick += 1

    def clear(self):
        if self.tty and self.drawn:
            self.stream.write('\x1b[3A')
            for _ in range(3): self.stream.write('\r\x1b[2K\n')
            self.stream.write('\x1b[3A'); self.stream.flush()
        self.drawn = False


@contextmanager
def activity(title, detail='Пожалуйста, дождитесь завершения'):
    # Prompts are always outside this context. No cursor hiding or raw terminal mode.
    dashboard = Dashboard()
    stop = threading.Event()
    def animate():
        while not stop.wait(0.12): dashboard.draw(title, detail)
    dashboard.draw(title, detail)
    thread = threading.Thread(target=animate, daemon=True)
    thread.start()
    try: yield
    finally:
        stop.set(); thread.join(); dashboard.clear()


def private_log(directory=None):
    directory = Path(directory or '/var/log/vpnbot-global-v3')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = directory.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.geteuid() or stat.S_IMODE(info.st_mode) & 0o077:
        raise ValueError('Каталог журнала должен принадлежать текущему пользователю и иметь права 0700')
    fd, name = tempfile.mkstemp(prefix=datetime.now(timezone.utc).strftime('%Y%m%d-%H%M%S-'), suffix='.log', dir=directory)
    os.fchmod(fd, 0o600)
    return os.fdopen(fd, 'w', encoding='utf-8'), Path(name)


class CommandError(RuntimeError):
    pass


def run_process(command, *, title='Идёт выполнение этапа', env=None, cwd=None, check=True,
                timeout=None, log_directory=None):
    """Drain both pipes in one reader, filter before disk, stop the whole process group."""
    stream, log_path = private_log(log_directory)
    environment = env if env is not None else os.environ
    secrets = [str(value) for key, value in environment.items()
               if re.search(r'(?i)(TOKEN|PASSWORD|SECRET|PRIVATE_KEY|PRESHARED_KEY)', key) and value]
    tail = deque(maxlen=5)
    failure = []
    reported = False
    process = None
    thread = None
    try:
        stream.write(title + '\n'); stream.flush()
        with activity(title, 'Журнал: ' + str(log_path)):
            process = subprocess.Popen([str(v) for v in command], env=env, cwd=cwd,
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                start_new_session=True)
            def drain():
                try:
                    # Limit long/binary/QR lines; never buffer unbounded child output.
                    while True:
                        raw = process.stdout.readline(8192)
                        if not raw: break
                        line = raw.decode('utf-8', errors='replace').rstrip('\r\n')
                        if len(raw) >= 8192:
                            while raw and not raw.endswith(b'\n'): raw = process.stdout.readline(8192)
                            continue
                        if safe_output(line, secrets):
                            clean = ''.join(c for c in line if c == '\t' or ord(c) >= 32)
                            stream.write(clean + '\n'); stream.flush()
                            if clean.strip(): tail.append(clean[-400:])
                except Exception as error:
                    failure.append(error)
                    try: os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError: pass
            thread = threading.Thread(target=drain, daemon=True); thread.start()
            try:
                result = process.wait(timeout=timeout)
                thread.join(timeout=3)
                if thread.is_alive(): raise CommandError('Дочерний процесс оставил открытый канал вывода')
            finally:
                if process.poll() is None or (thread and thread.is_alive()):
                    try: os.killpg(process.pid, signal.SIGTERM)
                    except ProcessLookupError: pass
                    try: process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        try: os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                        process.wait()
                    thread.join(timeout=1)
                    if thread.is_alive():
                        try: os.killpg(process.pid, signal.SIGKILL)
                        except ProcessLookupError: pass
                        thread.join(timeout=3)
                if thread.is_alive():
                    # Do not block acquiring a buffered reader held by a detached descendant.
                    os.close(process.stdout.fileno())
                else:
                    process.stdout.close()
        if failure: raise CommandError('Не удалось сохранить журнал этапа') from failure[0]
        stream.write('Код завершения: ' + str(result) + '\n')
        if result:
            # Never print profiles, arbitrary child output, or secrets on the terminal.
            reason = next((line for line in reversed(tail) if re.search(r'(?i)(ошибка|error|failed|fatal|не совпадает)', line)), None)
            if reason: print(reason, file=sys.stderr)
            print('Подробности: ' + str(log_path), file=sys.stderr)
            reported = True
            if check: raise CommandError(title + ': код ' + str(result))
        return subprocess.CompletedProcess(command, result)
    except (OSError, RuntimeError, subprocess.SubprocessError, KeyboardInterrupt):
        if not reported: print('Подробности: ' + str(log_path), file=sys.stderr)
        raise
    finally:
        stream.close()
