# install_telemt_debian11.sh

> RU: Это не официальный установщик Telemt или Debian-пакетов. Полное уведомление и список источников ПО: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).
> EN: This is not an official Telemt or Debian package installer. Full notice and software source list: [README.md](../../README.md#installer-notice--уведомление-об-установщиках).

## Русское описание

`install_telemt_debian11.sh` - отдельный установщик Telemt для Debian 11 / bullseye.

Используйте его только если целевой сервер действительно Debian 11. Для Debian 13 и Ubuntu используйте основной установщик:

```text
telemt/debian-13-ubuntu/install_telemt.sh
```

Debian 11 требует отдельного сценария из-за старых версий `nftables`, `nginx`, `docker-compose` и частых случаев, когда `ufw` уже включён и закрывает `80/tcp` или `443/tcp`.

Telemt запускается из официального образа `ghcr.io/telemt/telemt:latest`; конфиг монтируется как `/opt/telemt-config -> /etc/telemt`, runtime-кеш вынесен в tmpfs `/run/telemt`, CPU/RAM/PID лимиты не задаются.

Скачать на сервер:

```bash
wget -O /root/install_telemt_debian11.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-11/install_telemt_debian11.sh
chmod +x /root/install_telemt_debian11.sh
/root/install_telemt_debian11.sh
```

Через `curl`:

```bash
curl -fsSL -o /root/install_telemt_debian11.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-11/install_telemt_debian11.sh
chmod +x /root/install_telemt_debian11.sh
/root/install_telemt_debian11.sh
```


### Как обновлять уже установленный Telemt

Скачайте свежий установщик и запустите update-режим. Он сохранит существующие настройки, пользователей, секреты, nginx/SSH-конфиги и сертификаты.

```bash
wget -O /root/install_telemt_debian11.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-11/install_telemt_debian11.sh
chmod +x /root/install_telemt_debian11.sh
/root/install_telemt_debian11.sh --update -lang ru
```

Если текущий Docker compose закреплён на `image@sha256:...`, update пересоздаст контейнер на том же digest. Чтобы явно перейти на другой image/tag, передайте:

```bash
TELEMT_IMAGE=<IMAGE_OR_TAG> /root/install_telemt_debian11.sh --update -lang ru
```

IDN-домены поддерживаются: если ввести кириллицу, скрипт переведёт домен в punycode; если ввести `xn--...`, скрипт проверит, что это корректный punycode.

### Что спросит скрипт

Вопросы такие же, как в основном Debian/Ubuntu-установщике: домен прокси, email Let's Encrypt, SSH-порт, отключать ли SSH-пароли, включать ли fail2ban, добавлять ли swap, лимит Telemt-подключений и финальное подтверждение `y`/`yes`.

По умолчанию: email `admin@<PROXY_DOMAIN>`, SSH-порт `22`, SSH-пароли не отключаются, fail2ban не включается, swap не добавляется, лимит Telemt `5000`.

## English

`install_telemt_debian11.sh` is a separate Telemt installer for Debian 11 / bullseye.

Use it only when the target server is really Debian 11. For Debian 13 and Ubuntu, use the main installer:

```text
telemt/debian-13-ubuntu/install_telemt.sh
```

Debian 11 needs a separate path because of older `nftables`, `nginx`, `docker-compose`, and common setups where `ufw` is already enabled and blocks `80/tcp` or `443/tcp`.

Telemt runs from the official `ghcr.io/telemt/telemt:latest` image; config is mounted as `/opt/telemt-config -> /etc/telemt`, runtime cache uses tmpfs `/run/telemt`, and no CPU/RAM/PID limits are set.

Download on the server:

```bash
wget -O /root/install_telemt_debian11.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-11/install_telemt_debian11.sh
chmod +x /root/install_telemt_debian11.sh
/root/install_telemt_debian11.sh
```

With `curl`:

```bash
curl -fsSL -o /root/install_telemt_debian11.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-11/install_telemt_debian11.sh
chmod +x /root/install_telemt_debian11.sh
/root/install_telemt_debian11.sh
```


### Updating an Existing Telemt Install

Download the fresh installer and run update mode. It preserves existing settings, users, secrets, nginx/SSH configs, and certificates.

```bash
wget -O /root/install_telemt_debian11.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/debian-11/install_telemt_debian11.sh
chmod +x /root/install_telemt_debian11.sh
/root/install_telemt_debian11.sh --update -lang en
```

If the current Docker compose file is pinned to `image@sha256:...`, update recreates the container with the same digest. To explicitly move to another image/tag, pass:

```bash
TELEMT_IMAGE=<IMAGE_OR_TAG> /root/install_telemt_debian11.sh --update -lang en
```

IDN domains are supported: Cyrillic input is converted to punycode; existing `xn--...` input is validated as real punycode.
