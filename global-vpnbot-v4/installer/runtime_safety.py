"""Boot-safe kernel prerequisites and conntrack policy from the validated USA/NL setup."""
from pathlib import Path
import os
import platform
import shutil
import subprocess


def memory_swap_required(meminfo):
    values = {line.split(':', 1)[0]: int(line.split()[1]) for line in meminfo.splitlines() if ':' in line}
    return values.get('MemTotal', 0) < 1536 * 1024 and values.get('SwapTotal', 0) < 512 * 1024


def ensure_build_memory(run):
    if not memory_swap_required(Path('/proc/meminfo').read_text()):
        return
    if shutil.disk_usage('/').free < 2 * 1024**3:
        raise ValueError('Для сборки AWG на малой RAM нужен swap. Освободите минимум 2 ГиБ на диске либо настройте swap самостоятельно')
    directory = Path('/var/lib/vpnbot-global-v4')
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    swap = directory / 'build.swap'
    if swap.exists() or swap.is_symlink():
        raise ValueError('Обнаружен неактивный build.swap. Проверьте swapon --show и завершите настройку swap вручную')
    run(['fallocate', '-l', '1G', str(swap)])
    swap.chmod(0o600)
    try:
        run(['mkswap', str(swap)])
        run(['swapon', str(swap)])
    except Exception:
        swap.unlink(missing_ok=True)
        raise
    fstab = Path('/etc/fstab')
    backup = directory / 'fstab.before'
    if not backup.exists():
        shutil.copy2(fstab, backup)
        backup.chmod(0o600)
    text = fstab.read_text()
    fstab.write_text(text.rstrip() + '\n' + str(swap) + ' none swap sw 0 0\n')
    print('Добавлен 1 ГиБ swap для безопасной сборки AWG; запись сохранена в fstab.')


def headers_meta():
    info = platform.freedesktop_os_release()
    if info.get('ID') == 'debian':
        arch = {'x86_64': 'amd64', 'aarch64': 'arm64'}.get(platform.machine())
        if not arch:
            raise ValueError('Поддерживаются amd64 и arm64')
        return ['linux-headers-' + arch]
    return ['linux-headers-generic']


def ensure_headers_meta(run, env):
    missing = []
    for name in headers_meta():
        result = subprocess.run(['dpkg-query','-W','-f=${Status}', name], capture_output=True, text=True)
        if result.returncode or result.stdout.strip() != 'install ok installed':
            missing.append(name)
    if missing:
        run(['apt-get','update'], env=env)
    run(['apt-get','install','-y',*headers_meta()], env=env)


def configure_conntrack():
    Path('/etc/modules-load.d/vpnbot-v4.conf').write_text('nf_conntrack\n')
    Path('/etc/sysctl.d/99-zz-vpnbot-v4.conf').write_text(
        '# VPN v4: load conntrack before systemd-sysctl.\n'
        'net.netfilter.nf_conntrack_max = 65536\n'
        'net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30\n')
    subprocess.run(['modprobe','nf_conntrack'], check=True)
    subprocess.run(['sysctl','-w','net.netfilter.nf_conntrack_max=65536',
                    'net.netfilter.nf_conntrack_tcp_timeout_time_wait=30'], check=True)


def verify_conntrack():
    root = Path('/proc/sys/net/netfilter')
    maximum = int((root/'nf_conntrack_max').read_text())
    count = int((root/'nf_conntrack_count').read_text())
    if maximum < 65536 or int((root/'nf_conntrack_tcp_timeout_time_wait').read_text()) != 30:
        raise ValueError('Не применены настройки conntrack; проверьте module-load и sysctl')
    if count >= maximum * .8:
        raise ValueError('Conntrack заполнен более чем на 80%; установка не подтверждена. Проверьте conntrack -S и нагрузку relay')
    return {'count':count, 'maximum':maximum, 'time_wait':30}
