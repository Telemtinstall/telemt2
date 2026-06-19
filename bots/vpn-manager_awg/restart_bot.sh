#!/usr/bin/env bash
set -euo pipefail

SERVICE="${1:-vpnbot.service}"

systemctl restart "$SERVICE"
sleep 1

if systemctl is-active --quiet "$SERVICE"; then
  echo "$SERVICE active"
  exit 0
fi

echo "$SERVICE failed"
systemctl status "$SERVICE" --no-pager -l
exit 1
