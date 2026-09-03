from __future__ import annotations

import json
import logging
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path


log = logging.getLogger("vpnbot.servers")
SERVER_ID_RE = re.compile(r"^[A-Za-z0-9_-]{1,20}$")
SUPPORTED_PROTOCOLS = {"amneziawg", "vless"}
SUPPORTED_TRANSPORTS = {"local", "ssh"}


@dataclass(frozen=True)
class ServerConfig:
    id: str
    title: str
    protocol: str
    transport: str
    command: str
    service: str
    host: str | None = None
    user: str = "root"


class VpnServer:
    def __init__(self, config: ServerConfig):
        self.config = config

    @property
    def id(self) -> str:
        return self.config.id

    @property
    def title(self) -> str:
        return self.config.title

    @property
    def protocol(self) -> str:
        return self.config.protocol

    @property
    def is_amneziawg(self) -> bool:
        return self.protocol == "amneziawg"

    @property
    def is_vless(self) -> bool:
        return self.protocol == "vless"

    @property
    def service(self) -> str:
        return self.config.service

    def set_enabled(self, enabled: bool) -> None:
        if self.config.transport != "local":
            raise RuntimeError("переключение удалённого VPN-сервера не поддерживается")
        action = "enable" if enabled else "disable"
        cmd = ["systemctl", action, "--now", self.service]
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            timeout=120,
        )
        if proc.returncode != 0:
            raise RuntimeError((proc.stderr or proc.stdout).strip() or f"systemctl {action} failed")

    def run(self, *args: str) -> dict:
        cmd = self._build_command("-j", *args)
        proc = subprocess.run(cmd, text=True, capture_output=True, stdin=subprocess.DEVNULL, timeout=120)
        raw = proc.stdout.strip() or proc.stderr.strip()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            log.warning("%s returned non-json for %s: rc=%s", self.id, args, proc.returncode)
            raise RuntimeError(raw or f"{self.id} exited with {proc.returncode}")

        if proc.returncode != 0 or not data.get("ok"):
            raise RuntimeError(data.get("error") or data.get("status") or f"{self.id} command error")
        return data

    def _build_command(self, *args: str) -> list[str]:
        return self._build_command_for(self.config.command, *args)

    def _build_command_for(self, command: str, *args: str) -> list[str]:
        if self.config.transport == "local":
            return [command, *args]
        if self.config.transport == "ssh":
            if not self.config.host:
                raise RuntimeError(f"server {self.id} has ssh transport without host")
            return [
                "ssh",
                "-n",
                "-o",
                "BatchMode=yes",
                "-o",
                "ConnectTimeout=8",
                f"{self.config.user}@{self.config.host}",
                command,
                *args,
            ]
        raise RuntimeError(f"unknown transport for {self.id}: {self.config.transport}")

    def add(self, name: str | None = None) -> dict:
        if name:
            return self.run("add", name)
        return self.run("add")

    def delete(self, ref: str) -> dict:
        return self.run("delete", ref)

    def list_clients(self) -> list[dict]:
        clients = self.run("list").get("clients") or []
        return [self.normalize_client(item, index + 1) for index, item in enumerate(clients)]

    def normalize_client(self, item: dict, fallback_num: int) -> dict:
        name = str(item.get("name") or item.get("num") or fallback_num)
        if self.is_amneziawg:
            ref = str(item.get("num") or name)
            details = item.get("ip") or ""
        elif self.is_vless:
            ref = name
            uuid = str(item.get("uuid") or "")
            details = uuid[:8] if uuid else ""
        else:
            ref = name
            details = ""

        normalized = dict(item)
        normalized.update(
            {
                "ref": ref,
                "name": name,
                "details": details,
                "server_id": self.id,
                "server_title": self.title,
                "protocol": self.protocol,
            }
        )
        return normalized

    def qr(self, ref: str) -> dict:
        return self.run("qr", ref)

    def vpn_key(self, ref: str) -> dict:
        return self.run("vpnkey", ref)

    def show(self, ref: str) -> dict:
        return self.run("show", ref)

    def traffic(self) -> dict:
        return self.run("traffic")

    def online(self, seconds: int | None = None) -> dict:
        if seconds is None:
            return self.run("online")
        return self.run("online", str(seconds))

class ServerRegistry:
    def __init__(self, servers: list[VpnServer]):
        self.servers = servers
        self.by_id = {server.id: server for server in servers}
        if not self.servers:
            raise RuntimeError("servers list is empty")
        if len(self.by_id) != len(self.servers):
            raise RuntimeError("servers list contains duplicate ids")

    @property
    def is_single(self) -> bool:
        return len(self.servers) == 1

    @property
    def default(self) -> VpnServer:
        return self.servers[0]

    @classmethod
    def from_file(cls, path: Path) -> "ServerRegistry":
        raw_servers = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(raw_servers, list):
            raise RuntimeError("servers config must contain a JSON list")
        servers = [VpnServer(load_server_config(item)) for item in raw_servers]
        return cls(servers)

    def get(self, server_id: str) -> VpnServer:
        try:
            return self.by_id[server_id]
        except KeyError as exc:
            raise RuntimeError(f"unknown server: {server_id}") from exc


def load_server_config(item: dict) -> ServerConfig:
    if not isinstance(item, dict):
        raise RuntimeError("each server config entry must be an object")
    server_id = str(item.get("id") or "")
    protocol = str(item.get("protocol") or "")
    transport = str(item.get("transport") or "local")
    command = str(item.get("command") or "")
    default_service = (
        "xray.service"
        if protocol == "vless"
        else (
            "awg-quick@awg3.service"
            if server_id == "amneziawg3"
            else "awg-quick@awg0.service"
        )
    )
    service = str(item.get("service") or default_service)
    host = item.get("host")
    if not SERVER_ID_RE.fullmatch(server_id):
        raise RuntimeError(
            "server id must be 1-20 characters: latin letters, digits, _ or -"
        )
    if protocol not in SUPPORTED_PROTOCOLS:
        raise RuntimeError(f"unsupported protocol for {server_id}: {protocol}")
    if transport not in SUPPORTED_TRANSPORTS:
        raise RuntimeError(f"unsupported transport for {server_id}: {transport}")
    if not command:
        raise RuntimeError(f"command is missing for server {server_id}")
    if not re.fullmatch(r"[A-Za-z0-9@_.-]{1,100}", service):
        raise RuntimeError(f"service is missing or invalid for server {server_id}")
    if transport == "ssh" and not host:
        raise RuntimeError(f"host is missing for ssh server {server_id}")
    return ServerConfig(
        id=server_id,
        title=str(item.get("title") or item["id"]),
        protocol=protocol,
        transport=transport,
        command=command,
        service=service,
        host=str(host) if host else None,
        user=str(item.get("user") or "root"),
    )
