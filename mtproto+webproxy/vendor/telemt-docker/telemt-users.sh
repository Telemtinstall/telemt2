#!/usr/bin/env bash
set -Eeuo pipefail

INSTALL_DIR="${INSTALL_DIR:-/opt/telemt-docker}"
CONFIG_FILE="${CONFIG_FILE:-$INSTALL_DIR/telemt.toml}"
COMPOSE_FILE="${COMPOSE_FILE:-$INSTALL_DIR/docker-compose.yml}"
LINKS_FILE="${LINKS_FILE:-/root/telemt-proxy-links.txt}"
PRIMARY_LINK_FILE="${PRIMARY_LINK_FILE:-/root/telemt-proxy-link.txt}"
DIRECT_LINK_FILE="${DIRECT_LINK_FILE:-/root/telemt-proxy-link-ip.txt}"
DEFAULT_MAX_TCP_CONNS="${DEFAULT_MAX_TCP_CONNS:-5000}"

say() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<'EOF'
Usage:
  telemt-users list
  telemt-users status
  telemt-users links
  telemt-users add <user> [max_tcp_conns]
  telemt-users enable <user>
  telemt-users disable <user>
  telemt-users del <user>

Examples:
  telemt-users add user2
  telemt-users add friend 5000
  telemt-users disable friend
  telemt-users enable friend
  telemt-users status
  telemt-users links
  telemt-users del friend
EOF
}

require_config() {
  [ -f "$CONFIG_FILE" ] || die "Telemt config not found: $CONFIG_FILE"
}

validate_user() {
  [[ "$1" =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || die "Bad Telemt user name: $1"
}

hex_encode_ascii() {
  LC_ALL=C printf '%s' "$1" | od -An -tx1 -v | tr -d ' \n'
}

config_value() {
  local section="$1" key="$2"
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
  ' "$CONFIG_FILE"
}

config_first_value() {
  local key="$1"
  awk -v wanted="$key" '
    {
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
  ' "$CONFIG_FILE"
}

users_and_secrets() {
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
      if (key != "" && length(val) == 32 && val !~ /[^A-Fa-f0-9]/) print key, val
    }
  ' "$CONFIG_FILE"
}

list_users() {
  require_config
  users_and_secrets | awk '{print $1}'
}

user_enabled() {
  local user="$1"
  awk -v wanted="$user" '
    /^\[access\.user_enabled\]/ {in_enabled=1; next}
    /^\[/ && in_enabled {in_enabled=0}
    in_enabled {
      line=$0
      sub(/#.*/, "", line)
      eq=index(line, "=")
      if (!eq) next
      key=substr(line, 1, eq - 1)
      val=substr(line, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^"|"$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (key == wanted) {
        if (val ~ /^(false|False|FALSE)$/) print "false"
        else print "true"
        found=1
        exit
      }
    }
    END { if (!found) print "true" }
  ' "$CONFIG_FILE"
}

user_limit() {
  local user="$1"
  awk -v wanted="$user" '
    /^\[access\.user_max_tcp_conns\]/ {in_limits=1; next}
    /^\[/ && in_limits {in_limits=0}
    in_limits {
      line=$0
      sub(/#.*/, "", line)
      eq=index(line, "=")
      if (!eq) next
      key=substr(line, 1, eq - 1)
      val=substr(line, eq + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", key)
      gsub(/^"|"$/, "", key)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (key == wanted) { print val; found=1; exit }
    }
    END { if (!found) print "unlimited" }
  ' "$CONFIG_FILE"
}

unique_backup_path() {
  local base candidate i=0
  base="${CONFIG_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
  candidate="$base"
  while [ -e "$candidate" ]; do
    i=$((i + 1))
    candidate="${base}.${i}"
  done
  printf '%s' "$candidate"
}

status_users() {
  require_config
  while read -r user _secret; do
    [ -n "$user" ] || continue
    printf '%-24s enabled=%s max_tcp_conns=%s\n' "$user" "$(user_enabled "$user")" "$(user_limit "$user")"
  done < <(users_and_secrets)
}

write_links() {
  require_config
  local domain port domain_hex direct_host user secret enabled tls_secret https_link tg_link direct_https direct_tg first_https="" first_direct_https=""
  domain="$(config_value 'general\\.links' public_host)"
  port="$(config_value 'general\\.links' public_port)"
  direct_host="$(config_first_value announce || true)"
  [ -n "$domain" ] || die "Cannot detect public_host from [general.links]."
  port="${port:-443}"
  domain_hex="$(hex_encode_ascii "$domain")"

  : > "$LINKS_FILE"
  chmod 600 "$LINKS_FILE" 2>/dev/null || true
  while read -r user secret; do
    [ -n "$user" ] || continue
    enabled="$(user_enabled "$user")"
    secret="$(printf '%s' "$secret" | tr 'A-F' 'a-f')"
    tls_secret="ee${secret}${domain_hex}"
    https_link="https://t.me/proxy?server=${domain}&port=${port}&secret=${tls_secret}"
    tg_link="tg://proxy?server=${domain}&port=${port}&secret=${tls_secret}"
    [ -n "$first_https" ] || first_https="$https_link"
    {
      if [ "$enabled" = "false" ]; then
        printf '# user: %s (disabled)\n' "$user"
      else
        printf '# user: %s\n' "$user"
      fi
      printf '%s\n' "$https_link"
      printf '%s\n\n' "$tg_link"
      if [ -n "$direct_host" ] && [ "$direct_host" != "$domain" ]; then
        direct_https="https://t.me/proxy?server=${direct_host}&port=${port}&secret=${tls_secret}"
        direct_tg="tg://proxy?server=${direct_host}&port=${port}&secret=${tls_secret}"
        [ -n "$first_direct_https" ] || first_direct_https="$direct_https"
        printf '# direct IP variant, TLS SNI remains %s\n' "$domain"
        printf '%s\n' "$direct_https"
        printf '%s\n\n' "$direct_tg"
      fi
    } >> "$LINKS_FILE"
  done < <(users_and_secrets)

  [ -n "$first_https" ] || die "No Telemt users found in $CONFIG_FILE."
  printf '%s\n' "$first_https" > "$PRIMARY_LINK_FILE"
  if [ -n "$first_direct_https" ]; then
    printf '%s\n' "$first_direct_https" > "$DIRECT_LINK_FILE"
    chmod 600 "$DIRECT_LINK_FILE" 2>/dev/null || true
  fi
  chmod 600 "$PRIMARY_LINK_FILE" "$LINKS_FILE" 2>/dev/null || true
  say "Links written: $LINKS_FILE"
  say "Primary link:  $PRIMARY_LINK_FILE"
  if [ -n "$first_direct_https" ]; then
    say "Direct IP link: $DIRECT_LINK_FILE"
  fi
}

restart_telemt() {
  [ -f "$COMPOSE_FILE" ] || die "docker-compose.yml not found: $COMPOSE_FILE"
  if docker compose version >/dev/null 2>&1; then
    (cd "$INSTALL_DIR" && docker compose up -d --force-recreate telemt)
  elif have docker-compose; then
    (cd "$INSTALL_DIR" && docker-compose up -d --force-recreate telemt)
  else
    die "Docker Compose is not available."
  fi
}

modify_config() {
  local action="$1" user="${2:-}" max_tcp="${3:-$DEFAULT_MAX_TCP_CONNS}" secret backup
  validate_user "$user"
  [[ "$max_tcp" =~ ^[0-9]+$ ]] || die "Bad max_tcp_conns: $max_tcp"
  secret="$(openssl rand -hex 16)"
  backup="$(unique_backup_path)"
  cp -a "$CONFIG_FILE" "$backup"

  python3 - "$CONFIG_FILE" "$action" "$user" "$secret" "$max_tcp" <<'PY'
import json
import re
import sys
from collections import OrderedDict
from pathlib import Path

path = Path(sys.argv[1])
action, user, secret, max_tcp = sys.argv[2:6]
lines = path.read_text().splitlines(True)

section_re = re.compile(r'^\s*\[([^\[\]]+)\]\s*(?:#.*)?$')

def find_section(name):
    start = None
    for i, line in enumerate(lines):
        m = section_re.match(line)
        if m and m.group(1) == name:
            start = i
            break
    if start is None:
        return None, None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if re.match(r'^\s*\[', lines[j]):
            end = j
            break
    return start, end

def parse_section(name):
    start, end = find_section(name)
    data = OrderedDict()
    if start is None:
        return data
    for line in lines[start + 1:end]:
        raw = line.split('#', 1)[0].strip()
        if '=' not in raw:
            continue
        k, v = raw.split('=', 1)
        k = k.strip().strip('"')
        v = v.strip().strip('"')
        if k:
            data[k] = v
    return data

users = parse_section('access.users')
limits = parse_section('access.user_max_tcp_conns')
enabled = parse_section('access.user_enabled')

if action == 'add':
    if user in users:
        print(f'user already exists: {user}', file=sys.stderr)
        sys.exit(2)
    users[user] = secret.lower()
    limits[user] = max_tcp
    enabled[user] = 'true'
elif action == 'del':
    if user not in users:
        print(f'user not found: {user}', file=sys.stderr)
        sys.exit(2)
    if len(users) <= 1:
        print('cannot delete the last Telemt user', file=sys.stderr)
        sys.exit(2)
    users.pop(user, None)
    limits.pop(user, None)
    enabled.pop(user, None)
elif action == 'enable':
    if user not in users:
        print(f'user not found: {user}', file=sys.stderr)
        sys.exit(2)
    enabled[user] = 'true'
elif action == 'disable':
    if user not in users:
        print(f'user not found: {user}', file=sys.stderr)
        sys.exit(2)
    enabled[user] = 'false'
else:
    print(f'bad action: {action}', file=sys.stderr)
    sys.exit(2)

user_names = list(users.keys())
array_value = '[' + ', '.join(json.dumps(u) for u in user_names) + ']'

def replace_section(name, body_lines):
    global lines
    start, end = find_section(name)
    block = [f'[{name}]\n'] + body_lines + ['\n']
    if start is None:
        insert_at = len(lines)
        for i, line in enumerate(lines):
            if line.startswith('[[upstreams]]'):
                insert_at = i
                break
        lines = lines[:insert_at] + block + lines[insert_at:]
    else:
        lines = lines[:start] + block + lines[end:]

def set_top_show_link():
    global lines
    first_section = next((i for i, line in enumerate(lines) if re.match(r'^\s*\[', line)), len(lines))
    for i in range(first_section):
        if re.match(r'^\s*show_link\s*=', lines[i]):
            lines[i] = f'show_link = {array_value}\n'
            return
    lines.insert(0, f'show_link = {array_value}\n')

def set_general_links_show():
    global lines
    start, end = find_section('general.links')
    if start is None:
        lines.append(f'\n[general.links]\nshow = {array_value}\npublic_port = 443\n')
        return
    for i in range(start + 1, end):
        if re.match(r'^\s*show\s*=', lines[i]):
            lines[i] = f'show = {array_value}\n'
            return
    lines.insert(start + 1, f'show = {array_value}\n')

replace_section('access.user_max_tcp_conns', [f'{json.dumps(k)} = {int(v)}\n' for k, v in limits.items()])
replace_section('access.users', [f'{json.dumps(k)} = {json.dumps(v)}\n' for k, v in users.items()])
replace_section('access.user_enabled', [f'{json.dumps(k)} = {str(v).lower()}\n' for k, v in enabled.items() if k in users])
set_general_links_show()
set_top_show_link()
path.write_text(''.join(lines))
PY

  chown 65532:65532 "$CONFIG_FILE" 2>/dev/null || true
  chmod 600 "$CONFIG_FILE"
  say "Backup: $backup"
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    list)
      list_users
      ;;
    status)
      status_users
      ;;
    links)
      write_links
      ;;
    add)
      [ $# -ge 2 ] || { usage; exit 1; }
      require_config
      modify_config add "$2" "${3:-$DEFAULT_MAX_TCP_CONNS}"
      restart_telemt
      write_links
      ;;
    enable)
      [ $# -ge 2 ] || { usage; exit 1; }
      require_config
      modify_config enable "$2" "$DEFAULT_MAX_TCP_CONNS"
      restart_telemt
      write_links
      ;;
    disable)
      [ $# -ge 2 ] || { usage; exit 1; }
      require_config
      modify_config disable "$2" "$DEFAULT_MAX_TCP_CONNS"
      restart_telemt
      write_links
      ;;
    del|delete|remove|rm)
      [ $# -ge 2 ] || { usage; exit 1; }
      require_config
      modify_config del "$2" "$DEFAULT_MAX_TCP_CONNS"
      restart_telemt
      write_links
      ;;
    -h|--help|help|'')
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
