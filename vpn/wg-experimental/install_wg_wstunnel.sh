#!/usr/bin/env bash
set -Eeuo pipefail

# Experimental WireGuard over wstunnel installer for Debian/Ubuntu.
# Server side:
#   Browser/curl -> https://domain/        -> nginx mask site
#   wstunnel     -> wss://domain/<secret>  -> nginx -> local wstunnel -> local WireGuard UDP
#
# Client side:
#   WireGuard profile endpoint is localhost:51820.
#   wstunnel client must run locally before WireGuard is enabled.

MASK_DOMAIN="${MASK_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
WG_IFACE="${WG_IFACE:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_SUBNET="${WG_SUBNET:-10.77.77.0/24}"
WG_SERVER_IP="${WG_SERVER_IP:-10.77.77.1}"
WG_DNS="${WG_DNS:-1.1.1.1,8.8.8.8}"
CLIENT_NAME="${CLIENT_NAME:-}"
CLIENT_ENDPOINT_HOST="${CLIENT_ENDPOINT_HOST:-127.0.0.1}"
CLIENT_ENDPOINT_PORT="${CLIENT_ENDPOINT_PORT:-51820}"
CLIENT_MTU="${CLIENT_MTU:-1300}"
WSTUNNEL_BACKEND_PORT="${WSTUNNEL_BACKEND_PORT:-12780}"
WSTUNNEL_PATH="${WSTUNNEL_PATH:-}"
ENABLE_NGINX_LOGS="${ENABLE_NGINX_LOGS:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
INSTALL_RETRIES="${INSTALL_RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-5}"

WG_DIR="/etc/wireguard"
CLIENT_DIR="$WG_DIR/clients"
CLIENT_OUT_DIR="/root/wg-clients"
MASK_ROOT_BASE="/var/www"
ENV_FILE="$WG_DIR/wgctl.env"
CTL_PATH="/usr/local/sbin/wgctl"
WSTUNNEL_BIN="/usr/local/bin/wstunnel"
WSTUNNEL_SERVICE="/etc/systemd/system/wstunnel-wg.service"
STATE_FILE="/root/.install_wg_wstunnel.state"
RESUME_CONFIG="/root/.install_wg_wstunnel.config"
CONFIG_HASH_FILE="/root/.install_wg_wstunnel.config.sha256"
BACKUP_ROOT="/root/wg-wstunnel-install-backups"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

step_no=0
BACKUP_DIR=""
SERVER_PUBLIC_IPV4=""

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

retry_command() {
  local label="$1"
  local attempt=1
  local rc=0
  shift

  while (( attempt <= INSTALL_RETRIES )); do
    if "$@"; then
      return 0
    fi
    rc=$?
    if (( attempt >= INSTALL_RETRIES )); then
      echo "ERROR: ${label} failed after ${INSTALL_RETRIES} attempts." >&2
      return "$rc"
    fi
    echo "WARN: ${label} failed with exit code ${rc}. Retrying in ${RETRY_DELAY_SECONDS}s (${attempt}/${INSTALL_RETRIES})..." >&2
    sleep "$RETRY_DELAY_SECONDS"
    attempt=$((attempt + 1))
  done
  return "$rc"
}

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

prompt() {
  local var_name="$1"
  local label="$2"
  local default="$3"
  local value

  if [[ -n "${!var_name:-}" ]]; then
    printf '%s [%s]: ' "$label" "${!var_name}"
  elif [[ -n "$default" ]]; then
    printf '%s [%s]: ' "$label" "$default"
  else
    printf '%s: ' "$label"
  fi
  read -r value
  value="$(trim_value "$value")"
  if [[ -z "$value" ]]; then
    value="${!var_name:-$default}"
  fi
  printf -v "$var_name" '%s' "$value"
}

confirm() {
  local prompt_text="$1"
  local answer
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  printf '%s' "$prompt_text"
  read -r answer
  answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

step_done() {
  [[ -f "$STATE_FILE" ]] && grep -Fxq "$1" "$STATE_FILE"
}

mark_done() {
  local id="$1"
  touch "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  grep -Fxq "$id" "$STATE_FILE" 2>/dev/null || echo "$id" >> "$STATE_FILE"
}

run_step() {
  local id="$1"
  local title="$2"
  shift 2
  if step_done "$id"; then
    step "$title (already done)"
    return 0
  fi
  step "$title"
  "$@"
  mark_done "$id"
}

save_resume_config() {
  umask 077
  cat > "$RESUME_CONFIG" <<EOF
MASK_DOMAIN=$(printf '%q' "$MASK_DOMAIN")
LETSENCRYPT_EMAIL=$(printf '%q' "$LETSENCRYPT_EMAIL")
WG_IFACE=$(printf '%q' "$WG_IFACE")
WG_PORT=$(printf '%q' "$WG_PORT")
WG_SUBNET=$(printf '%q' "$WG_SUBNET")
WG_SERVER_IP=$(printf '%q' "$WG_SERVER_IP")
WG_DNS=$(printf '%q' "$WG_DNS")
CLIENT_NAME=$(printf '%q' "$CLIENT_NAME")
CLIENT_ENDPOINT_HOST=$(printf '%q' "$CLIENT_ENDPOINT_HOST")
CLIENT_ENDPOINT_PORT=$(printf '%q' "$CLIENT_ENDPOINT_PORT")
CLIENT_MTU=$(printf '%q' "$CLIENT_MTU")
WSTUNNEL_BACKEND_PORT=$(printf '%q' "$WSTUNNEL_BACKEND_PORT")
WSTUNNEL_PATH=$(printf '%q' "$WSTUNNEL_PATH")
ENABLE_NGINX_LOGS=$(printf '%q' "$ENABLE_NGINX_LOGS")
ASSUME_YES=$(printf '%q' "$ASSUME_YES")
INSTALL_RETRIES=$(printf '%q' "$INSTALL_RETRIES")
RETRY_DELAY_SECONDS=$(printf '%q' "$RETRY_DELAY_SECONDS")
EOF
}

load_resume_config() {
  if [[ "${RESET_INSTALL_STATE:-0}" == "1" ]]; then
    rm -f "$STATE_FILE" "$RESUME_CONFIG" "$CONFIG_HASH_FILE"
  fi
  if [[ -f "$RESUME_CONFIG" ]]; then
    echo "Resume config found: $RESUME_CONFIG"
    # shellcheck disable=SC1090
    . "$RESUME_CONFIG"
  fi
}

file_sha256() {
  if have sha256sum; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

reset_step_state_if_config_changed() {
  local current old
  [[ -f "$RESUME_CONFIG" ]] || return 0
  current="$(file_sha256 "$RESUME_CONFIG")"
  old="$(cat "$CONFIG_HASH_FILE" 2>/dev/null || true)"
  if [[ -f "$STATE_FILE" && ( -z "$old" || "$old" != "$current" ) ]]; then
    echo "Config changed since previous run; clearing completed-step state."
    rm -f "$STATE_FILE"
  fi
  printf '%s\n' "$current" > "$CONFIG_HASH_FILE"
  chmod 600 "$CONFIG_HASH_FILE"
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9._@-]{1,64}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_ipv4() {
  local ip="$1"
  local a b c d part
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for part in "$a" "$b" "$c" "$d"; do
    [[ "$part" =~ ^[0-9]+$ ]] && (( part >= 0 && part <= 255 )) || return 1
  done
}

valid_cidr() {
  local net="${1%/*}"
  local prefix="${1#*/}"
  valid_ipv4 "$net" || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] && (( prefix >= 8 && prefix <= 30 ))
}

valid_domain() {
  [[ "$1" =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$ ]]
}

valid_email() {
  [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$ ]]
}

valid_dns_list() {
  local item
  IFS=, read -ra items <<< "$1"
  ((${#items[@]} > 0)) || return 1
  for item in "${items[@]}"; do
    item="$(trim_value "$item")"
    valid_ipv4 "$item" || return 1
  done
}

bool_value() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    y|yes|true|1|on) echo 1 ;;
    n|no|false|0|off|"") echo 0 ;;
    *) return 1 ;;
  esac
}

detect_os() {
  [[ $EUID -eq 0 ]] || die "Run this script as root."
  [[ -r /etc/os-release ]] || die "Cannot detect OS."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "Only Debian/Ubuntu are supported. Detected ID=${ID:-unknown}." ;;
  esac
  have systemctl || die "systemd is required."
  have apt-get || die "apt-get is required."
}

detect_public_ipv4() {
  local detected=""
  if have curl; then
    detected="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  elif have wget; then
    detected="$(wget -4qO- --timeout=10 https://api.ipify.org || true)"
  fi
  if valid_ipv4 "$detected"; then
    SERVER_PUBLIC_IPV4="$detected"
  fi
}

resolve_domain_ipv4() {
  local domain="$1"
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}'
}

default_wstunnel_path() {
  if [[ -n "$WSTUNNEL_PATH" ]]; then
    echo "$WSTUNNEL_PATH"
  else
    printf 'ws-%s\n' "$(openssl rand -hex 8 2>/dev/null || date +%s)"
  fi
}

mask_default_email() {
  if [[ -n "$MASK_DOMAIN" ]]; then
    echo "admin@$MASK_DOMAIN"
  else
    echo ""
  fi
}

prompt_config() {
  local logs_answer mask_ip
  detect_public_ipv4 || true

  prompt MASK_DOMAIN "Mask domain with DNS A record to this server" "$MASK_DOMAIN"
  LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$(mask_default_email)}"
  prompt LETSENCRYPT_EMAIL "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
  WSTUNNEL_PATH="$(default_wstunnel_path)"
  prompt WSTUNNEL_PATH "Secret WebSocket path prefix without leading slash" "$WSTUNNEL_PATH"
  prompt WSTUNNEL_BACKEND_PORT "Local wstunnel backend TCP port" "$WSTUNNEL_BACKEND_PORT"
  prompt WG_IFACE "WireGuard interface" "$WG_IFACE"
  prompt WG_PORT "Local WireGuard UDP port on server" "$WG_PORT"
  prompt WG_SUBNET "VPN IPv4 subnet" "$WG_SUBNET"
  prompt WG_SERVER_IP "Server VPN IPv4" "$WG_SERVER_IP"
  prompt WG_DNS "Client DNS, comma separated IPv4" "$WG_DNS"
  prompt CLIENT_ENDPOINT_HOST "WireGuard endpoint host inside client config" "$CLIENT_ENDPOINT_HOST"
  prompt CLIENT_ENDPOINT_PORT "WireGuard endpoint port inside client config" "$CLIENT_ENDPOINT_PORT"
  prompt CLIENT_MTU "WireGuard client MTU" "$CLIENT_MTU"
  prompt CLIENT_NAME "First client name" "$CLIENT_NAME"
  logs_answer="$([[ "$ENABLE_NGINX_LOGS" == "1" ]] && echo yes || echo no)"
  prompt logs_answer "Enable nginx access logs for mask site? yes/no" "$logs_answer"
  ENABLE_NGINX_LOGS="$(bool_value "$logs_answer")" || die "Logs answer must be yes or no."

  valid_domain "$MASK_DOMAIN" || die "Mask domain must be a valid domain name."
  valid_email "$LETSENCRYPT_EMAIL" || die "Let's Encrypt email is invalid."
  [[ "$WSTUNNEL_PATH" =~ ^[A-Za-z0-9._~-]{4,96}$ ]] || die "Secret WebSocket path must be 4-96 safe URL chars without leading slash."
  valid_port "$WSTUNNEL_BACKEND_PORT" || die "Invalid wstunnel backend port: $WSTUNNEL_BACKEND_PORT"
  [[ "$WG_IFACE" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Invalid WireGuard interface."
  valid_port "$WG_PORT" || die "Invalid local WireGuard UDP port: $WG_PORT"
  valid_cidr "$WG_SUBNET" || die "VPN subnet must be IPv4 CIDR with prefix 8..30."
  valid_ipv4 "$WG_SERVER_IP" || die "Invalid server VPN IPv4: $WG_SERVER_IP"
  valid_dns_list "$WG_DNS" || die "DNS list must contain IPv4 addresses separated by commas."
  [[ "$CLIENT_ENDPOINT_HOST" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Invalid client endpoint host."
  valid_port "$CLIENT_ENDPOINT_PORT" || die "Invalid client endpoint port: $CLIENT_ENDPOINT_PORT"
  [[ "$CLIENT_MTU" =~ ^[0-9]+$ ]] && (( CLIENT_MTU >= 1000 && CLIENT_MTU <= 1500 )) || die "Invalid MTU: $CLIENT_MTU"
  valid_name "$CLIENT_NAME" || die "Client name must be 1-64 chars: letters, digits, dot, underscore, dash, @."

  [[ -n "$SERVER_PUBLIC_IPV4" ]] || die "Cannot detect this server public IPv4 for DNS preflight."
  mask_ip="$(resolve_domain_ipv4 "$MASK_DOMAIN" || true)"
  [[ -n "$mask_ip" ]] || die "DNS A record for $MASK_DOMAIN was not found."
  [[ "$mask_ip" == "$SERVER_PUBLIC_IPV4" ]] || die "$MASK_DOMAIN resolves to $mask_ip, but this server public IPv4 is $SERVER_PUBLIC_IPV4."

  save_resume_config
}

print_plan() {
  cat <<EOF

Install plan:
  public site:      https://${MASK_DOMAIN}/
  wstunnel path:   ${WSTUNNEL_PATH}
  wstunnel backend:127.0.0.1:${WSTUNNEL_BACKEND_PORT}
  local WG server: 127.0.0.1:${WG_PORT}/udp
  client WG target:${CLIENT_ENDPOINT_HOST}:${CLIENT_ENDPOINT_PORT}/udp
  interface:       ${WG_IFACE}
  subnet:          ${WG_SUBNET}
  server IP:       ${WG_SERVER_IP}
  client DNS:      ${WG_DNS}
  client MTU:      ${CLIENT_MTU}
  nginx logs:      $([[ "$ENABLE_NGINX_LOGS" == "1" ]] && echo yes || echo no)
  first client:    ${CLIENT_NAME}

EOF
  confirm "Type y or yes to continue: " || die "Cancelled."
}

backup_state() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  for path in "$WG_DIR" "$CTL_PATH" "$ENV_FILE" "$WSTUNNEL_SERVICE"; do
    [[ -e "$path" || -L "$path" ]] && cp -a "$path" "$BACKUP_DIR"/
  done
  echo "backup_dir=$BACKUP_DIR"
}

port_listening_tcp() {
  have ss || return 1
  ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

port_listening_udp() {
  have ss || return 1
  ss -H -lun "sport = :$1" 2>/dev/null | grep -q .
}

port_preflight() {
  if port_listening_tcp 80; then
    die "TCP port 80 is already in use. Let's Encrypt webroot flow needs port 80."
  fi
  if port_listening_tcp 443; then
    die "TCP port 443 is already in use. HTTPS mask site needs nginx on TCP 443."
  fi
  if port_listening_tcp "$WSTUNNEL_BACKEND_PORT"; then
    die "Local wstunnel backend TCP port $WSTUNNEL_BACKEND_PORT is already in use."
  fi
  if port_listening_udp "$WG_PORT"; then
    die "Local WireGuard UDP port $WG_PORT is already in use."
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  retry_command "apt-get update" apt-get update
  retry_command "apt-get install base packages" apt-get install -y \
    ca-certificates curl tar gzip wireguard-tools iproute2 iptables qrencode nginx certbot
}

download_wstunnel() {
  local api url tmp archive bin
  if [[ -x "$WSTUNNEL_BIN" ]]; then
    "$WSTUNNEL_BIN" --version || true
    return 0
  fi

  api="$(mktemp)"
  tmp="$(mktemp -d)"
  retry_command "fetch wstunnel release metadata" curl -fsSL \
    "https://api.github.com/repos/erebe/wstunnel/releases/latest" -o "$api"
  url="$(awk -F\" '/browser_download_url/ && /linux/ && /amd64/ && /\.tar\.gz/ {print $4; exit}' "$api")"
  [[ -n "$url" ]] || die "Cannot find linux amd64 wstunnel release asset."
  archive="$tmp/wstunnel.tar.gz"
  retry_command "download wstunnel" curl -fL "$url" -o "$archive"
  tar -xzf "$archive" -C "$tmp"
  bin="$(find "$tmp" -type f -name 'wstunnel' -perm -111 | head -n 1)"
  [[ -n "$bin" ]] || bin="$(find "$tmp" -type f -name 'wstunnel' | head -n 1)"
  [[ -n "$bin" ]] || die "Downloaded archive does not contain wstunnel binary."
  install -m 0755 "$bin" "$WSTUNNEL_BIN"
  rm -rf "$tmp" "$api"
  "$WSTUNNEL_BIN" --version || true
}

out_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

configure_sysctl() {
  cat > /etc/sysctl.d/99-wireguard-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

generate_server_keys() {
  install -d -m 0700 "$WG_DIR" "$CLIENT_DIR" "$CLIENT_OUT_DIR"
  if [[ ! -s "$WG_DIR/server_private.key" ]]; then
    umask 077
    wg genkey > "$WG_DIR/server_private.key"
    wg pubkey < "$WG_DIR/server_private.key" > "$WG_DIR/server_public.key"
  fi
  chmod 600 "$WG_DIR/server_private.key"
  chmod 644 "$WG_DIR/server_public.key"
}

write_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
WG_IFACE=$(printf '%q' "$WG_IFACE")
WG_PORT=$(printf '%q' "$WG_PORT")
WG_SUBNET=$(printf '%q' "$WG_SUBNET")
WG_SERVER_IP=$(printf '%q' "$WG_SERVER_IP")
WG_DNS=$(printf '%q' "$WG_DNS")
PUBLIC_ENDPOINT=$(printf '%q' "$MASK_DOMAIN")
CLIENT_ENDPOINT_HOST=$(printf '%q' "$CLIENT_ENDPOINT_HOST")
CLIENT_ENDPOINT_PORT=$(printf '%q' "$CLIENT_ENDPOINT_PORT")
CLIENT_MTU=$(printf '%q' "$CLIENT_MTU")
OBFS_MODE=wstunnel
WSTUNNEL_DOMAIN=$(printf '%q' "$MASK_DOMAIN")
WSTUNNEL_PATH=$(printf '%q' "$WSTUNNEL_PATH")
WG_DIR=$(printf '%q' "$WG_DIR")
CLIENT_DIR=$(printf '%q' "$CLIENT_DIR")
CLIENT_OUT_DIR=$(printf '%q' "$CLIENT_OUT_DIR")
EOF
}

write_wg_config() {
  local private_key
  local prefix
  local wan_iface
  private_key="$(cat "$WG_DIR/server_private.key")"
  prefix="${WG_SUBNET#*/}"
  wan_iface="$(out_iface)"
  [[ -n "$wan_iface" ]] || die "Cannot detect outbound network interface."

  umask 077
  cat > "$WG_DIR/${WG_IFACE}.conf" <<EOF
[Interface]
Address = ${WG_SERVER_IP}/${prefix}
ListenPort = ${WG_PORT}
PrivateKey = ${private_key}
SaveConfig = false
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -C FORWARD -i ${WG_IFACE} -o ${wan_iface} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${WG_IFACE} -o ${wan_iface} -j ACCEPT; iptables -C FORWARD -i ${wan_iface} -o ${WG_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${wan_iface} -o ${WG_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -C POSTROUTING -s ${WG_SUBNET} -o ${wan_iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_SUBNET} -o ${wan_iface} -j MASQUERADE; iptables -C INPUT ! -i lo -p udp --dport ${WG_PORT} -j DROP 2>/dev/null || iptables -I INPUT ! -i lo -p udp --dport ${WG_PORT} -j DROP
PostDown = iptables -D FORWARD -i ${WG_IFACE} -o ${wan_iface} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i ${wan_iface} -o ${WG_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${WG_SUBNET} -o ${wan_iface} -j MASQUERADE 2>/dev/null || true; iptables -D INPUT ! -i lo -p udp --dport ${WG_PORT} -j DROP 2>/dev/null || true
EOF
  chmod 600 "$WG_DIR/${WG_IFACE}.conf"
}

install_wgctl() {
  [[ -f "$SCRIPT_DIR/wgctl.sh" ]] || die "wgctl.sh must be next to install_wg_wstunnel.sh."
  install -m 0755 "$SCRIPT_DIR/wgctl.sh" "$CTL_PATH"
}

mask_root() {
  printf '%s/%s\n' "$MASK_ROOT_BASE" "$MASK_DOMAIN"
}

write_mask_http_config() {
  local root_dir conf
  root_dir="$(mask_root)"
  conf="/etc/nginx/sites-available/wg-wstunnel-${MASK_DOMAIN}.conf"
  install -d -m 0755 "$root_dir"
  cat > "$root_dir/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>${MASK_DOMAIN}</title>
</head>
<body>
  <h1>${MASK_DOMAIN}</h1>
</body>
</html>
EOF

  cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${MASK_DOMAIN};
    root ${root_dir};

    location ^~ /.well-known/acme-challenge/ {
        root ${root_dir};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF
  ln -sf "$conf" "/etc/nginx/sites-enabled/wg-wstunnel-${MASK_DOMAIN}.conf"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_certificate() {
  local root_dir
  root_dir="$(mask_root)"
  if [[ -r "/etc/letsencrypt/live/${MASK_DOMAIN}/fullchain.pem" ]]; then
    echo "Certificate already exists for ${MASK_DOMAIN}."
  else
    retry_command "certbot certificate issue" certbot certonly \
      --webroot -w "$root_dir" \
      -d "$MASK_DOMAIN" \
      --non-interactive --agree-tos \
      --email "$LETSENCRYPT_EMAIL"
  fi
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

acme_http01_preflight() {
  local root_dir token expected challenge_dir local_body public_body url
  root_dir="$(mask_root)"
  challenge_dir="$root_dir/.well-known/acme-challenge"
  token="wstunnel-$(openssl rand -hex 8 2>/dev/null || date +%s)"
  expected="wstunnel-acme-ok-${token}"
  install -d -m 0755 "$challenge_dir"
  printf '%s\n' "$expected" > "$challenge_dir/$token"

  local_body="$(curl -fsS --max-time 10 -H "Host: ${MASK_DOMAIN}" "http://127.0.0.1/.well-known/acme-challenge/${token}" || true)"
  if [[ "$local_body" != "$expected" ]]; then
    rm -f "$challenge_dir/$token"
    die "ACME HTTP-01 local preflight failed. nginx does not serve ${MASK_DOMAIN} challenge files from ${challenge_dir}."
  fi

  url="http://${MASK_DOMAIN}/.well-known/acme-challenge/${token}"
  if [[ -n "$SERVER_PUBLIC_IPV4" ]]; then
    public_body="$(curl -4fsS --max-time 15 --resolve "${MASK_DOMAIN}:80:${SERVER_PUBLIC_IPV4}" "$url" || true)"
  else
    public_body="$(curl -4fsS --max-time 15 "$url" || true)"
  fi
  rm -f "$challenge_dir/$token"
  [[ "$public_body" == "$expected" ]] || die "ACME HTTP-01 public IPv4 preflight failed. Check DNS A record, port 80/tcp, provider firewall, and existing nginx sites."
}

write_mask_https_config() {
  local root_dir conf access_log error_log
  root_dir="$(mask_root)"
  conf="/etc/nginx/sites-available/wg-wstunnel-${MASK_DOMAIN}.conf"
  access_log="off"
  error_log="/dev/null crit"
  if [[ "$ENABLE_NGINX_LOGS" == "1" ]]; then
    access_log="/var/log/nginx/wg-wstunnel-${MASK_DOMAIN}.access.log"
    error_log="/var/log/nginx/wg-wstunnel-${MASK_DOMAIN}.error.log warn"
  fi

  cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${MASK_DOMAIN};
    root ${root_dir};

    location ^~ /.well-known/acme-challenge/ {
        root ${root_dir};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name ${MASK_DOMAIN};
    root ${root_dir};

    access_log ${access_log};
    error_log ${error_log};

    ssl_certificate /etc/letsencrypt/live/${MASK_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MASK_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    location /${WSTUNNEL_PATH} {
        proxy_pass http://127.0.0.1:${WSTUNNEL_BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 86400;
        proxy_send_timeout 86400;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  nginx -t
  systemctl reload nginx
}

write_wstunnel_service() {
  cat > "$WSTUNNEL_SERVICE" <<EOF
[Unit]
Description=wstunnel for WireGuard over WebSocket
After=network-online.target wg-quick@${WG_IFACE}.service
Wants=network-online.target

[Service]
User=nobody
NoNewPrivileges=true
ExecStart=${WSTUNNEL_BIN} server --log-lvl=OFF --restrict-to 127.0.0.1:${WG_PORT} --restrict-http-upgrade-path-prefix "${WSTUNNEL_PATH}" ws://127.0.0.1:${WSTUNNEL_BACKEND_PORT}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

configure_firewall() {
  local wan_iface
  wan_iface="$(out_iface || true)"
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "80/tcp"
    ufw allow "443/tcp"
    if [[ -n "$wan_iface" ]]; then
      ufw route allow in on "$WG_IFACE" out on "$wan_iface" || true
    fi
  fi
}

start_services() {
  systemctl enable --now "wg-quick@${WG_IFACE}"
  systemctl enable --now wstunnel-wg.service
}

ensure_first_client() {
  if [[ -f "$CLIENT_DIR/${CLIENT_NAME}.env" ]]; then
    echo "Client already exists: $CLIENT_NAME"
  else
    "$CTL_PATH" add "$CLIENT_NAME"
  fi
}

verify_install() {
  systemctl is-active --quiet "wg-quick@${WG_IFACE}" || die "wg-quick@${WG_IFACE} is not active."
  systemctl is-active --quiet wstunnel-wg.service || die "wstunnel-wg.service is not active."
  systemctl is-active --quiet nginx || die "nginx is not active."
  wg show "$WG_IFACE" >/dev/null || die "WireGuard interface is not available."
}

main() {
  detect_os
  load_resume_config
  echo "Experimental WireGuard over wstunnel installer."
  echo
  echo "Before running:"
  echo "  1. Use a clean server. Ports 80 and 443/tcp must be free."
  echo "  2. Create DNS A record: <domain> -> this server IPv4."
  echo "  3. Client device must be able to run wstunnel locally."
  echo "  4. Keep the current SSH session open until a second login works."
  echo
  prompt_config
  reset_step_state_if_config_changed
  print_plan

  run_step "backup" "Backup current state" backup_state
  run_step "ports" "Port preflight" port_preflight
  run_step "packages" "Install packages" install_packages
  run_step "wstunnel" "Install wstunnel" download_wstunnel
  run_step "sysctl" "Enable IPv4 forwarding" configure_sysctl
  run_step "server_keys" "Generate WireGuard server keys" generate_server_keys
  run_step "env" "Write control environment" write_env
  run_step "config" "Write WireGuard config" write_wg_config
  run_step "ctl" "Install wgctl" install_wgctl
  run_step "nginx_http" "Create nginx HTTP challenge site" write_mask_http_config
  run_step "acme_preflight" "Check ACME HTTP-01 challenge path" acme_http01_preflight
  run_step "cert" "Issue Let's Encrypt certificate" issue_certificate
  run_step "nginx_https" "Create nginx HTTPS mask and wstunnel route" write_mask_https_config
  run_step "wstunnel_service" "Create wstunnel service" write_wstunnel_service
  run_step "firewall" "Open firewall ports if ufw is active" configure_firewall
  run_step "service" "Start WireGuard and wstunnel" start_services
  run_step "first_client" "Create first client" ensure_first_client
  run_step "verify" "Verify" verify_install
  mark_done "done"
  save_resume_config

  step "Done"
  cat <<EOF
Installed experimental WireGuard over wstunnel.

Public mask site:
  https://${MASK_DOMAIN}/

wstunnel endpoint:
  wss://${MASK_DOMAIN}:443/${WSTUNNEL_PATH}

WireGuard client profile:
  ${CLIENT_OUT_DIR}/${CLIENT_NAME}.conf

wstunnel client helper:
  ${CLIENT_OUT_DIR}/${CLIENT_NAME}-wstunnel-client.sh

Client order:
  1. Run the wstunnel helper on the client machine.
  2. Start WireGuard using ${CLIENT_NAME}.conf.

Manage clients:
  wgctl add
  wgctl delete
  wgctl list
  wgctl show
  wgctl qr
  wgctl traffic

Backups:
  ${BACKUP_DIR}
EOF
}

main "$@"
