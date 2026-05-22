#!/usr/bin/env bash
set -Eeuo pipefail

# Experimental WhatsApp Chat Proxy installer for Debian/Ubuntu.
# It never overwrites an existing Telemt/nginx 443 setup. If 443 is already
# owned by nginx with a Telemt stream map, it can add one SNI route after backup.

PROXY_DOMAIN="${PROXY_DOMAIN:-}"
INSTALL_MODE="${INSTALL_MODE:-auto}" # auto, direct, sni
WHATSAPP_IMAGE="${WHATSAPP_IMAGE:-facebook/whatsapp_proxy:latest}"
PUBLIC_587="${PUBLIC_587:-yes}"
LOCAL_TLS_PORT="${LOCAL_TLS_PORT:-18443}"
LOCAL_STATS_PORT="${LOCAL_STATS_PORT:-18199}"
ENABLE_DOCKER_LOGS="${ENABLE_DOCKER_LOGS:-no}"
ASSUME_YES="${ASSUME_YES:-0}"
INSTALL_RETRIES="${INSTALL_RETRIES:-3}"
RETRY_DELAY_SECONDS="${RETRY_DELAY_SECONDS:-5}"

APP_DIR="/opt/whatsapp-proxy"
COMPOSE_FILE="$APP_DIR/docker-compose.yml"
ENV_FILE="$APP_DIR/whatsapp-proxy.env"
STATE_FILE="/root/.install_whatsapp_proxy.state"
RESUME_CONFIG="/root/.install_whatsapp_proxy.config"
BACKUP_ROOT="/root/whatsapp-proxy-install-backups"
SNIPPET_FILE="/root/whatsapp-proxy-nginx-stream-snippet.conf"
CONTAINER_NAME="whatsapp_proxy"

step_no=0
BACKUP_DIR=""
SERVER_PUBLIC_IPV4=""
SELECTED_MODE=""
NGINX_STREAM_CONF=""

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

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
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

prompt() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local answer=""
  local current_value="${!var_name:-}"

  if [[ "$ASSUME_YES" == "1" && -n "$current_value" ]]; then
    printf '%s: %s\n' "$label" "$current_value"
    return 0
  fi

  if [[ -n "$current_value" ]]; then
    printf '%s [%s]: ' "$label" "$current_value"
  elif [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value"
  else
    printf '%s: ' "$label"
  fi

  read -r answer
  answer="$(trim_value "$answer")"
  if [[ -n "$answer" ]]; then
    printf -v "$var_name" '%s' "$answer"
  elif [[ -z "$current_value" ]]; then
    printf -v "$var_name" '%s' "$default_value"
  fi
}

confirm() {
  local prompt_text="$1"
  local answer=""
  if [[ "$ASSUME_YES" == "1" ]]; then
    echo "$prompt_text y"
    return 0
  fi
  printf '%s' "$prompt_text"
  read -r answer
  answer="$(trim_value "$answer")"
  answer="${answer,,}"
  [[ "$answer" == "y" || "$answer" == "yes" || "$answer" == "да" ]]
}

normalize_yes_no() {
  local value
  value="$(trim_value "$1")"
  case "${value,,}" in
    y|yes|да|1|true|on) echo "yes" ;;
    n|no|нет|0|false|off|"") echo "no" ;;
    *) die "Use yes/no." ;;
  esac
}

valid_domain() {
  local domain="$1"
  [[ ${#domain} -le 253 ]] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 65535 ))
}

valid_mode() {
  [[ "$1" == "auto" || "$1" == "direct" || "$1" == "sni" ]]
}

validate_input() {
  PROXY_DOMAIN="$(trim_value "$PROXY_DOMAIN")"
  PROXY_DOMAIN="${PROXY_DOMAIN,,}"
  INSTALL_MODE="$(trim_value "$INSTALL_MODE")"
  INSTALL_MODE="${INSTALL_MODE,,}"
  PUBLIC_587="$(normalize_yes_no "$PUBLIC_587")"
  ENABLE_DOCKER_LOGS="$(normalize_yes_no "$ENABLE_DOCKER_LOGS")"

  valid_domain "$PROXY_DOMAIN" || die "Proxy domain must be an ASCII domain or punycode domain, not an IP address."
  valid_mode "$INSTALL_MODE" || die "Install mode must be auto, direct, or sni."
  valid_port "$LOCAL_TLS_PORT" || die "Local TLS port must be 1..65535."
  valid_port "$LOCAL_STATS_PORT" || die "Local stats port must be 1..65535."
  [[ "$LOCAL_TLS_PORT" != "$LOCAL_STATS_PORT" ]] || die "Local TLS and stats ports must be different."
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
PROXY_DOMAIN=$(printf '%q' "$PROXY_DOMAIN")
INSTALL_MODE=$(printf '%q' "$INSTALL_MODE")
WHATSAPP_IMAGE=$(printf '%q' "$WHATSAPP_IMAGE")
PUBLIC_587=$(printf '%q' "$PUBLIC_587")
LOCAL_TLS_PORT=$(printf '%q' "$LOCAL_TLS_PORT")
LOCAL_STATS_PORT=$(printf '%q' "$LOCAL_STATS_PORT")
ENABLE_DOCKER_LOGS=$(printf '%q' "$ENABLE_DOCKER_LOGS")
SELECTED_MODE=$(printf '%q' "$SELECTED_MODE")
NGINX_STREAM_CONF=$(printf '%q' "$NGINX_STREAM_CONF")
SERVER_PUBLIC_IPV4=$(printf '%q' "$SERVER_PUBLIC_IPV4")
BACKUP_DIR=$(printf '%q' "$BACKUP_DIR")
EOF
  chmod 600 "$RESUME_CONFIG"
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

public_ipv4() {
  local ip=""
  ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ -z "$ip" ]]; then
    ip="$(curl -4fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  fi
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  printf '%s\n' "$ip"
}

system_domain_a_records() {
  local domain="$1"
  if have host; then
    host -t A "$domain" 2>/dev/null | awk '/has address/ {print $4}' | sort -u
  elif have getent; then
    getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u
  fi
}

doh_domain_a_records() {
  local domain="$1"
  have curl || return 0
  curl -4fsS --max-time 10 "https://dns.google/resolve?name=${domain}&type=A" 2>/dev/null |
    tr ',' '\n' |
    sed -n 's/.*"data":"\([0-9][0-9.]*\)".*/\1/p' |
    sort -u
}

records_contain_ip() {
  local ip="$1"
  shift
  local record
  for record in "$@"; do
    [[ "$record" == "$ip" ]] && return 0
  done
  return 1
}

dns_preflight() {
  local system_records doh_records chosen_records
  if [[ -z "$SERVER_PUBLIC_IPV4" ]]; then
    SERVER_PUBLIC_IPV4="$(public_ipv4)" || die "Cannot detect this server public IPv4."
  fi

  mapfile -t system_records < <(system_domain_a_records "$PROXY_DOMAIN")
  mapfile -t doh_records < <(doh_domain_a_records "$PROXY_DOMAIN")

  echo "server_public_ipv4=$SERVER_PUBLIC_IPV4"
  echo "system_dns_a=${system_records[*]:-(none)}"
  echo "doh_dns_a=${doh_records[*]:-(none)}"

  if ((${#doh_records[@]} > 0)); then
    chosen_records=("${doh_records[@]}")
  else
    chosen_records=("${system_records[@]}")
  fi

  ((${#chosen_records[@]} > 0)) || die "No A record found for $PROXY_DOMAIN."
  records_contain_ip "$SERVER_PUBLIC_IPV4" "${chosen_records[@]}" ||
    die "A record for $PROXY_DOMAIN does not point to this server IPv4 ($SERVER_PUBLIC_IPV4). Fix DNS first."
}

port_listener() {
  local port="$1"
  ss -H -ltnp "sport = :$port" 2>/dev/null || true
}

port_is_busy() {
  [[ -n "$(port_listener "$1")" ]]
}

find_telemt_stream_conf() {
  local path
  for path in \
    /etc/nginx/modules-enabled/60-stream-sni.conf \
    /etc/nginx/modules-enabled/60-telemt-stream-sni.conf \
    /etc/nginx/modules-enabled/90-stream-sni.conf \
    /etc/nginx/stream-conf.d/telemt-sni.conf; do
    if [[ -f "$path" ]] && grep -q 'telemt_backend' "$path" && grep -q 'ssl_preread' "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done

  if [[ -d /etc/nginx ]]; then
    while IFS= read -r path; do
      if grep -q 'telemt_backend' "$path" && grep -q 'ssl_preread' "$path"; then
        printf '%s\n' "$path"
        return 0
      fi
    done < <(find /etc/nginx -type f -name '*.conf' 2>/dev/null)
  fi

  return 1
}

route_backend_for_domain() {
  local conf="$1"
  local domain="$2"
  awk -v domain="$domain" '
    $1 == domain {
      gsub(/;$/, "", $2)
      print $2
      exit
    }
  ' "$conf"
}

ensure_domain_not_already_routed_elsewhere() {
  local backend=""
  [[ -n "$NGINX_STREAM_CONF" && -f "$NGINX_STREAM_CONF" ]] || return 0
  backend="$(route_backend_for_domain "$NGINX_STREAM_CONF" "$PROXY_DOMAIN")"
  [[ -n "$backend" ]] || return 0

  if [[ "$backend" == "127.0.0.1:${LOCAL_TLS_PORT}" ]]; then
    return 0
  fi

  die "SNI domain $PROXY_DOMAIN is already routed in $NGINX_STREAM_CONF to $backend. Use a separate domain for WhatsApp proxy, for example wa.<your-domain>, with an A record pointing to this server."
}

select_mode() {
  local listener443 listener587
  listener443="$(port_listener 443)"
  listener587="$(port_listener 587)"

  if [[ -n "$listener443" ]]; then
    echo "Port 443/tcp is busy:"
    echo "$listener443"
  else
    echo "Port 443/tcp is free."
  fi

  if [[ "$PUBLIC_587" == "yes" && -n "$listener587" ]]; then
    echo "Port 587/tcp is busy:"
    echo "$listener587"
    if confirm "Disable public 587/tcp and continue without media helper port? [y/N]: "; then
      PUBLIC_587="no"
    else
      die "Free port 587/tcp or rerun with PUBLIC_587=no."
    fi
  fi

  if [[ "$INSTALL_MODE" == "direct" ]]; then
    [[ -z "$listener443" ]] || die "Direct mode needs free 443/tcp."
    SELECTED_MODE="direct"
    return 0
  fi

  if [[ "$INSTALL_MODE" == "sni" ]]; then
    [[ -n "$listener443" ]] || die "SNI mode is for an existing nginx stream on 443/tcp. Use direct mode if 443 is free."
    NGINX_STREAM_CONF="${NGINX_STREAM_CONF:-$(find_telemt_stream_conf || true)}"
    [[ -n "$NGINX_STREAM_CONF" ]] || die "Cannot find a known Telemt nginx stream config to patch safely."
    ensure_domain_not_already_routed_elsewhere
    SELECTED_MODE="sni"
    return 0
  fi

  if [[ -z "$listener443" ]]; then
    SELECTED_MODE="direct"
    return 0
  fi

  NGINX_STREAM_CONF="$(find_telemt_stream_conf || true)"
  if [[ -n "$NGINX_STREAM_CONF" ]]; then
    echo "Found Telemt nginx stream config: $NGINX_STREAM_CONF"
    ensure_domain_not_already_routed_elsewhere
    if confirm "Use SNI mode and add only one route for $PROXY_DOMAIN to existing stream map? [y/N]: "; then
      SELECTED_MODE="sni"
      return 0
    fi
  fi

  write_manual_snippet
  die "443/tcp is busy. Existing nginx config was not changed. Manual snippet saved to $SNIPPET_FILE."
}

write_manual_snippet() {
  cat > "$SNIPPET_FILE" <<EOF
# Manual nginx stream idea for WhatsApp proxy.
# Add this route inside your existing stream map, do not create a second server listening on 443.
#
# map \$ssl_preread_server_name \$telemt_backend {
#     ${PROXY_DOMAIN} 127.0.0.1:${LOCAL_TLS_PORT};
#     <existing routes stay here>
# }
#
# The WhatsApp proxy container should listen on 127.0.0.1:${LOCAL_TLS_PORT} -> container 443.
EOF
  chmod 600 "$SNIPPET_FILE"
}

backup_current_state() {
  local ts
  ts="$(date +%Y%m%d-%H%M%S)"
  BACKUP_DIR="${BACKUP_DIR:-$BACKUP_ROOT/$ts}"
  install -d -m 0700 "$BACKUP_DIR"
  [[ -f "$COMPOSE_FILE" ]] && cp -a "$COMPOSE_FILE" "$BACKUP_DIR/docker-compose.yml" || true
  [[ -f "$ENV_FILE" ]] && cp -a "$ENV_FILE" "$BACKUP_DIR/whatsapp-proxy.env" || true
  [[ -n "$NGINX_STREAM_CONF" && -f "$NGINX_STREAM_CONF" ]] && cp -a "$NGINX_STREAM_CONF" "$BACKUP_DIR/$(basename "$NGINX_STREAM_CONF").before-whatsapp" || true
  echo "backup_dir=$BACKUP_DIR"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  retry_command "apt update" apt-get update
  retry_command "base packages" apt-get install -y ca-certificates curl iproute2 bind9-host openssl
  if ! have docker; then
    retry_command "docker package" apt-get install -y docker.io
  fi
  if ! docker compose version >/dev/null 2>&1 && ! have docker-compose; then
    retry_command "docker compose package" apt-get install -y docker-compose-plugin || retry_command "docker-compose package" apt-get install -y docker-compose
  fi
  systemctl enable --now docker >/dev/null 2>&1 || service docker start || true
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

write_compose() {
  local port443_mapping=""
  local port587_mapping=""
  local logging_block=""

  install -d -m 0755 "$APP_DIR"

  if [[ "$SELECTED_MODE" == "direct" ]]; then
    port443_mapping='      - "0.0.0.0:443:443/tcp"'
  else
    port443_mapping="      - \"127.0.0.1:${LOCAL_TLS_PORT}:443/tcp\""
  fi

  if [[ "$PUBLIC_587" == "yes" ]]; then
    port587_mapping='      - "0.0.0.0:587:587/tcp"'
  else
    port587_mapping='      # public 587 disabled'
  fi

  if [[ "$ENABLE_DOCKER_LOGS" == "yes" ]]; then
    logging_block='    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"'
  else
    logging_block='    logging:
      driver: "none"'
  fi

  cat > "$ENV_FILE" <<EOF
PUBLIC_IP=$SERVER_PUBLIC_IPV4
SSL_DNS=$PROXY_DOMAIN
DEBUG=
EOF
  chmod 600 "$ENV_FILE"

  cat > "$COMPOSE_FILE" <<EOF
services:
  whatsapp_proxy:
    image: ${WHATSAPP_IMAGE}
    container_name: ${CONTAINER_NAME}
    restart: unless-stopped
    env_file:
      - ${ENV_FILE}
    ports:
${port443_mapping}
${port587_mapping}
      - "127.0.0.1:${LOCAL_STATS_PORT}:8199/tcp"
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "bash", "/usr/local/bin/healthcheck.sh"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 10s
${logging_block}
EOF
  chmod 600 "$COMPOSE_FILE"
}

patch_nginx_stream() {
  local tmp backup
  [[ "$SELECTED_MODE" == "sni" ]] || return 0
  [[ -n "$NGINX_STREAM_CONF" && -f "$NGINX_STREAM_CONF" ]] || die "nginx stream config not found."

  ensure_domain_not_already_routed_elsewhere
  if [[ "$(route_backend_for_domain "$NGINX_STREAM_CONF" "$PROXY_DOMAIN")" == "127.0.0.1:${LOCAL_TLS_PORT}" ]]; then
    echo "SNI route for $PROXY_DOMAIN already points to 127.0.0.1:${LOCAL_TLS_PORT} in $NGINX_STREAM_CONF."
    return 0
  fi

  backup="$BACKUP_DIR/$(basename "$NGINX_STREAM_CONF").before-whatsapp-patch"
  cp -a "$NGINX_STREAM_CONF" "$backup"
  tmp="$(mktemp)"

  awk -v domain="$PROXY_DOMAIN" -v backend="127.0.0.1:${LOCAL_TLS_PORT}" '
    /^[[:space:]]*default[[:space:]]/ && !added {
      print "        " domain " " backend "; # whatsapp-proxy managed"
      added=1
    }
    { print }
    END {
      if (!added) exit 2
    }
  ' "$NGINX_STREAM_CONF" > "$tmp" || {
    rm -f "$tmp"
    die "Cannot find default route in $NGINX_STREAM_CONF."
  }

  install -m 0644 "$tmp" "$NGINX_STREAM_CONF"
  rm -f "$tmp"

  if ! nginx -t; then
    cp -a "$backup" "$NGINX_STREAM_CONF"
    nginx -t || true
    die "nginx test failed. Restored backup: $backup"
  fi

  systemctl reload nginx >/dev/null 2>&1 || service nginx reload
}

configure_firewall() {
  local ports=()
  if [[ "$SELECTED_MODE" == "direct" ]]; then
    ports+=(443)
  fi
  if [[ "$PUBLIC_587" == "yes" ]]; then
    ports+=(587)
  fi
  ((${#ports[@]} > 0)) || return 0

  if have ufw && ufw status 2>/dev/null | grep -qi '^Status: active'; then
    local port
    for port in "${ports[@]}"; do
      ufw allow "${port}/tcp"
    done
    return 0
  fi

  if have firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
    local port
    for port in "${ports[@]}"; do
      firewall-cmd --add-port="${port}/tcp" >/dev/null
      firewall-cmd --permanent --add-port="${port}/tcp" >/dev/null
    done
    return 0
  fi

  echo "No active ufw/firewalld detected. If your provider has an external firewall, open: ${ports[*]}/tcp."
}

start_proxy() {
  retry_command "docker pull $WHATSAPP_IMAGE" docker pull "$WHATSAPP_IMAGE"
  compose_cmd -f "$COMPOSE_FILE" up -d
}

verify_install() {
  echo "Listening sockets:"
  ss -ltnp | awk '$4 ~ /:(443|587|8199|18199|18443)$/ || $4 ~ /127.0.0.1:'"${LOCAL_TLS_PORT}"'$/ || $4 ~ /127.0.0.1:'"${LOCAL_STATS_PORT}"'$/ {print}' || true

  echo
  echo "Container:"
  docker ps --filter "name=${CONTAINER_NAME}" --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

  echo
  echo "Local stats check:"
  curl -fsS --max-time 5 "http://127.0.0.1:${LOCAL_STATS_PORT}/" >/dev/null &&
    echo "OK: HAProxy stats is reachable on 127.0.0.1:${LOCAL_STATS_PORT}" ||
    echo "WARN: stats page is not reachable yet. Check: docker logs ${CONTAINER_NAME}"

  if [[ "$SELECTED_MODE" == "sni" ]]; then
    echo
    echo "SNI check:"
    timeout 8 openssl s_client -connect "127.0.0.1:443" -servername "$PROXY_DOMAIN" </dev/null 2>/dev/null |
      openssl x509 -noout -subject -issuer 2>/dev/null || echo "WARN: openssl SNI check did not return a certificate."
  fi
}

print_summary() {
  cat <<EOF

Installed WhatsApp Chat Proxy.

Domain:       $PROXY_DOMAIN
Mode:         $SELECTED_MODE
Image:        $WHATSAPP_IMAGE
Public 443:   $([[ "$SELECTED_MODE" == "direct" ]] && echo "container direct" || echo "nginx SNI -> 127.0.0.1:${LOCAL_TLS_PORT}")
Public 587:   $PUBLIC_587
Stats:        http://127.0.0.1:${LOCAL_STATS_PORT}/
Compose:      $COMPOSE_FILE
Backup:       $BACKUP_DIR

Client value to enter in WhatsApp proxy settings:
  $PROXY_DOMAIN

Notes:
  - This installer exposes only the minimal public ports: 443/tcp and optionally 587/tcp.
  - Stats port 8199 is kept local only via 127.0.0.1:${LOCAL_STATS_PORT}.
  - Existing Telemt secrets and configs are not touched.
EOF
}

main() {
  load_resume_config

  cat <<'EOF'
Experimental WhatsApp Chat Proxy installer.

Before running:
  1. Use your own domain only.
  2. Create DNS A record: <domain> -> this server IPv4.
  3. If Telemt already owns 443/tcp through nginx stream, choose SNI mode only after checking the plan.
  4. Keep the current SSH session open.
EOF

  [[ "$(id -u)" == "0" ]] || die "Run as root."

  prompt PROXY_DOMAIN "WhatsApp proxy domain"
  prompt INSTALL_MODE "Install mode: auto/direct/sni" "$INSTALL_MODE"
  prompt WHATSAPP_IMAGE "Docker image" "$WHATSAPP_IMAGE"
  prompt PUBLIC_587 "Expose public 587/tcp for whatsapp.net/media yes/no" "$PUBLIC_587"
  prompt LOCAL_TLS_PORT "Local WhatsApp TLS port for SNI mode" "$LOCAL_TLS_PORT"
  prompt LOCAL_STATS_PORT "Local HAProxy stats port" "$LOCAL_STATS_PORT"
  prompt ENABLE_DOCKER_LOGS "Enable Docker logs yes/no" "$ENABLE_DOCKER_LOGS"

  validate_input

  step "DNS preflight"
  dns_preflight
  save_resume_config
  run_step "packages" "Install packages" install_packages
  step "Port and mode preflight"
  select_mode
  save_resume_config

  cat <<EOF

Install plan:
  domain:          $PROXY_DOMAIN
  public IPv4:     $SERVER_PUBLIC_IPV4
  mode:            $SELECTED_MODE
  Docker image:    $WHATSAPP_IMAGE
  public 443/tcp:  $([[ "$SELECTED_MODE" == "direct" ]] && echo "direct container bind" || echo "existing nginx SNI route")
  public 587/tcp:  $PUBLIC_587
  local TLS port:  127.0.0.1:$LOCAL_TLS_PORT
  local stats:     127.0.0.1:$LOCAL_STATS_PORT
  Docker logs:     $ENABLE_DOCKER_LOGS
EOF

  if [[ "$SELECTED_MODE" == "sni" ]]; then
    cat <<EOF
  nginx file:      $NGINX_STREAM_CONF

SNI mode will:
  - keep existing nginx 443 listener;
  - backup $NGINX_STREAM_CONF;
  - add one map route: $PROXY_DOMAIN -> 127.0.0.1:$LOCAL_TLS_PORT;
  - run nginx -t before reload and restore backup on failure.
EOF
  fi

  confirm "Type y/yes/да to continue: " || die "Cancelled."

  run_step "backup" "Backup current state" backup_current_state
  save_resume_config
  run_step "compose" "Write Docker Compose" write_compose
  run_step "nginx_sni" "Patch nginx SNI route if needed" patch_nginx_stream
  run_step "firewall" "Configure firewall if active" configure_firewall
  run_step "start" "Start WhatsApp proxy" start_proxy
  run_step "verify" "Verify" verify_install
  print_summary
}

main "$@"
