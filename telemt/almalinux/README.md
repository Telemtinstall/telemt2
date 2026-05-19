# Telemt AlmaLinux Installer

> RU: Это не официальный установщик Telemt или AlmaLinux-пакетов. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is not an official Telemt or AlmaLinux package installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

## RU

Эти файлы предназначены для AlmaLinux-серверов и не заменяют Debian/Ubuntu-скрипты.

```text
install_telemt_alma.sh          установка одного AlmaLinux-сервера
install_telemt_batch_alma.sh    пакетная установка на несколько AlmaLinux-серверов
add_key.sh                      вспомогательный скрипт для копирования SSH-ключа
```

### Что ставит install_telemt_alma.sh

Установщик поднимает весь стек Telemt для AlmaLinux: Docker CE с плагином Docker Compose, Telemt в Docker, HTTP -> HTTPS редирект на `80/tcp`, nginx Stream SNI-маршрутизацию на `443/tcp`, маскировочный HTTPS-сайт на `127.0.0.1:8443`, Telemt backend на `127.0.0.1:1443` и локальный Telemt API на `127.0.0.1:9091`.

Также он выпускает Let's Encrypt сертификат, включает автопродление с certbot hooks для остановки/запуска nginx при standalone-renew, настраивает `firewalld`, SSH-port настройки, отключает nginx access logs и runtime-логи Docker-контейнера Telemt, а в конце добавляет утилиту `telemt-report`. Fail2ban и swap включаются только по отдельным вопросам.

### Важные отличия AlmaLinux-версии

В AlmaLinux-версии пакеты ставятся через `dnf`, EPEL включается для `certbot` и, если выбран fail2ban, для `fail2ban`, а Docker ставится из официального `docker-ce` репозитория. Nginx site-конфиг создаётся как `/etc/nginx/conf.d/<domain>.conf`, stream-конфиг как `/etc/nginx/stream-conf.d/telemt-sni.conf`.

Скрипт не перезаписывает `nginx.conf`: он только добавляет include для `stream-conf.d`, если такого include ещё нет. Если `443/tcp` уже занят чужим HTTPS-сервисом, установка останавливается. Firewall управляется через `firewalld`; если выбран fail2ban, он использует actions для firewalld. SELinux настраивается для `8443` и nginx proxy connect.

### Что спрашивает

1. Домен прокси.
2. Email для Let's Encrypt. По умолчанию используется `admin@<domain>`.
3. SSH-порт. По умолчанию используется `22`.
4. Отключать ли SSH-пароли и оставить root только по ключу. По умолчанию `no`.
5. Включать ли fail2ban для SSH. По умолчанию `no`.
6. Добавлять ли swap `1G`, если swap нет. По умолчанию `no`.
7. Лимит подключений Telemt. По умолчанию используется `5000`.

Пример полного диалога:

```text
Proxy domain: <PROXY_DOMAIN>
Let's Encrypt email [admin@<PROXY_DOMAIN>]: <Enter>
SSH port, Enter keeps current/default [22]: <Enter>
Disable SSH password login and keep root key-only? yes/no [no]: <Enter>
Enable fail2ban for SSH? yes/no [no]: <Enter>
Add 1G swap if missing? yes/no [no]: <Enter>
Max Telemt connections [5000]: <Enter>

Install plan:
  domain:       <PROXY_DOMAIN>
  public IPv4:  <SERVER_PUBLIC_IP>
  email:        admin@<PROXY_DOMAIN>
  SSH port:     22
  SSH key-only: no
  fail2ban SSH: no
  add swap:     no
  Telemt limit: 5000

Type y or yes to continue:
y
```

В примере пустой ответ означает “оставить значение по умолчанию”. По умолчанию SSH-пароли не отключаются, fail2ban не включается и swap не добавляется. После `y` начинается установка: `dnf` ставит системные пакеты, включается EPEL, ставятся Docker CE/Compose, nginx, certbot и firewalld, затем выпускается сертификат, создаются nginx/Telemt-конфиги, запускается контейнер и применяется firewall/SELinux/SSH-port настройка.

Перед выпуском сертификата скрипт проверяет, что `A`-запись домена указывает на публичный IPv4 текущего сервера.

Если на вопрос `Disable SSH password login and keep root key-only?` ответить `yes`, скрипт проверит `/root/.ssh/authorized_keys`, затем попросит второе подтверждение. Без найденного ключа и второго `yes` парольный SSH-вход не отключается.

### Важно: только чистый сервер

Используйте новый VPS/server без существующих сайтов, панелей управления и сетевых сервисов. Установщик настраивает nginx, firewalld, SSH-port, Docker/Telemt и сертификаты; ему нужны свободные `80/tcp` и `443/tcp`, а также локальные `8443`, `1443`, `9091`. Fail2ban включается только если выбрать `yes`. Если уже работают nginx/apache/caddy/traefik, почта, VPN, панели хостинга или другие прокси, возможны конфликты портов и конфигов. Для такого сервера лучше взять отдельную машину или интегрировать Telemt вручную.

### Как скачать файл на сервер

Если файл уже есть на вашем компьютере, скопируйте его через `scp`:

```bash
scp install_telemt_alma.sh root@<SERVER_PUBLIC_IP>:/root/
```

Если файл нужно скачать прямо с GitHub на сервере:

```bash
wget -O /root/install_telemt_alma.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/almalinux/install_telemt_alma.sh
chmod +x /root/install_telemt_alma.sh
```

То же самое через `curl`:

```bash
curl -fsSL -o /root/install_telemt_alma.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/almalinux/install_telemt_alma.sh
chmod +x /root/install_telemt_alma.sh
```

Если нужен именно `git`, скачайте только каталог AlmaLinux:

```bash
dnf install -y git
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt
cd /tmp/telemt
git sparse-checkout set telemt/almalinux
cp telemt/almalinux/install_telemt_alma.sh /root/
chmod +x /root/install_telemt_alma.sh
```

### Запуск на одном сервере

```bash
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_alma.sh
/root/install_telemt_alma.sh
```

После установки ссылка будет сохранена на сервере:

```bash
/root/telemt-proxy-link.txt
```

Проверка состояния:

```bash
telemt-report 5m
```

### Пакетная установка AlmaLinux

`install_telemt_batch_alma.sh` запускается на админской машине, например macOS, Debian, Ubuntu, AlmaLinux или любом другом Linux с `bash`, `ssh`, `scp` и DNS-утилитой. Он не ставит Telemt локально.

AlmaLinux нужна только на целевых серверах, куда batch-скрипт копирует и запускает `install_telemt_alma.sh`.

Как работает пакетная установка:

1. Сначала скрипт проверяет локальные `ssh`/`scp`/DNS-инструменты и спрашивает общие SSH/install-настройки.
2. Затем он принимает домены по одному. Пустая строка завершает ввод.
3. Для каждого домена скрипт проверяет `A`-запись и SSH-доступ по ключу.
4. Если ключевой вход не работает, можно запустить `add_key.sh`, использовать password mode (вход по паролю) или пропустить сервер.
5. Когда доступ готов, скрипт копирует `install_telemt_alma.sh` на каждый сервер и запускает его удалённо.
6. После успешной установки скрипт читает `/root/telemt-proxy-link.txt` и в конце печатает общий список `Proxy links`.

Пример диалога batch-режима:

```text
SSH user for installation [root]: root
Current SSH port for connecting to servers [22]: <Enter>
SSH port to configure on installed servers [22]: <Enter>
Enable fail2ban for SSH? yes/no [no]: <Enter>
Add 1G swap if missing? yes/no [no]: <Enter>
Telemt max TCP connections [5000]: <Enter>
Common Let's Encrypt email, empty = admin@domain []: <Enter>

Domain: proxy-one.example.com
Server IP to use [<SERVER_PUBLIC_IP>]: <Enter>
Domain: proxy-two.example.com
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

Запуск:

```bash
chmod +x install_telemt_batch_alma.sh ../common/add_key.sh
./install_telemt_batch_alma.sh
```

Пример:

```text
Domain: proxy-one.example.com
Domain: proxy-two.example.com
Domain:
```

Пустая строка завершает ввод доменов.

Блок `Proxy links` содержит рабочие Telegram proxy-ссылки с секретами. Относитесь к ним как к паролям.

### Повторный запуск

Скрипт сохраняет состояние:

```text
/root/.install_telemt_alma.state
/root/.install_telemt_alma.config
```

Если соединение оборвалось, можно запустить скрипт повторно. Уже пройденные шаги будут пропущены.

Сброс состояния:

```bash
RESET_INSTALL_STATE=1 bash /root/install_telemt_alma.sh
```

Секрет Telemt сохраняется отдельно и при обычном повторном запуске не меняется:

```text
/root/telemt-secret.env
```

---

## EN

These files are for AlmaLinux servers and do not replace the Debian/Ubuntu scripts.

```text
install_telemt_alma.sh          single AlmaLinux server installer
install_telemt_batch_alma.sh    batch installer for multiple AlmaLinux servers
add_key.sh                      helper for copying an SSH public key
```

### What install_telemt_alma.sh installs

The installer brings up the full Telemt stack for AlmaLinux: Docker CE with the compose plugin, Telemt in Docker, an HTTP -> HTTPS redirect on `80/tcp`, nginx Stream SNI routing on `443/tcp`, an HTTPS mask site on `127.0.0.1:8443`, a Telemt backend on `127.0.0.1:1443`, and a local-only Telemt API on `127.0.0.1:9091`.

It also issues a Let's Encrypt certificate, enables renewal with certbot hooks that stop/start nginx for standalone renewal, configures `firewalld`, SSH-port settings, disables nginx access logs and Telemt Docker runtime logs, and installs the `telemt-report` utility. Fail2ban and swap are enabled only when selected in the prompts.

### AlmaLinux-specific differences

In the AlmaLinux version, packages are installed with `dnf`, EPEL is enabled for `certbot` and, if selected, `fail2ban`, and Docker is installed from the official `docker-ce` repository. The nginx site config is created as `/etc/nginx/conf.d/<domain>.conf`, and the stream config is created as `/etc/nginx/stream-conf.d/telemt-sni.conf`.

The script does not overwrite `nginx.conf`: it only adds the `stream-conf.d` include if it is missing. If `443/tcp` is already owned by another HTTPS service, installation stops. Firewall is managed with `firewalld`; if fail2ban is selected, it uses firewalld actions. SELinux is configured for `8443` and nginx proxy connect.

### Prompts

1. Proxy domain.
2. Let's Encrypt email. The default is `admin@<domain>`.
3. SSH port. The default is `22`.
4. Whether to disable SSH password login and keep root key-only. The default is `no`.
5. Whether to enable fail2ban for SSH. The default is `no`.
6. Whether to add `1G` swap if swap is missing. The default is `no`.
7. Max Telemt connections. The default is `5000`.

Full dialogue example:

```text
Proxy domain: <PROXY_DOMAIN>
Let's Encrypt email [admin@<PROXY_DOMAIN>]: <Enter>
SSH port, Enter keeps current/default [22]: <Enter>
Disable SSH password login and keep root key-only? yes/no [no]: <Enter>
Enable fail2ban for SSH? yes/no [no]: <Enter>
Add 1G swap if missing? yes/no [no]: <Enter>
Max Telemt connections [5000]: <Enter>

Install plan:
  domain:       <PROXY_DOMAIN>
  public IPv4:  <SERVER_PUBLIC_IP>
  email:        admin@<PROXY_DOMAIN>
  SSH port:     22
  SSH key-only: no
  fail2ban SSH: no
  add swap:     no
  Telemt limit: 5000

Type y or yes to continue:
y
```

In this example, an empty answer means “keep the default”. By default, SSH password login is not disabled, fail2ban is not enabled, and swap is not added. After `y`, installation starts: `dnf` installs system packages, EPEL is enabled, Docker CE/Compose, nginx, certbot, and firewalld are installed, then the certificate is issued, nginx/Telemt configs are written, the container starts, and firewall/SELinux/SSH-port settings are applied.

Before issuing a certificate, the script checks that the domain `A` record points to the current server public IPv4.

If you answer `yes` to `Disable SSH password login and keep root key-only?`, the script checks `/root/.ssh/authorized_keys`, then asks for a second confirmation. Without a detected key and the second `yes`, password SSH login is not disabled.

### Important: Clean Server Only

Use a new VPS/server without existing websites, control panels, or network services. The installer configures nginx, firewalld, SSH-port, Docker/Telemt, and certificates; it needs free `80/tcp` and `443/tcp`, plus local `8443`, `1443`, and `9091`. Fail2ban is enabled only if you choose `yes`. If nginx/apache/caddy/traefik, mail, VPN, hosting panels, or other proxies already run on the server, port and config conflicts are possible. Use a separate machine or integrate Telemt manually.

### How To Download The File To The Server

If the file is already on your computer, copy it with `scp`:

```bash
scp install_telemt_alma.sh root@<SERVER_PUBLIC_IP>:/root/
```

If you want to download it directly from GitHub on the server:

```bash
wget -O /root/install_telemt_alma.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/almalinux/install_telemt_alma.sh
chmod +x /root/install_telemt_alma.sh
```

The same with `curl`:

```bash
curl -fsSL -o /root/install_telemt_alma.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/almalinux/install_telemt_alma.sh
chmod +x /root/install_telemt_alma.sh
```

If you specifically want to use `git`, download only the AlmaLinux directory:

```bash
dnf install -y git
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt
cd /tmp/telemt
git sparse-checkout set telemt/almalinux
cp telemt/almalinux/install_telemt_alma.sh /root/
chmod +x /root/install_telemt_alma.sh
```

### Single-server install

```bash
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_alma.sh
/root/install_telemt_alma.sh
```

The generated link is stored on the server:

```bash
/root/telemt-proxy-link.txt
```

Health check:

```bash
telemt-report 5m
```

### AlmaLinux batch install

`install_telemt_batch_alma.sh` runs on the admin machine, for example macOS, Debian, Ubuntu, AlmaLinux, or any other Linux with `bash`, `ssh`, `scp`, and a DNS lookup tool. It does not install Telemt locally.

AlmaLinux is required only on the target servers where the batch script copies and runs `install_telemt_alma.sh`.

How the batch install works:

1. First, the script checks local `ssh`/`scp`/DNS tools and asks for common SSH/install settings.
2. Then it accepts domains one by one. An empty line finishes input.
3. For every domain, it checks the `A` record and SSH key login.
4. If key login does not work, you can run `add_key.sh`, use password mode, or skip the server.
5. When access is ready, the script copies `install_telemt_alma.sh` to each server and runs it remotely.
6. After a successful install, it reads `/root/telemt-proxy-link.txt` and prints the final `Proxy links` list.

Batch mode dialogue example:

```text
SSH user for installation [root]: root
Current SSH port for connecting to servers [22]: <Enter>
SSH port to configure on installed servers [22]: <Enter>
Enable fail2ban for SSH? yes/no [no]: <Enter>
Add 1G swap if missing? yes/no [no]: <Enter>
Telemt max TCP connections [5000]: <Enter>
Common Let's Encrypt email, empty = admin@domain []: <Enter>

Domain: proxy-one.example.com
Server IP to use [<SERVER_PUBLIC_IP>]: <Enter>
Domain: proxy-two.example.com
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

Run:

```bash
chmod +x install_telemt_batch_alma.sh ../common/add_key.sh
./install_telemt_batch_alma.sh
```

Example:

```text
Domain: proxy-one.example.com
Domain: proxy-two.example.com
Domain:
```

An empty line finishes domain input.

The `Proxy links` block contains live Telegram proxy links with secrets. Treat them like passwords.

### Resume

The installer saves state:

```text
/root/.install_telemt_alma.state
/root/.install_telemt_alma.config
```

If the connection drops, rerun the script. Completed steps will be skipped.

Reset state:

```bash
RESET_INSTALL_STATE=1 bash /root/install_telemt_alma.sh
```

The Telemt secret is saved separately and is not changed on a normal rerun:

```text
/root/telemt-secret.env
```
