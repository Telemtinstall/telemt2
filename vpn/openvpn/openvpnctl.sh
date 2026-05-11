#!/usr/bin/env bash
set -Eeuo pipefail

ENV_FILE="/etc/openvpn/server/openvpnctl.env"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

require_root() {
  [[ $EUID -eq 0 ]] || die "Run this script as root."
}

load_env() {
  [[ -r "$ENV_FILE" ]] || die "Environment file not found: $ENV_FILE"
  # shellcheck disable=SC1090
  . "$ENV_FILE"
}

ensure_dirs() {
  install -d -m 0750 "$CLIENT_DIR" "$CLIENT_OUT_DIR"
  [[ -r "$SERVER_DIR/ca.crt" ]] || die "CA file not found."
  [[ -r "$TLS_CRYPT_KEY" ]] || die "tls-crypt key not found."
  [[ -r "$AUTH_FILE" ]] || die "Auth file not found: $AUTH_FILE"
}

valid_name() {
  [[ "$1" =~ ^[A-Za-z0-9._@-]{1,64}$ ]]
}

client_exists() {
  [[ -f "$CLIENT_DIR/$1.env" ]]
}

bytes_human() {
  local bytes="${1:-0}"
  awk -v b="$bytes" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ");
    i = 1;
    while (b >= 1024 && i < 6) { b = b / 1024; i++; }
    if (i == 1) printf "%.0f %s", b, u[i];
    else printf "%.2f %s", b, u[i];
  }'
}

random_password() {
  openssl rand -hex 12
}

client_name_by_number() {
  local number="$1"
  shopt -s nullglob
  basename -s .env "$CLIENT_DIR"/*.env | sort | sed -n "${number}p"
  shopt -u nullglob
}

openvpn_cipher_lines() {
  if openvpn --version 2>/dev/null | head -n 1 | grep -Eq 'OpenVPN 2\.[0-4]\.'; then
    cat <<'EOF'
cipher AES-256-GCM
ncp-ciphers AES-256-GCM:AES-128-GCM
EOF
  else
    cat <<'EOF'
data-ciphers AES-256-GCM:AES-128-GCM:CHACHA20-POLY1305
data-ciphers-fallback AES-256-GCM
EOF
  fi
}

profile_remote_host() {
  local mode="$1"
  if [[ "$mode" == "tcp" && "${ENABLE_HTTPS_MASK:-0}" == "1" && -n "${MASK_DOMAIN:-}" ]]; then
    echo "$MASK_DOMAIN"
  else
    echo "$PUBLIC_ENDPOINT"
  fi
}

render_one_profile() {
  local name="$1"
  local mode="$2"
  local proto port out remote_host

  if [[ "$mode" == "udp" ]]; then
    proto="udp"
    port="$OVPN_UDP_PORT"
  else
    proto="tcp-client"
    port="$OVPN_TCP_PORT"
  fi

  remote_host="$(profile_remote_host "$mode")"
  out="$CLIENT_OUT_DIR/${name}-${mode}.ovpn"

  umask 077
  cat > "$out" <<EOF
client
dev tun
proto ${proto}
remote ${remote_host} ${port}
resolv-retry infinite
nobind
persist-key
persist-tun
remote-cert-tls server
auth SHA256
auth-user-pass
auth-nocache
verb 3

$(openvpn_cipher_lines)

<ca>
$(cat "$SERVER_DIR/ca.crt")
</ca>
<tls-crypt>
$(cat "$TLS_CRYPT_KEY")
</tls-crypt>
EOF
  chmod 600 "$out"
}

render_client_files() {
  local name="$1"
  local password="$2"
  local created_at="${3:-}"
  [[ -n "$created_at" ]] || created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  render_one_profile "$name" udp
  render_one_profile "$name" tcp

  umask 077
  cat > "$CLIENT_OUT_DIR/${name}-credentials.txt" <<EOF
username: ${name}
password: ${password}

UDP profile: ${CLIENT_OUT_DIR}/${name}-udp.ovpn
TCP profile: ${CLIENT_OUT_DIR}/${name}-tcp.ovpn
created_at: ${created_at}
EOF
  chmod 600 "$CLIENT_OUT_DIR/${name}-credentials.txt"
}

write_client_env() {
  local name="$1"
  local password="$2"
  local created_at="$3"
  umask 077
  cat > "$CLIENT_DIR/${name}.env" <<EOF
OPENVPN_USERNAME=$(printf '%q' "$name")
OPENVPN_PASSWORD=$(printf '%q' "$password")
OPENVPN_CREATED_AT=$(printf '%q' "$created_at")
EOF
}

upsert_auth_user() {
  local name="$1"
  local password="$2"
  printf '%s\n' "$password" | htpasswd -B -i "$AUTH_FILE" "$name" >/dev/null
  chmod 640 "$AUTH_FILE"
  chgrp nogroup "$AUTH_FILE" 2>/dev/null || true
}

cmd_add() {
  local name="${1:-}"
  local password="${2:-}"
  local created_at
  if [[ -z "$name" ]]; then
    read -r -p "Username: " name
  fi
  valid_name "$name" || die "Username must be 1-64 chars: letters, digits, dot, underscore, dash, @."
  client_exists "$name" && die "User already exists: $name"
  if [[ -z "$password" ]]; then
    password="$(random_password)"
  fi

  created_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  upsert_auth_user "$name" "$password"
  write_client_env "$name" "$password" "$created_at"
  render_client_files "$name" "$password" "$created_at"

  echo "User added: $name"
  echo "Password: $password"
  echo "UDP profile: $CLIENT_OUT_DIR/${name}-udp.ovpn"
  echo "TCP profile: $CLIENT_OUT_DIR/${name}-tcp.ovpn"
  echo "Credentials: $CLIENT_OUT_DIR/${name}-credentials.txt"
}

cmd_delete() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "User to delete: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "No user selected."
  client_exists "$name" || die "User not found: $name"

  htpasswd -D "$AUTH_FILE" "$name" >/dev/null 2>&1 || true
  rm -f "$CLIENT_DIR/${name}.env" \
    "$CLIENT_OUT_DIR/${name}-udp.ovpn" \
    "$CLIENT_OUT_DIR/${name}-tcp.ovpn" \
    "$CLIENT_OUT_DIR/${name}-credentials.txt"
  echo "User deleted: $name"
  echo "Existing active sessions may remain until the client reconnects or the service is restarted."
}

cmd_passwd() {
  local name="${1:-}"
  local password="${2:-}"
  local created_at
  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "User to reset password: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "No user selected."
  client_exists "$name" || die "User not found: $name"
  [[ -n "$password" ]] || password="$(random_password)"

  # shellcheck disable=SC1090
  . "$CLIENT_DIR/${name}.env"
  created_at="${OPENVPN_CREATED_AT:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  upsert_auth_user "$name" "$password"
  write_client_env "$name" "$password" "$created_at"
  render_client_files "$name" "$password" "$created_at"
  echo "Password reset for: $name"
  echo "Password: $password"
}

cmd_list() {
  local i=0 env name created
  shopt -s nullglob
  if ! compgen -G "$CLIENT_DIR/*.env" >/dev/null; then
    echo "No users."
    shopt -u nullglob
    return 0
  fi
  printf '%-4s %-24s %s\n' "num" "username" "created_at"
  for env in "$CLIENT_DIR"/*.env; do
    # shellcheck disable=SC1090
    . "$env"
    name="${OPENVPN_USERNAME:-$(basename -s .env "$env")}"
    created="${OPENVPN_CREATED_AT:-unknown}"
    i=$((i + 1))
    printf '%-4s %-24s %s\n' "$i" "$name" "$created"
  done
  shopt -u nullglob
}

cmd_show() {
  local name="${1:-}"
  local kind="${2:-bundle}"
  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "User to show: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "No user selected."
  client_exists "$name" || die "User not found: $name"
  case "$kind" in
    udp) cat "$CLIENT_OUT_DIR/${name}-udp.ovpn" ;;
    tcp) cat "$CLIENT_OUT_DIR/${name}-tcp.ovpn" ;;
    auth|credentials|bundle) cat "$CLIENT_OUT_DIR/${name}-credentials.txt" ;;
    *) die "Unknown show type: $kind. Use udp, tcp, or credentials." ;;
  esac
}

cmd_qr() {
  local name="${1:-}"
  local kind="${2:-tcp}"
  local profile
  if [[ -z "$name" ]]; then
    cmd_list
    read -r -p "User to show QR: " name
  fi
  [[ "$name" =~ ^[0-9]+$ ]] && name="$(client_name_by_number "$name")"
  [[ -n "$name" ]] || die "No user selected."
  [[ "$kind" == "udp" || "$kind" == "tcp" ]] || die "QR type must be udp or tcp."
  profile="$CLIENT_OUT_DIR/${name}-${kind}.ovpn"
  [[ -r "$profile" ]] || die "Profile not found: $profile"
  have qrencode || die "qrencode is not installed. Run: apt-get install -y qrencode"
  if ! qrencode -t ANSIUTF8 < "$profile"; then
    die "OpenVPN profile is too large for QR. Use the .ovpn file instead: $profile"
  fi
}

print_status_file() {
  local proto="$1"
  local file="$2"
  [[ -r "$file" ]] || return 0
  awk -F, -v proto="$proto" '$1 == "CLIENT_LIST" {
    name=$2; real=$3; vpn=$4; rx=$6; tx=$7; since=$8;
    printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n", proto, name, real, vpn, rx, tx, since;
  }' "$file"
}

cmd_traffic() {
  local rows
  rows="$(print_status_file udp "$UDP_STATUS_FILE"; print_status_file tcp "$TCP_STATUS_FILE")"
  if [[ -z "$rows" ]]; then
    echo "No active OpenVPN sessions found."
    echo "Status files:"
    echo "  $UDP_STATUS_FILE"
    echo "  $TCP_STATUS_FILE"
    return 0
  fi

  printf '%-5s %-24s %-24s %-16s %14s %14s %s\n' "proto" "username" "real_address" "vpn_ip" "rx" "tx" "connected_since"
  while IFS=$'\t' read -r proto name real vpn_ip rx tx since; do
    printf '%-5s %-24s %-24s %-16s %14s %14s %s\n' \
      "$proto" "$name" "$real" "$vpn_ip" "$(bytes_human "$rx")" "$(bytes_human "$tx")" "$since"
  done <<< "$rows"
}

cmd_help() {
  cat <<'EOF'
Usage:
  openvpnctl add [username] [password]
  openvpnctl delete [username|number]
  openvpnctl passwd [username|number] [password]
  openvpnctl list
  openvpnctl show [username|number] [udp|tcp|credentials]
  openvpnctl qr [username|number] [udp|tcp]
  openvpnctl traffic

Notes:
  - add/passwd generate a random password if password is not provided.
  - traffic shows only currently connected sessions from OpenVPN status files.
EOF
}

main() {
  local cmd="${1:-help}"
  shift || true

  case "$cmd" in
    help|-h|--help) cmd_help; return 0 ;;
  esac

  require_root
  load_env
  ensure_dirs

  case "$cmd" in
    add) cmd_add "${1:-}" "${2:-}" ;;
    delete|del|remove|rm) cmd_delete "${1:-}" ;;
    passwd|password|reset-password) cmd_passwd "${1:-}" "${2:-}" ;;
    list|ls) cmd_list ;;
    show|profile) cmd_show "${1:-}" "${2:-bundle}" ;;
    qr|qrcode) cmd_qr "${1:-}" "${2:-tcp}" ;;
    traffic|stats|online) cmd_traffic ;;
    *) cmd_help; exit 1 ;;
  esac
}

main "$@"
