#!/bin/sh
set -eu

# Universal Telemt installer dispatcher. It selects an existing maintained
# installer; Telemt version selection and config migration stay in that
# installer so this bootstrap never duplicates deployment logic.

REPO_URL="${TELEMT_REPO_URL:-https://github.com/Telemtinstall/telemt2.git}"
REPO_BRANCH="${TELEMT_REPO_BRANCH:-main}"
REPO_DIR="${TELEMT_REPO_DIR:-}"
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"
SCRIPT_LANG="${SCRIPT_LANG:-ru}"
ACTION="${TELEMT_ACTION:-}"
VARIANT="${TELEMT_VARIANT:-}"
DRY_RUN="${TELEMT_BOOTSTRAP_DRY_RUN:-0}"
ALLOW_NON_ROOT="${TELEMT_BOOTSTRAP_ALLOW_NON_ROOT:-0}"

DOCKER_INSTALL_DIR="${DOCKER_INSTALL_DIR:-/opt/telemt-docker}"
SYSTEMD_INSTALL_DIR="${SYSTEMD_INSTALL_DIR:-/opt/telemt-config}"
SYSTEMD_ETC_DIR="${SYSTEMD_ETC_DIR:-/etc/telemt}"
SYSTEMD_BINARY="${SYSTEMD_BINARY:-/usr/local/bin/telemt}"
SYSTEMD_SERVICE="${SYSTEMD_SERVICE:-/etc/systemd/system/telemt.service}"
TINYCORE_HOME="${TINYCORE_HOME:-/opt/telemt}"

OS_KIND=""
OS_ID_VALUE=""
OS_VERSION_VALUE=""
OS_PRETTY_VALUE=""
FOUND_DOCKER=0
FOUND_SYSTEMD=0
FOUND_TINYCORE=0
FOUND_COUNT=0
FOUND_VARIANT=""
TARGET_RELATIVE=""
TARGET_KIND=""

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

is_ru() {
  [ "$SCRIPT_LANG" = "ru" ]
}

die() {
  if is_ru; then
    printf 'ОШИБКА: %s\n' "$*" >&2
  else
    printf 'ERROR: %s\n' "$*" >&2
  fi
  exit 1
}

usage() {
  if is_ru; then
    cat <<'EOF'
Единый установщик Telemt

Использование:
  ./install.sh [-lang ru|en]
  ./install.sh --install [--docker|--native] [-lang ru|en]
  ./install.sh --update [-lang ru|en]

Опции:
  --install          Новая установка на чистый сервер.
  --update           Обновить найденную существующую установку.
  --docker           На Debian 13 выбрать Docker-вариант.
  --native           На Debian 13 выбрать вариант без Docker/systemd.
  -lang, --lang      Язык: ru или en. По умолчанию ru.
  --dry-run          Только показать выбранный установщик и команду.
  -h, --help         Показать справку.

Без --install/--update скрипт задаёт вопрос. На обновлении способ установки
определяется автоматически и не переключается между Docker и systemd.
EOF
  else
    cat <<'EOF'
Universal Telemt installer

Usage:
  ./install.sh [-lang ru|en]
  ./install.sh --install [--docker|--native] [-lang ru|en]
  ./install.sh --update [-lang ru|en]

Options:
  --install          Fresh install on a clean server.
  --update           Update the detected existing installation.
  --docker           Select Docker on Debian 13.
  --native           Select native/systemd on Debian 13.
  -lang, --lang      Interface language: ru or en. Default: ru.
  --dry-run          Only print the selected installer and command.
  -h, --help         Show this help.

Without --install/--update the script asks. Update mode detects the existing
installation type and never switches between Docker and systemd.
EOF
  fi
}

normalize_lang() {
  case "$(lower "$1")" in
    ru|rus|russian) printf 'ru' ;;
    en|eng|english) printf 'en' ;;
    *) return 1 ;;
  esac
}

parse_args() {
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --install|-install|install)
        [ -z "$ACTION" ] || [ "$ACTION" = "install" ] || die "Cannot combine --install and --update."
        ACTION="install"
        ;;
      --update|-update|update)
        [ -z "$ACTION" ] || [ "$ACTION" = "update" ] || die "Cannot combine --install and --update."
        ACTION="update"
        ;;
      --docker|-docker|docker)
        [ -z "$VARIANT" ] || [ "$VARIANT" = "docker" ] || die "Cannot combine --docker and --native."
        VARIANT="docker"
        ;;
      --native|--systemd|-native|native|systemd)
        [ -z "$VARIANT" ] || [ "$VARIANT" = "native" ] || die "Cannot combine --docker and --native."
        VARIANT="native"
        ;;
      -lang|--lang)
        shift
        [ "$#" -gt 0 ] || die "Missing language after --lang."
        SCRIPT_LANG="$(normalize_lang "$1")" || die "Bad language: $1"
        ;;
      -lang=*|--lang=*)
        SCRIPT_LANG="$(normalize_lang "${1#*=}")" || die "Bad language: ${1#*=}"
        ;;
      --dry-run)
        DRY_RUN=1
        ;;
      -h|--help|help)
        usage
        exit 0
        ;;
      *)
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done

  case "$SCRIPT_LANG" in
    ru|en) ;;
    *) die "Bad SCRIPT_LANG: $SCRIPT_LANG" ;;
  esac
}

need_root() {
  [ "$ALLOW_NON_ROOT" = "1" ] && return 0
  [ "$(id -u)" -eq 0 ] || die "Run as root. / Запустите от root."
}

detect_os() {
  os_id=""
  os_version=""
  os_pretty=""

  if [ -r "$OS_RELEASE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE"
    os_id="${ID:-}"
    os_version="${VERSION_ID:-}"
    os_pretty="${PRETTY_NAME:-${NAME:-}}"
  fi

  os_id="$(lower "$os_id")"
  if [ "$os_id" = "tinycore" ] || [ "$os_id" = "tiny core linux" ]; then
    OS_KIND="tinycore"
  elif command -v tce-load >/dev/null 2>&1 && [ -e /etc/sysconfig/tcedir ]; then
    OS_KIND="tinycore"
  elif [ "$os_id" = "debian" ]; then
    major="${os_version%%.*}"
    [ "$major" = "13" ] || die "Supported Debian version is 13. Detected: ${os_pretty:-Debian $os_version}."
    OS_KIND="debian13"
  elif [ "$os_id" = "ubuntu" ]; then
    major="${os_version%%.*}"
    case "$major" in
      24|25|26) OS_KIND="ubuntu" ;;
      *) die "Supported Ubuntu versions are 24.x through 26.x. Detected: ${os_pretty:-Ubuntu $os_version}." ;;
    esac
  else
    die "Unsupported operating system: ${os_pretty:-${os_id:-unknown}}. Use Debian 13, Ubuntu 24-26, or Tiny Core Linux."
  fi

  OS_ID_VALUE="$os_id"
  OS_VERSION_VALUE="$os_version"
  OS_PRETTY_VALUE="${os_pretty:-$os_id $os_version}"

  if [ -z "$REPO_DIR" ]; then
    if [ "$OS_KIND" = "tinycore" ]; then
      REPO_DIR="/tmp/telemt2"
    else
      REPO_DIR="/root/telemt2"
    fi
  fi
}

detect_existing_install() {
  if [ -f "$DOCKER_INSTALL_DIR/docker-compose.yml" ] ||
     [ -f "$DOCKER_INSTALL_DIR/telemt.toml" ]; then
    FOUND_DOCKER=1
  elif command -v docker >/dev/null 2>&1 && docker inspect telemt >/dev/null 2>&1; then
    FOUND_DOCKER=1
  fi

  if [ -f "$SYSTEMD_SERVICE" ] ||
     { [ -x "$SYSTEMD_BINARY" ] &&
       { [ -f "$SYSTEMD_ETC_DIR/telemt.toml" ] || [ -f "$SYSTEMD_INSTALL_DIR/telemt.toml" ]; }; }; then
    FOUND_SYSTEMD=1
  fi

  if [ -x "$TINYCORE_HOME/bin/telemt" ] && [ -f "$TINYCORE_HOME/telemt.toml" ]; then
    FOUND_TINYCORE=1
  fi

  FOUND_COUNT=$((FOUND_DOCKER + FOUND_SYSTEMD + FOUND_TINYCORE))
  if [ "$FOUND_COUNT" -eq 1 ]; then
    if [ "$FOUND_DOCKER" -eq 1 ]; then
      FOUND_VARIANT="docker"
    elif [ "$FOUND_SYSTEMD" -eq 1 ]; then
      FOUND_VARIANT="native"
    else
      FOUND_VARIANT="tinycore"
    fi
  elif [ "$FOUND_COUNT" -gt 1 ]; then
    FOUND_VARIANT="conflict"
  else
    FOUND_VARIANT="none"
  fi
}

print_detection() {
  if is_ru; then
    printf 'ОС: %s\n' "$OS_PRETTY_VALUE"
    case "$FOUND_VARIANT" in
      docker) printf 'Найдена установка: Docker (%s)\n' "$DOCKER_INSTALL_DIR" ;;
      native) printf 'Найдена установка: native/systemd\n' ;;
      tinycore) printf 'Найдена установка: Tiny Core native (%s)\n' "$TINYCORE_HOME" ;;
      conflict) printf 'Найдено несколько вариантов Telemt одновременно.\n' ;;
      none) printf 'Существующая установка Telemt не найдена.\n' ;;
    esac
  else
    printf 'OS: %s\n' "$OS_PRETTY_VALUE"
    case "$FOUND_VARIANT" in
      docker) printf 'Detected installation: Docker (%s)\n' "$DOCKER_INSTALL_DIR" ;;
      native) printf 'Detected installation: native/systemd\n' ;;
      tinycore) printf 'Detected installation: Tiny Core native (%s)\n' "$TINYCORE_HOME" ;;
      conflict) printf 'Multiple Telemt installation types were detected.\n' ;;
      none) printf 'No existing Telemt installation was detected.\n' ;;
    esac
  fi
}

ask_action() {
  [ -z "$ACTION" ] || return 0
  [ -t 0 ] || die "Choose --install or --update in non-interactive mode."

  if [ "$FOUND_VARIANT" = "none" ]; then
    default_action="install"
    if is_ru; then
      printf '\nДействие:\n  1) Установить [по умолчанию]\n  2) Обновить\nВыбор [1]: '
    else
      printf '\nAction:\n  1) Install [default]\n  2) Update\nChoice [1]: '
    fi
  else
    default_action="update"
    if is_ru; then
      printf '\nДействие:\n  1) Установить\n  2) Обновить найденную установку [по умолчанию]\nВыбор [2]: '
    else
      printf '\nAction:\n  1) Install\n  2) Update detected installation [default]\nChoice [2]: '
    fi
  fi

  read answer || answer=""
  case "$answer" in
    "") ACTION="$default_action" ;;
    1|install|Install) ACTION="install" ;;
    2|update|Update) ACTION="update" ;;
    *) die "Unknown choice: $answer" ;;
  esac
}

validate_action() {
  case "$ACTION" in
    install|update) ;;
    *) die "Bad action: $ACTION" ;;
  esac

  [ "$FOUND_VARIANT" != "conflict" ] || die "Docker and native Telemt are both present. Resolve the conflict manually before using the universal updater."

  if [ "$ACTION" = "update" ]; then
    [ "$FOUND_VARIANT" != "none" ] || die "Telemt is not installed. Choose --install."
  else
    [ "$FOUND_VARIANT" = "none" ] || die "Telemt is already installed. Choose --update; a reinstall requires the explicit specialist installer."
  fi
}

ask_debian_variant() {
  [ "$OS_KIND" = "debian13" ] || return 0
  [ "$ACTION" = "install" ] || return 0
  [ -z "$VARIANT" ] || return 0
  [ -t 0 ] || die "Choose --docker or --native for a non-interactive Debian 13 install."

  if is_ru; then
    printf '\nВарианты для Debian 13:\n  1) Docker [рекомендуется]\n  2) Без Docker, native/systemd\nВыбор [1]: '
  else
    printf '\nDebian 13 variants:\n  1) Docker [recommended]\n  2) Native/systemd without Docker\nChoice [1]: '
  fi
  read answer || answer=""
  case "$answer" in
    ""|1|docker|Docker) VARIANT="docker" ;;
    2|native|Native|systemd) VARIANT="native" ;;
    *) die "Unknown choice: $answer" ;;
  esac
}

select_target() {
  if [ "$ACTION" = "update" ]; then
    case "$FOUND_VARIANT" in
      docker) VARIANT="docker" ;;
      native) VARIANT="native" ;;
      tinycore) VARIANT="tinycore" ;;
    esac
  fi

  case "$OS_KIND" in
    ubuntu)
      [ -z "$VARIANT" ] || [ "$VARIANT" = "docker" ] || die "Ubuntu 24-26 supports Docker Telemt only."
      VARIANT="docker"
      ;;
    tinycore)
      [ -z "$VARIANT" ] || [ "$VARIANT" = "native" ] || [ "$VARIANT" = "tinycore" ] || die "Tiny Core uses its native installer only."
      VARIANT="tinycore"
      ;;
    debian13)
      ask_debian_variant
      ;;
  esac

  case "$VARIANT" in
    docker)
      TARGET_RELATIVE="telemt/docker-telemt/install_docker-telemt.sh"
      TARGET_KIND="docker"
      ;;
    native)
      [ "$OS_KIND" = "debian13" ] || die "Native/systemd Telemt is supported on Debian 13 only."
      TARGET_RELATIVE="telemt/debian-13/install_telemt_systemd.sh"
      TARGET_KIND="native"
      ;;
    tinycore)
      [ "$OS_KIND" = "tinycore" ] || die "Tiny Core installer selected on the wrong OS."
      TARGET_RELATIVE="telemt/tinycore/install_telemt_tinycore.sh"
      TARGET_KIND="tinycore"
      ;;
    *) die "Cannot select a compatible installer." ;;
  esac
}

print_plan() {
  if is_ru; then
    printf '\nПлан:\n'
    printf '  действие:       %s\n' "$ACTION"
    printf '  вариант:        %s\n' "$TARGET_KIND"
    printf '  репозиторий:    %s (%s)\n' "$REPO_URL" "$REPO_BRANCH"
    printf '  каталог Git:    %s\n' "$REPO_DIR"
    printf '  установщик:     %s\n' "$TARGET_RELATIVE"
    printf '  версия Telemt:  точная совместимая версия выбирается профильным установщиком, не latest\n'
  else
    printf '\nPlan:\n'
    printf '  action:         %s\n' "$ACTION"
    printf '  variant:        %s\n' "$TARGET_KIND"
    printf '  repository:     %s (%s)\n' "$REPO_URL" "$REPO_BRANCH"
    printf '  Git directory:  %s\n' "$REPO_DIR"
    printf '  installer:      %s\n' "$TARGET_RELATIVE"
    printf '  Telemt version: exact compatible target is selected by the specialist installer, never latest\n'
  fi
}

install_git_if_needed() {
  command -v git >/dev/null 2>&1 && return 0

  if [ "$OS_KIND" = "tinycore" ]; then
    command -v tce-load >/dev/null 2>&1 || die "tce-load not found on Tiny Core."
    [ -e /etc/sysconfig/tcedir ] || die "Configure a persistent Tiny Core TCE directory first."
    tce-load -wi ca-certificates
    tce-load -wi git
  else
    command -v apt-get >/dev/null 2>&1 || die "apt-get not found."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends git ca-certificates
  fi

  command -v git >/dev/null 2>&1 || die "Git installation failed."
}

repo_slug() {
  value="$1"
  case "$value" in
    https://github.com/*) value="${value#https://github.com/}" ;;
    http://github.com/*) value="${value#http://github.com/}" ;;
    git@github.com:*) value="${value#git@github.com:}" ;;
    ssh://git@github.com/*) value="${value#ssh://git@github.com/}" ;;
  esac
  value="${value%/}"
  value="${value%.git}"
  printf '%s' "$value"
}

prepare_repo() {
  install_git_if_needed

  if [ -d "$REPO_DIR/.git" ]; then
    origin="$(git -C "$REPO_DIR" remote get-url origin 2>/dev/null || true)"
    [ -n "$origin" ] || die "$REPO_DIR has no origin remote."
    [ "$(repo_slug "$origin")" = "$(repo_slug "$REPO_URL")" ] ||
      die "$REPO_DIR belongs to another repository: $origin"

    branch="$(git -C "$REPO_DIR" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
    [ "$branch" = "$REPO_BRANCH" ] || die "$REPO_DIR is on branch '${branch:-detached}', expected '$REPO_BRANCH'."

    changes="$(git -C "$REPO_DIR" status --porcelain)"
    [ -z "$changes" ] || die "$REPO_DIR has local changes. They were not overwritten; commit or move them before updating."

    git -C "$REPO_DIR" pull --ff-only origin "$REPO_BRANCH"
    local_head="$(git -C "$REPO_DIR" rev-parse HEAD)"
    remote_head="$(git -C "$REPO_DIR" rev-parse "refs/remotes/origin/$REPO_BRANCH")"
    [ "$local_head" = "$remote_head" ] ||
      die "$REPO_DIR contains local commits not present in origin/$REPO_BRANCH. They were not overwritten."
  elif [ -e "$REPO_DIR" ]; then
    die "$REPO_DIR exists but is not a Git repository. It was not overwritten; move it aside or set TELEMT_REPO_DIR."
  else
    mkdir -p "$(dirname "$REPO_DIR")"
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$REPO_DIR"
  fi

  target="$REPO_DIR/$TARGET_RELATIVE"
  if [ ! -f "$target" ] && [ "$(git -C "$REPO_DIR" config --bool core.sparseCheckout 2>/dev/null || true)" = "true" ]; then
    git -C "$REPO_DIR" sparse-checkout add "$(dirname "$TARGET_RELATIVE")"
  fi
  [ -f "$target" ] || die "Selected installer is missing after Git update: $target"
}

run_target() {
  target="$REPO_DIR/$TARGET_RELATIVE"

  if [ "$DRY_RUN" = "1" ]; then
    if is_ru; then
      printf '\nDRY RUN: пакеты, Git и сервер не изменялись.\n'
    else
      printf '\nDRY RUN: packages, Git, and server were not changed.\n'
    fi
    if [ "$TARGET_KIND" = "tinycore" ]; then
      printf 'sh %s%s\n' "$target" "$( [ "$ACTION" = "update" ] && printf ' --update' || true )"
    else
      printf '%s%s -lang %s\n' "$target" "$( [ "$ACTION" = "update" ] && printf ' --update' || true )" "$SCRIPT_LANG"
    fi
    return 0
  fi

  prepare_repo
  target="$REPO_DIR/$TARGET_RELATIVE"
  chmod +x "$target"

  if [ "$TARGET_KIND" = "docker" ]; then
    chmod +x \
      "$REPO_DIR/telemt/docker-telemt/build.sh" \
      "$REPO_DIR/telemt/docker-telemt/telemt-users.sh"
  fi

  if [ "$TARGET_KIND" = "tinycore" ]; then
    if [ "$ACTION" = "update" ]; then
      exec sh "$target" --update
    fi
    exec sh "$target"
  fi

  if [ "$ACTION" = "update" ]; then
    exec "$target" --update -lang "$SCRIPT_LANG"
  fi
  exec "$target" -lang "$SCRIPT_LANG"
}

main() {
  parse_args "$@"
  need_root
  detect_os
  detect_existing_install
  print_detection
  ask_action
  validate_action
  select_target
  print_plan
  run_target
}

main "$@"
