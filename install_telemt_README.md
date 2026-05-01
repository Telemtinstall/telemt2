# install_telemt.sh

## Русское описание

`install_telemt.sh` автоматически поднимает Telemt MTProto proxy на новом сервере без WireGuard.

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

1. Новый VPS/server с Debian или Ubuntu.
2. Root-доступ по SSH.
3. Домен, уже направленный A-записью на публичный IPv4 сервера:

```text
<PROXY_DOMAIN> -> <SERVER_PUBLIC_IP>
```

4. Порты `80/tcp` и `443/tcp` должны быть доступны с интернета.
5. В `/root/.ssh/authorized_keys` должен быть SSH-ключ, потому что скрипт отключает SSH-пароли.

### Как запускать

Скрипт нужно запускать на целевом сервере, а не на локальном компьютере.

```bash
scp install_telemt.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
bash /root/install_telemt.sh
```

Рекомендуемый способ для долгой установки, чтобы пережить обрыв SSH:

```bash
tmux new -s telemt-install
bash /root/install_telemt.sh
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
bash /root/install_telemt.sh
```

Скрипт повторно спросит параметры, подставит сохранённые значения по умолчанию и пропустит шаги, которые уже были успешно завершены.

Чтобы начать установку заново без учёта state-файла:

```bash
RESET_INSTALL_STATE=1 bash /root/install_telemt.sh
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
5. Маскировочный HTTPS-сайт на `127.0.0.1:8443`.
6. Telemt backend на `127.0.0.1:1443`.
7. Telemt API на `127.0.0.1:9091`.
8. Firewall-правило, закрывающее `9091/tcp` снаружи.
9. Fail2ban для SSH.
10. SSH hardening:

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

### Вспомогательный Инструмент add_key

`add_key` помогает подготовить SSH-доступ к серверу до запуска `install_telemt.sh`.

Что делает:

```text
создаёт локальный ed25519 SSH-ключ, если выбранный ключ отсутствует
восстанавливает .pub файл из приватного ключа, если .pub отсутствует
спрашивает адрес сервера, SSH-порт, пользователя и comment/email для ключа
добавляет public key в authorized_keys на Unix/Linux сервере
пробует ssh-copy-id как fallback
поддерживает импорт ключей на MikroTik RouterOS
проверяет, что вход по ключу реально работает
```

Запуск:

```bash
./add_key
```

Запуск с параметрами через environment:

```bash
SERVER_INPUT=root@<SERVER_PUBLIC_IP> SERVER_PORT=<SSH_PORT> KEY_PATH=~/.ssh/id_ed25519 ./add_key
```

После успешной проверки ключа можно копировать и запускать установщик:

```bash
scp install_telemt.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
bash /root/install_telemt.sh
```

---

## English Description

`install_telemt.sh` automatically installs a Telemt MTProto proxy on a new server without WireGuard.

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

1. A fresh Debian or Ubuntu VPS/server.
2. Root SSH access.
3. A domain with an A record already pointing to the server public IPv4:

```text
<PROXY_DOMAIN> -> <SERVER_PUBLIC_IP>
```

4. Ports `80/tcp` and `443/tcp` must be reachable from the internet.
5. `/root/.ssh/authorized_keys` must contain your SSH public key because the script disables SSH password login.

### How To Run

Run the script on the target server, not on your local computer.

```bash
scp install_telemt.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
bash /root/install_telemt.sh
```

Recommended method for long installations, so the process survives SSH disconnects:

```bash
tmux new -s telemt-install
bash /root/install_telemt.sh
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
bash /root/install_telemt.sh
```

The script will ask for parameters again, use saved values as defaults, and skip steps that were already completed successfully.

To restart the installer without using the progress state:

```bash
RESET_INSTALL_STATE=1 bash /root/install_telemt.sh
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
5. HTTPS mask site on `127.0.0.1:8443`.
6. Telemt backend on `127.0.0.1:1443`.
7. Telemt API on `127.0.0.1:9091`.
8. Firewall rule blocking external access to `9091/tcp`.
9. Fail2ban for SSH.
10. SSH hardening:

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

### Auxiliary Tool add_key

`add_key` helps prepare SSH access before running `install_telemt.sh`.

What it does:

```text
creates a local ed25519 SSH key if the selected key does not exist
rebuilds the .pub file from the private key if .pub is missing
asks for server address, SSH port, username, and key comment/email
adds the public key to authorized_keys on Unix/Linux servers
tries ssh-copy-id as a fallback
supports MikroTik RouterOS key import
verifies that key login actually works
```

Run:

```bash
./add_key
```

Run with environment parameters:

```bash
SERVER_INPUT=root@<SERVER_PUBLIC_IP> SERVER_PORT=<SSH_PORT> KEY_PATH=~/.ssh/id_ed25519 ./add_key
```

After key login is verified, copy and run the installer:

```bash
scp install_telemt.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
bash /root/install_telemt.sh
```
