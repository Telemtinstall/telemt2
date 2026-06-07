#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/amnezia/amneziawg/awgctl.env"
JSON_OUTPUT="${JSON_OUTPUT:-0}"

json_escape() {
  local value="${1:-}"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\b'/\\b}"
  value="${value//$'\f'/\\f}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  value="${value//$'\e'/\\u001b}"
  printf '"%s"' "$value"
}

die() {
  if [[ "${JSON_OUTPUT:-0}" == "1" ]]; then
    printf '{"ok":false,"error":%s}\n' "$(json_escape "$*")" >&2
  else
    echo "ОШИБКА: $*" >&2
  fi
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

normalize_command() {
  local value="$1"

  value="${value//а/a}"
  value="${value//А/A}"
  value="${value//е/e}"
  value="${value//Е/E}"
  value="${value//о/o}"
  value="${value//О/O}"
  value="${value//р/p}"
  value="${value//Р/P}"
  value="${value//с/c}"
  value="${value//С/C}"
  value="${value//х/x}"
  value="${value//Х/X}"
  printf '%s' "$value"
}

json_string_or_null() {
  local value="${1:-}"
  case "$value" in
    ""|none|"(none)"|null|"(null)") printf 'null' ;;
    *) json_escape "$value" ;;
  esac
}

json_number_or_null() {
  local value="${1:-}"
  [[ "$value" =~ ^[0-9]+$ ]] && printf '%s' "$value" || printf 'null'
}

install_apt_package() {
  local package="$1"

  have apt-get || die "${package} не установлен, а apt-get не найден. Автоустановка доступна только на Debian/Ubuntu."
  echo "Пакет ${package} не найден. Устанавливаю автоматически..." >&2
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    apt-get update >&2 || die "не удалось обновить apt перед установкой ${package}. Проверьте DNS/доступ к репозиториям."
    apt-get install -y "$package" >&2 || die "не удалось установить ${package}. Проверьте apt и запустите команду еще раз."
  else
    apt-get update || die "не удалось обновить apt перед установкой ${package}. Проверьте DNS/доступ к репозиториям."
    apt-get install -y "$package" || die "не удалось установить ${package}. Проверьте apt и запустите команду еще раз."
  fi
}

ensure_command() {
  local command_name="$1"
  local package="$2"

  have "$command_name" || install_apt_package "$package"
  have "$command_name" || die "команда ${command_name} не появилась после установки пакета ${package}."
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
  return 0
}

client_config_complete() {
  local conf="$CLIENT_OUT_DIR/${1}.conf"
  [[ -r "$conf" ]] || return 1
  grep -Eq '^\[Interface\]$' "$conf" || return 1
  grep -Eq '^PrivateKey = .+' "$conf" || return 1
  grep -Eq '^\[Peer\]$' "$conf" || return 1
  grep -Eq '^PublicKey = .+' "$conf" || return 1
  grep -Eq '^PresharedKey = .+' "$conf" || return 1
  grep -Eq '^Endpoint = .+' "$conf" || return 1
  grep -Eq '^AllowedIPs = .+' "$conf" || return 1
  return 0
}

client_private_key_from_config() {
  local conf="$CLIENT_OUT_DIR/${1}.conf"
  awk -F ' = ' '$1 == "PrivateKey" {print $2; exit}' "$conf"
}

peer_psk_from_server_config() {
  local name="$1"
  awk -F ' = ' -v start="# BEGIN_AWG_CLIENT ${name}" -v end="# END_AWG_CLIENT ${name}" '
    $0 == start {inside=1; next}
    $0 == end {exit}
    inside && $1 == "PresharedKey" {print $2; exit}
  ' "$AWG_CONFIG"
}

repair_client_config() {
  local name="$1"
  local private_key psk ip

  if client_config_complete "$name"; then
    return 0
  fi
  [[ -r "$CLIENT_DIR/${name}.env" ]] || die "клиентский env не найден: ${CLIENT_DIR}/${name}.env"
  # shellcheck disable=SC1090
  . "$CLIENT_DIR/${name}.env"
  ip="${CLIENT_IP:-}"
  [[ -n "$ip" ]] || die "не удалось исправить конфиг ${name}: в env нет CLIENT_IP."
  private_key="$(client_private_key_from_config "$name")"
  [[ -n "$private_key" ]] || die "не удалось исправить конфиг ${name}: нет PrivateKey. Создайте клиента заново: awgctl delete ${name} && awgctl add ${name}"
  psk="$(peer_psk_from_server_config "$name")"
  [[ -n "$psk" ]] || die "не удалось исправить конфиг ${name}: не найден PresharedKey в ${AWG_CONFIG}."
  write_client_config "$name" "$private_key" "$psk" "$ip"
  client_config_complete "$name" || die "не удалось исправить конфиг ${name}: после пересборки он все еще неполный."
  echo "Конфиг клиента ${name} был неполным, я пересобрал его: ${CLIENT_OUT_DIR}/${name}.conf" >&2
}

cmd_add() {
  local name="${1:-}"
  local requested_name auto_incremented=0
  local private_key public_key psk ip created_at config_text

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      name="pipiska1"
    else
      read -r -p "Имя клиента [pipiska1]: " name
      name="${name:-pipiska1}"
    fi
  fi
  requested_name="$name"
  valid_name "$name" || die "имя клиента должно быть 1-64 символа: буквы, цифры, точка, underscore, дефис, @."
  if client_name_exists "$name"; then
    name="$(next_client_name "$name")"
    auto_incremented=1
    [[ "$JSON_OUTPUT" == "1" ]] || echo "Клиент уже существует, создаю следующего: $name"
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
  client_config_complete "$name" || die "клиентский конфиг создан неполным: ${CLIENT_OUT_DIR}/${name}.conf"

  if awg show "$AWG_IFACE" >/dev/null 2>&1; then
    awg set "$AWG_IFACE" peer "$public_key" preshared-key <(printf '%s\n' "$psk") allowed-ips "${ip}/32"
  fi

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    config_text="$(cat "$CLIENT_OUT_DIR/${name}.conf")"
    printf '{"ok":true,"action":"add","status":"created","requested_name":%s,"name":%s,"auto_incremented":%s,"ip":%s,"public_key":%s,"interface":%s,"endpoint":%s,"config_path":%s,"env_path":%s,"config":%s}\n' \
      "$(json_escape "$requested_name")" \
      "$(json_escape "$name")" \
      "$([[ "$auto_incremented" == "1" ]] && echo true || echo false)" \
      "$(json_escape "$ip")" \
      "$(json_escape "$public_key")" \
      "$(json_escape "$AWG_IFACE")" \
      "$(json_escape "${PUBLIC_ENDPOINT}:${AWG_PORT}")" \
      "$(json_escape "$CLIENT_OUT_DIR/${name}.conf")" \
      "$(json_escape "$CLIENT_DIR/${name}.env")" \
      "$(json_escape "$config_text")"
    return 0
  fi

  echo "Клиент добавлен: $name"
  echo "Конфиг: $CLIENT_OUT_DIR/${name}.conf"
  echo "QR для импорта:"
  cmd_qr "$name"
  echo >&2
  echo "Текстовый конфиг: awgctl show ${name}" >&2
}

cmd_delete() {
  local name="${1:-}"
  local public_key ip created config_path env_path

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die "укажите клиента для удаления: awgctl -j delete <name|number>"
    fi
    cmd_list
    read -r -p "Клиент для удаления: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "клиент не выбран."
  client_exists "$name" || die "клиент не найден: $name"

  # shellcheck disable=SC1090
  . "$CLIENT_DIR/${name}.env"
  public_key="${CLIENT_PUBLIC_KEY}"
  ip="${CLIENT_IP:-}"
  created="${CLIENT_CREATED_AT:-}"
  config_path="$CLIENT_OUT_DIR/${name}.conf"
  env_path="$CLIENT_DIR/${name}.env"
  if awg show "$AWG_IFACE" >/dev/null 2>&1; then
    awg set "$AWG_IFACE" peer "$public_key" remove || true
  fi
  remove_peer_config "$name"
  rm -f "$env_path" "$config_path"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"action":"delete","status":"deleted","name":%s,"ip":%s,"public_key":%s,"created_at":%s,"config_path":%s,"env_path":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$ip")" \
      "$(json_escape "$public_key")" \
      "$(json_string_or_null "$created")" \
      "$(json_escape "$config_path")" \
      "$(json_escape "$env_path")"
    return 0
  fi
  echo "Клиент удален: $name"
}

client_name_by_number() {
  local number="$1"
  shopt -s nullglob
  basename -s .env "$CLIENT_DIR"/*.env | sort | sed -n "${number}p"
  shopt -u nullglob
}

cmd_list() {
  local i=0 env name ip created pub first=1
  shopt -s nullglob
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"clients":['
    for env in "$CLIENT_DIR"/*.env; do
      # shellcheck disable=SC1090
      . "$env"
      name="${CLIENT_NAME:-$(basename -s .env "$env")}"
      ip="${CLIENT_IP:-unknown}"
      created="${CLIENT_CREATED_AT:-unknown}"
      pub="${CLIENT_PUBLIC_KEY:-}"
      i=$((i + 1))
      (( first == 1 )) || printf ','
      first=0
      printf '{"num":%s,"name":%s,"ip":%s,"public_key":%s,"created_at":%s,"config_path":%s,"env_path":%s}' \
        "$i" \
        "$(json_escape "$name")" \
        "$(json_escape "$ip")" \
        "$(json_string_or_null "$pub")" \
        "$(json_string_or_null "$created")" \
        "$(json_escape "$CLIENT_OUT_DIR/${name}.conf")" \
        "$(json_escape "$env")"
    done
    printf ']}\n'
    shopt -u nullglob
    return 0
  fi

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
  local conf config_text ip created pub env_path
  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die "укажите клиента для показа: awgctl -j show <name|number>"
    fi
    cmd_list
    read -r -p "Клиент для показа: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "клиент не выбран."
  conf="$CLIENT_OUT_DIR/${name}.conf"
  [[ -r "$conf" ]] || die "конфиг клиента не найден: $name"
  repair_client_config "$name"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    env_path="$CLIENT_DIR/${name}.env"
    ip=""
    created=""
    pub=""
    if [[ -r "$env_path" ]]; then
      # shellcheck disable=SC1090
      . "$env_path"
      ip="${CLIENT_IP:-}"
      created="${CLIENT_CREATED_AT:-}"
      pub="${CLIENT_PUBLIC_KEY:-}"
    fi
    config_text="$(cat "$conf")"
    printf '{"ok":true,"name":%s,"ip":%s,"public_key":%s,"created_at":%s,"config_path":%s,"env_path":%s,"config":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_string_or_null "$ip")" \
      "$(json_string_or_null "$pub")" \
      "$(json_string_or_null "$created")" \
      "$(json_escape "$conf")" \
      "$(json_escape "$env_path")" \
      "$(json_escape "$config_text")"
    return 0
  fi

  cat "$conf"
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
  local conf config_text qr_text
  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die "укажите клиента для QR: awgctl -j qr <name|number>"
    fi
    cmd_list
    read -r -p "Клиент для показа QR: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "клиент не выбран."
  conf="$CLIENT_OUT_DIR/${name}.conf"
  [[ -r "$conf" ]] || die "конфиг клиента не найден: $name"
  repair_client_config "$name"
  ensure_command qrencode qrencode
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    config_text="$(cat "$conf")"
    qr_text="$(qrencode -t ANSIUTF8 < "$conf")"
    printf '{"ok":true,"name":%s,"config_path":%s,"config":%s,"qr_ansi_utf8":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$conf")" \
      "$(json_escape "$config_text")" \
      "$(json_escape "$qr_text")"
    return 0
  fi
  qrencode -t ANSIUTF8 < "$conf"
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
  local peer endpoint allowed latest rx tx keepalive first latest_json keepalive_json
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

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"interface":%s,"peers":[' "$(json_escape "$AWG_IFACE")"
    first=1
    while IFS=$'\t' read -r peer psk endpoint allowed latest rx tx keepalive; do
      [[ -n "${peer:-}" ]] || continue
      name="${name_by_pub[$peer]:-unknown}"
      ip="${ip_by_pub[$peer]:-${allowed%/*}}"
      latest_json="$(json_number_or_null "$latest")"
      keepalive_json="$(json_number_or_null "$keepalive")"
      (( first == 1 )) || printf ','
      first=0
      printf '{"name":%s,"vpn_ip":%s,"peer_public_key":%s,"endpoint":%s,"allowed_ips":%s,"latest_handshake_epoch":%s,"handshake":%s,"rx_bytes":%s,"tx_bytes":%s,"keepalive":%s}' \
        "$(json_escape "$name")" \
        "$(json_escape "$ip")" \
        "$(json_escape "$peer")" \
        "$(json_string_or_null "${endpoint:-}")" \
        "$(json_string_or_null "${allowed:-}")" \
        "$latest_json" \
        "$(json_escape "$(latest_human "$latest")")" \
        "$(json_number_or_null "$rx")" \
        "$(json_number_or_null "$tx")" \
        "$keepalive_json"
    done < <(awg show "$AWG_IFACE" dump | tail -n +2)
    printf ']}\n'
    return 0
  fi

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
  awgctl -j|--json <command>
  awgctl add [name]
  awgctl delete [name|number]
  awgctl list
  awgctl show [name|number]
  awgctl show [name|number] --qr
  awgctl qr [name|number]
  awgctl traffic|stats
EOF
}

main() {
  local cmd
  local args=()

  while (($#)); do
    case "$1" in
      -j|--json) JSON_OUTPUT=1 ;;
      *) args+=("$1") ;;
    esac
    shift
  done

  set -- "${args[@]}"
  cmd="${1:-help}"
  cmd="$(normalize_command "$cmd")"
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
    traffic|stats|stat|trafic) cmd_traffic ;;
    *)
      if [[ "$JSON_OUTPUT" == "1" ]]; then
        die "неизвестная команда: $cmd"
      fi
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
