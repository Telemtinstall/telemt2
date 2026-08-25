#!/usr/bin/env bash
set -Eeuo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$TEST_DIR/.." && pwd)"
INSTALLER="$PROJECT_DIR/install.sh"
[ ! -f "$PROJECT_DIR/webproxy-install.sh" ] || INSTALLER="$PROJECT_DIR/webproxy-install.sh"
export WEBPROXY_ONLY_SOURCE_ONLY=1
# shellcheck disable=SC1091
source "$INSTALLER"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$1', got '$2'"
}

DOMAIN=Proxy.Example.COM.
EMAIL=
WEBPROXY_SECRET=0123456789ABCDEF0123456789ABCDEF
MTPROXY_WORKERS=1
MTPROXY_MAX_CONNECTIONS=4096
collect_inputs
assert_eq proxy.example.com "$DOMAIN" "domain normalization"
assert_eq admin@proxy.example.com "$EMAIL" "default email"
assert_eq 0123456789abcdef0123456789abcdef "$WEBPROXY_SECRET" "secret normalization"

[[ "$TPROXY_COMMIT" =~ ^[0-9a-f]{40}$ ]] || fail "bad tproxy commit"
[[ "$TPROXY_ARCHIVE_SHA256" =~ ^[0-9a-f]{64}$ ]] || fail "bad archive hash"

source_text="$(<"$INSTALLER")"
[[ "$source_text" == *'TLS frontend:         nginx + certbot'* ]] || fail "nginx/certbot plan missing"
[[ "$source_text" == *'certbot certonly --webroot'* ]] || fail "certbot webroot issue missing"
[[ "$source_text" == *'systemctl enable --now certbot.timer'* ]] || fail "certbot timer missing"
[[ "$source_text" == *'reload-nginx-webproxy'* ]] || fail "certbot deploy hook missing"
[[ "$source_text" != *'systemctl is-active --quiet caddy'* ]] || fail "Caddy validation remains"
[[ "$source_text" == *'/anal/data.json'* ]] || fail "analytics data route missing"
[[ "$source_text" == *'openssl rand -hex 5'* ]] || fail "10-character credentials missing"
[[ "$source_text" == *'webproxy-analytics.service'* ]] || fail "analytics service missing"
[[ "$source_text" == *'access_log /var/log/tproxy/access.log webproxy_transport'* ]] || fail "selective transport log missing"
[[ "$source_text" == *'map_hash_bucket_size 64'* ]] || fail "nginx map hash size missing"
[[ "$source_text" == *'This website is available.'* ]] || fail "legacy landing-page upgrade detection missing"
[[ "$source_text" == *'<html lang="en">'* ]] || fail "English landing language missing"
[[ "$source_text" == *'Connectivity'*'without borders.'* ]] || fail "English landing headline missing"
[[ "$source_text" == *'machine-scene'* ]] || fail "landing animation missing"
[[ "$source_text" == *'@keyframes spin'* ]] || fail "landing spin animation missing"
[[ "$source_text" == *'webproxy_cli -add USER'* ]] || fail "webproxy_cli add missing"
[[ "$source_text" == *'webproxy_cli -delete USER'* ]] || fail "webproxy_cli delete missing"
[[ "$source_text" == *'Удалить пользователя'* ]] || fail "webproxy_cli confirmation missing"
[[ "$source_text" == *'нельзя удалить последнего пользователя'* ]] || fail "last-user protection missing"
[[ "$source_text" == *'for secret in "${secrets[@]}"; do args+=(-S "$secret")'* ]] || fail "multiple MTProxy secrets missing"
[[ "$source_text" == *'t.me/webproxy'* ]] || fail "WEB proxy link missing"
[[ "$source_text" == *'umask 022'* ]] || fail "Go test umask fix missing"
[[ "$source_text" == *'chmod 0755 "$build_directory"'* ]] || fail "MTProxy permission fix missing"
[[ "$source_text" == *'run-webproxy-mtproxy'* ]] || fail "NAT-aware MTProxy runner missing"
[[ "$source_text" == *'/root/webproxy-install-summary.txt'* ]] || fail "unified install summary missing"
[[ "$source_text" == *'WEB PROXY INSTALLATION SUMMARY'* ]] || fail "summary header missing"
[[ "$source_text" == *'write_install_summary'* ]] || fail "summary finalizer missing"

bash -n "$INSTALLER"
BOOTSTRAP="$PROJECT_DIR/bootstrap.sh"
[ ! -f "$PROJECT_DIR/webproxy-install.sh" ] || BOOTSTRAP="$PROJECT_DIR/install.sh"
if [ -f "$BOOTSTRAP" ]; then
  bash -n "$BOOTSTRAP"
  bootstrap_text="$(<"$BOOTSTRAP")"
  [[ "$bootstrap_text" == *'https://github.com/Telemtinstall/telemt2.git'* ]] || fail "bootstrap repository missing"
  [[ "$bootstrap_text" == *'INSTALL_ROOT="/opt/teleminstall"'* ]] || fail "bootstrap managed checkout missing"
  [[ "$bootstrap_text" == *'PAYLOAD="teleminstall/webproxy-install.sh"'* ]] || fail "bootstrap payload missing"
  [[ "$bootstrap_text" == *'git -C "$INSTALL_ROOT" fetch --depth 1 origin "$REPOSITORY_BRANCH"'* ]] || fail "bootstrap update missing"
fi
test_tmp="$(mktemp -d)"
trap 'rm -rf "$test_tmp"' EXIT
collector="$test_tmp/collector.py"
sed -n '/^  cat > \/usr\/local\/lib\/webproxy-analytics\/collector.py <<'"'"'PY'"'"'$/,/^PY$/p' "$INSTALLER" | sed '1d;$d' > "$collector"
python3 -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' "$collector"
cli="$test_tmp/webproxy_cli.py"
sed -n '/^  cat > \/usr\/local\/sbin\/webproxy_cli <<'"'"'PY'"'"'$/,/^PY$/p' "$INSTALLER" | sed '1d;$d' > "$cli"
python3 -c 'import pathlib,sys; compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec")' "$cli"

DOMAIN=proxy.example.com
write_default_site "$test_tmp/site"
grep -Fq '<html lang="en">' "$test_tmp/site/index.html" || fail "generated landing is not English"
grep -Fq 'class="machine-scene"' "$test_tmp/site/index.html" || fail "generated landing animation missing"
grep -Fq '@keyframes spin' "$test_tmp/site/index.html" || fail "generated landing spin missing"
python3 -c 'import pathlib,re,sys; text=pathlib.Path(sys.argv[1]).read_text(); assert not re.search(r"[А-Яа-яЁё]", text)' "$test_tmp/site/index.html"

python3 - "$cli" "$test_tmp/summary-test" <<'PY'
import pathlib
import sys

namespace = {"__name__": "webproxy_cli_test"}
exec(compile(pathlib.Path(sys.argv[1]).read_text(), sys.argv[1], "exec"), namespace)
root = pathlib.Path(sys.argv[2])
root.mkdir()
namespace["SECRETS"] = root / "secrets"
namespace["LINKS"] = root / "users.txt"
namespace["LEGACY_LINKS"] = root / "legacy.txt"
namespace["SUMMARY"] = root / "summary.txt"
namespace["ANALYTICS_CREDENTIALS"] = root / "analytics.txt"
namespace["ANALYTICS_CREDENTIALS"].write_text("url=https://proxy.example.com/anal/\nlogin=0123456789\npassword=abcdefghij\n")

def local_write(path, content, mode=0o600, group=None):
    pathlib.Path(path).write_text(content)

namespace["write_private"] = local_write
namespace["sync_auxiliary"]([
    {"name": "default", "secret": "0123456789abcdef0123456789abcdef", "backend": "127.0.0.1:2398"}
], "proxy.example.com")
summary = namespace["SUMMARY"].read_text()
assert "WEB PROXY INSTALLATION SUMMARY" in summary
assert "login=0123456789" in summary
assert "password=abcdefghij" in summary
assert "t.me/webproxy?server=proxy.example.com" in summary
assert "webproxy_cli -add USER" in summary
PY
printf 'OK: webproxy-only offline tests passed.\n'
