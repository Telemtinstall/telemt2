#!/usr/bin/env python3
"""Global v3 coordinator: validate → kernel → questionnaire → preflight → modules."""
import argparse
import fcntl
import os
from pathlib import Path
import shlex
import subprocess
import sys

from detection import assigned_ipv4, resolve_auto
from execution import StageRunner
from ini_config import load_ini, merge_protocols, selected_valid, validate_answers, validate_common, validate_silent, build_plan
from ports import occupied_ports, validate
from masquerade import normalize_url, prepare_site
from questionnaire import Questionnaire, PROTOCOLS
from state import InstallState, atomic_json
from recovery import hysteria_untouched
from progress import activity
from system_prepare import PACKAGES, install_speedtest, kernel_preflight, kernel_ready, require_platform, run

ROOT = Path(__file__).resolve().parents[1]
CURRENT_RESUME = None
OPTIONS = {'bot-token': 'BOT_TOKEN', 'admin-bot': 'ADMIN_BOT', 'public-ip': 'VPN_PUBLIC_HOST',
           'initial-client': 'VPN_INITIAL_CLIENT', 'channel-mbit': 'SERVER_CHANNEL_MBIT',
           'vless-domain': 'VLESS_DOMAIN', 'vless-mode': 'VLESS_MODE', 'reality-target': 'REALITY_TARGET',
           'reality-server-name': 'REALITY_SERVER_NAME', 'awg20-port': 'AWG20_PORT', 'awg31-port': 'AWG31_PORT',
           'vless-port': 'VLESS_PORT', 'hysteria-port': 'HY_PORT', 'hysteria-domain': 'HY_DOMAIN',
           'hysteria-obfs': 'HY_OBFS', 'hysteria-obfs-password': 'HY_OBFS_PASSWORD',
           'hysteria-masquerade-mode': 'HY_MASQUERADE_MODE', 'hysteria-masquerade-url': 'HY_MASQUERADE', 'hysteria-version': 'HY_VERSION',
           'hysteria-min-packet-size': 'HY_MIN_PACKET', 'hysteria-max-packet-size': 'HY_MAX_PACKET'}


def parser():
    result = argparse.ArgumentParser(description='Global v3: ядро перед анкетой; отдельный чистый Debian 13 / Ubuntu 24+')
    result.add_argument('--onlyprotocol', action='append', choices=PROTOCOLS)
    result.add_argument('--silent', action='store_true', default=None, help='без вопросов; ошибки не скрываются')
    result.add_argument('--config', type=Path, help='INI-файл с ответами')
    result.add_argument('--check', '--dry-run', dest='check', action='store_true')
    result.add_argument('--state-file', type=Path, default=Path('/root/.vpnbot-global-v3.json'))
    result.add_argument('--resolve-stage', choices=['backup', 'bot', *PROTOCOLS],
                        help='только после сверки прерванного этапа с реальным сервером')
    result.add_argument('--stage-result', choices=['done', 'retry'])
    for option in OPTIONS:
        result.add_argument('--' + option)
    return result


def input_settings(args):
    answers, configured = load_ini(args.config) if args.config else ({}, None)
    protocols = merge_protocols(configured, args.onlyprotocol)
    if protocols is not None:
        protocols = selected_valid(protocols)
    answers.update({key: os.environ[key] for key in OPTIONS.values() if key in os.environ})
    answers.update({key: getattr(args, option.replace('-', '_')) for option, key in OPTIONS.items()
                    if getattr(args, option.replace('-', '_')) is not None})
    if 'hysteria2' in (protocols or []) and answers.get('HY_OBFS') == 'none' and answers.get('HY_MASQUERADE'):
        answers['HY_MASQUERADE'] = normalize_url(answers['HY_MASQUERADE'])
    validate_common(answers, protocols)
    validate_answers(answers, protocols)
    return answers, protocols


def resume_command(state_path):
    # Secrets and the INI path are unnecessary: all accepted answers are persisted.
    return shlex.join(['bash', str(ROOT / 'install-global.sh'), '--state-file', str(state_path)])


def verify_package():
    result = subprocess.run(['sha256sum', '--check', '--quiet', 'SHA256SUMS'],
                            cwd=ROOT / 'bots/vpn-manager_awg', capture_output=True, text=True)
    if result.returncode:
        raise ValueError('Пакет установщика повреждён: проверка SHA256 не пройдена. Загрузите пакет заново')


def reject_opposite(chosen):
    paths = []
    service = None
    if 'hysteria2' in chosen:
        paths, service = ['/usr/local/etc/xray/config.json', '/usr/local/etc/xray/vless.env'], 'xray.service'
    elif 'vless' in chosen:
        paths, service = ['/etc/hysteria/config.yaml', '/etc/hysteria/settings.json'], 'hysteria2.service'
    if any(Path(path).exists() for path in paths):
        raise ValueError('Конфликт: на сервере уже настроен взаимоисключающий протокол; автоматическое удаление запрещено')
    if service and subprocess.run(['systemctl', 'is-active', '--quiet', service],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0:
        raise ValueError('Конфликт: уже работает взаимоисключающая служба ' + service)


def install(args, supplied, protocols):
    require_platform()
    if Path(os.environ.get('INSTALL_DIR', '/root/vpnbot')).exists() and not args.state_file.exists():
        raise ValueError('Обнаружен существующий бот. Для v3 нужен отдельный чистый сервер; миграция не выполняется')
    with open('/run/lock/vpnbot-global-v3.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = InstallState(args.state_file)
        if args.resolve_stage:
            if not args.stage_result:
                raise ValueError('Для --resolve-stage требуется --stage-result done или retry')
            state.resolve_stage(args.resolve_stage, args.stage_result)
            print('Сохранён проверенный итог этапа. Для продолжения: ' + resume_command(state.path))
            return
        if args.stage_result:
            raise ValueError('--stage-result используется только вместе с --resolve-stage')
        explicit_keys = {key for option, key in OPTIONS.items() if getattr(args, option.replace('-', '_')) is not None}
        state.merge(supplied, protocols, args.silent, force_keys=explicit_keys)
        if state.data.get('running') == 'hysteria2' and hysteria_untouched():
            state.resolve_stage('hysteria2', 'retry')
            print('Подготовка Hysteria была прервана до установки: конфигурации, CLI, бинарника и службы нет. Повтор разрешён.')
        silent = bool(state.data.get('silent'))
        chosen = state.data.get('protocols')
        if silent:
            validate_silent(state.data['answers'], chosen)
        if chosen:
            reject_opposite(chosen)
        if state.data.get('running') not in {None, 'dependencies', 'packages', 'verification'}:
            raise ValueError('Прерван этап ' + state.data['running'] + '. Требуется сверка сервера; '
                             'после неё используйте --resolve-stage и --stage-result')
        # No questionnaire before the kernel stage, including on interrupted runs.
        if not chosen or any(name.startswith('amnezia') for name in chosen):
            kernel_preflight(resume_command(state.path), state)
        base_env = dict(os.environ, DEBIAN_FRONTEND='noninteractive', NEEDRESTART_MODE='l')
        runner = StageRunner(state, base_env)
        runner.run('dependencies', ['apt-get', 'update'])
        runner.run('packages', ['apt-get', 'install', '-y', *PACKAGES])
        if 'speedtest-package' not in state.data['done']:
            install_speedtest(base_env)
            state.data['done'].append('speedtest-package')
            state.save()
        questionnaire = Questionnaire(state, silent)
        chosen = questionnaire.select_protocols()
        reject_opposite(chosen)
        questionnaire.collect(chosen)
        with activity('Идёт определение публичного IPv4'):
            initial = resolve_auto(state, report=lambda message: None, include_speed=False)
        if 'hysteria2' in chosen and 'hysteria2' not in state.data['done']:
            prepare_site(questionnaire, initial['VPN_PUBLIC_HOST'])
        plan = build_plan(dict(state.data['answers'], **state.data['resolved']), chosen)
        remaining = [row for row in plan if row[2].split(':', 1)[0] not in state.data['done']]
        with activity('Идёт проверка портов и сетевых интерфейсов'):
            validate(remaining, occupied_ports())
            assigned = assigned_ipv4()
        explicit_ip = state.data['answers']['VPN_PUBLIC_HOST']
        if explicit_ip != 'auto' and explicit_ip not in assigned:
            raise ValueError('Выбранный публичный IPv4 не назначен интерфейсу сервера')
        reports = []
        with activity('Идёт проверка скорости канала'):
            effective = resolve_auto(state, report=reports.append)
        for message in reports:
            print(message)
        validate_common(effective, chosen, require=True)
        if effective['VPN_PUBLIC_HOST'] not in assigned:
            raise ValueError('Выбранный публичный IPv4 больше не назначен интерфейсу сервера')
        env = dict(base_env, **effective, ASSUME_YES='1', V3_SELECTED=','.join(chosen),
                   AWG_RESUME_COMMAND=resume_command(state.path))
        runner = StageRunner(state, env)
        runner.run('backup', ['bash', ROOT / 'installer/bridge.sh', 'backup'])
        for name in chosen:
            runner.run(name, ['bash', ROOT / 'installer/modules' / (name + '.sh')], protocol=True)
        runner.run('bot', ['bash', ROOT / 'installer/bridge.sh', 'bot'])
        runner.run('verification', ['python3', ROOT / 'installer/verify.py'])
        print('Global v3 установлен. Откройте бота и отправьте /start. '
              'Ссылки, QR и YAML выдаются через бота.')


def main(argv=None):
    global CURRENT_RESUME
    args = parser().parse_args(argv)
    CURRENT_RESUME = None if args.check else resume_command(args.state_file)
    supplied, protocols = input_settings(args)
    verify_package()
    if args.check:
        if args.silent:
            validate_silent(supplied, protocols)
        print('DRY RUN: Global v3, локальная копия Глобал: пакет целостен. Изменений системы нет.')
        if protocols:
            print('Выбор: ' + ', '.join(protocols))
            for transport, port, owner in build_plan(supplied, protocols):
                print(f'  {owner}: {transport}/{port}')
        print('Порядок: ядро → reboot при необходимости → анкета → проверка портов → auto → установка.')
        print('Занятые порты проверяются на целевом сервере при установке.')
        return
    install(args, supplied, protocols)


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        print('Установка остановлена. Принятые ответы сохранены.', file=sys.stderr)
        if CURRENT_RESUME: print('Продолжение: ' + CURRENT_RESUME, file=sys.stderr)
        sys.exit(130)
    except EOFError:
        print('ОШИБКА: ввод недоступен. Используйте --silent --config или интерактивный терминал.', file=sys.stderr)
        sys.exit(1)
    except (ValueError, RuntimeError, OSError, subprocess.SubprocessError) as exc:
        print('ОШИБКА: ' + str(exc), file=sys.stderr)
        if CURRENT_RESUME: print('Продолжение: ' + CURRENT_RESUME, file=sys.stderr)
        sys.exit(1)
