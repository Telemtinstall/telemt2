#!/usr/bin/env bash
set -Eeuo pipefail

# Full installer for a fresh Debian 13 / Ubuntu 24+ VPN server.
# This v2 package is independent from the legacy vpn-manager_awg installer.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="${REPO_URL:-https://github.com/Telemtinstall/telemt2.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/root/telemt2}"
INSTALL_DIR="${INSTALL_DIR:-/root/vpnbot}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/vpnbot-backups}"
AWGCTL_PATH="${AWGCTL_PATH:-/usr/local/sbin/awgctl}"
VLESSCTL_PATH="${VLESSCTL_PATH:-/usr/local/sbin/vlessctl}"
SERVER_STATUS_PATH="${SERVER_STATUS_PATH:-/usr/local/sbin/server-status}"
SPEEDTEST_PATH="${SPEEDTEST_PATH:-/usr/local/sbin/vpn-speedtest}"
INSTALL_STATE_FILE="${INSTALL_STATE_FILE:-/root/.install_vpnbot.state}"
INSTALL_RESUME_CONFIG="${INSTALL_RESUME_CONFIG:-/root/.install_vpnbot.config}"
INSTALL_LOG="${INSTALL_LOG:-/var/log/vpnbot-install.log}"

BOT_TOKEN="${BOT_TOKEN:-}"
ADMIN_BOT="${ADMIN_BOT:-}"
BOT_TITLE="${BOT_TITLE:-Личный VPN-бот}"
SERVER_CHANNEL_MBIT="${SERVER_CHANNEL_MBIT:-}"
VLESS_MODE="${VLESS_MODE:-direct}"
RUN_SPEEDTEST="${RUN_SPEEDTEST:-1}"
ASSUME_YES="${ASSUME_YES:-0}"
DRY_RUN="${DRY_RUN:-0}"
SKIP_AWG="${SKIP_AWG:-0}"
SKIP_VLESS="${SKIP_VLESS:-0}"
INSTALL_VPN_COMPONENTS="${INSTALL_VPN_COMPONENTS:-}"
INSTALL_EXTRA_SOFTWARE="${INSTALL_EXTRA_SOFTWARE:-}"
VPN_PUBLIC_HOST="${VPN_PUBLIC_HOST:-}"
VPN_INITIAL_CLIENT="${VPN_INITIAL_CLIENT:-}"

EXTRA_PACKAGES=(
  git ca-certificates python3 python3-pil fonts-dejavu-core logrotate speedtest-cli
)

step_no=0

step() {
  step_no=$((step_no + 1))
  printf '\n[%02d] %s\n' "$step_no" "$1"
}

die() {
  printf 'ОШИБКА: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'ПРЕДУПРЕЖДЕНИЕ: %s\n' "$*" >&2
}

current_installer_version() {
  tr -d '[:space:]' < "$SCRIPT_DIR/INSTALLER_VERSION"
}

save_resume_config() {
  local tmp
  umask 077
  tmp="$(mktemp)"
  {
    printf 'RESUME_INSTALLER_VERSION=%q\n' "$(current_installer_version)"
    printf 'INSTALL_EXTRA_SOFTWARE=%q\n' "$INSTALL_EXTRA_SOFTWARE"
    printf 'INSTALL_VPN_COMPONENTS=%q\n' "$INSTALL_VPN_COMPONENTS"
    printf 'VPN_PUBLIC_HOST=%q\n' "$VPN_PUBLIC_HOST"
    printf 'VPN_INITIAL_CLIENT=%q\n' "$VPN_INITIAL_CLIENT"
    printf 'SERVER_CHANNEL_MBIT=%q\n' "$SERVER_CHANNEL_MBIT"
  } > "$tmp"
  install -m 0600 "$tmp" "$INSTALL_RESUME_CONFIG"
  rm -f "$tmp"
}

load_resume_config() {
  local saved_version=""
  [[ -f "$INSTALL_RESUME_CONFIG" ]] || return 0
  # shellcheck disable=SC1090
  . "$INSTALL_RESUME_CONFIG"
  saved_version="${RESUME_INSTALLER_VERSION:-}"
  if [[ "$saved_version" != "$(current_installer_version)" ]]; then
    warn "версия установщика изменилась; старые контрольные точки сброшены"
    rm -f "$INSTALL_STATE_FILE" "$INSTALL_RESUME_CONFIG"
    INSTALL_EXTRA_SOFTWARE=""
    INSTALL_VPN_COMPONENTS=""
    VPN_PUBLIC_HOST=""
    VPN_INITIAL_CLIENT=""
    SERVER_CHANNEL_MBIT=""
  fi
}

step_done() {
  [[ -f "$INSTALL_STATE_FILE" ]] && grep -Fxq "$1" "$INSTALL_STATE_FILE"
}

mark_step_done() {
  local step_id="$1"
  touch "$INSTALL_STATE_FILE"
  chmod 600 "$INSTALL_STATE_FILE"
  grep -Fxq "$step_id" "$INSTALL_STATE_FILE" 2>/dev/null ||
    printf '%s\n' "$step_id" >> "$INSTALL_STATE_FILE"
}

run_resumable_step() {
  local step_id="$1"
  local title="$2"
  shift 2
  if step_done "$step_id"; then
    step "$title (уже выполнено, пропускаю)"
    return 0
  fi
  step "$title"
  "$@"
  mark_step_done "$step_id"
  save_resume_config
}

configure_installer_log() {
  install -d -m 0755 "$(dirname "$INSTALL_LOG")"
  touch "$INSTALL_LOG"
  chmod 600 "$INSTALL_LOG"
  cat > /etc/logrotate.d/vpnbot-installer <<EOF
$INSTALL_LOG {
    daily
    rotate 7
    maxage 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
}

installation_exit_report() {
  local rc="$?"
  trap - EXIT
  if (( rc != 0 )); then
    printf '\nУстановка прервана с кодом %s.\n' "$rc"
    printf 'Журнал: %s\n' "$INSTALL_LOG"
    printf 'Повторный запуск продолжит работу с последнего завершённого шага.\n'
  fi
  exit "$rc"
}

start_installation_tracking() {
  configure_installer_log
  exec > >(tee -a "$INSTALL_LOG") 2>&1
  trap installation_exit_report EXIT
  printf '\n===== VPN Bot installer %s: %s UTC =====\n' \
    "$(current_installer_version)" "$(date -u '+%Y-%m-%d %H:%M:%S')"
  load_resume_config
  if [[ -s "$INSTALL_STATE_FILE" ]]; then
    echo "Найдена незавершённая установка. Завершённые шаги:"
    sed 's/^/  - /' "$INSTALL_STATE_FILE"
  fi
}

finish_installation_tracking() {
  rm -f "$INSTALL_STATE_FILE" "$INSTALL_RESUME_CONFIG"
  echo "Контрольные точки очищены: установка полностью завершена."
}

have() {
  command -v "$1" >/dev/null 2>&1
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

confirm() {
  local label="$1"
  local default="${2:-yes}"
  local answer=""
  if [[ "$ASSUME_YES" == "1" ]]; then
    [[ "$default" == "yes" ]]
    return
  fi
  printf '%s [%s]: ' "$label" "$default"
  read -r answer
  answer="$(printf '%s' "${answer:-$default}" | tr '[:upper:]' '[:lower:]')"
  [[ "$answer" == "y" || "$answer" == "yes" || "$answer" == "д" || "$answer" == "да" ]]
}

prompt_value() {
  local var_name="$1"
  local label="$2"
  local default_value="${3:-}"
  local current="${!var_name:-}"
  local value=""
  if [[ -n "$current" ]]; then
    return 0
  fi
  if [[ "$ASSUME_YES" == "1" ]]; then
    [[ -n "$default_value" ]] || die "для автоматической установки задайте $var_name"
    printf -v "$var_name" '%s' "$default_value"
    return 0
  fi
  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value"
  else
    printf '%s: ' "$label"
  fi
  read -r value
  value="$(trim "$value")"
  printf -v "$var_name" '%s' "${value:-$default_value}"
}

prompt_secret() {
  local var_name="$1"
  local label="$2"
  local value=""
  [[ -n "${!var_name:-}" ]] && return 0
  [[ "$ASSUME_YES" != "1" ]] || die "для автоматической установки задайте $var_name"
  while [[ -z "$value" ]]; do
    printf '%s: ' "$label"
    read -r -s value
    printf '\n'
    value="$(trim "$value")"
  done
  printf -v "$var_name" '%s' "$value"
}

usage() {
  cat <<'EOF'
Полный установщик VPN Bot v2

Использование:
  ./install.sh
  ./install.sh --dry-run
  BOT_TOKEN=... ADMIN_BOT=123,456 ASSUME_YES=1 ./install.sh

Опции:
  --dry-run       проверить пакет и показать план без изменений
  --auto, -y      автоматический режим; токен и ADMIN_BOT передаются через env
  --skip-awg      не устанавливать AWG, но проверить существующий awgctl
  --skip-vless    не устанавливать VLESS, но проверить существующий vlessctl
  --vless-mask    запустить VLESS с доменной HTTPS-маскировкой
  --vless-direct  прямой VLESS WebSocket на TCP 443
  -h, --help      справка

Основные переменные:
  BOT_TOKEN, ADMIN_BOT, BOT_TITLE, SERVER_CHANNEL_MBIT
  REPO_URL, REPO_BRANCH, REPO_DIR, INSTALL_DIR
  VLESS_MODE=direct|mask, RUN_SPEEDTEST=0|1
  INSTALL_VPN_COMPONENTS=0|1, INSTALL_EXTRA_SOFTWARE=0|1
EOF
}

parse_args() {
  while (($#)); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --auto|-y|--yes) ASSUME_YES=1 ;;
      --skip-awg) SKIP_AWG=1 ;;
      --skip-vless) SKIP_VLESS=1 ;;
      --vless-mask) VLESS_MODE=mask ;;
      --vless-direct) VLESS_MODE=direct ;;
      -h|--help) usage; exit 0 ;;
      *) die "неизвестный аргумент: $1" ;;
    esac
    shift
  done
  [[ "$VLESS_MODE" == "direct" || "$VLESS_MODE" == "mask" ]] ||
    die "VLESS_MODE должен быть direct или mask"
}

require_sources() {
  local required=(
    bot.py traffic_collect.py channel_collect.py VPNBOT_VERSION servers.json .env.example
    INSTALLER_VERSION README.md USAGE_RU.md install.sh install_bot.sh
    app/config.py app/actions.py app/handlers.py app/access_store.py app/traffic_store.py
    app/channel_store.py
    app/traffic_chart.py
    assets/vpn-bot-avatar-640-v2.png assets/vpn-bot-avatar-640-v2.jpg
    server/server-status server/vpn-speedtest
    systemd/vpnbot.service systemd/vpnbot-traffic.service systemd/vpnbot-traffic.timer
    systemd/vpnbot-channel.service systemd/vpnbot-channel.timer
  )
  local item
  for item in "${required[@]}"; do
    [[ -f "$SCRIPT_DIR/$item" ]] || die "в пакете отсутствует $item"
  done
}

print_plan() {
  cat <<EOF
План установки:
  пакет:              $SCRIPT_DIR
  каталог бота:       $INSTALL_DIR
  репозиторий VPN:    $REPO_URL ($REPO_BRANCH)
  VPN-компоненты:     аудит и вопрос об установке/обновлении
  AmneziaWG:          $([[ "$SKIP_AWG" == "1" ]] && echo 'только проверка' || echo 'совместимая версия, DNS-профиль')
  VLESS:              $([[ "$SKIP_VLESS" == "1" ]] && echo 'только проверка' || echo "совместимая версия, режим $VLESS_MODE")
  дополнительное ПО: аудит версий и вопрос об установке/обновлении
  SQLite traffic:     ежедневно в 23:59 UTC
  SQLite access:      одноразовые ссылки и права на свои VPN-профили
  Channel metrics:    каждую минуту, хранение 90 дней
  мониторинг:         CPU/RAM/disk/network
  журналы:            максимум 7 дней
  channel capacity:   ${SERVER_CHANNEL_MBIT:-определить через Speedtest/ввод}
EOF
}

require_root_and_os() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "запустите установщик от root"
  [[ -r /etc/os-release ]] || die "не найден /etc/os-release"
  # shellcheck disable=SC1091
  . /etc/os-release
  case "${ID:-}:${VERSION_ID:-}" in
    debian:13*|ubuntu:24*|ubuntu:25*|ubuntu:26*) ;;
    *) die "поддерживаются Debian 13 и Ubuntu 24-26; обнаружено ${PRETTY_NAME:-unknown}" ;;
  esac
  [[ -d /run/systemd/system ]] || die "нужен systemd"
}

install_base_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y "${EXTRA_PACKAGES[@]}"
}

normalize_yes_no_value() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    1|y|yes|д|да) printf '1' ;;
    0|n|no|н|нет) printf '0' ;;
    *) return 1 ;;
  esac
}

choose_yes_no() {
  local var_name="$1"
  local question="$2"
  local current="${!var_name:-}"
  local normalized=""
  if [[ -n "$current" ]]; then
    normalized="$(normalize_yes_no_value "$current")" ||
      die "$var_name: укажите 1/0, yes/no или да/нет"
    printf -v "$var_name" '%s' "$normalized"
    save_resume_config
    return 0
  fi
  if confirm "$question" "yes"; then
    printf -v "$var_name" '%s' 1
  else
    printf -v "$var_name" '%s' 0
  fi
  save_resume_config
}

package_version() {
  dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

package_candidate() {
  apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2; exit}'
}

audit_extra_software() {
  local package installed candidate
  printf 'Дополнительное ПО для функций бота:\n'
  for package in "${EXTRA_PACKAGES[@]}"; do
    installed="$(package_version "$package")"
    candidate="$(package_candidate "$package")"
    if [[ -z "$installed" ]]; then
      printf '  - %-20s не установлено (доступно: %s)\n' "$package" "${candidate:-неизвестно}"
    elif [[ -n "$candidate" && "$candidate" != "(none)" && "$candidate" != "$installed" ]]; then
      printf '  - %-20s установлено %s, доступно обновление %s\n' "$package" "$installed" "$candidate"
    else
      printf '  - %-20s установлено %s, актуально\n' "$package" "$installed"
    fi
  done
}

verify_extra_software() {
  local package missing=()
  for package in "${EXTRA_PACKAGES[@]}"; do
    [[ -n "$(package_version "$package")" ]] || missing+=("$package")
  done
  ((${#missing[@]} == 0)) ||
    die "без установки отсутствуют обязательные пакеты: ${missing[*]}"
  python3 -c 'from PIL import Image' >/dev/null 2>&1 || die "модуль Python Pillow не работает"
  have speedtest-cli || die "команда speedtest-cli не найдена"
  have logrotate || die "команда logrotate не найдена"
}

prepare_extra_software() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  audit_extra_software
  choose_yes_no INSTALL_EXTRA_SOFTWARE \
    "Установить/обновить дополнительное ПО бота (Python, Pillow, logrotate, Speedtest)?"
  if [[ "$INSTALL_EXTRA_SOFTWARE" == "1" ]]; then
    install_base_packages
  else
    echo "Установка обновлений дополнительного ПО пропущена пользователем."
  fi
  verify_extra_software
}

ensure_repo() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
    git -C "$REPO_DIR" fetch origin "$REPO_BRANCH"
    git -C "$REPO_DIR" checkout "$REPO_BRANCH"
    git -C "$REPO_DIR" pull --ff-only origin "$REPO_BRANCH"
  elif [[ -e "$REPO_DIR" ]]; then
    die "$REPO_DIR существует и не является git-репозиторием"
  else
    install -d -m 0755 "$(dirname "$REPO_DIR")"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
  fi
  [[ -f "$REPO_DIR/vpn/amneziawg/install_amneziawg.sh" ]] || die "не найден AWG installer"
  [[ -f "$REPO_DIR/vpn/vless/install_vless.sh" ]] || die "не найден VLESS installer"
}

valid_ctl() {
  local command_path="$1"
  [[ -x "$command_path" ]] || return 1
  "$command_path" -j list | python3 -c 'import json,sys; data=json.load(sys.stdin); raise SystemExit(0 if data.get("ok") is True else 1)'
}

controller_is_current() {
  local installed="$1"
  local source="$2"
  valid_ctl "$installed" && cmp -s "$installed" "$source"
}

controller_status() {
  local label="$1"
  local installed="$2"
  local source="$3"
  if ! valid_ctl "$installed"; then
    printf '  - %-12s не установлен или не прошёл JSON-проверку\n' "$label"
  elif cmp -s "$installed" "$source"; then
    printf '  - %-12s установлен и совместим с этой версией бота\n' "$label"
  else
    printf '  - %-12s работает, но управляющий скрипт требует обновления\n' "$label"
  fi
}

audit_vpn_components() {
  echo "VPN-компоненты:"
  controller_status "AmneziaWG" "$AWGCTL_PATH" "$REPO_DIR/vpn/amneziawg/awgctl.sh"
  controller_status "VLESS" "$VLESSCTL_PATH" "$REPO_DIR/vpn/vless/vlessctl.sh"
}

detect_public_host() {
  python3 - <<'PY'
import ipaddress
import urllib.request

for url in ("https://api.ipify.org", "https://ifconfig.me/ip"):
    try:
        with urllib.request.urlopen(url, timeout=8) as response:
            value = response.read().decode().strip()
        ipaddress.ip_address(value)
        print(value)
        break
    except Exception:
        continue
PY
}

vpn_install_is_needed() {
  ! valid_ctl "$AWGCTL_PATH" || ! valid_ctl "$VLESSCTL_PATH"
}

collect_shared_vpn_settings() {
  local detected=""
  [[ -n "$VPN_PUBLIC_HOST" ]] || detected="$(detect_public_host)"
  prompt_value VPN_PUBLIC_HOST "Публичный IP/host для обоих VPN" "$detected"
  [[ -n "$VPN_PUBLIC_HOST" ]] || die "не удалось определить публичный IP/host"
  prompt_value VPN_INITIAL_CLIENT "Имя первого пользователя в обоих VPN" "vpnuser1"
  [[ "$VPN_INITIAL_CLIENT" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]] ||
    die "имя первого пользователя должно содержать 1-64 символа: буквы, цифры, точка, _, -, @"
  save_resume_config
}

update_controller() {
  local label="$1"
  local source="$2"
  local installed="$3"
  local link_path="$4"
  chmod +x "$source"
  valid_ctl "$source" || die "новый $label несовместим с текущей конфигурацией сервера"
  install -m 0755 "$source" "$installed"
  ln -sf "$installed" "$link_path"
  valid_ctl "$installed" || die "$label не прошёл проверку после обновления"
  echo "$label обновлён до версии из текущего репозитория."
}

prepare_vpn_components() {
  local awg_source="$REPO_DIR/vpn/amneziawg/awgctl.sh"
  local vless_source="$REPO_DIR/vpn/vless/vlessctl.sh"
  audit_vpn_components
  choose_yes_no INSTALL_VPN_COMPONENTS \
    "Установить/обновить AmneziaWG и VLESS, совместимые с ботом?"

  if [[ "$INSTALL_VPN_COMPONENTS" == "0" ]]; then
    controller_is_current "$AWGCTL_PATH" "$awg_source" ||
      die "AmneziaWG не соответствует версии бота; разрешите установку/обновление"
    controller_is_current "$VLESSCTL_PATH" "$vless_source" ||
      die "VLESS не соответствует версии бота; разрешите установку/обновление"
    echo "Оба VPN-протокола уже совместимы; их обновление пропущено."
    return 0
  fi

  if vpn_install_is_needed; then
    echo "Общие настройки будут использованы для обоих протоколов."
    collect_shared_vpn_settings
  fi
  ensure_awg
  ensure_vless
}

ensure_awg() {
  if valid_ctl "$AWGCTL_PATH"; then
    if ! cmp -s "$AWGCTL_PATH" "$REPO_DIR/vpn/amneziawg/awgctl.sh"; then
      update_controller "awgctl" "$REPO_DIR/vpn/amneziawg/awgctl.sh" \
        "$AWGCTL_PATH" "/usr/local/bin/awgctl"
    else
      echo "AmneziaWG уже готов: $AWGCTL_PATH"
    fi
    return 0
  fi
  [[ "$SKIP_AWG" != "1" ]] || die "--skip-awg указан, но рабочий awgctl не найден"
  step "Установка AmneziaWG с DNS-профилем"
  chmod +x "$REPO_DIR/vpn/amneziawg/install_amneziawg.sh" "$REPO_DIR/vpn/amneziawg/awgctl.sh"
  (cd "$REPO_DIR/vpn/amneziawg" && \
    ASSUME_YES=1 \
    AWG_OBFS_PROFILE=dns \
    PUBLIC_ENDPOINT="$VPN_PUBLIC_HOST" \
    CLIENT_NAME="$VPN_INITIAL_CLIENT" \
    ./install_amneziawg.sh)
  valid_ctl "$AWGCTL_PATH" || die "awgctl не прошёл JSON-проверку"
}

ensure_vless() {
  if valid_ctl "$VLESSCTL_PATH"; then
    if ! cmp -s "$VLESSCTL_PATH" "$REPO_DIR/vpn/vless/vlessctl.sh"; then
      update_controller "vlessctl" "$REPO_DIR/vpn/vless/vlessctl.sh" \
        "$VLESSCTL_PATH" "/usr/local/bin/vlessctl"
    else
      echo "VLESS уже готов: $VLESSCTL_PATH"
    fi
    return 0
  fi
  [[ "$SKIP_VLESS" != "1" ]] || die "--skip-vless указан, но рабочий vlessctl не найден"
  step "Установка VLESS/Xray ($VLESS_MODE)"
  chmod +x "$REPO_DIR/vpn/vless/install_vless.sh" "$REPO_DIR/vpn/vless/vlessctl.sh"
  if [[ "$VLESS_MODE" == "mask" ]]; then
    (cd "$REPO_DIR/vpn/vless" && \
      PUBLIC_HOST="$VPN_PUBLIC_HOST" CLIENT_NAME="$VPN_INITIAL_CLIENT" \
      ./install_vless.sh --mask --auto -lang ru)
  else
    (cd "$REPO_DIR/vpn/vless" && \
      PUBLIC_HOST="$VPN_PUBLIC_HOST" CLIENT_NAME="$VPN_INITIAL_CLIENT" \
      ./install_vless.sh --direct --auto -lang ru)
  fi
  valid_ctl "$VLESSCTL_PATH" || die "vlessctl не прошёл JSON-проверку"
}

validate_admins() {
  [[ "$ADMIN_BOT" =~ ^[0-9]+([[:space:]]*,[[:space:]]*[0-9]+)*$ ]] ||
    die "ADMIN_BOT: нужны числовые Telegram ID через запятую"
  ADMIN_BOT="$(printf '%s' "$ADMIN_BOT" | tr -d '[:space:]')"
}

validate_token() {
  [[ "$BOT_TOKEN" =~ ^[0-9]+:.+ ]] || die "BOT_TOKEN выглядит неверно"
TOKEN="$BOT_TOKEN" python3 - <<'PY'
import json, os, urllib.request
url = f"https://api.telegram.org/bot{os.environ['TOKEN']}/getMe"
try:
    with urllib.request.urlopen(url, timeout=30) as response:
        data = json.loads(response.read().decode())
except Exception as exc:
    raise SystemExit(f"Telegram token check failed: {type(exc).__name__}") from None
if not data.get("ok"):
    raise SystemExit("Telegram rejected BOT_TOKEN")
print("Telegram token: OK")
PY
}

recommend_channel() {
  local raw="$1"
  SPEEDTEST_JSON="$raw" python3 - <<'PY'
import json, os
data = json.loads(os.environ["SPEEDTEST_JSON"])
measured = max(float(data.get("download", 0)), float(data.get("upload", 0))) / 1_000_000
for capacity in (50, 100, 200, 300, 500, 1000, 2000, 5000, 10000):
    if capacity >= measured * 1.05:
        print(capacity)
        break
else:
    print(int(measured * 1.10 + 0.5))
PY
}

configure_channel() {
  local raw=""
  local suggested="200"
  if [[ -n "$SERVER_CHANNEL_MBIT" ]]; then
    [[ "$SERVER_CHANNEL_MBIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "SERVER_CHANNEL_MBIT должен быть числом"
    return 0
  fi
  if [[ "$ASSUME_YES" != "1" && "$RUN_SPEEDTEST" == "1" ]] &&
     confirm "Запустить Speedtest для оценки канала? Он временно загрузит сеть" "yes"; then
    if raw="$(speedtest-cli --json --secure)"; then
      suggested="$(recommend_channel "$raw")"
      SPEEDTEST_JSON="$raw" python3 - <<'PY'
import json, os
d = json.loads(os.environ["SPEEDTEST_JSON"])
print(f"Speedtest: download={d['download']/1e6:.1f} Mbit/s upload={d['upload']/1e6:.1f} Mbit/s ping={d['ping']:.1f} ms")
PY
    else
      warn "Speedtest не выполнен; используется ручной ввод"
    fi
  fi
  prompt_value SERVER_CHANNEL_MBIT "Номинальная скорость канала, Мбит/с" "$suggested"
  [[ "$SERVER_CHANNEL_MBIT" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "SERVER_CHANNEL_MBIT должен быть числом"
}

backup_existing_bot() {
  [[ -e "$INSTALL_DIR" ]] || return 0
  local stamp target
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  target="$BACKUP_ROOT/${stamp}-installer-v2"
  install -d -m 0700 "$BACKUP_ROOT"
  cp -a "$INSTALL_DIR" "$target"
  echo "Резервная копия: $target"
}

install_bot_files() {
  install -d -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/app" "$INSTALL_DIR/assets"
  install -d -m 0700 "$INSTALL_DIR/traffic-data"
  install -m 0755 "$SCRIPT_DIR/bot.py" "$INSTALL_DIR/bot.py"
  install -m 0755 "$SCRIPT_DIR/traffic_collect.py" "$INSTALL_DIR/traffic_collect.py"
  install -m 0755 "$SCRIPT_DIR/channel_collect.py" "$INSTALL_DIR/channel_collect.py"
  install -m 0644 "$SCRIPT_DIR/VPNBOT_VERSION" "$INSTALL_DIR/VPNBOT_VERSION"
  install -m 0644 "$SCRIPT_DIR/README.md" "$INSTALL_DIR/README.md"
  install -m 0644 "$SCRIPT_DIR/.env.example" "$INSTALL_DIR/.env.example"
  install -m 0644 "$SCRIPT_DIR/servers.json" "$INSTALL_DIR/servers.json"
  install -m 0644 "$SCRIPT_DIR/assets/vpn-bot-avatar-640-v2.png" "$INSTALL_DIR/assets/vpn-bot-avatar-640-v2.png"
  install -m 0644 "$SCRIPT_DIR/assets/vpn-bot-avatar-640-v2.jpg" "$INSTALL_DIR/assets/vpn-bot-avatar-640-v2.jpg"
  local file
  for file in "$SCRIPT_DIR"/app/*.py; do
    install -m 0644 "$file" "$INSTALL_DIR/app/$(basename "$file")"
  done
  install -m 0755 "$SCRIPT_DIR/server/server-status" "$SERVER_STATUS_PATH"
  install -m 0755 "$SCRIPT_DIR/server/vpn-speedtest" "$SPEEDTEST_PATH"
}

deploy_bot_payload() {
  install_bot_files
  write_env
  delete_webhook
}

write_env() {
  local tmp
  umask 077
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_BOT=$ADMIN_BOT
AWGCTL=$AWGCTL_PATH

BOT_TITLE=$BOT_TITLE
PRIVATE_ONLY=1
ONLINE_WINDOW_SECONDS=180
VLESS_ONLINE_INTERVAL_SECONDS=3
POLL_TIMEOUT=45
REQUEST_TIMEOUT=75
MAX_MESSAGE=3900
LOG_LEVEL=WARNING

SERVERS_CONFIG=$INSTALL_DIR/servers.json
TRAFFIC_DB_DIR=$INSTALL_DIR/traffic-data
TRAFFIC_TIMEZONE=UTC
ACCESS_DB_PATH=$INSTALL_DIR/access.sqlite3
ACCESS_INVITE_HOURS=24

SERVER_STATUS_COMMAND=$SERVER_STATUS_PATH
SERVER_CHANNEL_MBIT=$SERVER_CHANNEL_MBIT
SPEEDTEST_COMMAND=$SPEEDTEST_PATH
SPEEDTEST_TIMEOUT=210
CHANNEL_DB_PATH=$INSTALL_DIR/server-metrics.sqlite3
CHANNEL_INTERFACE=auto
CHANNEL_RETENTION_DAYS=90
EOF
  install -m 0600 "$tmp" "$INSTALL_DIR/.env"
  rm -f "$tmp"
}

install_units() {
  local source target tmp
  for source in "$SCRIPT_DIR"/systemd/*; do
    target="/etc/systemd/system/$(basename "$source")"
    tmp="$(mktemp)"
    sed "s#/root/vpnbot#$INSTALL_DIR#g" "$source" >"$tmp"
    install -m 0644 "$tmp" "$target"
    rm -f "$tmp"
  done
  systemctl daemon-reload
  systemctl enable --now vpnbot.service vpnbot-traffic.timer vpnbot-channel.timer
  systemctl restart vpnbot.service
  systemctl start vpnbot-traffic.service
  systemctl start vpnbot-channel.service
}

configure_log_retention() {
  install -d -m 0755 /etc/systemd/journald.conf.d
  cat >/etc/systemd/journald.conf.d/99-vpn-retention.conf <<'EOF'
[Journal]
SystemMaxUse=200M
MaxRetentionSec=7day
EOF
  if [[ -f /etc/logrotate.conf ]]; then
    cp -an /etc/logrotate.conf /etc/logrotate.conf.before-vpnbot-v2 || true
    sed -i -E 's/^[[:space:]]*weekly[[:space:]]*$/daily/; s/^[[:space:]]*rotate[[:space:]]+[0-9]+/rotate 7/' /etc/logrotate.conf
    grep -Eq '^[[:space:]]*maxage[[:space:]]+' /etc/logrotate.conf ||
      sed -i '/^[[:space:]]*rotate[[:space:]]+7/a maxage 7' /etc/logrotate.conf
  fi
  if [[ -f /etc/logrotate.d/vless-xray ]]; then
    grep -Eq '^[[:space:]]*maxage[[:space:]]+' /etc/logrotate.d/vless-xray ||
      sed -i '/^[[:space:]]*rotate[[:space:]]+7/a\    maxage 7' /etc/logrotate.d/vless-xray
  fi
  systemctl restart systemd-journald
  systemctl enable --now logrotate.timer 2>/dev/null || true
}

delete_webhook() {
  TOKEN="$BOT_TOKEN" python3 - <<'PY'
import json, os, urllib.parse, urllib.request
url = f"https://api.telegram.org/bot{os.environ['TOKEN']}/deleteWebhook"
body = urllib.parse.urlencode({"drop_pending_updates": "false"}).encode()
try:
    with urllib.request.urlopen(url, data=body, timeout=30) as response:
        data = json.loads(response.read().decode())
except Exception as exc:
    raise SystemExit(f"Telegram webhook cleanup failed: {type(exc).__name__}") from None
if not data.get("ok"):
    raise SystemExit("could not delete Telegram webhook")
PY
}

verify_installation() {
  python3 -m py_compile "$INSTALL_DIR/bot.py" "$INSTALL_DIR/traffic_collect.py" "$INSTALL_DIR/channel_collect.py" "$INSTALL_DIR"/app/*.py "$SERVER_STATUS_PATH"
  valid_ctl "$AWGCTL_PATH" || die "финальная проверка awgctl не пройдена"
  valid_ctl "$VLESSCTL_PATH" || die "финальная проверка vlessctl не пройдена"
  "$SERVER_STATUS_PATH" -j | python3 -c 'import json,sys; d=json.load(sys.stdin); raise SystemExit(0 if d.get("ok") else 1)'
  [[ -x "$SPEEDTEST_PATH" ]] || die "не установлен $SPEEDTEST_PATH"
  systemctl is-active --quiet vpnbot.service || die "vpnbot.service не активен"
  systemctl is-active --quiet awg-quick@awg0.service || die "AWG service не активен"
  systemctl is-active --quiet xray.service || die "xray.service не активен"
  systemctl is-active --quiet vpnbot-traffic.timer || die "traffic timer не активен"
  systemctl is-active --quiet vpnbot-channel.timer || die "channel timer не активен"
}

main() {
  parse_args "$@"
  require_sources
  if [[ "$DRY_RUN" == "1" ]]; then
    print_plan
    echo
    echo "DRY RUN: пакет целостен, изменений не выполнено."
    exit 0
  fi

  require_root_and_os
  start_installation_tracking
  print_plan
  run_resumable_step extra_software "Проверка дополнительного ПО" prepare_extra_software
  run_resumable_step repository "Загрузка или обновление telemt2" ensure_repo
  run_resumable_step vpn_components "Проверка AmneziaWG и VLESS" prepare_vpn_components

  if ! step_done bot_payload; then
    step "Настройки Telegram и канала"
    prompt_secret BOT_TOKEN "Telegram BOT_TOKEN"
    prompt_value ADMIN_BOT "Telegram ID администраторов через запятую"
    validate_admins
    validate_token
    configure_channel
    save_resume_config
  else
    step "Настройки Telegram и канала (уже сохранены в установленном боте)"
  fi

  run_resumable_step bot_backup "Резервное копирование существующего бота" backup_existing_bot
  run_resumable_step bot_payload "Установка VPN Bot v2" deploy_bot_payload
  run_resumable_step systemd_units "Настройка systemd и ежедневного трафика" install_units
  run_resumable_step log_retention "Ротация журналов: максимум 7 дней" configure_log_retention
  run_resumable_step verification "Финальная проверка" verify_installation

  echo
  echo "VPN Bot v2 установлен: $INSTALL_DIR"
  echo "Версия: $(cat "$INSTALL_DIR/VPNBOT_VERSION")"
  echo "Канал: $SERVER_CHANNEL_MBIT Мбит/с"
  echo "Откройте бота и отправьте /start."
  finish_installation_tracking
}

main "$@"
