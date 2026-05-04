#!/usr/bin/env bash
set -uo pipefail

# Telemt/Nginx/WireGuard status report for a single-host setup.
# Usage: telemt-report [since]
# Example: telemt-report 10m

SINCE="${1:-5m}"
TOP_N="${TOP_N:-20}"
API_URL="${API_URL:-http://127.0.0.1:9091}"
CONTAINER="${CONTAINER:-telemt}"
WG_IF="${WG_IF:-wg0}"

tmp_clients="$(mktemp)"
trap 'rm -f "$tmp_clients"' EXIT

have() {
  command -v "$1" >/dev/null 2>&1
}

section() {
  printf '\n=== %s ===\n' "$1"
}

bytes_human() {
  local value="${1:-0}"
  if have numfmt; then
    numfmt --to=iec --suffix=B "$value" 2>/dev/null || printf '%sB' "$value"
  else
    printf '%sB' "$value"
  fi
}

mask_secrets() {
  sed -E \
    -e 's/(secret=)[0-9a-fA-F]+/\1***REDACTED***/g' \
    -e 's/[0-9a-fA-F]{32,}/***REDACTED***/g' \
    -e 's/("tls":\["?)[^]",}]+/\1REDACTED/g'
}

json_field_string() {
  local json="$1"
  local key="$2"
  printf '%s' "$json" | grep -oE "\"${key}\":\"[^\"]*\"" | head -n 1 | sed -E "s/^\"${key}\":\"(.*)\"$/\\1/"
}

json_field_number_or_null() {
  local json="$1"
  local key="$2"
  local value
  value="$(printf '%s' "$json" | grep -oE "\"${key}\":(null|[0-9]+)" | head -n 1 | sed -E "s/^\"${key}\"://")"
  [ -n "$value" ] && printf '%s' "$value" || printf 'null'
}

api_get() {
  curl -fsS --max-time 3 "${API_URL}$1" 2>/dev/null || true
}

service_state() {
  systemctl is-active "$1" 2>/dev/null || printf 'unknown'
}

count_recent_logs() {
  local pattern="$1"
  docker logs --since "$SINCE" "$CONTAINER" 2>&1 | grep -Ec "$pattern" || true
}

peer_ip_from_ss() {
  # ss -H -ant columns: State Recv-Q Send-Q Local:Port Peer:Port
  awk '
    {
      peer=$4
      sub(/^\[/, "", peer)
      sub(/\]:[0-9]+$/, "", peer)
      sub(/:[0-9]+$/, "", peer)
      if (peer != "") print peer
    }
  '
}

section "SUMMARY"
printf 'time:          %s\n' "$(date -Is)"
printf 'host:          %s\n' "$(hostname -f 2>/dev/null || hostname)"
printf 'kernel:        %s\n' "$(uname -srmo)"
printf 'uptime:        %s\n' "$(uptime | sed 's/^ //')"

telemt_running="no"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  telemt_running="$(docker inspect "$CONTAINER" --format '{{if .State.Running}}yes{{else}}no{{end}}' 2>/dev/null || printf no)"
fi

api_users="$(api_get /v1/users)"
api_ok="no"
if printf '%s' "$api_users" | grep -q '"ok":true'; then
  api_ok="yes"
fi

listener_443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:443$/ {print; found=1} END{exit !found}' >/dev/null 2>&1 && printf yes || printf no)"
listener_1443="$(ss -H -lnt 2>/dev/null | awk '$4 ~ /:1443$/ {print; found=1} END{exit !found}' >/dev/null 2>&1 && printf yes || printf no)"

ss -H -ant state established 'sport = :443' 2>/dev/null | peer_ip_from_ss > "$tmp_clients"
conn_443="$(wc -l < "$tmp_clients" | tr -d ' ')"
uniq_443="$(sort -u "$tmp_clients" | grep -c . || true)"

limit_errors="$(count_recent_logs 'User limit|exceeded connection limit')"
me_errors="$(count_recent_logs 'ME pool is NOT ready|ME pool is not ready|All ME servers|Upstream failed')"

status="OK"
reasons=()
[ "$telemt_running" = "yes" ] || { status="BAD"; reasons+=("telemt container is not running"); }
[ "$api_ok" = "yes" ] || { status="BAD"; reasons+=("telemt API is not reachable"); }
[ "$listener_443" = "yes" ] || { status="BAD"; reasons+=("external 443 listener is missing"); }
[ "$listener_1443" = "yes" ] || { status="BAD"; reasons+=("telemt backend 1443 listener is missing"); }
[ "$limit_errors" = "0" ] || reasons+=("recent user limit errors: $limit_errors")
[ "$me_errors" = "0" ] || reasons+=("recent ME/upstream warnings: $me_errors")

printf 'health:        %s\n' "$status"
printf 'telemt:        running=%s api=%s backend_1443=%s\n' "$telemt_running" "$api_ok" "$listener_1443"
printf 'front door:    nginx_or_listener_443=%s established_443=%s unique_peer_ips=%s\n' "$listener_443" "$conn_443" "$uniq_443"
if [ "${#reasons[@]}" -gt 0 ]; then
  printf 'notes:\n'
  for reason in "${reasons[@]}"; do
    printf '  - %s\n' "$reason"
  done
fi

section "TELEMT USERS"
if [ -n "$api_users" ] && [ "$api_ok" = "yes" ]; then
  if have jq; then
    printf '%s\n' "$api_users" | jq -r '
      .data[] |
      [
        .username,
        (.current_connections | tostring),
        ((.max_tcp_conns // "unlimited") | tostring),
        (.active_unique_ips // 0 | tostring),
        (.recent_unique_ips // 0 | tostring),
        (.total_octets // 0 | tostring)
      ] | @tsv
    ' | while IFS=$'\t' read -r user current max active recent octets; do
      printf '%-18s connections=%s/%s api_active_ips=%s api_recent_ips=%s traffic=%s\n' \
        "$user" "$current" "$max" "$active" "$recent" "$(bytes_human "$octets")"
    done
  else
    users_payload="$(printf '%s' "$api_users" | sed -E 's/^\{"ok":true,"data":\[//; s/\],"revision":.*$//; s/\},\{/\}\n\{/g')"
    printf '%s\n' "$users_payload" | while IFS= read -r user_json; do
      [ -n "$user_json" ] || continue
      user="$(json_field_string "$user_json" username)"
      current="$(json_field_number_or_null "$user_json" current_connections)"
      max="$(json_field_number_or_null "$user_json" max_tcp_conns)"
      active="$(json_field_number_or_null "$user_json" active_unique_ips)"
      recent="$(json_field_number_or_null "$user_json" recent_unique_ips)"
      octets="$(json_field_number_or_null "$user_json" total_octets)"
      [ "$max" = "null" ] && max="unlimited"
      [ "$octets" = "null" ] && octets="0"
      printf '%-18s connections=%s/%s api_active_ips=%s api_recent_ips=%s traffic=%s\n' \
        "${user:-unknown}" "$current" "$max" "$active" "$recent" "$(bytes_human "$octets")"
    done
  fi
else
  printf 'Telemt API is not reachable at %s/v1/users\n' "$API_URL"
fi

section "CLIENT PEER IPS ON TCP/443"
printf 'total_established_443_connections: %s\n' "$conn_443"
printf 'unique_peer_ips: %s\n' "$uniq_443"
printf 'top_peer_ips:\n'
if [ "$conn_443" -gt 0 ]; then
  sort "$tmp_clients" | uniq -c | sort -nr | head -n "$TOP_N" | awk '{printf "  %6s  %s\n", $1, $2}'
else
  printf '  none\n'
fi
printf '\nNote: these are TCP peers on nginx/front 443. They can include real clients, reconnects, and probes.\n'
printf 'Telemt API sees 127.0.0.1 because nginx stream proxies traffic locally.\n'

section "WIREGUARD"
if have wg && wg show "$WG_IF" >/dev/null 2>&1; then
  wg show "$WG_IF"
  printf '\nroute_to_telegram_test:\n'
  ip route get 149.154.167.51 2>/dev/null || true
  if timeout 4 bash -c '</dev/tcp/149.154.167.51/443' 2>/dev/null; then
    printf 'tcp_149.154.167.51_443: OK\n'
  else
    printf 'tcp_149.154.167.51_443: FAIL\n'
  fi
else
  printf '%s is not available or interface %s is missing\n' "wg" "$WG_IF"
fi

section "SERVICES AND PORTS"
for svc in nginx docker "wg-quick@${WG_IF}" fail2ban local-hardening-nft; do
  printf '%-24s %s\n' "$svc" "$(service_state "$svc")"
done
printf '\nlistening_ports:\n'
ss -lntp 2>/dev/null | grep -E ':(443|1443|9091|122)\b' || printf 'no expected listeners found\n'

section "DOCKER TELEMT"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  docker inspect "$CONTAINER" --format \
    'name={{.Name}} image={{.Config.Image}} user={{.Config.User}} running={{.State.Running}} status={{.State.Status}} started={{.State.StartedAt}} restarts={{.RestartCount}} readonly={{.HostConfig.ReadonlyRootfs}} network={{.HostConfig.NetworkMode}}'
  pid="$(docker inspect "$CONTAINER" --format '{{.State.Pid}}' 2>/dev/null || true)"
  if [ -n "${pid:-}" ] && [ -r "/proc/$pid/limits" ]; then
    grep -E 'Max open files|Max processes' "/proc/$pid/limits" || true
  fi
else
  printf 'container %s not found\n' "$CONTAINER"
fi

section "SERVER RESOURCES"
free -m 2>/dev/null | awk 'NR<=2{print}'
df -h / /var /opt 2>/dev/null | awk '!seen[$0]++'
printf '\nnetwork_interfaces:\n'
ip -br addr 2>/dev/null || true

section "RECENT TELEMT WARNINGS"
if have docker && docker inspect "$CONTAINER" >/dev/null 2>&1; then
  docker logs --since "$SINCE" "$CONTAINER" 2>&1 \
    | grep -E 'User limit|exceeded connection limit|ME pool is NOT ready|ME pool is not ready|All ME servers|Upstream failed|ERROR|WARN' \
    | tail -n 80 \
    || printf 'no relevant warnings in last %s\n' "$SINCE"
else
  printf 'docker/container unavailable\n'
fi

section "WHAT THIS REPORT CAN SEE"
cat <<'EOF'
Can see:
  - server/container/WireGuard/nginx health
  - active TCP peer IPs connected to external 443
  - Telemt per-config-user connection count, configured limit, and total octets
  - recent Telemt limit/ME/upstream warnings

Cannot see:
  - Telegram account names, phone numbers, chats, messages, or destinations
  - exact traffic per real client IP in this nginx stream setup
  - whether a TCP peer is a human client or a scanner without deeper correlation
EOF
