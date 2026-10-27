"""Real subprocess, PTY and interruption checks for the installer console."""
import contextlib
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'installer'))
from progress import CommandError, Dashboard, run_process


class Terminal(io.StringIO):
    def isatty(self): return True


class ProgressTests(unittest.TestCase):
    def test_terminal_reuses_three_rows_without_printing_child_output(self):
        terminal = Terminal()
        with patch.dict(os.environ, TERM='xterm'), patch('progress.shutil.get_terminal_size', return_value=os.terminal_size((40,24))):
            dashboard = Dashboard(terminal)
            dashboard.draw('Установка ' + 'x'*100, 'Журнал: /tmp/install.log')
            dashboard.draw('Проверка', 'Журнал: /tmp/install.log')
            dashboard.clear()
        frames = terminal.getvalue().split('\x1b[3A')
        self.assertEqual(len(frames), 4)
        for frame in frames[:2]:
            self.assertEqual(frame.count('\n'), 3)
            for line in frame.splitlines(): self.assertLessEqual(len(line.replace('\x1b[2K', '')), 39)

    def test_non_terminal_has_no_escape_sequences(self):
        stream = io.StringIO(); dashboard = Dashboard(stream)
        dashboard.draw('Установка', 'Журнал'); dashboard.draw('Установка', 'Журнал'); dashboard.clear()
        self.assertEqual(stream.getvalue(), 'Установка\nЖурнал\n')

    def test_real_noisy_child_is_drained_and_private_log_filters_credentials(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stderr(io.StringIO()) as console:
            env = dict(os.environ, BOT_TOKEN='fixture-sensitive-token')
            code = "import sys; print('fixture-sensitive-token'); print('PrivateKey = fixture'); print('hy2://fixture'); print('noise\\n'*20000); print('stderr-line', file=sys.stderr)"
            result = run_process([sys.executable,'-c',code], title='Идёт установка', env=env, log_directory=directory)
            self.assertEqual(result.returncode, 0)
            log = next(Path(directory).glob('*.log'))
            text = log.read_text()
            self.assertIn('stderr-line', text); self.assertIn('noise', text)
            for secret in ['fixture-sensitive-token', 'PrivateKey', 'hy2://']:
                self.assertNotIn(secret,text); self.assertNotIn(secret,console.getvalue())
            self.assertNotIn('noise',console.getvalue()); self.assertEqual(log.stat().st_mode & 0o777,0o600)

    def test_failure_is_visible_and_timeout_stops_child(self):
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stderr(io.StringIO()) as console:
            with self.assertRaises(CommandError):
                run_process([sys.executable,'-c',"import sys; print('ERROR: dependency unavailable'); sys.exit(7)"], log_directory=directory)
            self.assertIn('ERROR: dependency unavailable', console.getvalue())
            self.assertIn('Подробности:', console.getvalue())
            pidfile = Path(directory)/'child.pid'
            code = "import os,time; from pathlib import Path; Path("+repr(str(pidfile))+").write_text(str(os.getpid())); time.sleep(30)"
            with self.assertRaises(subprocess.TimeoutExpired):
                run_process([sys.executable,'-c',code], log_directory=directory, timeout=0.5)
            with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()),0)

    @unittest.skipUnless(os.name=='posix', 'POSIX process groups')
    def test_ctrl_c_stops_running_child_and_returns_without_hanging(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory)/'child.pid'
            childcode = "import os,time; from pathlib import Path; Path("+repr(str(pidfile))+").write_text(str(os.getpid())); time.sleep(30)"
            driver = "import sys; sys.path.insert(0,"+repr(str(ROOT/'installer'))+"); from progress import run_process; run_process([sys.executable,'-c',"+repr(childcode)+"], log_directory="+repr(directory)+")"
            driver_process = subprocess.Popen([sys.executable,'-c',driver], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                deadline=time.monotonic()+5
                while not pidfile.exists() and time.monotonic()<deadline: time.sleep(0.03)
                self.assertTrue(pidfile.exists())
                os.kill(driver_process.pid,signal.SIGINT)
                driver_process.communicate(timeout=8)
                with self.assertRaises(ProcessLookupError): os.kill(int(pidfile.read_text()),0)
            finally:
                if driver_process.poll() is None: driver_process.kill(); driver_process.communicate()

    @unittest.skipUnless(os.name=='posix', 'POSIX process groups')
    def test_exited_parent_cannot_leave_pipe_open_in_a_term_ignoring_child(self):
        child = "import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); print('ready',flush=True); time.sleep(30)"
        parent = "import subprocess,sys; p=subprocess.Popen([sys.executable,'-c'," + repr(child) + "],stdout=subprocess.PIPE); p.stdout.readline(); print('parent exit')"
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stderr(io.StringIO()):
            # The detached child inherits stderr (our pipe) even though its stdout is private.
            started=time.monotonic()
            with self.assertRaisesRegex(CommandError,'канал'):
                run_process([sys.executable,'-c',parent],log_directory=directory)
            self.assertLess(time.monotonic()-started,12)

    @unittest.skipUnless(os.name=='posix', 'PTY required')
    def test_real_pty_animates_in_place_and_restores_prompt_position(self):
        import pty
        master, slave = pty.openpty()
        driver = "import sys; sys.path.insert(0,"+repr(str(ROOT/'installer'))+"); from progress import activity; import time;\nwith activity('Идёт установка'): time.sleep(.4)\nprint('READY')"
        process = subprocess.Popen([sys.executable,'-c',driver], stdout=slave, stderr=slave, env=dict(os.environ,TERM='xterm'))
        os.close(slave)
        data=b''
        try:
            while True:
                try: chunk=os.read(master,8192)
                except OSError: break
                if not chunk: break
                data+=chunk
            process.wait(timeout=5)
        finally: os.close(master)
        self.assertEqual(process.returncode,0)
        self.assertIn(b'\x1b[3A',data)
        self.assertIn(b'  |',data); self.assertIn(b'  /',data)
        self.assertTrue(data.endswith(b'READY\r\n'))



class AuditRecoveryTests(unittest.TestCase):
    def test_wrong_answer_is_reasked_without_losing_other_answers(self):
        from state import InstallState
        from questionnaire import Questionnaire
        with tempfile.TemporaryDirectory() as directory:
            state=InstallState(Path(directory)/'state.json')
            state.data['answers']={'BOT_TOKEN':'123:fixture','HY_PORT':'bad'}; state.save()
            with patch('builtins.input',side_effect=['70000','443']) as prompt, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(Questionnaire(state).ask('HY_PORT','Порт'),'443')
            self.assertEqual(prompt.call_count,2)
            self.assertEqual(InstallState(state.path).data['answers'],{'BOT_TOKEN':'123:fixture','HY_PORT':'443'})

    def test_pending_kernel_does_not_reinstall_or_loop_after_wrong_boot(self):
        from state import InstallState
        from system_prepare import kernel_preflight
        with tempfile.TemporaryDirectory() as directory:
            state=InstallState(Path(directory)/'state.json')
            state.data['kernel_pending']={'boot_id':'boot-1','candidates':['6.12-test']};state.save()
            with patch('system_prepare.platform.release',return_value='6.1-old'), patch('system_prepare.Path.exists',return_value=False), patch('system_prepare.Path.read_text',return_value='boot-1'), patch('system_prepare.run') as command, contextlib.redirect_stdout(io.StringIO()):
                with self.assertRaises(SystemExit) as result: kernel_preflight('resume',state)
                self.assertEqual(result.exception.code,75);command.assert_not_called()
            with patch('system_prepare.platform.release',return_value='6.1-old'), patch('system_prepare.Path.exists',return_value=False), patch('system_prepare.Path.read_text',return_value='boot-2'), patch('system_prepare.run') as command:
                with self.assertRaisesRegex(ValueError,'загрузчике'):kernel_preflight('resume',state)
                command.assert_not_called()
            with patch('system_prepare.platform.release',return_value='6.12-test'), patch('system_prepare.Path.exists',return_value=True):
                kernel_preflight('resume',state)
            self.assertNotIn('kernel_pending',InstallState(state.path).data)

    def test_bootstrap_error_is_compact_and_diagnostic_log_survives(self):
        helper=ROOT/'installer/progress.sh'
        script='source "$1"; v3_progress_run "Идёт установка" bash -c \'for i in {1..100}; do echo noise; done; echo "ERROR: unavailable"; exit 7\''
        with tempfile.TemporaryDirectory() as directory:
            result=subprocess.run(['bash','-c',script,'bash',str(helper)],env=dict(os.environ,TMPDIR=directory),capture_output=True,text=True)
            self.assertEqual(result.returncode,7)
            self.assertNotIn('noise',result.stderr);self.assertIn('ERROR: unavailable',result.stderr)
            logs=list(Path(directory).glob('vpnbot-bootstrap.*'));self.assertEqual(len(logs),1)
            self.assertEqual(logs[0].stat().st_mode & 0o777,0o600)

if __name__=='__main__': unittest.main()
