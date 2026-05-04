# Telemt Proxy Setup Description

## Scheme

1. Browser HTTP requests to `PROXY_DOMAIN:80` are redirected to `https://PROXY_DOMAIN/`.
2. Telegram client connects to `PROXY_DOMAIN:443`.
3. DNS points `PROXY_DOMAIN` to `PROXY_PUBLIC_IP`.
4. Public `443/tcp` is handled by `nginx stream`.
5. `nginx stream` checks SNI without decrypting TLS:
   - `PROXY_DOMAIN` -> `127.0.0.1:1443` -> Telemt
   - any other SNI/no SNI -> `127.0.0.1:8443` -> camouflage HTTPS site
6. Telemt listens only on `127.0.0.1:1443`.
7. If the MTProxy secret is valid, Telemt serves MTProto traffic.
8. If the secret is invalid, or the request is active probing/scanning, traffic is sent to the camouflage site.
9. Telemt outbound traffic to Telegram goes through `wg0` only in deployments where WireGuard is enabled.

## Ports

1. External `80/tcp`: nginx HTTP -> HTTPS redirect.
2. External `443/tcp`: `nginx stream`.
3. `127.0.0.1:1443`: Telemt backend.
4. `127.0.0.1:8443`: camouflage HTTPS site.
5. `127.0.0.1:9091`: Telemt read-only API.
6. `SSH_PORT/tcp`: SSH.
7. External `9091/tcp`: blocked by firewall.

## Telemt

1. Docker image is pinned by digest: `TELEMT_IMAGE@sha256:IMAGE_DIGEST`.
2. Container name: `telemt`.
3. Container user: `NON_ROOT_UID:NON_ROOT_GID`.
4. Root filesystem: `read_only: true`.
5. Capabilities: `cap_drop: ALL`.
6. Security option: `no-new-privileges=true`.
7. Default user connection limit: `MAX_TCP_CONNECTIONS`.
8. Proxy links/secrets are not printed in logs:
   - `show_link = []`
   - `show = []`

## Telemt Modes

1. `classic = false`
2. `secure = false`
3. `tls = true`
4. Only FakeTLS/EE mode is enabled.

## Camouflage

1. `tls_domain = "PROXY_DOMAIN"`.
2. `mask = true`.
3. `mask_host = "127.0.0.1"`.
4. `mask_port = 8443`.
5. Camouflage target is a normal HTTPS page.
6. TLS certificate is issued by Let's Encrypt for `PROXY_DOMAIN`.

## WireGuard

1. Interface: `wg0`.
2. Local WireGuard address: `WG_CLIENT_IP/CIDR`.
3. Endpoint: `WG_EXIT_IP:WG_PORT`.
4. `AllowedIPs = 0.0.0.0/0`.
5. All outbound traffic goes through WireGuard.
6. SSH protection rule keeps replies from `PROXY_PUBLIC_IP` routed through the main table.
7. Telemt NAT IP is set to `WG_EXIT_PUBLIC_IP`, because Telegram sees the WireGuard exit address.

## Hardening

1. SSH listens on `SSH_PORT`.
2. SSH password disabling is optional. By default password login is left unchanged.
3. If `SSH_KEY_ONLY_LOGIN=yes` is selected and confirmed, the installer sets:
   - `PasswordAuthentication no`
   - `PermitRootLogin prohibit-password`
   - `KbdInteractiveAuthentication no`
   - `PubkeyAuthentication yes`
4. `fail2ban` for SSH is optional and is installed/enabled only when selected.
5. `wg-quick@wg0` is enabled at boot when WireGuard is part of the deployment.
6. Secret configuration files use mode `600`.
7. `local-hardening-nft` blocks external access to `9091`.

## Monitoring

1. Report script path: `/usr/local/sbin/telemt-report`.
2. Run:

```bash
ssh -p SSH_PORT root@PROXY_DOMAIN 'telemt-report'
```

3. The report shows:
   - Telemt health;
   - active connection count;
   - configured connection limit;
   - top TCP peer IPs on external `443`;
   - WireGuard status;
   - recent Telemt errors;
   - server resource usage.

## Limitations

1. Telemt API sees clients as `127.0.0.1`, because traffic reaches Telemt through local `nginx stream`.
2. Real client peer IPs are visible at the external `443` level through `ss` or `telemt-report`.
3. Telegram account names, phone numbers, chats, messages, and exact per-person traffic are not visible.
