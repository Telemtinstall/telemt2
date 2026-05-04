#!/usr/bin/env bash
set -Eeuo pipefail

echo "host=$(hostname -f 2>/dev/null || hostname)"
echo "time=$(date -Is)"

if ! command -v certbot >/dev/null 2>&1; then
  echo "certbot=missing"
  exit 0
fi

install -d -m 0755 /etc/letsencrypt/renewal-hooks/pre /etc/letsencrypt/renewal-hooks/post /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/pre/stop-nginx-telemt.sh <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl stop nginx
fi
EOF
chown root:root /etc/letsencrypt/renewal-hooks/pre/stop-nginx-telemt.sh
chmod 0755 /etc/letsencrypt/renewal-hooks/pre/stop-nginx-telemt.sh
echo "pre_hook=/etc/letsencrypt/renewal-hooks/pre/stop-nginx-telemt.sh"

cat > /etc/letsencrypt/renewal-hooks/post/start-nginx-telemt.sh <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1; then
  systemctl start nginx || systemctl restart nginx || true
fi
EOF
chown root:root /etc/letsencrypt/renewal-hooks/post/start-nginx-telemt.sh
chmod 0755 /etc/letsencrypt/renewal-hooks/post/start-nginx-telemt.sh
echo "post_hook=/etc/letsencrypt/renewal-hooks/post/start-nginx-telemt.sh"

cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh <<'EOF'
#!/usr/bin/env bash
set -e

if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet nginx; then
  systemctl reload nginx || systemctl restart nginx
fi
EOF
chown root:root /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh
echo "deploy_hook=/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh"

if command -v systemctl >/dev/null 2>&1; then
  systemctl enable --now certbot.timer
  echo "certbot_timer_enabled=$(systemctl is-enabled certbot.timer 2>/dev/null || true)"
  echo "certbot_timer_active=$(systemctl is-active certbot.timer 2>/dev/null || true)"
  systemctl list-timers certbot.timer --no-pager || true
fi

echo "certificates:"
certbot certificates || true

mapfile -t renewal_files < <(find /etc/letsencrypt/renewal -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort)
if [[ "${#renewal_files[@]}" -eq 0 ]]; then
  echo "renewal_configs=none"
  exit 0
fi

echo "renewal_configs:"
printf '  %s\n' "${renewal_files[@]}"

echo "renewal_authenticators:"
grep -HnE '^(authenticator|installer|pref_challs|server|archive_dir|cert) =' "${renewal_files[@]}" || true

if [[ "${RUN_DRY_RUN:-1}" == "1" ]]; then
  echo "dry_run=start"
  certbot renew --dry-run --no-random-sleep-on-renew
  echo "dry_run=ok"
else
  echo "dry_run=skipped"
fi
