#!/usr/bin/env bash
set -Eeuo pipefail

# OpenVPN installer for a fresh Debian/Ubuntu server.
# Default layout mirrors the existing production-style servers:
# TCP + UDP listeners, username/password auth, tls-crypt, dynamic NAT,
# optional TCP HTTPS camouflage through OpenVPN port-share + nginx.

PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT:-}"
OVPN_PORT="${OVPN_PORT:-50001}"
OVPN_TCP_PORT="${OVPN_TCP_PORT:-}"
OVPN_UDP_PORT="${OVPN_UDP_PORT:-}"
OVPN_TCP_CIDR="${OVPN_TCP_CIDR:-10.251.0.0/24}"
OVPN_UDP_CIDR="${OVPN_UDP_CIDR:-10.251.1.0/24}"
OVPN_DNS="${OVPN_DNS:-1.1.1.1,8.8.8.8}"
MAX_CLIENTS="${MAX_CLIENTS:-1000}"
CLIENT_NAME="${CLIENT_NAME:-}"
ENABLE_OPENVPN_LOGS="${ENABLE_OPENVPN_LOGS:-0}"
ENABLE_HTTPS_MASK="${ENABLE_HTTPS_MASK:-0}"
MASK_DOMAIN="${MASK_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
MASK_BACKEND_PORT="${MASK_BACKEND_PORT:-8443}"
ASSUME_YES="${ASSUME_YES:-0}"
INSTALL_RETRIES="${INSTALL_RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-5}"

OPENVPN_ETC="/etc/openvpn"
SERVER_DIR="/etc/openvpn/server"
EASYRSA_DIR="/etc/openvpn/easy-rsa"
CLIENT_DIR="/etc/openvpn/server/users"
CLIENT_OUT_DIR="/root/openvpn-clients"
MASK_ROOT_BASE="/var/www"
ENV_FILE="$SERVER_DIR/openvpnctl.env"
AUTH_FILE="$SERVER_DIR/auth"
AUTH_SCRIPT="$SERVER_DIR/vpn-auth.sh"
TLS_CRYPT_KEY="$SERVER_DIR/tc.key"
CTL_PATH="/usr/local/sbin/openvpnctl"
UDP_STATUS_FILE="/run/openvpn/server-udp.status"
TCP_STATUS_FILE="/run/openvpn/server-tcp.status"
STATE_FILE="/root/.install_openvpn.state"
RESUME_CONFIG="/root/.install_openvpn.config"
CONFIG_HASH_FILE="/root/.install_openvpn.config.sha256"
BACKUP_ROOT="/root/openvpn-install-backups"
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
PUBLIC_ENDPOINT=$(printf '%q' "$PUBLIC_ENDPOINT")
OVPN_PORT=$(printf '%q' "$OVPN_PORT")
OVPN_TCP_PORT=$(printf '%q' "$OVPN_TCP_PORT")
OVPN_UDP_PORT=$(printf '%q' "$OVPN_UDP_PORT")
OVPN_TCP_CIDR=$(printf '%q' "$OVPN_TCP_CIDR")
OVPN_UDP_CIDR=$(printf '%q' "$OVPN_UDP_CIDR")
OVPN_DNS=$(printf '%q' "$OVPN_DNS")
MAX_CLIENTS=$(printf '%q' "$MAX_CLIENTS")
CLIENT_NAME=$(printf '%q' "$CLIENT_NAME")
ENABLE_OPENVPN_LOGS=$(printf '%q' "$ENABLE_OPENVPN_LOGS")
ENABLE_HTTPS_MASK=$(printf '%q' "$ENABLE_HTTPS_MASK")
MASK_DOMAIN=$(printf '%q' "$MASK_DOMAIN")
LETSENCRYPT_EMAIL=$(printf '%q' "$LETSENCRYPT_EMAIL")
MASK_BACKEND_PORT=$(printf '%q' "$MASK_BACKEND_PORT")
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

valid_endpoint() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ ]]
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
    PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT:-$detected}"
  fi
}

resolve_domain_ipv4() {
  local domain="$1"
  getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1; exit}'
}

mask_default_email() {
  if [[ -n "$MASK_DOMAIN" ]]; then
    echo "admin@$MASK_DOMAIN"
  else
    echo ""
  fi
}

prompt_config() {
  local logs_answer mask_answer
  detect_public_ipv4 || true

  prompt PUBLIC_ENDPOINT "Public endpoint IP/host for clients" "$PUBLIC_ENDPOINT"
  prompt OVPN_PORT "OpenVPN UDP port and TCP port when mask is disabled" "$OVPN_PORT"

  mask_answer="$([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo yes || echo no)"
  prompt mask_answer "Enable HTTPS masking for TCP OpenVPN? yes/no" "$mask_answer"
  ENABLE_HTTPS_MASK="$(bool_value "$mask_answer")" || die "Mask answer must be yes or no."

  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    prompt MASK_DOMAIN "Mask domain with DNS A record to this server" "$MASK_DOMAIN"
    LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$(mask_default_email)}"
    prompt LETSENCRYPT_EMAIL "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
    OVPN_TCP_PORT="${OVPN_TCP_PORT:-443}"
    prompt OVPN_TCP_PORT "TCP OpenVPN public HTTPS-mask port" "$OVPN_TCP_PORT"
    prompt MASK_BACKEND_PORT "Local nginx HTTPS mask backend port" "$MASK_BACKEND_PORT"
  else
    OVPN_TCP_PORT="${OVPN_TCP_PORT:-$OVPN_PORT}"
  fi
  OVPN_UDP_PORT="${OVPN_UDP_PORT:-$OVPN_PORT}"

  prompt OVPN_TCP_CIDR "TCP VPN IPv4 subnet CIDR" "$OVPN_TCP_CIDR"
  prompt OVPN_UDP_CIDR "UDP VPN IPv4 subnet CIDR" "$OVPN_UDP_CIDR"
  prompt OVPN_DNS "Client DNS, comma separated IPv4" "$OVPN_DNS"
  prompt MAX_CLIENTS "Max clients per OpenVPN listener" "$MAX_CLIENTS"
  prompt CLIENT_NAME "First username" "$CLIENT_NAME"
  logs_answer="$([[ "$ENABLE_OPENVPN_LOGS" == "1" ]] && echo yes || echo no)"
  prompt logs_answer "Enable OpenVPN/nginx access logs? yes/no" "$logs_answer"
  ENABLE_OPENVPN_LOGS="$(bool_value "$logs_answer")" || die "Logs answer must be yes or no."

  valid_endpoint "$PUBLIC_ENDPOINT" || die "Endpoint must be IPv4 or hostname with letters, digits, dot, dash."
  valid_port "$OVPN_PORT" || die "Invalid OpenVPN port: $OVPN_PORT"
  valid_port "$OVPN_TCP_PORT" || die "Invalid TCP OpenVPN port: $OVPN_TCP_PORT"
  valid_port "$OVPN_UDP_PORT" || die "Invalid UDP OpenVPN port: $OVPN_UDP_PORT"
  valid_port "$MASK_BACKEND_PORT" || die "Invalid mask backend port: $MASK_BACKEND_PORT"
  valid_cidr "$OVPN_TCP_CIDR" || die "TCP VPN subnet must be IPv4 CIDR with prefix 8..30."
  valid_cidr "$OVPN_UDP_CIDR" || die "UDP VPN subnet must be IPv4 CIDR with prefix 8..30."
  [[ "$OVPN_TCP_CIDR" != "$OVPN_UDP_CIDR" ]] || die "TCP and UDP VPN subnets must be different."
  valid_dns_list "$OVPN_DNS" || die "DNS list must contain IPv4 addresses separated by commas."
  [[ "$MAX_CLIENTS" =~ ^[0-9]+$ ]] && (( MAX_CLIENTS >= 1 && MAX_CLIENTS <= 100000 )) || die "Invalid max clients: $MAX_CLIENTS"
  valid_name "$CLIENT_NAME" || die "Username must be 1-64 chars: letters, digits, dot, underscore, dash, @."
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    valid_domain "$MASK_DOMAIN" || die "Mask domain must be a valid domain name."
    valid_email "$LETSENCRYPT_EMAIL" || die "Let's Encrypt email is invalid."
  fi

  preflight_dns
  save_resume_config
}

preflight_dns() {
  local endpoint_ip mask_ip
  [[ -n "$SERVER_PUBLIC_IPV4" ]] || detect_public_ipv4 || true

  if [[ -n "$SERVER_PUBLIC_IPV4" && ! "$PUBLIC_ENDPOINT" =~ ^[0-9.]+$ ]]; then
    endpoint_ip="$(resolve_domain_ipv4 "$PUBLIC_ENDPOINT" || true)"
    if [[ -n "$endpoint_ip" && "$endpoint_ip" != "$SERVER_PUBLIC_IPV4" ]]; then
      echo
      echo "WARN: endpoint domain resolves to $endpoint_ip, but this server public IPv4 is $SERVER_PUBLIC_IPV4."
      confirm "Continue anyway? y/yes: " || die "Cancelled because endpoint DNS does not match this server."
    fi
  fi

  if [[ "$ENABLE_HTTPS_MASK" != "1" ]]; then
    return 0
  fi

  [[ -n "$SERVER_PUBLIC_IPV4" ]] || die "Cannot detect this server public IPv4 for mask DNS preflight."
  mask_ip="$(resolve_domain_ipv4 "$MASK_DOMAIN" || true)"
  if [[ -z "$mask_ip" ]]; then
    echo
    echo "WARN: DNS A record for $MASK_DOMAIN was not found."
    if confirm "Continue without HTTPS masking? y/yes: "; then
      ENABLE_HTTPS_MASK=0
      OVPN_TCP_PORT="$OVPN_PORT"
      MASK_DOMAIN=""
      LETSENCRYPT_EMAIL=""
      return 0
    fi
    die "Cancelled because mask domain has no A record."
  fi
  if [[ "$mask_ip" != "$SERVER_PUBLIC_IPV4" ]]; then
    echo
    echo "WARN: $MASK_DOMAIN resolves to $mask_ip, but this server public IPv4 is $SERVER_PUBLIC_IPV4."
    if confirm "Continue without HTTPS masking? y/yes: "; then
      ENABLE_HTTPS_MASK=0
      OVPN_TCP_PORT="$OVPN_PORT"
      MASK_DOMAIN=""
      LETSENCRYPT_EMAIL=""
      return 0
    fi
    die "Cancelled because mask domain does not point to this server."
  fi
}

print_plan() {
  cat <<EOF

Install plan:
  public endpoint:  ${PUBLIC_ENDPOINT}
  UDP OpenVPN:      ${OVPN_UDP_PORT}/udp, subnet ${OVPN_UDP_CIDR}
  TCP OpenVPN:      ${OVPN_TCP_PORT}/tcp, subnet ${OVPN_TCP_CIDR}
  HTTPS mask:       $([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo "yes, domain ${MASK_DOMAIN}, nginx backend 127.0.0.1:${MASK_BACKEND_PORT}" || echo no)
  client DNS:       ${OVPN_DNS}
  max clients:      ${MAX_CLIENTS}
  access logs:      $([[ "$ENABLE_OPENVPN_LOGS" == "1" ]] && echo yes || echo no)
  first username:   ${CLIENT_NAME}

EOF
  confirm "Type y or yes to continue: " || die "Cancelled."
}

backup_state() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  for path in "$SERVER_DIR" "$EASYRSA_DIR" "$CLIENT_DIR" "$CLIENT_OUT_DIR" "$CTL_PATH" \
    "$OPENVPN_ETC/server-udp.conf" "$OPENVPN_ETC/server-tcp.conf"; do
    [[ -e "$path" || -L "$path" ]] && cp -a "$path" "$BACKUP_DIR"/
  done
  echo "backup_dir=$BACKUP_DIR"
}

install_packages() {
  local packages
  export DEBIAN_FRONTEND=noninteractive
  packages=(ca-certificates curl openvpn easy-rsa iproute2 iptables qrencode openssl apache2-utils)
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    packages+=(nginx certbot)
  fi
  retry_command "apt-get update" apt-get update
  retry_command "apt-get install OpenVPN tools" apt-get install -y "${packages[@]}"
}

port_listening_tcp() {
  ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

port_listening_udp() {
  ss -H -lun "sport = :$1" 2>/dev/null | grep -q .
}

port_preflight() {
  if port_listening_udp "$OVPN_UDP_PORT"; then
    die "UDP port $OVPN_UDP_PORT is already in use. Use a clean server or choose another port."
  fi
  if port_listening_tcp "$OVPN_TCP_PORT"; then
    die "TCP port $OVPN_TCP_PORT is already in use. Use a clean server or choose another port."
  fi
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    if port_listening_tcp "$MASK_BACKEND_PORT"; then
      die "Mask backend port $MASK_BACKEND_PORT is already in use."
    fi
  fi
}

prefix_to_netmask() {
  local prefix="$1"
  local mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  printf '%d.%d.%d.%d' \
    $(((mask >> 24) & 255)) \
    $(((mask >> 16) & 255)) \
    $(((mask >> 8) & 255)) \
    $((mask & 255))
}

configure_sysctl() {
  cat > /etc/sysctl.d/99-openvpn-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

setup_dirs() {
  install -d -m 0750 "$SERVER_DIR" "$EASYRSA_DIR" "$CLIENT_DIR" "$CLIENT_OUT_DIR"
}

setup_pki() {
  if [[ ! -x "$EASYRSA_DIR/easyrsa" ]]; then
    cp -a /usr/share/easy-rsa/* "$EASYRSA_DIR"/
  fi
  cd "$EASYRSA_DIR"
  if [[ ! -d pki ]]; then
    ./easyrsa --batch init-pki
  fi
  [[ -r pki/ca.crt ]] || EASYRSA_REQ_CN="OpenVPN CA" ./easyrsa --batch build-ca nopass
  [[ -r pki/issued/server.crt && -r pki/private/server.key ]] || EASYRSA_REQ_CN="server" ./easyrsa --batch build-server-full server nopass
  [[ -r pki/dh.pem ]] || ./easyrsa --batch gen-dh
  [[ -r pki/crl.pem ]] || ./easyrsa --batch gen-crl

  install -m 0644 pki/ca.crt "$SERVER_DIR/ca.crt"
  install -m 0644 pki/issued/server.crt "$SERVER_DIR/server.crt"
  install -m 0600 pki/private/server.key "$SERVER_DIR/server.key"
  install -m 0644 pki/dh.pem "$SERVER_DIR/dh.pem"
  install -m 0644 pki/crl.pem "$SERVER_DIR/crl.pem"
  if [[ ! -s "$TLS_CRYPT_KEY" ]]; then
    openvpn --genkey secret "$TLS_CRYPT_KEY"
    chmod 600 "$TLS_CRYPT_KEY"
  fi
}

setup_auth() {
  touch "$AUTH_FILE"
  chmod 640 "$AUTH_FILE"
  chgrp nogroup "$AUTH_FILE" 2>/dev/null || true

  cat > "$AUTH_SCRIPT" <<EOF
#!/usr/bin/env bash
set -euo pipefail

AUTH_FILE="$AUTH_FILE"
USERPASS_FILE="\${1:-}"

[[ -n "\$USERPASS_FILE" && -r "\$USERPASS_FILE" ]] || exit 1
username="\$(sed -n '1p' "\$USERPASS_FILE")"
password="\$(sed -n '2p' "\$USERPASS_FILE")"

[[ "\$username" =~ ^[A-Za-z0-9._@-]{1,64}$ ]] || exit 1
[[ -n "\$password" ]] || exit 1

htpasswd -vb "\$AUTH_FILE" "\$username" "\$password" >/dev/null 2>&1
EOF
  chmod 750 "$AUTH_SCRIPT"
  chgrp nogroup "$AUTH_SCRIPT" 2>/dev/null || true
}

write_nat_scripts() {
  cat > "$SERVER_DIR/vpn-up.sh" <<'EOF'
#!/usr/bin/env bash
set -e

sysctl -w net.ipv4.ip_forward=1 >/dev/null

if [[ -n "${ifconfig_local:-}" && -n "${ifconfig_netmask:-}" ]]; then
  net="${ifconfig_local}/${ifconfig_netmask}"
  iptables -t nat -C POSTROUTING -s "$net" ! -d "$net" -j MASQUERADE 2>/dev/null || \
    iptables -t nat -A POSTROUTING -s "$net" ! -d "$net" -j MASQUERADE
  iptables -C FORWARD -s "$net" ! -d "$net" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -s "$net" ! -d "$net" -j ACCEPT
  iptables -C FORWARD -d "$net" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -d "$net" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
fi
EOF

  cat > "$SERVER_DIR/vpn-down.sh" <<'EOF'
#!/usr/bin/env bash

if [[ -n "${ifconfig_local:-}" && -n "${ifconfig_netmask:-}" ]]; then
  net="${ifconfig_local}/${ifconfig_netmask}"
  iptables -t nat -D POSTROUTING -s "$net" ! -d "$net" -j MASQUERADE 2>/dev/null || true
  iptables -D FORWARD -s "$net" ! -d "$net" -j ACCEPT 2>/dev/null || true
  iptables -D FORWARD -d "$net" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
fi
EOF
  chmod 700 "$SERVER_DIR/vpn-up.sh" "$SERVER_DIR/vpn-down.sh"
}

openvpn_cipher_lines() {
  if openvpn --version 2>/dev/null | head -n 1 | grep -Eq 'OpenVPN 2\.[0-4]\.'; then
    cat <<'EOF'
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:AES-128-GCM
EOF
  else
    cat <<'EOF'
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
EOF
  fi
}

write_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
PUBLIC_ENDPOINT=$(printf '%q' "$PUBLIC_ENDPOINT")
OVPN_PORT=$(printf '%q' "$OVPN_PORT")
OVPN_TCP_PORT=$(printf '%q' "$OVPN_TCP_PORT")
OVPN_UDP_PORT=$(printf '%q' "$OVPN_UDP_PORT")
OVPN_TCP_CIDR=$(printf '%q' "$OVPN_TCP_CIDR")
OVPN_UDP_CIDR=$(printf '%q' "$OVPN_UDP_CIDR")
OVPN_DNS=$(printf '%q' "$OVPN_DNS")
MAX_CLIENTS=$(printf '%q' "$MAX_CLIENTS")
ENABLE_OPENVPN_LOGS=$(printf '%q' "$ENABLE_OPENVPN_LOGS")
ENABLE_HTTPS_MASK=$(printf '%q' "$ENABLE_HTTPS_MASK")
MASK_DOMAIN=$(printf '%q' "$MASK_DOMAIN")
MASK_BACKEND_PORT=$(printf '%q' "$MASK_BACKEND_PORT")
SERVER_DIR=$(printf '%q' "$SERVER_DIR")
EASYRSA_DIR=$(printf '%q' "$EASYRSA_DIR")
CLIENT_DIR=$(printf '%q' "$CLIENT_DIR")
CLIENT_OUT_DIR=$(printf '%q' "$CLIENT_OUT_DIR")
AUTH_FILE=$(printf '%q' "$AUTH_FILE")
TLS_CRYPT_KEY=$(printf '%q' "$TLS_CRYPT_KEY")
UDP_STATUS_FILE=$(printf '%q' "$UDP_STATUS_FILE")
TCP_STATUS_FILE=$(printf '%q' "$TCP_STATUS_FILE")
EOF
}

write_one_server_config() {
  local proto_name="$1"
  local proto="$2"
  local port="$3"
  local dev="$4"
  local cidr="$5"
  local status_file="$6"
  local conf="$SERVER_DIR/server-${proto_name}.conf"
  local legacy_conf="$OPENVPN_ETC/server-${proto_name}.conf"
  local network="${cidr%/*}"
  local prefix="${cidr#*/}"
  local netmask
  local verb="0"
  netmask="$(prefix_to_netmask "$prefix")"
  [[ "$ENABLE_OPENVPN_LOGS" == "1" ]] && verb="3"

  cat > "$conf" <<EOF
port ${port}
proto ${proto}
dev ${dev}
topology subnet
server ${network} ${netmask}

ca ${SERVER_DIR}/ca.crt
cert ${SERVER_DIR}/server.crt
key ${SERVER_DIR}/server.key
dh ${SERVER_DIR}/dh.pem
tls-crypt ${TLS_CRYPT_KEY}

verify-client-cert none
username-as-common-name
duplicate-cn
auth-user-pass-verify ${AUTH_SCRIPT} via-file

auth SHA256
keepalive 10 120
max-clients ${MAX_CLIENTS}
persist-key
persist-tun
user nobody
group nogroup

push "redirect-gateway def1 bypass-dhcp"
EOF

  openvpn_cipher_lines >> "$conf"

  IFS=, read -ra dns_items <<< "$OVPN_DNS"
  for dns in "${dns_items[@]}"; do
    dns="$(trim_value "$dns")"
    echo "push \"dhcp-option DNS ${dns}\"" >> "$conf"
  done

  cat >> "$conf" <<EOF

script-security 2
up ${SERVER_DIR}/vpn-up.sh
down ${SERVER_DIR}/vpn-down.sh

status ${status_file} 10
status-version 3
verb ${verb}
EOF

  if [[ "$ENABLE_OPENVPN_LOGS" == "1" ]]; then
    echo "log-append /var/log/openvpn/server-${proto_name}.log" >> "$conf"
  fi
  if [[ "$proto_name" == "udp" ]]; then
    echo "explicit-exit-notify 1" >> "$conf"
  fi
  if [[ "$proto_name" == "tcp" && "$ENABLE_HTTPS_MASK" == "1" ]]; then
    echo "port-share 127.0.0.1 ${MASK_BACKEND_PORT}" >> "$conf"
  fi

  chmod 600 "$conf"
  ln -sf "$conf" "$legacy_conf"
}

write_server_configs() {
  write_one_server_config "udp" "udp" "$OVPN_UDP_PORT" "vpn-udp" "$OVPN_UDP_CIDR" "$UDP_STATUS_FILE"
  write_one_server_config "tcp" "tcp-server" "$OVPN_TCP_PORT" "vpn-tcp" "$OVPN_TCP_CIDR" "$TCP_STATUS_FILE"
}

install_openvpnctl() {
  [[ -f "$SCRIPT_DIR/openvpnctl.sh" ]] || die "openvpnctl.sh must be next to install_openvpn.sh."
  install -m 0755 "$SCRIPT_DIR/openvpnctl.sh" "$CTL_PATH"
}

mask_root() {
  printf '%s/%s\n' "$MASK_ROOT_BASE" "$MASK_DOMAIN"
}

write_mask_http_config() {
  local root_dir conf
  root_dir="$(mask_root)"
  conf="/etc/nginx/sites-available/openvpn-mask-${MASK_DOMAIN}.conf"
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
  ln -sf "$conf" "/etc/nginx/sites-enabled/openvpn-mask-${MASK_DOMAIN}.conf"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_certificate() {
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
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
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  local root_dir token expected challenge_dir local_body public_body url
  root_dir="$(mask_root)"
  challenge_dir="$root_dir/.well-known/acme-challenge"
  token="openvpn-$(openssl rand -hex 8 2>/dev/null || date +%s)"
  expected="openvpn-acme-ok-${token}"
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
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  local root_dir conf access_log error_log
  root_dir="$(mask_root)"
  conf="/etc/nginx/sites-available/openvpn-mask-${MASK_DOMAIN}.conf"
  access_log="off"
  error_log="/dev/null crit"
  if [[ "$ENABLE_OPENVPN_LOGS" == "1" ]]; then
    access_log="/var/log/nginx/openvpn-mask-${MASK_DOMAIN}.access.log"
    error_log="/var/log/nginx/openvpn-mask-${MASK_DOMAIN}.error.log warn"
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
    listen 127.0.0.1:${MASK_BACKEND_PORT} ssl;
    server_name ${MASK_DOMAIN};
    root ${root_dir};

    access_log ${access_log};
    error_log ${error_log};

    ssl_certificate /etc/letsencrypt/live/${MASK_DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${MASK_DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  nginx -t
  systemctl reload nginx
}

setup_https_mask() {
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  write_mask_http_config
  acme_http01_preflight
  issue_certificate
  write_mask_https_config
}

configure_firewall() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${OVPN_UDP_PORT}/udp"
    ufw allow "${OVPN_TCP_PORT}/tcp"
    [[ "$ENABLE_HTTPS_MASK" == "1" ]] && ufw allow "80/tcp"
  fi
}

openvpn_service_prefix() {
  if systemctl list-unit-files 'openvpn-server@.service' 2>/dev/null | grep -q '^openvpn-server@.service'; then
    echo "openvpn-server@"
  else
    echo "openvpn@"
  fi
}

start_services() {
  local prefix
  prefix="$(openvpn_service_prefix)"
  systemctl daemon-reload
  systemctl enable --now "${prefix}server-udp"
  systemctl enable --now "${prefix}server-tcp"
}

ensure_first_client() {
  if [[ -f "$CLIENT_DIR/${CLIENT_NAME}.env" ]]; then
    echo "User already exists: $CLIENT_NAME"
  else
    "$CTL_PATH" add "$CLIENT_NAME"
  fi
}

verify_install() {
  local prefix
  prefix="$(openvpn_service_prefix)"
  systemctl is-active --quiet "${prefix}server-udp" || die "${prefix}server-udp is not active."
  systemctl is-active --quiet "${prefix}server-tcp" || die "${prefix}server-tcp is not active."
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    systemctl is-active --quiet nginx || die "nginx is not active."
  fi
}

main() {
  detect_os
  load_resume_config
  echo "OpenVPN installer for Debian/Ubuntu."
  echo
  echo "Before running:"
  echo "  1. Use a clean server, especially when HTTPS masking uses ports 80/443."
  echo "  2. If HTTPS masking is enabled, create DNS A record: <mask-domain> -> this server IPv4."
  echo "  3. Make sure selected OpenVPN ports and port 80 are reachable from the internet."
  echo "  4. Keep the current SSH session open until a second login works."
  echo
  prompt_config
  reset_step_state_if_config_changed
  print_plan

  run_step "backup" "Backup current state" backup_state
  run_step "packages" "Install packages" install_packages
  run_step "ports" "Port preflight" port_preflight
  run_step "sysctl" "Enable IPv4 forwarding" configure_sysctl
  run_step "dirs" "Create directories" setup_dirs
  run_step "pki" "Create Easy-RSA server PKI" setup_pki
  run_step "auth" "Create username/password auth helper" setup_auth
  run_step "nat" "Write dynamic NAT scripts" write_nat_scripts
  run_step "env" "Write control environment" write_env
  run_step "ctl" "Install openvpnctl" install_openvpnctl
  run_step "mask" "Configure HTTPS mask if enabled" setup_https_mask
  run_step "config" "Write OpenVPN TCP and UDP configs" write_server_configs
  run_step "firewall" "Open firewall ports if ufw is active" configure_firewall
  run_step "service" "Start OpenVPN services" start_services
  run_step "first_client" "Create first user" ensure_first_client
  run_step "verify" "Verify" verify_install
  mark_done "done"
  save_resume_config

  step "Done"
  cat <<EOF
Installed OpenVPN.

UDP endpoint: ${PUBLIC_ENDPOINT}:${OVPN_UDP_PORT}/udp
TCP endpoint: $([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo "${MASK_DOMAIN}:${OVPN_TCP_PORT}/tcp with HTTPS mask" || echo "${PUBLIC_ENDPOINT}:${OVPN_TCP_PORT}/tcp")
First user: ${CLIENT_NAME}

Client files:
  ${CLIENT_OUT_DIR}/${CLIENT_NAME}-udp.ovpn
  ${CLIENT_OUT_DIR}/${CLIENT_NAME}-tcp.ovpn
  ${CLIENT_OUT_DIR}/${CLIENT_NAME}-credentials.txt

Manage users:
  openvpnctl add
  openvpnctl delete
  openvpnctl list
  openvpnctl show
  openvpnctl qr
  openvpnctl traffic

Backups:
  ${BACKUP_DIR}
EOF
}

main "$@"
