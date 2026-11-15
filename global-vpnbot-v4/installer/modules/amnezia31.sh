#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# Original AWG installer/controller; independent 3.1 instance, unchanged profile format.
export AWG_OBFS_PROFILE=awg3 AWG_IFACE=awg3 AWG_PORT="${AWG31_PORT:-1235}"
export AWG_SUBNET=10.89.89.0/24 AWG_SERVER_IP=10.89.89.1
export PUBLIC_ENDPOINT="$VPN_PUBLIC_HOST" CLIENT_NAME="$VPN_INITIAL_CLIENT"
export CLIENT_DIR=/etc/amnezia/amneziawg/clients-awg3 CLIENT_OUT_DIR=/root/amneziawg3-clients
export ENV_FILE=/etc/amnezia/amneziawg/awg3ctl.env CTL_PATH=/usr/local/sbin/awg3ctl CTL_BIN_PATH=/usr/local/bin/awg3ctl
export STATE_FILE=/root/.install_amneziawg3.state RESUME_CONFIG=/root/.install_amneziawg3.config
export CONFIG_HASH_FILE=/root/.install_amneziawg3.config.sha256 BACKUP_ROOT=/root/amneziawg3-install-backups
export SERVER_PRIVATE_KEY_FILE=/etc/amnezia/amneziawg/server_private_awg3.key
export SERVER_PUBLIC_KEY_FILE=/etc/amnezia/amneziawg/server_public_awg3.key
export AWG_RESUME_COMMAND="${AWG_RESUME_COMMAND:-bash $ROOT/install-global.sh}"
if [[ -e /etc/amnezia/amneziawg/awg3.conf && ! -s "$STATE_FILE" ]]; then
  echo 'AWG 3.1 уже настроен; автоматическая перезапись запрещена' >&2; exit 1
fi
exec bash "$ROOT/vpn/amneziawg/install_amneziawg.sh"
