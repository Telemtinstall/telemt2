# Experimental WireGuard obfuscation

> RU: Это экспериментальный Bash-установщик из этого репозитория, а не официальный установщик WireGuard или wstunnel. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is an experimental Bash installer from this repository, not an official WireGuard or wstunnel installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

## RU

Это экспериментальный каталог. Обычный стабильный WireGuard-установщик лежит в `wg/`.

Сейчас здесь автоматизирован первый рабочий вариант:

```text
WireGuard UDP -> wstunnel WebSocket -> nginx TLS 443 -> Internet
```

Снаружи сервер выглядит как обычный HTTPS-сайт:

```text
https://<domain>/
```

А туннель идет через секретный WebSocket path:

```text
wss://<domain>/<secret-path>
```

### Важное ограничение

Стандартное приложение WireGuard на iPhone не умеет само запускать `wstunnel`, `udp2raw` или `gost`. Поэтому этот экспериментальный вариант подходит для Linux/macOS/Windows/роутеров, где можно запустить локальный `wstunnel client`, а потом включить WireGuard.

Для iPhone отдельным следующим вариантом лучше делать:

```text
AmneziaWG через AmneziaVPN
или
sing-box/Streisand-подобный клиент с отдельным конфигом
```

Это уже не будет “обычный WireGuard app + один QR”, там нужна отдельная клиентская программа.

### Как установить

Новая установка на чистом сервере:

```bash
apt update
apt install -y git ca-certificates
cd /root
git clone https://github.com/Telemtinstall/telemt2.git telemt2
cd /root/telemt2
git pull
cd /root/telemt2/vpn/wg-experimental
chmod +x ./install_wg_wstunnel.sh ./wgctl.sh
./install_wg_wstunnel.sh
```

Если репозиторий уже скачан:

```bash
cd /root/telemt2
git pull
cd /root/telemt2/vpn/wg-experimental
chmod +x ./install_wg_wstunnel.sh ./wgctl.sh
./install_wg_wstunnel.sh
```

Обновить локальные файлы из репозитория:

```bash
cd /root/telemt2 && git pull
```

Скрипт рассчитан на чистый сервер. Порты `80/tcp` и `443/tcp` должны быть свободны.

### Что спрашивает установщик

```text
Mask domain with DNS A record to this server
Let's Encrypt email [admin@<domain>]
Secret WebSocket path prefix without leading slash [ws-xxxxxxxxxxxxxxxx]
Local wstunnel backend TCP port [12780]
WireGuard interface [wg0]
Local WireGuard UDP port on server [51820]
VPN IPv4 subnet [10.77.77.0/24]
Server VPN IPv4 [10.77.77.1]
Client DNS, comma separated IPv4 [1.1.1.1,8.8.8.8]
WireGuard endpoint host inside client config [127.0.0.1]
WireGuard endpoint port inside client config [51820]
WireGuard client MTU [1300]
First client name
Enable nginx access logs for mask site? yes/no [no]
```

### Что делает установщик

```text
1. Проверяет A-запись домена: домен должен указывать на IPv4 сервера.
2. Проверяет свободные порты 80/tcp, 443/tcp, backend wstunnel и локальный WG UDP.
3. Ставит wireguard-tools, nginx, certbot, qrencode и базовые утилиты.
4. Скачивает wstunnel из GitHub Releases.
5. Создает WireGuard wg0.
6. Закрывает прямой внешний доступ к локальному UDP-порту WireGuard через iptables.
7. Создает nginx-сайт-приманку.
8. Выпускает SSL через Let's Encrypt.
9. Проксирует секретный WebSocket path в локальный wstunnel.
10. Запускает wg-quick@wg0 и wstunnel-wg.service.
11. Создает первого клиента.
```

### Как работает подключение клиента

На клиентской машине сначала запускается wstunnel:

```bash
/root/wg-clients/<name>-wstunnel-client.sh
```

Он открывает локальный UDP-порт:

```text
127.0.0.1:51820
```

Потом WireGuard подключается не к серверу напрямую, а к локальному wstunnel:

```text
Endpoint = 127.0.0.1:51820
```

Схема:

```text
WireGuard app -> 127.0.0.1:51820/udp
local wstunnel client -> wss://<domain>/<secret-path>
nginx TLS 443 -> local wstunnel server
local wstunnel server -> 127.0.0.1:51820/udp -> WireGuard server
```

Если WireGuard на клиенте отправляет весь трафик через VPN (`AllowedIPs = 0.0.0.0/0`), нужно следить, чтобы само подключение `wstunnel` к `<domain>:443` не ушло внутрь этого же VPN. На Linux/macOS/роутере это обычно решается отдельным route до IP сервера через обычный gateway.

### Управление клиентами

```bash
wgctl add
wgctl delete
wgctl list
wgctl show
wgctl qr
wgctl traffic
```

Файлы клиента:

```text
/root/wg-clients/<name>.conf
/root/wg-clients/<name>-wstunnel-client.sh
```

### Логи и приватность

По умолчанию nginx access logs выключены:

```text
access_log off
error_log /dev/null crit
```

WireGuard показывает только текущие счетчики:

```bash
wgctl traffic
```

### Resume

Если SSH оборвался, запустите установщик снова:

```bash
./install_wg_wstunnel.sh
```

Начать заново:

```bash
RESET_INSTALL_STATE=1 ./install_wg_wstunnel.sh
```

### Что дальше

Следующие экспериментальные варианты лучше делать отдельными установщиками:

```text
udp2raw:
  WireGuard UDP -> udp2raw fake TCP/ICMP/UDP
  Хорошо для Linux/Android/роутеров, плохо для обычного iPhone.

gost:
  WireGuard UDP -> gost relay over TLS/WebSocket
  Нужен gost на клиенте.

AmneziaWG:
  Самый перспективный вариант для iPhone через AmneziaVPN.

sing-box:
  Перспективно для iPhone, но схема будет уже не стандартный WireGuard app.
```

## EN

This is an experimental directory. The stable WireGuard installer is in `wg/`.

Currently automated mode:

```text
WireGuard UDP -> wstunnel WebSocket -> nginx TLS 443 -> Internet
```

From the outside, the server looks like a normal HTTPS site:

```text
https://<domain>/
```

The tunnel uses a secret WebSocket path:

```text
wss://<domain>/<secret-path>
```

### Important limitation

The standard WireGuard iPhone app cannot run `wstunnel`, `udp2raw`, or `gost` by itself. This experimental mode is suitable for Linux/macOS/Windows/routers where you can run a local `wstunnel client` before enabling WireGuard.

For iPhone, the next practical options are:

```text
AmneziaWG through AmneziaVPN
or
sing-box/Streisand-like client with its own config
```

That will not be “standard WireGuard app plus one QR”; it needs a separate client app.

### Install

```bash
chmod +x ./install_wg_wstunnel.sh ./wgctl.sh
./install_wg_wstunnel.sh
```

Use a clean server. Ports `80/tcp` and `443/tcp` must be free.

### Installer prompts

```text
Mask domain with DNS A record to this server
Let's Encrypt email [admin@<domain>]
Secret WebSocket path prefix without leading slash [ws-xxxxxxxxxxxxxxxx]
Local wstunnel backend TCP port [12780]
WireGuard interface [wg0]
Local WireGuard UDP port on server [51820]
VPN IPv4 subnet [10.77.77.0/24]
Server VPN IPv4 [10.77.77.1]
Client DNS, comma separated IPv4 [1.1.1.1,8.8.8.8]
WireGuard endpoint host inside client config [127.0.0.1]
WireGuard endpoint port inside client config [51820]
WireGuard client MTU [1300]
First client name
Enable nginx access logs for mask site? yes/no [no]
```

### Installer actions

```text
1. Checks that the domain A record points to the server IPv4.
2. Checks ports 80/tcp, 443/tcp, local wstunnel backend, and local WG UDP.
3. Installs wireguard-tools, nginx, certbot, qrencode, and base tools.
4. Downloads wstunnel from GitHub Releases.
5. Creates WireGuard wg0.
6. Blocks direct external access to the local WireGuard UDP port through iptables.
7. Creates an nginx mask site.
8. Issues a Let's Encrypt certificate.
9. Proxies the secret WebSocket path to local wstunnel.
10. Starts wg-quick@wg0 and wstunnel-wg.service.
11. Creates the first client.
```

### Client connection flow

Run wstunnel first on the client machine:

```bash
/root/wg-clients/<name>-wstunnel-client.sh
```

It opens a local UDP port:

```text
127.0.0.1:51820
```

WireGuard then connects to local wstunnel:

```text
Endpoint = 127.0.0.1:51820
```

Flow:

```text
WireGuard app -> 127.0.0.1:51820/udp
local wstunnel client -> wss://<domain>/<secret-path>
nginx TLS 443 -> local wstunnel server
local wstunnel server -> 127.0.0.1:51820/udp -> WireGuard server
```

If the WireGuard client routes all traffic through VPN (`AllowedIPs = 0.0.0.0/0`), make sure the `wstunnel` connection to `<domain>:443` does not get routed into the same VPN. On Linux/macOS/routers this is usually handled by adding a direct route to the server IP through the normal gateway.

### Client management

```bash
wgctl add
wgctl delete
wgctl list
wgctl show
wgctl qr
wgctl traffic
```

Client files:

```text
/root/wg-clients/<name>.conf
/root/wg-clients/<name>-wstunnel-client.sh
```

### Logs and privacy

nginx access logs are disabled by default:

```text
access_log off
error_log /dev/null crit
```

WireGuard exposes only current counters:

```bash
wgctl traffic
```

### Resume

If SSH disconnects, run the installer again:

```bash
./install_wg_wstunnel.sh
```

Start from scratch:

```bash
RESET_INSTALL_STATE=1 ./install_wg_wstunnel.sh
```
