#!/usr/bin/env bash

set -euo pipefail

CONFIG_FILE="${CONFIG_FILE:-./add_server_ssh.conf}"
KEY_PATH="${KEY_PATH:-${HOME}/.ssh/id_ed25519}"
CONNECT_TIMEOUT="${CONNECT_TIMEOUT:-8}"
STRICT_HOST_KEY_CHECKING="${STRICT_HOST_KEY_CHECKING:-accept-new}"
EXPECTED_HOST_KEY_SHA256="${EXPECTED_HOST_KEY_SHA256:-}"
SERVER_IP="${SERVER_IP:-}"
SERVER_HOST="${SERVER_HOST:-}"
SERVER_PORT="${SERVER_PORT:-}"
USERNAME="${USERNAME:-}"
EMAIL="${EMAIL:-}"
REMOTE_SYSTEM="${REMOTE_SYSTEM:-auto}"
SERVER_INPUT="${SERVER_INPUT:-}"
PARSED_PORT=""

SSH_TARGET=""
SSH_OPTS=()
SCP_OPTS=()

load_config_file() {
  local line key value

  [ -f "$CONFIG_FILE" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    [[ "$line" == *=* ]] || continue

    key="${line%%=*}"
    value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"

    case "$value" in
      \"*\") value="${value#\"}"; value="${value%\"}" ;;
      \'*\') value="${value#\'}"; value="${value%\'}" ;;
    esac

    case "$key" in
      SERVER_INPUT|SERVER_IP|SERVER_HOST|SERVER_PORT|USERNAME|EMAIL|REMOTE_SYSTEM|KEY_PATH|CONNECT_TIMEOUT|STRICT_HOST_KEY_CHECKING|EXPECTED_HOST_KEY_SHA256)
        printf -v "$key" '%s' "$value"
        ;;
      *)
        echo "Игнорирую неизвестный параметр в $CONFIG_FILE: $key"
        ;;
    esac
  done < "$CONFIG_FILE"
}

load_config_file

SERVER_INPUT="${SERVER_INPUT:-${SERVER_IP:-${SERVER_HOST:-}}}"

confirm() {
  local prompt="${1:-Продолжить? [y/N]: }"
  local answer

  read -r -p "$prompt" answer
  case "$answer" in
    y|Y|yes|YES|д|Д|да|ДА) return 0 ;;
    *) return 1 ;;
  esac
}

ask_required() {
  local var_name="$1"
  local prompt_text="$2"
  local input_value
  local current_value="${!var_name:-}"

  while [ -z "$current_value" ]; do
    read -r -p "${prompt_text}: " input_value
    current_value="$input_value"
  done

  printf -v "$var_name" '%s' "$current_value"
}

ask_with_default() {
  local var_name="$1"
  local prompt_text="$2"
  local default_value="$3"
  local input_value
  local current_value="${!var_name:-}"

  if [ -n "$current_value" ]; then
    return 0
  fi

  if [ -n "$default_value" ]; then
    read -r -p "${prompt_text} [${default_value}]: " input_value
    if [ -z "$input_value" ]; then
      input_value="$default_value"
    fi
  else
    read -r -p "${prompt_text}: " input_value
  fi

  printf -v "$var_name" '%s' "$input_value"
}

default_email() {
  local local_user
  local local_host

  local_user="$(id -un 2>/dev/null || printf '%s' "${USER:-user}")"
  local_host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || printf 'local')"
  local_host="${local_host%% *}"

  if [[ "$local_host" != *.* ]]; then
    local_host="${local_host}.local"
  fi

  printf '%s@%s' "$local_user" "$local_host"
}

normalize_server_input() {
  local value="$1"

  value="${value#ssh://}"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"

  printf '%s' "$value"
}

parse_server_input() {
  local raw="$1"

  raw="$(normalize_server_input "$raw")"

  if [[ "$raw" =~ [[:space:]] ]]; then
    echo "Ошибка: адрес сервера содержит пробелы: $raw"
    exit 1
  fi

  if [[ "$raw" == *@* ]]; then
    if [ -z "$USERNAME" ]; then
      USERNAME="${raw%@*}"
    fi
    raw="${raw#*@}"
  fi

  if [[ "$raw" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    SERVER_HOST="${BASH_REMATCH[1]}"
    PARSED_PORT="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^([^:]+):([0-9]+)$ ]]; then
    SERVER_HOST="${BASH_REMATCH[1]}"
    PARSED_PORT="${BASH_REMATCH[2]}"
  else
    SERVER_HOST="$raw"
  fi
}

validate_inputs() {
  if [ -z "$SERVER_HOST" ]; then
    echo "Ошибка: пустой адрес сервера"
    exit 1
  fi

  if [[ "$SERVER_HOST" =~ [[:space:]] ]]; then
    echo "Ошибка: адрес сервера содержит пробелы: $SERVER_HOST"
    exit 1
  fi

  if ! [[ "$SERVER_PORT" =~ ^[0-9]+$ ]] || [ "$SERVER_PORT" -lt 1 ] || [ "$SERVER_PORT" -gt 65535 ]; then
    echo "Ошибка: SSH-порт должен быть числом от 1 до 65535"
    exit 1
  fi

  if [ -z "$USERNAME" ]; then
    echo "Ошибка: пустое имя пользователя"
    exit 1
  fi

  if [ -z "$EMAIL" ]; then
    echo "Ошибка: пустой email/comment для ключа"
    exit 1
  fi
}

ensure_ssh_dir() {
  mkdir -p "${HOME}/.ssh"
  chmod 700 "${HOME}/.ssh"
}

build_connection_options() {
  SSH_TARGET="${USERNAME}@${SERVER_HOST}"
  SSH_OPTS=(
    -p "$SERVER_PORT"
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
    -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}"
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts"
    -i "$KEY_PATH"
    -o IdentitiesOnly=yes
  )
  SCP_OPTS=(
    -P "$SERVER_PORT"
    -o "ConnectTimeout=${CONNECT_TIMEOUT}"
    -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}"
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts"
    -i "$KEY_PATH"
    -o IdentitiesOnly=yes
  )
}

known_host_name() {
  if [ "$SERVER_PORT" = "22" ]; then
    printf '%s' "$SERVER_HOST"
  else
    printf '[%s]:%s' "$SERVER_HOST" "$SERVER_PORT"
  fi
}

remove_known_host_entries() {
  ssh-keygen -R "$SERVER_HOST" >/dev/null 2>&1 || true
  ssh-keygen -R "[$SERVER_HOST]:$SERVER_PORT" >/dev/null 2>&1 || true
}

scan_host_key() {
  local tmp_file
  local fingerprints

  ensure_ssh_dir
  tmp_file="$(mktemp "${TMPDIR:-/tmp}/add-keyscan.XXXXXX")"

  if ssh-keyscan -T "$CONNECT_TIMEOUT" -p "$SERVER_PORT" "$SERVER_HOST" > "$tmp_file" 2>/dev/null && [ -s "$tmp_file" ]; then
    fingerprints="$(ssh-keygen -l -E sha256 -f "$tmp_file" 2>/dev/null || ssh-keygen -l -f "$tmp_file" 2>/dev/null || true)"
    echo
    echo "Host key fingerprints for $(known_host_name):"
    echo "$fingerprints"
    echo

    if [ -n "$EXPECTED_HOST_KEY_SHA256" ]; then
      if ! printf '%s\n' "$fingerprints" | grep -Fq "$EXPECTED_HOST_KEY_SHA256"; then
        echo "Ошибка: host key fingerprint не совпал с EXPECTED_HOST_KEY_SHA256=$EXPECTED_HOST_KEY_SHA256"
        rm -f "$tmp_file"
        return 1
      fi
    elif ! confirm "Доверять этому host key и добавить его в known_hosts? [y/N]: "; then
      rm -f "$tmp_file"
      return 1
    fi

    cat "$tmp_file" >> "${HOME}/.ssh/known_hosts"
    rm -f "$tmp_file"
    chmod 600 "${HOME}/.ssh/known_hosts" 2>/dev/null || true
    return 0
  fi

  rm -f "$tmp_file"
  return 1
}

check_host_key_conflict() {
  local output
  local rc
  local target

  target="${USERNAME}@${SERVER_HOST}"

  set +e
  output=$(ssh \
    -p "$SERVER_PORT" \
    -o BatchMode=yes \
    -o PreferredAuthentications=publickey \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o StrictHostKeyChecking=yes \
    -o "ConnectTimeout=${CONNECT_TIMEOUT}" \
    "$target" "exit" 2>&1)
  rc=$?
  set -e

  if echo "$output" | grep -q "REMOTE HOST IDENTIFICATION HAS CHANGED"; then
    echo
    echo "Обнаружено изменение host key у сервера:"
    echo "$output"
    echo

    if confirm "Удалить старый host key из known_hosts и записать новый? [y/N]: "; then
      remove_known_host_entries
      if scan_host_key; then
        echo "Новый host key добавлен в known_hosts для $(known_host_name)."
      else
        echo "ssh-keyscan не получил или не подтвердил host key."
        if confirm "Продолжить через StrictHostKeyChecking=accept-new? [y/N]: "; then
          STRICT_HOST_KEY_CHECKING="accept-new"
        else
          echo "Операция отменена."
          exit 1
        fi
      fi
    else
      echo "Операция отменена."
      exit 1
    fi
  elif echo "$output" | grep -Eqi "No .* host key is known|Host key verification failed|The authenticity of host"; then
    echo "Host key сервера ещё не записан в known_hosts. Пробую добавить через ssh-keyscan..."
    if scan_host_key; then
      echo "Host key добавлен в known_hosts для $(known_host_name)."
    else
      echo "ssh-keyscan не получил или не подтвердил host key."
      if confirm "Продолжить через StrictHostKeyChecking=accept-new? [y/N]: "; then
        STRICT_HOST_KEY_CHECKING="accept-new"
      else
        echo "Операция отменена."
        exit 1
      fi
    fi
  fi

  if [ "$rc" -eq 255 ]; then
    if echo "$output" | grep -Eqi "could not resolve hostname|no route to host|operation timed out|connection timed out|connection refused"; then
      echo
      echo "Ошибка SSH-подключения:"
      echo "$output"
      exit 1
    fi
  fi
}

backup_and_generate_key() {
  local timestamp
  local backup_path

  timestamp="$(date +%Y%m%d-%H%M%S)"
  backup_path="${KEY_PATH}.backup.${timestamp}"

  if [ -f "$KEY_PATH" ]; then
    mv "$KEY_PATH" "$backup_path"
    echo "Старый приватный ключ сохранён: $backup_path"
  fi

  if [ -f "${KEY_PATH}.pub" ]; then
    mv "${KEY_PATH}.pub" "${backup_path}.pub"
    echo "Старый публичный ключ сохранён: ${backup_path}.pub"
  fi

  ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH" -N ""
}

generate_key_if_needed() {
  ensure_ssh_dir

  if [ ! -f "$KEY_PATH" ]; then
    echo "Генерирую новый SSH-ключ: $KEY_PATH"
    ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY_PATH" -N ""
  elif ! ssh-keygen -y -f "$KEY_PATH" >/dev/null 2>&1; then
    echo "Локальный ключ есть, но ssh-keygen не может его прочитать: $KEY_PATH"
    if confirm "Сохранить его в backup и создать новый ключ? [y/N]: "; then
      backup_and_generate_key
    else
      echo "Операция отменена."
      exit 1
    fi
  else
    echo "Локальный ключ уже существует: $KEY_PATH"
  fi

  if [ ! -f "${KEY_PATH}.pub" ]; then
    echo "Публичного ключа нет, восстанавливаю из приватного..."
    ssh-keygen -y -f "$KEY_PATH" > "${KEY_PATH}.pub"
  fi

  if ! ssh-keygen -l -f "${KEY_PATH}.pub" >/dev/null 2>&1; then
    echo "Публичный ключ повреждён: ${KEY_PATH}.pub"
    if confirm "Пересоздать публичный ключ из приватного? [y/N]: "; then
      ssh-keygen -y -f "$KEY_PATH" > "${KEY_PATH}.pub"
    else
      echo "Операция отменена."
      exit 1
    fi
  fi

  chmod 600 "$KEY_PATH"
  chmod 644 "${KEY_PATH}.pub"
}

public_key_line() {
  local line

  IFS= read -r line < "${KEY_PATH}.pub"
  case "$line" in
    ssh-*|ecdsa-*|sk-*) printf '%s' "$line" ;;
    *)
      echo "Ошибка: ${KEY_PATH}.pub не похож на SSH public key"
      exit 1
      ;;
  esac
}

detect_remote_system() {
  local output
  local rc
  local choice

  case "$REMOTE_SYSTEM" in
    auto|"") ;;
    mikrotik|routeros|ros)
      REMOTE_SYSTEM="routeros"
      return 0
      ;;
    unix|linux|openssh|dropbear)
      REMOTE_SYSTEM="unix"
      return 0
      ;;
    *)
      echo "Ошибка: неизвестный REMOTE_SYSTEM=$REMOTE_SYSTEM"
      exit 1
      ;;
  esac

  echo "Определяю тип удалённой системы..."

  set +e
  output=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'printf "__UNIX__ "; uname -s 2>/dev/null; [ -d /etc/dropbear ] && printf " __DROPBEAR__"; true' 2>&1)
  rc=$?
  set -e

  if [ "$rc" -eq 0 ] && echo "$output" | grep -q "__UNIX__"; then
    REMOTE_SYSTEM="unix"
    if echo "$output" | grep -q "__DROPBEAR__"; then
      echo "Тип системы: Unix/Linux + Dropbear/OpenWrt."
    else
      echo "Тип системы: Unix/Linux/OpenSSH."
    fi
    return 0
  fi

  set +e
  output=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" ':put ("__ROUTEROS__" . [/system resource get version])' 2>&1)
  rc=$?
  set -e

  if [ "$rc" -eq 0 ] && echo "$output" | grep -q "__ROUTEROS__"; then
    REMOTE_SYSTEM="routeros"
    echo "Тип системы: MikroTik RouterOS."
    return 0
  fi

  echo
  echo "Не удалось автоматически определить тип удалённой системы."
  echo "1) unix     - Debian/Ubuntu/CentOS/FreeBSD/OpenWrt/Dropbear и похожие"
  echo "2) mikrotik - MikroTik RouterOS"

  while true; do
    read -r -p "Введите тип [unix/mikrotik]: " choice
    case "$choice" in
      1|unix|linux|openssh|dropbear)
        REMOTE_SYSTEM="unix"
        return 0
        ;;
      2|mikrotik|routeros|ros)
        REMOTE_SYSTEM="routeros"
        return 0
        ;;
      *)
        echo "Введите unix или mikrotik."
        ;;
    esac
  done
}

install_unix_key() {
  echo "Копирую ключ на Unix/Linux/OpenSSH/Dropbear..."

  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" 'set -eu
KEY_LINE=$(cat)

append_key() {
  dest="$1"
  dir=$(dirname "$dest")

  mkdir -p "$dir" 2>/dev/null || return 1
  touch "$dest" 2>/dev/null || return 1

  chmod 700 "$dir" 2>/dev/null || true
  chmod 600 "$dest" 2>/dev/null || true

  if grep -qxF "$KEY_LINE" "$dest" 2>/dev/null; then
    echo "already:$dest"
  else
    printf "%s\n" "$KEY_LINE" >> "$dest"
    echo "added:$dest"
  fi
}

USER_NAME=$(id -un 2>/dev/null || printf "%s" "${USER:-root}")
HOME_DIR="${HOME:-}"

if [ -z "$HOME_DIR" ] || [ ! -d "$HOME_DIR" ]; then
  HOME_DIR=$(awk -F: -v u="$USER_NAME" "\$1==u {print \$6; exit}" /etc/passwd 2>/dev/null || true)
fi

if [ -z "$HOME_DIR" ] && [ "$(id -u 2>/dev/null || echo 1)" = "0" ]; then
  HOME_DIR=/root
fi

if [ -z "$HOME_DIR" ]; then
  HOME_DIR=.
fi

installed=0

if append_key "$HOME_DIR/.ssh/authorized_keys"; then
  installed=1
fi

if [ -f "$HOME_DIR/.ssh/authorized_keys2" ]; then
  append_key "$HOME_DIR/.ssh/authorized_keys2" && installed=1 || true
fi

if [ -d /etc/dropbear ]; then
  append_key "/etc/dropbear/authorized_keys" && installed=1 || true
fi

if [ -d /etc/ssh/authorized_keys ]; then
  append_key "/etc/ssh/authorized_keys/$USER_NAME" && installed=1 || true
fi

if [ -d /etc/ssh/authorized_keys.d ]; then
  append_key "/etc/ssh/authorized_keys.d/$USER_NAME" && installed=1 || true
fi

if [ "$installed" -ne 1 ]; then
  echo "Не нашёл доступного места для authorized_keys."
  exit 1
fi
' < "${KEY_PATH}.pub"
}

copy_with_ssh_copy_id() {
  if ! command -v ssh-copy-id >/dev/null 2>&1; then
    return 1
  fi

  echo "Пробую запасной способ через ssh-copy-id..."
  ssh-copy-id \
    -i "${KEY_PATH}.pub" \
    -p "$SERVER_PORT" \
    -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}" \
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts" \
    "$SSH_TARGET"
}

routeros_quote() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

routeros_import_command() {
  local file_q
  local user_q

  file_q="$(routeros_quote "$1")"
  user_q="$(routeros_quote "$USERNAME")"
  printf '/user ssh-keys import public-key-file=%s user=%s' "$file_q" "$user_q"
}

routeros_add_key_command() {
  local key_q
  local user_q

  key_q="$(routeros_quote "$(public_key_line)")"
  user_q="$(routeros_quote "$USERNAME")"
  printf '/user ssh-keys add key=%s user=%s' "$key_q" "$user_q"
}

routeros_remove_file_command() {
  local file_q

  file_q="$(routeros_quote "$1")"
  printf '/file remove [find name=%s]' "$file_q"
}

routeros_remove_user_keys_command() {
  local user_q

  user_q="$(routeros_quote "$USERNAME")"
  printf '/user ssh-keys remove [find user=%s]' "$user_q"
}

scp_target_path() {
  local remote_path="$1"
  local host="$SERVER_HOST"

  if [[ "$host" == *:* ]]; then
    host="[$host]"
  fi

  printf '%s@%s:%s' "$USERNAME" "$host" "$remote_path"
}

scp_upload() {
  local src="$1"
  local remote_path="$2"

  if scp -O "${SCP_OPTS[@]}" "$src" "$(scp_target_path "$remote_path")"; then
    return 0
  fi

  echo "Legacy scp не сработал, пробую обычный scp..."
  scp "${SCP_OPTS[@]}" "$src" "$(scp_target_path "$remote_path")"
}

install_routeros_key_once() {
  local remote_file="$1"
  local output
  local rc

  scp_upload "${KEY_PATH}.pub" "$remote_file"

  set +e
  output=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$(routeros_import_command "$remote_file")" 2>&1)
  rc=$?
  set -e

  ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$(routeros_remove_file_command "$remote_file")" >/dev/null 2>&1 || true

  if [ -n "$output" ]; then
    echo "$output"
  fi

  return "$rc"
}

install_routeros_key_direct() {
  local output
  local rc

  set +e
  output=$(ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$(routeros_add_key_command)" 2>&1)
  rc=$?
  set -e

  if [ -n "$output" ]; then
    echo "$output"
  fi

  return "$rc"
}

install_routeros_key() {
  local local_user
  local remote_file

  echo "Копирую ключ на MikroTik RouterOS..."
  local_user="$(id -un 2>/dev/null || printf '%s' "${USER:-user}")"
  local_user="$(printf '%s' "$local_user" | tr -cd 'A-Za-z0-9_.-')"
  remote_file="add_key_${local_user:-user}.pub"

  if install_routeros_key_direct; then
    return 0
  fi

  if verify_key_login "routeros"; then
    return 0
  fi

  echo "Прямое добавление ключа не прошло, пробую импорт через файл..."

  if install_routeros_key_once "$remote_file"; then
    return 0
  fi

  echo
  echo "MikroTik не импортировал ключ с первого раза."
  echo "Если старый ключ уже записан на роутере, он может мешать повторному импорту."

  if verify_key_login "routeros"; then
    return 0
  fi

  if confirm "Удалить SSH-ключи пользователя '$USERNAME' на MikroTik и импортировать заново? [y/N]: "; then
    ssh "${SSH_OPTS[@]}" "$SSH_TARGET" "$(routeros_remove_user_keys_command)"
    install_routeros_key_once "$remote_file"
  else
    return 1
  fi
}

verify_key_login() {
  local system_type="$1"
  local command
  local output
  local rc

  echo "Проверяю вход по ключу..."

  if [ "$system_type" = "routeros" ]; then
    command=':put "KEY_LOGIN_OK"'
  else
    command='printf "%s\n" KEY_LOGIN_OK'
  fi

  set +e
  output=$(ssh \
    -p "$SERVER_PORT" \
    -o "ConnectTimeout=${CONNECT_TIMEOUT}" \
    -o "StrictHostKeyChecking=${STRICT_HOST_KEY_CHECKING}" \
    -o "UserKnownHostsFile=${HOME}/.ssh/known_hosts" \
    -i "$KEY_PATH" \
    -o IdentitiesOnly=yes \
    -o BatchMode=yes \
    -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no \
    -o PreferredAuthentications=publickey \
    "$SSH_TARGET" "$command" 2>&1)
  rc=$?
  set -e

  if [ "$rc" -eq 0 ] && echo "$output" | grep -q "KEY_LOGIN_OK"; then
    echo "Ключ установлен и работает."
    return 0
  fi

  echo
  echo "Не удалось подтвердить вход по ключу."
  echo "$output"
  echo
  return 1
}

install_key_for_detected_system() {
  case "$REMOTE_SYSTEM" in
    unix) install_unix_key ;;
    routeros) install_routeros_key ;;
    *)
      echo "Ошибка: неизвестный тип системы: $REMOTE_SYSTEM"
      exit 1
      ;;
  esac
}

retry_with_new_local_key() {
  echo "Ключ скопирован или попытка копирования была выполнена, но вход по ключу не подтвердился."
  if ! confirm "Сохранить локальный ключ в backup, создать новый и попробовать ещё раз? [y/N]: "; then
    return 1
  fi

  backup_and_generate_key
  build_connection_options
  install_key_for_detected_system
  verify_key_login "$REMOTE_SYSTEM"
}

main() {
  local default_port
  local default_mail
  local install_ok

  ask_required "SERVER_INPUT" "Введите IP/hostname сервера (можно user@host)"
  parse_server_input "$SERVER_INPUT"

  default_port="${PARSED_PORT:-22}"
  ask_with_default "SERVER_PORT" "Введите SSH-порт" "$default_port"

  default_mail="$(default_email)"
  ask_with_default "EMAIL" "Введите email/comment для ключа" "$default_mail"

  ask_with_default "USERNAME" "Введите имя пользователя на сервере" "root"

  validate_inputs
  check_host_key_conflict
  generate_key_if_needed
  build_connection_options
  detect_remote_system

  install_ok=0
  if install_key_for_detected_system; then
    if verify_key_login "$REMOTE_SYSTEM"; then
      install_ok=1
    fi
  fi

  if [ "$install_ok" -ne 1 ] && [ "$REMOTE_SYSTEM" = "unix" ]; then
    if copy_with_ssh_copy_id; then
      if verify_key_login "$REMOTE_SYSTEM"; then
        install_ok=1
      fi
    fi
  fi

  if [ "$install_ok" -ne 1 ]; then
    if retry_with_new_local_key; then
      install_ok=1
    fi
  fi

  if [ "$install_ok" -ne 1 ]; then
    echo "Не удалось настроить вход по ключу."
    exit 1
  fi

  echo
  echo "Готово. Можно подключаться:"
  echo "ssh -p ${SERVER_PORT} ${USERNAME}@${SERVER_HOST}"
}

main "$@"
