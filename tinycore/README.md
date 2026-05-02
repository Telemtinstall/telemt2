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

```text
нет Docker
нет systemd
нет apt/dnf
нет обычного certbot.timer
зависимости ставятся через tce-load
Telemt ставится как native musl binary из GitHub releases
автозапуск делается через /opt/bootlocal.sh
персистентность делается через /opt/.filetool.lst и filetool.sh -b
сертификат выпускается через acme.sh standalone mode
```

### Требования

```text
Tiny Core Linux x86_64/CorePure64 или aarch64
настроенный persistent /tce
root-доступ
открытые 80/tcp и 443/tcp
A-запись домена должна указывать на публичный IPv4 сервера
```

Официальный Telemt сейчас публикует `linux-musl` бинарники для `x86_64` и `aarch64`. Поэтому 32-bit Tiny Core x86 этим скриптом не поддерживается.

По умолчанию используется pinned Telemt release `3.4.0` и pinned `acme.sh` `3.1.2`; оба скачивания проверяются через sha256. Для другого release нужно передать свои `TELEMT_RELEASE`, `TELEMT_SHA256_X86_64` / `TELEMT_SHA256_AARCH64`.

### Что Ставит

```text
bash
curl
ca-certificates
openssl
nginx
socat
jq, optional
iproute2, optional
acme.sh
native Telemt binary
nginx access logs disabled
Telemt runtime logs disabled
pinned Telemt release and sha256 verification
pinned acme.sh version and sha256 verification
```

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

```text
не меняет SSH port
не отключает SSH password login
не ставит fail2ban
не использует Docker
не использует systemd
```

SSH-hardening на Tiny Core лучше делать отдельно, потому что там часто используется не стандартный OpenSSH/systemd-layout.

### Запуск На Одном Сервере

```bash
scp install_telemt_tinycore.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_tinycore.sh
/root/install_telemt_tinycore.sh
```

Скрипт спросит:

```text
Proxy domain
Let's Encrypt email, по умолчанию admin@<domain>
SSH port, только для подсказок и batch-режима
Max Telemt connections, по умолчанию 1000
```

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

Пакетный скрипт:

```text
спрашивает домены
проверяет A-записи
проверяет SSH-доступ
копирует install_telemt_tinycore.sh на серверы
запускает его удаленно
после успешной установки читает /root/telemt-proxy-link.txt
печатает итоговый список Proxy links
```

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

```text
no Docker
no systemd
no apt/dnf
no regular certbot.timer
dependencies are installed via tce-load
Telemt is installed as a native musl binary from GitHub releases
autostart is handled through /opt/bootlocal.sh
persistence is handled through /opt/.filetool.lst and filetool.sh -b
certificates are issued through acme.sh standalone mode
```

### Requirements

```text
Tiny Core Linux x86_64/CorePure64 or aarch64
configured persistent /tce
root access
open 80/tcp and 443/tcp
the domain A record must point to the server public IPv4
```

Official Telemt currently publishes `linux-musl` binaries for `x86_64` and `aarch64`. 32-bit Tiny Core x86 is not supported by this script.

By default, the installer uses pinned Telemt release `3.4.0` and pinned `acme.sh` `3.1.2`; both downloads are verified with sha256. To use another release, pass your own `TELEMT_RELEASE`, `TELEMT_SHA256_X86_64` / `TELEMT_SHA256_AARCH64`.

### What It Installs

```text
bash
curl
ca-certificates
openssl
nginx
socat
jq, optional
iproute2, optional
acme.sh
native Telemt binary
nginx access logs disabled
Telemt runtime logs disabled
pinned Telemt release and sha256 verification
pinned acme.sh version and sha256 verification
```

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

```text
does not change SSH port
does not disable SSH password login
does not install fail2ban
does not use Docker
does not use systemd
```

SSH hardening is better handled separately on Tiny Core because deployments often use non-standard OpenSSH/Dropbear layouts.

### Single-Server Install

```bash
scp install_telemt_tinycore.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_tinycore.sh
/root/install_telemt_tinycore.sh
```

The script asks for:

```text
Proxy domain
Let's Encrypt email, default admin@<domain>
SSH port, only for hints and batch mode
Max Telemt connections, default 1000
```

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

The batch script:

```text
asks for domains
checks A records
checks SSH access
copies install_telemt_tinycore.sh to servers
runs it remotely
reads /root/telemt-proxy-link.txt after successful installs
prints the final Proxy links list
```

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
