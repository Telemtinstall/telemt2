# WhatsApp Chat Proxy Installer

RU: Экспериментальный Bash-установщик для официального `WhatsApp/proxy`. Это не официальный установщик Meta/WhatsApp. Скрипт скачивает проверенный датированный Docker image `facebook/whatsapp_proxy:20260607` из официального Docker Hub образа проекта и настраивает минимальную безопасную схему.

EN: Experimental Bash installer for the official `WhatsApp/proxy`. This is not an official Meta/WhatsApp installer. The script pulls the checked dated `facebook/whatsapp_proxy:20260607` Docker image from the official Docker Hub image and configures a minimal safer layout.

Source:

- Official repository: `https://github.com/WhatsApp/proxy`
- Official image repository: `facebook/whatsapp_proxy`
- Default image tag: `20260607`

## Server Requirements / Требования К Серверу

RU:

- Рекомендуемый вариант: чистый Debian/Ubuntu VPS без чужих сайтов, панелей и занятых портов.
- Допустимый вариант: сервер, где уже установлен Telemt и внешний `443/tcp` уже обслуживает nginx `stream` с SNI-routing.
- Не запускайте на сервере, где `443/tcp` занят Apache/Caddy/панелью/другим Docker-контейнером без nginx stream: скрипт остановится, чтобы не сломать существующие сайты.
- Для режима `sni` нужен отдельный домен для WhatsApp proxy, например `<WHATSAPP_PROXY_DOMAIN>`. Нельзя использовать тот же домен, который уже ведёт на Telemt.
- Для домена WhatsApp proxy должна быть A-запись на IPv4 этого сервера. Скрипт проверяет DNS до изменения nginx.
- `587/tcp` желательно оставить свободным и открытым снаружи: он используется как дополнительный публичный порт для `whatsapp.net/media`.

EN:

- Recommended: a clean Debian/Ubuntu VPS without existing websites, control panels, or occupied ports.
- Supported: a server where Telemt is already installed and public `443/tcp` is already handled by nginx `stream` with SNI routing.
- Do not run it on a server where `443/tcp` is owned by Apache/Caddy/a hosting panel/another Docker container without nginx stream. The installer will stop to avoid breaking existing sites.
- `sni` mode needs a separate WhatsApp proxy domain, for example `<WHATSAPP_PROXY_DOMAIN>`. Do not reuse the domain that already routes to Telemt.
- The WhatsApp proxy domain must have an A record pointing to this server IPv4. The installer checks DNS before changing nginx.
- `587/tcp` should preferably be free and reachable from the internet: it is used as an additional public port for `whatsapp.net/media`.

## How One 443 Port Is Shared / Как Делится Один 443 Порт

RU: Если на сервере уже есть Telemt через nginx stream, WhatsApp proxy добавляется как отдельный SNI backend. nginx не расшифровывает TLS, а только читает имя домена из TLS ClientHello и направляет TCP-поток в нужный локальный сервис.

EN: If Telemt already runs behind nginx stream, WhatsApp proxy is added as a separate SNI backend. nginx does not decrypt TLS; it only reads the domain name from the TLS ClientHello and routes the TCP stream to the correct local service.

```text
Internet
  |
  | TCP 443
  v
nginx stream listens on 0.0.0.0:443
  |
  | reads SNI from TLS ClientHello
  |
  +-- SNI = <TELEMT_DOMAIN>           -> 127.0.0.1:1443  -> Telemt
  |
  +-- SNI = <WHATSAPP_PROXY_DOMAIN>   -> 127.0.0.1:18443 -> WhatsApp proxy
  |
  +-- any other SNI/default           -> 127.0.0.1:8443  -> camouflage site
```

RU: Один и тот же SNI-домен нельзя направить одновременно в Telemt и WhatsApp proxy. Поэтому для WhatsApp proxy нужен отдельный домен или поддомен.

EN: The same SNI domain cannot route to Telemt and WhatsApp proxy at the same time. Use a separate domain or subdomain for WhatsApp proxy.

## What It Does / Что Делает

RU:

- спрашивает домен прокси и проверяет, что A-запись домена указывает на IPv4 текущего сервера;
- не принимает IP-адрес вместо домена;
- ставит Docker, если его нет;
- запускает WhatsApp proxy в Docker Compose;
- публикует наружу только `443/tcp` и, по выбору, `587/tcp`;
- если активен `ufw` или `firewalld`, открывает только нужные TCP-порты;
- держит HAProxy stats `8199` только локально на `127.0.0.1:<local_stats_port>`;
- если `443/tcp` занят Telemt/nginx, предлагает SNI-режим и добавляет только один route в существующий Telemt nginx stream-map;
- если указанный домен уже используется Telemt в nginx stream-map, останавливается и просит отдельный домен;
- делает бэкап nginx/compose перед изменениями;
- не меняет Telemt-секреты, `telemt.toml`, пользователей Telemt и существующие Docker-контейнеры Telemt.

EN:

- asks for a proxy domain and checks that its A record points to the current server IPv4;
- refuses an IP address instead of a domain;
- installs Docker if missing;
- runs WhatsApp proxy with Docker Compose;
- exposes only `443/tcp` and optionally `587/tcp` publicly;
- if `ufw` or `firewalld` is active, opens only the required TCP ports;
- keeps HAProxy stats `8199` local only on `127.0.0.1:<local_stats_port>`;
- if `443/tcp` is already owned by Telemt/nginx, offers SNI mode and adds only one route to the existing Telemt nginx stream map;
- if the requested domain is already used by Telemt in the nginx stream map, stops and asks for a separate domain;
- backs up nginx/compose files before changes;
- does not change Telemt secrets, `telemt.toml`, Telemt users, or existing Telemt Docker containers.

## Modes / Режимы

`direct`

RU: Используется, когда `443/tcp` свободен. Docker-контейнер слушает публичный `443/tcp` напрямую. Это самый простой вариант.

EN: Used when `443/tcp` is free. The Docker container binds public `443/tcp` directly. This is the simplest mode.

`sni`

RU: Используется, когда `443/tcp` уже занят nginx stream от Telemt. Контейнер слушает `127.0.0.1:18443`, а nginx stream направляет только указанный SNI-домен на WhatsApp proxy. Существующий Telemt route остаётся на месте.

EN: Used when `443/tcp` is already owned by the Telemt nginx stream frontend. The container listens on `127.0.0.1:18443`, and nginx stream routes only the requested SNI domain to WhatsApp proxy. Existing Telemt routes remain in place.

RU: Для SNI-режима нужен отдельный домен. Нельзя использовать тот же домен, который уже ведёт на Telemt, потому что один SNI hostname на одном `443/tcp` может быть направлен только в один backend.

EN: SNI mode needs a separate domain. You cannot use the same domain that already routes to Telemt, because one SNI hostname on one `443/tcp` can route to only one backend.

`auto`

RU: По умолчанию. Если `443/tcp` свободен, выбирает `direct`. Если `443/tcp` занят и найден Telemt nginx stream-map, предлагает `sni`. Если безопасно встроиться нельзя, останавливается и сохраняет ручной snippet в `/root/whatsapp-proxy-nginx-stream-snippet.conf`.

EN: Default. If `443/tcp` is free, selects `direct`. If `443/tcp` is busy and a Telemt nginx stream map is found, offers `sni`. If it cannot integrate safely, it stops and writes a manual snippet to `/root/whatsapp-proxy-nginx-stream-snippet.conf`.

## Install / Установка

```bash
wget -O /root/install_whatsapp_proxy.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/proxy/whatsapp/install_whatsapp_proxy.sh
chmod +x /root/install_whatsapp_proxy.sh
/root/install_whatsapp_proxy.sh -lang ru
```

Or with `curl`:

```bash
curl -fsSL -o /root/install_whatsapp_proxy.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/proxy/whatsapp/install_whatsapp_proxy.sh
chmod +x /root/install_whatsapp_proxy.sh
/root/install_whatsapp_proxy.sh -lang ru
```

Download this directory with `git`:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt2
cd /tmp/telemt2
git sparse-checkout set proxy/whatsapp
cd proxy/whatsapp
chmod +x ./install_whatsapp_proxy.sh
./install_whatsapp_proxy.sh -lang ru
```

## Update / Обновление

RU: Режим обновления не меняет nginx/SNI-route, домен, локальные порты и остальную структуру compose. Он берёт текущие настройки из `/opt/whatsapp-proxy/docker-compose.yml` и `/opt/whatsapp-proxy/whatsapp-proxy.env`, проверяет официальный Docker Hub, выбирает самый свежий датированный tag `facebook/whatsapp_proxy:YYYYMMDD`, обновляет только строку `image:` в compose, тянет image и пересоздаёт контейнер. Если в compose указан кастомный image не из `facebook/whatsapp_proxy`, скрипт не заменяет его и просто обновляет текущий image.

EN: Update mode does not change nginx/SNI routing, domain, local ports, or the rest of the compose layout. It reads current settings from `/opt/whatsapp-proxy/docker-compose.yml` and `/opt/whatsapp-proxy/whatsapp-proxy.env`, checks the official Docker Hub tags, selects the newest dated `facebook/whatsapp_proxy:YYYYMMDD` tag, updates only the `image:` line in compose, pulls the image, and recreates the container. If compose uses a custom image outside `facebook/whatsapp_proxy`, the script keeps it and only updates the configured image.

```bash
curl -fsSL -o /root/install_whatsapp_proxy.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/proxy/whatsapp/install_whatsapp_proxy.sh
chmod +x /root/install_whatsapp_proxy.sh
/root/install_whatsapp_proxy.sh -update -lang ru
```

## Options / Опции

```text
-lang ru          Русский режим интерфейса.
-lang en          English interface.
-update           Update existing Docker container only.
-y                Assume yes where possible.
-h, --help        Show help.
```

## Questions / Вопросы Установщика

`WhatsApp proxy domain`

RU: Домен, который будет введён в WhatsApp как proxy host. У домена должна быть A-запись на IPv4 этого сервера. Если на сервере уже работает Telemt, укажите отдельный домен, например `<WHATSAPP_PROXY_DOMAIN>`, а не домен Telemt. Если A-записи нет или она указывает на другой IP, установка остановится до изменения nginx.

EN: Domain that will be entered in WhatsApp as the proxy host. It must have an A record pointing to this server IPv4. If Telemt already runs on the server, use a separate domain such as `<WHATSAPP_PROXY_DOMAIN>`, not the Telemt domain. If the A record is missing or points elsewhere, installation stops before nginx changes.

`Install mode: auto/direct/sni`

RU: Обычно оставьте `auto`.

- `auto`: скрипт сам выбирает режим. Если `443/tcp` свободен, будет `direct`; если `443/tcp` занят nginx stream от Telemt, предложит `sni`; если безопасно встроиться нельзя, остановится.
- `direct`: использовать только на чистом сервере со свободным `443/tcp`. Контейнер WhatsApp proxy будет слушать публичный `443/tcp` напрямую.
- `sni`: использовать, если `443/tcp` уже занят nginx stream от Telemt. Скрипт добавит один route `<WHATSAPP_PROXY_DOMAIN> -> 127.0.0.1:18443` после backup и `nginx -t`.

EN: Usually keep `auto`.

- `auto`: the installer chooses automatically. If `443/tcp` is free it uses `direct`; if `443/tcp` is owned by a Telemt nginx stream it offers `sni`; if safe integration is not possible it stops.
- `direct`: use only on a clean server with free `443/tcp`. The WhatsApp proxy container binds public `443/tcp` directly.
- `sni`: use when `443/tcp` is already owned by the Telemt nginx stream. The installer adds one route `<WHATSAPP_PROXY_DOMAIN> -> 127.0.0.1:18443` after backup and `nginx -t`.

`Docker image`

RU: По умолчанию `facebook/whatsapp_proxy:20260607`. Обычно нажмите Enter. Менять стоит только если вы сознательно используете другой официальный tag/image. `latest` лучше не указывать вручную: датированный tag делает установку повторяемой и защищает от неожиданного изменения образа в будущем.

EN: Default is `facebook/whatsapp_proxy:20260607`. Usually press Enter. Change it only if you intentionally use another official tag/image. Avoid setting `latest` manually: a dated tag makes installs repeatable and protects against unexpected image changes later.

`Expose public 587/tcp for whatsapp.net/media yes/no`

RU: Рекомендуется `yes`, если порт свободен. Скрипт опубликует `0.0.0.0:587 -> container:587`. Если порт занят, скрипт предложит отключить публикацию `587` и продолжить, но media может работать хуже или не работать.

EN: Recommended `yes` if the port is free. The installer publishes `0.0.0.0:587 -> container:587`. If the port is busy, it offers to disable public `587` and continue, but media may work worse or fail.

`Local WhatsApp TLS port for SNI mode`

RU: Локальный порт контейнера для SNI-режима, по умолчанию `18443`. Наружу он не открывается. nginx stream будет направлять `<WHATSAPP_PROXY_DOMAIN>` на `127.0.0.1:18443`. Обычно нажмите Enter.

EN: Local container port for SNI mode, default `18443`. It is not exposed publicly. nginx stream routes `<WHATSAPP_PROXY_DOMAIN>` to `127.0.0.1:18443`. Usually press Enter.

`Local HAProxy stats port`

RU: Локальная статистика HAProxy, по умолчанию `18199`. Открывается только на `127.0.0.1`, наружу не публикуется. Обычно нажмите Enter.

EN: Local HAProxy stats, default `18199`. Bound only to `127.0.0.1`, not exposed publicly. Usually press Enter.

`Enable Docker logs yes/no`

RU: По умолчанию `no`, чтобы не писать журналы соединений и не забивать диск. Если нужно временно отлаживать контейнер через `docker logs`, выберите `yes`. Для приватности и экономии диска оставьте `no`.

EN: Default is `no` to avoid connection logs and disk growth. Choose `yes` only if you need temporary debugging with `docker logs`. For privacy and disk safety, keep `no`.

After the questions / После вопросов:

RU:

- скрипт показывает план установки;
- если выбран SNI-режим, показывает nginx-файл, который будет изменён;
- просит подтвердить `y`, `yes` или `да`;
- делает backup;
- пишет Docker Compose;
- при необходимости добавляет SNI-route;
- запускает контейнер;
- в конце выводит данные подключения:

```text
Proxy host / Server: <WHATSAPP_PROXY_DOMAIN>
Main port:           443/tcp
Media port:          587/tcp
```

EN:

- the installer prints the installation plan;
- in SNI mode it prints the nginx file that will be edited;
- asks for `y`, `yes`, or `да` confirmation;
- creates a backup;
- writes Docker Compose;
- adds the SNI route if needed;
- starts the container;
- prints final connection details:

```text
Proxy host / Server: <WHATSAPP_PROXY_DOMAIN>
Main port:           443/tcp
Media port:          587/tcp
```

## Notes / Важно

RU:

- Это не полноценная Telemt-like маскировка active probing. WhatsApp proxy является TCP proxy/HAProxy, а не HTTP/SOCKS.
- Нельзя безопасно посадить второй сервис на уже занятый `443/tcp`, если 443 держит не nginx stream или если нельзя маршрутизировать по SNI.
- Если скрипт не нашёл знакомый Telemt nginx stream-map, он не будет править nginx автоматически.
- После установки в WhatsApp нужно указать только домен прокси.
- В конце установки скрипт показывает, как подключиться: host/server, основной порт `443/tcp` и media-порт `587/tcp`, если он включён.

EN:

- This is not full Telemt-like active probing camouflage. WhatsApp proxy is a TCP proxy/HAProxy, not HTTP/SOCKS.
- You cannot safely place a second service on an already occupied `443/tcp` unless 443 is owned by nginx stream or can be routed by SNI.
- If the script cannot find a known Telemt nginx stream map, it will not edit nginx automatically.
- After installation, enter only the proxy domain in WhatsApp.
- At the end, the installer prints connection details: host/server, main port `443/tcp`, and media port `587/tcp` if enabled.
