#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
export INSTALL_DIR="${INSTALL_DIR:-/root/vpnbot}"
export V3_SELECTED="$(python3 - "$INSTALL_DIR/servers.json" <<'PYCODE'
import json,sys
ids={'amneziawg':'amnezia20','amneziawg3':'amnezia31','vless':'vless','hysteria2':'hysteria2'}
print(','.join(ids[x['id']] for x in json.load(open(sys.argv[1]))))
PYCODE
)"
exec python3 "$ROOT/installer/verify.py"
