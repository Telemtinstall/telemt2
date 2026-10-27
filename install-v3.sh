#!/usr/bin/env bash
# Pinned Global v3 downloader; keeps v2 and default installers unchanged.
set -Eeuo pipefail
VERSION=global-v3-2026.10.27.4
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
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 300 "$URL" -o "$stage/source.tar.gz"
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
  bash "$stage/package/install-global.sh" --check
  [[ ! -e "$DEST" ]] || { echo "Каталог $DEST появился во время загрузки; перезапись запрещена." >&2; exit 1; }
  mv "$stage/package" "$DEST"
  rm -rf -- "$stage"
  trap - EXIT
fi
[[ "$(cat "$DEST/bots/vpn-manager_awg/INSTALLER_VERSION")" == "$VERSION" ]] || { echo "В каталоге загрузки другая версия; запуск запрещён." >&2; exit 1; }
bash "$DEST/install-global.sh" --check
exec bash "$DEST/install-global.sh" "$@"
