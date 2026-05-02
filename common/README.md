# add_key.sh

## RU

`add_key.sh` — общий вспомогательный скрипт для подготовки SSH-доступа перед установкой Telemt.

Он умеет:

```text
спросить сервер, SSH-порт, пользователя и комментарий ключа
создать локальный ed25519 ключ, если выбранного ключа нет
восстановить .pub из приватного ключа
обработать changed/missing known_hosts
скопировать публичный ключ в authorized_keys на Unix/Linux
использовать ssh-copy-id как fallback
поддержать MikroTik RouterOS key import
проверить key-only login
```

Запуск:

```bash
chmod +x ./add_key.sh
./add_key.sh
```

Из OS-каталога:

```bash
chmod +x ../common/add_key.sh
../common/add_key.sh
```

С параметрами:

```bash
chmod +x ./add_key.sh
SERVER_INPUT=root@<SERVER_PUBLIC_IP> SERVER_PORT=<SSH_PORT> KEY_PATH=~/.ssh/id_ed25519 ./add_key.sh
```

## EN

`add_key.sh` is a shared helper for preparing SSH access before running a Telemt installer.

It can:

```text
ask for server, SSH port, username, and key comment
generate a local ed25519 key if the selected key does not exist
repair a missing .pub file from the private key
handle changed or missing known_hosts entries
copy the public key to Unix/Linux authorized_keys
try ssh-copy-id as a fallback
support MikroTik RouterOS key import
verify key-only login
```

Run:

```bash
chmod +x ./add_key.sh
./add_key.sh
```

From an OS directory:

```bash
chmod +x ../common/add_key.sh
../common/add_key.sh
```

With parameters:

```bash
chmod +x ./add_key.sh
SERVER_INPUT=root@<SERVER_PUBLIC_IP> SERVER_PORT=<SSH_PORT> KEY_PATH=~/.ssh/id_ed25519 ./add_key.sh
```
