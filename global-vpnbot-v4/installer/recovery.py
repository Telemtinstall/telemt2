"""Recover only a Hysteria preparation that provably wrote no installation files."""
from pathlib import Path
import subprocess


def hysteria_untouched():
    for name in ('/etc/hysteria', '/etc/systemd/system/hysteria2.service',
                 '/usr/local/sbin/hysteria2ctl', '/usr/local/sbin/hysteria2-auth',
                 '/usr/local/bin/hysteria'):
        path=Path(name)
        if path.exists() or path.is_symlink():
            return False
    try:
        result=subprocess.run(['systemctl','show','hysteria2.service','-p','LoadState','--value'],
                              capture_output=True,text=True,timeout=15)
        return result.stdout.strip()=='not-found'
    except (OSError,subprocess.SubprocessError):
        return False
