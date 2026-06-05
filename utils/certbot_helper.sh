#!/usr/bin/env bash
set -Eeuo pipefail

DOMAINS=()
EMAIL=""
METHOD=""
WEBROOT=""
AUTO_RENEW="yes"
REDIRECT="yes"
STAGING="no"
INSTALL_PACKAGES="yes"
RELOAD_SERVICE=""
RELOAD_SERVICE_DISABLED="no"
STOP_SERVICE=""
SKIP_DNS_CHECK="no"
NO_PROMPT="no"
ASSUME_YES="no"
CERT_NAME=""
CERTBOT_COMMAND="certonly"
CERTBOT_EXTRA_ARGS=()
DETECTED_SERVER="none"

usage() {
  cat <<'EOF'
certbot_helper.sh - certbot-style helper for Let's Encrypt certificates.

Usage:
  ./certbot_helper.sh certonly -d example.com -d www.example.com
  ./certbot_helper.sh -d example.com --nginx --redirect -m admin@example.com
  ./certbot_helper.sh -d example.com --webroot -w /var/www/html --non-interactive

Certbot-compatible options handled by this helper:
  certonly                  Issue/renew certificate without relying on certbot install mode.
  -d, --domain DOMAIN       Add domain. Can be repeated. Comma-separated values are accepted.
  -m, --email EMAIL         Let's Encrypt account email. Default: admin@<first-domain>.
      --nginx               Use certbot nginx authenticator when available.
      --apache              Use certbot apache authenticator when available.
      --standalone          Use certbot standalone HTTP-01 challenge.
      --webroot             Use certbot webroot HTTP-01 challenge.
  -w, --webroot-path PATH   Webroot path for --webroot. Default: /var/www/html.
      --redirect            Configure HTTP -> HTTPS redirect after certificate issue. Default.
      --no-redirect         Do not configure HTTP -> HTTPS redirect.
      --agree-tos           Accepted for certbot compatibility.
  -n, --non-interactive     Ask nothing. Missing required values fail or use documented defaults.

Helper-specific options:
      --no-prompt           Same as --non-interactive.
      --auto-renew yes|no   Enable certbot.timer and deploy hook. Default: yes.
      --no-auto-renew       Do not enable certbot.timer.
      --reload-service SVC  Reload this systemd service after renewal. Default: detected web server.
      --no-reload-service   Do not install a renewal reload hook.
      --stop-service SVC    Stop this service during standalone issuance, then start it.
      --staging             Use Let's Encrypt staging endpoint for tests.
      --skip-dns-check      Do not compare domain A records with server public IPv4.
      --no-install-packages Do not install missing certbot/plugin packages.
      --cert-name NAME      Certbot certificate name. Default: first domain.
  -y, --yes                 Auto-confirm the final plan but still ask for missing values.
  -h, --help                Show this help.

Unknown certbot options are passed through to certbot.
EOF
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

warn() {
  echo "WARN: $*" >&2
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

trim() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s\n' "$value"
}

is_interactive() {
  [[ "$NO_PROMPT" != "yes" && -t 0 ]]
}

normalize_yes_no() {
  local value
  value="$(lower "$1")"
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

safe_name() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_.-' '_'
}

add_domain() {
  local raw="$1"
  local domain part
  IFS=',' read -r -a parts <<< "$raw"
  for part in "${parts[@]}"; do
    domain="$(trim "$part")"
    [[ -z "$domain" ]] && continue
    validate_domain "$domain" || die "Invalid domain: $domain"
    DOMAINS+=("$(lower "$domain")")
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      certonly|run)
        CERTBOT_COMMAND="$1"
        shift
        ;;
      -d|--domain|--domains)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        add_domain "$2"
        shift 2
        ;;
      --domain=*)
        add_domain "${1#*=}"
        shift
        ;;
      -m|--email)
        [[ $# -ge 2 ]] || die "$1 requires a value"
        EMAIL="$2"
        shift 2
        ;;
      --email=*)
        EMAIL="${1#*=}"
        shift
        ;;
      --nginx)
        METHOD="nginx"
        shift
        ;;
      --apache)
        METHOD="apache"
        shift
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
      --webroot-path=*)
        WEBROOT="${1#*=}"
        METHOD="webroot"
        shift
        ;;
      --redirect)
        REDIRECT="yes"
        shift
        ;;
      --no-redirect)
        REDIRECT="no"
        shift
        ;;
      --agree-tos)
        shift
        ;;
      -n|--non-interactive|--no-prompt)
        NO_PROMPT="yes"
        ASSUME_YES="yes"
        shift
        ;;
      --auto-renew)
        [[ $# -ge 2 ]] || die "$1 requires yes or no"
        AUTO_RENEW="$(normalize_yes_no "$2")" || die "--auto-renew must be yes or no"
        shift 2
        ;;
      --auto-renew=*)
        AUTO_RENEW="$(normalize_yes_no "${1#*=}")" || die "--auto-renew must be yes or no"
        shift
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
      --reload-service=*)
        RELOAD_SERVICE="${1#*=}"
        shift
        ;;
      --no-reload-service)
        RELOAD_SERVICE=""
        RELOAD_SERVICE_DISABLED="yes"
        shift
        ;;
      --stop-service)
        [[ $# -ge 2 ]] || die "$1 requires a service name"
        STOP_SERVICE="$2"
        shift 2
        ;;
      --stop-service=*)
        STOP_SERVICE="${1#*=}"
        shift
        ;;
      --staging|--test-cert)
        STAGING="yes"
        shift
        ;;
      --dry-run)
        STAGING="yes"
        CERTBOT_EXTRA_ARGS+=("--dry-run")
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
      --cert-name=*)
        CERT_NAME="${1#*=}"
        shift
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
        CERTBOT_EXTRA_ARGS+=("$1")
        if [[ $# -ge 2 && -n "${2:-}" && "${2:0:1}" != "-" ]]; then
          CERTBOT_EXTRA_ARGS+=("$2")
          shift 2
        else
          shift
        fi
        ;;
    esac
  done
}

systemd_unit_exists() {
  local unit="$1"
  command -v systemctl >/dev/null 2>&1 || return 1
  systemctl list-unit-files "$unit" >/dev/null 2>&1
}

service_active_or_exists() {
  local service="$1"
  if systemd_unit_exists "${service}.service"; then
    return 0
  fi
  command -v "$service" >/dev/null 2>&1
}

detect_web_server() {
  if service_active_or_exists nginx || service_active_or_exists openresty; then
    echo "nginx"
  elif service_active_or_exists apache2; then
    echo "apache2"
  elif service_active_or_exists httpd; then
    echo "httpd"
  elif service_active_or_exists caddy; then
    echo "caddy"
  else
    echo "none"
  fi
}

default_reload_service() {
  case "$DETECTED_SERVER" in
    nginx) echo "nginx" ;;
    apache2) echo "apache2" ;;
    httpd) echo "httpd" ;;
    caddy) echo "caddy" ;;
    *) echo "" ;;
  esac
}

default_method() {
  case "$DETECTED_SERVER" in
    nginx) echo "nginx" ;;
    apache2|httpd) echo "apache" ;;
    *) echo "standalone" ;;
  esac
}

prompt_missing_values() {
  DETECTED_SERVER="$(detect_web_server)"

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
    local suggested
    suggested="$(default_method)"
    if is_interactive; then
      echo "Detected web server: $DETECTED_SERVER"
      while true; do
        METHOD="$(ask "ACME method: nginx, apache, standalone or webroot" "$suggested")"
        METHOD="$(lower "$METHOD")"
        [[ "$METHOD" == "nginx" || "$METHOD" == "apache" || "$METHOD" == "standalone" || "$METHOD" == "webroot" ]] && break
        echo "Please enter nginx, apache, standalone or webroot."
      done
    else
      METHOD="$suggested"
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

  if is_interactive; then
    REDIRECT="$(ask_yes_no "Configure HTTP to HTTPS redirect after certificate issue" "$REDIRECT")"
    AUTO_RENEW="$(ask_yes_no "Enable certificate auto-renewal" "$AUTO_RENEW")"
  fi

  if [[ -z "$RELOAD_SERVICE" && "$AUTO_RENEW" == "yes" && "$RELOAD_SERVICE_DISABLED" != "yes" ]]; then
    RELOAD_SERVICE="$(default_reload_service)"
  fi
  if [[ "$AUTO_RENEW" == "yes" && "$RELOAD_SERVICE_DISABLED" != "yes" && is_interactive ]]; then
    RELOAD_SERVICE="$(ask "Reload systemd service after renewal, empty means none" "$RELOAD_SERVICE")"
  fi

  CERT_NAME="${CERT_NAME:-${DOMAINS[0]}}"
  RELOAD_SERVICE="$(normalize_service_name "$RELOAD_SERVICE")"
  STOP_SERVICE="$(normalize_service_name "$STOP_SERVICE")"
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Run as root."
}

package_manager() {
  if command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  else
    echo "unknown"
  fi
}

install_certbot_if_needed() {
  local pm packages=(certbot)
  case "$METHOD" in
    nginx) packages+=(python3-certbot-nginx) ;;
    apache) packages+=(python3-certbot-apache) ;;
  esac

  local missing=()
  command -v certbot >/dev/null 2>&1 || missing+=("certbot")
  if [[ "$METHOD" == "nginx" ]] && ! certbot plugins 2>/dev/null | grep -q "nginx"; then
    missing+=("python3-certbot-nginx")
  fi
  if [[ "$METHOD" == "apache" ]] && ! certbot plugins 2>/dev/null | grep -q "apache"; then
    missing+=("python3-certbot-apache")
  fi
  [[ "${#missing[@]}" -eq 0 ]] && return 0

  [[ "$INSTALL_PACKAGES" == "yes" ]] || die "Missing packages/tools: ${missing[*]}"

  echo "[01] Install certbot packages"
  pm="$(package_manager)"
  case "$pm" in
    apt)
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
      ;;
    dnf)
      dnf install -y "${packages[@]}"
      ;;
    yum)
      yum install -y "${packages[@]}"
      ;;
    *)
      die "Cannot install certbot automatically: unsupported package manager."
      ;;
  esac
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
    ips="$(resolve_domain_ipv4 "$domain" | xargs 2>/dev/null || true)"
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
    STOP_SERVICE="$(ask "Service to stop temporarily, empty to abort" "$DETECTED_SERVER")"
  fi
  [[ -n "$STOP_SERVICE" && "$STOP_SERVICE" != "none" ]] || die "Port 80 is busy. Use --webroot, --nginx, --apache, or --stop-service SERVICE."
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
  local cmd=(certbot "$CERTBOT_COMMAND" --non-interactive --agree-tos --no-eff-email --email "$EMAIL" --cert-name "$CERT_NAME" --keep-until-expiring --expand)
  local domain
  for domain in "${DOMAINS[@]}"; do
    cmd+=(-d "$domain")
  done
  [[ "$STAGING" == "yes" ]] && cmd+=(--staging)

  case "$METHOD" in
    nginx) cmd+=(--nginx) ;;
    apache) cmd+=(--apache) ;;
    standalone) cmd+=(--standalone --preferred-challenges http) ;;
    webroot) cmd+=(--webroot -w "$WEBROOT") ;;
    *) die "Unsupported method: $METHOD" ;;
  esac

  cmd+=("${CERTBOT_EXTRA_ARGS[@]}")

  printf 'certbot_command='
  printf '%q ' "${cmd[@]}"
  printf '\n'
  "${cmd[@]}"
}

nginx_available() {
  command -v nginx >/dev/null 2>&1 || systemd_unit_exists nginx.service
}

apache_service_name() {
  if service_active_or_exists apache2; then
    echo "apache2"
  elif service_active_or_exists httpd; then
    echo "httpd"
  else
    echo ""
  fi
}

configure_nginx_redirect() {
  nginx_available || return 1
  local name conf webroot domains_line
  name="$(safe_name "$CERT_NAME")"
  conf="/etc/nginx/conf.d/certbot-helper-redirect-${name}.conf"
  webroot="${WEBROOT:-/var/www/html}"
  domains_line="${DOMAINS[*]}"
  install -d -m 0755 /etc/nginx/conf.d
  install -d -m 0755 "$webroot/.well-known/acme-challenge"

  cat > "$conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${domains_line};

    location ^~ /.well-known/acme-challenge/ {
        root ${webroot};
        default_type "text/plain";
        try_files \$uri =404;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
EOF

  nginx -t
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload nginx || systemctl restart nginx
  fi
  echo "redirect=nginx:$conf"
}

configure_apache_redirect() {
  local service conf name webroot server_alias
  service="$(apache_service_name)"
  [[ -n "$service" ]] || return 1
  name="$(safe_name "$CERT_NAME")"
  webroot="${WEBROOT:-/var/www/html}"
  install -d -m 0755 "$webroot/.well-known/acme-challenge"

  if [[ "$service" == "apache2" ]]; then
    conf="/etc/apache2/sites-available/certbot-helper-redirect-${name}.conf"
  else
    conf="/etc/httpd/conf.d/certbot-helper-redirect-${name}.conf"
  fi
  install -d -m 0755 "$(dirname "$conf")"

  server_alias=""
  if [[ "${#DOMAINS[@]}" -gt 1 ]]; then
    server_alias="    ServerAlias ${DOMAINS[*]:1}"
  fi

  cat > "$conf" <<EOF
<VirtualHost *:80>
    ServerName ${DOMAINS[0]}
${server_alias}
    DocumentRoot ${webroot}

    Alias /.well-known/acme-challenge/ ${webroot}/.well-known/acme-challenge/
    <Directory "${webroot}/.well-known/acme-challenge/">
        Require all granted
    </Directory>

    RewriteEngine On
    RewriteCond %{REQUEST_URI} !^/\\.well-known/acme-challenge/
    RewriteRule ^ https://%{HTTP_HOST}%{REQUEST_URI} [R=301,L]
</VirtualHost>
EOF

  if [[ "$service" == "apache2" ]]; then
    a2enmod rewrite >/dev/null 2>&1 || true
    a2ensite "certbot-helper-redirect-${name}.conf" >/dev/null 2>&1 || true
    apache2ctl configtest
  else
    httpd -t
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload "$service" || systemctl restart "$service"
  fi
  echo "redirect=apache:$conf"
}

configure_redirect() {
  [[ "$REDIRECT" == "yes" ]] || {
    echo "redirect=not_enabled_by_request"
    return 0
  }

  echo "[07] Configure HTTP to HTTPS redirect"
  if [[ "$METHOD" == "nginx" || "$DETECTED_SERVER" == "nginx" ]]; then
    configure_nginx_redirect && return 0
  fi
  if [[ "$METHOD" == "apache" || "$DETECTED_SERVER" == "apache2" || "$DETECTED_SERVER" == "httpd" ]]; then
    configure_apache_redirect && return 0
  fi
  warn "No supported web server detected for automatic redirect. Supported: nginx, apache2/httpd."
  echo "redirect=not_configured"
}

print_summary() {
  echo "[08] Result"
  echo "cert_name=$CERT_NAME"
  echo "domains=${DOMAINS[*]}"
  echo "email=$EMAIL"
  echo "method=$METHOD"
  echo "detected_web_server=$DETECTED_SERVER"
  echo "auto_renew=$AUTO_RENEW"
  echo "redirect=$REDIRECT"
  echo "fullchain=/etc/letsencrypt/live/$CERT_NAME/fullchain.pem"
  echo "privkey=/etc/letsencrypt/live/$CERT_NAME/privkey.pem"
  certbot certificates --cert-name "$CERT_NAME" || true
  if command -v systemctl >/dev/null 2>&1; then
    systemctl list-timers certbot.timer --no-pager 2>/dev/null || true
  fi
}

validate_all() {
  [[ "${#DOMAINS[@]}" -gt 0 ]] || die "At least one domain is required."
  validate_email "$EMAIL" || die "Invalid email: $EMAIL"
  [[ "$METHOD" == "nginx" || "$METHOD" == "apache" || "$METHOD" == "standalone" || "$METHOD" == "webroot" ]] || die "Bad method: $METHOD"
  validate_service_name "$RELOAD_SERVICE" || die "Unsafe reload service name: $RELOAD_SERVICE"
  validate_service_name "$STOP_SERVICE" || die "Unsafe stop service name: $STOP_SERVICE"
  validate_cert_name "$CERT_NAME" || die "Unsafe certificate name: $CERT_NAME"
}

print_plan() {
  echo "Plan:"
  echo "  domains:             ${DOMAINS[*]}"
  echo "  cert name:           $CERT_NAME"
  echo "  email:               $EMAIL"
  echo "  detected web server: $DETECTED_SERVER"
  echo "  method:              $METHOD"
  [[ "$METHOD" == "webroot" ]] && echo "  webroot:             $WEBROOT"
  echo "  staging:             $STAGING"
  echo "  redirect:            $REDIRECT"
  echo "  auto-renew:          $AUTO_RENEW"
  if [[ "$AUTO_RENEW" == "yes" ]]; then
    echo "  reload service:      ${RELOAD_SERVICE:-none}"
  else
    echo "  reload service:      not used"
  fi
  echo "  certbot extra args:  ${CERTBOT_EXTRA_ARGS[*]:-none}"
  echo
}

main() {
  parse_args "$@"
  prompt_missing_values
  validate_all
  print_plan

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
  configure_redirect
  print_summary
}

main "$@"
