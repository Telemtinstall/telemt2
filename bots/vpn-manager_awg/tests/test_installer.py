import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "install.sh"
BOOTSTRAP = ROOT / "install_bot.sh"
AWG_INSTALLER = ROOT.parents[1] / "vpn" / "amneziawg" / "install_amneziawg.sh"


class InstallerTests(unittest.TestCase):
    def test_bash_syntax(self):
        subprocess.run(["bash", "-n", str(INSTALLER)], check=True)
        subprocess.run(["bash", "-n", str(BOOTSTRAP)], check=True)
        subprocess.run(["bash", "-n", str(AWG_INSTALLER)], check=True)

    def test_bootstrap_updates_safely_and_delegates(self):
        source = BOOTSTRAP.read_text(encoding="utf-8")
        self.assertIn("status --porcelain", source)
        self.assertIn("pull --ff-only", source)
        self.assertIn("sha256sum --check SHA256SUMS", source)
        self.assertIn("</dev/tty", source)
        self.assertIn('exec "$installer"', source)
        self.assertNotIn("reset --hard", source)

    def test_installer_asks_before_vpn_and_software_updates(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn(
            "Установить/обновить дополнительное ПО бота "
            "(Python, Pillow, logrotate, Speedtest)?",
            source,
        )
        self.assertIn(
            "Установить/обновить AmneziaWG и VLESS, совместимые с ботом?",
            source,
        )
        self.assertIn("status --porcelain", BOOTSTRAP.read_text(encoding="utf-8"))
        self.assertIn("speedtest-cli", source)
        self.assertIn("apt-cache policy", source)

    def test_package_candidate_does_not_trigger_pipefail_sigpipe(self):
        source = INSTALLER.read_text(encoding="utf-8")
        block = source.split("package_candidate()", 1)[1].split(
            "audit_extra_software()", 1
        )[0]
        self.assertNotIn("apt-cache policy \"$1\" 2>/dev/null |", block)
        self.assertIn("policy=\"$(apt-cache policy", block)
        self.assertIn("<<< \"$policy\"", block)

    def test_supported_os_and_old_kernel_upgrade_flow(self):
        source = INSTALLER.read_text(encoding="utf-8")
        awg_source = AWG_INSTALLER.read_text(encoding="utf-8")
        self.assertIn("(( major >= 13 ))", source)
        self.assertIn("(( major >= 22 ))", source)
        self.assertIn('AWG_MIN_KERNEL="${AWG_MIN_KERNEL:-6.7}"', awg_source)
        self.assertIn("linux-generic-hwe-22.04", awg_source)
        self.assertIn("linux-image-amd64", awg_source)
        self.assertIn("minimum_kernel_preflight", awg_source)
        self.assertIn("AWG_RESUME_COMMAND", source)

    def test_vpn_shared_answers_are_not_asked_twice(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertEqual(1, source.count("Публичный IP/host для обоих VPN"))
        self.assertEqual(1, source.count("Имя первого пользователя в обоих VPN"))
        self.assertIn("ASSUME_YES=1", source)
        self.assertIn("./install_vless.sh --direct --auto", source)

    def test_installer_has_resume_state_and_rotated_log(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("/root/.install_vpnbot.state", source)
        self.assertIn("/root/.install_vpnbot.config", source)
        self.assertIn("/var/log/vpnbot-install.log", source)
        self.assertIn("run_resumable_step", source)
        self.assertIn("maxage 7", source)
        resume_block = source.split("save_resume_config()", 1)[1].split(
            "load_resume_config()", 1
        )[0]
        self.assertNotIn("BOT_TOKEN", resume_block)
        self.assertIn("Telegram token check failed: {type(exc).__name__}", source)
        self.assertIn("Telegram webhook cleanup failed: {type(exc).__name__}", source)

    def test_dry_run_is_non_mutating_and_complete(self):
        result = subprocess.run(
            ["bash", str(INSTALLER), "--dry-run"],
            cwd=ROOT,
            check=True,
            text=True,
            capture_output=True,
        )
        self.assertIn("DRY RUN", result.stdout)
        self.assertIn("AmneziaWG", result.stdout)
        self.assertIn("VLESS", result.stdout)
        self.assertIn("SQLite traffic", result.stdout)
        self.assertIn("SQLite access", result.stdout)
        self.assertIn("максимум 7 дней", result.stdout)

    def test_installer_contains_current_components(self):
        required = [
            "bot.py",
            "traffic_collect.py",
            "channel_collect.py",
            "install_bot.sh",
            "USAGE_RU.md",
            "servers.json",
            "app/server_status.py",
            "app/speedtest_status.py",
            "app/access_store.py",
            "app/traffic_store.py",
            "app/channel_store.py",
            "server/server-status",
            "server/vpn-speedtest",
            "systemd/vpnbot.service",
            "systemd/vpnbot-traffic.service",
            "systemd/vpnbot-traffic.timer",
            "systemd/vpnbot-channel.service",
            "systemd/vpnbot-channel.timer",
        ]
        for relative in required:
            self.assertTrue((ROOT / relative).is_file(), relative)

    def test_speedtest_script_normalizes_cli_json(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            fake = root / "speedtest-cli"
            fake.write_text(
                "#!/bin/sh\n"
                "printf '%s\\n' '"
                '{"download":175400000,"upload":133600000,"ping":23.754,'
                '"bytes_sent":1000,"bytes_received":2000,'
                '"server":{"id":"1","name":"London","country":"UK",'
                '"sponsor":"Test ISP","d":42.5},'
                '"client":{"isp":"VPS Provider","ip":"secret"}}'
                "'\n",
                encoding="utf-8",
            )
            fake.chmod(0o755)
            env = {
                **os.environ,
                "SPEEDTEST_CLI": str(fake),
                "VPN_SPEEDTEST_LOCK": str(root / "speedtest.lock"),
            }
            result = subprocess.run(
                ["python3", str(ROOT / "server/vpn-speedtest"), "-j"],
                check=True,
                text=True,
                capture_output=True,
                env=env,
            )
            data = json.loads(result.stdout)

        self.assertTrue(data["ok"])
        self.assertEqual(175400000, data["download_bps"])
        self.assertEqual("Test ISP", data["server"]["sponsor"])
        self.assertNotIn("ip", data["client"])


if __name__ == "__main__":
    unittest.main()
