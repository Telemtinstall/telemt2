#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2026-08-25-preview1"
PROJECT_NAME="mtproto+webproxy"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TELEMT_INSTALLER="$SCRIPT_DIR/vendor/telemt-docker/install_docker-telemt.sh"

STATE_FILE="${STATE_FILE:-/root/.mtproto_webproxy.state}"
SAVED_CONFIG="${SAVED_CONFIG:-/root/.mtproto_webproxy.config}"
INSTALL_DIR="${INSTALL_DIR:-/opt/mtproto-webproxy}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/mtproto-webproxy-backups}"

TPROXY_COMMIT="52a5feb7fac38f68da5afef9cedd9b3bfc8473ca"
TPROXY_ARCHIVE_SHA256="2c56987035c7f0b9a3d40907fe9ff8889fd41d1a6dcb7bdd6e0de7784c442bfe"
MTPROXY_COMMIT="f36d8af769ffaeac36978d38c2c0f6d1104c2137"
MTPROXY_ARCHIVE_SHA256="919795c416b870670841a21d1930ad97a24c7b84b9eb8c6f9e3de32f2fdf4655"

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
ENABLE_SAFE_ACCESS_LOG="${ENABLE_SAFE_ACCESS_LOG:-no}"
WEBPROXY_SECRET="${WEBPROXY_SECRET:-}"
WEBPROXY_CARRIER="${WEBPROXY_CARRIER:-https}"
MTPROXY_WORKERS="${MTPROXY_WORKERS:-1}"
MTPROXY_MAX_CONNECTIONS="${MTPROXY_MAX_CONNECTIONS:-4096}"
MTPROXY_NAT_INFO="${MTPROXY_NAT_INFO:-auto}"
MTPROXY_NAT_RESOLVED=""
AUTO_MODE=0
UPDATE_MODE=0
REPAIR_MODE=0
DRY_RUN=0
TRANSACTION_BACKUP=""
TRANSACTION_ACTIVE=0

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
$PROJECT_NAME $SCRIPT_VERSION

Использование:
  sudo ./install.sh [--auto] [--domain proxy.example.com]
  sudo ./install.sh --update
  sudo ./install.sh --repair

Параметры:
  --domain DOMAIN               Домен Telemt и WEB proxy.
  --email EMAIL                 По умолчанию admin@DOMAIN.
  --safe-access-log yes|no      Безопасный nginx-журнал без URL. Default: no.
  --carrier MODE                https, https-lanes, websocket, websocket-lanes.
  --mtproxy-workers N           Default: 1.
  --mtproxy-max-connections N   Default: 4096.
  --nat-info auto|off|IP:IP     Автонастройка NAT официального MTProxy.
  --secret HEX                  WEB proxy secret: 32 hex или dd + 32 hex.
  --auto                        Задать только домен, остальное автоматически.
  --update                      Обновить Telemt и WEB relay с проверкой.
  --repair                      Повторно применить WEB proxy без обновления Telemt.
  --dry-run                     Показать план без изменений.
  -h, --help                    Эта справка.

Переменные окружения с теми же именами также поддерживаются.
EOF
}

need_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "Для $1 требуется значение."
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --domain) need_value "$@"; DOMAIN="$2"; shift 2 ;;
      --email) need_value "$@"; EMAIL="$2"; shift 2 ;;
      --safe-access-log) need_value "$@"; ENABLE_SAFE_ACCESS_LOG="$2"; shift 2 ;;
      --carrier) need_value "$@"; WEBPROXY_CARRIER="$2"; shift 2 ;;
      --mtproxy-workers) need_value "$@"; MTPROXY_WORKERS="$2"; shift 2 ;;
      --mtproxy-max-connections) need_value "$@"; MTPROXY_MAX_CONNECTIONS="$2"; shift 2 ;;
      --nat-info) need_value "$@"; MTPROXY_NAT_INFO="$2"; shift 2 ;;
      --secret) need_value "$@"; WEBPROXY_SECRET="$2"; shift 2 ;;
      --auto|-y|--yes) AUTO_MODE=1; shift ;;
      --update) UPDATE_MODE=1; shift ;;
      --repair) REPAIR_MODE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
  [ "$UPDATE_MODE" -eq 0 ] || [ "$REPAIR_MODE" -eq 0 ] || die "--update и --repair несовместимы."
}

normalize_yes_no() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    y|yes|1|true|да|д) printf 'yes' ;;
    n|no|0|false|нет|н|'') printf 'no' ;;
    *) return 1 ;;
  esac
}

ask_yes_no() {
  local variable="$1" question="$2" default="$3" answer normalized
  if [ "$AUTO_MODE" -eq 1 ]; then
    printf -v "$variable" '%s' "$default"
    return
  fi
  read -r -p "$question [$default]: " answer
  answer="${answer:-$default}"
  normalized="$(normalize_yes_no "$answer")" || die "Ответьте yes или no."
  printf -v "$variable" '%s' "$normalized"
}

load_saved_config() {
  [ -f "$SAVED_CONFIG" ] || return 0
  # The file is root-owned, mode 600, and contains only shell-escaped assignments.
  # shellcheck disable=SC1090
  source "$SAVED_CONFIG"
}

step_done() {
  [ -f "$STATE_FILE" ] && grep -Fxq "$1" "$STATE_FILE"
}

mark_done() {
  install -d -m 0700 "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  chmod 0600 "$STATE_FILE"
  grep -Fxq "$1" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$1" >> "$STATE_FILE"
}

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Запустите установщик от root: sudo ./install.sh"
}

require_clean_os() {
  [ -r /etc/os-release ] || die "Не найден /etc/os-release."
  # shellcheck disable=SC1091
  source /etc/os-release
  [ "${ID:-}" = "debian" ] && [[ "${VERSION_ID:-}" == 13* ]] || \
    die "Первая версия поддерживает только Debian 13 x86_64."
  [ "$(uname -m)" = "x86_64" ] || die "Официальный MTProxy требует x86_64."
  have systemctl || die "Требуется systemd."
  [ -x "$TELEMT_INSTALLER" ] || die "Не найден vendor Telemt installer: $TELEMT_INSTALLER"
}

collect_inputs() {
  if [ -z "$DOMAIN" ]; then
    if [ ! -t 0 ]; then
      die "Укажите DOMAIN=proxy.example.com или --domain proxy.example.com."
    fi
    read -r -p "Домен Telemt + WEB proxy: " DOMAIN
  fi
  [ -n "$DOMAIN" ] || die "Домен не указан."
  case "$DOMAIN" in
    *[[:space:]]*|*/*|*\\*) die "Домен содержит недопустимые символы." ;;
  esac
  EMAIL="${EMAIL:-admin@${DOMAIN%.}}"

  ENABLE_SAFE_ACCESS_LOG="$(normalize_yes_no "$ENABLE_SAFE_ACCESS_LOG")" || \
    die "--safe-access-log должен быть yes или no."
  if [ "$AUTO_MODE" -eq 0 ] && [ "$UPDATE_MODE" -eq 0 ] && [ "$REPAIR_MODE" -eq 0 ]; then
    ask_yes_no ENABLE_SAFE_ACCESS_LOG \
      "Включить безопасный nginx access-log без URL и секретов?" \
      "$ENABLE_SAFE_ACCESS_LOG"
  fi

  case "$WEBPROXY_CARRIER" in
    https|https-lanes|websocket|websocket-lanes) ;;
    *) die "Неверный carrier: $WEBPROXY_CARRIER" ;;
  esac
  [[ "$MTPROXY_WORKERS" =~ ^[1-9][0-9]*$ ]] && [ "$MTPROXY_WORKERS" -le 256 ] || \
    die "MTPROXY_WORKERS должен быть от 1 до 256."
  [[ "$MTPROXY_MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || \
    die "MTPROXY_MAX_CONNECTIONS должен быть положительным числом."
  case "$MTPROXY_NAT_INFO" in
    auto|off|'') ;;
    *) [[ "$MTPROXY_NAT_INFO" =~ ^[0-9.]+:[0-9.]+$ ]] || \
         die "--nat-info: auto, off или local_ipv4:external_ipv4." ;;
  esac
  if [ -n "$WEBPROXY_SECRET" ]; then
    WEBPROXY_SECRET="$(printf '%s' "$WEBPROXY_SECRET" | tr 'A-F' 'a-f')"
    [[ "$WEBPROXY_SECRET" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] || \
      die "WEB secret должен быть 32 hex, необязательно с префиксом dd."
  fi
}

print_plan() {
  cat <<EOF

План установки $PROJECT_NAME:
  domain:                  $DOMAIN
  Let's Encrypt email:    $EMAIL
  Telemt:                  Docker, exact 3.4.24
  WEB carrier:             $WEBPROXY_CARRIER
  safe nginx access-log:   $ENABLE_SAFE_ACCESS_LOG
  official MTProxy:        workers=$MTPROXY_WORKERS connections=$MTPROXY_MAX_CONNECTIONS
  MTProxy NAT:             $MTPROXY_NAT_INFO
  VPN/SSH:                 не изменяются
  public ports:            80/tcp, 443/tcp
EOF
}

save_config() {
  umask 077
  install -d -m 0700 "$(dirname "$SAVED_CONFIG")"
  {
    printf 'DOMAIN=%q\n' "$DOMAIN"
    printf 'EMAIL=%q\n' "$EMAIL"
    printf 'ENABLE_SAFE_ACCESS_LOG=%q\n' "$ENABLE_SAFE_ACCESS_LOG"
    printf 'WEBPROXY_SECRET=%q\n' "$WEBPROXY_SECRET"
    printf 'WEBPROXY_CARRIER=%q\n' "$WEBPROXY_CARRIER"
    printf 'MTPROXY_WORKERS=%q\n' "$MTPROXY_WORKERS"
    printf 'MTPROXY_MAX_CONNECTIONS=%q\n' "$MTPROXY_MAX_CONNECTIONS"
    printf 'MTPROXY_NAT_INFO=%q\n' "$MTPROXY_NAT_INFO"
  } > "$SAVED_CONFIG"
  chmod 0600 "$SAVED_CONFIG"
}

run_telemt_install() {
  if step_done telemt; then
    say "[1/8] Telemt уже установлен этим мастером — пропуск."
    return
  fi
  say "[1/8] Установка Telemt 3.4.24 из изолированного vendor-снимка"
  DOMAIN="$DOMAIN" \
  EMAIL="$EMAIL" \
  ENABLE_LOGS=no \
  MASK_SITE_MODE=fancy \
  TELEMT_USER=default \
  TELEMT_USERS=default \
  TELEMT_LINK_COUNT=1 \
  "$TELEMT_INSTALLER" --auto -lang ru

  [ -f /root/.install_docker_telemt.config ] || die "Telemt не сохранил конфигурацию."
  # Load the normalized IDNA domain and email produced by the base installer.
  local wanted_secret="$WEBPROXY_SECRET"
  # shellcheck disable=SC1091
  source /root/.install_docker_telemt.config
  WEBPROXY_SECRET="$wanted_secret"
  mark_done telemt
  save_config
}

run_telemt_update() {
  say "[1/8] Безопасное обновление Telemt"
  "$TELEMT_INSTALLER" --update -lang ru
  [ -f /root/.install_docker_telemt.config ] || die "Не найден сохранённый конфиг Telemt."
  local wanted_secret="$WEBPROXY_SECRET"
  # shellcheck disable=SC1091
  source /root/.install_docker_telemt.config
  WEBPROXY_SECRET="$wanted_secret"
}

install_packages() {
  say "[2/8] Пакеты сборки WEB proxy"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl nftables build-essential libssl-dev util-linux \
    zlib1g-dev golang-go tar gzip jq iproute2
  have go || die "Go не установлен."
  local go_minor
  go_minor="$(go env GOVERSION | sed -E 's/^go1\.([0-9]+).*/\1/')"
  [[ "$go_minor" =~ ^[0-9]+$ ]] && [ "$go_minor" -ge 20 ] || \
    die "Требуется Go 1.20 или новее."
}

download_checked() {
  local url="$1" output="$2" expected="$3" actual
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$output" "$url"
  actual="$(sha256sum "$output" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || die "Неверная SHA256 для $url"
}

install_tproxy_binary() (
  say "[3/8] Сборка tproxy-server @$TPROXY_COMMIT"
  local temporary archive source_dir
  temporary="$(mktemp -d /tmp/tproxy-build.XXXXXX)"
  archive="$temporary/tproxy-server.tar.gz"
  trap 'rm -rf "$temporary"' EXIT
  download_checked \
    "https://github.com/telegramdesktop/tproxy-server/archive/${TPROXY_COMMIT}.tar.gz" \
    "$archive" "$TPROXY_ARCHIVE_SHA256"
  tar -C "$temporary" -xzf "$archive"
  source_dir="$temporary/tproxy-server-$TPROXY_COMMIT"
  [ -f "$source_dir/go.mod" ] || die "Архив tproxy-server повреждён."
  (
    umask 022
    cd "$source_dir"
    go test ./...
    go build -trimpath -ldflags='-s -w' -o "$temporary/tproxy-server" ./cmd/tproxy-server
  )
  install -o root -g root -m 0755 "$temporary/tproxy-server" /usr/local/bin/tproxy-server
)

install_official_mtproxy() {
  say "[4/8] Сборка официального Telegram MTProxy @$MTPROXY_COMMIT"
  export DEBIAN_FRONTEND=noninteractive
  if ! id mtproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin mtproxy
  fi

  local source_directory=/opt/MTProxy temporary archive build_directory old_directory
  if [ -x "$source_directory/objs/bin/mtproto-proxy" ] && \
     [ -f "$source_directory/.tproxy-commit" ] && \
     grep -Fxq "$MTPROXY_COMMIT" "$source_directory/.tproxy-commit"; then
    chmod 0755 "$source_directory" "$source_directory/objs" \
      "$source_directory/objs/bin" "$source_directory/objs/bin/mtproto-proxy"
  else
    temporary="$(mktemp -d /tmp/mtproxy-build.XXXXXX)"
    chmod 0755 "$temporary"
    archive="$temporary/MTProxy.tar.gz"
    build_directory="$temporary/MTProxy"
    download_checked \
      "https://github.com/TelegramMessenger/MTProxy/archive/${MTPROXY_COMMIT}.tar.gz" \
      "$archive" "$MTPROXY_ARCHIVE_SHA256"
    install -d -o mtproxy -g mtproxy -m 0755 "$build_directory"
    tar -C "$build_directory" --strip-components=1 -xzf "$archive"
    chown -R mtproxy:mtproxy "$build_directory"
    chmod -R u+rwX,go+rX "$build_directory"
    runuser -u mtproxy -- make -C "$build_directory" -j"$(nproc)"
    [ -x "$build_directory/objs/bin/mtproto-proxy" ] || die "MTProxy не собрался."
    printf '%s\n' "$MTPROXY_COMMIT" > "$build_directory/.tproxy-commit"
    chown -R root:root "$build_directory"
    chmod 0755 "$build_directory" "$build_directory/objs" \
      "$build_directory/objs/bin" "$build_directory/objs/bin/mtproto-proxy"
    if [ -e "$source_directory" ]; then
      old_directory="${source_directory}.before-mtproto-webproxy.$(date +%Y%m%d%H%M%S)"
      mv "$source_directory" "$old_directory"
    fi
    mv "$build_directory" "$source_directory"
    rm -rf "$temporary"
  fi

  install -d -o root -g mtproxy -m 0750 /etc/mtproxy
  local secret_temp config_temp
  secret_temp="$(mktemp /etc/mtproxy/proxy-secret.XXXXXX)"
  config_temp="$(mktemp /etc/mtproxy/proxy-multi.conf.XXXXXX)"
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --output "$secret_temp" https://core.telegram.org/getProxySecret
  curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    --tlsv1.2 --output "$config_temp" https://core.telegram.org/getProxyConfig
  [ "$(wc -c < "$secret_temp")" -eq 128 ] || die "Неверный proxy-secret Telegram."
  [ "$(wc -c < "$config_temp")" -ge 100 ] || die "Неверный proxy config Telegram."
  grep -q '^default ' "$config_temp" || die "В proxy config нет default."
  grep -q '^proxy_for ' "$config_temp" || die "В proxy config нет proxy_for."
  chown root:mtproxy "$secret_temp" "$config_temp"
  chmod 0640 "$secret_temp" "$config_temp"
  mv -f "$secret_temp" /etc/mtproxy/proxy-secret
  mv -f "$config_temp" /etc/mtproxy/proxy-multi.conf
}

detect_nat_info() {
  local route_ip="" external_ip=""
  if [ "$MTPROXY_NAT_INFO" = "off" ] || [ -z "$MTPROXY_NAT_INFO" ]; then
    MTPROXY_NAT_RESOLVED=""
    return
  fi
  if [ "$MTPROXY_NAT_INFO" != "auto" ]; then
    MTPROXY_NAT_RESOLVED="$MTPROXY_NAT_INFO"
    return
  fi
  route_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | \
    awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
  external_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [[ "$route_ip" =~ ^[0-9.]+$ ]] && [[ "$external_ip" =~ ^[0-9.]+$ ]] && \
     [ "$route_ip" != "$external_ip" ]; then
    MTPROXY_NAT_RESOLVED="$route_ip:$external_ip"
    say "  Обнаружено отображение NAT/VPN для MTProxy: $MTPROXY_NAT_RESOLVED"
  else
    MTPROXY_NAT_RESOLVED=""
    say "  --nat-info не требуется или не удалось определить; маршруты не изменяются."
  fi
}

ensure_web_secret() {
  if [ -z "$WEBPROXY_SECRET" ]; then
    WEBPROXY_SECRET="$(openssl rand -hex 16)"
  fi
  WEBPROXY_SECRET="$(printf '%s' "$WEBPROXY_SECRET" | tr 'A-F' 'a-f')"
  [[ "$WEBPROXY_SECRET" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] || \
    die "Некорректный WEB proxy secret."
}

backend_secret() {
  local value="$WEBPROXY_SECRET"
  if [[ "$value" == dd* ]] && [ "${#value}" -eq 34 ]; then
    value="${value:2}"
  fi
  printf '%s' "$value"
}

begin_transaction() {
  TRANSACTION_BACKUP="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$TRANSACTION_BACKUP"
  TRANSACTION_ACTIVE=1
  local path key
  for path in \
    "/etc/nginx/sites-available/telemt-mask-${DOMAIN}.conf" \
    /etc/nginx/conf.d/50-mtproto-webproxy.conf \
    /etc/tproxy-server/config.json \
    /etc/tproxy-server/profiles.json \
    /etc/tproxy-server/firewall.nft \
    /etc/mtproxy/mtproxy.env \
    /usr/local/bin/tproxy-server \
    /usr/local/sbin/run-mtproxy-webproxy \
    /usr/local/sbin/refresh-mtproxy-config \
    /etc/systemd/system/mtproxy.service \
    /etc/systemd/system/tproxy-server.service \
    /etc/systemd/system/tproxy-firewall.service \
    /etc/systemd/system/refresh-mtproxy-config.service \
    /etc/systemd/system/refresh-mtproxy-config.timer \
    /root/webproxy-links.txt \
    "$SAVED_CONFIG"; do
    key="$(printf '%s' "$path" | sed 's#^/##; s#/#__#g')"
    if [ -e "$path" ]; then
      cp -a "$path" "$TRANSACTION_BACKUP/$key"
      printf 'present %s %s\n' "$path" "$key" >> "$TRANSACTION_BACKUP/manifest"
    else
      printf 'absent %s %s\n' "$path" "$key" >> "$TRANSACTION_BACKUP/manifest"
    fi
  done
}

rollback_transaction() {
  [ -n "$TRANSACTION_BACKUP" ] && [ -f "$TRANSACTION_BACKUP/manifest" ] || return 0
  warn "Восстанавливаю nginx/WEB proxy из $TRANSACTION_BACKUP"
  local state path key
  if grep -Fq 'absent /etc/systemd/system/tproxy-server.service ' \
      "$TRANSACTION_BACKUP/manifest"; then
    systemctl stop tproxy-server mtproxy tproxy-firewall 2>/dev/null || true
    nft delete table inet tproxy_backend 2>/dev/null || true
  fi
  while read -r state path key; do
    if [ "$state" = "present" ]; then
      cp -a "$TRANSACTION_BACKUP/$key" "$path"
    else
      rm -f "$path"
    fi
  done < "$TRANSACTION_BACKUP/manifest"
  systemctl daemon-reload 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || true
  systemctl try-restart mtproxy tproxy-server 2>/dev/null || true
}

on_exit() {
  local status="$1"
  if [ "$status" -ne 0 ] && [ "$TRANSACTION_ACTIVE" -eq 1 ]; then
    warn "Установка прервана с кодом $status."
    rollback_transaction
  fi
}

write_webproxy_config() {
  say "[5/8] Конфигурация WEB relay, systemd и firewall"
  if ! id tproxy >/dev/null 2>&1; then
    useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
  fi
  ensure_web_secret
  detect_nat_info

  install -d -o root -g tproxy -m 0750 /etc/tproxy-server
  jq -n \
    --arg hostname "$DOMAIN" \
    '{
      public_hostname: $hostname,
      listen: "127.0.0.1:8080",
      admin_listen: "127.0.0.1:8081",
      public_upstream: "http://127.0.0.1:8082",
      profiles_file: "/run/credentials/tproxy-server.service/profiles.json",
      enable_pprof: false,
      limits: {
        max_header_bytes: 16384,
        max_body_bytes: 2097152,
        max_frame_payload: 1048576,
        carrier_batch_bytes: 2097152,
        max_streams_per_session: 128,
        max_closed_stream_ids: 4096,
        max_pending_per_session: 33554432,
        max_pending_global: 536870912,
        max_pending_items_per_session: 16384,
        max_pending_items_global: 262144,
        max_sessions_per_ip: 0,
        max_sessions_global: 128,
        max_streams_global: 4096,
        max_backend_dials_in_flight: 256,
        new_sessions_per_minute: 600,
        new_sessions_burst: 128,
        new_streams_per_minute: 6000,
        new_streams_burst: 512,
        max_bootstraps_per_ip: 0,
        max_bootstraps_global: 512,
        new_bootstraps_per_minute: 1200,
        new_bootstraps_burst: 256,
        max_profiles: 32
      },
      timeouts: {
        backend_dial: "5s",
        long_poll: "25s",
        reconnect_grace: "2m",
        bootstrap_lifetime: "2m",
        read_header: "10s",
        idle: "75s",
        shutdown: "15s"
      }
    }' > /etc/tproxy-server/config.json
  jq -n \
    --arg secret "$WEBPROXY_SECRET" \
    --arg carrier "$WEBPROXY_CARRIER" \
    '{profiles:[{name:"default",secret:$secret,backend:"127.0.0.1:2398",carrier_mode:$carrier}]}' \
    > /etc/tproxy-server/profiles.json
  chown root:tproxy /etc/tproxy-server/config.json /etc/tproxy-server/profiles.json
  chmod 0640 /etc/tproxy-server/config.json
  chmod 0400 /etc/tproxy-server/profiles.json

  install -d -o root -g mtproxy -m 0750 /etc/mtproxy
  {
    printf 'MTPROXY_SECRET=%q\n' "$(backend_secret)"
    printf 'MTPROXY_WORKERS=%q\n' "$MTPROXY_WORKERS"
    printf 'MTPROXY_MAX_CONNECTIONS=%q\n' "$MTPROXY_MAX_CONNECTIONS"
    printf 'MTPROXY_NAT_INFO=%q\n' "$MTPROXY_NAT_RESOLVED"
  } > /etc/mtproxy/mtproxy.env
  chown root:mtproxy /etc/mtproxy/mtproxy.env
  chmod 0640 /etc/mtproxy/mtproxy.env

  write_mtproxy_runner
  write_systemd_units
  write_firewall
  write_refresh_script
  write_links
  save_config
}

write_mtproxy_runner() {
  cat > /usr/local/sbin/run-mtproxy-webproxy <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=(
  /opt/MTProxy/objs/bin/mtproto-proxy
  -u mtproxy
  -p 8888
  -H 2398
  -S "$MTPROXY_SECRET"
  --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf
  -M "${MTPROXY_WORKERS:-1}"
  -C "${MTPROXY_MAX_CONNECTIONS:-4096}"
)
if [ -n "${MTPROXY_NAT_INFO:-}" ]; then
  args+=(--nat-info "$MTPROXY_NAT_INFO")
fi
exec "${args[@]}"
EOF
  chmod 0755 /usr/local/sbin/run-mtproxy-webproxy
}

write_systemd_units() {
  cat > /etc/systemd/system/mtproxy.service <<'EOF'
[Unit]
Description=Official Telegram MTProxy backend for WEB proxy
After=network-online.target tproxy-firewall.service
Wants=network-online.target
Requires=tproxy-firewall.service

[Service]
Type=simple
User=mtproxy
Group=mtproxy
EnvironmentFile=/etc/mtproxy/mtproxy.env
WorkingDirectory=/opt/MTProxy
ExecStart=/usr/local/sbin/run-mtproxy-webproxy
Restart=on-failure
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectHome=true
ProtectProc=invisible
ProtectSystem=strict
ProcSubset=pid
ReadOnlyPaths=/etc/mtproxy
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
LockPersonality=true

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/tproxy-server.service <<'EOF'
[Unit]
Description=Telegram WEB proxy HTTPS transport relay
After=network-online.target mtproxy.service tproxy-firewall.service
Wants=network-online.target mtproxy.service
Requires=tproxy-firewall.service

[Service]
Type=simple
User=tproxy
Group=tproxy
LoadCredential=profiles.json:/etc/tproxy-server/profiles.json
ExecStart=/usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json
Restart=on-failure
RestartSec=3s
TimeoutStopSec=20s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateDevices=true
PrivateTmp=true
ProtectClock=true
ProtectControlGroups=true
ProtectHome=true
ProtectHostname=true
ProtectKernelLogs=true
ProtectKernelModules=true
ProtectKernelTunables=true
ProtectProc=invisible
ProtectSystem=strict
ProcSubset=pid
RestrictAddressFamilies=AF_INET AF_INET6
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=
IPAddressDeny=any
IPAddressAllow=localhost
SystemCallArchitectures=native
SystemCallFilter=@system-service
UMask=0077

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/tproxy-firewall.service <<'EOF'
[Unit]
Description=Protect local Telemt and WEB proxy backend ports
After=nftables.service
PartOf=nftables.service
Before=mtproxy.service tproxy-server.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=-/usr/sbin/nft delete table inet tproxy_backend
ExecStart=/usr/sbin/nft -f /etc/tproxy-server/firewall.nft
ExecReload=-/usr/sbin/nft delete table inet tproxy_backend
ExecReload=/usr/sbin/nft -f /etc/tproxy-server/firewall.nft
ExecStop=-/usr/sbin/nft delete table inet tproxy_backend

[Install]
WantedBy=multi-user.target
EOF

  cat > /etc/systemd/system/refresh-mtproxy-config.service <<'EOF'
[Unit]
Description=Refresh Telegram MTProxy routing configuration
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/refresh-mtproxy-config
EOF

  cat > /etc/systemd/system/refresh-mtproxy-config.timer <<'EOF'
[Unit]
Description=Refresh Telegram MTProxy routing configuration daily

[Timer]
OnBootSec=15m
OnUnitActiveSec=1d
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
}

write_firewall() {
  cat > /etc/tproxy-server/firewall.nft <<'EOF'
table inet tproxy_backend {
  chain local_backend {
    type filter hook input priority -10; policy accept;
    iifname != "lo" tcp dport { 1443, 8443, 8080, 8081, 8082, 2398, 8888, 9090, 9091 } drop
  }
}
EOF
  chmod 0644 /etc/tproxy-server/firewall.nft
}

write_refresh_script() {
  cat > /usr/local/sbin/refresh-mtproxy-config <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
destination=/etc/mtproxy/proxy-multi.conf
temporary="$(mktemp /etc/mtproxy/proxy-multi.conf.XXXXXX)"
trap 'rm -f "$temporary"' EXIT
curl --fail --silent --show-error --location \
  --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --output "$temporary" https://core.telegram.org/getProxyConfig
[ "$(wc -c < "$temporary")" -ge 100 ]
grep -q '^default ' "$temporary"
grep -q '^proxy_for ' "$temporary"
chown root:mtproxy "$temporary"
chmod 0640 "$temporary"
if [ -e "$destination" ] && cmp -s "$temporary" "$destination"; then
  exit 0
fi
mv -f "$temporary" "$destination"
trap - EXIT
systemctl try-restart mtproxy.service
EOF
  chmod 0755 /usr/local/sbin/refresh-mtproxy-config
}

write_links() {
  umask 077
  cat > /root/webproxy-links.txt <<EOF
https://t.me/webproxy?server=${DOMAIN}&secret=${WEBPROXY_SECRET}
tg://webproxy?server=${DOMAIN}&secret=${WEBPROXY_SECRET}
EOF
  chmod 0600 /root/webproxy-links.txt
}

write_nginx_integration() {
  say "[6/8] Интеграция nginx через маскировочный выход Telemt"
  local access_log_line="access_log off;"
  if [ "$ENABLE_SAFE_ACCESS_LOG" = "yes" ]; then
    access_log_line="access_log /var/log/nginx/${DOMAIN}.safe-access.log mtproto_safe;"
  fi

  cat > /etc/nginx/conf.d/50-mtproto-webproxy.conf <<'EOF'
# Managed by mtproto+webproxy. Contains no request URI in the log format.
log_format mtproto_safe '$remote_addr [$time_local] $request_method $status $body_bytes_sent $request_time';
map $http_upgrade $mtproto_connection_upgrade {
    default upgrade;
    ''      '';
}
EOF

  cat > "/etc/nginx/sites-available/telemt-mask-${DOMAIN}.conf" <<EOF
# Managed by mtproto+webproxy. Do not edit manually.
server {
    listen 80;
    server_name ${DOMAIN};
    ${access_log_line}
    error_log /var/log/nginx/${DOMAIN}.error.log crit;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/${DOMAIN};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# Telemt sends genuine HTTPS here after distinguishing it from MTProxy FakeTLS.
server {
    listen 127.0.0.1:8443 ssl http2;
    server_name ${DOMAIN};
    ${access_log_line}
    error_log /var/log/nginx/${DOMAIN}.error.log crit;
    client_max_body_size 2m;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$mtproto_connection_upgrade;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
    }
}

# Ordinary site shown by tproxy-server to every unauthenticated request.
server {
    listen 127.0.0.1:8082;
    server_name ${DOMAIN};
    access_log off;
    error_log /var/log/nginx/${DOMAIN}.site-error.log crit;
    root /var/www/${DOMAIN};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html =404;
    }
}
EOF
  ln -sfn "/etc/nginx/sites-available/telemt-mask-${DOMAIN}.conf" \
    "/etc/nginx/sites-enabled/telemt-mask-${DOMAIN}.conf"
  nginx -t
}

validate_configuration_before_start() {
  /usr/local/bin/tproxy-server \
    -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json \
    -check
  nginx -t
}

start_services() {
  say "[7/8] Запуск WEB proxy"
  systemctl daemon-reload
  systemctl enable --now nftables.service
  systemctl enable --now tproxy-firewall.service
  systemctl enable --now mtproxy.service
  systemctl restart mtproxy.service
  systemctl enable --now tproxy-server.service
  systemctl restart tproxy-server.service
  systemctl enable --now refresh-mtproxy-config.timer
  systemctl reload nginx || systemctl restart nginx
}

validate_install() {
  say "[8/8] Проверка установки"
  local ready=0 attempt
  for attempt in $(seq 1 30); do
    if curl -fsS --max-time 3 http://127.0.0.1:8081/readyz >/dev/null; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || {
    systemctl --no-pager --full status mtproxy tproxy-server >&2 || true
    journalctl -u mtproxy -u tproxy-server -n 100 --no-pager >&2 || true
    die "tproxy-server не перешёл в ready."
  }
  curl -fsS --max-time 10 \
    --resolve "$DOMAIN:443:127.0.0.1" \
    "https://$DOMAIN/" >/dev/null || die "HTTPS-сайт через Telemt/WEB relay не отвечает."
  systemctl is-active --quiet mtproxy
  systemctl is-active --quiet tproxy-server
  systemctl is-active --quiet nginx
}

main() {
  local argument
  for argument in "$@"; do
    case "$argument" in
      -h|--help) usage; exit 0 ;;
    esac
  done
  load_saved_config
  parse_args "$@"
  need_root
  require_clean_os
  collect_inputs
  print_plan
  if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry-run завершён; изменений нет."
    exit 0
  fi

  if [ "$UPDATE_MODE" -eq 1 ]; then
    run_telemt_update
  elif [ "$REPAIR_MODE" -eq 0 ]; then
    run_telemt_install
  else
    [ -f /root/.install_docker_telemt.config ] || die "Для --repair сначала нужен установленный Telemt."
  fi

  # Telemt normalizes IDN and persists its final hostname/email.
  if [ -f /root/.install_docker_telemt.config ]; then
    local wanted_secret="$WEBPROXY_SECRET"
    # shellcheck disable=SC1091
    source /root/.install_docker_telemt.config
    WEBPROXY_SECRET="$wanted_secret"
  fi

  install_packages
  begin_transaction
  trap 'on_exit "$?"' EXIT
  install_tproxy_binary
  install_official_mtproxy
  write_webproxy_config
  write_nginx_integration
  validate_configuration_before_start
  start_services
  validate_install
  TRANSACTION_ACTIVE=0
  trap - EXIT
  mark_done complete
  save_config

  cat <<EOF

Готово: Telemt + WEB proxy работают на одном домене $DOMAIN.

Обычные MTProto-ссылки:
$(cat /root/telemt-proxy-links.txt 2>/dev/null || true)

WEB proxy-ссылки:
$(cat /root/webproxy-links.txt)

Проверка:
  systemctl --no-pager --full status nginx mtproxy tproxy-server
  curl -fsS http://127.0.0.1:8081/readyz

Конфигурация: $SAVED_CONFIG
Резервная копия: $TRANSACTION_BACKUP
EOF
}

if [ "${MTPROTO_WEBPROXY_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
