#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$TEST_DIR/../install_docker-telemt.sh"
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/telemt-3424-test.XXXXXX")"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Load installer functions without executing main.
TELEMT_INSTALLER_SOURCE_ONLY=1
source "$INSTALLER"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || fail "$label: expected '$expected', got '$actual'"
}

TELEMT_VERSION_ENV_SET=0
TELEMT_VERSION_ENV_VALUE=""
TELEMT_LATEST_COMPATIBLE_VERSION="3.4.24"
TELEMT_UPDATE_TARGET_VERSION=""
resolve_update_target_version
assert_eq "3.4.24" "$TELEMT_UPDATE_TARGET_VERSION" "default update target"

TELEMT_DETECTED_VERSION="3.4.23"
prevent_update_downgrade
TELEMT_DETECTED_VERSION="3.4.18"
prevent_update_downgrade

if (
  SCRIPT_LANG=en
  TELEMT_DETECTED_VERSION="3.4.25"
  TELEMT_UPDATE_TARGET_VERSION="3.4.24"
  prevent_update_downgrade
) >/dev/null 2>&1; then
  fail "newer installed version was allowed to downgrade"
fi

TELEMT_IMAGE="telemt-local:3.4.24"
TELEMT_VERSION="3.4.24"
assert_eq "3.4.24" "$(expected_telemt_version)" "expected image version"

INSTALL_DIR="$TMP_ROOT/install"
mkdir -p "$INSTALL_DIR"

cat > "$INSTALL_DIR/telemt.toml" <<'EOF'
[general]
config_strict = true

[general.links]
public_host = "proxy.example.com"

[server]
port = 1443
client_mss = "2in8"

[[server.listeners]]
ip = "127.0.0.1"
client_mss = "2in8"

[server.api]
enabled = true
listen = "127.0.0.1:9091"

[censorship]
tls_domain = "proxy.example.com"

[access.users]
"default" = "0123456789abcdef0123456789abcdef"

[[upstreams]]
type = "direct"
enabled = true
prefer = "ipv4"
EOF

cat > "$INSTALL_DIR/docker-compose.yml" <<'EOF'
services:
  telemt:
    image: telemt-local:3.4.23
    container_name: telemt
    restart: unless-stopped
    ports:
      - "1443:1443"
EOF

DOMAIN="proxy.example.com"
PUBLIC_IP="203.0.113.10"
TELEMT_CLIENT_MSS="tspu"
TELEMT_CLIENT_MSS_BULK="1400"
TELEMT_SYNLIMIT="false"
TELEMT_VERSION="3.4.24"

before_secret="$(awk -F'"' '/^"default"/{print $4}' "$INSTALL_DIR/telemt.toml")"
apply_telemt_config_compat_updates
apply_compose_runtime_compat_updates
patch_compose_image_ref "telemt-local:3.4.24"
after_secret="$(awk -F'"' '/^"default"/{print $4}' "$INSTALL_DIR/telemt.toml")"

assert_eq "$before_secret" "$after_secret" "Telemt user secret"
grep -q '^client_mss = "2in8"$' "$INSTALL_DIR/telemt.toml" || fail "manual server client_mss was overwritten"
grep -q '^"default" = true$' "$INSTALL_DIR/telemt.toml" || fail "access.user_enabled was not added"
grep -q '^ipv4 = true$' "$INSTALL_DIR/telemt.toml" || fail "upstream IPv4 policy was not added"
grep -q '^ipv6 = false$' "$INSTALL_DIR/telemt.toml" || fail "upstream IPv6 policy was not added"
! grep -q '^prefer[[:space:]]*=' "$INSTALL_DIR/telemt.toml" || fail "obsolete upstream prefer key remains"
! grep -q 'direct_relay_buffer_budget_max_bytes' "$INSTALL_DIR/telemt.toml" || fail "rollback-unsafe Direct Relay key was added"
! grep -q 'me_writer_byte_budget_bytes' "$INSTALL_DIR/telemt.toml" || fail "rollback-unsafe ME Writer key was added"
grep -q '^    image: telemt-local:3.4.24$' "$INSTALL_DIR/docker-compose.yml" || fail "compose image was not updated"
grep -q '^    network_mode: host$' "$INSTALL_DIR/docker-compose.yml" || fail "host network mode was not added"
grep -q '/run/telemt:' "$INSTALL_DIR/docker-compose.yml" || fail "runtime tmpfs was not added"
! grep -q '^    ports:' "$INSTALL_DIR/docker-compose.yml" || fail "ports block remains with host networking"

curl() {
  printf '%s\n' \
    'telemt_direct_relay_buffer_budget_bytes{kind="hard_limit"} 67108864' \
    'telemt_me_writer_byte_budget_limit_bytes 33570816' \
    'telemt_buffer_pool_buffers_total{kind="pooled"} 0'
}
verify_telemt_3424_metrics "3.4.24" >/dev/null

if (
  SCRIPT_LANG=en
  curl() { printf '%s\n' 'telemt_direct_relay_buffer_budget_bytes 1'; }
  verify_telemt_3424_metrics "3.4.24"
) >/dev/null 2>&1; then
  fail "missing Telemt 3.4.24 memory metrics were accepted"
fi

TELEMT_UPDATE_BACKUP_DIR="$TMP_ROOT/rollback"
mkdir -p "$TELEMT_UPDATE_BACKUP_DIR"
cat > "$TELEMT_UPDATE_BACKUP_DIR/telemt.toml" <<'EOF'
[access.users]
"default" = "0123456789abcdef0123456789abcdef"
EOF
cat > "$TELEMT_UPDATE_BACKUP_DIR/docker-compose.yml" <<'EOF'
services:
  telemt:
    image: telemt-local:3.4.23
EOF
SECRET_FILE="$INSTALL_DIR/telemt-secret.env"
SAVED_CONFIG="$TMP_ROOT/.install_docker_telemt.config"
printf 'TELEMT_SECRET=0123456789abcdef0123456789abcdef\n' > "$TELEMT_UPDATE_BACKUP_DIR/telemt-secret.env"
printf 'TELEMT_SECRET=changed\n' > "$SECRET_FILE"
printf 'changed\n' > "$INSTALL_DIR/telemt.toml"
printf 'changed\n' > "$INSTALL_DIR/docker-compose.yml"

start_telemt() {
  [ "$TELEMT_IMAGE" = "telemt-local:3.4.23" ]
}
fix_runtime_permissions() {
  return 0
}
curl() {
  return 0
}

restore_update_core_state || fail "automatic rollback core state failed"
grep -q 'telemt-local:3.4.23' "$INSTALL_DIR/docker-compose.yml" || fail "rollback did not restore old compose image"
grep -q '0123456789abcdef0123456789abcdef' "$INSTALL_DIR/telemt.toml" || fail "rollback did not restore old user secret"
grep -q 'TELEMT_SECRET=0123456789abcdef0123456789abcdef' "$SECRET_FILE" || fail "rollback did not restore secret file"

printf 'OK: Telemt 3.4.24 update policy and config preservation tests passed.\n'
