#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/wireguard/wgctl.env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Run this script as root."
}

load_env() {
  [[ -r "$ENV_FILE" ]] || die "Environment file not found: $ENV_FILE"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  WG_CONFIG="${WG_DIR}/${WG_IFACE}.conf"
  SERVER_PUBLIC_KEY_FILE="${WG_DIR}/server_public.key"
}

ensure_dirs() {
  install -d -m 0700 "$CLIENT_DIR" "$CLIENT_OUT_DIR"
  [[ -r "$WG_CONFIG" ]] || die "WireGuard config not found: $WG_CONFIG"
  [[ -r "$SERVER_PUBLIC_KEY_FILE" ]] || die "Server public key not found: $SERVER_PUBLIC_KEY_FILE"
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
  local base="${WG_SUBNET%/*}"
  local prefix="${WG_SUBNET#*/}"
  local network mask size first last n used_ip used_int server_int
  declare -A used=()

  mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
  network=$(( $(ip2int "$base") & mask ))
  size=$(( 1 << (32 - prefix) ))
  first=$(( network + 2 ))
  last=$(( network + size - 2 ))
  server_int="$(ip2int "$WG_SERVER_IP")"
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
  die "No free client IPs in $WG_SUBNET"
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
    valid_name "$candidate" || die "Cannot choose next client name after ${requested}: invalid generated name ${candidate}."
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

  cat >> "$WG_CONFIG" <<EOF

# BEGIN_WG_CLIENT ${name}
[Peer]
# Name = ${name}
PublicKey = ${public_key}
PresharedKey = ${psk}
AllowedIPs = ${ip}/32
# END_WG_CLIENT ${name}
EOF
}

remove_peer_config() {
  local name="$1"
  local tmp
  tmp="$(mktemp)"
  awk -v start="# BEGIN_WG_CLIENT ${name}" -v end="# END_WG_CLIENT ${name}" '
    $0 == start {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "$WG_CONFIG" > "$tmp"
  install -m 0600 "$tmp" "$WG_CONFIG"
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
  cat > "$CLIENT_OUT_DIR/${name}.conf" <<EOF
[Interface]
PrivateKey = ${private_key}
Address = ${ip}/32
DNS = ${WG_DNS}
MTU = ${WG_MTU:-1280}

[Peer]
PublicKey = ${server_pub}
PresharedKey = ${psk}
Endpoint = ${PUBLIC_ENDPOINT}:${WG_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF
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
  awk -F ' = ' -v start="# BEGIN_WG_CLIENT ${name}" -v end="# END_WG_CLIENT ${name}" '
    $0 == start {inside=1; next}
    $0 == end {exit}
    inside && $1 == "PresharedKey" {print $2; exit}
  ' "$WG_CONFIG"
}

repair_client_config() {
  local name="$1"
  local private_key psk ip

  if client_config_complete "$name"; then
    return 0
  fi
  [[ -r "$CLIENT_DIR/${name}.env" ]] || die "Client env not found: ${CLIENT_DIR}/${name}.env"
  # shellcheck disable=SC1090
  . "$CLIENT_DIR/${name}.env"
  ip="${CLIENT_IP:-}"
  [[ -n "$ip" ]] || die "Cannot repair ${name}: CLIENT_IP is missing in env."
  private_key="$(client_private_key_from_config "$name")"
  [[ -n "$private_key" ]] || die "Cannot repair ${name}: PrivateKey is missing. Recreate client: wgctl delete ${name} && wgctl add ${name}"
  psk="$(peer_psk_from_server_config "$name")"
  [[ -n "$psk" ]] || die "Cannot repair ${name}: PresharedKey not found in ${WG_CONFIG}."
  write_client_config "$name" "$private_key" "$psk" "$ip"
  client_config_complete "$name" || die "Cannot repair ${name}: config is still incomplete after rebuild."
  echo "Client config ${name} was incomplete, rebuilt it: ${CLIENT_OUT_DIR}/${name}.conf" >&2
}

cmd_add() {
  local name="${1:-}"
  local private_key public_key psk ip created_at

  if [[ -z "$name" ]]; then
    read -r -p "Client name [pipiska1]: " name
    name="${name:-pipiska1}"
  fi
  valid_name "$name" || die "Client name must be 1-64 chars: letters, digits, dot, underscore, dash, @."
  if client_name_exists "$name"; then
    name="$(next_client_name "$name")"
    echo "Client already exists, creating next: $name"
  fi

  private_key="$(wg genkey)"
  public_key="$(printf '%s' "$private_key" | wg pubkey)"
  psk="$(wg genpsk)"
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
  client_config_complete "$name" || die "Client config was created incomplete: ${CLIENT_OUT_DIR}/${name}.conf"

  if wg show "$WG_IFACE" >/dev/null 2>&1; then
    wg set "$WG_IFACE" peer "$public_key" preshared-key <(printf '%s\n' "$psk") allowed-ips "${ip}/32"
  fi

  echo "Client added: $name"
  echo "Config: $CLIENT_OUT_DIR/${name}.conf"
  echo "QR for import:"
  cmd_qr "$name"
  echo >&2
  echo "Text config: wgctl show ${name}" >&2
}

cmd_delete() {
  local name="${1:-}"
  local public_key

  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "Client to delete: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "No client selected."
  client_exists "$name" || die "Client not found: $name"

  # shellcheck disable=SC1090
  . "$CLIENT_DIR/${name}.env"
  public_key="${CLIENT_PUBLIC_KEY}"
  if wg show "$WG_IFACE" >/dev/null 2>&1; then
    wg set "$WG_IFACE" peer "$public_key" remove || true
  fi
  remove_peer_config "$name"
  rm -f "$CLIENT_DIR/${name}.env" "$CLIENT_OUT_DIR/${name}.conf"
  echo "Client deleted: $name"
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
    echo "No clients."
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
  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "Client to show: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "No client selected."
  [[ -r "$CLIENT_OUT_DIR/${name}.conf" ]] || die "Client config not found: $name"
  repair_client_config "$name"
  cat "$CLIENT_OUT_DIR/${name}.conf"
}

cmd_qr() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "Client to show QR: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "No client selected."
  [[ -r "$CLIENT_OUT_DIR/${name}.conf" ]] || die "Client config not found: $name"
  repair_client_config "$name"
  if ! have qrencode; then
    die "qrencode is not installed. Run: apt-get install -y qrencode"
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
  wg show "$WG_IFACE" dump | tail -n +2 | while IFS=$'\t' read -r peer psk endpoint allowed latest rx tx keepalive; do
    name="${name_by_pub[$peer]:-unknown}"
    ip="${ip_by_pub[$peer]:-${allowed%/*}}"
    printf '%-24s %-16s %-24s %-12s %12s %12s\n' \
      "$name" "$ip" "${endpoint:-none}" "$(latest_human "$latest")" "$(bytes_human "$rx")" "$(bytes_human "$tx")"
  done
}

cmd_help() {
  cat <<'EOF'
Usage:
  wgctl add [name]
  wgctl delete [name|number]
  wgctl list
  wgctl show [name|number]
  wgctl qr [name|number]
  wgctl traffic
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
    show|config) cmd_show "${1:-}" ;;
    qr|qrcode) cmd_qr "${1:-}" ;;
    traffic|stats) cmd_traffic ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"
