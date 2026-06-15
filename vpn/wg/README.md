# WireGuard installer

> RU: Это не официальный установщик WireGuard. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is not an official WireGuard installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

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
cd /root/telemt2/vpn/wg
chmod +x ./install_wg.sh ./wgctl.sh
./install_wg.sh
```

Если репозиторий уже скачан:

```bash
cd /root/telemt2
git pull
cd /root/telemt2/vpn/wg
chmod +x ./install_wg.sh ./wgctl.sh
./install_wg.sh
```

Обновить локальные файлы из репозитория:

```bash
cd /root/telemt2 && git pull
```

Скрипт рассчитан на чистый сервер. Если на машине уже заняты `80`, `443`, `51820` или стоит другой nginx/WireGuard, сначала проверьте конфликты.

### Режимы установки

Без маскировки:

```text
WireGuard -> UDP 51820
```

С HTTPS-маскировкой:

```text
nginx site -> TCP 443
WireGuard  -> UDP 443
```

TCP и UDP на одном номере порта не конфликтуют. Поэтому при открытии домена в браузере будет обычный HTTPS-сайт с сертификатом Let's Encrypt, а WireGuard-клиент будет подключаться к тому же домену, но по UDP.

Важно: это не превращает WireGuard-трафик в настоящий HTTPS. Это практичная маскировка сервера под сайт, совместимая со стандартным WireGuard-клиентом на iPhone. Глубокую обфускацию через `udp2raw`, `wstunnel`, `gost`, `AmneziaWG` или `sing-box` нужно делать отдельным вариантом.

### Что спрашивает установщик

```text
Enable HTTPS mask site? yes/no [no]
```

Если ответ `no`, дальше:

```text
Public endpoint IP/host for clients [<detected_ip>]
WireGuard UDP port [51820]
```

Если ответ `yes`, дальше:

```text
Mask domain with DNS A record to this server
Let's Encrypt email [admin@<domain>]
WireGuard UDP port [443]
```

Потом общие вопросы:

```text
WireGuard interface [wg0]
VPN IPv4 subnet [10.66.66.0/24]
Server VPN IPv4 [10.66.66.1]
Client DNS, comma separated IPv4 [1.1.1.1,8.8.8.8]
First client name
Enable nginx access logs for mask site? yes/no [no]
```

Если включена маскировка, установщик проверяет, что A-запись домена указывает на публичный IPv4 сервера. Если A-записи нет или она указывает не туда, скрипт предложит продолжить без маскировки.

### Что делает установщик

```text
1. Ставит wireguard-tools, iptables, qrencode и базовые утилиты.
2. Если включена маскировка, ставит nginx и certbot.
3. Проверяет занятые порты.
4. Включает IPv4 forwarding.
5. Создает /etc/wireguard/wg0.conf.
6. Добавляет forwarding-правила и NAT MASQUERADE для VPN-сети.
7. Если включена маскировка, создает nginx-сайт, выпускает SSL и включает certbot.timer.
8. Открывает порты и `ufw route allow` для VPN-маршрута, если ufw активен.
9. Включает и перезапускает wg-quick@wg0.
10. Создает первого клиента через wgctl и печатает QR-код.
```

### Логи и приватность

WireGuard сам по себе не пишет историю сайтов и запросов. `wgctl traffic` берет текущие счетчики из ядра WireGuard.

Для nginx-маскировки access logs по умолчанию выключены:

```text
access_log off
error_log /dev/null crit
```

### Управление клиентами

`wgctl` устанавливается как системная команда в `/usr/local/sbin/wgctl` и доступен через `/usr/local/bin/wgctl`, поэтому его можно запускать из любого каталога.

```bash
wgctl add
wgctl delete
wgctl list
wgctl show
wgctl qr
wgctl qrpng
wgctl traffic
```

Примеры:

```bash
wgctl add client1
wgctl show client1
wgctl qr client1
wgctl qrpng client1
wgctl traffic
wgctl delete client1
```

Если выполнить `wgctl add` без имени и просто нажать Enter, будет создан `pipiska1`. Если такое имя уже занято, будет выбран следующий свободный номер.

После `wgctl add <name>` показывается QR для импорта. Текстовый конфиг можно посмотреть отдельно: `wgctl show <name>`. Для Android и Telegram-ботов лучше использовать PNG, а не терминальный QR:

```bash
wgctl qrpng client1
wgctl -j add client1
wgctl -j qr client1
wgctl -j traffic
```

В JSON-режиме `add`, `show` и `qr` возвращают клиентский конфиг в поле `config`; `add` и `qr` дополнительно возвращают PNG QR в `qr_png_base64` и `qr_png_data_uri`; `list` и `traffic` возвращают структурированные списки для бота. Бот должен декодировать `qr_png_base64` и отправлять bytes как photo/document. Не распознавайте терминальный QR через OCR/скриншот и не пересобирайте QR из отформатированного сообщения Telegram: так часто теряются переносы строк WireGuard-конфига.

Конфиги клиентов сохраняются в:

```text
/root/wg-clients/<name>.conf
```

`wgctl traffic` показывает endpoint клиента, последний handshake и текущие счетчики `rx/tx`. WireGuard не хранит долговременную историю трафика по пользователям после перезапуска интерфейса.

### Resume

Установщик сохраняет состояние:

```text
/root/.install_wg.state
/root/.install_wg.config
```

Если SSH оборвался, запустите скрипт снова, он продолжит с нужного шага.

Начать установку заново:

```bash
RESET_INSTALL_STATE=1 ./install_wg.sh
```

## EN

This directory contains two standalone scripts for Debian/Ubuntu:

```bash
chmod +x ./install_wg.sh ./wgctl.sh
./install_wg.sh
```

The installer is intended for a clean server. If ports `80`, `443`, `51820`, nginx, or another WireGuard service are already in use, check conflicts first.

### Install modes

Without masking:

```text
WireGuard -> UDP 51820
```

With HTTPS masking:

```text
nginx site -> TCP 443
WireGuard  -> UDP 443
```

TCP and UDP do not conflict on the same port number. Opening the domain in a browser shows a normal HTTPS site with a Let's Encrypt certificate, while the WireGuard client connects to the same domain over UDP.

Important: this does not turn WireGuard packets into real HTTPS. It is practical server camouflage compatible with the standard WireGuard app on iPhone. Deep obfuscation through `udp2raw`, `wstunnel`, `gost`, `AmneziaWG`, or `sing-box` should be a separate installer mode.

### Installer prompts

```text
Enable HTTPS mask site? yes/no [no]
```

If `no`:

```text
Public endpoint IP/host for clients [<detected_ip>]
WireGuard UDP port [51820]
```

If `yes`:

```text
Mask domain with DNS A record to this server
Let's Encrypt email [admin@<domain>]
WireGuard UDP port [443]
```

Then common settings:

```text
WireGuard interface [wg0]
VPN IPv4 subnet [10.66.66.0/24]
Server VPN IPv4 [10.66.66.1]
Client DNS, comma separated IPv4 [1.1.1.1,8.8.8.8]
First client name
Enable nginx access logs for mask site? yes/no [no]
```

When masking is enabled, the installer checks that the domain A record points to the server public IPv4. If the record is missing or points elsewhere, it offers to continue without masking.

### Installer actions

```text
1. Installs wireguard-tools, iptables, qrencode, and base tools.
2. If masking is enabled, installs nginx and certbot.
3. Checks occupied ports.
4. Enables IPv4 forwarding.
5. Creates /etc/wireguard/wg0.conf.
6. Adds forwarding rules and NAT MASQUERADE for the VPN subnet.
7. If masking is enabled, creates an nginx site, issues SSL, and enables certbot.timer.
8. Opens ports and `ufw route allow` for the VPN route if ufw is active.
9. Enables and restarts wg-quick@wg0.
10. Creates the first client through wgctl and prints QR code.
```

### Logs and privacy

WireGuard itself does not log visited sites or requests. `wgctl traffic` reads current counters from the WireGuard kernel interface.

For nginx masking, access logs are disabled by default:

```text
access_log off
error_log /dev/null crit
```

### Client management

`wgctl` is installed as a system command at `/usr/local/sbin/wgctl` and exposed through `/usr/local/bin/wgctl`, so it can be run from any directory.

```bash
wgctl add
wgctl delete
wgctl list
wgctl show
wgctl qr
wgctl qrpng
wgctl traffic
```

Examples:

```bash
wgctl add client1
wgctl show client1
wgctl qr client1
wgctl qrpng client1
wgctl traffic
wgctl delete client1
```

If you run `wgctl add` without a name and press Enter, it creates `pipiska1`. If that name already exists, the next free number is used.

After `wgctl add <name>`, the command prints the QR for import. To view the text config separately, run `wgctl show <name>`. For Android and Telegram bots, use PNG instead of terminal QR:

```bash
wgctl qrpng client1
wgctl -j add client1
wgctl -j qr client1
wgctl -j traffic
```

In JSON mode, `add`, `show`, and `qr` return the client config in the `config` field; `add` and `qr` also return PNG QR data in `qr_png_base64` and `qr_png_data_uri`; `list` and `traffic` return structured bot-friendly lists. A bot should decode `qr_png_base64` and send the bytes as photo/document. Do not OCR/decode terminal QR output and rebuild a QR from a formatted Telegram message: that often loses WireGuard config newlines.

Client configs are saved to:

```text
/root/wg-clients/<name>.conf
```

`wgctl traffic` shows client endpoint, latest handshake, and current `rx/tx` counters. WireGuard does not keep long-term per-user traffic history after the interface restarts.

### Resume

Installer state:

```text
/root/.install_wg.state
/root/.install_wg.config
```

If SSH disconnects, run the installer again and it will resume from the correct step.

Start from scratch:

```bash
RESET_INSTALL_STATE=1 ./install_wg.sh
```
