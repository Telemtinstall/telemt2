#!/usr/bin/env bash
set -Eeuo pipefail

CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/xray}"
ENV_FILE="${ENV_FILE:-$CONFIG_DIR/vless.env}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

load_env() {
  [[ -r "$ENV_FILE" ]] || die "VLESS env file not found: $ENV_FILE"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  CONFIG_FILE="${CONFIG_FILE:-$CONFIG_DIR/config.json}"
  USERS_FILE="${USERS_FILE:-$CONFIG_DIR/users.json}"
  : "${PUBLIC_HOST:?missing PUBLIC_HOST in $ENV_FILE}"
  : "${HTTPS_PORT:?missing HTTPS_PORT in $ENV_FILE}"
  : "${LOCAL_PORT:?missing LOCAL_PORT in $ENV_FILE}"
  : "${VLESS_PATH:?missing VLESS_PATH in $ENV_FILE}"
  FRONTEND_MODE="${FRONTEND_MODE:-mask}"
  case "$FRONTEND_MODE" in
    mask|direct) ;;
    *) die "Unsupported FRONTEND_MODE in $ENV_FILE: $FRONTEND_MODE" ;;
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
  [[ $EUID -eq 0 ]] || die "Run as root."
}

valid_client_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]
}

logs_enabled() {
  case "${ENABLE_ACCESS_LOGS,,}" in
    1|y|yes|true|on) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_files() {
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

  have xray || die "xray is required."
  if out="$(xray api statsquery --server="$XRAY_API_LISTEN" -pattern "$pattern" 2>&1)"; then
    :
  elif out="$(xray api statsquery -server="$XRAY_API_LISTEN" -pattern "$pattern" 2>&1)"; then
    :
  elif out="$(xray api statsquery -s "$XRAY_API_LISTEN" -pattern "$pattern" 2>&1)"; then
    :
  else
    echo "$out" >&2
    die "Xray stats API is unavailable at $XRAY_API_LISTEN. Run: vlessctl restart"
  fi

  if ! jq -e . >/dev/null 2>&1 <<< "$out"; then
    echo "$out" >&2
    die "Xray stats API returned non-JSON output."
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
  [[ -n "$uuid" && "$uuid" != "null" ]] || die "Client not found: $name"
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
  if have qrencode; then
    return 0
  fi

  if have apt-get; then
    echo "qrencode is not installed. Installing it..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y qrencode
  fi

  have qrencode || die "qrencode is not installed. Install it manually and retry."
}

print_link_and_qr_for() {
  local name="$1"
  local link
  link="$(print_link_for "$name")"
  printf '%s\n\n' "$link"
  echo "QR code:"
  ensure_qrencode
  qrencode -t ANSIUTF8 "$link"
}

cmd_add() {
  local name="${1:-}"
  local uuid
  local created_at
  local tmp

  if [[ -z "$name" ]]; then
    read -r -p "Client name: " name
  fi
  valid_client_name "$name" || die "Client name must be 1-64 chars: letters, digits, dot, underscore, dash, @."
  if client_exists "$name"; then
    die "Client already exists: $name"
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
  echo "Client added: $name"
  print_link_and_qr_for "$name"
}

cmd_delete() {
  local name="${1:-}"
  local tmp

  if [[ -z "$name" ]]; then
    echo "Current clients:"
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name)"' "$USERS_FILE"
    read -r -p "Client to delete: " name
  fi

  if [[ "$name" =~ ^[0-9]+$ ]]; then
    name="$(jq -r --argjson n "$name" '.[$n - 1].name // empty' "$USERS_FILE")"
  fi

  [[ -n "$name" ]] || die "No client selected."
  client_exists "$name" || die "Client not found: $name"

  tmp="$(mktemp)"
  jq --arg name "$name" '[.[] | select(.name != $name)]' "$USERS_FILE" > "$tmp"
  install -m 0600 -o xray -g xray "$tmp" "$USERS_FILE"
  rm -f "$tmp"

  render_config
  restart_xray
  echo "Client deleted: $name"
}

cmd_list() {
  if [[ "$(jq 'length' "$USERS_FILE")" == "0" ]]; then
    echo "No clients."
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
  if [[ -z "$name" ]]; then
    echo "Current clients:"
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name)"' "$USERS_FILE"
    read -r -p "Client to show, or all: " name
  fi
  if [[ "$name" == "all" ]]; then
    jq -r '.[].name' "$USERS_FILE" | while read -r one; do
      print_link_for "$one"
    done
    return 0
  fi
  if [[ "$name" =~ ^[0-9]+$ ]]; then
    name="$(jq -r --argjson n "$name" '.[$n - 1].name // empty' "$USERS_FILE")"
  fi
  [[ -n "$name" ]] || die "No client selected."
  print_link_for "$name"
}

cmd_qr() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "Current clients:"
    jq -r 'to_entries[] | "\(.key + 1)) \(.value.name)"' "$USERS_FILE"
    read -r -p "Client to show QR, or all: " name
  fi
  if [[ "$name" == "all" ]]; then
    jq -r '.[].name' "$USERS_FILE" | while read -r one; do
      echo "Client: $one"
      print_link_and_qr_for "$one"
      echo
    done
    return 0
  fi
  if [[ "$name" =~ ^[0-9]+$ ]]; then
    name="$(jq -r --argjson n "$name" '.[$n - 1].name // empty' "$USERS_FILE")"
  fi
  [[ -n "$name" ]] || die "No client selected."
  print_link_and_qr_for "$name"
}

cmd_traffic() {
  local stats
  local name up down total
  local sum_up=0
  local sum_down=0

  if [[ "$(jq 'length' "$USERS_FILE")" == "0" ]]; then
    echo "No clients."
    return 0
  fi

  stats="$(stats_query_json "user>>>")"
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

  valid_interval "$interval" || die "Interval must be a number from 1 to 3600 seconds."
  if [[ "$(jq 'length' "$USERS_FILE")" == "0" ]]; then
    echo "No clients."
    return 0
  fi

  before="$(stats_query_json "user>>>")"
  sleep "$interval"
  after="$(stats_query_json "user>>>")"
  tcp_count="$(active_xray_tcp_connections)"

  echo "Observed interval: ${interval}s"
  echo "Established local Xray TCP connections: ${tcp_count}"
  echo "Note: idle connected clients may show no traffic during this interval."
  printf '%-24s %-8s %14s %14s %14s\n' "name" "active" "uplink" "downlink" "total"

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

    printf '%-24s %-8s %14s %14s %14s\n' \
      "$name" "$active" "$(bytes_human "$delta_up")" "$(bytes_human "$delta_down")" "$(bytes_human "$delta_total")"
  done < <(jq -r '.[].name' "$USERS_FILE")

  echo "Users with traffic during interval: ${active_users}"
}

cmd_help() {
  cat <<'EOF'
Usage:
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
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    help|-h|--help)
      cmd_help
      return 0
      ;;
  esac

  require_root
  have jq || die "jq is required."
  load_env
  ensure_files

  case "$cmd" in
    add) cmd_add "${1:-}" ;;
    delete|del|remove|rm) cmd_delete "${1:-}" ;;
    list|ls) cmd_list ;;
    show|link) cmd_show "${1:-}" ;;
    qr|qrcode) cmd_qr "${1:-}" ;;
    traffic|stats) cmd_traffic ;;
    online) cmd_online "${1:-10}" ;;
    render) render_config ;;
    restart) render_config; restart_xray ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"
