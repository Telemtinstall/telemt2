# mtproto+webproxy

Отдельный автоматический установщик для одного домена и одного публичного
`443/tcp`:

- Telemt `3.4.24` в Docker;
- nginx stream с `ssl_preread`;
- Telegram WEB proxy relay (`tproxy-server`);
- официальный Telegram MTProxy как локальный backend;
- Let's Encrypt и маскировочный сайт.

Старые установщики в родительском проекте не изменяются. Проверенная локальная
версия Telemt `3.4.24` хранится здесь как независимый vendor-снимок.

> `tproxy-server` пока называется авторами proof of concept. Для подключения
> нужен Telegram-клиент, в котором доступен тип прокси `WEB`.

## Требования

- новый чистый VPS;
- Debian 13 или Ubuntu 24.04–26.x, `x86_64`, systemd;
- root;
- минимум 1 ГБ RAM, рекомендуется 2 ГБ;
- публичные `80/tcp` и `443/tcp`;
- DNS `A` домена должен указывать на сервер;
- не добавляйте неработающую DNS `AAAA` запись и не ставьте CDN перед первым
  запуском.

Установщик не меняет SSH, не устанавливает VPN и не меняет существующие маршруты.
Если исходящий трафик уже направлен через VPN, сервисы используют системную
маршрутизацию. Для официального MTProxy автоматически вычисляется `--nat-info`,
когда локальный исходящий IPv4 отличается от внешнего; это можно отключить.

Для Debian и Ubuntu используется одна WEB proxy-конфигурация, одинаковые
systemd units, nftables и набор backend-портов. Различия nginx/Docker обрабатывает
vendor-установщик Telemt: на Ubuntu он проверяет активный nginx/OpenSSL и при
необходимости устанавливает совместимую изолированную сборку, не заменяя
системные библиотеки OpenSSL.

## Быстрый запуск

Одна команда на чистом сервере:

```bash
wget -qO install.sh 'https://raw.githubusercontent.com/Telemtinstall/telemt2/mtproto%2Bwebproxy/mtproto%2Bwebproxy/install.sh' && bash install.sh --auto
```

Загруженный одиночный `install.sh` сам установит `ca-certificates`, `curl` и
`tar`, скачает полный комплект с vendor-файлами в
`/opt/mtproto-webproxy-installer` и продолжит установку. Git заранее не нужен.

Запуск из полного Git checkout:

```bash
chmod +x install.sh
sudo ./install.sh --auto
```

Мастер спросит домен. Email будет создан автоматически:

```text
admin@введённый-домен
```

Полностью без вопросов:

```bash
sudo ./install.sh --auto --domain proxy.example.com
```

Обычная установка дополнительно спрашивает, включать ли безопасный nginx
access-log. В нём нет URL, query string, заголовков и секретов.

## Результат

Один домен обслуживает оба вида прокси:

```text
Internet :443
    -> nginx stream
        -> Telemt :1443
            -> MTProxy FakeTLS
            -> genuine HTTPS -> nginx TLS :8443
                                  -> tproxy-server :8080
                                      -> public site :8082
                                      -> official MTProxy :2398
```

Публичны только `80/tcp`, `443/tcp` и уже существующий SSH-порт. Локальные
backend-порты дополнительно закрываются nftables от внешних интерфейсов.

Ссылки сохраняются в:

```text
/root/telemt-proxy-links.txt
/root/webproxy-links.txt
```

WEB proxy использует отдельный автоматически сгенерированный секрет. Он не
совпадает с ключом обычного Telemt, поэтому их можно менять независимо.

## Тонкие параметры

Без дополнительных параметров используются безопасные значения:

```text
WEB carrier:                 https
WEB sessions global:         128
WEB streams global:          4096
Per-IP limits:               disabled
Official MTProxy workers:    1
Official MTProxy connections: 4096
Telemt connections:          5000
Safe access log:             disabled
MTProxy NAT:                 auto
```

Расширенный пример:

```bash
sudo ./install.sh --auto \
  --domain proxy.example.com \
  --carrier websocket \
  --safe-access-log yes \
  --mtproxy-workers 2 \
  --mtproxy-max-connections 8192 \
  --nat-info auto
```

Допустимые carrier-режимы:

- `https` — совместимый базовый режим;
- `https-lanes` — отдельные HTTPS lanes, лучше работает с HTTP/2;
- `websocket` — один мультиплексированный WebSocket;
- `websocket-lanes` — отдельный WebSocket на логический поток.

Для первой проверки используйте `https`.

`--nat-info` принимает:

- `auto` — вычислить только для запуска MTProxy;
- `off` — никогда не добавлять;
- `LOCAL_IPV4:EXTERNAL_IPV4` — задать явно.

Установщик не блокирует установку из-за способа выхода в интернет и не меняет
маршруты/VPN.

## Повторный запуск

Если первая установка прервалась после успешной установки Telemt, следующий
обычный запуск пропускает уже завершённую фазу Telemt и продолжает WEB proxy.

Повторно применить WEB-конфигурацию:

```bash
sudo ./install.sh --repair
```

Обновить Telemt закреплённой версией и пересобрать закреплённый WEB relay:

```bash
sudo ./install.sh --update
```

Перед изменением WEB/nginx конфигурации создаётся резервная копия в:

```text
/root/mtproto-webproxy-backups/
```

При ошибке конфигурация nginx и секреты WEB proxy восстанавливаются
автоматически. Vendor-установщик Telemt имеет собственный rollback обновления.

## Проверка

```bash
systemctl --no-pager --full status nginx mtproxy tproxy-server
curl -fsS http://127.0.0.1:8081/healthz
curl -fsS http://127.0.0.1:8081/readyz
curl -fsS https://proxy.example.com/
ss -lntp
nft list table inet tproxy_backend
```

Порты `2398`, `8888`, `8080`, `8081` и `8082` не должны открываться извне.

## Закреплённые исходники

- Telemt installer candidate: exact Telemt `3.4.24`;
- `tproxy-server`: commit
  `52a5feb7fac38f68da5afef9cedd9b3bfc8473ca`, архив проверяется SHA-256;
- официальный MTProxy: commit
  `f36d8af769ffaeac36978d38c2c0f6d1104c2137`, архив проверяется SHA-256.

Движущиеся `latest`-версии не используются.
