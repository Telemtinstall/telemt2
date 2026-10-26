"""Run installer control flow with sandboxed paths and stubbed system operations."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest

BOT = Path(__file__).resolve().parents[1]
REPO = BOT.parents[1]
AWG = REPO / 'vpn/amneziawg/install_amneziawg.sh'
VLESS = REPO / 'vpn/vless/install_vless.sh'


def library(path):
    text = path.read_text()
    if path == AWG:
        return text.split('if [[ "${AWG_INSTALLER_LIBRARY_ONLY:-0}"')[0]
    return text.rsplit('main "$@"', 1)[0]


class InstallerFailureTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def run_script(self, path, body, replacements=None):
        text = library(path)
        for old, new in (replacements or {}).items(): text = text.replace(old, new)
        script = self.root/'fixture.sh'
        script.write_text(text + '\ntrap - ERR\n' + body)
        return subprocess.run(['bash', str(script)], capture_output=True, text=True)

    def test_kernel_pause_has_distinct_exit_code_and_resume_command(self):
        result = self.run_script(AWG, 'AWG_RESUME_COMMAND="bash /root/install-v2.sh"\ndie_reboot_required_for_kernel old new\necho MUST_NOT_RUN\n')
        self.assertEqual(result.returncode, 75)
        self.assertIn('reboot', result.stdout)
        self.assertIn('bash /root/install-v2.sh', result.stdout)
        self.assertNotIn('ОШИБКА', result.stdout + result.stderr)
        self.assertNotIn('MUST_NOT_RUN', result.stdout)

    def test_parent_preserves_pause_and_does_not_complete_step(self):
        state = self.root/'state'
        result = self.run_script(BOT/'install.sh', f"INSTALL_STATE_FILE={shlex.quote(str(state))}\ntrap installation_exit_report EXIT\nrun_resumable_step vpn fixture bash -c 'exit 75'\necho MUST_NOT_RUN\n")
        self.assertEqual(result.returncode, 75)
        self.assertIn('штатная пауза', result.stdout)
        self.assertNotIn('Установка прервана с кодом', result.stdout)
        self.assertNotIn('MUST_NOT_RUN', result.stdout)
        self.assertFalse(state.exists())

    def test_pending_token_resumes_and_is_deleted_on_success(self):
        config = self.root/'resume'
        state = self.root/'state'
        result = self.run_script(BOT/'install.sh', f"""
INSTALL_RESUME_CONFIG={shlex.quote(str(config))}
INSTALL_STATE_FILE={shlex.quote(str(state))}
current_installer_version() {{ echo fixture; }}
BOT_TOKEN='123:fixture-secret'
save_pending_token
BOT_TOKEN=''
load_pending_token
[[ "$BOT_TOKEN" == '123:fixture-secret' ]]
finish_installation_tracking
""")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('fixture-secret', result.stdout + result.stderr)
        self.assertFalse(Path(str(config)+'.token').exists())
        self.assertTrue(Path(str(state)+'.completed').exists())

    def test_pending_token_rejects_readable_file(self):
        config = self.root/'resume'; token=Path(str(config)+'.token')
        token.write_text('secret');token.chmod(0o644)
        result=self.run_script(BOT/'install.sh', f'INSTALL_RESUME_CONFIG={shlex.quote(str(config))}\nBOT_TOKEN=""\nload_pending_token\necho MUST_NOT_RUN\n')
        self.assertNotEqual(result.returncode,0)
        self.assertNotIn('MUST_NOT_RUN',result.stdout)

    def test_completed_install_is_detected_without_running_install(self):
        state=self.root/'state'; installed=self.root/'bot';installed.mkdir()
        (installed/'VPNBOT_VERSION').write_text((BOT/'VPNBOT_VERSION').read_text())
        result=self.run_script(BOT/'install.sh', f"""
SCRIPT_DIR={shlex.quote(str(BOT))}
INSTALL_DIR={shlex.quote(str(installed))}
INSTALL_STATE_FILE={shlex.quote(str(state))}
printf '%s|%s\\n' "$(current_installer_version)" "$INSTALL_DIR" > "${{INSTALL_STATE_FILE}}.completed"
installation_already_complete
echo detected
printf 'extra_software\\n' > "$INSTALL_STATE_FILE"
if installation_already_complete; then exit 99; fi
""")
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('detected',result.stdout)

    def test_v3_checkpoints_survive_resume_version_change(self):
        config=self.root/'resume';state=self.root/'state'
        config.write_text('RESUME_INSTALLER_VERSION=global-v2-2026.10.26.3\nVPN_INITIAL_CLIENT=alice\nADMIN_BOT=123\n')
        state.write_text('extra_software\nrepository\nendpoint_backup\n')
        result=self.run_script(BOT/'install.sh',f'INSTALL_RESUME_CONFIG={shlex.quote(str(config))}\nINSTALL_STATE_FILE={shlex.quote(str(state))}\ncurrent_installer_version() {{ echo global-v2-2026.10.27.4; }}\nload_resume_config\n[[ "$VPN_INITIAL_CLIENT" == alice ]]\nstep_done extra_software\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertTrue(state.exists())

    def test_exhausted_retry_preserves_failure_for_both_installers(self):
        for path in (AWG, VLESS):
            with self.subTest(path=path):
                result = self.run_script(path, 'INSTALL_RETRIES=1\nretry_command fixture bash -c "exit 42"\necho MUST_NOT_RUN\n')
                self.assertEqual(result.returncode, 42, result.stderr)
                self.assertNotIn('MUST_NOT_RUN', result.stdout)

    def test_retry_can_succeed_on_second_attempt(self):
        for path in (AWG, VLESS):
            result = self.run_script(path, 'INSTALL_RETRIES=2\nRETRY_DELAY_SECONDS=0\nattempts=0\nflaky() { attempts=$((attempts+1)); [[ $attempts -eq 2 ]]; }\nretry_command fixture flaky\necho attempts=$attempts\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('attempts=2', result.stdout)

    def test_awg_does_not_mark_failed_step(self):
        state = self.root/'state'
        result = self.run_script(AWG, f'STATE_FILE={shlex.quote(str(state))}\nbroken() {{ false; echo MUST_NOT_RUN; }}\nrun_step broken fixture broken\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('MUST_NOT_RUN', result.stdout)
        self.assertFalse(state.exists())

    def test_missing_logrotate_directory_is_created(self):
        directory = self.root/'logrotate.d'
        result = self.run_script(BOT/'install.sh', f'INSTALL_LOG={shlex.quote(str(self.root/"logs/install.log"))}\nconfigure_installer_log\n', {'/etc/logrotate.d': str(directory)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((directory/'vpnbot-installer').exists())

    def test_working_ppa_is_not_removed_by_second_awg_install(self):
        result = self.run_script(AWG, '''
remove_amnezia_ppa_entries() { echo MUST_NOT_REMOVE; }
apt_update_checked() { :; }
apt-get() { :; }
have() { return 0; }
awg() { :; }
ensure_amneziawg_kernel_module() { :; }
install_packages
install_amneziawg_tools
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('MUST_NOT_REMOVE', result.stdout)

    def test_local_resume_keeps_mode_and_paths_without_token(self):
        config = self.root/'resume'
        body = f'''
SCRIPT_DIR={shlex.quote(str(BOT))}
INSTALL_RESUME_CONFIG={shlex.quote(str(config))}
INSTALL_STATE_FILE={shlex.quote(str(self.root/'state'))}
VLESS_MODE=mask
LOCAL_SOURCE=1
INSTALL_DIR=/srv/custom-bot
save_resume_config
VLESS_MODE=direct
LOCAL_SOURCE=0
INSTALL_DIR=/wrong
load_resume_config
printf '%s|%s|%s\\n' "$VLESS_MODE" "$LOCAL_SOURCE" "$INSTALL_DIR"
bot_resume_command
'''
        result = self.run_script(BOT/'install.sh', body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('mask|1|/srv/custom-bot', result.stdout)
        self.assertIn('--local-source --vless-mask', result.stdout)
        self.assertNotIn('BOT_TOKEN=', config.read_text())

    def test_existing_awg_peers_cannot_be_overwritten(self):
        config = self.root/'awg0.conf'; config.write_text('[Peer]\nPublicKey = existing\n')
        result = self.run_script(AWG, f'AWG_DIR={shlex.quote(str(self.root))}\nAWG_IFACE=awg0\nwrite_awg_config\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(config.read_text(), '[Peer]\nPublicKey = existing\n')

    def test_existing_vless_users_are_preserved(self):
        users = self.root/'users.json'
        content = json.dumps([{'name':'old', 'uuid':'old-uuid'}, {'name':'second', 'uuid':'second-uuid'}])
        users.write_text(content)
        result = self.run_script(VLESS, f'USERS_FILE={shlex.quote(str(users))}\nnew_uuid() {{ echo unused; }}\nCLIENT_NAME=new\ninit_first_user\necho selected=$CLIENT_NAME\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(users.read_text(), content)
        self.assertIn('selected=old', result.stdout)

    def test_reality_is_accepted_by_both_installers(self):
        for path, flag in [(VLESS, '--reality'), (BOT/'install.sh', '--vless-reality')]:
            result = self.run_script(path, f'parse_args {flag}\necho mode=${{FRONTEND_MODE:-${{VLESS_MODE}}}}\n')
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn('mode=reality', result.stdout)

    def test_reality_keys_created_once_and_partial_keys_not_rotated(self):
        binary = self.root/'xray'
        binary.write_text('#!/bin/sh\nprintf "PrivateKey: '+ 'A'*43 +'\\nPassword (PublicKey): '+ 'B'*43 +'\\n"\n')
        binary.chmod(0o755)
        key = self.root/'reality.key'
        body = f'''
export PATH={shlex.quote(str(self.root))}:"$PATH"
FRONTEND_MODE=reality
REALITY_PRIVATE_KEY_FILE={shlex.quote(str(key))}
REALITY_SHORT_ID=abcd1234
chown() {{ :; }}
save_resume_config() {{ :; }}
prepare_reality_keys
printf 'public=%s\\n' "$REALITY_PUBLIC_KEY"
'''
        result = self.run_script(VLESS, body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('A'*43, result.stdout)
        self.assertEqual(key.stat().st_mode & 0o777, 0o600)
        original = key.read_bytes()
        binary.write_text('#!/bin/sh\nexit 99\n')
        result = self.run_script(VLESS, body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(key.read_bytes(), original)
        Path(str(key)+'.pub').unlink()
        result = self.run_script(VLESS, body)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(key.read_bytes(), original)

    def test_reality_fresh_install_control_flow_reaches_config_and_verification(self):
        """Actual main sequencing, with OS/package/service operations replaced by fixtures."""
        r = shlex.quote(str(self.root))
        body = f'''
CONFIG_DIR={r}/xray
ENV_FILE="$CONFIG_DIR/vless.env"
USERS_FILE="$CONFIG_DIR/users.json"
CONFIG_FILE="$CONFIG_DIR/config.json"
STATE_FILE={r}/state
RESUME_CONFIG={r}/resume
CONFIG_HASH_FILE={r}/hash
LINKS_FILE={r}/links
BACKUP_ROOT={r}/backups
REALITY_PRIVATE_KEY_FILE="$CONFIG_DIR/reality.key"
REALITY_SHORT_ID=abcd1234
PUBLIC_HOST=1.1.1.1
PUBLIC_IP=1.1.1.1
CLIENT_NAME=alice
SCRIPT_DIR={shlex.quote(str(VLESS.parent))}
FRONTEND_MODE=reality
ASSUME_YES=1
VLESS_PATH=/fixture
mkdir -p "$CONFIG_DIR"
# Keep actual mode selection, validation, checkpoints, key/config preparation.
detect_os() {{ :; }}
early_preflight() {{ :; }}
preflight() {{ :; }}
install_base_tools() {{ :; }}
setup_xray_runtime() {{ :; }}
setup_nginx_certbot() {{ echo UNEXPECTED_NGINX; return 91; }}
configure_firewall() {{ :; }}
chown() {{ :; }}
install() {{
  local args=()
  while (($#)); do
    case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
  done
  command install "${{args[@]}}"
}}
new_uuid() {{ echo 11111111-1111-4111-8111-111111111111; }}
prepare_reality_keys() {{
  printf '%s\\n' '{'A'*43}' > "$REALITY_PRIVATE_KEY_FILE"
  REALITY_PUBLIC_KEY={'B'*43}
}}
CTL_PATH={r}/ctl
cat > "$CTL_PATH" <<'CTL'
#!/bin/sh
[ "$1" = render ] || exit 92
exit 0
CTL
chmod +x "$CTL_PATH"
start_services() {{ echo STARTED_$FRONTEND_MODE; }}
verify_install() {{ echo VERIFIED_$FRONTEND_MODE; printf 'fixture-link\\n' > "$LINKS_FILE"; }}
print_install_qr() {{ :; }}
main --reality --auto
'''
        result = self.run_script(VLESS, body)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('UNEXPECTED_NGINX', result.stdout)
        self.assertIn('VERIFIED_reality', result.stdout)
        env = (self.root/'xray/vless.env').read_text()
        self.assertIn('FRONTEND_MODE=reality', env)
        self.assertIn('REALITY_PUBLIC_KEY=' + 'B'*43, env)
        self.assertNotIn('A'*43, env)
        users = json.loads((self.root/'xray/users.json').read_text())
        self.assertEqual(users[0]['name'], 'alice')
        self.assertIn('done', (self.root/'state').read_text().splitlines())

    def test_apt_warning_with_zero_exit_is_still_a_failure(self):
        result = self.run_script(AWG, '''
INSTALL_RETRIES=1
apt-get() { echo 'W: Failed to fetch https://ppa.launchpadcontent.net/amnezia/ppa/ubuntu/dists/focal/InRelease'; return 0; }
apt_update_checked fixture return
echo MUST_NOT_RUN
''', {'/tmp/amneziawg-apt-update.log': str(self.root/'apt.log')})
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn('MUST_NOT_RUN', result.stdout)

    def test_completed_install_is_not_mistaken_for_partial_resume(self):
        state, config = self.root/'state', self.root/'resume'
        state.write_text('config\ndone\n'); config.write_text('PUBLIC_HOST=1.1.1.1\n')
        result = self.run_script(BOT/'install.sh', f'incomplete_protocol_install {shlex.quote(str(state))} {shlex.quote(str(config))}\n')
        self.assertNotEqual(result.returncode, 0)
        state.write_text('config\n')
        result = self.run_script(BOT/'install.sh', f'incomplete_protocol_install {shlex.quote(str(state))} {shlex.quote(str(config))}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
