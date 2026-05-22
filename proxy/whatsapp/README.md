# WhatsApp Chat Proxy Installer

RU: Экспериментальный Bash-установщик для официального `WhatsApp/proxy`. Это не официальный установщик Meta/WhatsApp. Скрипт скачивает Docker image `facebook/whatsapp_proxy:latest` из официального Docker Hub образа проекта и настраивает минимальную безопасную схему.

EN: Experimental Bash installer for the official `WhatsApp/proxy`. This is not an official Meta/WhatsApp installer. The script pulls the `facebook/whatsapp_proxy:latest` Docker image from the official Docker Hub image and configures a minimal safer layout.

Source:

- Official repository: `https://github.com/WhatsApp/proxy`
- Official image: `facebook/whatsapp_proxy:latest`

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
/root/install_whatsapp_proxy.sh
```

Or with `curl`:

```bash
curl -fsSL -o /root/install_whatsapp_proxy.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/proxy/whatsapp/install_whatsapp_proxy.sh
chmod +x /root/install_whatsapp_proxy.sh
/root/install_whatsapp_proxy.sh
```

Download this directory with `git`:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt2
cd /tmp/telemt2
git sparse-checkout set proxy/whatsapp
cd proxy/whatsapp
chmod +x ./install_whatsapp_proxy.sh
./install_whatsapp_proxy.sh
```

## Questions / Вопросы Установщика

`WhatsApp proxy domain`

RU: Домен, который будет введён в WhatsApp как proxy host. У домена должна быть A-запись на IPv4 этого сервера.

EN: Domain that will be entered in WhatsApp as the proxy host. It must have an A record pointing to this server IPv4.

`Install mode: auto/direct/sni`

RU: Обычно оставьте `auto`. `direct` требует свободный `443/tcp`. `sni` нужен, если `443/tcp` уже занят nginx stream от Telemt.

EN: Usually keep `auto`. `direct` requires free `443/tcp`. `sni` is for an existing Telemt nginx stream on `443/tcp`.

`Docker image`

RU: По умолчанию `facebook/whatsapp_proxy:latest`.

EN: Default is `facebook/whatsapp_proxy:latest`.

`Expose public 587/tcp for whatsapp.net/media yes/no`

RU: Рекомендуется `yes`, если порт свободен. Официальная документация указывает `443` и `587` как минимальный публичный набор для сообщений и media.

EN: Recommended `yes` if the port is free. Official docs mention `443` and `587` as the minimal public set for messages and media.

`Local WhatsApp TLS port for SNI mode`

RU: Локальный порт контейнера для SNI-режима, по умолчанию `18443`. Наружу он не открывается.

EN: Local container port for SNI mode, default `18443`. It is not exposed publicly.

`Local HAProxy stats port`

RU: Локальная статистика HAProxy, по умолчанию `18199`. Открывается только на `127.0.0.1`.

EN: Local HAProxy stats, default `18199`. Bound only to `127.0.0.1`.

`Enable Docker logs yes/no`

RU: По умолчанию `no`, чтобы не писать журналы соединений и не забивать диск. Если нужно отлаживать, выберите `yes`.

EN: Default is `no` to avoid connection logs and disk growth. Choose `yes` for debugging.

## Notes / Важно

RU:

- Это не полноценная Telemt-like маскировка active probing. WhatsApp proxy является TCP proxy/HAProxy, а не HTTP/SOCKS.
- Нельзя безопасно посадить второй сервис на уже занятый `443/tcp`, если 443 держит не nginx stream или если нельзя маршрутизировать по SNI.
- Если скрипт не нашёл знакомый Telemt nginx stream-map, он не будет править nginx автоматически.
- После установки в WhatsApp нужно указать только домен прокси.

EN:

- This is not full Telemt-like active probing camouflage. WhatsApp proxy is a TCP proxy/HAProxy, not HTTP/SOCKS.
- You cannot safely place a second service on an already occupied `443/tcp` unless 443 is owned by nginx stream or can be routed by SNI.
- If the script cannot find a known Telemt nginx stream map, it will not edit nginx automatically.
- After installation, enter only the proxy domain in WhatsApp.
