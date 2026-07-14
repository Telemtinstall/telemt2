#!/usr/bin/env bash
set -Eeuo pipefail

# Compatibility wrapper for manually installed OpenSSL builds whose compiled
# default CA path does not point to the operating system trust store.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_LANG="${SCRIPT_LANG:-ru}"
RUN_UPDATE=0
INSTALLER="${INSTALLER:-}"
DOMAIN="${DOMAIN:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
TELEMT_CA_FILE="${TELEMT_CA_FILE:-}"
LOG_FILE="${LOG_FILE:-/root/telemt-openssl-ca-check.txt}"
OPENSSL_DIR=""
RUNNING_TELEMT_VERSION=""
INSTALLER_TARGET_VERSION=""

say() { printf '%s\n' "$*"; }
die() { printf '%s\n' "$*" >&2; exit 1; }
is_ru() { [ "$SCRIPT_LANG" = "ru" ]; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  if is_ru; then
    cat <<'EOF'
Использование:
  ./update-with-system-ca.sh [-lang ru|en] [--run-update]

Переменные:
  DOMAIN=proxy.example.com       Переопределить домен Telemt.
  PUBLIC_IP=203.0.113.10         Переопределить проверяемый IPv4.
  TELEMT_CA_FILE=/path/ca.pem    Переопределить системный CA-bundle.
  INSTALLER=/path/install.sh     Переопределить путь к установщику.

По умолчанию скрипт только проверяет TLS с системным CA-bundle. С явным
--run-update он запускает официальный install_docker-telemt.sh --update,
передав ему SSL_CERT_FILE/CURL_CA_BUNDLE. Сам wrapper не изменяет сертификаты,
конфиги, пользователей и секреты; после проверки действует обычный --update.
Скрипт не устанавливает и не обновляет OpenSSL/nginx.
EOF
  else
    cat <<'EOF'
Usage:
  ./update-with-system-ca.sh [-lang ru|en] [--run-update]

Variables:
  DOMAIN=proxy.example.com       Override the Telemt domain.
  PUBLIC_IP=203.0.113.10         Override the IPv4 address to test.
  TELEMT_CA_FILE=/path/ca.pem    Override the system CA bundle.
  INSTALLER=/path/install.sh     Override the installer path.

By default the script only validates TLS with the system CA bundle. With an
explicit --run-update it runs the official install_docker-telemt.sh --update
with SSL_CERT_FILE/CURL_CA_BUNDLE set. The wrapper itself does not modify
certificates, configs, users, or secrets; regular --update behavior applies.
It does not install or upgrade OpenSSL/nginx.
EOF
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    -lang|--lang)
      [ "$#" -ge 2 ] || die "Missing value for $1"
      SCRIPT_LANG="$2"
      shift 2
      ;;
    --run-update)
      RUN_UPDATE=1
      shift
      ;;
    --check-only)
      RUN_UPDATE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

case "$SCRIPT_LANG" in
  ru|en) ;;
  *) die "Unsupported language: $SCRIPT_LANG" ;;
esac

have openssl || die "openssl not found"
have awk || die "awk not found"
have getent || die "getent not found"

find_installer() {
  local candidate

  [ -n "$INSTALLER" ] && [ -f "$INSTALLER" ] && return 0
  for candidate in \
    "$SCRIPT_DIR/install_docker-telemt.sh" \
    "$PWD/install_docker-telemt.sh" \
    /root/telemt2/telemt/docker-telemt/install_docker-telemt.sh \
    /root/docker-telemt/install_docker-telemt.sh
  do
    if [ -f "$candidate" ]; then
      INSTALLER="$candidate"
      return 0
    fi
  done
  return 1
}

detect_domain() {
  local config_file="${TELEMT_CONFIG:-/opt/telemt-docker/telemt.toml}"

  [ -n "$DOMAIN" ] && return 0
  if [ -r "$config_file" ]; then
    DOMAIN="$(awk -F'"' '/^[[:space:]]*public_host[[:space:]]*=/{print $2; exit}' "$config_file")"
  fi
  [ -n "$DOMAIN" ]
}

detect_public_ip() {
  local dns_ip local_ips

  [ -n "$PUBLIC_IP" ] && return 0
  local_ips="$(ip -4 -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' || true)"
  while IFS= read -r dns_ip; do
    [ -n "$dns_ip" ] || continue
    if printf '%s\n' "$local_ips" | grep -Fxq "$dns_ip"; then
      PUBLIC_IP="$dns_ip"
      return 0
    fi
    [ -n "$PUBLIC_IP" ] || PUBLIC_IP="$dns_ip"
  done < <(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u)
  [ -n "$PUBLIC_IP" ]
}

detect_ca_file() {
  local candidate

  if [ -n "$TELEMT_CA_FILE" ]; then
    [ -s "$TELEMT_CA_FILE" ] || return 1
    return 0
  fi

  for candidate in \
    /etc/ssl/certs/ca-certificates.crt \
    /etc/pki/tls/certs/ca-bundle.crt \
    /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
    /etc/ssl/ca-bundle.pem \
    /usr/local/etc/ssl/certs/ca-certificates.crt \
    /usr/local/etc/ssl/cert.pem \
    /etc/ssl/cert.pem
  do
    if [ -s "$candidate" ]; then
      TELEMT_CA_FILE="$candidate"
      return 0
    fi
  done
  return 1
}

detect_openssl_dir() {
  OPENSSL_DIR="$(openssl version -d 2>/dev/null | awk -F'"' '/OPENSSLDIR/{print $2; exit}' || true)"
}

detect_telemt_versions() {
  local version_output=""

  if have docker && docker inspect telemt >/dev/null 2>&1; then
    version_output="$(docker exec telemt /usr/local/bin/telemt --version 2>/dev/null || \
      docker exec telemt telemt --version 2>/dev/null || true)"
    RUNNING_TELEMT_VERSION="$(printf '%s\n' "$version_output" | sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -n 1)"
  fi

  if [ -r "$INSTALLER" ]; then
    INSTALLER_TARGET_VERSION="$(sed -nE 's/^TELEMT_LATEST_COMPATIBLE_VERSION=.*:-([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' "$INSTALLER" | head -n 1)"
  fi
}

version_gt() {
  local left="$1" right="$2"
  [ "$left" != "$right" ] && [ "$(printf '%s\n%s\n' "$left" "$right" | sort -V | tail -n 1)" = "$left" ]
}

openssl_supports_ipv4_flag() {
  openssl s_client -help 2>&1 | grep -q -- '-4'
}

run_probe() {
  local label="$1"
  local ca_file="${2:-}"
  local rc=0
  local command=(openssl s_client)

  openssl_supports_ipv4_flag && command+=(-4)
  command+=(
    -connect "${PUBLIC_IP}:443"
    -servername "$DOMAIN"
    -verify_hostname "$DOMAIN"
    -verify_return_error
  )
  [ -n "$ca_file" ] && command+=(-CAfile "$ca_file")
  command+=(-brief)

  {
    printf '\n[%s]\n' "$label"
    printf 'command='
    printf '%q ' "${command[@]}"
    printf '\n'
  } >> "$LOG_FILE"

  if have timeout; then
    timeout 15 "${command[@]}" </dev/null >> "$LOG_FILE" 2>&1 || rc=$?
  else
    "${command[@]}" </dev/null >> "$LOG_FILE" 2>&1 || rc=$?
  fi
  printf 'result=%s exit_code=%s\n' "$([ "$rc" -eq 0 ] && printf OK || printf FAILED)" "$rc" >> "$LOG_FILE"
  return "$rc"
}

[ "$(id -u)" -eq 0 ] || die "Run this script as root."
find_installer || die "install_docker-telemt.sh not found. Set INSTALLER=/full/path/install_docker-telemt.sh"
detect_domain || die "Telemt domain was not found. Set DOMAIN=proxy.example.com"
detect_public_ip || die "IPv4 for $DOMAIN was not found. Set PUBLIC_IP=x.x.x.x"
detect_ca_file || die "System CA bundle was not found. Set TELEMT_CA_FILE=/full/path/ca-bundle.pem"
detect_openssl_dir
detect_telemt_versions

: > "$LOG_FILE"
chmod 600 "$LOG_FILE" 2>/dev/null || true

if is_ru; then
  say "Домен:             $DOMAIN"
  say "Проверяемый IPv4:  $PUBLIC_IP"
  say "OpenSSL:           $(openssl version 2>/dev/null || true)"
  say "OpenSSL directory: ${OPENSSL_DIR:-unknown}"
  say "Системный CA:      $TELEMT_CA_FILE"
  say "Установщик:        $INSTALLER"
  say "Telemt сейчас:     ${RUNNING_TELEMT_VERSION:-unknown}"
  say "Target updater:    ${INSTALLER_TARGET_VERSION:-unknown}"
else
  say "Domain:            $DOMAIN"
  say "Tested IPv4:       $PUBLIC_IP"
  say "OpenSSL:           $(openssl version 2>/dev/null || true)"
  say "OpenSSL directory: ${OPENSSL_DIR:-unknown}"
  say "System CA:         $TELEMT_CA_FILE"
  say "Installer:         $INSTALLER"
  say "Running Telemt:    ${RUNNING_TELEMT_VERSION:-unknown}"
  say "Updater target:    ${INSTALLER_TARGET_VERSION:-unknown}"
fi

if [ -n "$OPENSSL_DIR" ] && [ ! -s "$OPENSSL_DIR/cert.pem" ]; then
  if is_ru; then
    say "Примечание: в OPENSSLDIR нет cert.pem; это типичная причина ошибки после отдельной установки OpenSSL."
  else
    say "Note: OPENSSLDIR has no cert.pem; this commonly causes the error after a separate OpenSSL install."
  fi
fi

default_rc=0
run_probe "OpenSSL default trust path" || default_rc=$?

system_ca_rc=0
run_probe "OpenSSL with explicit system CA bundle" "$TELEMT_CA_FILE" || system_ca_rc=$?

if [ "$system_ca_rc" -ne 0 ]; then
  sed -n '1,160p' "$LOG_FILE" >&2 || true
  if is_ru; then
    die "TLS не прошел даже с системным CA-bundle. Это не ложная ошибка пути OpenSSL: проверьте сертификат/цепочку. Лог: $LOG_FILE"
  else
    die "TLS failed even with the system CA bundle. This is not an OpenSSL path false positive; check the certificate chain. Log: $LOG_FILE"
  fi
fi

if [ "$default_rc" -ne 0 ]; then
  if is_ru; then
    say "Подтверждено: сертификат исправен, но текущий OpenSSL не использует системный CA-bundle по умолчанию."
  else
    say "Confirmed: the certificate is valid, but this OpenSSL does not use the system CA bundle by default."
  fi
else
  if is_ru; then
    say "Обычная проверка OpenSSL тоже прошла; ошибка пути CA сейчас не воспроизводится."
  else
    say "The default OpenSSL check also passed; the CA path issue is not currently reproducible."
  fi
fi

if [ "$RUN_UPDATE" -ne 1 ]; then
  if is_ru; then
    say "Проверка завершена. Лог: $LOG_FILE"
    say "Обновление не запускалось. Для явного запуска: $0 --run-update -lang ru"
  else
    say "Check completed. Log: $LOG_FILE"
    say "The update was not started. To run it explicitly: $0 --run-update -lang en"
  fi
  exit 0
fi

if [ -n "$RUNNING_TELEMT_VERSION" ] && [ -n "$INSTALLER_TARGET_VERSION" ] && \
   version_gt "$RUNNING_TELEMT_VERSION" "$INSTALLER_TARGET_VERSION"; then
  if is_ru; then
    die "Обновление не запущено: Telemt $RUNNING_TELEMT_VERSION новее target $INSTALLER_TARGET_VERSION в официальном updater. Сначала обновите совместимый target проекта, чтобы не получить откат версии."
  else
    die "Update not started: Telemt $RUNNING_TELEMT_VERSION is newer than the official updater target $INSTALLER_TARGET_VERSION. Update the project's compatible target first to avoid a downgrade."
  fi
fi

export SSL_CERT_FILE="$TELEMT_CA_FILE"
export CURL_CA_BUNDLE="$TELEMT_CA_FILE"
if [ -d /etc/ssl/certs ]; then
  export SSL_CERT_DIR=/etc/ssl/certs
fi

if is_ru; then
  say "Запускаю штатный update с системным CA-bundle. Секреты и сертификаты не изменяются."
else
  say "Starting the regular update with the system CA bundle. Secrets and certificates are unchanged."
fi

cd "$(dirname "$INSTALLER")"
exec bash "$INSTALLER" --update -lang "$SCRIPT_LANG"
