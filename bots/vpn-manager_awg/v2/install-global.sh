#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == "--check" ]]; then
 exec bash "$ROOT_DIR/bots/vpn-manager_awg/install.sh" --local-source --dry-run
fi
exec bash "$ROOT_DIR/bots/vpn-manager_awg/install.sh" --local-source "$@"
