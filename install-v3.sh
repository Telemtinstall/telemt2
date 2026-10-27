#!/usr/bin/env bash
# Pinned Global v3 downloader; keeps v2 and default installers unchanged.
set -Eeuo pipefail
VERSION=global-v3-2026.10.27.8
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$HERE/install-global.sh" && -f "$HERE/bots/vpn-manager_awg/SHA256SUMS" ]]; then
  exec bash "$HERE/install-global.sh" "$@"
fi
for argument in "$@"; do
  case "$argument" in
    --help|-h)
      echo "Global v3: $VERSION"
      echo 'Запуск: bash install-v3.sh [--check] [--silent --config /root/install.local.ini]'
      echo 'Повторный запуск продолжает установку. После reboot можно повторить ту же команду.'
      exit 0
      ;;
  esac
done
# Three-line bootstrap progress. Never use for protocol/profile commands.
v3_progress_run() {
  local label="$1"; shift
  local detail_log child rc frame=0 v3_frame group=0 old_int old_term columns width
  old_int="$(trap -p INT)"; old_term="$(trap -p TERM)"
  umask 077
  detail_log="$(mktemp "${TMPDIR:-/tmp}/vpnbot-bootstrap.XXXXXXXX")"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$detail_log" 2>&1 &
    group=1
  else
    "$@" >"$detail_log" 2>&1 &
  fi
  child=$!
  trap 'if ((group)); then kill -TERM -- "-$child" 2>/dev/null || true; else kill -TERM "$child" 2>/dev/null || true; fi; wait "$child" 2>/dev/null || true; rm -f -- "$detail_log"; trap - INT TERM; eval "$old_int"; eval "$old_term"; return 130' INT TERM
  if [[ -t 2 && "${TERM:-}" != dumb ]]; then
    columns="$(tput cols 2>/dev/null || echo 80)"
    [[ "$columns" =~ ^[0-9]+$ ]] || columns=80
    width=$((columns > 10 ? columns - 1 : 9))
    printf '%.*s\n%.*s  |\n%.*s\n' "$width" 'Global v3 · подготовка' "$((width - 3))" "$label" "$width" 'Пожалуйста, дождитесь завершения' >&2
    while kill -0 "$child" 2>/dev/null; do
      case $((frame % 4)) in 0) v3_frame='|' ;; 1) v3_frame='/' ;; 2) v3_frame='-' ;; 3) v3_frame='\' ;; esac
      printf '\033[2A\r\033[2K%.*s  %s\033[2B\r' "$((width - 3))" "$label" "$v3_frame" >&2
      frame=$((frame + 1)); sleep 0.15
    done
    printf '\033[3A\r\033[2K\n\033[2K\n\033[2K\n\033[3A' >&2
  else
    printf '%s\n' "$label" >&2
  fi
  if wait "$child"; then rc=0; else rc=$?; fi
  trap - INT TERM; eval "$old_int"; eval "$old_term"
  if ((rc)); then
    tail -n 1 "$detail_log" >&2
    printf 'Ошибка этапа: %s (код %s)\n' "$label" "$rc" >&2
    printf 'Журнал: %s\n' "$detail_log" >&2
  else
    rm -f -- "$detail_log"
  fi
  return "$rc"
}

DEST="${VPNBOT_V3_DOWNLOAD_DIR:-/root/vpnbot-${VERSION}}"
URL="https://github.com/Telemtinstall/telemt2/archive/refs/tags/${VERSION}.tar.gz"
if [[ -e "$DEST" && ! -f "$DEST/install-global.sh" ]]; then
  echo "Каталог $DEST существует, но не содержит пакет v3; перезапись запрещена." >&2
  exit 1
fi
if [[ ! -f "$DEST/install-global.sh" ]]; then
  for required in curl python3 sha256sum; do
    command -v "$required" >/dev/null || { echo "Не найден $required. Установите ca-certificates curl python3 перед загрузкой." >&2; exit 1; }
  done
  umask 077
  parent="$(dirname -- "$DEST")"
  [[ -d "$parent" && -w "$parent" ]] || { echo "Нет доступа к каталогу $parent" >&2; exit 1; }
  stage="$(mktemp -d "$parent/.vpnbot-v3.XXXXXXXX")"
  trap 'rm -rf -- "$stage"' EXIT
  v3_progress_run 'Идёт загрузка Global v3' curl --silent --show-error --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 300 "$URL" -o "$stage/source.tar.gz"
  python3 - "$stage" "$VERSION" <<'PY'
from pathlib import Path, PurePosixPath
import sys, tarfile
stage=Path(sys.argv[1])
prefix='telemt2-'+sys.argv[2]+'/bots/vpn-manager_awg/v3/'
with tarfile.open(stage/'source.tar.gz','r:gz') as archive:
    members=[]
    for member in archive.getmembers():
        if not member.name.startswith(prefix):continue
        relative=member.name[len(prefix):]
        if not relative:continue
        path=PurePosixPath(relative)
        if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):
            raise SystemExit('Unsafe v3 archive entry')
        member.name=relative
        members.append(member)
    if not members:raise SystemExit('Каталог v3 отсутствует в архиве')
    archive.extractall(stage/'package',members=members,filter='data')
PY
  v3_progress_run 'Идёт проверка загруженного пакета' bash "$stage/package/install-global.sh" --check
  [[ ! -e "$DEST" ]] || { echo "Каталог $DEST появился во время загрузки; перезапись запрещена." >&2; exit 1; }
  mv "$stage/package" "$DEST"
  rm -rf -- "$stage"
  trap - EXIT
fi
[[ "$(cat "$DEST/bots/vpn-manager_awg/INSTALLER_VERSION")" == "$VERSION" ]] || { echo "В каталоге загрузки другая версия; запуск запрещён." >&2; exit 1; }
# The Python coordinator checks the manifest on every invocation.
exec bash "$DEST/install-global.sh" "$@"
