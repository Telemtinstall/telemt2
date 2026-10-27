"""Resumable stage runner. Uncertain VPN changes need explicit server verification."""
import re
import os
import signal
import subprocess

SAFE_RETRY = {'dependencies', 'packages', 'verification'}
SENSITIVE = re.compile(r'(?i)(?:vless://|vpn://|hysteria2://|hy2://|private.?key|preshared.?key|password|token|secret|uuid)')


def safe_output(line, secrets=()):
    return not (SENSITIVE.search(line) or '\x1b' in line
                or any(0x2580 <= ord(c) <= 0x259f for c in line)
                or any(value and value in line for value in secrets))


class StageRunner:
    def __init__(self, state, env):
        self.state, self.env = state, env

    def run(self, name, command, protocol=False):
        data = self.state.data
        if name in data['done']:
            return
        previous = data.get('running')
        if previous and previous not in SAFE_RETRY:
            raise ValueError('Прерван этап ' + previous + '. Сначала сверьте состояние сервера; '
                             'автоматический повтор запрещён. Используйте --resolve-stage после проверки')
        data['running'] = name
        self.state.save()
        print('Этап: ' + name, flush=True)
        try:
            if protocol:
                result = self._protocol(command)
                if result == 75:
                    data.pop('running', None)
                    self.state.save()
                    print('Требуется reboot. Ответы сохранены; повторите команду продолжения.')
                    raise SystemExit(75)
                if result:
                    raise ValueError('Этап ' + name + ' не завершён; требуется сверка состояния сервера')
            else:
                subprocess.run([str(v) for v in command], env=self.env, check=True)
        except (subprocess.SubprocessError, OSError):
            if name in SAFE_RETRY:
                data.pop('running', None)
                self.state.save()
            raise
        data['done'].append(name)
        data.pop('running', None)
        self.state.save()

    def _protocol(self, command):
        secrets = [self.env.get(key) for key in ('BOT_TOKEN', 'HY_OBFS_PASSWORD')]
        process = subprocess.Popen([str(v) for v in command], env=self.env, stdin=subprocess.DEVNULL,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, errors='replace', start_new_session=True)
        try:
            for line in process.stdout:
                if safe_output(line, secrets):
                    print(line, end='', flush=True)
            return process.wait()
        finally:
            process.stdout.close()
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
