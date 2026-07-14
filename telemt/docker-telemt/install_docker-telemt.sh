#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_VERSION="2026-07-14"
INSTALL_DIR="${INSTALL_DIR:-/opt/telemt-docker}"
STATE_FILE="${STATE_FILE:-/root/.install_docker_telemt.state}"
SAVED_CONFIG="${SAVED_CONFIG:-/root/.install_docker_telemt.config}"
SECRET_FILE="${SECRET_FILE:-$INSTALL_DIR/telemt-secret.env}"
TELEMT_VERSION_ENV_SET=0
TELEMT_VERSION_ENV_VALUE=""
if [ -n "${TELEMT_VERSION+x}" ]; then
  TELEMT_VERSION_ENV_SET=1
  TELEMT_VERSION_ENV_VALUE="$TELEMT_VERSION"
fi
# Bump only after checking the installer/config compatibility for that Telemt release.
TELEMT_LATEST_COMPATIBLE_VERSION="${TELEMT_LATEST_COMPATIBLE_VERSION:-3.4.23}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
TELEMT_DEFAULT_VERSION="${TELEMT_DEFAULT_VERSION:-$TELEMT_LATEST_COMPATIBLE_VERSION}"

SYSTEM_CA_FILE="${SYSTEM_CA_FILE:-/etc/ssl/certs/ca-certificates.crt}"
TELEMT_OPENSSL_MIN_VERSION="${TELEMT_OPENSSL_MIN_VERSION:-3.5.2}"
TELEMT_OPENSSL_BUILD_VERSION="${TELEMT_OPENSSL_BUILD_VERSION:-3.5.7}"
TELEMT_OPENSSL_BUILD_SHA256="${TELEMT_OPENSSL_BUILD_SHA256:-a8c0d28a529ca480f9f36cf5792e2cd21984552a3c8e4aa11a24aa31aeac98e8}"
TELEMT_NGINX_BUILD_VERSION="${TELEMT_NGINX_BUILD_VERSION:-1.31.2}"
TELEMT_NGINX_BUILD_SHA256="${TELEMT_NGINX_BUILD_SHA256:-af2a957c41da636ddc4f883e4523c6d140b4784dbce42000c364ae5092aa473c}"
TELEMT_NGINX_OPENSSL_MODE="${TELEMT_NGINX_OPENSSL_MODE:-auto}"
TELEMT_NGINX_PREFIX="${TELEMT_NGINX_PREFIX:-/opt/telemt-nginx-openssl35}"
TELEMT_NGINX_BIN="${TELEMT_NGINX_BIN:-/usr/local/sbin/nginx-telemt-openssl35}"
TELEMT_NGINX_CONF="${TELEMT_NGINX_CONF:-$TELEMT_NGINX_PREFIX/nginx.conf}"
TELEMT_NGINX_DROPIN="${TELEMT_NGINX_DROPIN:-/etc/systemd/system/nginx.service.d/90-telemt-openssl35.conf}"

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
TELEMT_IMAGE="${TELEMT_IMAGE:-telemt-local:${TELEMT_DEFAULT_VERSION}}"
TELEMT_VERSION="${TELEMT_VERSION:-$TELEMT_DEFAULT_VERSION}"
TELEMT_USER="${TELEMT_USER:-default}"
TELEMT_USERS="${TELEMT_USERS:-}"
TELEMT_LINK_COUNT="${TELEMT_LINK_COUNT:-}"
TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-5000}"
TELEMT_CLIENT_MSS="${TELEMT_CLIENT_MSS:-tspu}"
TELEMT_CLIENT_MSS_BULK="${TELEMT_CLIENT_MSS_BULK:-1400}"
TELEMT_SYNLIMIT="${TELEMT_SYNLIMIT:-false}"
TELEMT_SYNLIMIT_SECONDS="${TELEMT_SYNLIMIT_SECONDS:-60}"
TELEMT_SYNLIMIT_HITCOUNT="${TELEMT_SYNLIMIT_HITCOUNT:-48}"
TELEMT_SYNLIMIT_BURST="${TELEMT_SYNLIMIT_BURST:-1}"
TELEMT_SYNLIMIT_IOS_SECONDS="${TELEMT_SYNLIMIT_IOS_SECONDS:-1}"
TELEMT_SYNLIMIT_IOS_HITCOUNT="${TELEMT_SYNLIMIT_IOS_HITCOUNT:-12}"
TELEMT_SYNLIMIT_IOS_BURST="${TELEMT_SYNLIMIT_IOS_BURST:-24}"
TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS="${TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS:-60000}"
TELEMT_SYNLIMIT_HASHLIMIT_SIZE="${TELEMT_SYNLIMIT_HASHLIMIT_SIZE:-32768}"
AD_TAG="${AD_TAG:-}"
USE_MIDDLE_PROXY="${USE_MIDDLE_PROXY:-}"
ENABLE_LOGS="${ENABLE_LOGS:-no}"
ENABLE_DOCKER_HARDENING="${ENABLE_DOCKER_HARDENING:-yes}"
ENABLE_HIGH_LOAD_TUNING="${ENABLE_HIGH_LOAD_TUNING:-yes}"
AUTO_BUILD_IMAGE="${AUTO_BUILD_IMAGE:-yes}"
MASK_SITE_MODE="${MASK_SITE_MODE:-fancy}"
SCRIPT_LANG="${SCRIPT_LANG:-en}"
ASSUME_YES="${ASSUME_YES:-0}"
AUTO_MODE="${AUTO_MODE:-0}"
UPDATE_MODE="${UPDATE_MODE:-0}"
FIX_NGINX_MODE="${FIX_NGINX_MODE:-0}"
NO_CACHE="${NO_CACHE:-0}"
CLEAN_INSTALL_MODE="0"

PUBLIC_IP=""
SCRIPT_LANG_FROM_CLI="0"
TELEMT_DETECTED_VERSION=""
TELEMT_DETECTED_VERSION_SOURCE=""
TELEMT_UPDATE_TARGET_VERSION=""
TELEMT_UPDATE_IMAGE_BEFORE=""
TELEMT_UPDATE_IMAGE_AFTER=""
TELEMT_UPDATE_CONFIG_MISSING=""
ACME_PREFLIGHT_TOKEN=""
ACME_PREFLIGHT_EXPECTED=""
ACME_PREFLIGHT_PATH=""
ACME_PREFLIGHT_LOG="/root/telemt-acme-http01-check.txt"
DETECTED_OS_ID=""
DETECTED_OS_VERSION_ID=""

say() {
  printf '%s\n' "$*"
}

die() {
  if [ "${SCRIPT_LANG:-en}" = "ru" ]; then
    printf 'ОШИБКА: %s\n' "$*" >&2
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
  exit 1
}

is_ru() {
  [ "${SCRIPT_LANG:-en}" = "ru" ]
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

normalize_script_lang() {
  case "$(lower "$1")" in
    ru|rus|russian|рус|русский) printf 'ru' ;;
    en|eng|english|'') printf 'en' ;;
    *) return 1 ;;
  esac
}

usage() {
  if is_ru; then
    cat <<'EOF'
Использование:
  ./install_docker-telemt.sh [-lang ru|en] [--auto] [--update] [--fix-nginx]

Примеры:
  ./install_docker-telemt.sh
  ./install_docker-telemt.sh -lang ru
  ./install_docker-telemt.sh --auto -lang ru
  DOMAIN=proxy.example.com ./install_docker-telemt.sh --auto -lang ru
  ./install_docker-telemt.sh --lang en
  ./install_docker-telemt.sh --update -lang ru
  ./install_docker-telemt.sh --fix-nginx -lang ru

Опции:
  -lang, --lang   Язык интерфейса установщика: en или ru.
  -auto, --auto   Автоматический режим: взять значения по умолчанию,
                  автоматически подтвердить план и спросить только домен,
                  если его нельзя определить заранее.
                  Домен берется из DOMAIN, сохраненного конфига или FQDN
                  hostname; в интерактивном терминале будет задан один
                  вопрос "Домен прокси".
  -update, --update
                  Проанализировать текущую установку, выбрать точную
                  совместимую версию Telemt, обновить Docker image и
                  перезапустить контейнер; на Ubuntu также проверить host
                  nginx/OpenSSL. Сохранить telemt.toml,
                  docker-compose.yml, секреты, ссылки и nginx-конфиги.
  -fix, --fix-nginx
                  Аварийно починить nginx после ошибки
                  unknown directive "http2" и выполнить Docker doctor.
                  Секреты и сертификаты сохраняются; telemt.toml правится
                  только для совместимости, если он мешает старту.
  -h, --help      Показать эту справку.

Переменные:
  RESET_INSTALL_STATE=1
                  Новая установка с нуля: не читать старый сохраненный ввод,
                  удалить старый Telemt secret/config/compose/container.
  TELEMT_NGINX_OPENSSL_MODE=auto|required|off
                  Только Ubuntu: проверить реальный host nginx и при
                  необходимости собрать nginx/OpenSSL 3.5.7. Default: auto.
EOF
    return 0
  fi

  cat <<'EOF'
Usage:
  ./install_docker-telemt.sh [-lang ru|en] [--auto] [--update] [--fix-nginx]

Examples:
  ./install_docker-telemt.sh
  ./install_docker-telemt.sh -lang ru
  ./install_docker-telemt.sh --auto -lang en
  DOMAIN=proxy.example.com ./install_docker-telemt.sh --auto -lang en
  ./install_docker-telemt.sh --lang en
  ./install_docker-telemt.sh --update -lang ru
  ./install_docker-telemt.sh --fix-nginx -lang ru

Options:
  -lang, --lang   Installer interface language: en or ru.
  -auto, --auto   Automatic mode: use defaults and confirm the plan
                  automatically. If no domain can be detected, it asks only
                  for the proxy domain. Domain is read from DOMAIN, saved
                  config, or FQDN hostname first.
  -update, --update
                  Analyze the current install, choose an exact compatible
                  Telemt version, update the Docker image, and recreate the
                  container; on Ubuntu also validate host nginx/OpenSSL.
                  Preserve telemt.toml, docker-compose.yml, secrets, links,
                  and nginx configs.
  -fix, --fix-nginx
                  Emergency nginx repair for unknown directive "http2"
                  and Docker doctor checks. Secrets, certificates, and
                  users are preserved; telemt.toml is edited only for
                  compatibility when it prevents startup.
  -h, --help      Show this help.

Variables:
  RESET_INSTALL_STATE=1
                  Fresh install: do not load old saved input; remove the old
                  Telemt secret/config/compose/container.
  TELEMT_NGINX_OPENSSL_MODE=auto|required|off
                  Ubuntu only: validate the real host nginx and build the
                  isolated nginx/OpenSSL 3.5.7 stack if needed. Default: auto.
EOF
}

parse_args() {
  local value
  local show_help=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -lang|--lang)
        shift
        [ "$#" -gt 0 ] || die "Missing value for -lang. Use ru or en."
        value="$1"
        SCRIPT_LANG="$(normalize_script_lang "$value")" || die "Bad language: $value. Use ru or en."
        SCRIPT_LANG_FROM_CLI="1"
        ;;
      -lang=*|--lang=*)
        value="${1#*=}"
        SCRIPT_LANG="$(normalize_script_lang "$value")" || die "Bad language: $value. Use ru or en."
        SCRIPT_LANG_FROM_CLI="1"
        ;;
      -h|--help)
        show_help=1
        ;;
      -auto|--auto|auto|--assume-yes|--yes|-y)
        AUTO_MODE="1"
        ASSUME_YES="1"
        ;;
      -update|--update|update)
        UPDATE_MODE="1"
        ;;
      -fix|--fix|--fix-nginx|--fix-http2|fix)
        FIX_NGINX_MODE="1"
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done
  if [ "$show_help" = "1" ]; then
    usage
    exit 0
  fi
}

have() {
  command -v "$1" >/dev/null 2>&1
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    if is_ru; then
      die "Запустите от root."
    else
      die "Run as root."
    fi
  fi
}

require_supported_os() {
  local os_id version_id pretty major

  [ -r "$OS_RELEASE_FILE" ] || die "Cannot detect OS: $OS_RELEASE_FILE not found."
  # shellcheck disable=SC1091
  source "$OS_RELEASE_FILE"
  os_id="$(lower "${ID:-}")"
  version_id="${VERSION_ID:-}"
  pretty="${PRETTY_NAME:-$os_id $version_id}"
  DETECTED_OS_ID="$os_id"
  DETECTED_OS_VERSION_ID="$version_id"

  case "$os_id" in
    debian)
      major="${version_id%%.*}"
      if ! [[ "$major" =~ ^[0-9]+$ ]]; then
        if is_ru; then
          die "Не удалось определить версию Debian ($pretty). Используйте Debian 13.x."
        else
          die "Cannot detect Debian version ($pretty). Use Debian 13.x."
        fi
      fi
      if [ "$major" != "13" ]; then
        if is_ru; then
          die "Неподдерживаемая ОС: $pretty. Docker-установщик Telemt поддерживает только Debian 13.x."
        else
          die "Unsupported OS: $pretty. The Telemt Docker installer supports Debian 13.x only."
        fi
      fi
      ;;
    ubuntu)
      major="${version_id%%.*}"
      if ! [[ "$major" =~ ^[0-9]+$ ]]; then
        if is_ru; then
          die "Не удалось определить версию Ubuntu ($pretty). Используйте Ubuntu 24.x-26.x."
        else
          die "Cannot detect Ubuntu version ($pretty). Use Ubuntu 24.x-26.x."
        fi
      fi
      if [ "$major" -lt 24 ] || [ "$major" -gt 26 ]; then
        if is_ru; then
          die "Неподдерживаемая ОС: $pretty. Docker-установщик Telemt поддерживает Ubuntu 24.x-26.x."
        else
          die "Unsupported OS: $pretty. The Telemt Docker installer supports Ubuntu 24.x-26.x."
        fi
      fi
      ;;
    *)
      if is_ru; then
        die "Неподдерживаемая ОС: $pretty. Используйте Debian 13.x или Ubuntu 24.x-26.x."
      else
        die "Unsupported OS: $pretty. Use Debian 13.x or Ubuntu 24.x-26.x."
      fi
      ;;
  esac
}

run_fix_nginx_mode() {
  local backup_dir changed file doctor_failed canonical_stream keep_stream
  local -a stream_files
  doctor_failed=0
  have nginx || die "nginx is not installed."
  backup_dir="/root/telemt-docker-nginx-fix-backups/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$backup_dir"

  if is_ru; then
    say "Режим fix: чиню nginx-конфиги и проверяю Docker/Telemt. Секреты и сертификаты не перезаписываю; telemt.toml правлю только для совместимости."
    say "Бэкап измененных файлов: $backup_dir"
  else
    say "Fix mode: repairing nginx configs and checking Docker/Telemt. Secrets and certificates are not rewritten; telemt.toml is edited only for compatibility."
    say "Changed-file backup: $backup_dir"
  fi

  say
  say "nginx -t before fix:"
  nginx -t 2>&1 || true
  ensure_ubuntu_nginx_openssl35

  changed=0
  while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue
    if grep -Eq '^[[:space:]]*http2[[:space:]]+on[[:space:]]*;|^[[:space:]]*listen[[:space:]][^;]*[[:space:]]http2([[:space:]]|;)' "$file"; then
      install -d -m 0700 "$backup_dir$(dirname "$file")"
      cp -a "$file" "$backup_dir$file"
      sed -i \
        -e '/^[[:space:]]*http2[[:space:]][[:space:]]*on[[:space:]]*;/d' \
        -e 's/[[:space:]]http2[[:space:]]*;/;/' \
        -e 's/[[:space:]]http2[[:space:]][[:space:]]*/ /g' \
        "$file"
      say "fixed: $file"
      changed=1
    fi
  done < <(find /etc/nginx -type f \( -name '*.conf' -o -path '/etc/nginx/sites-available/*' -o -path '/etc/nginx/sites-enabled/*' -o -path '/etc/nginx/modules-enabled/*' \) -print0 2>/dev/null)

  canonical_stream="/etc/nginx/modules-enabled/60-telemt-stream-sni.conf"
  keep_stream=""
  stream_files=()
  while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue
    if grep -Eq '^[[:space:]]*stream[[:space:]]*\{' "$file"; then
      stream_files+=("$file")
      [ -z "$keep_stream" ] && keep_stream="$file"
    fi
  done < <(find /etc/nginx -type f \( -name '*.conf' -o -path '/etc/nginx/sites-available/*' -o -path '/etc/nginx/sites-enabled/*' -o -path '/etc/nginx/modules-enabled/*' \) -print0 2>/dev/null)

  if [ "${#stream_files[@]}" -gt 1 ]; then
    if [ -f "$canonical_stream" ] && grep -Eq '^[[:space:]]*stream[[:space:]]*\{' "$canonical_stream"; then
      keep_stream="$canonical_stream"
    fi
    say "Found duplicate nginx stream blocks. Keeping: $keep_stream"
    for file in "${stream_files[@]}"; do
      [ "$file" = "$keep_stream" ] && continue
      if [ "$file" = "/etc/nginx/nginx.conf" ]; then
        say "WARN: duplicate stream block is inside /etc/nginx/nginx.conf; not disabling it automatically"
        doctor_failed=1
        continue
      fi
      install -d -m 0700 "$backup_dir$(dirname "$file")"
      cp -a "$file" "$backup_dir$file"
      rm -f "$file"
      say "disabled duplicate stream file: $file"
      changed=1
    done
  fi

  if [ -z "${DOMAIN:-}" ]; then
    infer_update_config_from_existing_files || true
  fi
  if [ -n "${DOMAIN:-}" ]; then
    for file in \
      "/var/www/$DOMAIN/index.html" \
      "/etc/nginx/sites-available/telemt-mask-${DOMAIN}.conf" \
      "/etc/nginx/sites-enabled/telemt-mask-${DOMAIN}.conf" \
      "/etc/nginx/sites-available/$DOMAIN" \
      "/etc/nginx/sites-enabled/$DOMAIN"
    do
      if [ -e "$file" ] || [ -L "$file" ]; then
        install -d -m 0700 "$backup_dir$(dirname "$file")"
        cp -a "$file" "$backup_dir$file"
      fi
    done
    write_mask_site_index
    if [ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ] && [ -f "/etc/letsencrypt/live/${DOMAIN}/privkey.pem" ]; then
      write_nginx_mask_site_config
      say "refreshed mask site placeholder and local HTTPS mask server: /var/www/$DOMAIN/index.html"
    else
      say "refreshed mask site placeholder only: /var/www/$DOMAIN/index.html"
      say "WARN: Let's Encrypt certificate was not found; local HTTPS mask server config was not rewritten"
    fi
    changed=1
  else
    say "WARN: cannot refresh mask site placeholder: domain was not detected"
  fi

  if [ -f "$INSTALL_DIR/telemt.toml" ] && grep -q '^\[censorship\.exclusive_mask\]' "$INSTALL_DIR/telemt.toml"; then
    install -d -m 0700 "$backup_dir$INSTALL_DIR"
    cp -a "$INSTALL_DIR/telemt.toml" "$backup_dir$INSTALL_DIR/telemt.toml"
    awk '
      /^\[censorship\.exclusive_mask\]/ {skip=1; next}
      /^\[/ && skip {skip=0}
      !skip {print}
    ' "$INSTALL_DIR/telemt.toml" > "$INSTALL_DIR/telemt.toml.tmp"
    mv "$INSTALL_DIR/telemt.toml.tmp" "$INSTALL_DIR/telemt.toml"
    chown 65532:65532 "$INSTALL_DIR/telemt.toml" 2>/dev/null || true
    chmod 600 "$INSTALL_DIR/telemt.toml"
    say "removed unsupported optional [censorship.exclusive_mask] block from $INSTALL_DIR/telemt.toml"
    changed=1
  fi

  if [ "$changed" = "0" ]; then
    if is_ru; then
      say "Несовместимых директив http2 не найдено."
    else
      say "No incompatible http2 directives were found."
    fi
  fi

  say
  say "nginx -t after fix:"
  if nginx -t; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    if is_ru; then
      say "nginx config валиден."
    else
      say "nginx config is valid."
    fi
  else
    if is_ru; then
      die "nginx все еще не проходит проверку. Смотри ошибку выше. Бэкап измененных файлов: $backup_dir"
    else
      die "nginx still fails validation. See the error above. Changed-file backup: $backup_dir"
    fi
  fi

  say
  if is_ru; then
    say "Проверяю остальной стек Telemt без перезаписи секретов и полной перегенерации конфигов."
  else
    say "Checking the rest of the Telemt stack without rewriting secrets or fully regenerating configs."
  fi

  if have systemctl && systemctl list-unit-files docker.service >/dev/null 2>&1; then
    if systemctl enable --now docker >/dev/null 2>&1; then
      say "OK: docker.service active/enabled"
    else
      say "WARN: docker.service could not be started"
      doctor_failed=1
    fi
  fi

  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    if ! ensure_compose_available; then
      say "WARN: Docker Compose is not available"
      doctor_failed=1
    fi
    if (cd "$INSTALL_DIR" && compose_cmd config >/dev/null); then
      say "OK: docker compose config"
      if start_telemt; then
        say "OK: Telemt container recreated/started from existing compose"
      else
        say "WARN: failed to recreate/start Telemt container from $INSTALL_DIR/docker-compose.yml"
        doctor_failed=1
      fi
    else
      say "WARN: docker compose config failed in $INSTALL_DIR"
      doctor_failed=1
    fi
  else
    say "INFO: $INSTALL_DIR/docker-compose.yml not found, skipping compose check"
  fi

  if [ -f "$INSTALL_DIR/telemt.toml" ]; then
    chmod 600 "$INSTALL_DIR/telemt.toml" 2>/dev/null || true
    chown 65532:65532 "$INSTALL_DIR/telemt.toml" 2>/dev/null || true
    if [ -s "$INSTALL_DIR/telemt.toml" ]; then
      say "OK: $INSTALL_DIR/telemt.toml exists"
    else
      say "WARN: $INSTALL_DIR/telemt.toml is empty"
      doctor_failed=1
    fi
  else
    say "INFO: $INSTALL_DIR/telemt.toml not found"
  fi

  if have curl && curl -fsS --max-time 3 http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then
    say "OK: Telemt local API responds on 127.0.0.1:9091"
  else
    say "WARN: Telemt local API did not respond on 127.0.0.1:9091"
    doctor_failed=1
  fi

  if have systemctl && systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    if systemctl is-active --quiet certbot.timer; then
      say "OK: certbot.timer active"
    else
      say "WARN: certbot.timer not active"
      doctor_failed=1
    fi
  fi

  if have ss; then
    say "Listening ports:"
    ss -lntp 2>/dev/null | grep -E ':(80|443|8443|1443|9091)[[:space:]]' || true
  fi

  if [ "$doctor_failed" = "0" ]; then
    if is_ru; then
      say "Готово: безопасный fix/doctor завершен."
    else
      say "Done: safe fix/doctor completed."
    fi
  else
    if is_ru; then
      die "fix/doctor нашел проблемы, которые нельзя безопасно исправить автоматически. Смотри WARN выше."
    else
      die "fix/doctor found issues that cannot be safely repaired automatically. See WARN lines above."
    fi
  fi
}

normalize_yes_no() {
  case "$(lower "$1")" in
    y|yes|д|да|true|1) printf 'yes' ;;
    n|no|н|нет|false|0|'') printf 'no' ;;
    *) return 1 ;;
  esac
}

ask_default() {
  local var="$1"
  local prompt="$2"
  local default="$3"
  local value
  if [ -n "${!var:-}" ]; then
    default="${!var}"
  fi
  if [ "$ASSUME_YES" = "1" ]; then
    printf -v "$var" '%s' "$default"
    return 0
  fi
  if [ -n "$default" ]; then
    read -r -p "$prompt [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$prompt: " value
  fi
  printf -v "$var" '%s' "$value"
}

ask_yes_no() {
  local var="$1"
  local prompt="$2"
  local default="$3"
  local value normalized
  if [ "$ASSUME_YES" = "1" ]; then
    if normalized="$(normalize_yes_no "$default")"; then
      printf -v "$var" '%s' "$normalized"
      return 0
    fi
  fi
  while true; do
    if is_ru; then
      read -r -p "$prompt yes/no/да/нет [$default]: " value
    else
      read -r -p "$prompt yes/no [$default]: " value
    fi
    value="${value:-$default}"
    if normalized="$(normalize_yes_no "$value")"; then
      printf -v "$var" '%s' "$normalized"
      return 0
    fi
    if is_ru; then
      say "Ответьте yes/no или да/нет."
    else
      say "Please answer yes or no."
    fi
  done
}

normalize_mask_site_mode() {
  case "$(lower "$1")" in
    fancy|pretty|beautiful|красивую|красивая|красиво|yes|y|да|д) printf 'fancy' ;;
    empty|blank|пустую|пустая|пусто|no|n|нет|н) printf 'empty' ;;
    *) return 1 ;;
  esac
}

normalize_client_mss() {
  local value
  value="$(lower "$1")"
  case "$value" in
    off|none|false|no|нет|0|'') printf 'off' ;;
    tspu|2in8|extreme-low) printf '%s' "$value" ;;
    *)
      if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 88 ] && [ "$value" -le 4096 ]; then
        printf '%s' "$value"
        return 0
      fi
      return 1
      ;;
  esac
}

toml_bool() {
  case "$(normalize_yes_no "$1" 2>/dev/null || true)" in
    yes) printf 'true' ;;
    no) printf 'false' ;;
    *) return 1 ;;
  esac
}

normalize_synlimit() {
  local value
  value="$(lower "$1")"
  case "$value" in
    off|none|false|no|нет|0|'') printf 'false' ;;
    iptables|nftables) printf '%s' "$value" ;;
    *) return 1 ;;
  esac
}

validate_synlimit_number() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] || die "Bad $name: $value"
}

ask_mask_site_mode() {
  local value normalized
  if [ "$ASSUME_YES" = "1" ]; then
    MASK_SITE_MODE="$(normalize_mask_site_mode "$MASK_SITE_MODE")"
    return 0
  fi
  while true; do
    if is_ru; then
      read -r -p "Маскировочная страница: fancy=красивая или empty=пустая [$MASK_SITE_MODE]: " value
    else
      read -r -p "Mask site page: fancy or empty [$MASK_SITE_MODE]: " value
    fi
    value="${value:-$MASK_SITE_MODE}"
    if normalized="$(normalize_mask_site_mode "$value")"; then
      MASK_SITE_MODE="$normalized"
      return 0
    fi
    if is_ru; then
      say "Ответьте fancy или empty."
    else
      say "Please answer fancy or empty."
    fi
  done
}

auto_domain_from_hostname() {
  local candidate lowered
  for candidate in "$(hostname -f 2>/dev/null || true)" "$(hostname 2>/dev/null || true)"; do
    candidate="${candidate%.}"
    lowered="$(lower "$candidate")"
    case "$lowered" in
      ""|localhost|localhost.localdomain|*.local)
        continue
        ;;
    esac
    if [[ "$candidate" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

fill_auto_defaults() {
  [ "$ASSUME_YES" = "1" ] || return 0

  if [ -z "$DOMAIN" ]; then
    DOMAIN="$(auto_domain_from_hostname || true)"
  fi

  if [ -z "$DOMAIN" ]; then
    if [ -t 0 ]; then
      if is_ru; then
        printf 'Домен прокси: '
      else
        printf 'Proxy domain: '
      fi
      if ! read -r DOMAIN; then
        DOMAIN=""
      fi
    else
      if is_ru; then
        die "Автоматический режим не смог определить домен. Запустите так: DOMAIN=proxy.example.com ./install_docker-telemt.sh --auto -lang ru"
      else
        die "Automatic mode cannot detect a domain. Run: DOMAIN=proxy.example.com ./install_docker-telemt.sh --auto -lang en"
      fi
    fi
  fi

  if [ -z "$DOMAIN" ]; then
    if is_ru; then
      die "Домен не указан. Запустите --auto еще раз и введите домен или передайте DOMAIN=proxy.example.com."
    else
      die "Domain is empty. Run --auto again and enter the domain or pass DOMAIN=proxy.example.com."
    fi
  fi

  if is_ru; then
    say "Автоматический режим: домен задан, остальные вопросы пропущены, используются значения по умолчанию."
  else
    say "Automatic mode: domain is set, all other prompts are skipped, defaults are used."
  fi
}

needs_idn_normalization() {
  local value="$1"
  case "$value" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-]*|*xn--*|*XN--*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_python3_for_idn() {
  if have python3; then
    return 0
  fi
  if ! have apt-get; then
    die "python3 is required for IDN/punycode domain normalization."
  fi
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3-minimal
  have python3 || die "python3 is required for IDN/punycode domain normalization."
}

domain_to_ascii() {
  local value="$1"
  ensure_python3_for_idn
  python3 - "$value" <<'PY'
import sys

domain = sys.argv[1].strip().rstrip(".").lower()
if not domain:
    print("empty domain", file=sys.stderr)
    sys.exit(1)
if any(ch.isspace() or ch in "/\\" for ch in domain):
    print("domain contains whitespace, slash, or backslash", file=sys.stderr)
    sys.exit(1)
try:
    ascii_domain = domain.encode("idna").decode("ascii").lower()
    decoded = ascii_domain.encode("ascii").decode("idna")
    roundtrip = decoded.encode("idna").decode("ascii").lower()
except Exception as exc:
    print(f"IDNA/punycode conversion failed: {exc}", file=sys.stderr)
    sys.exit(1)
if ascii_domain != roundtrip:
    print("IDNA/punycode round-trip check failed", file=sys.stderr)
    sys.exit(1)
labels = ascii_domain.split(".")
if len(labels) < 2 or any(not label for label in labels):
    print("domain must contain at least two non-empty labels", file=sys.stderr)
    sys.exit(1)
if any(len(label) > 63 for label in labels) or len(ascii_domain) > 253:
    print("domain is too long after IDNA conversion", file=sys.stderr)
    sys.exit(1)
for label in labels:
    if label.startswith("-") or label.endswith("-"):
        print("domain label starts or ends with '-'", file=sys.stderr)
        sys.exit(1)
    if not all(ch.isalnum() or ch == "-" for ch in label):
        print("domain contains invalid ASCII characters after IDNA conversion", file=sys.stderr)
        sys.exit(1)
print(ascii_domain)
PY
}

normalize_domain_input() {
  local original="$DOMAIN"
  DOMAIN="$(printf '%s' "$DOMAIN" | tr '[:upper:]' '[:lower:]')"
  DOMAIN="${DOMAIN%.}"
  if needs_idn_normalization "$DOMAIN"; then
    DOMAIN="$(domain_to_ascii "$DOMAIN")" || die "Bad domain: $original"
  fi
  if [ "$DOMAIN" != "$original" ]; then
    if is_ru; then
      say "Домен нормализован в punycode/ASCII: $original -> $DOMAIN"
    else
      say "Domain normalized to punycode/ASCII: $original -> $DOMAIN"
    fi
  fi
}

normalize_email_input() {
  local local_part domain_part ascii_domain original="$EMAIL"
  local_part="${EMAIL%@*}"
  domain_part="${EMAIL#*@}"
  [ "$local_part" != "$EMAIL" ] || die "Bad email: $EMAIL"
  [ -n "$local_part" ] || die "Bad email: $EMAIL"
  [[ "$local_part" =~ ^[A-Za-z0-9._%+-]+$ ]] || die "Bad email local part: $EMAIL"
  domain_part="$(printf '%s' "$domain_part" | tr '[:upper:]' '[:lower:]')"
  domain_part="${domain_part%.}"
  if needs_idn_normalization "$domain_part"; then
    ascii_domain="$(domain_to_ascii "$domain_part")" || die "Bad email domain: $original"
  else
    ascii_domain="$domain_part"
  fi
  EMAIL="${local_part}@${ascii_domain}"
  if [ "$EMAIL" != "$original" ]; then
    if is_ru; then
      say "Email нормализован в punycode/ASCII: $original -> $EMAIL"
    else
      say "Email normalized to punycode/ASCII: $original -> $EMAIL"
    fi
  fi
}

append_telemt_user() {
  local user="$1"
  [ -n "$user" ] || return 0
  if [ -z "$TELEMT_USERS" ]; then
    TELEMT_USERS="$user"
    return 0
  fi
  case ",$TELEMT_USERS," in
    *",$user,"*) ;;
    *) TELEMT_USERS="${TELEMT_USERS},${user}" ;;
  esac
}

telemt_users_list() {
  printf '%s\n' "${TELEMT_USERS:-$TELEMT_USER}" | tr ',' '\n' | awk 'NF {print}'
}

telemt_users_toml_array() {
  local first=1
  local user
  printf '['
  while IFS= read -r user; do
    [ -n "$user" ] || continue
    if [ "$first" = "1" ]; then
      first=0
    else
      printf ', '
    fi
    printf '"%s"' "$user"
  done < <(telemt_users_list)
  printf ']'
}

normalize_telemt_users() {
  local normalized=""
  local first=""
  local user

  TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
  TELEMT_USERS="$(printf '%s' "$TELEMT_USERS" | tr ' ' ',')"
  while IFS= read -r user; do
    user="$(printf '%s' "$user" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -n "$user" ] || continue
    [[ "$user" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "Bad Telemt user name: $user"
    case ",$normalized," in
      *",$user,"*) ;;
      *)
        [ -n "$first" ] || first="$user"
        if [ -z "$normalized" ]; then
          normalized="$user"
        else
          normalized="${normalized},${user}"
        fi
        ;;
    esac
  done < <(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n')

  [ -n "$normalized" ] || die "At least one Telemt user is required."
  TELEMT_USERS="$normalized"
  TELEMT_USER="$first"
  TELEMT_LINK_COUNT="$(telemt_users_list | wc -l | tr -d ' ')"
}

validate_inputs() {
  [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] || die "Bad domain: $DOMAIN"
  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Bad email: $EMAIL"
  normalize_telemt_users
  [[ "$TELEMT_LINK_COUNT" =~ ^[0-9]+$ ]] || die "Bad Telemt link count: $TELEMT_LINK_COUNT"
  [ "$TELEMT_LINK_COUNT" -ge 1 ] && [ "$TELEMT_LINK_COUNT" -le 100 ] || die "Telemt link count must be between 1 and 100."
  [[ "$TELEMT_MAX_TCP_CONNS" =~ ^[0-9]+$ ]] || die "Bad connection limit: $TELEMT_MAX_TCP_CONNS"
  normalize_client_mss "$TELEMT_CLIENT_MSS" >/dev/null || die "Bad TELEMT_CLIENT_MSS: use off, tspu, 2in8, extreme-low, or 88..4096."
  normalize_client_mss "$TELEMT_CLIENT_MSS_BULK" >/dev/null || die "Bad TELEMT_CLIENT_MSS_BULK: use off, tspu, 2in8, extreme-low, or 88..4096."
  normalize_synlimit "$TELEMT_SYNLIMIT" >/dev/null || die "Bad TELEMT_SYNLIMIT: use false, iptables, or nftables."
  validate_synlimit_number TELEMT_SYNLIMIT_SECONDS "$TELEMT_SYNLIMIT_SECONDS"
  validate_synlimit_number TELEMT_SYNLIMIT_HITCOUNT "$TELEMT_SYNLIMIT_HITCOUNT"
  validate_synlimit_number TELEMT_SYNLIMIT_BURST "$TELEMT_SYNLIMIT_BURST"
  validate_synlimit_number TELEMT_SYNLIMIT_IOS_SECONDS "$TELEMT_SYNLIMIT_IOS_SECONDS"
  validate_synlimit_number TELEMT_SYNLIMIT_IOS_HITCOUNT "$TELEMT_SYNLIMIT_IOS_HITCOUNT"
  validate_synlimit_number TELEMT_SYNLIMIT_IOS_BURST "$TELEMT_SYNLIMIT_IOS_BURST"
  validate_synlimit_number TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS"
  validate_synlimit_number TELEMT_SYNLIMIT_HASHLIMIT_SIZE "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE"
  [[ "$TELEMT_IMAGE" =~ ^[A-Za-z0-9._/:@+-]+$ ]] || die "Bad Docker image: $TELEMT_IMAGE"
  [[ "$TELEMT_VERSION" =~ ^[A-Za-z0-9._/@:+-]+$ ]] || die "Bad Telemt version: $TELEMT_VERSION"
  if [ -n "$AD_TAG" ]; then
    [[ "$AD_TAG" =~ ^[A-Fa-f0-9]{32}$ ]] || die "ad_tag must be 32 hex chars."
  fi
  normalize_yes_no "$USE_MIDDLE_PROXY" >/dev/null || die "Bad USE_MIDDLE_PROXY"
  normalize_yes_no "$ENABLE_LOGS" >/dev/null || die "Bad ENABLE_LOGS"
  normalize_yes_no "$ENABLE_DOCKER_HARDENING" >/dev/null || die "Bad ENABLE_DOCKER_HARDENING"
  normalize_yes_no "$ENABLE_HIGH_LOAD_TUNING" >/dev/null || die "Bad ENABLE_HIGH_LOAD_TUNING"
  normalize_yes_no "$AUTO_BUILD_IMAGE" >/dev/null || die "Bad AUTO_BUILD_IMAGE"
  normalize_mask_site_mode "$MASK_SITE_MODE" >/dev/null || die "Bad MASK_SITE_MODE"
  normalize_script_lang "$SCRIPT_LANG" >/dev/null || die "Bad SCRIPT_LANG"
  USE_MIDDLE_PROXY="$(normalize_yes_no "$USE_MIDDLE_PROXY")"
  ENABLE_LOGS="$(normalize_yes_no "$ENABLE_LOGS")"
  ENABLE_DOCKER_HARDENING="$(normalize_yes_no "$ENABLE_DOCKER_HARDENING")"
  ENABLE_HIGH_LOAD_TUNING="$(normalize_yes_no "$ENABLE_HIGH_LOAD_TUNING")"
  AUTO_BUILD_IMAGE="$(normalize_yes_no "$AUTO_BUILD_IMAGE")"
  MASK_SITE_MODE="$(normalize_mask_site_mode "$MASK_SITE_MODE")"
  TELEMT_CLIENT_MSS="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  TELEMT_CLIENT_MSS_BULK="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")"
  TELEMT_SYNLIMIT="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
  SCRIPT_LANG="$(normalize_script_lang "$SCRIPT_LANG")"
}

save_config() {
  umask 077
  cat > "$SAVED_CONFIG" <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
EMAIL=$(printf '%q' "$EMAIL")
TELEMT_IMAGE=$(printf '%q' "$TELEMT_IMAGE")
TELEMT_VERSION=$(printf '%q' "$TELEMT_VERSION")
TELEMT_USER=$(printf '%q' "$TELEMT_USER")
TELEMT_USERS=$(printf '%q' "$TELEMT_USERS")
TELEMT_LINK_COUNT=$(printf '%q' "$TELEMT_LINK_COUNT")
TELEMT_MAX_TCP_CONNS=$(printf '%q' "$TELEMT_MAX_TCP_CONNS")
TELEMT_CLIENT_MSS=$(printf '%q' "$TELEMT_CLIENT_MSS")
TELEMT_CLIENT_MSS_BULK=$(printf '%q' "$TELEMT_CLIENT_MSS_BULK")
TELEMT_SYNLIMIT=$(printf '%q' "$TELEMT_SYNLIMIT")
TELEMT_SYNLIMIT_SECONDS=$(printf '%q' "$TELEMT_SYNLIMIT_SECONDS")
TELEMT_SYNLIMIT_HITCOUNT=$(printf '%q' "$TELEMT_SYNLIMIT_HITCOUNT")
TELEMT_SYNLIMIT_BURST=$(printf '%q' "$TELEMT_SYNLIMIT_BURST")
TELEMT_SYNLIMIT_IOS_SECONDS=$(printf '%q' "$TELEMT_SYNLIMIT_IOS_SECONDS")
TELEMT_SYNLIMIT_IOS_HITCOUNT=$(printf '%q' "$TELEMT_SYNLIMIT_IOS_HITCOUNT")
TELEMT_SYNLIMIT_IOS_BURST=$(printf '%q' "$TELEMT_SYNLIMIT_IOS_BURST")
TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS=$(printf '%q' "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS")
TELEMT_SYNLIMIT_HASHLIMIT_SIZE=$(printf '%q' "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE")
AD_TAG=$(printf '%q' "$AD_TAG")
USE_MIDDLE_PROXY=$(printf '%q' "$USE_MIDDLE_PROXY")
ENABLE_LOGS=$(printf '%q' "$ENABLE_LOGS")
ENABLE_DOCKER_HARDENING=$(printf '%q' "$ENABLE_DOCKER_HARDENING")
ENABLE_HIGH_LOAD_TUNING=$(printf '%q' "$ENABLE_HIGH_LOAD_TUNING")
AUTO_BUILD_IMAGE=$(printf '%q' "$AUTO_BUILD_IMAGE")
MASK_SITE_MODE=$(printf '%q' "$MASK_SITE_MODE")
SCRIPT_LANG=$(printf '%q' "$SCRIPT_LANG")
EOF
}

load_config_if_exists() {
  if [ -f "$SAVED_CONFIG" ]; then
    if is_ru; then
      say "Найден сохраненный конфиг: $SAVED_CONFIG"
    else
      say "Resume config found: $SAVED_CONFIG"
    fi
    # shellcheck disable=SC1090
    source "$SAVED_CONFIG"
  fi
}

step_done() {
  [ -f "$STATE_FILE" ] && grep -Fxq "$1" "$STATE_FILE"
}

install_in_progress() {
  [ -f "$STATE_FILE" ] || return 1
  step_done complete && return 1
  if ! step_done cert || ! step_done config; then
    return 0
  fi
  if have docker && ! docker inspect -f '{{.State.Running}}' telemt 2>/dev/null | grep -Fxq true; then
    return 0
  fi
  return 1
}

mark_done() {
  install -d -m 0700 "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  grep -Fxq "$1" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$1" >> "$STATE_FILE"
}

reset_resume_state_if_requested() {
  [ "${RESET_INSTALL_STATE:-0}" = "1" ] || return 0
  rm -f "$STATE_FILE"
  if is_ru; then
    say "RESET_INSTALL_STATE=1: состояние resume сброшено, все шаги установки будут выполнены заново."
  else
    say "RESET_INSTALL_STATE=1: resume state was cleared, all install steps will run again."
  fi
}

saved_config_domain() {
  [ -f "$SAVED_CONFIG" ] || return 1
  (
    set +u
    # shellcheck disable=SC1090
    source "$SAVED_CONFIG"
    printf '%s\n' "${DOMAIN:-}"
  )
}

existing_domains_for_clean_install() {
  {
    saved_config_domain 2>/dev/null || true
    if [ -f "$INSTALL_DIR/telemt.toml" ]; then
      toml_value_from_section "$INSTALL_DIR/telemt.toml" "general\\.links" "public_host" 2>/dev/null || true
      toml_value_from_section "$INSTALL_DIR/telemt.toml" "censorship" "tls_domain" 2>/dev/null || true
    fi
  } | awk 'NF' | sort -u
}

safe_remove_install_dir() {
  if [ ! -d "$INSTALL_DIR" ]; then
    return 0
  fi

  case "$INSTALL_DIR" in
    /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/opt|/root|/sbin|/tmp|/usr|/var)
      say "WARN: refusing to remove suspicious INSTALL_DIR: $INSTALL_DIR"
      return 1
      ;;
  esac

  if [ -f "$INSTALL_DIR/docker-compose.yml" ] && grep -q 'container_name:[[:space:]]*telemt' "$INSTALL_DIR/docker-compose.yml"; then
    rm -rf -- "$INSTALL_DIR"
    return 0
  fi

  if [ "$INSTALL_DIR" = "/opt/telemt-docker" ]; then
    rm -rf -- "$INSTALL_DIR"
    return 0
  fi

  say "WARN: $INSTALL_DIR does not look like an installer-managed Telemt directory; keeping it"
  return 1
}

clean_install_reset_if_requested() {
  local domain backup_dir path

  [ "${RESET_INSTALL_STATE:-0}" = "1" ] || return 0
  CLEAN_INSTALL_MODE="1"

  backup_dir="/root/telemt-docker-reset-nginx-backups/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$backup_dir"

  if is_ru; then
    say "RESET_INSTALL_STATE=1: новая установка с нуля. Старый сохраненный ввод, proxy secret, compose/config и контейнер Telemt будут удалены."
    say "Чужие nginx-сайты не удаляются. Старые nginx-файлы Telemt будут удалены только если выглядят созданными этим установщиком."
  else
    say "RESET_INSTALL_STATE=1: clean install. Old saved input, proxy secret, compose/config, and the Telemt container will be removed."
    say "Non-Telemt nginx sites are not removed. Old Telemt nginx files are removed only when they look installer-managed."
  fi

  if have docker && docker inspect telemt >/dev/null 2>&1; then
    docker rm -f telemt >/dev/null 2>&1 || true
  fi

  while IFS= read -r domain; do
    [ -n "$domain" ] || continue
    for path in \
      "/etc/nginx/sites-enabled/telemt-mask-${domain}.conf" \
      "/etc/nginx/sites-available/telemt-mask-${domain}.conf" \
      "/etc/nginx/sites-enabled/${domain}" \
      "/etc/nginx/sites-available/${domain}"
    do
      if [ -e "$path" ] || [ -L "$path" ]; then
        install -d -m 0700 "$backup_dir$(dirname "$path")"
        cp -a "$path" "$backup_dir$path" 2>/dev/null || true
        if remove_file_if_telemt_managed "$path"; then
          say "removed old installer-managed nginx file: $path"
        else
          say "WARN: keeping non-Telemt nginx file: $path"
        fi
      fi
    done
  done < <(existing_domains_for_clean_install)

  path="/etc/nginx/modules-enabled/60-telemt-stream-sni.conf"
  if [ -e "$path" ] || [ -L "$path" ]; then
    install -d -m 0700 "$backup_dir$(dirname "$path")"
    cp -a "$path" "$backup_dir$path" 2>/dev/null || true
    rm -f "$path"
    say "removed old installer-managed nginx stream file: $path"
  fi

  safe_remove_install_dir || true
  rm -f "$STATE_FILE" "$SAVED_CONFIG" \
    /root/telemt-proxy-links.txt \
    /root/telemt-proxy-link.txt \
    /root/telemt-proxy-link-ip.txt \
    /root/telemt-active-probing-check.txt \
    /root/telemt-acme-http01-check.txt \
    /root/telemt-certbot-check.txt

  unset TELEMT_SECRET || true

  if have nginx; then
    if nginx -t >/dev/null 2>&1; then
      systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    else
      say "WARN: nginx is temporarily invalid after cleanup; continuing because install will write a fresh Telemt nginx config."
    fi
  fi
  return 0
}

write_file_root() {
  local path="$1"
  local mode="$2"
  local owner="$3"
  install -d -m 0755 "$(dirname "$path")"
  cat > "$path"
  chown "$owner" "$path"
  chmod "$mode" "$path"
}

local_ipv4s() {
  {
    ip -o -4 addr show 2>/dev/null | awk '{split($4, a, "/"); print a[1]}'
    hostname -I 2>/dev/null | tr ' ' '\n'
  } | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | sort -u
}

domain_local_ipv4() {
  local domain="${DOMAIN:-}" ip locals
  [ -n "$domain" ] || return 1
  locals="$(local_ipv4s || true)"
  [ -n "$locals" ] || return 1
  while IFS= read -r ip; do
    [ -n "$ip" ] || continue
    if grep -Fxq "$ip" <<< "$locals"; then
      printf '%s\n' "$ip"
      return 0
    fi
  done < <(domain_ipv4s "$domain" || true)
  return 1
}

public_ipv4() {
  local url ip
  ip="$(domain_local_ipv4 || true)"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "$ip"
    return 0
  fi
  for url in \
    https://api.ipify.org \
    https://ifconfig.me \
    https://icanhazip.com
  do
    ip="$(curl -4fsS --max-time 10 "$url" 2>/dev/null | tr -d '[:space:]' || true)"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  done
  return 1
}

domain_ipv4s() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

port_listeners() {
  local port="$1"
  ss -H -ltnp 2>/dev/null | awk -v p=":$port" '$4 ~ p "$" {print}'
}

docker_containers_for_public_port() {
  local port="$1"
  have docker || return 0
  docker ps --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}' 2>/dev/null |
    awk -F '\t' -v port="$port" '
      index($4, ":" port "->") > 0 || index($4, "[::]:" port "->") > 0 || index($4, ":::" port "->") > 0 {
        print
      }
    '
}

remove_docker_port_conflict_if_allowed() {
  local port="$1"
  local containers answer id name image ports listeners

  containers="$(docker_containers_for_public_port "$port" || true)"
  [ -n "$containers" ] || return 1

  if is_ru; then
    say "Порт ${port}/tcp уже занят Docker-контейнером:"
    printf '  %-14s %-24s %-32s %s\n' "ID" "NAME" "IMAGE" "PORTS"
  else
    say "Port ${port}/tcp is already used by a Docker container:"
    printf '  %-14s %-24s %-32s %s\n' "ID" "NAME" "IMAGE" "PORTS"
  fi
  while IFS=$'\t' read -r id name image ports; do
    [ -n "$id" ] || continue
    printf '  %-14s %-24s %-32s %s\n' "$id" "$name" "$image" "$ports"
  done <<< "$containers"

  if is_ru; then
    ask_yes_no answer "Удалить эти Docker-контейнеры и продолжить установку Telemt" "no"
  else
    ask_yes_no answer "Remove these Docker containers and continue Telemt installation" "no"
  fi
  [ "$answer" = "yes" ] || return 1

  while IFS=$'\t' read -r id name image ports; do
    [ -n "$id" ] || continue
    if is_ru; then
      say "Удаляю Docker-контейнер: ${name} (${id}, ${image})"
    else
      say "Removing Docker container: ${name} (${id}, ${image})"
    fi
    docker rm -f "$id" >/dev/null || die "Failed to remove Docker container: ${name} (${id})"
  done <<< "$containers"

  sleep 1
  listeners="$(port_listeners "$port" || true)"
  if [ -n "$listeners" ] && ! grep -q 'nginx' <<< "$listeners"; then
    printf '%s\n' "$listeners"
    if is_ru; then
      die "Порт ${port}/tcp все еще занят после удаления Docker-контейнера."
    else
      die "Port ${port}/tcp is still busy after removing Docker container."
    fi
  fi
  return 0
}

check_port_clean_or_nginx() {
  local port="$1"
  local listeners
  listeners="$(port_listeners "$port" || true)"
  [ -z "$listeners" ] && return 0
  if grep -q 'nginx' <<< "$listeners"; then
    return 0
  fi
  printf '%s\n' "$listeners"
  if grep -q 'docker-proxy' <<< "$listeners" && ! have docker; then
    if is_ru; then
      say "Порт ${port}/tcp держит docker-proxy, но Docker CLI не найден. Сначала установлю/починю Docker CLI, чтобы показать контейнер и спросить про удаление."
    else
      say "Port ${port}/tcp is held by docker-proxy, but Docker CLI was not found. Installing/repairing Docker CLI first so the container can be shown and removal can be confirmed."
    fi
    ensure_docker_available
  fi
  if remove_docker_port_conflict_if_allowed "$port"; then
    return 0
  fi
  if is_ru; then
    die "Порт ${port}/tcp занят не nginx-процессом. Освободите порт или установите Telemt на чистый сервер."
  fi
  die "Port $port/tcp is already in use by a non-nginx process. Use a clean server or free the port first."
}

nginx_mask_site_available_path() {
  printf '/etc/nginx/sites-available/telemt-mask-%s.conf' "$DOMAIN"
}

nginx_mask_site_enabled_path() {
  printf '/etc/nginx/sites-enabled/telemt-mask-%s.conf' "$DOMAIN"
}

nginx_file_is_telemt_managed() {
  local file="$1"
  [ -f "$file" ] || return 1
  grep -Eq 'Managed by install_docker-telemt\.sh|Telemt Docker installer|telemt_backend|127\.0\.0\.1:8443|127\.0\.0\.1:1443' "$file"
}

nginx_file_has_server_name() {
  local file="$1"
  local domain="$2"
  [ -f "$file" ] || return 1
  awk -v domain="$domain" '
    {
      line=$0
      sub(/#.*/, "", line)
      gsub(/;/, " ", line)
      n=split(line, fields, /[[:space:]]+/)
      for (i = 1; i <= n; i++) {
        if (fields[i] == "server_name") {
          for (j = i + 1; j <= n; j++) {
            if (fields[j] == domain) {
              found=1
            }
          }
        }
      }
    }
    END { exit found ? 0 : 1 }
  ' "$file"
}

remove_file_if_telemt_managed() {
  local file="$1"
  local target=""

  if [ -L "$file" ]; then
    target="$(readlink -f "$file" 2>/dev/null || true)"
    if [ -z "$target" ] || [ ! -e "$target" ] || nginx_file_is_telemt_managed "$target"; then
      rm -f "$file"
      return 0
    fi
    return 1
  fi

  if nginx_file_is_telemt_managed "$file"; then
    rm -f "$file"
    return 0
  fi

  return 1
}

remove_legacy_nginx_domain_config_if_safe() {
  local domain="$1"
  local path

  for path in "/etc/nginx/sites-enabled/$domain" "/etc/nginx/sites-available/$domain"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      if remove_file_if_telemt_managed "$path"; then
        say "removed old installer-managed nginx file: $path"
      else
        say "WARN: keeping non-Telemt nginx file: $path"
      fi
    fi
  done
}

ensure_nginx_domain_not_owned_elsewhere() {
  local file target legacy_available legacy_enabled
  target="$(nginx_mask_site_available_path)"
  legacy_available="/etc/nginx/sites-available/$DOMAIN"
  legacy_enabled="/etc/nginx/sites-enabled/$DOMAIN"

  if [ -e "$target" ] && ! nginx_file_is_telemt_managed "$target"; then
    if is_ru; then
      die "Файл $target уже существует и не похож на конфиг Telemt. Установщик не будет его перезаписывать."
    else
      die "$target already exists and does not look like a Telemt config. The installer will not overwrite it."
    fi
  fi

  remove_legacy_nginx_domain_config_if_safe "$DOMAIN"

  while IFS= read -r -d '' file; do
    [ -f "$file" ] || continue
    [ "$file" = "$target" ] && continue
    [ "$file" = "$legacy_available" ] && continue
    [ "$file" = "$legacy_enabled" ] && continue
    if nginx_file_has_server_name "$file" "$DOMAIN" && ! nginx_file_is_telemt_managed "$file"; then
      if is_ru; then
        die "Домен $DOMAIN уже описан в чужом nginx-конфиге: $file. Установщик не будет его перезаписывать."
      else
        die "Domain $DOMAIN is already configured in a non-Telemt nginx file: $file. The installer will not overwrite it."
      fi
    fi
  done < <(find /etc/nginx -type f \( -name '*.conf' -o -path '/etc/nginx/sites-available/*' -o -path '/etc/nginx/sites-enabled/*' \) -print0 2>/dev/null)
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  elif have docker-compose; then
    docker-compose "$@"
  else
    die "Docker Compose is not installed."
  fi
}

apt_package_available() {
  local package="$1"
  apt-cache show "$package" >/dev/null 2>&1
}

apt_install_first_available() {
  local package

  for package in "$@"; do
    if apt_package_available "$package"; then
      DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$package"
      return 0
    fi
  done

  return 1
}

install_compose_v2_if_possible() {
  if docker compose version >/dev/null 2>&1; then
    return 0
  fi
  have apt-get || return 1

  if is_ru; then
    say "Docker Compose v2 не найден. Пытаюсь установить Compose v2; системный Python не трогаю."
  else
    say "Docker Compose v2 was not found. Trying to install Compose v2; system Python is not changed."
  fi

  apt-get update
  apt_install_first_available docker-compose-plugin docker-compose-v2 || return 1

  docker compose version >/dev/null 2>&1
}

ensure_compose_available() {
  local legacy_version

  if docker compose version >/dev/null 2>&1; then
    return 0
  fi

  if have docker-compose; then
    legacy_version="$(docker-compose version --short 2>/dev/null || docker-compose version 2>/dev/null | sed -n 's/.*version \([0-9][^, ]*\).*/\1/p' | head -n 1 || true)"
    case "$legacy_version" in
      1.*)
        if is_ru; then
          say "Найден старый docker-compose v1${legacy_version:+ ($legacy_version)}. Он может падать с KeyError: ContainerConfig."
        else
          say "Found old docker-compose v1${legacy_version:+ ($legacy_version)}. It can fail with KeyError: ContainerConfig."
        fi
        install_compose_v2_if_possible && return 0
        if is_ru; then
          say "WARN: не удалось поставить Compose v2 автоматически. Продолжаю через docker-compose v1 с обходом старого ContainerConfig bug."
        else
          say "WARN: automatic Compose v2 install failed. Continuing with docker-compose v1 and the old ContainerConfig bug workaround."
        fi
        return 0
        ;;
      *)
        return 0
        ;;
    esac
  fi

  install_compose_v2_if_possible && return 0

  if have apt-get; then
    apt-get update
    apt_install_first_available docker-compose || true
  fi

  docker compose version >/dev/null 2>&1 || have docker-compose || die "Docker Compose is not installed."
}

install_packages() {
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl openssl jq iproute2 python3-minimal nginx certbot docker.io

  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends libnginx-mod-stream || true
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-cli docker-buildx || true
  apt_install_first_available docker-compose-plugin docker-compose-v2 docker-compose ||
    die "Docker Compose package was not found in apt repositories."

  ensure_docker_available
  ensure_compose_available
  systemctl enable --now nginx || true
  systemctl enable --now certbot.timer 2>/dev/null || true
}

configure_system_ca_environment() {
  [ -s "$SYSTEM_CA_FILE" ] || die "System CA bundle is missing: $SYSTEM_CA_FILE"
  export SSL_CERT_FILE="$SYSTEM_CA_FILE"
  export CURL_CA_BUNDLE="$SYSTEM_CA_FILE"
  [ -d /etc/ssl/certs ] && export SSL_CERT_DIR=/etc/ssl/certs
}

version_ge() {
  local current="$1" required="$2"
  [ "$(printf '%s\n%s\n' "$required" "$current" | sort -V | head -n 1)" = "$required" ]
}

nginx_openssl_versions() {
  local nginx_bin="${1:-$(command -v nginx 2>/dev/null || true)}"
  [ -n "$nginx_bin" ] || return 1
  "$nginx_bin" -V 2>&1 | grep -oE 'OpenSSL [0-9]+\.[0-9]+\.[0-9]+' | awk '{print $2}' | sort -Vu
}

nginx_service_binary() {
  local service_exec
  service_exec="$(systemctl show nginx.service -p ExecStart --value 2>/dev/null || true)"
  printf '%s\n' "$service_exec" | grep -oE '/[^ ;]*nginx[^ ;]*' | head -n 1
}

nginx_stack_versions_at_least() {
  local required="$1" command_bin service_bin bin versions version
  command_bin="$(command -v nginx 2>/dev/null || true)"
  service_bin="$(nginx_service_binary || true)"
  [ -n "$command_bin" ] || return 1
  for bin in "$command_bin" "$service_bin"; do
    [ -n "$bin" ] || continue
    [ -x "$bin" ] || return 1
    versions="$(nginx_openssl_versions "$bin" || true)"
    [ -n "$versions" ] || return 1
    while IFS= read -r version; do
      [ -n "$version" ] || continue
      version_ge "$version" "$required" || return 1
    done <<< "$versions"
  done
}

nginx_has_compatible_openssl() {
  local nginx_bin="${1:-$(command -v nginx 2>/dev/null || true)}" output versions version service_bin
  [ -n "$nginx_bin" ] && [ -x "$nginx_bin" ] || return 1
  output="$("$nginx_bin" -V 2>&1 || true)"
  printf '%s\n' "$output" | grep -q -- '--with-stream' || return 1
  printf '%s\n' "$output" | grep -q -- '--with-stream_ssl_preread_module' || return 1
  versions="$(nginx_openssl_versions "$nginx_bin" || true)"
  [ -n "$versions" ] || return 1
  while IFS= read -r version; do
    [ -n "$version" ] || continue
    version_ge "$version" "$TELEMT_OPENSSL_MIN_VERSION" || return 1
  done <<< "$versions"

  service_bin="$(nginx_service_binary || true)"
  if [ -n "$service_bin" ] && [ "$service_bin" != "$nginx_bin" ]; then
    [ -x "$service_bin" ] || return 1
    versions="$(nginx_openssl_versions "$service_bin" || true)"
    [ -n "$versions" ] || return 1
    while IFS= read -r version; do
      [ -n "$version" ] || continue
      version_ge "$version" "$TELEMT_OPENSSL_MIN_VERSION" || return 1
    done <<< "$versions"
  fi
}

backup_nginx_path() {
  local path="$1" backup_root="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    install -d -m 0700 "$backup_root$(dirname "$path")"
    cp -a "$path" "$backup_root$path"
  fi
}

write_custom_nginx_config() {
  install -d -m 0755 \
    "$TELEMT_NGINX_PREFIX" /var/log/nginx /var/lib/nginx \
    /etc/nginx/conf.d /etc/nginx/sites-enabled /etc/nginx/modules-enabled
  write_file_root "$TELEMT_NGINX_CONF" 0644 root:root <<'EOF'
user www-data;
worker_processes auto;
pid /run/nginx.pid;
error_log /var/log/nginx/error.log;
worker_rlimit_nofile 65535;

events {
    worker_connections 8192;
    multi_accept on;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    server_tokens off;
    ssl_protocols TLSv1.2 TLSv1.3;
    access_log /var/log/nginx/access.log;
    gzip on;
    include /etc/nginx/conf.d/*.conf;
    include /etc/nginx/sites-enabled/*;
}

include /etc/nginx/modules-enabled/*telemt-stream-sni.conf;
EOF
}

install_custom_nginx_openssl35() {
  local build_dir openssl_archive nginx_archive openssl_src nginx_src build_jobs=1 backup_root
  build_dir="$(mktemp -d /tmp/telemt-nginx-openssl35.XXXXXX)"
  openssl_archive="$build_dir/openssl-${TELEMT_OPENSSL_BUILD_VERSION}.tar.gz"
  nginx_archive="$build_dir/nginx-${TELEMT_NGINX_BUILD_VERSION}.tar.gz"
  openssl_src="$build_dir/openssl-${TELEMT_OPENSSL_BUILD_VERSION}"
  nginx_src="$build_dir/nginx-${TELEMT_NGINX_BUILD_VERSION}"
  backup_root="/root/telemt-docker-nginx-openssl-backups/$(date +%Y%m%d-%H%M%S)"

  backup_nginx_path "$TELEMT_NGINX_BIN" "$backup_root"
  backup_nginx_path "$TELEMT_NGINX_CONF" "$backup_root"
  backup_nginx_path "$TELEMT_NGINX_DROPIN" "$backup_root"
  backup_nginx_path /usr/local/sbin/nginx "$backup_root"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends build-essential perl zlib1g-dev libpcre2-dev

  if [ -r /proc/meminfo ] && [ "$(awk '/MemTotal/{print $2}' /proc/meminfo)" -ge 1800000 ]; then
    build_jobs=2
  fi

  (
    trap 'rm -rf "$build_dir"' EXIT
    curl -fL --retry 3 --connect-timeout 20 \
      "https://github.com/openssl/openssl/releases/download/openssl-${TELEMT_OPENSSL_BUILD_VERSION}/openssl-${TELEMT_OPENSSL_BUILD_VERSION}.tar.gz" \
      -o "$openssl_archive"
    printf '%s  %s\n' "$TELEMT_OPENSSL_BUILD_SHA256" "$openssl_archive" | sha256sum -c -

    curl -fL --retry 3 --connect-timeout 20 \
      "https://nginx.org/download/nginx-${TELEMT_NGINX_BUILD_VERSION}.tar.gz" \
      -o "$nginx_archive"
    printf '%s  %s\n' "$TELEMT_NGINX_BUILD_SHA256" "$nginx_archive" | sha256sum -c -

    tar -xzf "$openssl_archive" -C "$build_dir"
    tar -xzf "$nginx_archive" -C "$build_dir"
    cd "$nginx_src"
    ./configure \
      --prefix="$TELEMT_NGINX_PREFIX" \
      --sbin-path="$TELEMT_NGINX_BIN" \
      --conf-path="$TELEMT_NGINX_CONF" \
      --pid-path=/run/nginx.pid \
      --lock-path=/run/lock/nginx.lock \
      --error-log-path=/var/log/nginx/error.log \
      --http-log-path=/var/log/nginx/access.log \
      --http-client-body-temp-path=/var/lib/nginx/body \
      --http-proxy-temp-path=/var/lib/nginx/proxy \
      --http-fastcgi-temp-path=/var/lib/nginx/fastcgi \
      --user=www-data \
      --group=www-data \
      --with-compat \
      --with-threads \
      --with-http_ssl_module \
      --with-http_v2_module \
      --with-http_realip_module \
      --with-http_gzip_static_module \
      --with-http_stub_status_module \
      --with-stream \
      --with-stream_ssl_preread_module \
      --with-pcre-jit \
      --with-openssl="$openssl_src" \
      --with-openssl-opt="no-shared no-tests --openssldir=$TELEMT_NGINX_PREFIX/ssl"
    make -j"$build_jobs"
    make install
  )

  write_custom_nginx_config
  install -d -m 0755 \
    /var/lib/nginx/body /var/lib/nginx/proxy /var/lib/nginx/fastcgi \
    "$(dirname "$TELEMT_NGINX_DROPIN")"
  ln -sfn "$TELEMT_NGINX_BIN" /usr/local/sbin/nginx
  hash -r

  write_file_root "$TELEMT_NGINX_DROPIN" 0644 root:root <<EOF
[Service]
ExecStartPre=
ExecStartPre=$TELEMT_NGINX_BIN -t -q -c $TELEMT_NGINX_CONF
ExecStart=
ExecStart=$TELEMT_NGINX_BIN -c $TELEMT_NGINX_CONF -g 'daemon on; master_process on;'
ExecReload=
ExecReload=$TELEMT_NGINX_BIN -c $TELEMT_NGINX_CONF -g 'daemon on; master_process on;' -s reload
EOF

  "$TELEMT_NGINX_BIN" -t -c "$TELEMT_NGINX_CONF"
  systemctl stop nginx 2>/dev/null || true
  systemctl daemon-reload
  systemctl enable nginx
  systemctl start nginx
  chmod -R go-rwx "$backup_root" 2>/dev/null || true
  say "Nginx/OpenSSL backup: $backup_root"
}

ensure_ubuntu_nginx_openssl35() {
  local current_versions side_version=""
  [ "$DETECTED_OS_ID" = "ubuntu" ] || return 0

  case "$TELEMT_NGINX_OPENSSL_MODE" in
    auto|required|off) ;;
    *) die "TELEMT_NGINX_OPENSSL_MODE must be auto, required, or off." ;;
  esac

  configure_system_ca_environment
  if [ -x /opt/openssl-3.5/bin/openssl ]; then
    side_version="$(/opt/openssl-3.5/bin/openssl version 2>/dev/null | awk '{print $2}' || true)"
    say "Detected side-by-side OpenSSL: ${side_version:-unknown}. It is not injected into apt, curl, Docker, or the system linker."
  fi

  if nginx_has_compatible_openssl; then
    current_versions="$(nginx_openssl_versions | tr '\n' ' ')"
    if nginx_stack_versions_at_least "$TELEMT_OPENSSL_BUILD_VERSION"; then
      say "Ubuntu host nginx already uses compatible OpenSSL: ${current_versions:-unknown}."
      return 0
    fi
    say "Ubuntu host nginx OpenSSL ${current_versions:-unknown} is older than security target $TELEMT_OPENSSL_BUILD_VERSION."
  fi

  if [ "$TELEMT_NGINX_OPENSSL_MODE" = "off" ]; then
    say "WARN: Ubuntu nginx OpenSSL compatibility build is disabled. The mask site may not support X25519MLKEM768."
    return 0
  fi

  say "Building Ubuntu host nginx $TELEMT_NGINX_BUILD_VERSION with isolated OpenSSL $TELEMT_OPENSSL_BUILD_VERSION."
  say "Telemt remains in Docker; system OpenSSL shared libraries are not replaced."
  install_custom_nginx_openssl35
  nginx_has_compatible_openssl "$TELEMT_NGINX_BIN" || die "Custom nginx OpenSSL verification failed."
}

host_nginx_tls_plan() {
  if [ "$DETECTED_OS_ID" = "ubuntu" ]; then
    printf 'Ubuntu host nginx >= OpenSSL %s; auto-build %s/%s' \
      "$TELEMT_OPENSSL_MIN_VERSION" "$TELEMT_NGINX_BUILD_VERSION" "$TELEMT_OPENSSL_BUILD_VERSION"
  else
    printf 'distribution nginx (Debian path unchanged)'
  fi
}

install_official_docker_packages() {
  local os_id os_codename docker_codename arch

  [ -r /etc/os-release ] || die "Cannot detect OS for Docker CLI fallback."
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="${ID:-}"
  os_codename="${VERSION_CODENAME:-}"

  case "$os_id" in
    debian|ubuntu) ;;
    *) die "Docker CLI is missing and automatic Docker CE fallback supports only Debian/Ubuntu." ;;
  esac

  if [ -z "$os_codename" ] && have lsb_release; then
    os_codename="$(lsb_release -cs)"
  fi
  [ -n "$os_codename" ] || die "Cannot detect Debian/Ubuntu codename for Docker CE fallback."

  docker_codename="$os_codename"
  if [ "$os_id" = "debian" ] && [ "$docker_codename" = "trixie" ]; then
    say "Docker CE repo for Debian trixie may be unavailable; using bookworm Docker repo for CLI fallback."
    docker_codename="bookworm"
  fi

  arch="$(dpkg --print-architecture)"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${os_id}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${os_id} ${docker_codename} stable
EOF
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

ensure_docker_available() {
  if have docker; then
    systemctl enable --now docker
    return 0
  fi

  say "Docker daemon package is installed, but Docker CLI is missing. Trying distro docker-cli package..."
  if have apt-get; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends docker-cli docker-buildx || true
  fi

  if ! have docker; then
    say "Docker CLI is still missing. Installing official Docker CE CLI packages..."
    install_official_docker_packages
  fi

  have docker || die "Docker CLI is still not available after installation."
  systemctl enable --now docker
  docker version >/dev/null
}

image_name_and_tag() {
  local image="$1"
  local last name tag

  if [[ "$image" == *@sha256:* ]]; then
    return 1
  fi

  last="${image##*/}"
  if [[ "$last" == *:* ]]; then
    name="${image%:*}"
    tag="${last##*:}"
  else
    name="$image"
    tag="$TELEMT_VERSION"
  fi

  [ -n "$tag" ] || tag="latest"
  printf '%s\n%s\n' "$name" "$tag"
}

is_exact_telemt_version() {
  local version="${1#refs/tags/}"
  version="${version#v}"
  [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

normalize_exact_telemt_version() {
  local version="${1#refs/tags/}"
  version="${version#v}"
  is_exact_telemt_version "$version" || return 1
  printf '%s' "$version"
}

version_from_image_ref() {
  local parsed tag
  parsed="$(image_name_and_tag "$1")" || return 1
  tag="$(printf '%s\n' "$parsed" | sed -n '2p')"
  normalize_exact_telemt_version "$tag"
}

image_ref_with_tag() {
  local image="$1" tag="$2" parsed name
  parsed="$(image_name_and_tag "$image")" || return 1
  name="$(printf '%s\n' "$parsed" | sed -n '1p')"
  printf '%s:%s' "$name" "$tag"
}

telemt_version_from_text() {
  sed -n 's/^telemt[[:space:]]\+v\{0,1\}\([0-9][0-9.]*\).*/\1/p' |
    sed -n '1p'
}

detect_running_telemt_version() {
  local output version
  have docker || return 1
  docker inspect telemt >/dev/null 2>&1 || return 1
  output="$(docker exec telemt /app/telemt --version 2>/dev/null || true)"
  version="$(printf '%s\n' "$output" | telemt_version_from_text)"
  if is_exact_telemt_version "$version"; then
    printf '%s' "$version"
    return 0
  fi
  return 1
}

detect_image_telemt_version() {
  local image="$1" output version
  [ -n "$image" ] || return 1
  have docker || return 1
  docker image inspect "$image" >/dev/null 2>&1 || return 1
  output="$(docker run --rm --entrypoint /app/telemt "$image" --version 2>/dev/null || true)"
  version="$(printf '%s\n' "$output" | telemt_version_from_text)"
  if is_exact_telemt_version "$version"; then
    printf '%s' "$version"
    return 0
  fi
  return 1
}

detect_current_telemt_version() {
  local existing_image saved_version saved_source version

  TELEMT_DETECTED_VERSION=""
  TELEMT_DETECTED_VERSION_SOURCE=""

  if version="$(detect_running_telemt_version)"; then
    TELEMT_DETECTED_VERSION="$version"
    TELEMT_DETECTED_VERSION_SOURCE="running container"
    return 0
  fi

  existing_image="$(compose_image_from_file "$INSTALL_DIR/docker-compose.yml" || true)"
  if [ -n "$existing_image" ] && version="$(detect_image_telemt_version "$existing_image")"; then
    TELEMT_DETECTED_VERSION="$version"
    TELEMT_DETECTED_VERSION_SOURCE="compose image binary"
    return 0
  fi

  if [ -n "$existing_image" ] && version="$(version_from_image_ref "$existing_image")"; then
    TELEMT_DETECTED_VERSION="$version"
    TELEMT_DETECTED_VERSION_SOURCE="compose image tag"
    return 0
  fi

  saved_version=""
  saved_source=""
  if [ "$TELEMT_VERSION_ENV_SET" = "1" ]; then
    saved_version="$TELEMT_VERSION_ENV_VALUE"
    saved_source="TELEMT_VERSION env"
  elif [ -f "$SAVED_CONFIG" ]; then
    saved_version="$(
      awk -F= '$1 == "TELEMT_VERSION" {
        value=substr($0, index($0, "=") + 1)
        gsub(/^'\''|'\''$/, "", value)
        gsub(/^"|"$/, "", value)
        print value
        exit
      }' "$SAVED_CONFIG" 2>/dev/null || true
    )"
    saved_source="saved installer config"
  fi

  if [ -n "$saved_version" ] && version="$(normalize_exact_telemt_version "$saved_version" 2>/dev/null)"; then
    TELEMT_DETECTED_VERSION="$version"
    TELEMT_DETECTED_VERSION_SOURCE="$saved_source"
    return 0
  fi

  return 1
}

resolve_update_target_version() {
  local requested version

  requested=""
  if [ "$TELEMT_VERSION_ENV_SET" = "1" ]; then
    requested="$TELEMT_VERSION_ENV_VALUE"
  fi

  if [ -n "$requested" ]; then
    if version="$(normalize_exact_telemt_version "$requested" 2>/dev/null)"; then
      TELEMT_UPDATE_TARGET_VERSION="$version"
      TELEMT_VERSION="$version"
      return 0
    fi
    if [ "$(lower "$requested")" = "latest" ]; then
      if is_ru; then
        say "WARN: TELEMT_VERSION=latest в --update не используется; беру проверенную совместимую версию $TELEMT_LATEST_COMPATIBLE_VERSION."
      else
        say "WARN: TELEMT_VERSION=latest is ignored in --update; using checked compatible version $TELEMT_LATEST_COMPATIBLE_VERSION."
      fi
    else
      die "Bad TELEMT_VERSION for --update: use an exact release tag like $TELEMT_LATEST_COMPATIBLE_VERSION, not '$requested'."
    fi
  fi

  TELEMT_UPDATE_TARGET_VERSION="$TELEMT_LATEST_COMPATIBLE_VERSION"
  TELEMT_VERSION="$TELEMT_UPDATE_TARGET_VERSION"
  is_exact_telemt_version "$TELEMT_UPDATE_TARGET_VERSION" ||
    die "Bad TELEMT_LATEST_COMPATIBLE_VERSION: $TELEMT_UPDATE_TARGET_VERSION"
}

resolve_update_image_ref() {
  local image="$1" target="$2"
  image_ref_with_tag "$image" "$target"
}

build_local_image() {
  local script_dir build_script parsed image_name image_tag upstream_version
  script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
  build_script="${BUILD_SCRIPT:-$script_dir/build.sh}"

  [ -f "$build_script" ] || die "Cannot auto-build Docker image: build.sh is not found near install_docker-telemt.sh."
  chmod +x "$build_script"

  parsed="$(image_name_and_tag "$TELEMT_IMAGE")" || die "Cannot auto-build digest-pinned image: $TELEMT_IMAGE"
  image_name="$(printf '%s\n' "$parsed" | sed -n '1p')"
  image_tag="$(printf '%s\n' "$parsed" | sed -n '2p')"
  upstream_version="${TELEMT_BUILD_VERSION:-$TELEMT_VERSION}"
  if [ "$upstream_version" = "latest" ] && [ "$image_tag" = "latest" ]; then
    upstream_version="$TELEMT_DEFAULT_VERSION"
  elif [ "$upstream_version" = "$TELEMT_DEFAULT_VERSION" ] && is_exact_telemt_version "$image_tag"; then
    upstream_version="$image_tag"
  fi

  say "Building Telemt Docker image automatically:"
  say "  image:   ${image_name}:${image_tag}"
  say "  version: ${upstream_version}"
  (
    cd "$(dirname "$build_script")"
    IMAGE="$image_name" IMAGE_TAG="$image_tag" TELEMT_VERSION="$upstream_version" NO_CACHE="$NO_CACHE" PUSH=0 "$build_script"
  )
}

refresh_docker_image_for_update() {
  local parsed image_name image_tag old_no_cache target_version target_image source_image

  target_version="${TELEMT_UPDATE_TARGET_VERSION:-$TELEMT_LATEST_COMPATIBLE_VERSION}"
  source_image="$TELEMT_IMAGE"
  target_image="$(resolve_update_image_ref "$TELEMT_IMAGE" "$target_version")" ||
    die "Cannot update digest-pinned image safely: $TELEMT_IMAGE"

  TELEMT_UPDATE_IMAGE_BEFORE="$source_image"
  TELEMT_UPDATE_IMAGE_AFTER="$target_image"

  if [[ "$target_image" != telemt-local:* ]]; then
    say "Pulling Docker image for update: $target_image"
    docker pull "$target_image"
    if [ "$target_image" != "$source_image" ]; then
      is_ru && say "Переключаю compose image на точный tag: $source_image -> $target_image" ||
        say "Switching compose image to an exact tag: $source_image -> $target_image"
      patch_compose_image_ref "$target_image"
    fi
    TELEMT_IMAGE="$target_image"
    return 0
  fi

  TELEMT_IMAGE="$target_image"
  parsed="$(image_name_and_tag "$TELEMT_IMAGE")" || die "Cannot rebuild digest-pinned image: $TELEMT_IMAGE"
  image_name="$(printf '%s\n' "$parsed" | sed -n '1p')"
  image_tag="$(printf '%s\n' "$parsed" | sed -n '2p')"

  old_no_cache="$NO_CACHE"
  NO_CACHE=1
  TELEMT_VERSION="$target_version"
  say "Rebuilding local Telemt image for update: ${image_name}:${image_tag} from Telemt ${target_version}"
  TELEMT_BUILD_VERSION="$target_version" build_local_image
  NO_CACHE="$old_no_cache"
  docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1 ||
    die "Image build finished, but Docker cannot inspect $TELEMT_IMAGE."
  if [ "$target_image" != "$source_image" ]; then
    is_ru && say "Переключаю compose image на точный tag: $source_image -> $target_image" ||
      say "Switching compose image to an exact tag: $source_image -> $target_image"
    patch_compose_image_ref "$target_image"
  fi
}

check_docker_image() {
  local old_no_cache
  say "Checking Docker image: $TELEMT_IMAGE"
  if [ "$CLEAN_INSTALL_MODE" = "1" ] && [[ "$TELEMT_IMAGE" == telemt-local:* ]]; then
    say "Clean install requested: rebuilding $TELEMT_IMAGE instead of reusing the old local image."
    old_no_cache="$NO_CACHE"
    NO_CACHE=1
    build_local_image
    NO_CACHE="$old_no_cache"
    docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1 && return 0
    die "Image build finished, but Docker cannot inspect $TELEMT_IMAGE."
  fi

  if docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1; then
    say "Docker image exists locally."
    return 0
  fi

  if [[ "$TELEMT_IMAGE" != telemt-local:* ]]; then
    say "Docker image is not local. Trying docker pull..."
    if docker pull "$TELEMT_IMAGE"; then
      return 0
    fi
  else
    say "Local image is not built yet."
  fi

  if [ "$AUTO_BUILD_IMAGE" = "yes" ]; then
    build_local_image
    docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1 && return 0
    die "Image build finished, but Docker cannot inspect $TELEMT_IMAGE."
  fi

  if docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1; then
    return 0
  fi

  cat >&2 <<EOF
ERROR: Cannot find or pull image: $TELEMT_IMAGE

Auto-build is disabled. Build the local image manually:
  cd docker-telemt
  TELEMT_VERSION=<version> ./build.sh

Or use a registry image:
  TELEMT_IMAGE=ghcr.io/Telemtinstall/telemt:<version> ./install_docker-telemt.sh
EOF
  exit 1
}

ensure_secret() {
  install -d -m 0700 "$INSTALL_DIR"
  if [ -f "$SECRET_FILE" ]; then
    # shellcheck disable=SC1090
    source "$SECRET_FILE"
  fi
  if [ -z "${TELEMT_SECRET:-}" ]; then
    TELEMT_SECRET="$(openssl rand -hex 16)"
  fi
  TELEMT_SECRET="$(printf '%s' "$TELEMT_SECRET" | tr 'A-F' 'a-f')"
  [[ "$TELEMT_SECRET" =~ ^[a-f0-9]{32}$ ]] || die "Telemt secret must be exactly 32 hex chars."
  umask 077
  cat > "$SECRET_FILE" <<EOF
TELEMT_SECRET=$(printf '%q' "$TELEMT_SECRET")
EOF
  chmod 600 "$SECRET_FILE"
}

hex_encode_ascii() {
  LC_ALL=C printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

load_existing_secret_for_links() {
  if [ -z "${TELEMT_SECRET:-}" ] && [ -f "$SECRET_FILE" ]; then
    # shellcheck disable=SC1090
    source "$SECRET_FILE"
  fi

  if [ -z "${TELEMT_SECRET:-}" ] && [ -f "$INSTALL_DIR/telemt.toml" ]; then
    TELEMT_SECRET="$(
      awk -v user="$TELEMT_USER" '
        /^\[access\.users\]/ {in_users=1; next}
        /^\[/ && in_users {in_users=0}
        in_users {
          line=$0
          sub(/#.*/, "", line)
          eq=index(line, "=")
          if (!eq) next
          key=substr(line, 1, eq - 1)
          val=substr(line, eq + 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
          gsub(/^"|"$/, "", key)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
          gsub(/^"|"$/, "", val)
          if (key == user && length(val) == 32 && val !~ /[^A-Fa-f0-9]/) {
            print val
            exit
          }
        }
      ' "$INSTALL_DIR/telemt.toml"
    )"
  fi

  TELEMT_SECRET="$(printf '%s' "${TELEMT_SECRET:-}" | tr 'A-F' 'a-f')"
  [[ "$TELEMT_SECRET" =~ ^[a-f0-9]{32}$ ]] || die "Cannot load the existing 32-hex Telemt secret for link generation."
}

write_proxy_links() {
  local users_json="$1"
  local domain_hex tls_secret https_link tg_link direct_https direct_tg api_link user secret first_https="" first_direct_https=""

  domain_hex="$(hex_encode_ascii "$DOMAIN")"
  api_link=""

  if command -v jq >/dev/null 2>&1; then
    api_link="$(jq -r '.. | strings | select(startswith("tg://proxy?"))' "$users_json" 2>/dev/null | head -n 1 || true)"
  else
    api_link="$(grep -o 'tg://proxy[^"]*' "$users_json" | head -n 1 || true)"
  fi

  {
    while read -r user secret; do
      [ -n "$user" ] || continue
      secret="$(printf '%s' "$secret" | tr 'A-F' 'a-f')"
      [[ "$secret" =~ ^[a-f0-9]{32}$ ]] || continue
      tls_secret="ee${secret}${domain_hex}"
      [[ "$tls_secret" =~ ^ee[a-f0-9]{34,}$ ]] || die "Generated MTProxy TLS secret is invalid."
      https_link="https://t.me/proxy?server=${DOMAIN}&port=443&secret=${tls_secret}"
      tg_link="tg://proxy?server=${DOMAIN}&port=443&secret=${tls_secret}"
      [ -n "$first_https" ] || first_https="$https_link"
      printf '# user: %s\n' "$user"
      printf '%s\n' "$https_link"
      printf '%s\n\n' "$tg_link"
      if [ -n "${PUBLIC_IP:-}" ] && [ "$PUBLIC_IP" != "$DOMAIN" ]; then
        direct_https="https://t.me/proxy?server=${PUBLIC_IP}&port=443&secret=${tls_secret}"
        direct_tg="tg://proxy?server=${PUBLIC_IP}&port=443&secret=${tls_secret}"
        [ -n "$first_direct_https" ] || first_direct_https="$direct_https"
        printf '# direct IP variant, TLS SNI remains %s\n' "$DOMAIN"
        printf '%s\n' "$direct_https"
        printf '%s\n\n' "$direct_tg"
      fi
    done < <(
      awk '
        /^\[access\.users\]/ {in_users=1; next}
        /^\[/ && in_users {in_users=0}
        in_users {
          line=$0
          sub(/#.*/, "", line)
          eq=index(line, "=")
          if (!eq) next
          key=substr(line, 1, eq - 1)
          val=substr(line, eq + 1)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
          gsub(/^"|"$/, "", key)
          gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
          gsub(/^"|"$/, "", val)
          if (key != "" && length(val) == 32 && val !~ /[^A-Fa-f0-9]/) print key, val
        }
      ' "$INSTALL_DIR/telemt.toml"
    )
    if [ -n "$api_link" ]; then
      printf '\n# Telemt API link, for comparison only:\n%s\n' "$api_link"
    fi
  } > /root/telemt-proxy-links.txt

  [ -n "$first_https" ] || die "Cannot generate proxy links from $INSTALL_DIR/telemt.toml."
  printf '%s\n' "$first_https" > /root/telemt-proxy-link.txt
  if [ -n "$first_direct_https" ]; then
    printf '%s\n' "$first_direct_https" > /root/telemt-proxy-link-ip.txt
    chmod 600 /root/telemt-proxy-link-ip.txt 2>/dev/null || true
  fi
  chmod 600 /root/telemt-proxy-link.txt /root/telemt-proxy-links.txt 2>/dev/null || true
}

install_telemt_users_tool() {
  local src="$SCRIPT_DIR/telemt-users.sh"
  if [ -f "$src" ]; then
    install -m 0755 "$src" /usr/local/sbin/telemt-users
    if is_ru; then
      say "Утилита пользователей установлена: telemt-users"
    else
      say "User management tool installed: telemt-users"
    fi
  fi
}

configure_high_load() {
  [ "$ENABLE_HIGH_LOAD_TUNING" = "yes" ] || return 0

  say "Writing /etc/sysctl.d/99-telemt-high-load.conf"
  {
    cat <<'EOF'
# Telemt high-load tuning.
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
fs.file-max = 2097152
EOF
    if [ -r /proc/sys/net/ipv4/tcp_available_congestion_control ] &&
       grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control; then
      cat <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
    fi
  } > /etc/sysctl.d/99-telemt-high-load.conf

  chmod 0644 /etc/sysctl.d/99-telemt-high-load.conf
  sysctl --system
}

telemt_image_version() {
  docker run --rm --entrypoint /app/telemt "$TELEMT_IMAGE" --version 2>/dev/null |
    sed -n 's/^telemt[[:space:]]\+v\{0,1\}\([0-9][0-9.]*\).*/\1/p' |
    head -n 1
}

telemt_effective_version() {
  local version="${TELEMT_VERSION:-latest}"

  version="${version#v}"
  if [ "$version" = "latest" ] || ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    version="$(telemt_image_version || true)"
  fi
  if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    version="$TELEMT_DEFAULT_VERSION"
  fi
  printf '%s' "$version"
}

telemt_version_at_least() {
  local wanted_major="$1" wanted_minor="$2" wanted_patch="$3"
  local version major minor patch
  version="$(telemt_effective_version)"
  [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  IFS=. read -r major minor patch <<< "$version"
  minor="${minor:-0}"
  patch="${patch:-0}"

  (( major > wanted_major )) && return 0
  (( major < wanted_major )) && return 1
  (( minor > wanted_minor )) && return 0
  (( minor < wanted_minor )) && return 1
  (( patch >= wanted_patch ))
}

telemt_version_supports_exclusive_mask() {
  telemt_version_at_least 3 4 12
}

telemt_version_supports_user_enabled() {
  telemt_version_at_least 3 4 14
}

telemt_version_supports_client_mss() {
  telemt_version_at_least 3 4 15
}

telemt_version_supports_client_mss_bulk() {
  telemt_version_at_least 3 4 19
}

telemt_version_supports_synlimit() {
  telemt_version_at_least 3 4 18
}

write_mask_site_index() {
  local install_started_at
  install_started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  install -d -m 0755 "/var/www/$DOMAIN/.well-known/acme-challenge"

  if [ "$MASK_SITE_MODE" = "empty" ]; then
    : > "/var/www/$DOMAIN/index.html"
  else
    cat > "/var/www/$DOMAIN/index.html" <<EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${DOMAIN}</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #202020;
      --panel: #f4f4f1;
      --text: #f7f7f5;
      --muted: #b9b9b4;
      --ink: #2a2a2a;
      --line: rgba(255,255,255,.13);
      --accent: #8fd3ff;
    }
    * { box-sizing: border-box; }
    html, body { min-height: 100%; margin: 0; }
    body {
      font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      background:
        radial-gradient(circle at 78% 32%, rgba(143,211,255,.08), transparent 28%),
        linear-gradient(135deg, #242424 0%, var(--bg) 100%);
      color: var(--text);
      display: grid;
      place-items: center;
      padding: 40px 22px;
    }
    main {
      width: min(980px, 100%);
      display: grid;
      gap: 56px;
    }
    .domain {
      color: var(--muted);
      font-size: 15px;
      letter-spacing: .08em;
      text-transform: uppercase;
    }
    .hero {
      display: grid;
      grid-template-columns: minmax(0, 1fr) 260px;
      gap: 56px;
      align-items: center;
    }
    h1 {
      font-size: clamp(44px, 8vw, 86px);
      line-height: .92;
      margin: 0 0 20px;
      letter-spacing: 0;
      text-transform: uppercase;
    }
    .timer-label {
      margin: 34px 0 14px;
      color: var(--muted);
      font-size: 16px;
    }
    .timer {
      background: var(--panel);
      color: var(--ink);
      border-radius: 8px;
      padding: 28px 30px;
      display: grid;
      grid-template-columns: repeat(4, minmax(80px, 1fr));
      gap: 18px;
      width: min(650px, 100%);
      box-shadow: 0 24px 60px rgba(0,0,0,.26);
    }
    .num {
      display: block;
      font-size: clamp(34px, 6vw, 58px);
      font-weight: 300;
      line-height: 1;
      font-variant-numeric: tabular-nums;
    }
    .unit {
      display: block;
      margin-top: 10px;
      color: #676761;
      font-size: 11px;
      letter-spacing: .22em;
      text-transform: uppercase;
    }
    .machine {
      position: relative;
      width: 240px;
      height: 240px;
      border: 13px solid rgba(255,255,255,.22);
      border-radius: 50%;
    }
    .machine:before {
      content: "";
      position: absolute;
      inset: 42px;
      border: 13px solid rgba(255,255,255,.19);
      border-left-color: transparent;
      border-radius: 50%;
      animation: spin 14s linear infinite;
    }
    .machine:after {
      content: "";
      position: absolute;
      width: 170px;
      height: 92px;
      right: -54px;
      bottom: 8px;
      border: 13px solid rgba(255,255,255,.22);
      border-radius: 18px;
      background:
        linear-gradient(rgba(255,255,255,.22), rgba(255,255,255,.22)) 24px 24px / 118px 10px no-repeat,
        linear-gradient(rgba(255,255,255,.22), rgba(255,255,255,.22)) 24px 52px / 118px 10px no-repeat;
    }
    @keyframes spin { to { transform: rotate(360deg); } }
    @media (max-width: 760px) {
      main { gap: 34px; }
      .hero { grid-template-columns: 1fr; gap: 28px; }
      .machine { display: none; }
      .timer { grid-template-columns: repeat(2, minmax(0, 1fr)); }
    }
  </style>
</head>
<body>
  <main>
    <div class="domain">${DOMAIN}</div>
    <section class="hero" aria-label="Статус сайта">
      <div>
        <h1>Сайт уже работает</h1>
        <div class="timer-label">Работает с момента установки:</div>
        <div class="timer" aria-live="polite">
          <div><span class="num" id="days">0</span><span class="unit">дней</span></div>
          <div><span class="num" id="hours">00</span><span class="unit">часов</span></div>
          <div><span class="num" id="minutes">00</span><span class="unit">минут</span></div>
          <div><span class="num" id="seconds">00</span><span class="unit">секунд</span></div>
        </div>
      </div>
      <div class="machine" aria-hidden="true"></div>
    </section>
  </main>
  <script>
    const startedAt = new Date("${install_started_at}");
    const pad = function(value) { return String(value).padStart(2, "0"); };
    function updateTimer() {
      const diff = Math.max(0, Date.now() - startedAt.getTime());
      const totalSeconds = Math.floor(diff / 1000);
      const days = Math.floor(totalSeconds / 86400);
      const hours = Math.floor(totalSeconds % 86400 / 3600);
      const minutes = Math.floor(totalSeconds % 3600 / 60);
      const seconds = totalSeconds % 60;
      document.getElementById("days").textContent = String(days);
      document.getElementById("hours").textContent = pad(hours);
      document.getElementById("minutes").textContent = pad(minutes);
      document.getElementById("seconds").textContent = pad(seconds);
    }
    updateTimer();
    setInterval(updateTimer, 1000);
  </script>
</body>
</html>
EOF
  fi
  chmod 0644 "/var/www/$DOMAIN/index.html"
}

write_mask_site_http_only() {
  ensure_nginx_domain_not_owned_elsewhere
  write_mask_site_index
  write_file_root "$(nginx_mask_site_available_path)" 0644 root:root <<EOF
# Managed by install_docker-telemt.sh. Do not edit manually.
server {
    listen 80;
    server_name ${DOMAIN};
    access_log off;
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
EOF
  ln -sfn "$(nginx_mask_site_available_path)" "$(nginx_mask_site_enabled_path)"
  nginx -t
  systemctl reload nginx || systemctl restart nginx
  sleep 1
}

append_acme_diagnostics() {
  local log_file="$1"
  local dns_a=""
  local dns_aaaa=""

  {
    printf '\n[automatic ACME HTTP-01 diagnostics]\n'
    printf 'domain=%s\n' "$DOMAIN"
    printf 'server_public_ipv4=%s\n' "$PUBLIC_IP"
    printf 'time=%s\n' "$(date -Is 2>/dev/null || date)"

    printf '\n[dns]\n'
    if have getent; then
      dns_a="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
      dns_aaaa="$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
      printf 'A/IPv4: %s\n' "${dns_a:-not found}"
      printf 'AAAA/IPv6: %s\n' "${dns_aaaa:-not found}"
      if [ -n "$dns_a" ] && ! printf ' %s ' "$dns_a" | grep -q " $PUBLIC_IP "; then
        printf 'WARNING: domain IPv4 does not include this server public IPv4.\n'
      fi
      if [ -n "$dns_aaaa" ]; then
        printf 'NOTE: domain has IPv6 records. If IPv6 is not configured and open on this server, remove AAAA or configure IPv6.\n'
      fi
    else
      printf 'getent not found; DNS diagnostics skipped.\n'
    fi

    printf '\n[challenge file]\n'
    printf 'webroot=/var/www/%s\n' "$DOMAIN"
    printf 'challenge_path=%s\n' "${ACME_PREFLIGHT_PATH:-not set}"
    if [ -n "$ACME_PREFLIGHT_PATH" ] && [ -f "$ACME_PREFLIGHT_PATH" ]; then
      ls -l "$ACME_PREFLIGHT_PATH" 2>&1 || true
      printf 'expected_content=%s\n' "$ACME_PREFLIGHT_EXPECTED"
      printf 'actual_content='
      sed -n '1p' "$ACME_PREFLIGHT_PATH" 2>/dev/null || true
    else
      printf 'challenge file missing\n'
    fi

    printf '\n[local HTTP check]\n'
    if [ -n "$ACME_PREFLIGHT_TOKEN" ]; then
      printf 'url=http://127.0.0.1/.well-known/acme-challenge/%s host=%s\n' "$ACME_PREFLIGHT_TOKEN" "$DOMAIN"
      curl -4fsSIL --connect-timeout 5 --max-time 10 -H "Host: ${DOMAIN}" \
        "http://127.0.0.1/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}" 2>&1 || true
      curl -4fsS --connect-timeout 5 --max-time 10 -H "Host: ${DOMAIN}" \
        "http://127.0.0.1/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}" 2>&1 || true
      printf '\n'
    else
      printf 'challenge token is not set\n'
    fi

    printf '\n[public IPv4 HTTP check]\n'
    if [ -n "$ACME_PREFLIGHT_TOKEN" ]; then
      printf 'url=http://%s/.well-known/acme-challenge/%s resolved_to=%s\n' "$DOMAIN" "$ACME_PREFLIGHT_TOKEN" "$PUBLIC_IP"
      curl -4fsSIL --connect-timeout 8 --max-time 20 --resolve "${DOMAIN}:80:${PUBLIC_IP}" \
        "http://${DOMAIN}/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}" 2>&1 || true
      curl -4fsS --connect-timeout 8 --max-time 20 --resolve "${DOMAIN}:80:${PUBLIC_IP}" \
        "http://${DOMAIN}/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}" 2>&1 || true
      printf '\n'
    else
      printf 'challenge token is not set\n'
    fi

    printf '\n[listening ports]\n'
    ss -lntp 2>&1 | grep -E ':(80|443)\b' || printf 'No 80/443 listeners found by ss.\n'

    printf '\n[nginx]\n'
    if have systemctl; then
      systemctl is-active nginx 2>/dev/null | sed 's/^/nginx_active=/' || true
    fi
    nginx -t 2>&1 || true
    if [ -f "$(nginx_mask_site_available_path)" ]; then
      printf 'site_config=%s\n' "$(nginx_mask_site_available_path)"
      grep -nE 'listen 80|server_name|well-known|root|return 301' "$(nginx_mask_site_available_path)" 2>/dev/null || true
    else
      printf 'site_config=%s missing\n' "$(nginx_mask_site_available_path)"
    fi

    printf '\n[firewall]\n'
    if have ufw; then
      ufw status verbose 2>&1 || true
    else
      printf 'ufw not installed\n'
    fi
    if have firewall-cmd; then
      firewall-cmd --state 2>&1 || true
      firewall-cmd --list-all 2>&1 || true
    else
      printf 'firewalld not installed\n'
    fi
    if have nft; then
      printf '\n[nftables first 160 lines]\n'
      nft list ruleset 2>&1 | sed -n '1,160p' || true
    fi
    if have iptables; then
      printf '\n[iptables first 120 lines]\n'
      iptables -S 2>&1 | sed -n '1,120p' || true
    fi
  } >> "$log_file"
}

acme_http01_failed() {
  local log_file="$1"
  local failed_check="$2"

  append_acme_diagnostics "$log_file"
  cat "$log_file" >&2 || true

  if is_ru; then
    cat >&2 <<EOF

Let's Encrypt HTTP-01 check failed: ${failed_check}

Что это значит:
  Центр сертификации должен скачать файл:
  http://${DOMAIN}/.well-known/acme-challenge/<token>

  Если файл не скачивается снаружи, сертификат не выпускается. Обычно причина одна из этих:
  1. DNS A-запись домена не указывает на IPv4 этого сервера: ${PUBLIC_IP}
  2. Входящий 80/tcp закрыт в firewall сервера или в панели хостера.
  3. У домена есть AAAA/IPv6, но IPv6 на сервере не настроен или закрыт.
  4. Перед сервером включен CDN/proxy, который не пропускает /.well-known/acme-challenge/.
  5. nginx не отдает webroot /var/www/${DOMAIN} для этого домена.

Что сделать:
  1. Проверьте DNS A-запись и при необходимости подождите обновления DNS.
  2. Откройте входящий TCP 80 в панели хостера/security group и в firewall ОС.
  3. Если IPv6 не используете, удалите AAAA-запись домена.
  4. Если используете Cloudflare/CDN, временно включите DNS only или пропустите challenge path.
  5. Полный лог диагностики сохранен тут: ${log_file}
EOF
    die "Let's Encrypt HTTP-01 challenge is not reachable."
  fi

  cat >&2 <<EOF

Let's Encrypt HTTP-01 check failed: ${failed_check}

Meaning:
  The Certificate Authority must download:
  http://${DOMAIN}/.well-known/acme-challenge/<token>

  If that file is unreachable from the internet, certificate issuance fails. Common causes:
  1. The domain A record does not point to this server IPv4: ${PUBLIC_IP}
  2. Inbound TCP 80 is blocked by the server firewall or provider firewall.
  3. The domain has AAAA/IPv6 records, but IPv6 is not configured or open.
  4. A CDN/proxy in front of the server does not pass /.well-known/acme-challenge/.
  5. nginx is not serving webroot /var/www/${DOMAIN} for this domain.

What to do:
  1. Check the DNS A record and wait for DNS propagation if needed.
  2. Allow inbound TCP 80 in the provider panel/security group and OS firewall.
  3. Remove the AAAA record if you do not use IPv6.
  4. If you use Cloudflare/CDN, temporarily switch to DNS only or pass the challenge path.
  5. Full diagnostics log: ${log_file}
EOF
  die "Let's Encrypt HTTP-01 challenge is not reachable."
}

fetch_acme_local_body_with_retries() {
  local attempt body rc

  for attempt in 1 2 3 4 5; do
    rc=0
    body="$(curl -4fsS --connect-timeout 5 --max-time 10 -H "Host: ${DOMAIN}" \
      "http://127.0.0.1/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}" 2>>"$ACME_PREFLIGHT_LOG")" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$body" = "$ACME_PREFLIGHT_EXPECTED" ]; then
      printf '%s' "$body"
      return 0
    fi
    printf 'local_check_attempt=%s rc=%s body=%q\n' "$attempt" "$rc" "$body" >> "$ACME_PREFLIGHT_LOG"
    sleep 1
  done

  printf '%s' "$body"
  return 1
}

fetch_acme_public_body_with_retries() {
  local attempt body rc

  for attempt in 1 2 3 4 5; do
    rc=0
    body="$(curl -4fsS --connect-timeout 8 --max-time 20 --resolve "${DOMAIN}:80:${PUBLIC_IP}" \
      "http://${DOMAIN}/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}" 2>>"$ACME_PREFLIGHT_LOG")" || rc=$?
    if [ "$rc" -eq 0 ] && [ "$body" = "$ACME_PREFLIGHT_EXPECTED" ]; then
      printf '%s' "$body"
      return 0
    fi
    printf 'public_check_attempt=%s rc=%s body=%q\n' "$attempt" "$rc" "$body" >> "$ACME_PREFLIGHT_LOG"
    sleep 1
  done

  printf '%s' "$body"
  return 1
}

verify_acme_http01_webroot() {
  local local_body=""
  local public_body=""
  local rc=0

  ACME_PREFLIGHT_TOKEN="telemt-$(openssl rand -hex 12)"
  ACME_PREFLIGHT_EXPECTED="telemt-acme-ok-$(openssl rand -hex 16)"
  ACME_PREFLIGHT_PATH="/var/www/${DOMAIN}/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}"

  install -d -m 0755 "/var/www/${DOMAIN}/.well-known/acme-challenge"
  printf '%s\n' "$ACME_PREFLIGHT_EXPECTED" > "$ACME_PREFLIGHT_PATH"
  chmod 0644 "$ACME_PREFLIGHT_PATH"

  : > "$ACME_PREFLIGHT_LOG"
  chmod 600 "$ACME_PREFLIGHT_LOG" 2>/dev/null || true
  {
    printf '[ACME HTTP-01 preflight]\n'
    printf 'domain=%s\n' "$DOMAIN"
    printf 'server_public_ipv4=%s\n' "$PUBLIC_IP"
    printf 'challenge_path=%s\n' "$ACME_PREFLIGHT_PATH"
  } >> "$ACME_PREFLIGHT_LOG"

  if is_ru; then
    say "Проверка HTTP-01 webroot локально: http://127.0.0.1/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}"
  else
    say "Checking HTTP-01 webroot locally: http://127.0.0.1/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}"
  fi

  local_body="$(fetch_acme_local_body_with_retries)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    acme_http01_failed "$ACME_PREFLIGHT_LOG" "local nginx webroot check on 127.0.0.1:80"
  fi

  if is_ru; then
    say "Проверка HTTP-01 через публичный IPv4: curl -4 --resolve ${DOMAIN}:80:${PUBLIC_IP}"
  else
    say "Checking HTTP-01 through public IPv4: curl -4 --resolve ${DOMAIN}:80:${PUBLIC_IP}"
  fi

  rc=0
  public_body="$(fetch_acme_public_body_with_retries)" || rc=$?
  if [ "$rc" -ne 0 ]; then
    acme_http01_failed "$ACME_PREFLIGHT_LOG" "public IPv4 webroot check on ${PUBLIC_IP}:80"
  fi
}

issue_certificate() {
  local certbot_log="/root/telemt-certbot-check.txt"
  : > "$certbot_log"
  chmod 600 "$certbot_log" 2>/dev/null || true

  if ! certbot certonly \
      --webroot \
      -w "/var/www/$DOMAIN" \
      -d "$DOMAIN" \
      --non-interactive \
      --agree-tos \
      --email "$EMAIL" \
      --keep-until-expiring 2>&1 | tee -a "$certbot_log"; then
    acme_http01_failed "$certbot_log" "certbot HTTP-01 challenge"
  fi
  systemctl enable --now certbot.timer 2>/dev/null || true
}

write_nginx_mask_site_config() {
  local access_log_line="access_log off;"
  if [ "$ENABLE_LOGS" = "yes" ]; then
    access_log_line="access_log /var/log/nginx/${DOMAIN}.access.log;"
  fi

  ensure_nginx_domain_not_owned_elsewhere
  write_file_root "$(nginx_mask_site_available_path)" 0644 root:root <<EOF
# Managed by install_docker-telemt.sh. Do not edit manually.
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

server {
    listen 127.0.0.1:8443 ssl;
    server_name ${DOMAIN};
    ${access_log_line}
    error_log /var/log/nginx/${DOMAIN}.error.log crit;

    root /var/www/${DOMAIN};
    index index.html;

    ssl_certificate /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_prefer_server_ciphers off;

    location / {
        try_files \$uri /index.html =404;
    }
}
EOF
  ln -sfn "$(nginx_mask_site_available_path)" "$(nginx_mask_site_enabled_path)"
}

write_nginx_full_config() {
  write_nginx_mask_site_config

  write_file_root /etc/nginx/modules-enabled/60-telemt-stream-sni.conf 0644 root:root <<EOF
# Managed by install_docker-telemt.sh. Do not edit manually.
stream {
    map \$ssl_preread_server_name \$telemt_backend {
        ${DOMAIN} 127.0.0.1:1443;
        default   127.0.0.1:8443;
    }

    server {
        listen 443;
        proxy_pass \$telemt_backend;
        ssl_preread on;
        proxy_connect_timeout 5s;
        proxy_timeout 24h;
    }
}
EOF
  nginx -t
  systemctl reload nginx || systemctl restart nginx
}

write_telemt_config() {
  install -d -m 0750 "$INSTALL_DIR"
  install -d -m 0777 "$INSTALL_DIR/runtime"

  local middle_bool="false"
  local users_array user secret client_mss client_mss_bulk synlimit_value
  [ "$USE_MIDDLE_PROXY" = "yes" ] && middle_bool="true"
  normalize_telemt_users
  users_array="$(telemt_users_toml_array)"
  client_mss="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  client_mss_bulk="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")"
  synlimit_value="$(normalize_synlimit "$TELEMT_SYNLIMIT")"

  {
    cat <<EOF
show_link = ${users_array}

[general]
data_path = "/run/telemt"
quota_state_path = "/run/telemt/telemt.limit.json"
fast_mode = true
use_middle_proxy = ${middle_bool}
config_strict = true
beobachten = true
beobachten_minutes = 10
beobachten_flush_secs = 15
beobachten_file = "/run/telemt/beobachten.txt"
log_level = "silent"
EOF
    if [ -n "$AD_TAG" ]; then
      printf 'ad_tag = "%s"\n' "$AD_TAG"
    fi
    cat <<EOF

[general.links]
show = ${users_array}
public_host = "${DOMAIN}"
public_port = 443

[general.modes]
classic = false
secure = false
tls = true

[network]
ipv4 = true
ipv6 = false
prefer = 4

[server]
port = 1443
listen_addr_ipv4 = "127.0.0.1"
listen_addr_ipv6 = "::1"
proxy_protocol = false
metrics_listen = "127.0.0.1:9090"
metrics_whitelist = ["127.0.0.1/32", "::1/128"]
EOF
    if telemt_version_supports_client_mss && [ "$client_mss" != "off" ]; then
      printf 'client_mss = "%s"\n' "$client_mss"
    fi
    if telemt_version_supports_client_mss_bulk && [ "$client_mss" != "off" ] && [ "$client_mss_bulk" != "off" ]; then
      printf 'client_mss_bulk = "%s"\n' "$client_mss_bulk"
    fi
    cat <<EOF
[server.api]
enabled = true
listen = "127.0.0.1:9091"
read_only = true
whitelist = ["127.0.0.1/32", "::1/128"]
request_body_limit_bytes = 65536
minimal_runtime_enabled = true
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "127.0.0.1"
announce = "${PUBLIC_IP}"
EOF
    if telemt_version_supports_client_mss && [ "$client_mss" != "off" ]; then
      printf 'client_mss = "%s"\n' "$client_mss"
    fi
    if telemt_version_supports_synlimit; then
      if [ "$synlimit_value" = "false" ]; then
        printf 'synlimit = false\n'
      else
        printf 'synlimit = "%s"\n' "$synlimit_value"
        printf 'synlimit_seconds = %s\n' "$TELEMT_SYNLIMIT_SECONDS"
        printf 'synlimit_hitcount = %s\n' "$TELEMT_SYNLIMIT_HITCOUNT"
        printf 'synlimit_burst = %s\n' "$TELEMT_SYNLIMIT_BURST"
        printf 'synlimit_ios_seconds = %s\n' "$TELEMT_SYNLIMIT_IOS_SECONDS"
        printf 'synlimit_ios_hitcount = %s\n' "$TELEMT_SYNLIMIT_IOS_HITCOUNT"
        printf 'synlimit_ios_burst = %s\n' "$TELEMT_SYNLIMIT_IOS_BURST"
        printf 'synlimit_hashlimit_expire_ms = %s\n' "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS"
        printf 'synlimit_hashlimit_size = %s\n' "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE"
      fi
    fi
    cat <<EOF
[censorship]
tls_domain = "${DOMAIN}"
mask = true
mask_host = "127.0.0.1"
mask_port = 8443
mask_dynamic = false
tls_emulation = true
tls_front_dir = "/tmp/telemt-tlsfront"
tls_full_cert_ttl_secs = 0
alpn_enforce = true
EOF
    if telemt_version_supports_exclusive_mask; then
      cat <<EOF

[censorship.exclusive_mask]
"${DOMAIN}" = "127.0.0.1:8443"
EOF
    fi
    cat <<EOF

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
EOF
    while IFS= read -r user; do
      [ -n "$user" ] || continue
      if [ "$user" = "$TELEMT_USER" ]; then
        secret="$TELEMT_SECRET"
      else
        secret="$(openssl rand -hex 16)"
      fi
      printf '"%s" = "%s"\n' "$user" "$secret"
	    done < <(telemt_users_list)
    if telemt_version_supports_user_enabled; then
      cat <<EOF

[access.user_enabled]
EOF
      while IFS= read -r user; do
        [ -n "$user" ] || continue
        printf '"%s" = true\n' "$user"
      done < <(telemt_users_list)
    fi
	    cat <<EOF
[access.user_max_tcp_conns]
EOF
    while IFS= read -r user; do
      [ -n "$user" ] || continue
      printf '"%s" = %s\n' "$user" "$TELEMT_MAX_TCP_CONNS"
    done < <(telemt_users_list)
    cat <<EOF
[[upstreams]]
type = "direct"
enabled = true
weight = 10
ipv4 = true
ipv6 = false
EOF
  } > "$INSTALL_DIR/telemt.toml"
  chown 65532:65532 "$INSTALL_DIR/telemt.toml"
  chmod 600 "$INSTALL_DIR/telemt.toml"
}

fix_runtime_permissions() {
  if [ -f "$INSTALL_DIR/telemt.toml" ]; then
    chown 65532:65532 "$INSTALL_DIR/telemt.toml"
    chmod 600 "$INSTALL_DIR/telemt.toml"
  fi
  install -d -m 0777 "$INSTALL_DIR/runtime"
}

ensure_telemt_image_available() {
  local compose_image script_dir build_script

  compose_image="$(compose_image_from_file "$INSTALL_DIR/docker-compose.yml" || true)"
  [ -n "$compose_image" ] && TELEMT_IMAGE="$compose_image"

  if docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1; then
    return 0
  fi

  if [[ "$TELEMT_IMAGE" == telemt-local:* ]]; then
    script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
    build_script="${BUILD_SCRIPT:-$script_dir/build.sh}"
    if [ ! -f "$build_script" ]; then
      say "WARN: missing local image $TELEMT_IMAGE and build.sh was not found near installer"
      return 1
    fi
    say "Local image $TELEMT_IMAGE is missing. Rebuilding it with build.sh..."
    build_local_image || return 1
    docker image inspect "$TELEMT_IMAGE" >/dev/null 2>&1
    return $?
  fi

  say "Docker image $TELEMT_IMAGE is missing locally. Pulling it..."
  docker pull "$TELEMT_IMAGE"
}

write_compose() {
  local logging_block
  local hardening_block
  install -d -m 0750 "$INSTALL_DIR"
  if [ "$ENABLE_LOGS" = "yes" ]; then
    logging_block='
    logging:
      driver: "json-file"
      options:
        max-size: "10m"
        max-file: "3"'
  else
    logging_block='
    logging:
      driver: "none"'
  fi

  if [ "$ENABLE_DOCKER_HARDENING" = "yes" ]; then
    hardening_block='
    healthcheck:
      test: [ "CMD", "/app/telemt", "healthcheck", "/etc/telemt/telemt.toml", "--mode", "liveness" ]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    security_opt:
      - no-new-privileges=true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
      - /run/telemt:rw,nosuid,nodev,noexec,size=32m'
  else
    hardening_block='
    healthcheck:
      disable: true
    tmpfs:
      - /run/telemt:rw,nosuid,nodev,noexec,size=32m'
  fi

  cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
services:
  telemt:
    image: ${TELEMT_IMAGE}
    container_name: telemt
    restart: unless-stopped
    network_mode: host
    user: "65532:65532"
    environment:
      RUST_LOG: "warn"
    volumes:
      - ${INSTALL_DIR}/telemt.toml:/etc/telemt/telemt.toml:ro
    command: ["/etc/telemt/telemt.toml"]
${hardening_block}${logging_block}
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
EOF
  chmod 600 "$INSTALL_DIR/docker-compose.yml"
}

start_telemt() {
  local cid found
  cd "$INSTALL_DIR"
  ensure_compose_available || return 1
  compose_cmd config >/dev/null || return 1
  ensure_telemt_image_available || return 1
  found=0
  while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    found=1
    docker_remove_container_with_retry "$cid" || return 1
  done < <(telemt_container_ids || true)
  if [ "$found" = "1" ]; then
    if is_ru; then
      say "Удалил старый контейнер Telemt перед запуском, чтобы обойти ошибку docker-compose v1 ContainerConfig/removed image."
    else
      say "Removed the old Telemt container before start to avoid the docker-compose v1 ContainerConfig/removed-image bug."
    fi
  fi
  compose_up_telemt_with_retry
}

telemt_container_ids() {
  local cid name
  docker ps -aq --filter "name=telemt" 2>/dev/null | while IFS= read -r cid; do
    [ -n "$cid" ] || continue
    name="$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | sed 's#^/##' || true)"
    [ "$name" = "telemt" ] && printf '%s\n' "$cid"
  done
  return 0
}

docker_remove_container_with_retry() {
  local cid="$1" attempt output state
  for attempt in 1 2 3; do
    if output="$(docker rm -f "$cid" 2>&1)"; then
      return 0
    fi
    if grep -Eqi 'zombie|cannot be killed|Could not kill' <<< "$output"; then
      state="$(docker inspect "$cid" --format 'status={{.State.Status}} running={{.State.Running}} pid={{.State.Pid}} exit={{.State.ExitCode}}' 2>/dev/null || true)"
      if is_ru; then
        say "WARN: Docker считает контейнер Telemt zombie и пока не может его удалить; жду и повторяю попытку (${attempt}/3). ${state}"
      else
        say "WARN: Docker reports the Telemt container as zombie and cannot remove it yet; waiting and retrying (${attempt}/3). ${state}"
      fi
      sleep $((attempt * 5))
      if ! docker inspect "$cid" >/dev/null 2>&1; then
        return 0
      fi
      continue
    fi
    say "WARN: docker rm -f $cid failed: $output"
    return 1
  done

  if is_ru; then
    say "WARN: контейнер Telemt остался zombie после повторных попыток. Обычно помогает: systemctl restart docker, затем повторить --fix-nginx."
  else
    say "WARN: the Telemt container is still zombie after retries. Usually this helps: systemctl restart docker, then rerun --fix-nginx."
  fi
  return 1
}

compose_up_telemt_with_retry() {
  local attempt output
  for attempt in 1 2; do
    if output="$(compose_cmd up -d --force-recreate telemt 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    printf '%s\n' "$output"
    if grep -Eqi 'zombie|cannot be killed|Could not kill' <<< "$output"; then
      if is_ru; then
        say "WARN: Docker еще держит zombie-процесс Telemt; жду 10 секунд и повторяю recreate."
      else
        say "WARN: Docker is still holding a zombie Telemt process; waiting 10 seconds and retrying recreate."
      fi
      sleep 10
      continue
    fi
    return 1
  done

  if is_ru; then
    say "WARN: Docker не смог пересоздать Telemt после повторной попытки. Если контейнер zombie, перезапустите docker.service и повторите --fix-nginx."
  else
    say "WARN: Docker could not recreate Telemt after retry. If the container is zombie, restart docker.service and rerun --fix-nginx."
  fi
  return 1
}

write_firewall_hints() {
  if have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
    ufw allow 80/tcp
    ufw allow 443/tcp
  fi
  if have firewall-cmd && systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-service=http || true
    firewall-cmd --permanent --add-service=https || true
    firewall-cmd --reload || true
  fi
}

openssl_supports_ipv4_flag() {
  openssl s_client -help 2>&1 | grep -q -- '-4'
}

log_command() {
  local log_file="$1"
  shift
  {
    printf 'command='
    printf '%q ' "$@"
    printf '\n'
  } >> "$log_file"
}

run_openssl_probe() {
  local log_file="$1"
  local label="$2"
  local connect_to="$3"
  local optional="${4:-no}"
  local rc=0
  local ipv4_flag=()

  if openssl_supports_ipv4_flag; then
    ipv4_flag=(-4)
  fi

  {
    printf '\n[%s]\n' "$label"
    log_command "$log_file" timeout 15 openssl s_client "${ipv4_flag[@]}" -connect "$connect_to" -servername "$DOMAIN" -verify_hostname "$DOMAIN" -verify_return_error -brief
  } >> "$log_file"

  timeout 15 openssl s_client \
    "${ipv4_flag[@]}" \
    -connect "$connect_to" \
    -servername "$DOMAIN" \
    -verify_hostname "$DOMAIN" \
    -verify_return_error \
    -brief </dev/null >> "$log_file" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    printf 'result=OK\n' >> "$log_file"
    return 0
  fi

  printf 'result=FAILED exit_code=%s optional=%s\n' "$rc" "$optional" >> "$log_file"
  [ "$optional" = "yes" ] && return 0
  return "$rc"
}

run_curl_probe() {
  local log_file="$1"
  local rc=0

  {
    printf '\n[curl IPv4 active probing]\n'
    log_command "$log_file" curl -4fsSIL --connect-timeout 8 --max-time 20 --resolve "${DOMAIN}:443:${PUBLIC_IP}" "https://${DOMAIN}/"
  } >> "$log_file"

  curl -4fsSIL \
    --connect-timeout 8 \
    --max-time 20 \
    --resolve "${DOMAIN}:443:${PUBLIC_IP}" \
    "https://${DOMAIN}/" >> "$log_file" 2>&1 || rc=$?

  if [ "$rc" -eq 0 ]; then
    printf 'result=OK\n' >> "$log_file"
    return 0
  fi

  printf 'result=FAILED exit_code=%s\n' "$rc" >> "$log_file"
  return "$rc"
}

run_mask_site_probe() {
  local log_file="$1"
  local out_file="/tmp/telemt-mask-site-check.html"
  local rc=0
  local result=""

  {
    printf '\n[mask site IPv4 GET]\n'
    log_command "$log_file" curl -4fsSL --connect-timeout 8 --max-time 20 --resolve "${DOMAIN}:443:${PUBLIC_IP}" "https://${DOMAIN}/" -o "$out_file" -w "http_code=%{http_code}\\nsize_download=%{size_download}\\n"
  } >> "$log_file"

  result="$(curl -4fsSL \
    --connect-timeout 8 \
    --max-time 20 \
    --resolve "${DOMAIN}:443:${PUBLIC_IP}" \
    "https://${DOMAIN}/" \
    -o "$out_file" \
    -w "http_code=%{http_code}\nsize_download=%{size_download}\n" 2>>"$log_file")" || rc=$?

  printf '%s' "$result" >> "$log_file"
  [ -n "$result" ] && printf '\n' >> "$log_file"

  if [ "$rc" -eq 0 ]; then
    printf 'result=OK\n' >> "$log_file"
    if is_ru; then
      say "Маскировочная страница OK: https://${DOMAIN}/"
    else
      say "Mask site OK: https://${DOMAIN}/"
    fi
    return 0
  fi

  printf 'result=FAILED exit_code=%s\n' "$rc" >> "$log_file"
  return "$rc"
}

append_active_probe_diagnostics() {
  local log_file="$1"
  local dns_a=""
  local dns_aaaa=""

  {
    printf '\n[automatic diagnostics]\n'
    printf 'domain=%s\n' "$DOMAIN"
    printf 'server_public_ipv4=%s\n' "$PUBLIC_IP"
    printf 'time=%s\n' "$(date -Is 2>/dev/null || date)"

    printf '\n[dns]\n'
    if have getent; then
      dns_a="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
      dns_aaaa="$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
      printf 'A/IPv4: %s\n' "${dns_a:-not found}"
      printf 'AAAA/IPv6: %s\n' "${dns_aaaa:-not found}"
      if [ -n "$dns_a" ] && ! printf ' %s ' "$dns_a" | grep -q " $PUBLIC_IP "; then
        printf 'WARNING: domain IPv4 does not include this server public IPv4.\n'
      fi
      if [ -n "$dns_aaaa" ]; then
        printf 'NOTE: domain has IPv6 records. If IPv6 is not configured and open on this server, clients may fail unless they use IPv4.\n'
      fi
    else
      printf 'getent not found; DNS diagnostics skipped.\n'
    fi

    printf '\n[listening ports]\n'
    ss -lntp 2>&1 | grep -E ':(80|443|8443|1443|9090|9091)\b' || printf 'No expected listeners found by ss.\n'

    printf '\n[nginx]\n'
    if have systemctl; then
      systemctl is-active nginx 2>/dev/null | sed 's/^/nginx_active=/' || true
    fi
    nginx -t 2>&1 || true
    if [ -f /etc/nginx/modules-enabled/60-telemt-stream-sni.conf ]; then
      printf 'stream_config=/etc/nginx/modules-enabled/60-telemt-stream-sni.conf exists\n'
      grep -nE 'stream|ssl_preread|listen 443|127\.0\.0\.1:(1443|8443)' /etc/nginx/modules-enabled/60-telemt-stream-sni.conf 2>/dev/null || true
    else
      printf 'stream_config=/etc/nginx/modules-enabled/60-telemt-stream-sni.conf missing\n'
    fi

    printf '\n[docker]\n'
    if have docker; then
      docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>&1 || true
      docker logs telemt --tail 80 2>&1 | sed -E \
        -e 's#tg://proxy[^[:space:]]+#tg://proxy<redacted>#g' \
        -e 's#secret[=:][0-9A-Fa-f]{32,}#secret=<redacted>#g' || true
    else
      printf 'docker command not found\n'
    fi

    printf '\n[firewall]\n'
    if have ufw; then
      ufw status verbose 2>&1 || true
    else
      printf 'ufw not installed\n'
    fi
    if have firewall-cmd; then
      firewall-cmd --state 2>&1 || true
      firewall-cmd --list-all 2>&1 || true
    else
      printf 'firewalld not installed\n'
    fi
  } >> "$log_file"
}

active_probe_failed() {
  local log_file="$1"
  local failed_check="$2"

  append_active_probe_diagnostics "$log_file"
  cat "$log_file" >&2 || true

  if is_ru; then
    cat >&2 <<EOF

Active probing check failed: ${failed_check}

Что это значит:
  Проверка не смогла получить нормальный TLS/HTTPS ответ на ${DOMAIN}:443.
  Если выше есть "BIO_connect:connect error", это почти всегда значит, что TCP 443 не открылся:
  порт закрыт firewall-ом/панелью хостера, nginx не слушает 443 или stream-конфиг не применился.

Что сделать:
  1. Откройте входящие TCP-порты 80 и 443 в firewall сервера и в панели хостера.
  2. Проверьте, что DNS A-запись домена указывает на этот IPv4: ${PUBLIC_IP}.
  3. Если у домена есть AAAA/IPv6, либо настройте IPv6 и listen [::]:443, либо удалите AAAA-запись.
  4. Проверьте nginx stream: должен быть ssl_preread на 443 и маршруты 127.0.0.1:1443 / 127.0.0.1:8443.
  5. Проверьте, что контейнер telemt запущен и слушает 127.0.0.1:1443, а API доступен на 127.0.0.1:9091.
  6. Полный лог диагностики сохранен тут: ${log_file}
EOF
    die "Active probing failed. See diagnostics above."
  fi

  cat >&2 <<EOF

Active probing check failed: ${failed_check}

Meaning:
  The installer could not get a valid TLS/HTTPS response from ${DOMAIN}:443.
  If the log above contains "BIO_connect:connect error", TCP 443 usually did not open:
  firewall/provider filtering, nginx is not listening on 443, or nginx stream was not applied.

What to do:
  1. Allow inbound TCP ports 80 and 443 in the server firewall and provider firewall.
  2. Make sure the domain A record points to this IPv4: ${PUBLIC_IP}.
  3. If the domain has AAAA/IPv6 records, configure IPv6 and listen [::]:443, or remove the AAAA record.
  4. Check nginx stream: ssl_preread must listen on 443 and route to 127.0.0.1:1443 / 127.0.0.1:8443.
  5. Check that the telemt container is running, 127.0.0.1:1443 is listening, and API is reachable on 127.0.0.1:9091.
  6. Full diagnostics log: ${log_file}
EOF
  die "Active probing failed. See diagnostics above."
}

print_telemt_container_diagnostics() {
  say
  if is_ru; then
    say "Диагностика Docker/Telemt:"
  else
    say "Docker/Telemt diagnostics:"
  fi

  docker ps -a --filter "name=telemt" 2>&1 || true

  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    say
    say "$INSTALL_DIR/docker-compose.yml:"
    sed -n '1,220p' "$INSTALL_DIR/docker-compose.yml" 2>&1 || true
  fi

  say
  say "telemt logs:"
  if docker compose version >/dev/null 2>&1; then
    (cd "$INSTALL_DIR" && docker compose logs --no-color --tail=120 telemt) 2>&1 || docker logs --tail 120 telemt 2>&1 || true
  elif have docker-compose; then
    (cd "$INSTALL_DIR" && docker-compose logs --tail=120 telemt) 2>&1 || docker logs --tail 120 telemt 2>&1 || true
  else
    docker logs --tail 120 telemt 2>&1 || true
  fi
}

validate_install() {
  sleep 8
  ss -lntp | grep -E ':(80|443|8443|1443|9090|9091)\b' || true
  if ! curl -fsS "http://127.0.0.1:9091/v1/users" | tee /tmp/telemt-users.json >/dev/null; then
    print_telemt_container_diagnostics
    if is_ru; then
      die "Telemt API не отвечает на 127.0.0.1:9091. Смотри диагностику контейнера выше."
    else
      die "Telemt API does not respond on 127.0.0.1:9091. See container diagnostics above."
    fi
  fi
  if ! grep -q '"ok":true' /tmp/telemt-users.json; then
    cat /tmp/telemt-users.json >&2 || true
    print_telemt_container_diagnostics
    if is_ru; then
      die "Telemt API ответил, но формат ответа неожиданный."
    else
      die "Telemt API responded, but the response format was unexpected."
    fi
  fi
  write_proxy_links /tmp/telemt-users.json

  local probe_log="/root/telemt-active-probing-check.txt"
  : > "$probe_log"
  chmod 600 "$probe_log" 2>/dev/null || true

  if is_ru; then
    say "Active probing check: openssl s_client -4 -connect ${PUBLIC_IP}:443 -servername ${DOMAIN}"
  else
    say "Active probing check: openssl s_client -4 -connect ${PUBLIC_IP}:443 -servername ${DOMAIN}"
  fi
  run_openssl_probe "$probe_log" "openssl IPv4 via server public IP" "${PUBLIC_IP}:443" "no" || \
    active_probe_failed "$probe_log" "openssl IPv4 connection to ${PUBLIC_IP}:443"

  run_openssl_probe "$probe_log" "openssl IPv4 via domain DNS" "${DOMAIN}:443" "yes"

  if is_ru; then
    say "Active probing check: curl -4 -I --resolve ${DOMAIN}:443:${PUBLIC_IP} https://${DOMAIN}/"
  else
    say "Active probing check: curl -4 -I --resolve ${DOMAIN}:443:${PUBLIC_IP} https://${DOMAIN}/"
  fi
  run_curl_probe "$probe_log" || \
    active_probe_failed "$probe_log" "curl IPv4 HTTPS request through ${PUBLIC_IP}:443"
  run_mask_site_probe "$probe_log" || \
    active_probe_failed "$probe_log" "mask site HTTPS GET through ${PUBLIC_IP}:443"
  sed -n '1,24p' "$probe_log" || true
}

print_plan() {
  if is_ru; then
    cat <<EOF

План установки:
  домен:              $DOMAIN
  публичный IPv4:     $PUBLIC_IP
  email:              $EMAIL
  Docker image:       $TELEMT_IMAGE
  автосборка image:   $AUTO_BUILD_IMAGE
  страница маскировки: $MASK_SITE_MODE
  пользователи Telemt: $(printf '%s' "$TELEMT_USERS" | tr ',' ' ')
  ссылок MTProxy:     $TELEMT_LINK_COUNT
  лимит подключений:  $TELEMT_MAX_TCP_CONNS
  client_mss:         $TELEMT_CLIENT_MSS
  client_mss_bulk:    $TELEMT_CLIENT_MSS_BULK
  synlimit:           $TELEMT_SYNLIMIT
  ad_tag:             $([ -n "$AD_TAG" ] && printf yes || printf no)
  middle_proxy:       $USE_MIDDLE_PROXY
  логи включены:      $ENABLE_LOGS
  Docker hardening:   $ENABLE_DOCKER_HARDENING
  high-load tuning:   $ENABLE_HIGH_LOAD_TUNING
  host nginx TLS:     $(host_nginx_tls_plan)

Установщик настроит:
  - TLS-Fronting + TCP-Splitting схему для своего домена
  - nginx HTTP -> HTTPS redirect
  - nginx SNI stream на публичном 443/tcp
  - HTTPS mask site на 127.0.0.1:8443 ($MASK_SITE_MODE page)
  - Telemt внутри Docker на 127.0.0.1:1443
  - Telemt API на 127.0.0.1:9091
  - Telemt metrics на 127.0.0.1:9090
  - Let's Encrypt сертификат и certbot renewal timer
  - HTTP-01 preflight перед certbot: проверка challenge-файла локально и через публичный IPv4
  - финальную active probing проверку через openssl s_client и curl --resolve
  - опциональный Docker runtime hardening и healthcheck
EOF

    if [ "$ENABLE_DOCKER_HARDENING" = "yes" ]; then
      cat <<'EOF'

Docker hardening включит:
  - read_only root filesystem
  - cap_drop: ALL
  - no-new-privileges
  - tmpfs для /tmp
  - tmpfs для /run/telemt
  - Docker healthcheck

CPU/RAM/PID лимиты не задаются: контейнер не будет искусственно ограничен при загрузке медиа.
EOF
    else
      cat <<'EOF'

Docker hardening выключен:
  - filesystem контейнера будет writable
  - Linux capabilities не будут сброшены этим compose-файлом
  - Docker healthcheck выключен в compose
EOF
    fi

    if [ "$ENABLE_HIGH_LOAD_TUNING" = "yes" ]; then
      cat <<'EOF'

High-load tuning запишет /etc/sysctl.d/99-telemt-high-load.conf:
  - net.core.somaxconn = 65535
  - net.ipv4.tcp_max_syn_backlog = 65535
  - net.ipv4.tcp_keepalive_time = 300
  - net.ipv4.tcp_keepalive_intvl = 30
  - net.ipv4.tcp_keepalive_probes = 5
  - fs.file-max = 2097152
  - BBR/fq, если поддерживается ядром
EOF
    fi
    return 0
  fi

  cat <<EOF

Install plan:
  domain:             $DOMAIN
  public IPv4:        $PUBLIC_IP
  email:              $EMAIL
  docker image:       $TELEMT_IMAGE
  auto-build image:   $AUTO_BUILD_IMAGE
  mask site page:     $MASK_SITE_MODE
  Telemt users:       $(printf '%s' "$TELEMT_USERS" | tr ',' ' ')
  MTProxy links:      $TELEMT_LINK_COUNT
  connection limit:   $TELEMT_MAX_TCP_CONNS
  client_mss:         $TELEMT_CLIENT_MSS
  client_mss_bulk:    $TELEMT_CLIENT_MSS_BULK
  synlimit:           $TELEMT_SYNLIMIT
  ad_tag:             $([ -n "$AD_TAG" ] && printf yes || printf no)
  middle_proxy:       $USE_MIDDLE_PROXY
  logs enabled:       $ENABLE_LOGS
  Docker hardening:   $ENABLE_DOCKER_HARDENING
  high-load tuning:   $ENABLE_HIGH_LOAD_TUNING
  host nginx TLS:     $(host_nginx_tls_plan)

This installer will configure:
  - TLS-Fronting + TCP-Splitting for your own domain
  - nginx HTTP -> HTTPS redirect
  - nginx SNI stream on public 443/tcp
  - HTTPS mask site on 127.0.0.1:8443 ($MASK_SITE_MODE page)
  - Telemt inside Docker on 127.0.0.1:1443
  - Telemt API on 127.0.0.1:9091
  - Telemt metrics on 127.0.0.1:9090
  - Let's Encrypt certificate and certbot renewal timer
  - HTTP-01 preflight before certbot: challenge-file check locally and through the public IPv4
  - final active probing check with openssl s_client and curl --resolve
  - optional Docker runtime hardening and healthcheck
EOF

  if [ "$ENABLE_DOCKER_HARDENING" = "yes" ]; then
    cat <<'EOF'

Docker hardening will enable:
  - read_only root filesystem
  - cap_drop: ALL
  - no-new-privileges
  - tmpfs for /tmp
  - tmpfs for /run/telemt
  - Docker healthcheck

CPU/RAM/PID limits are not set: the container is not artificially throttled while loading media.
EOF
  else
    cat <<'EOF'

Docker hardening is disabled:
  - container filesystem will be writable
  - Linux capabilities are not dropped by this compose file
  - Docker healthcheck is disabled in compose
EOF
  fi

  if [ "$ENABLE_HIGH_LOAD_TUNING" = "yes" ]; then
    cat <<'EOF'

High-load tuning will write /etc/sysctl.d/99-telemt-high-load.conf:
  - net.core.somaxconn = 65535
  - net.ipv4.tcp_max_syn_backlog = 65535
  - net.ipv4.tcp_keepalive_time = 300
  - net.ipv4.tcp_keepalive_intvl = 30
  - net.ipv4.tcp_keepalive_probes = 5
  - fs.file-max = 2097152
  - BBR/fq if supported by the kernel
EOF
  fi
}

confirm_plan() {
  [ "$ASSUME_YES" = "1" ] && return 0
  local answer
  if is_ru; then
    read -r -p "Введите y, yes или да для продолжения: " answer
  else
    read -r -p "Type y or yes to continue: " answer
  fi
  case "$(lower "$answer")" in
    y|yes|д|да) ;;
    *)
      if is_ru; then
        die "Отменено."
      else
        die "Cancelled."
      fi
      ;;
  esac
}

interactive_inputs() {
  local i existing_user existing_users extra_user

  if is_ru; then
    cat <<'EOF'
Установщик Telemt Docker.

Перед запуском:
  1. Используйте чистый Debian 13.x+ или Ubuntu 24.x+ сервер.
  2. Создайте DNS A-запись: <домен> -> IPv4 этого сервера.
  3. Убедитесь, что порты 80/tcp и 443/tcp доступны из интернета.
  4. Держите build.sh рядом с этим установщиком; image будет собран автоматически, если его нет.

EOF

    ask_default DOMAIN "Домен прокси" "$DOMAIN"
    normalize_domain_input
    EMAIL="${EMAIL:-admin@$DOMAIN}"
    ask_default EMAIL "Email для Let's Encrypt" "$EMAIL"
    normalize_email_input
    ask_default TELEMT_IMAGE "Docker image Telemt" "$TELEMT_IMAGE"
    ask_mask_site_mode
    ask_default TELEMT_USER "Имя пользователя Telemt" "$TELEMT_USER"
    TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
    existing_users="$TELEMT_USERS"
    TELEMT_LINK_COUNT="${TELEMT_LINK_COUNT:-$(telemt_users_list | wc -l | tr -d ' ')}"
    ask_default TELEMT_LINK_COUNT "Сколько ссылок/пользователей создать сразу" "$TELEMT_LINK_COUNT"
    [[ "$TELEMT_LINK_COUNT" =~ ^[0-9]+$ ]] && [ "$TELEMT_LINK_COUNT" -ge 1 ] && [ "$TELEMT_LINK_COUNT" -le 100 ] || die "Количество ссылок должно быть от 1 до 100."
    TELEMT_USERS=""
    append_telemt_user "$TELEMT_USER"
    for ((i=2; i<=TELEMT_LINK_COUNT; i++)); do
      existing_user="$(printf '%s\n' "$existing_users" | tr ',' '\n' | sed -n "${i}p" || true)"
      extra_user=""
      ask_default extra_user "Имя пользователя Telemt #${i}" "${existing_user:-user${i}}"
      append_telemt_user "$extra_user"
	    done
	    ask_default TELEMT_MAX_TCP_CONNS "Максимум подключений Telemt" "$TELEMT_MAX_TCP_CONNS"
	    ask_default TELEMT_CLIENT_MSS "TCP MSS для Telemt listener: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS"
	    ask_default TELEMT_CLIENT_MSS_BULK "TCP MSS для bulk-фазы после handshake: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS_BULK"
	    ask_default TELEMT_SYNLIMIT "SYN limiter Telemt listener: false/iptables/nftables" "$TELEMT_SYNLIMIT"
	    ask_default AD_TAG "MTProxy ad_tag, Enter = пропустить" "$AD_TAG"
  else
    cat <<'EOF'
Telemt Docker installer.

Before running:
  1. Use a clean Debian 13.x+ or Ubuntu 24.x+ server.
  2. Create DNS A record: <domain> -> this server IPv4.
  3. Make sure ports 80/tcp and 443/tcp are reachable.
  4. Keep build.sh next to this installer; the image will be built automatically if missing.

EOF

    ask_default DOMAIN "Proxy domain" "$DOMAIN"
    normalize_domain_input
    EMAIL="${EMAIL:-admin@$DOMAIN}"
    ask_default EMAIL "Let's Encrypt email" "$EMAIL"
    normalize_email_input
    ask_default TELEMT_IMAGE "Telemt Docker image" "$TELEMT_IMAGE"
    ask_mask_site_mode
    ask_default TELEMT_USER "Telemt user name" "$TELEMT_USER"
    TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
    existing_users="$TELEMT_USERS"
    TELEMT_LINK_COUNT="${TELEMT_LINK_COUNT:-$(telemt_users_list | wc -l | tr -d ' ')}"
    ask_default TELEMT_LINK_COUNT "How many proxy links/users to create now" "$TELEMT_LINK_COUNT"
    [[ "$TELEMT_LINK_COUNT" =~ ^[0-9]+$ ]] && [ "$TELEMT_LINK_COUNT" -ge 1 ] && [ "$TELEMT_LINK_COUNT" -le 100 ] || die "Link count must be between 1 and 100."
    TELEMT_USERS=""
    append_telemt_user "$TELEMT_USER"
    for ((i=2; i<=TELEMT_LINK_COUNT; i++)); do
      existing_user="$(printf '%s\n' "$existing_users" | tr ',' '\n' | sed -n "${i}p" || true)"
      extra_user=""
      ask_default extra_user "Telemt user name #${i}" "${existing_user:-user${i}}"
      append_telemt_user "$extra_user"
	    done
	    ask_default TELEMT_MAX_TCP_CONNS "Max Telemt connections" "$TELEMT_MAX_TCP_CONNS"
	    ask_default TELEMT_CLIENT_MSS "Telemt listener TCP MSS: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS"
	    ask_default TELEMT_CLIENT_MSS_BULK "Telemt bulk-phase TCP MSS after handshake: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS_BULK"
	    ask_default TELEMT_SYNLIMIT "Telemt listener SYN limiter: false/iptables/nftables" "$TELEMT_SYNLIMIT"
	    ask_default AD_TAG "MTProxy ad_tag, Enter = skip" "$AD_TAG"
  fi

  if [ -z "$USE_MIDDLE_PROXY" ]; then
    if [ -n "$AD_TAG" ]; then
      USE_MIDDLE_PROXY="yes"
    else
      USE_MIDDLE_PROXY="no"
    fi
  fi
  if is_ru; then
    ask_yes_no USE_MIDDLE_PROXY "Использовать Telegram middle proxy" "$USE_MIDDLE_PROXY"
    ask_yes_no ENABLE_LOGS "Включить access-логи nginx/Docker" "$ENABLE_LOGS"
    ask_yes_no ENABLE_DOCKER_HARDENING "Включить Docker hardening и healthcheck" "$ENABLE_DOCKER_HARDENING"
    ask_yes_no ENABLE_HIGH_LOAD_TUNING "Включить high-load tuning для большого числа клиентов" "$ENABLE_HIGH_LOAD_TUNING"
  else
    ask_yes_no USE_MIDDLE_PROXY "Use Telegram middle proxy" "$USE_MIDDLE_PROXY"
    ask_yes_no ENABLE_LOGS "Enable nginx/Docker access logs" "$ENABLE_LOGS"
    ask_yes_no ENABLE_DOCKER_HARDENING "Enable Docker hardening and healthcheck" "$ENABLE_DOCKER_HARDENING"
    ask_yes_no ENABLE_HIGH_LOAD_TUNING "Enable high-load tuning for many clients" "$ENABLE_HIGH_LOAD_TUNING"
  fi
}

toml_value_from_section() {
  local file="$1"
  local section="$2"
  local key="$3"
  [ -f "$file" ] || return 1
  awk -v section="$section" -v wanted="$key" '
    $0 ~ "^\\[" section "\\]" {in_section=1; next}
    /^\[/ && in_section {in_section=0}
    in_section {
      line=$0
      sub(/#.*/, "", line)
      eq=index(line, "=")
      if (!eq) next
      key=substr(line, 1, eq - 1)
      val=substr(line, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^"|"$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      gsub(/^"|"$/, "", val)
      if (key == wanted) {
        print val
        exit
      }
    }
  ' "$file"
}

first_toml_key_from_section() {
  local file="$1"
  local section="$2"
  [ -f "$file" ] || return 1
  awk -v section="$section" '
    $0 ~ "^\\[" section "\\]" {in_section=1; next}
    /^\[/ && in_section {in_section=0}
    in_section {
      line=$0
      sub(/#.*/, "", line)
      eq=index(line, "=")
      if (!eq) next
      key=substr(line, 1, eq - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^"|"$/, "", key)
      if (key != "") {
        print key
        exit
      }
    }
  ' "$file"
}

compose_image_from_file() {
  local file="$1"
  [ -f "$file" ] || return 1
  awk '
    /^[[:space:]]*image:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*image:[[:space:]]*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'\''|'\''$/, "", value)
      print value
      exit
    }
  ' "$file"
}

patch_compose_image_ref() {
  local new_image="$1"
  local compose_file="$INSTALL_DIR/docker-compose.yml"
  [ -f "$compose_file" ] || return 0

  python3 - "$compose_file" "$new_image" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
new_image = sys.argv[2]
lines = path.read_text().splitlines(True)
changed = False

for i, line in enumerate(lines):
    if re.match(r'^\s*image:\s*', line):
        indent = line[: len(line) - len(line.lstrip())]
        replacement = f"{indent}image: {new_image}\n"
        if line != replacement:
            lines[i] = replacement
            changed = True
        break

if changed:
    path.write_text("".join(lines))
PY
}

build_update_config_gap_report() {
  local config_file="$INSTALL_DIR/telemt.toml"
  local compose_file="$INSTALL_DIR/docker-compose.yml"
  local client_mss client_mss_bulk support_exclusive_mask=0 support_user_enabled=0 support_client_mss=0 support_client_mss_bulk=0 support_synlimit=0

  [ -f "$config_file" ] || return 0
  if ! have python3; then
    printf 'python3 unavailable before update; detailed config gap analysis will run after package check'
    return 0
  fi

  telemt_version_supports_exclusive_mask && support_exclusive_mask=1
  telemt_version_supports_user_enabled && support_user_enabled=1
  telemt_version_supports_client_mss && support_client_mss=1
  telemt_version_supports_client_mss_bulk && support_client_mss_bulk=1
  telemt_version_supports_synlimit && support_synlimit=1
  client_mss="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  client_mss_bulk="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")"

  python3 - "$config_file" "$compose_file" "$DOMAIN" "$client_mss" "$client_mss_bulk" \
    "$support_exclusive_mask" "$support_user_enabled" "$support_client_mss" "$support_client_mss_bulk" "$support_synlimit" <<'PY'
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
compose_path = Path(sys.argv[2])
domain = sys.argv[3]
client_mss = sys.argv[4]
client_mss_bulk = sys.argv[5]
support_exclusive_mask = sys.argv[6] == "1"
support_user_enabled = sys.argv[7] == "1"
support_client_mss = sys.argv[8] == "1"
support_client_mss_bulk = sys.argv[9] == "1"
support_synlimit = sys.argv[10] == "1"

lines = config_path.read_text().splitlines(True)
section_re = re.compile(r'^\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?$')
array_re = re.compile(r'^\s*\[\[([A-Za-z0-9_.-]+)\]\]\s*(?:#.*)?$')

def section_name(line):
    m = section_re.match(line)
    if m:
        return m.group(1), False
    m = array_re.match(line)
    if m:
        return m.group(1), True
    return None, False

def find_section(name):
    start = None
    for i, line in enumerate(lines):
        found, is_array = section_name(line)
        if found == name and not is_array:
            start = i
            break
    if start is None:
        return None, None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        found, _ = section_name(lines[j])
        if found is not None:
            end = j
            break
    return start, end

def find_arrays(name):
    ranges = []
    for i, line in enumerate(lines):
        found, is_array = section_name(line)
        if found == name and is_array:
            end = len(lines)
            for j in range(i + 1, len(lines)):
                next_found, _ = section_name(lines[j])
                if next_found is not None:
                    end = j
                    break
            ranges.append((i, end))
    return ranges

def raw_key(line):
    raw = line.split("#", 1)[0].strip()
    if "=" not in raw:
        return None
    return raw.split("=", 1)[0].strip().strip('"')

def raw_value(line):
    raw = line.split("#", 1)[0].strip()
    if "=" not in raw:
        return None
    return raw.split("=", 1)[1].strip().strip('"')

def has_key(start, end, key):
    return start is not None and any(raw_key(line) == key for line in lines[start + 1:end])

def value_for_key(start, end, key):
    if start is None:
        return None
    for line in lines[start + 1:end]:
        if raw_key(line) == key:
            return raw_value(line)
    return None

def section_has(section, key):
    start, end = find_section(section)
    return has_key(start, end, key)

def arrays_have(array_name, key):
    arrays = find_arrays(array_name)
    return bool(arrays) and all(has_key(start, end, key) for start, end in arrays)

def arrays_have_non_true(array_name, key):
    arrays = find_arrays(array_name)
    return bool(arrays) and all(has_key(start, end, key) and (value_for_key(start, end, key) or "").lower() != "true" for start, end in arrays)

def section_keys(section):
    start, end = find_section(section)
    if start is None:
        return []
    return [key for key in (raw_key(line) for line in lines[start + 1:end]) if key]

checks = [
    ("general.data_path", section_has("general", "data_path")),
    ("general.quota_state_path", section_has("general", "quota_state_path")),
    ("general.beobachten", section_has("general", "beobachten")),
    ("general.beobachten_file", section_has("general", "beobachten_file")),
    ("server.api.request_body_limit_bytes", section_has("server.api", "request_body_limit_bytes")),
    ("server.api.minimal_runtime_enabled", section_has("server.api", "minimal_runtime_enabled")),
    ("server.metrics_listen", section_has("server", "metrics_listen")),
    ("server.metrics_whitelist", section_has("server", "metrics_whitelist")),
    ("censorship.mask_dynamic", section_has("censorship", "mask_dynamic")),
]

if support_client_mss and client_mss != "off":
    checks.append(("server.client_mss", section_has("server", "client_mss")))
    checks.append(("server.listeners.client_mss", arrays_have("server.listeners", "client_mss")))
if support_client_mss_bulk and client_mss != "off" and client_mss_bulk != "off":
    checks.append(("server.client_mss_bulk", section_has("server", "client_mss_bulk")))
if support_synlimit:
    checks.append(("server.listeners.synlimit", arrays_have_non_true("server.listeners", "synlimit")))
if support_exclusive_mask and domain:
    checks.append((f"censorship.exclusive_mask.{domain}", section_has("censorship.exclusive_mask", domain)))
if support_user_enabled:
    users = section_keys("access.users")
    enabled = section_keys("access.user_enabled")
    checks.append(("access.user_enabled", bool(users) and all(user in enabled for user in users)))

upstreams = find_arrays("upstreams")
if upstreams:
    checks.append(("upstreams.ipv4", all(has_key(start, end, "ipv4") for start, end in upstreams)))
    checks.append(("upstreams.ipv6", all(has_key(start, end, "ipv6") for start, end in upstreams)))
else:
    checks.append(("upstreams", False))

if compose_path.exists():
    compose_text = compose_path.read_text()
    checks.append(("compose.tmpfs./run/telemt", "/run/telemt:" in compose_text))
    compose_host = bool(re.search(r'(?m)^\s{4}network_mode:\s*"?host"?\s*$', compose_text))
    checks.append(("compose.network_mode.host", compose_host))
    if compose_host:
        checks.append(("compose.no_ports_with_host", not bool(re.search(r'(?m)^\s{4}ports:\s*$', compose_text))))

missing = [name for name, ok in checks if not ok]
if missing:
    print(", ".join(missing))
else:
    print("none")
PY
}

infer_update_config_from_existing_files() {
  local existing_domain existing_user existing_image

  if [ -f "$INSTALL_DIR/telemt.toml" ]; then
    existing_domain="$(toml_value_from_section "$INSTALL_DIR/telemt.toml" "general\\.links" "public_host" || true)"
    if [ -z "$existing_domain" ]; then
      existing_domain="$(toml_value_from_section "$INSTALL_DIR/telemt.toml" "censorship" "tls_domain" || true)"
    fi
    existing_user="$(first_toml_key_from_section "$INSTALL_DIR/telemt.toml" "access\\.users" || true)"
    [ -n "$existing_domain" ] && DOMAIN="${DOMAIN:-$existing_domain}"
    [ -n "$existing_user" ] && TELEMT_USER="${TELEMT_USER:-$existing_user}"
  fi

  existing_image="$(compose_image_from_file "$INSTALL_DIR/docker-compose.yml" || true)"
  [ -n "$existing_image" ] && TELEMT_IMAGE="$existing_image"

  if [ -n "$DOMAIN" ]; then
    normalize_domain_input
  fi
}

backup_update_state() {
  local backup_dir
  backup_dir="/root/telemt-docker-update-backups/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$backup_dir"

  for path in \
    "$INSTALL_DIR/telemt.toml" \
    "$INSTALL_DIR/docker-compose.yml" \
    "$SECRET_FILE" \
    "$SAVED_CONFIG" \
    "$(nginx_mask_site_available_path)" \
    "$(nginx_mask_site_enabled_path)" \
    "/etc/nginx/sites-available/$DOMAIN" \
    "/etc/nginx/sites-enabled/$DOMAIN" \
    /etc/nginx/modules-enabled/60-telemt-stream-sni.conf \
    /root/telemt-proxy-links.txt \
    /root/telemt-proxy-link.txt \
    /root/telemt-proxy-link-ip.txt
  do
    if [ -e "$path" ] || [ -L "$path" ]; then
      cp -a "$path" "$backup_dir"/
    fi
  done
  chmod -R go-rwx "$backup_dir" 2>/dev/null || true
  if is_ru; then
    say "Бэкап перед обновлением: $backup_dir"
  else
    say "Update backup: $backup_dir"
  fi
}

apply_telemt_config_compat_updates() {
  local config_file="$INSTALL_DIR/telemt.toml"
  local client_mss client_mss_bulk synlimit_value support_exclusive_mask=0 support_user_enabled=0 support_client_mss=0 support_client_mss_bulk=0 support_synlimit=0

  [ -f "$config_file" ] || return 0
  client_mss="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  client_mss_bulk="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")"
  synlimit_value="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
  telemt_version_supports_exclusive_mask && support_exclusive_mask=1
  telemt_version_supports_user_enabled && support_user_enabled=1
  telemt_version_supports_client_mss && support_client_mss=1
  telemt_version_supports_client_mss_bulk && support_client_mss_bulk=1
  telemt_version_supports_synlimit && support_synlimit=1

  python3 - "$config_file" "$DOMAIN" "$PUBLIC_IP" "$client_mss" "$client_mss_bulk" "$synlimit_value" \
    "$TELEMT_SYNLIMIT_SECONDS" "$TELEMT_SYNLIMIT_HITCOUNT" "$TELEMT_SYNLIMIT_BURST" \
    "$TELEMT_SYNLIMIT_IOS_SECONDS" "$TELEMT_SYNLIMIT_IOS_HITCOUNT" "$TELEMT_SYNLIMIT_IOS_BURST" \
    "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS" "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE" \
    "$support_exclusive_mask" "$support_user_enabled" "$support_client_mss" "$support_client_mss_bulk" "$support_synlimit" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
domain, public_ip, client_mss, client_mss_bulk, synlimit = sys.argv[2:7]
syn_seconds, syn_hitcount, syn_burst = sys.argv[7:10]
syn_ios_seconds, syn_ios_hitcount, syn_ios_burst = sys.argv[10:13]
syn_hashlimit_expire_ms, syn_hashlimit_size = sys.argv[13:15]
support_exclusive_mask = sys.argv[15] == "1"
support_user_enabled = sys.argv[16] == "1"
support_client_mss = sys.argv[17] == "1"
support_client_mss_bulk = sys.argv[18] == "1"
support_synlimit = sys.argv[19] == "1"

lines = path.read_text().splitlines(True)
changed = False

section_re = re.compile(r'^\s*\[([A-Za-z0-9_.-]+)\]\s*(?:#.*)?$')
array_re = re.compile(r'^\s*\[\[([A-Za-z0-9_.-]+)\]\]\s*(?:#.*)?$')

def section_name(line):
    m = section_re.match(line)
    if m:
        return m.group(1), False
    m = array_re.match(line)
    if m:
        return m.group(1), True
    return None, False

def find_section(name):
    start = None
    for i, line in enumerate(lines):
        found, is_array = section_name(line)
        if found == name and not is_array:
            start = i
            break
    if start is None:
        return None, None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        found, _ = section_name(lines[j])
        if found is not None:
            end = j
            break
    return start, end

def find_arrays(name):
    ranges = []
    for i, line in enumerate(lines):
        found, is_array = section_name(line)
        if found == name and is_array:
            end = len(lines)
            for j in range(i + 1, len(lines)):
                next_found, _ = section_name(lines[j])
                if next_found is not None:
                    end = j
                    break
            ranges.append((i, end))
    return ranges

def raw_key(line):
    raw = line.split("#", 1)[0].strip()
    if "=" not in raw:
        return None
    return raw.split("=", 1)[0].strip().strip('"')

def has_key(start, end, key):
    return any(raw_key(line) == key for line in lines[start + 1:end])

def set_key(start, end, key, value_line):
    global changed
    for i in range(start + 1, end):
        if raw_key(lines[i]) == key:
            if lines[i].strip() != value_line.strip():
                lines[i] = value_line
                changed = True
            return
    lines.insert(end, value_line)
    changed = True

def remove_key_in_range(start, end, key):
    global changed
    for i in range(end - 1, start, -1):
        if raw_key(lines[i]) == key:
            del lines[i]
            changed = True

def ensure_section(name, insert_before_arrays=True):
    global changed
    start, end = find_section(name)
    if start is not None:
        return start, end
    insert_at = len(lines)
    if insert_before_arrays:
        for i, line in enumerate(lines):
            found, is_array = section_name(line)
            if is_array and found == "upstreams":
                insert_at = i
                break
    block = []
    if lines and lines[insert_at - 1:insert_at] and lines[insert_at - 1].strip():
        block.append("\n")
    block.append(f"[{name}]\n")
    lines[insert_at:insert_at] = block
    changed = True
    return find_section(name)

def ensure_section_key(name, key, value_line):
    start, end = ensure_section(name)
    if not has_key(start, end, key):
        set_key(start, end, key, value_line)

def ensure_key_in_range(start, end, key, value_line):
    if not has_key(start, end, key):
        set_key(start, end, key, value_line)

def parse_section_values(name):
    start, end = find_section(name)
    values = {}
    if start is None:
        return values
    for line in lines[start + 1:end]:
        key = raw_key(line)
        if not key:
            continue
        raw = line.split("#", 1)[0]
        val = raw.split("=", 1)[1].strip().strip('"')
        values[key] = val
    return values

ensure_section_key("general", "data_path", 'data_path = "/run/telemt"\n')
ensure_section_key("general", "quota_state_path", 'quota_state_path = "/run/telemt/telemt.limit.json"\n')
ensure_section_key("general", "config_strict", "config_strict = true\n")
ensure_section_key("general", "beobachten", "beobachten = true\n")
ensure_section_key("general", "beobachten_minutes", "beobachten_minutes = 10\n")
ensure_section_key("general", "beobachten_flush_secs", "beobachten_flush_secs = 15\n")
ensure_section_key("general", "beobachten_file", 'beobachten_file = "/run/telemt/beobachten.txt"\n')

ensure_section_key("server.api", "request_body_limit_bytes", "request_body_limit_bytes = 65536\n")
ensure_section_key("server.api", "minimal_runtime_enabled", "minimal_runtime_enabled = true\n")
ensure_section_key("server.api", "minimal_runtime_cache_ttl_ms", "minimal_runtime_cache_ttl_ms = 1000\n")

if support_client_mss and client_mss != "off":
    ensure_section_key("server", "client_mss", f'client_mss = "{client_mss}"\n')
    if support_client_mss_bulk and client_mss_bulk != "off":
        ensure_section_key("server", "client_mss_bulk", f'client_mss_bulk = "{client_mss_bulk}"\n')

server_start, server_end = find_section("server")
if server_start is not None:
    ensure_key_in_range(server_start, server_end, "metrics_listen", 'metrics_listen = "127.0.0.1:9090"\n')
    ensure_key_in_range(server_start, server_end, "metrics_whitelist", 'metrics_whitelist = ["127.0.0.1/32", "::1/128"]\n')

for start, end in find_arrays("server.listeners"):
    if support_client_mss and client_mss != "off":
        ensure_key_in_range(start, end, "client_mss", f'client_mss = "{client_mss}"\n')
    if support_synlimit:
        current_true = False
        for i in range(start + 1, end):
            if raw_key(lines[i]) == "synlimit" and lines[i].split("#", 1)[0].split("=", 1)[1].strip().lower() == "true":
                current_true = True
                break
        if synlimit == "false":
            if current_true:
                set_key(start, end, "synlimit", "synlimit = false\n")
            else:
                ensure_key_in_range(start, end, "synlimit", "synlimit = false\n")
        else:
            ensure_key_in_range(start, end, "synlimit", f'synlimit = "{synlimit}"\n')
            ensure_key_in_range(start, end, "synlimit_seconds", f"synlimit_seconds = {syn_seconds}\n")
            ensure_key_in_range(start, end, "synlimit_hitcount", f"synlimit_hitcount = {syn_hitcount}\n")
            ensure_key_in_range(start, end, "synlimit_burst", f"synlimit_burst = {syn_burst}\n")
            ensure_key_in_range(start, end, "synlimit_ios_seconds", f"synlimit_ios_seconds = {syn_ios_seconds}\n")
            ensure_key_in_range(start, end, "synlimit_ios_hitcount", f"synlimit_ios_hitcount = {syn_ios_hitcount}\n")
            ensure_key_in_range(start, end, "synlimit_ios_burst", f"synlimit_ios_burst = {syn_ios_burst}\n")
            ensure_key_in_range(start, end, "synlimit_hashlimit_expire_ms", f"synlimit_hashlimit_expire_ms = {syn_hashlimit_expire_ms}\n")
            ensure_key_in_range(start, end, "synlimit_hashlimit_size", f"synlimit_hashlimit_size = {syn_hashlimit_size}\n")

ensure_section_key("censorship", "mask_dynamic", "mask_dynamic = false\n")
if support_exclusive_mask and domain:
    ex_start, ex_end = ensure_section("censorship.exclusive_mask")
    if not has_key(ex_start, ex_end, domain):
        set_key(ex_start, ex_end, domain, f'{json.dumps(domain)} = "127.0.0.1:8443"\n')

if support_user_enabled:
    users = parse_section_values("access.users")
    en_start, en_end = ensure_section("access.user_enabled")
    for username in users:
        if not has_key(en_start, en_end, username):
            set_key(en_start, en_end, username, f'{json.dumps(username)} = true\n')
            en_start, en_end = find_section("access.user_enabled")

upstreams = find_arrays("upstreams")
if not upstreams:
    block = '\n[[upstreams]]\ntype = "direct"\nenabled = true\nweight = 10\nipv4 = true\nipv6 = false\n'
    lines.append(block)
    changed = True
else:
    for start, end in upstreams:
        ensure_key_in_range(start, end, "ipv4", "ipv4 = true\n")
        ensure_key_in_range(start, end, "ipv6", "ipv6 = false\n")
        remove_key_in_range(start, end, "prefer")

if changed:
    path.write_text("".join(lines))
PY
}

apply_compose_runtime_compat_updates() {
  local compose_file="$INSTALL_DIR/docker-compose.yml"
  [ -f "$compose_file" ] || return 0

  python3 - "$compose_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
lines = path.read_text().splitlines(True)
changed = False

def telemt_bounds():
    start = None
    for i, line in enumerate(lines):
        if re.match(r'^\s{2}telemt:\s*$', line):
            start = i
            break
    if start is None:
        return None, None
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if re.match(r'^\s{2}[A-Za-z0-9_.-]+:\s*$', lines[i]):
            end = i
            break
    return start, end

def service_key_pattern(key):
    return re.compile(rf'^\s{{4}}{re.escape(key)}:\s*')

def service_block_end(i, end):
    j = i + 1
    while j < end and not re.match(r'^\s{4}[A-Za-z0-9_.-]+:\s*', lines[j]):
        j += 1
    return j

def remove_service_block(key):
    global changed
    start, end = telemt_bounds()
    if start is None:
        return
    pattern = service_key_pattern(key)
    i = start + 1
    while i < end:
        if pattern.match(lines[i]):
            del lines[i:service_block_end(i, end)]
            changed = True
            return
        i += 1

def set_service_scalar(key, value, anchors):
    global changed
    start, end = telemt_bounds()
    if start is None:
        return
    pattern = service_key_pattern(key)
    wanted = f"    {key}: {value}\n"
    for i in range(start + 1, end):
        if pattern.match(lines[i]):
            if lines[i] != wanted:
                lines[i] = wanted
                changed = True
            return

    insert_at = start + 1
    for anchor in anchors:
        anchor_pattern = service_key_pattern(anchor)
        found = None
        for i in range(start + 1, end):
            if anchor_pattern.match(lines[i]):
                found = service_block_end(i, end)
                break
        if found is not None:
            insert_at = found
            break
    lines.insert(insert_at, wanted)
    changed = True

def ensure_tmpfs_run_telemt():
    global changed
    start, end = telemt_bounds()
    if start is None:
        return
    if any("/run/telemt:" in line for line in lines[start:end]):
        return

    tmpfs_idx = None
    for i in range(start + 1, end):
        if re.match(r'^\s{4}tmpfs:\s*$', lines[i]):
            tmpfs_idx = i
            break

    if tmpfs_idx is not None:
        insert_at = tmpfs_idx + 1
        while insert_at < end and re.match(r'^\s{6}-\s+', lines[insert_at]):
            insert_at += 1
        lines.insert(insert_at, "      - /run/telemt:rw,nosuid,nodev,noexec,size=32m\n")
        changed = True
        return

    for anchor in ("read_only", "command", "network_mode", "restart"):
        anchor_pattern = service_key_pattern(anchor)
        start, end = telemt_bounds()
        for i in range(start + 1, end):
            if anchor_pattern.match(lines[i]):
                insert_at = service_block_end(i, end)
                lines[insert_at:insert_at] = [
                    "    tmpfs:\n",
                    "      - /run/telemt:rw,nosuid,nodev,noexec,size=32m\n",
                ]
                changed = True
                return

set_service_scalar("container_name", "telemt", ("image",))
set_service_scalar("restart", "unless-stopped", ("container_name", "image"))
set_service_scalar("network_mode", "host", ("restart", "container_name", "image"))
remove_service_block("ports")
ensure_tmpfs_run_telemt()

if changed:
    path.write_text("".join(lines))
PY
}

apply_update_compatibility_patches() {
  if is_ru; then
    say "Обновляю существующий telemt.toml/compose безопасными ключами для Telemt $(telemt_effective_version)."
  else
    say "Applying safe telemt.toml/compose compatibility keys for Telemt $(telemt_effective_version)."
  fi
  apply_telemt_config_compat_updates
  apply_compose_runtime_compat_updates
  fix_runtime_permissions
}

run_update_mode() {
  if is_ru; then
    say "Режим update: сохраняю настройки, обновляю Docker image/контейнер и проверяю host nginx/OpenSSL на Ubuntu."
  else
    say "Update mode: preserving settings, updating the Docker image/container, and validating host nginx/OpenSSL on Ubuntu."
  fi

  [ -d "$INSTALL_DIR" ] || die "Install directory not found: $INSTALL_DIR"
  [ -f "$INSTALL_DIR/docker-compose.yml" ] || die "docker-compose.yml not found: $INSTALL_DIR/docker-compose.yml"
  [ -f "$INSTALL_DIR/telemt.toml" ] || die "telemt.toml not found: $INSTALL_DIR/telemt.toml"

  [ -s "$SYSTEM_CA_FILE" ] && configure_system_ca_environment

  infer_update_config_from_existing_files
  [ -n "$DOMAIN" ] || die "Cannot detect domain from saved config or $INSTALL_DIR/telemt.toml."
  [ -n "$TELEMT_USER" ] || die "Cannot detect Telemt user from saved config or $INSTALL_DIR/telemt.toml."

  PUBLIC_IP="$(public_ipv4 || true)"
  if ! [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "Cannot detect public IPv4."
  fi

  TELEMT_CLIENT_MSS="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  TELEMT_CLIENT_MSS_BULK="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")"
  TELEMT_SYNLIMIT="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
  validate_synlimit_number TELEMT_SYNLIMIT_SECONDS "$TELEMT_SYNLIMIT_SECONDS"
  validate_synlimit_number TELEMT_SYNLIMIT_HITCOUNT "$TELEMT_SYNLIMIT_HITCOUNT"
  validate_synlimit_number TELEMT_SYNLIMIT_BURST "$TELEMT_SYNLIMIT_BURST"
  validate_synlimit_number TELEMT_SYNLIMIT_IOS_SECONDS "$TELEMT_SYNLIMIT_IOS_SECONDS"
  validate_synlimit_number TELEMT_SYNLIMIT_IOS_HITCOUNT "$TELEMT_SYNLIMIT_IOS_HITCOUNT"
  validate_synlimit_number TELEMT_SYNLIMIT_IOS_BURST "$TELEMT_SYNLIMIT_IOS_BURST"
  validate_synlimit_number TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS"
  validate_synlimit_number TELEMT_SYNLIMIT_HASHLIMIT_SIZE "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE"

  detect_current_telemt_version || true
  resolve_update_target_version
  TELEMT_UPDATE_IMAGE_BEFORE="$TELEMT_IMAGE"
  TELEMT_UPDATE_IMAGE_AFTER="$(resolve_update_image_ref "$TELEMT_IMAGE" "$TELEMT_UPDATE_TARGET_VERSION")" ||
    die "Cannot update digest-pinned image safely: $TELEMT_IMAGE"
  TELEMT_UPDATE_CONFIG_MISSING="$(build_update_config_gap_report || true)"
  [ -n "$TELEMT_UPDATE_CONFIG_MISSING" ] || TELEMT_UPDATE_CONFIG_MISSING="none"

  if is_ru; then
    cat <<EOF

План обновления:
  домен:            $DOMAIN
  публичный IPv4:   $PUBLIC_IP
  текущая версия:   ${TELEMT_DETECTED_VERSION:-unknown}${TELEMT_DETECTED_VERSION_SOURCE:+ ($TELEMT_DETECTED_VERSION_SOURCE)}
  целевая версия:   $TELEMT_UPDATE_TARGET_VERSION (точный совместимый release tag)
  Docker image:     $TELEMT_UPDATE_IMAGE_BEFORE
  target image:     $TELEMT_UPDATE_IMAGE_AFTER
  каталог:          $INSTALL_DIR
  конфиг Telemt:    будет сохранен, затем дополнен только отсутствующими безопасными ключами
  не хватает:       $TELEMT_UPDATE_CONFIG_MISSING
  compose:          будет сохранен, затем приведен к текущей Docker-схеме: network_mode host + tmpfs /run/telemt
  client_mss:       $TELEMT_CLIENT_MSS
  client_mss_bulk:  $TELEMT_CLIENT_MSS_BULK
  synlimit:         $TELEMT_SYNLIMIT
  host nginx TLS:   $(host_nginx_tls_plan)
  секреты/ссылки:   будут сохранены, ссылки будут пересобраны из текущего секрета

EOF
  else
    cat <<EOF

Update plan:
  domain:           $DOMAIN
  public IPv4:      $PUBLIC_IP
  current version:  ${TELEMT_DETECTED_VERSION:-unknown}${TELEMT_DETECTED_VERSION_SOURCE:+ ($TELEMT_DETECTED_VERSION_SOURCE)}
  target version:   $TELEMT_UPDATE_TARGET_VERSION (exact compatible release tag)
  Docker image:     $TELEMT_UPDATE_IMAGE_BEFORE
  target image:     $TELEMT_UPDATE_IMAGE_AFTER
  directory:        $INSTALL_DIR
  Telemt config:    preserved, then extended only with missing safe keys
  missing keys:     $TELEMT_UPDATE_CONFIG_MISSING
  compose:          preserved, then aligned to the current Docker layout: host networking + /run/telemt tmpfs
  client_mss:       $TELEMT_CLIENT_MSS
  client_mss_bulk:  $TELEMT_CLIENT_MSS_BULK
  synlimit:         $TELEMT_SYNLIMIT
  host nginx TLS:   $(host_nginx_tls_plan)
  secrets/links:    preserved; links regenerated from the existing secret

EOF
  fi
  confirm_plan

  ensure_docker_available
  backup_update_state
  ensure_ubuntu_nginx_openssl35
  ensure_python3_for_idn
  refresh_docker_image_for_update
  apply_update_compatibility_patches
  install_telemt_users_tool
  fix_runtime_permissions
  start_telemt
  validate_install

  if is_ru; then
    cat <<EOF

Обновление готово.

Ссылки прокси:
$(cat /root/telemt-proxy-links.txt 2>/dev/null || cat /root/telemt-proxy-link.txt 2>/dev/null || true)
EOF
  else
    cat <<EOF

Update done.

Proxy links:
$(cat /root/telemt-proxy-links.txt 2>/dev/null || cat /root/telemt-proxy-link.txt 2>/dev/null || true)
EOF
  fi
}

existing_install_found() {
  [ -f "$INSTALL_DIR/telemt.toml" ] ||
  [ -f "$INSTALL_DIR/docker-compose.yml" ] ||
  [ -f "$SECRET_FILE" ] ||
  [ -f "$SAVED_CONFIG" ] ||
  docker inspect telemt >/dev/null 2>&1
}

guard_against_accidental_reinstall() {
  [ "${RESET_INSTALL_STATE:-0}" = "1" ] && return 0
  install_in_progress && return 0
  existing_install_found || return 0

  if is_ru; then
    cat >&2 <<EOF
ОШИБКА: найдена существующая установка Telemt.

Обычный запуск установщика предназначен для чистого сервера и остановлен,
чтобы не повредить текущие nginx/Docker/Telemt настройки.

Для безопасного обновления:
  ./install_docker-telemt.sh --update -lang ru

Для ремонта/диагностики:
  ./install_docker-telemt.sh --fix-nginx -lang ru

Для осознанной переустановки с нуля:
  RESET_INSTALL_STATE=1 ./install_docker-telemt.sh -lang ru
EOF
  else
    cat >&2 <<EOF
ERROR: an existing Telemt installation was found.

Normal installer mode is intended for a clean server and has been stopped
to avoid damaging current nginx/Docker/Telemt settings.

For a safe update:
  ./install_docker-telemt.sh --update -lang en

For repair/diagnostics:
  ./install_docker-telemt.sh --fix-nginx -lang en

For an intentional clean reinstall:
  RESET_INSTALL_STATE=1 ./install_docker-telemt.sh -lang en
EOF
  fi
  exit 1
}

main() {
  parse_args "$@"
  need_root
  local requested_script_lang="$SCRIPT_LANG"
  local auto_defaults_filled="0"
  if [ "$UPDATE_MODE" = "1" ]; then
    load_config_if_exists
    if [ "$SCRIPT_LANG_FROM_CLI" = "1" ]; then
      SCRIPT_LANG="$requested_script_lang"
    fi
    require_supported_os
    run_update_mode
    exit 0
  fi
  if [ "$FIX_NGINX_MODE" = "1" ]; then
    load_config_if_exists
    if [ "$SCRIPT_LANG_FROM_CLI" = "1" ]; then
      SCRIPT_LANG="$requested_script_lang"
    fi
    require_supported_os
    run_fix_nginx_mode
    exit 0
  fi

  require_supported_os

  if [ "${RESET_INSTALL_STATE:-0}" = "1" ] && [ "$ASSUME_YES" = "1" ]; then
    fill_auto_defaults
    auto_defaults_filled="1"
  fi

  if [ "${RESET_INSTALL_STATE:-0}" = "1" ]; then
    clean_install_reset_if_requested
  else
    load_config_if_exists
    if [ "$SCRIPT_LANG_FROM_CLI" = "1" ]; then
      SCRIPT_LANG="$requested_script_lang"
    fi
    reset_resume_state_if_requested
  fi

  guard_against_accidental_reinstall
  if [ "$auto_defaults_filled" != "1" ]; then
    fill_auto_defaults
  fi
  interactive_inputs
  normalize_domain_input
  normalize_email_input
  validate_inputs
  save_config

  if ! have curl || ! have ss || ! have getent; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl iproute2 libc-bin
  fi

  PUBLIC_IP="$(public_ipv4 || true)"
  if ! [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    if is_ru; then
      die "Не удалось определить публичный IPv4."
    else
      die "Cannot detect public IPv4."
    fi
  fi

  say
  if is_ru; then
    say "[01] DNS и проверка портов"
    say "server_public_ipv4=$PUBLIC_IP"
    say "IPv4 домена:"
  else
    say "[01] DNS and port preflight"
    say "server_public_ipv4=$PUBLIC_IP"
    say "domain_ipv4s:"
  fi
  domain_ipv4s "$DOMAIN" || true
  if ! domain_ipv4s "$DOMAIN" | grep -Fxq "$PUBLIC_IP"; then
    if is_ru; then
      die "DNS A-запись для $DOMAIN не указывает на IPv4 этого сервера: $PUBLIC_IP."
    else
      die "DNS A record for $DOMAIN does not point to this server IPv4 $PUBLIC_IP."
    fi
  fi
  check_port_clean_or_nginx 80
  check_port_clean_or_nginx 443

  print_plan
  confirm_plan

  if step_done packages; then
    is_ru && say "[02] Установка пакетов (уже выполнено)" || say "[02] Install packages (already done)"
  else
    is_ru && say "[02] Установка пакетов" || say "[02] Install packages"
    install_packages
    mark_done packages
  fi

  if step_done host_nginx_tls; then
    is_ru && say "[03] Host nginx/OpenSSL (уже проверено)" || say "[03] Host nginx/OpenSSL (already checked)"
  else
    is_ru && say "[03] Проверка host nginx/OpenSSL" || say "[03] Check host nginx/OpenSSL"
    ensure_ubuntu_nginx_openssl35
    mark_done host_nginx_tls
  fi
  ensure_docker_available
  ensure_compose_available

  if step_done docker_image; then
    is_ru && say "[04] Проверка Docker image (уже выполнено)" || say "[04] Check Docker image (already done)"
  else
    is_ru && say "[04] Проверка Docker image" || say "[04] Check Docker image"
    check_docker_image
    mark_done docker_image
  fi

  if step_done high_load; then
    is_ru && say "[05] High-load tuning (уже выполнено)" || say "[05] High-load tuning (already done)"
  else
    is_ru && say "[05] High-load tuning" || say "[05] High-load tuning"
    configure_high_load
    mark_done high_load
  fi

  if step_done cert; then
    is_ru && say "[06] nginx HTTP и сертификат (уже выполнено)" || say "[06] nginx HTTP and certificate (already done)"
  else
    is_ru && say "[06] nginx HTTP и сертификат" || say "[06] nginx HTTP and certificate"
    write_mask_site_http_only
    write_firewall_hints
    verify_acme_http01_webroot
    issue_certificate
    mark_done cert
  fi

  if step_done config; then
    is_ru && say "[07] Конфиг Telemt и nginx SNI (уже выполнено)" || say "[07] Telemt config and nginx SNI (already done)"
  else
    is_ru && say "[07] Конфиг Telemt и nginx SNI" || say "[07] Telemt config and nginx SNI"
    ensure_secret
    write_telemt_config
    write_compose
    install_telemt_users_tool
    write_nginx_full_config
    write_firewall_hints
    mark_done config
  fi
  fix_runtime_permissions

  is_ru && say "[08] Запуск Telemt" || say "[08] Start Telemt"
  start_telemt

  is_ru && say "[09] Проверка" || say "[09] Validate"
  validate_install
  mark_done complete

  if is_ru; then
    cat <<EOF

Готово.

Ссылки прокси:
$(cat /root/telemt-proxy-links.txt 2>/dev/null || cat /root/telemt-proxy-link.txt 2>/dev/null || true)

Файлы:
  конфиг:       $INSTALL_DIR/telemt.toml
  compose:      $INSTALL_DIR/docker-compose.yml
  секрет:       $SECRET_FILE
  сохраненный ввод: $SAVED_CONFIG
  ссылки:       /root/telemt-proxy-links.txt
  основная ссылка: /root/telemt-proxy-link.txt
  IP-ссылка:    /root/telemt-proxy-link-ip.txt
  active probe: /root/telemt-active-probing-check.txt

Команды:
  cd $INSTALL_DIR
  docker compose ps || docker-compose ps
  curl -fsS http://127.0.0.1:9091/v1/users | jq
EOF
  else
    cat <<EOF

Done.

Proxy links:
$(cat /root/telemt-proxy-links.txt 2>/dev/null || cat /root/telemt-proxy-link.txt 2>/dev/null || true)

Files:
  config:       $INSTALL_DIR/telemt.toml
  compose:      $INSTALL_DIR/docker-compose.yml
  secret:       $SECRET_FILE
  saved input:  $SAVED_CONFIG
  links:        /root/telemt-proxy-links.txt
  primary link: /root/telemt-proxy-link.txt
  IP link:      /root/telemt-proxy-link-ip.txt
  active probe: /root/telemt-active-probing-check.txt

Commands:
  cd $INSTALL_DIR
  docker compose ps || docker-compose ps
  curl -fsS http://127.0.0.1:9091/v1/users | jq
EOF
  fi
}

if [ "${TELEMT_INSTALLER_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
