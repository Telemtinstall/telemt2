# Telemt Docker: Ubuntu 24-26 and OpenSSL 3.5

Ubuntu 24.x through 26.x is supported **only in Docker mode**. Telemt runs in
the hardened Docker container; host nginx still owns public ports 80/443,
serves the HTTPS mask site, and routes Telegram SNI to the container backend.

There is no native/systemd Telemt installer in this directory. The small
`install_telemt_docker.sh` launcher validates Ubuntu first and then runs the
single canonical installer from `telemt/docker-telemt/`, so install, `--update`,
secret preservation, and user management cannot drift between two copies.

## Единый установщик

Рекомендуемый способ установки и обновления:

```bash
curl -fsSL -o /root/install.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/install.sh
chmod +x /root/install.sh
/root/install.sh -lang ru
```

Он определяет Ubuntu 24.x-26.x, выбирает только Docker-вариант и передаёт
работу каноническому установщику с проверкой реально запущенного host nginx и
OpenSSL. Если установка уже существует, обновление будет предложено по
умолчанию. Без первого меню:

```bash
/root/install.sh --update -lang ru
```

Прямые команды с `install_telemt_docker.sh` ниже остаются для ручного запуска.

## Почему Ubuntu требует отдельной проверки

Ubuntu 24.x may ship nginx with OpenSSL 3.0.x. Installing OpenSSL `3.5.2` into
`/opt/openssl-3.5` changes an `openssl version` command only; it does not change
the TLS library already compiled into the nginx process.

The Docker installer therefore checks both the nginx command and the binary
started by `nginx.service`. On Ubuntu it requires stream preread support and
OpenSSL `>=3.5.2`. The functional floor `3.5.2` is no longer the security
target: if nginx uses an older stack, the installer builds isolated nginx
`1.31.2` with security-fixed OpenSSL `3.5.7`.

This changes only host nginx:

```text
/usr/local/sbin/nginx-telemt-openssl35
/opt/telemt-nginx-openssl35/
/etc/systemd/system/nginx.service.d/90-telemt-openssl35.conf
```

System OpenSSL shared libraries are not replaced. Telemt itself remains in
Docker. Source archives are downloaded from official OpenSSL/nginx release
URLs and checked against pinned SHA-256 values.

## Новая установка

```bash
curl -fsSL -o /root/install_telemt_docker.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_docker.sh
chmod +x /root/install_telemt_docker.sh
/root/install_telemt_docker.sh -lang ru
```

The launcher accepts only Ubuntu 24.x-26.x, installs Git when needed, prepares
a sparse checkout under `/root/telemt2`, and starts the canonical Docker
installer. A clean server, a domain A record pointing to this VPS, and free
public ports `80/tcp` and `443/tcp` are required.

## Обновление

```bash
curl -fsSL -o /root/install_telemt_docker.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_docker.sh
chmod +x /root/install_telemt_docker.sh
/root/install_telemt_docker.sh --update -lang ru
```

`--update` detects the running Telemt version, targets the exact checked
release `3.4.23`, backs up the current state, preserves users/secrets/links and
certificates, upgrades the Ubuntu host nginx/OpenSSL stack when required, and
recreates only the Telemt container.

## Режим OpenSSL

Default `TELEMT_NGINX_OPENSSL_MODE=auto` uses an already compatible nginx or
builds the isolated stack. `required` has the same target but is intended for
strict automation. `off` skips the build for diagnostics and may leave the
mask site without `X25519MLKEM768` support.

## Проверка

```bash
docker exec telemt /app/telemt --version
docker ps --filter name=telemt
curl -fsS http://127.0.0.1:9091/v1/users | jq
nginx -V 2>&1 | grep -oE 'nginx/[0-9.]+|OpenSSL [0-9.]+'
systemctl show nginx -p ExecStart --no-pager
nginx -t
cat /root/telemt-active-probing-check.txt
```

## English quick start

Recommended universal entry point:

```bash
curl -fsSL -o /root/install.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/install.sh
chmod +x /root/install.sh
/root/install.sh -lang en
```

It detects Ubuntu 24.x-26.x, selects Docker only, and starts the canonical
installer with validation of the nginx service binary and its OpenSSL build.
An existing install defaults to Update; use
`/root/install.sh --update -lang en` to skip the first menu. The direct
launcher commands below remain available for manual operation.

Ubuntu uses Docker Telemt only. The launcher rejects non-Ubuntu systems and
Ubuntu releases outside 24.x-26.x. Host nginx is checked against the real
service binary and, when needed, rebuilt as nginx `1.31.2` with isolated
OpenSSL `3.5.7`; Telemt stays in Docker.

```bash
curl -fsSL -o /root/install_telemt_docker.sh \
  https://raw.githubusercontent.com/Telemtinstall/telemt2/main/telemt/ubuntu-24-26/install_telemt_docker.sh
chmod +x /root/install_telemt_docker.sh
/root/install_telemt_docker.sh -lang en
```

Update:

```bash
/root/install_telemt_docker.sh --update -lang en
```
