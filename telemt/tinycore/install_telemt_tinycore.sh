#!/bin/sh
set -eu

# Telemt installer for Tiny Core Linux / CorePure64, without Docker or systemd.
# It uses Tiny Core extensions, native Telemt musl binary, nginx stream SNI
# routing, acme.sh standalone ACME, and /opt/bootlocal.sh autostart.

TELEMT_HOME="${TELEMT_HOME:-/opt/telemt}"
ACME_HOME="${ACME_HOME:-/opt/acme.sh}"
STATE_FILE="${STATE_FILE:-$TELEMT_HOME/.install_tinycore.state}"
RESUME_CONFIG="${RESUME_CONFIG:-$TELEMT_HOME/install.conf}"
TELEMT_RELEASE_ENV_SET=0
TELEMT_RELEASE_ENV_VALUE=""
if [ -n "${TELEMT_RELEASE+x}" ]; then
  TELEMT_RELEASE_ENV_SET=1
  TELEMT_RELEASE_ENV_VALUE="$TELEMT_RELEASE"
fi
TELEMT_LATEST_COMPATIBLE_RELEASE="${TELEMT_LATEST_COMPATIBLE_RELEASE:-3.4.23}"
TELEMT_RELEASE="${TELEMT_RELEASE:-$TELEMT_LATEST_COMPATIBLE_RELEASE}"
TELEMT_UPDATE_TARGET_RELEASE=""
TELEMT_DETECTED_RELEASE=""
ALLOW_TELEMT_DOWNGRADE="${ALLOW_TELEMT_DOWNGRADE:-0}"
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
ACME_SH_VERSION="${ACME_SH_VERSION:-3.1.2}"
ACME_SH_SHA256="${ACME_SH_SHA256:-c46b41a61c96f67d424e4b4e476907c964b81d53cf94358a9c1d363a4f99c3a4}"
ASSUME_YES="${ASSUME_YES:-0}"

PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
SSH_PORT="${SSH_PORT:-22}"
TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-5000}"
TELEMT_USER="${TELEMT_USER:-default}"
TELEMT_USERS="${TELEMT_USERS:-}"
TELEMT_LINK_COUNT="${TELEMT_LINK_COUNT:-}"
TELEMT_SECRET="${TELEMT_SECRET:-}"
AD_TAG="${AD_TAG:-}"
USE_MIDDLE_PROXY="${USE_MIDDLE_PROXY:-}"
UPDATE_MODE="${UPDATE_MODE:-0}"
BOOTLOCAL="/opt/bootlocal.sh"

step_no=0

usage() {
  cat <<EOF
Usage:
  $0
  $0 --update

Options:
  --update, -update, update   Update to the exact project target or an explicit exact TELEMT_RELEASE.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --update|-update|update)
      UPDATE_MODE=1
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: Unknown argument: $1" >&2
      exit 1
      ;;
  esac
  shift
done

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

prompt_value() {
  label="$1"
  default_value="$2"
  answer=""

  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$label" "$default_value"
  else
    printf '%s: ' "$label"
  fi
  read -r answer
  if [ -n "$answer" ]; then
    REPLY="$answer"
  else
    REPLY="$default_value"
  fi
}

prompt_value_assume() {
  label="$1"
  default_value="$2"
  if [ "$ASSUME_YES" = "1" ]; then
    if [ -n "$default_value" ]; then
      printf '%s: %s\n' "$label" "$default_value"
    else
      printf '%s: <empty>\n' "$label"
    fi
    REPLY="$default_value"
  else
    prompt_value "$label" "$default_value"
  fi
}

valid_domain() {
  domain="$1"
  [ "${#domain}" -le 253 ] || return 1
  printf '%s\n' "$domain" | awk -F. '
    NF < 2 { exit 1 }
    {
      for (i = 1; i <= NF; i++) {
        if (length($i) < 1 || length($i) > 63) exit 1
        if ($i !~ /^[A-Za-z0-9]$/ && $i !~ /^[A-Za-z0-9][A-Za-z0-9-]*[A-Za-z0-9]$/) exit 1
      }
    }
  '
}

valid_port() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_limit() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ] && [ "$1" -le 1000000 ]
}

valid_user_name() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.-]{1,64}$'
}

valid_telemt_release() {
  release="$1"
  case "$release" in
    latest|LATEST|Latest)
      return 1
      ;;
  esac
  printf '%s\n' "$release" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'
}

detect_installed_telemt_release() {
  [ -x "$TELEMT_HOME/bin/telemt" ] || return 1
  "$TELEMT_HOME/bin/telemt" --version 2>/dev/null |
    sed -n 's/^telemt[[:space:]]\+v\{0,1\}\([0-9][0-9.]*\).*/\1/p' |
    sed -n '1p'
}

version_gt() {
  local left="$1" right="$2" l_major l_minor l_patch r_major r_minor r_patch
  IFS=. read -r l_major l_minor l_patch <<EOF
$left
EOF
  IFS=. read -r r_major r_minor r_patch <<EOF
$right
EOF
  l_minor="${l_minor:-0}"
  l_patch="${l_patch:-0}"
  r_minor="${r_minor:-0}"
  r_patch="${r_patch:-0}"
  [ "$l_major" -gt "$r_major" ] && return 0
  [ "$l_major" -lt "$r_major" ] && return 1
  [ "$l_minor" -gt "$r_minor" ] && return 0
  [ "$l_minor" -lt "$r_minor" ] && return 1
  [ "$l_patch" -gt "$r_patch" ]
}

resolve_update_release() {
  local requested=""
  if [ "$TELEMT_RELEASE_ENV_SET" = "1" ]; then
    requested="$TELEMT_RELEASE_ENV_VALUE"
  fi
  case "$requested" in
    latest|LATEST|Latest)
      echo "WARN: TELEMT_RELEASE=latest is ignored in --update; using $TELEMT_LATEST_COMPATIBLE_RELEASE."
      TELEMT_UPDATE_TARGET_RELEASE="$TELEMT_LATEST_COMPATIBLE_RELEASE"
      ;;
    '')
      TELEMT_UPDATE_TARGET_RELEASE="$TELEMT_LATEST_COMPATIBLE_RELEASE"
      ;;
    *)
      valid_telemt_release "$requested" || die "TELEMT_RELEASE must be an exact tag like $TELEMT_LATEST_COMPATIBLE_RELEASE, not '$requested'."
      TELEMT_UPDATE_TARGET_RELEASE="$requested"
      ;;
  esac
  TELEMT_RELEASE="$TELEMT_UPDATE_TARGET_RELEASE"
}

confirm_update_plan() {
  local confirm=""
  if [ "$ASSUME_YES" = "1" ]; then
    echo "ASSUME_YES=1, continuing."
    return 0
  fi
  printf 'Type y or yes to continue: '
  read -r confirm
  case "$confirm" in
    y|yes|Y|YES) ;;
    *) die "Cancelled." ;;
  esac
}

telemt_release_at_least() {
  wanted_major="$1"
  wanted_minor="$2"
  wanted_patch="$3"
  IFS=. read -r major minor patch <<EOF
$TELEMT_RELEASE
EOF
  [ "$major" -gt "$wanted_major" ] && return 0
  [ "$major" -lt "$wanted_major" ] && return 1
  [ "$minor" -gt "$wanted_minor" ] && return 0
  [ "$minor" -lt "$wanted_minor" ] && return 1
  [ "$patch" -ge "$wanted_patch" ]
}

telemt_supports_exclusive_mask() { telemt_release_at_least 3 4 12; }
telemt_supports_user_enabled() { telemt_release_at_least 3 4 14; }
telemt_supports_client_mss() { telemt_release_at_least 3 4 15; }
telemt_supports_client_mss_bulk() { telemt_release_at_least 3 4 19; }
telemt_supports_synlimit() { telemt_release_at_least 3 4 18; }

normalize_client_mss() {
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    off|none|no|false|0) printf '%s\n' "off" ;;
    tspu|2in8|extreme-low) printf '%s\n' "$value" ;;
    *)
      if printf '%s\n' "$value" | grep -Eq '^[0-9]+$' && [ "$value" -ge 88 ] && [ "$value" -le 4096 ]; then
        printf '%s\n' "$value"
      else
        die "Bad TELEMT_CLIENT_MSS: $1"
      fi
      ;;
  esac
}

normalize_synlimit() {
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    false|no|off|0) printf '%s\n' "false" ;;
    iptables|nftables) printf '%s\n' "$value" ;;
    *) die "Bad TELEMT_SYNLIMIT: $1" ;;
  esac
}

normalize_yes_no() {
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    yes|y|true|1|да|д) printf '%s\n' "yes" ;;
    no|n|false|0|нет|н|'') printf '%s\n' "no" ;;
    *) die "Bad yes/no value: $1" ;;
  esac
}

valid_synlimit_number() {
  printf '%s\n' "$1" | grep -Eq '^[0-9]+$' && [ "$1" -ge 1 ]
}

trim_value() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

append_telemt_user() {
  user="$(trim_value "$1")"
  [ -n "$user" ] || return 0
  valid_user_name "$user" || die "Bad Telemt user name: $user"
  if [ -z "$TELEMT_USERS" ]; then
    TELEMT_USERS="$user"
  elif ! printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | grep -Fxq "$user"; then
    TELEMT_USERS="${TELEMT_USERS},${user}"
  fi
}

normalize_telemt_users() {
  [ -n "$TELEMT_USER" ] || TELEMT_USER="default"
  TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
  normalized=""
  first_user=""
  old_ifs="$IFS"
  IFS=,
  for raw_user in $TELEMT_USERS; do
    user="$(trim_value "$raw_user")"
    [ -n "$user" ] || continue
    valid_user_name "$user" || die "Bad Telemt user name: $user"
    if [ -z "$normalized" ]; then
      normalized="$user"
      first_user="$user"
    elif ! printf '%s\n' "$normalized" | tr ',' '\n' | grep -Fxq "$user"; then
      normalized="${normalized},${user}"
    fi
  done
  IFS="$old_ifs"
  [ -n "$normalized" ] || normalized="$TELEMT_USER"
  TELEMT_USERS="$normalized"
  TELEMT_USER="$first_user"
  [ -n "$TELEMT_USER" ] || TELEMT_USER="$normalized"
  TELEMT_LINK_COUNT="$(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | grep -c .)"
}

telemt_users_list() {
  old_ifs="$IFS"
  IFS=,
  for raw_user in $TELEMT_USERS; do
    user="$(trim_value "$raw_user")"
    [ -n "$user" ] && printf '%s\n' "$user"
  done
  IFS="$old_ifs"
}

telemt_user_at() {
  wanted="$1"
  index=0
  old_ifs="$IFS"
  IFS=,
  for raw_user in $TELEMT_USERS; do
    user="$(trim_value "$raw_user")"
    [ -n "$user" ] || continue
    index=$((index + 1))
    if [ "$index" -eq "$wanted" ]; then
      IFS="$old_ifs"
      printf '%s\n' "$user"
      return 0
    fi
  done
  IFS="$old_ifs"
  return 1
}

telemt_users_toml_array() {
  first=1
  printf '['
  while IFS= read -r user; do
    [ -n "$user" ] || continue
    if [ "$first" = "1" ]; then
      first=0
    else
      printf ', '
    fi
    printf '"%s"' "$user"
  done <<EOF
$(telemt_users_list)
EOF
  printf ']'
}

secret_for_user() {
  user="$1"
  existing_secret=""
  if [ -f "$TELEMT_HOME/telemt.toml" ]; then
    existing_secret="$(awk -v wanted="$user" '
      /^\[access\.users\]/ { inside = 1; next }
      /^\[/ { inside = 0 }
      inside && $0 ~ /=/ {
        line = $0
        sub(/#.*/, "", line)
        split(line, parts, "=")
        key = parts[1]
        value = parts[2]
        gsub(/^[ \t"]+|[ \t"]+$/, "", key)
        gsub(/^[ \t"]+|[ \t"]+$/, "", value)
        if (key == wanted) {
          print value
          exit
        }
      }
    ' "$TELEMT_HOME/telemt.toml" 2>/dev/null || true)"
  fi
  if printf '%s\n' "$existing_secret" | grep -Eq '^[A-Fa-f0-9]{32}$'; then
    printf '%s\n' "$existing_secret"
    return 0
  fi
  if [ "$user" = "$TELEMT_USER" ]; then
    printf '%s\n' "$TELEMT_SECRET"
  else
    openssl rand -hex 16
  fi
}

is_public_ipv4() {
  printf '%s\n' "$1" | awk -F. '
    NF != 4 { exit 1 }
    {
      for (i = 1; i <= 4; i++) {
        if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) exit 1
      }
      if ($1 == 10 || $1 == 127) exit 1
      if ($1 == 169 && $2 == 254) exit 1
      if ($1 == 172 && $2 >= 16 && $2 <= 31) exit 1
      if ($1 == 192 && $2 == 168) exit 1
      if ($1 == 100 && $2 >= 64 && $2 <= 127) exit 1
      if ($1 >= 224) exit 1
    }
  '
}

step_done() {
  [ -f "$STATE_FILE" ] && grep -Fxq "$1" "$STATE_FILE"
}

mark_done() {
  mkdir -p "$TELEMT_HOME"
  touch "$STATE_FILE"
  grep -Fxq "$1" "$STATE_FILE" 2>/dev/null || echo "$1" >> "$STATE_FILE"
}

save_resume_config() {
  mkdir -p "$TELEMT_HOME"
  umask 077
  cat > "$RESUME_CONFIG" <<EOF
PUBLIC_HOST='$PUBLIC_HOST'
PUBLIC_IP='$PUBLIC_IP'
LETSENCRYPT_EMAIL='$LETSENCRYPT_EMAIL'
SSH_PORT='$SSH_PORT'
TELEMT_MAX_TCP_CONNS='$TELEMT_MAX_TCP_CONNS'
TELEMT_RELEASE='$TELEMT_RELEASE'
TELEMT_USER='$TELEMT_USER'
TELEMT_USERS='$TELEMT_USERS'
TELEMT_LINK_COUNT='$TELEMT_LINK_COUNT'
TELEMT_CLIENT_MSS='$TELEMT_CLIENT_MSS'
TELEMT_CLIENT_MSS_BULK='$TELEMT_CLIENT_MSS_BULK'
TELEMT_SYNLIMIT='$TELEMT_SYNLIMIT'
TELEMT_SYNLIMIT_SECONDS='$TELEMT_SYNLIMIT_SECONDS'
TELEMT_SYNLIMIT_HITCOUNT='$TELEMT_SYNLIMIT_HITCOUNT'
TELEMT_SYNLIMIT_BURST='$TELEMT_SYNLIMIT_BURST'
TELEMT_SYNLIMIT_IOS_SECONDS='$TELEMT_SYNLIMIT_IOS_SECONDS'
TELEMT_SYNLIMIT_IOS_HITCOUNT='$TELEMT_SYNLIMIT_IOS_HITCOUNT'
TELEMT_SYNLIMIT_IOS_BURST='$TELEMT_SYNLIMIT_IOS_BURST'
TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS='$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS'
TELEMT_SYNLIMIT_HASHLIMIT_SIZE='$TELEMT_SYNLIMIT_HASHLIMIT_SIZE'
ACME_SH_VERSION='$ACME_SH_VERSION'
ACME_SH_SHA256='$ACME_SH_SHA256'
TELEMT_SECRET='$TELEMT_SECRET'
AD_TAG='$AD_TAG'
USE_MIDDLE_PROXY='$USE_MIDDLE_PROXY'
EOF
  chmod 600 "$RESUME_CONFIG"
}

detect_public_ip() {
  if is_public_ipv4 "$PUBLIC_IP"; then
    return 0
  fi
  PUBLIC_IP=""
  if have curl; then
    PUBLIC_IP="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if is_public_ipv4 "$PUBLIC_IP"; then
      return 0
    fi
  fi
  if have wget; then
    PUBLIC_IP="$(wget -qO- -T 8 https://api.ipify.org 2>/dev/null || true)"
    if is_public_ipv4 "$PUBLIC_IP"; then
      return 0
    fi
  fi
  if have ip; then
    PUBLIC_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
    if is_public_ipv4 "$PUBLIC_IP"; then
      return 0
    fi
  fi
  die "Could not detect public IPv4. Set PUBLIC_IP explicitly after networking is ready and rerun."
}

resolve_ipv4() {
  host="$1"
  if have getent; then
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
    return 0
  fi
  if have host; then
    host "$host" 2>/dev/null | awk '/has address/ {print $NF}' | sort -u
    return 0
  fi
  if have nslookup; then
    nslookup "$host" 2>/dev/null | awk '/^Address: / {print $2}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | sort -u
    return 0
  fi
  die "Need getent, host, or nslookup for DNS preflight."
}

require_tinycore() {
  [ "$(id -u)" -eq 0 ] || die "Run as root."
  [ "$(uname -s)" = "Linux" ] || die "Run on Tiny Core Linux target server."
  have tce-load || die "tce-load not found. This installer is for Tiny Core Linux."
  [ -e /etc/sysconfig/tcedir ] || die "/etc/sysconfig/tcedir not found. Configure Tiny Core persistent TCE first."

  tce_dir="$(readlink /etc/sysconfig/tcedir 2>/dev/null || printf '%s' /etc/sysconfig/tcedir)"
  case "$tce_dir" in
    /tmp/*|/tmp)
      [ "${ALLOW_TMP_TCE:-0}" = "1" ] || die "TCE directory is in /tmp. Configure persistent /tce first or run ALLOW_TMP_TCE=1 if this is only a test."
      ;;
  esac
}

install_extensions() {
  # Tiny Core names are extension names without .tcz.
  for ext in bash curl ca-certificates openssl nginx socat; do
    echo "tce-load -wi $ext"
    tce-load -wi "$ext"
  done
  for ext in jq iproute2; do
    echo "tce-load -wi $ext"
    tce-load -wi "$ext" || echo "Warning: optional extension $ext was not installed."
  done
}

telemt_asset() {
  arch="$(uname -m)"
  case "$arch" in
    x86_64) printf '%s\n' "telemt-x86_64-linux-musl.tar.gz" ;;
    aarch64|arm64) printf '%s\n' "telemt-aarch64-linux-musl.tar.gz" ;;
    *) die "Unsupported architecture for official Telemt release: $arch. Use x86_64/CorePure64 or aarch64." ;;
  esac
}

download_telemt() {
  asset="$(telemt_asset)"
  tmp_dir="/tmp/telemt-download.$$"
  base_url=""
  version_output=""
  mkdir -p "$tmp_dir"

  valid_telemt_release "$TELEMT_RELEASE" ||
    die "TELEMT_RELEASE must be an exact release tag like $TELEMT_LATEST_COMPATIBLE_RELEASE, not '$TELEMT_RELEASE'."

  base_url="https://github.com/telemt/telemt/releases/download/$TELEMT_RELEASE"
  url="$base_url/$asset"

  echo "download=$url"
  curl -fsSL "$url" -o "$tmp_dir/$asset"
  curl -fsSL "$base_url/$asset.sha256" -o "$tmp_dir/$asset.sha256"
  (cd "$tmp_dir" && sha256sum -c "$asset.sha256") || die "Telemt sha256 check failed."

  tar -xzf "$tmp_dir/$asset" -C "$tmp_dir"
  bin_path="$(find "$tmp_dir" -type f -name telemt | head -n 1)"
  [ -n "$bin_path" ] || die "Telemt binary not found in release archive."
  version_output="$("$bin_path" --version 2>/dev/null || true)"
  printf '%s\n' "$version_output" | grep -Eq "(^|[ v])${TELEMT_RELEASE}([^0-9.]|$)" ||
    die "Downloaded Telemt binary version does not match TELEMT_RELEASE=$TELEMT_RELEASE. Output: $version_output"

  mkdir -p "$TELEMT_HOME/bin"
  cp "$bin_path" "$TELEMT_HOME/bin/telemt"
  chmod 755 "$TELEMT_HOME/bin/telemt"
  rm -rf "$tmp_dir"
}

install_acme_sh() {
  mkdir -p "$ACME_HOME"
  tmp_acme="/tmp/acme.sh.$$"
  curl -fsSL "https://raw.githubusercontent.com/acmesh-official/acme.sh/${ACME_SH_VERSION}/acme.sh" -o "$tmp_acme"
  printf '%s  %s\n' "$ACME_SH_SHA256" "$tmp_acme" | sha256sum -c - || die "acme.sh sha256 check failed."
  cp "$tmp_acme" "$ACME_HOME/acme.sh"
  rm -f "$tmp_acme"
  chmod 700 "$ACME_HOME/acme.sh"
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" --set-default-ca --server letsencrypt
}

stop_services() {
  if [ -f "$TELEMT_HOME/run/telemt.pid" ]; then
    kill "$(cat "$TELEMT_HOME/run/telemt.pid")" 2>/dev/null || true
  fi
  if [ -f "$TELEMT_HOME/run/nginx.pid" ]; then
    nginx -c "$TELEMT_HOME/nginx/nginx.conf" -s stop 2>/dev/null || kill "$(cat "$TELEMT_HOME/run/nginx.pid")" 2>/dev/null || true
  fi
  sleep 1
}

write_restart_script() {
  mkdir -p "$TELEMT_HOME/bin" "$TELEMT_HOME/run" "$TELEMT_HOME/log"
  cat > "$TELEMT_HOME/bin/restart.sh" <<EOF
#!/bin/sh
set -eu
TELEMT_HOME="$TELEMT_HOME"

if [ -f "\$TELEMT_HOME/run/telemt.pid" ]; then
  kill "\$(cat "\$TELEMT_HOME/run/telemt.pid")" 2>/dev/null || true
fi
if [ -f "\$TELEMT_HOME/run/nginx.pid" ]; then
  nginx -c "\$TELEMT_HOME/nginx/nginx.conf" -s stop 2>/dev/null || kill "\$(cat "\$TELEMT_HOME/run/nginx.pid")" 2>/dev/null || true
fi
sleep 1

mkdir -p "\$TELEMT_HOME/run" "\$TELEMT_HOME/log"
nginx -c "\$TELEMT_HOME/nginx/nginx.conf"
ulimit -n 65535 2>/dev/null || true
RUST_LOG=warn "\$TELEMT_HOME/bin/telemt" "\$TELEMT_HOME/telemt.toml" >/dev/null 2>&1 &
echo \$! > "\$TELEMT_HOME/run/telemt.pid"
EOF
  chmod 700 "$TELEMT_HOME/bin/restart.sh"

  cat > "$TELEMT_HOME/bin/stop-nginx.sh" <<EOF
#!/bin/sh
set -eu
TELEMT_HOME="$TELEMT_HOME"

if [ -f "\$TELEMT_HOME/run/nginx.pid" ]; then
  nginx -c "\$TELEMT_HOME/nginx/nginx.conf" -s stop 2>/dev/null || kill "\$(cat "\$TELEMT_HOME/run/nginx.pid")" 2>/dev/null || true
fi
EOF
  chmod 700 "$TELEMT_HOME/bin/stop-nginx.sh"

  cat > "$TELEMT_HOME/bin/start-nginx-if-cert.sh" <<EOF
#!/bin/sh
set -eu
TELEMT_HOME="$TELEMT_HOME"

[ -s "\$TELEMT_HOME/certs/fullchain.pem" ] || exit 0
[ -s "\$TELEMT_HOME/certs/privkey.pem" ] || exit 0
"\$TELEMT_HOME/bin/restart.sh"
EOF
  chmod 700 "$TELEMT_HOME/bin/start-nginx-if-cert.sh"

  cat > "$TELEMT_HOME/bin/watchdog.sh" <<EOF
#!/bin/sh
set -eu
TELEMT_HOME="$TELEMT_HOME"
LOCK_DIR="/tmp/telemt-watchdog.lock"
RENEW_LOCK="/tmp/telemt-renew-cert.lock"

[ -d "\$RENEW_LOCK" ] && exit 0

if ! mkdir "\$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "\$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

pid_alive() {
  pid_file="\$1"
  [ -s "\$pid_file" ] || return 1
  pid="\$(cat "\$pid_file" 2>/dev/null || true)"
  [ -n "\$pid" ] || return 1
  kill -0 "\$pid" 2>/dev/null
}

need_restart=0
pid_alive "\$TELEMT_HOME/run/telemt.pid" || need_restart=1
pid_alive "\$TELEMT_HOME/run/nginx.pid" || need_restart=1

if [ "\$need_restart" = "1" ]; then
  mkdir -p "\$TELEMT_HOME/log"
  echo "\$(date -u '+%Y-%m-%dT%H:%M:%SZ') watchdog restart: telemt or nginx is not running" >> "\$TELEMT_HOME/log/watchdog.log" 2>/dev/null || true
  "\$TELEMT_HOME/bin/restart.sh" >/dev/null 2>&1 || true
fi
EOF
  chmod 700 "$TELEMT_HOME/bin/watchdog.sh"
}

issue_certificate() {
  mkdir -p "$TELEMT_HOME/certs"
  stop_services
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" --issue --server letsencrypt --standalone \
    --accountemail "$LETSENCRYPT_EMAIL" --keylength ec-256 -d "$PUBLIC_HOST" \
    --pre-hook "$TELEMT_HOME/bin/stop-nginx.sh" \
    --post-hook "$TELEMT_HOME/bin/start-nginx-if-cert.sh"
  "$ACME_HOME/acme.sh" --home "$ACME_HOME" --install-cert -d "$PUBLIC_HOST" --ecc \
    --fullchain-file "$TELEMT_HOME/certs/fullchain.pem" \
    --key-file "$TELEMT_HOME/certs/privkey.pem" \
    --reloadcmd "$TELEMT_HOME/bin/restart.sh"
  chmod 600 "$TELEMT_HOME/certs/"*.pem
}

set_acme_conf_value() {
  key="$1"
  value="$2"
  file="$3"
  safe_value="$(printf '%s' "$value" | sed 's/[&|]/\\&/g')"

  if grep -q "^${key}=" "$file"; then
    sed -i "s|^${key}=.*|${key}='${safe_value}'|" "$file"
  else
    printf "%s='%s'\n" "$key" "$value" >> "$file"
  fi
}

configure_acme_renewal_hooks() {
  for domain_conf in "$ACME_HOME/${PUBLIC_HOST}_ecc/${PUBLIC_HOST}.conf" "$ACME_HOME/${PUBLIC_HOST}/${PUBLIC_HOST}.conf"; do
    [ -f "$domain_conf" ] || continue
    set_acme_conf_value "Le_PreHook" "$TELEMT_HOME/bin/stop-nginx.sh" "$domain_conf"
    set_acme_conf_value "Le_PostHook" "$TELEMT_HOME/bin/start-nginx-if-cert.sh" "$domain_conf"
    set_acme_conf_value "Le_ReloadCmd" "$TELEMT_HOME/bin/restart.sh" "$domain_conf"
  done
}

write_mask_page() {
  mkdir -p "$TELEMT_HOME/www"
  cat > "$TELEMT_HOME/www/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${PUBLIC_HOST}</title>
  <style>
    body { margin: 0; font-family: system-ui, sans-serif; background: #f6f7f9; color: #1d2733; }
    main { min-height: 100vh; display: grid; place-items: center; padding: 32px; box-sizing: border-box; }
    section { width: min(720px, 100%); }
    h1 { margin: 0 0 14px; font-size: 44px; font-weight: 650; letter-spacing: 0; }
    p { margin: 0 0 18px; font-size: 18px; line-height: 1.55; color: #52606d; }
  </style>
</head>
<body>
  <main>
    <section>
      <h1>${PUBLIC_HOST}</h1>
      <p>Digital infrastructure, network diagnostics, and private systems maintenance.</p>
      <p>For service requests, scheduled access, or operational questions, contact your project administrator.</p>
    </section>
  </main>
</body>
</html>
EOF
}

write_nginx_config() {
  nginx_bin="$(command -v nginx)"
  nginx_v="$($nginx_bin -V 2>&1 || true)"
  echo "$nginx_v" | grep -q -- '--with-stream' || die "Tiny Core nginx extension does not report stream support. SNI routing needs nginx stream."

  stream_load=""
  if echo "$nginx_v" | grep -q -- '--with-stream=dynamic'; then
    stream_mod="$(find /usr/local/lib/nginx /usr/lib/nginx -name '*stream*.so' 2>/dev/null | head -n 1 || true)"
    [ -n "$stream_mod" ] || die "nginx stream module is dynamic but module file was not found."
    stream_load="load_module $stream_mod;"
  fi

  mkdir -p "$TELEMT_HOME/nginx" "$TELEMT_HOME/run" "$TELEMT_HOME/log"
  cat > "$TELEMT_HOME/nginx/nginx.conf" <<EOF
$stream_load
worker_processes 1;
error_log /dev/null crit;
pid $TELEMT_HOME/run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /usr/local/etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    sendfile on;
    keepalive_timeout 65;

    server {
        listen 80;
        server_name ${PUBLIC_HOST};
        access_log off;
        error_log /dev/null crit;

        location ^~ /.well-known/acme-challenge/ {
            root $TELEMT_HOME/www;
            default_type "text/plain";
            try_files \$uri =404;
        }

        location / {
            return 301 https://\$host\$request_uri;
        }
    }

    server {
        listen 127.0.0.1:8443 ssl;
        server_name ${PUBLIC_HOST};
        access_log off;
        error_log /dev/null crit;

        root $TELEMT_HOME/www;
        index index.html;

        ssl_certificate $TELEMT_HOME/certs/fullchain.pem;
        ssl_certificate_key $TELEMT_HOME/certs/privkey.pem;

        location / {
            try_files \$uri \$uri/ =404;
        }
    }
}

stream {
    map \$ssl_preread_server_name \$telemt_backend {
        ${PUBLIC_HOST} 127.0.0.1:1443;
        default       127.0.0.1:8443;
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
  nginx -t -c "$TELEMT_HOME/nginx/nginx.conf"
}

write_telemt_config() {
  middle_bool="false"
  [ "$USE_MIDDLE_PROXY" = "yes" ] && middle_bool="true"
  normalize_telemt_users
  users_array="$(telemt_users_toml_array)"
  client_mss="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  client_mss_bulk="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")"
  synlimit_value="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
  cat > "$TELEMT_HOME/telemt.toml" <<EOF
show_link = ${users_array}

[general]
data_path = "$TELEMT_HOME/run/telemt-runtime"
quota_state_path = "$TELEMT_HOME/run/telemt.limit.json"
fast_mode = true
use_middle_proxy = ${middle_bool}
config_strict = true
beobachten = true
beobachten_minutes = 10
beobachten_flush_secs = 15
beobachten_file = "$TELEMT_HOME/run/beobachten.txt"
log_level = "silent"
EOF
  if [ -n "$AD_TAG" ]; then
    printf 'ad_tag = "%s"\n' "$AD_TAG" >> "$TELEMT_HOME/telemt.toml"
  fi
  cat >> "$TELEMT_HOME/telemt.toml" <<EOF

[general.links]
show = ${users_array}
public_host = "${PUBLIC_HOST}"
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
  if telemt_supports_client_mss && [ "$client_mss" != "off" ]; then
    printf 'client_mss = "%s"\n' "$client_mss" >> "$TELEMT_HOME/telemt.toml"
  fi
  if telemt_supports_client_mss_bulk && [ "$client_mss" != "off" ] && [ "$client_mss_bulk" != "off" ]; then
    printf 'client_mss_bulk = "%s"\n' "$client_mss_bulk" >> "$TELEMT_HOME/telemt.toml"
  fi
  cat >> "$TELEMT_HOME/telemt.toml" <<EOF

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
  if telemt_supports_client_mss && [ "$client_mss" != "off" ]; then
    printf 'client_mss = "%s"\n' "$client_mss" >> "$TELEMT_HOME/telemt.toml"
  fi
  if telemt_supports_synlimit; then
    if [ "$synlimit_value" = "false" ]; then
      printf 'synlimit = false\n' >> "$TELEMT_HOME/telemt.toml"
    else
      printf 'synlimit = "%s"\n' "$synlimit_value" >> "$TELEMT_HOME/telemt.toml"
      printf 'synlimit_seconds = %s\n' "$TELEMT_SYNLIMIT_SECONDS" >> "$TELEMT_HOME/telemt.toml"
      printf 'synlimit_hitcount = %s\n' "$TELEMT_SYNLIMIT_HITCOUNT" >> "$TELEMT_HOME/telemt.toml"
      printf 'synlimit_burst = %s\n' "$TELEMT_SYNLIMIT_BURST" >> "$TELEMT_HOME/telemt.toml"
      printf 'synlimit_ios_seconds = %s\n' "$TELEMT_SYNLIMIT_IOS_SECONDS" >> "$TELEMT_HOME/telemt.toml"
      printf 'synlimit_ios_hitcount = %s\n' "$TELEMT_SYNLIMIT_IOS_HITCOUNT" >> "$TELEMT_HOME/telemt.toml"
      printf 'synlimit_ios_burst = %s\n' "$TELEMT_SYNLIMIT_IOS_BURST" >> "$TELEMT_HOME/telemt.toml"
      printf 'synlimit_hashlimit_expire_ms = %s\n' "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS" >> "$TELEMT_HOME/telemt.toml"
      printf 'synlimit_hashlimit_size = %s\n' "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE" >> "$TELEMT_HOME/telemt.toml"
    fi
  fi
  cat >> "$TELEMT_HOME/telemt.toml" <<EOF

[censorship]
tls_domain = "${PUBLIC_HOST}"
mask = true
mask_host = "127.0.0.1"
mask_port = 8443
mask_dynamic = false
tls_emulation = true
tls_front_dir = "/tmp/telemt-tlsfront"
tls_full_cert_ttl_secs = 0
alpn_enforce = true
EOF
  if telemt_supports_exclusive_mask; then
    cat >> "$TELEMT_HOME/telemt.toml" <<EOF

[censorship.exclusive_mask]
"${PUBLIC_HOST}" = "127.0.0.1:8443"
EOF
  fi
  cat >> "$TELEMT_HOME/telemt.toml" <<EOF

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
EOF
  while IFS= read -r user; do
    [ -n "$user" ] || continue
    secret="$(secret_for_user "$user")"
    printf '"%s" = "%s"\n' "$user" "$secret" >> "$TELEMT_HOME/telemt.toml"
  done <<EOF
$(telemt_users_list)
EOF
  if telemt_supports_user_enabled; then
    cat >> "$TELEMT_HOME/telemt.toml" <<EOF

[access.user_enabled]
EOF
    while IFS= read -r user; do
      [ -n "$user" ] || continue
      printf '"%s" = true\n' "$user" >> "$TELEMT_HOME/telemt.toml"
    done <<EOF
$(telemt_users_list)
EOF
  fi
  cat >> "$TELEMT_HOME/telemt.toml" <<EOF

[access.user_max_tcp_conns]
EOF
  while IFS= read -r user; do
    [ -n "$user" ] || continue
    printf '"%s" = %s\n' "$user" "$TELEMT_MAX_TCP_CONNS" >> "$TELEMT_HOME/telemt.toml"
  done <<EOF
$(telemt_users_list)
EOF
  cat >> "$TELEMT_HOME/telemt.toml" <<EOF

[[upstreams]]
type = "direct"
enabled = true
weight = 10
ipv4 = true
ipv6 = false
EOF
  chmod 600 "$TELEMT_HOME/telemt.toml"
}

write_report_script() {
  cat > /usr/local/sbin/telemt-report <<EOF
#!/bin/sh
SINCE="\${1:-5m}"
TELEMT_HOME="$TELEMT_HOME"
API_URL="\${API_URL:-http://127.0.0.1:9091}"

echo "=== SUMMARY ==="
date
hostname
if [ -f "\$TELEMT_HOME/run/telemt.pid" ] && kill -0 "\$(cat "\$TELEMT_HOME/run/telemt.pid")" 2>/dev/null; then
  echo "telemt: running"
else
  echo "telemt: not running"
fi
if [ -f "\$TELEMT_HOME/run/nginx.pid" ] && kill -0 "\$(cat "\$TELEMT_HOME/run/nginx.pid")" 2>/dev/null; then
  echo "nginx: running"
else
  echo "nginx: not running"
fi

echo
echo "=== TELEMT API ==="
if command -v jq >/dev/null 2>&1; then
  curl -fsS "\$API_URL/v1/users" 2>/dev/null | jq . || echo "api not reachable"
else
  curl -fsS "\$API_URL/v1/users" 2>/dev/null || echo "api not reachable"
fi

echo
echo "=== TCP LISTENERS ==="
if command -v ss >/dev/null 2>&1; then
  ss -lntp 2>/dev/null | grep -E ':(443|8443|1443|9091)\b' || true
else
  netstat -lntp 2>/dev/null | grep -E ':(443|8443|1443|9091)\b' || true
fi

echo
echo "=== RUNTIME LOGGING ==="
echo "nginx access logs: disabled"
echo "telemt runtime logs: disabled"
if [ -x "\$TELEMT_HOME/bin/watchdog.sh" ]; then
  echo "watchdog: installed via crond"
  echo "watchdog log: \$TELEMT_HOME/log/watchdog.log"
else
  echo "watchdog: not installed"
fi
EOF
  chmod 700 /usr/local/sbin/telemt-report
}

persist_tinycore_files() {
  touch /opt/.filetool.lst
  for item in opt/telemt opt/acme.sh opt/bootlocal.sh opt/.filetool.lst usr/local/sbin/telemt-report; do
    grep -Fxq "$item" /opt/.filetool.lst 2>/dev/null || echo "$item" >> /opt/.filetool.lst
  done

  touch "$BOOTLOCAL"
  chmod 755 "$BOOTLOCAL"
  if grep -Fq "$TELEMT_HOME/bin/restart.sh" "$BOOTLOCAL"; then
    sed -i "s|.*$TELEMT_HOME/bin/restart.sh.*|$TELEMT_HOME/bin/restart.sh >/dev/null 2>\\&1 \\&|" "$BOOTLOCAL" 2>/dev/null || true
  else
    cat >> "$BOOTLOCAL" <<EOF

# Telemt autostart
$TELEMT_HOME/bin/restart.sh >/dev/null 2>&1 &
EOF
  fi

  if ! grep -Fq "$TELEMT_HOME/bin/renew-cert.sh" "$BOOTLOCAL"; then
    cat >> "$BOOTLOCAL" <<EOF

# Telemt certificate renewal cron
mkdir -p /var/spool/cron/crontabs
touch /var/spool/cron/crontabs/root
grep -Fq '$TELEMT_HOME/bin/renew-cert.sh' /var/spool/cron/crontabs/root 2>/dev/null || echo '17 3 * * * $TELEMT_HOME/bin/renew-cert.sh >/dev/null 2>&1' >> /var/spool/cron/crontabs/root
crond 2>/dev/null || true
EOF
  fi

  if ! grep -Fq "$TELEMT_HOME/bin/watchdog.sh" "$BOOTLOCAL"; then
    cat >> "$BOOTLOCAL" <<EOF

# Telemt watchdog cron
mkdir -p /var/spool/cron/crontabs
touch /var/spool/cron/crontabs/root
grep -Fq '$TELEMT_HOME/bin/watchdog.sh' /var/spool/cron/crontabs/root 2>/dev/null || echo '* * * * * $TELEMT_HOME/bin/watchdog.sh >/dev/null 2>&1' >> /var/spool/cron/crontabs/root
crond 2>/dev/null || true
EOF
  fi

  cat > "$TELEMT_HOME/bin/renew-cert.sh" <<EOF
#!/bin/sh
set -eu
LOCK_DIR="/tmp/telemt-renew-cert.lock"

if ! mkdir "\$LOCK_DIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "\$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM

"$ACME_HOME/acme.sh" --home "$ACME_HOME" --cron --server letsencrypt
EOF
  chmod 700 "$TELEMT_HOME/bin/renew-cert.sh"

  mkdir -p /var/spool/cron/crontabs
  touch /var/spool/cron/crontabs/root
  grep -Fq "$TELEMT_HOME/bin/renew-cert.sh" /var/spool/cron/crontabs/root 2>/dev/null || \
    echo "17 3 * * * $TELEMT_HOME/bin/renew-cert.sh >/dev/null 2>&1" >> /var/spool/cron/crontabs/root
  grep -Fq "$TELEMT_HOME/bin/watchdog.sh" /var/spool/cron/crontabs/root 2>/dev/null || \
    echo "* * * * * $TELEMT_HOME/bin/watchdog.sh >/dev/null 2>&1" >> /var/spool/cron/crontabs/root
  crond 2>/dev/null || true

  filetool.sh -b
}

write_proxy_link() {
  tmp_users="$(mktemp)"
  chmod 600 "$tmp_users"
  curl -fsS http://127.0.0.1:9091/v1/users > "$tmp_users"
  grep -o 'tg://proxy[^"]*' "$tmp_users" > /root/telemt-proxy-link.txt || true
  rm -f "$tmp_users"
  chmod 600 /root/telemt-proxy-link.txt 2>/dev/null || true
}

run_update_mode() {
  [ -f "$RESUME_CONFIG" ] || die "Resume config not found: $RESUME_CONFIG. Run the installer normally once before --update."
  [ -n "$PUBLIC_HOST" ] || die "PUBLIC_HOST is empty in $RESUME_CONFIG."
  valid_domain "$PUBLIC_HOST" || die "Bad PUBLIC_HOST in $RESUME_CONFIG: $PUBLIC_HOST"
  resolve_update_release
  valid_telemt_release "$TELEMT_RELEASE" || die "Telemt release must be an exact tag like $TELEMT_LATEST_COMPATIBLE_RELEASE; latest is not allowed."
  TELEMT_DETECTED_RELEASE="$(detect_installed_telemt_release || true)"
  if [ "$ALLOW_TELEMT_DOWNGRADE" != "1" ] &&
     [ -n "$TELEMT_DETECTED_RELEASE" ] &&
     version_gt "$TELEMT_DETECTED_RELEASE" "$TELEMT_UPDATE_TARGET_RELEASE"; then
    die "Refusing Telemt downgrade ${TELEMT_DETECTED_RELEASE} -> ${TELEMT_UPDATE_TARGET_RELEASE}. Set ALLOW_TELEMT_DOWNGRADE=1 only for an intentional rollback."
  fi

  if [ -z "$TELEMT_SECRET" ] && [ -f "$TELEMT_HOME/telemt-secret.env" ]; then
    # shellcheck disable=SC1090
    . "$TELEMT_HOME/telemt-secret.env"
  fi

  TELEMT_USER="${TELEMT_USER:-default}"
  TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
  normalize_telemt_users
  TELEMT_SECRET="$(secret_for_user "$TELEMT_USER")"
  printf '%s\n' "$TELEMT_SECRET" | grep -Eq '^[A-Fa-f0-9]{32}$' || die "Cannot detect existing Telemt secret safely."

  TELEMT_CLIENT_MSS="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
  TELEMT_CLIENT_MSS_BULK="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")"
  TELEMT_SYNLIMIT="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
  USE_MIDDLE_PROXY="$(normalize_yes_no "$USE_MIDDLE_PROXY")"
  if [ -n "$AD_TAG" ]; then
    printf '%s\n' "$AD_TAG" | grep -Eq '^[A-Fa-f0-9]{32}$' || die "ad_tag must be 32 hex chars."
  fi
  valid_synlimit_number "$TELEMT_SYNLIMIT_SECONDS" || die "TELEMT_SYNLIMIT_SECONDS must be a positive number."
  valid_synlimit_number "$TELEMT_SYNLIMIT_HITCOUNT" || die "TELEMT_SYNLIMIT_HITCOUNT must be a positive number."
  valid_synlimit_number "$TELEMT_SYNLIMIT_BURST" || die "TELEMT_SYNLIMIT_BURST must be a positive number."
  valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_SECONDS" || die "TELEMT_SYNLIMIT_IOS_SECONDS must be a positive number."
  valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_HITCOUNT" || die "TELEMT_SYNLIMIT_IOS_HITCOUNT must be a positive number."
  valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_BURST" || die "TELEMT_SYNLIMIT_IOS_BURST must be a positive number."
  valid_synlimit_number "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS" || die "TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS must be a positive number."
  valid_synlimit_number "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE" || die "TELEMT_SYNLIMIT_HASHLIMIT_SIZE must be a positive number."

  detect_public_ip
  backup_dir="$TELEMT_HOME/update-backups/$(date +%Y%m%d-%H%M%S)"

  cat <<EOF

Tiny Core Telemt update plan:
  domain:       ${PUBLIC_HOST}
  public IPv4:  ${PUBLIC_IP}
  current:      ${TELEMT_DETECTED_RELEASE:-unknown}
  target:       ${TELEMT_UPDATE_TARGET_RELEASE} (exact compatible release)
  users:        ${TELEMT_USERS}
  client_mss:   ${TELEMT_CLIENT_MSS}
  client_mss_bulk: ${TELEMT_CLIENT_MSS_BULK}
  synlimit:     ${TELEMT_SYNLIMIT}
  backup:       ${backup_dir}
EOF
  confirm_update_plan

  mkdir -p "$backup_dir"
  [ -f "$TELEMT_HOME/telemt.toml" ] && cp "$TELEMT_HOME/telemt.toml" "$backup_dir/"
  [ -f "$TELEMT_HOME/bin/telemt" ] && cp "$TELEMT_HOME/bin/telemt" "$backup_dir/"
  chmod -R go-rwx "$backup_dir" 2>/dev/null || true

  step "Download checked Telemt release"
  download_telemt
  step "Rewrite Telemt config"
  write_telemt_config
  step "Refresh scripts and persistence"
  write_restart_script
  write_report_script
  persist_tinycore_files
  save_resume_config
  step "Restart Telemt"
  "$TELEMT_HOME/bin/restart.sh"
  sleep 2
  write_proxy_link || true
  telemt-report 2m || true
}

require_tinycore

if [ "${RESET_INSTALL_STATE:-0}" = "1" ]; then
  rm -f "$STATE_FILE" "$RESUME_CONFIG"
fi

if [ -f "$RESUME_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$RESUME_CONFIG"
  echo "Resume config found: $RESUME_CONFIG"
fi

if [ "$UPDATE_MODE" = "1" ]; then
  run_update_mode
  exit 0
fi

cat <<'EOF'
Telemt Tiny Core Linux installer, no Docker, no systemd.

Before running:
  1. Use x86_64/CorePure64 or aarch64 Tiny Core.
  2. Configure persistent /tce first.
  3. Create DNS A record: <domain> -> this server IPv4.
  4. Make sure ports 80 and 443 are reachable from the internet.
  5. Keep the current SSH session open until a second login works.

EOF

prompt_value_assume "Proxy domain" "$PUBLIC_HOST"
PUBLIC_HOST="$REPLY"
valid_domain "$PUBLIC_HOST" || die "Domain must be a valid DNS name, for example proxy.example.com."

LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@$PUBLIC_HOST}"
prompt_value_assume "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
LETSENCRYPT_EMAIL="$REPLY"

prompt_value_assume "SSH port, Enter keeps current/default. Tiny Core installer does not change SSH config" "$SSH_PORT"
SSH_PORT="$REPLY"

prompt_value_assume "Max Telemt connections" "$TELEMT_MAX_TCP_CONNS"
TELEMT_MAX_TCP_CONNS="$REPLY"

prompt_value_assume "Telemt release version" "$TELEMT_RELEASE"
TELEMT_RELEASE="$REPLY"

prompt_value_assume "Telemt first user name" "$TELEMT_USER"
TELEMT_USER="$REPLY"
valid_user_name "$TELEMT_USER" || die "Bad Telemt user name: $TELEMT_USER"
TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
append_telemt_user "$TELEMT_USER"
if [ -z "$TELEMT_LINK_COUNT" ]; then
  TELEMT_LINK_COUNT="$(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | grep -c .)"
fi
prompt_value_assume "How many proxy links/users to create now" "$TELEMT_LINK_COUNT"
TELEMT_LINK_COUNT="$REPLY"
printf '%s\n' "$TELEMT_LINK_COUNT" | grep -Eq '^[0-9]+$' && [ "$TELEMT_LINK_COUNT" -ge 1 ] && [ "$TELEMT_LINK_COUNT" -le 100 ] ||
  die "Telemt link count must be between 1 and 100."
i=2
while [ "$i" -le "$TELEMT_LINK_COUNT" ]; do
  default_user="$(telemt_user_at "$i" 2>/dev/null || printf 'user%s' "$i")"
  prompt_value_assume "Telemt user name #$i" "$default_user"
  append_telemt_user "$REPLY"
  i=$((i + 1))
done

prompt_value_assume "Telemt listener TCP MSS: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS"
TELEMT_CLIENT_MSS="$REPLY"

prompt_value_assume "Telemt bulk-phase TCP MSS after handshake: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS_BULK"
TELEMT_CLIENT_MSS_BULK="$REPLY"

prompt_value_assume "Telemt listener SYN limiter: false/iptables/nftables" "$TELEMT_SYNLIMIT"
TELEMT_SYNLIMIT="$REPLY"

prompt_value_assume "MTProxy ad_tag, Enter = skip" "$AD_TAG"
AD_TAG="$REPLY"
if [ -z "$USE_MIDDLE_PROXY" ]; then
  if [ -n "$AD_TAG" ]; then
    USE_MIDDLE_PROXY="yes"
  else
    USE_MIDDLE_PROXY="no"
  fi
fi
prompt_value_assume "Use Telegram middle proxy: yes/no" "$USE_MIDDLE_PROXY"
USE_MIDDLE_PROXY="$REPLY"

printf '%s\n' "$LETSENCRYPT_EMAIL" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' || die "Email must be a plain email address."
valid_port "$SSH_PORT" || die "SSH port must be a number from 1 to 65535."
valid_limit "$TELEMT_MAX_TCP_CONNS" || die "Connection limit must be a number from 1 to 1000000."
valid_telemt_release "$TELEMT_RELEASE" || die "Telemt release must be an exact tag like $TELEMT_LATEST_COMPATIBLE_RELEASE; latest is not allowed."
normalize_telemt_users
TELEMT_CLIENT_MSS="$(normalize_client_mss "$TELEMT_CLIENT_MSS")"
TELEMT_CLIENT_MSS_BULK="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")"
TELEMT_SYNLIMIT="$(normalize_synlimit "$TELEMT_SYNLIMIT")"
valid_synlimit_number "$TELEMT_SYNLIMIT_SECONDS" || die "TELEMT_SYNLIMIT_SECONDS must be a positive number."
valid_synlimit_number "$TELEMT_SYNLIMIT_HITCOUNT" || die "TELEMT_SYNLIMIT_HITCOUNT must be a positive number."
valid_synlimit_number "$TELEMT_SYNLIMIT_BURST" || die "TELEMT_SYNLIMIT_BURST must be a positive number."
valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_SECONDS" || die "TELEMT_SYNLIMIT_IOS_SECONDS must be a positive number."
valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_HITCOUNT" || die "TELEMT_SYNLIMIT_IOS_HITCOUNT must be a positive number."
valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_BURST" || die "TELEMT_SYNLIMIT_IOS_BURST must be a positive number."
valid_synlimit_number "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS" || die "TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS must be a positive number."
valid_synlimit_number "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE" || die "TELEMT_SYNLIMIT_HASHLIMIT_SIZE must be a positive number."
if [ -n "$AD_TAG" ]; then
  printf '%s\n' "$AD_TAG" | grep -Eq '^[A-Fa-f0-9]{32}$' || die "ad_tag must be 32 hex chars."
fi
USE_MIDDLE_PROXY="$(normalize_yes_no "$USE_MIDDLE_PROXY")"

if [ -z "$TELEMT_SECRET" ] && [ -f "$TELEMT_HOME/telemt-secret.env" ]; then
  # shellcheck disable=SC1090
  . "$TELEMT_HOME/telemt-secret.env"
fi

save_resume_config

cat <<EOF

Install plan:
  target OS:    Tiny Core Linux
  domain:       ${PUBLIC_HOST}
  email:        ${LETSENCRYPT_EMAIL}
  SSH port:     ${SSH_PORT} (not changed by this installer)
  Telemt limit: ${TELEMT_MAX_TCP_CONNS}
  release:      ${TELEMT_RELEASE}
  users:        ${TELEMT_USERS}
  client_mss:   ${TELEMT_CLIENT_MSS}
  client_mss_bulk: ${TELEMT_CLIENT_MSS_BULK}
  synlimit:     ${TELEMT_SYNLIMIT}
  ad_tag:       $([ -n "$AD_TAG" ] && printf yes || printf no)
  middle_proxy: ${USE_MIDDLE_PROXY}

Type y or yes to continue:
EOF
if [ "$ASSUME_YES" = "1" ]; then
  echo "ASSUME_YES=1, continuing."
else
  read -r confirm
  case "$confirm" in
    y|Y|yes|YES|Yes) ;;
    *) die "Cancelled." ;;
  esac
fi

if step_done extensions; then
  step "Install Tiny Core extensions (already done)"
else
  step "Install Tiny Core extensions"
  install_extensions
  mark_done extensions
fi

step "DNS preflight"
detect_public_ip
echo "server_public_ipv4=$PUBLIC_IP"
resolved_ips="$(resolve_ipv4 "$PUBLIC_HOST" | tr '\n' ' ')"
echo "domain_ipv4=$resolved_ips"
if ! printf ' %s ' "$resolved_ips" | grep -q " $PUBLIC_IP "; then
  cat >&2 <<EOF

DNS check failed.

${PUBLIC_HOST} must resolve to this server IPv4 before SSL can be issued.

Expected:
  ${PUBLIC_HOST} -> ${PUBLIC_IP}

Current A records:
  ${resolved_ips:-none}
EOF
  exit 1
fi
save_resume_config

if step_done secret; then
  step "Prepare Telemt secret (already done)"
else
  step "Prepare Telemt secret"
  if [ -z "$TELEMT_SECRET" ]; then
    TELEMT_SECRET="$(openssl rand -hex 16)"
  fi
  mkdir -p "$TELEMT_HOME"
  umask 077
  cat > "$TELEMT_HOME/telemt-secret.env" <<EOF
TELEMT_SECRET=${TELEMT_SECRET}
EOF
  chmod 600 "$TELEMT_HOME/telemt-secret.env"
  save_resume_config
  mark_done secret
fi

if step_done telemt_binary; then
  step "Install Telemt native binary (already done)"
else
  step "Install Telemt native binary"
  download_telemt
  mark_done telemt_binary
fi

if step_done acme; then
  step "Install acme.sh (already done)"
else
  step "Install acme.sh"
  install_acme_sh
  mark_done acme
fi

step "Write service scripts and configs"
write_restart_script
write_mask_page
write_telemt_config

if step_done cert; then
  step "Issue certificate (already done)"
else
  step "Issue certificate"
  issue_certificate
  mark_done cert
fi

step "Configure acme.sh renewal hooks"
configure_acme_renewal_hooks

step "Configure nginx"
write_nginx_config
rm -f "$TELEMT_HOME/log/telemt.log" "$TELEMT_HOME/log/nginx-access.log" "$TELEMT_HOME/log/nginx-error.log" 2>/dev/null || true

step "Start Telemt"
"$TELEMT_HOME/bin/restart.sh"
sleep 8

step "Install report script and persistence"
write_report_script
persist_tinycore_files

step "Validation"
write_proxy_link
curl -fsSIs --resolve "${PUBLIC_HOST}:80:${PUBLIC_IP}" "http://${PUBLIC_HOST}/" | head -n 12 || true
curl -fsSIs --resolve "${PUBLIC_HOST}:443:${PUBLIC_IP}" "https://${PUBLIC_HOST}/" | head -n 12 || true
telemt-report 2m || true

cat <<EOF

Installed Telemt on Tiny Core Linux.

Proxy host: ${PUBLIC_HOST}:443
Telemt limit: ${TELEMT_MAX_TCP_CONNS}
Proxy link file: /root/telemt-proxy-link.txt
Secret: ${TELEMT_HOME}/telemt-secret.env
Config: ${TELEMT_HOME}/telemt.toml
Autostart: /opt/bootlocal.sh
Certificate renewal: ${TELEMT_HOME}/bin/renew-cert.sh via crond
Watchdog: ${TELEMT_HOME}/bin/watchdog.sh via crond
EOF

if [ -s /root/telemt-proxy-link.txt ]; then
  echo
  echo "Proxy link:"
  cat /root/telemt-proxy-link.txt
else
  echo
  echo "Proxy link was not generated. Check:"
  echo "  curl -fsS http://127.0.0.1:9091/v1/users"
fi
