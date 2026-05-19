#!/usr/bin/env bash
set -Eeuo pipefail

# Telemt installer for a fresh Debian/Ubuntu server.
# It asks for a domain, verifies DNS A -> this server IPv4 before Let's Encrypt,
# then installs nginx SNI routing + Telemt + local API firewall.
# SSH key-only login, fail2ban, and swap are opt-in prompts.

TELEMT_IMAGE_DEFAULT="whn0thacked/telemt-docker@sha256:cf9b970f2d13937328372e903e40b971e4a5319cd005930453a89a80ba2365e4"

PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_ONLY_LOGIN="${SSH_KEY_ONLY_LOGIN:-no}"
SSH_KEY_ONLY_CONFIRM="${SSH_KEY_ONLY_CONFIRM:-no}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-no}"
ADD_SWAP="${ADD_SWAP:-no}"
TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-5000}"
TELEMT_IMAGE="${TELEMT_IMAGE:-$TELEMT_IMAGE_DEFAULT}"
ASSUME_YES="${ASSUME_YES:-0}"
BACKUP_ROOT="/root/telemt-install-backups"
STATE_FILE="/root/.install_telemt.state"
RESUME_CONFIG="/root/.install_telemt.config"
NGINX_ACTIVE_AT_START="${NGINX_ACTIVE_AT_START:-}"

step_no=0
BACKUP_DIR=""

step() {
  step_no=$((step_no + 1))
  printf '\n[%02d] %s\n' "$step_no" "$1"
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

step_done() {
  [[ -f "$STATE_FILE" ]] && grep -Fxq "$1" "$STATE_FILE"
}

mark_done() {
  local id="$1"
  touch "$STATE_FILE"
  grep -Fxq "$id" "$STATE_FILE" 2>/dev/null || echo "$id" >> "$STATE_FILE"
}

save_resume_config() {
  umask 077
  cat > "$RESUME_CONFIG" <<EOF
PUBLIC_HOST=$(printf '%q' "$PUBLIC_HOST")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
LETSENCRYPT_EMAIL=$(printf '%q' "$LETSENCRYPT_EMAIL")
SSH_PORT=$(printf '%q' "$SSH_PORT")
SSH_KEY_ONLY_LOGIN=$(printf '%q' "$SSH_KEY_ONLY_LOGIN")
SSH_KEY_ONLY_CONFIRM=$(printf '%q' "$SSH_KEY_ONLY_CONFIRM")
ENABLE_FAIL2BAN=$(printf '%q' "$ENABLE_FAIL2BAN")
ADD_SWAP=$(printf '%q' "$ADD_SWAP")
TELEMT_MAX_TCP_CONNS=$(printf '%q' "$TELEMT_MAX_TCP_CONNS")
TELEMT_IMAGE=$(printf '%q' "$TELEMT_IMAGE")
BACKUP_DIR=$(printf '%q' "$BACKUP_DIR")
NGINX_ACTIVE_AT_START=$(printf '%q' "$NGINX_ACTIVE_AT_START")
EOF
  chmod 600 "$RESUME_CONFIG"
}

prompt() {
  local var="$1"
  local label="$2"
  local default_value="${3:-}"
  local answer=""
  local current_value="${!var:-}"

  if [[ "$ASSUME_YES" == "1" && -n "$current_value" ]]; then
    printf '%s: %s\n' "$label" "$current_value"
    return 0
  fi

  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value"
  else
    printf '%s: ' "$label"
  fi
  read -r answer

  if [[ -n "$answer" ]]; then
    printf -v "$var" '%s' "$answer"
  else
    printf -v "$var" '%s' "$default_value"
  fi
}

prompt_yes_no() {
  local var="$1"
  local label="$2"
  local default_value="${3:-no}"
  local value=""

  prompt "$var" "$label" "$default_value"
  value="${!var,,}"
  case "$value" in
    y|yes) printf -v "$var" '%s' "yes" ;;
    n|no|"") printf -v "$var" '%s' "no" ;;
    *) die "$label must be yes or no." ;;
  esac
}

valid_domain() {
  local domain="$1"
  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_limit() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 1000000 ))
}

is_public_ipv4() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<< "$ip"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  (( a == 10 )) && return 1
  (( a == 127 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  (( a >= 224 )) && return 1
  return 0
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

detect_public_ip() {
  local candidate=""
  if is_public_ipv4 "$PUBLIC_IP"; then
    return 0
  fi
  if have curl; then
    candidate="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if is_public_ipv4 "$candidate"; then
      PUBLIC_IP="$candidate"
      return 0
    fi
  fi
  if have ip; then
    candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
    if is_public_ipv4 "$candidate"; then
      PUBLIC_IP="$candidate"
      return 0
    fi
  fi
  die "Could not detect public IPv4. Set PUBLIC_IP explicitly after networking is ready and rerun."
}

resolve_ipv4() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

port_listening() {
  local port="$1"
  ss -H -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" {found=1} END {exit found ? 0 : 1}'
}

ensure_certbot_can_bind_http() {
  if ! port_listening 80; then
    return 0
  fi

  if [[ "$NGINX_ACTIVE_AT_START" == "0" ]]; then
    systemctl stop nginx 2>/dev/null || true
    return 0
  fi

  cat >&2 <<EOF
ERROR: port 80 is already in use by an existing service.

This installer uses certbot standalone HTTP-01 and will not stop an nginx
instance that was already active before installation.

Free port 80 temporarily, issue the certificate manually, or run on a clean VPS.
EOF
  exit 1
}

ensure_https_frontdoor_available() {
  if ! port_listening 443; then
    return 0
  fi

  if [[ -f /etc/nginx/modules-enabled/60-stream-sni.conf ]] && grep -q 'telemt_backend' /etc/nginx/modules-enabled/60-stream-sni.conf; then
    return 0
  fi

  cat >&2 <<EOF
ERROR: port 443 is already in use by an existing service.

Telemt needs nginx stream to own 443/tcp. To avoid breaking existing websites,
the installer stops here instead of replacing the current HTTPS frontend.
Move the existing site behind nginx stream manually, or use a clean server.
EOF
  exit 1
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
    return 0
  fi

  apt-get install -y docker-compose-plugin || {
    apt-get remove -y docker-buildx-plugin docker-compose-plugin || true
    dpkg --configure -a
    apt-get -f install -y
    apt-get install -y docker-compose
  }
}

configure_certbot_renewal() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post /etc/letsencrypt/renewal-hooks/deploy
  write_file_root /etc/letsencrypt/renewal-hooks/pre/stop-nginx-telemt.sh 0755 root:root <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl stop nginx
fi
EOF
  write_file_root /etc/letsencrypt/renewal-hooks/post/start-nginx-telemt.sh 0755 root:root <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1; then
  systemctl start nginx || systemctl restart nginx || true
fi
EOF
  write_file_root /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 0755 root:root <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl reload nginx || systemctl restart nginx
fi
EOF

  systemctl enable --now certbot.timer
  systemctl list-timers certbot.timer --no-pager || true
}

open_public_firewall_ports() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi

  if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=80/tcp || true
    firewall-cmd --permanent --add-port=443/tcp || true
    firewall-cmd --reload || true
  fi
}

certbot_renewal_hooks_current() {
  [[ -x /etc/letsencrypt/renewal-hooks/pre/stop-nginx-telemt.sh ]] &&
    [[ -x /etc/letsencrypt/renewal-hooks/post/start-nginx-telemt.sh ]] &&
    [[ -x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh ]]
}

nginx_http_redirect_current() {
  [[ -f /etc/nginx/sites-available/"$PUBLIC_HOST" ]] &&
    grep -Fq 'return 301 https://$host$request_uri;' /etc/nginx/sites-available/"$PUBLIC_HOST"
}

[[ "$(id -u)" -eq 0 ]] || die "Run as root."
if [[ "$(uname -s)" != "Linux" ]] || ! have apt-get || ! have systemctl; then
  cat >&2 <<'EOF'
ERROR: This installer must be run on the target Debian/Ubuntu server, not on your local computer.

Use:
  scp install_telemt.sh root@<SERVER_PUBLIC_IP>:/root/
  ssh root@<SERVER_PUBLIC_IP>
  bash /root/install_telemt.sh
EOF
  exit 1
fi

if [[ "${RESET_INSTALL_STATE:-0}" == "1" ]]; then
  rm -f "$STATE_FILE" "$RESUME_CONFIG"
fi

if [[ -f "$RESUME_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$RESUME_CONFIG"
  echo "Resume config found: $RESUME_CONFIG"
fi

if [[ -z "$NGINX_ACTIVE_AT_START" ]]; then
  if systemctl is-active --quiet nginx 2>/dev/null; then
    NGINX_ACTIVE_AT_START=1
  else
    NGINX_ACTIVE_AT_START=0
  fi
fi

cat <<'EOF'
Telemt installer.

Before running:
  1. Create DNS A record: <domain> -> this server IPv4.
  2. Make sure ports 80 and 443 are reachable from the internet.
  3. Keep the current SSH session open until a second login works.

EOF

prompt PUBLIC_HOST "Proxy domain" "$PUBLIC_HOST"
valid_domain "$PUBLIC_HOST" || die "Domain must be a valid DNS name, for example proxy.example.com."

detect_public_ip
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@${PUBLIC_HOST}}"

prompt LETSENCRYPT_EMAIL "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
prompt SSH_PORT "SSH port, Enter keeps current/default" "$SSH_PORT"
prompt_yes_no SSH_KEY_ONLY_LOGIN "Disable SSH password login and keep root key-only? yes/no" "$SSH_KEY_ONLY_LOGIN"
prompt_yes_no ENABLE_FAIL2BAN "Enable fail2ban for SSH? yes/no" "$ENABLE_FAIL2BAN"
prompt_yes_no ADD_SWAP "Add 1G swap if missing? yes/no" "$ADD_SWAP"
prompt TELEMT_MAX_TCP_CONNS "Max Telemt connections" "$TELEMT_MAX_TCP_CONNS"

[[ "$LETSENCRYPT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Email must be a plain email address."
valid_port "$SSH_PORT" || die "SSH port must be a number from 1 to 65535."
valid_limit "$TELEMT_MAX_TCP_CONNS" || die "Connection limit must be a number from 1 to 1000000."

if [[ "$SSH_KEY_ONLY_LOGIN" == "yes" ]]; then
  if ! root_authorized_key_exists; then
    cat >&2 <<'EOF'

SSH key-only login was requested, but no root SSH public key was found.

Add your public key first:
  /root/.ssh/authorized_keys

Then rerun the installer and choose SSH key-only login again.
EOF
    exit 1
  fi

  prompt_yes_no SSH_KEY_ONLY_CONFIRM "Are you sure you want to close SSH password login? yes/no" "$SSH_KEY_ONLY_CONFIRM"
  if [[ "$SSH_KEY_ONLY_CONFIRM" != "yes" ]]; then
    SSH_KEY_ONLY_LOGIN="no"
    echo "SSH password login will not be disabled."
  fi
fi

step "DNS preflight"
echo "server_public_ipv4=$PUBLIC_IP"
resolved_ips="$(resolve_ipv4 "$PUBLIC_HOST" | tr '\n' ' ')"
echo "domain_ipv4=$resolved_ips"
if have host; then
  echo "host_check:"
  host "$PUBLIC_HOST" || true
fi
if ! printf ' %s ' "$resolved_ips" | grep -q " $PUBLIC_IP "; then
  cat >&2 <<EOF

DNS check failed.

${PUBLIC_HOST} must resolve to this server IPv4 before SSL can be issued.

Expected:
  ${PUBLIC_HOST} -> ${PUBLIC_IP}

Current A records:
  ${resolved_ips:-none}

Fix DNS and rerun this script.
EOF
  exit 1
fi

cat <<EOF

Install plan:
  domain:       ${PUBLIC_HOST}
  public IPv4:  ${PUBLIC_IP}
  email:        ${LETSENCRYPT_EMAIL}
  SSH port:     ${SSH_PORT}
  SSH key-only: ${SSH_KEY_ONLY_LOGIN}
  fail2ban SSH: ${ENABLE_FAIL2BAN}
  add swap:     ${ADD_SWAP}
  Telemt limit: ${TELEMT_MAX_TCP_CONNS}

Type y or yes to continue:
EOF
if [[ "$ASSUME_YES" != "1" ]]; then
  read -r confirm
  confirm="${confirm,,}"
  case "$confirm" in
    y|yes) ;;
    *) die "Cancelled." ;;
  esac
else
  echo "ASSUME_YES=1, continuing."
fi

if [[ -z "$BACKUP_DIR" ]]; then
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
fi
save_resume_config

if step_done backup; then
  step "Backup current state (already done)"
  echo "backup_dir=$BACKUP_DIR"
else
  step "Backup current state"
  mkdir -p "$BACKUP_DIR"
  backup_path /opt/telemt-config
  backup_path /etc/nginx/modules-enabled/60-stream-sni.conf
  backup_path /etc/nginx/sites-available/"$PUBLIC_HOST"
  backup_path /etc/nginx/sites-enabled/"$PUBLIC_HOST"
  backup_path /etc/nftables-local-hardening.conf
  backup_path /etc/systemd/system/local-hardening-nft.service
  backup_path /etc/fail2ban/jail.d/sshd.local
  backup_path /etc/fail2ban/jail.d/defaults-debian.conf
  backup_path /etc/ssh/sshd_config
  backup_path /etc/ssh/sshd_config.d/00password.conf
  echo "backup_dir=$BACKUP_DIR"
  mark_done backup
fi

if [[ "$ADD_SWAP" == "yes" ]]; then
  if step_done swap; then
    step "Add 1G swap if missing (already done)"
    swapon --show || true
  else
    step "Add 1G swap if missing"
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
      if [[ ! -e /swapfile ]]; then
        fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
        chmod 600 /swapfile
        mkswap /swapfile
      fi
      swapon /swapfile || true
      grep -qE '^[^#].*[[:space:]]/swapfile[[:space:]]' /etc/fstab 2>/dev/null || \
        printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    fi
    swapon --show || true
    mark_done swap
  fi
else
  step "Add 1G swap if missing (skipped)"
  swapon --show || true
fi

if step_done packages; then
  step "Install packages (already done)"
else
  step "Install packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg openssl iproute2 nftables \
    nginx libnginx-mod-stream certbot jq
  if ! have docker; then
    apt-get install -y docker.io
  fi
  ensure_compose
  systemctl enable --now docker
  mark_done packages
fi

if step_done secret && [[ -f /root/telemt-secret.env ]]; then
  step "Prepare Telemt secret (already done)"
  # shellcheck disable=SC1091
  source /root/telemt-secret.env
else
  step "Prepare Telemt secret"
  if [[ -f /root/telemt-secret.env ]]; then
    # shellcheck disable=SC1091
    source /root/telemt-secret.env
  else
    TELEMT_SECRET="$(openssl rand -hex 16)"
    cat > /root/telemt-secret.env <<EOF
TELEMT_SECRET=${TELEMT_SECRET}
EOF
    chmod 600 /root/telemt-secret.env
  fi
  echo "secret_saved=/root/telemt-secret.env"
  mark_done secret
fi

if step_done ssh_hardening && [[ "$SSH_KEY_ONLY_LOGIN" == "yes" ]] &&
   [[ -f /etc/ssh/sshd_config.d/00password.conf ]] &&
   grep -Eq '^PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config.d/00password.conf; then
  step "Configure SSH settings (already done)"
else
  step "Configure SSH settings"
  if grep -Eq '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
    sed -i -E "s/^[#[:space:]]*Port[[:space:]]+.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
  else
    printf '\nPort %s\n' "$SSH_PORT" >> /etc/ssh/sshd_config
  fi

  if [[ "$SSH_KEY_ONLY_LOGIN" == "yes" ]]; then
    root_authorized_key_exists || die "SSH key-only login requested, but /root/.ssh/authorized_keys has no supported public key."
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
  mark_done ssh_hardening
fi

if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
  if step_done fail2ban; then
    step "Configure fail2ban (already done)"
  else
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
    mark_done fail2ban
  fi
else
  step "Configure fail2ban (skipped)"
  echo "fail2ban was left unchanged."
fi

if step_done nft_api_block; then
  step "Block external Telemt API port (already done)"
else
  step "Block external Telemt API port"
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
  systemctl enable --now local-hardening-nft
  mark_done nft_api_block
fi

if step_done firewall_public_ports; then
  step "Open public HTTP/HTTPS firewall ports (already done)"
else
  step "Open public HTTP/HTTPS firewall ports"
  open_public_firewall_ports
  mark_done firewall_public_ports
fi

if step_done certbot; then
  step "Issue Let's Encrypt certificate (already done)"
else
  step "Issue Let's Encrypt certificate"
  ensure_https_frontdoor_available
  ensure_certbot_can_bind_http
  certbot certonly --standalone --non-interactive --agree-tos --keep-until-expiring \
    --preferred-challenges http \
    --email "$LETSENCRYPT_EMAIL" \
    -d "$PUBLIC_HOST"
  mark_done certbot
fi

if step_done certbot_renewal && certbot_renewal_hooks_current; then
  step "Configure certificate auto-renewal (already done)"
else
  step "Configure certificate auto-renewal"
  configure_certbot_renewal
  mark_done certbot_renewal
fi

if step_done nginx_config && nginx_http_redirect_current; then
  step "Configure nginx mask site and SNI routing (already done)"
else
  step "Configure nginx mask site and SNI routing"
  ensure_https_frontdoor_available
  install -d -m 0755 /var/www/"$PUBLIC_HOST"
  write_file_root /var/www/"$PUBLIC_HOST"/index.html 0644 root:root <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${PUBLIC_HOST}</title>
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
      <h1>${PUBLIC_HOST}</h1>
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
    listen 80;
    listen [::]:80;
    server_name ${PUBLIC_HOST};
    access_log off;
    error_log /var/log/nginx/${PUBLIC_HOST}.error.log crit;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/${PUBLIC_HOST};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 127.0.0.1:8443 ssl;
    http2 on;
    server_name ${PUBLIC_HOST};
    access_log off;
    error_log /var/log/nginx/${PUBLIC_HOST}.error.log crit;

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
  mark_done nginx_config
fi

if step_done telemt_config; then
  step "Configure Telemt (already done)"
else
  step "Configure Telemt"
  install -d -m 0700 -o 65532 -g 65532 /opt/telemt-config
  write_file_root /opt/telemt-config/telemt.toml 0600 65532:65532 <<EOF
show_link = []

[general]
fast_mode = true
use_middle_proxy = false

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

[[upstreams]]
type = "direct"
enabled = true
weight = 10
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
      RUST_LOG: "warn"
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
    logging:
      driver: "none"
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
EOF

  cd /opt/telemt-config
  compose_cmd config >/dev/null
  compose_cmd pull
  compose_cmd up -d
  mark_done telemt_config
fi

if step_done log_hardening; then
  step "Disable access and runtime logs (already done)"
else
  step "Disable access and runtime logs"
  install -d -m 0755 /etc/nginx/conf.d
  write_file_root /etc/nginx/conf.d/00-telemt-no-access-log.conf 0644 root:root <<'EOF'
# Disable HTTP access logs for the Telemt mask site.
access_log off;
EOF
  : > /var/log/nginx/access.log 2>/dev/null || true

  if [[ -f /opt/telemt-config/docker-compose.yml ]]; then
    old_log_path="$(docker inspect telemt --format '{{.LogPath}}' 2>/dev/null || true)"
    if [[ -n "$old_log_path" && -f "$old_log_path" ]]; then
      : > "$old_log_path" 2>/dev/null || true
    fi
    write_file_root /opt/telemt-config/docker-compose.yml 0644 root:root <<EOF
services:
  telemt:
    image: ${TELEMT_IMAGE}
    container_name: telemt
    restart: unless-stopped
    network_mode: host
    user: "65532:65532"
    environment:
      RUST_LOG: "warn"
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
    logging:
      driver: "none"
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
EOF
    cd /opt/telemt-config
    compose_cmd config >/dev/null
    compose_cmd up -d --force-recreate
  fi

  nginx -t
  systemctl reload nginx || systemctl restart nginx
  mark_done log_hardening
fi

if step_done report_script; then
  step "Install telemt-report (already done)"
else
  step "Install telemt-report"
  write_file_root /usr/local/sbin/telemt-report 0700 root:root <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SINCE="${1:-5m}"
CONTAINER="${CONTAINER:-telemt}"
API_URL="${API_URL:-http://127.0.0.1:9091}"
tmp_clients="$(mktemp)"
trap 'rm -f "$tmp_clients"' EXIT
have(){ command -v "$1" >/dev/null 2>&1; }
section(){ printf '\n=== %s ===\n' "$1"; }
bytes_human(){ if have numfmt; then numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; else printf '%sB' "${1:-0}"; fi; }
api_get(){ curl -fsS --max-time 3 "${API_URL}$1" 2>/dev/null || true; }
service_state(){ systemctl is-active "$1" 2>/dev/null || printf 'unknown'; }
peer_ip_from_ss(){ awk '{peer=$4; sub(/^\[/,"",peer); sub(/\]:[0-9]+$/,"",peer); sub(/:[0-9]+$/,"",peer); if(peer!="") print peer}'; }
section "SUMMARY"
printf 'time:          %s\n' "$(date -Is)"
printf 'host:          %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'uptime:        %s\n' "$(uptime | sed 's/^ //')"
api_users="$(api_get /v1/users)"
api_ok=no; printf '%s' "$api_users" | grep -q '"ok":true' && api_ok=yes
telemt_running=no
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then telemt_running="$(docker inspect "$CONTAINER" --format '{{if .State.Running}}yes{{else}}no{{end}}' 2>/dev/null || printf no)"; fi
listener_443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}' && printf yes || printf no)"
listener_1443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:1443$/ {found=1} END{exit !found}' && printf yes || printf no)"
ss -H -ant state established 'sport = :443' 2>/dev/null | peer_ip_from_ss > "$tmp_clients"
conn_443="$(wc -l < "$tmp_clients" | tr -d ' ')"
uniq_443="$(sort -u "$tmp_clients" | grep -c . || true)"
status=OK
[ "$telemt_running" = yes ] || status=BAD
[ "$api_ok" = yes ] || status=BAD
[ "$listener_443" = yes ] || status=BAD
[ "$listener_1443" = yes ] || status=BAD
printf 'health:        %s\n' "$status"
printf 'telemt:        running=%s api=%s backend_1443=%s\n' "$telemt_running" "$api_ok" "$listener_1443"
printf 'front door:    listener_443=%s established_443=%s unique_peer_ips=%s\n' "$listener_443" "$conn_443" "$uniq_443"
section "TELEMT USERS"
if [ "$api_ok" = yes ] && have jq; then
  printf '%s\n' "$api_users" | jq -r '.data[] | [.username,(.current_connections|tostring),((.max_tcp_conns//"unlimited")|tostring),(.active_unique_ips//0|tostring),(.recent_unique_ips//0|tostring),(.total_octets//0|tostring)] | @tsv' |
  while IFS=$'\t' read -r u c m a r o; do printf '%-18s connections=%s/%s api_active_ips=%s api_recent_ips=%s traffic=%s\n' "$u" "$c" "$m" "$a" "$r" "$(bytes_human "$o")"; done
else
  printf 'Telemt API is not reachable or jq is missing\n'
fi
section "CLIENT PEER IPS ON TCP/443"
printf 'total_established_443_connections: %s\nunique_peer_ips: %s\ntop_peer_ips:\n' "$conn_443" "$uniq_443"
if [ "$conn_443" -gt 0 ]; then sort "$tmp_clients" | uniq -c | sort -nr | head -n 20 | awk '{printf "  %6s  %s\n",$1,$2}'; else printf '  none\n'; fi
section "SERVICES AND PORTS"
for svc in nginx docker fail2ban local-hardening-nft; do printf '%-24s %s\n' "$svc" "$(service_state "$svc")"; done
ssh_ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | paste -sd '|' -)"
[ -n "$ssh_ports" ] || ssh_ports="22"
printf '\nlistening_ports:\n'; ss -lntp 2>/dev/null | grep -E ":(${ssh_ports}|443|8443|1443|9091)\b" || printf 'no expected listeners found\n'
section "DOCKER TELEMT"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then docker inspect "$CONTAINER" --format 'name={{.Name}} image={{.Config.Image}} user={{.Config.User}} running={{.State.Running}} status={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}} readonly={{.HostConfig.ReadonlyRootfs}} network={{.HostConfig.NetworkMode}}'; docker stats --no-stream "$CONTAINER" || true; fi
section "SERVER RESOURCES"
free -m 2>/dev/null | awk 'NR<=3{print}'; df -h / /var /opt 2>/dev/null | awk '!seen[$0]++'
section "TELEMT CONTAINER LOGGING"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  log_driver="$(docker inspect "$CONTAINER" --format '{{.HostConfig.LogConfig.Type}}' 2>/dev/null || printf unknown)"
  printf 'docker_log_driver: %s\n' "$log_driver"
  if [ "$log_driver" = none ]; then
    printf 'runtime logs are disabled to avoid storing client activity and filling disk\n'
  else
    printf 'runtime logs are not disabled; run the installer log_hardening step again\n'
  fi
fi
EOF
  mark_done report_script
fi

step "Validation"
sleep 12
ss -lntp | grep -E ':(443|8443|1443|9091|'"${SSH_PORT}"')\b' || true
tmp_users="$(mktemp)"
chmod 600 "$tmp_users"
trap 'rm -f "$tmp_users"' EXIT
curl -fsS http://127.0.0.1:9091/v1/users > "$tmp_users"
grep -q '"ok":true' "$tmp_users"
grep -o 'tg://proxy[^"]*' "$tmp_users" > /root/telemt-proxy-link.txt || true
chmod 600 /root/telemt-proxy-link.txt 2>/dev/null || true
curl -fsSIs --resolve "${PUBLIC_HOST}:80:${PUBLIC_IP}" "http://${PUBLIC_HOST}/" | head -n 12 || true
curl -fsSIs --resolve "${PUBLIC_HOST}:443:${PUBLIC_IP}" "https://${PUBLIC_HOST}/" | head -n 12 || true
/usr/local/sbin/telemt-report 2m || true

step "Done"
cat <<EOF
Installed Telemt.

Proxy host: ${PUBLIC_HOST}:443
Telemt limit: ${TELEMT_MAX_TCP_CONNS}
Proxy link file: /root/telemt-proxy-link.txt
Secret: /root/telemt-secret.env
Backups: ${BACKUP_DIR}
SSH port: ${SSH_PORT}
EOF

if [[ -s /root/telemt-proxy-link.txt ]]; then
  echo
  echo "Proxy link:"
  cat /root/telemt-proxy-link.txt
else
  echo
  echo "Proxy link was not generated. Check:"
  echo "  curl -fsS http://127.0.0.1:9091/v1/users"
fi

cat <<EOF
Health report:
  telemt-report 5m

Important: open a second SSH session now:
  ssh -p ${SSH_PORT} root@${PUBLIC_HOST}
EOF
