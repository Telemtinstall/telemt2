#!/usr/bin/env bash
set -Eeuo pipefail

# VLESS + WebSocket installer for a fresh Debian/Ubuntu server.
# Mask mode configures nginx as the public HTTPS frontend and Xray as a local backend.
# Direct mode exposes Xray WebSocket directly without a mask site or TLS certificate.

XRAY_INSTALL_SCRIPT_URL="${XRAY_INSTALL_SCRIPT_URL:-https://github.com/XTLS/Xray-install/raw/main/install-release.sh}"

PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
CLIENT_NAME="${CLIENT_NAME:-}"
DEFAULT_CLIENT_NAME="${DEFAULT_CLIENT_NAME:-pipiska1}"
FRONTEND_MODE="${FRONTEND_MODE:-}"
HTTPS_PORT="${HTTPS_PORT:-443}"
LOCAL_PORT="${LOCAL_PORT:-12710}"
XRAY_API_LISTEN="${XRAY_API_LISTEN:-127.0.0.1:10085}"
VLESS_PATH="${VLESS_PATH:-}"
ENABLE_ACCESS_LOGS="${ENABLE_ACCESS_LOGS:-0}"
XRAY_FORCE_IPV4="${XRAY_FORCE_IPV4:-1}"
ASSUME_YES="${ASSUME_YES:-0}"
INSTALL_RETRIES="${INSTALL_RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-5}"

CONFIG_DIR="/usr/local/etc/xray"
ENV_FILE="$CONFIG_DIR/vless.env"
USERS_FILE="$CONFIG_DIR/users.json"
CONFIG_FILE="$CONFIG_DIR/config.json"
CTL_PATH="/usr/local/sbin/vlessctl"
BACKUP_ROOT="/root/vless-install-backups"
LINKS_FILE="/root/vless-links.txt"
STATE_FILE="/root/.install_vless.state"
RESUME_CONFIG="/root/.install_vless.config"
EXISTING_INSTALL=0

step_no=0
BACKUP_DIR=""
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

step() {
  step_no=$((step_no + 1))
  printf '\n[%02d] %s\n' "$step_no" "$1"
}

die() {
  echo "ОШИБКА: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

usage() {
  cat <<'EOF'
Usage:
  ./install_vless.sh [--auto] [--mask|--direct]

Options:
  --auto, -y, --yes, --assume-yes
      Use defaults, continue without interactive confirmations, and require PUBLIC_HOST
      when mask mode is selected.
  --mask
      Use domain + HTTPS mask mode.
  --direct
      Use direct WebSocket mode without nginx/certbot mask site.
  -h, --help
      Show this help.

Useful examples:
  PUBLIC_HOST=proxy.example.com ./install_vless.sh --auto
  FRONTEND_MODE=direct ./install_vless.sh --auto
  RESET_INSTALL_STATE=1 PUBLIC_HOST=proxy.example.com CLIENT_NAME=pipiska1 ./install_vless.sh --auto
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --auto|-y|--yes|--assume-yes)
        ASSUME_YES=1
        ;;
      --mask)
        FRONTEND_MODE="mask"
        ;;
      --direct)
        FRONTEND_MODE="direct"
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "неизвестный аргумент: $1"
        ;;
    esac
    shift
  done
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
      echo "ОШИБКА: ${label} не выполнено после ${INSTALL_RETRIES} попыток." >&2
      return "$rc"
    fi

    echo "ПРЕДУПРЕЖДЕНИЕ: ${label} завершилось с кодом ${rc}. Повтор через ${RETRY_DELAY_SECONDS}s (${attempt}/${INSTALL_RETRIES})..." >&2
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
PUBLIC_HOST=$(printf '%q' "$PUBLIC_HOST")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
LETSENCRYPT_EMAIL=$(printf '%q' "$LETSENCRYPT_EMAIL")
CLIENT_NAME=$(printf '%q' "$CLIENT_NAME")
HTTPS_PORT=$(printf '%q' "$HTTPS_PORT")
LOCAL_PORT=$(printf '%q' "$LOCAL_PORT")
XRAY_API_LISTEN=$(printf '%q' "$XRAY_API_LISTEN")
VLESS_PATH=$(printf '%q' "$VLESS_PATH")
ENABLE_ACCESS_LOGS=$(printf '%q' "$ENABLE_ACCESS_LOGS")
XRAY_FORCE_IPV4=$(printf '%q' "$XRAY_FORCE_IPV4")
FRONTEND_MODE=$(printf '%q' "$FRONTEND_MODE")
BACKUP_DIR=$(printf '%q' "$BACKUP_DIR")
EOF
  chmod 600 "$RESUME_CONFIG"
}

load_resume_config() {
  if [[ "${RESET_INSTALL_STATE:-0}" == "1" ]]; then
    rm -f "$STATE_FILE" "$RESUME_CONFIG"
    return 0
  fi
  if [[ -f "$RESUME_CONFIG" ]]; then
    # shellcheck disable=SC1090
    . "$RESUME_CONFIG"
  fi
}

confirm() {
  local prompt_text="$1"
  local answer=""
  if [[ "$ASSUME_YES" == "1" ]]; then
    echo "$prompt_text y"
    return 0
  fi
  read -r -p "$prompt_text" answer
  answer="$(trim_value "$answer")"
  answer="${answer,,}"
  [[ "$answer" == "y" || "$answer" == "yes" ]]
}

prompt() {
  local var="$1"
  local label="$2"
  local default_value="${3:-}"
  local answer=""
  local current_value="${!var:-}"

  if [[ "$ASSUME_YES" == "1" ]]; then
    if [[ -n "$current_value" ]]; then
      printf '%s: %s\n' "$label" "$current_value"
      return 0
    fi
    if [[ -n "$default_value" ]]; then
      printf -v "$var" '%s' "$default_value"
      printf '%s: %s\n' "$label" "$default_value"
      return 0
    fi
    die "автоматический режим не знает значение '${label}'. Укажите переменную окружения перед запуском."
  fi

  if [[ -n "$current_value" && -z "$default_value" ]]; then
    default_value="$current_value"
  fi

  if [[ -n "$current_value" && "$current_value" != "$default_value" ]]; then
    default_value="$current_value"
  fi

  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value"
  else
    printf '%s: ' "$label"
  fi
  read -r answer

  if [[ -n "$answer" ]]; then
    printf -v "$var" '%s' "$answer"
    return 0
  fi
  printf -v "$var" '%s' "$default_value"
}

valid_domain() {
  local domain="$1"
  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_public_host() {
  valid_domain "$1" || is_public_ipv4 "$1"
}

valid_frontend_mode() {
  [[ "$1" == "mask" || "$1" == "direct" ]]
}

valid_client_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_retry_number() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 20 ))
}

valid_api_listen() {
  local listen="$1"
  local port="${listen##*:}"
  [[ "$listen" =~ ^127\.0\.0\.1:[0-9]+$ ]] && valid_port "$port"
}

normalize_bool() {
  local value
  value="$(trim_value "$1")"
  case "${value,,}" in
    1|y|yes|true|on) echo "1" ;;
    0|n|no|false|off|"") echo "0" ;;
    *) die "для access logs используйте yes/no." ;;
  esac
}

normalize_yes_no() {
  local value
  local label="${2:-answer}"
  value="$(trim_value "$1")"
  case "${value,,}" in
    1|y|yes|true|on) echo "1" ;;
    0|n|no|false|off|"") echo "0" ;;
    *) die "для '${label}' используйте yes/no." ;;
  esac
}

bool_enabled() {
  local value
  value="$(trim_value "$1")"
  case "${value,,}" in
    1|y|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

bool_word() {
  if bool_enabled "$1"; then
    echo "yes"
  else
    echo "no"
  fi
}

nginx_access_log_line() {
  if bool_enabled "$ENABLE_ACCESS_LOGS"; then
    printf 'access_log /var/log/nginx/vless-%s-access.log combined;' "$PUBLIC_HOST"
  else
    printf 'access_log off;'
  fi
}

access_log_prompt_label() {
  if [[ "$FRONTEND_MODE" == "direct" ]]; then
    echo "Enable Xray access logs? yes/no"
  else
    echo "Enable nginx/Xray access logs? yes/no"
  fi
}

valid_path() {
  [[ "$1" =~ ^/[A-Za-z0-9._~/-]{4,128}$ ]]
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
  (( a == 0 )) && return 1
  (( a == 127 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 192 && b == 0 && c == 2 )) && return 1
  (( a == 198 && b == 18 )) && return 1
  (( a == 198 && b == 19 )) && return 1
  (( a == 198 && b == 51 && c == 100 )) && return 1
  (( a == 203 && b == 0 && c == 113 )) && return 1
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

detect_os() {
  [[ $EUID -eq 0 ]] || die "запустите установщик от root."
  [[ -r /etc/os-release ]] || die "не удалось определить ОС: нет /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "поддерживаются только Debian/Ubuntu. Обнаружено: ID=${ID:-unknown}." ;;
  esac
  have systemctl || die "нужен systemd."
  have apt-get || die "нужен apt-get."
}

install_base_tools() {
  export DEBIAN_FRONTEND=noninteractive
  retry_command "apt-get update" apt-get update
  retry_command "apt-get install base tools" apt-get install -y ca-certificates curl jq openssl iproute2 unzip lsb-release qrencode
}

detect_public_ip() {
  if [[ -n "$PUBLIC_IP" ]]; then
    is_public_ipv4 "$PUBLIC_IP" || die "PUBLIC_IP не является публичным IPv4: $PUBLIC_IP"
    return 0
  fi

  if have curl; then
    PUBLIC_IP="$(curl -4fsS --max-time 10 https://api.ipify.org || true)"
  elif have wget; then
    PUBLIC_IP="$(wget -4 -qO- -T 10 https://api.ipify.org 2>/dev/null || true)"
  elif have python3; then
    PUBLIC_IP="$(python3 - <<'PY' 2>/dev/null || true
import urllib.request
print(urllib.request.urlopen("https://api.ipify.org", timeout=10).read().decode())
PY
)"
  elif have ip; then
    PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  else
    die "не удалось определить публичный IPv4 до установки пакетов. Запустите так: PUBLIC_IP=<SERVER_PUBLIC_IP> ./install_vless.sh"
  fi
  is_public_ipv4 "$PUBLIC_IP" || die "не удалось определить публичный IPv4 этого сервера."
}

resolve_ipv4() {
  local domain="$1"
  getent ahostsv4 "$domain" | awk '{print $1}' | sort -u
}

port_listeners() {
  local port="$1"
  ss -H -ltnp 2>/dev/null | awk -v p=":${port}" '$4 ~ p"$" {print}'
}

port_in_use() {
  [[ -n "$(port_listeners "$1")" ]]
}

listener_active() {
  local port="$1"
  ss -H -ltn | awk -v p=":${port}" '$4 ~ p"$" {found=1} END {exit found ? 0 : 1}'
}

wait_for_listener() {
  local port="$1"
  local attempt
  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    if listener_active "$port"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

nginx_has_foreign_sites() {
  local found=0
  [[ -d /etc/nginx/sites-enabled ]] || return 1
  while IFS= read -r entry; do
    case "$(basename "$entry")" in
      default|"vless-${PUBLIC_HOST}.conf") ;;
      *) found=1 ;;
    esac
  done < <(find /etc/nginx/sites-enabled -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  (( found == 1 ))
}

preflight() {
  local api_port="${XRAY_API_LISTEN##*:}"

  if (( EXISTING_INSTALL == 0 )); then
    if [[ "$FRONTEND_MODE" == "mask" ]]; then
      if port_in_use 80; then
        echo "Port 80 listeners:"
        port_listeners 80 || true
        die "80/tcp уже занят. Используйте чистый сервер или остановите конфликтующий сервис."
      fi
    fi
    if port_in_use "$HTTPS_PORT"; then
      echo "Port $HTTPS_PORT listeners:"
      port_listeners "$HTTPS_PORT" || true
      die "$HTTPS_PORT/tcp уже занят. Используйте чистый сервер или выберите другой HTTPS/VLESS порт."
    fi
    if [[ "$FRONTEND_MODE" == "mask" ]]; then
      if port_in_use "$LOCAL_PORT"; then
        echo "Port $LOCAL_PORT listeners:"
        port_listeners "$LOCAL_PORT" || true
        die "$LOCAL_PORT/tcp уже занят. Выберите другой локальный порт Xray."
      fi
    fi
    if port_in_use "$api_port"; then
      echo "Port $api_port listeners:"
      port_listeners "$api_port" || true
      die "$api_port/tcp уже занят. Выберите другой локальный порт Xray API через XRAY_API_LISTEN=127.0.0.1:<port>."
    fi
    if [[ "$FRONTEND_MODE" == "mask" ]]; then
      if nginx_has_foreign_sites; then
        die "найдены чужие nginx sites. Используйте чистый сервер или интегрируйте вручную."
      fi
    fi
  fi
}

switch_to_direct_mode() {
  local reason="$1"

  cat >&2 <<EOF

Mask mode cannot continue:
  ${reason}

You can continue without a mask site. In that mode:
  - no domain certificate is issued;
  - nginx camouflage site is not installed;
  - Xray listens directly on ${PUBLIC_IP}:${HTTPS_PORT};
  - the client link uses security=none.

EOF

  if [[ "$ASSUME_YES" == "1" ]]; then
    die "режим mask не прошел проверку, а ASSUME_YES=1 не переключает установку в direct автоматически."
  fi

  if confirm "Continue without mask using ${PUBLIC_IP}? [y/N]: "; then
    FRONTEND_MODE="direct"
    PUBLIC_HOST="$PUBLIC_IP"
    LETSENCRYPT_EMAIL=""
    LOCAL_PORT="$HTTPS_PORT"
    save_resume_config
    return 0
  fi

  exit 1
}

early_preflight() {
  local resolved_ips
  local ip

  [[ -f "$SCRIPT_DIR/vlessctl.sh" ]] || die "vlessctl.sh должен лежать рядом с install_vless.sh."

  if [[ -f "$ENV_FILE" ]]; then
    EXISTING_INSTALL=1
    echo "Existing VLESS install detected: $ENV_FILE"
    confirm "Reconfigure this VLESS installation? [y/N]: " || die "отменено."
  elif [[ -e "$CONFIG_FILE" ]]; then
    die "конфиг Xray уже существует, но не управляется этим установщиком: $CONFIG_FILE"
  fi

  detect_public_ip
  echo "server_public_ipv4=$PUBLIC_IP"

  if [[ "$FRONTEND_MODE" == "direct" ]]; then
    PUBLIC_HOST="${PUBLIC_HOST:-$PUBLIC_IP}"
    if is_public_ipv4 "$PUBLIC_HOST"; then
      [[ "$PUBLIC_HOST" == "$PUBLIC_IP" ]] || die "в direct-режиме IP должен быть публичным IPv4 этого сервера: $PUBLIC_IP"
      echo "client_address=${PUBLIC_HOST}"
      save_resume_config
      return 0
    fi

    have getent || die "для проверки DNS нужен getent. Для direct-режима без домена используйте PUBLIC_HOST=${PUBLIC_IP}."
    resolved_ips="$(resolve_ipv4 "$PUBLIC_HOST" | tr '\n' ' ')"
    echo "domain_ipv4=${resolved_ips:-none}"
    if ! printf ' %s ' "$resolved_ips" | grep -q " $PUBLIC_IP "; then
      cat >&2 <<EOF

DNS warning.

${PUBLIC_HOST} does not resolve to this server IPv4.

Expected:
  ${PUBLIC_HOST} -> ${PUBLIC_IP}

Current A records:
  ${resolved_ips:-none}
EOF
      if [[ "$ASSUME_YES" == "1" ]]; then
        die "домен direct-режима не указывает на этот сервер. Используйте PUBLIC_HOST=${PUBLIC_IP} или исправьте DNS."
      fi
      if confirm "Use ${PUBLIC_IP} in the client link instead? [y/N]: "; then
        PUBLIC_HOST="$PUBLIC_IP"
        save_resume_config
        return 0
      fi
      exit 1
    fi
    save_resume_config
    return 0
  fi

  have getent || die "для ранней DNS-проверки нужен getent."
  resolved_ips="$(resolve_ipv4 "$PUBLIC_HOST" | tr '\n' ' ')"
  echo "domain_ipv4=${resolved_ips:-none}"

  if [[ -z "$resolved_ips" ]]; then
    cat >&2 <<EOF

DNS check failed.

${PUBLIC_HOST} has no IPv4 A record.

Create DNS A record first:
  ${PUBLIC_HOST} -> ${PUBLIC_IP}

Then rerun this script.
EOF
    switch_to_direct_mode "${PUBLIC_HOST} has no IPv4 A record."
    return 0
  fi

  for ip in $resolved_ips; do
    if ! is_public_ipv4 "$ip"; then
      cat >&2 <<EOF

DNS check failed.

${PUBLIC_HOST} resolves to a non-public IPv4 address:
  ${ip}

Let's Encrypt needs a public A record:
  ${PUBLIC_HOST} -> ${PUBLIC_IP}

Fix DNS and rerun this script.
EOF
      switch_to_direct_mode "${PUBLIC_HOST} resolves to non-public IPv4 ${ip}."
      return 0
    fi
  done

  if ! printf ' %s ' "$resolved_ips" | grep -q " $PUBLIC_IP "; then
    cat >&2 <<EOF

DNS check failed.

${PUBLIC_HOST} must resolve to this server IPv4 before SSL can be issued.

Expected:
  ${PUBLIC_HOST} -> ${PUBLIC_IP}

Current A records:
  ${resolved_ips}

Fix DNS and rerun this script.
EOF
    switch_to_direct_mode "${PUBLIC_HOST} does not resolve to this server IPv4."
    return 0
  fi
}

create_backup_dir() {
  BACKUP_DIR="${BACKUP_DIR:-${BACKUP_ROOT}/$(date -u +%Y%m%d-%H%M%S)}"
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  save_resume_config
}

install_runtime_packages() {
  export DEBIAN_FRONTEND=noninteractive
  retry_command "apt-get install nginx/certbot" apt-get install -y nginx certbot
}

install_xray() {
  local tmp_script
  tmp_script="$(mktemp)"
  retry_command "download Xray install script" curl -fsSL "$XRAY_INSTALL_SCRIPT_URL" -o "$tmp_script"
  retry_command "install Xray" bash "$tmp_script" install
  rm -f "$tmp_script"
  systemctl stop xray 2>/dev/null || true
}

configure_xray_user() {
  if ! id -u xray >/dev/null 2>&1; then
    useradd --system --home-dir /var/lib/xray --shell /usr/sbin/nologin xray
  fi
  install -d -m 0750 -o xray -g xray "$CONFIG_DIR"
  install -d -m 0750 -o xray -g xray /var/lib/xray
  install -d -m 0750 -o xray -g xray /var/log/xray
  touch /var/log/xray/access.log /var/log/xray/error.log
  chown xray:xray /var/log/xray/access.log /var/log/xray/error.log
  chmod 0640 /var/log/xray/access.log /var/log/xray/error.log
  install -d -m 0755 /etc/systemd/system/xray.service.d
  write_file_root /etc/systemd/system/xray.service.d/10-vless-user.conf 0644 root:root <<'EOF'
[Service]
User=xray
Group=xray
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=full
ReadWritePaths=/usr/local/etc/xray /var/lib/xray /var/log/xray
EOF
}

disable_default_nginx_site() {
  if [[ -L /etc/nginx/sites-enabled/default ]]; then
    backup_path /etc/nginx/sites-enabled/default
    rm -f /etc/nginx/sites-enabled/default
  fi
}

write_mask_site() {
  local web_root="/var/www/${PUBLIC_HOST}"
  install -d -m 0755 "$web_root"
  write_file_root "$web_root/index.html" 0644 root:root <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${PUBLIC_HOST}</title>
</head>
<body>
  <h1>${PUBLIC_HOST}</h1>
</body>
</html>
EOF
}

write_nginx_http_config() {
  local site_available="/etc/nginx/sites-available/vless-${PUBLIC_HOST}.conf"
  local site_enabled="/etc/nginx/sites-enabled/vless-${PUBLIC_HOST}.conf"
  local web_root="/var/www/${PUBLIC_HOST}"
  local access_log_line

  access_log_line="$(nginx_access_log_line)"
  backup_path "$site_available"
  write_file_root "$site_available" 0644 root:root <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PUBLIC_HOST};

    root ${web_root};
    ${access_log_line}
    error_log /var/log/nginx/vless-${PUBLIC_HOST}-error.log crit;

    location ^~ /.well-known/acme-challenge/ {
        root ${web_root};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  ln -sfn "$site_available" "$site_enabled"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_certificate() {
  local web_root="/var/www/${PUBLIC_HOST}"
  retry_command "issue Let's Encrypt certificate" certbot certonly \
    --webroot \
    -w "$web_root" \
    -d "$PUBLIC_HOST" \
    --agree-tos \
    -m "$LETSENCRYPT_EMAIL" \
    --non-interactive \
    --keep-until-expiring

  if systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer
  fi

  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  write_file_root /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-vless.sh 0755 root:root <<'EOF'
#!/usr/bin/env sh
systemctl reload nginx >/dev/null 2>&1 || true
EOF
}

write_nginx_final_config() {
  local site_available="/etc/nginx/sites-available/vless-${PUBLIC_HOST}.conf"
  local web_root="/var/www/${PUBLIC_HOST}"
  local redirect_target
  local access_log_line

  access_log_line="$(nginx_access_log_line)"
  if [[ "$HTTPS_PORT" == "443" ]]; then
    redirect_target="https://\$host\$request_uri"
  else
    redirect_target="https://\$host:${HTTPS_PORT}\$request_uri"
  fi

  backup_path "$site_available"
  write_file_root "$site_available" 0644 root:root <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PUBLIC_HOST};

    root ${web_root};
    ${access_log_line}
    error_log /var/log/nginx/vless-${PUBLIC_HOST}-error.log crit;

    location ^~ /.well-known/acme-challenge/ {
        root ${web_root};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 ${redirect_target};
    }
}

server {
    listen ${HTTPS_PORT} ssl;
    listen [::]:${HTTPS_PORT} ssl;
    server_name ${PUBLIC_HOST};

    ssl_certificate /etc/letsencrypt/live/${PUBLIC_HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PUBLIC_HOST}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    root ${web_root};
    index index.html;

    ${access_log_line}
    error_log /var/log/nginx/vless-${PUBLIC_HOST}-error.log crit;

    location = ${VLESS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${LOCAL_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  nginx -t
  systemctl reload nginx
}

write_vless_env() {
  install -d -m 0750 -o xray -g xray "$CONFIG_DIR"
  umask 077
  cat > "$ENV_FILE" <<EOF
PUBLIC_HOST=$(printf '%q' "$PUBLIC_HOST")
HTTPS_PORT=$(printf '%q' "$HTTPS_PORT")
LOCAL_PORT=$(printf '%q' "$LOCAL_PORT")
XRAY_API_LISTEN=$(printf '%q' "$XRAY_API_LISTEN")
VLESS_PATH=$(printf '%q' "$VLESS_PATH")
ENABLE_ACCESS_LOGS=$(printf '%q' "$ENABLE_ACCESS_LOGS")
XRAY_FORCE_IPV4=$(printf '%q' "$XRAY_FORCE_IPV4")
FRONTEND_MODE=$(printf '%q' "$FRONTEND_MODE")
CONFIG_FILE=$(printf '%q' "$CONFIG_FILE")
USERS_FILE=$(printf '%q' "$USERS_FILE")
EOF
  chown xray:xray "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

install_vlessctl() {
  install -m 0755 "$SCRIPT_DIR/vlessctl.sh" "$CTL_PATH"
}

print_install_qr() {
  local link
  [[ -s "$LINKS_FILE" ]] || return 0
  if ! have qrencode; then
    echo "QR клиента:"
    echo "  qrencode is not installed; run: apt-get install -y qrencode"
    return 0
  fi
  link="$(cat "$LINKS_FILE")"
  echo "QR клиента:"
  qrencode -t ANSIUTF8 "$link"
}

new_uuid() {
  if have xray; then
    xray uuid
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  fi
}

init_first_user() {
  local uuid
  local created_at
  uuid="$(new_uuid)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ -f "$USERS_FILE" ]]; then
    backup_path "$USERS_FILE"
  fi

  jq -n \
    --arg name "$CLIENT_NAME" \
    --arg uuid "$uuid" \
    --arg created_at "$created_at" \
    '[{name:$name, uuid:$uuid, created_at:$created_at}]' > "$USERS_FILE"
  chown xray:xray "$USERS_FILE"
  chmod 600 "$USERS_FILE"
}

configure_firewall() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    if [[ "$FRONTEND_MODE" == "mask" ]]; then
      ufw allow 80/tcp
    fi
    ufw allow "${HTTPS_PORT}/tcp"
  fi
}

write_links_file() {
  "$CTL_PATH" show "$CLIENT_NAME" > "$LINKS_FILE"
  chmod 600 "$LINKS_FILE"
}

setup_nginx_certbot() {
  install_runtime_packages
  disable_default_nginx_site
  write_mask_site
  write_nginx_http_config
}

setup_xray_runtime() {
  install_xray
  configure_xray_user
  install_vlessctl
}

write_vless_config() {
  backup_path "$CONFIG_FILE"
  write_vless_env
  init_first_user
  "$CTL_PATH" render
}

start_services() {
  systemctl daemon-reload
  systemctl enable --now xray
  systemctl restart xray
  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    systemctl reload nginx
  fi
  configure_firewall
}

verify_install() {
  if ! systemctl is-active --quiet xray; then
    systemctl --no-pager --full status xray || true
    journalctl -u xray -n 60 --no-pager || true
    die "сервис xray не активен."
  fi
  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    if ! systemctl is-active --quiet nginx; then
      systemctl --no-pager --full status nginx || true
      journalctl -u nginx -n 60 --no-pager || true
      die "сервис nginx не активен."
    fi
    if ! curl -fsSI --resolve "${PUBLIC_HOST}:${HTTPS_PORT}:${PUBLIC_IP}" "https://${PUBLIC_HOST}:${HTTPS_PORT}/" >/dev/null; then
      die "HTTPS-проверка не прошла для https://${PUBLIC_HOST}:${HTTPS_PORT}/."
    fi
  else
    if ! wait_for_listener "$HTTPS_PORT"; then
      die "direct VLESS не слушает ${HTTPS_PORT}/tcp."
    fi
  fi
  write_links_file
}

main() {
  local api_port
  local logs_default
  local mask_answer

  load_resume_config
  parse_args "$@"
  detect_os

  cat <<'EOF'
VLESS WebSocket installer for Debian/Ubuntu.

Before running:
  1. Use a clean server.
  2. Create DNS A record: <domain> -> this server IPv4.
  3. Make sure ports 80 and 443 are reachable from the internet.
  4. Keep the current SSH session open until a second login works.

EOF

  mask_answer="yes"
  [[ "$FRONTEND_MODE" == "direct" ]] && mask_answer="no"
  prompt mask_answer "Use domain + HTTPS mask site? yes/no" "$mask_answer"
  mask_answer="$(normalize_yes_no "$mask_answer" "mask mode")"
  if [[ "$mask_answer" == "1" ]]; then
    FRONTEND_MODE="mask"
  else
    FRONTEND_MODE="direct"
  fi
  valid_frontend_mode "$FRONTEND_MODE" || die "FRONTEND_MODE должен быть mask или direct."

  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    prompt PUBLIC_HOST "Proxy domain" "$PUBLIC_HOST"
    if is_public_ipv4 "$PUBLIC_HOST"; then
      echo "IP address was entered. A mask site needs a domain and Let's Encrypt certificate."
      if confirm "Continue without mask using ${PUBLIC_HOST}? [y/N]: "; then
        FRONTEND_MODE="direct"
      else
        die "для режима mask укажите домен."
      fi
    elif ! valid_domain "$PUBLIC_HOST"; then
      die "домен должен быть корректным DNS-именем, например proxy.example.com."
    fi
  fi

  if [[ "$FRONTEND_MODE" == "direct" ]]; then
    if [[ -z "$PUBLIC_HOST" ]]; then
      detect_public_ip
      PUBLIC_HOST="$PUBLIC_IP"
    fi
    prompt PUBLIC_HOST "Server IP/host for VLESS link" "$PUBLIC_HOST"
    valid_public_host "$PUBLIC_HOST" || die "IP/host сервера должен быть публичным IPv4 или DNS-именем."
  fi

  VLESS_PATH="${VLESS_PATH:-/vless-$(openssl rand -hex 8 2>/dev/null || date +%s)}"

  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@${PUBLIC_HOST}}"
    prompt LETSENCRYPT_EMAIL "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
  else
    LETSENCRYPT_EMAIL=""
  fi
  CLIENT_NAME="${CLIENT_NAME:-$DEFAULT_CLIENT_NAME}"
  prompt CLIENT_NAME "First client name" "$CLIENT_NAME"
  prompt HTTPS_PORT "HTTPS/VLESS external port" "$HTTPS_PORT"
  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    prompt LOCAL_PORT "Local Xray port" "$LOCAL_PORT"
  else
    LOCAL_PORT="$HTTPS_PORT"
  fi
  prompt VLESS_PATH "VLESS WebSocket path" "$VLESS_PATH"
  logs_default="$(bool_word "$ENABLE_ACCESS_LOGS")"
  prompt ENABLE_ACCESS_LOGS "$(access_log_prompt_label)" "$logs_default"
  ENABLE_ACCESS_LOGS="$(normalize_bool "$ENABLE_ACCESS_LOGS")"

  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    [[ "$LETSENCRYPT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "email должен быть обычным адресом."
  fi
  valid_client_name "$CLIENT_NAME" || die "имя клиента должно быть 1-64 символа: буквы, цифры, точка, underscore, дефис, @."
  valid_port "$HTTPS_PORT" || die "HTTPS/VLESS порт должен быть числом от 1 до 65535."
  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    valid_port "$LOCAL_PORT" || die "локальный порт Xray должен быть числом от 1 до 65535."
  fi
  valid_api_listen "$XRAY_API_LISTEN" || die "XRAY_API_LISTEN должен быть 127.0.0.1:<port>."
  api_port="${XRAY_API_LISTEN##*:}"
  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    [[ "$HTTPS_PORT" != "80" ]] || die "HTTPS/VLESS порт не может быть 80, потому что 80 используется для Let's Encrypt."
    [[ "$LOCAL_PORT" != "80" && "$LOCAL_PORT" != "$HTTPS_PORT" ]] || die "локальный порт Xray не должен совпадать с 80 или внешним HTTPS-портом."
    [[ "$api_port" != "80" && "$api_port" != "$HTTPS_PORT" && "$api_port" != "$LOCAL_PORT" ]] || die "порт Xray API не должен совпадать с 80, HTTPS-портом или локальным портом Xray."
  else
    [[ "$api_port" != "$HTTPS_PORT" ]] || die "порт Xray API не должен совпадать с внешним VLESS-портом."
  fi
  valid_path "$VLESS_PATH" || die "VLESS path должен начинаться с / и содержать только A-Z, a-z, 0-9, точку, дефис, underscore, тильду и slash."
  valid_retry_number "$INSTALL_RETRIES" || die "INSTALL_RETRIES должен быть числом от 1 до 20."
  valid_retry_number "$RETRY_DELAY_SECONDS" || die "RETRY_DELAY_SECONDS должен быть числом от 1 до 20."

  save_resume_config

  run_step "early_preflight" "Early DNS preflight" early_preflight
  run_step "base_tools" "Install base tools" install_base_tools
  run_step "port_preflight" "Port preflight" preflight

  cat <<EOF

Install plan:
  mode:         ${FRONTEND_MODE}
  domain:       ${PUBLIC_HOST}
  public IPv4:  ${PUBLIC_IP}
  email:        ${LETSENCRYPT_EMAIL:-not used}
  HTTPS port:   ${HTTPS_PORT}
  local port:   ${LOCAL_PORT}
  stats API:    ${XRAY_API_LISTEN}
  VLESS path:   ${VLESS_PATH}
  access logs:  $(bool_word "$ENABLE_ACCESS_LOGS")
  first client: ${CLIENT_NAME}

Type y or yes to continue:
EOF
  if step_done "confirmed"; then
    echo "Install plan already confirmed."
  elif [[ "$ASSUME_YES" != "1" ]]; then
    read -r answer
    answer="$(trim_value "$answer")"
    answer="${answer,,}"
    [[ "$answer" == "y" || "$answer" == "yes" ]] || die "отменено."
    mark_done "confirmed"
  else
    echo "ASSUME_YES=1, continuing."
    mark_done "confirmed"
  fi

  create_backup_dir

  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    run_step "install_nginx_certbot" "Install nginx and certbot" setup_nginx_certbot
    run_step "issue_certificate" "Issue Let's Encrypt certificate" issue_certificate
  else
    step "Install nginx and certbot (skipped: direct mode)"
    step "Issue Let's Encrypt certificate (skipped: direct mode)"
  fi
  run_step "install_xray" "Install Xray" setup_xray_runtime
  run_step "write_config" "Write VLESS config" write_vless_config
  if [[ "$FRONTEND_MODE" == "mask" ]]; then
    run_step "nginx_tls" "Configure nginx TLS frontend" write_nginx_final_config
  else
    step "Configure nginx TLS frontend (skipped: direct mode)"
  fi
  run_step "start_services" "Start services" start_services
  run_step "verify" "Verify" verify_install
  mark_done "done"
  save_resume_config

  step "Done"
  cat <<EOF
Installed VLESS WebSocket.

Mode: ${FRONTEND_MODE}
Proxy host: ${PUBLIC_HOST}:${HTTPS_PORT}
VLESS path: ${VLESS_PATH}
Access logs: $(bool_word "$ENABLE_ACCESS_LOGS")
First client: ${CLIENT_NAME}
Client link:
$(cat "$LINKS_FILE")

$(print_install_qr)

Manage users:
  vlessctl add
  vlessctl delete
  vlessctl list
  vlessctl show
  vlessctl qr
  vlessctl traffic
  vlessctl online

Saved link:
  ${LINKS_FILE}

Backups:
  ${BACKUP_DIR}
EOF
}

main "$@"
