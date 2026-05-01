#!/usr/bin/env bash
set -Eeuo pipefail

# Telemt installer for a fresh Debian/Ubuntu server, without WireGuard.
# It asks for a domain, verifies DNS A -> this server IPv4 before Let's Encrypt,
# then installs nginx SNI routing + Telemt + fail2ban + local API firewall.

TELEMT_IMAGE_DEFAULT="whn0thacked/telemt-docker@sha256:cf9b970f2d13937328372e903e40b971e4a5319cd005930453a89a80ba2365e4"

PUBLIC_HOST=""
PUBLIC_IP=""
LETSENCRYPT_EMAIL=""
SSH_PORT="22"
TELEMT_MAX_TCP_CONNS="1000"
TELEMT_IMAGE="$TELEMT_IMAGE_DEFAULT"
BACKUP_ROOT="/root/telemt-install-backups"
STATE_FILE="/root/.install_telemt.state"
RESUME_CONFIG="/root/.install_telemt.config"

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
TELEMT_MAX_TCP_CONNS=$(printf '%q' "$TELEMT_MAX_TCP_CONNS")
TELEMT_IMAGE=$(printf '%q' "$TELEMT_IMAGE")
BACKUP_DIR=$(printf '%q' "$BACKUP_DIR")
EOF
  chmod 600 "$RESUME_CONFIG"
}

prompt() {
  local var="$1"
  local label="$2"
  local default_value="${3:-}"
  local answer=""

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

detect_public_ip() {
  if have ip; then
    PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  fi
  if [[ -z "$PUBLIC_IP" ]] && have curl; then
    PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  fi
  [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Could not detect public IPv4. Set DNS after networking is ready and rerun."
}

resolve_ipv4() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
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
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
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

cat <<'EOF'
Telemt installer, no WireGuard.

Before running:
  1. Create DNS A record: <domain> -> this server IPv4.
  2. Make sure ports 80 and 443 are reachable from the internet.
  3. Keep the current SSH session open until a second login works.

EOF

prompt PUBLIC_HOST "Proxy domain" "$PUBLIC_HOST"
[[ "$PUBLIC_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || die "Domain must be a plain DNS name."

detect_public_ip
LETSENCRYPT_EMAIL="admin@${PUBLIC_HOST}"

prompt LETSENCRYPT_EMAIL "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
prompt SSH_PORT "SSH port, Enter keeps current/default" "$SSH_PORT"
prompt TELEMT_MAX_TCP_CONNS "Max Telemt connections" "$TELEMT_MAX_TCP_CONNS"

[[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "SSH port must be numeric."
[[ "$TELEMT_MAX_TCP_CONNS" =~ ^[0-9]+$ ]] || die "Connection limit must be numeric."

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

if [[ ! -s /root/.ssh/authorized_keys && "${ALLOW_NO_ROOT_KEY:-0}" != "1" ]]; then
  cat >&2 <<'EOF'

SSH key check failed.

This installer disables SSH password login. Add your public key to:
  /root/.ssh/authorized_keys

Then rerun the script. If you are intentionally running from a provider console,
you can override this guard:
  ALLOW_NO_ROOT_KEY=1 bash install_telemt.sh
EOF
  exit 1
fi

cat <<EOF

Install plan:
  domain:       ${PUBLIC_HOST}
  public IPv4:  ${PUBLIC_IP}
  email:        ${LETSENCRYPT_EMAIL}
  SSH port:     ${SSH_PORT}
  Telemt limit: ${TELEMT_MAX_TCP_CONNS}

Type y or yes to continue:
EOF
read -r confirm
confirm="${confirm,,}"
case "$confirm" in
  y|yes) ;;
  *) die "Cancelled." ;;
esac

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

if step_done packages; then
  step "Install packages (already done)"
else
  step "Install packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg openssl iproute2 nftables \
    nginx libnginx-mod-stream certbot fail2ban jq
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

if step_done ssh_hardening; then
  step "Configure SSH hardening (already done)"
else
  step "Configure SSH hardening"
  if grep -Eq '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
    sed -i -E "s/^[#[:space:]]*Port[[:space:]]+.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
  else
    printf '\nPort %s\n' "$SSH_PORT" >> /etc/ssh/sshd_config
  fi
  write_file_root /etc/ssh/sshd_config.d/00password.conf 0644 root:root <<EOF
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
EOF
  sshd -t
  systemctl restart ssh || systemctl restart sshd
  mark_done ssh_hardening
fi

if step_done fail2ban; then
  step "Configure fail2ban (already done)"
else
  step "Configure fail2ban"
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

if step_done certbot; then
  step "Issue Let's Encrypt certificate (already done)"
else
  step "Issue Let's Encrypt certificate"
  systemctl stop nginx 2>/dev/null || true
  certbot certonly --standalone --non-interactive --agree-tos --keep-until-expiring \
    --preferred-challenges http \
    --email "$LETSENCRYPT_EMAIL" \
    -d "$PUBLIC_HOST"
  mark_done certbot
fi

if step_done certbot_renewal; then
  step "Configure certificate auto-renewal (already done)"
else
  step "Configure certificate auto-renewal"
  configure_certbot_renewal
  mark_done certbot_renewal
fi

if step_done nginx_config; then
  step "Configure nginx mask site and SNI routing (already done)"
else
  step "Configure nginx mask site and SNI routing"
  rm -f /etc/nginx/sites-enabled/default
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
    listen 127.0.0.1:8443 ssl;
    http2 on;
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
    pids_limit: 256
    mem_limit: 256m
    cpus: "0.50"
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
EOF

  cd /opt/telemt-config
  compose_cmd pull
  compose_cmd up -d
  mark_done telemt_config
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
section "RECENT TELEMT WARNINGS"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then docker logs --since "$SINCE" "$CONTAINER" 2>&1 | grep -E 'User limit|exceeded connection limit|ME pool is NOT ready|ME pool is not ready|All ME servers|Upstream failed|ERROR|WARN' | tail -n 80 || printf 'no relevant warnings in last %s\n' "$SINCE"; fi
EOF
  mark_done report_script
fi

step "Validation"
sleep 12
ss -lntp | grep -E ':(443|8443|1443|9091|'"${SSH_PORT}"')\b' || true
curl -fsS http://127.0.0.1:9091/v1/users > /tmp/telemt-users.json
grep -q '"ok":true' /tmp/telemt-users.json
grep -o 'tg://proxy[^"]*' /tmp/telemt-users.json > /root/telemt-proxy-link.txt || true
chmod 600 /root/telemt-proxy-link.txt 2>/dev/null || true
curl -kIs --resolve "${PUBLIC_HOST}:443:${PUBLIC_IP}" "https://${PUBLIC_HOST}/" | head -n 12 || true
/usr/local/sbin/telemt-report 2m || true

step "Done"
cat <<EOF
Installed Telemt without WireGuard.

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
