#!/usr/bin/env bash
set -Eeuo pipefail

# AmneziaWG installer for a fresh Debian/Ubuntu server.
# Modes:
#   1. Plain AmneziaWG: UDP 51820 by default.
#   2. HTTPS mask site: nginx serves a real HTTPS site on TCP 443,
#      AmneziaWG listens on UDP 443. TCP and UDP do not conflict.

PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT:-}"
AWG_IFACE="${AWG_IFACE:-awg0}"
AWG_PORT="${AWG_PORT:-51820}"
AWG_SUBNET="${AWG_SUBNET:-10.88.88.0/24}"
AWG_SERVER_IP="${AWG_SERVER_IP:-10.88.88.1}"
AWG_DNS="${AWG_DNS:-1.1.1.1,8.8.8.8}"
CLIENT_NAME="${CLIENT_NAME:-}"
AWG_JC="${AWG_JC:-}"
AWG_JMIN="${AWG_JMIN:-}"
AWG_JMAX="${AWG_JMAX:-}"
AWG_S1="${AWG_S1:-}"
AWG_S2="${AWG_S2:-}"
AWG_H1="${AWG_H1:-}"
AWG_H2="${AWG_H2:-}"
AWG_H3="${AWG_H3:-}"
AWG_H4="${AWG_H4:-}"
ENABLE_HTTPS_MASK="${ENABLE_HTTPS_MASK:-0}"
MASK_DOMAIN="${MASK_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
ENABLE_NGINX_LOGS="${ENABLE_NGINX_LOGS:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
INSTALL_RETRIES="${INSTALL_RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-5}"

AWG_DIR="/etc/amnezia/amneziawg"
CLIENT_DIR="$AWG_DIR/clients"
CLIENT_OUT_DIR="/root/amneziawg-clients"
MASK_ROOT_BASE="/var/www"
ENV_FILE="$AWG_DIR/awgctl.env"
CTL_PATH="/usr/local/sbin/awgctl"
STATE_FILE="/root/.install_amneziawg.state"
RESUME_CONFIG="/root/.install_amneziawg.config"
BACKUP_ROOT="/root/amneziawg-install-backups"
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
AWG_IFACE=$(printf '%q' "$AWG_IFACE")
AWG_PORT=$(printf '%q' "$AWG_PORT")
AWG_SUBNET=$(printf '%q' "$AWG_SUBNET")
AWG_SERVER_IP=$(printf '%q' "$AWG_SERVER_IP")
AWG_DNS=$(printf '%q' "$AWG_DNS")
CLIENT_NAME=$(printf '%q' "$CLIENT_NAME")
AWG_JC=$(printf '%q' "$AWG_JC")
AWG_JMIN=$(printf '%q' "$AWG_JMIN")
AWG_JMAX=$(printf '%q' "$AWG_JMAX")
AWG_S1=$(printf '%q' "$AWG_S1")
AWG_S2=$(printf '%q' "$AWG_S2")
AWG_H1=$(printf '%q' "$AWG_H1")
AWG_H2=$(printf '%q' "$AWG_H2")
AWG_H3=$(printf '%q' "$AWG_H3")
AWG_H4=$(printf '%q' "$AWG_H4")
ENABLE_HTTPS_MASK=$(printf '%q' "$ENABLE_HTTPS_MASK")
MASK_DOMAIN=$(printf '%q' "$MASK_DOMAIN")
LETSENCRYPT_EMAIL=$(printf '%q' "$LETSENCRYPT_EMAIL")
ENABLE_NGINX_LOGS=$(printf '%q' "$ENABLE_NGINX_LOGS")
ASSUME_YES=$(printf '%q' "$ASSUME_YES")
INSTALL_RETRIES=$(printf '%q' "$INSTALL_RETRIES")
RETRY_DELAY_SECONDS=$(printf '%q' "$RETRY_DELAY_SECONDS")
EOF
}

load_resume_config() {
  if [[ "${RESET_INSTALL_STATE:-0}" == "1" ]]; then
    rm -f "$STATE_FILE" "$RESUME_CONFIG"
  fi
  if [[ -f "$RESUME_CONFIG" ]]; then
    echo "Resume config found: $RESUME_CONFIG"
    # shellcheck disable=SC1090
    . "$RESUME_CONFIG"
  fi
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

rand_range() {
  local min="$1"
  local max="$2"
  local span
  span=$((max - min + 1))
  echo $((min + (RANDOM % span)))
}

ensure_awg_obfuscation_params() {
  AWG_JC="${AWG_JC:-$(rand_range 3 8)}"
  AWG_JMIN="${AWG_JMIN:-$(rand_range 40 80)}"
  AWG_JMAX="${AWG_JMAX:-$(rand_range 160 320)}"
  AWG_S1="${AWG_S1:-$(rand_range 96 160)}"
  AWG_S2="${AWG_S2:-$(rand_range 96 160)}"
  AWG_H1="${AWG_H1:-$(rand_range 10000000 2000000000)}"
  AWG_H2="${AWG_H2:-$(rand_range 10000000 2000000000)}"
  AWG_H3="${AWG_H3:-$(rand_range 10000000 2000000000)}"
  AWG_H4="${AWG_H4:-$(rand_range 10000000 2000000000)}"
}

valid_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 0 ))
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
  local mask_answer logs_answer
  detect_public_ipv4 || true
  ensure_awg_obfuscation_params

  mask_answer="$([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo yes || echo no)"
  prompt mask_answer "Enable HTTPS mask site? yes/no" "$mask_answer"
  ENABLE_HTTPS_MASK="$(bool_value "$mask_answer")" || die "Mask answer must be yes or no."

  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    prompt MASK_DOMAIN "Mask domain with DNS A record to this server" "$MASK_DOMAIN"
    PUBLIC_ENDPOINT="$MASK_DOMAIN"
    LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$(mask_default_email)}"
    prompt LETSENCRYPT_EMAIL "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
    if [[ "$AWG_PORT" == "51820" ]]; then
      AWG_PORT="443"
    fi
    prompt AWG_PORT "AmneziaWG UDP port" "$AWG_PORT"
  else
    prompt PUBLIC_ENDPOINT "Public endpoint IP/host for clients" "$PUBLIC_ENDPOINT"
    prompt AWG_PORT "AmneziaWG UDP port" "$AWG_PORT"
  fi

  prompt AWG_IFACE "AmneziaWG interface" "$AWG_IFACE"
  prompt AWG_SUBNET "VPN IPv4 subnet" "$AWG_SUBNET"
  prompt AWG_SERVER_IP "Server VPN IPv4" "$AWG_SERVER_IP"
  prompt AWG_DNS "Client DNS, comma separated IPv4" "$AWG_DNS"
  prompt AWG_JC "AmneziaWG junk packet count Jc" "$AWG_JC"
  prompt AWG_JMIN "AmneziaWG junk min size Jmin" "$AWG_JMIN"
  prompt AWG_JMAX "AmneziaWG junk max size Jmax" "$AWG_JMAX"
  prompt CLIENT_NAME "First client name" "$CLIENT_NAME"

  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    logs_answer="$([[ "$ENABLE_NGINX_LOGS" == "1" ]] && echo yes || echo no)"
    prompt logs_answer "Enable nginx access logs for mask site? yes/no" "$logs_answer"
    ENABLE_NGINX_LOGS="$(bool_value "$logs_answer")" || die "Logs answer must be yes or no."
  else
    ENABLE_NGINX_LOGS=0
  fi

  valid_endpoint "$PUBLIC_ENDPOINT" || die "Endpoint must be IPv4 or hostname with letters, digits, dot, dash."
  [[ "$AWG_IFACE" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "Invalid AmneziaWG interface."
  valid_port "$AWG_PORT" || die "Invalid UDP port: $AWG_PORT"
  valid_cidr "$AWG_SUBNET" || die "VPN subnet must be IPv4 CIDR with prefix 8..30."
  valid_ipv4 "$AWG_SERVER_IP" || die "Invalid server VPN IPv4: $AWG_SERVER_IP"
  valid_dns_list "$AWG_DNS" || die "DNS list must contain IPv4 addresses separated by commas."
  valid_positive_int "$AWG_JC" && (( AWG_JC <= 128 )) || die "Invalid Jc: $AWG_JC"
  valid_positive_int "$AWG_JMIN" && valid_positive_int "$AWG_JMAX" && (( AWG_JMIN <= AWG_JMAX && AWG_JMAX <= 1280 )) || die "Invalid Jmin/Jmax."
  valid_positive_int "$AWG_S1" && valid_positive_int "$AWG_S2" || die "Invalid S1/S2."
  valid_positive_int "$AWG_H1" && valid_positive_int "$AWG_H2" && valid_positive_int "$AWG_H3" && valid_positive_int "$AWG_H4" || die "Invalid H1-H4."
  valid_name "$CLIENT_NAME" || die "Client name must be 1-64 chars: letters, digits, dot, underscore, dash, @."
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    valid_domain "$MASK_DOMAIN" || die "Mask domain must be a valid domain name."
    valid_email "$LETSENCRYPT_EMAIL" || die "Let's Encrypt email is invalid."
  fi

  preflight_dns
  save_resume_config
}

preflight_dns() {
  local endpoint_ip mask_ip old_mask
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
  old_mask="$MASK_DOMAIN"
  mask_ip="$(resolve_domain_ipv4 "$MASK_DOMAIN" || true)"
  if [[ -z "$mask_ip" ]]; then
    echo
    echo "WARN: DNS A record for $MASK_DOMAIN was not found."
    if confirm "Continue without HTTPS mask site? y/yes: "; then
      ENABLE_HTTPS_MASK=0
      MASK_DOMAIN=""
      LETSENCRYPT_EMAIL=""
      if [[ "$PUBLIC_ENDPOINT" == "$old_mask" ]]; then
        PUBLIC_ENDPOINT="$SERVER_PUBLIC_IPV4"
      fi
      return 0
    fi
    die "Cancelled because mask domain has no A record."
  fi
  if [[ "$mask_ip" != "$SERVER_PUBLIC_IPV4" ]]; then
    echo
    echo "WARN: $MASK_DOMAIN resolves to $mask_ip, but this server public IPv4 is $SERVER_PUBLIC_IPV4."
    if confirm "Continue without HTTPS mask site? y/yes: "; then
      ENABLE_HTTPS_MASK=0
      MASK_DOMAIN=""
      LETSENCRYPT_EMAIL=""
      if [[ "$PUBLIC_ENDPOINT" == "$old_mask" ]]; then
        PUBLIC_ENDPOINT="$SERVER_PUBLIC_IPV4"
      fi
      return 0
    fi
    die "Cancelled because mask domain does not point to this server."
  fi
}

print_plan() {
  cat <<EOF

Install plan:
  endpoint:        ${PUBLIC_ENDPOINT}:${AWG_PORT}/udp
  interface:       ${AWG_IFACE}
  subnet:          ${AWG_SUBNET}
  server IP:       ${AWG_SERVER_IP}
  client DNS:      ${AWG_DNS}
  obfuscation:     Jc=${AWG_JC}, Jmin=${AWG_JMIN}, Jmax=${AWG_JMAX}, S1=${AWG_S1}, S2=${AWG_S2}
  HTTPS mask site: $([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo "yes, https://${MASK_DOMAIN}/ on TCP 443" || echo no)
  nginx logs:      $([[ "$ENABLE_NGINX_LOGS" == "1" ]] && echo yes || echo no)
  first client:    ${CLIENT_NAME}

EOF
  confirm "Type y or yes to continue: " || die "Cancelled."
}

backup_state() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  for path in "$AWG_DIR" "$CTL_PATH" "$ENV_FILE"; do
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
  if port_listening_udp "$AWG_PORT"; then
    die "UDP port $AWG_PORT is already in use. Use a clean server or choose another port."
  fi
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    if port_listening_tcp 80; then
      die "TCP port 80 is already in use. HTTPS mask needs port 80 for Let's Encrypt."
    fi
    if port_listening_tcp 443; then
      die "TCP port 443 is already in use. HTTPS mask needs nginx on TCP 443."
    fi
  fi
}

install_packages() {
  local packages
  export DEBIAN_FRONTEND=noninteractive
  packages=(ca-certificates curl gnupg dirmngr lsb-release iproute2 iptables qrencode)
  retry_command "apt-get update" apt-get update
  retry_command "apt-get install base tools" apt-get install -y "${packages[@]}"
}

install_mask_packages() {
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  export DEBIAN_FRONTEND=noninteractive
  retry_command "install nginx and certbot" apt-get install -y nginx certbot
}

install_amneziawg_tools() {
  local os_id os_codename repo_codename keyring
  if have awg && have awg-quick; then
    awg --version || true
    return 0
  fi

  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  os_codename="${VERSION_CODENAME:-}"
  keyring="/etc/apt/keyrings/amneziawg.gpg"
  install -d -m 0755 /etc/apt/keyrings

  if [[ "$os_id" == "ubuntu" ]]; then
    retry_command "install software-properties-common" apt-get install -y software-properties-common python3-launchpadlib
    retry_command "add AmneziaWG PPA" add-apt-repository -y ppa:amnezia/ppa
  else
    repo_codename="focal"
    retry_command "download AmneziaWG PPA key" curl -fsSL \
      "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75c9dd72c799870e310542e24166f2c257290828" \
      -o /tmp/amneziawg-ppa.key
    gpg --dearmor < /tmp/amneziawg-ppa.key > "$keyring"
    rm -f /tmp/amneziawg-ppa.key
    cat > /etc/apt/sources.list.d/amneziawg.list <<EOF
deb [signed-by=${keyring}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${repo_codename} main
EOF
  fi

  retry_command "apt-get update with AmneziaWG repo" apt-get update
  apt-get install -y "linux-headers-$(uname -r)" || true
  retry_command "install AmneziaWG package" apt-get install -y amneziawg
  have awg || die "awg command was not installed."
  have awg-quick || die "awg-quick command was not installed."
  awg --version || true
}

out_iface() {
  ip route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}'
}

configure_sysctl() {
  cat > /etc/sysctl.d/99-amneziawg-forward.conf <<'EOF'
net.ipv4.ip_forward=1
EOF
  sysctl --system >/dev/null
}

generate_server_keys() {
  install -d -m 0700 "$AWG_DIR" "$CLIENT_DIR" "$CLIENT_OUT_DIR"
  if [[ ! -s "$AWG_DIR/server_private.key" ]]; then
    umask 077
    awg genkey > "$AWG_DIR/server_private.key"
    awg pubkey < "$AWG_DIR/server_private.key" > "$AWG_DIR/server_public.key"
  fi
  chmod 600 "$AWG_DIR/server_private.key"
  chmod 644 "$AWG_DIR/server_public.key"
}

write_env() {
  umask 077
  cat > "$ENV_FILE" <<EOF
AWG_IFACE=$(printf '%q' "$AWG_IFACE")
AWG_PORT=$(printf '%q' "$AWG_PORT")
AWG_SUBNET=$(printf '%q' "$AWG_SUBNET")
AWG_SERVER_IP=$(printf '%q' "$AWG_SERVER_IP")
AWG_DNS=$(printf '%q' "$AWG_DNS")
PUBLIC_ENDPOINT=$(printf '%q' "$PUBLIC_ENDPOINT")
AWG_JC=$(printf '%q' "$AWG_JC")
AWG_JMIN=$(printf '%q' "$AWG_JMIN")
AWG_JMAX=$(printf '%q' "$AWG_JMAX")
AWG_S1=$(printf '%q' "$AWG_S1")
AWG_S2=$(printf '%q' "$AWG_S2")
AWG_H1=$(printf '%q' "$AWG_H1")
AWG_H2=$(printf '%q' "$AWG_H2")
AWG_H3=$(printf '%q' "$AWG_H3")
AWG_H4=$(printf '%q' "$AWG_H4")
ENABLE_HTTPS_MASK=$(printf '%q' "$ENABLE_HTTPS_MASK")
MASK_DOMAIN=$(printf '%q' "$MASK_DOMAIN")
AWG_DIR=$(printf '%q' "$AWG_DIR")
CLIENT_DIR=$(printf '%q' "$CLIENT_DIR")
CLIENT_OUT_DIR=$(printf '%q' "$CLIENT_OUT_DIR")
EOF
}

write_awg_config() {
  local private_key
  local prefix
  local wan_iface
  private_key="$(cat "$AWG_DIR/server_private.key")"
  prefix="${AWG_SUBNET#*/}"
  wan_iface="$(out_iface)"
  [[ -n "$wan_iface" ]] || die "Cannot detect outbound network interface."

  umask 077
  cat > "$AWG_DIR/${AWG_IFACE}.conf" <<EOF
[Interface]
Address = ${AWG_SERVER_IP}/${prefix}
ListenPort = ${AWG_PORT}
PrivateKey = ${private_key}
Jc = ${AWG_JC}
Jmin = ${AWG_JMIN}
Jmax = ${AWG_JMAX}
S1 = ${AWG_S1}
S2 = ${AWG_S2}
H1 = ${AWG_H1}
H2 = ${AWG_H2}
H3 = ${AWG_H3}
H4 = ${AWG_H4}
SaveConfig = false
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -t nat -C POSTROUTING -s ${AWG_SUBNET} -o ${wan_iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${AWG_SUBNET} -o ${wan_iface} -j MASQUERADE
PostDown = iptables -t nat -D POSTROUTING -s ${AWG_SUBNET} -o ${wan_iface} -j MASQUERADE 2>/dev/null || true
EOF
  chmod 600 "$AWG_DIR/${AWG_IFACE}.conf"
}

install_awgctl() {
  [[ -f "$SCRIPT_DIR/awgctl.sh" ]] || die "awgctl.sh must be next to install_amneziawg.sh."
  install -m 0755 "$SCRIPT_DIR/awgctl.sh" "$CTL_PATH"
}

configure_firewall() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${AWG_PORT}/udp"
    if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
      ufw allow "80/tcp"
      ufw allow "443/tcp"
    fi
  fi
}

mask_root() {
  printf '%s/%s\n' "$MASK_ROOT_BASE" "$MASK_DOMAIN"
}

write_mask_http_config() {
  local root_dir conf
  root_dir="$(mask_root)"
  conf="/etc/nginx/sites-available/awg-mask-${MASK_DOMAIN}.conf"
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
  ln -sf "$conf" "/etc/nginx/sites-enabled/awg-mask-${MASK_DOMAIN}.conf"
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

write_mask_https_config() {
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  local root_dir conf access_log error_log
  root_dir="$(mask_root)"
  conf="/etc/nginx/sites-available/awg-mask-${MASK_DOMAIN}.conf"
  access_log="off"
  error_log="/dev/null crit"
  if [[ "$ENABLE_NGINX_LOGS" == "1" ]]; then
    access_log="/var/log/nginx/awg-mask-${MASK_DOMAIN}.access.log"
    error_log="/var/log/nginx/awg-mask-${MASK_DOMAIN}.error.log warn"
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
  issue_certificate
  write_mask_https_config
}

start_service() {
  systemctl enable --now "awg-quick@${AWG_IFACE}"
}

ensure_first_client() {
  if [[ -f "$CLIENT_DIR/${CLIENT_NAME}.env" ]]; then
    echo "Client already exists: $CLIENT_NAME"
  else
    "$CTL_PATH" add "$CLIENT_NAME"
  fi
}

verify_install() {
  systemctl is-active --quiet "awg-quick@${AWG_IFACE}" || die "awg-quick@${AWG_IFACE} is not active."
  awg show "$AWG_IFACE" >/dev/null || die "AmneziaWG interface is not available."
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    systemctl is-active --quiet nginx || die "nginx is not active."
  fi
}

main() {
  detect_os
  load_resume_config
  echo "AmneziaWG installer for Debian/Ubuntu."
  echo
  echo "Before running:"
  echo "  1. Use a clean server, especially when HTTPS masking uses TCP 80/443."
  echo "  2. If HTTPS masking is enabled, create DNS A record: <mask-domain> -> this server IPv4."
  echo "  3. Make sure the selected AmneziaWG UDP port is reachable from the internet."
  echo "  4. Keep the current SSH session open until a second login works."
  echo
  prompt_config
  print_plan

  run_step "backup" "Backup current state" backup_state
  run_step "packages" "Install base packages" install_packages
  run_step "ports" "Port preflight" port_preflight
  run_step "awg_tools" "Install AmneziaWG tools" install_amneziawg_tools
  run_step "mask_packages" "Install nginx/certbot if needed" install_mask_packages
  run_step "sysctl" "Enable IPv4 forwarding" configure_sysctl
  run_step "server_keys" "Generate server keys" generate_server_keys
  run_step "env" "Write control environment" write_env
  run_step "config" "Write AmneziaWG config" write_awg_config
  run_step "ctl" "Install awgctl" install_awgctl
  run_step "firewall" "Open firewall ports if ufw is active" configure_firewall
  run_step "mask" "Configure HTTPS mask if enabled" setup_https_mask
  run_step "service" "Start AmneziaWG" start_service
  run_step "first_client" "Create first client" ensure_first_client
  run_step "verify" "Verify" verify_install
  mark_done "done"
  save_resume_config

  step "Done"
  cat <<EOF
Installed AmneziaWG.

Endpoint: ${PUBLIC_ENDPOINT}:${AWG_PORT}/udp
Interface: ${AWG_IFACE}
HTTPS mask site: $([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo "https://${MASK_DOMAIN}/ on TCP 443" || echo no)
First client: ${CLIENT_NAME}

Client config:
  ${CLIENT_OUT_DIR}/${CLIENT_NAME}.conf

Show QR:
  awgctl qr ${CLIENT_NAME}

Manage clients:
  awgctl add
  awgctl delete
  awgctl list
  awgctl show
  awgctl qr
  awgctl traffic

Backups:
  ${BACKUP_DIR}
EOF
}

main "$@"
