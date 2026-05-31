# Telemt / VPN Install Tools

Utilities for installing and maintaining Telemt MTProto proxy servers and VPN servers on fresh Linux machines.

## Installer Notice / Уведомление об установщиках

RU: Эти скрипты являются обычными Bash-установщиками для упрощения настройки Telemt с HTTPS-маскировкой и VPN-сервисов. Это не официальные установщики Telemt, WireGuard, OpenVPN, AmneziaWG, Xray или других проектов. В репозитории нет встроенных бинарников, VPN-клиентов, proxy-серверов, сертификатов или ключей. Скрипты скачивают и устанавливают программное обеспечение из официальных источников ОС и upstream-проектов:

- Telemt: GitHub releases проекта `telemt/telemt`, `https://github.com/telemt/telemt`.
- Docker / containerd / Docker Compose: пакеты дистрибутива или официальный Docker apt/yum repository, `https://download.docker.com`.
- nginx, certbot, WireGuard, OpenVPN, easy-rsa, qrencode, iproute2, nftables, fail2ban и другие системные пакеты: официальные репозитории Debian/Ubuntu/Astra/AlmaLinux/Tiny Core.
- acme.sh для Tiny Core: официальный репозиторий `acmesh-official/acme.sh`, `https://github.com/acmesh-official/acme.sh`.
- Xray для VLESS: официальный проект `XTLS/Xray-core`, `https://github.com/XTLS/Xray-core`.
- wstunnel для экспериментального WireGuard-over-WebSocket: официальный проект `erebe/wstunnel`, `https://github.com/erebe/wstunnel`.
- AmneziaWG: официальные пакеты/репозитории AmneziaWG, когда они используются установщиком.
- WhatsApp Chat Proxy: официальный проект `WhatsApp/proxy` и Docker image `facebook/whatsapp_proxy`, `https://github.com/WhatsApp/proxy`.

EN: These scripts are ordinary Bash installers intended to make Telemt with HTTPS camouflage and VPN service setup easier. They are not official installers for Telemt, WireGuard, OpenVPN, AmneziaWG, Xray, or any other upstream project. This repository does not contain embedded binaries, VPN clients, proxy servers, certificates, or keys. The scripts download and install software from official operating-system repositories and upstream project sources:

- Telemt: GitHub releases of `telemt/telemt`, `https://github.com/telemt/telemt`.
- Docker / containerd / Docker Compose: distribution packages or the official Docker apt/yum repository, `https://download.docker.com`.
- nginx, certbot, WireGuard, OpenVPN, easy-rsa, qrencode, iproute2, nftables, fail2ban, and other system packages: official Debian/Ubuntu/Astra/AlmaLinux/Tiny Core repositories.
- acme.sh for Tiny Core: official `acmesh-official/acme.sh` repository, `https://github.com/acmesh-official/acme.sh`.
- Xray for VLESS: official `XTLS/Xray-core` project, `https://github.com/XTLS/Xray-core`.
- wstunnel for experimental WireGuard-over-WebSocket: official `erebe/wstunnel` project, `https://github.com/erebe/wstunnel`.
- AmneziaWG: official AmneziaWG packages/repositories when used by the installer.
- WhatsApp Chat Proxy: official `WhatsApp/proxy` project and Docker image `facebook/whatsapp_proxy`, `https://github.com/WhatsApp/proxy`.

This repository intentionally uses placeholders only:

```text
<PROXY_DOMAIN>
<VPN_DOMAIN>
<SERVER_PUBLIC_IP>
<SSH_PORT>
<LIMIT>
<CLIENT_NAME>
```

No private domains, real server IPs, logins, SSH private keys, generated proxy secrets, VPN client configs, or GitHub tokens should be committed here.

Latest repository changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## Clean Server Only / Только Чистый Сервер

RU: Запускайте установщики только на новом чистом VPS/server без чужих сайтов, панелей управления и сетевых сервисов. Скрипты настраивают nginx, firewall, SSH-port, Docker/Telemt или VPN-сервисы и сертификаты; для режимов с HTTPS-маскировкой им нужны свободные `80/tcp` и `443/tcp`. У Telemt также используются локальные `8443`, `1443`, `9091`. Отключение SSH-паролей, включение fail2ban и добавление swap спрашиваются отдельно и по умолчанию выключены. Если на сервере уже работают nginx/apache/caddy/traefik, почта, VPN, панели хостинга или другие прокси, возможны конфликты портов и конфигов. В таком случае используйте отдельную машину или интегрируйте нужный сервис вручную.

EN: Run the installers only on a new clean VPS/server without existing websites, control panels, or network services. The scripts configure nginx, firewall, SSH-port, Docker/Telemt or VPN services, and certificates; HTTPS camouflage modes need free `80/tcp` and `443/tcp`. Telemt also uses local `8443`, `1443`, and `9091`. Disabling SSH password login, enabling fail2ban, and adding swap are asked separately and are off by default. If nginx/apache/caddy/traefik, mail, VPN, hosting panels, or other proxies already run on the server, port and config conflicts are possible. Use a separate machine or integrate the required service manually.

## Structure

```text
telemt/
  debian-13-ubuntu/
    install_telemt.sh
    install_telemt_batch.sh
    README.md
  debian-11/
    install_telemt_debian11.sh
    README.md
  astra/
    install_telemt_astra.sh
    install_telemt_batch_astra.sh
    README.md
  almalinux/
    install_telemt_alma.sh
    install_telemt_batch_alma.sh
    README.md
  tinycore/
    install_telemt_tinycore.sh
    install_telemt_batch_tinycore.sh
    README.md
  common/
    add_key.sh
    README.md

vpn/
  vless/
    install_vless.sh
    vlessctl.sh
    README.md
  wg/
    install_wg.sh
    wgctl.sh
    README.md
  wg-experimental/
    install_wg_wstunnel.sh
    wgctl.sh
    README.md
  openvpn/
    install_openvpn.sh
    openvpnctl.sh
    README.md
  amneziawg/
    install_amneziawg.sh
    awgctl.sh
    README.md

proxy/
  whatsapp/
    install_whatsapp_proxy.sh
    README.md

utils/
  certbot_helper.sh
  README.md
```

## Which Directory To Use

```text
Telemt on Debian 13 / Ubuntu    -> telemt/debian-13-ubuntu/
Telemt on Debian 11             -> telemt/debian-11/
Telemt on Astra Linux           -> telemt/astra/
Telemt on AlmaLinux             -> telemt/almalinux/
Telemt on Tiny Core Linux       -> telemt/tinycore/
SSH key helper                  -> telemt/common/
VLESS over WebSocket + TLS      -> vpn/vless/
WireGuard                       -> vpn/wg/
WireGuard over wstunnel, test   -> vpn/wg-experimental/
OpenVPN                         -> vpn/openvpn/
AmneziaWG, test                 -> vpn/amneziawg/
WhatsApp Chat Proxy, test       -> proxy/whatsapp/
Certificate helper              -> utils/
```

Each service and utility directory has its own `README.md` with Russian and English instructions.

## VPN Directories / VPN-Каталоги

`vpn/vless/` installs Xray VLESS over WebSocket + TLS. It can work with a real domain and nginx HTTPS camouflage. It includes `vlessctl.sh` for adding, deleting, listing, showing links/QR codes, and checking traffic counters.

`vpn/wg/` installs standard WireGuard. It supports a plain UDP mode and a camouflage mode where nginx serves a normal HTTPS site on `443/tcp` while WireGuard listens separately on UDP. It includes `wgctl.sh` for client management and traffic viewing.

`vpn/wg-experimental/` installs an experimental WireGuard over `wstunnel` layout. This is for desktop/router scenarios where a local wstunnel client can run near the WireGuard client. It is not for the standard iPhone WireGuard app by itself.

`vpn/openvpn/` installs OpenVPN with client management. It supports UDP/TCP profiles, username/password handling, traffic viewing, and an optional HTTPS camouflage scheme through nginx/OpenVPN `port-share`.

`vpn/amneziawg/` installs AmneziaWG. It supports plain UDP mode and a mode with an HTTPS camouflage site on TCP 443 plus AmneziaWG on UDP 443. Client configs are intended for AmneziaVPN-compatible clients, not ordinary WireGuard clients.

`utils/` contains helper scripts that are useful across installers. `certbot_helper.sh` issues Let's Encrypt certificates with certbot-style `-d` domain arguments, optional interactive prompts, DNS preflight, and certbot auto-renewal setup.

## Proxy Directories / Proxy-Каталоги

`proxy/whatsapp/` installs the official WhatsApp Chat Proxy Docker image in an experimental guarded layout. It can run directly on a free `443/tcp`, or add one SNI route to an existing Telemt nginx stream setup after DNS/port checks and backup. It does not change Telemt secrets or existing Telemt containers.

## Download From GitHub / Скачать С GitHub

RU: Если нужен один установщик, его можно скачать прямо на сервер через `wget` или `curl`:

```bash
wget -O /root/install_telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13-ubuntu/install_telemt.sh
chmod +x /root/install_telemt.sh
```

```bash
curl -fsSL -o /root/install_telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13-ubuntu/install_telemt.sh
chmod +x /root/install_telemt.sh
```

RU: Если нужен `git`, скачайте только нужный каталог:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt
cd /tmp/telemt
git sparse-checkout set telemt/debian-13-ubuntu
cp telemt/debian-13-ubuntu/install_telemt.sh /root/
chmod +x /root/install_telemt.sh
```

EN: To download a single installer directly on the server, use `wget` or `curl`:

```bash
wget -O /root/install_telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13-ubuntu/install_telemt.sh
chmod +x /root/install_telemt.sh
```

```bash
curl -fsSL -o /root/install_telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13-ubuntu/install_telemt.sh
chmod +x /root/install_telemt.sh
```

EN: If you want to use `git`, download only the needed directory:

```bash
git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /tmp/telemt
cd /tmp/telemt
git sparse-checkout set telemt/debian-13-ubuntu
cp telemt/debian-13-ubuntu/install_telemt.sh /root/
chmod +x /root/install_telemt.sh
```

## Telemt Update Mode / Обновление Telemt

RU: Одиночные Telemt-установщики поддерживают безопасный режим обновления. Он не пересоздаёт пользователей, не меняет секреты, не переписывает `telemt.toml`, nginx, SSH и сертификаты. Он делает бэкап текущего состояния, обновляет Docker image/контейнер или native binary на Tiny Core, перезапускает Telemt и заново выводит proxy-ссылку из текущего секрета.

EN: Single-server Telemt installers support a safe update mode. It does not recreate users, change secrets, or rewrite `telemt.toml`, nginx, SSH, or certificate settings. It backs up the current state, updates the Docker image/container or the native Tiny Core binary, restarts Telemt, and prints the proxy link from the existing secret.

Debian 13 / Ubuntu:

```bash
wget -O /root/install_telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13-ubuntu/install_telemt.sh
chmod +x /root/install_telemt.sh
/root/install_telemt.sh --update -lang ru
```

Debian 11:

```bash
wget -O /root/install_telemt_debian11.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-11/install_telemt_debian11.sh
chmod +x /root/install_telemt_debian11.sh
/root/install_telemt_debian11.sh --update -lang ru
```

Astra Linux:

```bash
wget -O /root/install_telemt_astra.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/astra/install_telemt_astra.sh
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh --update -lang ru
```

AlmaLinux:

```bash
wget -O /root/install_telemt_alma.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/almalinux/install_telemt_alma.sh
chmod +x /root/install_telemt_alma.sh
/root/install_telemt_alma.sh --update -lang ru
```

Tiny Core:

```bash
wget -O /root/install_telemt_tinycore.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/tinycore/install_telemt_tinycore.sh
chmod +x /root/install_telemt_tinycore.sh
/root/install_telemt_tinycore.sh --update -lang ru
```

RU: Если Docker compose использует digest-pinned image вида `image@sha256:...`, обычный `--update` пересоздаст контейнер на том же digest. Чтобы явно перейти на другой image/tag, задайте переменную:

```bash
TELEMT_IMAGE=<IMAGE_OR_TAG> /root/install_telemt.sh --update -lang ru
```

EN: If Docker compose uses a digest-pinned image such as `image@sha256:...`, plain `--update` recreates the container with that same digest. To explicitly move to another image/tag, pass:

```bash
TELEMT_IMAGE=<IMAGE_OR_TAG> /root/install_telemt.sh --update -lang ru
```

## Telemt Nginx Fix Mode / Ремонт Nginx

RU: Если после обновления nginx падает с ошибкой `unknown directive "http2"` и `nginx -t` не проходит, используйте аварийный режим. Он чинит только nginx-конфиги: делает бэкап измененных файлов, удаляет несовместимые строки `http2 on;` и `listen ... http2;`, затем запускает `nginx -t` и reload. Telemt-секреты, пользователи, Docker, сертификаты и `telemt.toml` не трогаются.

EN: If nginx fails after an update with `unknown directive "http2"` and `nginx -t` does not pass, use emergency fix mode. It repairs only nginx configs: backs up changed files, removes incompatible `http2 on;` and `listen ... http2;` syntax, then runs `nginx -t` and reloads nginx. Telemt secrets, users, Docker, certificates, and `telemt.toml` are not touched.

Debian 13 / Ubuntu:

```bash
wget -O /root/install_telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13-ubuntu/install_telemt.sh
chmod +x /root/install_telemt.sh
/root/install_telemt.sh --fix-nginx -lang ru
```

Astra Linux:

```bash
wget -O /root/install_telemt_astra.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/astra/install_telemt_astra.sh
chmod +x /root/install_telemt_astra.sh
/root/install_telemt_astra.sh --fix-nginx -lang ru
```

AlmaLinux:

```bash
wget -O /root/install_telemt_alma.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/almalinux/install_telemt_alma.sh
chmod +x /root/install_telemt_alma.sh
/root/install_telemt_alma.sh --fix-nginx -lang ru
```

## Telemt Installer Questions / Вопросы Установщика Telemt

RU: При обычной установке одиночный Telemt-установщик спрашивает:

1. `Proxy domain` - домен прокси. Можно вводить ASCII, punycode или кириллицу/IDN. Кириллица переводится в punycode, введённый `xn--...` проверяется через IDN round-trip.
2. `Let's Encrypt email` - email для сертификата. По умолчанию `admin@<domain>`; доменная часть email тоже нормализуется в punycode при необходимости.
3. `SSH port` - SSH-порт, который должен остаться или быть настроен. По умолчанию `22`.
4. `Disable SSH password login...` - отключать ли парольный SSH-вход. По умолчанию `no`. Если выбрать `yes`, скрипт проверит `/root/.ssh/authorized_keys` и попросит второе подтверждение.
5. `Enable fail2ban for SSH` - включать ли fail2ban для SSH. По умолчанию `no`.
6. `Add 1G swap if missing` - добавлять ли swap, если его нет. По умолчанию `no`.
7. `Max Telemt connections` - лимит одновременных подключений пользователя Telemt. По умолчанию `5000`.
8. Финальное подтверждение `y`/`yes`/`да` - только после него начинается установка.

EN: During a normal single-server install, the Telemt installer asks for:

1. `Proxy domain` - the proxy domain. ASCII, punycode, or IDN/Cyrillic input is accepted. IDN is converted to punycode; existing `xn--...` input is validated with an IDN round-trip.
2. `Let's Encrypt email` - certificate email. Default is `admin@<domain>`; the email domain is normalized to punycode when needed.
3. `SSH port` - SSH port to keep/configure. Default is `22`.
4. `Disable SSH password login...` - whether to disable password SSH login. Default is `no`. If `yes`, the script checks `/root/.ssh/authorized_keys` and asks for a second confirmation.
5. `Enable fail2ban for SSH` - whether to enable fail2ban for SSH. Default is `no`.
6. `Add 1G swap if missing` - whether to add swap when absent. Default is `no`.
7. `Max Telemt connections` - Telemt per-user simultaneous connection limit. Default is `5000`.
8. Final confirmation `y`/`yes`/`да` - installation starts only after confirmation.

## Batch Mode

Batch scripts are local orchestrators. They can run on an admin machine such as macOS, Debian, Ubuntu, AlmaLinux, or another Linux host with:

```text
bash
ssh
scp
getent, dig, or host
```

They do not install Telemt locally. They copy the OS-specific installer to target servers and run it over SSH.

Examples:

```bash
cd telemt/debian-13-ubuntu
chmod +x install_telemt_batch.sh ../common/add_key.sh
./install_telemt_batch.sh
```

```bash
cd telemt/astra
chmod +x install_telemt_batch_astra.sh ../common/add_key.sh
./install_telemt_batch_astra.sh
```

```bash
cd telemt/almalinux
chmod +x install_telemt_batch_alma.sh ../common/add_key.sh
./install_telemt_batch_alma.sh
```

```bash
cd telemt/tinycore
chmod +x install_telemt_batch_tinycore.sh ../common/add_key.sh
./install_telemt_batch_tinycore.sh
```

The shared SSH key helper is in `telemt/common/add_key.sh`; batch scripts find it automatically via `../common/add_key.sh` from each Telemt OS directory.

## Common Result

The installers configure the full Telemt proxy stack: Telemt itself, nginx SNI routing, an HTTP -> HTTPS redirect, an HTTPS mask site, Let's Encrypt / ACME certificates with renewal hooks, a local-only Telemt API, connection limits, and proxy link output. New Telemt configs also add `censorship.exclusive_mask` when the selected Telemt image/release is `latest` or `3.4.12+`; update mode preserves existing configs and does not add it automatically to already installed servers.

Where supported, they also disable nginx access logs and Telemt runtime logs, support non-interactive batch execution through explicit environment variables, and use safe nginx behavior: separate configs are added, and installation stops if `443/tcp` is already owned by another site.

After a successful install, the generated proxy link is stored on the target server:

```text
/root/telemt-proxy-link.txt
```

The `Proxy links` output contains live Telegram proxy secrets. Treat it like credentials.
