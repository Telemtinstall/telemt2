#!/usr/bin/env bash
# Standalone downloader for the Global v2 release. No registrar API.
set -Eeuo pipefail
VERSION=global-v2-2026.10.26.2
DEST="/root/vpnbot-global-v2-${VERSION}"
URL="https://github.com/Telemtinstall/telemt2/archive/refs/tags/${VERSION}.tar.gz"
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# The same entry point also works inside the complete downloaded package.
if [[ -f "$HERE/install-global.sh" && -f "$HERE/bots/vpn-manager_awg/SHA256SUMS" ]]; then
 exec bash "$HERE/install-global.sh" "$@"
fi
case "${1:-}" in
 --help|-h) echo "Запуск: bash install-v2.sh [--check]. Пакет: $VERSION. Повторный запуск продолжает установку."; exit 0 ;;
esac
[[ $EUID == 0 ]] || { echo 'Запустите от root'; exit 1; }
if [[ ! -f "$DEST/install-global.sh" ]]; then
 for cmd in curl tar python3 sha256sum; do
  command -v "$cmd" >/dev/null || { echo "Не найден $cmd. Установите: apt-get update && apt-get install -y ca-certificates curl python3"; exit 1; }
 done
 umask 077
 stage="$(mktemp -d /root/.vpnbot-global-v2.XXXXXXXX)"
 trap 'rm -rf -- "$stage"' EXIT
 curl --fail --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 15 --max-time 300 "$URL" -o "$stage/source.tar.gz"
 # Extract only v2 regular files/directories; reject traversal and symlinks.
 python3 - "$stage" <<'PYEXTRACT'
from pathlib import Path, PurePosixPath
import sys, tarfile
stage=Path(sys.argv[1]); prefix="telemt2-global-v2-2026.10.26.2/bots/vpn-manager_awg/v2/"
with tarfile.open(stage/'source.tar.gz', 'r:gz') as archive:
    members=[]
    for member in archive.getmembers():
        if not member.name.startswith(prefix): continue
        relative=member.name[len(prefix):]
        if not relative: continue
        path=PurePosixPath(relative)
        if path.is_absolute() or '..' in path.parts or not (member.isfile() or member.isdir()):
            raise SystemExit('Unsafe archive entry')
        member.name=relative
        members.append(member)
    if not members: raise SystemExit('v2 missing from archive')
    archive.extractall(stage/'package', members=members, filter='data')
PYEXTRACT
 bash "$stage/package/install-global.sh" --check
 [[ ! -e "$DEST" ]] || { echo "Каталог $DEST уже существует; проверьте его перед повтором"; exit 1; }
 mv "$stage/package" "$DEST"
 rm -rf -- "$stage"
 trap - EXIT
fi
bash "$DEST/install-global.sh" --check
exec bash "$DEST/install-global.sh" "$@"
