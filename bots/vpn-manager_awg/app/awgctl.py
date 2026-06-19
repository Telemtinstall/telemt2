from __future__ import annotations

import json
import logging
import subprocess


log = logging.getLogger("vpnbotawg.awgctl")


class Awgctl:
    def __init__(self, path: str, timeout: int = 120):
        self.path = path
        self.timeout = timeout

    def run(self, *args: str) -> dict:
        cmd = [self.path, "-j", *args]
        proc = subprocess.run(
            cmd,
            text=True,
            capture_output=True,
            stdin=subprocess.DEVNULL,
            timeout=self.timeout,
        )
        raw = proc.stdout.strip() or proc.stderr.strip()
        try:
            data = json.loads(raw)
        except json.JSONDecodeError:
            log.warning("awgctl returned non-json for %s: rc=%s", args, proc.returncode)
            raise RuntimeError(raw or f"awgctl exited with {proc.returncode}")

        if proc.returncode != 0 or not data.get("ok"):
            raise RuntimeError(data.get("error") or data.get("status") or "awgctl error")
        return data

    def add(self, name: str | None = None) -> dict:
        if name:
            return self.run("add", name)
        return self.run("add")

    def delete(self, ref: str) -> dict:
        return self.run("delete", ref)

    def list_clients(self) -> list[dict]:
        return self.run("list").get("clients") or []

    def qr(self, ref: str) -> dict:
        return self.run("qr", ref)

    def show(self, ref: str) -> dict:
        return self.run("show", ref)

    def traffic(self) -> dict:
        return self.run("traffic")

