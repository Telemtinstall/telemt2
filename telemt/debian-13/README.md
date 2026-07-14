# Telemt without Docker: Debian 13

This directory contains the native systemd installer for **Debian 13 only**.
It installs the exact checked Telemt release `3.4.23`; the moving `latest` tag
is not used.

## Единый установщик

Рекомендуемый способ установки и обновления:

```bash
curl -fsSL -o /root/install.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/install.sh
chmod +x /root/install.sh
/root/install.sh -lang ru
```

Скрипт определит Debian 13 и предложит Docker-вариант по умолчанию либо
native/systemd без Docker. Если Telemt уже установлен, ответом по умолчанию
будет обновление найденного варианта. Обновить без первого меню:

```bash
/root/install.sh --update -lang ru
```

Команды с `install_telemt_systemd.sh` ниже оставлены для прямого запуска
профильного native-установщика.

## Важно: Ubuntu устанавливается только через Docker

Этот Debian systemd-установщик нельзя использовать на Ubuntu. Для Ubuntu
24.x-26.x создан отдельный Docker entry point в каталоге
[`telemt/ubuntu-24-26/`](../ubuntu-24-26/README.md). Он проверяет версию Ubuntu
и запускает канонический `telemt/docker-telemt/install_docker-telemt.sh`.

Причина разделения связана с OpenSSL и nginx:

1. На Ubuntu 24.x системный nginx может использовать OpenSSL 3.0.x, которой
   недостаточно для нужного варианта PQ TLS (`X25519MLKEM768`).
2. В некоторых инструкциях OpenSSL `3.5.2` устанавливалась отдельно в
   `/opt/openssl-3.5`. Это меняет команду `openssl version`, но само по себе не
   переводит уже собранный и запущенный nginx на новую TLS-библиотеку.
3. OpenSSL `3.5.2` теперь является устаревшей security-версией: уязвимости ветки
   `3.5.0`-`3.5.6` исправлены в security-релизе `3.5.7`.
4. Docker-установщик на Ubuntu проверяет OpenSSL именно у реально запускаемого
   host nginx и при необходимости собирает отдельный nginx `1.31.2` с OpenSSL
   `3.5.7`, не заменяя системные shared libraries. Telemt при этом работает в
   Docker, а не как systemd-сервис на хосте.

Официальные сведения: [OpenSSL 3.5 release notes](https://openssl-library.org/news/openssl-3.5-notes/)
и [уязвимости ветки OpenSSL 3.5](https://openssl-library.org/news/vulnerabilities-3.5/).

Установка на Ubuntu 24.x-26.x:

```bash
curl -fsSL -o /root/install_telemt_docker.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_docker.sh
chmod +x /root/install_telemt_docker.sh
/root/install_telemt_docker.sh -lang ru
```

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

Recommended universal entry point:

```bash
curl -fsSL -o /root/install.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/install.sh
chmod +x /root/install.sh
/root/install.sh -lang en
```

It detects Debian 13, offers Docker (default) or native/systemd, and defaults
to updating the detected installation when Telemt is already present. Use
`/root/install.sh --update -lang en` to skip the first menu. The direct
systemd commands below remain available for advanced/manual operation.

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
