#!/usr/bin/env bash
set -Eeuo pipefail

# Bootstrap installer. It downloads or safely updates telemt2 and then hands
# control to the full interactive VPN Bot installer from this repository.

REPO_URL="${REPO_URL:-https://github.com/Telemtinstall/telemt2.git}"
REPO_BRANCH="${REPO_BRANCH:-main}"
REPO_DIR="${REPO_DIR:-/root/telemt2}"
BOT_PACKAGE_RELATIVE="${BOT_PACKAGE_RELATIVE:-bots/vpn-manager_awg}"

die() {
  printf 'ОШИБКА: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "запустите установщик от root"
}

install_download_tools() {
  if command -v git >/dev/null 2>&1; then
    return 0
  fi
  command -v apt-get >/dev/null 2>&1 ||
    die "не найден git и пакетный менеджер apt-get"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y git ca-certificates
}

download_or_update_repo() {
  if [[ -d "$REPO_DIR/.git" ]]; then
    if [[ -n "$(git -C "$REPO_DIR" status --porcelain)" ]]; then
      die "$REPO_DIR содержит локальные изменения; сохраните их перед обновлением"
    fi
    git -C "$REPO_DIR" remote set-url origin "$REPO_URL"
    git -C "$REPO_DIR" fetch origin "$REPO_BRANCH"
    git -C "$REPO_DIR" checkout "$REPO_BRANCH"
    git -C "$REPO_DIR" pull --ff-only origin "$REPO_BRANCH"
  elif [[ -e "$REPO_DIR" ]]; then
    die "$REPO_DIR существует и не является git-репозиторием"
  else
    install -d -m 0755 "$(dirname "$REPO_DIR")"
    git clone --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
  fi
}

verify_package() {
  local package_dir="$REPO_DIR/$BOT_PACKAGE_RELATIVE"
  [[ -x "$package_dir/install.sh" ]] ||
    die "не найден основной установщик: $package_dir/install.sh"
  [[ -f "$package_dir/SHA256SUMS" ]] ||
    die "не найден файл контрольных сумм: $package_dir/SHA256SUMS"
  command -v sha256sum >/dev/null 2>&1 || die "не найдена команда sha256sum"
  (cd "$package_dir" && sha256sum --check SHA256SUMS)
}

run_installer() {
  local installer="$REPO_DIR/$BOT_PACKAGE_RELATIVE/install.sh"
  if [[ -t 0 ]]; then
    exec "$installer" "$@"
  fi
  if [[ -r /dev/tty ]]; then
    exec "$installer" "$@" </dev/tty
  fi
  if [[ -n "${BOT_TOKEN:-}" && -n "${ADMIN_BOT:-}" ]]; then
    exec "$installer" "$@"
  fi
  die "нет интерактивного терминала; задайте BOT_TOKEN и ADMIN_BOT через окружение"
}

main() {
  require_root
  install_download_tools
  printf 'Загрузка или обновление VPN Bot из %s (%s)...\n' "$REPO_URL" "$REPO_BRANCH"
  download_or_update_repo
  verify_package
  run_installer "$@"
}

main "$@"
