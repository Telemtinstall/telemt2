# install_telemt_astra.sh

## Русское описание

`install_telemt_astra.sh` автоматически поднимает Telemt MTProto proxy на новом сервере Astra Linux без WireGuard.

Целевая схема после установки:

```text
Internet
  -> <PROXY_DOMAIN>:443
  -> nginx stream SNI router
     -> SNI = <PROXY_DOMAIN>
        -> 127.0.0.1:1443
        -> Telemt
     -> default / browser / scanner
        -> 127.0.0.1:8443
        -> HTTPS mask site
```

Снаружи открыт только HTTPS-порт `443`. Telemt не слушает внешний интерфейс напрямую, он доступен только локально на `127.0.0.1:1443`. API Telemt доступен только локально на `127.0.0.1:9091`.

### Что нужно до запуска

1. Новый VPS/server с Astra Linux.
2. Root-доступ по SSH.
3. Домен, уже направленный A-записью на публичный IPv4 сервера:

```text
<PROXY_DOMAIN> -> <SERVER_PUBLIC_IP>
```

4. Порты `80/tcp` и `443/tcp` должны быть доступны с интернета.
5. В `/root/.ssh/authorized_keys` должен быть SSH-ключ, потому что скрипт отключает SSH-пароли.

### Важно: только чистый сервер

Используйте новый VPS/server без существующих сайтов, панелей управления и сетевых сервисов. Установщик настраивает nginx, firewall, SSH hardening, Docker/Telemt и сертификаты; ему нужны свободные `80/tcp` и `443/tcp`, а также локальные `8443`, `1443`, `9091`. Если уже работают nginx/apache/caddy/traefik, почта, VPN, панели хостинга или другие прокси, возможны конфликты портов и конфигов. Для такого сервера лучше взять отдельную машину или интегрировать Telemt вручную.

### Как запускать

Скрипт нужно запускать на целевом сервере, а не на локальном компьютере.

```bash
scp install_telemt_astra.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh
```

Рекомендуемый способ для долгой установки, чтобы пережить обрыв SSH:

```bash
tmux new -s telemt-install
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh
```

Если SSH оборвался, вернуться в сессию:

```bash
tmux attach -t telemt-install
```

Если `tmux` не установлен, можно просто запустить скрипт повторно. Скрипт сохраняет прогресс и пропускает уже завершённые шаги.

### Что спросит скрипт

1. Домен прокси:

```text
Proxy domain:
```

2. Email для Let's Encrypt. По умолчанию:

```text
admin@<PROXY_DOMAIN>
```

3. SSH-порт. По умолчанию:

```text
22
```

Можно нажать Enter и оставить `22`, либо указать другой порт.

4. Лимит подключений Telemt. По умолчанию:

```text
1000
```

Можно нажать Enter и оставить `1000`, либо указать другое число.

После показа плана установки скрипт спросит подтверждение. Можно ввести `y`, `yes` или `YES`.

### Проверки перед установкой

Скрипт определяет публичный IPv4 сервера и проверяет DNS:

```text
<PROXY_DOMAIN> must resolve to <SERVER_PUBLIC_IP>
```

Если домен ещё не указывает на IP сервера, установка остановится до получения SSL-сертификата.

Скрипт также проверяет наличие:

```text
/root/.ssh/authorized_keys
```

Если ключей нет, установка остановится, чтобы не отключить парольный вход и не заблокировать доступ.

### Продолжение После Обрыва

Скрипт сохраняет состояние установки:

```text
/root/.install_telemt.state
/root/.install_telemt.config
```

Секрет Telemt сохраняется отдельно:

```text
/root/telemt-secret.env
```

Если SSH-сессия оборвалась или команда прервалась, зайдите на сервер снова и запустите:

```bash
bash /root/install_telemt_astra.sh
```

Скрипт повторно спросит параметры, подставит сохранённые значения по умолчанию и пропустит шаги, которые уже были успешно завершены.

Чтобы начать установку заново без учёта state-файла:

```bash
RESET_INSTALL_STATE=1 bash /root/install_telemt_astra.sh
```

Это сбрасывает только маркеры прогресса и сохранённые параметры установщика. Уже созданные системные файлы, сертификаты, Docker-образы и конфиги не удаляются.

### Что устанавливается

Скрипт ставит и настраивает:

```text
docker / docker-compose
nginx
nginx stream module
certbot
fail2ban
nftables
jq
curl
openssl
```

Также добавляется swap `1G`, если swap ещё не включён.

### Что настраивается

1. Let's Encrypt сертификат для `<PROXY_DOMAIN>`.
2. Автопродление сертификата через `certbot.timer`.
3. Deploy-hook для `reload nginx` после успешного продления.
4. Nginx stream router на внешнем `443/tcp`.
5. Маскировочный HTTPS-сайт на `127.0.0.1:8443`; HTML-страница создаётся в `/var/www/<PROXY_DOMAIN>/index.html`, а её `<title>` и `<h1>` равны введённому домену.
6. Telemt backend на `127.0.0.1:1443`.
7. Telemt API на `127.0.0.1:9091`.
8. Firewall-правило, закрывающее `9091/tcp` снаружи.
9. Fail2ban для SSH.
10. Отключение nginx access logs для маскировочного сайта.
11. Отключение Docker runtime logs для Telemt-контейнера.
12. Безопасное поведение nginx: скрипт добавляет отдельный site/stream config и не удаляет существующие сайты. Если `443/tcp` уже занят чужим HTTPS-сервисом, установка останавливается до изменения frontend-а.
13. SSH hardening:

```text
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```

### Telemt настройки

Telemt запускается в Docker:

```text
container_name: telemt
network_mode: host
user: 65532:65532
read_only: true
cap_drop: ALL
no-new-privileges: true
```

Основные параметры Telemt:

```text
classic = false
secure = false
tls = true
use_middle_proxy = false
upstream = direct
max_tcp_conns = <LIMIT>
```

WireGuard не используется.

### Результат установки

После успешного завершения будут созданы:

```text
/opt/telemt-config/telemt.toml
/opt/telemt-config/docker-compose.yml
/root/telemt-proxy-link.txt
/root/telemt-secret.env
/usr/local/sbin/telemt-report
/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
/etc/nginx/modules-enabled/60-stream-sni.conf
/etc/nginx/sites-available/<PROXY_DOMAIN>
/var/www/<PROXY_DOMAIN>/index.html
```

Прокси-ссылка печатается в конце установки и дополнительно сохраняется в файл:

```bash
cat /root/telemt-proxy-link.txt
```

Отчёт по серверу:

```bash
telemt-report 5m
```

Проверка автопродления сертификата:

```bash
systemctl status certbot.timer
systemctl list-timers certbot.timer
certbot renew --dry-run
```

Проверка портов:

```bash
ss -lntp | grep -E ':(443|8443|1443|9091)'
```

Ожидаемая схема портов:

```text
0.0.0.0:443        nginx
127.0.0.1:8443     nginx mask site
127.0.0.1:1443     telemt
127.0.0.1:9091     telemt API
```

### Важные замечания

После установки нужно открыть вторую SSH-сессию и проверить вход:

```bash
ssh -p <SSH_PORT> root@<PROXY_DOMAIN>
```

Не закрывайте первую SSH-сессию, пока не убедитесь, что новый вход работает.

Если SSL не выпускается, почти всегда причина одна из этих:

```text
DNS ещё не указывает на сервер
порт 80 закрыт
порт 443 занят другим сервисом
провайдерский firewall блокирует входящие подключения
```

### Вспомогательный Инструмент add_key.sh

`add_key.sh` помогает подготовить SSH-доступ к серверу до запуска `install_telemt_astra.sh`.

Как он работает:

1. Спрашивает адрес сервера, SSH-порт, пользователя, путь к локальному ключу и комментарий для нового ключа.
2. Создаёт локальный `ed25519` ключ, если выбранного ключа ещё нет. Если приватный ключ есть, а `.pub` файл отсутствует, восстанавливает публичный ключ.
3. Проверяет `known_hosts`: показывает SHA256 fingerprint host key перед добавлением или остановится при несовпадении с `EXPECTED_HOST_KEY_SHA256`.
4. На Unix/Linux сервере добавляет публичный ключ в `authorized_keys`; если основной способ не сработал, пробует `ssh-copy-id`.
5. Для MikroTik RouterOS использует отдельный импорт ключа.
6. В конце проверяет, что вход по ключу без пароля действительно работает.

Запуск:

```bash
chmod +x ../common/add_key.sh
../common/add_key.sh
```

Запуск с параметрами через environment:

```bash
chmod +x ../common/add_key.sh
SERVER_INPUT=root@<SERVER_PUBLIC_IP> SERVER_PORT=<SSH_PORT> KEY_PATH=~/.ssh/id_ed25519 ../common/add_key.sh
```

После успешной проверки ключа можно копировать и запускать установщик:

```bash
scp install_telemt_astra.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh
```

### Пакетная Установка install_telemt_batch_astra.sh

`install_telemt_batch_astra.sh` запускается на локальной админской машине и устанавливает Telemt сразу на несколько серверов.

Важно: пакетный скрипт не содержит отдельной копии логики установки Telemt. Он использует основной `install_telemt_astra.sh`: копирует его на каждый сервер и запускает удалённо.

Пакетный скрипт можно запускать на локальной машине с:

```text
macOS
любой Linux на админской машине
```

Перед началом пакетный скрипт проверяет локальные зависимости:

```text
bash 3+
ssh
scp
один DNS resolver: getent, dig или host
install_telemt_astra.sh рядом с install_telemt_batch_astra.sh
../common/add_key.sh относительно каталога astra
```

Если чего-то не хватает, скрипт остановится до любых подключений к серверам.

Что делает пакетный скрипт:

```text
спрашивает общие SSH/install настройки
спрашивает домены по одному
пользователь вводит домен, Enter, следующий домен, Enter
пустая строка завершает ввод доменов
проверяет A-запись каждого домена
если A-записи нет, предлагает указать другой домен с A-записью
проверяет SSH-вход по ключу на каждый сервер
если ключ не работает, предлагает add_key.sh, password mode или skip
копирует install_telemt_astra.sh на сервер
запускает install_telemt_astra.sh удалённо с выбранным доменом и настройками
печатает результат по каждому домену
после успешной установки читает /root/telemt-proxy-link.txt
печатает итоговый список Proxy links
```

Блок `Proxy links` содержит рабочие Telegram proxy-ссылки с секретами. Относитесь к ним как к паролям.

Запуск:

```bash
chmod +x install_telemt_batch_astra.sh ../common/add_key.sh
./install_telemt_batch_astra.sh
```

Пример ввода доменов:

```text
Domain: proxy-one.example.com
Domain: proxy-two.example.com
Domain:
```

Пустой `Domain:` завершает список.

Опциональные переменные:

```bash
chmod +x install_telemt_batch_astra.sh ../common/add_key.sh
CONNECT_SSH_PORT=22 TARGET_SSH_PORT=22 TELEMT_MAX_TCP_CONNS=1000 ./install_telemt_batch_astra.sh
```

`install_telemt_astra.sh` и `add_key.sh` остаются самостоятельными скриптами: их можно запускать отдельно без пакетного режима.

---

## English Description

`install_telemt_astra.sh` automatically installs a Telemt MTProto proxy on a new server without WireGuard.

Target architecture after installation:

```text
Internet
  -> <PROXY_DOMAIN>:443
  -> nginx stream SNI router
     -> SNI = <PROXY_DOMAIN>
        -> 127.0.0.1:1443
        -> Telemt
     -> default / browser / scanner
        -> 127.0.0.1:8443
        -> HTTPS mask site
```

Only external port `443` is exposed. Telemt does not listen on the public network interface directly. It listens only on `127.0.0.1:1443`. The Telemt API is local-only on `127.0.0.1:9091`.

### Requirements Before Running

1. A fresh Astra Linux VPS/server.
2. Root SSH access.
3. A domain with an A record already pointing to the server public IPv4:

```text
<PROXY_DOMAIN> -> <SERVER_PUBLIC_IP>
```

4. Ports `80/tcp` and `443/tcp` must be reachable from the internet.
5. `/root/.ssh/authorized_keys` must contain your SSH public key because the script disables SSH password login.

### Important: Clean Server Only

Use a new VPS/server without existing websites, control panels, or network services. The installer configures nginx, firewall, SSH hardening, Docker/Telemt, and certificates; it needs free `80/tcp` and `443/tcp`, plus local `8443`, `1443`, and `9091`. If nginx/apache/caddy/traefik, mail, VPN, hosting panels, or other proxies already run on the server, port and config conflicts are possible. Use a separate machine or integrate Telemt manually.

### How To Run

Run the script on the target server, not on your local computer.

```bash
scp install_telemt_astra.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh
```

Recommended method for long installations, so the process survives SSH disconnects:

```bash
tmux new -s telemt-install
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh
```

If SSH disconnects, reattach:

```bash
tmux attach -t telemt-install
```

If `tmux` is not installed, you can simply rerun the script. The installer stores progress and skips completed steps.

### Script Prompts

1. Proxy domain:

```text
Proxy domain:
```

2. Let's Encrypt email. Default:

```text
admin@<PROXY_DOMAIN>
```

3. SSH port. Default:

```text
22
```

Press Enter to keep `22`, or type a different port.

4. Telemt connection limit. Default:

```text
1000
```

Press Enter to keep `1000`, or type another number.

After showing the installation plan, the script asks for confirmation. You can type `y`, `yes`, or `YES`.

### Preflight Checks

The script detects the server public IPv4 and checks DNS:

```text
<PROXY_DOMAIN> must resolve to <SERVER_PUBLIC_IP>
```

If the domain does not point to the server IP yet, the installation stops before requesting the SSL certificate.

The script also checks:

```text
/root/.ssh/authorized_keys
```

If no SSH key is found, the installation stops to avoid locking you out after password login is disabled.

### Resume After Disconnect

The installer stores progress in:

```text
/root/.install_telemt.state
/root/.install_telemt.config
```

The Telemt secret is stored separately:

```text
/root/telemt-secret.env
```

If the SSH session disconnects or the command is interrupted, log into the server again and run:

```bash
bash /root/install_telemt_astra.sh
```

The script will ask for parameters again, use saved values as defaults, and skip steps that were already completed successfully.

To restart the installer without using the progress state:

```bash
RESET_INSTALL_STATE=1 bash /root/install_telemt_astra.sh
```

This resets only installer progress markers and saved installer parameters. Existing system files, certificates, Docker images, and configs are not deleted.

### Installed Packages

The script installs and configures:

```text
docker / docker-compose
nginx
nginx stream module
certbot
fail2ban
nftables
jq
curl
openssl
```

It also adds `1G` swap if swap is not already enabled.

### Configured Components

1. Let's Encrypt certificate for `<PROXY_DOMAIN>`.
2. Automatic certificate renewal via `certbot.timer`.
3. Deploy hook that reloads nginx after a successful renewal.
4. Nginx stream router on public `443/tcp`.
5. HTTPS mask site on `127.0.0.1:8443`; the HTML page is created at `/var/www/<PROXY_DOMAIN>/index.html`, and its `<title>` and `<h1>` are set to the entered domain.
6. Telemt backend on `127.0.0.1:1443`.
7. Telemt API on `127.0.0.1:9091`.
8. Firewall rule blocking external access to `9091/tcp`.
9. Fail2ban for SSH.
10. Disabled nginx access logs for the mask site.
11. Disabled Docker runtime logs for the Telemt container.
12. Safe nginx behavior: the installer adds separate site/stream configs and does not remove existing sites. If `443/tcp` is already owned by another HTTPS service, installation stops before changing the frontend.
13. SSH hardening:

```text
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```

### Telemt Settings

Telemt runs in Docker:

```text
container_name: telemt
network_mode: host
user: 65532:65532
read_only: true
cap_drop: ALL
no-new-privileges: true
```

Main Telemt parameters:

```text
classic = false
secure = false
tls = true
use_middle_proxy = false
upstream = direct
max_tcp_conns = <LIMIT>
```

WireGuard is not used.

### Installation Result

After a successful run, these files are created:

```text
/opt/telemt-config/telemt.toml
/opt/telemt-config/docker-compose.yml
/root/telemt-proxy-link.txt
/root/telemt-secret.env
/usr/local/sbin/telemt-report
/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
/etc/nginx/modules-enabled/60-stream-sni.conf
/etc/nginx/sites-available/<PROXY_DOMAIN>
/var/www/<PROXY_DOMAIN>/index.html
```

The proxy link is printed at the end of the installation and also saved to a file:

```bash
cat /root/telemt-proxy-link.txt
```

Server health report:

```bash
telemt-report 5m
```

Certificate auto-renewal check:

```bash
systemctl status certbot.timer
systemctl list-timers certbot.timer
certbot renew --dry-run
```

Port check:

```bash
ss -lntp | grep -E ':(443|8443|1443|9091)'
```

Expected port layout:

```text
0.0.0.0:443        nginx
127.0.0.1:8443     nginx mask site
127.0.0.1:1443     telemt
127.0.0.1:9091     telemt API
```

### Important Notes

After installation, open a second SSH session and verify login:

```bash
ssh -p <SSH_PORT> root@<PROXY_DOMAIN>
```

Do not close the original SSH session until the new login works.

If SSL issuance fails, the usual causes are:

```text
DNS does not point to the server yet
port 80 is closed
port 443 is occupied by another service
provider firewall blocks incoming connections
```

### Auxiliary Tool add_key.sh

`add_key.sh` helps prepare SSH access before running `install_telemt_astra.sh`.

How it works:

1. It asks for the server address, SSH port, username, local key path, and comment for a new key.
2. It creates a local `ed25519` key if the selected key does not exist. If the private key exists but `.pub` is missing, it rebuilds the public key.
3. It checks `known_hosts`: it shows the SHA256 host key fingerprint before adding it, or stops if it does not match `EXPECTED_HOST_KEY_SHA256`.
4. On Unix/Linux servers, it adds the public key to `authorized_keys`; if the primary method fails, it tries `ssh-copy-id`.
5. For MikroTik RouterOS, it uses a separate key import flow.
6. At the end, it verifies that passwordless key login really works.

Run:

```bash
chmod +x ../common/add_key.sh
../common/add_key.sh
```

Run with environment parameters:

```bash
chmod +x ../common/add_key.sh
SERVER_INPUT=root@<SERVER_PUBLIC_IP> SERVER_PORT=<SSH_PORT> KEY_PATH=~/.ssh/id_ed25519 ../common/add_key.sh
```

After key login is verified, copy and run the installer:

```bash
scp install_telemt_astra.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh
```

### Batch Installation install_telemt_batch_astra.sh

`install_telemt_batch_astra.sh` runs on the local admin machine and installs Telemt on multiple Astra Linux servers.

Important: the batch script does not contain a separate copy of the Telemt installation logic. It uses the main `install_telemt_astra.sh`: copies it to every server and runs it remotely.

The batch script can be launched from a local machine running:

```text
macOS
any Linux admin machine
```

Before starting, the batch script checks local dependencies:

```text
bash 3+
ssh
scp
one DNS resolver: getent, dig, or host
install_telemt_astra.sh next to install_telemt_batch_astra.sh
../common/add_key.sh relative to the astra directory
```

If something is missing, the script stops before connecting to any server.

What the batch script does:

```text
asks for common SSH/install settings
asks for domains one by one
the user enters domain, Enter, next domain, Enter
an empty line finishes domain input
checks the A record for every domain
if no A record exists, offers entering another domain with an A record
checks SSH key login for every server
if the key does not work, offers add_key.sh, password mode, or skip
copies install_telemt_astra.sh to the server
runs install_telemt_astra.sh remotely with the selected domain and settings
prints per-domain results
reads /root/telemt-proxy-link.txt after successful installs
prints the final Proxy links list
```

The `Proxy links` block contains live Telegram proxy links with secrets. Treat them like passwords.

Run:

```bash
chmod +x install_telemt_batch_astra.sh ../common/add_key.sh
./install_telemt_batch_astra.sh
```

Domain input example:

```text
Domain: proxy-one.example.com
Domain: proxy-two.example.com
Domain:
```

Empty `Domain:` finishes the list.

Optional environment variables:

```bash
chmod +x install_telemt_batch_astra.sh ../common/add_key.sh
CONNECT_SSH_PORT=22 TARGET_SSH_PORT=22 TELEMT_MAX_TCP_CONNS=1000 ./install_telemt_batch_astra.sh
```

`install_telemt_astra.sh` and `add_key.sh` remain standalone scripts and can still be run without batch mode.
