# install_telemt_astra.sh

> RU: Это не официальный установщик Telemt или Astra Linux-пакетов. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is not an official Telemt or Astra Linux package installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

## Русское описание

`install_telemt_astra.sh` автоматически поднимает Telemt MTProto proxy на новом сервере Astra Linux.

Целевая схема после установки:

```text
Internet
  -> <PROXY_DOMAIN>:80
  -> nginx HTTP redirect
     -> 301 https://<PROXY_DOMAIN>/
  -> <PROXY_DOMAIN>:443
  -> nginx stream SNI router
     -> SNI = <PROXY_DOMAIN>
        -> 127.0.0.1:1443
        -> Telemt
     -> default / browser / scanner
        -> 127.0.0.1:8443
        -> HTTPS mask site
```

Снаружи открыты `80/tcp` и `443/tcp`: `80/tcp` только перенаправляет HTTP на HTTPS, `443/tcp` принимает Telemt/HTTPS через nginx SNI router. Telemt не слушает внешний интерфейс напрямую, он доступен только локально на `127.0.0.1:1443`. API Telemt доступен только локально на `127.0.0.1:9091`.

### Что нужно до запуска

1. Новый VPS/server с Astra Linux.
2. Root-доступ по SSH.
3. Домен, уже направленный A-записью на публичный IPv4 сервера:

```text
<PROXY_DOMAIN> -> <SERVER_PUBLIC_IP>
```

4. Порты `80/tcp` и `443/tcp` должны быть доступны с интернета.
5. SSH-ключ в `/root/.ssh/authorized_keys` нужен только если вы сами включите режим “root только по ключу”.

### Важно: только чистый сервер

Используйте новый VPS/server без существующих сайтов, панелей управления и сетевых сервисов. Установщик настраивает nginx, firewall, SSH-port, Docker/Telemt и сертификаты; ему нужны свободные `80/tcp` и `443/tcp`, а также локальные `8443`, `1443`, `9091`. Fail2ban включается только если выбрать `yes`. Если уже работают nginx/apache/caddy/traefik, почта, VPN, панели хостинга или другие прокси, возможны конфликты портов и конфигов. Для такого сервера лучше взять отдельную машину или интегрировать Telemt вручную.

### Как скачать файл на сервер

Если файл уже есть на вашем компьютере, скопируйте его через `scp`:

```bash
scp install_telemt_astra.sh root@<SERVER_PUBLIC_IP>:/root/
```

Если файл нужно скачать прямо с GitHub на сервере:

```bash
wget -O /root/install_telemt_astra.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/astra/install_telemt_astra.sh
chmod +x /root/install_telemt_astra.sh
```

То же самое через `curl`:

```bash
curl -fsSL -o /root/install_telemt_astra.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/astra/install_telemt_astra.sh
chmod +x /root/install_telemt_astra.sh
```

Если нужен именно `git`, скачайте только каталог Astra:

```bash
apt-get update
apt-get install -y git
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt
cd /tmp/telemt
git sparse-checkout set telemt/astra
cp telemt/astra/install_telemt_astra.sh /root/
chmod +x /root/install_telemt_astra.sh
```

### Как запускать

Скрипт нужно запускать на целевом сервере, а не на локальном компьютере.

```bash
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


### Как обновлять уже установленный Telemt

Скачайте свежий установщик и запустите update-режим. Он сохранит существующие настройки, пользователей, секреты, nginx/SSH-конфиги и сертификаты.

```bash
wget -O /root/install_telemt_astra.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/astra/install_telemt_astra.sh
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh --update -lang ru
```

Если текущий Docker compose закреплён на `image@sha256:...`, update пересоздаст контейнер на том же digest. Чтобы явно перейти на другой image/tag, передайте:

```bash
TELEMT_IMAGE=<IMAGE_OR_TAG> /root/install_telemt_astra.sh --update -lang ru
```

IDN-домены поддерживаются: если ввести кириллицу, скрипт переведёт домен в punycode; если ввести `xn--...`, скрипт проверит, что это корректный punycode.

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

4. Отключать ли SSH-пароли и оставить root только по ключу. По умолчанию:

```text
no
```

Если выбрать `yes`, скрипт проверит `/root/.ssh/authorized_keys` и попросит второе подтверждение.

5. Включать ли fail2ban для SSH. По умолчанию:

```text
no
```

6. Добавлять ли swap `1G`, если swap нет. По умолчанию:

```text
no
```

7. Лимит подключений Telemt. По умолчанию:

```text
5000
```

Можно нажать Enter и оставить `5000`, либо указать другое число.

После показа плана установки скрипт спросит подтверждение. Можно ввести `y`, `yes` или `YES`.

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

В примере пустой ответ означает “оставить значение по умолчанию”. По умолчанию SSH-пароли не отключаются, fail2ban не включается и swap не добавляется. После `y` начинается установка: `apt` обновляет пакеты, ставятся Docker/Compose, nginx, nginx stream module, certbot, nftables, jq, curl и openssl, затем выпускается сертификат, создаются nginx/Telemt-конфиги, запускается контейнер и применяется firewall/SSH-port настройка.

### Проверки перед установкой

Скрипт определяет публичный IPv4 сервера и проверяет DNS:

```text
<PROXY_DOMAIN> must resolve to <SERVER_PUBLIC_IP>
```

Если домен ещё не указывает на IP сервера, установка остановится до получения SSL-сертификата.

Если на вопрос `Disable SSH password login and keep root key-only?` ответить `yes`, скрипт сначала проверит наличие root SSH-ключа:

```text
/root/.ssh/authorized_keys
```

Если ключей нет, установка остановится. Если ключ найден, скрипт ещё раз спросит подтверждение `Are you sure you want to close SSH password login?`. Только после второго `yes` он отключит парольный SSH-вход.

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
fail2ban (только если выбран yes)
nftables
jq
curl
openssl
```

Swap `1G` добавляется только если на вопрос `Add 1G swap if missing?` выбран `yes`.

### Что настраивается

1. Let's Encrypt сертификат для `<PROXY_DOMAIN>`.
2. Автопродление сертификата через `certbot.timer`.
3. Pre/post/deploy hooks для certbot: nginx останавливается перед standalone-renew, запускается обратно и reload выполняется после успешного продления.
4. HTTP -> HTTPS редирект на внешнем `80/tcp`.
5. Nginx stream router на внешнем `443/tcp`.
6. Маскировочный HTTPS-сайт на `127.0.0.1:8443`; HTML-страница создаётся в `/var/www/<PROXY_DOMAIN>/index.html`, а её `<title>` и `<h1>` равны введённому домену.
7. Telemt backend на `127.0.0.1:1443`.
8. Telemt API на `127.0.0.1:9091`.
9. Firewall-правило, закрывающее `9091/tcp` снаружи.
10. Fail2ban для SSH, только если на вопрос `Enable fail2ban for SSH?` выбран `yes`.
11. Отключение nginx access logs для маскировочного сайта.
12. Отключение Docker runtime logs для Telemt-контейнера.
13. Безопасное поведение nginx: скрипт добавляет отдельный site/stream config и не удаляет существующие сайты. Если `443/tcp` уже занят чужим HTTPS-сервисом, установка останавливается до изменения frontend-а.
14. SSH port настройка. Отключение SSH-паролей выполняется только если на вопрос `Disable SSH password login and keep root key-only?` выбран `yes` и подтверждение повторено вторым `yes`:

```text
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```

### Telemt настройки

Telemt запускается в Docker:

```text
image: ghcr.io/telemt/telemt:latest
container_name: telemt
network_mode: host
user: 65532:65532
read_only: true
cap_drop: ALL
no-new-privileges: true
config mount: /opt/telemt-config -> /etc/telemt
runtime tmpfs: /tmp, /run/telemt
```

CPU/RAM/PID лимиты в `docker-compose.yml` не задаются, чтобы Telemt не упирался в искусственные ограничения при большом числе клиентов и загрузке медиа.

Основные параметры Telemt:

```text
classic = false
secure = false
tls = true
use_middle_proxy = false
upstream = direct
max_tcp_conns = <LIMIT>
config_strict = true
server.api.read_only = true
```

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
ss -lntp | grep -E ':(80|443|8443|1443|9091)'
```

Ожидаемая схема портов:

```text
0.0.0.0:80         nginx HTTP -> HTTPS redirect
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

1. Спрашивает адрес сервера, SSH-порт, пользователя и комментарий для нового ключа. Локальный ключ берётся из `KEY_PATH`, а если переменная не задана, используется `~/.ssh/id_ed25519`.
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

Он спросит:

```text
Введите IP/hostname сервера (можно user@host): root@<SERVER_PUBLIC_IP>
Введите SSH-порт [22]: <SSH_PORT>
Введите email/comment для ключа [<LOCAL_USER>@<LOCAL_HOST>]: admin@<PROXY_DOMAIN>
Введите имя пользователя на сервере [root]: root
Доверять этому host key и добавить его в known_hosts? [y/N]: y
root@<SERVER_PUBLIC_IP>'s password: <SSH_PASSWORD>
```

Пароль нужен только чтобы один раз зайти на сервер и записать публичный ключ. После этого скрипт копирует ключ в `authorized_keys` и проверяет вход без пароля.

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

Пакетный скрипт можно запускать на локальной админской машине с macOS или любым Linux.

Перед началом он проверяет локальные зависимости: `bash 3+`, `ssh`, `scp`, один DNS resolver (`getent`, `dig` или `host`), файл `install_telemt_astra.sh` рядом с `install_telemt_batch_astra.sh` и helper `../common/add_key.sh` относительно каталога `astra`.

Если чего-то не хватает, скрипт остановится до любых подключений к серверам.

Как работает пакетная установка:

1. Сначала скрипт спрашивает общие SSH/install-настройки.
2. Затем он принимает домены по одному: пользователь вводит домен, нажимает Enter и вводит следующий. Пустая строка завершает список.
3. Для каждого домена скрипт проверяет `A`-запись. Если записи нет, он предлагает указать другой домен, который уже смотрит на сервер.
4. После DNS-проверки скрипт проверяет SSH-вход по ключу на каждый сервер. Если ключевой вход не работает, можно запустить `add_key.sh`, использовать password mode (вход по паролю) или пропустить сервер.
5. Когда доступ готов, скрипт копирует `install_telemt_astra.sh` на сервер и запускает его удалённо с выбранным доменом и настройками.
6. По каждому домену печатается отдельный результат. После успешной установки скрипт читает `/root/telemt-proxy-link.txt` и в конце выводит общий блок `Proxy links`.

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
CONNECT_SSH_PORT=22 TARGET_SSH_PORT=22 ENABLE_FAIL2BAN=no ADD_SWAP=no TELEMT_MAX_TCP_CONNS=5000 ./install_telemt_batch_astra.sh
```

`install_telemt_astra.sh` и `add_key.sh` остаются самостоятельными скриптами: их можно запускать отдельно без пакетного режима.

---

## English Description

`install_telemt_astra.sh` automatically installs a Telemt MTProto proxy on a new Astra Linux server.

Target architecture after installation:

```text
Internet
  -> <PROXY_DOMAIN>:80
  -> nginx HTTP redirect
     -> 301 https://<PROXY_DOMAIN>/
  -> <PROXY_DOMAIN>:443
  -> nginx stream SNI router
     -> SNI = <PROXY_DOMAIN>
        -> 127.0.0.1:1443
        -> Telemt
     -> default / browser / scanner
        -> 127.0.0.1:8443
        -> HTTPS mask site
```

External ports `80/tcp` and `443/tcp` are exposed: `80/tcp` only redirects HTTP to HTTPS, while `443/tcp` accepts Telemt/HTTPS through the nginx SNI router. Telemt does not listen on the public network interface directly. It listens only on `127.0.0.1:1443`. The Telemt API is local-only on `127.0.0.1:9091`.

### Requirements Before Running

1. A fresh Astra Linux VPS/server.
2. Root SSH access.
3. A domain with an A record already pointing to the server public IPv4:

```text
<PROXY_DOMAIN> -> <SERVER_PUBLIC_IP>
```

4. Ports `80/tcp` and `443/tcp` must be reachable from the internet.
5. `/root/.ssh/authorized_keys` is required only if you explicitly enable root key-only login.

### Important: Clean Server Only

Use a new VPS/server without existing websites, control panels, or network services. The installer configures nginx, firewall, SSH-port, Docker/Telemt, and certificates; it needs free `80/tcp` and `443/tcp`, plus local `8443`, `1443`, and `9091`. Fail2ban is enabled only if you choose `yes`. If nginx/apache/caddy/traefik, mail, VPN, hosting panels, or other proxies already run on the server, port and config conflicts are possible. Use a separate machine or integrate Telemt manually.

### How To Download The File To The Server

If the file is already on your computer, copy it with `scp`:

```bash
scp install_telemt_astra.sh root@<SERVER_PUBLIC_IP>:/root/
```

If you want to download it directly from GitHub on the server:

```bash
wget -O /root/install_telemt_astra.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/astra/install_telemt_astra.sh
chmod +x /root/install_telemt_astra.sh
```

The same with `curl`:

```bash
curl -fsSL -o /root/install_telemt_astra.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/astra/install_telemt_astra.sh
chmod +x /root/install_telemt_astra.sh
```

If you specifically want to use `git`, download only the Astra directory:

```bash
apt-get update
apt-get install -y git
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt
cd /tmp/telemt
git sparse-checkout set telemt/astra
cp telemt/astra/install_telemt_astra.sh /root/
chmod +x /root/install_telemt_astra.sh
```

### How To Run

Run the script on the target server, not on your local computer.

```bash
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

4. Whether to disable SSH password login and keep root key-only. Default:

```text
no
```

If you choose `yes`, the script checks `/root/.ssh/authorized_keys` and asks for a second confirmation.

5. Whether to enable fail2ban for SSH. Default:

```text
no
```

6. Whether to add `1G` swap if swap is missing. Default:

```text
no
```

7. Telemt connection limit. Default:

```text
5000
```

Press Enter to keep `5000`, or type another number.

After showing the installation plan, the script asks for confirmation. You can type `y`, `yes`, or `YES`.

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

In this example, an empty answer means “keep the default”. By default, SSH password login is not disabled, fail2ban is not enabled, and swap is not added. After `y`, installation starts: `apt` updates packages, installs Docker/Compose, nginx, nginx stream module, certbot, nftables, jq, curl, and openssl, then issues the certificate, writes nginx/Telemt configs, starts the container, and applies firewall/SSH-port settings.

### Preflight Checks

The script detects the server public IPv4 and checks DNS:

```text
<PROXY_DOMAIN> must resolve to <SERVER_PUBLIC_IP>
```

If the domain does not point to the server IP yet, the installation stops before requesting the SSL certificate.

If you answer `yes` to `Disable SSH password login and keep root key-only?`, the script first checks for a root SSH key:

```text
/root/.ssh/authorized_keys
```

If no SSH key is found, installation stops. If a key is found, the script asks again: `Are you sure you want to close SSH password login?`. Password SSH login is disabled only after that second `yes`.

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
fail2ban (only if selected)
nftables
jq
curl
openssl
```

It adds `1G` swap only when `Add 1G swap if missing?` is answered with `yes`.

### Configured Components

1. Let's Encrypt certificate for `<PROXY_DOMAIN>`.
2. Automatic certificate renewal via `certbot.timer`.
3. Certbot pre/post/deploy hooks: nginx is stopped before standalone renewal, started again after it, and reloaded after successful renewal.
4. HTTP -> HTTPS redirect on public `80/tcp`.
5. Nginx stream router on public `443/tcp`.
6. HTTPS mask site on `127.0.0.1:8443`; the HTML page is created at `/var/www/<PROXY_DOMAIN>/index.html`, and its `<title>` and `<h1>` are set to the entered domain.
7. Telemt backend on `127.0.0.1:1443`.
8. Telemt API on `127.0.0.1:9091`.
9. Firewall rule blocking external access to `9091/tcp`.
10. Fail2ban for SSH, only when `Enable fail2ban for SSH?` is answered with `yes`.
11. Disabled nginx access logs for the mask site.
12. Disabled Docker runtime logs for the Telemt container.
13. Safe nginx behavior: the installer adds separate site/stream configs and does not remove existing sites. If `443/tcp` is already owned by another HTTPS service, installation stops before changing the frontend.
14. SSH port configuration. Disabling SSH passwords is optional and happens only when `Disable SSH password login and keep root key-only?` is answered with `yes` and confirmed by a second `yes`:

```text
PasswordAuthentication no
PermitRootLogin prohibit-password
KbdInteractiveAuthentication no
PubkeyAuthentication yes
```

### Telemt Settings

Telemt runs in Docker:

```text
image: ghcr.io/telemt/telemt:latest
container_name: telemt
network_mode: host
user: 65532:65532
read_only: true
cap_drop: ALL
no-new-privileges: true
config mount: /opt/telemt-config -> /etc/telemt
runtime tmpfs: /tmp, /run/telemt
```

CPU/RAM/PID limits are not set in `docker-compose.yml`, so Telemt does not hit artificial limits when many clients load media.

Main Telemt parameters:

```text
classic = false
secure = false
tls = true
use_middle_proxy = false
upstream = direct
max_tcp_conns = <LIMIT>
config_strict = true
server.api.read_only = true
```

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
ss -lntp | grep -E ':(80|443|8443|1443|9091)'
```

Expected port layout:

```text
0.0.0.0:80         nginx HTTP -> HTTPS redirect
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

1. It asks for the server address, SSH port, username, and comment for a new key. The local key is taken from `KEY_PATH`; if the variable is not set, `~/.ssh/id_ed25519` is used.
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

It asks:

```text
Введите IP/hostname сервера (можно user@host): root@<SERVER_PUBLIC_IP>
Введите SSH-порт [22]: <SSH_PORT>
Введите email/comment для ключа [<LOCAL_USER>@<LOCAL_HOST>]: admin@<PROXY_DOMAIN>
Введите имя пользователя на сервере [root]: root
Доверять этому host key и добавить его в known_hosts? [y/N]: y
root@<SERVER_PUBLIC_IP>'s password: <SSH_PASSWORD>
```

The password is needed only for the one-time login that writes the public key to the server. After that, the script copies the key into `authorized_keys` and verifies passwordless login.

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


### Updating an Existing Telemt Install

Download the fresh installer and run update mode. It preserves existing settings, users, secrets, nginx/SSH configs, and certificates.

```bash
wget -O /root/install_telemt_astra.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/astra/install_telemt_astra.sh
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh --update -lang en
```

If the current Docker compose file is pinned to `image@sha256:...`, update recreates the container with the same digest. To explicitly move to another image/tag, pass:

```bash
TELEMT_IMAGE=<IMAGE_OR_TAG> /root/install_telemt_astra.sh --update -lang en
```

IDN domains are supported: Cyrillic input is converted to punycode; existing `xn--...` input is validated as real punycode.

### Batch Installation install_telemt_batch_astra.sh

`install_telemt_batch_astra.sh` runs on the local admin machine and installs Telemt on multiple Astra Linux servers.

Important: the batch script does not contain a separate copy of the Telemt installation logic. It uses the main `install_telemt_astra.sh`: copies it to every server and runs it remotely.

The batch script can be launched from a local admin machine running macOS or any Linux distribution.

Before starting, it checks local dependencies: `bash 3+`, `ssh`, `scp`, one DNS resolver (`getent`, `dig`, or `host`), `install_telemt_astra.sh` next to `install_telemt_batch_astra.sh`, and `../common/add_key.sh` relative to the `astra` directory.

If something is missing, the script stops before connecting to any server.

How the batch install works:

1. First, the script asks for common SSH/install settings.
2. Then it accepts domains one by one: enter a domain, press Enter, and enter the next one. An empty line finishes the list.
3. For every domain, the script checks the `A` record. If no record exists, it offers entering another domain that already points to the server.
4. After DNS checks, it verifies SSH key login for every server. If key login does not work, you can run `add_key.sh`, use password mode, or skip the server.
5. When access is ready, the script copies `install_telemt_astra.sh` to the server and runs it remotely with the selected domain and settings.
6. The script prints a result for every domain. After each successful install, it reads `/root/telemt-proxy-link.txt` and prints the final `Proxy links` block at the end.

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
CONNECT_SSH_PORT=22 TARGET_SSH_PORT=22 ENABLE_FAIL2BAN=no ADD_SWAP=no TELEMT_MAX_TCP_CONNS=5000 ./install_telemt_batch_astra.sh
```

`install_telemt_astra.sh` and `add_key.sh` remain standalone scripts and can still be run without batch mode.
