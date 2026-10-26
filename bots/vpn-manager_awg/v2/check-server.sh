#!/usr/bin/env bash
# Read-only health check; no domain lookup required for installation success.
set -Eeuo pipefail
[[ $EUID == 0 ]] || { echo 'Запустите от root'; exit 1; }
failed=0
check() {
  local label="$1"; shift
  if "$@" >/dev/null 2>&1; then printf 'OK: %s\n' "$label";
  else printf 'ОШИБКА: %s\n' "$label"; failed=1; fi
}
for svc in vpnbot awg-quick@awg0 awg-quick@awg3 xray vpnbot-traffic.timer vpnbot-channel.timer; do
 check "$svc" systemctl is-active --quiet "$svc"
done
for ctl in awgctl awg3ctl vlessctl; do
 check "$ctl" /usr/local/sbin/"$ctl" -j list
done
check 'Xray config' /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json
check 'host (bind9-host)' test -x /usr/bin/host
check 'Настройки домена' python3 /usr/local/sbin/vpn_ip_switch.py domain-status
printf 'Сборка: '; cat /root/vpnbot/VPNBOT_VERSION
printf '\nVPN-порты:\n'
ss -lntu | awk 'NR==1 || /:(1234|1235|443)[[:space:]]/'
echo 'Проверка QR, подключения и доступа в Интернет выполняется отдельно на телефоне.'
exit "$failed"
