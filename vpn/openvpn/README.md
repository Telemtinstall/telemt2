# OpenVPN installer

> RU: Это не официальный установщик OpenVPN. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is not an official OpenVPN installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

## RU

Каталог содержит два самостоятельных скрипта для Debian/Ubuntu:

### Быстрый старт

Новая установка на чистом сервере:

```bash
apt update
apt install -y git ca-certificates
cd /root
git clone https://github.com/Telemtinstall/telemt2.git telemt2
cd /root/telemt2
git pull
cd /root/telemt2/vpn/openvpn
chmod +x ./install_openvpn.sh ./openvpnctl.sh
./install_openvpn.sh
```

Если репозиторий уже скачан:

```bash
cd /root/telemt2
git pull
cd /root/telemt2/vpn/openvpn
chmod +x ./install_openvpn.sh ./openvpnctl.sh
./install_openvpn.sh
```

Обновить локальные файлы из репозитория:

```bash
cd /root/telemt2 && git pull
```

Скрипт рассчитан на чистый сервер. Если на машине уже заняты `80`, `443`, `50001` или стоит другой nginx/OpenVPN, сначала проверьте конфликты, иначе можно сломать существующий сервис.

### Что спрашивает установщик

```text
Public endpoint IP/host for clients [<detected_ip>]
OpenVPN UDP port and TCP port when mask is disabled [50001]
Enable HTTPS masking for TCP OpenVPN? yes/no [no]
```

Если включить HTTPS-маскировку, дополнительно спросит:

```text
Mask domain with DNS A record to this server
Let's Encrypt email [admin@<domain>]
TCP OpenVPN public HTTPS-mask port [443]
Local nginx HTTPS mask backend port [8443]
```

Потом общие параметры:

```text
TCP VPN IPv4 subnet CIDR [10.251.0.0/24]
UDP VPN IPv4 subnet CIDR [10.251.1.0/24]
Client DNS, comma separated IPv4 [1.1.1.1,8.8.8.8]
Max clients per OpenVPN listener [1000]
First username
Enable OpenVPN/nginx access logs? yes/no [no]
```

### Как работает схема

По умолчанию поднимаются два OpenVPN-сервиса:

```text
UDP: <endpoint>:50001/udp, dev vpn-udp, сеть 10.251.1.0/24
TCP: <endpoint>:50001/tcp, dev vpn-tcp, сеть 10.251.0.0/24
```

Авторизация сделана через логин/пароль:

```text
verify-client-cert none
username-as-common-name
duplicate-cn
auth-user-pass-verify /etc/openvpn/server/vpn-auth.sh via-file
tls-crypt /etc/openvpn/server/tc.key
```

То есть клиентам не выдаются отдельные сертификаты. У каждого пользователя свой логин и пароль, а `.ovpn` профиль общий по структуре.

### HTTPS-маскировка

Если включена маскировка, TCP-OpenVPN слушает `443/tcp`, а обычные HTTPS-запросы передаются через `port-share` в локальный nginx:

```text
Internet -> 443/tcp -> OpenVPN tcp-server
OpenVPN-клиент -> OpenVPN
Обычный HTTPS/curl/browser -> 127.0.0.1:8443 -> nginx mask site
```

Для маскировки нужен домен с A-записью на IPv4 сервера. Если A-записи нет или она указывает не на этот сервер, установщик предложит продолжить без маскировки.

Сертификат выпускается через Let's Encrypt и `certbot --webroot`. Автопродление включает `certbot.timer`.

### Логи и приватность

По умолчанию access logs выключены:

```text
OpenVPN log-append не пишется
nginx access_log off
nginx error_log /dev/null crit
```

Текущие подключения смотрятся через runtime status-файлы:

```text
/run/openvpn/server-udp.status
/run/openvpn/server-tcp.status
```

Это не долговременная история. После отключения клиента накопленная статистика без отдельных логов не хранится.

### Управление пользователями

`openvpnctl` устанавливается как системная команда в `/usr/local/sbin/openvpnctl` и доступен через `/usr/local/bin/openvpnctl`, поэтому его можно запускать из любого каталога.

```bash
openvpnctl add
openvpnctl delete
openvpnctl passwd
openvpnctl list
openvpnctl show
openvpnctl qr
openvpnctl traffic
```

Примеры:

```bash
openvpnctl add client1
openvpnctl show client1 credentials
openvpnctl show client1 tcp
openvpnctl qr client1 tcp
openvpnctl traffic
openvpnctl delete client1
```

Для Telegram-бота сейчас надёжнее отправлять готовые `.ovpn` и `credentials.txt` файлы. Терминальный QR из `openvpnctl qr` предназначен для ручного SSH-вывода; JSON-режим и PNG/base64 QR для OpenVPN пока не реализованы.

Файлы клиента сохраняются в:

```text
/root/openvpn-clients/<user>-udp.ovpn
/root/openvpn-clients/<user>-tcp.ovpn
/root/openvpn-clients/<user>-credentials.txt
```

`openvpnctl traffic` показывает активные подключения: протокол, username, реальный IP, VPN IP, received/sent bytes, время подключения.

### Resume

Установщик сохраняет состояние:

```text
/root/.install_openvpn.state
/root/.install_openvpn.config
/root/.install_openvpn.config.sha256
```

Если SSH оборвался, запустите скрипт снова, он продолжит с нужного шага. Если сохранённые ответы изменились, state выполненных шагов очищается и план установки проходит заново с новыми значениями.

Начать установку заново:

```bash
RESET_INSTALL_STATE=1 ./install_openvpn.sh
```

## EN

This directory contains two standalone scripts for Debian/Ubuntu:

```bash
chmod +x ./install_openvpn.sh ./openvpnctl.sh
./install_openvpn.sh
```

The installer is intended for a clean server. If ports `80`, `443`, `50001`, nginx, or another OpenVPN service are already in use, check conflicts first or you may break an existing service.

### Installer prompts

```text
Public endpoint IP/host for clients [<detected_ip>]
OpenVPN UDP port and TCP port when mask is disabled [50001]
Enable HTTPS masking for TCP OpenVPN? yes/no [no]
```

If HTTPS masking is enabled, it also asks:

```text
Mask domain with DNS A record to this server
Let's Encrypt email [admin@<domain>]
TCP OpenVPN public HTTPS-mask port [443]
Local nginx HTTPS mask backend port [8443]
```

Then common settings:

```text
TCP VPN IPv4 subnet CIDR [10.251.0.0/24]
UDP VPN IPv4 subnet CIDR [10.251.1.0/24]
Client DNS, comma separated IPv4 [1.1.1.1,8.8.8.8]
Max clients per OpenVPN listener [1000]
First username
Enable OpenVPN/nginx access logs? yes/no [no]
```

### Runtime layout

By default the installer starts two OpenVPN services:

```text
UDP: <endpoint>:50001/udp, dev vpn-udp, subnet 10.251.1.0/24
TCP: <endpoint>:50001/tcp, dev vpn-tcp, subnet 10.251.0.0/24
```

Authentication uses username/password:

```text
verify-client-cert none
username-as-common-name
duplicate-cn
auth-user-pass-verify /etc/openvpn/server/vpn-auth.sh via-file
tls-crypt /etc/openvpn/server/tc.key
```

Clients do not get individual certificates. Each user has a separate username and password, while profiles share the same structure.

### HTTPS masking

When masking is enabled, TCP OpenVPN listens on `443/tcp`, while normal HTTPS probes are forwarded by OpenVPN `port-share` to a local nginx site:

```text
Internet -> 443/tcp -> OpenVPN tcp-server
OpenVPN client -> OpenVPN
Normal HTTPS/curl/browser -> 127.0.0.1:8443 -> nginx mask site
```

Masking requires a domain with an A record pointing to the server IPv4. If the record is missing or points elsewhere, the installer offers to continue without masking.

The certificate is issued by Let's Encrypt through `certbot --webroot`. Renewal is enabled through `certbot.timer`.

### Logs and privacy

Access logs are disabled by default:

```text
OpenVPN log-append is not configured
nginx access_log off
nginx error_log /dev/null crit
```

Current sessions are read from runtime status files:

```text
/run/openvpn/server-udp.status
/run/openvpn/server-tcp.status
```

These files are not long-term history. Without persistent logs, disconnected clients do not keep cumulative traffic counters.

### User management

`openvpnctl` is installed as a system command at `/usr/local/sbin/openvpnctl` and exposed through `/usr/local/bin/openvpnctl`, so it can be run from any directory.

```bash
openvpnctl add
openvpnctl delete
openvpnctl passwd
openvpnctl list
openvpnctl show
openvpnctl qr
openvpnctl traffic
```

Examples:

```bash
openvpnctl add client1
openvpnctl show client1 credentials
openvpnctl show client1 tcp
openvpnctl qr client1 tcp
openvpnctl traffic
openvpnctl delete client1
```

For a Telegram bot, send the ready `.ovpn` and `credentials.txt` files. The terminal QR from `openvpnctl qr` is intended for manual SSH output; JSON mode and PNG/base64 QR are not implemented for OpenVPN yet.

Client files are saved to:

```text
/root/openvpn-clients/<user>-udp.ovpn
/root/openvpn-clients/<user>-tcp.ovpn
/root/openvpn-clients/<user>-credentials.txt
```

`openvpnctl traffic` shows active sessions: protocol, username, real IP, VPN IP, received/sent bytes, and connection time.

### Resume

Installer state:

```text
/root/.install_openvpn.state
/root/.install_openvpn.config
/root/.install_openvpn.config.sha256
```

If SSH disconnects, run the installer again and it will resume from the correct step. If saved answers changed, the completed-step state is cleared and the install plan runs again with the new values.

Start from scratch:

```bash
RESET_INSTALL_STATE=1 ./install_openvpn.sh
```
