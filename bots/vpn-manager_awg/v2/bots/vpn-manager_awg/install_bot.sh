#!/usr/bin/env bash
set -Eeuo pipefail
GLOBAL_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
exec bash "$GLOBAL_ROOT/install-global.sh" "$@"
