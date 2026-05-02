# Telemt Install Tools

Utilities for installing and maintaining a Telemt MTProto proxy on fresh Linux servers.

This repository intentionally uses placeholders only:

```text
<PROXY_DOMAIN>
<SERVER_PUBLIC_IP>
<SSH_PORT>
<LIMIT>
```

No private domains, real server IPs, logins, SSH private keys, or generated proxy secrets should be committed here.

## Clean Server Only / Только Чистый Сервер

RU: Запускайте установщики только на новом чистом VPS/server без чужих сайтов, панелей управления и сетевых сервисов. Скрипты настраивают nginx, firewall, SSH hardening, Docker/Telemt и сертификаты; для этого им нужны свободные `80/tcp` и `443/tcp`, а также локальные `8443`, `1443`, `9091`. Если на сервере уже работают nginx/apache/caddy/traefik, почта, VPN, панели хостинга или другие прокси, возможны конфликты портов и конфигов. В таком случае используйте отдельную машину или интегрируйте Telemt вручную.

EN: Run the installers only on a new clean VPS/server without existing websites, control panels, or network services. The scripts configure nginx, firewall, SSH hardening, Docker/Telemt, and certificates; they need free `80/tcp` and `443/tcp`, plus local `8443`, `1443`, and `9091`. If nginx/apache/caddy/traefik, mail, VPN, hosting panels, or other proxies already run on the server, port and config conflicts are possible. Use a separate machine or integrate Telemt manually.

## Structure

```text
debian-ubuntu/
  install_telemt.sh
  install_telemt_batch.sh
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
```

## Which Directory To Use

```text
Debian / Ubuntu  -> debian-ubuntu/
Astra Linux      -> astra/
AlmaLinux        -> almalinux/
Tiny Core Linux  -> tinycore/
SSH key helper   -> common/
```

Each OS directory has its own `README.md` with Russian and English instructions.

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
cd debian-ubuntu
chmod +x install_telemt_batch.sh ../common/add_key.sh
./install_telemt_batch.sh
```

```bash
cd astra
chmod +x install_telemt_batch_astra.sh ../common/add_key.sh
./install_telemt_batch_astra.sh
```

```bash
cd almalinux
chmod +x install_telemt_batch_alma.sh ../common/add_key.sh
./install_telemt_batch_alma.sh
```

```bash
cd tinycore
chmod +x install_telemt_batch_tinycore.sh ../common/add_key.sh
./install_telemt_batch_tinycore.sh
```

The shared SSH key helper is in `common/add_key.sh`; batch scripts find it automatically via `../common/add_key.sh`.

## Common Result

The installers configure the full Telemt proxy stack: Telemt itself, nginx SNI routing, an HTTPS mask site, Let's Encrypt / ACME certificates with renewal, a local-only Telemt API, connection limits, and proxy link output.

Where supported, they also disable nginx access logs and Telemt runtime logs, support non-interactive batch execution through explicit environment variables, and use safe nginx behavior: separate configs are added, and installation stops if `443/tcp` is already owned by another site.

After a successful install, the generated proxy link is stored on the target server:

```text
/root/telemt-proxy-link.txt
```

The `Proxy links` output contains live Telegram proxy secrets. Treat it like credentials.
