#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

SCRIPT_VERSION="2026-08-25"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ANALYTICS_ASSET_DIR="$SCRIPT_DIR/analytics"
TPROXY_COMMIT="52a5feb7fac38f68da5afef9cedd9b3bfc8473ca"
TPROXY_ARCHIVE_SHA256="2c56987035c7f0b9a3d40907fe9ff8889fd41d1a6dcb7bdd6e0de7784c442bfe"

DOMAIN="${DOMAIN:-}"
EMAIL="${EMAIL:-}"
WEBPROXY_SECRET="${WEBPROXY_SECRET:-}"
IPINFO_TOKEN="${IPINFO_TOKEN:-}"
SITE_DIR="${SITE_DIR:-}"
MTPROXY_WORKERS="${MTPROXY_WORKERS:-1}"
MTPROXY_MAX_CONNECTIONS="${MTPROXY_MAX_CONNECTIONS:-4096}"
AUTO_MODE=0
DRY_RUN=0
ANALYTICS_ONLY=0

say() { printf '%s\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
WEB proxy only installer $SCRIPT_VERSION

Использование:
  sudo ./install.sh --auto
  sudo ./install.sh --auto --domain proxy.example.com

Параметры:
  --domain DOMAIN               Публичный домен WEB proxy.
  --email EMAIL                 Default: admin@DOMAIN.
  --secret HEX                  32 hex или dd + 32 hex; default: generate.
  --ipinfo-token TOKEN          Токен IPinfo для стран, городов и ASN; optional.
  --site-dir DIR                Свой публичный сайт; default: simple local site.
  --mtproxy-workers N           Default: 1.
  --mtproxy-max-connections N   Default: 4096.
  --auto                        Использовать значения по умолчанию.
  --dry-run                     Только показать план.
  --analytics-only              Добавить/обновить аналитику существующей установки.
  -h, --help                    Справка.
EOF
}

need_value() {
  [ "$#" -ge 2 ] && [ -n "$2" ] || die "Для $1 требуется значение."
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --domain) need_value "$@"; DOMAIN="$2"; shift 2 ;;
      --email) need_value "$@"; EMAIL="$2"; shift 2 ;;
      --secret) need_value "$@"; WEBPROXY_SECRET="$2"; shift 2 ;;
      --ipinfo-token) need_value "$@"; IPINFO_TOKEN="$2"; shift 2 ;;
      --site-dir) need_value "$@"; SITE_DIR="$2"; shift 2 ;;
      --mtproxy-workers) need_value "$@"; MTPROXY_WORKERS="$2"; shift 2 ;;
      --mtproxy-max-connections) need_value "$@"; MTPROXY_MAX_CONNECTIONS="$2"; shift 2 ;;
      --auto|-y|--yes) AUTO_MODE=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --analytics-only) ANALYTICS_ONLY=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done
}

need_root() {
  [ "${EUID:-$(id -u)}" -eq 0 ] || die "Запустите от root."
}

require_supported_os() {
  local os_id version_id major pretty
  [ -r /etc/os-release ] || die "Не найден /etc/os-release."
  # shellcheck disable=SC1091
  source /etc/os-release
  os_id="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
  version_id="${VERSION_ID:-}"
  major="${version_id%%.*}"
  pretty="${PRETTY_NAME:-$os_id $version_id}"
  [[ "$major" =~ ^[0-9]+$ ]] || die "Не удалось определить версию ОС: $pretty"
  case "$os_id" in
    debian)
      [ "$major" -ge 12 ] && [ "$major" -le 13 ] || \
        die "Используйте Debian 12 или 13. Обнаружено: $pretty"
      ;;
    ubuntu)
      [ "$major" -ge 22 ] && [ "$major" -le 26 ] || \
        die "Используйте Ubuntu 22.04–26.x. Обнаружено: $pretty"
      ;;
    *) die "Поддерживаются Debian 12/13 и Ubuntu 22.04–26.x. Обнаружено: $pretty" ;;
  esac
  [ "$(uname -m)" = "x86_64" ] || die "Официальный MTProxy требует x86_64."
  have systemctl || die "Требуется systemd."
}

collect_inputs() {
  if [ -z "$DOMAIN" ]; then
    [ -t 0 ] || die "Укажите --domain proxy.example.com."
    read -r -p "Домен WEB proxy: " DOMAIN
  fi
  DOMAIN="$(printf '%s' "${DOMAIN%.}" | tr '[:upper:]' '[:lower:]')"
  [[ "$DOMAIN" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] || \
    die "Неверный домен: $DOMAIN"
  EMAIL="${EMAIL:-admin@$DOMAIN}"
  [[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || \
    die "Неверный email: $EMAIL"

  if [ -z "$WEBPROXY_SECRET" ]; then
    WEBPROXY_SECRET="$(openssl rand -hex 16 2>/dev/null || true)"
  fi
  WEBPROXY_SECRET="$(printf '%s' "$WEBPROXY_SECRET" | tr 'A-F' 'a-f')"
  [[ "$WEBPROXY_SECRET" =~ ^([0-9a-f]{32}|dd[0-9a-f]{32})$ ]] || \
    die "WEB secret должен быть 32 hex, необязательно с префиксом dd."
  [[ "$MTPROXY_WORKERS" =~ ^[1-9][0-9]*$ ]] && [ "$MTPROXY_WORKERS" -le 256 ] || \
    die "Workers должны быть от 1 до 256."
  [[ "$MTPROXY_MAX_CONNECTIONS" =~ ^[1-9][0-9]*$ ]] || \
    die "Max connections должен быть положительным числом."
  if [ -n "$SITE_DIR" ]; then
    [ -r "$SITE_DIR/index.html" ] || die "$SITE_DIR должен содержать читаемый index.html."
    SITE_DIR="$(cd "$SITE_DIR" && pwd -P)"
  fi
}

collect_ipinfo_token() {
  local existing=/etc/webproxy-analytics/ipinfo.token answer=""
  if [ -z "$IPINFO_TOKEN" ] && [ -s "$existing" ]; then
    IPINFO_TOKEN="$(tr -d '\r\n' < "$existing")"
    return
  fi
  if [ -z "$IPINFO_TOKEN" ] && [ -t 0 ]; then
    printf '\nIPinfo token нужен для стран, городов и ASN.\n'
    printf 'Получить токен: https://ipinfo.io/account/token\n'
    printf 'Регистрация:      https://ipinfo.io/signup\n'
    printf 'IPinfo token (Enter — аналитика без географии): '
    read -r answer || true
    IPINFO_TOKEN="$answer"
  fi
  if [ -n "$IPINFO_TOKEN" ] && ! [[ "$IPINFO_TOKEN" =~ ^[A-Za-z0-9._-]{8,256}$ ]]; then
    die "Токен IPinfo содержит недопустимые символы или слишком короткий."
  fi
}

configure_ipinfo_token() {
  install -d -o root -g root -m 0700 /etc/webproxy-analytics
  printf '%s' "$IPINFO_TOKEN" > /etc/webproxy-analytics/ipinfo.token
  chown root:root /etc/webproxy-analytics/ipinfo.token
  chmod 0600 /etc/webproxy-analytics/ipinfo.token
  if [ -n "$IPINFO_TOKEN" ]; then
    say "IPinfo: включены страны, города и ASN; токен сохранён только на сервере."
  else
    say "IPinfo: токен не указан; аналитика работает без стран и городов."
  fi
}

install_bootstrap_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl openssl tar gzip iproute2 libc-bin \
    nginx certbot nftables apache2-utils python3
}

check_clean_server() {
  [ ! -e /etc/tproxy-server/config.json ] || \
    die "Найдена существующая установка tproxy-server. Этот preview предназначен для чистого сервера."
  [ ! -e /etc/nginx/nginx.conf ] || \
    die "Найдена существующая установка nginx. Этот preview предназначен для чистого сервера."
  local listeners
  listeners="$(ss -H -ltn 2>/dev/null | awk '$4 ~ /(^|\]|:)(80|443)$/ {print}' || true)"
  [ -z "$listeners" ] || {
    printf '%s\n' "$listeners" >&2
    die "Порты 80/443 заняты. Для WEB proxy only нужен чистый сервер."
  }
}

check_dns() {
  local public_ip addresses local_addresses matched=0 address
  public_ip="$(curl -4fsS --max-time 10 https://api.ipify.org 2>/dev/null || true)"
  addresses="$(getent ahostsv4 "$DOMAIN" 2>/dev/null | awk '{print $1}' | sort -u || true)"
  [ -n "$addresses" ] || die "DNS A для $DOMAIN не найден."
  local_addresses="$(ip -o -4 addr show scope global 2>/dev/null | awk '{sub(/\/.*/,"",$4); print $4}' | sort -u || true)"
  while IFS= read -r address; do
    [ -n "$address" ] || continue
    if printf '%s\n%s\n' "$local_addresses" "$public_ip" | grep -Fxq "$address"; then
      matched=1
      break
    fi
  done <<< "$addresses"
  if [ "$matched" -ne 1 ]; then
    say "DNS A:"
    printf '  %s\n' $addresses
    say "WARN: DNS A не совпал с локальными/исходящим IPv4. Установка продолжится: VPN/NAT и маршруты не изменяются."
  fi
}

print_plan() {
  cat <<EOF

План WEB proxy only:
  domain:               $DOMAIN
  email:                $EMAIL
  TLS frontend:         nginx + certbot
  relay:                tproxy-server @$TPROXY_COMMIT
  backend:              official Telegram MTProxy
  workers/connections:  $MTPROXY_WORKERS / $MTPROXY_MAX_CONNECTIONS
  public ports:         80/tcp, 443/tcp
  SSH/VPN/routes:       не изменяются
  public site:          ${SITE_DIR:-generated local site}
EOF
}

download_source() {
  local destination archive actual
  destination="$1"
  archive="$destination/tproxy-server.tar.gz"
  curl --fail --silent --show-error --location \
    --proto '=https' --proto-redir '=https' --tlsv1.2 \
    --output "$archive" \
    "https://github.com/telegramdesktop/tproxy-server/archive/${TPROXY_COMMIT}.tar.gz"
  actual="$(sha256sum "$archive" | awk '{print $1}')"
  [ "$actual" = "$TPROXY_ARCHIVE_SHA256" ] || die "Неверная SHA256 tproxy-server."
  tar -C "$destination" -xzf "$archive"
  printf '%s' "$destination/tproxy-server-$TPROXY_COMMIT"
}

patch_upstream_installer() {
  local repository="$1" installer mtproxy_installer mtproxy_service
  installer="$repository/deploy/install.sh"
  mtproxy_installer="$repository/deploy/install-mtproxy.sh"
  mtproxy_service="$repository/deploy/mtproxy.service"

  grep -Fq '(cd "$repository" && "$go_binary" test ./...)' "$installer" || \
    die "Не найден ожидаемый Go test block в upstream installer."
  sed -i.bak 's#(cd "$repository" && "$go_binary" test ./...)#(umask 022; cd "$repository" \&\& "$go_binary" test ./...)#' "$installer"
  sed -i.bak 's#(cd "$repository" && "$go_binary" build -trimpath#(umask 022; cd "$repository" \&\& "$go_binary" build -trimpath#' "$installer"

  grep -Fq 'chown -R root:root "$build_directory"' "$mtproxy_installer" || \
    die "Не найден ожидаемый MTProxy permission block."
  sed -i.bak '/chown -R root:root "$build_directory"/a\
        chmod 0755 "$build_directory" "$build_directory/objs" "$build_directory/objs/bin" "$build_directory/objs/bin/mtproto-proxy"' \
    "$mtproxy_installer"

  grep -Fq 'ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy' "$mtproxy_service" || \
    die "Не найден ожидаемый ExecStart официального MTProxy."
  sed -i.bak 's#^ExecStart=/opt/MTProxy/objs/bin/mtproto-proxy.*#ExecStart=/usr/local/sbin/run-webproxy-mtproxy#' \
    "$mtproxy_service"

  # The pinned upstream installer uses Caddy. Keep its relay/MTProxy setup, but
  # remove only Caddy installation, validation and service management. nginx and
  # certbot are configured by this wrapper after the relay is healthy.
  sed -i.bak '/^caddy_version=2\.11\.4$/,/^install -d -o caddy -g caddy -m 0750 \/var\/lib\/caddy$/d' \
    "$installer"
  sed -i.bak '/^install -m 0644 "$repository\/deploy\/Caddyfile" \/etc\/caddy\/Caddyfile\.tproxy$/,/^install -m 0644 "$repository\/deploy\/tproxy-server\.service"/c\
install -m 0644 "$repository/deploy/tproxy-server.service" /etc/systemd/system/tproxy-server.service' \
    "$installer"
  sed -i.bak '/^TPROXY_HOSTNAME=.*ACME_EMAIL=/d; /\/usr\/local\/bin\/caddy validate/d' \
    "$installer"
  sed -i.bak '/^systemctl enable --now caddy\.service$/d; /^systemctl restart caddy\.service$/d' \
    "$installer"
  sed -i.bak 's/status caddy mtproxy tproxy-server/status nginx mtproxy tproxy-server/' "$installer"
  rm -f "$installer.bak" "$mtproxy_installer.bak" "$mtproxy_service.bak"

  grep -Fq '(umask 022; cd "$repository" && "$go_binary" test ./...)' "$installer" || \
    die "Не удалось применить безопасный umask для Go tests."
  grep -Fq 'chmod 0755 "$build_directory"' "$mtproxy_installer" || \
    die "Не удалось применить permissions fix для MTProxy."
  grep -Fq 'ExecStart=/usr/local/sbin/run-webproxy-mtproxy' "$mtproxy_service" || \
    die "Не удалось включить NAT-aware MTProxy runner."
  ! grep -Fq 'caddy_version=' "$installer" || die "Не удалось удалить установку Caddy."
  ! grep -Fq '/usr/local/bin/caddy' "$installer" || die "В upstream installer остался вызов Caddy."
  bash -n "$installer"
  bash -n "$mtproxy_installer"
}

write_mtproxy_runner() {
  cat > /usr/local/sbin/run-webproxy-mtproxy <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
args=(
  /opt/MTProxy/objs/bin/mtproto-proxy
  -u mtproxy
  -p 8888
  -H 2398
)
secrets=()
if [ -r /etc/mtproxy/webproxy-secrets ]; then
  while IFS= read -r secret; do
    [[ "$secret" =~ ^[0-9a-f]{32}$ ]] && secrets+=("$secret")
  done < /etc/mtproxy/webproxy-secrets
fi
if [ "${#secrets[@]}" -eq 0 ] && [[ "${MTPROXY_SECRET:-}" =~ ^[0-9a-f]{32}$ ]]; then
  secrets+=("$MTPROXY_SECRET")
fi
[ "${#secrets[@]}" -gt 0 ] || { echo "No valid MTProxy secrets configured" >&2; exit 1; }
for secret in "${secrets[@]}"; do args+=(-S "$secret"); done
args+=(
  --aes-pwd /etc/mtproxy/proxy-secret /etc/mtproxy/proxy-multi.conf
  -M "${MTPROXY_WORKERS:-1}"
  -C "${MTPROXY_MAX_CONNECTIONS:-4096}"
)
route_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++)if($i=="src"){print $(i+1);exit}}' || true)"
external_ip="$(curl -4fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
if [[ "$route_ip" =~ ^[0-9.]+$ ]] && [[ "$external_ip" =~ ^[0-9.]+$ ]] && [ "$route_ip" != "$external_ip" ]; then
  args+=(--nat-info "$route_ip:$external_ip")
fi
exec "${args[@]}"
EOF
  chmod 0755 /usr/local/sbin/run-webproxy-mtproxy
}

write_webproxy_cli() {
  cat > /usr/local/sbin/webproxy_cli <<'PY'
#!/usr/bin/env python3
import fcntl
import grp
import json
import os
import re
import secrets
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
from datetime import datetime
from pathlib import Path

CONFIG = Path("/etc/tproxy-server/config.json")
PROFILES = Path("/etc/tproxy-server/profiles.json")
SECRETS = Path("/etc/mtproxy/webproxy-secrets")
LINKS = Path("/root/webproxy-users.txt")
LEGACY_LINKS = Path("/root/webproxy-only-links.txt")
SUMMARY = Path("/root/webproxy-install-summary.txt")
ANALYTICS_CREDENTIALS = Path("/root/webproxy-analytics-credentials.txt")
IPINFO_TOKEN_FILE = Path("/etc/webproxy-analytics/ipinfo.token")
BACKUPS = Path("/etc/tproxy-server/backups")
LOCK = Path("/run/lock/webproxy-cli.lock")
NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")


def fail(message, code=1):
    print(f"ОШИБКА: {message}", file=sys.stderr)
    raise SystemExit(code)


def require_root():
    if os.geteuid() != 0:
        fail("запустите webproxy_cli от root")
    for path in (CONFIG, PROFILES):
        if not path.is_file():
            fail(f"не найден файл {path}")


def load():
    try:
        config = json.loads(CONFIG.read_text())
        source = json.loads(PROFILES.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"не удалось прочитать конфигурацию: {exc}")
    profiles = source.get("profiles")
    if not isinstance(profiles, list) or not profiles:
        fail("profiles.json не содержит пользователей")
    domain = config.get("public_hostname", "")
    if not isinstance(domain, str) or not domain:
        fail("не удалось определить домен")
    maximum = config.get("limits", {}).get("max_profiles", 32)
    return config, profiles, domain, int(maximum)


def base_secret(value):
    value = str(value).lower()
    if re.fullmatch(r"dd[0-9a-f]{32}", value):
        return value[2:]
    if re.fullmatch(r"[0-9a-f]{32}", value):
        return value
    fail("обнаружен секрет, который нельзя передать официальному MTProxy")


def links_text(profiles, domain):
    blocks = []
    for profile in profiles:
        name, secret = profile["name"], profile["secret"]
        blocks.append(f"# user: {name}\nhttps://t.me/webproxy?server={domain}&secret={secret}\n"
                      f"tg://webproxy?server={domain}&secret={secret}\n")
    return "\n".join(blocks)


def write_private(path, content, mode=0o600, group=None):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        if group is not None:
            os.chown(temporary, 0, grp.getgrnam(group).gr_gid)
        os.replace(temporary, path)
    finally:
        try: os.unlink(temporary)
        except FileNotFoundError: pass


def sync_auxiliary(profiles, domain):
    secret_lines = "".join(base_secret(profile["secret"]) + "\n" for profile in profiles)
    write_private(SECRETS, secret_lines, 0o640, "mtproxy")
    text = links_text(profiles, domain)
    write_private(LINKS, text)
    write_private(LEGACY_LINKS, text)
    if ANALYTICS_CREDENTIALS.is_file():
        analytics = ANALYTICS_CREDENTIALS.read_text().strip()
    else:
        analytics = "Analytics credentials will be added after installation completes."
    try:
        geo_status = "enabled" if IPINFO_TOKEN_FILE.read_text().strip() else "disabled (token not provided)"
    except OSError:
        geo_status = "disabled (token not provided)"
    summary = f"""WEB PROXY INSTALLATION SUMMARY
Updated: {datetime.now().astimezone().isoformat(timespec='seconds')}
Domain: {domain}

PUBLIC WEBSITE
https://{domain}/

WEB PROXY USERS AND LINKS
{text.rstrip()}

ANALYTICS
{analytics}

IPINFO GEOLOCATION
status={geo_status}
token_file=/etc/webproxy-analytics/ipinfo.token

USER MANAGEMENT
webproxy_cli -add USER
webproxy_cli -list
webproxy_cli -del USER       # confirmation required
webproxy_cli -delete USER    # delete without confirmation

IMPORTANT FILES
/root/webproxy-install-summary.txt
/root/webproxy-users.txt
/root/webproxy-analytics-credentials.txt
/etc/webproxy-analytics/ipinfo.token
/root/.webproxy-only.config
"""
    write_private(SUMMARY, summary)


def validate_candidate(path):
    result = subprocess.run(["/usr/local/bin/tproxy-server", "-config", str(CONFIG),
                             "-profiles-file", str(path), "-check"], text=True, capture_output=True)
    if result.returncode:
        fail("проверка новой конфигурации не прошла: " + (result.stderr or result.stdout).strip())


def service_ready():
    for _ in range(20):
        active = subprocess.run(["systemctl", "is-active", "--quiet", "mtproxy.service",
                                 "tproxy-server.service"]).returncode == 0
        if active:
            try:
                with urllib.request.urlopen("http://127.0.0.1:8081/readyz", timeout=2) as response:
                    if response.status == 200:
                        return True
            except Exception:
                pass
        time.sleep(1)
    return False


def restart_services():
    subprocess.run(["systemctl", "restart", "mtproxy.service"], check=True)
    subprocess.run(["systemctl", "restart", "tproxy-server.service"], check=True)
    if not service_ready():
        raise RuntimeError("службы не стали готовы после изменения")


def apply(profiles, domain):
    BACKUPS.mkdir(parents=True, exist_ok=True)
    os.chmod(BACKUPS, 0o700)
    stamp = datetime.now().strftime("%Y%m%d-%H%M%S-%f")
    profile_backup = BACKUPS / f"profiles.{stamp}.json"
    secrets_backup = BACKUPS / f"mtproxy-secrets.{stamp}"
    shutil.copy2(PROFILES, profile_backup)
    if SECRETS.exists():
        shutil.copy2(SECRETS, secrets_backup)
    candidate_fd, candidate_name = tempfile.mkstemp(prefix="profiles.candidate.", dir=PROFILES.parent)
    candidate = Path(candidate_name)
    try:
        with os.fdopen(candidate_fd, "w") as stream:
            json.dump({"profiles": profiles}, stream, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(candidate, 0o400)
        os.chown(candidate, 0, grp.getgrnam("tproxy").gr_gid)
        validate_candidate(candidate)
        os.replace(candidate, PROFILES)
        sync_auxiliary(profiles, domain)
        try:
            restart_services()
        except Exception as exc:
            shutil.copy2(profile_backup, PROFILES)
            os.chown(PROFILES, 0, grp.getgrnam("tproxy").gr_gid)
            os.chmod(PROFILES, 0o400)
            if secrets_backup.exists():
                shutil.copy2(secrets_backup, SECRETS)
                os.chown(SECRETS, 0, grp.getgrnam("mtproxy").gr_gid)
                os.chmod(SECRETS, 0o640)
            old_profiles = json.loads(PROFILES.read_text())["profiles"]
            sync_auxiliary(old_profiles, domain)
            try: restart_services()
            except Exception: pass
            fail(f"изменение отменено, восстановлена резервная копия: {exc}")
    finally:
        try: candidate.unlink()
        except FileNotFoundError: pass


def validate_name(name):
    if not NAME_RE.fullmatch(name):
        fail("имя должно содержать 1–64 символа: A-Z, a-z, 0-9, _, . или -")


def show(profiles, domain):
    print(f"{'USER':<24} LINK")
    for profile in profiles:
        link = f"https://t.me/webproxy?server={domain}&secret={profile['secret']}"
        print(f"{profile['name']:<24} {link}")
    print(f"\nВсего пользователей: {len(profiles)}")


def usage():
    print("""Использование:
  webproxy_cli -add USER       создать пользователя
  webproxy_cli -list           показать пользователей и ссылки
  webproxy_cli -del USER       удалить с подтверждением
  webproxy_cli -delete USER    удалить без подтверждения
""")


def main():
    require_root()
    LOCK.parent.mkdir(parents=True, exist_ok=True)
    with LOCK.open("w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        _, profiles, domain, maximum = load()
        args = sys.argv[1:]
        if args == ["--sync-internal"]:
            sync_auxiliary(profiles, domain)
            return
        if not args or args[0] in ("-h", "--help", "help"):
            usage(); return
        command = args[0]
        if command in ("-list", "--list", "list"):
            if len(args) != 1: fail("для -list не нужны дополнительные параметры", 2)
            show(profiles, domain); return
        if command in ("-add", "--add", "add"):
            if len(args) != 2: fail("использование: webproxy_cli -add USER", 2)
            name = args[1]; validate_name(name)
            if any(profile.get("name") == name for profile in profiles):
                fail(f"пользователь {name} уже существует")
            if len(profiles) >= maximum:
                fail(f"достигнут лимит пользователей: {maximum}")
            used = {str(profile.get("secret", "")).lower() for profile in profiles}
            secret = secrets.token_hex(16)
            while secret in used: secret = secrets.token_hex(16)
            profiles.append({"name": name, "secret": secret, "backend": "127.0.0.1:2398", "carrier_mode": "https"})
            apply(profiles, domain)
            print(f"Пользователь создан: {name}")
            print(f"https://t.me/webproxy?server={domain}&secret={secret}")
            print(f"tg://webproxy?server={domain}&secret={secret}")
            return
        if command in ("-del", "--del", "del", "-delete", "--delete", "delete"):
            if len(args) != 2: fail("использование: webproxy_cli -del USER", 2)
            name = args[1]; validate_name(name)
            if not any(profile.get("name") == name for profile in profiles):
                fail(f"пользователь {name} не найден")
            if len(profiles) == 1:
                fail("нельзя удалить последнего пользователя")
            if command in ("-del", "--del", "del"):
                try:
                    answer = input(f"Удалить пользователя {name}? [y/N]: ").strip().lower()
                except EOFError:
                    answer = ""
                if answer not in ("y", "yes", "д", "да"):
                    print("Удаление отменено."); return
            profiles = [profile for profile in profiles if profile.get("name") != name]
            apply(profiles, domain)
            print(f"Пользователь удалён: {name}")
            return
        fail(f"неизвестная команда: {command}", 2)


if __name__ == "__main__":
    main()
PY
  chmod 0755 /usr/local/sbin/webproxy_cli
}

setup_webproxy_cli() {
  write_mtproxy_runner
  write_webproxy_cli
  /usr/local/sbin/webproxy_cli --sync-internal
  systemctl restart mtproxy.service
  systemctl is-active --quiet mtproxy.service || die "MTProxy не запустился после включения webproxy_cli."
}

write_default_site() {
  local directory="$1"
  install -d -m 0755 "$directory"
  cat > "$directory/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <meta name="theme-color" content="#07111f">
  <title>Netnum · Digital infrastructure</title>
  <style>
    :root{color-scheme:dark;--ink:#eef6ff;--muted:#91a5ba;--line:rgba(255,255,255,.12);--a:#58d5ff;--b:#8f73ff}
    *{box-sizing:border-box}html,body{min-height:100%;margin:0}body{overflow:hidden;background:#050b14;color:var(--ink);font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
    body:before,body:after{content:"";position:fixed;border-radius:50%;filter:blur(10px);opacity:.65;pointer-events:none}
    body:before{width:48rem;height:48rem;right:-17rem;top:-22rem;background:radial-gradient(circle,var(--b),transparent 67%)}
    body:after{width:42rem;height:42rem;left:-20rem;bottom:-22rem;background:radial-gradient(circle,#087ea4,transparent 69%)}
    .grid{position:fixed;inset:0;background-image:linear-gradient(var(--line) 1px,transparent 1px),linear-gradient(90deg,var(--line) 1px,transparent 1px);background-size:64px 64px;mask-image:linear-gradient(to bottom,rgba(0,0,0,.42),transparent 82%);opacity:.28}
    main{position:relative;z-index:1;min-height:100vh;display:flex;flex-direction:column;max-width:1280px;margin:auto;padding:34px clamp(24px,5vw,72px)}
    nav{display:flex;justify-content:space-between;align-items:center}.brand{font-size:14px;font-weight:800;letter-spacing:.22em;text-transform:uppercase}.status{display:flex;align-items:center;gap:9px;color:var(--muted);font-size:13px}.status i{width:8px;height:8px;border-radius:50%;background:#52e3a4;box-shadow:0 0 17px #52e3a4}
    .hero{margin:auto 0;padding:70px 0;display:grid;grid-template-columns:minmax(0,1fr) 330px;align-items:center;gap:clamp(44px,7vw,100px)}.copy{min-width:0}.eyebrow{color:var(--a);font-size:12px;font-weight:800;letter-spacing:.2em;text-transform:uppercase}.hero h1{max-width:850px;margin:22px 0;font-size:clamp(48px,7vw,96px);font-weight:750;line-height:.94;letter-spacing:-.055em}.hero h1 span{background:linear-gradient(100deg,var(--a),#bcb0ff);-webkit-background-clip:text;background-clip:text;color:transparent}.hero p{max-width:650px;margin:0;color:var(--muted);font-size:clamp(17px,2vw,21px);line-height:1.65}
    .machine-scene{position:relative;width:320px;height:320px;display:grid;place-items:center;filter:drop-shadow(0 26px 60px rgba(15,7,55,.5));animation:float 5s ease-in-out infinite}.machine-scene:before{content:"";position:absolute;inset:20px;border-radius:50%;background:radial-gradient(circle,rgba(88,213,255,.15),rgba(143,115,255,.07) 48%,transparent 70%);filter:blur(8px);animation:pulse 4s ease-in-out infinite}.machine{position:relative;width:240px;height:240px;border:13px solid rgba(188,176,255,.34);border-radius:50%;box-shadow:inset 0 0 35px rgba(88,213,255,.08),0 0 45px rgba(143,115,255,.14)}.machine:before{content:"";position:absolute;inset:42px;border:13px solid rgba(88,213,255,.48);border-left-color:transparent;border-bottom-color:rgba(188,176,255,.18);border-radius:50%;animation:spin 12s linear infinite}.machine:after{content:"";position:absolute;width:170px;height:92px;right:-54px;bottom:8px;border:13px solid rgba(188,176,255,.38);border-radius:18px;background:linear-gradient(rgba(88,213,255,.52),rgba(88,213,255,.52)) 24px 24px/118px 10px no-repeat,linear-gradient(rgba(188,176,255,.48),rgba(188,176,255,.48)) 24px 52px/82px 10px no-repeat,rgba(8,14,29,.9);box-shadow:0 18px 45px rgba(0,0,0,.35)}
    @keyframes spin{to{transform:rotate(360deg)}}@keyframes float{0%,100%{transform:translateY(-8px)}50%{transform:translateY(10px)}}@keyframes pulse{0%,100%{opacity:.65;transform:scale(.96)}50%{opacity:1;transform:scale(1.06)}}
    footer{display:flex;justify-content:space-between;gap:24px;padding-top:24px;border-top:1px solid var(--line);color:#6f8499;font-size:12px;letter-spacing:.08em;text-transform:uppercase}
    @media(max-width:900px){.hero{grid-template-columns:1fr}.machine-scene{display:none}}@media(max-width:620px){main{padding:24px}.hero{padding:55px 0}.hero h1{font-size:54px}footer{flex-direction:column}.status span{display:none}}
  </style>
</head>
<body><div class="grid"></div><main>
  <nav><div class="brand">Netnum</div><div class="status"><i></i><span>All systems operational</span></div></nav>
  <section class="hero" aria-label="Network infrastructure status"><div class="copy"><div class="eyebrow">Private digital infrastructure</div><h1>Connectivity<br><span>without borders.</span></h1><p>Reliable network infrastructure for fast and secure connections. Availability, privacy and stability — by default.</p></div><div class="machine-scene" aria-hidden="true"><div class="machine"></div></div></section>
  <footer><span>${DOMAIN}</span><span>Secure edge · Europe</span></footer>
</main></body>
</html>
EOF
  chmod 0644 "$directory/index.html"
}

run_upstream_install() {
  local repository="$1" site="$2"
  printf '%s\n' "$WEBPROXY_SECRET" | \
    "$repository/deploy/install.sh" \
      --hostname "$DOMAIN" \
      --email "$EMAIL" \
      --site-dir "$site" \
      --mtproxy-workers "$MTPROXY_WORKERS" \
      --mtproxy-max-connections "$MTPROXY_MAX_CONNECTIONS"
}

configure_nginx_http() {
  install -d -m 0755 /var/www/webproxy-acme/.well-known/acme-challenge
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/webproxy-only <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/webproxy-acme;
        default_type text/plain;
    }

    location / {
        return 404;
    }

    access_log off;
}
EOF
  ln -sfn /etc/nginx/sites-available/webproxy-only /etc/nginx/sites-enabled/webproxy-only
  nginx -t
  systemctl enable --now nginx
  systemctl reload nginx
}

issue_certificate() {
  certbot certonly --webroot \
    --webroot-path /var/www/webproxy-acme \
    --domain "$DOMAIN" \
    --email "$EMAIL" \
    --non-interactive --agree-tos --keep-until-expiring \
    --preferred-challenges http || \
      die "Certbot не выпустил сертификат. Проверьте DNS и доступность 80/tcp."
}

configure_nginx_https() {
  cat > /etc/nginx/sites-available/webproxy-only <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location ^~ /.well-known/acme-challenge/ {
        root /var/www/webproxy-acme;
        default_type text/plain;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }

    access_log off;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:WEBPROXY:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    access_log off;
    error_log /var/log/nginx/webproxy-only-error.log warn;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Connection "";
        proxy_connect_timeout 5s;
        proxy_send_timeout 60s;
        proxy_read_timeout 40s;
        proxy_request_buffering off;
        proxy_buffering off;
    }
}
EOF
  nginx -t
  systemctl reload nginx
}

configure_certbot_renewal() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-webproxy <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
nginx -t
systemctl reload nginx
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx-webproxy
  systemctl enable --now certbot.timer
  systemctl is-active --quiet certbot.timer || die "certbot.timer не запустился."
}

write_analytics_collector() {
  install -d -m 0755 /usr/local/lib/webproxy-analytics
  if [ -f "$ANALYTICS_ASSET_DIR/collector.py" ]; then
    install -o root -g root -m 0755 "$ANALYTICS_ASSET_DIR/collector.py" \
      /usr/local/lib/webproxy-analytics/collector.py
    return
  fi
  cat > /usr/local/lib/webproxy-analytics/collector.py <<'PY'
#!/usr/bin/env python3
import hashlib
import json
import os
import signal
import sqlite3
import time
import urllib.request
from datetime import datetime, timezone

DB = "/var/lib/webproxy-analytics/analytics.sqlite3"
OUTPUT = "/var/lib/webproxy-analytics/data.json"
LOG = "/var/log/tproxy/access.log"
METRICS = "http://127.0.0.1:8081/metrics"
WINDOWS = {"15m": 900, "1h": 3600, "24h": 86400, "7d": 604800}
ENDPOINTS = {"/api/v1/session", "/api/v1/up", "/api/v1/down", "/api/v1/ws"}
running = True


def stop(*_):
    global running
    running = False


def connect():
    db = sqlite3.connect(DB, timeout=10)
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript("""
      CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);
      CREATE TABLE IF NOT EXISTS seen_events(hash TEXT PRIMARY KEY,occurred INTEGER NOT NULL);
      CREATE TABLE IF NOT EXISTS minute_stats(
        bucket INTEGER NOT NULL,endpoint TEXT NOT NULL,class TEXT NOT NULL,reason TEXT NOT NULL,status INTEGER NOT NULL,
        requests INTEGER NOT NULL DEFAULT 0,request_bytes INTEGER NOT NULL DEFAULT 0,response_bytes INTEGER NOT NULL DEFAULT 0,
        total_ms INTEGER NOT NULL DEFAULT 0,max_ms INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(bucket,endpoint,class,reason,status));
      CREATE TABLE IF NOT EXISTS errors(
        hash TEXT PRIMARY KEY,occurred INTEGER NOT NULL,remote TEXT NOT NULL,endpoint TEXT NOT NULL,method TEXT NOT NULL,
        status INTEGER NOT NULL,reason TEXT NOT NULL,request_bytes INTEGER NOT NULL,response_bytes INTEGER NOT NULL,request_ms INTEGER NOT NULL);
      CREATE INDEX IF NOT EXISTS errors_time ON errors(occurred);
      CREATE TABLE IF NOT EXISTS metrics(
        occurred INTEGER PRIMARY KEY,sessions_live INTEGER,streams_live INTEGER,backend_dials_in_flight INTEGER,
        pending_bytes INTEGER,pending_items INTEGER,sessions_created_total INTEGER,sessions_closed_total INTEGER,
        streams_opened_total INTEGER,streams_rejected_total INTEGER,backend_dial_failures_total INTEGER,
        bytes_up_total INTEGER,bytes_down_total INTEGER,limit_hits_total INTEGER);
    """)
    return db


def classify(endpoint, method, status):
    expected = {
        ("/api/v1/session", "POST"): {200}, ("/api/v1/session", "DELETE"): {204},
        ("/api/v1/up", "POST"): {204}, ("/api/v1/down", "POST"): {200, 204, 499},
        ("/api/v1/ws", "GET"): {101},
    }
    if status in expected.get((endpoint, method), set()):
        if endpoint == "/api/v1/session":
            return "good", "session_created" if method == "POST" else "session_closed"
        if status == 499:
            return "good", "poll_replaced"
        return "good", "request_ok"
    if status == 503:
        return "failed", "capacity_or_backpressure"
    if status == 404:
        return "failed", "rejected_request"
    if status >= 500:
        return "failed", "server_error"
    return "failed", "unexpected_status"


def event_from_line(raw, identity):
    item = json.loads(raw)
    endpoint = str(item.get("endpoint", ""))
    if endpoint not in ENDPOINTS:
        return None
    method = str(item.get("method", ""))[:8]
    status = int(item.get("status", 0))
    stamp = int(datetime.fromisoformat(str(item["time"])).timestamp())
    class_name, reason = classify(endpoint, method, status)
    return {
        "hash": hashlib.sha256((identity + raw.rstrip()).encode()).hexdigest(), "occurred": stamp,
        "bucket": stamp - stamp % 60, "remote": str(item.get("remote_addr") or "unknown")[:45],
        "endpoint": endpoint, "method": method, "status": status, "class": class_name, "reason": reason,
        "request_bytes": max(0, int(item.get("request_bytes", 0))),
        "response_bytes": max(0, int(item.get("response_bytes", 0))),
        "request_ms": max(0, int(round(float(item.get("request_time", 0)) * 1000))),
    }


def import_log(db):
    if not os.path.isfile(LOG):
        return
    stat = os.stat(LOG)
    row = db.execute("SELECT value FROM state WHERE key='log_position'").fetchone()
    inode, offset = stat.st_ino, 0
    if row:
        try:
            old_inode, old_offset = map(int, row[0].split(":", 1))
            if old_inode == inode and old_offset <= stat.st_size:
                offset = old_offset
        except ValueError:
            pass
    with open(LOG, encoding="utf-8", errors="replace") as stream:
        stream.seek(offset)
        while True:
            line_offset = stream.tell()
            raw = stream.readline()
            if not raw:
                break
            try:
                event = event_from_line(raw, f"{inode}:{line_offset}:")
                if not event:
                    continue
                inserted = db.execute("INSERT OR IGNORE INTO seen_events(hash,occurred) VALUES(?,?)",
                                      (event["hash"], event["occurred"])).rowcount
                if not inserted:
                    continue
                db.execute("""INSERT INTO minute_stats
                  (bucket,endpoint,class,reason,status,requests,request_bytes,response_bytes,total_ms,max_ms)
                  VALUES(?,?,?,?,?,1,?,?,?,?) ON CONFLICT(bucket,endpoint,class,reason,status) DO UPDATE SET
                  requests=requests+1,request_bytes=request_bytes+excluded.request_bytes,
                  response_bytes=response_bytes+excluded.response_bytes,total_ms=total_ms+excluded.total_ms,
                  max_ms=MAX(max_ms,excluded.max_ms)""",
                  (event["bucket"], event["endpoint"], event["class"], event["reason"], event["status"],
                   event["request_bytes"], event["response_bytes"], event["request_ms"], event["request_ms"]))
                if event["class"] == "failed":
                    db.execute("""INSERT OR IGNORE INTO errors
                      (hash,occurred,remote,endpoint,method,status,reason,request_bytes,response_bytes,request_ms)
                      VALUES(?,?,?,?,?,?,?,?,?,?)""",
                      (event["hash"], event["occurred"], event["remote"], event["endpoint"], event["method"],
                       event["status"], event["reason"], event["request_bytes"], event["response_bytes"], event["request_ms"]))
            except Exception as exc:
                print(json.dumps({"event": "parse_error", "error": str(exc)}), flush=True)
        offset = stream.tell()
    db.execute("INSERT INTO state(key,value) VALUES('log_position',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
               (f"{inode}:{offset}",))
    db.commit()


def collect_metrics(db):
    with urllib.request.urlopen(METRICS, timeout=3) as response:
        values = {}
        for line in response.read().decode().splitlines():
            name, value = line.split(None, 1)
            values[name] = int(float(value))
    names = ["sessions_live", "streams_live", "backend_dials_in_flight", "pending_bytes", "pending_items",
             "sessions_created_total", "sessions_closed_total", "streams_opened_total", "streams_rejected_total",
             "backend_dial_failures_total", "bytes_up_total", "bytes_down_total", "limit_hits_total"]
    db.execute("INSERT OR REPLACE INTO metrics VALUES(" + ",".join(["?"] * 14) + ")",
               (int(time.time()), *[values.get("tproxy_" + name, 0) for name in names]))
    db.commit()


def window_data(db, since):
    endpoint_rows = {"good": [], "failed": []}
    for class_name in endpoint_rows:
        rows = db.execute("""SELECT endpoint,SUM(requests),SUM(request_bytes),SUM(response_bytes),MAX(max_ms)
          FROM minute_stats WHERE class=? AND bucket>=? GROUP BY endpoint ORDER BY SUM(requests) DESC""",
          (class_name, since)).fetchall()
        endpoint_rows[class_name] = [{"endpoint": r[0], "requests": r[1] or 0, "bytes_in": r[2] or 0,
                                      "bytes_out": r[3] or 0, "max_ms": r[4] or 0} for r in rows]
    reasons = {row[0]: row[1] for row in db.execute(
        "SELECT reason,SUM(requests) FROM minute_stats WHERE class='failed' AND bucket>=? GROUP BY reason ORDER BY 2 DESC",
        (since,)).fetchall()}
    errors = [{"time": datetime.fromtimestamp(r[0], timezone.utc).isoformat(), "ip": r[1], "endpoint": r[2],
               "method": r[3], "status": r[4], "reason": r[5], "bytes_in": r[6], "bytes_out": r[7], "ms": r[8]}
              for r in db.execute("""SELECT occurred,remote,endpoint,method,status,reason,request_bytes,response_bytes,request_ms
                FROM errors WHERE occurred>=? ORDER BY occurred DESC LIMIT 50""", (since,)).fetchall()]
    latest = db.execute("SELECT * FROM metrics ORDER BY occurred DESC LIMIT 1").fetchone()
    first = db.execute("SELECT * FROM metrics WHERE occurred>=? ORDER BY occurred LIMIT 1", (since,)).fetchone()
    names = ["occurred", "sessions_live", "streams_live", "backend_dials_in_flight", "pending_bytes", "pending_items",
             "sessions_created_total", "sessions_closed_total", "streams_opened_total", "streams_rejected_total",
             "backend_dial_failures_total", "bytes_up_total", "bytes_down_total", "limit_hits_total"]
    latest_map = dict(zip(names, latest or [0] * len(names)))
    first_map = dict(zip(names, first or latest or [0] * len(names)))
    counters = names[6:]
    period = {key: max(0, latest_map[key] - first_map[key]) for key in counters}
    created = db.execute("SELECT COALESCE(SUM(requests),0) FROM minute_stats WHERE class='good' AND reason='session_created' AND bucket>=?", (since,)).fetchone()[0]
    period["sessions_created_total"] = created
    return {"endpoints": endpoint_rows, "reasons": reasons, "errors": errors,
            "metrics": {"latest": {key: latest_map[key] for key in names[1:]}, "period": period}}


def publish(db):
    now = int(time.time())
    payload = {"generated_at": datetime.now(timezone.utc).isoformat(), "windows": {}}
    for name, seconds in WINDOWS.items():
        payload["windows"][name] = window_data(db, now - seconds)
    temporary = OUTPUT + ".tmp"
    with open(temporary, "w", encoding="utf-8") as stream:
        json.dump(payload, stream, ensure_ascii=False, separators=(",", ":"))
    os.chmod(temporary, 0o640)
    os.replace(temporary, OUTPUT)


def cleanup(db):
    cutoff = int(time.time()) - WINDOWS["7d"] - 3600
    for table, column in (("seen_events", "occurred"), ("minute_stats", "bucket"), ("errors", "occurred"), ("metrics", "occurred")):
        db.execute(f"DELETE FROM {table} WHERE {column}<?", (cutoff,))
    db.commit()


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    db = connect()
    last_metrics = last_publish = last_cleanup = 0
    while running:
        try:
            import_log(db)
            now = time.monotonic()
            if now - last_metrics >= 10:
                collect_metrics(db); last_metrics = now
            if now - last_publish >= 5:
                publish(db); last_publish = now
            if now - last_cleanup >= 3600:
                cleanup(db); last_cleanup = now
        except Exception as exc:
            print(json.dumps({"event": "collector_error", "error": str(exc)}), flush=True)
            try: db.rollback()
            except Exception: pass
        time.sleep(2)
    db.close()


if __name__ == "__main__":
    main()
PY
  chmod 0755 /usr/local/lib/webproxy-analytics/collector.py
}

write_analytics_dashboard() {
  install -d -o root -g root -m 0755 /srv/tproxy-site/anal
  if [ -f "$ANALYTICS_ASSET_DIR/index.html" ] && [ -f "$ANALYTICS_ASSET_DIR/app.css" ] && [ -f "$ANALYTICS_ASSET_DIR/app.js" ]; then
    sed "s/__DOMAIN__/$DOMAIN/g" "$ANALYTICS_ASSET_DIR/index.html" > /srv/tproxy-site/anal/index.html
    install -o root -g root -m 0644 "$ANALYTICS_ASSET_DIR/app.css" /srv/tproxy-site/anal/app.css
    install -o root -g root -m 0644 "$ANALYTICS_ASSET_DIR/app.js" /srv/tproxy-site/anal/app.js
    chmod 0644 /srv/tproxy-site/anal/index.html
    return
  fi
  cat > /srv/tproxy-site/anal/index.html <<EOF
<!doctype html><html lang="ru"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>WEB proxy · Analytics</title><link rel="stylesheet" href="/anal/app.css"></head><body><main>
<nav><a href="/">${DOMAIN}</a><span><i></i> WEB proxy live</span></nav>
<header><div><p class="eyebrow">Private dashboard</p><h1>Аналитика WEB proxy</h1><p class="sub">Сессии, потоки, трафик и ошибки транспортного шлюза. Обновление каждые 5 секунд.</p></div>
<div class="ranges"><button data-window="15m">15 мин</button><button data-window="1h" class="active">1 час</button><button data-window="24h">24 часа</button><button data-window="7d">7 дней</button></div></header>
<section class="summary" id="summary"></section><section class="boards"><article><div class="title"><h2>Успешные операции</h2><strong id="goodTotal">0</strong></div><div id="goodBars" class="bars"></div></article><article class="failed"><div class="title"><h2>Ошибки</h2><strong id="failedTotal">0</strong></div><div id="failedBars" class="bars"></div></article></section>
<section class="lower"><article><h2>Причины ошибок</h2><div id="reasons" class="reasons"></div></article><article><div class="title"><h2>Последние ошибки</h2><span id="updated"></span></div><div class="table"><table><thead><tr><th>Время</th><th>IP</th><th>Endpoint</th><th>Статус</th><th>Задержка</th></tr></thead><tbody id="errors"></tbody></table></div></article></section>
</main><script src="/anal/app.js"></script></body></html>
EOF
  cat > /srv/tproxy-site/anal/app.css <<'EOF'
:root{color-scheme:dark;--bg:#070b11;--panel:#0d141d;--line:#233142;--text:#edf5ff;--muted:#8497aa;--good:#45d3a0;--bad:#ff657a;--accent:#68c9ff}*{box-sizing:border-box}body{margin:0;background:radial-gradient(circle at 50% -20%,#15283d 0,var(--bg) 42%);color:var(--text);font-family:Inter,-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;min-height:100vh;font-variant-numeric:tabular-nums}main{max-width:1600px;margin:auto;padding:28px}nav{display:flex;align-items:center;justify-content:space-between;border-bottom:1px solid var(--line);padding:0 0 20px;margin-bottom:34px}nav a{color:var(--accent);font-size:13px;font-weight:800;letter-spacing:.13em;text-transform:uppercase;text-decoration:none}nav span{display:flex;align-items:center;gap:9px;color:var(--muted);font-size:12px;text-transform:uppercase}nav i{width:8px;height:8px;border-radius:50%;background:var(--good);box-shadow:0 0 14px var(--good)}header{display:flex;align-items:flex-end;justify-content:space-between;gap:25px;margin-bottom:25px}.eyebrow{margin:0 0 11px;color:var(--accent);font-size:11px;font-weight:800;letter-spacing:.17em;text-transform:uppercase}h1{font-size:clamp(38px,5vw,70px);line-height:1;margin:0 0 12px;letter-spacing:-.045em}.sub{margin:0;color:var(--muted);line-height:1.5}.ranges{display:flex;padding:4px;border:1px solid var(--line);background:#091019}.ranges button{border:0;background:transparent;color:var(--muted);padding:10px 14px;font-weight:700;cursor:pointer}.ranges button.active{background:var(--accent);color:#06101a}.summary{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;margin-bottom:12px}.metric,article{border:1px solid var(--line);background:linear-gradient(145deg,#101924,#0b1119)}.metric{padding:18px}.metric span{display:block;color:var(--muted);font-size:11px;text-transform:uppercase;margin-bottom:8px}.metric strong{font-size:30px}.boards{display:grid;grid-template-columns:1fr 1fr;gap:12px}.lower{display:grid;grid-template-columns:minmax(280px,.65fr) minmax(620px,1.35fr);gap:12px;margin-top:12px}article{padding:22px}.title{display:flex;align-items:center;justify-content:space-between;gap:15px}.title h2,article>h2{margin:0;font-size:22px}.title strong{font-size:30px}.title span{color:var(--muted);font-size:12px}.bars{display:grid;gap:13px;margin-top:22px}.bar-row{display:grid;grid-template-columns:130px 1fr auto;align-items:center;gap:12px}.bar-row span{color:#dbe7f2}.track{height:9px;background:#1b2835}.track i{display:block;height:100%;background:linear-gradient(90deg,#2ca982,var(--good))}.failed .track i{background:linear-gradient(90deg,#c33d56,var(--bad))}.bar-row strong{min-width:60px;text-align:right}.reasons{display:grid;gap:15px;margin-top:22px}.reason{display:grid;grid-template-columns:1fr auto;gap:8px}.reason span{color:var(--muted)}.reason div{grid-column:1/-1;height:5px;background:#1b2835}.reason i{display:block;height:100%;background:var(--bad)}.table{overflow:auto;max-height:390px;margin-top:18px}table{width:100%;border-collapse:collapse;font-size:13px}th{position:sticky;top:0;background:#101924;color:var(--muted);text-align:left}th,td{padding:11px;border-bottom:1px solid #1e2a37;white-space:nowrap}.empty{padding:35px;color:var(--muted);text-align:center}@media(max-width:1000px){.boards,.lower{grid-template-columns:1fr}.summary{grid-template-columns:1fr 1fr}}@media(max-width:650px){main{padding:16px}header{align-items:stretch;flex-direction:column}.ranges{overflow:auto}.summary{grid-template-columns:1fr 1fr}.bar-row{grid-template-columns:95px 1fr auto}article{padding:15px}}
EOF
  cat > /srv/tproxy-site/anal/app.js <<'EOF'
const nf=new Intl.NumberFormat('ru-RU'),names={'/api/v1/session':'Сессии','/api/v1/up':'Отправка','/api/v1/down':'Получение','/api/v1/ws':'WebSocket'},reasonNames={capacity_or_backpressure:'Лимит или обратное давление',rejected_request:'Запрос отклонён',server_error:'Ошибка сервера',unexpected_status:'Неожиданный HTTP-статус'};let selected='1h';
const bytes=n=>n<1024?n+' Б':n<1048576?(n/1024).toFixed(1)+' КБ':n<1073741824?(n/1048576).toFixed(1)+' МБ':(n/1073741824).toFixed(2)+' ГБ';const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
function bars(id,rows){const box=document.getElementById(id),max=Math.max(1,...rows.map(r=>r.requests));box.innerHTML=rows.length?'':'<div class="empty">Событий за период нет</div>';rows.forEach(r=>{const e=document.createElement('div');e.className='bar-row';e.innerHTML=`<span>${esc(names[r.endpoint]||r.endpoint)}</span><div class="track"><i style="width:${r.requests/max*100}%"></i></div><strong>${nf.format(r.requests)}</strong>`;box.appendChild(e)})}
function render(data){const w=data.windows[selected],latest=w.metrics.latest,period=w.metrics.period,good=w.endpoints.good.reduce((s,r)=>s+r.requests,0),bad=w.endpoints.failed.reduce((s,r)=>s+r.requests,0),traffic=(period.bytes_up_total||0)+(period.bytes_down_total||0);document.getElementById('summary').innerHTML=`<div class="metric"><span>Активные сессии</span><strong>${nf.format(latest.sessions_live||0)}</strong></div><div class="metric"><span>Активные потоки</span><strong>${nf.format(latest.streams_live||0)}</strong></div><div class="metric"><span>Создано сессий</span><strong>${nf.format(period.sessions_created_total||0)}</strong></div><div class="metric"><span>Полезный трафик</span><strong>${bytes(traffic)}</strong></div>`;document.getElementById('goodTotal').textContent=nf.format(good);document.getElementById('failedTotal').textContent=nf.format(bad);bars('goodBars',w.endpoints.good);bars('failedBars',w.endpoints.failed);const reasons=document.getElementById('reasons'),entries=Object.entries(w.reasons),max=Math.max(1,...entries.map(x=>x[1]));reasons.innerHTML=entries.length?'':'<div class="empty">Ошибок за период нет</div>';entries.forEach(([key,n])=>{const e=document.createElement('div');e.className='reason';e.innerHTML=`<span>${esc(reasonNames[key]||key)}</span><strong>${nf.format(n)}</strong><div><i style="width:${n/max*100}%"></i></div>`;reasons.appendChild(e)});const body=document.getElementById('errors');body.innerHTML='';w.errors.forEach(r=>{const tr=document.createElement('tr');tr.innerHTML=`<td>${new Date(r.time).toLocaleString('ru-RU')}</td><td>${esc(r.ip)}</td><td>${esc(names[r.endpoint]||r.endpoint)} · ${esc(r.method)}</td><td>${r.status} · ${esc(reasonNames[r.reason]||r.reason)}</td><td>${r.ms} мс · ${bytes(r.bytes_in+r.bytes_out)}</td>`;body.appendChild(tr)});if(!w.errors.length)body.innerHTML='<tr><td colspan="5" class="empty">Ошибок за период нет</td></tr>';document.getElementById('updated').textContent='обновлено '+new Date(data.generated_at).toLocaleTimeString('ru-RU')}
async function load(){try{const r=await fetch('/anal/data.json?t='+Date.now(),{cache:'no-store'});if(!r.ok)throw new Error(r.status);render(await r.json())}catch(e){document.getElementById('updated').textContent='ожидание данных'}}document.querySelectorAll('[data-window]').forEach(b=>b.onclick=()=>{selected=b.dataset.window;document.querySelectorAll('[data-window]').forEach(x=>x.classList.toggle('active',x===b));load()});load();setInterval(load,5000);
EOF
  chmod 0644 /srv/tproxy-site/anal/index.html /srv/tproxy-site/anal/app.css /srv/tproxy-site/anal/app.js
}

configure_analytics_credentials() {
  local credentials=/root/webproxy-analytics-credentials.txt
  ANALYTICS_LOGIN=""
  ANALYTICS_PASSWORD=""
  if [ -s "$credentials" ]; then
    ANALYTICS_LOGIN="$(sed -n 's/^login=//p' "$credentials" | head -n1)"
    ANALYTICS_PASSWORD="$(sed -n 's/^password=//p' "$credentials" | head -n1)"
  fi
  if ! [[ "$ANALYTICS_LOGIN" =~ ^[0-9a-f]{10}$ && "$ANALYTICS_PASSWORD" =~ ^[0-9a-f]{10}$ ]]; then
    ANALYTICS_LOGIN="$(openssl rand -hex 5)"
    ANALYTICS_PASSWORD="$(openssl rand -hex 5)"
  fi
  htpasswd -bcB /etc/nginx/.htpasswd-webproxy-anal "$ANALYTICS_LOGIN" "$ANALYTICS_PASSWORD" >/dev/null
  chown root:www-data /etc/nginx/.htpasswd-webproxy-anal
  chmod 0640 /etc/nginx/.htpasswd-webproxy-anal
  cat > "$credentials" <<EOF
url=https://${DOMAIN}/anal/
login=${ANALYTICS_LOGIN}
password=${ANALYTICS_PASSWORD}
EOF
  chmod 0600 "$credentials"
}

configure_analytics_service() {
  if ! id webproxy-analytics >/dev/null 2>&1; then
    useradd --system --home /var/lib/webproxy-analytics --shell /usr/sbin/nologin webproxy-analytics
  fi
  install -d -o webproxy-analytics -g www-data -m 0750 /var/lib/webproxy-analytics
  cat > /etc/systemd/system/webproxy-analytics.service <<'EOF'
[Unit]
Description=WEB proxy analytics collector
After=network.target nginx.service tproxy-server.service
Wants=tproxy-server.service

[Service]
Type=simple
User=webproxy-analytics
Group=www-data
UMask=0027
ExecStart=/usr/local/lib/webproxy-analytics/collector.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/webproxy-analytics
LoadCredential=ipinfo_token:/etc/webproxy-analytics/ipinfo.token

[Install]
WantedBy=multi-user.target
EOF
}

configure_token_admin() {
  [ -f "$ANALYTICS_ASSET_DIR/token_admin.py" ] || die "Не найден $ANALYTICS_ASSET_DIR/token_admin.py."
  install -o root -g root -m 0755 "$ANALYTICS_ASSET_DIR/token_admin.py" \
    /usr/local/lib/webproxy-analytics/token_admin.py
  printf '%s\n' "$DOMAIN" > /etc/webproxy-analytics/domain
  chown root:root /etc/webproxy-analytics/domain
  chmod 0600 /etc/webproxy-analytics/domain
  cat > /etc/systemd/system/webproxy-token-admin.service <<'EOF'
[Unit]
Description=WEB proxy IPinfo token administrator
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
UMask=0077
ExecStart=/usr/local/lib/webproxy-analytics/token_admin.py
Restart=always
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/etc/webproxy-analytics
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6

[Install]
WantedBy=multi-user.target
EOF
}

configure_analytics_logging() {
  install -d -o root -g www-data -m 0750 /var/log/tproxy
  touch /var/log/tproxy/access.log
  chown www-data:www-data /var/log/tproxy/access.log
  chmod 0640 /var/log/tproxy/access.log
  cat > /etc/nginx/conf.d/webproxy-analytics-log.conf <<'EOF'
map_hash_bucket_size 64;
map $http_upgrade $webproxy_connection_upgrade { default upgrade; '' close; }
map $uri $webproxy_transport_loggable {
    default 0;
    /api/v1/session 1;
    /api/v1/up 1;
    /api/v1/down 1;
    /api/v1/ws 1;
}
log_format webproxy_transport escape=json
    '{"time":"$time_iso8601","remote_addr":"$remote_addr","method":"$request_method",'
    '"endpoint":"$uri","status":$status,"request_bytes":$request_length,'
    '"response_bytes":$bytes_sent,"request_time":$request_time,"upgrade":"$http_upgrade"}';
EOF
  cat > /etc/logrotate.d/webproxy-analytics <<'EOF'
/var/log/tproxy/access.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    su www-data www-data
}
EOF
}

configure_tproxy_public_upstream() {
  local backup="" candidate
  TPROXY_CONFIG_CHANGED=0
  candidate="$(mktemp /tmp/tproxy-config.XXXXXX)"
  cat > "$candidate" <<EOF
{
  "public_hostname": "$DOMAIN",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_upstream": "http://127.0.0.1:8082",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF
  if [ -f /etc/tproxy-server/config.json ] && cmp -s "$candidate" /etc/tproxy-server/config.json; then
    rm -f "$candidate"
    TPROXY_CONFIG_BACKUP=""
    return
  fi
  if [ -f /etc/tproxy-server/config.json ]; then
    backup="/root/tproxy-config.before-analytics.$(date +%Y%m%d-%H%M%S).json"
    cp -a /etc/tproxy-server/config.json "$backup"
  fi
  TPROXY_CONFIG_BACKUP="$backup"
  install -o root -g tproxy -m 0640 "$candidate" /etc/tproxy-server/config.json
  rm -f "$candidate"
  TPROXY_CONFIG_CHANGED=1
  if ! /usr/local/bin/tproxy-server -config /etc/tproxy-server/config.json \
    -profiles-file /etc/tproxy-server/profiles.json -check; then
    [ -n "$backup" ] && cp -a "$backup" /etc/tproxy-server/config.json
    die "Новая конфигурация tproxy-server не прошла проверку."
  fi
}

configure_nginx_analytics() {
  local site_backup
  site_backup="/root/nginx-webproxy.before-analytics.$(date +%Y%m%d-%H%M%S).conf"
  [ -f /etc/nginx/sites-available/webproxy-only ] && \
    cp -a /etc/nginx/sites-available/webproxy-only "$site_backup"
  cat > /etc/nginx/sites-available/webproxy-only <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root /var/www/webproxy-acme; default_type text/plain; }
    location / { return 301 https://\$host\$request_uri; }
    access_log off;
}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $DOMAIN;
    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_cache shared:WEBPROXY:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    access_log /var/log/tproxy/access.log webproxy_transport if=\$webproxy_transport_loggable;
    error_log /var/log/nginx/webproxy-only-error.log warn;
    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection \$webproxy_connection_upgrade;
        proxy_connect_timeout 5s;
        proxy_send_timeout 75s;
        proxy_read_timeout 75s;
        proxy_request_buffering off;
        proxy_buffering off;
    }
}
server {
    listen 127.0.0.1:8082;
    server_name $DOMAIN;
    root /srv/tproxy-site;
    index index.html;
    location = /anal { return 301 /anal/; }
    location = /anal/data.json {
        auth_basic "WEB proxy analytics";
        auth_basic_user_file /etc/nginx/.htpasswd-webproxy-anal;
        alias /var/lib/webproxy-analytics/data.json;
        add_header Cache-Control "no-store" always;
    }
    location = /anal/ipinfo-token {
        auth_basic "WEB proxy analytics";
        auth_basic_user_file /etc/nginx/.htpasswd-webproxy-anal;
        limit_except POST { deny all; }
        proxy_pass http://127.0.0.1:8083/token;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header Origin \$http_origin;
        proxy_set_header X-Forwarded-Host \$host;
        proxy_connect_timeout 5s;
        proxy_read_timeout 20s;
        add_header Cache-Control "no-store" always;
    }
    location ^~ /anal/ {
        auth_basic "WEB proxy analytics";
        auth_basic_user_file /etc/nginx/.htpasswd-webproxy-anal;
        try_files \$uri \$uri/ =404;
    }
    location / { try_files \$uri \$uri/ =404; }
    access_log off;
}
EOF
  if ! nginx -t; then
    [ -f "$site_backup" ] && cp -a "$site_backup" /etc/nginx/sites-available/webproxy-only
    if [ "${ANALYTICS_LOG_CONFIG_EXISTED:-0}" -eq 1 ]; then
      cp -a "$ANALYTICS_LOG_CONFIG_BACKUP" /etc/nginx/conf.d/webproxy-analytics-log.conf
    else
      rm -f /etc/nginx/conf.d/webproxy-analytics-log.conf
    fi
    nginx -t || true
    [ -z "${TPROXY_CONFIG_BACKUP:-}" ] || \
      cp -a "$TPROXY_CONFIG_BACKUP" /etc/tproxy-server/config.json
    die "Новая конфигурация nginx не прошла проверку; восстановлена резервная копия."
  fi
  systemctl reload nginx
}

setup_analytics() {
  [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ] || die "Не найден сертификат для $DOMAIN."
  ANALYTICS_LOG_CONFIG_EXISTED=0
  ANALYTICS_LOG_CONFIG_BACKUP="/root/nginx-webproxy-log.before-analytics.$(date +%Y%m%d-%H%M%S).conf"
  if [ -f /etc/nginx/conf.d/webproxy-analytics-log.conf ]; then
    ANALYTICS_LOG_CONFIG_EXISTED=1
    cp -a /etc/nginx/conf.d/webproxy-analytics-log.conf "$ANALYTICS_LOG_CONFIG_BACKUP"
  fi
  if [ ! -s /srv/tproxy-site/index.html ] || grep -Fq 'This website is available.' /srv/tproxy-site/index.html; then
    [ ! -f /srv/tproxy-site/index.html ] || \
      cp -a /srv/tproxy-site/index.html "/root/webproxy-index.before-analytics.$(date +%Y%m%d-%H%M%S).html"
    write_default_site /srv/tproxy-site
  fi
  write_analytics_collector
  write_analytics_dashboard
  configure_analytics_credentials
  configure_ipinfo_token
  configure_analytics_service
  configure_token_admin
  configure_analytics_logging
  configure_tproxy_public_upstream
  configure_nginx_analytics
  systemctl daemon-reload
  if [ "${TPROXY_CONFIG_CHANGED:-0}" -eq 1 ] || ! systemctl is-active --quiet tproxy-server; then
    systemctl restart tproxy-server
  fi
  systemctl enable webproxy-analytics
  systemctl restart webproxy-analytics
  systemctl enable webproxy-token-admin
  systemctl restart webproxy-token-admin
  local ready=0
  for _ in $(seq 1 20); do
    if [ -s /var/lib/webproxy-analytics/data.json ]; then ready=1; break; fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "Аналитика не создала первый снимок данных."
  curl -kfsS --max-time 8 --resolve "$DOMAIN:443:127.0.0.1" \
    -u "$ANALYTICS_LOGIN:$ANALYTICS_PASSWORD" "https://$DOMAIN/anal/" >/dev/null || \
    die "Проверка /anal/ не прошла."
}

write_result_files() {
  umask 077
  cat > /root/webproxy-only-links.txt <<EOF
https://t.me/webproxy?server=${DOMAIN}&secret=${WEBPROXY_SECRET}
tg://webproxy?server=${DOMAIN}&secret=${WEBPROXY_SECRET}
EOF
  cat > /root/.webproxy-only.config <<EOF
DOMAIN=$(printf '%q' "$DOMAIN")
EMAIL=$(printf '%q' "$EMAIL")
WEBPROXY_SECRET=$(printf '%q' "$WEBPROXY_SECRET")
MTPROXY_WORKERS=$(printf '%q' "$MTPROXY_WORKERS")
MTPROXY_MAX_CONNECTIONS=$(printf '%q' "$MTPROXY_MAX_CONNECTIONS")
EOF
  chmod 0600 /root/webproxy-only-links.txt /root/.webproxy-only.config
}

write_install_summary() {
  /usr/local/sbin/webproxy_cli --sync-internal
  [ -s /root/webproxy-install-summary.txt ] || die "Не удалось создать итоговый файл установки."
  chmod 0600 /root/webproxy-install-summary.txt
}

validate_result() {
  local analytics_login analytics_password ok=0
  nginx -t
  systemctl is-active --quiet nginx
  systemctl is-active --quiet mtproxy
  systemctl is-active --quiet tproxy-server
  systemctl is-active --quiet webproxy-analytics
  systemctl is-active --quiet webproxy-token-admin
  systemctl is-active --quiet certbot.timer
  [ -x /usr/local/sbin/webproxy_cli ]
  [ -s /var/lib/webproxy-analytics/data.json ]
  [ -s /root/webproxy-analytics-credentials.txt ]
  curl -fsS --max-time 5 http://127.0.0.1:8083/status >/dev/null
  curl -fsS --max-time 5 http://127.0.0.1:8081/readyz >/dev/null
  for _ in $(seq 1 30); do
    if curl -4fsS --max-time 8 "https://$DOMAIN/" >/dev/null; then
      ok=1
      break
    fi
    sleep 2
  done
  [ "$ok" -eq 1 ] || die "Публичный HTTPS не ответил после установки. Проверьте DNS и firewall хостера."
  analytics_login="$(sed -n 's/^login=//p' /root/webproxy-analytics-credentials.txt | head -n1)"
  analytics_password="$(sed -n 's/^password=//p' /root/webproxy-analytics-credentials.txt | head -n1)"
  [ "${#analytics_login}" -eq 10 ] && [ "${#analytics_password}" -eq 10 ] || \
    die "Учётные данные аналитики имеют неверную длину."
  curl -kfsS --max-time 8 --resolve "$DOMAIN:443:127.0.0.1" \
    -u "$analytics_login:$analytics_password" "https://$DOMAIN/anal/data.json" >/dev/null || \
    die "Финальная проверка аналитики не прошла."
}

main() {
  parse_args "$@"
  need_root
  require_supported_os
  if [ "$ANALYTICS_ONLY" -eq 1 ]; then
    [ -r /root/.webproxy-only.config ] || die "Не найдена существующая конфигурация /root/.webproxy-only.config."
    # shellcheck disable=SC1091
    source /root/.webproxy-only.config
    [ -n "$DOMAIN" ] || die "В существующей конфигурации не указан DOMAIN."
    collect_ipinfo_token
    install_bootstrap_packages
    setup_webproxy_cli
    setup_analytics
    validate_result
    write_install_summary
    cat <<EOF

WEB proxy и analytics обновлены.

$(cat /root/webproxy-install-summary.txt)
EOF
    exit 0
  fi
  check_clean_server
  install_bootstrap_packages
  collect_inputs
  collect_ipinfo_token
  check_dns
  print_plan
  if [ "$DRY_RUN" -eq 1 ]; then
    say "Dry-run: изменений после preflight не выполнено."
    exit 0
  fi

  local temporary repository generated_site active_site
  temporary="$(mktemp -d /tmp/webproxy-only.XXXXXX)"
  trap 'rm -rf "$temporary"' EXIT
  repository="$(download_source "$temporary")"
  patch_upstream_installer "$repository"
  write_mtproxy_runner
  if [ -n "$SITE_DIR" ]; then
    active_site="$SITE_DIR"
  else
    generated_site="$temporary/site"
    write_default_site "$generated_site"
    active_site="$generated_site"
  fi
  run_upstream_install "$repository" "$active_site"
  setup_webproxy_cli
  configure_nginx_http
  issue_certificate
  configure_nginx_https
  configure_certbot_renewal
  setup_analytics
  write_result_files
  validate_result
  write_install_summary
  trap - EXIT
  rm -rf "$temporary"

  cat <<EOF

WEB proxy установлен полностью.

$(cat /root/webproxy-install-summary.txt)

Проверка:
  systemctl --no-pager --full status nginx certbot.timer mtproxy tproxy-server webproxy-analytics webproxy-token-admin
  certbot renew --dry-run
  curl -fsS http://127.0.0.1:8081/readyz

Все данные сохранены: /root/webproxy-install-summary.txt
EOF
}

if [ "${WEBPROXY_ONLY_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
