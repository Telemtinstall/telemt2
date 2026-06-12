#!/usr/bin/env bash
set -Eeuo pipefail

# Telemt systemd installer for Debian/Ubuntu servers.
# No Docker is installed or required. The updater uses an exact tested Telemt
# release tag, never a moving "latest" tag.

SCRIPT_VERSION="2026-06-12-systemd"
INSTALL_DIR="${INSTALL_DIR:-/opt/telemt-config}"
ETC_DIR="${ETC_DIR:-/etc/telemt}"
CONFIG_FILE="${CONFIG_FILE:-$ETC_DIR/telemt.toml}"
CANONICAL_CONFIG_FILE="$INSTALL_DIR/telemt.toml"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/telemt.service}"
BINARY_PATH="${BINARY_PATH:-/usr/local/bin/telemt}"
SECRET_FILE="${SECRET_FILE:-/root/telemt-secret.env}"
STATE_FILE="${STATE_FILE:-/root/.install_telemt_systemd.state}"
SAVED_CONFIG="${SAVED_CONFIG:-/root/.install_telemt_systemd.config}"
BACKUP_ROOT="${BACKUP_ROOT:-/root/telemt-systemd-install-backups}"
UPDATE_BACKUP_ROOT="${UPDATE_BACKUP_ROOT:-/root/telemt-systemd-update-backups}"
ACME_PREFLIGHT_LOG="/root/telemt-acme-http01-check.txt"

TELEMT_VERSION_ENV_SET=0
TELEMT_VERSION_ENV_VALUE=""
if [ -n "${TELEMT_VERSION+x}" ]; then
  TELEMT_VERSION_ENV_SET=1
  TELEMT_VERSION_ENV_VALUE="$TELEMT_VERSION"
fi

TELEMT_REPOSITORY="${TELEMT_REPOSITORY:-telemt/telemt}"
TELEMT_LATEST_COMPATIBLE_VERSION="${TELEMT_LATEST_COMPATIBLE_VERSION:-3.4.18}"
TELEMT_DEFAULT_VERSION="${TELEMT_DEFAULT_VERSION:-$TELEMT_LATEST_COMPATIBLE_VERSION}"
TELEMT_VERSION="${TELEMT_VERSION:-$TELEMT_DEFAULT_VERSION}"

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_ONLY_LOGIN="${SSH_KEY_ONLY_LOGIN:-no}"
SSH_KEY_ONLY_CONFIRM="${SSH_KEY_ONLY_CONFIRM:-no}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-no}"
ADD_SWAP="${ADD_SWAP:-no}"
TELEMT_USER="${TELEMT_USER:-default}"
TELEMT_USERS="${TELEMT_USERS:-}"
TELEMT_LINK_COUNT="${TELEMT_LINK_COUNT:-}"
TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-5000}"
TELEMT_CLIENT_MSS="${TELEMT_CLIENT_MSS:-tspu}"
TELEMT_SYNLIMIT="${TELEMT_SYNLIMIT:-false}"
TELEMT_SYNLIMIT_SECONDS="${TELEMT_SYNLIMIT_SECONDS:-60}"
TELEMT_SYNLIMIT_HITCOUNT="${TELEMT_SYNLIMIT_HITCOUNT:-60}"
TELEMT_SYNLIMIT_BURST="${TELEMT_SYNLIMIT_BURST:-120}"
AD_TAG="${AD_TAG:-}"
USE_MIDDLE_PROXY="${USE_MIDDLE_PROXY:-}"
ENABLE_LOGS="${ENABLE_LOGS:-no}"
ENABLE_HIGH_LOAD_TUNING="${ENABLE_HIGH_LOAD_TUNING:-yes}"
MASK_SITE_MODE="${MASK_SITE_MODE:-fancy}"
ASSUME_YES="${ASSUME_YES:-0}"
AUTO_MODE="${AUTO_MODE:-0}"
UPDATE_MODE="${UPDATE_MODE:-0}"
SCRIPT_LANG="${SCRIPT_LANG:-en}"
SCRIPT_LANG_FROM_CLI="0"
RESET_INSTALL_STATE="${RESET_INSTALL_STATE:-0}"

TELEMT_DETECTED_VERSION=""
TELEMT_DETECTED_VERSION_SOURCE=""
TELEMT_UPDATE_TARGET_VERSION=""
TELEMT_UPDATE_CONFIG_MISSING=""
BACKUP_DIR=""
ACME_PREFLIGHT_TOKEN=""
ACME_PREFLIGHT_EXPECTED=""
ACME_PREFLIGHT_PATH=""

say() { printf '%s\n' "$*"; }
is_ru() { [ "${SCRIPT_LANG:-en}" = "ru" ]; }
have() { command -v "$1" >/dev/null 2>&1; }

die() {
  if is_ru; then
    printf 'ERROR: %s\n' "$*" >&2
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
  exit 1
}

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

normalize_script_lang() {
  case "$(lower "$1")" in
    ru|rus|russian|рус|русский) printf 'ru' ;;
    en|eng|english|'') printf 'en' ;;
    *) return 1 ;;
  esac
}

usage() {
  if is_ru; then
    cat <<EOF
Использование:
  ./install_telemt_systemd.sh [-lang ru|en] [--auto] [--update]

Опции:
  -lang, --lang   Язык интерфейса: ru или en.
  --auto          Автоматический режим с default-значениями.
  --update        Обновить существующую systemd-установку Telemt.
  -h, --help      Показать справку.

Важные переменные:
  TELEMT_VERSION=<version>  Точный release tag. Default: $TELEMT_DEFAULT_VERSION
  RESET_INSTALL_STATE=1     Разрешить повторную установку поверх systemd-install.
EOF
  else
    cat <<EOF
Usage:
  ./install_telemt_systemd.sh [-lang ru|en] [--auto] [--update]

Options:
  -lang, --lang   Installer language: ru or en.
  --auto          Automatic mode with default values.
  --update        Update an existing Telemt systemd install.
  -h, --help      Show this help.

Important variables:
  TELEMT_VERSION=<version>  Exact release tag. Default: $TELEMT_DEFAULT_VERSION
  RESET_INSTALL_STATE=1     Allow reinstall over a systemd install.
EOF
  fi
}

parse_args() {
  local value show_help=0
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -lang|--lang)
        shift
        [ "$#" -gt 0 ] || die "Missing value for --lang."
        value="$1"
        SCRIPT_LANG="$(normalize_script_lang "$value")" || die "Bad language: $value"
        SCRIPT_LANG_FROM_CLI="1"
        ;;
      -lang=*|--lang=*)
        value="${1#*=}"
        SCRIPT_LANG="$(normalize_script_lang "$value")" || die "Bad language: $value"
        SCRIPT_LANG_FROM_CLI="1"
        ;;
      --auto|-auto|auto|--yes|-y|--assume-yes)
        AUTO_MODE="1"
        ASSUME_YES="1"
        ;;
      --update|-update|update)
        UPDATE_MODE="1"
        ;;
      -h|--help)
        show_help=1
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

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Run as root."
}

require_apt_systemd() {
  [ "$(uname -s)" = "Linux" ] || die "Run this installer on the target Linux server."
  have apt-get || die "This installer supports Debian/Ubuntu with apt-get."
  have systemctl || die "systemd is required."
}

require_debian_ubuntu() {
  local os_id pretty
  [ -r /etc/os-release ] || die "Cannot detect OS: /etc/os-release is missing."
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="$(lower "${ID:-}")"
  pretty="${PRETTY_NAME:-$os_id}"
  case "$os_id" in
    debian|ubuntu) ;;
    *) die "Unsupported OS: $pretty. Use Debian or Ubuntu." ;;
  esac
}

write_file_root() {
  local path="$1" mode="$2" owner="$3"
  install -d -m 0755 "$(dirname "$path")"
  cat > "$path"
  chown "$owner" "$path"
  chmod "$mode" "$path"
}

backup_path_to_dir() {
  local path="$1" dest="$2"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  install -d -m 0700 "$dest"
  cp -a "$path" "$dest"/
}

valid_domain() {
  local domain="$1"
  [ "${#domain}" -le 253 ] || return 1
  [[ "$domain" == *.* ]] || return 1
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

valid_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_limit() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 1000000 ]
}

valid_user_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.@-]{1,64}$ ]]
}

is_public_ipv4() {
  local ip="$1" a b c d octet
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
  [ "$a" -eq 10 ] && return 1
  [ "$a" -eq 127 ] && return 1
  [ "$a" -eq 169 ] && [ "$b" -eq 254 ] && return 1
  [ "$a" -eq 172 ] && [ "$b" -ge 16 ] && [ "$b" -le 31 ] && return 1
  [ "$a" -eq 192 ] && [ "$b" -eq 168 ] && return 1
  [ "$a" -eq 100 ] && [ "$b" -ge 64 ] && [ "$b" -le 127 ] && return 1
  [ "$a" -ge 224 ] && return 1
  return 0
}

public_ipv4() {
  local candidate=""
  if is_public_ipv4 "$PUBLIC_IP"; then
    printf '%s' "$PUBLIC_IP"
    return 0
  fi
  if have curl; then
    candidate="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if is_public_ipv4 "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  if have ip; then
    candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
    if is_public_ipv4 "$candidate"; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  return 1
}

detect_public_ip() {
  PUBLIC_IP="$(public_ipv4 || true)"
  is_public_ipv4 "$PUBLIC_IP" || die "Could not detect public IPv4. Set PUBLIC_IP explicitly."
}

resolve_ipv4() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

port_listening() {
  local port="$1"
  ss -H -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" {found=1} END {exit found ? 0 : 1}'
}

step_done() {
  [ -f "$STATE_FILE" ] && grep -Fxq "$1" "$STATE_FILE"
}

mark_done() {
  local id="$1"
  touch "$STATE_FILE"
  grep -Fxq "$id" "$STATE_FILE" 2>/dev/null || printf '%s\n' "$id" >> "$STATE_FILE"
}

step_no=0
step() {
  step_no=$((step_no + 1))
  printf '\n[%02d] %s\n' "$step_no" "$1"
}

prompt() {
  local var="$1" label="$2" default_value="${3:-}" answer="" current_value="${!var:-}"
  if [ "$ASSUME_YES" = "1" ] && [ -n "$current_value" ]; then
    printf '%s: %s\n' "$label" "$current_value"
    return 0
  fi
  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$label" "$default_value"
  else
    printf '%s: ' "$label"
  fi
  read -r answer
  if [ -n "$answer" ]; then
    printf -v "$var" '%s' "$answer"
  else
    printf -v "$var" '%s' "$default_value"
  fi
}

prompt_yes_no() {
  local var="$1" label="$2" default_value="${3:-no}" value
  prompt "$var" "$label" "$default_value"
  value="$(lower "${!var:-}")"
  case "$value" in
    y|yes) printf -v "$var" '%s' "yes" ;;
    n|no|"") printf -v "$var" '%s' "no" ;;
    *) die "$label must be yes or no." ;;
  esac
}

confirm_plan() {
  local confirm
  if [ "$ASSUME_YES" = "1" ]; then
    say "ASSUME_YES=1, continuing."
    return 0
  fi
  if is_ru; then
    printf 'Введите y или yes для продолжения: '
  else
    printf 'Type y or yes to continue: '
  fi
  read -r confirm
  case "$(lower "$confirm")" in
    y|yes) ;;
    *) die "Cancelled." ;;
  esac
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

validate_telemt_version() {
  local normalized
  if normalized="$(normalize_exact_telemt_version "$TELEMT_VERSION" 2>/dev/null)"; then
    TELEMT_VERSION="$normalized"
    return 0
  fi
  if [ "$(lower "$TELEMT_VERSION")" = "latest" ]; then
    die "TELEMT_VERSION=latest is disabled. Use an exact release tag like $TELEMT_LATEST_COMPATIBLE_VERSION."
  fi
  die "Bad TELEMT_VERSION: $TELEMT_VERSION. Use an exact release tag like $TELEMT_LATEST_COMPATIBLE_VERSION."
}

telemt_version_from_text() {
  sed -n 's/^telemt[[:space:]]\+v\{0,1\}\([0-9][0-9.]*\).*/\1/p' | sed -n '1p'
}

detect_installed_telemt_version() {
  local output version
  [ -x "$BINARY_PATH" ] || return 1
  output="$("$BINARY_PATH" --version 2>/dev/null || true)"
  version="$(printf '%s\n' "$output" | telemt_version_from_text)"
  if is_exact_telemt_version "$version"; then
    printf '%s' "$version"
    return 0
  fi
  return 1
}

detect_current_telemt_version() {
  local version
  TELEMT_DETECTED_VERSION=""
  TELEMT_DETECTED_VERSION_SOURCE=""
  if version="$(detect_installed_telemt_version)"; then
    TELEMT_DETECTED_VERSION="$version"
    TELEMT_DETECTED_VERSION_SOURCE="$BINARY_PATH"
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
      say "WARN: TELEMT_VERSION=latest is ignored in --update; using checked compatible version $TELEMT_LATEST_COMPATIBLE_VERSION."
    else
      die "Bad TELEMT_VERSION for --update: use an exact release tag like $TELEMT_LATEST_COMPATIBLE_VERSION, not '$requested'."
    fi
  fi
  TELEMT_UPDATE_TARGET_VERSION="$TELEMT_LATEST_COMPATIBLE_VERSION"
  TELEMT_VERSION="$TELEMT_UPDATE_TARGET_VERSION"
  is_exact_telemt_version "$TELEMT_UPDATE_TARGET_VERSION" ||
    die "Bad TELEMT_LATEST_COMPATIBLE_VERSION: $TELEMT_UPDATE_TARGET_VERSION"
}

telemt_version_effective() {
  local version="${TELEMT_VERSION:-$TELEMT_DEFAULT_VERSION}"
  version="${version#v}"
  if ! [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
    version="$TELEMT_DEFAULT_VERSION"
  fi
  printf '%s' "$version"
}

telemt_version_at_least() {
  local wanted_major="$1" wanted_minor="$2" wanted_patch="$3"
  local version major minor patch
  version="$(telemt_version_effective)"
  IFS=. read -r major minor patch <<< "$version"
  minor="${minor:-0}"
  patch="${patch:-0}"
  [ "$major" -gt "$wanted_major" ] && return 0
  [ "$major" -lt "$wanted_major" ] && return 1
  [ "$minor" -gt "$wanted_minor" ] && return 0
  [ "$minor" -lt "$wanted_minor" ] && return 1
  [ "$patch" -ge "$wanted_patch" ]
}

telemt_version_supports_exclusive_mask() { telemt_version_at_least 3 4 12; }
telemt_version_supports_user_enabled() { telemt_version_at_least 3 4 14; }
telemt_version_supports_client_mss() { telemt_version_at_least 3 4 15; }
telemt_version_supports_synlimit() { telemt_version_at_least 3 4 18; }

telemt_asset() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'telemt-x86_64-linux-musl.tar.gz' ;;
    aarch64|arm64) printf 'telemt-aarch64-linux-musl.tar.gz' ;;
    *) die "Unsupported architecture: $(uname -m). Use x86_64 or aarch64." ;;
  esac
}

download_and_install_telemt_binary() {
  local asset tmp_dir base_url bin_path output version
  validate_telemt_version
  asset="$(telemt_asset)"
  tmp_dir="$(mktemp -d /tmp/telemt-release.XXXXXX)"
  base_url="https://github.com/${TELEMT_REPOSITORY}/releases/download/${TELEMT_VERSION}"

  say "Downloading Telemt ${TELEMT_VERSION}: ${base_url}/${asset}"
  curl -fL --retry 5 --retry-delay 3 --connect-timeout 10 --max-time 180 \
    -o "$tmp_dir/$asset" "$base_url/$asset"
  curl -fL --retry 5 --retry-delay 3 --connect-timeout 10 --max-time 60 \
    -o "$tmp_dir/$asset.sha256" "$base_url/$asset.sha256"
  (cd "$tmp_dir" && sha256sum -c "$asset.sha256")
  tar -xzf "$tmp_dir/$asset" -C "$tmp_dir"
  bin_path="$(find "$tmp_dir" -type f -name telemt | head -n 1)"
  [ -n "$bin_path" ] || die "Telemt binary was not found inside release archive."

  install -m 0755 "$bin_path" "$tmp_dir/telemt"
  output="$("$tmp_dir/telemt" --version 2>/dev/null || true)"
  version="$(printf '%s\n' "$output" | telemt_version_from_text)"
  if [ -n "$version" ] && [ "$version" != "$TELEMT_VERSION" ]; then
    die "Downloaded binary version mismatch: expected $TELEMT_VERSION, got $version."
  fi

  if [ -x "$BINARY_PATH" ]; then
    backup_path_to_dir "$BINARY_PATH" "${BACKUP_DIR:-$UPDATE_BACKUP_ROOT/manual-binary-backup}"
  fi
  install -m 0755 "$tmp_dir/telemt" "$BINARY_PATH"
  chown root:root "$BINARY_PATH"
  "$BINARY_PATH" --version || true
  rm -rf "$tmp_dir"
}

save_resume_config() {
  umask 077
  cat > "$SAVED_CONFIG" <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
EMAIL=$(printf '%q' "$EMAIL")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
SSH_PORT=$(printf '%q' "$SSH_PORT")
SSH_KEY_ONLY_LOGIN=$(printf '%q' "$SSH_KEY_ONLY_LOGIN")
SSH_KEY_ONLY_CONFIRM=$(printf '%q' "$SSH_KEY_ONLY_CONFIRM")
ENABLE_FAIL2BAN=$(printf '%q' "$ENABLE_FAIL2BAN")
ADD_SWAP=$(printf '%q' "$ADD_SWAP")
TELEMT_VERSION=$(printf '%q' "$TELEMT_VERSION")
TELEMT_USER=$(printf '%q' "$TELEMT_USER")
TELEMT_USERS=$(printf '%q' "$TELEMT_USERS")
TELEMT_LINK_COUNT=$(printf '%q' "$TELEMT_LINK_COUNT")
TELEMT_MAX_TCP_CONNS=$(printf '%q' "$TELEMT_MAX_TCP_CONNS")
TELEMT_CLIENT_MSS=$(printf '%q' "$TELEMT_CLIENT_MSS")
TELEMT_SYNLIMIT=$(printf '%q' "$TELEMT_SYNLIMIT")
TELEMT_SYNLIMIT_SECONDS=$(printf '%q' "$TELEMT_SYNLIMIT_SECONDS")
TELEMT_SYNLIMIT_HITCOUNT=$(printf '%q' "$TELEMT_SYNLIMIT_HITCOUNT")
TELEMT_SYNLIMIT_BURST=$(printf '%q' "$TELEMT_SYNLIMIT_BURST")
AD_TAG=$(printf '%q' "$AD_TAG")
USE_MIDDLE_PROXY=$(printf '%q' "$USE_MIDDLE_PROXY")
ENABLE_LOGS=$(printf '%q' "$ENABLE_LOGS")
ENABLE_HIGH_LOAD_TUNING=$(printf '%q' "$ENABLE_HIGH_LOAD_TUNING")
MASK_SITE_MODE=$(printf '%q' "$MASK_SITE_MODE")
BACKUP_DIR=$(printf '%q' "$BACKUP_DIR")
EOF
  chmod 600 "$SAVED_CONFIG"
}

root_authorized_key_exists() {
  [ -f /root/.ssh/authorized_keys ] &&
    grep -Eq '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]' /root/.ssh/authorized_keys
}

remove_installer_key_only_config_if_present() {
  local conf="/etc/ssh/sshd_config.d/00password.conf"
  [ -f "$conf" ] || return 0
  if grep -Eq '^PasswordAuthentication[[:space:]]+no' "$conf" &&
     grep -Eq '^KbdInteractiveAuthentication[[:space:]]+no' "$conf" &&
     grep -Eq '^PubkeyAuthentication[[:space:]]+yes' "$conf"; then
    rm -f "$conf"
    say "Removed installer key-only SSH config; password login is left to the base sshd_config."
  fi
}

append_telemt_user() {
  local user="$1"
  valid_user_name "$user" || die "Bad Telemt user name: $user"
  if [ -z "$TELEMT_USERS" ]; then
    TELEMT_USERS="$user"
  elif ! printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | grep -Fxq "$user"; then
    TELEMT_USERS="${TELEMT_USERS},${user}"
  fi
}

normalize_telemt_users() {
  local user
  [ -n "$TELEMT_USER" ] || TELEMT_USER="default"
  TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
  local normalized=""
  while IFS= read -r user; do
    user="$(printf '%s' "$user" | xargs)"
    [ -n "$user" ] || continue
    valid_user_name "$user" || die "Bad Telemt user name: $user"
    if [ -z "$normalized" ]; then
      normalized="$user"
    elif ! printf '%s\n' "$normalized" | tr ',' '\n' | grep -Fxq "$user"; then
      normalized="${normalized},${user}"
    fi
  done < <(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n')
  [ -n "$normalized" ] || normalized="$TELEMT_USER"
  TELEMT_USERS="$normalized"
  TELEMT_USER="$(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | sed -n '1p')"
}

telemt_users_list() {
  normalize_telemt_users
  printf '%s\n' "$TELEMT_USERS" | tr ',' '\n'
}

telemt_users_toml_array() {
  local first=1 user
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

normalize_client_mss() {
  local value="$(lower "$1")"
  case "$value" in
    off|none|no|false|0) printf 'off' ;;
    tspu|2in8|extreme-low) printf '%s' "$value" ;;
    *)
      if [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 88 ] && [ "$value" -le 4096 ]; then
        printf '%s' "$value"
      else
        die "Bad TELEMT_CLIENT_MSS: $1"
      fi
      ;;
  esac
}

normalize_synlimit() {
  local value="$(lower "$1")"
  case "$value" in
    false|no|off|0) printf 'false' ;;
    iptables|nftables) printf '%s' "$value" ;;
    *) die "Bad TELEMT_SYNLIMIT: $1" ;;
  esac
}

validate_synlimit_number() {
  local name="$1" value="$2"
  [[ "$value" =~ ^[0-9]+$ ]] && [ "$value" -ge 1 ] && [ "$value" -le 1000000 ] ||
    die "$name must be a number from 1 to 1000000."
}

ensure_secret() {
  install -d -m 0700 "$(dirname "$SECRET_FILE")"
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

secret_for_user() {
  local user="$1"
  if [ "$user" = "$TELEMT_USER" ]; then
    printf '%s' "$TELEMT_SECRET"
  else
    openssl rand -hex 16
  fi
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y \
    ca-certificates curl openssl iproute2 nftables nginx libnginx-mod-stream \
    certbot jq python3 tar coreutils procps dnsutils
}

ensure_telemt_account() {
  local group_name="65532"
  if ! getent group 65532 >/dev/null 2>&1; then
    if ! getent group telemt >/dev/null 2>&1; then
      groupadd --system --gid 65532 telemt 2>/dev/null || true
    fi
  fi
  if getent group 65532 >/dev/null 2>&1; then
    group_name="$(getent group 65532 | cut -d: -f1)"
  fi
  if ! getent passwd 65532 >/dev/null 2>&1; then
    if ! getent passwd telemt >/dev/null 2>&1; then
      useradd --system --uid 65532 --gid "$group_name" --home-dir /nonexistent --shell /usr/sbin/nologin telemt 2>/dev/null || true
    fi
  fi
}

open_public_firewall_ports() {
  if have ufw && ufw status 2>/dev/null | grep -q "Status: active"; then
    ufw allow 80/tcp || true
    ufw allow 443/tcp || true
  fi
  if have firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
    firewall-cmd --permanent --add-port=80/tcp || true
    firewall-cmd --permanent --add-port=443/tcp || true
    firewall-cmd --reload || true
  fi
}

configure_nft_api_block() {
  write_file_root /etc/nftables-local-hardening.conf 0755 root:root <<'EOF'
#!/usr/sbin/nft -f

destroy table inet local_hardening

table inet local_hardening {
    chain input {
        type filter hook input priority -10; policy accept;
        iifname "lo" accept
        tcp dport 9091 drop
        tcp dport 9090 drop
    }
}
EOF
  write_file_root /etc/systemd/system/local-hardening-nft.service 0644 root:root <<'EOF'
[Unit]
Description=Local nftables hardening rules
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target
After=systemd-modules-load.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f /etc/nftables-local-hardening.conf
ExecReload=/usr/sbin/nft -f /etc/nftables-local-hardening.conf
ExecStop=/usr/sbin/nft delete table inet local_hardening

[Install]
WantedBy=sysinit.target
EOF
  systemctl daemon-reload
  systemctl enable --now local-hardening-nft
}

configure_high_load() {
  [ "$ENABLE_HIGH_LOAD_TUNING" = "yes" ] || return 0
  write_file_root /etc/sysctl.d/99-telemt-high-load.conf 0644 root:root <<'EOF'
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
    cat >> /etc/sysctl.d/99-telemt-high-load.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  fi
  sysctl --system
}

configure_certbot_renewal() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  write_file_root /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-telemt.sh 0755 root:root <<'EOF'
#!/usr/bin/env bash
set -e
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl reload nginx || systemctl restart nginx
fi
EOF
  systemctl enable --now certbot.timer 2>/dev/null || true
}

nginx_mask_site_available_path() { printf '/etc/nginx/sites-available/%s' "$DOMAIN"; }
nginx_mask_site_enabled_path() { printf '/etc/nginx/sites-enabled/%s' "$DOMAIN"; }
nginx_stream_canonical_path() { printf '/etc/nginx/modules-enabled/60-telemt-stream-sni.conf'; }

stream_config_managed() {
  local file="$1"
  [ -f "$file" ] && grep -q 'telemt_backend' "$file" && grep -q 'ssl_preread' "$file"
}

ensure_https_frontdoor_available() {
  if ! port_listening 443; then
    return 0
  fi
  if stream_config_managed /etc/nginx/modules-enabled/60-telemt-stream-sni.conf ||
     stream_config_managed /etc/nginx/modules-enabled/60-stream-sni.conf ||
     stream_config_managed /etc/nginx/modules-enabled/90-stream-sni.conf; then
    return 0
  fi
  die "Port 443 is already used by another service. Move it behind nginx stream or use a clean server."
}

write_mask_site_index() {
  local install_started_at
  install_started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  install -d -m 0755 "/var/www/$DOMAIN/.well-known/acme-challenge"

  if [ "$MASK_SITE_MODE" = "empty" ]; then
    : > "/var/www/$DOMAIN/index.html"
    chmod 0644 "/var/www/$DOMAIN/index.html"
    return 0
  fi

  cat > "/var/www/$DOMAIN/index.html" <<EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${DOMAIN}</title>
  <style>
    :root { color-scheme: dark; --bg:#202020; --text:#f7f7f5; --muted:#b9b9b4; --panel:#f4f4f1; --ink:#2a2a2a; }
    * { box-sizing: border-box; }
    html, body { min-height: 100%; margin: 0; }
    body { font-family: system-ui, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; background: var(--bg); color: var(--text); display: grid; place-items: center; padding: 40px 22px; }
    main { width: min(980px, 100%); display: grid; gap: 48px; }
    .domain { color: var(--muted); font-size: 15px; letter-spacing: .08em; text-transform: uppercase; }
    h1 { font-size: clamp(42px, 8vw, 82px); line-height: .94; margin: 0 0 20px; letter-spacing: 0; text-transform: uppercase; }
    .timer-label { margin: 34px 0 14px; color: var(--muted); font-size: 16px; }
    .timer { background: var(--panel); color: var(--ink); border-radius: 8px; padding: 28px 30px; display: grid; grid-template-columns: repeat(4, minmax(80px, 1fr)); gap: 18px; width: min(650px, 100%); }
    .num { display: block; font-size: clamp(34px, 6vw, 58px); font-weight: 300; line-height: 1; font-variant-numeric: tabular-nums; }
    .unit { display: block; margin-top: 10px; color: #676761; font-size: 11px; letter-spacing: .18em; text-transform: uppercase; }
    @media (max-width: 640px) { .timer { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
  </style>
</head>
<body>
  <main>
    <div class="domain">${DOMAIN}</div>
    <section aria-label="status">
      <h1>Сайт уже работает</h1>
      <div class="timer-label">Работает с момента установки:</div>
      <div class="timer" aria-live="polite">
        <div><span class="num" id="days">0</span><span class="unit">дней</span></div>
        <div><span class="num" id="hours">00</span><span class="unit">часов</span></div>
        <div><span class="num" id="minutes">00</span><span class="unit">минут</span></div>
        <div><span class="num" id="seconds">00</span><span class="unit">секунд</span></div>
      </div>
    </section>
  </main>
  <script>
    const startedAt = new Date("${install_started_at}");
    const pad = function(value) { return String(value).padStart(2, "0"); };
    function updateTimer() {
      const diff = Math.max(0, Date.now() - startedAt.getTime());
      const totalSeconds = Math.floor(diff / 1000);
      document.getElementById("days").textContent = String(Math.floor(totalSeconds / 86400));
      document.getElementById("hours").textContent = pad(Math.floor(totalSeconds % 86400 / 3600));
      document.getElementById("minutes").textContent = pad(Math.floor(totalSeconds % 3600 / 60));
      document.getElementById("seconds").textContent = pad(totalSeconds % 60);
    }
    updateTimer();
    setInterval(updateTimer, 1000);
  </script>
</body>
</html>
EOF
  chmod 0644 "/var/www/$DOMAIN/index.html"
}

write_mask_site_http_only() {
  local access_log_line="access_log off;"
  [ "$ENABLE_LOGS" = "yes" ] && access_log_line="access_log /var/log/nginx/${DOMAIN}.access.log;"
  write_mask_site_index
  write_file_root "$(nginx_mask_site_available_path)" 0644 root:root <<EOF
# Managed by install_telemt_systemd.sh. Do not edit manually.
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
EOF
  ln -sfn "$(nginx_mask_site_available_path)" "$(nginx_mask_site_enabled_path)"
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx || systemctl restart nginx
}

write_nginx_full_config() {
  local old_stream access_log_line="access_log off;"
  [ "$ENABLE_LOGS" = "yes" ] && access_log_line="access_log /var/log/nginx/${DOMAIN}.access.log;"
  write_mask_site_index
  write_file_root "$(nginx_mask_site_available_path)" 0644 root:root <<EOF
# Managed by install_telemt_systemd.sh. Do not edit manually.
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

  for old_stream in /etc/nginx/modules-enabled/60-stream-sni.conf /etc/nginx/modules-enabled/90-stream-sni.conf; do
    if [ "$old_stream" != "$(nginx_stream_canonical_path)" ] && stream_config_managed "$old_stream"; then
      backup_path_to_dir "$old_stream" "$BACKUP_DIR"
      rm -f "$old_stream"
    fi
  done

  write_file_root "$(nginx_stream_canonical_path)" 0644 root:root <<EOF
# Managed by install_telemt_systemd.sh. Do not edit manually.
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
  systemctl enable --now nginx
  systemctl reload nginx || systemctl restart nginx
}

append_acme_diagnostics() {
  local log_file="$1" dns_a="" dns_aaaa=""
  {
    printf '\n[automatic ACME HTTP-01 diagnostics]\n'
    printf 'domain=%s\n' "$DOMAIN"
    printf 'server_public_ipv4=%s\n' "$PUBLIC_IP"
    printf 'time=%s\n' "$(date -Is 2>/dev/null || date)"
    printf '\n[dns]\n'
    dns_a="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    dns_aaaa="$(getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1}' | sort -u | tr '\n' ' ' | sed 's/[[:space:]]*$//' || true)"
    printf 'A/IPv4: %s\n' "${dns_a:-not found}"
    printf 'AAAA/IPv6: %s\n' "${dns_aaaa:-not found}"
    printf '\n[listening ports]\n'
    ss -lntp 2>&1 | grep -E ':(80|443|8443|1443|9090|9091)\b' || true
    printf '\n[nginx]\n'
    systemctl is-active nginx 2>/dev/null | sed 's/^/nginx_active=/' || true
    nginx -t 2>&1 || true
    printf '\n[firewall]\n'
    have ufw && ufw status verbose 2>&1 || true
    have firewall-cmd && firewall-cmd --state 2>&1 && firewall-cmd --list-all 2>&1 || true
  } >> "$log_file"
}

acme_http01_failed() {
  local log_file="$1" failed_check="$2"
  append_acme_diagnostics "$log_file"
  cat "$log_file" >&2 || true
  die "Let's Encrypt HTTP-01 challenge is not reachable: $failed_check. Full log: $log_file"
}

verify_acme_http01_webroot() {
  local local_body="" public_body=""
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
  } >> "$ACME_PREFLIGHT_LOG"

  local_body="$(curl -4fsS --connect-timeout 5 --max-time 10 -H "Host: ${DOMAIN}" \
    "http://127.0.0.1/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}" 2>>"$ACME_PREFLIGHT_LOG" || true)"
  [ "$local_body" = "$ACME_PREFLIGHT_EXPECTED" ] ||
    acme_http01_failed "$ACME_PREFLIGHT_LOG" "local nginx webroot check"

  public_body="$(curl -4fsS --connect-timeout 8 --max-time 20 --resolve "${DOMAIN}:80:${PUBLIC_IP}" \
    "http://${DOMAIN}/.well-known/acme-challenge/${ACME_PREFLIGHT_TOKEN}" 2>>"$ACME_PREFLIGHT_LOG" || true)"
  [ "$public_body" = "$ACME_PREFLIGHT_EXPECTED" ] ||
    acme_http01_failed "$ACME_PREFLIGHT_LOG" "public IPv4 webroot check"
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
}

hex_encode_ascii() {
  LC_ALL=C printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

write_proxy_links() {
  local domain_hex user secret tls_secret first_https="" first_direct_https=""
  domain_hex="$(hex_encode_ascii "$DOMAIN")"
  {
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
        if (key != "" && val ~ /^[A-Fa-f0-9]{32}$/) print key, val
      }
    ' "$CONFIG_FILE" | while read -r user secret; do
      secret="$(printf '%s' "$secret" | tr 'A-F' 'a-f')"
      tls_secret="ee${secret}${domain_hex}"
      printf '# user: %s\n' "$user"
      printf 'https://t.me/proxy?server=%s&port=443&secret=%s\n' "$DOMAIN" "$tls_secret"
      printf 'tg://proxy?server=%s&port=443&secret=%s\n\n' "$DOMAIN" "$tls_secret"
      if [ -n "${PUBLIC_IP:-}" ] && [ "$PUBLIC_IP" != "$DOMAIN" ]; then
        printf '# direct IP variant, TLS SNI remains %s\n' "$DOMAIN"
        printf 'https://t.me/proxy?server=%s&port=443&secret=%s\n' "$PUBLIC_IP" "$tls_secret"
        printf 'tg://proxy?server=%s&port=443&secret=%s\n\n' "$PUBLIC_IP" "$tls_secret"
      fi
    done
  } > /root/telemt-proxy-links.txt
  first_https="$(grep -m1 '^https://t.me/proxy?' /root/telemt-proxy-links.txt || true)"
  first_direct_https="$(awk '/^# direct IP variant/{getline; print; exit}' /root/telemt-proxy-links.txt || true)"
  [ -n "$first_https" ] || die "Cannot generate proxy links from $CONFIG_FILE."
  printf '%s\n' "$first_https" > /root/telemt-proxy-link.txt
  [ -n "$first_direct_https" ] && printf '%s\n' "$first_direct_https" > /root/telemt-proxy-link-ip.txt
  chmod 600 /root/telemt-proxy-link.txt /root/telemt-proxy-links.txt /root/telemt-proxy-link-ip.txt 2>/dev/null || true
}

write_telemt_config() {
  local middle_bool="false" users_array user secret client_mss synlimit_value
  [ "$USE_MIDDLE_PROXY" = "yes" ] && middle_bool="true"
  normalize_telemt_users
  users_array="$(telemt_users_toml_array)"
  client_mss="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  synlimit_value="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
  install -d -m 0755 "$ETC_DIR"
  install -d -m 0750 "$INSTALL_DIR"
  chown 65532:65532 "$INSTALL_DIR" || die "Cannot chown $INSTALL_DIR to 65532:65532."

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
    [ -n "$AD_TAG" ] && printf 'ad_tag = "%s"\n' "$AD_TAG"
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
      secret="$(secret_for_user "$user")"
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
prefer = 4
EOF
  } > "$CANONICAL_CONFIG_FILE"
  chown 65532:65532 "$CANONICAL_CONFIG_FILE" || die "Cannot chown $CANONICAL_CONFIG_FILE to 65532:65532."
  chmod 600 "$CANONICAL_CONFIG_FILE"
  ln -sfn "$CANONICAL_CONFIG_FILE" "$CONFIG_FILE"
}

write_systemd_service() {
  install -d -m 0755 "$ETC_DIR"
  if [ -f "$CANONICAL_CONFIG_FILE" ] && [ "$CONFIG_FILE" != "$CANONICAL_CONFIG_FILE" ]; then
    ln -sfn "$CANONICAL_CONFIG_FILE" "$CONFIG_FILE"
  fi
  write_file_root "$SERVICE_FILE" 0644 root:root <<EOF
[Unit]
Description=Telemt MTProto proxy
Documentation=https://github.com/telemt/telemt
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=65532
Group=65532
WorkingDirectory=${ETC_DIR}
Environment=RUST_LOG=warn
ExecStart=${BINARY_PATH} ${CONFIG_FILE}
Restart=always
RestartSec=3
LimitNOFILE=65535
RuntimeDirectory=telemt
RuntimeDirectoryMode=0750
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
SystemCallArchitectures=native
ReadWritePaths=/run/telemt

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

start_telemt_service() {
  write_systemd_service
  systemctl enable --now telemt
  systemctl restart telemt
}

toml_value_from_section() {
  local file="$1" section="$2" key="$3"
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
      if (key == wanted) { print val; exit }
    }
  ' "$file"
}

first_toml_key_from_section() {
  local file="$1" section="$2"
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
      if (key != "") { print key; exit }
    }
  ' "$file"
}

infer_update_config_from_existing_files() {
  local config existing_domain existing_user
  if [ -f "$CONFIG_FILE" ]; then
    config="$CONFIG_FILE"
  elif [ -f "$CANONICAL_CONFIG_FILE" ]; then
    config="$CANONICAL_CONFIG_FILE"
    CONFIG_FILE="$CANONICAL_CONFIG_FILE"
  else
    die "Telemt config not found: $CONFIG_FILE or $CANONICAL_CONFIG_FILE"
  fi
  existing_domain="$(toml_value_from_section "$config" "general\\.links" "public_host" || true)"
  [ -n "$existing_domain" ] || existing_domain="$(toml_value_from_section "$config" "censorship" "tls_domain" || true)"
  existing_user="$(first_toml_key_from_section "$config" "access\\.users" || true)"
  [ -n "$existing_domain" ] && DOMAIN="${DOMAIN:-$existing_domain}"
  [ -n "$existing_user" ] && TELEMT_USER="${TELEMT_USER:-$existing_user}"
  [ -n "$DOMAIN" ] || die "Cannot detect domain from $config."
  valid_domain "$DOMAIN" || die "Detected bad domain from config: $DOMAIN"
}

build_update_config_gap_report() {
  local config_file="$CONFIG_FILE"
  local support_exclusive_mask=0 support_user_enabled=0 support_client_mss=0 support_synlimit=0
  [ -f "$config_file" ] || return 0
  have python3 || { printf 'python3 unavailable'; return 0; }
  telemt_version_supports_exclusive_mask && support_exclusive_mask=1
  telemt_version_supports_user_enabled && support_user_enabled=1
  telemt_version_supports_client_mss && support_client_mss=1
  telemt_version_supports_synlimit && support_synlimit=1
  python3 - "$config_file" "$DOMAIN" "$support_exclusive_mask" "$support_user_enabled" "$support_client_mss" "$support_synlimit" <<'PY'
import re
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
domain = sys.argv[2]
support_exclusive_mask = sys.argv[3] == "1"
support_user_enabled = sys.argv[4] == "1"
support_client_mss = sys.argv[5] == "1"
support_synlimit = sys.argv[6] == "1"
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
if support_client_mss:
    checks.append(("server.client_mss", section_has("server", "client_mss")))
    checks.append(("server.listeners.client_mss", arrays_have("server.listeners", "client_mss")))
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
    checks.append(("upstreams.prefer", all(has_key(start, end, "prefer") for start, end in upstreams)))
else:
    checks.append(("upstreams", False))
missing = [name for name, ok in checks if not ok]
print(", ".join(missing) if missing else "none")
PY
}

apply_telemt_config_compat_updates() {
  local config_file="$CONFIG_FILE" client_mss synlimit_value
  local support_exclusive_mask=0 support_user_enabled=0 support_client_mss=0 support_synlimit=0
  [ -f "$config_file" ] || return 0
  client_mss="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  synlimit_value="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
  telemt_version_supports_exclusive_mask && support_exclusive_mask=1
  telemt_version_supports_user_enabled && support_user_enabled=1
  telemt_version_supports_client_mss && support_client_mss=1
  telemt_version_supports_synlimit && support_synlimit=1
  python3 - "$config_file" "$DOMAIN" "$PUBLIC_IP" "$client_mss" "$synlimit_value" \
    "$TELEMT_SYNLIMIT_SECONDS" "$TELEMT_SYNLIMIT_HITCOUNT" "$TELEMT_SYNLIMIT_BURST" \
    "$support_exclusive_mask" "$support_user_enabled" "$support_client_mss" "$support_synlimit" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
domain, public_ip, client_mss, synlimit = sys.argv[2:6]
syn_seconds, syn_hitcount, syn_burst = sys.argv[6:9]
support_exclusive_mask = sys.argv[9] == "1"
support_user_enabled = sys.argv[10] == "1"
support_client_mss = sys.argv[11] == "1"
support_synlimit = sys.argv[12] == "1"
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
    return start is not None and any(raw_key(line) == key for line in lines[start + 1:end])

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
    if insert_at > 0 and lines[insert_at - 1].strip():
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
server_start, server_end = ensure_section("server")
ensure_key_in_range(server_start, server_end, "metrics_listen", 'metrics_listen = "127.0.0.1:9090"\n')
ensure_key_in_range(server_start, server_end, "metrics_whitelist", 'metrics_whitelist = ["127.0.0.1/32", "::1/128"]\n')
if support_client_mss and client_mss != "off":
    ensure_key_in_range(server_start, server_end, "client_mss", f'client_mss = "{client_mss}"\n')

listeners = find_arrays("server.listeners")
if not listeners:
    lines.append(f'\n[[server.listeners]]\nip = "127.0.0.1"\nannounce = "{public_ip}"\n')
    changed = True
    listeners = find_arrays("server.listeners")
for start, end in listeners:
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
            if current_true:
                set_key(start, end, "synlimit", f'synlimit = "{synlimit}"\n')
            else:
                ensure_key_in_range(start, end, "synlimit", f'synlimit = "{synlimit}"\n')
            ensure_key_in_range(start, end, "synlimit_seconds", f"synlimit_seconds = {syn_seconds}\n")
            ensure_key_in_range(start, end, "synlimit_hitcount", f"synlimit_hitcount = {syn_hitcount}\n")
            ensure_key_in_range(start, end, "synlimit_burst", f"synlimit_burst = {syn_burst}\n")
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
    lines.append('\n[[upstreams]]\ntype = "direct"\nenabled = true\nweight = 10\nipv4 = true\nipv6 = false\nprefer = 4\n')
    changed = True
else:
    for start, end in upstreams:
        ensure_key_in_range(start, end, "ipv4", "ipv4 = true\n")
        ensure_key_in_range(start, end, "ipv6", "ipv6 = false\n")
        ensure_key_in_range(start, end, "prefer", "prefer = 4\n")
if changed:
    path.write_text("".join(lines))
PY
  chown 65532:65532 "$config_file" 2>/dev/null || true
  chmod 600 "$config_file" 2>/dev/null || true
}

configure_ssh_settings() {
  if grep -Eq '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
    sed -i -E "s/^[#[:space:]]*Port[[:space:]]+.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
  else
    printf '\nPort %s\n' "$SSH_PORT" >> /etc/ssh/sshd_config
  fi
  if [ "$SSH_KEY_ONLY_LOGIN" = "yes" ]; then
    root_authorized_key_exists || die "SSH key-only login requested, but /root/.ssh/authorized_keys has no supported public key."
    write_file_root /etc/ssh/sshd_config.d/00password.conf 0644 root:root <<'EOF'
# Managed by Telemt installer when SSH_KEY_ONLY_LOGIN=yes.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
EOF
  else
    remove_installer_key_only_config_if_present
    say "SSH password login was left enabled/unchanged."
  fi
  sshd -t
  systemctl restart ssh || systemctl restart sshd
}

configure_fail2ban() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y fail2ban
  write_file_root /etc/fail2ban/jail.d/defaults-debian.conf 0644 root:root <<'EOF'
[DEFAULT]
banaction = nftables
banaction_allports = nftables[type=allports]

[sshd]
backend = systemd
journalmatch = _SYSTEMD_UNIT=ssh.service + _COMM=sshd
enabled = true
EOF
  write_file_root /etc/fail2ban/jail.d/sshd.local 0644 root:root <<EOF
[sshd]
enabled = true
port = ${SSH_PORT}
backend = systemd
maxretry = 4
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban
  systemctl restart fail2ban
}

add_swap_if_missing() {
  if ! swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
    if [ ! -e /swapfile ]; then
      fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
      chmod 600 /swapfile
      mkswap /swapfile
    fi
    swapon /swapfile || true
    grep -qE '^[^#].*[[:space:]]/swapfile[[:space:]]' /etc/fstab 2>/dev/null ||
      printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
  fi
  swapon --show || true
}

install_report_script() {
  write_file_root /usr/local/sbin/telemt-report 0700 root:root <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SINCE="${1:-5m}"
API_URL="${API_URL:-http://127.0.0.1:9091}"
CONFIG_FILE="${CONFIG_FILE:-/etc/telemt/telemt.toml}"
tmp_clients="$(mktemp)"
trap 'rm -f "$tmp_clients"' EXIT
have(){ command -v "$1" >/dev/null 2>&1; }
section(){ printf '\n=== %s ===\n' "$1"; }
bytes_human(){ if have numfmt; then numfmt --to=iec --suffix=B "${1:-0}" 2>/dev/null || printf '%sB' "${1:-0}"; else printf '%sB' "${1:-0}"; fi; }
api_get(){ curl -fsS --max-time 3 "${API_URL}$1" 2>/dev/null || true; }
service_state(){ systemctl is-active "$1" 2>/dev/null || printf 'unknown'; }
peer_ip_from_ss(){ awk '{peer=$4; sub(/^\[/,"",peer); sub(/\]:[0-9]+$/,"",peer); sub(/:[0-9]+$/,"",peer); if(peer!="") print peer}'; }
section "SUMMARY"
printf 'time:          %s\n' "$(date -Is)"
printf 'host:          %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'uptime:        %s\n' "$(uptime | sed 's/^ //')"
api_users="$(api_get /v1/users)"
api_ok=no; printf '%s' "$api_users" | grep -q '"ok":true' && api_ok=yes
telemt_running="$(service_state telemt)"
listener_443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}' && printf yes || printf no)"
listener_1443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:1443$/ {found=1} END{exit !found}' && printf yes || printf no)"
ss -H -ant state established 'sport = :443' 2>/dev/null | peer_ip_from_ss > "$tmp_clients"
conn_443="$(wc -l < "$tmp_clients" | tr -d ' ')"
uniq_443="$(sort -u "$tmp_clients" | grep -c . || true)"
status=OK
[ "$telemt_running" = active ] || status=BAD
[ "$api_ok" = yes ] || status=BAD
[ "$listener_443" = yes ] || status=BAD
[ "$listener_1443" = yes ] || status=BAD
printf 'health:        %s\n' "$status"
printf 'telemt:        service=%s api=%s backend_1443=%s\n' "$telemt_running" "$api_ok" "$listener_1443"
printf 'front door:    listener_443=%s established_443=%s unique_peer_ips=%s\n' "$listener_443" "$conn_443" "$uniq_443"
if [ -x /usr/local/bin/telemt ]; then /usr/local/bin/telemt --version 2>/dev/null | sed 's/^/version:       /' || true; fi
section "TELEMT USERS"
if [ "$api_ok" = yes ] && have jq; then
  printf '%s\n' "$api_users" | jq -r '.data[] | [.username,(.enabled//true|tostring),(.current_connections|tostring),((.max_tcp_conns//"unlimited")|tostring),(.active_unique_ips//0|tostring),(.recent_unique_ips//0|tostring),(.total_octets//0|tostring)] | @tsv' |
  while IFS=$'\t' read -r u e c m a r o; do printf '%-18s enabled=%s connections=%s/%s api_active_ips=%s api_recent_ips=%s traffic=%s\n' "$u" "$e" "$c" "$m" "$a" "$r" "$(bytes_human "$o")"; done
else
  printf 'Telemt API is not reachable or jq is missing\n'
fi
section "CLIENT PEER IPS ON TCP/443"
printf 'total_established_443_connections: %s\nunique_peer_ips: %s\ntop_peer_ips:\n' "$conn_443" "$uniq_443"
if [ "$conn_443" -gt 0 ]; then sort "$tmp_clients" | uniq -c | sort -nr | head -n 20 | awk '{printf "  %6s  %s\n",$1,$2}'; else printf '  none\n'; fi
section "SERVICES AND PORTS"
for svc in telemt nginx certbot.timer fail2ban local-hardening-nft; do printf '%-24s %s\n' "$svc" "$(service_state "$svc")"; done
printf '\nlistening_ports:\n'; ss -lntp 2>/dev/null | grep -E ':(80|443|8443|1443|9090|9091)\b' || printf 'no expected listeners found\n'
section "SERVER RESOURCES"
free -m 2>/dev/null | awk 'NR<=3{print}'; df -h / /var /opt 2>/dev/null | awk '!seen[$0]++'
section "RECENT TELEMT WARNINGS"
journalctl -u telemt --since "-${SINCE}" --no-pager 2>/dev/null | grep -E 'User limit|exceeded connection limit|ME pool|Upstream failed|ERROR|WARN|panic' | tail -n 80 || printf 'no relevant warnings in last %s\n' "$SINCE"
EOF
}

openssl_supports_ipv4_flag() {
  openssl s_client -help 2>&1 | grep -q -- '-4'
}

run_openssl_probe() {
  local log_file="$1" label="$2" connect_to="$3" optional="${4:-no}" rc=0
  local ipv4_flag=()
  openssl_supports_ipv4_flag && ipv4_flag=(-4)
  {
    printf '\n[%s]\n' "$label"
    printf 'command=timeout 15 openssl s_client -connect %s -servername %s\n' "$connect_to" "$DOMAIN"
  } >> "$log_file"
  timeout 15 openssl s_client "${ipv4_flag[@]}" -connect "$connect_to" -servername "$DOMAIN" \
    -verify_hostname "$DOMAIN" -verify_return_error -brief </dev/null >> "$log_file" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && { printf 'result=OK\n' >> "$log_file"; return 0; }
  printf 'result=FAILED exit_code=%s optional=%s\n' "$rc" "$optional" >> "$log_file"
  [ "$optional" = "yes" ] && return 0
  return "$rc"
}

run_curl_probe() {
  local log_file="$1" rc=0
  {
    printf '\n[curl IPv4 active probing]\n'
    printf 'command=curl -4fsSIL --resolve %s:443:%s https://%s/\n' "$DOMAIN" "$PUBLIC_IP" "$DOMAIN"
  } >> "$log_file"
  curl -4fsSIL --connect-timeout 8 --max-time 20 --resolve "${DOMAIN}:443:${PUBLIC_IP}" \
    "https://${DOMAIN}/" >> "$log_file" 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && { printf 'result=OK\n' >> "$log_file"; return 0; }
  printf 'result=FAILED exit_code=%s\n' "$rc" >> "$log_file"
  return "$rc"
}

append_active_probe_diagnostics() {
  local log_file="$1"
  {
    printf '\n[automatic diagnostics]\n'
    printf 'domain=%s\nserver_public_ipv4=%s\ntime=%s\n' "$DOMAIN" "$PUBLIC_IP" "$(date -Is 2>/dev/null || date)"
    printf '\n[dns]\n'
    getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u | sed 's/^/A: /' || true
    getent ahostsv6 "$DOMAIN" 2>/dev/null | awk '$1 !~ /^::ffff:/ {print $1}' | sort -u | sed 's/^/AAAA: /' || true
    printf '\n[listening ports]\n'
    ss -lntp 2>&1 | grep -E ':(80|443|8443|1443|9090|9091)\b' || true
    printf '\n[nginx]\n'
    systemctl is-active nginx 2>/dev/null | sed 's/^/nginx_active=/' || true
    nginx -t 2>&1 || true
    [ -f "$(nginx_stream_canonical_path)" ] && grep -nE 'stream|ssl_preread|listen 443|127\.0\.0\.1:(1443|8443)' "$(nginx_stream_canonical_path)" || true
    printf '\n[telemt]\n'
    systemctl status telemt --no-pager -l 2>&1 | sed -n '1,80p' || true
    journalctl -u telemt -n 120 --no-pager 2>&1 || true
    printf '\n[firewall]\n'
    have ufw && ufw status verbose 2>&1 || true
    have firewall-cmd && firewall-cmd --state 2>&1 && firewall-cmd --list-all 2>&1 || true
  } >> "$log_file"
}

active_probe_failed() {
  local log_file="$1" failed_check="$2"
  append_active_probe_diagnostics "$log_file"
  cat "$log_file" >&2 || true
  die "Active probing failed: $failed_check. Full log: $log_file"
}

validate_install() {
  local probe_log="/root/telemt-active-probing-check.txt"
  sleep 8
  ss -lntp | grep -E ':(80|443|8443|1443|9090|9091)\b' || true
  curl -fsS "http://127.0.0.1:9091/v1/users" | tee /tmp/telemt-users.json >/dev/null
  grep -q '"ok":true' /tmp/telemt-users.json
  write_proxy_links
  : > "$probe_log"
  chmod 600 "$probe_log" 2>/dev/null || true
  run_openssl_probe "$probe_log" "openssl IPv4 via server public IP" "${PUBLIC_IP}:443" "no" ||
    active_probe_failed "$probe_log" "openssl connection to ${PUBLIC_IP}:443"
  run_openssl_probe "$probe_log" "openssl IPv4 via domain DNS" "${DOMAIN}:443" "yes"
  run_curl_probe "$probe_log" ||
    active_probe_failed "$probe_log" "curl HTTPS through ${PUBLIC_IP}:443"
  sed -n '1,24p' "$probe_log" || true
}

detect_docker_install() {
  [ -f "$INSTALL_DIR/docker-compose.yml" ] && return 0
  [ -f /opt/telemt-docker/docker-compose.yml ] && return 0
  if have docker && docker inspect telemt >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

detect_systemd_install() {
  [ -f "$SERVICE_FILE" ] && return 0
  [ -x "$BINARY_PATH" ] && { [ -f "$CONFIG_FILE" ] || [ -f "$CANONICAL_CONFIG_FILE" ]; } && return 0
  return 1
}

backup_install_state() {
  BACKUP_DIR="${BACKUP_DIR:-$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)}"
  install -d -m 0700 "$BACKUP_DIR"
  for path in \
    "$INSTALL_DIR" "$ETC_DIR" "$BINARY_PATH" "$SERVICE_FILE" "$SECRET_FILE" "$SAVED_CONFIG" \
    "$(nginx_mask_site_available_path)" "$(nginx_mask_site_enabled_path)" \
    /etc/nginx/modules-enabled/60-telemt-stream-sni.conf \
    /etc/nginx/modules-enabled/60-stream-sni.conf \
    /etc/nginx/modules-enabled/90-stream-sni.conf \
    /etc/sysctl.d/99-telemt-high-load.conf \
    /etc/systemd/system/local-hardening-nft.service \
    /etc/nftables-local-hardening.conf \
    /root/telemt-proxy-link.txt /root/telemt-proxy-links.txt /root/telemt-proxy-link-ip.txt
  do
    backup_path_to_dir "$path" "$BACKUP_DIR"
  done
  chmod -R go-rwx "$BACKUP_DIR" 2>/dev/null || true
  say "backup_dir=$BACKUP_DIR"
}

backup_update_state() {
  BACKUP_DIR="$UPDATE_BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  backup_install_state
}

ask_install_questions() {
  local existing_users existing_user extra_user i
  if [ -z "$DOMAIN" ]; then
    prompt DOMAIN "Proxy domain" "$DOMAIN"
  elif [ "$ASSUME_YES" != "1" ]; then
    prompt DOMAIN "Proxy domain" "$DOMAIN"
  fi
  valid_domain "$DOMAIN" || die "Domain must be a valid DNS name, for example proxy.example.com."
  detect_public_ip
  EMAIL="${EMAIL:-admin@${DOMAIN}}"
  prompt EMAIL "Let's Encrypt email" "$EMAIL"
  prompt SSH_PORT "SSH port, Enter keeps current/default" "$SSH_PORT"
  prompt_yes_no SSH_KEY_ONLY_LOGIN "Disable SSH password login and keep root key-only? yes/no" "$SSH_KEY_ONLY_LOGIN"
  prompt_yes_no ENABLE_FAIL2BAN "Enable fail2ban for SSH? yes/no" "$ENABLE_FAIL2BAN"
  prompt_yes_no ADD_SWAP "Add 1G swap if missing? yes/no" "$ADD_SWAP"
  prompt TELEMT_VERSION "Telemt release version" "$TELEMT_VERSION"
  validate_telemt_version
  prompt TELEMT_USER "Telemt first user name" "$TELEMT_USER"
  valid_user_name "$TELEMT_USER" || die "Bad Telemt user name: $TELEMT_USER"
  TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
  existing_users="$TELEMT_USERS"
  TELEMT_LINK_COUNT="${TELEMT_LINK_COUNT:-$(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | grep -c . || true)}"
  [ -n "$TELEMT_LINK_COUNT" ] && [ "$TELEMT_LINK_COUNT" -ge 1 ] 2>/dev/null || TELEMT_LINK_COUNT=1
  prompt TELEMT_LINK_COUNT "How many proxy links/users to create now" "$TELEMT_LINK_COUNT"
  [[ "$TELEMT_LINK_COUNT" =~ ^[0-9]+$ ]] && [ "$TELEMT_LINK_COUNT" -ge 1 ] && [ "$TELEMT_LINK_COUNT" -le 100 ] ||
    die "Link count must be between 1 and 100."
  TELEMT_USERS=""
  append_telemt_user "$TELEMT_USER"
  for ((i=2; i<=TELEMT_LINK_COUNT; i++)); do
    existing_user="$(printf '%s\n' "$existing_users" | tr ',' '\n' | sed -n "${i}p" || true)"
    extra_user=""
    prompt extra_user "Telemt user name #${i}" "${existing_user:-user${i}}"
    append_telemt_user "$extra_user"
  done
  prompt TELEMT_MAX_TCP_CONNS "Max Telemt connections" "$TELEMT_MAX_TCP_CONNS"
  prompt TELEMT_CLIENT_MSS "Telemt listener TCP MSS: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS"
  prompt TELEMT_SYNLIMIT "Telemt listener SYN limiter: false/iptables/nftables" "$TELEMT_SYNLIMIT"
  prompt AD_TAG "MTProxy ad_tag, Enter = skip" "$AD_TAG"
  if [ -z "$USE_MIDDLE_PROXY" ]; then
    [ -n "$AD_TAG" ] && USE_MIDDLE_PROXY="yes" || USE_MIDDLE_PROXY="no"
  fi
  prompt_yes_no USE_MIDDLE_PROXY "Use Telegram middle proxy? yes/no" "$USE_MIDDLE_PROXY"
  prompt_yes_no ENABLE_LOGS "Enable nginx access logs? yes/no" "$ENABLE_LOGS"
  prompt_yes_no ENABLE_HIGH_LOAD_TUNING "Enable high-load tuning for many clients? yes/no" "$ENABLE_HIGH_LOAD_TUNING"

  [[ "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Email must be a plain email address."
  valid_port "$SSH_PORT" || die "SSH port must be a number from 1 to 65535."
  valid_limit "$TELEMT_MAX_TCP_CONNS" || die "Connection limit must be a number from 1 to 1000000."
  TELEMT_CLIENT_MSS="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  TELEMT_SYNLIMIT="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
  validate_synlimit_number TELEMT_SYNLIMIT_SECONDS "$TELEMT_SYNLIMIT_SECONDS"
  validate_synlimit_number TELEMT_SYNLIMIT_HITCOUNT "$TELEMT_SYNLIMIT_HITCOUNT"
  validate_synlimit_number TELEMT_SYNLIMIT_BURST "$TELEMT_SYNLIMIT_BURST"

  if [ "$SSH_KEY_ONLY_LOGIN" = "yes" ]; then
    root_authorized_key_exists || die "SSH key-only login requested, but no root SSH public key was found."
    prompt_yes_no SSH_KEY_ONLY_CONFIRM "Are you sure you want to close SSH password login? yes/no" "$SSH_KEY_ONLY_CONFIRM"
    [ "$SSH_KEY_ONLY_CONFIRM" = "yes" ] || SSH_KEY_ONLY_LOGIN="no"
  fi
}

print_install_plan() {
  cat <<EOF

Install plan:
  mode:             systemd, no Docker
  domain:           ${DOMAIN}
  public IPv4:      ${PUBLIC_IP}
  email:            ${EMAIL}
  SSH port:         ${SSH_PORT}
  SSH key-only:     ${SSH_KEY_ONLY_LOGIN}
  fail2ban SSH:     ${ENABLE_FAIL2BAN}
  add swap:         ${ADD_SWAP}
  Telemt version:   ${TELEMT_VERSION} (exact release tag)
  Telemt users:     ${TELEMT_USERS}
  Telemt limit:     ${TELEMT_MAX_TCP_CONNS}
  client_mss:       ${TELEMT_CLIENT_MSS}
  synlimit:         ${TELEMT_SYNLIMIT}
  middle proxy:     ${USE_MIDDLE_PROXY}
  logs:             ${ENABLE_LOGS}
  high-load tuning: ${ENABLE_HIGH_LOAD_TUNING}
  binary:           ${BINARY_PATH}
  config:           ${CONFIG_FILE} -> ${CANONICAL_CONFIG_FILE}
  service:          ${SERVICE_FILE}

EOF
}

run_fresh_install() {
  need_root
  require_apt_systemd
  require_debian_ubuntu

  if [ "$RESET_INSTALL_STATE" = "1" ]; then
    rm -f "$STATE_FILE" "$SAVED_CONFIG"
  elif [ -f "$SAVED_CONFIG" ]; then
    # shellcheck disable=SC1090
    source "$SAVED_CONFIG"
    say "Resume config found: $SAVED_CONFIG"
  fi

  if detect_docker_install; then
    die "Docker Telemt install detected. This script does not migrate Docker installs. Use docker-telemt/install_docker-telemt.sh --update."
  fi
  if detect_systemd_install && [ "$RESET_INSTALL_STATE" != "1" ]; then
    die "Existing systemd Telemt install detected. Use --update, or set RESET_INSTALL_STATE=1 for a reinstall."
  fi

  cat <<'EOF'
Telemt systemd installer.

Before running:
  1. Create DNS A record: <domain> -> this server IPv4.
  2. Make sure ports 80 and 443 are reachable from the internet.
  3. Keep the current SSH session open until a second login works.

EOF

  ask_install_questions
  step "DNS preflight"
  say "server_public_ipv4=$PUBLIC_IP"
  local resolved_ips
  resolved_ips="$(resolve_ipv4 "$DOMAIN" | tr '\n' ' ')"
  say "domain_ipv4=$resolved_ips"
  if ! printf ' %s ' "$resolved_ips" | grep -q " $PUBLIC_IP "; then
    die "${DOMAIN} must resolve to this server IPv4 before SSL can be issued. Expected ${PUBLIC_IP}, current: ${resolved_ips:-none}"
  fi

  print_install_plan
  confirm_plan
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  save_resume_config

  step "Backup current state"
  backup_install_state

  if [ "$ADD_SWAP" = "yes" ]; then
    step "Add 1G swap if missing"
    add_swap_if_missing
  else
    step "Add 1G swap if missing (skipped)"
    swapon --show || true
  fi

  step "Install packages"
  install_packages
  ensure_telemt_account

  step "Prepare Telemt secret"
  ensure_secret

  step "Configure SSH settings"
  configure_ssh_settings

  if [ "$ENABLE_FAIL2BAN" = "yes" ]; then
    step "Configure fail2ban"
    configure_fail2ban
  else
    step "Configure fail2ban (skipped)"
  fi

  step "Block external Telemt API and metrics ports"
  configure_nft_api_block

  step "Open public HTTP/HTTPS firewall ports"
  open_public_firewall_ports

  step "Download and install Telemt binary"
  download_and_install_telemt_binary

  step "Configure high-load tuning"
  configure_high_load

  step "Prepare nginx HTTP site for ACME"
  ensure_https_frontdoor_available
  write_mask_site_http_only
  verify_acme_http01_webroot

  step "Issue Let's Encrypt certificate"
  issue_certificate

  step "Configure certificate auto-renewal"
  configure_certbot_renewal

  step "Configure nginx mask site and SNI routing"
  write_nginx_full_config

  step "Configure Telemt"
  write_telemt_config
  start_telemt_service

  step "Install telemt-report"
  install_report_script

  step "Validation"
  validate_install
  mark_done installed

  step "Done"
  cat <<EOF
Installed Telemt systemd.

Proxy host: ${DOMAIN}:443
Telemt version: ${TELEMT_VERSION}
Telemt limit: ${TELEMT_MAX_TCP_CONNS}
Proxy link file: /root/telemt-proxy-link.txt
All links: /root/telemt-proxy-links.txt
Secret: ${SECRET_FILE}
Backups: ${BACKUP_DIR}
SSH port: ${SSH_PORT}

Health report:
  telemt-report 5m

Open a second SSH session now:
  ssh -p ${SSH_PORT} root@${DOMAIN}
EOF
  [ -s /root/telemt-proxy-links.txt ] && { printf '\nProxy links:\n'; cat /root/telemt-proxy-links.txt; }
}

run_update_mode() {
  need_root
  require_apt_systemd
  require_debian_ubuntu
  if detect_docker_install; then
    die "Docker Telemt install detected. Migration is not supported here; use docker-telemt/install_docker-telemt.sh --update."
  fi
  detect_systemd_install || die "Systemd Telemt install was not detected."
  infer_update_config_from_existing_files
  detect_public_ip
  detect_current_telemt_version || true
  resolve_update_target_version
  TELEMT_UPDATE_CONFIG_MISSING="$(build_update_config_gap_report || true)"
  [ -n "$TELEMT_UPDATE_CONFIG_MISSING" ] || TELEMT_UPDATE_CONFIG_MISSING="none"
  TELEMT_CLIENT_MSS="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  TELEMT_SYNLIMIT="$(normalize_synlimit "$TELEMT_SYNLIMIT")"

  cat <<EOF

Update plan:
  mode:             systemd, no Docker migration
  domain:           ${DOMAIN}
  public IPv4:      ${PUBLIC_IP}
  current version:  ${TELEMT_DETECTED_VERSION:-unknown}${TELEMT_DETECTED_VERSION_SOURCE:+ (${TELEMT_DETECTED_VERSION_SOURCE})}
  target version:   ${TELEMT_UPDATE_TARGET_VERSION} (exact compatible release tag)
  binary:           ${BINARY_PATH}
  config:           ${CONFIG_FILE}
  service:          ${SERVICE_FILE}
  config patch:     only missing safe keys are added
  missing keys:     ${TELEMT_UPDATE_CONFIG_MISSING}
  nginx:            preserved unless managed Telemt files are missing
  secrets/links:    preserved; links regenerated from current config

EOF
  confirm_plan

  step "Backup current state"
  backup_update_state

  step "Install/update packages"
  install_packages
  ensure_telemt_account

  step "Download and install exact Telemt release"
  download_and_install_telemt_binary

  step "Apply safe config compatibility keys"
  apply_telemt_config_compat_updates

  step "Ensure systemd service"
  start_telemt_service

  if ! stream_config_managed "$(nginx_stream_canonical_path)" &&
     ! stream_config_managed /etc/nginx/modules-enabled/60-stream-sni.conf &&
     ! stream_config_managed /etc/nginx/modules-enabled/90-stream-sni.conf; then
    step "Restore missing nginx SNI routing"
    write_nginx_full_config
  else
    step "Nginx SNI routing exists (preserved)"
    nginx -t
    systemctl reload nginx || systemctl restart nginx
  fi

  step "Install/update telemt-report"
  install_report_script

  step "Validation"
  validate_install

  step "Done"
  cat <<EOF
Updated Telemt systemd.

Current target version: ${TELEMT_UPDATE_TARGET_VERSION}
Proxy host: ${DOMAIN}:443
Proxy link file: /root/telemt-proxy-link.txt
All links: /root/telemt-proxy-links.txt
Backups: ${BACKUP_DIR}
Health report:
  telemt-report 5m
EOF
  [ -s /root/telemt-proxy-links.txt ] && { printf '\nProxy links:\n'; cat /root/telemt-proxy-links.txt; }
}

main() {
  parse_args "$@"
  if [ "$UPDATE_MODE" = "1" ]; then
    run_update_mode
  else
    run_fresh_install
  fi
}

main "$@"
