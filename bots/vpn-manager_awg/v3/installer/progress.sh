# Three-line bootstrap progress. Never use for protocol/profile commands.
v3_progress_run() {
  local label="$1"; shift
  local detail_log child rc frame=0 v3_frame group=0 old_int old_term columns width
  old_int="$(trap -p INT)"; old_term="$(trap -p TERM)"
  umask 077
  detail_log="$(mktemp "${TMPDIR:-/tmp}/vpnbot-bootstrap.XXXXXXXX")"
  if command -v setsid >/dev/null 2>&1; then
    setsid "$@" >"$detail_log" 2>&1 &
    group=1
  else
    "$@" >"$detail_log" 2>&1 &
  fi
  child=$!
  trap 'if ((group)); then kill -TERM -- "-$child" 2>/dev/null || true; else kill -TERM "$child" 2>/dev/null || true; fi; wait "$child" 2>/dev/null || true; rm -f -- "$detail_log"; trap - INT TERM; eval "$old_int"; eval "$old_term"; return 130' INT TERM
  if [[ -t 2 && "${TERM:-}" != dumb ]]; then
    columns="$(tput cols 2>/dev/null || echo 80)"
    [[ "$columns" =~ ^[0-9]+$ ]] || columns=80
    width=$((columns > 10 ? columns - 1 : 9))
    printf '%.*s\n%.*s  |\n%.*s\n' "$width" 'Global v3 · подготовка' "$((width - 3))" "$label" "$width" 'Пожалуйста, дождитесь завершения' >&2
    while kill -0 "$child" 2>/dev/null; do
      case $((frame % 4)) in 0) v3_frame='|' ;; 1) v3_frame='/' ;; 2) v3_frame='-' ;; 3) v3_frame='\' ;; esac
      printf '\033[2A\r\033[2K%.*s  %s\033[2B\r' "$((width - 3))" "$label" "$v3_frame" >&2
      frame=$((frame + 1)); sleep 0.15
    done
    printf '\033[3A\r\033[2K\n\033[2K\n\033[2K\n\033[3A' >&2
  else
    printf '%s\n' "$label" >&2
  fi
  if wait "$child"; then rc=0; else rc=$?; fi
  trap - INT TERM; eval "$old_int"; eval "$old_term"
  if ((rc)); then
    tail -n 1 "$detail_log" >&2
    printf 'Ошибка этапа: %s (код %s)\n' "$label" "$rc" >&2
    printf 'Журнал: %s\n' "$detail_log" >&2
  else
    rm -f -- "$detail_log"
  fi
  return "$rc"
}
