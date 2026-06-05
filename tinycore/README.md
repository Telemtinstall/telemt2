# Telemt Tiny Core Linux Installer

## RU

Tiny Core Linux-версия сделана отдельно и не заменяет Debian/Ubuntu или AlmaLinux-скрипты.

```text
install_telemt_tinycore.sh          установка одного Tiny Core сервера
install_telemt_batch_tinycore.sh    пакетная установка на несколько Tiny Core серверов
add_key.sh                          вспомогательный скрипт для копирования SSH-ключа
```

Статус: experimental. Tiny Core сильно отличается от обычных серверных дистрибутивов, поэтому перед массовым использованием лучше проверить скрипт на одном чистом сервере.

### Главные Отличия

В Tiny Core версии нет Docker, systemd, apt/dnf и обычного `certbot.timer`. Зависимости ставятся через `tce-load`, Telemt ставится как нативный `musl` бинарник из GitHub releases, автозапуск делается через `/opt/bootlocal.sh`, а persistence фиксируется через `/opt/.filetool.lst` и `filetool.sh -b`. Сертификат выпускается через `acme.sh` в standalone mode, для продления добавляются hooks остановки/запуска nginx.

### Требования

1. Tiny Core Linux `x86_64`/CorePure64 или `aarch64`.
2. Настроенный persistent `/tce`.
3. Root-доступ.
4. Открытые `80/tcp` и `443/tcp`.
5. `A`-запись домена должна указывать на публичный IPv4 сервера.

### Важно: только чистый сервер

Используйте новый Tiny Core сервер без существующих сайтов, панелей управления и сетевых сервисов. Установщик настраивает nginx stream, Telemt, acme.sh, autostart и persistence; ему нужны свободные `80/tcp` и `443/tcp`, а также локальные `8443`, `1443`, `9091`. Если на сервере уже есть web/proxy/VPN/mail-сервисы, возможны конфликты портов и потеря настроек после reboot из-за persistence. Для таких случаев лучше отдельная машина или ручная интеграция.

Официальный Telemt сейчас публикует `linux-musl` бинарники для `x86_64` и `aarch64`. Поэтому 32-bit Tiny Core x86 этим скриптом не поддерживается.

По умолчанию используется pinned Telemt release `3.4.13` и pinned `acme.sh` `3.1.2`; оба скачивания проверяются через sha256. Для другого release нужно передать свои `TELEMT_RELEASE`, `TELEMT_SHA256_X86_64` / `TELEMT_SHA256_AARCH64`.

### Что Ставит

Скрипт ставит базовые зависимости (`bash`, `curl`, `ca-certificates`, `openssl`, `nginx`, `socat`), а также optional-компоненты `jq` и `iproute2`, если они доступны. Для сертификатов используется `acme.sh`, а Telemt ставится как нативный бинарник.

При установке используются закреплённые версии Telemt и `acme.sh` с проверкой sha256. Nginx access logs и Telemt runtime logs отключаются. На `80/tcp` nginx отдаёт только HTTP -> HTTPS редирект.

### Схема

```text
Internet
  -> <PROXY_DOMAIN>:80
  -> nginx HTTP redirect
     -> 301 https://<PROXY_DOMAIN>/
  -> <PROXY_DOMAIN>:443
  -> nginx stream SNI router
     -> SNI = <PROXY_DOMAIN>
        -> 127.0.0.1:1443
        -> Telemt native binary
     -> default / browser / scanner
        -> 127.0.0.1:8443
        -> local HTTPS mask site
```

### Что Не Делает

Скрипт не меняет SSH-порт, не отключает SSH password login, не ставит `fail2ban`, не использует Docker и не зависит от systemd.

SSH-hardening на Tiny Core лучше делать отдельно, потому что там часто используется не стандартный OpenSSH/systemd-layout.

### Как скачать файл на сервер

Если файл уже есть на вашем компьютере, скопируйте его через `scp`:

```bash
scp install_telemt_tinycore.sh root@<SERVER_PUBLIC_IP>:/root/
```

Если файл нужно скачать прямо с GitHub на сервере:

```bash
wget -O /root/install_telemt_tinycore.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/tinycore/install_telemt_tinycore.sh
chmod +x /root/install_telemt_tinycore.sh
```

То же самое через `curl`:

```bash
curl -fsSL -o /root/install_telemt_tinycore.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/tinycore/install_telemt_tinycore.sh
chmod +x /root/install_telemt_tinycore.sh
```

Если нужен именно `git`, скачайте только каталог Tiny Core:

```bash
tce-load -wi git
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt
cd /tmp/telemt
git sparse-checkout set tinycore
cp tinycore/install_telemt_tinycore.sh /root/
chmod +x /root/install_telemt_tinycore.sh
```

### Запуск На Одном Сервере

```bash
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_tinycore.sh
/root/install_telemt_tinycore.sh
```

Скрипт спросит домен прокси, email для Let's Encrypt со значением по умолчанию `admin@<domain>`, SSH-порт только для подсказок и batch-режима, а также лимит подключений Telemt со значением по умолчанию `5000`.

Пример полного диалога:

```text
Proxy domain: <PROXY_DOMAIN>
Let's Encrypt email [admin@<PROXY_DOMAIN>]: <Enter>
SSH port, Enter keeps current/default. Tiny Core installer does not change SSH config [22]: <Enter>
Max Telemt connections [5000]: <Enter>

Install plan:
  target OS:    Tiny Core Linux
  domain:       <PROXY_DOMAIN>
  email:        admin@<PROXY_DOMAIN>
  SSH port:     22 (not changed by this installer)
  Telemt limit: 5000
  release:      3.4.13

Type y or yes to continue:
y
```

В примере пустой ответ означает “оставить значение по умолчанию”. После `y` начинается установка: через `tce-load` ставятся зависимости, настраивается nginx stream, скачивается и проверяется Telemt native binary, устанавливается `acme.sh`, выпускается сертификат, создаются конфиги, autostart и persistence через `/opt/.filetool.lst`.

Telemt на Tiny Core запускается без Docker из pinned native binary. Настройки такие же по смыслу: TLS mode only, `use_middle_proxy = false`, direct upstream, локальный read-only API, `config_strict = true`, лимит подключений по умолчанию `5000`.

После установки:

```text
/root/telemt-proxy-link.txt
/opt/telemt/telemt.toml
/opt/telemt/telemt-secret.env
/opt/telemt/bin/restart.sh
/opt/telemt/bin/renew-cert.sh
```

Проверка:

```bash
telemt-report 5m
```

Перезапуск вручную:

```bash
/opt/telemt/bin/restart.sh
```

### Пакетный Режим

`install_telemt_batch_tinycore.sh` запускается на админской машине: macOS, Debian, Ubuntu, AlmaLinux или любом Linux с `bash`, `ssh`, `scp` и DNS-утилитой.

Tiny Core нужен только на целевых серверах.

Запуск:

```bash
chmod +x install_telemt_batch_tinycore.sh ../common/add_key.sh
./install_telemt_batch_tinycore.sh
```

Как работает пакетная установка:

1. Скрипт принимает домены по одному и завершает ввод по пустой строке.
2. Для каждого домена он проверяет `A`-запись и SSH-доступ.
3. Когда доступ готов, скрипт копирует `install_telemt_tinycore.sh` на сервер и запускает его удалённо.
4. После успешной установки он читает `/root/telemt-proxy-link.txt` и в конце печатает общий список `Proxy links`.

Пример диалога batch-режима:

```text
SSH user for installation [root]: root
Current SSH port for connecting to servers [22]: <Enter>
SSH port after install, Tiny Core installer does not change SSH config [22]: <Enter>
Telemt max TCP connections [5000]: <Enter>
Common Let's Encrypt email, empty = admin@domain []: <Enter>

Domain: proxy-one.example.com
Server IP to use [<SERVER_PUBLIC_IP>]: <Enter>
Domain:
```

Пустой ответ оставляет значение по умолчанию. Пустой `Domain:` завершает список серверов. Если SSH-вход по ключу не работает, появится выбор:

```text
1) Copy/install key with add_key.sh (recommended)
2) Use SSH password for this installation
3) Skip this server
Choose [1/2/3]:
```

Вариант `1` запускает `add_key.sh` и может спросить SSH-пароль для копирования ключа. Вариант `2` использует парольные запросы SSH/SCP только для текущей установки. Вариант `3` пропускает сервер.

Блок `Proxy links` содержит рабочие Telegram proxy-ссылки с секретами. Относитесь к ним как к паролям.

### Повторный Запуск

Состояние:

```text
/opt/telemt/.install_tinycore.state
/opt/telemt/install.conf
```

Сброс состояния:

```bash
RESET_INSTALL_STATE=1 sh /root/install_telemt_tinycore.sh
```

---

## EN

The Tiny Core Linux version is separate and does not replace the Debian/Ubuntu or AlmaLinux scripts.

```text
install_telemt_tinycore.sh          single Tiny Core server installer
install_telemt_batch_tinycore.sh    batch installer for multiple Tiny Core servers
add_key.sh                          helper for copying an SSH public key
```

Status: experimental. Tiny Core is very different from conventional server distributions, so test this on one clean server before using it in bulk.

### Main Differences

The Tiny Core version has no Docker, systemd, apt/dnf, or regular `certbot.timer`. Dependencies are installed via `tce-load`, Telemt is installed as a native `musl` binary from GitHub releases, autostart is handled through `/opt/bootlocal.sh`, and persistence is saved through `/opt/.filetool.lst` and `filetool.sh -b`. Certificates are issued through `acme.sh` in standalone mode, with nginx stop/start hooks for renewal.

### Requirements

1. Tiny Core Linux `x86_64`/CorePure64 or `aarch64`.
2. Configured persistent `/tce`.
3. Root access.
4. Open `80/tcp` and `443/tcp`.
5. The domain `A` record must point to the server public IPv4.

### Important: Clean Server Only

Use a new Tiny Core server without existing websites, control panels, or network services. The installer configures nginx stream, Telemt, acme.sh, autostart, and persistence; it needs free `80/tcp` and `443/tcp`, plus local `8443`, `1443`, and `9091`. If web/proxy/VPN/mail services already exist, port conflicts and reboot persistence issues are possible. Use a separate machine or integrate manually.

Official Telemt currently publishes `linux-musl` binaries for `x86_64` and `aarch64`. 32-bit Tiny Core x86 is not supported by this script.

By default, the installer uses pinned Telemt release `3.4.13` and pinned `acme.sh` `3.1.2`; both downloads are verified with sha256. To use another release, pass your own `TELEMT_RELEASE`, `TELEMT_SHA256_X86_64` / `TELEMT_SHA256_AARCH64`.

### What It Installs

The script installs base dependencies (`bash`, `curl`, `ca-certificates`, `openssl`, `nginx`, `socat`), plus optional `jq` and `iproute2` when available. Certificates are handled by `acme.sh`, and Telemt is installed as a native binary.

The installer uses a pinned Telemt release and pinned `acme.sh` version with sha256 verification. Nginx access logs and Telemt runtime logs are disabled. On `80/tcp`, nginx only serves the HTTP -> HTTPS redirect.

### Layout

```text
Internet
  -> <PROXY_DOMAIN>:80
  -> nginx HTTP redirect
     -> 301 https://<PROXY_DOMAIN>/
  -> <PROXY_DOMAIN>:443
  -> nginx stream SNI router
     -> SNI = <PROXY_DOMAIN>
        -> 127.0.0.1:1443
        -> Telemt native binary
     -> default / browser / scanner
        -> 127.0.0.1:8443
        -> local HTTPS mask site
```

### What It Does Not Do

The script does not change the SSH port, does not disable SSH password login, does not install `fail2ban`, does not use Docker, and does not depend on systemd.

SSH hardening is better handled separately on Tiny Core because deployments often use non-standard OpenSSH/Dropbear layouts.

### How To Download The File To The Server

If the file is already on your computer, copy it with `scp`:

```bash
scp install_telemt_tinycore.sh root@<SERVER_PUBLIC_IP>:/root/
```

If you want to download it directly from GitHub on the server:

```bash
wget -O /root/install_telemt_tinycore.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/tinycore/install_telemt_tinycore.sh
chmod +x /root/install_telemt_tinycore.sh
```

The same with `curl`:

```bash
curl -fsSL -o /root/install_telemt_tinycore.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/tinycore/install_telemt_tinycore.sh
chmod +x /root/install_telemt_tinycore.sh
```

If you specifically want to use `git`, download only the Tiny Core directory:

```bash
tce-load -wi git
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt
cd /tmp/telemt
git sparse-checkout set tinycore
cp tinycore/install_telemt_tinycore.sh /root/
chmod +x /root/install_telemt_tinycore.sh
```

### Single-Server Install

```bash
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_tinycore.sh
/root/install_telemt_tinycore.sh
```

The script asks for the proxy domain, Let's Encrypt email with default `admin@<domain>`, SSH port only for hints and batch mode, and max Telemt connections with default `5000`.

Full dialogue example:

```text
Proxy domain: <PROXY_DOMAIN>
Let's Encrypt email [admin@<PROXY_DOMAIN>]: <Enter>
SSH port, Enter keeps current/default. Tiny Core installer does not change SSH config [22]: <Enter>
Max Telemt connections [5000]: <Enter>

Install plan:
  target OS:    Tiny Core Linux
  domain:       <PROXY_DOMAIN>
  email:        admin@<PROXY_DOMAIN>
  SSH port:     22 (not changed by this installer)
  Telemt limit: 5000
  release:      3.4.13

Type y or yes to continue:
y
```

In this example, an empty answer means “keep the default”. After `y`, installation starts: dependencies are installed through `tce-load`, nginx stream is configured, the Telemt native binary is downloaded and verified, `acme.sh` is installed, the certificate is issued, and configs, autostart, and persistence through `/opt/.filetool.lst` are written.

On Tiny Core, Telemt runs without Docker from a pinned native binary. The effective settings match the other installers: TLS mode only, `use_middle_proxy = false`, direct upstream, local read-only API, `config_strict = true`, and default connection limit `5000`.

After installation:

```text
/root/telemt-proxy-link.txt
/opt/telemt/telemt.toml
/opt/telemt/telemt-secret.env
/opt/telemt/bin/restart.sh
/opt/telemt/bin/renew-cert.sh
```

Health check:

```bash
telemt-report 5m
```

Manual restart:

```bash
/opt/telemt/bin/restart.sh
```

### Batch Mode

`install_telemt_batch_tinycore.sh` runs on the admin machine: macOS, Debian, Ubuntu, AlmaLinux, or any Linux with `bash`, `ssh`, `scp`, and a DNS lookup tool.

Tiny Core is required only on the target servers.

Run:

```bash
chmod +x install_telemt_batch_tinycore.sh ../common/add_key.sh
./install_telemt_batch_tinycore.sh
```

How the batch install works:

1. The script accepts domains one by one and finishes input on an empty line.
2. For every domain, it checks the `A` record and SSH access.
3. When access is ready, it copies `install_telemt_tinycore.sh` to the server and runs it remotely.
4. After a successful install, it reads `/root/telemt-proxy-link.txt` and prints the final `Proxy links` list.

Batch mode dialogue example:

```text
SSH user for installation [root]: root
Current SSH port for connecting to servers [22]: <Enter>
SSH port after install, Tiny Core installer does not change SSH config [22]: <Enter>
Telemt max TCP connections [5000]: <Enter>
Common Let's Encrypt email, empty = admin@domain []: <Enter>

Domain: proxy-one.example.com
Server IP to use [<SERVER_PUBLIC_IP>]: <Enter>
Domain:
```

An empty answer keeps the default. An empty `Domain:` finishes the server list. If SSH key login does not work, the script shows:

```text
1) Copy/install key with add_key.sh (recommended)
2) Use SSH password for this installation
3) Skip this server
Choose [1/2/3]:
```

Option `1` runs `add_key.sh` and may ask for the SSH password to copy the key. Option `2` uses interactive SSH/SCP password prompts only for the current installation. Option `3` skips the server.

The `Proxy links` block contains live Telegram proxy links with secrets. Treat them like passwords.

### Resume

State files:

```text
/opt/telemt/.install_tinycore.state
/opt/telemt/install.conf
```

Reset state:

```bash
RESET_INSTALL_STATE=1 sh /root/install_telemt_tinycore.sh
```
