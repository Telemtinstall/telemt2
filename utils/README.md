# Utilities

> RU: Эти скрипты являются вспомогательными Bash-утилитами из этого репозитория, а не официальными установщиками upstream-проектов. Полное уведомление и список источников ПО: [README.md](../README.md#installer-notice--уведомление-об-установщиках).
> EN: These scripts are helper Bash utilities from this repository, not official upstream installers. Full notice and software source list: [README.md](../README.md#installer-notice--уведомление-об-установщиках).

## certbot_helper.sh

### RU

`certbot_helper.sh` выпускает или обновляет Let's Encrypt сертификат через `certbot`.

Он принимает домены так же, как `certbot`:

```bash
chmod +x ./certbot_helper.sh
sudo ./certbot_helper.sh -d example.com -d www.example.com
```

Если запустить без параметров, скрипт спросит:

1. `Domain 1` - первый домен.
2. `Domain 2, Enter to finish` - дополнительные домены; пустой Enter завершает список.
3. `Let's Encrypt email` - email аккаунта Let's Encrypt, по умолчанию `admin@<первый-домен>`.
4. `ACME challenge method` - `standalone` или `webroot`.
5. `Webroot path` - только для `webroot`, по умолчанию `/var/www/html`.
6. `Use Let's Encrypt staging/test certificate` - тестовый сертификат без расхода production rate limit, по умолчанию `no`.
7. `Enable certificate auto-renewal` - включить `certbot.timer`, по умолчанию `yes`.
8. `Reload systemd service after renewal` - какой сервис перезагрузить после renew, по умолчанию `nginx`, пустое значение отключает hook.
9. Если порт `80/tcp` занят в режиме `standalone`, скрипт спросит сервис, который можно временно остановить.

Перед выпуском сертификата скрипт автоматически проверяет DNS `A`-записи доменов и сравнивает их с публичным IPv4 сервера. Если запись отсутствует или указывает не на этот сервер, установка останавливается, если вы не подтвердите продолжение вручную или не передадите `--skip-dns-check`.

Если выбрать `auto-renew no`, скрипт не включает `certbot.timer` и не ставит renewal hook. Уже существующий `certbot.timer` он не отключает, чтобы не сломать другие сертификаты на сервере.

Примеры:

```bash
sudo ./certbot_helper.sh -d example.com -d www.example.com
```

```bash
sudo ./certbot_helper.sh -d example.com --webroot -w /var/www/html
```

```bash
sudo ./certbot_helper.sh -d example.com --standalone --stop-service nginx
```

```bash
sudo ./certbot_helper.sh -d example.com --auto-renew no
```

Скачать один файл на сервер:

```bash
wget -O /root/certbot_helper.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/utils/certbot_helper.sh
chmod +x /root/certbot_helper.sh
sudo /root/certbot_helper.sh -d example.com
```

### EN

`certbot_helper.sh` issues or updates a Let's Encrypt certificate through `certbot`.

It accepts domains in the same style as `certbot`:

```bash
chmod +x ./certbot_helper.sh
sudo ./certbot_helper.sh -d example.com -d www.example.com
```

When started without parameters, it asks:

1. `Domain 1` - first domain.
2. `Domain 2, Enter to finish` - extra domains; empty Enter finishes the list.
3. `Let's Encrypt email` - Let's Encrypt account email, default `admin@<first-domain>`.
4. `ACME challenge method` - `standalone` or `webroot`.
5. `Webroot path` - only for `webroot`, default `/var/www/html`.
6. `Use Let's Encrypt staging/test certificate` - test certificate without consuming production rate limits, default `no`.
7. `Enable certificate auto-renewal` - enable `certbot.timer`, default `yes`.
8. `Reload systemd service after renewal` - service to reload after renewal, default `nginx`; empty disables the hook.
9. If `80/tcp` is busy in `standalone` mode, the script asks which service can be stopped temporarily.

Before issuing the certificate, the script checks domain `A` records and compares them with the server public IPv4. If a record is missing or points elsewhere, the script stops unless you confirm manually or pass `--skip-dns-check`.

If `auto-renew no` is selected, the script does not enable `certbot.timer` and does not install a renewal hook. It does not disable an already existing `certbot.timer`, because that timer may be used by other certificates on the server.

Examples:

```bash
sudo ./certbot_helper.sh -d example.com -d www.example.com
```

```bash
sudo ./certbot_helper.sh -d example.com --webroot -w /var/www/html
```

```bash
sudo ./certbot_helper.sh -d example.com --standalone --stop-service nginx
```

```bash
sudo ./certbot_helper.sh -d example.com --auto-renew no
```

Download one file to a server:

```bash
wget -O /root/certbot_helper.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/utils/certbot_helper.sh
chmod +x /root/certbot_helper.sh
sudo /root/certbot_helper.sh -d example.com
```
