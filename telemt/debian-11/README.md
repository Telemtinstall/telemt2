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

## English

`install_telemt_debian11.sh` is a separate Telemt installer for Debian 11 / bullseye.

Use it only when the target server is really Debian 11. For Debian 13 and Ubuntu, use the main installer:

```text
telemt/debian-13-ubuntu/install_telemt.sh
```

Debian 11 needs a separate path because of older `nftables`, `nginx`, `docker-compose`, and common setups where `ufw` is already enabled and blocks `80/tcp` or `443/tcp`.

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
