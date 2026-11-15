"""Private, atomic installer checkpoints; each answer survives a reboot."""
import json
import hashlib
import os
from pathlib import Path
import stat
import tempfile

PROTOCOL_STAGES = {'amnezia20', 'amnezia31', 'vless', 'hysteria2', 'bot', 'backup'}


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            os.fchmod(stream.fileno(), 0o600)
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        Path(temporary).unlink(missing_ok=True)


class InstallState:
    def __init__(self, path):
        self.path = Path(path)
        self.data = {'answers': {}, 'done': [], 'selection': {}, 'resolved': {}}
        if self.path.exists() or self.path.is_symlink():
            info = self.path.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid()
                    or stat.S_IMODE(info.st_mode) != 0o600):
                raise ValueError('Файл ответов должен принадлежать текущему пользователю и иметь права 0600')
            try:
                self.data.update(json.loads(self.path.read_text(encoding='utf-8')))
            except (ValueError, TypeError):
                raise ValueError('Файл продолжения повреждён; установка не запущена') from None
        if (not isinstance(self.data['answers'], dict) or not isinstance(self.data['done'], list)
                or not isinstance(self.data['selection'], dict) or not isinstance(self.data['resolved'], dict)):
            raise ValueError('Некорректный формат файла продолжения')

    def save(self):
        atomic_json(self.path, self.data)

    def started_vpn(self):
        return bool(PROTOCOL_STAGES.intersection(self.data['done'])
                    or self.data.get('running') in PROTOCOL_STAGES)

    def merge(self, answers, protocols, silent=None, force_keys=None):
        current = self.data['answers']
        previous_inputs = self.data.setdefault('input_hashes', {})
        incoming_hashes = {key: hashlib.sha256(str(value).encode()).hexdigest() for key, value in answers.items()}
        explicit = set(answers) if force_keys is None else set(force_keys)
        # An unchanged INI must not replace a site the user corrected interactively.
        answers = {key: value for key, value in answers.items()
                   if key in explicit or previous_inputs.get(key) != incoming_hashes[key] or key not in current}
        changed = {key for key, value in answers.items() if current.get(key) != value}
        different_protocols = protocols is not None and set(protocols) != set(self.data.get('protocols', []))
        if self.started_vpn() and (changed or different_protocols):
            raise ValueError('После начала установки VPN нельзя менять сохранённый план; '
                             'используйте прежние ответы до завершения или сверки сервера')
        for key in changed:
            self.data['resolved'].pop(key, None)
        if changed.intersection({'HY_DOMAIN', 'HY_OBFS', 'HY_MASQUERADE', 'HY_MASQUERADE_MODE'}):
            self.data['resolved'].pop('HY_MASQUERADE_MODE', None)
        if 'SERVER_CHANNEL_MBIT' in changed:
            self.data.setdefault('detection', {}).pop('channel_source', None)
        current.update(answers)
        previous_inputs.update(incoming_hashes)
        if protocols is not None:
            self.data['protocols'] = list(dict.fromkeys(protocols))
        if silent is not None:
            self.data['silent'] = silent
        self.save()

    def resolve_stage(self, name, result):
        if self.data.get('running') != name:
            raise ValueError('Этот этап не отмечен как прерванный: ' + name)
        if result not in {'done', 'retry'}:
            raise ValueError('stage-result: done или retry')
        if result == 'done' and name not in self.data['done']:
            self.data['done'].append(name)
        self.data.pop('running', None)
        self.save()
