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
            "Установить/обновить AmneziaWG 2.0, AmneziaWG 3.1 и VLESS, совместимые с ботом?",
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

    def test_kernel_detection_ignores_header_common_package(self):
        script = f'''\
set -Eeuo pipefail
export AWG_INSTALLER_LIBRARY_ONLY=1
source "{AWG_INSTALLER}"
apt-get() {{
  printf '%s\\n' \\
    'Inst linux-headers-6.12.107+deb13-common (6.12.107-1 Debian:13 [all])' \\
    'Inst linux-headers-6.12.107+deb13-amd64 (6.12.107-1 Debian:13 [amd64])'
}}
headers_kernel_from_apt_simulation linux-headers-amd64
'''
        result = subprocess.run(
            ["bash", "-c", script], check=True, text=True, capture_output=True
        )
        self.assertEqual("6.12.107+deb13-amd64", result.stdout.strip())

        source = AWG_INSTALLER.read_text(encoding="utf-8")
        installed_block = source.split("newest_installed_kernel()", 1)[1].split(
            "newest_other_kernel_with_headers()", 1
        )[0]
        self.assertIn("/boot/vmlinuz-*", installed_block)
        self.assertNotIn("/lib/modules/*", installed_block)

        preflight = source.split("kernel_headers_reboot_preflight()", 1)[1].split(
            "install_kernel_headers()", 1
        )[0]
        self.assertIn('apt-get install -y "${packages[@]}"', preflight)
        self.assertIn("newest_other_kernel_with_headers", preflight)

    def test_vpn_shared_answers_are_not_asked_twice(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertEqual(1, source.count("Публичный IP/host для всех VPN"))
        self.assertEqual(1, source.count("Имя первого пользователя во всех VPN"))
        self.assertIn("ASSUME_YES=1", source)
        self.assertIn("AWG_OBFS_PROFILE=awg3", source)
        self.assertIn("AWG_IFACE=awg3", source)
        self.assertIn("AWG_PORT=1235", source)
        self.assertIn("./install_vless.sh --direct --auto", source)

    def test_awg3_is_a_separate_resumable_instance(self):
        source = INSTALLER.read_text(encoding="utf-8")
        self.assertIn("AWG3CTL_PATH", source)
        self.assertIn("AWG_IFACE=awg3", source)
        self.assertIn("AWG_PORT=1235", source)
        self.assertIn("AWG_SUBNET=10.89.89.0/24", source)
        self.assertIn("STATE_FILE=/root/.install_amneziawg3.state", source)
        self.assertIn("server_private_awg3.key", source)
        self.assertIn("awg-quick@awg3.service", source)

        registry = json.loads((ROOT / "servers.json").read_text(encoding="utf-8"))
        self.assertEqual(
            ["AmneziaWG 2.0", "AmneziaWG 3.1", "VLESS"],
            [item["title"] for item in registry],
        )
        self.assertEqual("/usr/local/sbin/awg3ctl", registry[1]["command"])

    def test_awg3_profile_has_required_generation_fields(self):
        script = f'''\
set -Eeuo pipefail
export AWG_INSTALLER_LIBRARY_ONLY=1
source "{AWG_INSTALLER}"
AWG_OBFS_PROFILE=awg3
AWG_JC= AWG_JMIN= AWG_JMAX= AWG_S1= AWG_S2= AWG_S3= AWG_S4=
AWG_H1= AWG_H2= AWG_H3= AWG_H4= AWG_I1=
AWG_HEADER_PROTECTION_KEY= AWG_CONTENT_PADDING_ADDITION=
ensure_awg_obfuscation_params
printf '%s|%s|%s|%s|%s|%s\n' \
  "$AWG_JC" "$AWG_S1" "$AWG_S3" "$AWG_S4" \
  "$AWG_CONTENT_PADDING_ADDITION" "$AWG_HEADER_PROTECTION_KEY"
'''
        result = subprocess.run(
            ["bash", "-c", script], check=True, text=True, capture_output=True
        )
        jc, s1, s3, s4, padding, key = result.stdout.strip().split("|")
        self.assertEqual("6", jc)
        self.assertGreaterEqual(int(s1), 12)
        self.assertGreaterEqual(int(s3), 12)
        self.assertGreaterEqual(int(s4), 12)
        self.assertEqual("10-50", padding)
        self.assertEqual(44, len(key))

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
