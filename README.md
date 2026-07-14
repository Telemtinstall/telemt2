# Telemt / VPN Install Tools

Utilities for installing and maintaining Telemt MTProto proxy servers and VPN servers on fresh Linux machines.

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

## Clean Server Only / Только Чистый Сервер

RU: Запускайте установщики только на новом чистом VPS/server без чужих сайтов, панелей управления и сетевых сервисов. Скрипты настраивают nginx, firewall, SSH-port, Docker/Telemt или VPN-сервисы и сертификаты; для режимов с HTTPS-маскировкой им нужны свободные `80/tcp` и `443/tcp`. У Telemt также используются локальные `8443`, `1443`, `9091`. Отключение SSH-паролей, включение fail2ban и добавление swap спрашиваются отдельно и по умолчанию выключены. Если на сервере уже работают nginx/apache/caddy/traefik, почта, VPN, панели хостинга или другие прокси, возможны конфликты портов и конфигов. В таком случае используйте отдельную машину или интегрируйте нужный сервис вручную.

EN: Run the installers only on a new clean VPS/server without existing websites, control panels, or network services. The scripts configure nginx, firewall, SSH-port, Docker/Telemt or VPN services, and certificates; HTTPS camouflage modes need free `80/tcp` and `443/tcp`. Telemt also uses local `8443`, `1443`, and `9091`. Disabling SSH password login, enabling fail2ban, and adding swap are asked separately and are off by default. If nginx/apache/caddy/traefik, mail, VPN, hosting panels, or other proxies already run on the server, port and config conflicts are possible. Use a separate machine or integrate the required service manually.

## Structure

```text
telemt/
  common/
    add_key.sh
    README.md
  debian-13/
    install_telemt_systemd.sh
    README.md
  ubuntu-24-26/
    install_telemt_docker.sh
    README.md
  docker-telemt/
    Dockerfile
    build.sh
    install_docker-telemt.sh
    compose.example.yml
    README.md
  tinycore/
    install_telemt_tinycore.sh
    install_telemt_batch_tinycore.sh
    README.md

proxy/
  whatsapp/
    install_whatsapp_proxy.sh
    README.md

vpn/
  amneziawg/
    install_amneziawg.sh
    awgctl.sh
    README.md
  openvpn/
    install_openvpn.sh
    openvpnctl.sh
    README.md
  vless/
    install_vless.sh
    vlessctl.sh
    README.md
  wg/
    install_wg.sh
    wgctl.sh
    README.md
```

## Which Directory To Use

```text
Telemt on Debian 13             -> telemt/debian-13/
Telemt Docker on Ubuntu 24-26   -> telemt/ubuntu-24-26/
Telemt on Tiny Core Linux       -> telemt/tinycore/
Telemt Docker install/build     -> telemt/docker-telemt/
SSH key helper                  -> telemt/common/
VLESS over WebSocket + TLS      -> vpn/vless/
WireGuard                       -> vpn/wg/
OpenVPN                         -> vpn/openvpn/
AmneziaWG                       -> vpn/amneziawg/
WhatsApp Chat Proxy             -> proxy/whatsapp/
```

Each service directory has its own `README.md` with Russian and English instructions.

## VPN Directories / VPN-Каталоги

`vpn/vless/` installs Xray VLESS over WebSocket + TLS. It can work with a real domain and nginx HTTPS camouflage. It includes `vlessctl.sh` for adding, deleting, listing, showing links/QR codes, and checking traffic counters.

`vpn/wg/` installs standard WireGuard. It supports a plain UDP mode and a camouflage mode where nginx serves a normal HTTPS site on `443/tcp` while WireGuard listens separately on UDP. It includes `wgctl.sh` for client management and traffic viewing.

`vpn/openvpn/` installs OpenVPN with client management. It supports UDP/TCP profiles, username/password handling, traffic viewing, and an optional HTTPS camouflage scheme through nginx/OpenVPN `port-share`.

`vpn/amneziawg/` installs AmneziaWG. It supports plain UDP mode and a mode with an HTTPS camouflage site on TCP 443 plus AmneziaWG on UDP 443. Client configs are intended for AmneziaVPN-compatible clients, not ordinary WireGuard clients.

`proxy/whatsapp/` installs the official WhatsApp Chat Proxy Docker image. It supports direct 443 mode on a clean server and SNI mode behind an existing Telemt nginx stream frontend. The installer uses the official dated Docker image tag and its update mode checks Docker Hub for the newest dated tag.

`telemt/docker-telemt/` builds a local Telemt Docker image from official upstream release artifacts. It verifies upstream `.sha256`, uses a non-root distroless runtime by default, includes a healthcheck, and does not publish anything unless `PUSH=1` is explicitly set.

## Download From GitHub / Скачать С GitHub

RU: Telemt без Docker поддерживается только на Debian 13:

```bash
wget -O /root/install_telemt_systemd.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh -lang ru
```

```bash
curl -fsSL -o /root/install_telemt_systemd.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh -lang ru
```

RU: На Ubuntu 24.x-26.x используется только Docker-вариант. Ubuntu launcher
проверяет ОС и передаёт установку каноническому Docker installer, который также
проверяет реальный host nginx/OpenSSL и при необходимости собирает nginx
`1.31.2` с OpenSSL `3.5.7`:

```bash
curl -fsSL -o /root/install_telemt_docker.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_docker.sh
chmod +x /root/install_telemt_docker.sh
/root/install_telemt_docker.sh -lang ru
```

RU: Для Docker Telemt на Debian 13 или для прямого запуска без Ubuntu launcher
скачайте каталог Docker-установщика:

```bash
apt update
apt install -y git ca-certificates
if [ -d /root/telemt2/.git ]; then
  cd /root/telemt2
  git pull --ff-only
else
  git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /root/telemt2
  cd /root/telemt2
  git sparse-checkout set telemt/docker-telemt
fi
cd /root/telemt2/telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh -lang ru
```

EN: No-Docker Telemt is supported on Debian 13 only:

```bash
wget -O /root/install_telemt_systemd.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh -lang en
```

```bash
curl -fsSL -o /root/install_telemt_systemd.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-13/install_telemt_systemd.sh
chmod +x /root/install_telemt_systemd.sh
/root/install_telemt_systemd.sh -lang en
```

EN: Ubuntu 24.x-26.x uses Docker Telemt only. The Ubuntu launcher validates the
OS and runs the canonical Docker installer, which checks the real host nginx
OpenSSL stack and builds nginx `1.31.2` with OpenSSL `3.5.7` when required:

```bash
curl -fsSL -o /root/install_telemt_docker.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_docker.sh
chmod +x /root/install_telemt_docker.sh
/root/install_telemt_docker.sh -lang en
```

EN: For Docker Telemt, download only the Docker installer directory:

```bash
apt update
apt install -y git ca-certificates
if [ -d /root/telemt2/.git ]; then
  cd /root/telemt2
  git pull --ff-only
else
  git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /root/telemt2
  cd /root/telemt2
  git sparse-checkout set telemt/docker-telemt
fi
cd /root/telemt2/telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh -lang en
```

## Batch Mode

Batch scripts are local orchestrators. They can run on an admin machine such as macOS, Debian, Ubuntu, or another Linux host with:

```text
bash
ssh
scp
getent, dig, or host
```

They do not install Telemt locally. They copy the OS-specific installer to target servers and run it over SSH.

Example:

```bash
cd telemt/tinycore
chmod +x install_telemt_batch_tinycore.sh ../common/add_key.sh
./install_telemt_batch_tinycore.sh
```

The shared SSH key helper is in `telemt/common/add_key.sh`; batch scripts find it automatically via `../common/add_key.sh`.

## Common Result

The installers configure the full Telemt proxy stack: Telemt itself, nginx SNI routing, an HTTP -> HTTPS redirect, an HTTPS mask site, Let's Encrypt / ACME certificates with renewal hooks, a local-only Telemt API, connection limits, and proxy link output.

Where supported, they also disable nginx access logs and Telemt runtime logs, support non-interactive batch execution through explicit environment variables, and use safe nginx behavior: separate configs are added, and installation stops if `443/tcp` is already owned by another site.

After a successful install, the generated proxy link is stored on the target server:

```text
/root/telemt-proxy-link.txt
```

The `Proxy links` output contains live Telegram proxy secrets. Treat it like credentials.
