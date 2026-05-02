# add_key.sh

## RU

`add_key.sh` — общий вспомогательный скрипт для подготовки SSH-доступа перед установкой Telemt. Его задача простая: положить ваш публичный SSH-ключ на сервер и проверить, что после этого вход по ключу действительно работает.

Как он работает:

1. Сначала скрипт спрашивает адрес сервера, SSH-порт, имя пользователя, путь к локальному ключу и комментарий для нового ключа.
2. Если выбранного локального ключа ещё нет, скрипт создаёт новый `ed25519` ключ. Если приватный ключ есть, а `.pub` файл потерян, скрипт восстановит публичный ключ из приватного.
3. Перед подключением скрипт проверяет `known_hosts`. Если host key отсутствует или изменился, он показывает SHA256 fingerprint и просит подтверждение перед записью. Для строгой проверки можно заранее задать `EXPECTED_HOST_KEY_SHA256=SHA256:<FINGERPRINT>`; при несовпадении скрипт остановится.
4. Для обычного Unix/Linux сервера скрипт добавляет публичный ключ в `authorized_keys` выбранного пользователя. Если основной способ не сработал, он пробует `ssh-copy-id` как запасной вариант.
5. Для MikroTik RouterOS скрипт использует отдельный режим импорта ключа через RouterOS.
6. В конце скрипт проверяет вход по ключу без пароля. Если проверка не прошла, он сообщает об ошибке, чтобы не запускать установщик Telemt на сервере с неготовым SSH-доступом.

Скрипт не отключает SSH-пароли и не меняет конфиг SSH-сервера. Этим занимается основной установщик Telemt после проверки, что ключевой вход уже работает.

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

Строгая проверка host key:

```bash
EXPECTED_HOST_KEY_SHA256=SHA256:<FINGERPRINT> SERVER_INPUT=root@<SERVER_PUBLIC_IP> ./add_key.sh
```

## EN

`add_key.sh` is a shared helper for preparing SSH access before running a Telemt installer. Its job is simple: put your public SSH key on the target server and verify that key login really works.

How it works:

1. The script first asks for the server address, SSH port, username, local key path, and comment for a new key.
2. If the selected local key does not exist, the script creates a new `ed25519` key. If the private key exists but the `.pub` file is missing, it rebuilds the public key from the private key.
3. Before connecting, the script checks `known_hosts`. If the host key is missing or changed, it shows the SHA256 fingerprint and asks for confirmation before saving it. For strict verification, set `EXPECTED_HOST_KEY_SHA256=SHA256:<FINGERPRINT>` in advance; the script stops if the fingerprint does not match.
4. For a regular Unix/Linux server, the script adds the public key to the selected user's `authorized_keys`. If the primary method fails, it tries `ssh-copy-id` as a fallback.
5. For MikroTik RouterOS, the script uses a separate RouterOS key import flow.
6. At the end, the script verifies passwordless key login. If verification fails, it reports the error so you do not start the Telemt installer on a server with unfinished SSH access.

The script does not disable SSH passwords and does not modify the SSH server config. The main Telemt installer does that later, after key login has been verified.

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

Strict host key verification:

```bash
EXPECTED_HOST_KEY_SHA256=SHA256:<FINGERPRINT> SERVER_INPUT=root@<SERVER_PUBLIC_IP> ./add_key.sh
```
