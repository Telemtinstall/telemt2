# Telemt without Docker: Ubuntu 24-26 and OpenSSL 3.5

This is the separate native systemd installer for **Ubuntu 24.x through 26.x**.
It pins Telemt `3.4.23` and treats OpenSSL compatibility as part of the nginx
TLS stack instead of trusting the output of a separately installed CLI.

## Почему отдельный установщик

На Ubuntu 24.x системный nginx может быть собран с OpenSSL 3.0.x. Простая
установка `/opt/openssl-3.5/bin/openssl` не меняет TLS-библиотеку уже собранного
nginx. Поэтому установщик проверяет сразу:

1. что ОС действительно Ubuntu с major-версией от 24 до 26;
2. какие версии OpenSSL сообщает реально запускаемый nginx;
3. что nginx собран с `stream` и `stream_ssl_preread`;
4. что используется OpenSSL не ниже `3.5.2`;
5. что `curl` и проверки сертификата используют системный CA bundle.

Уже установленная side-by-side OpenSSL `3.5.2` распознаётся, но не добавляется
в глобальный linker path и не подменяет `/usr/bin/openssl`. Версия `3.5.2`
считается минимальным функциональным порогом, но не конечным security target:
если nginx использует `3.5.2`-`3.5.6`, для него будет установлен изолированный
вариант на `3.5.7`.

Для новой автоматической сборки используется OpenSSL `3.5.7`, а не `3.5.2`:
это та же совместимая ветка 3.5, но с исправлениями безопасности. Она статически
встраивается в отдельный nginx `1.31.2`. Системные shared libraries и системный
`/usr/bin/openssl` не заменяются.

## Установка

```bash
curl -fsSL -o /root/install_telemt_systemd.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh -lang ru
```

Нужен чистый VPS, домен с A-записью на сервер и свободные публичные порты
`80/tcp` и `443/tcp`. Проверка Ubuntu выполняется до установки пакетов.

Если nginx уже использует OpenSSL `>=3.5.7`, долгая сборка пропускается.
OpenSSL `3.5.2` распознаётся как поддерживающая нужную функцию, но обновляется
до security target. При необходимости собирается изолированный nginx:

```text
/usr/local/sbin/nginx-telemt-openssl35
/opt/telemt-nginx-openssl35/
/etc/systemd/system/nginx.service.d/90-telemt-openssl35.conf
```

Исходники OpenSSL и nginx скачиваются только с официальных release URL и
проверяются закреплёнными SHA-256. На VPS с памятью меньше примерно 1.8 ГБ
сборка идёт одним потоком, чтобы не получить OOM.

## Обновление существующей установки

```bash
curl -fsSL -o /root/install_telemt_systemd.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh --update -lang ru
```

Это одновременно заменяет старый ручной wrapper для **нативной** Ubuntu
установки: скрипт явно передаёт `/etc/ssl/certs/ca-certificates.crt` в
`SSL_CERT_FILE` и `CURL_CA_BUNDLE`, использует системный OpenSSL для служебных
проверок и не зависит от `PATH=/opt/openssl-3.5/bin`.

`--update` сохраняет Telemt secret, пользователей, ссылки, сертификат и ручные
значения конфига. Понижение Telemt блокируется; штатный target сейчас `3.4.23`.

## Режимы OpenSSL nginx

`TELEMT_NGINX_OPENSSL_MODE=auto` является default: использовать совместимый
nginx или собрать изолированный.

`TELEMT_NGINX_OPENSSL_MODE=required` также требует совместимый nginx и полезен
для автоматизации, где любая ошибка должна остановить установку.

`TELEMT_NGINX_OPENSSL_MODE=off` отключает сборку. Это диагностический override;
сайт-маска тогда может не поддерживать `X25519MLKEM768`.

Порог `TELEMT_OPENSSL_MIN_VERSION=3.5.2` менять обычно не нужно. Версии сборки
также закреплены и не берутся из `latest`.

## Проверка после установки

```bash
nginx -V 2>&1 | grep -oE 'nginx/[0-9.]+|OpenSSL [0-9.]+'
systemctl show nginx -p ExecStart --no-pager
/usr/local/bin/telemt --version
systemctl status nginx telemt --no-pager
telemt-report 5m
```

## Docker wrapper

Ранее созданный `telemt/docker-telemt/update-with-system-ca.sh` остаётся для
старых **Docker**-установок. Для этой нативной Ubuntu-ветки CA-исправление уже
встроено в сам установщик, поэтому дополнительный wrapper не требуется.

## English quick start

The installer accepts Ubuntu major versions 24 through 26 only. It requires the
nginx process serving the mask site to use OpenSSL `>=3.5.2`; if necessary it
builds isolated nginx `1.31.2` with security-fixed OpenSSL `3.5.7`, without
replacing system OpenSSL shared libraries. Telemt is pinned to `3.4.23`.

```bash
curl -fsSL -o /root/install_telemt_systemd.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh -lang en
```

Update:

```bash
/root/install_telemt_systemd.sh --update -lang en
```
