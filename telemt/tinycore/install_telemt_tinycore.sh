#!/bin/sh
set -eu

# Telemt installer for Tiny Core Linux / CorePure64, without Docker or systemd.
# It uses Tiny Core extensions, native Telemt musl binary, nginx stream SNI
# routing, acme.sh standalone ACME, and /opt/bootlocal.sh autostart.

TELEMT_HOME="${TELEMT_HOME:-/opt/telemt}"
ACME_HOME="${ACME_HOME:-/opt/acme.sh}"
STATE_FILE="${STATE_FILE:-$TELEMT_HOME/.install_tinycore.state}"
RESUME_CONFIG="${RESUME_CONFIG:-$TELEMT_HOME/install.conf}"
TELEMT_RELEASE_FROM_ENV="${TELEMT_RELEASE:+1}"
TELEMT_RELEASE="${TELEMT_RELEASE:-latest}"
TELEMT_SHA256_X86_64="${TELEMT_SHA256_X86_64:-}"
TELEMT_SHA256_AARCH64="${TELEMT_SHA256_AARCH64:-}"
ACME_SH_VERSION="${ACME_SH_VERSION:-3.1.2}"
ACME_SH_SHA256="${ACME_SH_SHA256:-c46b41a61c96f67d424e4b4e476907c964b81d53cf94358a9c1d363a4f99c3a4}"
ASSUME_YES="${ASSUME_YES:-0}"
SCRIPT_LANG="${SCRIPT_LANG:-en}"
UPDATE_MODE="${UPDATE_MODE:-0}"

PUBLIC_HOST="${PUBLIC_HOST:-}"
PUBLIC_IP="${PUBLIC_IP:-}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
SSH_PORT="${SSH_PORT:-22}"
TELEMT_MAX_TCP_CONNS="${TELEMT_MAX_TCP_CONNS:-5000}"
TELEMT_SECRET="${TELEMT_SECRET:-}"
BOOTLOCAL="/opt/bootlocal.sh"

step_no=0

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
  if [ "$ASSUME_YES" = "1" ] && [ -n "$default_value" ]; then
    printf '%s: %s\n' "$label" "$default_value"
    REPLY="$default_value"
  else
    prompt_value "$label" "$default_value"
  fi
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
  [ "${SCRIPT_LANG:-en}" = "ru" ]
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -update|--update|update)
        UPDATE_MODE=1
        ;;
      -lang|--lang)
        shift
        [ "$#" -gt 0 ] || die "Missing value for -lang. Use ru or en."
        SCRIPT_LANG="$(normalize_script_lang "$1")" || die "Bad language: $1. Use ru or en."
        ;;
      -lang=*|--lang=*)
        value="${1#*=}"
        SCRIPT_LANG="$(normalize_script_lang "$value")" || die "Bad language: $value. Use ru or en."
        ;;
      -h|--help)
        cat <<'EOF'
Usage:
  install_telemt_tinycore.sh [--update] [-lang ru|en]

Options:
  -update, --update  Update the native Telemt binary and restart services while
                     preserving telemt.toml, secrets, nginx and ACME settings.
  -lang, --lang      Accept ru/en language selector.
EOF
        exit 0
        ;;
      *) die "Unknown argument: $1" ;;
    esac
    shift
  done
}

needs_idn_normalization() {
  value="$1"
  case "$value" in
    *[!abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-]*|*xn--*|*XN--*) return 0 ;;
    *) return 1 ;;
  esac
}

ensure_python3_for_idn() {
  if have python3; then
    return 0
  fi
  if have tce-load; then
    tce-load -wi python3.11 || tce-load -wi python3.10 || tce-load -wi python3 || true
  fi
  have python3 || die "python3 is required for IDN/punycode domain normalization on Tiny Core. Install python3 or enter the domain in punycode."
}

domain_to_ascii() {
  value="$1"
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
  original="$PUBLIC_HOST"
  PUBLIC_HOST="$(printf '%s' "$PUBLIC_HOST" | tr '[:upper:]' '[:lower:]')"
  PUBLIC_HOST="${PUBLIC_HOST%.}"
  if needs_idn_normalization "$PUBLIC_HOST"; then
    PUBLIC_HOST="$(domain_to_ascii "$PUBLIC_HOST")" || die "Bad domain: $original"
  fi
  if [ "$PUBLIC_HOST" != "$original" ]; then
    echo "Domain normalized to punycode/ASCII: $original -> $PUBLIC_HOST"
  fi
}

normalize_letsencrypt_email() {
  original="$LETSENCRYPT_EMAIL"
  local_part="${LETSENCRYPT_EMAIL%@*}"
  domain_part="${LETSENCRYPT_EMAIL#*@}"
  [ "$local_part" != "$LETSENCRYPT_EMAIL" ] && [ -n "$local_part" ] || die "Email must be a plain email address."
  printf '%s' "$local_part" | grep -Eq '^[A-Za-z0-9._%+-]+$' || die "Email local part has unsupported characters."
  domain_part="$(printf '%s' "$domain_part" | tr '[:upper:]' '[:lower:]')"
  domain_part="${domain_part%.}"
  if needs_idn_normalization "$domain_part"; then
    ascii_domain="$(domain_to_ascii "$domain_part")" || die "Bad email domain: $original"
  else
    ascii_domain="$domain_part"
  fi
  LETSENCRYPT_EMAIL="${local_part}@${ascii_domain}"
  if [ "$LETSENCRYPT_EMAIL" != "$original" ]; then
    echo "Email normalized to punycode/ASCII: $original -> $LETSENCRYPT_EMAIL"
  fi
}

telemt_release_supports_exclusive_mask() {
  case "$TELEMT_RELEASE" in
    latest|v3.4.1[2-9]|3.4.1[2-9]|v3.[5-9].*|3.[5-9].*|v[4-9].*|[4-9].*) return 0 ;;
    *) return 1 ;;
  esac
}

exclusive_mask_block() {
  if telemt_release_supports_exclusive_mask; then
    printf '\n[censorship.exclusive_mask]\n"%s" = "127.0.0.1:8443"\n' "$PUBLIC_HOST"
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
TELEMT_SHA256_X86_64='$TELEMT_SHA256_X86_64'
TELEMT_SHA256_AARCH64='$TELEMT_SHA256_AARCH64'
ACME_SH_VERSION='$ACME_SH_VERSION'
ACME_SH_SHA256='$ACME_SH_SHA256'
TELEMT_SECRET='$TELEMT_SECRET'
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
  expected_sha=""
  mkdir -p "$tmp_dir"

  case "$asset" in
    telemt-x86_64-linux-musl.tar.gz) expected_sha="$TELEMT_SHA256_X86_64" ;;
    telemt-aarch64-linux-musl.tar.gz) expected_sha="$TELEMT_SHA256_AARCH64" ;;
  esac

  if [ "$TELEMT_RELEASE" = "latest" ]; then
    base_url="https://github.com/telemt/telemt/releases/latest/download"
  else
    base_url="https://github.com/telemt/telemt/releases/download/$TELEMT_RELEASE"
  fi
  url="$base_url/$asset"

  echo "download=$url"
  curl -fsSL "$url" -o "$tmp_dir/$asset"
  if [ -n "$expected_sha" ]; then
    printf '%s  %s\n' "$expected_sha" "$asset" > "$tmp_dir/$asset.sha256"
  else
    curl -fsSL "$base_url/$asset.sha256" -o "$tmp_dir/$asset.sha256"
  fi
  (cd "$tmp_dir" && sha256sum -c "$asset.sha256") || die "Telemt sha256 check failed."

  tar -xzf "$tmp_dir/$asset" -C "$tmp_dir"
  bin_path="$(find "$tmp_dir" -type f -name telemt | head -n 1)"
  [ -n "$bin_path" ] || die "Telemt binary not found in release archive."

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
  mask_site_started_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  cat > "$TELEMT_HOME/www/index.html" <<EOF
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
  cat > "$TELEMT_HOME/telemt.toml" <<EOF
show_link = []

[general]
fast_mode = true
use_middle_proxy = false
config_strict = true

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

  cat > "$TELEMT_HOME/bin/renew-cert.sh" <<EOF
#!/bin/sh
set -eu
"$ACME_HOME/acme.sh" --home "$ACME_HOME" --cron --server letsencrypt
EOF
  chmod 700 "$TELEMT_HOME/bin/renew-cert.sh"

  mkdir -p /var/spool/cron/crontabs
  touch /var/spool/cron/crontabs/root
  grep -Fq "$TELEMT_HOME/bin/renew-cert.sh" /var/spool/cron/crontabs/root 2>/dev/null || \
    echo "17 3 * * * $TELEMT_HOME/bin/renew-cert.sh >/dev/null 2>&1" >> /var/spool/cron/crontabs/root
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


toml_value_from_section() {
  file="$1"
  section="$2"
  key="$3"
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

infer_update_config_from_existing_files() {
  if [ -f "$TELEMT_HOME/telemt.toml" ]; then
    existing_domain="$(toml_value_from_section "$TELEMT_HOME/telemt.toml" "general\\.links" "public_host" || true)"
    if [ -z "$existing_domain" ]; then
      existing_domain="$(toml_value_from_section "$TELEMT_HOME/telemt.toml" "censorship" "tls_domain" || true)"
    fi
    [ -n "$existing_domain" ] && PUBLIC_HOST="${PUBLIC_HOST:-$existing_domain}"
  fi
  if [ -n "$PUBLIC_HOST" ]; then
    normalize_public_host
  fi
}

backup_update_state() {
  backup_dir="$TELEMT_HOME/update-backups/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$backup_dir"
  for path in "$TELEMT_HOME/telemt.toml" "$TELEMT_HOME/telemt-secret.env" "$TELEMT_HOME/nginx/nginx.conf" "$RESUME_CONFIG" /root/telemt-proxy-link.txt; do
    if [ -e "$path" ]; then
      cp -a "$path" "$backup_dir"/
    fi
  done
  chmod -R go-rwx "$backup_dir" 2>/dev/null || true
  echo "Update backup: $backup_dir"
}

run_update_mode() {
  [ -d "$TELEMT_HOME" ] || die "Telemt home not found: $TELEMT_HOME"
  [ -f "$TELEMT_HOME/telemt.toml" ] || die "Telemt config not found: $TELEMT_HOME/telemt.toml"
  infer_update_config_from_existing_files
  [ -n "$PUBLIC_HOST" ] || die "Cannot detect domain from existing Telemt config."
  detect_public_ip

  cat <<EOF

Update plan:
  domain:        ${PUBLIC_HOST}
  public IPv4:   ${PUBLIC_IP}
  release:       ${TELEMT_RELEASE}
  Telemt config: preserved without rewrite
  secrets/users: preserved
  nginx/ACME:    preserved

Type y or yes to update:
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

  backup_update_state
  stop_services
  download_telemt
  write_restart_script
  configure_acme_renewal_hooks
  "$TELEMT_HOME/bin/restart.sh"
  sleep 8
  write_proxy_link || true
  persist_tinycore_files
  telemt-report 2m || true
  echo
  echo "Update done. Existing config and secrets were preserved."
  if [ -s /root/telemt-proxy-link.txt ]; then
    echo "Proxy link:"
    cat /root/telemt-proxy-link.txt
  fi
}

parse_args "$@"
REQUESTED_TELEMT_RELEASE="$TELEMT_RELEASE"

require_tinycore

if [ "${RESET_INSTALL_STATE:-0}" = "1" ]; then
  rm -f "$STATE_FILE" "$RESUME_CONFIG"
fi

if [ -f "$RESUME_CONFIG" ]; then
  # shellcheck disable=SC1090
  . "$RESUME_CONFIG"
  echo "Resume config found: $RESUME_CONFIG"
fi
if [ "$TELEMT_RELEASE_FROM_ENV" = "1" ]; then
  TELEMT_RELEASE="$REQUESTED_TELEMT_RELEASE"
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

if is_ru; then
  prompt_value_assume "Домен прокси" "$PUBLIC_HOST"
else
  prompt_value_assume "Proxy domain" "$PUBLIC_HOST"
fi
PUBLIC_HOST="$REPLY"
normalize_public_host
valid_domain "$PUBLIC_HOST" || die "Domain must be a valid DNS name, for example proxy.example.com."

LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-admin@$PUBLIC_HOST}"
if is_ru; then
  prompt_value_assume "Email для Let's Encrypt" "$LETSENCRYPT_EMAIL"
else
  prompt_value_assume "Let's Encrypt email" "$LETSENCRYPT_EMAIL"
fi
LETSENCRYPT_EMAIL="$REPLY"
normalize_letsencrypt_email

if is_ru; then
  prompt_value_assume "SSH-порт, Enter оставляет текущий/по умолчанию. Tiny Core установщик не меняет SSH config" "$SSH_PORT"
else
  prompt_value_assume "SSH port, Enter keeps current/default. Tiny Core installer does not change SSH config" "$SSH_PORT"
fi
SSH_PORT="$REPLY"

if is_ru; then
  prompt_value_assume "Максимум подключений Telemt" "$TELEMT_MAX_TCP_CONNS"
else
  prompt_value_assume "Max Telemt connections" "$TELEMT_MAX_TCP_CONNS"
fi
TELEMT_MAX_TCP_CONNS="$REPLY"

printf '%s\n' "$LETSENCRYPT_EMAIL" | grep -Eq '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' || die "Email must be a plain email address."
valid_port "$SSH_PORT" || die "SSH port must be a number from 1 to 65535."
valid_limit "$TELEMT_MAX_TCP_CONNS" || die "Connection limit must be a number from 1 to 1000000."

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

Type y or yes to continue:
EOF
if [ "$ASSUME_YES" = "1" ]; then
  echo "ASSUME_YES=1, continuing."
else
  read -r confirm
  case "$confirm" in
    y|Y|yes|YES|Yes|д|Д|да|ДА|Да) ;;
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
