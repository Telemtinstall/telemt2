#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if ! command -v python3 >/dev/null 2>&1; then
  for argument in "$@"; do
    case "$argument" in
      --check|--dry-run|--help|-h)
        echo 'Для проверки пакета, INI и полной справки требуется Python 3. Системные изменения не выполнялись.' >&2
        exit 1
        ;;
    esac
  done
  if [[ "$(uname -s)" != Linux || "$(id -u)" != 0 ]]; then
    echo 'Для установки нужен root на Linux и Python 3.' >&2
    exit 1
  fi
  (cd "$ROOT_DIR/bots/vpn-manager_awg" && sha256sum --check --quiet SHA256SUMS)
  echo 'Подготовка Python 3 перед проверкой ядра. Вопросы о VPN пока не задаются.'
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l
  apt-get update
  apt-get install -y python3
fi
exec python3 "$ROOT_DIR/installer/install.py" "$@"
