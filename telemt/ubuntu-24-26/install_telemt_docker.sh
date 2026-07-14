#!/usr/bin/env bash
set -Eeuo pipefail

# Ubuntu-only entry point for the canonical Docker Telemt installer.
# The full implementation lives in telemt/docker-telemt to avoid two copies
# of update, secret-preservation, and nginx/OpenSSL logic drifting apart.

REPO_DIR="${TELEMT_REPO_DIR:-/root/telemt2}"
REPO_URL="${TELEMT_REPO_URL:-https://github.com/Telemtinstall/telemt2.git}"
DOCKER_SUBDIR="telemt/docker-telemt"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_ubuntu_os() {
  local os_id major
  [ -r "$OS_RELEASE_FILE" ] || die "Cannot detect operating system."

  # shellcheck disable=SC1090
  source "$OS_RELEASE_FILE"
  os_id="$(printf '%s' "${ID:-}" | tr '[:upper:]' '[:lower:]')"
  major="${VERSION_ID%%.*}"

  [ "$os_id" = "ubuntu" ] || die "This launcher supports Ubuntu only. Use telemt/docker-telemt directly on Debian 13."
  [[ "$major" =~ ^[0-9]+$ ]] || die "Cannot detect Ubuntu version: ${PRETTY_NAME:-unknown}."
  [ "$major" -ge 24 ] && [ "$major" -le 26 ] || die "Supported Ubuntu versions are 24.x through 26.x. Detected: ${PRETTY_NAME:-unknown}."
}

main() {
  [ "$(id -u)" -eq 0 ] || die "Run as root. / Запустите от root."
  require_ubuntu_os

  export DEBIAN_FRONTEND=noninteractive
  if ! command -v git >/dev/null 2>&1; then
    apt-get update
    apt-get install -y --no-install-recommends git ca-certificates
  fi

  if [ -d "$REPO_DIR/.git" ]; then
    git -C "$REPO_DIR" pull --ff-only
  elif [ -e "$REPO_DIR" ]; then
    die "$REPO_DIR exists but is not a Git repository. Move it aside or set TELEMT_REPO_DIR."
  else
    git clone --depth 1 --filter=blob:none --sparse "$REPO_URL" "$REPO_DIR"
  fi

  git -C "$REPO_DIR" sparse-checkout set "$DOCKER_SUBDIR"
  chmod +x \
    "$REPO_DIR/$DOCKER_SUBDIR/build.sh" \
    "$REPO_DIR/$DOCKER_SUBDIR/install_docker-telemt.sh" \
    "$REPO_DIR/$DOCKER_SUBDIR/telemt-users.sh"

  exec "$REPO_DIR/$DOCKER_SUBDIR/install_docker-telemt.sh" "$@"
}

if [ "${TELEMT_UBUNTU_LAUNCHER_SOURCE_ONLY:-0}" != "1" ]; then
  main "$@"
fi
