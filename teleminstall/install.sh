#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

REPOSITORY_URL="https://github.com/Telemtinstall/telemt2.git"
REPOSITORY_BRANCH="main"
INSTALL_ROOT="/opt/teleminstall"
PAYLOAD="teleminstall/webproxy-install.sh"

say() { printf '%s\n' "$*"; }
die() { printf 'ОШИБКА: %s\n' "$*" >&2; exit 1; }

[ "${EUID:-$(id -u)}" -eq 0 ] || die "Запустите установщик от root."

export DEBIAN_FRONTEND=noninteractive
say "[1/3] Установка компонентов для загрузки установщика"
apt-get update
apt-get install -y --no-install-recommends ca-certificates git

say "[2/3] Получение актуальной версии Teleminstall"
if [ -d "$INSTALL_ROOT/.git" ]; then
  current_origin="$(git -C "$INSTALL_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$current_origin" in
    "$REPOSITORY_URL"|git@github.com:Telemtinstall/telemt2.git) ;;
    *) die "$INSTALL_ROOT уже содержит другой Git-репозиторий: ${current_origin:-unknown}" ;;
  esac
  git -C "$INSTALL_ROOT" fetch --depth 1 origin "$REPOSITORY_BRANCH"
  git -C "$INSTALL_ROOT" checkout -B "$REPOSITORY_BRANCH" FETCH_HEAD
  git -C "$INSTALL_ROOT" reset --hard FETCH_HEAD
  git -C "$INSTALL_ROOT" clean -fd
elif [ -e "$INSTALL_ROOT" ]; then
  die "$INSTALL_ROOT уже существует и не является репозиторием Teleminstall."
else
  install -d -m 0755 "$(dirname "$INSTALL_ROOT")"
  git clone --depth 1 --branch "$REPOSITORY_BRANCH" \
    "$REPOSITORY_URL" "$INSTALL_ROOT"
fi

installer="$INSTALL_ROOT/$PAYLOAD"
[ -f "$installer" ] || die "В репозитории не найден $PAYLOAD."
chmod 0755 "$installer"

say "[3/3] Запуск актуального установщика WEB proxy"
exec "$installer" "$@"
