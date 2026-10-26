#!/usr/bin/env python3
"""Switch VPN endpoints, egress and reserve-IP filtering transactionally."""
from __future__ import annotations

import argparse
import datetime as dt
import fcntl
import ipaddress
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
from contextlib import contextmanager


def run(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=25)
    if result.returncode:
        raise RuntimeError(f"Команда {args[0]} завершилась с ошибкой: {result.stderr.strip()[:500]}")
    return result.stdout


def read_env(path):
    values = {}
    for line in path.read_text().splitlines():
        match = re.match(r"^([A-Z_][A-Z_0-9]*)=(.*)$", line)
        if match:
            parts = shlex.split(match[2], comments=True)
            if len(parts) == 1:
                values[match[1]] = parts[0]
    return values


def set_env(text, key, value):
    line = f"{key}={value}"
    pattern = rf"(?m)^{re.escape(key)}=.*$"
    return re.sub(pattern, lambda _: line, text) if re.search(pattern, text) else text.rstrip() + "\n" + line + "\n"


def atomic_write(path, content, original=None):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    info = original or (path.stat() if path.exists() else None)
    fd, temp = tempfile.mkstemp(prefix=".ip-switch-", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as output:
            output.write(content)
            output.flush()
            os.fsync(output.fileno())
            os.fchmod(output.fileno(), info.st_mode & 0o7777 if info else 0o600)
            if info and os.geteuid() == 0:
                os.fchown(output.fileno(), info.st_uid, info.st_gid)
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


class Manager:
    def __init__(self, root=Path("/"), runner=run, registry="/root/vpnbot/servers.json"):
        self.root, self.run = Path(root), runner
        self.registry = registry

    def path(self, value):
        return self.root / str(value).lstrip("/")

    @contextmanager
    def lock(self, exclusive=False):
        path = self.path("/run/lock/vpn-endpoint.lock")
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("a") as stream:
            os.chmod(path, 0o600)
            deadline = time.monotonic() + 90
            while True:
                try:
                    fcntl.flock(stream, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RuntimeError("Генератор VPN занят. Повторите переключение позже.")
                    time.sleep(0.1)
            yield

    def addresses(self):
        routes = json.loads(self.run(["ip", "-j", "-4", "route", "show", "default"]))
        interfaces = {item.get("dev") for item in routes}
        result = []
        for interface in json.loads(self.run(["ip", "-j", "-4", "address", "show", "scope", "global"])):
            if interface["ifname"] not in interfaces or "UP" not in interface.get("flags", []):
                continue
            for item in interface.get("addr_info", []):
                address = ipaddress.ip_address(item["local"])
                if address.version == 4 and address.is_global and not address.is_multicast:
                    result.append({"ip": str(address), "interface": interface["ifname"]})
        return sorted(result, key=lambda item: (item["interface"], int(ipaddress.ip_address(item["ip"]))))

    def targets(self):
        registry = json.loads(self.path(self.registry).read_text())
        result = []
        for server in registry:
            if server.get("transport", "local") != "local":
                continue
            command = Path(server["command"]).name
            protocol = server["protocol"]
            default = {
                "awgctl": "/etc/amnezia/amneziawg/awgctl.env",
                "awg3ctl": "/etc/amnezia/amneziawg/awg3ctl.env",
                "vlessctl": "/usr/local/etc/xray/vless.env",
            }.get(command)
            env_path = server.get("endpoint_env", default)
            if not env_path or protocol not in {"amneziawg", "vless"}:
                raise RuntimeError(f"Не настроен адаптер смены IP: {server['id']}")
            controller = self.path(server["command"])
            if "/run/lock/vpn-endpoint.lock" not in controller.read_text():
                raise RuntimeError(f"Обновите контроллер для безопасной смены IP: {server['id']}")
            env = read_env(self.path(env_path))
            key = "PUBLIC_ENDPOINT" if protocol == "amneziawg" else "CONNECT_HOST"
            current = env.get(key, env.get("PUBLIC_HOST", ""))
            if not current:
                raise RuntimeError(f"Не найден адрес: {server['id']}")
            result.append({**server, "env_path": env_path, "env": env, "key": key, "current": current})
        if not result:
            raise RuntimeError("Нет локальных VPN-протоколов для переключения.")
        return result

    def status(self):
        with self.lock():
            targets = self.targets()
            return {"ok": True, "addresses": self.addresses(), "protocols": [
                {"id": t["id"], "title": t["title"], "ip": t["current"]} for t in targets
            ]}

    def network(self, address):
        interface = next(a["interface"] for a in self.addresses() if a["ip"] == address)
        if not re.fullmatch(r"[A-Za-z0-9_.:-]+", interface):
            raise ValueError("Некорректный внешний интерфейс")
        awg, tcp = [], []
        for target in self.targets():
            env = target["env"]
            if target["protocol"] == "amneziawg":
                subnet = str(ipaddress.IPv4Network(env["AWG_SUBNET"]))
                iface = env["AWG_IFACE"]
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", iface):
                    raise ValueError("Некорректный VPN-интерфейс")
                awg.append({"subnet": subnet, "interface": iface, "port": int(env["AWG_PORT"])})
            else:
                tcp.append(int(env["HTTPS_PORT"]))
        if any(not 1 <= port <= 65535 for port in tcp + [a["port"] for a in awg]):
            raise ValueError("Некорректный VPN-порт")
        return {"ip": address, "interface": interface, "awg": awg, "tcp": tcp}

    @staticmethod
    def rules(network):
        ip, wan = network["ip"], network["interface"]
        lines = ["table inet vpnbot_ip {", "chain input { type filter hook input priority -10; policy accept;"]
        for protocol, ports in (("udp", [a["port"] for a in network["awg"]]), ("tcp", network["tcp"])):
            for port in sorted(set(ports)):
                lines += [f'iifname "{wan}" {protocol} dport {port} ip daddr != {ip} counter drop',
                          f'iifname "{wan}" meta nfproto ipv6 {protocol} dport {port} counter drop']
        lines += ["}", "chain forward { type filter hook forward priority -10; policy accept;"]
        for awg in network["awg"]:
            lines.append(f'iifname "{awg["interface"]}" meta nfproto ipv6 counter drop')
        lines += ["}", "chain output { type filter hook output priority -10; policy accept;"]
        for awg in network["awg"]:
            lines.append(f'oifname "{wan}" meta nfproto ipv6 udp sport {awg["port"]} counter drop')
        lines += ["}", "chain nat { type nat hook postrouting priority 90; policy accept;"]
        for awg in network["awg"]:
            lines.append(f'ip saddr {awg["subnet"]} oifname "{wan}" counter snat ip to {ip}')
            lines.append(f'oifname "{wan}" udp sport {awg["port"]} counter snat ip to {ip}')
        lines += ["}", "}"]
        return "\n".join(lines) + "\n"

    def nft_snapshot(self):
        tables = json.loads(self.run(["nft", "-j", "list", "tables"]))
        exists = any(t.get("table", {}).get("name") == "vpnbot_ip" and
                     t["table"].get("family") == "inet" for t in tables.get("nftables", []))
        return self.run(["nft", "-s", "list", "table", "inet", "vpnbot_ip"]) if exists else ""

    def nft_apply(self, rules):
        previous = self.nft_snapshot()
        batch = ("delete table inet vpnbot_ip\n" if previous else "") + rules
        if not batch:
            return
        with tempfile.NamedTemporaryFile(mode="w", prefix="vpnbot-nft-", delete=False) as output:
            output.write(batch)
            name = output.name
        try:
            self.run(["nft", "-c", "-f", name])
            self.run(["nft", "-f", name])
        finally:
            Path(name).unlink(missing_ok=True)

    def clear_connections(self, network):
        # Delete only VPN tuples. Exit 1 is conntrack's documented zero-match case.
        for subnet in [a["subnet"] for a in network["awg"]]:
            self.run(["sh", "-c", 'conntrack -D -s "$1" >/dev/null 2>&1; rc=$?; [ "$rc" -le 1 ]', "conntrack", subnet])
        for port in sorted({a["port"] for a in network["awg"]}):
            for item in self.addresses():
                self.run(["sh", "-c", 'conntrack -D -p udp --dport "$1" -d "$2" >/dev/null 2>&1; rc=$?; [ "$rc" -le 1 ]', "conntrack", str(port), item["ip"]])
                self.run(["sh", "-c", 'conntrack -D -p udp --sport "$1" -s "$2" >/dev/null 2>&1; rc=$?; [ "$rc" -le 1 ]', "conntrack", str(port), item["ip"]])

    def enforce(self):
        with self.lock(exclusive=True):
            state = json.loads(self.path("/etc/vpnbot/public-ip.json").read_text())
            network = self.network(state["ip"])
            self.nft_apply(self.rules(network))
            return {"ok": True, "ip": state["ip"]}

    def profile_host(self, address):
        return address

    def plan(self, address):
        address = str(ipaddress.IPv4Address(address))
        if address not in {item["ip"] for item in self.addresses()}:
            raise ValueError("Этот публичный IPv4 больше не назначен внешнему интерфейсу. Обновите список.")
        endpoint = self.profile_host(address)
        changes, titles = {}, []
        for target in self.targets():
            env = target["env"]
            titles.append(target["title"])
            path = self.path(target["env_path"])
            changes[path] = set_env(path.read_text(), target["key"], endpoint).encode()
            if target["protocol"] == "amneziawg":
                directory = self.path(env["CLIENT_OUT_DIR"])
                if not directory.is_dir():
                    raise RuntimeError(f"Не найден каталог конфигов: {directory}")
                for client in directory.glob("*.conf"):
                    text = client.read_text()
                    pattern = r"(?m)^(Endpoint\s*=\s*)(?:\[[^\]]+\]|[^:\s]+):(\d+)([ \t]*)$"
                    updated, count = re.subn(pattern, lambda m: f"{m[1]}{endpoint}:{m[2]}{m[3]}", text)
                    if count != 1:
                        raise RuntimeError(f"Некорректный Endpoint в {client.name}")
                    changes[client] = updated.encode()
            else:
                command = self.path(target["command"])
                if '${CONNECT_HOST:-$PUBLIC_HOST}' not in command.read_text():
                    raise RuntimeError("Обновите vlessctl: требуется поддержка CONNECT_HOST.")
                if 'VPN_BIND_IP' not in command.read_text():
                    raise RuntimeError("Обновите vlessctl: требуется поддержка VPN_BIND_IP.")
                changes[path] = set_env(set_env(changes[path].decode(), "VPN_BIND_IP", address), "XRAY_FORCE_IPV4", "1").encode()
                config_path = self.path(env.get("CONFIG_FILE", "/usr/local/etc/xray/config.json"))
                config = json.loads(config_path.read_text())
                for outbound in config.get("outbounds", []):
                    if outbound.get("protocol") == "freedom":
                        outbound["sendThrough"] = address
                        outbound.setdefault("settings", {})["domainStrategy"] = "UseIPv4"
                for inbound in config.get("inbounds", []):
                    if inbound.get("protocol") == "vless" and env.get("FRONTEND_MODE", "mask") != "mask":
                        inbound["listen"] = address
                changes[config_path] = (json.dumps(config, indent=2) + "\n").encode()
                if env.get("FRONTEND_MODE", "mask") == "mask":
                    host = env["PUBLIC_HOST"]
                    if not re.fullmatch(r"[A-Za-z0-9.-]+", host):
                        raise ValueError("Некорректный PUBLIC_HOST для VLESS")
                    site = self.path(f"/etc/nginx/sites-available/vless-{host}.conf")
                    text = site.read_text()
                    port = int(env["HTTPS_PORT"])
                    # Keep existing listeners so already distributed profiles keep working.
                    if not re.search(rf"(?m)^\s*listen\s+{re.escape(address)}:{port}\s", text) and not re.search(rf"(?m)^\s*listen\s+(?:0\.0\.0\.0:)?{port}\s", text):
                        pattern = rf"(?m)^(\s*)listen\s+[^;\n]*:{port}\s+ssl[^;]*;"
                        text, count = re.subn(pattern, lambda m: m[0] + f"\n{m[1]}listen {address}:{port} ssl;", text, count=1)
                        if count != 1:
                            raise RuntimeError("Не найден HTTPS listen в конфигурации VLESS.")
                    changes[site] = text.encode()
        state = self.path("/etc/vpnbot/public-ip.json")
        changes[state] = (json.dumps({"ip": address, "network": self.network(address)}, indent=2) + "\n").encode()
        unit = self.path("/etc/systemd/system/vpnbot-ip-policy.service")
        changes[unit] = ("[Unit]\nDescription=VPN active IP and reserve isolation\nWants=network-online.target\nAfter=network-online.target nftables.service\nBefore=awg-quick@awg0.service awg-quick@awg3.service xray.service nginx.service\n"
                        "[Service]\nType=oneshot\nExecStart=/usr/bin/python3 /usr/local/sbin/vpn_ip_switch.py enforce --registry " + self.registry + "\nRemainAfterExit=yes\n"
                        "[Install]\nWantedBy=multi-user.target\n").encode()
        return {p: value for p, value in changes.items() if not p.exists() or p.read_bytes() != value}, titles

    def apply(self, address, actor="cli"):
        with self.lock(exclusive=True):
            changes, titles = self.plan(address)
            network = self.network(address)
            self.run(["sh", "-c", "command -v nft >/dev/null && command -v conntrack >/dev/null"])
            if not changes:
                self.nft_apply(self.rules(network))
                return {"ok": True, "ip": address, "changed": False, "protocols": titles}
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
            backup = self.path(f"/root/vpn-endpoint-backups/{stamp}")
            backup.mkdir(parents=True, mode=0o700)
            originals = {}
            for path in changes:
                originals[path] = (path.read_bytes(), path.stat()) if path.exists() else None
                if path.exists():
                    dest = backup / path.relative_to(self.root)
                    dest.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
                    shutil.copy2(path, dest)
            runtime = self.nft_snapshot()
            active_xray = self.run(["systemctl", "show", "xray", "-p", "ActiveState", "--value"]).strip() == "active"
            enabled_policy = self.run(["systemctl", "show", "vpnbot-ip-policy", "-p", "UnitFileState", "--value"]).strip() == "enabled"
            manifest = {"runtime_before": runtime, "network": network, "xray_active": active_xray, "policy_enabled": enabled_policy, "ip": address, "actor": str(actor), "files": [str(p) for p in changes], "status": "pending"}
            manifest["snapshots"] = {
                str(path): {
                    "existed": original is not None,
                    "before": hashlib.sha256(original[0]).hexdigest() if original else None,
                    "after": hashlib.sha256(changes[path]).hexdigest(),
                    "mode": original[1].st_mode & 0o7777 if original else None,
                    "uid": original[1].st_uid if original else None,
                    "gid": original[1].st_gid if original else None,
                } for path, original in originals.items()
            }
            atomic_write(backup / "manifest.json", json.dumps(manifest).encode())
            nginx_changed = any("/nginx/" in str(p) for p in changes)
            try:
                for path, content in changes.items():
                    atomic_write(path, content)
                for target in self.targets():
                    if target["protocol"] == "vless":
                        self.run(["xray", "run", "-test", "-config", str(self.path(target["env"].get("CONFIG_FILE", "/usr/local/etc/xray/config.json")))])
                self.nft_apply(self.rules(network))
                self.clear_connections(network)
                if active_xray:
                    self.run(["systemctl", "restart", "xray"])
                self.run(["systemctl", "daemon-reload"])
                self.run(["systemctl", "enable", "vpnbot-ip-policy"])
                if nginx_changed:
                    self.run(["nginx", "-t"])
                    self.run(["systemctl", "reload", "nginx"])
                # Re-read actual sources before acknowledging success.
                if any(t["current"] != self.profile_host(address) for t in self.targets()):
                    raise RuntimeError("Проверка адресов генераторов не пройдена.")
            except Exception as error:
                rollback_errors = []
                if not enabled_policy and self.path("/etc/systemd/system/vpnbot-ip-policy.service").exists():
                    try:
                        self.run(["systemctl", "disable", "vpnbot-ip-policy"])
                    except Exception as exc:
                        rollback_errors.append(str(exc))
                for path, original in originals.items():
                    try:
                        if original is None:
                            path.unlink(missing_ok=True)
                        else:
                            atomic_write(path, original[0], original[1])
                    except Exception as exc:
                        rollback_errors.append(str(exc))
                try:
                    self.nft_apply(runtime)
                    self.clear_connections(network)
                    if active_xray:
                        self.run(["systemctl", "restart", "xray"])
                    self.run(["systemctl", "daemon-reload"])
                    if enabled_policy:
                        self.run(["systemctl", "enable", "vpnbot-ip-policy"])
                except Exception as exc:
                    rollback_errors.append(str(exc))
                if nginx_changed:
                    try:
                        self.run(["nginx", "-t"])
                        self.run(["systemctl", "reload", "nginx"])
                    except Exception as exc:
                        rollback_errors.append(str(exc))
                manifest["status"] = "rollback_failed" if rollback_errors else "rolled_back"
                atomic_write(backup / "manifest.json", json.dumps(manifest).encode())
                if rollback_errors:
                    raise RuntimeError(f"Не удалось полностью восстановить настройки. Резервная копия: {backup}") from error
                raise RuntimeError(f"Настройки восстановлены после ошибки: {error}") from error
            manifest["runtime_after"] = self.nft_snapshot()
            manifest["status"] = "applied"
            atomic_write(backup / "manifest.json", json.dumps(manifest).encode())
            return {"ok": True, "ip": address, "changed": True, "protocols": titles, "backup": str(backup), "files": len(changes)}


    def rollback(self, backup_id):
        if not backup_id or Path(backup_id).name != backup_id or backup_id in {".", ".."}:
            raise ValueError("Укажите имя каталога резервной копии, без пути.")
        with self.lock(exclusive=True):
            backup = self.path("/root/vpn-endpoint-backups") / backup_id
            manifest_path = backup / "manifest.json"
            manifest = json.loads(manifest_path.read_text())
            if manifest.get("status") not in {"applied", "pending", "rollback_failed"}:
                raise ValueError("Эта операция уже отменена или не поддерживает откат.")
            if "runtime_after" in manifest and self.nft_snapshot() not in {manifest["runtime_before"], manifest["runtime_after"]}:
                raise RuntimeError("Правила VPN изменились после переключения; автоматический откат остановлен.")
            snapshots = manifest.get("snapshots")
            if not snapshots:
                raise ValueError("Старая резервная копия: требуется ручное восстановление.")
            # Validate every file before changing anything; never overwrite later edits.
            restore = []
            for name, info in snapshots.items():
                path = Path(name)
                relative = path.relative_to(self.root)
                if ".." in relative.parts or path.is_symlink():
                    raise ValueError("Некорректный путь в резервной копии.")
                actual = hashlib.sha256(path.read_bytes()).hexdigest() if path.exists() else None
                if actual not in {info["before"], info["after"]}:
                    raise RuntimeError(f"Файл изменился после переключения: {path}. Автоматический откат остановлен.")
                content = None
                if info["existed"]:
                    content = (backup / relative).read_bytes()
                    if hashlib.sha256(content).hexdigest() != info["before"]:
                        raise RuntimeError(f"Повреждена резервная копия: {path}")
                restore.append((path, info, content))
            try:
                if "runtime_before" in manifest and not manifest.get("policy_enabled") and self.path("/etc/systemd/system/vpnbot-ip-policy.service").exists():
                    self.run(["systemctl", "disable", "vpnbot-ip-policy"])
                for path, info, content in restore:
                    if content is None:
                        path.unlink(missing_ok=True)
                    else:
                        atomic_write(path, content)
                        os.chmod(path, info["mode"])
                        if os.geteuid() == 0:
                            os.chown(path, info["uid"], info["gid"])
                if "runtime_before" in manifest:
                    self.nft_apply(manifest["runtime_before"])
                    self.clear_connections(manifest["network"])
                    if manifest.get("xray_active"):
                        self.run(["systemctl", "restart", "xray"])
                    self.run(["systemctl", "daemon-reload"])
                    if manifest.get("policy_enabled"):
                        self.run(["systemctl", "enable", "vpnbot-ip-policy"])
                if any("/nginx/" in str(path) for path, _, _ in restore):
                    self.run(["nginx", "-t"])
                    self.run(["systemctl", "reload", "nginx"])
            except Exception:
                manifest["status"] = "rollback_failed"
                atomic_write(manifest_path, json.dumps(manifest).encode())
                raise
            manifest["status"] = "rolled_back"
            atomic_write(manifest_path, json.dumps(manifest).encode())
            return {"ok": True, "status": "rolled_back", "backup": str(backup)}


import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
from global_domain import GlobalMixin


class GlobalManager(GlobalMixin, Manager):
    pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["list", "apply", "rollback", "enforce", "domain-status", "domain-check", "domain-set"])
    parser.add_argument("ip", nargs="?")
    parser.add_argument("--address", help="Assigned IPv4 for domain-set")
    parser.add_argument("--actor", default="cli")
    parser.add_argument("--registry", default="/root/vpnbot/servers.json")
    args = parser.parse_args()
    try:
        if os.geteuid() != 0:
            raise PermissionError("Запустите скрипт от root.")
        manager = GlobalManager(registry=args.registry)
        if args.action == "domain-status":
            result = manager.domain_status()
        elif args.action == "domain-check":
            result = manager.domain_check()
        elif args.action == "domain-set":
            result = manager.domain_set(args.ip, args.address)
        elif args.action == "enforce":
            result = manager.enforce()
        elif args.action == "list":
            result = manager.status()
        elif args.action == "rollback":
            result = manager.rollback(args.ip)
        else:
            result = manager.apply(args.ip, args.actor)
        print(json.dumps(result, ensure_ascii=False))
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        raise SystemExit(1)


if __name__ == "__main__":
    main()
