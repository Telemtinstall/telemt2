#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export VPNBOT_INSTALL_LIBRARY=1
source <(sed '$d' "$ROOT/bots/vpn-manager_awg/install.sh")
SCRIPT_DIR="$ROOT/bots/vpn-manager_awg"
REPO_DIR="$ROOT"
LOCAL_SOURCE=1
bot_resume_command() { printf '%s' "$AWG_RESUME_COMMAND"; }
case "${1:-}" in
  backup) backup_endpoint_components; backup_existing_bot ;;
  amnezia20) export AWG_PORT="${AWG20_PORT:-1234}"; ensure_awg ;;
  vless)
    export HTTPS_PORT="${VLESS_PORT:-443}"
    if [[ "$VLESS_MODE" == mask ]]; then
      export PUBLIC_HOST="$VLESS_DOMAIN" CLIENT_NAME="$VPN_INITIAL_CLIENT"
      bash "$ROOT/vpn/vless/install_vless.sh" --mask --auto -lang ru
    else
      ensure_vless
    fi
    ;;
  bot)
    validate_token
    install_bot_files
    install -m 0755 "$SCRIPT_DIR/worker.py" "$INSTALL_DIR/worker.py"
    python3 - "$SCRIPT_DIR/servers.json" "$INSTALL_DIR/servers.json" "$V3_SELECTED" <<'PY'
import json,sys
from pathlib import Path
names={'amnezia20':'amneziawg','amnezia31':'amneziawg3','vless':'vless','hysteria2':'hysteria2'}
selected={names[x] for x in sys.argv[3].split(',')}
p=Path(sys.argv[2]); servers=json.loads(Path(sys.argv[1]).read_text())
servers.append({'id':'hysteria2','title':'Hysteria 2','protocol':'hysteria2','transport':'local','command':'/usr/local/sbin/hysteria2ctl','service':'hysteria2.service'})
p.write_text(json.dumps([s for s in servers if s['id'] in selected],ensure_ascii=False,indent=2)+'\n')
PY
    write_env
    delete_webhook
    install_units
    systemctl enable --now vpnbot-worker.service
    configure_log_retention
    python3 -m py_compile "$INSTALL_DIR/worker.py" "$INSTALL_DIR/bot.py" "$INSTALL_DIR"/app/*.py
    systemctl is-active --quiet vpnbot.service
    systemctl is-active --quiet vpnbot-worker.service
    ;;
  *) die 'unknown bridge phase' ;;
esac
