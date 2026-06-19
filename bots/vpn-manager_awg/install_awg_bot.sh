#!/usr/bin/env bash
set -Eeuo pipefail

REPO_URL="${REPO_URL:-https://github.com/Telemtinstall/telemt2.git}"
BRANCH="${BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/root/telemt2}"
BOT_SOURCE_DIR="${BOT_SOURCE_DIR:-$REPO_DIR/bots/vpn-manager_awg}"
INSTALL_DIR="${INSTALL_DIR:-/root/vpnbot}"
SERVICE_NAME="${SERVICE_NAME:-vpnbot.service}"
AWGCTL_PATH="${AWGCTL:-/usr/local/sbin/awgctl}"

BOT_TOKEN="${BOT_TOKEN:-}"
ADMIN_BOT="${ADMIN_BOT:-}"

step_no=0

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

have() {
  command -v "$1" >/dev/null 2>&1
}

on_error() {
  local rc="$1"
  local line="$2"
  local cmd="$3"

  echo >&2
  echo "ОШИБКА: установка остановлена." >&2
  echo "Строка: $line" >&2
  echo "Команда: $cmd" >&2
  exit "$rc"
}

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

confirm() {
  local label="$1"
  local default="${2:-yes}"
  local answer

  printf '%s [%s]: ' "$label" "$default"
  read -r answer
  answer="$(trim_value "$answer")"
  answer="${answer:-$default}"
  answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
  [[ "$answer" == "y" || "$answer" == "yes" || "$answer" == "д" || "$answer" == "да" ]]
}

prompt_secret() {
  local var_name="$1"
  local label="$2"
  local value

  if [[ -n "${!var_name:-}" ]]; then
    return 0
  fi

  while :; do
    printf '%s: ' "$label"
    read -r -s value
    printf '\n'
    value="$(trim_value "$value")"
    if [[ -n "$value" ]]; then
      printf -v "$var_name" '%s' "$value"
      return 0
    fi
    echo "Значение не может быть пустым."
  done
}

prompt_admin_id() {
  local value

  if [[ -n "$ADMIN_BOT" ]]; then
    [[ "$ADMIN_BOT" =~ ^[0-9]+$ ]] || die "ADMIN_BOT должен быть одним числовым Telegram ID."
    return 0
  fi

  while :; do
    printf 'Telegram admin ID, только цифры: '
    read -r value
    value="$(trim_value "$value")"
    if [[ "$value" =~ ^[0-9]+$ ]]; then
      ADMIN_BOT="$value"
      return 0
    fi
    echo "Введите один Telegram user ID, только цифры."
  done
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "запустите скрипт от root."
}

install_base_packages() {
  if have git && have python3 && have install; then
    return 0
  fi

  have apt-get || die "нужен git и python3; автоматическая установка поддерживается только через apt-get."

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git ca-certificates python3
}

ensure_repo() {
  install_base_packages

  if [[ -d "$REPO_DIR/.git" ]]; then
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
    git -C "$REPO_DIR" fetch origin "$BRANCH"
    git -C "$REPO_DIR" checkout "$BRANCH"
    git -C "$REPO_DIR" pull --ff-only origin "$BRANCH"
  elif [[ -e "$REPO_DIR" ]]; then
    die "$REPO_DIR уже существует, но это не git-репозиторий. Уберите каталог или задайте REPO_DIR."
  else
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --branch "$BRANCH" "$REPO_URL" "$REPO_DIR"
  fi

  [[ -d "$BOT_SOURCE_DIR" ]] || die "не найден каталог бота: $BOT_SOURCE_DIR"
}

detect_awgctl_path() {
  if [[ -x "$AWGCTL_PATH" ]]; then
    return 0
  fi

  local detected
  detected="$(command -v awgctl || true)"
  if [[ -n "$detected" && -x "$detected" ]]; then
    AWGCTL_PATH="$detected"
    return 0
  fi

  return 1
}

first_client_from_list_json() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
if data.get("ok") is not True:
    raise SystemExit("ok is not true")
clients = data.get("clients") or []
if not clients:
    print("")
else:
    first = clients[0]
    print(first.get("name") or first.get("ref") or first.get("id") or "")
'
}

validate_qr_json() {
  python3 -c '
import json, sys
data = json.load(sys.stdin)
if data.get("ok") is not True:
    raise SystemExit("ok is not true")
if not data.get("qr_png_base64"):
    raise SystemExit("missing qr_png_base64 for iPhone")
items = data.get("vpn_qr_png_base64_items") or []
if not isinstance(items, list) or len(items) < 1 or not items[0]:
    raise SystemExit("missing vpn_qr_png_base64_items[0] for Android")
if len(items) > 1:
    raise SystemExit("vpn_qr_png_base64_items has multiple chunks; Android app expects one QR")
'
}

test_awgctl() {
  local list_json first_client qr_json

  detect_awgctl_path || return 1

  list_json="$("$AWGCTL_PATH" -j list)" || return 1
  first_client="$(printf '%s' "$list_json" | first_client_from_list_json)" || return 1

  if [[ -z "$first_client" ]]; then
    warn "awgctl отвечает, но клиентов нет; QR-поля проверим после создания первого клиента."
    return 0
  fi

  qr_json="$("$AWGCTL_PATH" -j qr "$first_client")" || return 1
  printf '%s' "$qr_json" | validate_qr_json || return 1
}

install_amneziawg() {
  local awg_dir="$REPO_DIR/vpn/amneziawg"

  ensure_repo
  [[ -x "$awg_dir/install_amneziawg.sh" ]] || chmod +x "$awg_dir/install_amneziawg.sh"
  [[ -x "$awg_dir/awgctl.sh" ]] || chmod +x "$awg_dir/awgctl.sh"

  echo
  echo "Сейчас запустится установщик AmneziaWG. Он задаст свои вопросы про порт, домен, подсеть и первого клиента."
  echo "После завершения установка бота продолжится автоматически."
  echo
  (cd "$awg_dir" && ./install_amneziawg.sh)
}

ensure_awg_ready() {
  if test_awgctl; then
    echo "awgctl найден и подходит: $AWGCTL_PATH"
    return 0
  fi

  warn "AmneziaWG/awgctl не найден или awgctl не подходит для этого бота."
  if confirm "Установить наш AmneziaWG/AWG сервер сейчас?" "yes"; then
    install_amneziawg
  else
    die "без рабочего awgctl бот не сможет управлять VPN."
  fi

  test_awgctl || die "после установки awgctl всё еще не отвечает как нужно."
  echo "awgctl готов: $AWGCTL_PATH"
}

validate_bot_token() {
  local token="$1"
  [[ "$token" =~ ^[0-9]+:.+ ]] || die "BOT_TOKEN выглядит неверно: ожидается формат 123456:ABC..."
}

check_telegram_token() {
  TOKEN="$BOT_TOKEN" python3 - <<'PY'
import json
import os
import sys
import urllib.error
import urllib.request

token = os.environ["TOKEN"]
url = f"https://api.telegram.org/bot{token}/getMe"
try:
    with urllib.request.urlopen(url, timeout=30) as response:
        payload = response.read().decode("utf-8")
except urllib.error.HTTPError as exc:
    raise SystemExit(f"Telegram HTTP {exc.code}: token rejected or API unavailable")
except urllib.error.URLError as exc:
    raise SystemExit(f"Telegram network error: {exc}")

data = json.loads(payload)
if not data.get("ok"):
    raise SystemExit("Telegram token check failed")
username = data.get("result", {}).get("username") or ""
print(f"Telegram bot OK: @{username}" if username else "Telegram bot OK")
PY
}

delete_webhook() {
  TOKEN="$BOT_TOKEN" python3 - <<'PY'
import json
import os
import urllib.parse
import urllib.request

token = os.environ["TOKEN"]
url = f"https://api.telegram.org/bot{token}/deleteWebhook"
data = urllib.parse.urlencode({"drop_pending_updates": "false"}).encode()
with urllib.request.urlopen(url, data=data, timeout=30) as response:
    payload = json.loads(response.read().decode("utf-8"))
if not payload.get("ok"):
    raise SystemExit("could not delete Telegram webhook")
print("Telegram webhook disabled for polling")
PY
}

write_env() {
  local tmp

  umask 077
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
BOT_TOKEN=$BOT_TOKEN
ADMIN_BOT=$ADMIN_BOT
AWGCTL=$AWGCTL_PATH

BOT_TITLE=Личный VPN-бот
PRIVATE_ONLY=1
ONLINE_WINDOW_SECONDS=180
POLL_TIMEOUT=45
REQUEST_TIMEOUT=75
MAX_MESSAGE=3900
LOG_LEVEL=CRITICAL
EOF
  install -m 0600 "$tmp" "$INSTALL_DIR/.env"
  rm -f "$tmp"
}

install_bot_files() {
  install -d -m 0755 "$INSTALL_DIR" "$INSTALL_DIR/app"
  install -m 0755 "$BOT_SOURCE_DIR/bot.py" "$INSTALL_DIR/bot.py"
  install -m 0755 "$BOT_SOURCE_DIR/restart_bot.sh" "$INSTALL_DIR/restart_bot.sh"
  install -m 0644 "$BOT_SOURCE_DIR/README.md" "$INSTALL_DIR/README.md"
  install -m 0644 "$BOT_SOURCE_DIR/.env.example" "$INSTALL_DIR/.env.example"
  install -m 0644 "$BOT_SOURCE_DIR/.gitignore" "$INSTALL_DIR/.gitignore"
  install -m 0644 "$BOT_SOURCE_DIR/vpnbot.service" "$INSTALL_DIR/vpnbot.service"

  for file in "$BOT_SOURCE_DIR"/app/*.py; do
    install -m 0644 "$file" "$INSTALL_DIR/app/$(basename "$file")"
  done
}

install_systemd_service() {
  install -m 0644 "$INSTALL_DIR/vpnbot.service" "/etc/systemd/system/$SERVICE_NAME"
  systemctl daemon-reload
  systemctl enable --now "$SERVICE_NAME"
  systemctl restart "$SERVICE_NAME"
}

verify_bot_service() {
  sleep 2
  systemctl is-active --quiet "$SERVICE_NAME" || {
    systemctl status "$SERVICE_NAME" --no-pager -l || true
    die "$SERVICE_NAME не запустился."
  }
  echo "$SERVICE_NAME активен."
}

main() {
  require_root

  step "Проверка и установка базовых зависимостей"
  install_base_packages

  step "Проверка AmneziaWG/AWG и awgctl"
  ensure_awg_ready

  step "Загрузка/обновление telemt2"
  ensure_repo

  step "Ввод настроек Telegram-бота"
  prompt_secret BOT_TOKEN "Telegram bot token"
  prompt_admin_id
  validate_bot_token "$BOT_TOKEN"
  check_telegram_token

  step "Установка файлов бота в $INSTALL_DIR"
  install_bot_files
  write_env
  python3 -m py_compile "$INSTALL_DIR/bot.py" "$INSTALL_DIR"/app/*.py

  step "Настройка Telegram polling и systemd"
  delete_webhook
  install_systemd_service
  verify_bot_service

  echo
  echo "Готово. Бот установлен в $INSTALL_DIR"
  echo ".env создан с правами 600, токен не выводился."
  echo "Откройте Telegram-бота и отправьте /start."
}

main "$@"
