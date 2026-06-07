# AmneziaWG installer

> RU: Это не официальный установщик AmneziaWG. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is not an official AmneziaWG installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

## RU

Каталог содержит два самостоятельных скрипта для Debian 13+ / Ubuntu 24.04+:

Поддерживаемые ОС: Debian 13 или новее, Ubuntu 24.04 или новее. На более старых релизах установщик остановится сразу, чтобы не получить полусломанную установку из-за старого ядра, headers или репозиториев.

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
2. Проверяет, что сервер работает на Debian 13+ или Ubuntu 24.04+.
3. Ставит базовые пакеты.
4. Добавляет AmneziaWG PPA, ставит пакет amneziawg, проверяет linux-headers и собирает DKMS-модуль ядра. Для Ubuntu-релизов без своей ветки PPA, например 26.04/resolute, используется поддерживаемая ветка `noble`.
5. Создает /etc/amnezia/amneziawg/awg0.conf.
6. Включает IPv4 forwarding и NAT MASQUERADE.
7. Если включена маскировка, ставит nginx/certbot, создает сайт, выпускает SSL и включает certbot.timer.
8. Открывает порты через ufw, если ufw активен.
9. Запускает awg-quick@awg0.
10. Создает первого клиента через awgctl и печатает QR.
```

Если apt поставил headers только для нового ядра, установщик напишет об этом по-русски. В таком случае нужно перезагрузить сервер и запустить установщик повторно: после reboot DKMS-модуль соберется и загрузится для текущего ядра.

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

Для скриптов есть JSON-режим. Флаг можно ставить до или после команды:

```bash
awgctl -j list
awgctl traffic --json
awgctl -j add client1
awgctl -j show client1
```

В JSON-режиме `add`, `show` и `qr` возвращают клиентский конфиг в поле `config`; `traffic` возвращает числовые счетчики `rx_bytes`, `tx_bytes` и время последнего handshake.

#### JSON-ответы

`awgctl` остается CLI-утилитой, поэтому главный признак успеха для shell-скриптов — код выхода. Поле `status_code` сделано в стиле HTTP, чтобы ответы было проще обрабатывать одинаково в API-обвязках.

```text
exit 0 + ok=true   = команда выполнена
exit 1 + ok=false  = ошибка, причина в поле error
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
200 ok                 команда выполнена
201 created            клиент создан
400 bad_request        неверная команда, имя или не хватает аргумента
403 forbidden          awgctl запущен не от root
404 not_found          не найден клиент, конфиг, env-файл или ключ
409 conflict           нет свободного IP или клиентский конфиг поврежден
500 dependency_error   не удалось поставить/найти системную зависимость
500 internal_error     системная ошибка, которую awgctl не смог исправить сам
```

Ответы команд:

```text
awgctl -j list
  status_code: 200
  clients[]:
    num, name, ip, public_key, created_at, config_path, env_path

awgctl -j traffic
  status_code: 200
  interface
  peers[]:
    name, vpn_ip, peer_public_key, endpoint, allowed_ips,
    latest_handshake_epoch, handshake, rx_bytes, tx_bytes, keepalive

awgctl -j show <name|number>
  status_code: 200
  name, ip, public_key, created_at, config_path, env_path, config

awgctl -j qr <name|number>
  status_code: 200
  name, config_path, config, qr_ansi_utf8

awgctl -j add [name]
  status_code: 201
  action=add, requested_name, name, auto_incremented, ip, public_key,
  interface, endpoint, config_path, env_path, config

awgctl -j delete <name|number>
  status_code: 200
  action=delete, name, ip, public_key, created_at, config_path, env_path
```

Важно: `add`, `show` и `qr` возвращают `config`, а внутри клиентского конфига есть приватный ключ клиента и preshared key. Не пишите эти ответы в публичные логи.

Пример успешного `traffic`:

```json
{"ok":true,"status_code":200,"status":"ok","interface":"awg0","peers":[{"name":"pipiska1","vpn_ip":"10.88.88.2","peer_public_key":"...","endpoint":"178.218.117.39:56896","allowed_ips":"10.88.88.2/32","latest_handshake_epoch":1780863737,"handshake":"41s ago","rx_bytes":1369956,"tx_bytes":12947276,"keepalive":null}]}
```

Пример ошибки:

```json
{"ok":false,"status_code":404,"status":"not_found","error":"клиент не найден: test"}
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

This directory contains two standalone scripts for Debian 13+ / Ubuntu 24.04+:

Supported OS versions: Debian 13 or newer, Ubuntu 24.04 or newer. Older releases stop early to avoid half-installed systems caused by old kernels, missing headers, or incompatible repositories.

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
2. Checks that the server runs Debian 13+ or Ubuntu 24.04+.
3. Installs base packages.
4. Adds the AmneziaWG PPA, installs the amneziawg package, checks linux-headers, and builds the DKMS kernel module. Ubuntu releases without their own PPA suite, for example 26.04/resolute, use the supported `noble` suite.
5. Creates /etc/amnezia/amneziawg/awg0.conf.
6. Enables IPv4 forwarding and NAT MASQUERADE.
7. If masking is enabled, installs nginx/certbot, creates a site, issues SSL, and enables certbot.timer.
8. Opens ports through ufw if ufw is active.
9. Starts awg-quick@awg0.
10. Creates the first client through awgctl and prints QR.
```

If apt installs headers only for a newer kernel, the installer explains that explicitly. Reboot the server and run the installer again so the DKMS module can build and load for the currently booted kernel.

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

For scripts, use JSON mode. The flag can be placed before or after the command:

```bash
awgctl -j list
awgctl traffic --json
awgctl -j add client1
awgctl -j show client1
```

In JSON mode, `add`, `show`, and `qr` return the client config in the `config` field; `traffic` returns numeric `rx_bytes`, `tx_bytes`, and latest handshake fields.

#### JSON Responses

`awgctl` is still a CLI tool, so shell scripts should primarily use the process exit code. `status_code` is API-like and mirrors HTTP-style meanings for easier wrappers.

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
200 ok                 command succeeded
201 created            client was created
400 bad_request        bad command, bad name, or missing argument
403 forbidden          awgctl was not run as root
404 not_found          client, config, env file, or key was not found
409 conflict           no free client IP or damaged client config
500 dependency_error   system dependency could not be installed/found
500 internal_error     system error awgctl could not repair automatically
```

Command responses:

```text
awgctl -j list
  status_code: 200
  clients[]:
    num, name, ip, public_key, created_at, config_path, env_path

awgctl -j traffic
  status_code: 200
  interface
  peers[]:
    name, vpn_ip, peer_public_key, endpoint, allowed_ips,
    latest_handshake_epoch, handshake, rx_bytes, tx_bytes, keepalive

awgctl -j show <name|number>
  status_code: 200
  name, ip, public_key, created_at, config_path, env_path, config

awgctl -j qr <name|number>
  status_code: 200
  name, config_path, config, qr_ansi_utf8

awgctl -j add [name]
  status_code: 201
  action=add, requested_name, name, auto_incremented, ip, public_key,
  interface, endpoint, config_path, env_path, config

awgctl -j delete <name|number>
  status_code: 200
  action=delete, name, ip, public_key, created_at, config_path, env_path
```

Important: `add`, `show`, and `qr` return `config`, which contains the client private key and preshared key. Do not write these responses to public logs.

Successful `traffic` example:

```json
{"ok":true,"status_code":200,"status":"ok","interface":"awg0","peers":[{"name":"pipiska1","vpn_ip":"10.88.88.2","peer_public_key":"...","endpoint":"178.218.117.39:56896","allowed_ips":"10.88.88.2/32","latest_handshake_epoch":1780863737,"handshake":"41s ago","rx_bytes":1369956,"tx_bytes":12947276,"keepalive":null}]}
```

Error example:

```json
{"ok":false,"status_code":404,"status":"not_found","error":"client not found: test"}
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
