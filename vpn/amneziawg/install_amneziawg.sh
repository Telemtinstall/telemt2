#!/usr/bin/env bash
set -Eeuo pipefail

# AmneziaWG installer for a fresh Debian/Ubuntu server.
# Modes:
#   1. Plain AmneziaWG: UDP 51820 by default.
#   2. HTTPS mask site: nginx serves a real HTTPS site on TCP 443,
#      AmneziaWG listens on UDP 443. TCP and UDP do not conflict.

PUBLIC_ENDPOINT="${PUBLIC_ENDPOINT:-}"
AWG_IFACE="${AWG_IFACE:-awg0}"
AWG_PORT="${AWG_PORT:-1234}"
AWG_SUBNET="${AWG_SUBNET:-10.88.88.0/24}"
AWG_SERVER_IP="${AWG_SERVER_IP:-10.88.88.1}"
AWG_DNS="${AWG_DNS:-1.1.1.1,8.8.8.8}"
AWG_MTU="${AWG_MTU:-1280}"
AWG_OBFS_PROFILE="${AWG_OBFS_PROFILE:-mobile}"
CLIENT_NAME="${CLIENT_NAME:-}"
AWG_JC="${AWG_JC:-}"
AWG_JMIN="${AWG_JMIN:-}"
AWG_JMAX="${AWG_JMAX:-}"
AWG_S1="${AWG_S1:-}"
AWG_S2="${AWG_S2:-}"
AWG_S3="${AWG_S3:-}"
AWG_S4="${AWG_S4:-}"
AWG_H1="${AWG_H1:-}"
AWG_H2="${AWG_H2:-}"
AWG_H3="${AWG_H3:-}"
AWG_H4="${AWG_H4:-}"
AWG_I1="${AWG_I1:-}"
AWG_I2="${AWG_I2:-}"
AWG_I3="${AWG_I3:-}"
AWG_I4="${AWG_I4:-}"
AWG_I5="${AWG_I5:-}"
ENABLE_HTTPS_MASK="${ENABLE_HTTPS_MASK:-0}"
MASK_DOMAIN="${MASK_DOMAIN:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
ENABLE_NGINX_LOGS="${ENABLE_NGINX_LOGS:-0}"
ASSUME_YES="${ASSUME_YES:-0}"
INSTALL_RETRIES="${INSTALL_RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-5}"
AWG_PPA_CODENAME="${AWG_PPA_CODENAME:-}"

AWG_DIR="/etc/amnezia/amneziawg"
CLIENT_DIR="$AWG_DIR/clients"
CLIENT_OUT_DIR="/root/amneziawg-clients"
MASK_ROOT_BASE="/var/www"
ENV_FILE="$AWG_DIR/awgctl.env"
CTL_PATH="/usr/local/sbin/awgctl"
STATE_FILE="/root/.install_amneziawg.state"
RESUME_CONFIG="/root/.install_amneziawg.config"
CONFIG_HASH_FILE="/root/.install_amneziawg.config.sha256"
BACKUP_ROOT="/root/amneziawg-install-backups"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

step_no=0
BACKUP_DIR=""
SERVER_PUBLIC_IPV4=""
LAST_STEP=""

step() {
  step_no=$((step_no + 1))
  printf '\n[%02d] %s\n' "$step_no" "$1"
}

die() {
  echo "ОШИБКА: $*" >&2
  exit 1
}

warn() {
  echo "ПРЕДУПРЕЖДЕНИЕ: $*" >&2
}

on_unhandled_error() {
  local rc="$1"
  local line="$2"
  local cmd="$3"

  echo >&2
  echo "ОШИБКА: скрипт остановился неожиданно." >&2
  [[ -n "$LAST_STEP" ]] && echo "Шаг: $LAST_STEP" >&2
  echo "Строка: $line" >&2
  echo "Команда: $cmd" >&2
  echo "Что делать: пришлите этот блок и последние строки вывода установщика." >&2
  exit "$rc"
}

trap 'on_unhandled_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

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
      echo "ОШИБКА: не удалось выполнить: ${label}. Попыток: ${INSTALL_RETRIES}." >&2
      return "$rc"
    fi
    warn "не удалось выполнить: ${label} (код ${rc}). Повтор через ${RETRY_DELAY_SECONDS}s (${attempt}/${INSTALL_RETRIES})..."
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
    step "$title (уже выполнено)"
    return 0
  fi
  step "$title"
  LAST_STEP="$title"
  if ! "$@"; then
    die "шаг не выполнен: $title"
  fi
  mark_done "$id"
  LAST_STEP=""
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
AWG_MTU=$(printf '%q' "$AWG_MTU")
AWG_OBFS_PROFILE=$(printf '%q' "$AWG_OBFS_PROFILE")
CLIENT_NAME=$(printf '%q' "$CLIENT_NAME")
AWG_JC=$(printf '%q' "$AWG_JC")
AWG_JMIN=$(printf '%q' "$AWG_JMIN")
AWG_JMAX=$(printf '%q' "$AWG_JMAX")
AWG_S1=$(printf '%q' "$AWG_S1")
AWG_S2=$(printf '%q' "$AWG_S2")
AWG_S3=$(printf '%q' "$AWG_S3")
AWG_S4=$(printf '%q' "$AWG_S4")
AWG_H1=$(printf '%q' "$AWG_H1")
AWG_H2=$(printf '%q' "$AWG_H2")
AWG_H3=$(printf '%q' "$AWG_H3")
AWG_H4=$(printf '%q' "$AWG_H4")
AWG_I1=$(printf '%q' "$AWG_I1")
AWG_I2=$(printf '%q' "$AWG_I2")
AWG_I3=$(printf '%q' "$AWG_I3")
AWG_I4=$(printf '%q' "$AWG_I4")
AWG_I5=$(printf '%q' "$AWG_I5")
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
    rm -f "$STATE_FILE" "$RESUME_CONFIG" "$CONFIG_HASH_FILE"
  fi
  if [[ -f "$RESUME_CONFIG" ]]; then
    echo "Найден resume-конфиг: $RESUME_CONFIG"
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
    echo "Конфиг изменился после прошлого запуска; очищаю список выполненных шагов."
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

valid_mtu() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 576 && "$1" <= 1420 ))
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
  local span rnd
  span=$((max - min + 1))
  if have od; then
    rnd="$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d '[:space:]' || true)"
  else
    rnd=""
  fi
  if [[ -z "$rnd" ]]; then
    rnd=$(( (RANDOM << 16) ^ RANDOM ))
  fi
  echo $((min + (rnd % span)))
}

normalize_obfs_profile() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    plain|compat|mobile|dns|awg1|awg2) printf '%s' "$value" ;;
    *) return 1 ;;
  esac
}

set_default() {
  local var_name="$1"
  local value="$2"
  if [[ -z "${!var_name:-}" ]]; then
    printf -v "$var_name" '%s' "$value"
  fi
}

ensure_unique_fixed_headers() {
  local var_name value seen_values=" "

  for var_name in AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
    if [[ -z "${!var_name:-}" ]]; then
      while :; do
        value="$(rand_range 5 2147483647)"
        [[ "$seen_values" != *" $value "* ]] && break
      done
      printf -v "$var_name" '%s' "$value"
    fi
    seen_values="${seen_values}${!var_name} "
  done
}

rand_header_range() {
  local min="$1"
  local max="$2"
  local width="$3"
  local start end
  start="$(rand_range "$min" "$((max - width))")"
  end=$((start + width))
  printf '%s-%s' "$start" "$end"
}

ensure_range_headers() {
  set_default AWG_H1 "$(rand_header_range 100000000 199999999 999)"
  set_default AWG_H2 "$(rand_header_range 500000000 599999999 999)"
  set_default AWG_H3 "$(rand_header_range 900000000 999999999 999)"
  set_default AWG_H4 "$(rand_header_range 1300000000 1799999999 999999)"
}

recommended_dns_i1() {
  printf '%s' '<r 2><b 0x8580000100010000000004796162730679616e6465780272750000010001c00c000100010000026d000457fa27d1>'
}

ensure_awg_obfuscation_params() {
  AWG_OBFS_PROFILE="$(normalize_obfs_profile "$AWG_OBFS_PROFILE")" || die "некорректный профиль обфускации: $AWG_OBFS_PROFILE. Варианты: mobile, dns, compat, awg1, awg2, plain."

  case "$AWG_OBFS_PROFILE" in
    plain)
      set_default AWG_JC 0
      set_default AWG_JMIN 0
      set_default AWG_JMAX 0
      set_default AWG_S1 0
      set_default AWG_S2 0
      set_default AWG_H1 0
      set_default AWG_H2 0
      set_default AWG_H3 0
      set_default AWG_H4 0
      ;;
    compat)
      set_default AWG_JC 6
      set_default AWG_JMIN 64
      set_default AWG_JMAX 128
      set_default AWG_S1 0
      set_default AWG_S2 0
      set_default AWG_H1 1
      set_default AWG_H2 2
      set_default AWG_H3 3
      set_default AWG_H4 4
      ;;
    mobile)
      set_default AWG_JC 6
      set_default AWG_JMIN 64
      set_default AWG_JMAX 192
      set_default AWG_S1 "$(rand_range 15 64)"
      set_default AWG_S2 "$(rand_range 15 64)"
      ensure_unique_fixed_headers
      ;;
    dns)
      set_default AWG_JC 6
      set_default AWG_JMIN 64
      set_default AWG_JMAX 192
      set_default AWG_S1 "$(rand_range 15 64)"
      set_default AWG_S2 "$(rand_range 15 64)"
      ensure_unique_fixed_headers
      set_default AWG_I1 "$(recommended_dns_i1)"
      ;;
    awg1)
      set_default AWG_JC "$(rand_range 6 10)"
      set_default AWG_JMIN "$(rand_range 64 128)"
      set_default AWG_JMAX "$(rand_range 129 512)"
      set_default AWG_S1 "$(rand_range 15 64)"
      set_default AWG_S2 "$(rand_range 15 64)"
      ensure_unique_fixed_headers
      ;;
    awg2)
      set_default AWG_JC 6
      set_default AWG_JMIN 64
      set_default AWG_JMAX 192
      set_default AWG_S1 "$(rand_range 15 64)"
      set_default AWG_S2 "$(rand_range 15 64)"
      set_default AWG_S3 "$(rand_range 0 64)"
      set_default AWG_S4 "$(rand_range 0 32)"
      ensure_range_headers
      set_default AWG_I1 "$(recommended_dns_i1)"
      ;;
  esac
}

valid_positive_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 0 ))
}

valid_range_int() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= "$2" && "$1" <= "$3" ))
}

header_minmax() {
  local value="$1"
  local min max
  if [[ "$value" =~ ^([0-9]+)-([0-9]+)$ ]]; then
    min="${BASH_REMATCH[1]}"
    max="${BASH_REMATCH[2]}"
  elif [[ "$value" =~ ^[0-9]+$ ]]; then
    min="$value"
    max="$value"
  else
    return 1
  fi

  (( min <= max && max <= 4294967295 )) || return 1
  printf '%s %s\n' "$min" "$max"
}

validate_awg_headers() {
  local labels values i j min_i max_i min_j max_j
  labels=(H1 H2 H3 H4)
  values=("$AWG_H1" "$AWG_H2" "$AWG_H3" "$AWG_H4")

  if [[ "$AWG_OBFS_PROFILE" == "plain" && "$AWG_H1" == "0" && "$AWG_H2" == "0" && "$AWG_H3" == "0" && "$AWG_H4" == "0" ]]; then
    return 0
  fi

  for i in "${!values[@]}"; do
    read -r min_i max_i < <(header_minmax "${values[$i]}") || die "некорректный ${labels[$i]}: ${values[$i]}. Нужно число или диапазон min-max."
    for (( j=i+1; j<${#values[@]}; j++ )); do
      read -r min_j max_j < <(header_minmax "${values[$j]}") || die "некорректный ${labels[$j]}: ${values[$j]}. Нужно число или диапазон min-max."
      if (( min_i <= max_j && min_j <= max_i )); then
        die "диапазоны ${labels[$i]}=${values[$i]} и ${labels[$j]}=${values[$j]} пересекаются. H1-H4 должны быть уникальными."
      fi
    done
  done
}

valid_awg_text_param() {
  local value="$1"
  [[ "$value" != *$'\n'* && ${#value} -lt 4096 ]]
}

detect_os() {
  [[ $EUID -eq 0 ]] || die "запустите скрипт от root."
  [[ -r /etc/os-release ]] || die "не удалось определить ОС: нет /etc/os-release."
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "поддерживаются только Debian/Ubuntu. Обнаружено: ID=${ID:-unknown}." ;;
  esac
  have systemctl || die "нужен systemd, но команда systemctl не найдена."
  have apt-get || die "нужен apt-get, но команда apt-get не найдена."
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
  local mask_answer logs_answer s1_max s2_max
  detect_public_ipv4 || true

  mask_answer="$([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo yes || echo no)"
  prompt mask_answer "Включить HTTPS-маскировку? yes/no" "$mask_answer"
  ENABLE_HTTPS_MASK="$(bool_value "$mask_answer")" || die "ответ про HTTPS-маскировку должен быть yes/no."

  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    prompt MASK_DOMAIN "Домен маскировки с DNS A-записью на этот сервер" "$MASK_DOMAIN"
    PUBLIC_ENDPOINT="$MASK_DOMAIN"
    LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-$(mask_default_email)}"
    prompt LETSENCRYPT_EMAIL "Email для Let's Encrypt" "$LETSENCRYPT_EMAIL"
    if [[ "$AWG_PORT" == "1234" || "$AWG_PORT" == "51820" ]]; then
      AWG_PORT="443"
    fi
    prompt AWG_PORT "UDP-порт AmneziaWG" "$AWG_PORT"
  else
    prompt PUBLIC_ENDPOINT "Публичный IP/host для клиентов" "$PUBLIC_ENDPOINT"
    prompt AWG_PORT "UDP-порт AmneziaWG" "$AWG_PORT"
  fi

  prompt AWG_IFACE "Интерфейс AmneziaWG" "$AWG_IFACE"
  prompt AWG_SUBNET "VPN IPv4-сеть" "$AWG_SUBNET"
  prompt AWG_SERVER_IP "VPN IPv4 сервера" "$AWG_SERVER_IP"
  prompt AWG_DNS "DNS клиентов, IPv4 через запятую" "$AWG_DNS"
  AWG_OBFS_PROFILE="$(normalize_obfs_profile "$AWG_OBFS_PROFILE")" || die "некорректный профиль обфускации: $AWG_OBFS_PROFILE. Варианты: mobile, dns, compat, awg1, awg2, plain."
  prompt AWG_OBFS_PROFILE "Профиль обфускации (mobile/dns/compat/awg1/awg2/plain)" "$AWG_OBFS_PROFILE"
  AWG_OBFS_PROFILE="$(normalize_obfs_profile "$AWG_OBFS_PROFILE")" || die "некорректный профиль обфускации: $AWG_OBFS_PROFILE. Варианты: mobile, dns, compat, awg1, awg2, plain."
  ensure_awg_obfuscation_params
  prompt AWG_JC "AmneziaWG junk packet count Jc" "$AWG_JC"
  prompt AWG_JMIN "AmneziaWG junk min size Jmin" "$AWG_JMIN"
  prompt AWG_JMAX "AmneziaWG junk max size Jmax" "$AWG_JMAX"
  prompt CLIENT_NAME "Имя первого клиента" "$CLIENT_NAME"

  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    logs_answer="$([[ "$ENABLE_NGINX_LOGS" == "1" ]] && echo yes || echo no)"
    prompt logs_answer "Включить nginx access logs для маскировочного сайта? yes/no" "$logs_answer"
    ENABLE_NGINX_LOGS="$(bool_value "$logs_answer")" || die "ответ про nginx logs должен быть yes/no."
  else
    ENABLE_NGINX_LOGS=0
  fi

  valid_endpoint "$PUBLIC_ENDPOINT" || die "endpoint должен быть IPv4 или hostname из букв, цифр, точки и дефиса."
  [[ "$AWG_IFACE" =~ ^[A-Za-z0-9_.-]{1,32}$ ]] || die "некорректное имя интерфейса AmneziaWG."
  valid_port "$AWG_PORT" || die "некорректный UDP-порт: $AWG_PORT."
  valid_cidr "$AWG_SUBNET" || die "VPN-сеть должна быть IPv4 CIDR с prefix 8..30."
  valid_ipv4 "$AWG_SERVER_IP" || die "некорректный VPN IPv4 сервера: $AWG_SERVER_IP."
  valid_dns_list "$AWG_DNS" || die "DNS должен быть списком IPv4-адресов через запятую."
  valid_mtu "$AWG_MTU" || die "MTU должен быть числом от 576 до 1420."
  if (( AWG_PORT > 9999 )); then
    warn "UDP-порт ${AWG_PORT} выше 9999. Некоторые провайдеры в РФ уже блокируют такие UDP-порты; для теста лучше AWG_PORT=1234 или AWG_PORT=443."
  fi
  if [[ "$AWG_OBFS_PROFILE" == "plain" ]]; then
    valid_range_int "$AWG_JC" 0 10 || die "некорректный Jc: $AWG_JC. Допустимый диапазон: 0..10."
    valid_range_int "$AWG_JMIN" 0 1024 && valid_range_int "$AWG_JMAX" 0 1024 && (( AWG_JMIN <= AWG_JMAX )) || die "некорректные Jmin/Jmax. Допустимый диапазон: 0..1024, Jmin должен быть <= Jmax."
  else
    valid_range_int "$AWG_JC" 1 10 || die "некорректный Jc: $AWG_JC. Допустимый диапазон: 1..10."
    valid_range_int "$AWG_JMIN" 64 1024 && valid_range_int "$AWG_JMAX" 64 1024 && (( AWG_JMIN < AWG_JMAX )) || die "некорректные Jmin/Jmax. Допустимый диапазон: 64..1024, Jmin должен быть < Jmax."
  fi
  s1_max=64
  s2_max=64
  valid_range_int "$AWG_S1" 0 "$s1_max" && valid_range_int "$AWG_S2" 0 "$s2_max" || die "некорректные S1/S2. Допустимо по документации AmneziaWG 2.0: S1=0..64, S2=0..64."
  if [[ -n "$AWG_S3" ]]; then
    valid_range_int "$AWG_S3" 0 64 || die "некорректный S3: $AWG_S3. Допустимый диапазон: 0..64."
  fi
  if [[ -n "$AWG_S4" ]]; then
    valid_range_int "$AWG_S4" 0 32 || die "некорректный S4: $AWG_S4. Допустимый диапазон: 0..32."
  fi
  validate_awg_headers
  valid_awg_text_param "$AWG_I1" && valid_awg_text_param "$AWG_I2" && valid_awg_text_param "$AWG_I3" && valid_awg_text_param "$AWG_I4" && valid_awg_text_param "$AWG_I5" || die "некорректные I1-I5: параметр слишком длинный или содержит перенос строки."
  valid_name "$CLIENT_NAME" || die "имя клиента должно быть 1-64 символа: буквы, цифры, точка, underscore, дефис, @."
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    valid_domain "$MASK_DOMAIN" || die "домен маскировки должен быть корректным доменным именем."
    valid_email "$LETSENCRYPT_EMAIL" || die "email для Let's Encrypt некорректный."
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
      warn "endpoint-домен указывает на $endpoint_ip, а публичный IPv4 этого сервера: $SERVER_PUBLIC_IPV4."
      confirm "Продолжить всё равно? y/yes: " || die "отменено: DNS endpoint не указывает на этот сервер."
    fi
  fi

  if [[ "$ENABLE_HTTPS_MASK" != "1" ]]; then
    return 0
  fi

  [[ -n "$SERVER_PUBLIC_IPV4" ]] || die "не удалось определить публичный IPv4 сервера для проверки DNS маскировки."
  old_mask="$MASK_DOMAIN"
  mask_ip="$(resolve_domain_ipv4 "$MASK_DOMAIN" || true)"
  if [[ -z "$mask_ip" ]]; then
    echo
    warn "DNS A-запись для $MASK_DOMAIN не найдена."
    if confirm "Продолжить без HTTPS-маскировки? y/yes: "; then
      ENABLE_HTTPS_MASK=0
      MASK_DOMAIN=""
      LETSENCRYPT_EMAIL=""
      if [[ "$PUBLIC_ENDPOINT" == "$old_mask" ]]; then
        PUBLIC_ENDPOINT="$SERVER_PUBLIC_IPV4"
      fi
      return 0
    fi
    die "отменено: у домена маскировки нет A-записи."
  fi
  if [[ "$mask_ip" != "$SERVER_PUBLIC_IPV4" ]]; then
    echo
    warn "$MASK_DOMAIN указывает на $mask_ip, а публичный IPv4 этого сервера: $SERVER_PUBLIC_IPV4."
    if confirm "Продолжить без HTTPS-маскировки? y/yes: "; then
      ENABLE_HTTPS_MASK=0
      MASK_DOMAIN=""
      LETSENCRYPT_EMAIL=""
      if [[ "$PUBLIC_ENDPOINT" == "$old_mask" ]]; then
        PUBLIC_ENDPOINT="$SERVER_PUBLIC_IPV4"
      fi
      return 0
    fi
    die "отменено: домен маскировки не указывает на этот сервер."
  fi
}

print_plan() {
  cat <<EOF

План установки:
  endpoint:        ${PUBLIC_ENDPOINT}:${AWG_PORT}/udp
  интерфейс:       ${AWG_IFACE}
  сеть:            ${AWG_SUBNET}
  IP сервера:      ${AWG_SERVER_IP}
  DNS клиентов:    ${AWG_DNS}
  MTU:             ${AWG_MTU}
  профиль:         ${AWG_OBFS_PROFILE}
  обфускация:      Jc=${AWG_JC}, Jmin=${AWG_JMIN}, Jmax=${AWG_JMAX}, S1=${AWG_S1}, S2=${AWG_S2}
  AWG 2.0:         $([[ -n "${AWG_S3}${AWG_S4}${AWG_I1}${AWG_I2}${AWG_I3}${AWG_I4}${AWG_I5}" ]] && echo "S3=${AWG_S3:-off}, S4=${AWG_S4:-off}, I1=$([[ -n "$AWG_I1" ]] && echo да || echo нет)" || echo нет)
  HTTPS-маскировка: $([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo "да, https://${MASK_DOMAIN}/ на TCP 443" || echo нет)
  nginx logs:      $([[ "$ENABLE_NGINX_LOGS" == "1" ]] && echo да || echo нет)
  первый клиент:   ${CLIENT_NAME}

EOF
  confirm "Введите y или yes для продолжения: " || die "отменено пользователем."
}

backup_state() {
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  for path in "$AWG_DIR" "$CTL_PATH" "$ENV_FILE"; do
    [[ -e "$path" || -L "$path" ]] && cp -a "$path" "$BACKUP_DIR"/
  done
  echo "Бэкап: $BACKUP_DIR"
}

port_listening_tcp() {
  have ss || return 1
  ss -H -ltn "sport = :$1" 2>/dev/null | grep -q .
}

port_listening_udp() {
  have ss || return 1
  ss -H -lun "sport = :$1" 2>/dev/null | grep -q .
}

awg_iface_active() {
  ip link show "$AWG_IFACE" >/dev/null 2>&1 || systemctl is-active --quiet "awg-quick@${AWG_IFACE}" 2>/dev/null
}

port_preflight() {
  if port_listening_udp "$AWG_PORT"; then
    if awg_iface_active; then
      warn "UDP-порт $AWG_PORT уже слушает текущий ${AWG_IFACE}; это нормально для повторной установки, сервис будет перезапущен."
    else
      die "UDP-порт $AWG_PORT уже занят. Выберите другой порт или остановите сервис, который его использует."
    fi
  fi
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    if port_listening_tcp 80; then
      die "TCP-порт 80 уже занят. Для HTTPS-маскировки он нужен Let's Encrypt."
    fi
    if port_listening_tcp 443; then
      die "TCP-порт 443 уже занят. Для HTTPS-маскировки nginx должен слушать TCP 443."
    fi
  fi
}

apt_explain_failure() {
  local log_file="$1"

  if grep -Eq "does not have a Release file|404 .*Release" "$log_file"; then
    warn "apt подключил репозиторий, у которого нет Release-файла для этой версии Ubuntu/Debian."
    warn "Если это AmneziaWG PPA, скрипт попробует другую поддерживаемую ветку."
  elif grep -Eq "Temporary failure resolving|Could not resolve|Name or service not known" "$log_file"; then
    warn "похоже, на сервере проблема с DNS или сетевым доступом к репозиториям."
  elif grep -Eq "NO_PUBKEY|GPG error|EXPKEYSIG|The following signatures" "$log_file"; then
    warn "apt не доверяет ключу репозитория. Скрипт попробует заново установить ключ AmneziaWG PPA."
  elif grep -Eq "Unable to locate package amneziawg" "$log_file"; then
    warn "apt не видит пакет amneziawg в подключенных репозиториях."
  else
    warn "apt вернул ошибку. Ниже последние строки вывода:"
  fi

  tail -n 20 "$log_file" >&2 || true
}

apt_update_checked() {
  local label="$1"
  local ppa_release_mode="${2:-return}"
  local attempt=1
  local rc=0
  local log_file="/tmp/amneziawg-apt-update.log"

  while (( attempt <= INSTALL_RETRIES )); do
    : > "$log_file"
    if apt-get update 2>&1 | tee "$log_file"; then
      rc=0
    else
      rc="${PIPESTATUS[0]}"
    fi

    if (( rc == 0 )) && ! grep -Eq "does not have a Release file|404 .*Release|Failed to fetch .*ppa.launchpadcontent.net/amnezia" "$log_file"; then
      return 0
    fi

    apt_explain_failure "$log_file"
    if grep -Eq "ppa.launchpadcontent.net/amnezia|amnezia/ppa" "$log_file" && grep -Eq "does not have a Release file|404 .*Release" "$log_file"; then
      if [[ "$ppa_release_mode" == "remove" ]]; then
        warn "убираю старую сломанную запись AmneziaWG PPA и повторяю apt update."
        remove_amnezia_ppa_entries
      else
        return 2
      fi
    fi

    if (( attempt >= INSTALL_RETRIES )); then
      echo "ОШИБКА: не удалось выполнить apt update: ${label}. Попыток: ${INSTALL_RETRIES}." >&2
      return "${rc:-1}"
    fi
    warn "apt update не прошел (${label}). Повтор через ${RETRY_DELAY_SECONDS}s (${attempt}/${INSTALL_RETRIES})..."
    sleep "$RETRY_DELAY_SECONDS"
    attempt=$((attempt + 1))
  done

  return "${rc:-1}"
}

apt_package_has_candidate() {
  local package="$1"
  local candidate
  candidate="$(apt-cache policy "$package" | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$candidate" && "$candidate" != "(none)" ]]
}

install_packages() {
  local packages
  export DEBIAN_FRONTEND=noninteractive
  packages=(ca-certificates curl gnupg dirmngr lsb-release iproute2 iptables qrencode)
  remove_amnezia_ppa_entries
  apt_update_checked "обновление базовых репозиториев" remove
  retry_command "установка базовых пакетов" apt-get install -y "${packages[@]}"
}

install_mask_packages() {
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  export DEBIAN_FRONTEND=noninteractive
  retry_command "установка nginx и certbot" apt-get install -y nginx certbot
}

append_unique_candidate() {
  local list="$1"
  local candidate="$2"
  [[ -n "$candidate" ]] || { printf '%s' "$list"; return 0; }
  if [[ " $list " == *" $candidate "* ]]; then
    printf '%s' "$list"
  else
    printf '%s %s' "$list" "$candidate"
  fi
}

awg_ppa_candidates() {
  local os_id="$1"
  local os_codename="$2"
  local candidates=""

  if [[ -n "$AWG_PPA_CODENAME" ]]; then
    candidates="$(append_unique_candidate "$candidates" "$AWG_PPA_CODENAME")"
    printf '%s\n' $candidates
    return 0
  fi

  case "${os_id}:${os_codename}" in
    ubuntu:trusty|ubuntu:xenial|ubuntu:bionic|ubuntu:focal|ubuntu:jammy|ubuntu:noble|ubuntu:oracular|ubuntu:plucky)
      candidates="$(append_unique_candidate "$candidates" "$os_codename")"
      ;;
    ubuntu:*)
      candidates="$(append_unique_candidate "$candidates" "noble")"
      candidates="$(append_unique_candidate "$candidates" "jammy")"
      candidates="$(append_unique_candidate "$candidates" "focal")"
      ;;
    *)
      candidates="$(append_unique_candidate "$candidates" "focal")"
      candidates="$(append_unique_candidate "$candidates" "jammy")"
      candidates="$(append_unique_candidate "$candidates" "noble")"
      ;;
  esac

  printf '%s\n' $candidates
}

remove_amnezia_ppa_entries() {
  local entry
  shopt -s nullglob
  for entry in \
    /etc/apt/sources.list.d/amnezia-ubuntu-ppa*.list \
    /etc/apt/sources.list.d/amnezia-ubuntu-ppa*.sources \
    /etc/apt/sources.list.d/amneziawg.list; do
    rm -f "$entry"
  done
  shopt -u nullglob
}

install_amneziawg_tools() {
  local os_id os_codename repo_codename keyring installed
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

  retry_command "скачивание ключа AmneziaWG PPA" curl -fsSL \
    "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x75c9dd72c799870e310542e24166f2c257290828" \
    -o /tmp/amneziawg-ppa.key
  rm -f "$keyring"
  if ! gpg --dearmor --yes --output "$keyring" /tmp/amneziawg-ppa.key; then
    rm -f /tmp/amneziawg-ppa.key
    die "не удалось сохранить ключ AmneziaWG PPA в $keyring."
  fi
  chmod 0644 "$keyring"
  rm -f /tmp/amneziawg-ppa.key

  installed=0
  for repo_codename in $(awg_ppa_candidates "$os_id" "$os_codename"); do
    echo "Пробую AmneziaWG PPA suite: ${repo_codename} (система: ${os_id} ${os_codename:-unknown})"
    remove_amnezia_ppa_entries
    cat > /etc/apt/sources.list.d/amneziawg.list <<EOF
deb [signed-by=${keyring}] https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu ${repo_codename} main
EOF

    if ! apt_update_checked "обновление apt с AmneziaWG PPA (${repo_codename})" return; then
      warn "ветка PPA ${repo_codename} не подошла или временно недоступна. Пробую следующую."
      continue
    fi

    if ! apt_package_has_candidate amneziawg; then
      warn "в ветке PPA ${repo_codename} пакет amneziawg не найден. Пробую следующую."
      continue
    fi

    apt-get install -y "linux-headers-$(uname -r)" || warn "не удалось установить linux-headers для текущего ядра. Продолжаю: пакет amneziawg иногда ставится без них."
    if retry_command "установка пакета amneziawg из PPA ${repo_codename}" apt-get install -y amneziawg; then
      installed=1
      break
    fi

    warn "пакет amneziawg не установился из ветки ${repo_codename}. Пробую следующую."
  done

  (( installed == 1 )) || die "не удалось установить amneziawg ни из одной ветки PPA. Проверьте сеть/apt или задайте вручную: AWG_PPA_CODENAME=noble ./install_amneziawg.sh"
  have awg || die "команда awg не появилась после установки пакета amneziawg."
  have awg-quick || die "команда awg-quick не появилась после установки пакета amneziawg."
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
AWG_MTU=$(printf '%q' "$AWG_MTU")
AWG_OBFS_PROFILE=$(printf '%q' "$AWG_OBFS_PROFILE")
PUBLIC_ENDPOINT=$(printf '%q' "$PUBLIC_ENDPOINT")
AWG_JC=$(printf '%q' "$AWG_JC")
AWG_JMIN=$(printf '%q' "$AWG_JMIN")
AWG_JMAX=$(printf '%q' "$AWG_JMAX")
AWG_S1=$(printf '%q' "$AWG_S1")
AWG_S2=$(printf '%q' "$AWG_S2")
AWG_S3=$(printf '%q' "$AWG_S3")
AWG_S4=$(printf '%q' "$AWG_S4")
AWG_H1=$(printf '%q' "$AWG_H1")
AWG_H2=$(printf '%q' "$AWG_H2")
AWG_H3=$(printf '%q' "$AWG_H3")
AWG_H4=$(printf '%q' "$AWG_H4")
AWG_I1=$(printf '%q' "$AWG_I1")
AWG_I2=$(printf '%q' "$AWG_I2")
AWG_I3=$(printf '%q' "$AWG_I3")
AWG_I4=$(printf '%q' "$AWG_I4")
AWG_I5=$(printf '%q' "$AWG_I5")
ENABLE_HTTPS_MASK=$(printf '%q' "$ENABLE_HTTPS_MASK")
MASK_DOMAIN=$(printf '%q' "$MASK_DOMAIN")
AWG_DIR=$(printf '%q' "$AWG_DIR")
CLIENT_DIR=$(printf '%q' "$CLIENT_DIR")
CLIENT_OUT_DIR=$(printf '%q' "$CLIENT_OUT_DIR")
EOF
}

write_optional_awg_params() {
  [[ -n "$AWG_S3" ]] && printf 'S3 = %s\n' "$AWG_S3"
  [[ -n "$AWG_S4" ]] && printf 'S4 = %s\n' "$AWG_S4"
  [[ -n "$AWG_I1" ]] && printf 'I1 = %s\n' "$AWG_I1"
  [[ -n "$AWG_I2" ]] && printf 'I2 = %s\n' "$AWG_I2"
  [[ -n "$AWG_I3" ]] && printf 'I3 = %s\n' "$AWG_I3"
  [[ -n "$AWG_I4" ]] && printf 'I4 = %s\n' "$AWG_I4"
  [[ -n "$AWG_I5" ]] && printf 'I5 = %s\n' "$AWG_I5"
}

write_awg_config() {
  local private_key
  local prefix
  local wan_iface
  private_key="$(cat "$AWG_DIR/server_private.key")"
  prefix="${AWG_SUBNET#*/}"
  wan_iface="$(out_iface || true)"
  [[ -n "$wan_iface" ]] || die "не удалось определить внешний сетевой интерфейс для NAT."

  umask 077
  {
    cat <<EOF
[Interface]
Address = ${AWG_SERVER_IP}/${prefix}
MTU = ${AWG_MTU}
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
EOF
    write_optional_awg_params
    cat <<EOF
SaveConfig = false
PostUp = sysctl -w net.ipv4.ip_forward=1 >/dev/null; iptables -C FORWARD -i ${AWG_IFACE} -o ${wan_iface} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${AWG_IFACE} -o ${wan_iface} -j ACCEPT; iptables -C FORWARD -i ${wan_iface} -o ${AWG_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${wan_iface} -o ${AWG_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -C POSTROUTING -s ${AWG_SUBNET} -o ${wan_iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${AWG_SUBNET} -o ${wan_iface} -j MASQUERADE
PostDown = iptables -D FORWARD -i ${AWG_IFACE} -o ${wan_iface} -j ACCEPT 2>/dev/null || true; iptables -D FORWARD -i ${wan_iface} -o ${AWG_IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true; iptables -t nat -D POSTROUTING -s ${AWG_SUBNET} -o ${wan_iface} -j MASQUERADE 2>/dev/null || true
EOF
  } > "$AWG_DIR/${AWG_IFACE}.conf"
  chmod 600 "$AWG_DIR/${AWG_IFACE}.conf"
}

install_awgctl() {
  [[ -f "$SCRIPT_DIR/awgctl.sh" ]] || die "файл awgctl.sh должен лежать рядом с install_amneziawg.sh."
  install -m 0755 "$SCRIPT_DIR/awgctl.sh" "$CTL_PATH"
}

configure_firewall() {
  local wan_iface
  wan_iface="$(out_iface || true)"
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow "${AWG_PORT}/udp"
    if [[ -n "$wan_iface" ]]; then
      ufw route allow in on "$AWG_IFACE" out on "$wan_iface" || true
    fi
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
  nginx -t || die "nginx не принял HTTP-конфиг маскировочного сайта."
  systemctl enable --now nginx || die "не удалось запустить nginx."
  systemctl reload nginx || die "не удалось перечитать конфиг nginx."
}

issue_certificate() {
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  local root_dir
  root_dir="$(mask_root)"
  if [[ -r "/etc/letsencrypt/live/${MASK_DOMAIN}/fullchain.pem" ]]; then
    echo "Certificate already exists for ${MASK_DOMAIN}."
  else
    retry_command "выпуск Let's Encrypt сертификата через certbot" certbot certonly \
      --webroot -w "$root_dir" \
      -d "$MASK_DOMAIN" \
      --non-interactive --agree-tos \
      --email "$LETSENCRYPT_EMAIL" || die "certbot не смог выпустить сертификат. Проверьте DNS A-запись, порт 80/tcp и firewall провайдера."
  fi
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

acme_http01_preflight() {
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  local root_dir token expected challenge_dir local_body public_body url
  root_dir="$(mask_root)"
  challenge_dir="$root_dir/.well-known/acme-challenge"
  token="awg-$(openssl rand -hex 8 2>/dev/null || date +%s)"
  expected="awg-acme-ok-${token}"
  install -d -m 0755 "$challenge_dir"
  printf '%s\n' "$expected" > "$challenge_dir/$token"

  local_body="$(curl -fsS --max-time 10 -H "Host: ${MASK_DOMAIN}" "http://127.0.0.1/.well-known/acme-challenge/${token}" || true)"
  if [[ "$local_body" != "$expected" ]]; then
    rm -f "$challenge_dir/$token"
    die "локальная проверка ACME HTTP-01 не прошла: nginx не отдает challenge-файлы ${MASK_DOMAIN} из ${challenge_dir}."
  fi

  url="http://${MASK_DOMAIN}/.well-known/acme-challenge/${token}"
  if [[ -n "$SERVER_PUBLIC_IPV4" ]]; then
    public_body="$(curl -4fsS --max-time 15 --resolve "${MASK_DOMAIN}:80:${SERVER_PUBLIC_IPV4}" "$url" || true)"
  else
    public_body="$(curl -4fsS --max-time 15 "$url" || true)"
  fi
  rm -f "$challenge_dir/$token"
  [[ "$public_body" == "$expected" ]] || die "публичная проверка ACME HTTP-01 по IPv4 не прошла. Проверьте DNS A-запись, порт 80/tcp, firewall провайдера и существующие nginx-сайты."
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
  nginx -t || die "nginx не принял HTTPS-конфиг маскировочного сайта."
  systemctl reload nginx || die "не удалось перечитать конфиг nginx после настройки HTTPS."
}

setup_https_mask() {
  [[ "$ENABLE_HTTPS_MASK" == "1" ]] || return 0
  write_mask_http_config
  acme_http01_preflight
  issue_certificate
  write_mask_https_config
}

start_service() {
  systemctl enable "awg-quick@${AWG_IFACE}" >/dev/null || die "не удалось включить автозапуск awg-quick@${AWG_IFACE}."
  systemctl restart "awg-quick@${AWG_IFACE}" || die "не удалось перезапустить awg-quick@${AWG_IFACE}. Проверьте конфиг ${AWG_DIR}/${AWG_IFACE}.conf и вывод: journalctl -u awg-quick@${AWG_IFACE} --no-pager -n 50"
}

ensure_first_client() {
  if [[ -f "$CLIENT_DIR/${CLIENT_NAME}.env" ]]; then
    echo "Клиент уже существует: $CLIENT_NAME. Пересоздаю его под текущие параметры AmneziaWG."
    "$CTL_PATH" delete "$CLIENT_NAME" || die "не удалось удалить старого клиента $CLIENT_NAME."
  fi
  "$CTL_PATH" add "$CLIENT_NAME"
}

verify_install() {
  systemctl is-active --quiet "awg-quick@${AWG_IFACE}" || die "служба awg-quick@${AWG_IFACE} не активна."
  awg show "$AWG_IFACE" >/dev/null || die "интерфейс AmneziaWG ${AWG_IFACE} недоступен."
  if [[ "$ENABLE_HTTPS_MASK" == "1" ]]; then
    systemctl is-active --quiet nginx || die "nginx не активен."
  fi
}

main() {
  detect_os
  load_resume_config
  echo "Установщик AmneziaWG для Debian/Ubuntu."
  echo
  echo "Перед запуском:"
  echo "  1. Лучше использовать чистый сервер, особенно если HTTPS-маскировка занимает TCP 80/443."
  echo "  2. Если включаете HTTPS-маскировку, заранее создайте DNS A-запись: <domain> -> IPv4 сервера."
  echo "  3. Убедитесь, что выбранный UDP-порт AmneziaWG доступен из интернета."
  echo "  4. Не закрывайте текущую SSH-сессию, пока не проверите второй вход."
  echo
  prompt_config
  reset_step_state_if_config_changed
  print_plan

  run_step "backup" "Бэкап текущего состояния" backup_state
  run_step "packages" "Установка базовых пакетов" install_packages
  run_step "ports" "Проверка портов" port_preflight
  run_step "awg_tools" "Установка AmneziaWG tools" install_amneziawg_tools
  run_step "mask_packages" "Установка nginx/certbot при необходимости" install_mask_packages
  run_step "sysctl" "Включение IPv4 forwarding" configure_sysctl
  run_step "server_keys" "Генерация ключей сервера" generate_server_keys
  run_step "env" "Запись управляющего env-файла" write_env
  run_step "config" "Запись конфига AmneziaWG" write_awg_config
  run_step "ctl" "Установка awgctl" install_awgctl
  run_step "firewall" "Открытие портов в ufw, если он активен" configure_firewall
  run_step "mask" "Настройка HTTPS-маскировки при необходимости" setup_https_mask
  run_step "service" "Запуск AmneziaWG" start_service
  run_step "first_client" "Создание первого клиента" ensure_first_client
  run_step "verify" "Проверка установки" verify_install
  mark_done "done"
  save_resume_config

  step "Готово"
  cat <<EOF
AmneziaWG установлен.

Endpoint: ${PUBLIC_ENDPOINT}:${AWG_PORT}/udp
Интерфейс: ${AWG_IFACE}
Профиль обфускации: ${AWG_OBFS_PROFILE}
HTTPS-маскировка: $([[ "$ENABLE_HTTPS_MASK" == "1" ]] && echo "https://${MASK_DOMAIN}/ на TCP 443" || echo нет)
Первый клиент: ${CLIENT_NAME}

Конфиг клиента:
  ${CLIENT_OUT_DIR}/${CLIENT_NAME}.conf

Показать QR:
  awgctl qr ${CLIENT_NAME}

Управление клиентами:
  awgctl add
  awgctl delete
  awgctl list
  awgctl show
  awgctl qr
  awgctl traffic

Бэкапы:
  ${BACKUP_DIR}
EOF
}

if [[ "${AWG_INSTALLER_LIBRARY_ONLY:-0}" != "1" ]]; then
  main "$@"
fi
