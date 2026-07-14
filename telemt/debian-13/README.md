# Telemt without Docker: Debian 13

This directory contains the native systemd installer for **Debian 13 only**.
It installs the exact checked Telemt release `3.4.23`; the moving `latest` tag
is not used.

## Установка

Нужен чистый Debian 13 VPS с доменом, A-запись которого уже указывает на
публичный IPv4 сервера. Порты `80/tcp` и `443/tcp` должны быть свободны и
доступны из интернета.

```bash
curl -fsSL -o /root/install_telemt_systemd.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh -lang ru
```

До установки пакетов скрипт читает `/etc/os-release`. Если это не Debian 13,
он завершится с ошибкой и ничего не будет устанавливать.

## Обновление

```bash
curl -fsSL -o /root/install_telemt_systemd.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh --update -lang ru
```

`--update` определяет текущую версию нативного бинарника, выбирает точный
совместимый target `3.4.23`, делает бэкап и обновляет бинарник с проверкой
официального `.sha256`. Конфиг, пользователи, секреты, ссылки, сертификат и
существующие значения сохраняются. Добавляются только отсутствующие безопасные
ключи совместимости.

Понижение версии блокируется. Переменная `ALLOW_TELEMT_DOWNGRADE=1` существует
только для осознанного ручного rollback и при обычном обновлении не нужна.

## Что устанавливается

- нативный Telemt под `systemd`, без Docker;
- nginx stream SNI router на `443/tcp`;
- сайт-маска на локальном `127.0.0.1:8443`;
- Telemt backend на `127.0.0.1:1443`;
- локальный API на `127.0.0.1:9091`;
- Let's Encrypt и автоматическое продление сертификата;
- firewall-защита локальных API/metrics портов;
- `telemt-report` для проверки состояния.

Секрет хранится в `/root/telemt-secret.env`, ссылки в
`/root/telemt-proxy-links.txt`, конфиг в `/etc/telemt/telemt.toml`.

## Основные ответы

| Вопрос | Default | Рекомендация |
|---|---:|---|
| Domain | нет | Ваш домен с A-записью на сервер |
| Email | `admin@<domain>` | Рабочий email или Enter |
| SSH port | `22` | Оставить, если перенос не нужен |
| Disable SSH passwords | `no` | `yes` только после проверки SSH-ключа |
| Enable fail2ban | `no` | По необходимости |
| Add 1G swap | `no` | `yes` на VPS с малой памятью |
| Telemt release | `3.4.23` | Оставить точную проверенную версию |
| Max TCP connections | `5000` | Оставить, если нет расчётного лимита |
| `client_mss` | `tspu` | Оставить текущий проектный default |
| `client_mss_bulk` | `1400` | Оставить default |
| Synlimit | `false` | Не включать без отдельной проверки |
| Middle proxy | `no` | `yes` обычно только вместе с `ad_tag` |
| Nginx access logs | `no` | Оставить выключенными |
| High-load tuning | `yes` | Оставить включённым |

Изменения начинаются только после показа плана и ответа `y`/`yes`.

## English quick start

The installer accepts Debian 13 only and aborts before package installation on
any other OS. It pins Telemt `3.4.23`, verifies the official release checksum,
preserves secrets during `--update`, and refuses an accidental downgrade.

```bash
curl -fsSL -o /root/install_telemt_systemd.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh -lang en
```

Update an existing native systemd installation:

```bash
/root/install_telemt_systemd.sh --update -lang en
```
