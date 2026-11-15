"""Resumable stage runner. Uncertain VPN changes need explicit server verification."""
from progress import LABELS, run_process, safe_output
import subprocess

SAFE_RETRY = {'dependencies', 'packages', 'verification'}


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
        self.current_stage = name
        try:
            if protocol:
                result = self._protocol(command)
                if name == 'hysteria2' and result == 78:
                    data.pop('running', None)
                    self.state.save()
                    raise ValueError('Проверка релиза Hysteria не пройдена; установка протокола ещё не начиналась. Повтор разрешён после устранения причины')
                if result == 75:
                    data.pop('running', None)
                    self.state.save()
                    print('Требуется reboot. Ответы сохранены; повторите команду продолжения.')
                    raise SystemExit(75)
                if result:
                    raise ValueError('Этап ' + name + ' не завершён; требуется сверка состояния сервера')
            else:
                run_process(command, env=self.env, title=LABELS.get(name, name))
        except (RuntimeError, subprocess.SubprocessError, OSError):
            if name in SAFE_RETRY:
                data.pop('running', None)
                self.state.save()
            raise
        data['done'].append(name)
        data.pop('running', None)
        self.state.save()

    def _protocol(self, command):
        return run_process(command, env=self.env, check=False,
                           title=LABELS.get(self.current_stage, self.current_stage)).returncode
