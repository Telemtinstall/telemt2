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
/root/install_vless.sh
```

Для долгой установки лучше использовать `tmux`:

```bash
tmux new -s vless-install
chmod +x /root/install_vless.sh /root/vlessctl.sh
/root/install_vless.sh
```

### Что Спросит Установщик

Полный пример диалога:

```text
Use domain + HTTPS mask site? yes/no [yes]: <Enter>
Proxy domain: <PROXY_DOMAIN>
Let's Encrypt email [admin@<PROXY_DOMAIN>]: <Enter>
First client name: ivan
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
  first client: ivan

Type y or yes to continue:
y
```

Пример режима без маскировки:

```text
Use domain + HTTPS mask site? yes/no [yes]: no
Server IP/host for VLESS link [<SERVER_PUBLIC_IP>]: <Enter>
First client name: ivan
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
  first client: ivan

Type y or yes to continue:
y
```

Как отвечать:

1. `Use domain + HTTPS mask site?` — `yes` включает режим `mask`, `no` включает режим `direct`.
2. В режиме `mask`, `Proxy domain` — домен, который A-записью указывает на сервер.
3. В режиме `direct`, `Server IP/host for VLESS link` — публичный IP сервера или домен, который уже указывает на сервер.
4. `Let's Encrypt email` спрашивается только в режиме `mask`; можно нажать Enter, тогда будет `admin@<PROXY_DOMAIN>`.
5. `First client name` — имя первого клиента, например `ivan`.
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
6. Для режима `mask`: свободные `80/tcp`, внешний HTTPS-порт и локальный Xray-порт.
7. Для режима `direct`: свободный внешний VLESS WebSocket порт.
8. Свободный локальный порт Xray Stats API `10085/tcp`.
9. Отсутствие чужих nginx sites на сервере в режиме `mask`.
10. Отсутствие уже существующего чужого Xray-конфига.

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
ca-certificates
```

Создаются:

```text
/usr/local/etc/xray/vless.env
/usr/local/etc/xray/users.json
/usr/local/etc/xray/config.json
/usr/local/sbin/vlessctl
/etc/nginx/sites-available/vless-<PROXY_DOMAIN>.conf   только режим mask
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
```

### Управление Пользователями

После установки используйте `vlessctl`.

Добавить пользователя:

```bash
vlessctl add
```

Диалог:

```text
Client name: petr
Client added: petr
vless://<UUID>@<PROXY_DOMAIN>:443?...
QR code:
<terminal QR code>
```

Удалить пользователя:

```bash
vlessctl delete
```

Диалог:

```text
Current clients:
1) ivan
2) petr
Client to delete: 2
Client deleted: petr
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
Current clients:
1) ivan
Client to show, or all: 1
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
Current clients:
1) ivan
Client to show QR, or all: 1
vless://<UUID>@<PROXY_DOMAIN>:443?...
QR code:
<terminal QR code>
```

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

`online` не пишет логи и не хранит IP клиентов. Команда делает два замера счётчиков Xray и показывает пользователей, у которых за выбранный интервал изменился uplink/downlink. Если клиент подключён, но ничего не передаёт, он может быть idle и будет показан как `active no`.

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

Что можно узнать без логирования:

1. Список пользователей: `vlessctl list`.
2. Накопленный трафик по пользователям с момента старта Xray: `vlessctl traffic`.
3. Кто реально передавал трафик за последние N секунд: `vlessctl online 30`.
4. Общее число локальных TCP-соединений nginx -> Xray в момент проверки: выводится в `vlessctl online`.

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
/root/install_vless.sh
```

For longer installations, use `tmux`:

```bash
tmux new -s vless-install
chmod +x /root/install_vless.sh /root/vlessctl.sh
/root/install_vless.sh
```

### Installer Prompts

Full dialogue example:

```text
Use domain + HTTPS mask site? yes/no [yes]: <Enter>
Proxy domain: <PROXY_DOMAIN>
Let's Encrypt email [admin@<PROXY_DOMAIN>]: <Enter>
First client name: ivan
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
  first client: ivan

Type y or yes to continue:
y
```

Direct mode example:

```text
Use domain + HTTPS mask site? yes/no [yes]: no
Server IP/host for VLESS link [<SERVER_PUBLIC_IP>]: <Enter>
First client name: ivan
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
  first client: ivan

Type y or yes to continue:
y
```

How to answer:

1. `Use domain + HTTPS mask site?` selects `mask` with `yes` or `direct` with `no`.
2. In `mask` mode, `Proxy domain` is your domain with an A record pointing to the server.
3. In `direct` mode, `Server IP/host for VLESS link` is the server public IP or a domain that already points to the server.
4. `Let's Encrypt email` is asked only in `mask` mode; press Enter to use `admin@<PROXY_DOMAIN>`.
5. `First client name` is the first client, for example `ivan`.
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
6. Free `80/tcp`, external HTTPS port, and local Xray port.
7. Free local Xray Stats API port `10085/tcp`.
8. No foreign nginx sites on the server.
9. No existing unmanaged Xray config.

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
ca-certificates
```

Created files:

```text
/usr/local/etc/xray/vless.env
/usr/local/etc/xray/users.json
/usr/local/etc/xray/config.json
/usr/local/sbin/vlessctl
/etc/nginx/sites-available/vless-<PROXY_DOMAIN>.conf
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
```

### User Management

After installation, use `vlessctl`.

Add a user:

```bash
vlessctl add
```

Dialogue:

```text
Client name: petr
Client added: petr
vless://<UUID>@<PROXY_DOMAIN>:443?...
QR code:
<terminal QR code>
```

Delete a user:

```bash
vlessctl delete
```

Dialogue:

```text
Current clients:
1) ivan
2) petr
Client to delete: 2
Client deleted: petr
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
Current clients:
1) ivan
Client to show, or all: 1
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
Current clients:
1) ivan
Client to show QR, or all: 1
vless://<UUID>@<PROXY_DOMAIN>:443?...
QR code:
<terminal QR code>
```

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

`online` does not write logs and does not store client IPs. It samples Xray counters twice and marks users as active only when their uplink/downlink changes during the selected interval. If a client is connected but idle, it may be shown as `active no`.

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

What you can see without logging:

1. User list: `vlessctl list`.
2. Accumulated traffic per user since Xray start: `vlessctl traffic`.
3. Users that transferred traffic during the last N seconds: `vlessctl online 30`.
4. Current total TCP connections to Xray: printed by `vlessctl online`.

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
