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
AmneziaWG UDP port [1234]
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
First client name [pipiska1]
Enable nginx access logs for mask site? yes/no [no]
```

`S1`, `S2`, `H1`, `H2`, `H3`, `H4` генерируются автоматически и сохраняются в `/etc/amnezia/amneziawg/awgctl.env`. Для профиля `awg2` также могут генерироваться `S3`, `S4`, `I1-I5`.
MTU по умолчанию — `1280`. При необходимости его можно переопределить переменной окружения `AWG_MTU`.
Автоматические значения соблюдают диапазоны из документации AmneziaWG 2.0: `Jc=1..10`, `Jmin/Jmax=64..1024`, `S1/S2/S3=0..64`, `S4=0..32`, `H1-H4` не пересекаются. Для диагностического профиля `plain` допускаются нулевые значения.
По умолчанию используется UDP-порт `1234`, потому что в официальном troubleshooting отмечено: некоторые провайдеры в РФ могут блокировать UDP-порты выше `9999`. Если порт `1234` не подходит, пробуйте `AWG_PORT=443`.
Если apt/PPA дает типовую ошибку, установщик сначала пробует исправить ее сам: удаляет старую битую запись AmneziaWG PPA и перебирает поддерживаемые ветки PPA. Если исправить не получилось, причина выводится на русском языке.
Если имя первого клиента уже занято, установщик создает следующего клиента с числовым суффиксом: `pipiska1`, `pipiska2`, `pipiska3` и так далее.

### Профили обфускации

Проверенный на iPhone профиль в текущей сборке — `dns`. Если не знаете, что выбирать для реального использования, начинайте с него:

```bash
RESET_INSTALL_STATE=1 AWG_OBFS_PROFILE=dns AWG_PORT=1234 ./install_amneziawg.sh
```

| Профиль | Когда использовать | Чем отличается |
| --- | --- | --- |
| `dns` | Рекомендуемый рабочий вариант для телефона и обычного использования | `mobile` + `I1`, первый пакет похож на DNS-запрос |
| `mobile` | Базовый нормальный вариант без DNS-like первого пакета | Junk-пакеты + случайные `S1/S2/H1-H4`, без `I1` |
| `compat` | Диагностика, когда UDP доходит, но handshake не появляется | Простые фиксированные параметры: `S1/S2=0`, `H1-H4=1..4`; меньше маскировки, проще проверить совместимость |
| `awg1` | Проверка поведения старого стиля AmneziaWG 1.x | Случайные `J/S/H` в допустимых диапазонах |
| `awg2` | Эксперименты с более новым/агрессивным профилем AmneziaWG 2.0 | Добавляет `S3/S4`, диапазоны `H1-H4` и DNS-like `I1` |
| `plain` | Только диагностика | Почти без обфускации, WG-like режим с нулевыми параметрами |

Что означают основные параметры:

| Параметр | Смысл |
| --- | --- |
| `Jc` | Сколько junk-пакетов добавлять |
| `Jmin` | Минимальный размер junk-пакета |
| `Jmax` | Максимальный размер junk-пакета |
| `S1/S2` | Размеры/сдвиги обфускации |
| `S3/S4` | Дополнительные параметры AmneziaWG 2.0 |
| `H1-H4` | Заголовки AmneziaWG; должны совпадать на сервере и клиенте |
| `I1-I5` | Имитация начальных пакетов; в `dns` используется `I1`, похожий на DNS |

Важно: профиль обфускации нельзя поменять только на сервере. Параметры должны совпадать в серверном `awg0.conf` и клиентском QR. Если меняете `AWG_OBFS_PROFILE`, заново покажите QR через `awgctl qr <name>` и переимпортируйте профиль в AmneziaWG.

Быстрый тест, если UDP до сервера доходит, но `handshake never`:

```bash
cd /root/telemt2
git pull
cd /root/telemt2/vpn/amneziawg
RESET_INSTALL_STATE=1 AWG_OBFS_PROFILE=dns AWG_PORT=1234 CLIENT_NAME=dns1 ./install_amneziawg.sh
awgctl qr dns1
```

Если `dns` не подключается, но UDP до сервера доходит, попробуйте `AWG_PORT=443`. Если нужно отделить проблему параметров от проблемы порта, проверьте `AWG_OBFS_PROFILE=compat`.

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
9. Создает первого клиента через awgctl и печатает QR.
```

### Управление клиентами

`awgctl` устанавливается как системная команда в `/usr/local/sbin/awgctl` и доступен через `/usr/local/bin/awgctl`, поэтому его можно запускать из любого каталога.

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

Если выполнить `awgctl add` без имени и просто нажать Enter, будет создан `pipiska1`. Если такое имя уже занято, будет выбран следующий свободный номер.

После `awgctl add <name>` показывается QR для импорта. Текстовый конфиг можно посмотреть отдельно: `awgctl show <name>`.

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
AmneziaWG UDP port [1234]
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
First client name [pipiska1]
Enable nginx access logs for mask site? yes/no [no]
```

`S1`, `S2`, `H1`, `H2`, `H3`, `H4` are generated automatically and saved in `/etc/amnezia/amneziawg/awgctl.env`. The `awg2` profile may also generate `S3`, `S4`, and `I1-I5`.
The default MTU is `1280`. Override it with the `AWG_MTU` environment variable if needed.
Generated values follow AmneziaWG 2.0 documentation ranges: `Jc=1..10`, `Jmin/Jmax=64..1024`, `S1/S2/S3=0..64`, `S4=0..32`, and non-overlapping `H1-H4`. The diagnostic `plain` profile allows zero values.
The default UDP port is `1234` because the official troubleshooting notes that some providers in Russia may block UDP ports above `9999`. If `1234` does not work, try `AWG_PORT=443`.
For common apt/PPA failures, the installer first tries to repair the problem: it removes stale broken AmneziaWG PPA entries and tries supported PPA suites. If it cannot recover, it prints the reason in Russian.
If the first client name already exists, the installer creates the next numbered client: `pipiska1`, `pipiska2`, `pipiska3`, and so on.

### Obfuscation Profiles

The profile verified on iPhone in the current build is `dns`. If you are not sure what to choose for real use, start with it:

```bash
RESET_INSTALL_STATE=1 AWG_OBFS_PROFILE=dns AWG_PORT=1234 ./install_amneziawg.sh
```

| Profile | When to use it | Difference |
| --- | --- | --- |
| `dns` | Recommended working option for phones and normal use | `mobile` + `I1`; the first packet looks DNS-like |
| `mobile` | Basic normal option without a DNS-like first packet | Junk packets + random `S1/S2/H1-H4`, no `I1` |
| `compat` | Diagnostics when UDP reaches the server but no handshake appears | Simple fixed parameters: `S1/S2=0`, `H1-H4=1..4`; less masking, easier compatibility check |
| `awg1` | Testing classic AmneziaWG 1.x behavior | Random `J/S/H` values in valid ranges |
| `awg2` | Experiments with a newer/more aggressive AmneziaWG 2.0 profile | Adds `S3/S4`, `H1-H4` ranges, and DNS-like `I1` |
| `plain` | Diagnostics only | Almost no obfuscation, WG-like mode with zero parameters |

Main parameter meanings:

| Parameter | Meaning |
| --- | --- |
| `Jc` | Number of junk packets |
| `Jmin` | Minimum junk packet size |
| `Jmax` | Maximum junk packet size |
| `S1/S2` | Obfuscation sizes/shifts |
| `S3/S4` | Additional AmneziaWG 2.0 parameters |
| `H1-H4` | AmneziaWG headers; must match on server and client |
| `I1-I5` | Initial packet imitation; `dns` uses an `I1` that looks DNS-like |

Important: the obfuscation profile cannot be changed only on the server. Parameters must match in the server `awg0.conf` and in the client QR. If you change `AWG_OBFS_PROFILE`, show the QR again with `awgctl qr <name>` and re-import the profile into AmneziaWG.

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
9. Creates the first client through awgctl and prints QR.
```

### Client management

`awgctl` is installed as a system command at `/usr/local/sbin/awgctl` and exposed through `/usr/local/bin/awgctl`, so it can be run from any directory.

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

If you run `awgctl add` without a name and press Enter, it creates `pipiska1`. If that name already exists, the next free number is used.

After `awgctl add <name>`, the command prints the QR for import. To view the text config separately, run `awgctl show <name>`.

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
