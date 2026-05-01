# Telemt Install Tools

Utilities for installing and maintaining a Telemt MTProto proxy on fresh Debian/Ubuntu, AlmaLinux, or Tiny Core Linux servers.

This repository intentionally uses placeholders only:

```text
<PROXY_DOMAIN>
<SERVER_PUBLIC_IP>
<SSH_PORT>
<LIMIT>
```

No private domains, real server IPs, logins, SSH private keys, or generated proxy secrets should be committed here.

## Files

```text
install_telemt.sh          Main Telemt installer without WireGuard
install_telemt_batch.sh       Batch installer that runs install_telemt.sh on many servers
install_telemt_README.md   Full Russian and English documentation for install_telemt.sh
install_telemt_alma.sh          AlmaLinux Telemt installer without WireGuard
install_telemt_batch_alma.sh    Batch installer for AlmaLinux target servers
install_telemt_alma_README.md   Russian and English documentation for AlmaLinux scripts
install_telemt_tinycore.sh          Tiny Core Linux Telemt installer without Docker/systemd
install_telemt_batch_tinycore.sh    Batch installer for Tiny Core target servers
install_telemt_tinycore_README.md   Russian and English documentation for Tiny Core scripts
add_key.sh                    Helper for creating/copying SSH public keys to a server
```

## install_telemt.sh

`install_telemt.sh` installs this layout:

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

It configures:

```text
Docker / Docker Compose
Telemt in Docker
nginx stream frontend
local HTTPS mask site
Let's Encrypt certificate
certbot.timer auto-renewal
nginx reload hook after certificate renewal
fail2ban
nftables rule blocking external 9091/tcp
SSH password hardening
1G swap if swap is missing
```

The generated nginx mask page is created under `/var/www/<PROXY_DOMAIN>/index.html`; its browser title and main heading use the domain entered during installation.

Run it on the target server, not on your local computer:

```bash
scp install_telemt.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
bash /root/install_telemt.sh
```

Recommended long-running mode:

```bash
tmux new -s telemt-install
bash /root/install_telemt.sh
```

Show the generated proxy link after installation:

```bash
cat /root/telemt-proxy-link.txt
```

Health report:

```bash
telemt-report 5m
```

Full installer documentation:

```text
install_telemt_README.md
```

## install_telemt_batch.sh

`install_telemt_batch.sh` is a batch orchestrator. It is meant to be run on your local admin machine, not on the target server.

It does not duplicate Telemt installation logic. For every selected server it copies and runs the main `install_telemt.sh`.

Supported local launch systems:

```text
macOS
Debian/Ubuntu/Linux
```

Before doing anything, the batch script checks local requirements:

```text
bash 3+
ssh
scp
one DNS resolver: getent, dig, or host
install_telemt.sh next to install_telemt_batch.sh
add_key.sh next to install_telemt_batch.sh
```

Workflow:

```text
ask for common SSH/install settings
ask for proxy domains one by one
stop domain input when an empty line is entered
resolve A records for every domain
if a domain has no A record, offer entering a replacement domain
check SSH key login for every resolved server IP
if key login fails, offer add_key.sh, password mode, or skip
copy install_telemt.sh to each server
run install_telemt.sh remotely with the selected domain/settings
print a per-domain result summary
read /root/telemt-proxy-link.txt after successful installs
print the final Proxy links list
```

The `Proxy links` output contains live Telegram proxy secrets. Treat it like credentials.

Run:

```bash
./install_telemt_batch.sh
```

Batch install expects one proxy domain per target server:

```text
Domain: proxy-one.example.com
Domain: proxy-two.example.com
Domain:
```

Optional environment variables:

```bash
CONNECT_SSH_PORT=22 TARGET_SSH_PORT=22 TELEMT_MAX_TCP_CONNS=1000 ./install_telemt_batch.sh
```

`install_telemt.sh` and `add_key.sh` remain fully standalone and can still be used without batch mode.

## AlmaLinux Scripts

The AlmaLinux scripts are separate and do not replace the Debian/Ubuntu scripts:

```text
install_telemt_alma.sh
install_telemt_batch_alma.sh
install_telemt_alma_README.md
```

`install_telemt_alma.sh` must run on the target AlmaLinux server.

`install_telemt_batch_alma.sh` is only a local orchestrator for AlmaLinux target servers. The machine running the batch script can be macOS, Debian, Ubuntu, AlmaLinux, or any other Linux with `bash`, `ssh`, `scp`, and a DNS lookup tool.

Run Alma batch mode:

```bash
./install_telemt_batch_alma.sh
```

Full Alma documentation:

```text
install_telemt_alma_README.md
```

## Tiny Core Linux Scripts

The Tiny Core scripts are experimental and separate from the Debian/Ubuntu and AlmaLinux scripts:

```text
install_telemt_tinycore.sh
install_telemt_batch_tinycore.sh
install_telemt_tinycore_README.md
```

Tiny Core has no normal `systemd` or `apt/dnf` flow, so this version uses:

```text
tce-load extensions
native Telemt linux-musl binary
nginx stream SNI routing
acme.sh standalone ACME
/opt/bootlocal.sh autostart
/opt/.filetool.lst persistence
```

`install_telemt_tinycore.sh` must run on the target Tiny Core server. It requires x86_64/CorePure64 or aarch64, configured persistent `/tce`, and open ports `80/tcp` and `443/tcp`.

`install_telemt_batch_tinycore.sh` is only a local orchestrator for Tiny Core target servers. The machine running the batch script can be macOS, Debian, Ubuntu, AlmaLinux, or any other Linux with `bash`, `ssh`, `scp`, and a DNS lookup tool.

Run Tiny Core batch mode:

```bash
./install_telemt_batch_tinycore.sh
```

Full Tiny Core documentation:

```text
install_telemt_tinycore_README.md
```

## add_key.sh

`add_key.sh` is an auxiliary helper for preparing SSH access before running the installer.

It can:

```text
ask for a server host/IP, SSH port, username, and key comment
generate a local ed25519 key if the selected key does not exist
repair a missing .pub file from the private key
handle changed or missing known_hosts entries
copy the public key to Unix/Linux authorized_keys
try ssh-copy-id as a fallback
support MikroTik RouterOS key import
verify that key-only login works
```

Basic usage:

```bash
./add_key.sh
```

Optional environment variables:

```bash
SERVER_INPUT=<USER>@<SERVER_PUBLIC_IP> SERVER_PORT=<SSH_PORT> KEY_PATH=~/.ssh/id_ed25519 ./add_key.sh
```

Example with placeholders:

```bash
SERVER_INPUT=root@<SERVER_PUBLIC_IP> SERVER_PORT=22 KEY_PATH=~/.ssh/id_ed25519 ./add_key.sh
```

After the helper verifies key login, run the installer on the server:

```bash
scp install_telemt.sh root@<SERVER_PUBLIC_IP>:/root/
ssh root@<SERVER_PUBLIC_IP>
bash /root/install_telemt.sh
```

## Safety

Never commit:

```text
SSH private keys
Telemt secrets
real production proxy links
real personal domains or IP addresses
server-specific .env files
```

Before publishing changes, check:

```bash
grep -RInE 'BEGIN OPENSSH PRIVATE KEY|BEGIN RSA PRIVATE KEY|tg://proxy|secret=|[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' .
```
