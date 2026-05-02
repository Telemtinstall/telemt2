# Telemt AlmaLinux Installer

## RU

Эти файлы предназначены для AlmaLinux-серверов и не заменяют Debian/Ubuntu-скрипты.

```text
install_telemt_alma.sh          установка одного AlmaLinux-сервера
install_telemt_batch_alma.sh    пакетная установка на несколько AlmaLinux-серверов
add_key.sh                      вспомогательный скрипт для копирования SSH-ключа
```

### Что ставит install_telemt_alma.sh

```text
Docker CE + docker compose plugin
Telemt в Docker
nginx Stream SNI routing на 443/tcp
маскировочный HTTPS-сайт на 127.0.0.1:8443
Telemt backend на 127.0.0.1:1443
Telemt API на 127.0.0.1:9091
Let's Encrypt сертификат
автопродление сертификата
firewalld
fail2ban
nginx access logs disabled
Telemt Docker runtime logs disabled
SSH hardening
telemt-report
```

### Важные отличия AlmaLinux-версии

```text
пакеты ставятся через dnf
EPEL включается для certbot/fail2ban
Docker ставится из официального docker-ce repo
nginx config: /etc/nginx/conf.d/<domain>.conf
nginx stream config: /etc/nginx/stream-conf.d/telemt-sni.conf
firewall управляется через firewalld
fail2ban использует firewalld actions
SELinux настраивается для 8443 и nginx proxy connect
```

### Что спрашивает

```text
Proxy domain
Let's Encrypt email, по умолчанию admin@<domain>
SSH port, по умолчанию 22
Max Telemt connections, по умолчанию 1000
```

Перед выпуском сертификата скрипт проверяет, что `A`-запись домена указывает на публичный IPv4 текущего сервера.

### Запуск на одном сервере

```bash
scp install_telemt_alma.sh root@<SERVER_PUBLIC_IP>:/root/
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

Что делает:

```text
проверяет локальные ssh/scp/DNS-инструменты
просит общие SSH/install настройки
просит домены по одному
проверяет A-записи
проверяет SSH-доступ по ключу
если ключ не работает, предлагает add_key.sh, password mode или skip
копирует install_telemt_alma.sh на каждый сервер
запускает install_telemt_alma.sh удаленно
после успешной установки читает /root/telemt-proxy-link.txt
печатает итоговый список Proxy links
```

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

```text
Docker CE + docker compose plugin
Telemt in Docker
nginx Stream SNI routing on 443/tcp
HTTPS mask site on 127.0.0.1:8443
Telemt backend on 127.0.0.1:1443
Telemt API on 127.0.0.1:9091
Let's Encrypt certificate
certificate auto-renewal
firewalld
fail2ban
nginx access logs disabled
Telemt Docker runtime logs disabled
SSH hardening
telemt-report
```

### AlmaLinux-specific differences

```text
packages are installed with dnf
EPEL is enabled for certbot/fail2ban
Docker is installed from the official docker-ce repo
nginx config: /etc/nginx/conf.d/<domain>.conf
nginx stream config: /etc/nginx/stream-conf.d/telemt-sni.conf
firewall is managed with firewalld
fail2ban uses firewalld actions
SELinux is configured for 8443 and nginx proxy connect
```

### Prompts

```text
Proxy domain
Let's Encrypt email, default admin@<domain>
SSH port, default 22
Max Telemt connections, default 1000
```

Before issuing a certificate, the script checks that the domain `A` record points to the current server public IPv4.

### Single-server install

```bash
scp install_telemt_alma.sh root@<SERVER_PUBLIC_IP>:/root/
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

What it does:

```text
checks local ssh/scp/DNS tools
asks for common SSH/install settings
asks for domains one by one
checks A records
checks SSH key login
if the key does not work, offers add_key.sh, password mode, or skip
copies install_telemt_alma.sh to each server
runs install_telemt_alma.sh remotely
reads /root/telemt-proxy-link.txt after successful installs
prints the final Proxy links list
```

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
