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

die_with_status() {
  local status_code="$1"
  local status="$2"
  shift 2

  if [[ "${JSON_OUTPUT:-0}" == "1" ]]; then
    printf '{"ok":false,"status_code":%s,"status":%s,"error":%s}\n' \
      "$status_code" \
      "$(json_escape "$status")" \
      "$(json_escape "$*")" >&2
  else
    echo "ОШИБКА: $*" >&2
  fi
  exit 1
}

die() {
  die_with_status 500 internal_error "$*"
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

ensure_private_dir() {
  local dir="$1"

  [[ -d "$dir" ]] || install -d -m 0700 "$dir"
}

base64_one_line() {
  local file="$1"

  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0 "$file"
  elif base64 --help 2>&1 | grep -q -- '-i'; then
    base64 -i "$file" | tr -d '\n'
  else
    base64 "$file" | tr -d '\n'
  fi
}

base64_url_one_line() {
  local file="$1"

  base64_one_line "$file" | tr '+/' '-_' | tr -d '='
}

json_array_from_file_lines() {
  local file="$1"
  local first=1
  local line

  printf '['
  while IFS= read -r line || [[ -n "$line" ]]; do
    (( first == 1 )) || printf ','
    first=0
    json_escape "$line"
  done < "$file"
  printf ']'
}

emit_u8() {
  local value="$1"

  printf "\\$(printf '%03o' "$((value & 255))")"
}

emit_u32_be() {
  local value="$1"

  emit_u8 "$(((value >> 24) & 255))"
  emit_u8 "$(((value >> 16) & 255))"
  emit_u8 "$(((value >> 8) & 255))"
  emit_u8 "$((value & 255))"
}

write_amnezia_qr_payload() {
  local chunk_file="$1"
  local chunks_count="$2"
  local chunk_id="$3"
  local out="$4"
  local chunk_len

  chunk_len="$(wc -c < "$chunk_file" | tr -d '[:space:]')"
  {
    printf '\x07\xC0'
    emit_u8 "$chunks_count"
    emit_u8 "$chunk_id"
    emit_u32_be "$chunk_len"
    cat "$chunk_file"
  } > "$out"
}

make_amnezia_qr_text_chunks() {
  local conf="$1"
  local out_dir="$2"
  local chunk_size="${3:-850}"
  local chunks_count chunk_id chunk payload text_file
  local chunks=()

  install -d -m 0700 "$out_dir"
  split -b "$chunk_size" -d -a 3 "$conf" "$out_dir/chunk-"

  shopt -s nullglob
  chunks=("$out_dir"/chunk-*)
  shopt -u nullglob
  chunks_count="${#chunks[@]}"
  (( chunks_count > 0 )) || return 1
  (( chunks_count <= 255 )) || die_with_status 413 payload_too_large "слишком большой конфиг для Amnezia QR: ${chunks_count} частей."

  chunk_id=0
  for chunk in "${chunks[@]}"; do
    payload="$out_dir/payload-${chunk_id}.bin"
    text_file="$out_dir/text-${chunk_id}.txt"
    write_amnezia_qr_payload "$chunk" "$chunks_count" "$chunk_id" "$payload"
    base64_url_one_line "$payload" > "$text_file"
    chunk_id=$((chunk_id + 1))
  done
}

amnezia_qr_png_base64_items_json_from_config() {
  local conf="$1"
  local tmpdir text_file png_file lines_file ok

  tmpdir="$(mktemp -d)"
  lines_file="$tmpdir/png-base64-lines.txt"
  ok=1
  if ! make_amnezia_qr_text_chunks "$conf" "$tmpdir"; then
    rm -rf "$tmpdir"
    return 1
  fi

  : > "$lines_file"
  for text_file in "$tmpdir"/text-*.txt; do
    png_file="${text_file%.txt}.png"
    if ! qrencode -t PNG -s 10 -m 4 -l L -o "$png_file" < "$text_file"; then
      ok=0
      break
    fi
    base64_one_line "$png_file" >> "$lines_file"
    printf '\n' >> "$lines_file"
  done

  if (( ok != 1 )); then
    rm -rf "$tmpdir"
    return 1
  fi
  json_array_from_file_lines "$lines_file"
  rm -rf "$tmpdir"
}

write_amnezia_qr_pngs_from_config() {
  local conf="$1"
  local out="$2"
  local tmpdir paths_file text_file out_path base chunks_count index ok
  local text_files=()

  tmpdir="$(mktemp -d)"
  paths_file="$tmpdir/paths.txt"
  ok=1
  if ! make_amnezia_qr_text_chunks "$conf" "$tmpdir"; then
    rm -rf "$tmpdir"
    return 1
  fi

  shopt -s nullglob
  text_files=("$tmpdir"/text-*.txt)
  shopt -u nullglob
  chunks_count="${#text_files[@]}"
  : > "$paths_file"
  index=1
  base="${out%.png}"

  for text_file in "${text_files[@]}"; do
    if (( chunks_count == 1 )); then
      out_path="$out"
    else
      out_path="${base}-${index}of${chunks_count}.png"
    fi
    ensure_private_dir "$(dirname "$out_path")"
    if ! qrencode -t PNG -s 10 -m 4 -l L -o "$out_path" < "$text_file"; then
      ok=0
      break
    fi
    chmod 0600 "$out_path"
    printf '%s\n' "$out_path" >> "$paths_file"
    index=$((index + 1))
  done

  if (( ok != 1 )); then
    rm -rf "$tmpdir"
    return 1
  fi
  cat "$paths_file"
  rm -rf "$tmpdir"
}

make_amnezia_vpn_payload_files() {
  local conf="$1"
  local name="$2"
  local out_json="$3"
  local out_compressed="$4"
  local out_key="$5"

  python3 - "$conf" "$name" "$out_json" "$out_compressed" "$out_key" <<'PY'
import base64
import json
import re
import struct
import sys
import zlib

conf_path, name, out_json, out_compressed, out_key = sys.argv[1:6]
text = open(conf_path, "r", encoding="utf-8").read()

values = {}
for raw_line in text.splitlines():
    line = raw_line.strip()
    if not line or line.startswith("#") or line.startswith("[") or " = " not in line:
        continue
    key, value = line.split(" = ", 1)
    values[key.strip()] = value.strip()

required = ["PrivateKey", "Address", "PublicKey", "Endpoint", "AllowedIPs"]
missing = [key for key in required if not values.get(key)]
if missing:
    raise SystemExit("missing required AWG config fields: " + ", ".join(missing))

endpoint = values["Endpoint"]
host = ""
port = ""
if endpoint.startswith("[") and "]:" in endpoint:
    host, port = endpoint[1:].split("]:", 1)
elif ":" in endpoint:
    host, port = endpoint.rsplit(":", 1)
else:
    host = endpoint
if not host:
    raise SystemExit("invalid Endpoint host")
if not port.isdigit():
    port = "55424"

allowed_ips = [item.strip() for item in re.split(r"\s*,\s*", values.get("AllowedIPs", "")) if item.strip()]
dns_values = [item.strip() for item in re.split(r"\s*,\s*", values.get("DNS", "")) if item.strip()]

last_config = {
    "config": text,
    "hostName": host,
    "port": int(port),
    "client_priv_key": values["PrivateKey"],
    "client_ip": values["Address"],
    "server_pub_key": values["PublicKey"],
    "allowed_ips": allowed_ips,
    "mtu": values.get("MTU", "1280"),
}

if values.get("PresharedKey"):
    last_config["psk_key"] = values["PresharedKey"]
elif values.get("PreSharedKey"):
    last_config["psk_key"] = values["PreSharedKey"]
if values.get("PersistentKeepalive"):
    last_config["persistent_keep_alive"] = values["PersistentKeepalive"]

required_awg = ["Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4"]
for key in required_awg:
    if not values.get(key):
        raise SystemExit("missing required AmneziaWG field: " + key)
    last_config[key] = values[key]

optional_awg = ["S3", "S4", "I1", "I2", "I3", "I4", "I5"]
for key in optional_awg:
    if values.get(key):
        last_config[key] = values[key]

protocol_version = ""
if values.get("S3") and values.get("S4"):
    protocol_version = "2"
elif any(values.get(key) for key in ["I1", "I2", "I3", "I4", "I5"]):
    protocol_version = "1.5"

awg_config = {
    "last_config": json.dumps(last_config, ensure_ascii=False, separators=(",", ":")),
    "isThirdPartyConfig": True,
    "port": port,
    "transport_proto": "udp",
}
if protocol_version:
    awg_config["protocol_version"] = protocol_version

server_json = {
    "description": name,
    "hostName": host,
    "containers": [
        {
            "container": "amnezia-awg",
            "awg": awg_config,
        }
    ],
    "defaultContainer": "amnezia-awg",
}
if len(dns_values) >= 1:
    server_json["dns1"] = dns_values[0]
if len(dns_values) >= 2:
    server_json["dns2"] = dns_values[1]

raw = json.dumps(server_json, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
compressed = struct.pack(">I", len(raw)) + zlib.compress(raw, 8)
vpn_key = "vpn://" + base64.urlsafe_b64encode(compressed).rstrip(b"=").decode("ascii")

with open(out_json, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(server_json, ensure_ascii=False, separators=(",", ":")))
with open(out_compressed, "wb") as fh:
    fh.write(compressed)
with open(out_key, "w", encoding="utf-8") as fh:
    fh.write(vpn_key)
PY
}

amnezia_vpn_qr_png_base64_items_json_from_config() {
  local conf="$1"
  local name="$2"
  local tmpdir compressed_file json_file key_file

  tmpdir="$(mktemp -d)"
  json_file="$tmpdir/amnezia-vpn.json"
  compressed_file="$tmpdir/amnezia-vpn.bin"
  key_file="$tmpdir/amnezia-vpn.key"
  if ! make_amnezia_vpn_payload_files "$conf" "$name" "$json_file" "$compressed_file" "$key_file"; then
    rm -rf "$tmpdir"
    return 1
  fi
  amnezia_qr_png_base64_items_json_from_config "$compressed_file"
  rm -rf "$tmpdir"
}

qr_png_base64_from_config() {
  local conf="$1"
  local tmp

  tmp="$(mktemp)"
  if ! qrencode -t PNG -s 10 -m 4 -o "$tmp" < "$conf"; then
    rm -f "$tmp"
    return 1
  fi
  base64_one_line "$tmp"
  rm -f "$tmp"
}

write_qr_png_from_config() {
  local conf="$1"
  local out="$2"

  ensure_private_dir "$(dirname "$out")"
  qrencode -t PNG -s 10 -m 4 -o "$out" < "$conf"
  chmod 0600 "$out"
}

install_apt_package() {
  local package="$1"

  have apt-get || die_with_status 500 dependency_error "${package} не установлен, а apt-get не найден. Автоустановка доступна только на Debian/Ubuntu."
  echo "Пакет ${package} не найден. Устанавливаю автоматически..." >&2
  export DEBIAN_FRONTEND=noninteractive
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    apt-get update >&2 || die_with_status 500 dependency_error "не удалось обновить apt перед установкой ${package}. Проверьте DNS/доступ к репозиториям."
    apt-get install -y "$package" >&2 || die_with_status 500 dependency_error "не удалось установить ${package}. Проверьте apt и запустите команду еще раз."
  else
    apt-get update || die_with_status 500 dependency_error "не удалось обновить apt перед установкой ${package}. Проверьте DNS/доступ к репозиториям."
    apt-get install -y "$package" || die_with_status 500 dependency_error "не удалось установить ${package}. Проверьте apt и запустите команду еще раз."
  fi
}

ensure_command() {
  local command_name="$1"
  local package="$2"

  have "$command_name" || install_apt_package "$package"
  have "$command_name" || die_with_status 500 dependency_error "команда ${command_name} не появилась после установки пакета ${package}."
}

require_root() {
  [[ $EUID -eq 0 ]] || die_with_status 403 forbidden "запустите awgctl от root."
}

load_env() {
  [[ -r "$ENV_FILE" ]] || die_with_status 404 not_found "env-файл не найден: $ENV_FILE"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  AWG_CONFIG="${AWG_DIR}/${AWG_IFACE}.conf"
  SERVER_PUBLIC_KEY_FILE="${AWG_DIR}/server_public.key"
}

ensure_dirs() {
  install -d -m 0700 "$CLIENT_DIR" "$CLIENT_OUT_DIR"
  [[ -r "$AWG_CONFIG" ]] || die_with_status 404 not_found "конфиг AmneziaWG не найден: $AWG_CONFIG"
  [[ -r "$SERVER_PUBLIC_KEY_FILE" ]] || die_with_status 404 not_found "публичный ключ сервера не найден: $SERVER_PUBLIC_KEY_FILE"
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
  die_with_status 409 conflict "нет свободных IP для клиентов в сети $AWG_SUBNET"
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
    valid_name "$candidate" || die_with_status 409 conflict "не удалось подобрать имя клиента после ${requested}: получилось некорректное имя ${candidate}."
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
  [[ -r "$CLIENT_DIR/${name}.env" ]] || die_with_status 404 not_found "клиентский env не найден: ${CLIENT_DIR}/${name}.env"
  # shellcheck disable=SC1090
  . "$CLIENT_DIR/${name}.env"
  ip="${CLIENT_IP:-}"
  [[ -n "$ip" ]] || die_with_status 409 conflict "не удалось исправить конфиг ${name}: в env нет CLIENT_IP."
  private_key="$(client_private_key_from_config "$name")"
  [[ -n "$private_key" ]] || die_with_status 409 conflict "не удалось исправить конфиг ${name}: нет PrivateKey. Создайте клиента заново: awgctl delete ${name} && awgctl add ${name}"
  psk="$(peer_psk_from_server_config "$name")"
  [[ -n "$psk" ]] || die_with_status 409 conflict "не удалось исправить конфиг ${name}: не найден PresharedKey в ${AWG_CONFIG}."
  write_client_config "$name" "$private_key" "$psk" "$ip"
  client_config_complete "$name" || die_with_status 409 conflict "не удалось исправить конфиг ${name}: после пересборки он все еще неполный."
  echo "Конфиг клиента ${name} был неполным, я пересобрал его: ${CLIENT_OUT_DIR}/${name}.conf" >&2
}

cmd_add() {
  local name="${1:-}"
  local requested_name auto_incremented=0
  local private_key public_key psk ip created_at config_text qr_png_base64 amnezia_qr_png_base64_items vpn_qr_png_base64_items vpn_key_file vpn_payload_dir vpn_key

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      name="pipiska1"
    else
      read -r -p "Имя клиента [pipiska1]: " name
      name="${name:-pipiska1}"
    fi
  fi
  requested_name="$name"
  valid_name "$name" || die_with_status 400 bad_request "имя клиента должно быть 1-64 символа: буквы, цифры, точка, underscore, дефис, @."
  if client_name_exists "$name"; then
    name="$(next_client_name "$name")"
    auto_incremented=1
    [[ "$JSON_OUTPUT" == "1" ]] || echo "Клиент уже существует, создаю следующего: $name"
  fi

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    ensure_command qrencode qrencode
    ensure_command base64 coreutils
    ensure_command python3 python3
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
  client_config_complete "$name" || die_with_status 409 conflict "клиентский конфиг создан неполным: ${CLIENT_OUT_DIR}/${name}.conf"

  if awg show "$AWG_IFACE" >/dev/null 2>&1; then
    awg set "$AWG_IFACE" peer "$public_key" preshared-key <(printf '%s\n' "$psk") allowed-ips "${ip}/32"
  fi

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    config_text="$(cat "$CLIENT_OUT_DIR/${name}.conf")"
    qr_png_base64="$(qr_png_base64_from_config "$CLIENT_OUT_DIR/${name}.conf")" || die_with_status 500 dependency_error "не удалось создать PNG QR для клиента ${name}."
    amnezia_qr_png_base64_items="$(amnezia_qr_png_base64_items_json_from_config "$CLIENT_OUT_DIR/${name}.conf")" || die_with_status 500 dependency_error "не удалось создать Amnezia-native PNG QR для клиента ${name}."
    vpn_payload_dir="$(mktemp -d)"
    vpn_key_file="$vpn_payload_dir/amnezia-vpn.key"
    make_amnezia_vpn_payload_files "$CLIENT_OUT_DIR/${name}.conf" "$name" "$vpn_payload_dir/amnezia-vpn.json" "$vpn_payload_dir/amnezia-vpn.bin" "$vpn_key_file" || {
      rm -rf "$vpn_payload_dir"
      die_with_status 500 dependency_error "не удалось создать Amnezia .vpn payload для клиента ${name}."
    }
    vpn_key="$(cat "$vpn_key_file")"
    vpn_qr_png_base64_items="$(amnezia_qr_png_base64_items_json_from_config "$vpn_payload_dir/amnezia-vpn.bin")" || {
      rm -rf "$vpn_payload_dir"
      die_with_status 500 dependency_error "не удалось создать Amnezia .vpn PNG QR для клиента ${name}."
    }
    rm -rf "$vpn_payload_dir"
    printf '{"ok":true,"status_code":201,"status":"created","action":"add","requested_name":%s,"name":%s,"auto_incremented":%s,"ip":%s,"public_key":%s,"interface":%s,"endpoint":%s,"config_path":%s,"env_path":%s,"config":%s,"qr_png_mime":"image/png","qr_png_base64":%s,"qr_png_data_uri":%s,"amnezia_qr_format":"amnezia_qr_chunks","amnezia_qr_png_mime":"image/png","amnezia_qr_png_base64_items":%s,"vpn_key":%s,"vpn_qr_format":"amnezia_vpn_qcompress_chunks","vpn_qr_png_mime":"image/png","vpn_qr_png_base64_items":%s}\n' \
      "$(json_escape "$requested_name")" \
      "$(json_escape "$name")" \
      "$([[ "$auto_incremented" == "1" ]] && echo true || echo false)" \
      "$(json_escape "$ip")" \
      "$(json_escape "$public_key")" \
      "$(json_escape "$AWG_IFACE")" \
      "$(json_escape "${PUBLIC_ENDPOINT}:${AWG_PORT}")" \
      "$(json_escape "$CLIENT_OUT_DIR/${name}.conf")" \
      "$(json_escape "$CLIENT_DIR/${name}.env")" \
      "$(json_escape "$config_text")" \
      "$(json_escape "$qr_png_base64")" \
      "$(json_escape "data:image/png;base64,${qr_png_base64}")" \
      "$amnezia_qr_png_base64_items" \
      "$(json_escape "$vpn_key")" \
      "$vpn_qr_png_base64_items"
    return 0
  fi

  echo "Клиент добавлен: $name"
  echo "Конфиг: $CLIENT_OUT_DIR/${name}.conf"
  echo "QR для импорта:"
  cmd_qr "$name"
  echo >&2
  echo "Текстовый конфиг: awgctl show ${name}" >&2
  echo "Android Amnezia QR: awgctl amqrpng ${name}" >&2
  echo "AmneziaVPN .vpn QR: awgctl vpnqrpng ${name}" >&2
}

cmd_delete() {
  local name="${1:-}"
  local public_key ip created config_path env_path

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для удаления: awgctl -j delete <name|number>"
    fi
    cmd_list
    read -r -p "Клиент для удаления: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  client_exists "$name" || die_with_status 404 not_found "клиент не найден: $name"

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
    printf '{"ok":true,"status_code":200,"status":"deleted","action":"delete","name":%s,"ip":%s,"public_key":%s,"created_at":%s,"config_path":%s,"env_path":%s}\n' \
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
    printf '{"ok":true,"status_code":200,"status":"ok","clients":['
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
      die_with_status 400 bad_request "укажите клиента для показа: awgctl -j show <name|number>"
    fi
    cmd_list
    read -r -p "Клиент для показа: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  conf="$CLIENT_OUT_DIR/${name}.conf"
  [[ -r "$conf" ]] || die_with_status 404 not_found "конфиг клиента не найден: $name"
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
    printf '{"ok":true,"status_code":200,"status":"ok","name":%s,"ip":%s,"public_key":%s,"created_at":%s,"config_path":%s,"env_path":%s,"config":%s}\n' \
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
  local conf config_text qr_text qr_png_base64 amnezia_qr_png_base64_items vpn_qr_png_base64_items vpn_payload_dir vpn_key_file vpn_key
  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для QR: awgctl -j qr <name|number>"
    fi
    cmd_list
    read -r -p "Клиент для показа QR: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  conf="$CLIENT_OUT_DIR/${name}.conf"
  [[ -r "$conf" ]] || die_with_status 404 not_found "конфиг клиента не найден: $name"
  repair_client_config "$name"
  ensure_command qrencode qrencode
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    ensure_command base64 coreutils
    ensure_command python3 python3
    config_text="$(cat "$conf")"
    qr_text="$(qrencode -t ANSIUTF8 < "$conf")"
    qr_png_base64="$(qr_png_base64_from_config "$conf")" || die_with_status 500 dependency_error "не удалось создать PNG QR для клиента ${name}."
    amnezia_qr_png_base64_items="$(amnezia_qr_png_base64_items_json_from_config "$conf")" || die_with_status 500 dependency_error "не удалось создать Amnezia-native PNG QR для клиента ${name}."
    vpn_payload_dir="$(mktemp -d)"
    vpn_key_file="$vpn_payload_dir/amnezia-vpn.key"
    make_amnezia_vpn_payload_files "$conf" "$name" "$vpn_payload_dir/amnezia-vpn.json" "$vpn_payload_dir/amnezia-vpn.bin" "$vpn_key_file" || {
      rm -rf "$vpn_payload_dir"
      die_with_status 500 dependency_error "не удалось создать Amnezia .vpn payload для клиента ${name}."
    }
    vpn_key="$(cat "$vpn_key_file")"
    vpn_qr_png_base64_items="$(amnezia_qr_png_base64_items_json_from_config "$vpn_payload_dir/amnezia-vpn.bin")" || {
      rm -rf "$vpn_payload_dir"
      die_with_status 500 dependency_error "не удалось создать Amnezia .vpn PNG QR для клиента ${name}."
    }
    rm -rf "$vpn_payload_dir"
    printf '{"ok":true,"status_code":200,"status":"ok","name":%s,"config_path":%s,"config":%s,"qr_ansi_utf8":%s,"qr_png_mime":"image/png","qr_png_base64":%s,"qr_png_data_uri":%s,"amnezia_qr_format":"amnezia_qr_chunks","amnezia_qr_png_mime":"image/png","amnezia_qr_png_base64_items":%s,"vpn_key":%s,"vpn_qr_format":"amnezia_vpn_qcompress_chunks","vpn_qr_png_mime":"image/png","vpn_qr_png_base64_items":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$conf")" \
      "$(json_escape "$config_text")" \
      "$(json_escape "$qr_text")" \
      "$(json_escape "$qr_png_base64")" \
      "$(json_escape "data:image/png;base64,${qr_png_base64}")" \
      "$amnezia_qr_png_base64_items" \
      "$(json_escape "$vpn_key")" \
      "$vpn_qr_png_base64_items"
    return 0
  fi
  qrencode -t ANSIUTF8 < "$conf"
}

cmd_qrpng() {
  local name="${1:-}"
  local out="${2:-}"
  local conf
  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для PNG QR: awgctl -j qrpng <name|number> [output.png]"
    fi
    cmd_list
    read -r -p "Клиент для сохранения PNG QR: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  conf="$CLIENT_OUT_DIR/${name}.conf"
  [[ -r "$conf" ]] || die_with_status 404 not_found "конфиг клиента не найден: $name"
  repair_client_config "$name"
  ensure_command qrencode qrencode
  out="${out:-$CLIENT_OUT_DIR/${name}.png}"
  write_qr_png_from_config "$conf" "$out" || die_with_status 500 dependency_error "не удалось сохранить PNG QR: $out"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"status_code":200,"status":"ok","name":%s,"config_path":%s,"qr_png_path":%s,"qr_png_mime":"image/png"}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$conf")" \
      "$(json_escape "$out")"
    return 0
  fi
  echo "PNG QR: $out"
}

cmd_amqrpng() {
  local name="${1:-}"
  local out="${2:-}"
  local conf paths_file chunks_total

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для Amnezia-native PNG QR: awgctl -j amqrpng <name|number> [output.png]"
    fi
    cmd_list
    read -r -p "Клиент для сохранения Amnezia-native PNG QR: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  conf="$CLIENT_OUT_DIR/${name}.conf"
  [[ -r "$conf" ]] || die_with_status 404 not_found "конфиг клиента не найден: $name"
  repair_client_config "$name"
  ensure_command qrencode qrencode
  ensure_command base64 coreutils

  out="${out:-$CLIENT_OUT_DIR/${name}-amnezia.png}"
  paths_file="$(mktemp)"
  if ! write_amnezia_qr_pngs_from_config "$conf" "$out" > "$paths_file"; then
    rm -f "$paths_file"
    die_with_status 500 dependency_error "не удалось сохранить Amnezia-native PNG QR: $out"
  fi
  chunks_total="$(wc -l < "$paths_file" | tr -d '[:space:]')"

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"status_code":200,"status":"ok","name":%s,"config_path":%s,"amnezia_qr_format":"amnezia_qr_chunks","chunks_total":%s,"amnezia_qr_png_mime":"image/png","amnezia_qr_png_paths":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$conf")" \
      "$chunks_total" \
      "$(json_array_from_file_lines "$paths_file")"
    rm -f "$paths_file"
    return 0
  fi

  echo "Amnezia-native PNG QR:"
  cat "$paths_file"
  if (( chunks_total > 1 )); then
    echo "Сканируйте части по порядку 1-${chunks_total} в приложении Amnezia."
  fi
  rm -f "$paths_file"
}

cmd_vpnkey() {
  local name="${1:-}"
  local conf tmpdir key_file

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для AmneziaVPN .vpn key: awgctl -j vpnkey <name|number>"
    fi
    cmd_list
    read -r -p "Клиент для показа AmneziaVPN .vpn key: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  conf="$CLIENT_OUT_DIR/${name}.conf"
  [[ -r "$conf" ]] || die_with_status 404 not_found "конфиг клиента не найден: $name"
  repair_client_config "$name"
  ensure_command python3 python3

  tmpdir="$(mktemp -d)"
  key_file="$tmpdir/amnezia-vpn.key"
  if ! make_amnezia_vpn_payload_files "$conf" "$name" "$tmpdir/amnezia-vpn.json" "$tmpdir/amnezia-vpn.bin" "$key_file"; then
    rm -rf "$tmpdir"
    die_with_status 500 dependency_error "не удалось создать AmneziaVPN .vpn key: $name"
  fi

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"status_code":200,"status":"ok","name":%s,"config_path":%s,"vpn_key":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$conf")" \
      "$(json_escape "$(cat "$key_file")")"
    rm -rf "$tmpdir"
    return 0
  fi

  cat "$key_file"
  printf '\n'
  rm -rf "$tmpdir"
}

cmd_vpnqrpng() {
  local name="${1:-}"
  local out="${2:-}"
  local conf paths_file chunks_total tmpdir compressed_file key_file

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для AmneziaVPN .vpn PNG QR: awgctl -j vpnqrpng <name|number> [output.png]"
    fi
    cmd_list
    read -r -p "Клиент для сохранения AmneziaVPN .vpn PNG QR: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  conf="$CLIENT_OUT_DIR/${name}.conf"
  [[ -r "$conf" ]] || die_with_status 404 not_found "конфиг клиента не найден: $name"
  repair_client_config "$name"
  ensure_command qrencode qrencode
  ensure_command base64 coreutils
  ensure_command python3 python3

  tmpdir="$(mktemp -d)"
  compressed_file="$tmpdir/amnezia-vpn.bin"
  key_file="$tmpdir/amnezia-vpn.key"
  if ! make_amnezia_vpn_payload_files "$conf" "$name" "$tmpdir/amnezia-vpn.json" "$compressed_file" "$key_file"; then
    rm -rf "$tmpdir"
    die_with_status 500 dependency_error "не удалось создать AmneziaVPN .vpn payload: $name"
  fi

  out="${out:-$CLIENT_OUT_DIR/${name}-amnezia-vpn.png}"
  paths_file="$tmpdir/paths.txt"
  if ! write_amnezia_qr_pngs_from_config "$compressed_file" "$out" > "$paths_file"; then
    rm -rf "$tmpdir"
    die_with_status 500 dependency_error "не удалось сохранить AmneziaVPN .vpn PNG QR: $out"
  fi
  chunks_total="$(wc -l < "$paths_file" | tr -d '[:space:]')"

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"status_code":200,"status":"ok","name":%s,"config_path":%s,"vpn_key":%s,"vpn_qr_format":"amnezia_vpn_qcompress_chunks","chunks_total":%s,"vpn_qr_png_mime":"image/png","vpn_qr_png_paths":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$conf")" \
      "$(json_escape "$(cat "$key_file")")" \
      "$chunks_total" \
      "$(json_array_from_file_lines "$paths_file")"
    rm -rf "$tmpdir"
    return 0
  fi

  echo "AmneziaVPN .vpn PNG QR:"
  cat "$paths_file"
  if (( chunks_total > 1 )); then
    echo "Сканируйте части по порядку 1-${chunks_total} в приложении Amnezia."
  fi
  echo "Текстовый ключ: awgctl vpnkey ${name}"
  rm -rf "$tmpdir"
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
    printf '{"ok":true,"status_code":200,"status":"ok","interface":%s,"peers":[' "$(json_escape "$AWG_IFACE")"
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
  awgctl qrpng [name|number] [output.png]
  awgctl amqrpng [name|number] [output.png]
  awgctl vpnkey [name|number]
  awgctl vpnqrpng [name|number] [output.png]
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
    qrpng|png) cmd_qrpng "${1:-}" "${2:-}" ;;
    amqrpng|amneziaqrpng|amnezia-qrpng) cmd_amqrpng "${1:-}" "${2:-}" ;;
    vpnkey|vpn-key|key) cmd_vpnkey "${1:-}" ;;
    vpnqrpng|vpn-qrpng|vpnqr|nativeqrpng|native-qrpng) cmd_vpnqrpng "${1:-}" "${2:-}" ;;
    traffic|stats|stat|trafic) cmd_traffic ;;
    *)
      if [[ "$JSON_OUTPUT" == "1" ]]; then
        die_with_status 400 bad_request "неизвестная команда: $cmd"
      fi
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
