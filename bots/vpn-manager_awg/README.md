# VPN Manager AWG

`VPN Manager AWG` - минимальный Telegram-бот для управления одним локальным AmneziaWG/AWG сервером через `awgctl`.

Идея проекта простая: поставить бота на тот же сервер, где уже установлен и настроен AmneziaWG/AWG, указать путь до `awgctl`, токен Telegram-бота и Telegram ID админов. После этого админ управляет VPN-клиентами из Telegram: создает пользователей, получает QR, смотрит трафик и удаляет доступ.

В этой версии специально нет выбора серверов, `servers.json`, SSH-транспорта и VLESS. Это GitHub-ready вариант только для одного локального AWG/AmneziaWG сервера.

## Как Это Работает

Поток такой:

```text
Telegram admin
  -> Telegram Bot API polling
  -> bot.py
  -> awgctl -j <command>
  -> локальный AmneziaWG/AWG сервер
```

Бот сам забирает апдейты через polling, webhook не нужен.

Основные сценарии:

- `/create` - бот спрашивает имя клиента или создает имя автоматически.
- `awgctl -j add` - создает клиента и возвращает конфиг/QR в JSON.
- В профиле клиента бот показывает отдельные кнопки `QR для iPhone` и `QR для Android`.
- `/list` - бот показывает список клиентов и их online/offline статус по handshake.
- `/traffic` - бот показывает общий трафик.
- `Трафик клиента` - бот показывает RX/TX конкретного клиента.
- `Удалить` - бот удаляет клиента через `awgctl -j delete` после подтверждения.

## Что Нужен Уметь awgctl

Бот ожидает, что `awgctl` поддерживает JSON-режим:

```bash
awgctl -j list
awgctl -j add [name]
awgctl -j show <name|number>
awgctl -j qr <name|number>
awgctl -j traffic
awgctl -j delete <name|number>
```

Для QR нужны поля:

- `vpn_qr_png_base64_items[0]` - Android / AmneziaVPN native QR.
- `qr_png_base64` - iPhone / `.conf` QR для AmneziaWG или ручного импорта.

Это два разных QR для разных приложений, а не части одного QR. Подпись `QR 1/2` не используется. Если `vpn_qr_png_base64_items` содержит больше одного элемента, бот показывает ошибку и не отправляет серию QR, потому что приложение Amnezia не импортирует несколько QR подряд.

## .env

Скопируйте пример:

```bash
cp .env.example .env
nano .env
```

Минимальный рабочий `.env`:

```env
BOT_TOKEN=123456:telegram-bot-token
ADMIN_BOT=123456789
AWGCTL=/usr/local/sbin/awgctl
```

Полный пример:

```env
BOT_TOKEN=123456:telegram-bot-token
ADMIN_BOT=123456789,987654321
AWGCTL=/usr/local/sbin/awgctl

BOT_TITLE=Личный VPN-бот
PRIVATE_ONLY=1
ONLINE_WINDOW_SECONDS=180
POLL_TIMEOUT=45
REQUEST_TIMEOUT=75
MAX_MESSAGE=3900
LOG_LEVEL=INFO
```

Пояснение:

| Переменная | Обязательно | Описание |
| --- | --- | --- |
| `BOT_TOKEN` | да | Токен Telegram-бота от BotFather. |
| `ADMIN_BOT` | да | Telegram user ID админов, которым разрешен доступ. Несколько ID указываются через запятую. |
| `ADMIN_IDS` | нет | Алиас для `ADMIN_BOT`, тоже поддерживается ботом. |
| `AWGCTL` | да | Абсолютный путь до утилиты `awgctl`, например `/usr/local/sbin/awgctl`. |
| `BOT_TITLE` | нет | Название, которое показывается в главном меню. |
| `PRIVATE_ONLY` | нет | `1` - отвечать только в личном чате. `0` - разрешить работу в группах. По умолчанию лучше оставить `1`. |
| `ONLINE_WINDOW_SECONDS` | нет | Сколько секунд считать клиента онлайн после последнего handshake. По умолчанию `180`. |
| `POLL_TIMEOUT` | нет | Long polling timeout для `getUpdates`. Обычно `45` нормально. |
| `REQUEST_TIMEOUT` | нет | Таймаут HTTP-запросов к Telegram API. |
| `MAX_MESSAGE` | нет | Максимальная длина одного Telegram-сообщения перед разбиением на части. |
| `LOG_LEVEL` | нет | Уровень логов: `INFO`, `WARNING`, `ERROR`, `DEBUG`. |

Как узнать свой Telegram ID: можно написать любому боту вроде `@userinfobot` или временно посмотреть `from.id` в логах собственного бота.

## Установка

Автоматическая установка на чистом сервере:

```bash
apt update
apt install -y curl ca-certificates
curl -fsSL https://raw.githubusercontent.com/Telemtinstall/telemt2/main/bots/vpn-manager_awg/install_awg_bot.sh -o /root/install_awg_bot.sh
bash /root/install_awg_bot.sh
```

Скрипт спросит Telegram token и Telegram admin ID. Если AmneziaWG/AWG еще не установлен, он предложит поставить наш сервер из `telemt2/vpn/amneziawg`, дождется завершения установщика и продолжит настройку бота.

Ручная установка из уже скачанного репозитория:

```bash
mkdir -p /root/vpnbot
cd /root/vpnbot
cp .env.example .env
nano .env
```

Пробный запуск:

```bash
python3 bot.py
```

Установка systemd-сервиса:

```bash
cp vpnbot.service /etc/systemd/system/vpnbot.service
systemctl daemon-reload
systemctl enable --now vpnbot.service
systemctl status vpnbot.service --no-pager -l
```

## Команды

```text
/start или /menu       главное меню
/create                создать клиента
/list                  список клиентов
/online                кто онлайн
/traffic               общий трафик
/cancel                отмена ввода имени
```

## Функционал

- Создание клиента с заданным именем.
- Создание клиента с автоматическим именем.
- Список клиентов.
- Профиль клиента.
- Отдельный QR для iPhone.
- Отдельный QR для Android.
- Отправка `.conf` файла.
- Текст `.conf` для роутера.
- Трафик конкретного клиента.
- Общий трафик всех клиентов.
- Онлайн по свежему handshake.
- Удаление клиента с подтверждением.

## Безопасность

- Не коммитьте `.env`; он добавлен в `.gitignore`.
- Бот отвечает только пользователям из `ADMIN_BOT` или `ADMIN_IDS`.
- По умолчанию `PRIVATE_ONLY=1`, чтобы бот не отправлял VPN-ключи в групповые чаты.
- QR и `.conf` содержат приватные ключи клиента.
- Ставьте бота на доверенный сервер: он запускает локальный `awgctl`.

## Структура

```text
bot.py                  точка входа и polling
vpnbot.service          systemd-сервис как на рабочем сервере /root/vpnbot
restart_bot.sh          быстрый перезапуск vpnbot.service
app/config.py           чтение .env
app/telegram_api.py     Telegram Bot API без сторонних библиотек
app/awgctl.py           запуск awgctl -j
app/keyboards.py        inline-кнопки
app/handlers.py         маршрутизация message/callback
app/actions.py          сценарии создания, списка, QR, трафика, удаления
app/formatters.py       тексты, HTML escaping, форматирование трафика
app/auth.py             проверка ADMIN_IDS
app/state.py            временное состояние ввода имени
```
