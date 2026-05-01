# Telemt Install Tools

Utilities for installing and maintaining a Telemt MTProto proxy on a fresh Debian/Ubuntu server.

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
install_telemt_README.md   Full Russian and English documentation for install_telemt.sh
add_key                    Helper for creating/copying SSH public keys to a server
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

## add_key

`add_key` is an auxiliary helper for preparing SSH access before running the installer.

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
./add_key
```

Optional environment variables:

```bash
SERVER_INPUT=<USER>@<SERVER_PUBLIC_IP> SERVER_PORT=<SSH_PORT> KEY_PATH=~/.ssh/id_ed25519 ./add_key
```

Example with placeholders:

```bash
SERVER_INPUT=root@<SERVER_PUBLIC_IP> SERVER_PORT=22 KEY_PATH=~/.ssh/id_ed25519 ./add_key
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
