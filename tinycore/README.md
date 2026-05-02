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

В Tiny Core версии нет Docker, systemd, apt/dnf и обычного `certbot.timer`. Зависимости ставятся через `tce-load`, Telemt ставится как нативный `musl` бинарник из GitHub releases, автозапуск делается через `/opt/bootlocal.sh`, а persistence фиксируется через `/opt/.filetool.lst` и `filetool.sh -b`. Сертификат выпускается через `acme.sh` в standalone mode.

### Требования

1. Tiny Core Linux `x86_64`/CorePure64 или `aarch64`.
2. Настроенный persistent `/tce`.
3. Root-доступ.
4. Открытые `80/tcp` и `443/tcp`.
5. `A`-запись домена должна указывать на публичный IPv4 сервера.

### Важно: только чистый сервер

Используйте новый Tiny Core сервер без существующих сайтов, панелей управления и сетевых сервисов. Установщик настраивает nginx stream, Telemt, acme.sh, autostart и persistence; ему нужны свободные `80/tcp` и `443/tcp`, а также локальные `8443`, `1443`, `9091`. Если на сервере уже есть web/proxy/VPN/mail-сервисы, возможны конфликты портов и потеря настроек после reboot из-за persistence. Для таких случаев лучше отдельная машина или ручная интеграция.

Официальный Telemt сейчас публикует `linux-musl` бинарники для `x86_64` и `aarch64`. Поэтому 32-bit Tiny Core x86 этим скриптом не поддерживается.

По умолчанию используется pinned Telemt release `3.4.0` и pinned `acme.sh` `3.1.2`; оба скачивания проверяются через sha256. Для другого release нужно передать свои `TELEMT_RELEASE`, `TELEMT_SHA256_X86_64` / `TELEMT_SHA256_AARCH64`.

### Что Ставит

Скрипт ставит базовые зависимости (`bash`, `curl`, `ca-certificates`, `openssl`, `nginx`, `socat`), а также optional-компоненты `jq` и `iproute2`, если они доступны. Для сертификатов используется `acme.sh`, а Telemt ставится как нативный бинарник.

При установке используются закреплённые версии Telemt и `acme.sh` с проверкой sha256. Nginx access logs и Telemt runtime logs отключаются.

### Схема

```text
Internet
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

### Запуск На Одном Сервере

```bash
scp install_telemt_tinycore.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_tinycore.sh
/root/install_telemt_tinycore.sh
```

Скрипт спросит домен прокси, email для Let's Encrypt со значением по умолчанию `admin@<domain>`, SSH-порт только для подсказок и batch-режима, а также лимит подключений Telemt со значением по умолчанию `1000`.

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

The Tiny Core version has no Docker, systemd, apt/dnf, or regular `certbot.timer`. Dependencies are installed via `tce-load`, Telemt is installed as a native `musl` binary from GitHub releases, autostart is handled through `/opt/bootlocal.sh`, and persistence is saved through `/opt/.filetool.lst` and `filetool.sh -b`. Certificates are issued through `acme.sh` in standalone mode.

### Requirements

1. Tiny Core Linux `x86_64`/CorePure64 or `aarch64`.
2. Configured persistent `/tce`.
3. Root access.
4. Open `80/tcp` and `443/tcp`.
5. The domain `A` record must point to the server public IPv4.

### Important: Clean Server Only

Use a new Tiny Core server without existing websites, control panels, or network services. The installer configures nginx stream, Telemt, acme.sh, autostart, and persistence; it needs free `80/tcp` and `443/tcp`, plus local `8443`, `1443`, and `9091`. If web/proxy/VPN/mail services already exist, port conflicts and reboot persistence issues are possible. Use a separate machine or integrate manually.

Official Telemt currently publishes `linux-musl` binaries for `x86_64` and `aarch64`. 32-bit Tiny Core x86 is not supported by this script.

By default, the installer uses pinned Telemt release `3.4.0` and pinned `acme.sh` `3.1.2`; both downloads are verified with sha256. To use another release, pass your own `TELEMT_RELEASE`, `TELEMT_SHA256_X86_64` / `TELEMT_SHA256_AARCH64`.

### What It Installs

The script installs base dependencies (`bash`, `curl`, `ca-certificates`, `openssl`, `nginx`, `socat`), plus optional `jq` and `iproute2` when available. Certificates are handled by `acme.sh`, and Telemt is installed as a native binary.

The installer uses a pinned Telemt release and pinned `acme.sh` version with sha256 verification. Nginx access logs and Telemt runtime logs are disabled.

### Layout

```text
Internet
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

### Single-Server Install

```bash
scp install_telemt_tinycore.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_tinycore.sh
/root/install_telemt_tinycore.sh
```

The script asks for the proxy domain, Let's Encrypt email with default `admin@<domain>`, SSH port only for hints and batch mode, and max Telemt connections with default `1000`.

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
