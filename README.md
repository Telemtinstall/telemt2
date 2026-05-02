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
./install_telemt_batch.sh
```

```bash
cd astra
./install_telemt_batch_astra.sh
```

```bash
cd almalinux
./install_telemt_batch_alma.sh
```

```bash
cd tinycore
./install_telemt_batch_tinycore.sh
```

The shared SSH key helper is in `common/add_key.sh`; batch scripts find it automatically via `../common/add_key.sh`.

## Common Result

The installers configure:

```text
Telemt proxy
nginx SNI routing
HTTPS mask site
Let's Encrypt / ACME certificate
certificate renewal
local-only Telemt API
connection limit
proxy link output
disabled access/runtime logs where supported
```

After a successful install, the generated proxy link is stored on the target server:

```text
/root/telemt-proxy-link.txt
```

The `Proxy links` output contains live Telegram proxy secrets. Treat it like credentials.
