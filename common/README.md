# add_key.sh

## RU

`add_key.sh` — общий вспомогательный скрипт для подготовки SSH-доступа перед установкой Telemt. Его задача простая: положить ваш публичный SSH-ключ на сервер и проверить, что после этого вход по ключу действительно работает.

Как он работает:

1. Сначала скрипт спрашивает адрес сервера, SSH-порт, имя пользователя, комментарий для нового ключа и дополнительные `known_hosts` имена/IP, если вы будете подключаться к тому же серверу и по домену, и по IP. Локальный ключ берётся из `KEY_PATH`, а если переменная не задана, используется `~/.ssh/id_ed25519`.
2. Если выбранного локального ключа ещё нет, скрипт создаёт новый `ed25519` ключ. Если приватный ключ есть, а `.pub` файл потерян, скрипт восстановит публичный ключ из приватного.
3. Перед подключением скрипт проверяет `known_hosts`. Если вы указали домен, скрипт также найдёт его IPv4 A-записи и проверит `known_hosts` для домена и IP. Если host key отсутствует или изменился, он показывает SHA256 fingerprint и просит подтверждение перед записью. Для строгой проверки можно заранее задать `EXPECTED_HOST_KEY_SHA256=SHA256:<FINGERPRINT>`; при несовпадении скрипт остановится.
4. Для обычного Unix/Linux сервера скрипт добавляет публичный ключ в `authorized_keys` выбранного пользователя. Если основной способ не сработал, он пробует `ssh-copy-id` как запасной вариант.
5. Для MikroTik RouterOS скрипт использует отдельный режим импорта ключа через RouterOS.
6. В конце скрипт проверяет вход по ключу без пароля. Если проверка не прошла, он сообщает об ошибке, чтобы не запускать установщик Telemt на сервере с неготовым SSH-доступом.

Скрипт не отключает SSH-пароли и не меняет конфиг SSH-сервера. Этим занимается основной установщик Telemt после проверки, что ключевой вход уже работает.

Запуск:

```bash
chmod +x ./add_key.sh
./add_key.sh
```

Полный интерактивный пример:

```text
Введите IP/hostname сервера (можно user@host): root@<SERVER_PUBLIC_IP>
Введите SSH-порт [22]: <SSH_PORT>
Введите email/comment для ключа [<LOCAL_USER>@<LOCAL_HOST>]: admin@<PROXY_DOMAIN>
Введите имя пользователя на сервере [root]: root
Дополнительные known_hosts имена/IP через запятую (если будете подключаться и по IP): <SERVER_PUBLIC_IP>
```

Как отвечать:

1. В первом вопросе можно указать просто `<SERVER_PUBLIC_IP>` или сразу `root@<SERVER_PUBLIC_IP>`.
2. В SSH-порте можно нажать Enter и оставить `22`, либо ввести свой порт, например `122`.
3. В `email/comment` можно указать email или понятный комментарий ключа. Это только подпись локального SSH-ключа.
4. В имени пользователя обычно указывается `root`, если установка Telemt будет идти от root.
5. В дополнительных `known_hosts` можно указать IP сервера, если вы вводили домен, но потом будете подключаться командой `ssh root@<SERVER_PUBLIC_IP>`. Если не нужно, нажмите Enter.

Дальше скрипт проверит локальный ключ. Если файла ключа нет, начнётся создание нового `ed25519` ключа:

```text
Генерирую новый SSH-ключ: ~/.ssh/id_ed25519
```

Потом скрипт проверит host key сервера. Если указан домен, будут проверены и домен, и его A-записи. Это важно: `ssh root@<PROXY_DOMAIN>` и `ssh root@<SERVER_PUBLIC_IP>` для SSH являются разными записями в `known_hosts`.

Если host key отсутствует или изменился, скрипт покажет SHA256 fingerprint и спросит:

```text
Доверять этому host key и добавить его в known_hosts? [y/N]: y
```

Если сервер переустановлен и SSH ругается на старый ключ для IP, можно запустить:

```bash
SERVER_INPUT=root@<PROXY_DOMAIN> ./add_key.sh
```

Если локальная DNS-система отдаёт fake-IP, например `198.18.x.x`, скрипт пропустит этот адрес и напишет предупреждение. Настоящий IP нужно указать явно:

```bash
EXTRA_KNOWN_HOSTS=<SERVER_PUBLIC_IP> SERVER_INPUT=root@<PROXY_DOMAIN> ./add_key.sh
```

Скрипт увидит домен и дополнительный IP, удалит старые записи после подтверждения и запишет новые ключи для обоих вариантов подключения.

Если заранее задан `EXPECTED_HOST_KEY_SHA256=SHA256:<FINGERPRINT>`, скрипт сравнит fingerprint автоматически и остановится при несовпадении.

После этого начинается подключение к серверу. Если ключ ещё не установлен, SSH обычно спросит пароль пользователя на сервере:

```text
root@<SERVER_PUBLIC_IP>'s password: <SSH_PASSWORD>
```

Пароль вводится в терминале, символы при вводе не показываются. После успешного входа начинается копирование публичного ключа в `authorized_keys`. В конце скрипт проверяет вход только по ключу и должен вывести:

```text
Ключ установлен и работает.
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

1. The script first asks for the server address, SSH port, username, comment for a new key, and extra `known_hosts` names/IPs if you will connect to the same server by both domain and IP. The local key is taken from `KEY_PATH`; if the variable is not set, `~/.ssh/id_ed25519` is used.
2. If the selected local key does not exist, the script creates a new `ed25519` key. If the private key exists but the `.pub` file is missing, it rebuilds the public key from the private key.
3. Before connecting, the script checks `known_hosts`. If you entered a domain, it also resolves IPv4 A records and checks `known_hosts` for both the domain and the IP address. If the host key is missing or changed, it shows the SHA256 fingerprint and asks for confirmation before saving it. For strict verification, set `EXPECTED_HOST_KEY_SHA256=SHA256:<FINGERPRINT>` in advance; the script stops if the fingerprint does not match.
4. For a regular Unix/Linux server, the script adds the public key to the selected user's `authorized_keys`. If the primary method fails, it tries `ssh-copy-id` as a fallback.
5. For MikroTik RouterOS, the script uses a separate RouterOS key import flow.
6. At the end, the script verifies passwordless key login. If verification fails, it reports the error so you do not start the Telemt installer on a server with unfinished SSH access.

The script does not disable SSH passwords and does not modify the SSH server config. The main Telemt installer does that later, after key login has been verified.

Run:

```bash
chmod +x ./add_key.sh
./add_key.sh
```

Full interactive example:

```text
Введите IP/hostname сервера (можно user@host): root@<SERVER_PUBLIC_IP>
Введите SSH-порт [22]: <SSH_PORT>
Введите email/comment для ключа [<LOCAL_USER>@<LOCAL_HOST>]: admin@<PROXY_DOMAIN>
Введите имя пользователя на сервере [root]: root
Дополнительные known_hosts имена/IP через запятую (если будете подключаться и по IP): <SERVER_PUBLIC_IP>
```

How to answer:

1. For the first question, enter either `<SERVER_PUBLIC_IP>` or `root@<SERVER_PUBLIC_IP>`.
2. For SSH port, press Enter to keep `22`, or type your custom port, for example `122`.
3. For `email/comment`, enter an email or a clear key label. It is only the local SSH key comment.
4. For username, usually enter `root` when the Telemt installer will be run as root.
5. For extra `known_hosts`, enter the server IP if you entered a domain but will later connect with `ssh root@<SERVER_PUBLIC_IP>`. If you do not need this, press Enter.

Next, the script checks the local key. If the key file does not exist, it creates a new `ed25519` key:

```text
Генерирую новый SSH-ключ: ~/.ssh/id_ed25519
```

Then the script checks the server host key. If you entered a domain, it checks both the domain and its A records. This matters because `ssh root@<PROXY_DOMAIN>` and `ssh root@<SERVER_PUBLIC_IP>` are different `known_hosts` entries for SSH.

If the host key is missing or changed, it shows the SHA256 fingerprint and asks:

```text
Доверять этому host key и добавить его в known_hosts? [y/N]: y
```

If the server was reinstalled and SSH complains about the old key for the IP, run:

```bash
SERVER_INPUT=root@<PROXY_DOMAIN> ./add_key.sh
```

If local DNS returns a fake IP, for example `198.18.x.x`, the script skips that address and prints a warning. Provide the real IP explicitly:

```bash
EXTRA_KNOWN_HOSTS=<SERVER_PUBLIC_IP> SERVER_INPUT=root@<PROXY_DOMAIN> ./add_key.sh
```

The script will see the domain and the extra IP, remove old entries after confirmation, and save new keys for both connection forms.

If `EXPECTED_HOST_KEY_SHA256=SHA256:<FINGERPRINT>` is set in advance, the script compares the fingerprint automatically and stops on mismatch.

After that, the script connects to the server. If the key is not installed yet, SSH usually asks for the server user's password:

```text
root@<SERVER_PUBLIC_IP>'s password: <SSH_PASSWORD>
```

The password is typed in the terminal and is not shown while typing. After a successful login, the script copies the public key into `authorized_keys`. At the end, it verifies key-only login and should print:

```text
Ключ установлен и работает.
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
