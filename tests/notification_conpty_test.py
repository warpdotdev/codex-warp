import base64
import ctypes
from ctypes import wintypes as w
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest


ROOT = Path(__file__).resolve().parents[1]
IS_WINDOWS = sys.platform == "win32"

if IS_WINDOWS:
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)

    class Coord(ctypes.Structure):
        _fields_ = [("x", ctypes.c_short), ("y", ctypes.c_short)]

    class Overlapped(ctypes.Structure):
        _fields_ = [("internal", ctypes.c_size_t), ("internal_high", ctypes.c_size_t),
                    ("offset", w.DWORD), ("offset_high", w.DWORD), ("event", w.HANDLE)]

    class StartupInfo(ctypes.Structure):
        _fields_ = [
            ("cb", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR),
            ("title", w.LPWSTR), ("x", w.DWORD), ("y", w.DWORD),
            ("x_size", w.DWORD), ("y_size", w.DWORD),
            ("x_chars", w.DWORD), ("y_chars", w.DWORD),
            ("fill", w.DWORD), ("flags", w.DWORD), ("show", w.WORD),
            ("reserved_size", w.WORD), ("reserved_ptr", ctypes.c_void_p),
            ("stdin", w.HANDLE), ("stdout", w.HANDLE), ("stderr", w.HANDLE),
        ]

    class StartupInfoEx(ctypes.Structure):
        _fields_ = [("startup", StartupInfo), ("attributes", ctypes.c_void_p)]

    class ProcessInfo(ctypes.Structure):
        _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE),
                    ("pid", w.DWORD), ("tid", w.DWORD)]

    class BasicLimits(ctypes.Structure):
        _fields_ = [
            ("process_time", ctypes.c_int64), ("job_time", ctypes.c_int64),
            ("flags", w.DWORD), ("min_working_set", ctypes.c_size_t),
            ("max_working_set", ctypes.c_size_t), ("active_processes", w.DWORD),
            ("affinity", ctypes.c_size_t), ("priority", w.DWORD), ("scheduling", w.DWORD),
        ]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [
            ("basic", BasicLimits), ("io_counters", ctypes.c_uint64 * 6),
            ("process_memory", ctypes.c_size_t), ("job_memory", ctypes.c_size_t),
            ("peak_process_memory", ctypes.c_size_t), ("peak_job_memory", ctypes.c_size_t),
        ]

    def api(name, args, result=w.BOOL):
        function = getattr(kernel, name)
        function.argtypes = args
        function.restype = result
        return function

    close = api("CloseHandle", [w.HANDLE])
    create_pipe = api("CreatePipe", [ctypes.POINTER(w.HANDLE), ctypes.POINTER(w.HANDLE),
                                    ctypes.c_void_p, w.DWORD])
    read_file = api("ReadFile", [w.HANDLE, ctypes.c_void_p, w.DWORD,
                                ctypes.POINTER(w.DWORD), ctypes.c_void_p])
    write_file = api("WriteFile", [w.HANDLE, ctypes.c_void_p, w.DWORD,
                                  ctypes.POINTER(w.DWORD), ctypes.c_void_p])
    create_event = api("CreateEventW", [ctypes.c_void_p, w.BOOL, w.BOOL, w.LPCWSTR], w.HANDLE)
    overlapped_result = api("GetOverlappedResult",
                            [w.HANDLE, ctypes.c_void_p, ctypes.POINTER(w.DWORD), w.BOOL])
    cancel_io = api("CancelIoEx", [w.HANDLE, ctypes.c_void_p])
    wait = api("WaitForSingleObject", [w.HANDLE, w.DWORD], w.DWORD)
    terminate = api("TerminateProcess", [w.HANDLE, w.UINT])
    create_job = api("CreateJobObjectW", [ctypes.c_void_p, w.LPCWSTR], w.HANDLE)
    set_job_info = api("SetInformationJobObject",
                       [w.HANDLE, w.DWORD, ctypes.c_void_p, w.DWORD])
    assign_job = api("AssignProcessToJobObject", [w.HANDLE, w.HANDLE])
    resume = api("ResumeThread", [w.HANDLE], w.DWORD)
    get_exit = api("GetExitCodeProcess", [w.HANDLE, ctypes.POINTER(w.DWORD)])
    init_attributes = api("InitializeProcThreadAttributeList",
                          [ctypes.c_void_p, w.DWORD, w.DWORD, ctypes.POINTER(ctypes.c_size_t)])
    set_attribute = api("UpdateProcThreadAttribute",
                        [ctypes.c_void_p, w.DWORD, ctypes.c_size_t, ctypes.c_void_p,
                         ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p])
    delete_attributes = api("DeleteProcThreadAttributeList", [ctypes.c_void_p], None)
    create_process = api("CreateProcessW",
                         [w.LPCWSTR, w.LPWSTR, ctypes.c_void_p, ctypes.c_void_p, w.BOOL,
                          w.DWORD, ctypes.c_void_p, w.LPCWSTR, ctypes.POINTER(StartupInfo),
                          ctypes.POINTER(ProcessInfo)])

    def checked(ok):
        if not ok:
            raise ctypes.WinError(ctypes.get_last_error())

    class ConPty:
        def __init__(self, command):
            self.handles = []
            self.process = ProcessInfo()
            self.job = None
            self.console = w.HANDLE()
            self.output = bytearray()
            self.condition = threading.Condition()
            self.eof = False
            self.reader = None
            dll_path = os.environ.get("WARP_CONPTY_DLL")
            self.duplex = bool(dll_path)
            dll = ctypes.WinDLL(dll_path, use_last_error=True) if dll_path else kernel
            self.dll = dll
            create = dll.CreatePseudoConsole
            create.argtypes = [Coord, w.HANDLE, w.HANDLE, w.DWORD, ctypes.POINTER(w.HANDLE)]
            create.restype = ctypes.c_long
            self.close_console = dll.ClosePseudoConsole
            self.close_console.argtypes = [w.HANDLE]
            self.close_console.restype = None

            try:
                if dll_path:
                    # Warp's bundled ConPTY expects one duplex endpoint for both directions.
                    name = r"\\.\pipe\codex-warp-test-" + os.urandom(12).hex()
                    named = api("CreateNamedPipeW",
                                [w.LPCWSTR, w.DWORD, w.DWORD, w.DWORD, w.DWORD,
                                 w.DWORD, w.DWORD, ctypes.c_void_p], w.HANDLE)
                    file = api("CreateFileW", [w.LPCWSTR, w.DWORD, w.DWORD, ctypes.c_void_p,
                                              w.DWORD, w.DWORD, w.HANDLE], w.HANDLE)
                    connect = api("ConnectNamedPipe", [w.HANDLE, ctypes.c_void_p])
                    server = named(name, 3 | 0x40000000, 0, 1, 65536, 65536, 0, None)
                    checked(server != ctypes.c_void_p(-1).value)
                    self.handles.append(server)
                    client = file(name, 0xC0000000, 0, None, 3, 0x40000000, None)
                    checked(client != ctypes.c_void_p(-1).value)
                    self.handles.append(client)
                    connection = Overlapped()
                    connection.event = create_event(None, True, False, None)
                    checked(connection.event)
                    try:
                        if not connect(server, ctypes.byref(connection)):
                            checked(ctypes.get_last_error() == 535)
                    finally:
                        close(connection.event)
                    self.input_write = self.output_read = server
                    input_read = output_write = client
                else:
                    input_read, self.input_write = w.HANDLE(), w.HANDLE()
                    self.output_read, output_write = w.HANDLE(), w.HANDLE()
                    checked(create_pipe(ctypes.byref(input_read), ctypes.byref(self.input_write), None, 0))
                    self.handles.extend([input_read, self.input_write])
                    checked(create_pipe(ctypes.byref(self.output_read), ctypes.byref(output_write), None, 0))
                    self.handles.extend([self.output_read, output_write])
                hr = create(Coord(120, 40), input_read, output_write, 0, ctypes.byref(self.console))
                if hr < 0:
                    raise OSError("CreatePseudoConsole failed: HRESULT %08x" % (hr & 0xFFFFFFFF))

                for endpoint in {input_read.value if hasattr(input_read, "value") else input_read,
                                 output_write.value if hasattr(output_write, "value") else output_write}:
                    close(endpoint)
                    self.handles = [handle for handle in self.handles
                                    if (handle.value if hasattr(handle, "value") else handle) != endpoint]

                self.reader = threading.Thread(target=self._read, daemon=True)
                self.reader.start()
                self._write(b"\x1b[?1;2c")
                size = ctypes.c_size_t()
                init_attributes(None, 1, 0, ctypes.byref(size))
                attributes = ctypes.create_string_buffer(size.value)
                checked(init_attributes(attributes, 1, 0, ctypes.byref(size)))
                try:
                    checked(set_attribute(attributes, 0, 0x00020016, self.console,
                                          ctypes.sizeof(w.HANDLE), None, None))
                    startup = StartupInfoEx()
                    startup.startup.cb = ctypes.sizeof(startup)
                    startup.startup.flags = 0x100
                    startup.attributes = ctypes.cast(attributes, ctypes.c_void_p)
                    cmdline = ctypes.create_unicode_buffer(subprocess.list2cmdline(command))
                    checked(create_process(None, cmdline, None, None, False, 0x80004,
                                           None, str(ROOT),
                                           ctypes.cast(ctypes.byref(startup), ctypes.POINTER(StartupInfo)),
                                           ctypes.byref(self.process)))
                    self.job = create_job(None, None)
                    checked(self.job)
                    limits = ExtendedLimits()
                    limits.basic.flags = 0x2000
                    checked(set_job_info(self.job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
                    checked(assign_job(self.job, self.process.process))
                    checked(resume(self.process.thread) != 0xFFFFFFFF)
                finally:
                    delete_attributes(attributes)
                if dll_path:
                    show = dll.ConptyShowHidePseudoConsole
                    show.argtypes = [w.HANDLE, w.BOOL]
                    show.restype = ctypes.c_long
                    show(self.console, True)
                    release = dll.ConptyReleasePseudoConsole
                    release.argtypes = [w.HANDLE]
                    release.restype = ctypes.c_long
                    release(self.console)
            except BaseException:
                self.close()
                raise

        def _io(self, function, handle, buffer, length, transferred):
            if not self.duplex:
                return function(handle, buffer, length, ctypes.byref(transferred), None)
            operation = Overlapped()
            operation.event = create_event(None, True, False, None)
            checked(operation.event)
            try:
                if function(handle, buffer, length, ctypes.byref(transferred),
                            ctypes.byref(operation)):
                    return True
                if ctypes.get_last_error() != 997:
                    return False
                if wait(operation.event, 45000) != 0:
                    cancel_io(handle, ctypes.byref(operation))
                    overlapped_result(handle, ctypes.byref(operation),
                                      ctypes.byref(transferred), True)
                    return False
                return overlapped_result(handle, ctypes.byref(operation),
                                         ctypes.byref(transferred), True)
            finally:
                close(operation.event)

        def _write(self, data):
            written = w.DWORD()
            checked(self._io(write_file, self.input_write, data, len(data), written))

        def _read(self):
            buffer = ctypes.create_string_buffer(4096)
            read = w.DWORD()
            while self._io(read_file, self.output_read, buffer, len(buffer), read):
                if not read.value:
                    break
                chunk = buffer.raw[:read.value]
                with self.condition:
                    self.output.extend(chunk)
                    self.condition.notify_all()
                if b"\x1b[c" in chunk:
                    self._write(b"\x1b[?1;2c")
                if b"\x1b[6n" in chunk:
                    self._write(b"\x1b[1;1R")
            with self.condition:
                self.eof = True
                self.condition.notify_all()

        def complete(self, timeout=40):
            if wait(self.process.process, int(timeout * 1000)) != 0:
                raise TimeoutError("console fixture did not finish")
            code = w.DWORD()
            checked(get_exit(self.process.process, ctypes.byref(code)))
            if code.value:
                raise AssertionError("console fixture exited %d" % code.value)

        def notifications(self, count, timeout=5):
            pattern = rb"\x1b\]777;notify;warp://cli-agent;([^\x07]*)\x07"
            deadline = time.monotonic() + timeout
            with self.condition:
                while True:
                    matches = re.findall(pattern, bytes(self.output))
                    if len(matches) >= count or self.eof:
                        return [json.loads(match) for match in matches]
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        return [json.loads(match) for match in matches]
                    self.condition.wait(remaining)

        def close(self):
            if self.job:
                close(self.job)
                self.job = None
            if self.process.process:
                if wait(self.process.process, 0) != 0:
                    terminate(self.process.process, 1)
                    wait(self.process.process, 5000)
                close(self.process.thread)
                close(self.process.process)
                self.process = ProcessInfo()
            if self.console:
                self.close_console(self.console)
                self.console = w.HANDLE()
            if self.duplex:
                for handle in self.handles:
                    cancel_io(handle, None)
                if self.reader:
                    self.reader.join(timeout=5)
            for handle in self.handles:
                close(handle)
            self.handles = []
            if self.reader:
                self.reader.join(timeout=5)


@unittest.skipUnless(IS_WINDOWS, "requires Windows console APIs")
class ConPtyNotificationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="codex warp conpty ")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.root = Path(cls.temp.name)
        cls.codex = cls.root / "codex.exe"
        source = ROOT / "tests" / "console-parent.cs"
        compile_command = (
            "Add-Type -Path '" + str(source).replace("'", "''")
            + "' -OutputAssembly '" + str(cls.codex).replace("'", "''")
            + "' -OutputType ConsoleApplication"
        )
        subprocess.run(["powershell.exe", "-NoProfile", "-Command", compile_command],
                       check=True, capture_output=True, timeout=30)
        cls.scripts = cls.root / "plugin scripts"
        shutil.copytree(ROOT / "plugins" / "warp" / "scripts", cls.scripts)
        (cls.scripts / "control-output.ps1").write_text(
            ". \"$PSScriptRoot\\on-session-start.ps1\"\n"
            "[Console]::Out.WriteLine('{\"control\":true}')\n"
            "[Console]::Error.WriteLine('control-stderr')\n",
            encoding="utf-8",
        )

        (cls.scripts / "dead-parent.ps1").write_text(
            "$parent = Get-Process -Id ([int]$env:CONPTY_TEST_PARENT_PID) -ErrorAction SilentlyContinue\n"
            "$deadline = [DateTime]::UtcNow.AddSeconds(10)\n"
            "while ($null -ne $parent -and -not $parent.HasExited) {\n"
            "    if ([DateTime]::UtcNow -gt $deadline) { throw 'parent did not exit' }\n"
            "    Start-Sleep -Milliseconds 20\n"
            "}\n"
            ". \"$PSScriptRoot\\on-session-start.ps1\"\n",
            encoding="utf-8",
        )

    def run_hook(self, hook, detached=True, wrapper=True, count=1, owner=True, role=None):
        with tempfile.TemporaryDirectory(dir=self.root) as directory:
            result_root = Path(directory)
            payload = result_root / "input.json"
            payload.write_text(json.dumps({
                "session_id": "test-session", "cwd": "C:\\work\\project",
                "prompt": "Check café and \U0001f600", "last_assistant_message": "Done café \U0001f600",
            }, ensure_ascii=False), encoding="utf-8")
            executable = self.codex
            if not owner:
                executable = self.root / "unrelated-parent.exe"
                if not executable.exists():
                    shutil.copyfile(self.codex, executable)
            command = [
                str(executable), str(self.scripts / hook), str(payload), directory,
                "detached" if detached else "inherited",
                "cmd" if wrapper else "direct", str(count),
            ]
            if role:
                command.append(role)
            pty = ConPty(command)
            try:
                pty.complete()
                results = [
                    json.loads((result_root / ("result-%d.json" % i)).read_text(encoding="utf-8-sig"))
                    for i in range(count)
                ]
                for result in results:
                    result["stdout"] = base64.b64decode(result.pop("stdout_base64")).decode("utf-8")
                    result["stderr"] = base64.b64decode(result.pop("stderr_base64")).decode("utf-8")
                received = pty.notifications(count if owner and role != "dead" else 0)
                return results, received
            finally:
                pty.close()

    def test_inherited_and_detached_delivery(self):
        for detached in (False, True):
            for wrapper in (False, True):
                with self.subTest(detached=detached, wrapper=wrapper):
                    results, received = self.run_hook(
                        "on-session-start.ps1", detached=detached, wrapper=wrapper,
                    )
                    self.assertEqual(results, [{"exit_code": 0, "stdout": "", "stderr": ""}])
                    self.assertEqual(len(received), 1, "no lifecycle event on ConPTY output")
                    self.assertEqual(received[0]["event"], "session_start")
                    self.assertEqual(received[0]["session_id"], "test-session")

    def test_prompt_and_stop_delivery_with_unicode(self):
        for hook, event, field, text in (
            ("on-prompt-submit.ps1", "prompt_submit", "query", "Check café and \U0001f600"),
            ("on-stop.ps1", "stop", "response", "Done café \U0001f600"),
        ):
            with self.subTest(hook=hook):
                results, received = self.run_hook(hook)
                self.assertEqual(results, [{"exit_code": 0, "stdout": "", "stderr": ""}])
                self.assertEqual(len(received), 1)
                self.assertEqual(received[0]["event"], event)
                self.assertEqual(received[0][field], text)

    def test_concurrent_detached_hooks(self):
        results, received = self.run_hook("on-session-start.ps1", count=4)
        self.assertEqual(results, [{"exit_code": 0, "stdout": "", "stderr": ""}] * 4)
        self.assertEqual(len(received), 4)
        self.assertTrue(all(payload["event"] == "session_start" for payload in received))

    def test_control_output_stays_captured(self):
        results, received = self.run_hook("control-output.ps1")
        self.assertEqual(results, [{
            "exit_code": 0, "stdout": '{"control":true}\r\n', "stderr": "control-stderr\r\n",
        }])
        self.assertEqual(len(received), 1)
        self.assertEqual(received[0]["event"], "session_start")

    def test_unrelated_ancestor_is_not_used(self):
        results, received = self.run_hook("on-session-start.ps1", owner=False)
        self.assertEqual(results[0]["exit_code"], 0)
        self.assertEqual(results[0]["stdout"], "")
        self.assertIn("no live Codex ancestor", results[0]["stderr"])
        self.assertEqual(received, [])

    def test_exited_closest_codex_does_not_route_to_live_ancestor(self):
        results, received = self.run_hook("dead-parent.ps1", role="dead")
        self.assertEqual(results[0]["exit_code"], 0)
        self.assertEqual(results[0]["stdout"], "")
        self.assertIn("no live Codex ancestor", results[0]["stderr"])
        self.assertEqual(received, [])


if __name__ == "__main__":
    unittest.main()
