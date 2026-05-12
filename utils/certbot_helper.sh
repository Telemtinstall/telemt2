#!/usr/bin/env bash
set -Eeuo pipefail

DOMAINS=()
EMAIL=""
AUTO_RENEW="yes"
METHOD=""
WEBROOT=""
STAGING="no"
INSTALL_PACKAGES="yes"
RELOAD_SERVICE="nginx"
STOP_SERVICE=""
SKIP_DNS_CHECK="no"
ASSUME_YES="no"
CERT_NAME=""

usage() {
  cat <<'EOF'
certbot_helper.sh - helper for issuing Let's Encrypt certificates.

Usage:
  ./certbot_helper.sh -d example.com -d www.example.com
  ./certbot_helper.sh --domain example.com --email admin@example.com --webroot -w /var/www/html

Options:
  -d, --domain DOMAIN       Add domain, same style as certbot. Can be repeated.
  -m, --email EMAIL        Let's Encrypt account email. Default: admin@<first-domain>.
      --standalone         Use certbot standalone HTTP-01 challenge.
      --webroot            Use certbot webroot HTTP-01 challenge.
  -w, --webroot-path PATH  Webroot path for --webroot. Default: /var/www/html.
      --auto-renew yes|no  Enable certbot.timer and deploy hook. Default: yes.
      --no-auto-renew      Do not enable certbot.timer.
      --reload-service SVC Reload this systemd service after renewal. Default: nginx.
      --no-reload-service  Do not install a renewal reload hook.
      --stop-service SVC   Stop this service during standalone issuance, then start it.
      --staging            Use Let's Encrypt staging endpoint for tests.
      --skip-dns-check     Do not compare domain A records with server public IPv4.
      --no-install-packages Do not install certbot if it is missing.
      --cert-name NAME     Certbot certificate name. Default: first domain.
  -y, --yes                Non-interactive confirmations, but DNS mismatches still fail
                           unless --skip-dns-check is set.
  -h, --help               Show this help.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

is_interactive() {
  [[ -t 0 ]]
}

normalize_yes_no() {
  local value
  value="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    y|yes|true|1|on) echo "yes" ;;
    n|no|false|0|off) echo "no" ;;
    *) return 1 ;;
  esac
}

ask() {
  local prompt="$1"
  local default_value="${2:-}"
  local reply=""
  if [[ -n "$default_value" ]]; then
    read -r -p "$prompt [$default_value]: " reply
    printf '%s\n' "${reply:-$default_value}"
  else
    read -r -p "$prompt: " reply
    printf '%s\n' "$reply"
  fi
}

ask_yes_no() {
  local prompt="$1"
  local default_value="$2"
  local reply normalized
  default_value="$(normalize_yes_no "$default_value")" || die "Bad default yes/no value: $default_value"
  while true; do
    reply="$(ask "$prompt" "$default_value")"
    if normalized="$(normalize_yes_no "$reply")"; then
      printf '%s\n' "$normalized"
      return 0
    fi
    echo "Please answer yes or no."
  done
}

validate_domain() {
  local domain="$1"
  [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]]
}

validate_email() {
  local email="$1"
  [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]
}

validate_service_name() {
  local service="$1"
  [[ -z "$service" || "$service" =~ ^[A-Za-z0-9_.@-]+$ ]]
}

validate_cert_name() {
  local cert_name="$1"
  [[ "$cert_name" =~ ^[A-Za-z0-9_.-]+$ ]]
}

normalize_service_name() {
  local service="$1"
  service="${service%.service}"
  printf '%s\n' "$service"
}

add_domain() {
  local raw="$1"
  local domain
  IFS=',' read -r -a parts <<< "$raw"
  for domain in "${parts[@]}"; do
    domain="${domain#"${domain%%[![:space:]]*}"}"
    domain="${domain%"${domain##*[![:space:]]}"}"
    [[ -z "$domain" ]] && continue
    validate_domain "$domain" || die "Invalid domain: $domain"
    DOMAINS+=("$(printf '%s' "$domain" | tr '[:upper:]' '[:lower:]')")
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -d|--domain|--domains)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        add_domain "$2"
        shift 2
        ;;
      -m|--email)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        EMAIL="$2"
        shift 2
        ;;
      --standalone)
        METHOD="standalone"
        shift
        ;;
      --webroot)
        METHOD="webroot"
        shift
        ;;
      -w|--webroot-path)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        WEBROOT="$2"
        METHOD="webroot"
        shift 2
        ;;
      --auto-renew)
        [[ $# -ge 2 ]] || die "$1 requires yes or no"
        AUTO_RENEW="$(normalize_yes_no "$2")" || die "--auto-renew must be yes or no"
        shift 2
        ;;
      --no-auto-renew)
        AUTO_RENEW="no"
        shift
        ;;
      --reload-service)
        [[ $# -ge 2 ]] || die "$1 requires a service name"
        RELOAD_SERVICE="$2"
        shift 2
        ;;
      --no-reload-service)
        RELOAD_SERVICE=""
        shift
        ;;
      --stop-service)
        [[ $# -ge 2 ]] || die "$1 requires a service name"
        STOP_SERVICE="$2"
        shift 2
        ;;
      --staging|--test-cert)
        STAGING="yes"
        shift
        ;;
      --skip-dns-check)
        SKIP_DNS_CHECK="yes"
        shift
        ;;
      --install-packages)
        INSTALL_PACKAGES="yes"
        shift
        ;;
      --no-install-packages)
        INSTALL_PACKAGES="no"
        shift
        ;;
      --cert-name)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        CERT_NAME="$2"
        shift 2
        ;;
      -y|--yes)
        ASSUME_YES="yes"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
  done
}

prompt_missing_values() {
  if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
    is_interactive || die "No domains provided. Use -d example.com."
    local domain index=1
    while true; do
      if [[ "$index" -eq 1 ]]; then
        domain="$(ask "Domain $index" "")"
      else
        domain="$(ask "Domain $index, Enter to finish" "")"
      fi
      if [[ -z "$domain" ]]; then
        [[ "${#DOMAINS[@]}" -gt 0 ]] && break
        echo "At least one domain is required."
        continue
      fi
      add_domain "$domain"
      index=$((index + 1))
    done
  fi

  if [[ -z "$EMAIL" ]]; then
    if is_interactive; then
      EMAIL="$(ask "Let's Encrypt email" "admin@${DOMAINS[0]}")"
    else
      EMAIL="admin@${DOMAINS[0]}"
    fi
  fi

  if [[ -z "$METHOD" ]]; then
    if is_interactive; then
      while true; do
        METHOD="$(ask "ACME challenge method: standalone or webroot" "standalone")"
        METHOD="$(printf '%s' "$METHOD" | tr '[:upper:]' '[:lower:]')"
        [[ "$METHOD" == "standalone" || "$METHOD" == "webroot" ]] && break
        echo "Please enter standalone or webroot."
      done
    else
      METHOD="standalone"
    fi
  fi

  if [[ "$METHOD" == "webroot" && -z "$WEBROOT" ]]; then
    if is_interactive; then
      WEBROOT="$(ask "Webroot path" "/var/www/html")"
    else
      WEBROOT="/var/www/html"
    fi
  fi

  if is_interactive && [[ "$STAGING" != "yes" ]]; then
    STAGING="$(ask_yes_no "Use Let's Encrypt staging/test certificate" "no")"
  fi

  if is_interactive && [[ "$AUTO_RENEW" == "yes" ]]; then
    AUTO_RENEW="$(ask_yes_no "Enable certificate auto-renewal" "yes")"
  fi

  if [[ "$AUTO_RENEW" == "yes" && is_interactive ]]; then
    RELOAD_SERVICE="$(ask "Reload systemd service after renewal, empty means none" "${RELOAD_SERVICE:-nginx}")"
  fi

  CERT_NAME="${CERT_NAME:-${DOMAINS[0]}}"
  RELOAD_SERVICE="$(normalize_service_name "$RELOAD_SERVICE")"
  STOP_SERVICE="$(normalize_service_name "$STOP_SERVICE")"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."
}

install_certbot_if_needed() {
  command -v certbot >/dev/null 2>&1 && return 0
  [[ "$INSTALL_PACKAGES" == "yes" ]] || die "certbot is missing and package installation is disabled."

  echo "[01] Install certbot"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y certbot
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y certbot
  elif command -v yum >/dev/null 2>&1; then
    yum install -y certbot
  else
    die "Cannot install certbot automatically: unsupported package manager."
  fi
}

get_public_ipv4() {
  local ip=""
  if command -v curl >/dev/null 2>&1; then
    ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    [[ -n "$ip" ]] || ip="$(curl -4fsS --max-time 8 https://ifconfig.me/ip 2>/dev/null || true)"
  fi
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    printf '%s\n' "$ip"
  fi
}

resolve_domain_ipv4() {
  local domain="$1"
  if command -v getent >/dev/null 2>&1; then
    getent ahostsv4 "$domain" | awk '{print $1}' | sort -u
  elif command -v host >/dev/null 2>&1; then
    host -t A "$domain" | awk '/ has address / {print $4}' | sort -u
  elif command -v dig >/dev/null 2>&1; then
    dig +short A "$domain" | awk '/^[0-9.]+$/ {print}' | sort -u
  else
    return 1
  fi
}

dns_preflight() {
  [[ "$SKIP_DNS_CHECK" == "yes" ]] && return 0

  echo "[02] DNS preflight"
  local public_ip domain ips mismatch="no"
  public_ip="$(get_public_ipv4 || true)"
  if [[ -z "$public_ip" ]]; then
    warn "Cannot detect server public IPv4. DNS comparison skipped."
    return 0
  fi
  echo "server_public_ipv4=$public_ip"

  for domain in "${DOMAINS[@]}"; do
    if ! ips="$(resolve_domain_ipv4 "$domain" | xargs 2>/dev/null || true)"; then
      warn "Cannot resolve A record for $domain."
      mismatch="yes"
      continue
    fi
    echo "$domain A=${ips:-none}"
    if [[ -z "$ips" ]]; then
      mismatch="yes"
    elif ! grep -qw "$public_ip" <<< "$ips"; then
      mismatch="yes"
    fi
  done

  if [[ "$mismatch" == "yes" ]]; then
    warn "At least one domain A record is missing or does not point to this server IPv4."
    if is_interactive; then
      local continue_anyway
      continue_anyway="$(ask_yes_no "Continue anyway" "no")"
      [[ "$continue_anyway" == "yes" ]] || die "Stopped because DNS preflight failed."
    else
      die "DNS preflight failed. Fix DNS or use --skip-dns-check."
    fi
  fi
}

port_80_busy() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltn '( sport = :80 )' | awk 'NR > 1 {found=1} END {exit found ? 0 : 1}'
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:80 -sTCP:LISTEN >/dev/null 2>&1
  else
    return 1
  fi
}

show_port_80() {
  if command -v ss >/dev/null 2>&1; then
    ss -ltnp '( sport = :80 )' || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -iTCP:80 -sTCP:LISTEN || true
  fi
}

STOPPED_SERVICE=""

restart_stopped_service() {
  [[ -n "$STOPPED_SERVICE" ]] || return 0
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start "$STOPPED_SERVICE" || true
  fi
}

standalone_preflight() {
  [[ "$METHOD" == "standalone" ]] || return 0
  echo "[03] Port 80 preflight"
  if ! port_80_busy; then
    echo "port_80=free"
    return 0
  fi

  warn "Port 80 is already in use. certbot standalone needs it for HTTP-01."
  show_port_80

  if [[ -z "$STOP_SERVICE" && is_interactive ]]; then
    STOP_SERVICE="$(ask "Service to stop temporarily, empty to abort" "nginx")"
  fi
  [[ -n "$STOP_SERVICE" ]] || die "Port 80 is busy. Use --webroot or --stop-service SERVICE."
  validate_service_name "$STOP_SERVICE" || die "Unsafe service name: $STOP_SERVICE"
  command -v systemctl >/dev/null 2>&1 || die "Cannot stop service without systemctl."
  systemctl stop "$STOP_SERVICE"
  STOPPED_SERVICE="$STOP_SERVICE"
  trap restart_stopped_service EXIT

  if port_80_busy; then
    show_port_80
    die "Port 80 is still busy after stopping $STOP_SERVICE."
  fi
}

prepare_webroot() {
  [[ "$METHOD" == "webroot" ]] || return 0
  [[ -n "$WEBROOT" ]] || die "Webroot path is empty."
  install -d -m 0755 "$WEBROOT/.well-known/acme-challenge"
}

install_renew_hook() {
  [[ "$AUTO_RENEW" == "yes" ]] || return 0
  [[ -n "$RELOAD_SERVICE" ]] || return 0
  validate_service_name "$RELOAD_SERVICE" || die "Unsafe reload service name: $RELOAD_SERVICE"

  echo "[04] Configure renewal hook"
  local hook="/etc/letsencrypt/renewal-hooks/deploy/reload-${RELOAD_SERVICE}.sh"
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > "$hook" <<EOF
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files '${RELOAD_SERVICE}.service' >/dev/null 2>&1; then
  systemctl reload '${RELOAD_SERVICE}' || systemctl restart '${RELOAD_SERVICE}'
fi
EOF
  chown root:root "$hook"
  chmod 0755 "$hook"
  echo "renewal_hook=$hook"
}

enable_auto_renewal() {
  [[ "$AUTO_RENEW" == "yes" ]] || {
    echo "auto_renew=not_enabled_by_request"
    echo "note=existing certbot.timer is not disabled because it may be used by other certificates"
    return 0
  }

  echo "[05] Enable certbot auto-renewal"
  if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer
    echo "certbot_timer=$(systemctl is-active certbot.timer 2>/dev/null || true)"
  else
    warn "certbot.timer not found. This system may use cron or another renewal mechanism."
  fi
}

issue_certificate() {
  echo "[06] Issue certificate"
  local cmd=(certbot certonly --non-interactive --agree-tos --email "$EMAIL" --cert-name "$CERT_NAME" --keep-until-expiring --expand)
  local domain
  for domain in "${DOMAINS[@]}"; do
    cmd+=(-d "$domain")
  done
  if [[ "$STAGING" == "yes" ]]; then
    cmd+=(--staging)
  fi
  if [[ "$METHOD" == "standalone" ]]; then
    cmd+=(--standalone --preferred-challenges http)
  else
    cmd+=(--webroot -w "$WEBROOT")
  fi

  printf 'certbot_command='
  printf '%q ' "${cmd[@]}"
  printf '\n'
  "${cmd[@]}"
}

print_summary() {
  echo "[07] Result"
  echo "cert_name=$CERT_NAME"
  echo "domains=${DOMAINS[*]}"
  echo "email=$EMAIL"
  echo "method=$METHOD"
  echo "auto_renew=$AUTO_RENEW"
  echo "fullchain=/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
  echo "privkey=/etc/letsencrypt/live/$CERT_NAME/privkey.pem"
  certbot certificates --cert-name "$CERT_NAME" || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-timers certbot.timer --no-pager 2>/dev/null || true
  fi
}

main() {
  parse_args "$@"
  prompt_missing_values

  [[ "${#DOMAINS[@]}" -gt 0 ]] || die "At least one domain is required."
  validate_email "$EMAIL" || die "Invalid email: $EMAIL"
  [[ "$METHOD" == "standalone" || "$METHOD" == "webroot" ]] || die "Bad method: $METHOD"
  validate_service_name "$RELOAD_SERVICE" || die "Unsafe reload service name: $RELOAD_SERVICE"
  validate_service_name "$STOP_SERVICE" || die "Unsafe stop service name: $STOP_SERVICE"
  validate_cert_name "$CERT_NAME" || die "Unsafe certificate name: $CERT_NAME"

  echo "Plan:"
  echo "  domains:       ${DOMAINS[*]}"
  echo "  cert name:     $CERT_NAME"
  echo "  email:         $EMAIL"
  echo "  method:        $METHOD"
  [[ "$METHOD" == "webroot" ]] && echo "  webroot:       $WEBROOT"
  echo "  staging:       $STAGING"
  echo "  auto-renew:    $AUTO_RENEW"
  if [[ "$AUTO_RENEW" == "yes" ]]; then
    echo "  reload service:${RELOAD_SERVICE:+ $RELOAD_SERVICE}"
  else
    echo "  reload service: not used"
  fi
  echo

  if is_interactive && [[ "$ASSUME_YES" != "yes" ]]; then
    local confirm
    confirm="$(ask_yes_no "Continue" "yes")"
    [[ "$confirm" == "yes" ]] || die "Cancelled."
  fi

  require_root
  install_certbot_if_needed
  dns_preflight
  standalone_preflight
  prepare_webroot
  install_renew_hook
  enable_auto_renewal
  issue_certificate
  print_summary
}

main "$@"
