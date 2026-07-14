# Telemt Docker Image Builder

This directory builds a local Telemt Docker image from official upstream release artifacts and includes a Docker-based Telemt server installer.

## Installer Notice / Уведомление об установщике

RU: Этот проект содержит обычный Bash-установщик и Dockerfile для упрощения установки Telemt с HTTPS-маскировкой. Это не официальный установщик Telemt. В репозитории нет встроенного бинарника Telemt, сертификатов, ключей или proxy-секретов. Сборка и установщик скачивают программное обеспечение из официальных источников:

- Telemt: GitHub releases проекта `telemt/telemt`, `https://github.com/telemt/telemt`; Dockerfile скачивает release asset и проверяет upstream `.sha256`.
- Docker / containerd / Docker Compose: пакеты дистрибутива или официальный Docker apt repository, `https://download.docker.com`.
- nginx, certbot, openssl, jq, iproute2 и другие системные пакеты: официальные репозитории Debian/Ubuntu.
- Ubuntu nginx/OpenSSL fallback: официальные release archives OpenSSL и nginx с закрепленными SHA-256.
- base images: `debian:12-slim` и `gcr.io/distroless/static-debian12:nonroot` из публичных registry.

EN: This project contains an ordinary Bash installer and Dockerfile that make Telemt with HTTPS camouflage easier to install. It is not an official Telemt installer. This repository does not contain an embedded Telemt binary, certificates, keys, or proxy secrets. The build and installer download software from official sources:

- Telemt: GitHub releases of `telemt/telemt`, `https://github.com/telemt/telemt`; the Dockerfile downloads the release asset and verifies the upstream `.sha256`.
- Docker / containerd / Docker Compose: distribution packages or the official Docker apt repository, `https://download.docker.com`.
- nginx, certbot, openssl, jq, iproute2, and other system packages: official Debian/Ubuntu repositories.
- Ubuntu nginx/OpenSSL fallback: official OpenSSL and nginx release archives with pinned SHA-256 values.
- base images: `debian:12-slim` and `gcr.io/distroless/static-debian12:nonroot` from public registries.

The image is not published unless `PUSH=1` is explicitly set.

Latest repository changes are tracked in [CHANGELOG.md](CHANGELOG.md).

## RU

### Быстрый выбор

```text
telemt2/install.sh         Единый выбор установки/обновления по ОС.
build.sh                  Собрать Docker image Telemt.
install_docker-telemt.sh  Установить сервер: nginx + certbot + Docker Telemt + маскировка.
telemt-users.sh           Добавить/удалить пользователей и пересобрать ссылки после установки.
compose.example.yml       Пример hardened compose для ручной интеграции.
```

Для обычной установки или обновления рекомендуется единая точка входа:

```bash
curl -fsSL -o /root/install.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/install.sh
chmod +x /root/install.sh
/root/install.sh -lang ru
```

Она определит Debian 13 или Ubuntu 24-26, найдёт существующий Docker/native
Telemt и предложит безопасное действие. На Ubuntu будет выбран только Docker;
на Debian 13 при новой установке можно выбрать Docker или native/systemd.
Обновить найденный вариант без первого меню:

```bash
/root/install.sh --update -lang ru
```

Команды `install_docker-telemt.sh` ниже являются прямым интерфейсом Docker-
установщика и остаются полезны для `--fix-nginx`, `--auto` и диагностики.

Тот же `install.sh` автоматически зеркалируется в корень старого Docker-
репозитория `Telemtinstall/telemt`. Вложенных копий в папках установщиков нет;
оба корневых файла байт-в-байт одинаковы и используют `telemt2` как источник.

### Что делает

`Dockerfile` скачивает официальный Telemt release asset из `telemt/telemt`, скачивает рядом `.sha256`, проверяет checksum и кладет бинарник в минимальный image.

По умолчанию собирается `prod` image:

- base: `gcr.io/distroless/static-debian12:nonroot`;
- process user: non-root;
- config path: `/etc/telemt/telemt.toml`;
- healthcheck: `telemt healthcheck /etc/telemt/telemt.toml --mode liveness`;
- no shell, no package manager in final image.

Также есть `debug` target на `debian:12-slim` с `curl`, `iproute2`, `busybox`.

### Локальная сборка

Скачать репозиторий через Git и запустить установщик:

```bash
apt update
apt install -y git ca-certificates
if [ -d /root/telemt2/.git ]; then
  cd /root/telemt2
  git pull --ff-only
else
  git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /root/telemt2
  cd /root/telemt2
  git sparse-checkout set telemt/docker-telemt
fi
cd /root/telemt2/telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh -lang ru
```

Автоматическая установка: спросить только домен, дальше идти на настройках по умолчанию:

```bash
./install_docker-telemt.sh --auto -lang ru
```

Полностью без ввода:

```bash
DOMAIN=proxy.example.com ./install_docker-telemt.sh --auto -lang ru
```

`--auto` включает ответы по умолчанию и автоматически подтверждает план установки. Домен берется из `DOMAIN`, сохраненного конфига или FQDN hostname сервера. Если домен определить нельзя и запуск идет в обычном терминале, установщик спросит только `Домен прокси`, а дальше продолжит сам. В неинтерактивном запуске передайте `DOMAIN=proxy.example.com`.

Скачать только нужные файлы через `wget`:

```bash
apt update
apt install -y ca-certificates wget
mkdir -p /root/telemt2/telemt/docker-telemt
cd /root/telemt2/telemt/docker-telemt
wget -O Dockerfile https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/Dockerfile
wget -O build.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/build.sh
wget -O install_docker-telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/install_docker-telemt.sh
wget -O telemt-users.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/telemt-users.sh
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh -lang ru
```

Скачать только нужные файлы через `curl`:

```bash
apt update
apt install -y ca-certificates curl
mkdir -p /root/telemt2/telemt/docker-telemt
cd /root/telemt2/telemt/docker-telemt
curl -fsSLo Dockerfile https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/Dockerfile
curl -fsSLo build.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/build.sh
curl -fsSLo install_docker-telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/install_docker-telemt.sh
curl -fsSLo telemt-users.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/telemt-users.sh
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh -lang ru
```

Если файлы уже лежат на сервере:

```bash
chmod +x ./build.sh
./build.sh
```

Для production лучше указывать точный release tag:

```bash
TELEMT_VERSION=<version> ./build.sh
```

Собрать debug image:

```bash
TARGET=debug ./build.sh
```

Проверить версию:

```bash
docker run --rm --entrypoint /app/telemt telemt-local:3.4.23 --version
```

### Установка сервера

`install_docker-telemt.sh` ставит полный серверный слой вокруг Docker image:

- архитектура `TLS-Fronting + TCP-Splitting` только для вашего домена;
- nginx HTTP -> HTTPS redirect;
- nginx SNI stream на внешнем `443/tcp`;
- HTTPS mask site на `127.0.0.1:8443`;
- Telemt в Docker на `127.0.0.1:1443`;
- Telemt API только на `127.0.0.1:9091`;
- Telemt metrics только на `127.0.0.1:9090`;
- Let's Encrypt сертификат и `certbot.timer`;
- выбор маскировочной страницы: красивая заглушка или пустой HTML;
- Docker hardening и healthcheck с отдельным вопросом;
- отключение runtime-логов по умолчанию;
- опционально `ad_tag`, `middle_proxy`, high-load tuning;
- Telemt `3.4.23`-совместимые настройки: `/run/telemt` runtime cache, `client_mss`, `client_mss_bulk`, `user_enabled`, upstream IPv4 policy, Synlimit V2-поля и явно выключенный `synlimit`.

В этой схеме обычный сканер или браузер без MTProxy-ключа получает HTTPS-сайт-заглушку с настоящим сертификатом вашего домена. Telemt не подменяет TLS и не делает MITM: он оставляет валидных MTProxy-клиентов внутри Telemt, а остальные TLS-соединения передаёт на mask site как TCP-поток.

Заглушка намеренно настраивается как обычный HTTPS без отдельной директивы `http2`. Это совместимо с nginx 1.24 и старыми пакетами Debian/Ubuntu, где строка `http2 on;` вызывает ошибку `unknown directive "http2"`. Для маскировочного сайта HTTP/2 не нужен.

Перед запуском нужен чистый Debian 13.x или Ubuntu 24.x-26.x сервер, A-запись домена на IPv4 сервера и свободные `80/tcp`, `443/tcp`. Другие версии ОС установщик останавливает сразу, до установки пакетов.

На Ubuntu Telemt устанавливается только в Docker. Публичные `80/443` принимает
host nginx. Установщик проверяет OpenSSL не по случайной команде из `PATH`, а у
nginx command и бинарника, реально указанного в `nginx.service`. Если Ubuntu
nginx не имеет stream preread или использует OpenSSL ниже функционального
порога `3.5.2`/security target `3.5.7`, автоматически собирается изолированный
nginx `1.31.2` с OpenSSL `3.5.7`. Системные shared libraries не заменяются,
Telemt остается в Docker. Та же проверка выполняется при `--update` и
`--fix-nginx`; Debian 13 продолжает использовать обычный distro nginx.

Короткий Ubuntu-only launcher находится в `telemt/ubuntu-24-26/`. Он проверяет
ОС и передает все аргументы этому каноническому Docker-установщику.

Если `80/tcp` или `443/tcp` уже заняты Docker-контейнером, установщик покажет имя контейнера, image и проброшенные порты, например `whatsapp-proxy facebook/whatsapp_proxy:20260607`, и спросит, удалить ли эти контейнеры для продолжения установки Telemt. При ответе `no` установка остановится без удаления.

### Готовые команды

Установка с нуля на чистом сервере:

```bash
apt update
apt install -y git ca-certificates
if [ -d /root/telemt2/.git ]; then
  cd /root/telemt2
  git pull --ff-only
else
  git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /root/telemt2
  cd /root/telemt2
  git sparse-checkout set telemt/docker-telemt
fi
cd /root/telemt2/telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh -lang ru
```

Обновить уже установленный Telemt без сброса настроек:

```bash
cd /root/telemt2
git pull --ff-only
cd telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh --update -lang ru
```

Обновить Docker Telemt `3.4.18` до проверенной совместимой версии `3.4.23` из репозитория `telemt2`:

```bash
cd /root/telemt2
git pull --ff-only
cd telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh

# сначала посмотреть план без изменений
printf 'n\n' | ./install_docker-telemt.sh --update -lang ru

# если в плане указано 3.4.18 -> 3.4.23, запустить обновление
./install_docker-telemt.sh --update -lang ru
```

Проверка после обновления:

```bash
docker exec telemt /app/telemt --version
docker ps --filter name=telemt
curl -fsS http://127.0.0.1:9091/v1/users
nginx -t
cat /root/telemt-proxy-links.txt
```

Починить уже установленный сервер: nginx/Docker/Telemt doctor:

```bash
cd /root/telemt2
git pull --ff-only
cd telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh --fix-nginx -lang ru
```

Полная переустановка на уже установленном сервере:

```bash
cd /root/telemt2
git pull --ff-only
cd telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
RESET_INSTALL_STATE=1 ./install_docker-telemt.sh -lang ru
```

Этот режим удаляет старый saved config, secret, `telemt.toml`, compose, контейнер и ссылки. Чужие nginx-сайты не трогает.

На этапе сертификата установщик сначала проверяет HTTP-01 challenge без участия Let's Encrypt: создает временный файл в `/var/www/<domain>/.well-known/acme-challenge/`, проверяет его локально через nginx и затем через публичный IPv4 командой `curl -4 --resolve <domain>:80:<server_ipv4>`. Если файл не отдается, скрипт останавливается до `certbot` и пишет диагностику в `/root/telemt-acme-http01-check.txt`: DNS A/AAAA, слушающие порты, `nginx -t`, site config и firewall. Это помогает сразу увидеть закрытый `80/tcp`, неправильную A-запись, лишнюю AAAA-запись или CDN/proxy, который не пропускает `/.well-known/acme-challenge/`.

Обычный запуск:

```bash
chmod +x ./install_docker-telemt.sh
./install_docker-telemt.sh
```

Русский интерфейс установщика:

```bash
./install_docker-telemt.sh -lang ru
```

Аварийный ремонт nginx после ошибки `unknown directive "http2"`:

```bash
./install_docker-telemt.sh --fix-nginx -lang ru
```

Этот режим делает бэкап измененных nginx-файлов, удаляет несовместимые строки `http2 on;` и `listen ... http2;`, а при дублирующихся top-level `stream {}` блоках оставляет основной Telemt stream config и отключает лишние stream-файлы. Stream-конфиг на `443/tcp` использует SNI-router: домен прокси идет в Telemt на `127.0.0.1:1443`, а неизвестный или non-SNI трафик идет напрямую на локальную HTTPS-маску `127.0.0.1:8443`. Затем запускает `nginx -t` и reload. После этого он проверяет Docker/Compose, при необходимости ставит Docker Compose v2, пересобирает отсутствующий локальный image `telemt-local:*` через `build.sh` и пересоздает только контейнер `telemt` из уже существующего compose-файла. Системный Python при этом не обновляется. Это обходит Docker Compose v1 `ContainerConfig`/removed-image ошибки после неудачных обновлений. Потом проверяет наличие `telemt.toml`, локальный API, `certbot.timer` и слушающие порты. Telemt-секреты, пользователи и сертификаты сохраняются. `telemt.toml` не перегенерируется полностью; doctor может только убрать несовместимый optional-блок `censorship.exclusive_mask`, если старая версия Telemt из-за него не стартует. Обычная установка и `--update` дополнительно делают GET-проверку маскировочной страницы через публичный `443/tcp` и печатают `Маскировочная страница OK`, если сайт реально открывается.

Обновить уже установленный сервер без перезаписи текущих настроек:

```bash
./install_docker-telemt.sh --update -lang ru
```

Если установщик находит существующую установку в `/opt/telemt-docker`, обычный запуск останавливается. Это защита от случайного запуска install-режима поверх живого сервера. Используйте `--update` для обновления или `--fix-nginx` для ремонта. Переустановка с нуля требует явного подтверждения через `RESET_INSTALL_STATE=1`.

`RESET_INSTALL_STATE=1` означает именно новую установку: старый сохраненный ввод, старый Telemt secret, старый `telemt.toml`, compose, контейнер и ссылки удаляются до вопросов. Установщик заново спросит домен, email, пользователя и остальные параметры. Старые nginx-файлы Telemt удаляются только если выглядят созданными этим установщиком; чужие nginx-сайты не трогаются. Новая заглушка пишется в отдельный nginx-файл `telemt-mask-<domain>.conf`, чтобы не затирать vhost с именем домена.

Режим `--update` сначала анализирует существующую установку: читает домен и пользователя из `telemt.toml`, image из compose, пытается определить текущую версию Telemt по контейнеру/image/tag и выводит список отсутствующих совместимых ключей. После подтверждения он делает бэкап `/opt/telemt-docker/telemt.toml`, `docker-compose.yml`, секретов, ссылок и nginx-конфигов, переключает compose image на точный tag проверенной совместимой версии (`telemt-local:3.4.23` по умолчанию), пересобирает/скачивает именно этот release tag, дополняет текущий `telemt.toml`/compose только отсутствующими безопасными ключами, пересоздает контейнер и заново выполняет API/active-probing проверку. Ручные значения не перезаписываются; `TELEMT_VERSION=latest` в `--update` не используется и заменяется на pinned compatible version.

Домены можно вводить как обычные ASCII-домены, как punycode (`xn--...`) или кириллицей. Установщик переводит IDN в punycode/ASCII перед DNS, Let's Encrypt, nginx и MTProxy-ссылками. Если введен некорректный punycode, установка останавливается до изменения системы.

На чистом VPS обычно вход выполняется сразу под `root`, поэтому `sudo` не нужен и может быть не установлен. Если вы запускаете не под `root`, используйте:

```bash
if [ "$(id -u)" -eq 0 ]; then
  ./install_docker-telemt.sh -lang ru
elif command -v sudo >/dev/null 2>&1; then
  sudo ./install_docker-telemt.sh -lang ru
else
  su -c "./install_docker-telemt.sh -lang ru"
fi
```

Если `telemt-local:<tag>` ещё не собран, установщик сам запустит `build.sh` из этого же каталога. Отдельно запускать `build.sh` перед установкой больше не обязательно.

Если image находится в registry:

```bash
TELEMT_IMAGE=ghcr.io/Telemtinstall/telemt:3.4.23 ./install_docker-telemt.sh
```

### Вопросы установщика

В обычной установке можно нажимать `Enter` на всех вопросах, кроме домена. Дефолты подобраны для обычного VPS с nginx-fronting и Docker Telemt.

| Вопрос | Что означает | Дефолт | Что обычно ставить |
| --- | --- | --- | --- |
| `Домен прокси` | Домен, который будет в MTProxy-ссылке, TLS SNI, nginx и Let's Encrypt. DNS A-запись должна указывать на IPv4 сервера. | Нет дефолта, кроме сохраненного значения или hostname в `--auto`. | Указать настоящий домен прокси, например `proxy.example.com`. |
| `Email для Let's Encrypt` | Email для выпуска и продления TLS-сертификата. | `admin@<domain>`. | Можно оставить дефолт или указать свой рабочий email. |
| `Docker image Telemt` | Имя Docker image, который будет запускаться в compose. | `telemt-local:3.4.23`. | Оставить дефолт. Для registry указать точный tag, например `ghcr.io/Telemtinstall/telemt:3.4.23`. |
| `Маскировочная страница` | Что покажет обычный браузер без MTProxy secret. `fancy` дает простую красивую заглушку, `empty` отдает пустой HTML с `200 OK`. | `fancy`. | Обычно `fancy`; если нужна максимально пустая маска, выбрать `empty`. |
| `Имя пользователя Telemt` | Имя первой ссылки/пользователя в `[access.users]`. Secret генерируется автоматически. | `default`. | Для одного владельца можно оставить `default`; для учета клиентов лучше задать имя, например `user1` или `client1`. |
| `Сколько ссылок/пользователей создать сразу` | Сколько отдельных пользователей и proxy-ссылок создать при установке. | `1`. | Обычно `1`; если сразу нужны разные ссылки для разных людей, указать нужное число. |
| `Имя пользователя Telemt #2/#3/...` | Имена дополнительных пользователей, если выбрано больше одной ссылки. | `user2`, `user3`, ... | Задать понятные имена клиентов или оставить предложенные. |
| `Максимум подключений Telemt` | Лимит TCP-подключений на пользователя в `[access.user_max_tcp_conns]`. | `5000`. | Оставить `5000` для обычного/нагруженного VPS; уменьшать только если надо жестко ограничить клиента. |
| `TCP MSS для Telemt listener` | Настройка `client_mss` для устойчивости TCP против проблем с фрагментацией/DPI. Варианты: `off`, `tspu`, `2in8`, `extreme-low`, число `88..4096`. | `tspu`. | Оставить `tspu`. Если появляются сетевые проблемы, тестировать `2in8` или `extreme-low`; `off` только если точно не нужно. |
| `SYN limiter Telemt listener` | Встроенный SYN limiter Telemt. Варианты: `false`, `iptables`, `nftables`. | `false`. | Оставить `false`. В нашей схеме публичный `443/tcp` принимает nginx, а limiter требует дополнительных сетевых прав контейнера. |
| `MTProxy ad_tag` | 32-hex рекламный tag Telegram MTProxy. Нужен только если вы используете официальный promoted proxy/ad tag. | Пусто. | Обычно оставить пустым. Если есть свой `ad_tag`, вставить 32 hex символа. |
| `Использовать Telegram middle proxy` | Включает `use_middle_proxy`. Если задан `ad_tag`, установщик предлагает `yes`, иначе `no`. | `no` без `ad_tag`, `yes` с `ad_tag`. | Обычно `no`. С `ad_tag` чаще оставить `yes`. |
| `Включить access-логи nginx/Docker` | Включает runtime/access логи. По умолчанию они отключены для приватности и меньшей нагрузки на диск. | `no`. | Обычно `no`. Временно ставить `yes` только для диагностики. |
| `Включить Docker hardening и healthcheck` | Добавляет `read_only`, `cap_drop: ALL`, `no-new-privileges`, `/tmp` tmpfs и Docker healthcheck. `/run/telemt` tmpfs включается всегда. | `yes`. | Оставить `yes`. Отключать только для отладки нестандартной проблемы с контейнером. |
| `Включить high-load tuning для большого числа клиентов` | Пишет sysctl-настройки для backlog, keepalive, file-max и BBR, если доступен. | `yes`. | Оставить `yes` на VPS под прокси. |
| `Введите y, yes или да для продолжения` | Финальное подтверждение плана перед изменением системы. | Нет автодефолта в ручном режиме. | Проверить домен, IP, image, пользователей и ввести `y`. |

В режиме `--auto` установщик берет эти дефолты сам и спрашивает только домен, если не смог определить его из `DOMAIN`, сохраненного конфига или hostname.

В конце установки скрипт выполняет active probing проверку на вашем домене:

```bash
openssl s_client -4 -connect <server_ipv4>:443 -servername <domain>
openssl s_client -4 -connect <domain>:443 -servername <domain>
curl -4 -I --resolve <domain>:443:<server_ipv4> https://<domain>/
```

Результат сохраняется в `/root/telemt-active-probing-check.txt`. Если обычный HTTPS-запрос через IP сервера не получает корректный ответ, установка останавливается с ошибкой, потому что маскировочный слой работает неправильно. При ошибке скрипт сам печатает диагностику: DNS A/AAAA, слушающие порты, `nginx -t`, наличие stream-конфига, `docker ps`, последние логи Telemt и состояние firewall. Если в выводе есть `BIO_connect:connect error`, чаще всего `443/tcp` закрыт firewall-ом/панелью хостера или nginx stream не слушает публичный `443`.

Если после ручного обновления OpenSSL проверка падает с `unable to get local issuer certificate`, но сайт открывается и внешняя SNI/TLS-проверка проходит, используйте отдельный compatibility wrapper. Он сравнит стандартный trust path OpenSSL с системным CA-bundle, а с явным `--run-update` запустит штатный updater с `SSL_CERT_FILE`/`CURL_CA_BUNDLE`. Сам wrapper не меняет сертификат, nginx, Telemt-конфиг или секреты; после проверки действует обычная логика `--update`. Wrapper не устанавливает и не рекомендует стороннюю сборку OpenSSL/nginx; на Debian 13 следует использовать штатные обновляемые пакеты ОС:

```bash
cd /root/telemt2/telemt/docker-telemt
chmod +x ./update-with-system-ca.sh
./update-with-system-ca.sh -lang ru
# Только после проверки показанных current/target версий:
./update-with-system-ca.sh --run-update -lang ru
```

По умолчанию wrapper ничего не обновляет. С `--run-update` он дополнительно откажется запускаться, если работающая версия Telemt новее совместимого target в официальном updater, чтобы не сделать скрытый downgrade. Если проверка с явным системным CA-bundle тоже не проходит, надо исправлять реальный сертификат или его цепочку. Полный результат сохраняется в `/root/telemt-openssl-ca-check.txt`.

По умолчанию используется красивая заглушка. Если выбрать `empty`, nginx будет отдавать пустой `index.html` с `200 OK`, без видимого текста. Логи доступа выключены. Docker hardening включен по умолчанию, но его можно отключить. High-load tuning включен по умолчанию, но его можно отключить ответом `no`. Дефолтный лимит Telemt поднят до `5000` подключений.

В конце скрипт сам собирает корректные ссылки для TLS MTProxy:

```text
https://t.me/proxy?server=<domain>&port=443&secret=<tls_secret>
tg://proxy?server=<domain>&port=443&secret=<tls_secret>
```

Ссылки сохраняются в `/root/telemt-proxy-links.txt`, а основная HTTPS-ссылка для быстрого копирования — в `/root/telemt-proxy-link.txt`. Если при установке выбрать несколько пользователей, файл будет содержать отдельную пару ссылок для каждого пользователя. `secret` собирается как `ee + 32_hex_secret + hex(domain)`, чтобы Telegram не ругался на неверный параметр ключа. Если публичный IPv4 сервера отличается от домена, дополнительно пишется `/root/telemt-proxy-link-ip.txt`: это ссылка с подключением к IP, но с тем же доменным TLS-SNI внутри `secret`.

После установки можно добавлять и удалять ссылки отдельной утилитой:

```bash
telemt-users list
telemt-users status
telemt-users add user2
telemt-users add friend 5000
telemt-users disable friend
telemt-users enable friend
telemt-users links
telemt-users del friend
```

`telemt-users` делает бэкап `telemt.toml`, добавляет/удаляет пользователя в `[access.users]`, управляет временным отключением через `[access.user_enabled]`, обновляет список ссылок, пересоздает контейнер Telemt и снова пишет `/root/telemt-proxy-links.txt` и `/root/telemt-proxy-link-ip.txt`, если доступен публичный IPv4. Отключенные пользователи остаются в конфиге с прежним secret, но помечаются как disabled.

Если Docker hardening включен, compose добавляет:

```text
read_only root filesystem
cap_drop: ALL
no-new-privileges
tmpfs for /tmp
tmpfs for /run/telemt
Docker healthcheck
```

CPU/RAM/PID лимиты в compose не задаются. Это сделано специально, чтобы Telemt не упирался в искусственные ограничения при большом числе клиентов и загрузке медиа.

Если Docker hardening отключен, контейнер запускается проще: без `read_only`, `cap_drop`, `no-new-privileges`, `/tmp` tmpfs и без compose healthcheck. Runtime tmpfs `/run/telemt` остается включенным, потому что Telemt `3.4.23` пишет туда cache/state.

Для Telemt `3.4.12+` новые установки и `--update` также добавляют явную секцию:

```toml
[censorship.exclusive_mask]
"<domain>" = "127.0.0.1:8443"
```

Это закрепляет fallback-трафик с SNI вашего домена за локальным HTTPS mask site. Остальной fallback продолжает работать через обычные `mask_host`/`mask_port`.

Для Telemt `3.4.23` конфиг также получает runtime-кеш в `/run/telemt`, `beobachten`-окно для JA3/JA4 диагностики, `client_mss = "tspu"` и `client_mss_bulk = "1400"` если MSS не отключен, `[access.user_enabled]`, per-upstream `ipv4/ipv6`, `mask_dynamic = false` для сохранения статической mask-схемы и `synlimit = false`. SYN limiter не включается автоматически в Docker/nginx-stream схеме, потому что для него нужен `CAP_NET_ADMIN`, а внешний `443/tcp` принимает nginx. Если оператор вручную включает `TELEMT_SYNLIMIT=nftables|iptables`, скрипт пишет новые Synlimit V2-поля `synlimit_ios_*` и `synlimit_hashlimit_*`.

### Публикация

По умолчанию публикации нет. Чтобы отправить image в registry, нужно явно включить `PUSH=1`:

```bash
IMAGE=ghcr.io/Telemtinstall/telemt PUSH=1 ./build.sh
```

Перед публикацией нужно быть залогиненным:

```bash
docker login ghcr.io
```

### Переменные

```text
TELEMT_REPOSITORY  GitHub repo с release assets. Default: telemt/telemt
TELEMT_VERSION     Точный release tag. Default: 3.4.23
TELEMT_LATEST_COMPATIBLE_VERSION
                  Проверенная целевая версия для --update. Default: 3.4.23
IMAGE              Имя image. Default: telemt-local
IMAGE_TAG          Docker tag. Default: TELEMT_VERSION
AUTO_BUILD_IMAGE   yes автоматически собирает image, если его нет. Default: yes
MASK_SITE_MODE     fancy или empty. Default: fancy
TELEMT_CLIENT_MSS  off, tspu, 2in8, extreme-low или 88..4096. Default: tspu
TELEMT_CLIENT_MSS_BULK
                  off, tspu, 2in8, extreme-low или 88..4096. Default: 1400
TELEMT_SYNLIMIT    false, iptables или nftables. Default: false
TARGET             prod или debug. Default: prod
PLATFORM           linux/amd64 или linux/arm64, опционально
NO_CACHE           1 отключает build cache
PUSH               1 публикует image, по умолчанию 0
ALLOW_TELEMT_LATEST
                  1 разрешает TELEMT_VERSION=latest осознанно; по умолчанию latest заблокирован
```

### Compose пример

`compose.example.yml` показывает hardened-запуск:

- `network_mode: host`;
- config монтируется read-only;
- Docker logs отключены;
- root filesystem read-only;
- runtime cache использует tmpfs `/run/telemt`;
- `cap_drop: ALL`;
- `no-new-privileges`;
- `ulimits.nofile` поднят до `65535/65535`.

## EN

### Quick Choice

```text
telemt2/install.sh         Select install/update and installer by OS.
build.sh                  Build the Telemt Docker image.
install_docker-telemt.sh  Install server: nginx + certbot + Docker Telemt + masking.
telemt-users.sh           Add/remove users and regenerate proxy links after installation.
compose.example.yml       Hardened compose example for manual integration.
```

For a normal install or update, use the universal entry point:

```bash
curl -fsSL -o /root/install.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/install.sh
chmod +x /root/install.sh
/root/install.sh -lang en
```

It detects Debian 13 or Ubuntu 24-26 and any existing Docker/native Telemt
installation. Ubuntu is Docker-only; a clean Debian 13 install offers Docker
or native/systemd. Run `/root/install.sh --update -lang en` to update the
detected variant without the first menu. Direct `install_docker-telemt.sh`
commands remain available for `--fix-nginx`, `--auto`, and diagnostics.

The same `install.sh` is mirrored automatically to the root of the legacy
`Telemtinstall/telemt` Docker repository. There are no nested installer copies;
both root files are byte-identical and use `telemt2` as their source.

### What It Does

`Dockerfile` downloads the official Telemt release asset from `telemt/telemt`, downloads the matching `.sha256`, verifies the checksum, and copies the binary into a minimal runtime image.

Default target is `prod`:

- base: `gcr.io/distroless/static-debian12:nonroot`;
- process user: non-root;
- config path: `/etc/telemt/telemt.toml`;
- healthcheck: `telemt healthcheck /etc/telemt/telemt.toml --mode liveness`;
- no shell or package manager in the final image.

There is also a `debug` target based on `debian:12-slim` with `curl`, `iproute2`, and `busybox`.

### Local Build

Download the repository with Git and run the installer:

```bash
apt update
apt install -y git ca-certificates
if [ -d /root/telemt2/.git ]; then
  cd /root/telemt2
  git pull --ff-only
else
  git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /root/telemt2
  cd /root/telemt2
  git sparse-checkout set telemt/docker-telemt
fi
cd /root/telemt2/telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh
```

Automatic install: ask only for the domain, then continue with defaults:

```bash
./install_docker-telemt.sh --auto -lang en
```

Fully non-interactive install:

```bash
DOMAIN=proxy.example.com ./install_docker-telemt.sh --auto -lang en
```

`--auto` uses default answers and confirms the install plan automatically. The domain is read from `DOMAIN`, saved config, or the server FQDN hostname. If no domain can be detected and the installer is running in a normal terminal, it asks only for `Proxy domain` and then continues by itself. In non-interactive runs, pass `DOMAIN=proxy.example.com`.

Download only the required files with `wget`:

```bash
apt update
apt install -y ca-certificates wget
mkdir -p /root/telemt2/telemt/docker-telemt
cd /root/telemt2/telemt/docker-telemt
wget -O Dockerfile https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/Dockerfile
wget -O build.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/build.sh
wget -O install_docker-telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/install_docker-telemt.sh
wget -O telemt-users.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/telemt-users.sh
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh
```

Download only the required files with `curl`:

```bash
apt update
apt install -y ca-certificates curl
mkdir -p /root/telemt2/telemt/docker-telemt
cd /root/telemt2/telemt/docker-telemt
curl -fsSLo Dockerfile https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/Dockerfile
curl -fsSLo build.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/build.sh
curl -fsSLo install_docker-telemt.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/install_docker-telemt.sh
curl -fsSLo telemt-users.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/docker-telemt/telemt-users.sh
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh
```

If the files are already on the server:

```bash
chmod +x ./build.sh
./build.sh
```

For production, use an exact release tag:

```bash
TELEMT_VERSION=<version> ./build.sh
```

Build the debug image:

```bash
TARGET=debug ./build.sh
```

Check version:

```bash
docker run --rm --entrypoint /app/telemt telemt-local:3.4.23 --version
```

### Server Install

`install_docker-telemt.sh` installs the full server layer around the Docker image:

- `TLS-Fronting + TCP-Splitting` architecture for your own domain only;
- nginx HTTP -> HTTPS redirect;
- nginx SNI stream on public `443/tcp`;
- HTTPS mask site on `127.0.0.1:8443`;
- Telemt in Docker on `127.0.0.1:1443`;
- Telemt API only on `127.0.0.1:9091`;
- Telemt metrics only on `127.0.0.1:9090`;
- Let's Encrypt certificate and `certbot.timer`;
- mask page choice: playful placeholder or empty HTML;
- Docker hardening and healthcheck with a dedicated prompt;
- runtime logs disabled by default;
- optional `ad_tag`, `middle_proxy`, and high-load tuning;
- Telemt `3.4.23` compatibility settings: `/run/telemt` runtime cache, `client_mss`, `client_mss_bulk`, `user_enabled`, upstream IPv4 policy, Synlimit V2 fields, and explicit disabled `synlimit`.

In this architecture, a normal scanner or browser without the MTProxy key receives the HTTPS mask site with a real certificate for your domain. Telemt does not replace TLS and does not perform MITM: valid MTProxy clients stay inside Telemt, while other TLS connections are relayed to the mask site as a TCP stream.

The mask site is intentionally configured as regular HTTPS without a separate `http2` directive. This stays compatible with nginx 1.24 and older Debian/Ubuntu packages where `http2 on;` fails with `unknown directive "http2"`. HTTP/2 is not needed for the camouflage site.

Before running, use a clean Debian 13.x or Ubuntu 24.x-26.x server, create a DNS A record pointing to the server IPv4, and keep `80/tcp` and `443/tcp` free. Other OS versions are stopped before package installation.

Ubuntu uses Docker Telemt only. Host nginx owns public ports 80/443. The
installer checks the OpenSSL versions compiled into both the nginx command and
the binary actually started by `nginx.service`. If stream preread support is
missing or the stack is older than the OpenSSL `3.5.2` feature floor / `3.5.7`
security target, it builds isolated nginx `1.31.2` with OpenSSL `3.5.7`.
System shared libraries are not replaced and Telemt remains in Docker. The same
check runs during `--update` and `--fix-nginx`; Debian 13 keeps its distro nginx.

If `80/tcp` or `443/tcp` is already used by a Docker container, the installer shows the container name, image, and published ports, for example `whatsapp-proxy facebook/whatsapp_proxy:20260607`, and asks whether to remove those containers before continuing Telemt installation. If you answer `no`, installation stops without removing anything.

### Ready Commands

Fresh install on a clean server:

```bash
apt update
apt install -y git ca-certificates
if [ -d /root/telemt2/.git ]; then
  cd /root/telemt2
  git pull --ff-only
else
  git clone --depth 1 --filter=blob:none --sparse https://github.com/Telemtinstall/telemt2.git /root/telemt2
  cd /root/telemt2
  git sparse-checkout set telemt/docker-telemt
fi
cd /root/telemt2/telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh
```

Update an existing Telemt installation without resetting settings:

```bash
cd /root/telemt2
git pull --ff-only
cd telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh --update -lang ru
```

Update Docker Telemt `3.4.18` to the checked compatible `3.4.23` release from the `telemt2` repository:

```bash
cd /root/telemt2
git pull --ff-only
cd telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh

# first print the update plan without changing anything
printf 'n\n' | ./install_docker-telemt.sh --update -lang ru

# if the plan shows 3.4.18 -> 3.4.23, run the update
./install_docker-telemt.sh --update -lang ru
```

Post-update checks:

```bash
docker exec telemt /app/telemt --version
docker ps --filter name=telemt
curl -fsS http://127.0.0.1:9091/v1/users
nginx -t
cat /root/telemt-proxy-links.txt
```

Repair an existing server: nginx/Docker/Telemt doctor:

```bash
cd /root/telemt2
git pull --ff-only
cd telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
./install_docker-telemt.sh --fix-nginx -lang ru
```

Full reinstall on an already installed server:

```bash
cd /root/telemt2
git pull --ff-only
cd telemt/docker-telemt
chmod +x ./build.sh ./install_docker-telemt.sh ./telemt-users.sh
RESET_INSTALL_STATE=1 ./install_docker-telemt.sh -lang ru
```

This mode removes the old saved config, secret, `telemt.toml`, compose, container, and links. It does not touch unrelated nginx sites.

During the certificate step, the installer first checks the HTTP-01 challenge without involving Let's Encrypt: it creates a temporary file under `/var/www/<domain>/.well-known/acme-challenge/`, checks it locally through nginx, and then checks it through the public IPv4 with `curl -4 --resolve <domain>:80:<server_ipv4>`. If the file is not reachable, the script stops before `certbot` and writes diagnostics to `/root/telemt-acme-http01-check.txt`: DNS A/AAAA, listening ports, `nginx -t`, site config, and firewall state. This usually points directly to a closed `80/tcp`, a wrong A record, an unwanted AAAA record, or a CDN/proxy that does not pass `/.well-known/acme-challenge/`.

Normal run:

```bash
chmod +x ./install_docker-telemt.sh
./install_docker-telemt.sh
```

Russian installer UI:

```bash
./install_docker-telemt.sh -lang ru
```

Emergency nginx repair after `unknown directive "http2"`:

```bash
./install_docker-telemt.sh --fix-nginx -lang ru
```

This mode backs up changed nginx files, removes incompatible `http2 on;` and `listen ... http2;` syntax, and when duplicate top-level `stream {}` blocks are present it keeps the primary Telemt stream config and disables extra stream files. The `443/tcp` stream config uses an SNI router: the configured proxy domain goes to Telemt on `127.0.0.1:1443`, while unknown or non-SNI traffic goes directly to the local HTTPS mask site on `127.0.0.1:8443`. Then it runs `nginx -t` and reloads nginx. After that it checks Docker/Compose, installs Docker Compose v2 when needed, rebuilds a missing local `telemt-local:*` image through `build.sh` when needed, and recreates only the `telemt` container from the existing compose file. System Python is not upgraded. This works around Docker Compose v1 `ContainerConfig`/removed-image failures after broken updates. Then it verifies `telemt.toml`, the local API, `certbot.timer`, and listening ports. Telemt secrets, users, and certificates are preserved. `telemt.toml` is not fully regenerated; doctor may only remove the incompatible optional `censorship.exclusive_mask` block when an older Telemt version cannot start with it. Normal install and `--update` also run a real GET check against the mask site through public `443/tcp` and print `Mask site OK` when the page is reachable.

Update an already installed server without rewriting current settings:

```bash
./install_docker-telemt.sh --update -lang ru
```

If the installer finds an existing installation under `/opt/telemt-docker`, normal mode stops. This protects live servers from accidentally running install mode again. Use `--update` for updates or `--fix-nginx` for repair. A clean reinstall requires explicit confirmation through `RESET_INSTALL_STATE=1`.

`RESET_INSTALL_STATE=1` means a real fresh install: old saved input, the old Telemt secret, old `telemt.toml`, compose, container, and proxy links are removed before prompts. The installer asks for the domain, email, user, and other settings again. Old Telemt nginx files are removed only when they look installer-managed; unrelated nginx sites are not touched. The new mask site is written to a dedicated nginx file named `telemt-mask-<domain>.conf`, so a vhost named after the domain is not overwritten.

The `--update` mode first analyzes the existing installation: it reads the domain and user from `telemt.toml`, the image from compose, tries to detect the current Telemt version from the container/image/tag, and prints missing compatible config keys. After confirmation it backs up `/opt/telemt-docker/telemt.toml`, `docker-compose.yml`, secrets, links, and nginx configs, switches compose to the exact checked compatible tag (`telemt-local:3.4.23` by default), rebuilds/pulls that exact release tag, extends the current `telemt.toml`/compose only with missing safe keys, recreates the container, and runs API/active-probing validation again. Manual values are not overwritten; `TELEMT_VERSION=latest` in `--update` is ignored and replaced with the pinned compatible version.

Domains may be entered as regular ASCII domains, punycode (`xn--...`), or Cyrillic/IDN names. The installer converts IDN names to punycode/ASCII before DNS checks, Let's Encrypt, nginx, and MTProxy link generation. Invalid punycode is rejected before system changes.

On a clean VPS you usually log in as `root`, so `sudo` is not needed and may not be installed. If you are not root, use:

```bash
if [ "$(id -u)" -eq 0 ]; then
  ./install_docker-telemt.sh -lang ru
elif command -v sudo >/dev/null 2>&1; then
  sudo ./install_docker-telemt.sh -lang ru
else
  su -c "./install_docker-telemt.sh -lang ru"
fi
```

If `telemt-local:<tag>` is not built yet, the installer runs `build.sh` from the same directory automatically. Running `build.sh` before the installer is no longer required.

If the image is in a registry:

```bash
TELEMT_IMAGE=ghcr.io/Telemtinstall/telemt:3.4.23 ./install_docker-telemt.sh
```

### Installer Prompts

For a normal install, pressing `Enter` on every prompt except the domain is usually correct. Defaults are tuned for a typical VPS running nginx fronting plus Docker Telemt.

| Prompt | Meaning | Default | Recommended answer |
| --- | --- | --- | --- |
| `Proxy domain` | Domain used in MTProxy links, TLS SNI, nginx, and Let's Encrypt. Its DNS A record must point to the server IPv4. | No default, except saved config or hostname in `--auto`. | Enter the real proxy domain, for example `proxy.example.com`. |
| `Let's Encrypt email` | Email for certificate issuance and renewal notices. | `admin@<domain>`. | Keep the default or enter your real admin email. |
| `Telemt Docker image` | Docker image used by compose. | `telemt-local:3.4.23`. | Keep the default. For a registry image, use an exact tag such as `ghcr.io/Telemtinstall/telemt:3.4.23`. |
| `Mask site page` | What a regular browser sees without the MTProxy secret. `fancy` serves a simple placeholder, `empty` serves blank HTML with `200 OK`. | `fancy`. | Usually `fancy`; use `empty` when you want a blank camouflage page. |
| `Telemt user name` | First user/link name in `[access.users]`. The secret is generated automatically. | `default`. | Keep `default` for one owner, or use names such as `user1`/`client1` for tracking. |
| `How many proxy links/users to create now` | Number of separate users and proxy links created during install. | `1`. | Usually `1`; use more if different people need separate links immediately. |
| `Telemt user name #2/#3/...` | Names for extra users when more than one link is requested. | `user2`, `user3`, ... | Use meaningful client names or keep the proposed names. |
| `Max Telemt connections` | Per-user TCP connection limit in `[access.user_max_tcp_conns]`. | `5000`. | Keep `5000` for a normal or busy VPS; lower it only to restrict a user. |
| `Telemt listener TCP MSS` | `client_mss` setting for TCP stability against fragmentation/DPI issues. Values: `off`, `tspu`, `2in8`, `extreme-low`, or `88..4096`. | `tspu`. | Keep `tspu`. If network issues appear, test `2in8` or `extreme-low`; use `off` only when you know it is unnecessary. |
| `Telemt listener SYN limiter` | Built-in Telemt SYN limiter. Values: `false`, `iptables`, `nftables`. | `false`. | Keep `false`. In this layout public `443/tcp` is accepted by nginx, and the limiter needs extra container network privileges. |
| `MTProxy ad_tag` | 32-hex Telegram MTProxy ad tag. Needed only for an official promoted proxy/ad tag. | Empty. | Usually leave empty. If you have an `ad_tag`, paste the 32 hex characters. |
| `Use Telegram middle proxy` | Enables `use_middle_proxy`. If `ad_tag` is set, the installer suggests `yes`; otherwise `no`. | `no` without `ad_tag`, `yes` with `ad_tag`. | Usually `no`; with `ad_tag`, usually keep `yes`. |
| `Enable nginx/Docker access logs` | Enables runtime/access logs. They are disabled by default for privacy and lower disk load. | `no`. | Usually `no`; temporarily use `yes` for diagnostics. |
| `Enable Docker hardening and healthcheck` | Adds `read_only`, `cap_drop: ALL`, `no-new-privileges`, `/tmp` tmpfs, and Docker healthcheck. `/run/telemt` tmpfs is always enabled. | `yes`. | Keep `yes`. Disable only while debugging an unusual container issue. |
| `Enable high-load tuning for many clients` | Writes sysctl tuning for backlog, keepalive, file-max, and BBR when available. | `yes`. | Keep `yes` on a VPS used as a proxy. |
| `Type y or yes to continue` | Final plan confirmation before system changes. | No default in manual mode. | Review domain, IP, image, and users, then type `y`. |

In `--auto` mode, the installer uses these defaults and asks only for the domain when it cannot detect one from `DOMAIN`, saved config, or hostname.

At the end of the install, the script runs an active probing check against your own domain:

```bash
openssl s_client -4 -connect <server_ipv4>:443 -servername <domain>
openssl s_client -4 -connect <domain>:443 -servername <domain>
curl -4 -I --resolve <domain>:443:<server_ipv4> https://<domain>/
```

The result is saved to `/root/telemt-active-probing-check.txt`. If a normal HTTPS request through the server IP does not return a valid response, the installer stops with an error because the masking layer is not working correctly. On failure, the script prints diagnostics automatically: DNS A/AAAA, listening ports, `nginx -t`, stream config presence, `docker ps`, recent Telemt logs, and firewall state. If the output contains `BIO_connect:connect error`, TCP `443` is usually blocked by the server/provider firewall or nginx stream is not listening on the public `443`.

If a manually upgraded OpenSSL fails with `unable to get local issuer certificate` while the site and external SNI/TLS checks work, use the separate compatibility wrapper. It compares OpenSSL's default trust path with the operating system CA bundle and, with an explicit `--run-update`, starts the regular updater with `SSL_CERT_FILE`/`CURL_CA_BUNDLE` set. The wrapper itself does not modify the certificate, nginx, Telemt configuration, or secrets; after validation, the regular `--update` behavior applies. The wrapper neither installs nor recommends a third-party OpenSSL/nginx build; Debian 13 servers should use the maintained operating-system packages:

```bash
cd /root/telemt2/telemt/docker-telemt
chmod +x ./update-with-system-ca.sh
./update-with-system-ca.sh -lang en
# Only after reviewing the reported current/target versions:
./update-with-system-ca.sh --run-update -lang en
```

The wrapper does not update anything by default. With `--run-update`, it also refuses to continue when the running Telemt version is newer than the official updater's compatible target, preventing a hidden downgrade. If verification also fails with the explicit system CA bundle, the certificate or its chain needs a real repair. The complete result is written to `/root/telemt-openssl-ca-check.txt`.

The playful placeholder is used by default. If `empty` is selected, nginx serves an empty `index.html` with `200 OK` and no visible text. Access logs are disabled by default. Docker hardening is enabled by default, but can be disabled. High-load tuning is enabled by default, but can be disabled by answering `no`. The default Telemt connection limit is now `5000`.

At the end, the script generates valid TLS MTProxy links itself:

```text
https://t.me/proxy?server=<domain>&port=443&secret=<tls_secret>
tg://proxy?server=<domain>&port=443&secret=<tls_secret>
```

Links are saved to `/root/telemt-proxy-links.txt`, and the primary HTTPS link for quick copy-paste is saved to `/root/telemt-proxy-link.txt`. If several users are selected during installation, the file contains a separate pair of links for each user. The `secret` is built as `ee + 32_hex_secret + hex(domain)` so Telegram does not reject the link with an invalid key parameter. If the server public IPv4 differs from the domain, `/root/telemt-proxy-link-ip.txt` is written as well: it connects to the IP while keeping the same domain TLS SNI inside the `secret`.

After installation, users/links can be managed with:

```bash
telemt-users list
telemt-users status
telemt-users add user2
telemt-users add friend 5000
telemt-users disable friend
telemt-users enable friend
telemt-users links
telemt-users del friend
```

`telemt-users` backs up `telemt.toml`, adds/removes the user in `[access.users]`, manages temporary disabling through `[access.user_enabled]`, updates the shown link list, recreates the Telemt container, and rewrites `/root/telemt-proxy-links.txt` plus `/root/telemt-proxy-link-ip.txt` when a public IPv4 is available. Disabled users keep their existing secret in the config and are marked as disabled.

When Docker hardening is enabled, compose adds:

```text
read_only root filesystem
cap_drop: ALL
no-new-privileges
tmpfs for /tmp
tmpfs for /run/telemt
Docker healthcheck
```

Compose does not set CPU/RAM/PID limits. This is intentional, so Telemt does not hit artificial limits when many clients load media.

When Docker hardening is disabled, the container runs in a simpler mode without `read_only`, `cap_drop`, `no-new-privileges`, `/tmp` tmpfs, and compose healthcheck. The runtime tmpfs `/run/telemt` stays enabled because Telemt `3.4.23` writes cache/state there.

For Telemt `3.4.12+`, new installs and `--update` also add an explicit section:

```toml
[censorship.exclusive_mask]
"<domain>" = "127.0.0.1:8443"
```

This pins fallback traffic with your domain SNI to the local HTTPS mask site. Other fallback traffic keeps using normal `mask_host`/`mask_port`.

For Telemt `3.4.23`, the config also gets runtime cache under `/run/telemt`, a `beobachten` window for JA3/JA4 diagnostics, `client_mss = "tspu"` and `client_mss_bulk = "1400"` unless MSS is disabled, `[access.user_enabled]`, per-upstream `ipv4/ipv6`, `mask_dynamic = false` to preserve the static masking layout, and `synlimit = false`. SYN limiter is not enabled automatically in the Docker/nginx-stream layout because it needs `CAP_NET_ADMIN`, while public `443/tcp` is accepted by nginx. If the operator explicitly sets `TELEMT_SYNLIMIT=nftables|iptables`, the installer writes the newer Synlimit V2 `synlimit_ios_*` and `synlimit_hashlimit_*` fields.

### Publishing

Publishing is disabled by default. To push an image to a registry, set `PUSH=1` explicitly:

```bash
IMAGE=ghcr.io/Telemtinstall/telemt PUSH=1 ./build.sh
```

Log in first:

```bash
docker login ghcr.io
```

### Variables

```text
TELEMT_REPOSITORY  GitHub repo with release assets. Default: telemt/telemt
TELEMT_VERSION     Exact release tag. Default: 3.4.23
TELEMT_LATEST_COMPATIBLE_VERSION
                  Checked target version for --update. Default: 3.4.23
IMAGE              Image name. Default: telemt-local
IMAGE_TAG          Docker tag. Default: TELEMT_VERSION
AUTO_BUILD_IMAGE   yes builds the image automatically when missing. Default: yes
MASK_SITE_MODE     fancy or empty. Default: fancy
TELEMT_CLIENT_MSS  off, tspu, 2in8, extreme-low, or 88..4096. Default: tspu
TELEMT_CLIENT_MSS_BULK
                  off, tspu, 2in8, extreme-low, or 88..4096. Default: 1400
TELEMT_SYNLIMIT    false, iptables, or nftables. Default: false
TARGET             prod or debug. Default: prod
PLATFORM           linux/amd64 or linux/arm64, optional
NO_CACHE           1 disables build cache
PUSH               1 publishes the image, default is 0
ALLOW_TELEMT_LATEST
                  1 allows TELEMT_VERSION=latest intentionally; latest is blocked by default
```

### Compose Example

`compose.example.yml` shows a hardened runtime:

- `network_mode: host`;
- config mounted read-only;
- Docker logs disabled;
- read-only root filesystem;
- runtime cache uses tmpfs `/run/telemt`;
- `cap_drop: ALL`;
- `no-new-privileges`;
- `ulimits.nofile` raised to `65535/65535`.

## Source

Based on the official Telemt Docker approach:

- https://github.com/telemt/telemt
- https://github.com/telemt/telemt/blob/main/Dockerfile
