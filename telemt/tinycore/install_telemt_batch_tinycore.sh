#!/usr/bin/env bash
set -Eeuo pipefail

# Batch orchestrator for install_telemt_tinycore.sh.
# Run this script on your local admin machine. It collects proxy domains,
# resolves A records, checks SSH access, optionally calls add_key.sh,
# then copies and runs install_telemt_tinycore.sh on each Tiny Core target.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALLER_FILE="${INSTALLER_FILE:-$SCRIPT_DIR/install_telemt_tinycore.sh}"
INSTALLER_README_FILE="${INSTALLER_README_FILE:-$SCRIPT_DIR/README.md}"
ADD_KEY_FILE="${ADD_KEY_FILE:-$SCRIPT_DIR/../common/add_key.sh}"
REMOTE_INSTALLER_NAME="${REMOTE_INSTALLER_NAME:-$(basename "$INSTALLER_FILE")}"

SSH_USER="${SSH_USER:-root}"
CONNECT_SSH_PORT="${CONNECT_SSH_PORT:-22}"
TARGET_SSH_PORT="${TARGET_SSH_PORT:-22}"
TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-5000}"
TELEMT_LATEST_COMPATIBLE_RELEASE="${TELEMT_LATEST_COMPATIBLE_RELEASE:-3.4.22}"
TELEMT_RELEASE="${TELEMT_RELEASE:-$TELEMT_LATEST_COMPATIBLE_RELEASE}"
TELEMT_USER="${TELEMT_USER:-default}"
TELEMT_USERS="${TELEMT_USERS:-}"
TELEMT_LINK_COUNT="${TELEMT_LINK_COUNT:-}"
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
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
KEY_PATH="${KEY_PATH:-${HOME}/.ssh/id_ed25519}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-15}"
STRICT_HOST_KEY_CHECKING="${STRICT_HOST_KEY_CHECKING:-accept-new}"

DOMAINS=()
IPS=()
AUTH_MODES=()
RESULTS=()
PROXY_LINKS=()
SSH_OPTS=()
SCP_OPTS=()

have() {
  command -v "$1" >/dev/null 2>&1
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

prompt_default() {
  local var="$1"
  local label="$2"
  local default_value="$3"
  local answer=""

  if [[ -n "$default_value" ]]; then
    printf '%s [%s]: ' "$label" "$default_value"
  else
    printf '%s: ' "$label"
  fi
  read -r answer

  if [[ -n "$answer" ]]; then
    printf -v "$var" '%s' "$answer"
  else
    printf -v "$var" '%s' "$default_value"
  fi
}

confirm() {
  local label="${1:-Continue? [y/N]: }"
  local answer=""

  printf '%s' "$label"
  read -r answer
  case "$answer" in
    y|Y|yes|YES|Yes|д|Д|да|ДА) return 0 ;;
    *) return 1 ;;
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

valid_limit() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 && "$1" <= 1000000 ))
}

valid_user_name() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{1,64}$ ]]
}

valid_telemt_release() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

normalize_client_mss() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    off|none|no|false|0) printf '%s' "off" ;;
    tspu|2in8|extreme-low) printf '%s' "$value" ;;
    *)
      if [[ "$value" =~ ^[0-9]+$ ]] && (( value >= 88 && value <= 4096 )); then
        printf '%s' "$value"
      else
        return 1
      fi
      ;;
  esac
}

normalize_synlimit() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    false|no|off|0) printf '%s' "false" ;;
    iptables|nftables) printf '%s' "$value" ;;
    *) return 1 ;;
  esac
}

normalize_yes_no() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    yes|y|true|1|да|д) printf '%s' "yes" ;;
    no|n|false|0|нет|н|'') printf '%s' "no" ;;
    *) return 1 ;;
  esac
}

valid_synlimit_number() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( "$1" >= 1 ))
}

append_telemt_user() {
  local user="$1"
  [[ -n "$user" ]] || return 0
  valid_user_name "$user" || die "Bad Telemt user name: $user"
  if [[ -z "$TELEMT_USERS" ]]; then
    TELEMT_USERS="$user"
  elif ! printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | grep -Fxq "$user"; then
    TELEMT_USERS="${TELEMT_USERS},${user}"
  fi
}

normalize_telemt_users() {
  local user normalized=""
  [[ -n "$TELEMT_USER" ]] || TELEMT_USER="default"
  TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
  while IFS= read -r user; do
    user="$(printf '%s' "$user" | xargs)"
    [[ -n "$user" ]] || continue
    valid_user_name "$user" || die "Bad Telemt user name: $user"
    if [[ -z "$normalized" ]]; then
      normalized="$user"
    elif ! printf '%s\n' "$normalized" | tr ',' '\n' | grep -Fxq "$user"; then
      normalized="${normalized},${user}"
    fi
  done < <(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n')
  [[ -n "$normalized" ]] || normalized="$TELEMT_USER"
  TELEMT_USERS="$normalized"
  TELEMT_USER="$(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | sed -n '1p')"
  TELEMT_LINK_COUNT="$(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | grep -c .)"
}

telemt_user_at() {
  local wanted="$1"
  printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | sed -n "${wanted}p"
}

shell_quote() {
  printf '%q' "$1"
}

resolve_ipv4() {
  local host="$1"

  if have getent; then
    getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u
    return 0
  fi

  if have dig; then
    dig +short A "$host" 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ {print}' | sort -u
    return 0
  fi

  if have host; then
    host "$host" 2>/dev/null | awk '/has address/ {print $NF}' | sort -u
    return 0
  fi

  die "Need one of: getent, dig, host"
}

join_by() {
  local sep="$1"
  shift
  local first=1
  local item

  for item in "$@"; do
    if [[ "$first" -eq 1 ]]; then
      printf '%s' "$item"
      first=0
    else
      printf '%s%s' "$sep" "$item"
    fi
  done
}

require_files() {
  [[ -f "$INSTALLER_FILE" ]] || die "Missing installer: $INSTALLER_FILE"
  [[ -f "$ADD_KEY_FILE" ]] || die "Missing SSH key helper: $ADD_KEY_FILE"
  chmod +x "$INSTALLER_FILE" "$ADD_KEY_FILE"
  if [[ -f "$INSTALLER_README_FILE" ]]; then
    :
  else
    echo "Warning: missing README file: $INSTALLER_README_FILE"
  fi
}

preflight_local_machine() {
  local os_name
  local bash_major
  local missing=()

  os_name="$(uname -s 2>/dev/null || echo unknown)"
  case "$os_name" in
    Darwin|Linux) ;;
    *)
      die "Unsupported local OS: $os_name. Run batch from macOS or any Linux admin machine."
      ;;
  esac

  bash_major="${BASH_VERSINFO[0]:-0}"
  if [[ "$bash_major" -lt 3 ]]; then
    die "Bash 3+ is required. Current bash: ${BASH_VERSION:-unknown}"
  fi

  have ssh || missing+=("ssh")
  have scp || missing+=("scp")

  if ! have getent && ! have dig && ! have host; then
    missing+=("getent/dig/host")
  fi

  if [[ "${#missing[@]}" -gt 0 ]]; then
    die "Missing local tools: $(join_by ', ' "${missing[@]}")"
  fi

  echo "Local preflight OK: os=$os_name bash=${BASH_VERSION:-unknown}"
  echo "Note: install_telemt_batch_tinycore.sh is a local orchestrator for Tiny Core targets."
  echo "It can run on macOS or any Linux admin machine and will not install Telemt locally."
}

select_domain_ip() {
  local domain="$1"
  local -a records=()
  local ip=""
  local answer=""

  while IFS= read -r ip; do
    records+=("$ip")
  done < <(resolve_ipv4 "$domain")

  while [[ "${#records[@]}" -eq 0 ]]; do
    echo
    echo "No A record found for: $domain"
    echo "Enter another domain with a valid A record for this server, or press Enter to skip it."
    printf 'Replacement domain: '
    read -r answer
    if [[ -z "$answer" ]]; then
      return 1
    fi
    if ! valid_domain "$answer"; then
      echo "Bad domain: $answer"
      continue
    fi
    domain="$answer"
    records=()
    while IFS= read -r ip; do
      records+=("$ip")
    done < <(resolve_ipv4 "$domain")
  done

  if [[ "${#records[@]}" -eq 1 ]]; then
    ip="${records[0]}"
  else
    echo
    echo "Multiple A records found for $domain:"
    printf '  %s\n' "${records[@]}"
    prompt_default ip "Server IP to use" "${records[0]}"
    if ! printf '%s\n' "${records[@]}" | grep -Fxq "$ip"; then
      echo "Warning: selected IP is not in the current A record set."
    fi
  fi

  DOMAINS+=("$domain")
  IPS+=("$ip")
  return 0
}

collect_domains() {
  local domain=""

  echo "Enter proxy domains, one per line. Press Enter on an empty line when finished."
  while true; do
    printf 'Domain: '
    read -r domain
    [[ -z "$domain" ]] && break

    if ! valid_domain "$domain"; then
      echo "Bad domain: $domain"
      continue
    fi

    select_domain_ip "$domain" || true
  done

  [[ "${#DOMAINS[@]}" -gt 0 ]] || die "No domains selected."
}

build_ssh_opts_key() {
  local port="$1"
  SSH_OPTS=(
    -p "$port"
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
    -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}"
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts"
    -o BatchMode=yes
    -o PreferredAuthentications=publickey
    -o PasswordAuthentication=no
    -o KbdInteractiveAuthentication=no
  )

  if [[ -n "$KEY_PATH" && -f "$KEY_PATH" ]]; then
    SSH_OPTS+=(-i "$KEY_PATH" -o IdentitiesOnly=yes)
  fi
}

build_ssh_opts_interactive() {
  local port="$1"
  SSH_OPTS=(
    -p "$port"
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
    -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}"
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts"
  )

  if [[ -n "$KEY_PATH" && -f "$KEY_PATH" ]]; then
    SSH_OPTS+=(-i "$KEY_PATH")
  fi
}

build_scp_opts_for_mode() {
  local port="$1"
  local mode="$2"
  SCP_OPTS=(
    -P "$port"
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
    -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}"
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts"
  )

  if [[ -n "$KEY_PATH" && -f "$KEY_PATH" ]]; then
    SCP_OPTS+=(-i "$KEY_PATH")
  fi

  if [[ "$mode" == "key" ]]; then
    SCP_OPTS+=(
      -o BatchMode=yes
      -o PreferredAuthentications=publickey
      -o PasswordAuthentication=no
      -o KbdInteractiveAuthentication=no
      -o IdentitiesOnly=yes
    )
  fi
}

check_key_login() {
  local ip="$1"
  local target="${SSH_USER}@${ip}"

  build_ssh_opts_key "$CONNECT_SSH_PORT"
  ssh "${SSH_OPTS[@]}" "$target" 'printf KEY_LOGIN_OK' 2>/dev/null | grep -q KEY_LOGIN_OK
}

run_add_key_helper() {
  local ip="$1"

  echo
  echo "Running add_key.sh for ${SSH_USER}@${ip}:${CONNECT_SSH_PORT}"
  SERVER_INPUT="${SSH_USER}@${ip}" \
    SERVER_PORT="$CONNECT_SSH_PORT" \
    KEY_PATH="$KEY_PATH" \
    "$ADD_KEY_FILE"
}

choose_auth_mode() {
  local domain="$1"
  local ip="$2"
  local answer=""

  if check_key_login "$ip"; then
    echo "SSH key works for $domain ($ip)."
    AUTH_MODES+=("key")
    return 0
  fi

  while true; do
    echo
    echo "SSH key login does not work for $domain ($ip)."
    echo "Choose:"
    echo "  1) Copy/install key with add_key.sh (recommended)"
    echo "  2) Use SSH password for this installation"
    echo "  3) Skip this server"
    printf 'Choice [1]: '
    read -r answer
    answer="${answer:-1}"

    case "$answer" in
      1)
        run_add_key_helper "$ip"
        if check_key_login "$ip"; then
          AUTH_MODES+=("key")
          return 0
        fi
        echo "Key login still does not work."
        ;;
      2)
        cat <<'EOF'

Password mode will use interactive SSH/SCP password prompts.
The Tiny Core installer does not change SSH configuration, but key login is
still recommended so the batch script can finish non-interactively and fetch
the generated proxy link.

EOF
        if confirm "Use password mode for this server? [y/N]: "; then
          AUTH_MODES+=("password")
          return 0
        fi
        ;;
      3)
        AUTH_MODES+=("skip")
        return 0
        ;;
      *)
        echo "Enter 1, 2, or 3."
        ;;
    esac
  done
}

copy_installer_files() {
  local ip="$1"
  local mode="$2"
  local target="${SSH_USER}@${ip}:/root/"
  local files=("$INSTALLER_FILE" "$ADD_KEY_FILE")

  if [[ -f "$INSTALLER_README_FILE" ]]; then
    files+=("$INSTALLER_README_FILE")
  fi

  build_scp_opts_for_mode "$CONNECT_SSH_PORT" "$mode"
  scp "${SCP_OPTS[@]}" "${files[@]}" "$target"
}

run_remote_installer() {
  local domain="$1"
  local ip="$2"
  local mode="$3"
  local email_answer="$LETSENCRYPT_EMAIL"
  local target="${SSH_USER}@${ip}"
  local remote_cmd

  if [[ "$mode" == "key" ]]; then
    build_ssh_opts_key "$CONNECT_SSH_PORT"
  else
    build_ssh_opts_interactive "$CONNECT_SSH_PORT"
  fi

  remote_cmd="chmod +x /root/${REMOTE_INSTALLER_NAME} /root/add_key.sh 2>/dev/null || true; "
  remote_cmd+="PUBLIC_HOST=$(shell_quote "$domain") "
  remote_cmd+="LETSENCRYPT_EMAIL=$(shell_quote "$email_answer") "
  remote_cmd+="SSH_PORT=$(shell_quote "$TARGET_SSH_PORT") "
  remote_cmd+="TELEMT_MAX_TCP_CONNS=$(shell_quote "$TELEMT_MAX_TCP_CONNS") "
  remote_cmd+="TELEMT_RELEASE=$(shell_quote "$TELEMT_RELEASE") "
  remote_cmd+="TELEMT_USER=$(shell_quote "$TELEMT_USER") "
  remote_cmd+="TELEMT_USERS=$(shell_quote "$TELEMT_USERS") "
  remote_cmd+="TELEMT_LINK_COUNT=$(shell_quote "$TELEMT_LINK_COUNT") "
  remote_cmd+="TELEMT_CLIENT_MSS=$(shell_quote "$TELEMT_CLIENT_MSS") "
  remote_cmd+="TELEMT_CLIENT_MSS_BULK=$(shell_quote "$TELEMT_CLIENT_MSS_BULK") "
  remote_cmd+="TELEMT_SYNLIMIT=$(shell_quote "$TELEMT_SYNLIMIT") "
  remote_cmd+="TELEMT_SYNLIMIT_SECONDS=$(shell_quote "$TELEMT_SYNLIMIT_SECONDS") "
  remote_cmd+="TELEMT_SYNLIMIT_HITCOUNT=$(shell_quote "$TELEMT_SYNLIMIT_HITCOUNT") "
  remote_cmd+="TELEMT_SYNLIMIT_BURST=$(shell_quote "$TELEMT_SYNLIMIT_BURST") "
  remote_cmd+="TELEMT_SYNLIMIT_IOS_SECONDS=$(shell_quote "$TELEMT_SYNLIMIT_IOS_SECONDS") "
  remote_cmd+="TELEMT_SYNLIMIT_IOS_HITCOUNT=$(shell_quote "$TELEMT_SYNLIMIT_IOS_HITCOUNT") "
  remote_cmd+="TELEMT_SYNLIMIT_IOS_BURST=$(shell_quote "$TELEMT_SYNLIMIT_IOS_BURST") "
  remote_cmd+="TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS=$(shell_quote "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS") "
  remote_cmd+="TELEMT_SYNLIMIT_HASHLIMIT_SIZE=$(shell_quote "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE") "
  remote_cmd+="AD_TAG=$(shell_quote "$AD_TAG") "
  remote_cmd+="USE_MIDDLE_PROXY=$(shell_quote "$USE_MIDDLE_PROXY") "
  remote_cmd+="ASSUME_YES=1 /root/${REMOTE_INSTALLER_NAME}"
  ssh "${SSH_OPTS[@]}" "$target" "$remote_cmd"
}

fetch_proxy_links() {
  local domain="$1"
  local ip="$2"
  local mode="$3"
  local target="${SSH_USER}@${ip}"
  local links=""

  if [[ "$mode" == "key" ]]; then
    build_ssh_opts_key "$TARGET_SSH_PORT"
  else
    build_ssh_opts_interactive "$TARGET_SSH_PORT"
  fi

  # Read the link generated by install_telemt_tinycore.sh. Fall back to the local API
  # in case the file was not written but Telemt is healthy.
  links="$(ssh "${SSH_OPTS[@]}" "$target" 'if [ -s /root/telemt-proxy-link.txt ]; then cat /root/telemt-proxy-link.txt; else curl -fsS http://127.0.0.1:9091/v1/users 2>/dev/null | grep -o "tg://proxy[^\"]*" || true; fi' 2>/dev/null || true)"

  if [[ -n "$links" ]]; then
    while IFS= read -r link; do
      [[ -n "$link" ]] || continue
      PROXY_LINKS+=("$domain $link")
    done <<< "$links"
  else
    PROXY_LINKS+=("$domain LINK_NOT_FOUND")
  fi
}

install_one() {
  local index="$1"
  local domain="${DOMAINS[$index]}"
  local ip="${IPS[$index]}"
  local mode="${AUTH_MODES[$index]}"

  echo
  echo "===== Installing $domain ($ip), auth=$mode ====="

  if [[ "$mode" == "skip" ]]; then
    RESULTS+=("$domain SKIPPED")
    return 0
  fi

  if copy_installer_files "$ip" "$mode" && run_remote_installer "$domain" "$ip" "$mode"; then
    fetch_proxy_links "$domain" "$ip" "$mode"
    RESULTS+=("$domain OK")
  else
    RESULTS+=("$domain FAILED")
    return 1
  fi
}

show_plan() {
  local i

  echo
  echo "Batch install plan:"
  echo "  SSH user:            $SSH_USER"
  echo "  connect SSH port:    $CONNECT_SSH_PORT"
  echo "  target SSH port:     $TARGET_SSH_PORT"
  echo "  Telemt limit:        $TELEMT_MAX_TCP_CONNS"
  echo "  Telemt release:      $TELEMT_RELEASE"
  echo "  Telemt users:        $TELEMT_USERS"
  echo "  Telemt client_mss:   $TELEMT_CLIENT_MSS"
  echo "  Telemt bulk MSS:     $TELEMT_CLIENT_MSS_BULK"
  echo "  Telemt synlimit:     $TELEMT_SYNLIMIT"
  echo "  MTProxy ad_tag:      $([[ -n "$AD_TAG" ]] && echo yes || echo no)"
  echo "  middle proxy:        $USE_MIDDLE_PROXY"
  if [[ -n "$LETSENCRYPT_EMAIL" ]]; then
    echo "  Let's Encrypt email: $LETSENCRYPT_EMAIL"
  else
    echo "  Let's Encrypt email: admin@<domain>"
  fi
  echo
  printf '%-4s %-34s %-16s %-10s\n' "#" "DOMAIN" "IP" "AUTH"
  for i in "${!DOMAINS[@]}"; do
    printf '%-4s %-34s %-16s %-10s\n' "$((i + 1))" "${DOMAINS[$i]}" "${IPS[$i]}" "${AUTH_MODES[$i]}"
  done
}

main() {
  local i

  preflight_local_machine
  require_files

  cat <<'EOF'
Telemt batch installer for Tiny Core targets.

This script runs on your admin machine, which can be macOS or any Linux.
It installs Telemt on remote Tiny Core servers by copying and executing
install_telemt_tinycore.sh on each target server.

EOF

  prompt_default SSH_USER "SSH user for installation" "$SSH_USER"
  if [[ "$SSH_USER" != "root" ]]; then
    die "install_telemt_tinycore.sh must run as root. Use SSH_USER=root."
  fi
  prompt_default CONNECT_SSH_PORT "Current SSH port for connecting to servers" "$CONNECT_SSH_PORT"
  prompt_default TARGET_SSH_PORT "SSH port after install, Tiny Core installer does not change SSH config" "$TARGET_SSH_PORT"
  prompt_default TELEMT_MAX_TCP_CONNS "Telemt max TCP connections" "$TELEMT_MAX_TCP_CONNS"
  prompt_default TELEMT_RELEASE "Telemt release version" "$TELEMT_RELEASE"
  prompt_default TELEMT_USER "Telemt first user name" "$TELEMT_USER"
  valid_user_name "$TELEMT_USER" || die "Bad Telemt user name: $TELEMT_USER"
  TELEMT_USERS="${TELEMT_USERS:-$TELEMT_USER}"
  append_telemt_user "$TELEMT_USER"
  if [[ -z "$TELEMT_LINK_COUNT" ]]; then
    TELEMT_LINK_COUNT="$(printf '%s\n' "$TELEMT_USERS" | tr ',' '\n' | grep -c .)"
  fi
  prompt_default TELEMT_LINK_COUNT "How many proxy links/users to create now" "$TELEMT_LINK_COUNT"
  [[ "$TELEMT_LINK_COUNT" =~ ^[0-9]+$ ]] && (( TELEMT_LINK_COUNT >= 1 && TELEMT_LINK_COUNT <= 100 )) ||
    die "Telemt link count must be between 1 and 100."
  for ((i=2; i<=TELEMT_LINK_COUNT; i++)); do
    current_user="$(telemt_user_at "$i")"
    [[ -n "$current_user" ]] || current_user="user${i}"
    prompt_default current_user "Telemt user name #$i" "$current_user"
    append_telemt_user "$current_user"
  done
  prompt_default TELEMT_CLIENT_MSS "Telemt listener TCP MSS: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS"
  prompt_default TELEMT_CLIENT_MSS_BULK "Telemt bulk-phase TCP MSS after handshake: off/tspu/2in8/extreme-low/88..4096" "$TELEMT_CLIENT_MSS_BULK"
  prompt_default TELEMT_SYNLIMIT "Telemt listener SYN limiter: false/iptables/nftables" "$TELEMT_SYNLIMIT"
  prompt_default AD_TAG "MTProxy ad_tag, Enter = skip" "$AD_TAG"
  if [[ -z "$USE_MIDDLE_PROXY" ]]; then
    if [[ -n "$AD_TAG" ]]; then
      USE_MIDDLE_PROXY="yes"
    else
      USE_MIDDLE_PROXY="no"
    fi
  fi
  prompt_default USE_MIDDLE_PROXY "Use Telegram middle proxy: yes/no" "$USE_MIDDLE_PROXY"
  prompt_default LETSENCRYPT_EMAIL "Common Let's Encrypt email, empty = admin@domain" "$LETSENCRYPT_EMAIL"

  valid_port "$CONNECT_SSH_PORT" || die "Current SSH port must be a number from 1 to 65535."
  valid_port "$TARGET_SSH_PORT" || die "Target SSH port must be a number from 1 to 65535."
  valid_limit "$TELEMT_MAX_TCP_CONNS" || die "Telemt limit must be a number from 1 to 1000000."
  valid_telemt_release "$TELEMT_RELEASE" || die "Telemt release must be an exact tag like $TELEMT_LATEST_COMPATIBLE_RELEASE; latest is not allowed."
  normalize_telemt_users
  TELEMT_CLIENT_MSS="$(normalize_client_mss "$TELEMT_CLIENT_MSS")" || die "Bad Telemt client_mss."
  TELEMT_CLIENT_MSS_BULK="$(normalize_client_mss "$TELEMT_CLIENT_MSS_BULK")" || die "Bad Telemt bulk MSS."
  TELEMT_SYNLIMIT="$(normalize_synlimit "$TELEMT_SYNLIMIT")" || die "Bad Telemt synlimit."
  valid_synlimit_number "$TELEMT_SYNLIMIT_SECONDS" || die "Bad TELEMT_SYNLIMIT_SECONDS."
  valid_synlimit_number "$TELEMT_SYNLIMIT_HITCOUNT" || die "Bad TELEMT_SYNLIMIT_HITCOUNT."
  valid_synlimit_number "$TELEMT_SYNLIMIT_BURST" || die "Bad TELEMT_SYNLIMIT_BURST."
  valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_SECONDS" || die "Bad TELEMT_SYNLIMIT_IOS_SECONDS."
  valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_HITCOUNT" || die "Bad TELEMT_SYNLIMIT_IOS_HITCOUNT."
  valid_synlimit_number "$TELEMT_SYNLIMIT_IOS_BURST" || die "Bad TELEMT_SYNLIMIT_IOS_BURST."
  valid_synlimit_number "$TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS" || die "Bad TELEMT_SYNLIMIT_HASHLIMIT_EXPIRE_MS."
  valid_synlimit_number "$TELEMT_SYNLIMIT_HASHLIMIT_SIZE" || die "Bad TELEMT_SYNLIMIT_HASHLIMIT_SIZE."
  if [[ -n "$AD_TAG" ]] && ! [[ "$AD_TAG" =~ ^[A-Fa-f0-9]{32}$ ]]; then
    die "ad_tag must be 32 hex chars."
  fi
  USE_MIDDLE_PROXY="$(normalize_yes_no "$USE_MIDDLE_PROXY")" || die "Bad middle proxy value."

  collect_domains

  for i in "${!DOMAINS[@]}"; do
    choose_auth_mode "${DOMAINS[$i]}" "${IPS[$i]}"
  done

  show_plan
  confirm "Start batch installation? [y/N]: " || die "Cancelled."

  for i in "${!DOMAINS[@]}"; do
    install_one "$i" || true
  done

  echo
  echo "Batch results:"
  printf '  %s\n' "${RESULTS[@]}"

  echo
  echo "Proxy links:"
  if [[ "${#PROXY_LINKS[@]}" -gt 0 ]]; then
    printf '  %s\n' "${PROXY_LINKS[@]}"
  else
    echo "  none"
  fi
}

main "$@"
