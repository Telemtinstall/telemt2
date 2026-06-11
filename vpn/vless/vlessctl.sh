#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/xray}"
ENV_FILE="${ENV_FILE:-$CONFIG_DIR/vless.env}"
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

die_with_status() {
  local status_code="$1"
  local status="$2"
  shift 2

  if [[ "$JSON_OUTPUT" == "1" ]]; then
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

lower_value() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
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

base64_one_line() {
  local file="$1"

  if base64 --help 2>&1 | grep -q -- '-w'; then
    base64 -w 0 "$file"
  else
    base64 "$file" | tr -d '\n'
  fi
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

qr_png_base64_from_text() {
  local text="$1"
  local tmp

  tmp="$(mktemp)"
  if ! printf '%s' "$text" | qrencode -t PNG -o "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  base64_one_line "$tmp"
  rm -f "$tmp"
}

load_env() {
  [[ -r "$ENV_FILE" ]] || die_with_status 404 not_found "env-файл VLESS не найден: $ENV_FILE"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.json}"
  USERS_FILE="${USERS_FILE:-$CONFIG_DIR/users.json}"
  [[ -n "${PUBLIC_HOST:-}" ]] || die_with_status 409 conflict "в $ENV_FILE нет PUBLIC_HOST."
  [[ -n "${HTTPS_PORT:-}" ]] || die_with_status 409 conflict "в $ENV_FILE нет HTTPS_PORT."
  [[ -n "${LOCAL_PORT:-}" ]] || die_with_status 409 conflict "в $ENV_FILE нет LOCAL_PORT."
  [[ -n "${VLESS_PATH:-}" ]] || die_with_status 409 conflict "в $ENV_FILE нет VLESS_PATH."
  FRONTEND_MODE="${FRONTEND_MODE:-mask}"
  case "$FRONTEND_MODE" in
    mask|direct) ;;
    *) die_with_status 409 conflict "неподдерживаемый FRONTEND_MODE в $ENV_FILE: $FRONTEND_MODE" ;;
  esac
  XRAY_API_LISTEN="${XRAY_API_LISTEN:-127.0.0.1:10085}"
  ENABLE_ACCESS_LOGS="${ENABLE_ACCESS_LOGS:-0}"
  XRAY_FORCE_IPV4="${XRAY_FORCE_IPV4:-1}"
  XRAY_LISTEN_PORT="$LOCAL_PORT"
  if [[ "$FRONTEND_MODE" == "direct" ]]; then
    XRAY_LISTEN_PORT="$HTTPS_PORT"
  fi
}

require_root() {
  [[ $EUID -eq 0 ]] || die_with_status 403 forbidden "запустите vlessctl от root."
}

valid_client_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]
}

logs_enabled() {
  case "$(lower_value "$ENABLE_ACCESS_LOGS")" in
    1|y|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_files() {
  id -u xray >/dev/null 2>&1 || die_with_status 409 conflict "пользователь xray не найден. Запустите install_vless.sh заново."
  install -d -m 0750 -o xray -g xray "$CONFIG_DIR"
  if [[ ! -f "$USERS_FILE" ]]; then
    echo '[]' > "$USERS_FILE"
    chown xray:xray "$USERS_FILE"
    chmod 600 "$USERS_FILE"
  fi
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

urlencode() {
  local s="$1"
  local out=""
  local i c hex
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9.~_-]) out+="$c" ;;
      *) printf -v hex '%%%02X' "'$c"; out+="$hex" ;;
    esac
  done
  printf '%s' "$out"
}

client_exists() {
  local name="$1"
  jq -e --arg name "$name" '.[] | select(.name == $name)' "$USERS_FILE" >/dev/null
}

client_name_exists() {
  client_exists "$1"
}

client_name_by_number() {
  local number="$1"
  number=$((10#$number))
  jq -r --argjson n "$number" '.[$n - 1].name // empty' "$USERS_FILE"
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
    valid_client_name "$candidate" || die_with_status 409 conflict "не удалось подобрать имя клиента после ${requested}: получилось некорректное имя ${candidate}."
    if ! client_name_exists "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  done
}

client_uuid() {
  local name="$1"
  jq -r --arg name "$name" '.[] | select(.name == $name) | .uuid' "$USERS_FILE" | head -n 1
}

render_config() {
  local clients_json
  local log_config_json
  local tmp
  clients_json="$(jq '[.[] | {id:.uuid, email:.name, level:0}]' "$USERS_FILE")"
  if logs_enabled; then
    log_config_json='{"loglevel":"warning","access":"/var/log/xray/access.log","error":"/var/log/xray/error.log"}'
  else
    log_config_json='{"loglevel":"warning"}'
  fi
  tmp="$(mktemp)"
  jq -n \
    --argjson log_config "$log_config_json" \
    --arg frontend_mode "$FRONTEND_MODE" \
    --argjson local_port "$LOCAL_PORT" \
    --argjson public_port "$HTTPS_PORT" \
    --arg path "$VLESS_PATH" \
    --arg api_listen "$XRAY_API_LISTEN" \
    --arg force_ipv4 "$XRAY_FORCE_IPV4" \
    --argjson clients "$clients_json" \
    '{
      log: $log_config,
      api: {
        tag: "api",
        listen: $api_listen,
        services: [
          "StatsService"
        ]
      },
      policy: {
        levels: {
          "0": {
            statsUserUplink: true,
            statsUserDownlink: true,
            statsUserOnline: true
          }
        },
        system: {
          statsInboundUplink: true,
          statsInboundDownlink: true,
          statsOutboundUplink: true,
          statsOutboundDownlink: true
        }
      },
      stats: {},
      routing: {
        domainStrategy: (if $force_ipv4 == "1" then "IPIfNonMatch" else "AsIs" end),
        rules: [
          {
            type: "field",
            ip: [
              "geoip:private"
            ],
            outboundTag: "block"
          },
          {
            type: "field",
            network: "tcp,udp",
            outboundTag: "direct"
          }
        ]
      },
      inbounds: [
        {
          tag: "vless-ws-local",
          listen: (if $frontend_mode == "direct" then "0.0.0.0" else "127.0.0.1" end),
          port: (if $frontend_mode == "direct" then $public_port else $local_port end),
          protocol: "vless",
          settings: {
            clients: $clients,
            decryption: "none"
          },
          streamSettings: {
            network: "ws",
            security: "none",
            wsSettings: {
              path: $path
            }
          },
          sniffing: {
            enabled: true,
            destOverride: [
              "http",
              "tls",
              "quic"
            ]
          }
        }
      ],
      outbounds: [
        {
          tag: "direct",
          protocol: "freedom",
          settings: {
            domainStrategy: (if $force_ipv4 == "1" then "UseIPv4" else "AsIs" end)
          }
        },
        {
          tag: "block",
          protocol: "blackhole"
        }
      ]
    }' > "$tmp"
  install -m 0600 -o xray -g xray "$tmp" "$CONFIG_FILE"
  rm -f "$tmp"
}

bytes_human() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ");
    i = 1;
    while (b >= 1024 && i < 6) {
      b = b / 1024;
      i++;
    }
    if (i == 1) {
      printf "%.0f %s", b, u[i];
    } else {
      printf "%.2f %s", b, u[i];
    }
  }'
}

valid_interval() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 3600 ))
}

stats_query_json() {
  local pattern="${1:-user>>>}"
  local out

  have xray || die_with_status 500 dependency_error "xray не найден. Установите Xray или запустите установщик заново."
  if out="$(xray api statsquery --server="$XRAY_API_LISTEN" -pattern "$pattern" 2>&1)"; then
    :
  elif out="$(xray api statsquery -server="$XRAY_API_LISTEN" -pattern "$pattern" 2>&1)"; then
    :
  elif out="$(xray api statsquery -s "$XRAY_API_LISTEN" -pattern "$pattern" 2>&1)"; then
    :
  else
    echo "$out" >&2
    die_with_status 503 service_unavailable "Xray Stats API недоступен на $XRAY_API_LISTEN. Выполните: vlessctl restart"
  fi

  if ! jq -e . >/dev/null 2>&1 <<< "$out"; then
    echo "$out" >&2
    die_with_status 502 bad_gateway "Xray Stats API вернул не JSON."
  fi
  printf '%s\n' "$out"
}

stat_value() {
  local json="$1"
  local key="$2"
  jq -r --arg key "$key" '
    def stats_array:
      if (.stat | type) == "array" then .stat
      elif (.stats | type) == "array" then .stats
      else [] end;
    ([stats_array[]? | select(.name == $key) | (.value // .Value // 0)][0] // 0)
  ' <<< "$json"
}

active_xray_tcp_connections() {
  if ! have ss; then
    echo "unknown"
    return 0
  fi
  ss -Htn state established 2>/dev/null |
    awk -v p=":${XRAY_LISTEN_PORT}$" '$4 ~ p {c++} END {print c + 0}'
}

restart_xray() {
  systemctl daemon-reload
  systemctl restart xray
}

print_link_for() {
  local name="$1"
  local uuid
  local path_enc
  local name_enc
  uuid="$(client_uuid "$name")"
  [[ -n "$uuid" && "$uuid" != "null" ]] || die_with_status 404 not_found "клиент не найден: $name"
  path_enc="$(urlencode "$VLESS_PATH")"
  name_enc="$(urlencode "$name")"
  if [[ "$FRONTEND_MODE" == "direct" ]]; then
    printf 'vless://%s@%s:%s?encryption=none&security=none&type=ws&host=%s&path=%s#%s\n' \
      "$uuid" "$PUBLIC_HOST" "$HTTPS_PORT" "$PUBLIC_HOST" "$path_enc" "$name_enc"
  else
    printf 'vless://%s@%s:%s?encryption=none&security=tls&type=ws&host=%s&sni=%s&path=%s#%s\n' \
      "$uuid" "$PUBLIC_HOST" "$HTTPS_PORT" "$PUBLIC_HOST" "$PUBLIC_HOST" "$path_enc" "$name_enc"
  fi
}

ensure_qrencode() {
  ensure_command qrencode qrencode
}

print_link_and_qr_for() {
  local name="$1"
  local link
  link="$(print_link_for "$name")"
  printf '%s\n\n' "$link"
  echo "QR для импорта:"
  ensure_qrencode
  qrencode -t ANSIUTF8 "$link"
}

cmd_add() {
  local name="${1:-}"
  local requested_name auto_incremented=0
  local uuid
  local created_at
  local tmp
  local link qr_ansi qr_png_base64

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      name="pipiska1"
    else
      read -r -p "Имя клиента [pipiska1]: " name
      name="${name:-pipiska1}"
    fi
  fi
  requested_name="$name"
  valid_client_name "$name" || die_with_status 400 bad_request "имя клиента должно быть 1-64 символа: буквы, цифры, точка, underscore, дефис, @."
  if client_name_exists "$name"; then
    name="$(next_client_name "$name")"
    auto_incremented=1
    [[ "$JSON_OUTPUT" == "1" ]] || echo "Клиент уже существует, создаю следующего: $name"
  fi

  uuid="$(new_uuid)"
  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$(mktemp)"
  jq \
    --arg name "$name" \
    --arg uuid "$uuid" \
    --arg created_at "$created_at" \
    '. + [{name:$name, uuid:$uuid, created_at:$created_at}]' \
    "$USERS_FILE" > "$tmp"
  install -m 0600 -o xray -g xray "$tmp" "$USERS_FILE"
  rm -f "$tmp"

  render_config
  restart_xray
  link="$(print_link_for "$name")"

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    ensure_qrencode
    ensure_command base64 coreutils
    qr_ansi="$(printf '%s' "$link" | qrencode -t ANSIUTF8)"
    qr_png_base64="$(qr_png_base64_from_text "$link")" || die_with_status 500 dependency_error "не удалось создать PNG QR для клиента ${name}."
    printf '{"ok":true,"status_code":201,"status":"created","action":"add","requested_name":%s,"name":%s,"auto_incremented":%s,"uuid":%s,"created_at":%s,"link":%s,"qr_ansi_utf8":%s,"qr_png_mime":"image/png","qr_png_base64":%s,"qr_png_data_uri":%s}\n' \
      "$(json_escape "$requested_name")" \
      "$(json_escape "$name")" \
      "$([[ "$auto_incremented" == "1" ]] && echo true || echo false)" \
      "$(json_escape "$uuid")" \
      "$(json_escape "$created_at")" \
      "$(json_escape "$link")" \
      "$(json_escape "$qr_ansi")" \
      "$(json_escape "$qr_png_base64")" \
      "$(json_escape "data:image/png;base64,${qr_png_base64}")"
    return 0
  fi

  echo "Клиент добавлен: $name"
  printf '%s\n\n' "$link"
  echo "QR для импорта:"
  ensure_qrencode
  qrencode -t ANSIUTF8 "$link"
}

cmd_delete() {
  local name="${1:-}"
  local uuid created_at
  local tmp

  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для удаления: vlessctl -j delete <name|number>"
    fi
    echo "Текущие клиенты:"
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name)"' "$USERS_FILE"
    read -r -p "Клиент для удаления: " name
  fi

  if [[ "$name" =~ ^[0-9]+$ ]]; then
    name="$(client_name_by_number "$name")"
  fi

  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  client_exists "$name" || die_with_status 404 not_found "клиент не найден: $name"
  uuid="$(client_uuid "$name")"
  created_at="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .created_at // empty' "$USERS_FILE" | head -n 1)"

  tmp="$(mktemp)"
  jq --arg name "$name" '[.[] | select(.name != $name)]' "$USERS_FILE" > "$tmp"
  install -m 0600 -o xray -g xray "$tmp" "$USERS_FILE"
  rm -f "$tmp"

  render_config
  restart_xray
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"status_code":200,"status":"deleted","action":"delete","name":%s,"uuid":%s,"created_at":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_string_or_null "$uuid")" \
      "$(json_string_or_null "$created_at")"
    return 0
  fi
  echo "Клиент удален: $name"
}

cmd_list() {
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    jq -c '{ok:true,status_code:200,status:"ok",clients:.}' "$USERS_FILE"
    return 0
  fi

  if [[ "$(jq 'length' "$USERS_FILE")" == "0" ]]; then
    echo "Клиентов нет."
    return 0
  fi
  printf '%-24s %-36s %s\n' "name" "uuid" "created_at"
  jq -r '.[] | [.name, .uuid, .created_at] | @tsv' "$USERS_FILE" |
    while IFS=$'\t' read -r name uuid created_at; do
      printf '%-24s %-36s %s\n' "$name" "$uuid" "$created_at"
    done
}

cmd_show() {
  local name="${1:-}"
  local uuid created_at link first one
  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для показа: vlessctl -j show <name|number|all>"
    fi
    echo "Текущие клиенты:"
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name)"' "$USERS_FILE"
    read -r -p "Клиент для показа, или all: " name
  fi
  if [[ "$name" == "all" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      printf '{"ok":true,"status_code":200,"status":"ok","links":['
      first=1
      while IFS=$'\t' read -r one uuid created_at; do
        [[ -n "$one" ]] || continue
        link="$(print_link_for "$one")"
        (( first == 1 )) || printf ','
        first=0
        printf '{"name":%s,"uuid":%s,"created_at":%s,"link":%s}' \
          "$(json_escape "$one")" \
          "$(json_escape "$uuid")" \
          "$(json_string_or_null "$created_at")" \
          "$(json_escape "$link")"
      done < <(jq -r '.[] | [.name, .uuid, (.created_at // "")] | @tsv' "$USERS_FILE")
      printf ']}\n'
      return 0
    fi
    jq -r '.[].name' "$USERS_FILE" | while read -r one; do
      print_link_for "$one"
    done
    return 0
  fi
  if [[ "$name" =~ ^[0-9]+$ ]]; then
    name="$(client_name_by_number "$name")"
  fi
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  client_exists "$name" || die_with_status 404 not_found "клиент не найден: $name"
  uuid="$(client_uuid "$name")"
  created_at="$(jq -r --arg name "$name" '.[] | select(.name == $name) | .created_at // empty' "$USERS_FILE" | head -n 1)"
  link="$(print_link_for "$name")"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"status_code":200,"status":"ok","name":%s,"uuid":%s,"created_at":%s,"link":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$uuid")" \
      "$(json_string_or_null "$created_at")" \
      "$(json_escape "$link")"
    return 0
  fi
  printf '%s\n' "$link"
}

cmd_qr() {
  local name="${1:-}"
  local link qr_ansi qr_png_base64 first one
  if [[ -z "$name" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      die_with_status 400 bad_request "укажите клиента для QR: vlessctl -j qr <name|number|all>"
    fi
    echo "Текущие клиенты:"
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name)"' "$USERS_FILE"
    read -r -p "Клиент для показа QR, или all: " name
  fi
  if [[ "$name" == "all" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      ensure_qrencode
      ensure_command base64 coreutils
      printf '{"ok":true,"status_code":200,"status":"ok","items":['
      first=1
      while read -r one; do
        [[ -n "$one" ]] || continue
        link="$(print_link_for "$one")"
        qr_ansi="$(printf '%s' "$link" | qrencode -t ANSIUTF8)"
        qr_png_base64="$(qr_png_base64_from_text "$link")" || die_with_status 500 dependency_error "не удалось создать PNG QR для клиента ${one}."
        (( first == 1 )) || printf ','
        first=0
        printf '{"name":%s,"link":%s,"qr_ansi_utf8":%s,"qr_png_mime":"image/png","qr_png_base64":%s,"qr_png_data_uri":%s}' \
          "$(json_escape "$one")" \
          "$(json_escape "$link")" \
          "$(json_escape "$qr_ansi")" \
          "$(json_escape "$qr_png_base64")" \
          "$(json_escape "data:image/png;base64,${qr_png_base64}")"
      done < <(jq -r '.[].name' "$USERS_FILE")
      printf ']}\n'
      return 0
    fi
    jq -r '.[].name' "$USERS_FILE" | while read -r one; do
      echo "Клиент: $one"
      print_link_and_qr_for "$one"
      echo
    done
    return 0
  fi
  if [[ "$name" =~ ^[0-9]+$ ]]; then
    name="$(client_name_by_number "$name")"
  fi
  [[ -n "$name" ]] || die_with_status 400 bad_request "клиент не выбран."
  client_exists "$name" || die_with_status 404 not_found "клиент не найден: $name"
  link="$(print_link_for "$name")"
  ensure_qrencode
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    ensure_command base64 coreutils
    qr_ansi="$(printf '%s' "$link" | qrencode -t ANSIUTF8)"
    qr_png_base64="$(qr_png_base64_from_text "$link")" || die_with_status 500 dependency_error "не удалось создать PNG QR для клиента ${name}."
    printf '{"ok":true,"status_code":200,"status":"ok","name":%s,"link":%s,"qr_ansi_utf8":%s,"qr_png_mime":"image/png","qr_png_base64":%s,"qr_png_data_uri":%s}\n' \
      "$(json_escape "$name")" \
      "$(json_escape "$link")" \
      "$(json_escape "$qr_ansi")" \
      "$(json_escape "$qr_png_base64")" \
      "$(json_escape "data:image/png;base64,${qr_png_base64}")"
    return 0
  fi
  printf '%s\n\n' "$link"
  echo "QR для импорта:"
  qrencode -t ANSIUTF8 "$link"
}

cmd_traffic() {
  local stats
  local name up down total
  local sum_up=0
  local sum_down=0
  local first=1

  if [[ "$(jq 'length' "$USERS_FILE")" == "0" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      printf '{"ok":true,"status_code":200,"status":"ok","clients":[],"total":{"uplink_bytes":0,"downlink_bytes":0,"total_bytes":0}}\n'
    else
      echo "Клиентов нет."
    fi
    return 0
  fi

  stats="$(stats_query_json "user>>>")"
  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"status_code":200,"status":"ok","clients":['
    while read -r name; do
      up="$(stat_value "$stats" "user>>>${name}>>>traffic>>>uplink")"
      down="$(stat_value "$stats" "user>>>${name}>>>traffic>>>downlink")"
      [[ "$up" =~ ^[0-9]+$ ]] || up=0
      [[ "$down" =~ ^[0-9]+$ ]] || down=0
      total=$((up + down))
      sum_up=$((sum_up + up))
      sum_down=$((sum_down + down))
      (( first == 1 )) || printf ','
      first=0
      printf '{"name":%s,"uplink_bytes":%s,"downlink_bytes":%s,"total_bytes":%s,"uplink":%s,"downlink":%s,"total":%s}' \
        "$(json_escape "$name")" \
        "$up" \
        "$down" \
        "$total" \
        "$(json_escape "$(bytes_human "$up")")" \
        "$(json_escape "$(bytes_human "$down")")" \
        "$(json_escape "$(bytes_human "$total")")"
    done < <(jq -r '.[].name' "$USERS_FILE")
    total=$((sum_up + sum_down))
    printf '],"total":{"uplink_bytes":%s,"downlink_bytes":%s,"total_bytes":%s,"uplink":%s,"downlink":%s,"total":%s}}\n' \
      "$sum_up" \
      "$sum_down" \
      "$total" \
      "$(json_escape "$(bytes_human "$sum_up")")" \
      "$(json_escape "$(bytes_human "$sum_down")")" \
      "$(json_escape "$(bytes_human "$total")")"
    return 0
  fi

  printf '%-24s %14s %14s %14s\n' "name" "uplink" "downlink" "total"
  while read -r name; do
    up="$(stat_value "$stats" "user>>>${name}>>>traffic>>>uplink")"
    down="$(stat_value "$stats" "user>>>${name}>>>traffic>>>downlink")"
    [[ "$up" =~ ^[0-9]+$ ]] || up=0
    [[ "$down" =~ ^[0-9]+$ ]] || down=0
    total=$((up + down))
    sum_up=$((sum_up + up))
    sum_down=$((sum_down + down))
    printf '%-24s %14s %14s %14s\n' \
      "$name" "$(bytes_human "$up")" "$(bytes_human "$down")" "$(bytes_human "$total")"
  done < <(jq -r '.[].name' "$USERS_FILE")

  total=$((sum_up + sum_down))
  printf '%-24s %14s %14s %14s\n' \
    "TOTAL" "$(bytes_human "$sum_up")" "$(bytes_human "$sum_down")" "$(bytes_human "$total")"
}

cmd_online() {
  local interval="${1:-10}"
  local before after tcp_count
  local name before_up before_down after_up after_down delta_up delta_down delta_total
  local active active_users=0
  local first=1

  valid_interval "$interval" || die_with_status 400 bad_request "интервал должен быть числом от 1 до 3600 секунд."
  if [[ "$(jq 'length' "$USERS_FILE")" == "0" ]]; then
    if [[ "$JSON_OUTPUT" == "1" ]]; then
      printf '{"ok":true,"status_code":200,"status":"ok","interval_seconds":%s,"tcp_connections":null,"active_users":0,"clients":[]}\n' "$interval"
    else
      echo "Клиентов нет."
    fi
    return 0
  fi

  before="$(stats_query_json "user>>>")"
  sleep "$interval"
  after="$(stats_query_json "user>>>")"
  tcp_count="$(active_xray_tcp_connections)"

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '{"ok":true,"status_code":200,"status":"ok","interval_seconds":%s,"tcp_connections":%s,"clients":[' \
      "$interval" \
      "$(json_number_or_null "$tcp_count")"
  else
  echo "Observed interval: ${interval}s"
  echo "Established local Xray TCP connections: ${tcp_count}"
  echo "Note: idle connected clients may show no traffic during this interval."
  printf '%-24s %-8s %14s %14s %14s\n' "name" "active" "uplink" "downlink" "total"
  fi

  while read -r name; do
    before_up="$(stat_value "$before" "user>>>${name}>>>traffic>>>uplink")"
    before_down="$(stat_value "$before" "user>>>${name}>>>traffic>>>downlink")"
    after_up="$(stat_value "$after" "user>>>${name}>>>traffic>>>uplink")"
    after_down="$(stat_value "$after" "user>>>${name}>>>traffic>>>downlink")"
    [[ "$before_up" =~ ^[0-9]+$ ]] || before_up=0
    [[ "$before_down" =~ ^[0-9]+$ ]] || before_down=0
    [[ "$after_up" =~ ^[0-9]+$ ]] || after_up=0
    [[ "$after_down" =~ ^[0-9]+$ ]] || after_down=0

    delta_up=$((after_up - before_up))
    delta_down=$((after_down - before_down))
    (( delta_up < 0 )) && delta_up=0
    (( delta_down < 0 )) && delta_down=0
    delta_total=$((delta_up + delta_down))
    active="no"
    if (( delta_total > 0 )); then
      active="yes"
      active_users=$((active_users + 1))
    fi

    if [[ "$JSON_OUTPUT" == "1" ]]; then
      (( first == 1 )) || printf ','
      first=0
      printf '{"name":%s,"active":%s,"uplink_bytes":%s,"downlink_bytes":%s,"total_bytes":%s,"uplink":%s,"downlink":%s,"total":%s}' \
        "$(json_escape "$name")" \
        "$([[ "$active" == "yes" ]] && echo true || echo false)" \
        "$delta_up" \
        "$delta_down" \
        "$delta_total" \
        "$(json_escape "$(bytes_human "$delta_up")")" \
        "$(json_escape "$(bytes_human "$delta_down")")" \
        "$(json_escape "$(bytes_human "$delta_total")")"
      continue
    fi

    printf '%-24s %-8s %14s %14s %14s\n' \
      "$name" "$active" "$(bytes_human "$delta_up")" "$(bytes_human "$delta_down")" "$(bytes_human "$delta_total")"
  done < <(jq -r '.[].name' "$USERS_FILE")

  if [[ "$JSON_OUTPUT" == "1" ]]; then
    printf '],"active_users":%s}\n' "$active_users"
    return 0
  fi

  echo "Users with traffic during interval: ${active_users}"
}

cmd_help() {
  cat <<'EOF'
Usage:
  vlessctl -j|--json <command>
  vlessctl add [name]
  vlessctl delete [name|number]
  vlessctl list
  vlessctl show [name|number|all]
  vlessctl qr [name|number|all]
  vlessctl traffic
  vlessctl online [seconds]
  vlessctl render
  vlessctl restart
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
    help|-h|--help)
      cmd_help
      return 0
      ;;
  esac

  require_root
  have jq || die_with_status 500 dependency_error "jq не найден. Установите jq или запустите install_vless.sh заново."
  load_env
  ensure_files

  case "$cmd" in
    add) cmd_add "${1:-}" ;;
    delete|del|remove|rm) cmd_delete "${1:-}" ;;
    list|ls) cmd_list ;;
    show|link) cmd_show "${1:-}" ;;
    qr|qrcode) cmd_qr "${1:-}" ;;
    traffic|stats|stat|trafic) cmd_traffic ;;
    online) cmd_online "${1:-10}" ;;
    render)
      render_config
      if [[ "$JSON_OUTPUT" == "1" ]]; then
        printf '{"ok":true,"status_code":200,"status":"ok","action":"render","config_file":%s}\n' "$(json_escape "$CONFIG_FILE")"
      fi
      ;;
    restart)
      render_config
      restart_xray
      if [[ "$JSON_OUTPUT" == "1" ]]; then
        printf '{"ok":true,"status_code":200,"status":"ok","action":"restart"}\n'
      fi
      ;;
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
