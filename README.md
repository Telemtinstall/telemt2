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

EN: These scripts are ordinary Bash installers intended to make Telemt with HTTPS camouflage and VPN service setup easier. They are not official installers for Telemt, WireGuard, OpenVPN, AmneziaWG, Xray, or any other upstream project. This repository does not contain embedded binaries, VPN clients, proxy servers, certificates, or keys. The scripts download and install software from official operating-system repositories and upstream project sources:

- Telemt: GitHub releases of `telemt/telemt`, `https://github.com/telemt/telemt`.
- Docker / containerd / Docker Compose: distribution packages or the official Docker apt/yum repository, `https://download.docker.com`.
- nginx, certbot, WireGuard, OpenVPN, easy-rsa, qrencode, iproute2, nftables, fail2ban, and other system packages: official Debian/Ubuntu/Astra/AlmaLinux/Tiny Core repositories.
- acme.sh for Tiny Core: official `acmesh-official/acme.sh` repository, `https://github.com/acmesh-official/acme.sh`.
- Xray for VLESS: official `XTLS/Xray-core` project, `https://github.com/XTLS/Xray-core`.
- wstunnel for experimental WireGuard-over-WebSocket: official `erebe/wstunnel` project, `https://github.com/erebe/wstunnel`.
- AmneziaWG: official AmneziaWG packages/repositories when used by the installer.

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
```

Each service directory has its own `README.md` with Russian and English instructions.

## VPN Directories / VPN-Каталоги

`vpn/vless/` installs Xray VLESS over WebSocket + TLS. It can work with a real domain and nginx HTTPS camouflage. It includes `vlessctl.sh` for adding, deleting, listing, showing links/QR codes, and checking traffic counters.

`vpn/wg/` installs standard WireGuard. It supports a plain UDP mode and a camouflage mode where nginx serves a normal HTTPS site on `443/tcp` while WireGuard listens separately on UDP. It includes `wgctl.sh` for client management and traffic viewing.

`vpn/wg-experimental/` installs an experimental WireGuard over `wstunnel` layout. This is for desktop/router scenarios where a local wstunnel client can run near the WireGuard client. It is not for the standard iPhone WireGuard app by itself.

`vpn/openvpn/` installs OpenVPN with client management. It supports UDP/TCP profiles, username/password handling, traffic viewing, and an optional HTTPS camouflage scheme through nginx/OpenVPN `port-share`.

`vpn/amneziawg/` installs AmneziaWG. It supports plain UDP mode and a mode with an HTTPS camouflage site on TCP 443 plus AmneziaWG on UDP 443. Client configs are intended for AmneziaVPN-compatible clients, not ordinary WireGuard clients.

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

The installers configure the full Telemt proxy stack: Telemt itself, nginx SNI routing, an HTTP -> HTTPS redirect, an HTTPS mask site, Let's Encrypt / ACME certificates with renewal hooks, a local-only Telemt API, connection limits, and proxy link output.

Where supported, they also disable nginx access logs and Telemt runtime logs, support non-interactive batch execution through explicit environment variables, and use safe nginx behavior: separate configs are added, and installation stops if `443/tcp` is already owned by another site.

After a successful install, the generated proxy link is stored on the target server:

```text
/root/telemt-proxy-link.txt
```

The `Proxy links` output contains live Telegram proxy secrets. Treat it like credentials.
