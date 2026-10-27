from __future__ import annotations

import json
import subprocess


def run_speedtest(command: str, timeout: int = 210) -> dict:
    proc = subprocess.run(
        [command, "-j"],
        text=True,
        capture_output=True,
        stdin=subprocess.DEVNULL,
        timeout=timeout,
    )
    raw = proc.stdout.strip() or proc.stderr.strip()
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise RuntimeError(raw or f"vpn-speedtest exited with {proc.returncode}") from exc
    if proc.returncode != 0 or not data.get("ok"):
        raise RuntimeError(data.get("error") or f"vpn-speedtest exited with {proc.returncode}")
    return data
