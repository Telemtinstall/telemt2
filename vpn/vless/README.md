# VLESS WebSocket + TLS Installer

> RU: Это не официальный установщик Xray/VLESS. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is not an official Xray/VLESS installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

## RU

`install_vless.sh` поднимает VLESS через Xray на новом Debian/Ubuntu сервере.

Есть два режима:

1. `mask` — с маскировкой под обычный HTTPS-сайт на домене. Нужна DNS `A`-запись на сервер, выпускается Let's Encrypt сертификат, снаружи работает nginx.
2. `direct` — без маскировки. Можно использовать публичный IP сервера, сертификат не выпускается, nginx-сайт не ставится, Xray слушает внешний порт напрямую.

Схема с маскировкой:

```text
Internet
  -> https://<PROXY_DOMAIN>:443/
  -> nginx + Let's Encrypt TLS
     -> /                     обычная HTML-страница
     -> <VLESS_PATH>          proxy_pass на 127.0.0.1:<LOCAL_XRAY_PORT>
        -> Xray VLESS WebSocket
```

Схема без маскировки:

```text
Internet
  -> ws://<SERVER_PUBLIC_IP>:443<VLESS_PATH>
  -> Xray VLESS WebSocket
```

### Важно: Только Чистый Сервер

Используйте установщик только на чистом Debian/Ubuntu сервере.

В режиме `mask` скрипт настраивает nginx, certbot, Xray и firewall и по умолчанию занимает `80/tcp` и `443/tcp`.

В режиме `direct` скрипт не ставит nginx-маскировку и не выпускает сертификат; внешний VLESS WebSocket порт по умолчанию `443/tcp`.

Если на сервере уже работает Telemt, nginx, Apache, Caddy, панель хостинга, VPN/proxy или другой HTTPS-сервис, вероятен конфликт портов и конфигов. Для такого сервера используйте отдельную машину, другой внешний порт или ручную интеграцию.

### Что Нужно До Запуска

1. Новый Debian/Ubuntu VPS/server.
2. Root-доступ по SSH.
3. Для режима `mask`: домен с A-записью на публичный IPv4 сервера:

```text
<PROXY_DOMAIN> -> <SERVER_PUBLIC_IP>
```

Для режима `direct` можно использовать публичный IPv4 сервера без домена.

4. Открытые входящие порты:

```text
80/tcp   Let's Encrypt HTTP challenge, только для режима mask
443/tcp  HTTPS frontend в mask или прямой VLESS WebSocket в direct
```

5. Файлы `install_vless.sh` и `vlessctl.sh` должны лежать рядом на сервере.

### Как Скачать Файлы На Сервер

Если файлы уже есть на вашем компьютере, скопируйте их через `scp`:

```bash
scp install_vless.sh vlessctl.sh root@<SERVER_PUBLIC_IP>:/root/
```

Если файлы лежат в GitHub, можно скачать их напрямую через `wget`:

```bash
wget -O /root/install_vless.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/vpn/vless/install_vless.sh
wget -O /root/vlessctl.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/vpn/vless/vlessctl.sh
chmod +x /root/install_vless.sh /root/vlessctl.sh
```

То же самое через `curl`:

```bash
curl -fsSL -o /root/install_vless.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/vpn/vless/install_vless.sh
curl -fsSL -o /root/vlessctl.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/vpn/vless/vlessctl.sh
chmod +x /root/install_vless.sh /root/vlessctl.sh
```

Если нужен именно `git`, скачайте только нужный каталог через sparse checkout:

```bash
apt-get update
apt-get install -y git
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt2
cd /tmp/telemt2
git sparse-checkout set vpn/vless
cp vpn/vless/install_vless.sh vpn/vless/vlessctl.sh /root/
chmod +x /root/install_vless.sh /root/vlessctl.sh
```

### Запуск

Зайдите на сервер и запустите установщик:

```bash
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_vless.sh /root/vlessctl.sh
/root/install_vless.sh -lang ru
```

Для долгой установки лучше использовать `tmux`:

```bash
tmux new -s vless-install
chmod +x /root/install_vless.sh /root/vlessctl.sh
/root/install_vless.sh -lang ru
```

Автоматический режим без вопросов:

```bash
PUBLIC_HOST=<PROXY_DOMAIN> /root/install_vless.sh --auto -lang ru
```

Для прямого режима без домена:

```bash
/root/install_vless.sh --direct --auto -lang ru
```

В `mask`-режиме автоустановка не угадывает домен: задайте `PUBLIC_HOST`. Если первый клиент не задан, используется `pipiska1`. Флаг `-lang ru` включает русские вопросы, план установки и основной вывод; также можно использовать `-lang en`.

### Что Спросит Установщик

Полный пример диалога:

```text
Use domain + HTTPS mask site? yes/no [yes]: <Enter>
Proxy domain: <PROXY_DOMAIN>
Let's Encrypt email [admin@<PROXY_DOMAIN>]: <Enter>
First client name [pipiska1]: <Enter>
HTTPS/VLESS external port [443]: <Enter>
Local Xray port [12710]: <Enter>
VLESS WebSocket path [/vless-<RANDOM>]: <Enter>
Enable nginx/Xray access logs? yes/no [no]: <Enter>

server_public_ipv4=<SERVER_PUBLIC_IP>
domain_ipv4=<SERVER_PUBLIC_IP>

Install plan:
  mode:         mask
  domain:       <PROXY_DOMAIN>
  public IPv4:  <SERVER_PUBLIC_IP>
  email:        admin@<PROXY_DOMAIN>
  HTTPS port:   443
  local port:   12710
  stats API:    127.0.0.1:10085
  VLESS path:   /vless-<RANDOM>
  access logs:  no
  first client: pipiska1

Type y or yes to continue:
y
```

Пример режима без маскировки:

```text
Use domain + HTTPS mask site? yes/no [yes]: no
Server IP/host for VLESS link [<SERVER_PUBLIC_IP>]: <Enter>
First client name [pipiska1]: <Enter>
HTTPS/VLESS external port [443]: <Enter>
VLESS WebSocket path [/vless-<RANDOM>]: <Enter>
Enable Xray access logs? yes/no [no]: <Enter>

Install plan:
  mode:         direct
  domain:       <SERVER_PUBLIC_IP>
  public IPv4:  <SERVER_PUBLIC_IP>
  email:        not used
  HTTPS port:   443
  local port:   443
  stats API:    127.0.0.1:10085
  VLESS path:   /vless-<RANDOM>
  access logs:  no
  first client: pipiska1

Type y or yes to continue:
y
```

Как отвечать:

1. `Use domain + HTTPS mask site?` — `yes` включает режим `mask`, `no` включает режим `direct`.
2. В режиме `mask`, `Proxy domain` — домен, который A-записью указывает на сервер.
3. В режиме `direct`, `Server IP/host for VLESS link` — публичный IP сервера или домен, который уже указывает на сервер.
4. `Let's Encrypt email` спрашивается только в режиме `mask`; можно нажать Enter, тогда будет `admin@<PROXY_DOMAIN>`.
5. `First client name` — имя первого клиента. Если нажать Enter, будет `pipiska1`.
6. `HTTPS/VLESS external port` — внешний порт. По умолчанию `443`.
7. `Local Xray port` спрашивается только в режиме `mask`; обычно оставляйте `12710`.
8. `VLESS WebSocket path` — секретный path. Обычно оставляйте auto-generated значение.
9. `Enable nginx/Xray access logs? yes/no` в режиме `mask` или `Enable Xray access logs? yes/no` в режиме `direct` — по умолчанию `no`.
10. После плана установки введите `y` или `yes`.

DNS проверяется до `apt update` и до установки пакетов. Если выбран режим `mask`, но A-записи нет, она не публичная или указывает не на этот сервер, скрипт покажет ошибку и спросит:

```text
Continue without mask using <SERVER_PUBLIC_IP>? [y/N]:
```

Если ответить `y`, установка продолжится в режиме `direct` без домена, сайта-маски и сертификата.

До подтверждения плана (`Type y or yes to continue`) установщик не ставит пакеты и не меняет nginx/Xray. Он только собирает ответы, сохраняет resume-файл, проверяет DNS и, если на сервере уже есть `ss`, заранее проверяет занятые порты.

Если внешний `443/tcp`, локальный порт Xray `12710/tcp` или порт Stats API `10085/tcp` заняты, скрипт покажет процесс, который слушает порт, предложит следующий свободный порт и даст принять его или ввести свой. В `--auto` режиме свободный порт выбирается автоматически и печатается в выводе. Если в режиме `mask` занят `80/tcp`, скрипт объяснит, что этот порт нужен Let's Encrypt, и предложит перейти в `direct`-режим или освободить `80/tcp`.

После `y` начинается установка. В режиме `mask` ставятся nginx, certbot и Xray, выпускается Let's Encrypt сертификат, создаётся маскировочная HTML-страница и пишутся nginx/Xray-конфиги. В режиме `direct` ставится Xray, который слушает внешний порт напрямую. В обоих режимах включается локальный Xray Stats API на `127.0.0.1:10085`, применяются выбранные настройки логов, запускаются сервисы, открываются firewall-правила через `ufw`, если `ufw` активен.

По умолчанию Xray включает sniffing для `http`, `tls` и `quic`, а исходящие подключения предпочитают IPv4. Это нужно для VPS без IPv6: если телефон или приложение сначала выбирает IPv6-адрес сайта, Xray старается восстановить домен и отправить запрос через IPv4. Если на сервере нужен полноценный IPv6, запустите установку с `XRAY_FORCE_IPV4=0`.

Сетевые операции повторяются до 3 раз: `apt update`, установка пакетов, выпуск сертификата, скачивание Xray installer и установка Xray. Это помогает пережить временные обрывы сети или GitHub. Количество попыток и паузу можно изменить:

```bash
INSTALL_RETRIES=5 RETRY_DELAY_SECONDS=10 /root/install_vless.sh
```

### Preflight Проверки

До основной установки скрипт проверяет:

1. Запуск от root.
2. ОС Debian/Ubuntu.
3. Наличие systemd.
4. DNS A-запись домена до установки пакетов.
5. Публичность A-записи и совпадение с публичным IPv4 сервера.
6. Для режима `mask`: `80/tcp` для Let's Encrypt.
7. Свободный внешний HTTPS/VLESS-порт; если он занят, предлагается другой.
8. Свободный локальный Xray-порт в режиме `mask`; если он занят, предлагается другой.
9. Свободный локальный порт Xray Stats API `10085/tcp`; если он занят, предлагается другой.
10. Отсутствие чужих nginx sites на сервере в режиме `mask`.
11. Отсутствие уже существующего чужого Xray-конфига.

Если проверка не проходит, установка останавливается до изменения сервисов.

### Что Устанавливается

```text
nginx
certbot (только режим mask)
Xray-core
jq
curl
openssl
iproute2
unzip
qrencode
logrotate
ca-certificates
```

Создаются:

```text
/usr/local/etc/xray/vless.env
/usr/local/etc/xray/users.json
/usr/local/etc/xray/config.json
/usr/local/sbin/vlessctl
/etc/nginx/sites-available/vless-<PROXY_DOMAIN>.conf   только режим mask
/etc/nginx/conf.d/vless-log-format.conf                только режим mask
/etc/logrotate.d/vless-xray
/var/www/<PROXY_DOMAIN>/index.html                      только режим mask
/root/vless-links.txt
/root/.install_vless.state
/root/.install_vless.config
```

Если при установке включить access logs, дополнительно будут использоваться:

```text
/var/log/nginx/vless-<PROXY_DOMAIN>-access.log
/var/log/xray/access.log
/var/log/xray/error.log
/etc/logrotate.d/vless-xray
```

### Управление Пользователями

После установки используйте `vlessctl`.

`vlessctl` устанавливается как системная команда `/usr/local/sbin/vlessctl`, поэтому под root его можно запускать из любого каталога.

Добавить пользователя:

```bash
vlessctl add
```

Диалог:

```text
Имя клиента [pipiska1]: petr
Клиент добавлен: petr
vless://<UUID>@<PROXY_DOMAIN>:443?...
QR для импорта:
<terminal QR code>
```

Если выполнить `vlessctl add` без имени и просто нажать Enter, будет создан `pipiska1`. Если такое имя уже занято, будет выбран следующий свободный номер: `pipiska2`, `pipiska3` и так далее.

Удалить пользователя:

```bash
vlessctl delete
```

Диалог:

```text
Текущие клиенты:
1) ivan
2) petr
Клиент для удаления: 2
Клиент удален: petr
```

Посмотреть текущих пользователей:

```bash
vlessctl list
```

Показать ссылку:

```bash
vlessctl show
```

Диалог:

```text
Текущие клиенты:
1) ivan
Клиент для показа, или all: 1
vless://<UUID>@<PROXY_DOMAIN>:443?...
```

Показать все ссылки:

```bash
vlessctl show all
```

Показать ссылку и QR-код:

```bash
vlessctl qr
```

Диалог:

```text
Текущие клиенты:
1) ivan
Клиент для показа QR, или all: 1
vless://<UUID>@<PROXY_DOMAIN>:443?...
QR для импорта:
<terminal QR code>
```

Для скриптов есть JSON-режим. Флаг можно ставить до или после команды:

```bash
vlessctl -j list
vlessctl traffic --json
vlessctl -j add client1
vlessctl -j show client1
vlessctl -j qr client1
```

В JSON-режиме `add`, `show` и `qr` возвращают VLESS-ссылку в поле `link`; `add` и `qr` дополнительно возвращают PNG QR в `qr_png_base64` и `qr_png_data_uri`; `traffic` и `online` возвращают числовые счетчики байтов. Формат `online` расширяется добавлением новых полей, старые поля не удаляются.

#### JSON-ответы

`vlessctl` остается CLI-утилитой, поэтому главный признак успеха для shell-скриптов — код выхода. Поле `status_code` сделано в стиле HTTP, чтобы ответы было проще обрабатывать одинаково в API-обвязках.

```text
exit 0 + ok=true   = команда выполнена
exit 1 + ok=false  = команда не выполнена, причина в error
```

Общие поля:

```text
ok           boolean, true/false
status_code  number, API-like код результата
status       string, короткий статус
error        string, только при ok=false
```

Статусы:

```text
200 ok / deleted          команда выполнена
201 created               клиент создан
400 bad_request           неверная команда, имя или аргумент
403 forbidden             команда запущена не от root
404 not_found             env-файл или клиент не найден
409 conflict              конфликт состояния или конфига
500 internal_error        внутренняя ошибка/зависимость
502 bad_gateway           Xray API вернул неожиданный ответ
503 service_unavailable   Xray Stats API недоступен
```

Ответы команд:

```text
vlessctl -j list
  status_code: 200
  fields: clients[]

vlessctl -j add [name]
  status_code: 201
  fields: requested_name, name, auto_incremented, uuid, created_at, link,
          qr_ansi_utf8, qr_png_mime, qr_png_base64, qr_png_data_uri

vlessctl -j show <name|number|all>
  status_code: 200
  fields: name, uuid, created_at, link
  for all: links[]

vlessctl -j qr <name|number|all>
  status_code: 200
  fields: name, link, qr_ansi_utf8, qr_png_mime, qr_png_base64, qr_png_data_uri
  for all: items[]

vlessctl -j traffic
  status_code: 200
  fields: clients[].uplink_bytes, clients[].downlink_bytes, clients[].total_bytes, total

vlessctl -j online [seconds]
  status_code: 200
  old fields kept: interval_seconds, tcp_connections, active_users, clients[].active,
                   clients[].uplink_bytes, clients[].downlink_bytes, clients[].total_bytes
  added fields: observed_at_epoch, observed_at, online_users, last_seen_state_file,
                clients[].online, clients[].online_source,
                clients[].last_seen_epoch, clients[].last_seen_at,
                clients[].last_seen, clients[].last_seen_source

vlessctl -j logs status
  status_code: 200
  fields: enabled, retention_days, frontend_mode, xray_access_log, xray_error_log,
          nginx_access_log, logrotate_config, nginx_log_format

vlessctl -j delete <name|number>
  status_code: 200
  fields: name, uuid, created_at
```

#### Совместимость JSON Для Ботов

`vlessctl -j online` расширяется без удаления старых полей. Если бот читает JSON по именам ключей, обновлять его не обязательно: старые поля `active_users`, `clients[].active`, `clients[].uplink_bytes`, `clients[].downlink_bytes`, `clients[].total_bytes`, `clients[].uplink`, `clients[].downlink` и `clients[].total` остаются.

Обновление бота нужно только если у него строгая схема, где запрещены лишние поля, или если он сравнивает JSON как строку. В таком случае разрешите дополнительные поля и не привязывайтесь к порядку ключей.

Для нового отображения онлайна используйте:

```text
online_users                 сколько клиентов онлайн сейчас
clients[].online             true/false по каждому клиенту
clients[].online_source      xray_stats_online или traffic_delta
clients[].last_seen_epoch    Unix time последнего наблюдения, может быть null
clients[].last_seen_at       UTC-время последнего наблюдения, может быть null
```

`active_users` и `clients[].active` оставлены для старой логики и означают "был трафик за выбранный интервал". Для "кто онлайн сейчас" лучше использовать `online_users` и `clients[].online`.

Если боту нужен свежий `last_seen`, запускайте `vlessctl -j online <seconds>` периодически. Команда не хранит историю сама по себе и обновляет `last_seen_*` только в момент проверки.

Важно: `link`, `qr_png_base64` и `qr_png_data_uri` содержат секрет клиента. Не пишите эти ответы в публичные логи.

Для Telegram-бота декодируйте `qr_png_base64` и отправляйте bytes как photo/document. Для сайта отдавайте `image/png` из своего backend API или показывайте `qr_png_data_uri`, если JSON не попадает в публичные логи.

Пересобрать конфиг и перезапустить Xray:

```bash
vlessctl restart
```

### Трафик И Онлайн

Посмотреть сколько трафика прошло по каждому пользователю:

```bash
vlessctl traffic
```

Пример вывода:

```text
name                           uplink       downlink          total
ivan                         12.40 MiB     840.12 MiB     852.52 MiB
petr                          1.10 MiB      24.30 MiB      25.40 MiB
TOTAL                        13.50 MiB     864.42 MiB     877.92 MiB
```

Посмотреть кто передавал трафик за последние 10 секунд:

```bash
vlessctl online
```

Можно указать другой интервал:

```bash
vlessctl online 30
```

`online` не пишет access-логи и не хранит IP клиентов. Команда делает два замера счётчиков Xray и показывает пользователей, у которых за выбранный интервал изменился uplink/downlink. Старое поле `active` означает именно "был трафик за интервал".

Для "кто онлайн сейчас" команда использует Xray `statsUserOnline`, если эта метрика доступна. Тогда `clients[].online` показывает idle-клиентов тоже. Если установленная версия Xray не отдаёт online-метрику, `online` fallback-режимом совпадает с `active`.

`last_seen_epoch` и `last_seen_at` обновляются, когда клиент виден онлайн через Xray online-метрику или когда у него был трафик за интервал. Состояние хранится в `/usr/local/etc/xray/online-state.json`. Это не исторический лог подключений: если `vlessctl online` не запускался, он не мог наблюдать клиента.

Счётчики Xray находятся в памяти процесса. После `systemctl restart xray` или `vlessctl restart` накопленные значения начнутся заново.

### Логи И Приватность

Установщик спрашивает:

```text
Enable nginx/Xray access logs? yes/no [no]:
```

По умолчанию ответ `no`: nginx access log отключён через `access_log off`, Xray access log не включается. В этом режиме скрипты не сохраняют историю входов, client IP и URL-запросы на диск.

Если ответить `yes`, будут включены:

```text
/var/log/nginx/vless-<PROXY_DOMAIN>-access.log
/var/log/xray/access.log
/var/log/xray/error.log
```

Включайте это только если вам нужна диагностика подключений. Для приватного режима оставляйте `no`.

Включить или выключить логи на уже установленном сервере можно без переустановки:

```bash
cd /root/telemt2
git pull
install -m 0755 /root/telemt2/vpn/vless/vlessctl.sh /usr/local/sbin/vlessctl
vlessctl logs status
vlessctl logs on
vlessctl logs off
vlessctl -j logs status
```

`vlessctl logs on` включает Xray access log, пересобирает Xray config, перезапускает Xray и, в режиме `mask`, включает nginx access log. Пользователи, UUID и ссылки клиентов не меняются.

Для задачи "кто куда ходил" основной файл:

```text
/var/log/xray/access.log
```

Xray пишет имя VLESS-клиента как `email` и destination, например домен или IP:порт. Благодаря включенному sniffing многие HTTPS-запросы видны по SNI/домену, но если домен определить нельзя, в логе будет IP назначения.

Это access-метаданные, а не запись содержимого HTTPS/сообщений: логируются время, клиент, направление и техническая информация соединения.

Для реального внешнего IP клиента в режиме `mask` используйте nginx-лог:

```text
/var/log/nginx/vless-<PROXY_DOMAIN>-access.log
```

Строки nginx пишутся с маркером `[ip=<client-ip>]`, чтобы было удобно фильтровать:

```bash
grep '\[ip=1.2.3.4\]' /var/log/nginx/vless-<PROXY_DOMAIN>-access.log
```

Ротация ставится в `/etc/logrotate.d/vless-xray`: каждый день отдельный файл, хранить 7 дней, старые файлы с суффиксом даты `YYYYMMDD`.

Что можно узнать без логирования:

1. Список пользователей: `vlessctl list`.
2. Накопленный трафик по пользователям с момента старта Xray: `vlessctl traffic`.
3. Кто реально передавал трафик за последние N секунд: `vlessctl online 30`.
4. Кто онлайн сейчас, если Xray отдаёт `statsUserOnline`: `vlessctl -j online 5`.
5. Когда клиент последний раз был замечен online/active: поля `last_seen_epoch` и `last_seen_at`.
6. Общее число локальных TCP-соединений nginx -> Xray в момент проверки: выводится в `vlessctl online`.

Что нельзя надёжно узнать без включения логов:

1. Историю IP клиентов.
2. Точный user -> IP для прошлых подключений.
3. Кто был подключён, но долго ничего не передавал.

### Проверка После Установки

```bash
systemctl status xray
systemctl status nginx
cat /root/vless-links.txt
vlessctl list
vlessctl traffic
vlessctl online
```

Проверка сертификата:

```bash
systemctl status certbot.timer
certbot renew --dry-run
```

### Повторный Запуск

Скрипт сохраняет введённые ответы и историю успешных шагов:

```text
/root/.install_vless.state
/root/.install_vless.config
```

Если SSH-сессия оборвалась или установка упала на середине, зайдите на сервер снова и запустите:

```bash
/root/install_vless.sh
```

Скрипт подставит сохранённые значения по умолчанию и пропустит шаги, которые уже завершились успешно. Например, если сертификат уже выпущен, он начнёт со следующего незавершённого этапа.

Подтверждение плана установки тоже сохраняется. Если установка оборвалась после `y`, при повторном запуске скрипт не будет спрашивать подтверждение заново и продолжит с первого незавершённого шага.

Чтобы начать установку заново без учёта state-файла:

```bash
RESET_INSTALL_STATE=1 /root/install_vless.sh
```

Это удаляет только state/config установщика. Уже установленные пакеты, сертификаты, nginx/Xray-конфиги и пользователи автоматически не удаляются.

Если `/usr/local/etc/xray/vless.env` уже существует, установщик спросит:

```text
Existing VLESS install detected: /usr/local/etc/xray/vless.env
Reconfigure this VLESS installation? [y/N]:
```

При `y` он сделает backup конфигов в `/root/vless-install-backups/<DATE>/` и пересоберёт установку.

---

## EN

`install_vless.sh` installs VLESS through Xray on a new Debian/Ubuntu server.

There are two modes:

1. `mask` — a normal HTTPS website on your domain. A DNS `A` record is required, Let's Encrypt is issued, and nginx is used as the public frontend.
2. `direct` — no mask site. You can use the server public IP, no certificate is issued, and Xray listens on the public port directly.

Mask mode layout:

```text
Internet
  -> https://<PROXY_DOMAIN>:443/
  -> nginx + Let's Encrypt TLS
     -> /                     normal HTML page
     -> <VLESS_PATH>          proxy_pass to 127.0.0.1:<LOCAL_XRAY_PORT>
        -> Xray VLESS WebSocket
```

Direct mode layout:

```text
Internet
  -> ws://<SERVER_PUBLIC_IP>:443<VLESS_PATH>
  -> Xray VLESS WebSocket
```

### Important: Clean Server Only

Use this installer only on a clean Debian/Ubuntu server.

In `mask` mode, the script configures nginx, certbot, Xray, and firewall and uses `80/tcp` and `443/tcp` by default.

In `direct` mode, the script does not install the nginx mask site and does not issue a certificate; the external VLESS WebSocket port is `443/tcp` by default.

If Telemt, nginx, Apache, Caddy, a hosting panel, VPN/proxy, or another HTTPS service is already running, port and config conflicts are likely. Use a separate server, a different external port, or manual integration.

### Requirements Before Running

1. A new Debian/Ubuntu VPS/server.
2. Root SSH access.
3. For `mask` mode: a domain with an A record pointing to the server public IPv4:

```text
<PROXY_DOMAIN> -> <SERVER_PUBLIC_IP>
```

For `direct` mode, the server public IPv4 can be used without a domain.

4. Open incoming ports:

```text
80/tcp   Let's Encrypt HTTP challenge, mask mode only
443/tcp  HTTPS frontend in mask mode or direct VLESS WebSocket in direct mode
```

5. `install_vless.sh` and `vlessctl.sh` must be next to each other on the server.

### How To Download Files To The Server

If the files are already on your computer, copy them with `scp`:

```bash
scp install_vless.sh vlessctl.sh root@<SERVER_PUBLIC_IP>:/root/
```

If the files are in GitHub, download them directly with `wget`:

```bash
wget -O /root/install_vless.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/vpn/vless/install_vless.sh
wget -O /root/vlessctl.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/vpn/vless/vlessctl.sh
chmod +x /root/install_vless.sh /root/vlessctl.sh
```

The same with `curl`:

```bash
curl -fsSL -o /root/install_vless.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/vpn/vless/install_vless.sh
curl -fsSL -o /root/vlessctl.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/vpn/vless/vlessctl.sh
chmod +x /root/install_vless.sh /root/vlessctl.sh
```

If you specifically want to use `git`, download only the needed directory with sparse checkout:

```bash
apt-get update
apt-get install -y git
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt2
cd /tmp/telemt2
git sparse-checkout set vpn/vless
cp vpn/vless/install_vless.sh vpn/vless/vlessctl.sh /root/
chmod +x /root/install_vless.sh /root/vlessctl.sh
```

### Run

Log in to the server and run the installer:

```bash
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_vless.sh /root/vlessctl.sh
/root/install_vless.sh -lang en
```

For longer installations, use `tmux`:

```bash
tmux new -s vless-install
chmod +x /root/install_vless.sh /root/vlessctl.sh
/root/install_vless.sh -lang en
```

Non-interactive mode:

```bash
PUBLIC_HOST=<PROXY_DOMAIN> /root/install_vless.sh --auto -lang en
```

Direct mode without a domain:

```bash
/root/install_vless.sh --direct --auto -lang en
```

In `mask` mode, auto install does not guess the domain: set `PUBLIC_HOST`. If the first client is not set, `pipiska1` is used. Use `-lang ru` or `-lang en` to choose the installer prompt/output language.

### Installer Prompts

Full dialogue example:

```text
Use domain + HTTPS mask site? yes/no [yes]: <Enter>
Proxy domain: <PROXY_DOMAIN>
Let's Encrypt email [admin@<PROXY_DOMAIN>]: <Enter>
First client name [pipiska1]: <Enter>
HTTPS/VLESS external port [443]: <Enter>
Local Xray port [12710]: <Enter>
VLESS WebSocket path [/vless-<RANDOM>]: <Enter>
Enable nginx/Xray access logs? yes/no [no]: <Enter>

server_public_ipv4=<SERVER_PUBLIC_IP>
domain_ipv4=<SERVER_PUBLIC_IP>

Install plan:
  mode:         mask
  domain:       <PROXY_DOMAIN>
  public IPv4:  <SERVER_PUBLIC_IP>
  email:        admin@<PROXY_DOMAIN>
  HTTPS port:   443
  local port:   12710
  stats API:    127.0.0.1:10085
  VLESS path:   /vless-<RANDOM>
  access logs:  no
  first client: pipiska1

Type y or yes to continue:
y
```

Direct mode example:

```text
Use domain + HTTPS mask site? yes/no [yes]: no
Server IP/host for VLESS link [<SERVER_PUBLIC_IP>]: <Enter>
First client name [pipiska1]: <Enter>
HTTPS/VLESS external port [443]: <Enter>
VLESS WebSocket path [/vless-<RANDOM>]: <Enter>
Enable Xray access logs? yes/no [no]: <Enter>

Install plan:
  mode:         direct
  domain:       <SERVER_PUBLIC_IP>
  public IPv4:  <SERVER_PUBLIC_IP>
  email:        not used
  HTTPS port:   443
  local port:   443
  stats API:    127.0.0.1:10085
  VLESS path:   /vless-<RANDOM>
  access logs:  no
  first client: pipiska1

Type y or yes to continue:
y
```

How to answer:

1. `Use domain + HTTPS mask site?` selects `mask` with `yes` or `direct` with `no`.
2. In `mask` mode, `Proxy domain` is your domain with an A record pointing to the server.
3. In `direct` mode, `Server IP/host for VLESS link` is the server public IP or a domain that already points to the server.
4. `Let's Encrypt email` is asked only in `mask` mode; press Enter to use `admin@<PROXY_DOMAIN>`.
5. `First client name` is the first client. Press Enter to use `pipiska1`.
6. `HTTPS/VLESS external port` is the public port. Default is `443`.
7. `Local Xray port` is asked only in `mask` mode. Usually keep `12710`.
8. `VLESS WebSocket path` is the secret path. Usually keep the auto-generated value.
9. `Enable nginx/Xray access logs? yes/no` in `mask` mode or `Enable Xray access logs? yes/no` in `direct` mode defaults to `no`.
10. After the install plan, type `y` or `yes`.

DNS is checked before `apt update` and before package installation. If `mask` mode is selected but the A record is missing, non-public, or does not point to this server, the script shows the problem and asks:

```text
Continue without mask using <SERVER_PUBLIC_IP>? [y/N]:
```

If you answer `y`, installation continues in `direct` mode without a domain, mask site, or certificate.

Before the install-plan confirmation (`Type y or yes to continue`), the installer does not install packages and does not change nginx/Xray. It only collects answers, saves the resume file, checks DNS, and, if `ss` is already available, checks busy ports early.

If external `443/tcp`, local Xray `12710/tcp`, or Stats API `10085/tcp` is busy, the script prints the listener, suggests the next free port, and lets you accept it or enter your own. In `--auto` mode, the free port is selected automatically and printed. If `80/tcp` is busy in `mask` mode, the script explains that Let's Encrypt needs that port and offers switching to `direct` mode or freeing `80/tcp`.

After `y`, installation starts. In `mask` mode, nginx, certbot, and Xray are installed, a Let's Encrypt certificate is issued, a mask HTML page is created, and nginx/Xray configs are written. In `direct` mode, Xray is installed and listens on the public port directly. In both modes, the local Xray Stats API is enabled on `127.0.0.1:10085`, the selected logging mode is applied, services are started, and firewall rules are opened through `ufw` if `ufw` is active.

By default, Xray enables sniffing for `http`, `tls`, and `quic`, and outgoing connections prefer IPv4. This is useful for VPS providers without working IPv6: if a phone or app chooses an IPv6 destination first, Xray tries to recover the domain and connect through IPv4. If the server has proper IPv6 and you want to use it, run the installer with `XRAY_FORCE_IPV4=0`.

Network operations are retried up to 3 times: `apt update`, package installation, certificate issuance, Xray installer download, and Xray installation. This helps with temporary network or GitHub failures. You can override attempts and delay:

```bash
INSTALL_RETRIES=5 RETRY_DELAY_SECONDS=10 /root/install_vless.sh
```

### Preflight Checks

Before the main install, the script checks:

1. Running as root.
2. Debian/Ubuntu OS.
3. systemd availability.
4. Domain A record before package installation.
5. Public A record matching the server public IPv4.
6. `80/tcp` for Let's Encrypt in `mask` mode.
7. Free external HTTPS/VLESS port; if busy, another port is suggested.
8. Free local Xray port in `mask` mode; if busy, another port is suggested.
9. Free local Xray Stats API port `10085/tcp`; if busy, another port is suggested.
10. No foreign nginx sites on the server.
11. No existing unmanaged Xray config.

If a check fails, installation stops before changing services.

### Installed Components

```text
nginx
certbot (mask mode only)
Xray-core
jq
curl
openssl
iproute2
unzip
qrencode
logrotate
ca-certificates
```

Created files:

```text
/usr/local/etc/xray/vless.env
/usr/local/etc/xray/users.json
/usr/local/etc/xray/config.json
/usr/local/sbin/vlessctl
/etc/nginx/sites-available/vless-<PROXY_DOMAIN>.conf
/etc/nginx/conf.d/vless-log-format.conf
/etc/logrotate.d/vless-xray
/var/www/<PROXY_DOMAIN>/index.html
/root/vless-links.txt
/root/.install_vless.state
/root/.install_vless.config
```

If access logs are enabled during installation, these files are also used:

```text
/var/log/nginx/vless-<PROXY_DOMAIN>-access.log
/var/log/xray/access.log
/var/log/xray/error.log
/etc/logrotate.d/vless-xray
```

### User Management

After installation, use `vlessctl`.

`vlessctl` is installed as `/usr/local/sbin/vlessctl`, so root can run it from any directory.

Add a user:

```bash
vlessctl add
```

Dialogue:

```text
Имя клиента [pipiska1]: petr
Клиент добавлен: petr
vless://<UUID>@<PROXY_DOMAIN>:443?...
QR для импорта:
<terminal QR code>
```

If you run `vlessctl add` without a name and press Enter, `pipiska1` is created. If that name already exists, the next free numbered name is used: `pipiska2`, `pipiska3`, and so on.

Delete a user:

```bash
vlessctl delete
```

Dialogue:

```text
Текущие клиенты:
1) ivan
2) petr
Клиент для удаления: 2
Клиент удален: petr
```

List current users:

```bash
vlessctl list
```

Show a link:

```bash
vlessctl show
```

Dialogue:

```text
Текущие клиенты:
1) ivan
Клиент для показа, или all: 1
vless://<UUID>@<PROXY_DOMAIN>:443?...
```

Show all links:

```bash
vlessctl show all
```

Show a link and QR code:

```bash
vlessctl qr
```

Dialogue:

```text
Текущие клиенты:
1) ivan
Клиент для показа QR, или all: 1
vless://<UUID>@<PROXY_DOMAIN>:443?...
QR для импорта:
<terminal QR code>
```

For scripts, use JSON mode. The flag can be placed before or after the command:

```bash
vlessctl -j list
vlessctl traffic --json
vlessctl -j add client1
vlessctl -j show client1
vlessctl -j qr client1
```

In JSON mode, `add`, `show`, and `qr` return the VLESS link in `link`; `add` and `qr` also return PNG QR data in `qr_png_base64` and `qr_png_data_uri`; `traffic` and `online` return numeric byte counters. The `online` response is extended by adding fields; existing fields are not removed.

#### JSON Responses

`vlessctl` is still a CLI tool, so shell scripts should primarily use the process exit code. `status_code` is API-like and mirrors HTTP-style meanings for easier wrappers.

```text
exit 0 + ok=true   = command succeeded
exit 1 + ok=false  = command failed, reason is in error
```

Common fields:

```text
ok           boolean, true/false
status_code  number, API-like result code
status       string, short status
error        string, only when ok=false
```

Statuses:

```text
200 ok / deleted          command succeeded
201 created               client created
400 bad_request           invalid command, name, or argument
403 forbidden             command was not run as root
404 not_found             env file or client was not found
409 conflict              state/config conflict
500 internal_error        internal error/dependency problem
502 bad_gateway           Xray API returned unexpected output
503 service_unavailable   Xray Stats API is unavailable
```

Command responses:

```text
vlessctl -j list
  status_code: 200
  fields: clients[]

vlessctl -j add [name]
  status_code: 201
  fields: requested_name, name, auto_incremented, uuid, created_at, link,
          qr_ansi_utf8, qr_png_mime, qr_png_base64, qr_png_data_uri

vlessctl -j show <name|number|all>
  status_code: 200
  fields: name, uuid, created_at, link
  for all: links[]

vlessctl -j qr <name|number|all>
  status_code: 200
  fields: name, link, qr_ansi_utf8, qr_png_mime, qr_png_base64, qr_png_data_uri
  for all: items[]

vlessctl -j traffic
  status_code: 200
  fields: clients[].uplink_bytes, clients[].downlink_bytes, clients[].total_bytes, total

vlessctl -j online [seconds]
  status_code: 200
  old fields kept: interval_seconds, tcp_connections, active_users, clients[].active,
                   clients[].uplink_bytes, clients[].downlink_bytes, clients[].total_bytes
  added fields: observed_at_epoch, observed_at, online_users, last_seen_state_file,
                clients[].online, clients[].online_source,
                clients[].last_seen_epoch, clients[].last_seen_at,
                clients[].last_seen, clients[].last_seen_source

vlessctl -j logs status
  status_code: 200
  fields: enabled, retention_days, frontend_mode, xray_access_log, xray_error_log,
          nginx_access_log, logrotate_config, nginx_log_format

vlessctl -j delete <name|number>
  status_code: 200
  fields: name, uuid, created_at
```

#### JSON Compatibility For Bots

`vlessctl -j online` is extended without removing existing fields. If your bot reads JSON by key names, you do not have to update it: the old fields `active_users`, `clients[].active`, `clients[].uplink_bytes`, `clients[].downlink_bytes`, `clients[].total_bytes`, `clients[].uplink`, `clients[].downlink`, and `clients[].total` remain.

Update the bot only if it uses a strict schema that rejects extra fields, or if it compares the whole JSON response as a string. In that case, allow additional fields and do not depend on object key order.

For the new online display, use:

```text
online_users                 number of clients online now
clients[].online             true/false per client
clients[].online_source      xray_stats_online or traffic_delta
clients[].last_seen_epoch    Unix time of last observation, can be null
clients[].last_seen_at       UTC last observation time, can be null
```

`active_users` and `clients[].active` are kept for old logic and mean "had traffic during the selected interval". For "who is online now", prefer `online_users` and `clients[].online`.

If your bot needs fresh `last_seen`, run `vlessctl -j online <seconds>` periodically. The command is not a history logger by itself and updates `last_seen_*` only when a check runs.

Important: `link`, `qr_png_base64`, and `qr_png_data_uri` contain the client secret. Do not write these responses to public logs.

Telegram bot: decode `qr_png_base64` and send the bytes as photo/document. Website backend: serve decoded bytes as `image/png`, or use `qr_png_data_uri` if the JSON is not written to public logs.

Rebuild config and restart Xray:

```bash
vlessctl restart
```

### Traffic And Online

Show traffic per user:

```bash
vlessctl traffic
```

Example output:

```text
name                           uplink       downlink          total
ivan                         12.40 MiB     840.12 MiB     852.52 MiB
petr                          1.10 MiB      24.30 MiB      25.40 MiB
TOTAL                        13.50 MiB     864.42 MiB     877.92 MiB
```

Show who transferred traffic during the last 10 seconds:

```bash
vlessctl online
```

Use a custom interval:

```bash
vlessctl online 30
```

`online` does not write access logs and does not store client IPs. It samples Xray counters twice and marks users as active only when their uplink/downlink changes during the selected interval. The existing `active` field means "had traffic during the interval".

For "who is online now", the command uses Xray `statsUserOnline` when that metric is available. In that case, `clients[].online` also sees idle clients. If the installed Xray version does not return the online metric, `online` falls back to the same result as `active`.

`last_seen_epoch` and `last_seen_at` are updated when a client is seen online through the Xray online metric or when it has traffic during the interval. State is stored in `/usr/local/etc/xray/online-state.json`. This is not a historical connection log: if `vlessctl online` was not running, it could not observe the client.

Xray counters live in process memory. After `systemctl restart xray` or `vlessctl restart`, accumulated values start from zero again.

### Logs And Privacy

The installer asks:

```text
Enable nginx/Xray access logs? yes/no [no]:
# or, in direct mode:
Enable Xray access logs? yes/no [no]:
```

The default answer is `no`: in `mask` mode nginx access log is disabled with `access_log off`, and in both modes Xray access log is not enabled. In this mode, the scripts do not save login history, client IPs, or requested URLs to disk.

If you answer `yes`, these files are enabled:

```text
/var/log/nginx/vless-<PROXY_DOMAIN>-access.log   mask mode only
/var/log/xray/access.log
/var/log/xray/error.log
```

Enable this only when you need connection diagnostics. For private mode, keep `no`.

Enable or disable logs on an already installed server without reinstalling:

```bash
cd /root/telemt2
git pull
install -m 0755 /root/telemt2/vpn/vless/vlessctl.sh /usr/local/sbin/vlessctl
vlessctl logs status
vlessctl logs on
vlessctl logs off
vlessctl -j logs status
```

`vlessctl logs on` enables Xray access logs, rebuilds the Xray config, restarts Xray, and, in `mask` mode, enables the nginx access log. Existing users, UUIDs, and client links are not changed.

For "who visited where", the main file is:

```text
/var/log/xray/access.log
```

Xray writes the VLESS client name as `email` and the destination, for example a domain or IP:port. Because sniffing is enabled, many HTTPS requests are visible by SNI/domain; when the domain cannot be detected, the destination IP is logged.

These are access metadata, not HTTPS/message contents: the logs contain time, client, destination, and technical connection details.

For the real external client IP in `mask` mode, use the nginx log:

```text
/var/log/nginx/vless-<PROXY_DOMAIN>-access.log
```

Nginx lines include the `[ip=<client-ip>]` marker for filtering:

```bash
grep '\[ip=1.2.3.4\]' /var/log/nginx/vless-<PROXY_DOMAIN>-access.log
```

Rotation is installed in `/etc/logrotate.d/vless-xray`: one file per day, keep 7 days, old files use the `YYYYMMDD` date suffix.

What you can see without logging:

1. User list: `vlessctl list`.
2. Accumulated traffic per user since Xray start: `vlessctl traffic`.
3. Users that transferred traffic during the last N seconds: `vlessctl online 30`.
4. Users online now, if Xray returns `statsUserOnline`: `vlessctl -j online 5`.
5. Last time a client was observed online/active: `last_seen_epoch` and `last_seen_at`.
6. Current total TCP connections to Xray: printed by `vlessctl online`.

What you cannot reliably see without enabling logs:

1. Historical client IPs.
2. Exact historical user -> IP mapping.
3. Clients that are connected but idle for a long time.

### Checks After Install

```bash
systemctl status xray
systemctl status nginx   # mask mode only
cat /root/vless-links.txt
vlessctl list
vlessctl traffic
vlessctl online
```

Certificate renewal check:

```bash
systemctl status certbot.timer
certbot renew --dry-run
```

Certificate renewal exists only in `mask` mode.

### Rerun

The installer saves entered answers and successful step history:

```text
/root/.install_vless.state
/root/.install_vless.config
```

If the SSH session disconnects or installation fails halfway through, log in again and run:

```bash
/root/install_vless.sh
```

The script will reuse saved values as defaults and skip steps that already finished successfully. For example, if the certificate has already been issued, it will continue from the next unfinished stage.

The install-plan confirmation is saved too. If installation stops after you typed `y`, the next run will not ask for confirmation again and will continue from the first unfinished step.

To restart installation without using the state file:

```bash
RESET_INSTALL_STATE=1 /root/install_vless.sh
```

This removes only the installer state/config files. Already installed packages, certificates, nginx/Xray configs, and users are not removed automatically.

If `/usr/local/etc/xray/vless.env` already exists, the installer asks:

```text
Existing VLESS install detected: /usr/local/etc/xray/vless.env
Reconfigure this VLESS installation? [y/N]:
```

If you answer `y`, it backs up configs to `/root/vless-install-backups/<DATE>/` and rebuilds the installation.
