#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

TELEMT_REPOSITORY="${TELEMT_REPOSITORY:-telemt/telemt}"
TELEMT_VERSION="${TELEMT_VERSION:-3.4.23}"
IMAGE="${IMAGE:-telemt-local}"
IMAGE_TAG="${IMAGE_TAG:-}"
TARGET="${TARGET:-prod}"
PUSH="${PUSH:-0}"
NO_CACHE="${NO_CACHE:-0}"
PLATFORM="${PLATFORM:-}"
ALLOW_TELEMT_LATEST="${ALLOW_TELEMT_LATEST:-0}"

tag_from_version() {
  local version="$1"
  version="${version#refs/tags/}"
  version="${version#v}"
  if [ -z "$version" ]; then
    version="latest"
  fi
  printf '%s' "$version"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    printf 'ERROR: command not found: %s\n' "$1" >&2
    exit 1
  }
}

usage() {
  cat <<'USAGE'
Usage:
  TELEMT_VERSION=<release-tag> ./build.sh

Examples:
  ./build.sh
  TARGET=debug ./build.sh
  TELEMT_VERSION=<release-tag> ./build.sh
  IMAGE=ghcr.io/Telemtinstall/telemt PUSH=1 ./build.sh

Variables:
  TELEMT_REPOSITORY  GitHub repo with releases. Default: telemt/telemt
  TELEMT_VERSION     Exact upstream release tag. Default: 3.4.23
  IMAGE              Local or remote image name. Default: telemt-local
  IMAGE_TAG          Docker image tag. Default: TELEMT_VERSION
  TARGET             Dockerfile target: prod or debug. Default: prod
  PLATFORM           Optional docker platform, e.g. linux/amd64 or linux/arm64
  NO_CACHE           1 disables Docker build cache.
  PUSH               1 pushes the built image. Default: 0
  ALLOW_TELEMT_LATEST
                     1 allows TELEMT_VERSION=latest intentionally.
USAGE
}

main() {
  case "${1:-}" in
    -h|--help)
      usage
      exit 0
      ;;
  esac

  case "$TARGET" in
    prod|debug) ;;
    *) printf 'ERROR: TARGET must be prod or debug\n' >&2; exit 1 ;;
  esac

  if [ "${TELEMT_VERSION#refs/tags/}" = "latest" ] && [ "$ALLOW_TELEMT_LATEST" != "1" ]; then
    printf 'ERROR: TELEMT_VERSION=latest is disabled for reproducible builds. Use an exact release tag such as 3.4.23, or set ALLOW_TELEMT_LATEST=1 intentionally.\n' >&2
    exit 1
  fi

  need_cmd docker

  local tag
  tag="$(tag_from_version "${IMAGE_TAG:-$TELEMT_VERSION}")"
  local full_image="${IMAGE}:${tag}"

  printf 'Telemt Docker build\n'
  printf '  repository: %s\n' "$TELEMT_REPOSITORY"
  printf '  version:    %s\n' "$TELEMT_VERSION"
  printf '  image tag:  %s\n' "$tag"
  printf '  target:     %s\n' "$TARGET"
  printf '  image:      %s\n' "$full_image"
  printf '  push:       %s\n' "$PUSH"

  build_args=(
    build
    --pull
    --target "$TARGET"
    --build-arg "TELEMT_REPOSITORY=$TELEMT_REPOSITORY"
    --build-arg "TELEMT_VERSION=$TELEMT_VERSION"
    --build-arg "ALLOW_TELEMT_LATEST=$ALLOW_TELEMT_LATEST"
    -t "$full_image"
  )

  if [ -n "$PLATFORM" ]; then
    build_args+=(--platform "$PLATFORM")
  fi

  if [ "$NO_CACHE" = "1" ]; then
    build_args+=(--no-cache)
  fi

  build_args+=("$SCRIPT_DIR")

  docker "${build_args[@]}"

  printf '\nBuilt image:\n  %s\n' "$full_image"
  printf '\nVersion check:\n'
  docker run --rm --entrypoint /app/telemt "$full_image" --version || true

  if [ "$PUSH" = "1" ]; then
    printf '\nPushing image:\n  %s\n' "$full_image"
    docker push "$full_image"
  else
    printf '\nPUSH=0, image was not published.\n'
  fi
}

main "$@"
