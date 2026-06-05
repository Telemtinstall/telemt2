# AmneziaWG installer

> RU: Это не официальный установщик AmneziaWG. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is not an official AmneziaWG installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

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
cd /root/telemt2/vpn/amneziawg
chmod +x ./install_amneziawg.sh ./awgctl.sh
./install_amneziawg.sh
```

Если репозиторий уже скачан:

```bash
cd /root/telemt2
git pull
cd /root/telemt2/vpn/amneziawg
chmod +x ./install_amneziawg.sh ./awgctl.sh
./install_amneziawg.sh
```

Обновить локальные файлы из репозитория:

```bash
cd /root/telemt2 && git pull
```

Это экспериментальный установщик. Сначала тестируйте на чистой машине. Если уже заняты `80`, `443`, `51820` или стоит другой nginx/VPN, возможны конфликты.

### Что такое AmneziaWG

AmneziaWG — это WireGuard-подобный VPN с дополнительными параметрами обфускации:

```text
Jc, Jmin, Jmax, S1, S2, H1, H2, H3, H4
S3, S4, I1-I5 для профилей AmneziaWG 2.0
```

Обычный WireGuard app такие конфиги не понимает. Для iPhone используйте нативный **AmneziaWG** из App Store или **AmneziaVPN** с поддержкой AmneziaWG.

### Режимы установки

Без маскировочного сайта:

```text
AmneziaWG -> UDP 51820
```

С HTTPS-маскировкой:

```text
nginx site -> TCP 443
AmneziaWG  -> UDP 443
```

TCP и UDP на одном номере порта не конфликтуют. В браузере домен открывается как обычный HTTPS-сайт, а AmneziaVPN подключается к тому же домену по UDP.

Важно: HTTPS-сайт не превращает UDP-трафик AmneziaWG в HTTPS. Это маскировка сервера как сайта плюс протокольная обфускация AmneziaWG.

### Что спрашивает установщик

```text
Enable HTTPS mask site? yes/no [no]
```

Если `no`:

```text
Public endpoint IP/host for clients [<detected_ip>]
AmneziaWG UDP port [51820]
```

Если `yes`:

```text
Mask domain with DNS A record to this server
Let's Encrypt email [admin@<domain>]
AmneziaWG UDP port [443]
```

Потом общие вопросы:

```text
AmneziaWG interface [awg0]
VPN IPv4 subnet [10.88.88.0/24]
Server VPN IPv4 [10.88.88.1]
Client DNS, comma separated IPv4 [1.1.1.1,8.8.8.8]
Obfuscation profile [mobile]
AmneziaWG junk packet count Jc [random]
AmneziaWG junk min size Jmin [random]
AmneziaWG junk max size Jmax [random]
First client name
Enable nginx access logs for mask site? yes/no [no]
```

`S1`, `S2`, `H1`, `H2`, `H3`, `H4` генерируются автоматически и сохраняются в `/etc/amnezia/amneziawg/awgctl.env`. Для профиля `awg2` также могут генерироваться `S3`, `S4`, `I1-I5`.
MTU по умолчанию — `1280`. При необходимости его можно переопределить переменной окружения `AWG_MTU`.
Автоматические значения соблюдают диапазоны AmneziaWG: `Jc=1..128`, `Jmin/Jmax=1..1280`, `S1/S2` в пределах MTU, `H1-H4` не пересекаются. Для диагностического профиля `plain` допускаются нулевые значения.
Если apt/PPA дает типовую ошибку, установщик сначала пробует исправить ее сам: удаляет старую битую запись AmneziaWG PPA и перебирает поддерживаемые ветки PPA. Если исправить не получилось, причина выводится на русском языке.
При повторной установке первый клиент пересоздается под текущие параметры, поэтому нужно заново импортировать QR.

### Профили обфускации

```text
mobile  - профиль по умолчанию для LTE/мобильных сетей: Jc=3, короткие junk-пакеты, без I1.
compat  - совместимый режим из старых инструкций Amnezia: S1/S2=0, H1-H4=1..4. Удобен для диагностики handshake.
awg1    - классический AmneziaWG 1.x со случайными S/H/J в официальных диапазонах.
awg2    - AmneziaWG 2.0: добавляет S3/S4, диапазоны H1-H4 и QUIC-подобный I1.
plain   - диагностический WG-like режим с нулевой обфускацией.
```

Быстрый тест, если UDP до сервера доходит, но `handshake never`:

```bash
cd /root/telemt2
git pull
cd /root/telemt2/vpn/amneziawg
RESET_INSTALL_STATE=1 AWG_OBFS_PROFILE=compat CLIENT_NAME=compat1 ./install_amneziawg.sh
awgctl qr compat1
```

Если `compat` подключается, а `mobile` или `awg2` нет, значит проблема не в firewall/NAT, а в выбранных параметрах обфускации или реакции мобильного оператора на первый UDP-пакет.

### Что делает установщик

```text
1. Проверяет DNS A-запись домена, если включена HTTPS-маскировка.
2. Ставит базовые пакеты.
3. Добавляет AmneziaWG PPA и ставит пакет amneziawg. Для Ubuntu-релизов без своей ветки PPA, например 26.04/resolute, используется поддерживаемая ветка `noble`.
4. Создает /etc/amnezia/amneziawg/awg0.conf.
5. Включает IPv4 forwarding и NAT MASQUERADE.
6. Если включена маскировка, ставит nginx/certbot, создает сайт, выпускает SSL и включает certbot.timer.
7. Открывает порты через ufw, если ufw активен.
8. Запускает awg-quick@awg0.
9. Создает первого клиента и печатает конфиг/QR.
```

### Управление клиентами

```bash
awgctl add
awgctl delete
awgctl list
awgctl show
awgctl qr
awgctl traffic
```

Примеры:

```bash
awgctl add client1
awgctl show client1
awgctl qr client1
awgctl traffic
awgctl delete client1
```

Конфиги клиентов:

```text
/root/amneziawg-clients/<name>.conf
```

Этот `.conf` импортируется в AmneziaVPN, не в обычный WireGuard app.
Нативный клиент AmneziaWG тоже подходит.

### Логи и приватность

AmneziaWG сам по себе не пишет историю сайтов и запросов. `awgctl traffic` показывает текущие счетчики интерфейса.

Для nginx-маскировки access logs по умолчанию выключены:

```text
access_log off
error_log /dev/null crit
```

### Resume

Если SSH оборвался, запустите установщик снова:

```bash
./install_amneziawg.sh
```

Начать заново:

```bash
RESET_INSTALL_STATE=1 ./install_amneziawg.sh
```

## EN

This directory contains two standalone scripts for Debian/Ubuntu:

```bash
chmod +x ./install_amneziawg.sh ./awgctl.sh
./install_amneziawg.sh
```

This is an experimental installer. Test it on a clean server first. If ports `80`, `443`, `51820`, nginx, or another VPN are already in use, conflicts are possible.

### What is AmneziaWG

AmneziaWG is a WireGuard-like VPN with additional obfuscation parameters:

```text
Jc, Jmin, Jmax, S1, S2, H1, H2, H3, H4
S3, S4, I1-I5 for AmneziaWG 2.0 profiles
```

The standard WireGuard app does not understand these configs. On iPhone, use the native **AmneziaWG** app or **AmneziaVPN** with AmneziaWG support.

### Install modes

Without mask site:

```text
AmneziaWG -> UDP 51820
```

With HTTPS mask:

```text
nginx site -> TCP 443
AmneziaWG  -> UDP 443
```

TCP and UDP do not conflict on the same port number. Opening the domain in a browser shows a normal HTTPS site, while AmneziaVPN connects to the same domain over UDP.

Important: the HTTPS site does not turn AmneziaWG UDP traffic into HTTPS. It provides server camouflage as a website plus AmneziaWG protocol obfuscation.

### Installer prompts

```text
Enable HTTPS mask site? yes/no [no]
```

If `no`:

```text
Public endpoint IP/host for clients [<detected_ip>]
AmneziaWG UDP port [51820]
```

If `yes`:

```text
Mask domain with DNS A record to this server
Let's Encrypt email [admin@<domain>]
AmneziaWG UDP port [443]
```

Then common settings:

```text
AmneziaWG interface [awg0]
VPN IPv4 subnet [10.88.88.0/24]
Server VPN IPv4 [10.88.88.1]
Client DNS, comma separated IPv4 [1.1.1.1,8.8.8.8]
Obfuscation profile [mobile]
AmneziaWG junk packet count Jc [random]
AmneziaWG junk min size Jmin [random]
AmneziaWG junk max size Jmax [random]
First client name
Enable nginx access logs for mask site? yes/no [no]
```

`S1`, `S2`, `H1`, `H2`, `H3`, `H4` are generated automatically and saved in `/etc/amnezia/amneziawg/awgctl.env`. The `awg2` profile may also generate `S3`, `S4`, and `I1-I5`.
The default MTU is `1280`. Override it with the `AWG_MTU` environment variable if needed.
Generated values follow AmneziaWG ranges: `Jc=1..128`, `Jmin/Jmax=1..1280`, `S1/S2` within MTU limits, and non-overlapping `H1-H4`. The diagnostic `plain` profile allows zero values.
For common apt/PPA failures, the installer first tries to repair the problem: it removes stale broken AmneziaWG PPA entries and tries supported PPA suites. If it cannot recover, it prints the reason in Russian.
On reinstall, the first client is recreated for the current parameters, so import the new QR again.

### Obfuscation Profiles

```text
mobile  - default LTE/mobile profile: Jc=3, short junk packets, no I1.
compat  - compatibility mode from older Amnezia guidance: S1/S2=0, H1-H4=1..4. Useful for handshake diagnostics.
awg1    - classic AmneziaWG 1.x with random S/H/J values in official ranges.
awg2    - AmneziaWG 2.0: adds S3/S4, H1-H4 ranges, and a QUIC-like I1.
plain   - diagnostic WG-like mode with zero obfuscation.
```

### Installer actions

```text
1. Checks DNS A record if HTTPS masking is enabled.
2. Installs base packages.
3. Adds the AmneziaWG PPA and installs the amneziawg package. Ubuntu releases without their own PPA suite, for example 26.04/resolute, use the supported `noble` suite.
4. Creates /etc/amnezia/amneziawg/awg0.conf.
5. Enables IPv4 forwarding and NAT MASQUERADE.
6. If masking is enabled, installs nginx/certbot, creates a site, issues SSL, and enables certbot.timer.
7. Opens ports through ufw if ufw is active.
8. Starts awg-quick@awg0.
9. Creates the first client and prints config/QR.
```

### Client management

```bash
awgctl add
awgctl delete
awgctl list
awgctl show
awgctl qr
awgctl traffic
```

Examples:

```bash
awgctl add client1
awgctl show client1
awgctl qr client1
awgctl traffic
awgctl delete client1
```

Client configs:

```text
/root/amneziawg-clients/<name>.conf
```

Import this `.conf` into AmneziaVPN, not into the standard WireGuard app.
The native AmneziaWG client is supported too.

### Logs and privacy

AmneziaWG itself does not log visited sites or requests. `awgctl traffic` shows current interface counters.

For nginx masking, access logs are disabled by default:

```text
access_log off
error_log /dev/null crit
```

### Resume

If SSH disconnects, run the installer again:

```bash
./install_amneziawg.sh
```

Start from scratch:

```bash
RESET_INSTALL_STATE=1 ./install_amneziawg.sh
```
