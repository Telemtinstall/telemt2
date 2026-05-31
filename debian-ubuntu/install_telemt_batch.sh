#!/usr/bin/env bash
set -Eeuo pipefail

# Batch orchestrator for install_telemt.sh.
# Run this script on your local admin machine. It collects proxy domains,
# resolves A records, checks SSH access, optionally calls add_key.sh,
# then copies and runs install_telemt.sh on each target server.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

INSTALLER_FILE="${INSTALLER_FILE:-$SCRIPT_DIR/install_telemt.sh}"
INSTALLER_README_FILE="${INSTALLER_README_FILE:-$SCRIPT_DIR/README.md}"
ADD_KEY_FILE="${ADD_KEY_FILE:-$SCRIPT_DIR/../common/add_key.sh}"
REMOTE_INSTALLER_NAME="${REMOTE_INSTALLER_NAME:-$(basename "$INSTALLER_FILE")}"

SSH_USER="${SSH_USER:-root}"
CONNECT_SSH_PORT="${CONNECT_SSH_PORT:-22}"
TARGET_SSH_PORT="${TARGET_SSH_PORT:-22}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-no}"
ADD_SWAP="${ADD_SWAP:-no}"
TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-1000}"
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

prompt_yes_no() {
  local var="$1"
  local label="$2"
  local default_value="${3:-no}"
  local value=""

  prompt_default "$var" "$label" "$default_value"
  value="$(printf '%s' "${!var}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    y|yes) printf -v "$var" '%s' "yes" ;;
    n|no|"") printf -v "$var" '%s' "no" ;;
    *) die "$label must be yes or no." ;;
  esac
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
      die "Unsupported local OS: $os_name. Run batch from macOS or Debian/Ubuntu/Linux."
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
  echo "Note: install_telemt_batch.sh is a local orchestrator. It will not install Telemt on this machine."
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
By default, the main installer keeps SSH password login enabled. If you
explicitly enable SSH_KEY_ONLY_LOGIN=yes, make sure root key login works first.

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
  remote_cmd+="ENABLE_FAIL2BAN=$(shell_quote "$ENABLE_FAIL2BAN") "
  remote_cmd+="ADD_SWAP=$(shell_quote "$ADD_SWAP") "
  remote_cmd+="TELEMT_MAX_TCP_CONNS=$(shell_quote "$TELEMT_MAX_TCP_CONNS") "
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

  # Read the link generated by install_telemt.sh. Fall back to the local API
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
  echo "  fail2ban SSH:        $ENABLE_FAIL2BAN"
  echo "  add swap:            $ADD_SWAP"
  echo "  Telemt limit:        $TELEMT_MAX_TCP_CONNS"
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
Telemt batch installer.

This script runs locally and installs Telemt on multiple target servers by
copying and executing install_telemt.sh on each server.

EOF

  prompt_default SSH_USER "SSH user for installation" "$SSH_USER"
  if [[ "$SSH_USER" != "root" ]]; then
    die "install_telemt.sh must run as root. Use SSH_USER=root."
  fi
  prompt_default CONNECT_SSH_PORT "Current SSH port for connecting to servers" "$CONNECT_SSH_PORT"
  prompt_default TARGET_SSH_PORT "SSH port to configure on installed servers" "$TARGET_SSH_PORT"
  prompt_yes_no ENABLE_FAIL2BAN "Enable fail2ban for SSH? yes/no" "$ENABLE_FAIL2BAN"
  prompt_yes_no ADD_SWAP "Add 1G swap if missing? yes/no" "$ADD_SWAP"
  prompt_default TELEMT_MAX_TCP_CONNS "Telemt max TCP connections" "$TELEMT_MAX_TCP_CONNS"
  prompt_default LETSENCRYPT_EMAIL "Common Let's Encrypt email, empty = admin@domain" "$LETSENCRYPT_EMAIL"

  valid_port "$CONNECT_SSH_PORT" || die "Current SSH port must be a number from 1 to 65535."
  valid_port "$TARGET_SSH_PORT" || die "Target SSH port must be a number from 1 to 65535."
  valid_limit "$TELEMT_MAX_TCP_CONNS" || die "Telemt limit must be a number from 1 to 1000000."

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
