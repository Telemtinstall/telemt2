#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TEST_DIR/.." && pwd)"
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/mtproto-webproxy-test.XXXXXX")"
trap 'rm -rf "$TEST_TMP"' EXIT

export MTPROTO_WEBPROXY_SOURCE_ONLY=1
export STATE_FILE="$TEST_TMP/state"
export SAVED_CONFIG="$TEST_TMP/config"
# shellcheck disable=SC1091
source "$PROJECT_DIR/install.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [ "$actual" = "$expected" ] || \
    fail "$label: expected '$expected', got '$actual'"
}

assert_eq yes "$(normalize_yes_no Да)" "Russian yes"
assert_eq no "$(normalize_yes_no N)" "English no"

WEBPROXY_SECRET=dd0123456789abcdef0123456789abcdef
assert_eq 0123456789abcdef0123456789abcdef "$(backend_secret)" "dd backend secret"

WEBPROXY_SECRET=0123456789abcdef0123456789abcdef
DOMAIN=proxy.example.com
EMAIL=admin@proxy.example.com
ENABLE_SAFE_ACCESS_LOG=no
WEBPROXY_CARRIER=https
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
MTPROXY_NAT_INFO=auto
save_config

DOMAIN=
EMAIL=
WEBPROXY_SECRET=
load_saved_config
assert_eq proxy.example.com "$DOMAIN" "saved domain"
assert_eq admin@proxy.example.com "$EMAIL" "saved email"
assert_eq 0123456789abcdef0123456789abcdef "$WEBPROXY_SECRET" "saved WEB secret"

mark_done telemt
step_done telemt || fail "state marker was not persisted"

[[ "$TPROXY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "bad tproxy commit pin"
[[ "$TPROXY_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "bad tproxy archive hash"
[[ "$MTPROXY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "bad MTProxy commit pin"
[[ "$MTPROXY_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "bad MTProxy archive hash"

cat > "$TEST_TMP/debian-13" <<'EOF'
ID=debian
VERSION_ID="13"
PRETTY_NAME="Debian GNU/Linux 13"
EOF
OS_RELEASE_FILE="$TEST_TMP/debian-13"
detect_supported_os
assert_eq debian "$DETECTED_OS_ID" "Debian OS detection"
assert_eq 13 "$DETECTED_OS_VERSION_ID" "Debian version detection"

cat > "$TEST_TMP/ubuntu-24" <<'EOF'
ID=ubuntu
VERSION_ID="24.04"
PRETTY_NAME="Ubuntu 24.04 LTS"
EOF
OS_RELEASE_FILE="$TEST_TMP/ubuntu-24"
detect_supported_os
assert_eq ubuntu "$DETECTED_OS_ID" "Ubuntu 24 OS detection"
assert_eq 24.04 "$DETECTED_OS_VERSION_ID" "Ubuntu 24 version detection"

cat > "$TEST_TMP/ubuntu-26" <<'EOF'
ID=ubuntu
VERSION_ID="26.04"
PRETTY_NAME="Ubuntu 26.04 LTS"
EOF
OS_RELEASE_FILE="$TEST_TMP/ubuntu-26"
detect_supported_os
assert_eq ubuntu "$DETECTED_OS_ID" "Ubuntu 26 OS detection"

cat > "$TEST_TMP/ubuntu-22" <<'EOF'
ID=ubuntu
VERSION_ID="22.04"
PRETTY_NAME="Ubuntu 22.04 LTS"
EOF
if (
  OS_RELEASE_FILE="$TEST_TMP/ubuntu-22"
  detect_supported_os
) >/dev/null 2>&1; then
  fail "unsupported Ubuntu 22 was accepted"
fi

installer_source="$(<"$PROJECT_DIR/install.sh")"
[[ "$installer_source" == *"log_format mtproto_safe"* ]] || fail "safe log format missing"
[[ "$installer_source" == *'public_upstream: "http://127.0.0.1:8082"'* ]] || \
  fail "private public-site upstream missing"
[[ "$installer_source" == *"proxy_pass http://127.0.0.1:8080"* ]] || \
  fail "nginx relay integration missing"
[[ "$installer_source" == *"2398, 8888"* ]] || fail "backend firewall ports missing"
[[ "$installer_source" == *"ensure_full_installer_bundle"* ]] || \
  fail "standalone bootstrap missing"
[[ "$installer_source" == *"mtproto%2Bwebproxy.tar.gz"* ]] || \
  fail "bootstrap branch archive missing"

bash -n "$PROJECT_DIR/install.sh"
bash "$PROJECT_DIR/vendor/telemt-docker/tests/test-update-policy.sh"

printf 'OK: mtproto+webproxy installer tests passed.\n'
