#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/amnezia/amneziawg/awgctl.env"

die() {
  echo "ОШИБКА: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "запустите awgctl от root."
}

load_env() {
  [[ -r "$ENV_FILE" ]] || die "env-файл не найден: $ENV_FILE"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  AWG_CONFIG="${AWG_DIR}/${AWG_IFACE}.conf"
  SERVER_PUBLIC_KEY_FILE="${AWG_DIR}/server_public.key"
}

ensure_dirs() {
  install -d -m 0700 "$CLIENT_DIR" "$CLIENT_OUT_DIR"
  [[ -r "$AWG_CONFIG" ]] || die "конфиг AmneziaWG не найден: $AWG_CONFIG"
  [[ -r "$SERVER_PUBLIC_KEY_FILE" ]] || die "публичный ключ сервера не найден: $SERVER_PUBLIC_KEY_FILE"
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9._@-]{1,64}$ ]]
}

ip2int() {
  local a b c d
  IFS=. read -r a b c d <<< "$1"
  echo $(((a << 24) + (b << 16) + (c << 8) + d))
}

int2ip() {
  local n="$1"
  printf '%d.%d.%d.%d' \
    $(((n >> 24) & 255)) \
    $(((n >> 16) & 255)) \
    $(((n >> 8) & 255)) \
    $((n & 255))
}

next_client_ip() {
  local base="${AWG_SUBNET%/*}"
  local prefix="${AWG_SUBNET#*/}"
  local network mask size first last n used_ip used_int server_int
  declare -A used=()

  mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  network=$(( $(ip2int "$base") & mask ))
  size=$(( 1 << (32 - prefix) ))
  first=$(( network + 2 ))
  last=$(( network + size - 2 ))
  server_int="$(ip2int "$AWG_SERVER_IP")"
  used["$server_int"]=1

  shopt -s nullglob
  for env in "$CLIENT_DIR"/*.env; do
    # shellcheck disable=SC1090
    . "$env"
    used_ip="${CLIENT_IP:-}"
    [[ -n "$used_ip" ]] || continue
    used_int="$(ip2int "$used_ip")"
    used["$used_int"]=1
  done
  shopt -u nullglob

  for (( n=first; n<=last; n++ )); do
    if [[ -z "${used[$n]:-}" ]]; then
      int2ip "$n"
      return 0
    fi
  done
  die "нет свободных IP для клиентов в сети $AWG_SUBNET"
}

client_exists() {
  [[ -f "$CLIENT_DIR/$1.env" ]]
}

client_name_exists() {
  [[ -e "$CLIENT_DIR/$1.env" || -e "$CLIENT_OUT_DIR/$1.conf" ]]
}

next_client_name() {
  local requested="${1:-pipiska1}"
  local prefix number candidate

  if ! client_name_exists "$requested"; then
    printf '%s' "$requested"
    return 0
  fi

  if [[ "$requested" =~ ^(.*[^0-9])([0-9]+)$ ]]; then
    prefix="${BASH_REMATCH[1]}"
    number="${BASH_REMATCH[2]}"
  else
    prefix="${requested}"
    number=1
  fi

  while :; do
    number=$((10#$number + 1))
    candidate="${prefix}${number}"
    valid_name "$candidate" || die "не удалось подобрать имя клиента после ${requested}: получилось некорректное имя ${candidate}."
    if ! client_name_exists "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

bytes_human() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ");
    i = 1;
    while (b >= 1024 && i < 6) { b = b / 1024; i++; }
    if (i == 1) printf "%.0f %s", b, u[i];
    else printf "%.2f %s", b, u[i];
  }'
}

append_peer_config() {
  local name="$1"
  local public_key="$2"
  local psk="$3"
  local ip="$4"

  cat >> "$AWG_CONFIG" <<EOF

# BEGIN_AWG_CLIENT ${name}
[Peer]
# Name = ${name}
PublicKey = ${public_key}
PresharedKey = ${psk}
AllowedIPs = ${ip}/32
# END_AWG_CLIENT ${name}
EOF
}

remove_peer_config() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v start="# BEGIN_AWG_CLIENT ${name}" -v end="# END_AWG_CLIENT ${name}" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$AWG_CONFIG" > "$tmp"
  install -m 0600 "$tmp" "$AWG_CONFIG"
  rm -f "$tmp"
}

write_client_config() {
  local name="$1"
  local private_key="$2"
  local psk="$3"
  local ip="$4"
  local server_pub
  server_pub="$(cat "$SERVER_PUBLIC_KEY_FILE")"

  umask 077
  {
    cat <<EOF
[Interface]
PrivateKey = ${private_key}
Address = ${ip}/32
DNS = ${AWG_DNS}
MTU = ${AWG_MTU:-1280}
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

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${PUBLIC_ENDPOINT}:${AWG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
  } > "$CLIENT_OUT_DIR/${name}.conf"
}

write_optional_awg_params() {
  [[ -n "${AWG_S3:-}" ]] && printf 'S3 = %s\n' "$AWG_S3"
  [[ -n "${AWG_S4:-}" ]] && printf 'S4 = %s\n' "$AWG_S4"
  [[ -n "${AWG_I1:-}" ]] && printf 'I1 = %s\n' "$AWG_I1"
  [[ -n "${AWG_I2:-}" ]] && printf 'I2 = %s\n' "$AWG_I2"
  [[ -n "${AWG_I3:-}" ]] && printf 'I3 = %s\n' "$AWG_I3"
  [[ -n "${AWG_I4:-}" ]] && printf 'I4 = %s\n' "$AWG_I4"
  [[ -n "${AWG_I5:-}" ]] && printf 'I5 = %s\n' "$AWG_I5"
}

cmd_add() {
  local name="${1:-}"
  local private_key public_key psk ip created_at

  if [[ -z "$name" ]]; then
    read -r -p "Имя клиента [pipiska1]: " name
    name="${name:-pipiska1}"
  fi
  valid_name "$name" || die "имя клиента должно быть 1-64 символа: буквы, цифры, точка, underscore, дефис, @."
  if client_name_exists "$name"; then
    name="$(next_client_name "$name")"
    echo "Клиент уже существует, создаю следующего: $name"
  fi

  private_key="$(awg genkey)"
  public_key="$(printf '%s' "$private_key" | awg pubkey)"
  psk="$(awg genpsk)"
  ip="$(next_client_ip)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  umask 077
  cat > "$CLIENT_DIR/${name}.env" <<EOF
CLIENT_NAME=$(printf '%q' "$name")
CLIENT_IP=$(printf '%q' "$ip")
CLIENT_PUBLIC_KEY=$(printf '%q' "$public_key")
CLIENT_CREATED_AT=$(printf '%q' "$created_at")
EOF

  append_peer_config "$name" "$public_key" "$psk" "$ip"
  write_client_config "$name" "$private_key" "$psk" "$ip"

  if awg show "$AWG_IFACE" >/dev/null 2>&1; then
    awg set "$AWG_IFACE" peer "$public_key" preshared-key <(printf '%s\n' "$psk") allowed-ips "${ip}/32"
  fi

  echo "Клиент добавлен: $name"
  echo "Конфиг: $CLIENT_OUT_DIR/${name}.conf"
  cmd_show "$name" --qr
}

cmd_delete() {
  local name="${1:-}"
  local public_key

  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "Клиент для удаления: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "клиент не выбран."
  client_exists "$name" || die "клиент не найден: $name"

  # shellcheck disable=SC1090
  . "$CLIENT_DIR/${name}.env"
  public_key="${CLIENT_PUBLIC_KEY}"
  if awg show "$AWG_IFACE" >/dev/null 2>&1; then
    awg set "$AWG_IFACE" peer "$public_key" remove || true
  fi
  remove_peer_config "$name"
  rm -f "$CLIENT_DIR/${name}.env" "$CLIENT_OUT_DIR/${name}.conf"
  echo "Клиент удален: $name"
}

client_name_by_number() {
  local number="$1"
  shopt -s nullglob
  basename -s .env "$CLIENT_DIR"/*.env | sort | sed -n "${number}p"
  shopt -u nullglob
}

cmd_list() {
  local i=0 env name ip created
  shopt -s nullglob
  if ! compgen -G "$CLIENT_DIR/*.env" >/dev/null; then
    echo "Клиентов нет."
    shopt -u nullglob
    return 0
  fi
  printf '%-4s %-24s %-16s %s\n' "num" "name" "ip" "created_at"
  for env in "$CLIENT_DIR"/*.env; do
    # shellcheck disable=SC1090
    . "$env"
    name="${CLIENT_NAME:-$(basename -s .env "$env")}"
    ip="${CLIENT_IP:-unknown}"
    created="${CLIENT_CREATED_AT:-unknown}"
    i=$((i + 1))
    printf '%-4s %-24s %-16s %s\n' "$i" "$name" "$ip" "$created"
  done
  shopt -u nullglob
}

cmd_show() {
  local name="${1:-}"
  local qr_flag="${2:-}"
  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "Клиент для показа: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "клиент не выбран."
  [[ -r "$CLIENT_OUT_DIR/${name}.conf" ]] || die "конфиг клиента не найден: $name"
  cat "$CLIENT_OUT_DIR/${name}.conf"
  if [[ "$qr_flag" == "--qr" || "$qr_flag" == "qr" ]]; then
    echo
    cmd_qr "$name"
  else
    echo >&2
    echo "QR: awgctl qr ${name}" >&2
  fi
}

cmd_qr() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "Клиент для показа QR: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "клиент не выбран."
  [[ -r "$CLIENT_OUT_DIR/${name}.conf" ]] || die "конфиг клиента не найден: $name"
  if ! have qrencode; then
    die "qrencode не установлен. Выполните: apt-get install -y qrencode"
  fi
  qrencode -t ANSIUTF8 < "$CLIENT_OUT_DIR/${name}.conf"
}

latest_human() {
  local ts="$1"
  local now delta
  [[ "$ts" =~ ^[0-9]+$ ]] || { echo "unknown"; return 0; }
  (( ts == 0 )) && { echo "never"; return 0; }
  now="$(date +%s)"
  delta=$((now - ts))
  if (( delta < 60 )); then
    echo "${delta}s ago"
  elif (( delta < 3600 )); then
    echo "$((delta / 60))m ago"
  else
    echo "$((delta / 3600))h ago"
  fi
}

cmd_traffic() {
  local env pub name ip
  local line peer endpoint allowed latest rx tx keepalive
  declare -A name_by_pub=()
  declare -A ip_by_pub=()

  shopt -s nullglob
  for env in "$CLIENT_DIR"/*.env; do
    # shellcheck disable=SC1090
    . "$env"
    pub="${CLIENT_PUBLIC_KEY:-}"
    [[ -n "$pub" ]] || continue
    name_by_pub["$pub"]="${CLIENT_NAME:-$(basename -s .env "$env")}"
    ip_by_pub["$pub"]="${CLIENT_IP:-unknown}"
  done
  shopt -u nullglob

  printf '%-24s %-16s %-24s %-12s %12s %12s\n' "name" "vpn_ip" "endpoint" "handshake" "rx" "tx"
  awg show "$AWG_IFACE" dump | tail -n +2 | while IFS=$'\t' read -r peer psk endpoint allowed latest rx tx keepalive; do
    name="${name_by_pub[$peer]:-unknown}"
    ip="${ip_by_pub[$peer]:-${allowed%/*}}"
    printf '%-24s %-16s %-24s %-12s %12s %12s\n' \
      "$name" "$ip" "${endpoint:-none}" "$(latest_human "$latest")" "$(bytes_human "$rx")" "$(bytes_human "$tx")"
  done
}

cmd_help() {
  cat <<'EOF'
Usage:
  awgctl add [name]
  awgctl delete [name|number]
  awgctl list
  awgctl show [name|number]
  awgctl show [name|number] --qr
  awgctl qr [name|number]
  awgctl traffic
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    help|-h|--help) cmd_help; return 0 ;;
  esac

  require_root
  load_env
  ensure_dirs

  case "$cmd" in
    add) cmd_add "${1:-}" ;;
    delete|del|remove|rm) cmd_delete "${1:-}" ;;
    list|ls) cmd_list ;;
    show|config) cmd_show "$@" ;;
    qr|qrcode) cmd_qr "${1:-}" ;;
    traffic|stats) cmd_traffic ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"
