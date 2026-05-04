#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap a server matching the reference Telemt layout:
# nginx stream on public :443 -> Telemt 127.0.0.1:1443 by SNI,
# mask HTTPS site on 127.0.0.1:8443, Telemt API on 127.0.0.1:9091,
# WireGuard full tunnel, SSH on 122, optional fail2ban, nft hardening, Docker Telemt.

SCRIPT_VERSION="2026-05-01"
TELEMT_IMAGE_DEFAULT="whn0thacked/telemt-docker@sha256:cf9b970f2d13937328372e903e40b971e4a5319cd005930453a89a80ba2365e4"

CONFIG_FILE="${1:-}"
if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

: "${PUBLIC_HOST:=}"
: "${PUBLIC_IP:=}"
: "${LETSENCRYPT_EMAIL:=}"
: "${TELEMT_SECRET:=}"
: "${TELEMT_IMAGE:=$TELEMT_IMAGE_DEFAULT}"
: "${TELEMT_MAX_TCP_CONNS:=1000}"
: "${TELEMT_NAT_IP:=}"
: "${SSH_PORT:=122}"
: "${SSH_KEY_ONLY_LOGIN:=no}"
: "${SSH_KEY_ONLY_CONFIRM:=no}"
: "${ENABLE_FAIL2BAN:=no}"
: "${ADD_SWAP:=no}"
: "${WG_IF:=wg0}"
: "${WG_ADDRESS:=}"
: "${WG_PRIVATE_KEY:=}"
: "${WG_PEER_PUBLIC_KEY:=}"
: "${WG_ENDPOINT:=}"
: "${WG_ALLOWED_IPS:=0.0.0.0/0}"
: "${WG_PERSISTENT_KEEPALIVE:=25}"
: "${ASSUME_YES:=0}"
: "${ALLOW_DNS_MISMATCH:=0}"
: "${REQUIRE_WG_HANDSHAKE:=1}"
: "${BACKUP_ROOT:=/root/telemt-clone-backups}"

STEP=0
BACKUP_DIR=""

step() {
  STEP=$((STEP + 1))
  printf '\n[%02d] %s\n' "$STEP" "$1"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run as root."
}

have() {
  command -v "$1" >/dev/null 2>&1
}

backup_path() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  cp -a "$path" "$BACKUP_DIR"/
}

root_authorized_key_exists() {
  [[ -f /root/.ssh/authorized_keys ]] &&
    grep -Eq '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]' /root/.ssh/authorized_keys
}

remove_installer_key_only_config_if_present() {
  local conf="/etc/ssh/sshd_config.d/00password.conf"
  [[ -f "$conf" ]] || return 0
  if grep -Eq '^PasswordAuthentication[[:space:]]+no' "$conf" &&
     grep -Eq '^KbdInteractiveAuthentication[[:space:]]+no' "$conf" &&
     grep -Eq '^PubkeyAuthentication[[:space:]]+yes' "$conf"; then
    rm -f "$conf"
    echo "Removed installer key-only SSH config; password login is left to the base sshd_config."
  fi
}

require_var() {
  local name="$1"
  local value="${!name:-}"
  [[ -n "$value" ]] || die "Set $name in telemt-clone.env or environment."
}

detect_public_ip() {
  if [[ -n "$PUBLIC_IP" ]]; then
    return
  fi
  PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if [[ -z "$PUBLIC_IP" ]] && have curl; then
    PUBLIC_IP="$(curl -4fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)"
  fi
  [[ -n "$PUBLIC_IP" ]] || die "Could not detect PUBLIC_IP. Set it manually."
}

resolve_ipv4() {
  local host="$1"
  getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
}

host_from_endpoint() {
  local endpoint="$1"
  printf '%s' "${endpoint%:*}"
}

confirm() {
  [[ "$ASSUME_YES" == "1" ]] && return 0
  cat <<EOF

This will install and overwrite Telemt/nginx/WireGuard/SSH settings on this server.
Target domain: $PUBLIC_HOST
Public IP:     $PUBLIC_IP
SSH port:      $SSH_PORT

Type YES to continue:
EOF
  read -r answer
  [[ "$answer" == "YES" ]] || die "Cancelled."
}

write_file_root() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  install -d -m 0755 "$(dirname "$path")"
  cat > "$path"
  chown "$owner" "$path"
  chmod "$mode" "$path"
}

is_placeholder() {
  local value="${1:-}"
  [[ -z "$value" ]] && return 0
  [[ "$value" == "proxy.example.com" ]] && return 0
  [[ "$value" == "admin@example.com" ]] && return 0
  [[ "$value" == "10.200.0.X/24" ]] && return 0
  [[ "$value" == REPLACE_WITH_* ]] && return 0
  return 1
}

prompt_value() {
  local var="$1"
  local label="$2"
  local default_value="${3:-}"
  local secret="${4:-0}"
  local current="${!var:-}"
  local shown="$current"
  local answer=""

  if is_placeholder "$default_value"; then
    default_value=""
  fi
  if is_placeholder "$current"; then
    current=""
    shown=""
  fi
  if [[ -z "$shown" && -n "$default_value" ]]; then
    shown="$default_value"
  fi

  if [[ "$secret" == "1" ]]; then
    if [[ -n "$current" ]]; then
      printf '%s [hidden set, Enter keeps it]: ' "$label"
    elif [[ -n "$default_value" ]]; then
      printf '%s [%s]: ' "$label" "$default_value"
    else
      printf '%s: ' "$label"
    fi
    read -rs answer || true
    printf '\n'
  else
    if [[ -n "$shown" ]]; then
      printf '%s [%s]: ' "$label" "$shown"
    else
      printf '%s: ' "$label"
    fi
    read -r answer || true
  fi

  if [[ -n "$answer" ]]; then
    printf -v "$var" '%s' "$answer"
  elif [[ -z "$current" && -n "$default_value" ]]; then
    printf -v "$var" '%s' "$default_value"
  elif [[ -n "$current" ]]; then
    printf -v "$var" '%s' "$current"
  fi
}

needs_interactive_config() {
  [[ -t 0 ]] || return 1
  [[ "${PROMPT_CONFIG:-0}" == "1" ]] && return 0
  [[ -z "$CONFIG_FILE" ]] && return 0
  is_placeholder "$PUBLIC_HOST" && return 0
  is_placeholder "$WG_ADDRESS" && return 0
  is_placeholder "$WG_PRIVATE_KEY" && return 0
  is_placeholder "$WG_PEER_PUBLIC_KEY" && return 0
  is_placeholder "$WG_ENDPOINT" && return 0
  return 1
}

save_config_file() {
  local target="${CONFIG_FILE:-./telemt-clone.env}"
  local dir
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  umask 077
  cat > "$target" <<EOF
# Generated by telemt-clone-bootstrap.sh on $(date -Is)
PUBLIC_HOST=$(printf '%q' "$PUBLIC_HOST")
LETSENCRYPT_EMAIL=$(printf '%q' "$LETSENCRYPT_EMAIL")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
TELEMT_SECRET=$(printf '%q' "$TELEMT_SECRET")
TELEMT_MAX_TCP_CONNS=$(printf '%q' "$TELEMT_MAX_TCP_CONNS")
WG_ADDRESS=$(printf '%q' "$WG_ADDRESS")
WG_PRIVATE_KEY=$(printf '%q' "$WG_PRIVATE_KEY")
WG_PEER_PUBLIC_KEY=$(printf '%q' "$WG_PEER_PUBLIC_KEY")
WG_ENDPOINT=$(printf '%q' "$WG_ENDPOINT")
WG_ALLOWED_IPS=$(printf '%q' "$WG_ALLOWED_IPS")
WG_PERSISTENT_KEEPALIVE=$(printf '%q' "$WG_PERSISTENT_KEEPALIVE")
TELEMT_NAT_IP=$(printf '%q' "$TELEMT_NAT_IP")
SSH_PORT=$(printf '%q' "$SSH_PORT")
ASSUME_YES=$(printf '%q' "$ASSUME_YES")
ALLOW_DNS_MISMATCH=$(printf '%q' "$ALLOW_DNS_MISMATCH")
REQUIRE_WG_HANDSHAKE=$(printf '%q' "$REQUIRE_WG_HANDSHAKE")
EOF
  chmod 600 "$target"
  CONFIG_FILE="$target"
  echo "Saved config: $target"
}

wg_peer_allowed_ip() {
  local address="$1"
  local ip="${address%%/*}"
  if [[ "$ip" == *:* ]]; then
    printf '%s/128' "$ip"
  else
    printf '%s/32' "$ip"
  fi
}

write_wg_exit_instructions() {
  local pubkey="$1"
  local allowed_ip
  allowed_ip="$(wg_peer_allowed_ip "$WG_ADDRESS")"
  cat > /root/wg-exit-add-peer.txt <<EOF
Add this peer on the WireGuard exit server (${WG_ENDPOINT}).

Runtime command, if the exit interface is wg0:

wg set wg0 peer '${pubkey}' allowed-ips '${allowed_ip}'

Persistent config block for the exit server's wg0.conf:

[Peer]
PublicKey = ${pubkey}
AllowedIPs = ${allowed_ip}

If the exit server does not already route/NAT ${WG_ADDRESS}, it also needs:
  sysctl -w net.ipv4.ip_forward=1
  NAT/masquerade from the WG subnet to the internet-facing interface
EOF
  chmod 600 /root/wg-exit-add-peer.txt
}

interactive_config() {
  cat <<'EOF'

Telemt clone setup wizard.
Press Enter to keep a shown default. Secrets are saved to telemt-clone.env with mode 600.
Leave TELEMT_SECRET empty to generate a new proxy secret during install.

EOF
  prompt_value PUBLIC_HOST "Domain for proxy and certificate" "$PUBLIC_HOST" 0
  prompt_value LETSENCRYPT_EMAIL "Let's Encrypt email, optional" "$LETSENCRYPT_EMAIL" 0
  prompt_value PUBLIC_IP "Server public IPv4, empty = auto-detect" "$PUBLIC_IP" 0
  prompt_value TELEMT_SECRET "Telemt secret, empty = generate" "$TELEMT_SECRET" 1
  prompt_value TELEMT_MAX_TCP_CONNS "Telemt max TCP connections" "${TELEMT_MAX_TCP_CONNS:-1000}" 0
  prompt_value WG_ADDRESS "WireGuard address for this server, e.g. 10.200.0.3/24" "$WG_ADDRESS" 0
  prompt_value WG_PRIVATE_KEY "WireGuard private key for this server, empty = generate" "$WG_PRIVATE_KEY" 1
  prompt_value WG_PEER_PUBLIC_KEY "WireGuard exit peer public key" "$WG_PEER_PUBLIC_KEY" 0
  prompt_value WG_ENDPOINT "WireGuard endpoint host:port" "${WG_ENDPOINT:-203.0.113.10:51820}" 0
  prompt_value WG_ALLOWED_IPS "WireGuard AllowedIPs" "${WG_ALLOWED_IPS:-0.0.0.0/0}" 0
  prompt_value WG_PERSISTENT_KEEPALIVE "WireGuard PersistentKeepalive" "${WG_PERSISTENT_KEEPALIVE:-25}" 0
  prompt_value TELEMT_NAT_IP "Telemt NAT IP, usually WG exit IP, empty = derive/detect" "$TELEMT_NAT_IP" 0
  prompt_value SSH_PORT "SSH port" "${SSH_PORT:-122}" 0
  prompt_value ASSUME_YES "Skip final YES confirmation? 1/0" "${ASSUME_YES:-0}" 0
  prompt_value ALLOW_DNS_MISMATCH "Allow DNS mismatch? 1/0" "${ALLOW_DNS_MISMATCH:-0}" 0
  prompt_value REQUIRE_WG_HANDSHAKE "Require WG handshake before continuing? 1/0" "${REQUIRE_WG_HANDSHAKE:-1}" 0
  save_config_file
}

need_root
if needs_interactive_config; then
  interactive_config
fi
require_var PUBLIC_HOST
require_var WG_ADDRESS
require_var WG_PEER_PUBLIC_KEY
require_var WG_ENDPOINT
[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "PUBLIC_HOST must be a plain DNS name."
[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH_PORT must be numeric."
[[ "$TELEMT_MAX_TCP_CONNS" =~ ^[0-9]+$ ]] || die "TELEMT_MAX_TCP_CONNS must be numeric."
detect_public_ip

GENERATED_SECRET=0
GENERATED_WG_PRIVATE_KEY=0

if [[ -z "$TELEMT_NAT_IP" ]]; then
  TELEMT_NAT_IP="$(host_from_endpoint "$WG_ENDPOINT")"
fi

BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"

step "Preflight"
echo "script_version=$SCRIPT_VERSION"
echo "public_host=$PUBLIC_HOST"
echo "public_ip=$PUBLIC_IP"
echo "telemt_image=$TELEMT_IMAGE"
echo "telemt_max_tcp_conns=$TELEMT_MAX_TCP_CONNS"
echo "wg_endpoint=$WG_ENDPOINT"
echo "telemt_nat_ip=$TELEMT_NAT_IP"

resolved_ips="$(resolve_ipv4 "$PUBLIC_HOST" | tr '\n' ' ')"
echo "dns_ipv4=$resolved_ips"
if ! printf ' %s ' "$resolved_ips" | grep -q " $PUBLIC_IP "; then
  if [[ "$ALLOW_DNS_MISMATCH" != "1" ]]; then
    die "DNS for $PUBLIC_HOST does not include $PUBLIC_IP. Point DNS first or set ALLOW_DNS_MISMATCH=1."
  fi
  echo "warning: DNS mismatch allowed by ALLOW_DNS_MISMATCH=1"
fi

confirm

step "Backup existing files"
backup_path /opt/telemt-config
backup_path /etc/nginx/modules-enabled/60-stream-sni.conf
backup_path /etc/nginx/sites-available/"$PUBLIC_HOST"
backup_path /etc/nginx/sites-enabled/"$PUBLIC_HOST"
backup_path /etc/wireguard/"$WG_IF".conf
backup_path /etc/nftables-local-hardening.conf
backup_path /etc/systemd/system/local-hardening-nft.service
backup_path /etc/fail2ban/jail.d/sshd.local
backup_path /etc/ssh/sshd_config
backup_path /etc/ssh/sshd_config.d/00password.conf
echo "backup_dir=$BACKUP_DIR"

step "Install packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
  ca-certificates curl gnupg openssl iproute2 nftables \
  nginx libnginx-mod-stream certbot \
  docker.io docker-compose-plugin \
  wireguard-tools
systemctl enable --now docker

if [[ -z "$WG_PRIVATE_KEY" ]]; then
  WG_PRIVATE_KEY="$(wg genkey)"
  GENERATED_WG_PRIVATE_KEY=1
  generated_wg_public_key="$(printf '%s' "$WG_PRIVATE_KEY" | wg pubkey)"
  write_wg_exit_instructions "$generated_wg_public_key"
  if [[ -n "$CONFIG_FILE" ]]; then
    save_config_file
  fi
  echo "Generated WireGuard public key to add on the exit peer: $generated_wg_public_key"
  echo "Exit-server instructions saved: /root/wg-exit-add-peer.txt"
  if [[ "$REQUIRE_WG_HANDSHAKE" == "1" && -t 0 ]]; then
    echo
    echo "Add this public key to the WireGuard exit peer now, then press Enter."
    echo "If you cannot add it yet, press Ctrl+C and rerun later with the saved telemt-clone.env."
    read -r _
  fi
else
  write_wg_exit_instructions "$(printf '%s' "$WG_PRIVATE_KEY" | wg pubkey)"
fi

if [[ -z "$TELEMT_SECRET" ]]; then
  TELEMT_SECRET="$(openssl rand -hex 16 2>/dev/null || true)"
  [[ -n "$TELEMT_SECRET" ]] || die "Could not generate TELEMT_SECRET."
  GENERATED_SECRET=1
  if [[ -n "$CONFIG_FILE" ]]; then
    save_config_file
  fi
fi

step "Configure SSH settings"
if grep -Eq '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
  sed -i -E "s/^[#[:space:]]*Port[[:space:]]+.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
else
  printf '\nPort %s\n' "$SSH_PORT" >> /etc/ssh/sshd_config
fi

if [[ "${SSH_KEY_ONLY_LOGIN,,}" == "yes" || "${SSH_KEY_ONLY_LOGIN,,}" == "y" ]]; then
  root_authorized_key_exists || die "SSH_KEY_ONLY_LOGIN=yes requested, but /root/.ssh/authorized_keys has no supported public key."
  [[ "${SSH_KEY_ONLY_CONFIRM,,}" == "yes" || "${SSH_KEY_ONLY_CONFIRM,,}" == "y" ]] || die "Set SSH_KEY_ONLY_CONFIRM=yes to confirm disabling SSH password login."
  write_file_root /etc/ssh/sshd_config.d/00password.conf 0644 root:root <<EOF
# Managed by Telemt installer when SSH_KEY_ONLY_LOGIN=yes.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
EOF
else
  remove_installer_key_only_config_if_present
  echo "SSH password login was left enabled/unchanged."
fi
sshd -t
systemctl restart ssh || systemctl restart sshd

if [[ "${ENABLE_FAIL2BAN,,}" == "yes" || "${ENABLE_FAIL2BAN,,}" == "y" ]]; then
  step "Configure fail2ban"
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y fail2ban
  write_file_root /etc/fail2ban/jail.d/defaults-debian.conf 0644 root:root <<'EOF'
[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]

[sshd]
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
enabled = true
EOF
  write_file_root /etc/fail2ban/jail.d/sshd.local 0644 root:root <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 4
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
else
  step "Configure fail2ban (skipped)"
  echo "fail2ban was left unchanged."
fi

step "Configure local nft hardening"
write_file_root /etc/nftables-local-hardening.conf 0755 root:root <<'EOF'
#!/usr/sbin/nft -f

destroy table inet local_hardening

table inet local_hardening {
    chain input {
        type filter hook input priority -10; policy accept;
        iifname "lo" accept
        tcp dport 9091 drop
    }
}
EOF
write_file_root /etc/systemd/system/local-hardening-nft.service 0644 root:root <<'EOF'
[Unit]
Description=Local nftables hardening rules
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables-local-hardening.conf
ExecReload=/usr/sbin/nft -f /etc/nftables-local-hardening.conf
ExecStop=/usr/sbin/nft delete table inet local_hardening

[Install]
WantedBy=sysinit.target
EOF
systemctl daemon-reload
systemctl disable --now nftables 2>/dev/null || true
systemctl enable --now local-hardening-nft

step "Configure WireGuard"
install -d -m 0700 /etc/wireguard
write_file_root /etc/wireguard/"$WG_IF".conf 0600 root:root <<EOF
[Interface]
PrivateKey = ${WG_PRIVATE_KEY}
Address = ${WG_ADDRESS}

# Keep SSH replies on the main public route while default traffic goes through WG.
PostUp = ip rule add from ${PUBLIC_IP} table main 2>/dev/null || true
PostDown = ip rule delete from ${PUBLIC_IP} table main 2>/dev/null || true

[Peer]
PublicKey = ${WG_PEER_PUBLIC_KEY}
Endpoint = ${WG_ENDPOINT}
AllowedIPs = ${WG_ALLOWED_IPS}
PersistentKeepalive = ${WG_PERSISTENT_KEEPALIVE}
EOF
systemctl enable --now wg-quick@"$WG_IF"
sleep 3
wg show "$WG_IF" || true
if [[ "$REQUIRE_WG_HANDSHAKE" == "1" ]]; then
  if ! wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '{if ($2 > 0) ok=1} END{exit ok?0:1}'; then
    die "WireGuard handshake is missing. Add this server as a peer on the WG exit and rerun. Public key: $(printf '%s' "$WG_PRIVATE_KEY" | wg pubkey)"
  fi
fi

if [[ "$TELEMT_NAT_IP" == "$WG_ENDPOINT" || "$TELEMT_NAT_IP" == *:* ]]; then
  TELEMT_NAT_IP="$(host_from_endpoint "$WG_ENDPOINT")"
fi
if ! printf '%s' "$TELEMT_NAT_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  resolved_nat="$(resolve_ipv4 "$TELEMT_NAT_IP" | head -n 1 || true)"
  [[ -n "$resolved_nat" ]] && TELEMT_NAT_IP="$resolved_nat"
fi
if ! printf '%s' "$TELEMT_NAT_IP" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
  detected_exit="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  [[ -n "$detected_exit" ]] && TELEMT_NAT_IP="$detected_exit"
fi
echo "telemt_nat_ip_final=$TELEMT_NAT_IP"

step "Issue Let's Encrypt certificate"
systemctl stop nginx 2>/dev/null || true
certbot_args=(certonly --standalone --non-interactive --agree-tos --keep-until-expiring --preferred-challenges http -d "$PUBLIC_HOST")
if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
  certbot_args+=(--email "$LETSENCRYPT_EMAIL")
else
  certbot_args+=(--register-unsafely-without-email)
fi
certbot "${certbot_args[@]}"

step "Configure nginx mask site and SNI stream"
rm -f /etc/nginx/sites-enabled/default
install -d -m 0755 /var/www/"$PUBLIC_HOST"
write_file_root /var/www/"$PUBLIC_HOST"/index.html 0644 root:root <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>NetNum</title>
  <style>
    :root { color-scheme: light dark; }
    body { margin: 0; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: #f6f7f9; color: #1d2733; }
    main { min-height: 100vh; display: grid; place-items: center; padding: 32px; box-sizing: border-box; }
    section { width: min(720px, 100%); }
    h1 { margin: 0 0 14px; font-size: clamp(32px, 6vw, 56px); font-weight: 650; letter-spacing: 0; }
    p { margin: 0 0 18px; font-size: 18px; line-height: 1.55; color: #52606d; }
    .meta { display: flex; gap: 12px; flex-wrap: wrap; margin-top: 30px; font-size: 14px; color: #6b7785; }
    .meta span { border: 1px solid #d9dee5; border-radius: 6px; padding: 8px 10px; background: #fff; }
    @media (prefers-color-scheme: dark) {
      body { background: #11161c; color: #edf2f7; }
      p { color: #a9b4c0; }
      .meta { color: #9aa7b4; }
      .meta span { background: #171f28; border-color: #2a3542; }
    }
  </style>
</head>
<body>
  <main>
    <section>
      <h1>NetNum</h1>
      <p>Digital infrastructure, network diagnostics, and private systems maintenance.</p>
      <p>For service requests, scheduled access, or operational questions, contact your project administrator.</p>
      <div class="meta">
        <span>${PUBLIC_HOST}</span>
        <span>HTTPS enabled</span>
        <span>2026</span>
      </div>
    </section>
  </main>
</body>
</html>
EOF

write_file_root /etc/nginx/sites-available/"$PUBLIC_HOST" 0644 root:root <<EOF
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name ${PUBLIC_HOST};

    root /var/www/${PUBLIC_HOST};
    index index.html;

    ssl_certificate /etc/letsencrypt/live/${PUBLIC_HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PUBLIC_HOST}/privkey.pem;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
ln -sfn /etc/nginx/sites-available/"$PUBLIC_HOST" /etc/nginx/sites-enabled/"$PUBLIC_HOST"

write_file_root /etc/nginx/modules-enabled/60-stream-sni.conf 0644 root:root <<EOF
stream {
    map \$ssl_preread_server_name \$telemt_backend {
        ${PUBLIC_HOST} 127.0.0.1:1443;
        default       127.0.0.1:8443;
    }

    server {
        listen 443;
        proxy_pass \$telemt_backend;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 24h;
    }
}
EOF
nginx -t
systemctl enable --now nginx
systemctl restart nginx

step "Configure Telemt"
install -d -m 0700 -o 65532 -g 65532 /opt/telemt-config
write_file_root /opt/telemt-config/telemt.toml 0600 65532:65532 <<EOF
show_link = []

[general]
fast_mode = true
use_middle_proxy = true
middle_proxy_nat_ip = "${TELEMT_NAT_IP}"

[general.links]
show = []
public_host = "${PUBLIC_HOST}"
public_port = 443

[general.modes]
classic = false
secure = false
tls = true

[network]
ipv4 = true
ipv6 = false
prefer = 4

[server]
port = 1443
listen_addr_ipv4 = "127.0.0.1"
listen_addr_ipv6 = "::1"
proxy_protocol = false

[server.api]
enabled = true
listen = "127.0.0.1:9091"
read_only = true

[[server.listeners]]
ip = "127.0.0.1"
announce = "${PUBLIC_IP}"

[censorship]
tls_domain = "${PUBLIC_HOST}"
mask = true
mask_host = "127.0.0.1"
mask_port = 8443
tls_emulation = true
tls_front_dir = "tlsfront"
tls_full_cert_ttl_secs = 0
alpn_enforce = true

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
default = "${TELEMT_SECRET}"

[access.user_max_tcp_conns]
default = ${TELEMT_MAX_TCP_CONNS}
EOF

write_file_root /opt/telemt-config/docker-compose.yml 0644 root:root <<EOF
services:
  telemt:
    image: ${TELEMT_IMAGE}
    container_name: telemt
    restart: unless-stopped
    network_mode: host
    user: "65532:65532"
    environment:
      RUST_LOG: "info"
    volumes:
      - /opt/telemt-config:/etc/telemt:ro
    command: ["/etc/telemt/telemt.toml"]
    security_opt:
      - no-new-privileges=true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    pids_limit: 64
    mem_limit: 256m
    cpus: "0.50"
EOF
cd /opt/telemt-config
docker compose pull
docker compose up -d

step "Install telemt-report"
write_file_root /usr/local/sbin/telemt-report 0700 root:root <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SINCE="${1:-5m}"
TOP_N="${TOP_N:-20}"
API_URL="${API_URL:-http://127.0.0.1:9091}"
CONTAINER="${CONTAINER:-telemt}"
WG_IF="${WG_IF:-wg0}"
tmp_clients="$(mktemp)"
trap 'rm -f "$tmp_clients"' EXIT
have(){ command -v "$1" >/dev/null 2>&1; }
section(){ printf '\n=== %s ===\n' "$1"; }
bytes_human(){ if have numfmt; then numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; else printf '%sB' "${1:-0}"; fi; }
api_get(){ curl -fsS --max-time 3 "${API_URL}$1" 2>/dev/null || true; }
service_state(){ systemctl is-active "$1" 2>/dev/null || printf 'unknown'; }
count_recent_logs(){ docker logs --since "$SINCE" "$CONTAINER" 2>&1 | grep -Ec "$1" || true; }
json_s(){ printf '%s' "$1" | grep -oE "\"$2\":\"[^\"]*\"" | head -n 1 | sed -E "s/^\"$2\":\"(.*)\"$/\\1/"; }
json_n(){ v="$(printf '%s' "$1" | grep -oE "\"$2\":(null|[0-9]+)" | head -n 1 | sed -E "s/^\"$2\"://")"; [ -n "$v" ] && printf '%s' "$v" || printf null; }
peer_ip_from_ss(){ awk '{peer=$4; sub(/^\[/,"",peer); sub(/\]:[0-9]+$/,"",peer); sub(/:[0-9]+$/,"",peer); if(peer!="") print peer}'; }
section "SUMMARY"
printf 'time:          %s\n' "$(date -Is)"
printf 'host:          %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'kernel:        %s\n' "$(uname -srmo)"
printf 'uptime:        %s\n' "$(uptime | sed 's/^ //')"
telemt_running=no
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then telemt_running="$(docker inspect "$CONTAINER" --format '{{if .State.Running}}yes{{else}}no{{end}}' 2>/dev/null || printf no)"; fi
api_users="$(api_get /v1/users)"
api_ok=no; printf '%s' "$api_users" | grep -q '"ok":true' && api_ok=yes
listener_443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}' && printf yes || printf no)"
listener_1443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:1443$/ {found=1} END{exit !found}' && printf yes || printf no)"
ss -H -ant state established 'sport = :443' 2>/dev/null | peer_ip_from_ss > "$tmp_clients"
conn_443="$(wc -l < "$tmp_clients" | tr -d ' ')"
uniq_443="$(sort -u "$tmp_clients" | grep -c . || true)"
limit_errors="$(count_recent_logs 'User limit|exceeded connection limit')"
me_errors="$(count_recent_logs 'ME pool is NOT ready|ME pool is not ready|All ME servers|Upstream failed')"
status=OK
reasons=()
[ "$telemt_running" = yes ] || { status=BAD; reasons+=("telemt container is not running"); }
[ "$api_ok" = yes ] || { status=BAD; reasons+=("telemt API is not reachable"); }
[ "$listener_443" = yes ] || { status=BAD; reasons+=("external 443 listener is missing"); }
[ "$listener_1443" = yes ] || { status=BAD; reasons+=("telemt backend 1443 listener is missing"); }
[ "$limit_errors" = 0 ] || reasons+=("recent user limit errors: $limit_errors")
[ "$me_errors" = 0 ] || reasons+=("recent ME/upstream warnings: $me_errors")
printf 'health:        %s\n' "$status"
printf 'telemt:        running=%s api=%s backend_1443=%s\n' "$telemt_running" "$api_ok" "$listener_1443"
printf 'front door:    listener_443=%s established_443=%s unique_peer_ips=%s\n' "$listener_443" "$conn_443" "$uniq_443"
if [ "${#reasons[@]}" -gt 0 ]; then printf 'notes:\n'; for r in "${reasons[@]}"; do printf '  - %s\n' "$r"; done; fi
section "TELEMT USERS"
if [ "$api_ok" = yes ]; then
  if have jq; then
    printf '%s\n' "$api_users" | jq -r '.data[] | [.username,(.current_connections|tostring),((.max_tcp_conns//"unlimited")|tostring),(.active_unique_ips//0|tostring),(.recent_unique_ips//0|tostring),(.total_octets//0|tostring)] | @tsv' |
      while IFS=$'\t' read -r u c m a r o; do printf '%-18s connections=%s/%s api_active_ips=%s api_recent_ips=%s traffic=%s\n' "$u" "$c" "$m" "$a" "$r" "$(bytes_human "$o")"; done
  else
    payload="$(printf '%s' "$api_users" | sed -E 's/^\{"ok":true,"data":\[//; s/\],"revision":.*$//; s/\},\{/\}\n\{/g')"
    printf '%s\n' "$payload" | while IFS= read -r j; do
      [ -n "$j" ] || continue
      u="$(json_s "$j" username)"; c="$(json_n "$j" current_connections)"; m="$(json_n "$j" max_tcp_conns)"
      a="$(json_n "$j" active_unique_ips)"; r="$(json_n "$j" recent_unique_ips)"; o="$(json_n "$j" total_octets)"
      [ "$m" = null ] && m=unlimited; [ "$o" = null ] && o=0
      printf '%-18s connections=%s/%s api_active_ips=%s api_recent_ips=%s traffic=%s\n' "${u:-unknown}" "$c" "$m" "$a" "$r" "$(bytes_human "$o")"
    done
  fi
else
  printf 'Telemt API is not reachable at %s/v1/users\n' "$API_URL"
fi
section "CLIENT PEER IPS ON TCP/443"
printf 'total_established_443_connections: %s\nunique_peer_ips: %s\ntop_peer_ips:\n' "$conn_443" "$uniq_443"
if [ "$conn_443" -gt 0 ]; then sort "$tmp_clients" | uniq -c | sort -nr | head -n "$TOP_N" | awk '{printf "  %6s  %s\n",$1,$2}'; else printf '  none\n'; fi
printf '\nNote: Telemt API sees 127.0.0.1 because nginx stream proxies traffic locally.\n'
section "WIREGUARD"
if have wg && wg show "$WG_IF" >/dev/null 2>&1; then wg show "$WG_IF"; printf '\nroute_to_telegram_test:\n'; ip route get 149.154.167.51 2>/dev/null || true; if timeout 4 bash -c '</dev/tcp/149.154.167.51/443' 2>/dev/null; then echo 'tcp_149.154.167.51_443: OK'; else echo 'tcp_149.154.167.51_443: FAIL'; fi; else printf 'wg/interface missing\n'; fi
section "SERVICES AND PORTS"
for svc in nginx docker "wg-quick@${WG_IF}" fail2ban local-hardening-nft; do printf '%-24s %s\n' "$svc" "$(service_state "$svc")"; done
printf '\nlistening_ports:\n'; ss -lntp 2>/dev/null | grep -E ':(443|1443|9091|122)\b' || printf 'no expected listeners found\n'
section "DOCKER TELEMT"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then docker inspect "$CONTAINER" --format 'name={{.Name}} image={{.Config.Image}} user={{.Config.User}} running={{.State.Running}} status={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}} readonly={{.HostConfig.ReadonlyRootfs}} network={{.HostConfig.NetworkMode}}'; fi
section "SERVER RESOURCES"
free -m 2>/dev/null | awk 'NR<=2{print}'; df -h / /var /opt 2>/dev/null | awk '!seen[$0]++'; printf '\nnetwork_interfaces:\n'; ip -br addr 2>/dev/null || true
section "RECENT TELEMT WARNINGS"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then docker logs --since "$SINCE" "$CONTAINER" 2>&1 | grep -E 'User limit|exceeded connection limit|ME pool is NOT ready|ME pool is not ready|All ME servers|Upstream failed|ERROR|WARN' | tail -n 80 || printf 'no relevant warnings in last %s\n' "$SINCE"; fi
EOF

step "Validation"
sleep 20
systemctl --no-pager --full status nginx docker wg-quick@"$WG_IF" fail2ban local-hardening-nft >/dev/null || true
ss -lntp | grep -E ':(443|1443|9091|122)\b' || true
curl -fsS http://127.0.0.1:9091/v1/users >/tmp/telemt-users.json
grep -q '"ok":true' /tmp/telemt-users.json
grep -o 'tg://proxy[^"]*' /tmp/telemt-users.json > /root/telemt-proxy-link.txt || true
chmod 600 /root/telemt-proxy-link.txt 2>/dev/null || true
curl -kIs --resolve "${PUBLIC_HOST}:443:${PUBLIC_IP}" "https://${PUBLIC_HOST}/" | head -n 12 || true
/usr/local/sbin/telemt-report 2m || true
if [[ -n "$CONFIG_FILE" ]]; then
  save_config_file
fi

step "Done"
cat <<EOF
Installed.

Proxy host: ${PUBLIC_HOST}:443
Telemt limit: ${TELEMT_MAX_TCP_CONNS}
Report command: telemt-report
Full proxy link saved on the server: /root/telemt-proxy-link.txt
Backups: ${BACKUP_DIR}

Important:
- Do not run old and new servers with the same WireGuard private key/address.
- If WG handshake failed, add this server as a peer on the WG exit and rerun.
- New SSH port is ${SSH_PORT}; keep this session open until you verify a second login.
EOF

if [[ "$GENERATED_SECRET" == "1" ]]; then
  cat > /root/telemt-generated-secret.txt <<EOF
TELEMT_SECRET=${TELEMT_SECRET}
EOF
  chmod 600 /root/telemt-generated-secret.txt
  echo "Generated Telemt secret saved: /root/telemt-generated-secret.txt"
fi

if [[ "$GENERATED_WG_PRIVATE_KEY" == "1" ]]; then
  cat > /root/wg-generated-key.txt <<EOF
WG_PRIVATE_KEY=${WG_PRIVATE_KEY}
WG_PUBLIC_KEY=$(printf '%s' "$WG_PRIVATE_KEY" | wg pubkey)
EOF
  chmod 600 /root/wg-generated-key.txt
  echo "Generated WireGuard key saved: /root/wg-generated-key.txt"
fi
