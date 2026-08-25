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

installer_source="$(<"$PROJECT_DIR/install.sh")"
[[ "$installer_source" == *"log_format mtproto_safe"* ]] || fail "safe log format missing"
[[ "$installer_source" == *'public_upstream: "http://127.0.0.1:8082"'* ]] || \
  fail "private public-site upstream missing"
[[ "$installer_source" == *"proxy_pass http://127.0.0.1:8080"* ]] || \
  fail "nginx relay integration missing"
[[ "$installer_source" == *"2398, 8888"* ]] || fail "backend firewall ports missing"

bash -n "$PROJECT_DIR/install.sh"
bash "$PROJECT_DIR/vendor/telemt-docker/tests/test-update-policy.sh"

printf 'OK: mtproto+webproxy installer tests passed.\n'
