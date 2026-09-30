import errno
import json
import os
import pty
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1] / "plugins" / "warp" / "scripts"
BODY = '{"type":"agent_status","status":"working"}'
EXPECTED = f"\033]777;notify;warp://cli-agent;{BODY}\007".encode()
LAUNCHER = """
import fcntl
import json
import os
import signal
import subprocess
import sys
import tempfile
import termios

if sys.argv[2] == "tty":
    signal.signal(signal.SIGTTOU, signal.SIG_IGN)
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    os.tcsetpgrp(0, os.getpgrp())
    signal.signal(signal.SIGTTOU, signal.SIG_DFL)
os.environ["TEST_TTY_ROOT_PID"] = str(os.getpid())
detached = sys.argv[1] == "detached"
with tempfile.TemporaryFile() as out, tempfile.TemporaryFile() as err:
    proc = subprocess.Popen(
        sys.argv[3:], stdin=subprocess.PIPE, stdout=out, stderr=err,
        start_new_session=detached,
    )
    try:
        proc.communicate(b'{"session_id":"test-session","cwd":"/tmp/test"}', timeout=5)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait(timeout=2)
        raise
    out.seek(0)
    err.seek(0)
    print(json.dumps({
        "returncode": proc.returncode,
        "stdout": out.read().decode(),
        "stderr": err.read().decode(),
    }))
"""


class NotificationTTYTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        real_ps = shutil.which("ps")
        real_readlink = shutil.which("readlink")
        # End discovery at our synthetic terminal owner, never the real test terminal.
        ps = self.root / "ps"
        ps.write_text(
            """#!/bin/bash
if [ -n "${TEST_TERMINAL_OVERRIDE:-}" ]; then
    printf '1 %s\\n' "$TEST_TERMINAL_OVERRIDE"
    exit 0
fi
info=$("$TEST_REAL_PS" "$@") || exit 1
read -r parent terminal <<< "$info"
if [ "$2" = "$TEST_TTY_ROOT_PID" ]; then
    parent=1
fi
printf '%s %s\\n' "$parent" "$terminal"
"""
        )
        ps.chmod(0o755)
        readlink = self.root / "readlink"
        readlink.write_text(
            """#!/bin/bash
if [ -n "${TEST_TERMINAL_OVERRIDE:-}" ]; then
    printf '%s\\n' "$TEST_TERMINAL_OVERRIDE"
else
    exec "$TEST_REAL_READLINK" "$@"
fi
"""
        )
        readlink.chmod(0o755)
        self.env = os.environ.copy()
        self.env.update(
            PATH=f"{self.root}{os.pathsep}{self.env.get('PATH', '')}",
            TEST_REAL_PS=real_ps or "",
            TEST_REAL_READLINK=real_readlink or "",
            WARP_CLIENT_VERSION="v0.2026.09.29.08.29.dev_00",
            WARP_CLI_AGENT_PROTOCOL_VERSION="1",
        )

    def run_hook(self, args, detached, terminal=True):
        master, slave = pty.openpty()
        try:
            env = self.env.copy()
            if not terminal:
                env["TEST_TERMINAL_OVERRIDE"] = "/dev/null"

            proc = subprocess.Popen(
                [sys.executable, "-c", LAUNCHER,
                 "detached" if detached else "inherited",
                 "tty" if terminal else "none", *args],
                stdin=slave if terminal else subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                env=env,
                start_new_session=True,
            )
            try:
                stdout, stderr = proc.communicate(timeout=10)
            except subprocess.TimeoutExpired:
                os.close(master)
                master = None
                os.close(slave)
                slave = None
                try:
                    proc.kill()
                except (PermissionError, ProcessLookupError):
                    pass
                try:
                    proc.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
                proc.stdout.close()
                proc.stderr.close()
                self.fail("hook did not finish within the deadline")
            self.assertEqual(proc.returncode, 0, stderr.decode())
            result = json.loads(stdout)
            os.set_blocking(master, False)
            output = bytearray()
            while True:
                try:
                    chunk = os.read(master, 4096)
                except OSError as error:
                    if error.errno in (errno.EIO, errno.EAGAIN):
                        break
                    raise
                if not chunk:
                    break
                output.extend(chunk)
            return result, bytes(output)
        finally:
            if master is not None:
                os.close(master)
            if slave is not None:
                os.close(slave)

    def test_inherited_and_detached_notifications_reach_terminal(self):
        for detached in (False, True):
            with self.subTest(detached=detached):
                result, output = self.run_hook(
                    [str(SCRIPTS / "warp-notify.sh"), "warp://cli-agent", BODY],
                    detached,
                )
                self.assertEqual(result, {"returncode": 0, "stdout": "", "stderr": ""})
                self.assertEqual(output, EXPECTED)

    def test_detached_lifecycle_hooks_reach_terminal(self):
        for hook in ("on-session-start.sh", "on-prompt-submit.sh", "on-stop.sh"):
            with self.subTest(hook=hook):
                result, output = self.run_hook([str(SCRIPTS / hook)], detached=True)
                self.assertEqual(result, {"returncode": 0, "stdout": "", "stderr": ""})
                prefix = b"\033]777;notify;warp://cli-agent;"
                self.assertTrue(output.startswith(prefix), output)
                self.assertTrue(output.endswith(b"\007"), output)
                payload = json.loads(output[len(prefix):-1])
                self.assertEqual(payload["session_id"], "test-session")

    def test_no_terminal_is_nonfatal_and_diagnosable(self):
        result, output = self.run_hook(
            [str(SCRIPTS / "warp-notify.sh"), "warp://cli-agent", BODY],
            detached=True,
            terminal=False,
        )
        self.assertEqual(result["returncode"], 0)
        self.assertEqual(result["stdout"], "")
        self.assertIn("no writable terminal found", result["stderr"])
        self.assertEqual(output, b"")

    def test_unsupported_warp_emits_nothing(self):
        self.env.pop("WARP_CLI_AGENT_PROTOCOL_VERSION")
        result, output = self.run_hook(
            [str(SCRIPTS / "warp-notify.sh"), "warp://cli-agent", BODY],
            detached=True,
        )
        self.assertEqual(result, {"returncode": 0, "stdout": "", "stderr": ""})
        self.assertEqual(output, b"")

    def test_non_terminal_device_is_not_used(self):
        self.env["TEST_TERMINAL_OVERRIDE"] = "/dev/tty-invalid-test"
        result, output = self.run_hook(
            [str(SCRIPTS / "warp-notify.sh"), "warp://cli-agent", BODY],
            detached=True,
        )
        self.assertEqual(result["returncode"], 0)
        self.assertIn("no writable terminal found", result["stderr"])
        self.assertEqual(output, b"")


if __name__ == "__main__":
    unittest.main()
