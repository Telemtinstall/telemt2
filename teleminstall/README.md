# Teleminstall WEB Proxy

Новая установка одной командой — установщик сам загрузит актуальную ветку
`main`, задаст вопрос о домене и выполнит всю настройку:

```bash
apt-get update && apt-get install -y curl ca-certificates && curl -fsSL 'https://raw.githubusercontent.com/Telemtinstall/telemt2/main/teleminstall/install.sh' -o /root/install.sh && bash /root/install.sh --auto
```

Если домен уже известен:

```bash
apt-get update && apt-get install -y curl ca-certificates && curl -fsSL 'https://raw.githubusercontent.com/Telemtinstall/telemt2/main/teleminstall/install.sh' -o /root/install.sh && bash /root/install.sh --auto --domain proxy.example.com
```

Повторный запуск этой команды сначала обновляет локальную копию репозитория в
`/opt/teleminstall`, а затем запускает находящийся в ней актуальный установщик.

Отдельный установщик только нового Telegram WEB proxy. Он не устанавливает
Telemt или VPN и не изменяет SSH/маршруты.

Исходные файлы опубликованы в каталоге `teleminstall` основной ветки репозитория
`Telemtinstall/telemt2`.

## Схема

```text
Internet 80/443 -> nginx -> tproxy-server 127.0.0.1:8080
                               -> public site / protected /anal/
                               -> official MTProxy 127.0.0.1:2398
```

Полностью без TLS frontend работать нельзя: WEB proxy использует HTTPS на 443.
Здесь применяется nginx, а сертификат выпускает certbot через HTTP-01/webroot.
Для официального MTProxy runner добавляет `--nat-info`, только если локальный
исходящий IPv4 отличается от внешнего; существующие VPN и маршруты не меняются.

## Требования

- чистый сервер;
- Debian 12/13 или Ubuntu 22.04–26.x;
- x86_64, systemd, root;
- DNS A домена указывает на сервер;
- публичны TCP 80 и 443.

## Локальный запуск из репозитория

```bash
chmod +x webproxy-install.sh
./webproxy-install.sh --auto
```

Будет задан только вопрос о домене. По умолчанию:

- email: `admin@DOMAIN`;
- WEB secret: генерируется;
- nginx принимает HTTP/HTTPS, certbot получает сертификат;
- `certbot.timer` автоматически проверяет продление;
- после успешного продления выполняется `nginx -t` и мягкий reload;
- создаётся красивая публичная страница;
- `/anal/` показывает только WEB proxy: сессии, потоки, трафик и ошибки;
- логин и пароль аналитики генерируются по 10 символов;
- аналитика хранится локально 7 дней в SQLite без MariaDB и внешней геобазы;
- один MTProxy worker и 4096 соединений;
- создаётся простой публичный сайт.

С доменом без вопросов:

```bash
./webproxy-install.sh --auto --domain proxy.example.com
```

Для реального публичного развёртывания лучше подготовить собственный сайт:

```bash
./webproxy-install.sh --auto --domain proxy.example.com --site-dir /root/my-site
```

В каталоге должен быть читаемый `index.html`. Уникальный настоящий сайт снижает
возможность обнаружения одинакового шаблона активным сканированием.

После установки ссылки находятся в `/root/webproxy-only-links.txt`.
Доступ к аналитике находится в `/root/webproxy-analytics-credentials.txt`.
Все важные данные дополнительно собраны в одном защищённом файле
`/root/webproxy-install-summary.txt` с правами `0600`. Установщик выводит его
содержимое в конце успешной установки. Там находятся:

- домен и адрес публичной страницы;
- все пользователи WEB proxy и обе ссылки каждого пользователя;
- URL аналитики, её 10-символьные логин и пароль;
- команды `webproxy_cli`;
- пути ко всем важным конфигурационным файлам.

После добавления или удаления пользователя `webproxy_cli` автоматически обновляет
этот итоговый файл, поэтому актуальные ссылки не теряются.

Содержимое файла выглядит так:

```text
url=https://proxy.example.com/anal/
login=10-символьный-логин
password=10-символьный-пароль
```

Обновить аналитику уже установленного WEB proxy:

```bash
./webproxy-install.sh --analytics-only
```

## Управление пользователями

Установщик добавляет `/usr/local/sbin/webproxy_cli`. Каждый пользователь получает
отдельный WEB proxy secret и отдельную ссылку. Все пользователи используют общий
локальный MTProxy backend; upstream-лимит — 32 профиля.

```bash
webproxy_cli -add user
webproxy_cli -list
webproxy_cli -del user
webproxy_cli -delete user
```

`-del` запрашивает подтверждение. `-delete` удаляет сразу. Последнего пользователя
удалить нельзя, потому что `tproxy-server` требует хотя бы один профиль. Перед
изменением создаётся резервная копия, новая конфигурация проверяется, а при ошибке
служб автоматически восстанавливается прежняя версия. Все ссылки также сохраняются
в `/root/webproxy-users.txt`.

Проверка автоматического продления:

```bash
systemctl status certbot.timer
certbot renew --dry-run
```
