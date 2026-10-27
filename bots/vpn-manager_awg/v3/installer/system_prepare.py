"""No questionnaire until kernel preparation is finished."""
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
from progress import run_process

PACKAGES = ('python3', 'python3-pil', 'fonts-dejavu-core', 'curl', 'openssl', 'qrencode', 'jq',
            'git', 'logrotate', 'util-linux', 'nftables', 'conntrack', 'iproute2',
            'bind9-dnsutils', 'bind9-host', 'ca-certificates')


def run(args, **kwargs):
    return run_process(args, title=('Идёт обновление списка пакетов' if args[:2] == ['apt-get', 'update'] else 'Идёт установка ядра и зависимостей'), **kwargs)


def require_platform():
    import sys
    if sys.platform != 'linux' or os.geteuid() != 0:
        raise ValueError('Установка выполняется root на Linux; локально используйте --check')
    info = platform.freedesktop_os_release()
    version = int(info.get('VERSION_ID', '0').split('.')[0])
    if not ((info.get('ID') == 'debian' and version >= 13)
            or (info.get('ID') == 'ubuntu' and version >= 24)):
        raise ValueError('Нужен Debian 13 или Ubuntu 24+')


def kernel_ready(release, headers):
    numbers = re.match(r'(\d+)\.(\d+)', release)
    return bool(numbers and tuple(map(int, numbers.groups())) >= (6, 7) and headers)


def kernel_preflight(resume='повторите ту же команду установки', state=None):
    release = platform.release()
    headers = Path('/lib/modules') / release / 'build/Makefile'
    if kernel_ready(release, headers.exists()):
        if state and state.data.pop('kernel_pending', None): state.save()
        return
    boot_id = Path('/proc/sys/kernel/random/boot_id').read_text().strip() if state else None
    pending = state.data.get('kernel_pending') if state else None
    if pending:
        if pending['boot_id'] == boot_id:
            print('Ядро уже подготовлено. Выполните reboot.\nПродолжение: ' + resume)
            raise SystemExit(75)
        raise ValueError('После перезагрузки ядро ' + release + ' не готово для AWG. '
                         'Проверьте выбранное ядро в загрузчике и headers. '
                         'Подготовлены: ' + ', '.join(pending['candidates']))
    if not re.match(r'\d+\.\d+', release):
        raise ValueError('Не удалось определить версию ядра')
    env = dict(os.environ, DEBIAN_FRONTEND='noninteractive', NEEDRESTART_MODE='l')
    run(['apt-get', 'update'], env=env)
    osinfo = platform.freedesktop_os_release()
    if osinfo.get('ID') == 'debian':
        arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(platform.machine())
        if not arch:
            raise ValueError('Поддерживаются amd64 и arm64')
        packages = ['linux-image-' + arch, 'linux-headers-' + arch]
    elif osinfo.get('ID') == 'ubuntu':
        packages = ['linux-generic', 'linux-headers-generic']
    else:
        raise ValueError('Поддерживаются Debian 13 и Ubuntu 24+')
    if kernel_ready(release, True):
        result = run_process(['apt-get', 'install', '-y', 'linux-headers-' + release], env=env, check=False, title='Идёт установка headers текущего ядра')
        if result.returncode == 0 and headers.exists():
            return
    run(['apt-get', 'install', '-y', *packages], env=env)
    candidates = [p.parent.parent.name for p in Path('/lib/modules').glob('*/build/Makefile')
                  if kernel_ready(p.parent.parent.name, True)
                  and Path('/boot', 'vmlinuz-' + p.parent.parent.name).exists()]
    if kernel_ready(release, headers.exists()):
        return
    if not candidates:
        raise ValueError('Подходящее загрузочное ядро с headers не найдено после установки')
    if state:
        state.data['kernel_pending'] = {'boot_id': boot_id, 'candidates': candidates}
        state.save()
    print('Требуется перезагрузка. Выполните reboot.\nПродолжение: ' + resume +
          '\nПараметры сохранены; вопросы о боте и VPN ещё не задавались.')
    raise SystemExit(75)


def install_speedtest(env):
    if shutil.which('speedtest-cli'):
        return
    try:
        # Speedtest is optional: its package availability must not block VPN installation.
        run_process(['apt-get', 'install', '-y', 'speedtest-cli'], env=env,
                    title='Идёт установка Speedtest', timeout=120)
    except (RuntimeError, subprocess.SubprocessError, OSError):
        print('Пакет Speedtest недоступен. При автоматическом замере будет использовано 100 Мбит/с.')
