#!/usr/bin/env bash
set -Eeuo pipefail

# Telemt installer for a fresh Astra Linux server.
# It asks for a domain, verifies DNS A -> this server IPv4 before Let's Encrypt,
# then installs nginx SNI routing + Telemt + local API firewall.
# SSH key-only login, fail2ban, and swap are opt-in prompts.

TELEMT_IMAGE_DEFAULT="ghcr.io/telemt/telemt:latest"
TELEMT_IMAGE_FROM_ENV="${TELEMT_IMAGE:+1}"

PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
SSH_PORT="${SSH_PORT:-22}"
SSH_KEY_ONLY_LOGIN="${SSH_KEY_ONLY_LOGIN:-no}"
SSH_KEY_ONLY_CONFIRM="${SSH_KEY_ONLY_CONFIRM:-no}"
ENABLE_FAIL2BAN="${ENABLE_FAIL2BAN:-no}"
ADD_SWAP="${ADD_SWAP:-no}"
TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-5000}"
TELEMT_IMAGE="${TELEMT_IMAGE:-$TELEMT_IMAGE_DEFAULT}"
ASSUME_YES="${ASSUME_YES:-0}"
SCRIPT_LANG="${SCRIPT_LANG:-en}"
SCRIPT_LANG_FROM_CLI=0
UPDATE_MODE="${UPDATE_MODE:-0}"
FIX_NGINX_MODE="${FIX_NGINX_MODE:-0}"
BACKUP_ROOT="/root/telemt-astra-install-backups"
STATE_FILE="/root/.install_telemt_astra.state"
RESUME_CONFIG="/root/.install_telemt_astra.config"
NGINX_ACTIVE_AT_START="${NGINX_ACTIVE_AT_START:-}"

step_no=0
BACKUP_DIR=""

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

step_done() {
  [[ -f "$STATE_FILE" ]] && grep -Fxq "$1" "$STATE_FILE"
}

mark_done() {
  local id="$1"
  touch "$STATE_FILE"
  grep -Fxq "$id" "$STATE_FILE" 2>/dev/null || echo "$id" >> "$STATE_FILE"
}

save_resume_config() {
  umask 077
  cat > "$RESUME_CONFIG" <<EOF
PUBLIC_HOST=$(printf '%q' "$PUBLIC_HOST")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
LETSENCRYPT_EMAIL=$(printf '%q' "$LETSENCRYPT_EMAIL")
SSH_PORT=$(printf '%q' "$SSH_PORT")
SSH_KEY_ONLY_LOGIN=$(printf '%q' "$SSH_KEY_ONLY_LOGIN")
SSH_KEY_ONLY_CONFIRM=$(printf '%q' "$SSH_KEY_ONLY_CONFIRM")
ENABLE_FAIL2BAN=$(printf '%q' "$ENABLE_FAIL2BAN")
ADD_SWAP=$(printf '%q' "$ADD_SWAP")
TELEMT_MAX_TCP_CONNS=$(printf '%q' "$TELEMT_MAX_TCP_CONNS")
TELEMT_IMAGE=$(printf '%q' "$TELEMT_IMAGE")
BACKUP_DIR=$(printf '%q' "$BACKUP_DIR")
NGINX_ACTIVE_AT_START=$(printf '%q' "$NGINX_ACTIVE_AT_START")
EOF
  chmod 600 "$RESUME_CONFIG"
}

prompt() {
  local var="$1"
  local label="$2"
  local default_value="${3:-}"
  local answer=""
  local current_value="${!var:-}"

  if [[ "$ASSUME_YES" == "1" && -n "$current_value" ]]; then
    printf '%s: %s\n' "$label" "$current_value"
    return 0
  fi

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

  prompt "$var" "$label" "$default_value"
  value="$(lower "${!var}")"
  case "$value" in
    y|yes|д|да) printf -v "$var" '%s' "yes" ;;
    n|no|н|нет|"") printf -v "$var" '%s' "no" ;;
    *) die "$label must be yes/no or да/нет." ;;
  esac
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

is_ru() {
  [[ "${SCRIPT_LANG:-en}" == "ru" ]]
}

usage() {
  cat <<'EOF'
Usage:
  install_telemt.sh [--update] [--fix-nginx] [-lang ru|en]

Examples:
  ./install_telemt.sh
  ./install_telemt.sh -lang ru
  ./install_telemt.sh --update -lang ru
  ./install_telemt.sh --fix-nginx -lang ru

Options:
  -update, --update  Update Telemt container/image and restart it while preserving
                     telemt.toml, secrets, proxy links, nginx and SSH settings.
  -fix, --fix-nginx  Repair nginx configs after an incompatible HTTP/2 syntax error.
                     It backs up /etc/nginx, removes only "http2 on;" and
                     "listen ... http2;" forms, then runs nginx -t and reloads nginx.
  -lang, --lang      Installer language selector: ru or en.
  -h, --help         Show this help.
EOF
}

parse_args() {
  local value
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -update|--update|update)
        UPDATE_MODE=1
        ;;
      -fix|--fix|--fix-nginx|--fix-http2|fix)
        FIX_NGINX_MODE=1
        ;;
      -lang|--lang)
        shift
        [[ $# -gt 0 ]] || die "Missing value for -lang. Use ru or en."
        value="$1"
        SCRIPT_LANG="$(normalize_script_lang "$value")" || die "Bad language: $value. Use ru or en."
        SCRIPT_LANG_FROM_CLI=1
        ;;
      -lang=*|--lang=*)
        value="${1#*=}"
        SCRIPT_LANG="$(normalize_script_lang "$value")" || die "Bad language: $value. Use ru or en."
        SCRIPT_LANG_FROM_CLI=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done
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
  if have apt-get; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends python3-minimal
  elif have dnf; then
    dnf install -y python3
  else
    die "python3 is required for IDN/punycode domain normalization. Install python3 or enter the domain in punycode."
  fi
  have python3 || die "python3 is required for IDN/punycode domain normalization."
}

domain_to_ascii() {
  local value="$1"
  ensure_python3_for_idn
  python3 - "$value" <<'PYIDN'
import sys

domain = sys.argv[1].strip().rstrip('.').lower()
if not domain:
    print('empty domain', file=sys.stderr)
    sys.exit(1)
if any(ch.isspace() or ch in '/\\' for ch in domain):
    print('domain contains whitespace, slash, or backslash', file=sys.stderr)
    sys.exit(1)
try:
    ascii_domain = domain.encode('idna').decode('ascii').lower()
    decoded = ascii_domain.encode('ascii').decode('idna')
    roundtrip = decoded.encode('idna').decode('ascii').lower()
except Exception as exc:
    print(f'IDNA/punycode conversion failed: {exc}', file=sys.stderr)
    sys.exit(1)
if ascii_domain != roundtrip:
    print('IDNA/punycode round-trip check failed', file=sys.stderr)
    sys.exit(1)
labels = ascii_domain.split('.')
if len(labels) < 2 or any(not label for label in labels):
    print('domain must contain at least two non-empty labels', file=sys.stderr)
    sys.exit(1)
if any(len(label) > 63 for label in labels) or len(ascii_domain) > 253:
    print('domain is too long after IDNA conversion', file=sys.stderr)
    sys.exit(1)
for label in labels:
    if label.startswith('-') or label.endswith('-'):
        print("domain label starts or ends with '-'", file=sys.stderr)
        sys.exit(1)
    if not all(ch.isalnum() or ch == '-' for ch in label):
        print('domain contains invalid ASCII characters after IDNA conversion', file=sys.stderr)
        sys.exit(1)
print(ascii_domain)
PYIDN
}

normalize_public_host() {
  local original="$PUBLIC_HOST"
  PUBLIC_HOST="$(printf '%s' "$PUBLIC_HOST" | tr '[:upper:]' '[:lower:]')"
  PUBLIC_HOST="${PUBLIC_HOST%.}"
  if needs_idn_normalization "$PUBLIC_HOST"; then
    PUBLIC_HOST="$(domain_to_ascii "$PUBLIC_HOST")" || die "Bad domain: $original"
  fi
  if [[ "$PUBLIC_HOST" != "$original" ]]; then
    if is_ru; then
      echo "Домен нормализован в punycode/ASCII: $original -> $PUBLIC_HOST"
    else
      echo "Domain normalized to punycode/ASCII: $original -> $PUBLIC_HOST"
    fi
  fi
}

normalize_letsencrypt_email() {
  local original="$LETSENCRYPT_EMAIL" local_part domain_part ascii_domain
  local_part="${LETSENCRYPT_EMAIL%@*}"
  domain_part="${LETSENCRYPT_EMAIL#*@}"
  [[ "$local_part" != "$LETSENCRYPT_EMAIL" && -n "$local_part" ]] || die "Email must be a plain email address."
  [[ "$local_part" =~ ^[A-Za-z0-9._%+-]+$ ]] || die "Email local part has unsupported characters."
  domain_part="$(printf '%s' "$domain_part" | tr '[:upper:]' '[:lower:]')"
  domain_part="${domain_part%.}"
  if needs_idn_normalization "$domain_part"; then
    ascii_domain="$(domain_to_ascii "$domain_part")" || die "Bad email domain: $original"
  else
    ascii_domain="$domain_part"
  fi
  LETSENCRYPT_EMAIL="${local_part}@${ascii_domain}"
  if [[ "$LETSENCRYPT_EMAIL" != "$original" ]]; then
    if is_ru; then
      echo "Email нормализован в punycode/ASCII: $original -> $LETSENCRYPT_EMAIL"
    else
      echo "Email normalized to punycode/ASCII: $original -> $LETSENCRYPT_EMAIL"
    fi
  fi
}

telemt_image_supports_exclusive_mask() {
  local image="$TELEMT_IMAGE"
  [[ "$image" == *:latest || "$image" == latest || "$image" == *3.4.1[2-9]* || "$image" == *3.[5-9].* || "$image" == *[4-9].* ]]
}

exclusive_mask_block() {
  if telemt_image_supports_exclusive_mask; then
    printf '\n[censorship.exclusive_mask]\n"%s" = "127.0.0.1:8443"\n' "$PUBLIC_HOST"
  fi
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

is_public_ipv4() {
  local ip="$1"
  local a b c d
  IFS=. read -r a b c d <<< "$ip"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  for octet in "$a" "$b" "$c" "$d"; do
    (( octet >= 0 && octet <= 255 )) || return 1
  done
  (( a == 10 )) && return 1
  (( a == 127 )) && return 1
  (( a == 169 && b == 254 )) && return 1
  (( a == 172 && b >= 16 && b <= 31 )) && return 1
  (( a == 192 && b == 168 )) && return 1
  (( a == 100 && b >= 64 && b <= 127 )) && return 1
  (( a >= 224 )) && return 1
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

run_fix_nginx_mode() {
  local backup_dir changed file doctor_failed canonical_stream keep_stream
  local -a stream_files
  doctor_failed=0
  have nginx || die "nginx is not installed."
  backup_dir="${BACKUP_ROOT}/nginx-http2-fix-$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$backup_dir"

  if is_ru; then
    echo "Режим fix: чиню только nginx-конфиги. Telemt, секреты, Docker и сертификаты не трогаю."
    echo "Бэкап измененных файлов: $backup_dir"
  else
    echo "Fix mode: repairing nginx configs only. Telemt, secrets, Docker, and certificates are not touched."
    echo "Changed-file backup: $backup_dir"
  fi

  echo
  echo "nginx -t before fix:"
  nginx -t 2>&1 || true

  changed=0
  while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    if grep -Eq '^[[:space:]]*http2[[:space:]]+on[[:space:]]*;|^[[:space:]]*listen[[:space:]][^;]*[[:space:]]http2([[:space:]]|;)' "$file"; then
      install -d -m 0700 "$backup_dir$(dirname "$file")"
      cp -a "$file" "$backup_dir$file"
      sed -i \
        -e '/^[[:space:]]*http2[[:space:]][[:space:]]*on[[:space:]]*;/d' \
        -e 's/[[:space:]]http2[[:space:]]*;/;/' \
        -e 's/[[:space:]]http2[[:space:]][[:space:]]*/ /g' \
        "$file"
      echo "fixed: $file"
      changed=1
    fi
  done < <(find /etc/nginx -type f \( -name '*.conf' -o -path '/etc/nginx/sites-available/*' -o -path '/etc/nginx/sites-enabled/*' -o -path '/etc/nginx/modules-enabled/*' \) -print0 2>/dev/null)

  canonical_stream="/etc/nginx/modules-enabled/60-stream-sni.conf"
  keep_stream=""
  stream_files=()
  while IFS= read -r -d '' file; do
    [[ -f "$file" ]] || continue
    if grep -Eq '^[[:space:]]*stream[[:space:]]*\{' "$file"; then
      stream_files+=("$file")
      [[ -z "$keep_stream" ]] && keep_stream="$file"
    fi
  done < <(find /etc/nginx -type f \( -name '*.conf' -o -path '/etc/nginx/sites-available/*' -o -path '/etc/nginx/sites-enabled/*' -o -path '/etc/nginx/modules-enabled/*' \) -print0 2>/dev/null)

  if (( ${#stream_files[@]} > 1 )); then
    if [[ -f "$canonical_stream" ]] && grep -Eq '^[[:space:]]*stream[[:space:]]*\{' "$canonical_stream"; then
      keep_stream="$canonical_stream"
    fi
    echo "Found duplicate nginx stream blocks. Keeping: $keep_stream"
    for file in "${stream_files[@]}"; do
      [[ "$file" == "$keep_stream" ]] && continue
      if [[ "$file" == "/etc/nginx/nginx.conf" ]]; then
        echo "WARN: duplicate stream block is inside /etc/nginx/nginx.conf; not disabling it automatically"
        doctor_failed=1
        continue
      fi
      install -d -m 0700 "$backup_dir$(dirname "$file")"
      cp -a "$file" "$backup_dir$file"
      rm -f "$file"
      echo "disabled duplicate stream file: $file"
      changed=1
    done
  fi

  if [[ "$changed" == "0" ]]; then
    if is_ru; then
      echo "Несовместимых директив http2 не найдено."
    else
      echo "No incompatible http2 directives were found."
    fi
  fi

  echo
  echo "nginx -t after fix:"
  if nginx -t; then
    systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || true
    if is_ru; then
      echo "nginx config валиден."
    else
      echo "nginx config is valid."
    fi
  else
    if is_ru; then
      die "nginx все еще не проходит проверку. Смотри ошибку выше. Бэкап измененных файлов: $backup_dir"
    else
      die "nginx still fails validation. See the error above. Changed-file backup: $backup_dir"
    fi
  fi

  echo
  if is_ru; then
    echo "Проверяю остальной стек Telemt без перезаписи секретов и конфигов."
  else
    echo "Checking the rest of the Telemt stack without rewriting secrets or configs."
  fi

  if have systemctl && systemctl list-unit-files docker.service >/dev/null 2>&1; then
    if systemctl enable --now docker >/dev/null 2>&1; then
      echo "OK: docker.service active/enabled"
    else
      echo "WARN: docker.service could not be started"
      doctor_failed=1
    fi
  fi

  if [[ -f /opt/telemt-config/docker-compose.yml ]]; then
    if (cd /opt/telemt-config && compose_cmd config >/dev/null); then
      echo "OK: docker compose config"
      if docker inspect telemt >/dev/null 2>&1; then
        if docker start telemt >/dev/null 2>&1; then
          echo "OK: existing Telemt container started"
        else
          echo "WARN: docker start telemt failed"
          doctor_failed=1
        fi
      elif (cd /opt/telemt-config && COMPOSE_INTERACTIVE_NO_CLI=1 compose_cmd up -d --no-recreate >/dev/null); then
        echo "OK: Telemt container created and started"
      else
        echo "WARN: docker compose up -d --no-recreate failed in /opt/telemt-config"
        doctor_failed=1
      fi
    else
      echo "WARN: docker compose config failed in /opt/telemt-config"
      doctor_failed=1
    fi
  else
    echo "INFO: /opt/telemt-config/docker-compose.yml not found, skipping compose check"
  fi

  if [[ -f /opt/telemt-config/telemt.toml ]]; then
    chmod 600 /opt/telemt-config/telemt.toml 2>/dev/null || true
    chown 65532:65532 /opt/telemt-config/telemt.toml 2>/dev/null || true
    if [[ -s /opt/telemt-config/telemt.toml ]]; then
      echo "OK: /opt/telemt-config/telemt.toml exists"
    else
      echo "WARN: /opt/telemt-config/telemt.toml is empty"
      doctor_failed=1
    fi
  else
    echo "INFO: /opt/telemt-config/telemt.toml not found"
  fi

  if have curl && curl -fsS --max-time 3 http://127.0.0.1:9091/v1/users >/dev/null 2>&1; then
    echo "OK: Telemt local API responds on 127.0.0.1:9091"
  else
    echo "WARN: Telemt local API did not respond on 127.0.0.1:9091"
    doctor_failed=1
  fi

  if have systemctl && systemctl list-unit-files certbot.timer >/dev/null 2>&1; then
    systemctl enable --now certbot.timer >/dev/null 2>&1 || true
    if systemctl is-active --quiet certbot.timer; then
      echo "OK: certbot.timer active"
    else
      echo "WARN: certbot.timer not active"
      doctor_failed=1
    fi
  fi

  if have ss; then
    echo "Listening ports:"
    ss -lntp 2>/dev/null | grep -E ':(80|443|8443|1443|9091)[[:space:]]' || true
  fi

  if [[ "$doctor_failed" == "0" ]]; then
    if is_ru; then
      echo "Готово: безопасный fix/doctor завершен."
    else
      echo "Done: safe fix/doctor completed."
    fi
  else
    if is_ru; then
      die "fix/doctor нашел проблемы, которые нельзя безопасно исправить автоматически. Смотри WARN выше."
    else
      die "fix/doctor found issues that cannot be safely repaired automatically. See WARN lines above."
    fi
  fi
}

backup_path() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || return 0
  mkdir -p "$BACKUP_DIR"
  cp -a "$path" "$BACKUP_DIR"/
}

root_authorized_key_exists() {
  [[ -f /root/.ssh/authorized_keys ]] &&
    grep -Eq '(^|[[:space:]])(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)[[:space:]]' /root/.ssh/authorized_keys
}

remove_installer_key_only_config_if_present() {
  local conf="/etc/ssh/sshd_config.d/00password.conf"
  [[ -f "$conf" ]] || return 0
  if grep -Eq '^PasswordAuthentication[[:space:]]+no' "$conf" &&
     grep -Eq '^KbdInteractiveAuthentication[[:space:]]+no' "$conf" &&
     grep -Eq '^PubkeyAuthentication[[:space:]]+yes' "$conf"; then
    rm -f "$conf"
    echo "Removed installer key-only SSH config; password login is left to the base sshd_config."
  fi
}

detect_public_ip() {
  local candidate=""
  if is_public_ipv4 "$PUBLIC_IP"; then
    return 0
  fi
  if have curl; then
    candidate="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
    if is_public_ipv4 "$candidate"; then
      PUBLIC_IP="$candidate"
      return 0
    fi
  fi
  if have ip; then
    candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}' || true)"
    if is_public_ipv4 "$candidate"; then
      PUBLIC_IP="$candidate"
      return 0
    fi
  fi
  die "Could not detect public IPv4. Set PUBLIC_IP explicitly after networking is ready and rerun."
}

resolve_ipv4() {
  getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u
}

port_listening() {
  local port="$1"
  ss -H -lnt 2>/dev/null | awk -v p=":${port}" '$4 ~ p "$" {found=1} END {exit found ? 0 : 1}'
}

ensure_certbot_can_bind_http() {
  if ! port_listening 80; then
    return 0
  fi

  if [[ "$NGINX_ACTIVE_AT_START" == "0" ]]; then
    systemctl stop nginx 2>/dev/null || true
    return 0
  fi

  cat >&2 <<EOF
ERROR: port 80 is already in use by an existing service.

This installer uses certbot standalone HTTP-01 and will not stop an nginx
instance that was already active before installation.

Free port 80 temporarily, issue the certificate manually, or run on a clean VPS.
EOF
  exit 1
}

ensure_https_frontdoor_available() {
  if ! port_listening 443; then
    return 0
  fi

  if [[ -f /etc/nginx/modules-enabled/60-stream-sni.conf ]] && grep -q 'telemt_backend' /etc/nginx/modules-enabled/60-stream-sni.conf; then
    return 0
  fi

  cat >&2 <<EOF
ERROR: port 443 is already in use by an existing service.

Telemt needs nginx stream to own 443/tcp. To avoid breaking existing websites,
the installer stops here instead of replacing the current HTTPS frontend.
Move the existing site behind nginx stream manually, or use a clean server.
EOF
  exit 1
}

compose_cmd() {
  if docker compose version >/dev/null 2>&1; then
    docker compose "$@"
  else
    docker-compose "$@"
  fi
}

remove_old_telemt_container_for_recreate() {
  local cid found
  found=0
  cid="$(docker ps -aq --filter 'name=^/telemt$' 2>/dev/null || true)"
  if [[ -n "$cid" ]]; then
    found=1
    docker rm -f "$cid" >/dev/null 2>&1 || true
  fi
  [[ "$found" == "1" ]] && echo "Removed old Telemt container before recreate to avoid docker-compose v1 ContainerConfig/removed-image bug."
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1 || command -v docker-compose >/dev/null 2>&1; then
    return 0
  fi

  apt-get install -y docker-compose-plugin || {
    apt-get remove -y docker-buildx-plugin docker-compose-plugin || true
    dpkg --configure -a
    apt-get -f install -y
    apt-get install -y docker-compose
  }
}

configure_certbot_renewal() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post /etc/letsencrypt/renewal-hooks/deploy
  write_file_root /etc/letsencrypt/renewal-hooks/pre/stop-nginx-telemt.sh 0755 root:root <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl stop nginx
fi
EOF
  write_file_root /etc/letsencrypt/renewal-hooks/post/start-nginx-telemt.sh 0755 root:root <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1; then
  systemctl start nginx || systemctl restart nginx || true
fi
EOF
  write_file_root /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh 0755 root:root <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl reload nginx || systemctl restart nginx
fi
EOF

  systemctl enable --now certbot.timer
  systemctl list-timers certbot.timer --no-pager || true
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

certbot_renewal_hooks_current() {
  [[ -x /etc/letsencrypt/renewal-hooks/pre/stop-nginx-telemt.sh ]] &&
    [[ -x /etc/letsencrypt/renewal-hooks/post/start-nginx-telemt.sh ]] &&
    [[ -x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh ]]
}

nginx_http_redirect_current() {
  [[ -f /etc/nginx/sites-available/"$PUBLIC_HOST" ]] &&
    grep -Fq 'return 301 https://$host$request_uri;' /etc/nginx/sites-available/"$PUBLIC_HOST"
}


toml_value_from_section() {
  local file="$1"
  local section="$2"
  local key="$3"
  [[ -f "$file" ]] || return 1
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
  [[ -f "$file" ]] || return 1
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
  [[ -f "$file" ]] || return 1
  awk '
    /^[[:space:]]*image:[[:space:]]*/ {
      value=$0
      sub(/^[[:space:]]*image:[[:space:]]*/, "", value)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"|"$/, "", value)
      gsub(/^'"'"'|'"'"'$/, "", value)
      print value
      exit
    }
  ' "$file"
}

infer_update_config_from_existing_files() {
  local existing_domain existing_user existing_image

  if [[ -f /opt/telemt-config/telemt.toml ]]; then
    existing_domain="$(toml_value_from_section /opt/telemt-config/telemt.toml "general\\.links" "public_host" || true)"
    if [[ -z "$existing_domain" ]]; then
      existing_domain="$(toml_value_from_section /opt/telemt-config/telemt.toml "censorship" "tls_domain" || true)"
    fi
    existing_user="$(first_toml_key_from_section /opt/telemt-config/telemt.toml "access\\.users" || true)"
    [[ -n "$existing_domain" ]] && PUBLIC_HOST="${PUBLIC_HOST:-$existing_domain}"
    [[ -n "$existing_user" ]] && TELEMT_UPDATE_USER="$existing_user"
  fi

  existing_image="$(compose_image_from_file /opt/telemt-config/docker-compose.yml || true)"
  if [[ -n "$existing_image" && "$TELEMT_IMAGE_FROM_ENV" != "1" ]]; then
    TELEMT_IMAGE="$existing_image"
  fi

  if [[ -n "$PUBLIC_HOST" ]]; then
    normalize_public_host
  fi
}

backup_update_state() {
  local backup_dir path
  backup_dir="$BACKUP_ROOT/update-$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$backup_dir"
  for path in \
    /opt/telemt-config/telemt.toml \
    /opt/telemt-config/docker-compose.yml \
    /root/telemt-secret.env \
    "$RESUME_CONFIG" \
    /root/telemt-proxy-link.txt \
    /root/telemt-proxy-links.txt \
    "/etc/nginx/sites-available/$PUBLIC_HOST" \
    "/etc/nginx/sites-enabled/$PUBLIC_HOST" \
    "/etc/nginx/conf.d/$PUBLIC_HOST.conf" \
    /etc/nginx/modules-enabled/60-stream-sni.conf \
    /etc/nginx/modules-enabled/90-stream-sni.conf \
    /etc/nginx/stream-conf.d/telemt-sni.conf
  do
    if [[ -e "$path" || -L "$path" ]]; then
      cp -a "$path" "$backup_dir"/
    fi
  done
  chmod -R go-rwx "$backup_dir" 2>/dev/null || true
  echo "Update backup: $backup_dir"
}

set_compose_image_if_requested() {
  local current_image tmp
  current_image="$(compose_image_from_file /opt/telemt-config/docker-compose.yml || true)"
  [[ -n "$current_image" ]] || die "Cannot detect image in /opt/telemt-config/docker-compose.yml."
  if [[ "$TELEMT_IMAGE_FROM_ENV" == "1" && "$TELEMT_IMAGE" != "$current_image" ]]; then
    [[ "$TELEMT_IMAGE" =~ ^[A-Za-z0-9._/:@+-]+$ ]] || die "Bad Docker image: $TELEMT_IMAGE"
    tmp="$(mktemp)"
    awk -v image="$TELEMT_IMAGE" '
      !done && /^[[:space:]]*image:[[:space:]]*/ {
        match($0, /^[[:space:]]*/)
        print substr($0, RSTART, RLENGTH) "image: " image
        done=1
        next
      }
      { print }
    ' /opt/telemt-config/docker-compose.yml > "$tmp"
    cat "$tmp" > /opt/telemt-config/docker-compose.yml
    rm -f "$tmp"
    echo "Docker image updated in compose: $current_image -> $TELEMT_IMAGE"
  else
    TELEMT_IMAGE="$current_image"
  fi
}

confirm_update_plan() {
  local confirm
  if [[ "$ASSUME_YES" == "1" ]]; then
    echo "ASSUME_YES=1, continuing."
    return 0
  fi
  if is_ru; then
    printf 'Введите y, yes или да для обновления: '
  else
    printf 'Type y or yes to update: '
  fi
  read -r confirm
  confirm="$(lower "$confirm")"
  case "$confirm" in
    y|yes|д|да) ;;
    *) die "Cancelled." ;;
  esac
}

run_update_mode() {
  TELEMT_UPDATE_USER=""
  [[ -d /opt/telemt-config ]] || die "Install directory not found: /opt/telemt-config"
  [[ -f /opt/telemt-config/telemt.toml ]] || die "Telemt config not found: /opt/telemt-config/telemt.toml"
  [[ -f /opt/telemt-config/docker-compose.yml ]] || die "Compose config not found: /opt/telemt-config/docker-compose.yml"

  infer_update_config_from_existing_files
  [[ -n "$PUBLIC_HOST" ]] || die "Cannot detect domain from existing Telemt config."
  detect_public_ip

  cat <<EOF

Update plan:
  domain:          ${PUBLIC_HOST}
  public IPv4:     ${PUBLIC_IP}
  Docker image:    ${TELEMT_IMAGE}
  Telemt config:   preserved without rewrite
  compose file:    preserved unless TELEMT_IMAGE was explicitly passed
  secrets/users:   preserved
  nginx/SSH:       preserved

EOF
  if [[ "$TELEMT_IMAGE" == *@sha256:* && "$TELEMT_IMAGE_FROM_ENV" != "1" ]]; then
    cat <<'EOF'
Note: current Docker image is digest-pinned. Update mode will pull/recreate this exact digest.
To move to another image/tag, run for example:
  TELEMT_IMAGE=<image-or-tag> ./install_telemt.sh --update -lang ru
EOF
  fi
  confirm_update_plan

  backup_update_state
  set_compose_image_if_requested
  systemctl enable --now docker
  cd /opt/telemt-config
  compose_cmd config >/dev/null
  compose_cmd pull || true
  remove_old_telemt_container_for_recreate
  compose_cmd up -d --force-recreate
  sleep 12

  tmp_users="$(mktemp)"
  chmod 600 "$tmp_users"
  trap 'rm -f "$tmp_users"' EXIT
  curl -fsS http://127.0.0.1:9091/v1/users > "$tmp_users"
  grep -q '"ok":true' "$tmp_users"
  grep -o 'tg://proxy[^"]*' "$tmp_users" > /root/telemt-proxy-link.txt || true
  chmod 600 /root/telemt-proxy-link.txt 2>/dev/null || true
  /usr/local/sbin/telemt-report 2m || true

  echo
  echo "Update done. Existing config and secrets were preserved."
  if [[ -s /root/telemt-proxy-link.txt ]]; then
    echo "Proxy link:"
    cat /root/telemt-proxy-link.txt
  fi
}

parse_args "$@"
REQUESTED_SCRIPT_LANG="$SCRIPT_LANG"
REQUESTED_TELEMT_IMAGE="$TELEMT_IMAGE"

[[ "$(id -u)" -eq 0 ]] || die "Run as root."
if [[ "$(uname -s)" != "Linux" ]] || ! have apt-get || ! have systemctl; then
  cat >&2 <<'EOF'
ERROR: This installer must be run on the target Astra Linux server, not on your local computer.

Use:
  scp install_telemt_astra.sh root@<SERVER_PUBLIC_IP>:/root/
  ssh root@<SERVER_PUBLIC_IP>
  bash /root/install_telemt_astra.sh
EOF
  exit 1
fi

if [[ "${RESET_INSTALL_STATE:-0}" == "1" ]]; then
  rm -f "$STATE_FILE" "$RESUME_CONFIG"
fi

if [[ -f "$RESUME_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$RESUME_CONFIG"
  echo "Resume config found: $RESUME_CONFIG"
fi
if [[ "$SCRIPT_LANG_FROM_CLI" == "1" ]]; then
  SCRIPT_LANG="$REQUESTED_SCRIPT_LANG"
fi
if [[ "$TELEMT_IMAGE_FROM_ENV" == "1" ]]; then
  TELEMT_IMAGE="$REQUESTED_TELEMT_IMAGE"
fi

if [[ "$UPDATE_MODE" == "1" ]]; then
  run_update_mode
  exit 0
fi

if [[ "$FIX_NGINX_MODE" == "1" ]]; then
  run_fix_nginx_mode
  exit 0
fi

if [[ "${RESET_INSTALL_STATE:-0}" != "1" ]] && {
  [[ -f /opt/telemt-config/telemt.toml ]] ||
  [[ -f /opt/telemt-config/docker-compose.yml ]] ||
  [[ -f /root/telemt-secret.env ]] ||
  [[ -f "$RESUME_CONFIG" ]] ||
  docker inspect telemt >/dev/null 2>&1
}; then
  if is_ru; then
    cat >&2 <<'EOF'
ОШИБКА: найдена существующая установка Telemt.

Обычный запуск установщика предназначен для чистого сервера и остановлен,
чтобы не повредить текущие nginx/Docker/Telemt настройки.

Для безопасного обновления:
  ./install_telemt_astra.sh --update -lang ru

Для ремонта/диагностики:
  ./install_telemt_astra.sh --fix-nginx -lang ru

Для осознанной переустановки с нуля:
  RESET_INSTALL_STATE=1 ./install_telemt_astra.sh -lang ru
EOF
  else
    cat >&2 <<'EOF'
ERROR: an existing Telemt installation was found.

Normal installer mode is intended for a clean server and has been stopped
to avoid damaging current nginx/Docker/Telemt settings.

For a safe update:
  ./install_telemt_astra.sh --update -lang en

For repair/diagnostics:
  ./install_telemt_astra.sh --fix-nginx -lang en

For an intentional clean reinstall:
  RESET_INSTALL_STATE=1 ./install_telemt_astra.sh -lang en
EOF
  fi
  exit 1
fi

if [[ -z "$NGINX_ACTIVE_AT_START" ]]; then
  if systemctl is-active --quiet nginx 2>/dev/null; then
    NGINX_ACTIVE_AT_START=1
  else
    NGINX_ACTIVE_AT_START=0
  fi
fi

cat <<'EOF'
Telemt Astra Linux installer.

Before running:
  1. Create DNS A record: <domain> -> this server IPv4.
  2. Make sure ports 80 and 443 are reachable from the internet.
  3. Keep the current SSH session open until a second login works.

EOF

if is_ru; then
  prompt PUBLIC_HOST "Домен прокси" "$PUBLIC_HOST"
else
  prompt PUBLIC_HOST "Proxy domain" "$PUBLIC_HOST"
fi
normalize_public_host
valid_domain "$PUBLIC_HOST" || die "Domain must be a valid DNS name, for example proxy.example.com."

detect_public_ip
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@${PUBLIC_HOST}}"

if is_ru; then
  prompt LETSENCRYPT_EMAIL "Email для Let's Encrypt" "$LETSENCRYPT_EMAIL"
else
  prompt LETSENCRYPT_EMAIL "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
fi
normalize_letsencrypt_email
if is_ru; then
  prompt SSH_PORT "SSH-порт, Enter оставляет текущий/по умолчанию" "$SSH_PORT"
  prompt_yes_no SSH_KEY_ONLY_LOGIN "Отключить SSH-пароли и оставить root только по ключу? yes/no/да/нет" "$SSH_KEY_ONLY_LOGIN"
  prompt_yes_no ENABLE_FAIL2BAN "Включить fail2ban для SSH? yes/no/да/нет" "$ENABLE_FAIL2BAN"
  prompt_yes_no ADD_SWAP "Добавить 1G swap, если swap нет? yes/no/да/нет" "$ADD_SWAP"
  prompt TELEMT_MAX_TCP_CONNS "Максимум подключений Telemt" "$TELEMT_MAX_TCP_CONNS"
else
  prompt SSH_PORT "SSH port, Enter keeps current/default" "$SSH_PORT"
  prompt_yes_no SSH_KEY_ONLY_LOGIN "Disable SSH password login and keep root key-only? yes/no" "$SSH_KEY_ONLY_LOGIN"
  prompt_yes_no ENABLE_FAIL2BAN "Enable fail2ban for SSH? yes/no" "$ENABLE_FAIL2BAN"
  prompt_yes_no ADD_SWAP "Add 1G swap if missing? yes/no" "$ADD_SWAP"
  prompt TELEMT_MAX_TCP_CONNS "Max Telemt connections" "$TELEMT_MAX_TCP_CONNS"
fi

[[ "$LETSENCRYPT_EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || die "Email must be a plain email address."
valid_port "$SSH_PORT" || die "SSH port must be a number from 1 to 65535."
valid_limit "$TELEMT_MAX_TCP_CONNS" || die "Connection limit must be a number from 1 to 1000000."

if [[ "$SSH_KEY_ONLY_LOGIN" == "yes" ]]; then
  if ! root_authorized_key_exists; then
    cat >&2 <<'EOF'

SSH key-only login was requested, but no root SSH public key was found.

Add your public key first:
  /root/.ssh/authorized_keys

Then rerun the installer and choose SSH key-only login again.
EOF
    exit 1
  fi

  prompt_yes_no SSH_KEY_ONLY_CONFIRM "Are you sure you want to close SSH password login? yes/no" "$SSH_KEY_ONLY_CONFIRM"
  if [[ "$SSH_KEY_ONLY_CONFIRM" != "yes" ]]; then
    SSH_KEY_ONLY_LOGIN="no"
    echo "SSH password login will not be disabled."
  fi
fi

step "DNS preflight"
echo "server_public_ipv4=$PUBLIC_IP"
resolved_ips="$(resolve_ipv4 "$PUBLIC_HOST" | tr '\n' ' ')"
echo "domain_ipv4=$resolved_ips"
if have host; then
  echo "host_check:"
  host "$PUBLIC_HOST" || true
fi
if ! printf ' %s ' "$resolved_ips" | grep -q " $PUBLIC_IP "; then
  cat >&2 <<EOF

DNS check failed.

${PUBLIC_HOST} must resolve to this server IPv4 before SSL can be issued.

Expected:
  ${PUBLIC_HOST} -> ${PUBLIC_IP}

Current A records:
  ${resolved_ips:-none}

Fix DNS and rerun this script.
EOF
  exit 1
fi

cat <<EOF

Install plan:
  domain:       ${PUBLIC_HOST}
  public IPv4:  ${PUBLIC_IP}
  email:        ${LETSENCRYPT_EMAIL}
  SSH port:     ${SSH_PORT}
  SSH key-only: ${SSH_KEY_ONLY_LOGIN}
  fail2ban SSH: ${ENABLE_FAIL2BAN}
  add swap:     ${ADD_SWAP}
  Telemt limit: ${TELEMT_MAX_TCP_CONNS}

Type y or yes to continue:
EOF
if [[ "$ASSUME_YES" != "1" ]]; then
  read -r confirm
  confirm="$(lower "$confirm")"
  case "$confirm" in
    y|yes|д|да) ;;
    *) die "Cancelled." ;;
  esac
else
  echo "ASSUME_YES=1, continuing."
fi

if [[ -z "$BACKUP_DIR" ]]; then
  BACKUP_DIR="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
fi
save_resume_config

if step_done backup; then
  step "Backup current state (already done)"
  echo "backup_dir=$BACKUP_DIR"
else
  step "Backup current state"
  mkdir -p "$BACKUP_DIR"
  backup_path /opt/telemt-config
  backup_path /etc/nginx/modules-enabled/60-stream-sni.conf
  backup_path /etc/nginx/sites-available/"$PUBLIC_HOST"
  backup_path /etc/nginx/sites-enabled/"$PUBLIC_HOST"
  backup_path /etc/nftables-local-hardening.conf
  backup_path /etc/systemd/system/local-hardening-nft.service
  backup_path /etc/fail2ban/jail.d/sshd.local
  backup_path /etc/fail2ban/jail.d/defaults-astra.conf
  backup_path /etc/ssh/sshd_config
  backup_path /etc/ssh/sshd_config.d/00password.conf
  echo "backup_dir=$BACKUP_DIR"
  mark_done backup
fi

if [[ "$ADD_SWAP" == "yes" ]]; then
  if step_done swap; then
    step "Add 1G swap if missing (already done)"
    swapon --show || true
  else
    step "Add 1G swap if missing"
    if ! swapon --show=NAME --noheadings 2>/dev/null | grep -q .; then
      if [[ ! -e /swapfile ]]; then
        fallocate -l 1G /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=1024
        chmod 600 /swapfile
        mkswap /swapfile
      fi
      swapon /swapfile || true
      grep -qE '^[^#].*[[:space:]]/swapfile[[:space:]]' /etc/fstab 2>/dev/null || \
        printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    fi
    swapon --show || true
    mark_done swap
  fi
else
  step "Add 1G swap if missing (skipped)"
  swapon --show || true
fi

if step_done packages; then
  step "Install packages (already done)"
else
  step "Install packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg openssl iproute2 nftables \
    nginx libnginx-mod-stream certbot jq
  if ! have docker; then
    apt-get install -y docker.io
  fi
  ensure_compose
  systemctl enable --now docker
  mark_done packages
fi

if step_done secret && [[ -f /root/telemt-secret.env ]]; then
  step "Prepare Telemt secret (already done)"
  # shellcheck disable=SC1091
  source /root/telemt-secret.env
else
  step "Prepare Telemt secret"
  if [[ -f /root/telemt-secret.env ]]; then
    # shellcheck disable=SC1091
    source /root/telemt-secret.env
  else
    TELEMT_SECRET="$(openssl rand -hex 16)"
    cat > /root/telemt-secret.env <<EOF
TELEMT_SECRET=${TELEMT_SECRET}
EOF
    chmod 600 /root/telemt-secret.env
  fi
  echo "secret_saved=/root/telemt-secret.env"
  mark_done secret
fi

if step_done ssh_hardening && [[ "$SSH_KEY_ONLY_LOGIN" == "yes" ]] &&
   [[ -f /etc/ssh/sshd_config.d/00password.conf ]] &&
   grep -Eq '^PasswordAuthentication[[:space:]]+no' /etc/ssh/sshd_config.d/00password.conf; then
  step "Configure SSH settings (already done)"
else
  step "Configure SSH settings"
  if grep -Eq '^[#[:space:]]*Port[[:space:]]+' /etc/ssh/sshd_config; then
    sed -i -E "s/^[#[:space:]]*Port[[:space:]]+.*/Port ${SSH_PORT}/" /etc/ssh/sshd_config
  else
    printf '\nPort %s\n' "$SSH_PORT" >> /etc/ssh/sshd_config
  fi

  if [[ "$SSH_KEY_ONLY_LOGIN" == "yes" ]]; then
    root_authorized_key_exists || die "SSH key-only login requested, but /root/.ssh/authorized_keys has no supported public key."
    write_file_root /etc/ssh/sshd_config.d/00password.conf 0644 root:root <<EOF
# Managed by Telemt installer when SSH_KEY_ONLY_LOGIN=yes.
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 3
EOF
  else
    remove_installer_key_only_config_if_present
    echo "SSH password login was left enabled/unchanged."
  fi

  sshd -t
  systemctl restart ssh || systemctl restart sshd
  mark_done ssh_hardening
fi

if [[ "$ENABLE_FAIL2BAN" == "yes" ]]; then
  if step_done fail2ban; then
    step "Configure fail2ban (already done)"
  else
    step "Configure fail2ban"
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y fail2ban
    write_file_root /etc/fail2ban/jail.d/defaults-astra.conf 0644 root:root <<'EOF'
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
    mark_done fail2ban
  fi
else
  step "Configure fail2ban (skipped)"
  echo "fail2ban was left unchanged."
fi

if step_done nft_api_block; then
  step "Block external Telemt API port (already done)"
else
  step "Block external Telemt API port"
  write_file_root /etc/nftables-local-hardening.conf 0755 root:root <<'EOF'
#!/usr/sbin/nft -f

destroy table inet local_hardening

table inet local_hardening {
    chain input {
        type filter hook input priority -10; policy accept;
        iifname "lo" accept
        tcp dport 9091 drop
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
  mark_done nft_api_block
fi

if step_done firewall_public_ports; then
  step "Open public HTTP/HTTPS firewall ports (already done)"
else
  step "Open public HTTP/HTTPS firewall ports"
  open_public_firewall_ports
  mark_done firewall_public_ports
fi

if step_done certbot; then
  step "Issue Let's Encrypt certificate (already done)"
else
  step "Issue Let's Encrypt certificate"
  ensure_https_frontdoor_available
  ensure_certbot_can_bind_http
  certbot certonly --standalone --non-interactive --agree-tos --keep-until-expiring \
    --preferred-challenges http \
    --email "$LETSENCRYPT_EMAIL" \
    -d "$PUBLIC_HOST"
  mark_done certbot
fi

if step_done certbot_renewal && certbot_renewal_hooks_current; then
  step "Configure certificate auto-renewal (already done)"
else
  step "Configure certificate auto-renewal"
  configure_certbot_renewal
  mark_done certbot_renewal
fi

if step_done nginx_config && nginx_http_redirect_current; then
  step "Configure nginx mask site and SNI routing (already done)"
else
  step "Configure nginx mask site and SNI routing"
  ensure_https_frontdoor_available
  mask_site_started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  install -d -m 0755 /var/www/"$PUBLIC_HOST"
  write_file_root /var/www/"$PUBLIC_HOST"/index.html 0644 root:root <<EOF
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>${PUBLIC_HOST}</title>
  <style>
    :root {
      color-scheme: dark;
      --bg: #202020;
      --panel: #f4f4f1;
      --text: #f7f7f5;
      --muted: #b9b9b4;
      --ink: #2a2a2a;
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
    <div class="domain">${PUBLIC_HOST}</div>
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
    const startedAt = new Date("${mask_site_started_at}");
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

  write_file_root /etc/nginx/sites-available/"$PUBLIC_HOST" 0644 root:root <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${PUBLIC_HOST};
    access_log off;
    error_log /var/log/nginx/${PUBLIC_HOST}.error.log crit;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/${PUBLIC_HOST};
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
    error_log /var/log/nginx/${PUBLIC_HOST}.error.log crit;

    root /var/www/${PUBLIC_HOST};
    index index.html;

    ssl_certificate /etc/letsencrypt/live/${PUBLIC_HOST}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${PUBLIC_HOST}/privkey.pem;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
  ln -sfn /etc/nginx/sites-available/"$PUBLIC_HOST" /etc/nginx/sites-enabled/"$PUBLIC_HOST"

  write_file_root /etc/nginx/modules-enabled/60-stream-sni.conf 0644 root:root <<EOF
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
  nginx -t
  systemctl enable --now nginx
  systemctl restart nginx
  mark_done nginx_config
fi

if step_done telemt_config; then
  step "Configure Telemt (already done)"
else
  step "Configure Telemt"
  install -d -m 0700 -o 65532 -g 65532 /opt/telemt-config
  write_file_root /opt/telemt-config/telemt.toml 0600 65532:65532 <<EOF
show_link = []

[general]
fast_mode = true
use_middle_proxy = false
config_strict = true
log_level = "silent"

[general.links]
show = []
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

[server.api]
enabled = true
listen = "127.0.0.1:9091"
read_only = true
request_body_limit_bytes = 65536
minimal_runtime_enabled = true
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "127.0.0.1"
announce = "${PUBLIC_IP}"

[censorship]
tls_domain = "${PUBLIC_HOST}"
mask = true
mask_host = "127.0.0.1"
mask_port = 8443
tls_emulation = true
tls_front_dir = "/tmp/telemt-tlsfront"
tls_full_cert_ttl_secs = 0
alpn_enforce = true
$(exclusive_mask_block)
[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
default = "${TELEMT_SECRET}"

[access.user_max_tcp_conns]
default = ${TELEMT_MAX_TCP_CONNS}

[[upstreams]]
type = "direct"
enabled = true
weight = 10
EOF

  write_file_root /opt/telemt-config/docker-compose.yml 0644 root:root <<EOF
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
      - /opt/telemt-config:/etc/telemt
    command: ["/etc/telemt/telemt.toml"]
    security_opt:
      - no-new-privileges=true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
      - /run/telemt:rw,nosuid,nodev,noexec,size=16m
    logging:
      driver: "none"
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
EOF

  cd /opt/telemt-config
  compose_cmd config >/dev/null
  compose_cmd pull
  remove_old_telemt_container_for_recreate
  compose_cmd up -d
  mark_done telemt_config
fi

if step_done log_hardening; then
  step "Disable access and runtime logs (already done)"
else
  step "Disable access and runtime logs"
  install -d -m 0755 /etc/nginx/conf.d
  write_file_root /etc/nginx/conf.d/00-telemt-no-access-log.conf 0644 root:root <<'EOF'
# Disable HTTP access logs for the Telemt mask site.
access_log off;
EOF
  : > /var/log/nginx/access.log 2>/dev/null || true

  if [[ -f /opt/telemt-config/docker-compose.yml ]]; then
    old_log_path="$(docker inspect telemt --format '{{.LogPath}}' 2>/dev/null || true)"
    if [[ -n "$old_log_path" && -f "$old_log_path" ]]; then
      : > "$old_log_path" 2>/dev/null || true
    fi
    write_file_root /opt/telemt-config/docker-compose.yml 0644 root:root <<EOF
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
      - /opt/telemt-config:/etc/telemt
    command: ["/etc/telemt/telemt.toml"]
    security_opt:
      - no-new-privileges=true
    cap_drop:
      - ALL
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
      - /run/telemt:rw,nosuid,nodev,noexec,size=16m
    logging:
      driver: "none"
    ulimits:
      nofile:
        soft: 65535
        hard: 65535
EOF
    cd /opt/telemt-config
    compose_cmd config >/dev/null
    remove_old_telemt_container_for_recreate
    compose_cmd up -d --force-recreate
  fi

  nginx -t
  systemctl reload nginx || systemctl restart nginx
  mark_done log_hardening
fi

if step_done report_script; then
  step "Install telemt-report (already done)"
else
  step "Install telemt-report"
  write_file_root /usr/local/sbin/telemt-report 0700 root:root <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
SINCE="${1:-5m}"
CONTAINER="${CONTAINER:-telemt}"
API_URL="${API_URL:-http://127.0.0.1:9091}"
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
telemt_running=no
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then telemt_running="$(docker inspect "$CONTAINER" --format '{{if .State.Running}}yes{{else}}no{{end}}' 2>/dev/null || printf no)"; fi
listener_443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:443$/ {found=1} END{exit !found}' && printf yes || printf no)"
listener_1443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:1443$/ {found=1} END{exit !found}' && printf yes || printf no)"
ss -H -ant state established 'sport = :443' 2>/dev/null | peer_ip_from_ss > "$tmp_clients"
conn_443="$(wc -l < "$tmp_clients" | tr -d ' ')"
uniq_443="$(sort -u "$tmp_clients" | grep -c . || true)"
status=OK
[ "$telemt_running" = yes ] || status=BAD
[ "$api_ok" = yes ] || status=BAD
[ "$listener_443" = yes ] || status=BAD
[ "$listener_1443" = yes ] || status=BAD
printf 'health:        %s\n' "$status"
printf 'telemt:        running=%s api=%s backend_1443=%s\n' "$telemt_running" "$api_ok" "$listener_1443"
printf 'front door:    listener_443=%s established_443=%s unique_peer_ips=%s\n' "$listener_443" "$conn_443" "$uniq_443"
section "TELEMT USERS"
if [ "$api_ok" = yes ] && have jq; then
  printf '%s\n' "$api_users" | jq -r '.data[] | [.username,(.current_connections|tostring),((.max_tcp_conns//"unlimited")|tostring),(.active_unique_ips//0|tostring),(.recent_unique_ips//0|tostring),(.total_octets//0|tostring)] | @tsv' |
  while IFS=$'\t' read -r u c m a r o; do printf '%-18s connections=%s/%s api_active_ips=%s api_recent_ips=%s traffic=%s\n' "$u" "$c" "$m" "$a" "$r" "$(bytes_human "$o")"; done
else
  printf 'Telemt API is not reachable or jq is missing\n'
fi
section "CLIENT PEER IPS ON TCP/443"
printf 'total_established_443_connections: %s\nunique_peer_ips: %s\ntop_peer_ips:\n' "$conn_443" "$uniq_443"
if [ "$conn_443" -gt 0 ]; then sort "$tmp_clients" | uniq -c | sort -nr | head -n 20 | awk '{printf "  %6s  %s\n",$1,$2}'; else printf '  none\n'; fi
section "SERVICES AND PORTS"
for svc in nginx docker fail2ban local-hardening-nft; do printf '%-24s %s\n' "$svc" "$(service_state "$svc")"; done
ssh_ports="$(sshd -T 2>/dev/null | awk '$1=="port"{print $2}' | paste -sd '|' -)"
[ -n "$ssh_ports" ] || ssh_ports="22"
printf '\nlistening_ports:\n'; ss -lntp 2>/dev/null | grep -E ":(${ssh_ports}|443|8443|1443|9091)\b" || printf 'no expected listeners found\n'
section "DOCKER TELEMT"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then docker inspect "$CONTAINER" --format 'name={{.Name}} image={{.Config.Image}} user={{.Config.User}} running={{.State.Running}} status={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}} readonly={{.HostConfig.ReadonlyRootfs}} network={{.HostConfig.NetworkMode}}'; docker stats --no-stream "$CONTAINER" || true; fi
section "SERVER RESOURCES"
free -m 2>/dev/null | awk 'NR<=3{print}'; df -h / /var /opt 2>/dev/null | awk '!seen[$0]++'
section "TELEMT CONTAINER LOGGING"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  log_driver="$(docker inspect "$CONTAINER" --format '{{.HostConfig.LogConfig.Type}}' 2>/dev/null || printf unknown)"
  printf 'docker_log_driver: %s\n' "$log_driver"
  if [ "$log_driver" = none ]; then
    printf 'runtime logs are disabled to avoid storing client activity and filling disk\n'
  else
    printf 'runtime logs are not disabled; run the installer log_hardening step again\n'
  fi
fi
EOF
  mark_done report_script
fi

step "Validation"
sleep 12
ss -lntp | grep -E ':(443|8443|1443|9091|'"${SSH_PORT}"')\b' || true
tmp_users="$(mktemp)"
chmod 600 "$tmp_users"
trap 'rm -f "$tmp_users"' EXIT
curl -fsS http://127.0.0.1:9091/v1/users > "$tmp_users"
grep -q '"ok":true' "$tmp_users"
grep -o 'tg://proxy[^"]*' "$tmp_users" > /root/telemt-proxy-link.txt || true
chmod 600 /root/telemt-proxy-link.txt 2>/dev/null || true
curl -fsSIs --resolve "${PUBLIC_HOST}:80:${PUBLIC_IP}" "http://${PUBLIC_HOST}/" | head -n 12 || true
curl -fsSIs --resolve "${PUBLIC_HOST}:443:${PUBLIC_IP}" "https://${PUBLIC_HOST}/" | head -n 12 || true
/usr/local/sbin/telemt-report 2m || true

step "Done"
cat <<EOF
Installed Telemt on Astra Linux.

Proxy host: ${PUBLIC_HOST}:443
Telemt limit: ${TELEMT_MAX_TCP_CONNS}
Proxy link file: /root/telemt-proxy-link.txt
Secret: /root/telemt-secret.env
Backups: ${BACKUP_DIR}
SSH port: ${SSH_PORT}
EOF

if [[ -s /root/telemt-proxy-link.txt ]]; then
  echo
  echo "Proxy link:"
  cat /root/telemt-proxy-link.txt
else
  echo
  echo "Proxy link was not generated. Check:"
  echo "  curl -fsS http://127.0.0.1:9091/v1/users"
fi

cat <<EOF
Health report:
  telemt-report 5m

Important: open a second SSH session now:
  ssh -p ${SSH_PORT} root@${PUBLIC_HOST}
EOF
