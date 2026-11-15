#!/usr/bin/env bash
# Local v4 entrypoint. Never fetch or overwrite another edition.
set -Eeuo pipefail
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ ! -f "$HERE/install-global.sh" || ! -f "$HERE/bots/vpn-manager_awg/SHA256SUMS" ]]; then
  echo 'Распакуйте полный архив Global v4 и запустите install-v4.sh из его каталога. Отдельный файл не скачивает другие версии.' >&2
  exit 1
fi
exec bash "$HERE/install-global.sh" "$@"
