# Utilities

> RU: Эти скрипты являются вспомогательными Bash-утилитами из этого репозитория, а не официальными установщиками upstream-проектов. Полное уведомление и список источников ПО: [README.md](../README.md#installer-notice--уведомление-об-установщиках).
> EN: These scripts are helper Bash utilities from this repository, not official upstream installers. Full notice and software source list: [README.md](../README.md#installer-notice--уведомление-об-установщиках).

## certbot_helper.sh

### RU

`certbot_helper.sh` выпускает или обновляет Let's Encrypt сертификат через `certbot`.

Он принимает основные параметры в стиле `certbot`: `certonly`, `-d/--domain`, `-m/--email`, `--nginx`, `--apache`, `--standalone`, `--webroot`, `-w/--webroot-path`, `--redirect`, `--no-redirect`, `-n/--non-interactive`. Неизвестные параметры передаются дальше в `certbot`.

```bash
chmod +x ./certbot_helper.sh
sudo ./certbot_helper.sh -d example.com -d www.example.com
```

Если указан `--non-interactive` или `--no-prompt`, скрипт больше ничего не спрашивает. В этом режиме обязательный домен надо передать через `-d`; email по умолчанию будет `admin@<первый-домен>`, метод выпуска выбирается автоматически по найденному веб-серверу: nginx, apache/httpd или standalone.

Если запустить без параметров, скрипт спросит:

1. `Domain 1` - первый домен.
2. `Domain 2, Enter to finish` - дополнительные домены; пустой Enter завершает список.
3. `Let's Encrypt email` - email аккаунта Let's Encrypt, по умолчанию `admin@<первый-домен>`.
4. `ACME method` - `nginx`, `apache`, `standalone` или `webroot`; по умолчанию предлагается найденный веб-сервер.
5. `Webroot path` - только для `webroot`, по умолчанию `/var/www/html`.
6. `Use Let's Encrypt staging/test certificate` - тестовый сертификат без расхода production rate limit, по умолчанию `no`.
7. `Configure HTTP to HTTPS redirect after certificate issue` - поставить редирект после выпуска сертификата, по умолчанию `yes`.
8. `Enable certificate auto-renewal` - включить `certbot.timer`, по умолчанию `yes`.
9. `Reload systemd service after renewal` - какой сервис перезагрузить после renew, по умолчанию найденный веб-сервер, пустое значение отключает hook.
10. Если порт `80/tcp` занят в режиме `standalone`, скрипт спросит сервис, который можно временно остановить.

Перед выпуском сертификата скрипт автоматически проверяет DNS `A`-записи доменов и сравнивает их с публичным IPv4 сервера. Если запись отсутствует или указывает не на этот сервер, установка останавливается, если вы не подтвердите продолжение вручную или не передадите `--skip-dns-check`.

Если выбрать `auto-renew no`, скрипт не включает `certbot.timer` и не ставит renewal hook. Уже существующий `certbot.timer` он не отключает, чтобы не сломать другие сертификаты на сервере.

После успешного выпуска сертификата скрипт пытается настроить HTTP -> HTTPS redirect для найденного nginx или apache/httpd. Для неподдержанного веб-сервера, например caddy, он явно напишет, что redirect не настроен автоматически.

Примеры:

```bash
sudo ./certbot_helper.sh certonly -d example.com -d www.example.com
```

```bash
sudo ./certbot_helper.sh -d example.com --nginx --redirect -m admin@example.com
```

```bash
sudo ./certbot_helper.sh -d example.com --webroot -w /var/www/html --non-interactive
```

```bash
sudo ./certbot_helper.sh -d example.com --standalone --stop-service nginx
```

```bash
sudo ./certbot_helper.sh -d example.com --auto-renew no --no-redirect
```

Скачать один файл на сервер:

```bash
wget -O /root/certbot_helper.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/utils/certbot_helper.sh
chmod +x /root/certbot_helper.sh
sudo /root/certbot_helper.sh -d example.com
```

### EN

`certbot_helper.sh` issues or updates a Let's Encrypt certificate through `certbot`.

It accepts the main certbot-style options: `certonly`, `-d/--domain`, `-m/--email`, `--nginx`, `--apache`, `--standalone`, `--webroot`, `-w/--webroot-path`, `--redirect`, `--no-redirect`, `-n/--non-interactive`. Unknown options are passed through to `certbot`.

```bash
chmod +x ./certbot_helper.sh
sudo ./certbot_helper.sh -d example.com -d www.example.com
```

With `--non-interactive` or `--no-prompt`, the script asks nothing. In this mode the domain must be provided through `-d`; the default email is `admin@<first-domain>`, and the ACME method is selected from the detected web server: nginx, apache/httpd, or standalone.

When started without parameters, it asks:

1. `Domain 1` - first domain.
2. `Domain 2, Enter to finish` - extra domains; empty Enter finishes the list.
3. `Let's Encrypt email` - Let's Encrypt account email, default `admin@<first-domain>`.
4. `ACME method` - `nginx`, `apache`, `standalone`, or `webroot`; the default is based on the detected web server.
5. `Webroot path` - only for `webroot`, default `/var/www/html`.
6. `Use Let's Encrypt staging/test certificate` - test certificate without consuming production rate limits, default `no`.
7. `Configure HTTP to HTTPS redirect after certificate issue` - configure redirect after issuing the certificate, default `yes`.
8. `Enable certificate auto-renewal` - enable `certbot.timer`, default `yes`.
9. `Reload systemd service after renewal` - service to reload after renewal, default detected web server; empty disables the hook.
10. If `80/tcp` is busy in `standalone` mode, the script asks which service can be stopped temporarily.

Before issuing the certificate, the script checks domain `A` records and compares them with the server public IPv4. If a record is missing or points elsewhere, the script stops unless you confirm manually or pass `--skip-dns-check`.

If `auto-renew no` is selected, the script does not enable `certbot.timer` and does not install a renewal hook. It does not disable an already existing `certbot.timer`, because that timer may be used by other certificates on the server.

After successfully issuing the certificate, the script tries to configure HTTP -> HTTPS redirect for detected nginx or apache/httpd. For unsupported web servers such as caddy, it clearly reports that redirect was not configured automatically.

Examples:

```bash
sudo ./certbot_helper.sh certonly -d example.com -d www.example.com
```

```bash
sudo ./certbot_helper.sh -d example.com --nginx --redirect -m admin@example.com
```

```bash
sudo ./certbot_helper.sh -d example.com --webroot -w /var/www/html --non-interactive
```

```bash
sudo ./certbot_helper.sh -d example.com --standalone --stop-service nginx
```

```bash
sudo ./certbot_helper.sh -d example.com --auto-renew no --no-redirect
```

Download one file to a server:

```bash
wget -O /root/certbot_helper.sh https://raw.githubusercontent.com/Telemtinstall/telemt2/main/utils/certbot_helper.sh
chmod +x /root/certbot_helper.sh
sudo /root/certbot_helper.sh -d example.com
```
