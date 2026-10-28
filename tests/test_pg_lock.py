#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
"""Test cross-worktree PostgreSQL coordination without PostgreSQL or Cargo."""

import fcntl
import json
import os
from pathlib import Path
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, call, patch


ROOT = Path(__file__).resolve().parents[1]
WRAPPER = ROOT / "scripts" / "with-pg-lock.py"
RUNNERS = [
    "test-unit.sh", "test-e2e-local.sh", "test-upgrade.sh", "test-all-local.sh",
    "test-coverage.sh", "test-shutdown.sh", "test-epoch-race.sh",
    "pg-start.sh", "pg-stop.sh", "pg-reset.sh",
]
HOLD = "import sys; print('entered', flush=True); sys.stdin.readline()"


def cleanup_process(process):
    # Each fixture owns its process group, including any simulated server.
    try:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except PermissionError:
            # macOS rejects zombie-only groups. Reap our child before retrying.
            if process.poll() is None:
                raise
            os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.communicate(timeout=10)


class ProcessCleanupTests(unittest.TestCase):
    def test_reaps_zombie_before_retrying_group_cleanup(self):
        for result in (None, ProcessLookupError()):
            with self.subTest(result=result):
                process = Mock(pid=1234)
                process.poll.return_value = 0
                with patch("os.killpg", side_effect=[PermissionError(), result]) as kill_group:
                    cleanup_process(process)
                self.assertEqual(kill_group.call_args_list,
                                 [call(1234, signal.SIGKILL), call(1234, signal.SIGKILL)])
                process.poll.assert_called_once_with()
                process.communicate.assert_called_once_with(timeout=10)

    def test_group_permission_errors_are_not_suppressed(self):
        for returncode in (None, 0):
            with self.subTest(returncode=returncode):
                process = Mock(pid=1234)
                process.poll.return_value = returncode
                with patch("os.killpg", side_effect=PermissionError) as kill_group:
                    with self.assertRaises(PermissionError):
                        cleanup_process(process)
                self.assertEqual(kill_group.call_count, 1 if returncode is None else 2)
                process.communicate.assert_not_called()


class PostgresLockTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        self.home = self.root / "home"
        self.lock_path = self.home / ".pgrx" / "pg_durable-test.lock"
        self.lock_path.parent.mkdir(parents=True)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith("_PG_DURABLE_LOCK_")
        }
        self.env.update(HOME=str(self.home), PYTHONUNBUFFERED="1")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env["PATH"] = str(self.bin) + os.pathsep + self.env["PATH"]
        self.write_program(self.bin / "cargo", """
import json, os, sys
from pathlib import Path
if os.environ.get("CARGO_RECORD"):
    Path(os.environ["CARGO_RECORD"]).write_text(json.dumps({
        "args": sys.argv[1:], "cwd": os.getcwd(),
    }))
if os.environ.get("HOLD_CARGO"):
    sys.stdin.readline()
sys.exit(int(os.environ.get("CARGO_EXIT", "0")))
""")

    def write_program(self, path, code):
        path.write_text(f"#!{sys.executable}\n{code}", encoding="utf-8")
        path.chmod(0o755)

    def worktree(self, name):
        root = self.root / name
        scripts = root / "scripts"
        scripts.mkdir(parents=True)
        for name in [*RUNNERS, "pg-common.sh", "with-pg-lock.py"]:
            shutil.copy2(ROOT / "scripts" / name, scripts / name)
        shutil.copy2(ROOT / "Makefile", root / "Makefile")
        return root

    def start(self, command, *, cwd=None, env=None, wrapped=True):
        if wrapped:
            command = [sys.executable, str(WRAPPER), *command]
        process = subprocess.Popen(
            command, cwd=cwd, env={**self.env, **(env or {})},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, start_new_session=True,
        )

        self.addCleanup(cleanup_process, process)
        return process

    def read_line(self, stream):
        self.assertTrue(select.select([stream], [], [], 10)[0], "Timed out waiting for output")
        return stream.readline().strip()

    def assert_waiting(self, process):
        self.assertIn("waiting for shared PostgreSQL lock:", self.read_line(process.stderr))
        self.assertIsNone(process.poll())

    def assert_finished(self, process, code=0, input=None):
        output, error = process.communicate(input=input, timeout=10)
        self.assertEqual(process.returncode, code, output + error)
        return output, error

    def wait_for_file(self, path):
        deadline = time.monotonic() + 10
        while not path.exists():
            self.assertLess(time.monotonic(), deadline, f"Timed out waiting for {path}")
            time.sleep(0.01)

    def hold_lock(self):
        lock = self.lock_path.open("a")
        self.addCleanup(lock.close)
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return lock

    def test_strict_runner_preserves_empty_and_quoted_arguments(self):
        worktree = self.worktree("arguments")
        runner = worktree / "scripts" / "lock-args.sh"
        runner.write_text("""
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/pg-common.sh"
lock_local_postgres "$SCRIPT_DIR/lock-args.sh"
python3 -c 'import json, sys; print(json.dumps(sys.argv[1:]))' "$@"
""")
        for args in ([], [""], ["two words", '"quoted"', "*", "$HOME", "\u03bb"]):
            with self.subTest(args=args):
                process = self.start(["bash", str(runner), *args], wrapped=False)
                output, _ = self.assert_finished(process)
                self.assertEqual(json.loads(output), args)

    def test_worktrees_queue_even_for_different_postgres_versions(self):
        first = self.worktree("first worktree")
        second = self.worktree("second worktree")
        first_record = self.root / "first.json"
        second_record = self.root / "second.json"
        holder = self.start(
            ["bash", "./test-unit.sh", "--pg-version", "18",
             "--features", "test-hooks", "filter with spaces"],
            cwd=first / "scripts", wrapped=False,
            env={"CARGO_RECORD": str(first_record), "HOLD_CARGO": "1", "CARGO_EXIT": "23"},
        )
        self.wait_for_file(first_record)
        waiter = self.start(
            ["bash", "scripts/test-unit.sh", "--pg-version", "17", "second"],
            cwd=second, wrapped=False, env={"CARGO_RECORD": str(second_record)},
        )
        self.assert_waiting(waiter)
        self.assertFalse(second_record.exists())
        self.assert_finished(holder, 23, input="\n")
        self.assert_finished(waiter)
        self.assertEqual(json.loads(first_record.read_text()), {
            "args": ["pgrx", "test", "pg18", "--features", "test-hooks", "--", "filter with spaces"],
            "cwd": str(first),
        })
        self.assertEqual(json.loads(second_record.read_text())["args"],
                         ["pgrx", "test", "pg17", "--", "second"])

    def test_nested_runners_keep_the_outer_lock(self):
        worktree = self.worktree("nested")
        holder = self.start([sys.executable, "-c", """
import subprocess, sys
for _ in range(2):
    subprocess.run(["bash", "scripts/test-unit.sh", "nested"],
                   check=True, stdout=subprocess.DEVNULL)
print("entered", flush=True)
sys.stdin.readline()
"""], cwd=worktree)
        self.assertEqual(self.read_line(holder.stdout), "entered")
        waiter = self.start([sys.executable, "-c", "print('next')"])
        self.assert_waiting(waiter)
        self.assert_finished(holder, input="\n")
        self.assertEqual(self.assert_finished(waiter)[0].strip(), "next")

    def test_surviving_server_does_not_retain_lock(self):
        pid_file = self.root / "server.pid"
        holder = self.start([sys.executable, "-c", """
import subprocess, sys
from pathlib import Path
child = subprocess.Popen(
    [sys.executable, "-c", "import time; time.sleep(60)"],
    close_fds=False, stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
)
Path(sys.argv[1]).write_text(str(child.pid))
""", str(pid_file)])
        self.assert_finished(holder)
        server_pid = int(pid_file.read_text())
        os.kill(server_pid, 0)
        next_run = self.start([sys.executable, "-c", "print('next')"])
        self.assertEqual(self.assert_finished(next_run)[0].strip(), "next")
        os.kill(server_pid, 0)
        self.assertTrue(self.lock_path.exists(), "Never unlink a reusable lock file")

    def test_exit_cleanup_remains_locked(self):
        holder = self.start(["bash", "-c", """
trap 'echo cleanup; read -r line' EXIT
exit 7
"""])
        self.assertEqual(self.read_line(holder.stdout), "cleanup")
        waiter = self.start([sys.executable, "-c", "print('next')"])
        self.assert_waiting(waiter)
        self.assert_finished(holder, 7, input="\n")
        self.assertEqual(self.assert_finished(waiter)[0].strip(), "next")

    def test_signals_release_the_owner_lock(self):
        for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGKILL):
            with self.subTest(signal=sig):
                holder = self.start([sys.executable, "-c", HOLD])
                self.assertEqual(self.read_line(holder.stdout), "entered")
                waiter = self.start([sys.executable, "-c", "print('next')"])
                self.assert_waiting(waiter)
                holder.send_signal(sig)
                holder.communicate(timeout=10)
                self.assertNotEqual(holder.returncode, 0)
                self.assertEqual(self.assert_finished(waiter)[0].strip(), "next")

    def test_signalled_runner_keeps_lock_until_foreground_child_finishes(self):
        worktree = self.worktree("interrupted unit")
        for sig in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=sig):
                record = self.root / f"cargo-{sig}.json"
                holder = self.start(
                    ["bash", "scripts/test-unit.sh"], cwd=worktree, wrapped=False,
                    env={"CARGO_RECORD": str(record), "HOLD_CARGO": "1"},
                )
                self.wait_for_file(record)
                holder.send_signal(sig)
                waiter = self.start([sys.executable, "-c", "print('next')"])
                self.assert_waiting(waiter)
                self.assert_finished(holder, 128 + sig, input="\n")
                self.assertEqual(self.assert_finished(waiter)[0].strip(), "next")

    def test_interrupted_waiter_never_executes_command(self):
        lock = self.hold_lock()
        marker = self.root / "unexpected"
        waiter = self.start([sys.executable, "-c",
                             "from pathlib import Path; import sys; Path(sys.argv[1]).touch()",
                             str(marker)])
        self.assert_waiting(waiter)
        waiter.send_signal(signal.SIGINT)
        self.assert_finished(waiter, 130)
        lock.close()
        self.assertFalse(marker.exists())
        self.assert_finished(self.start([sys.executable, "-c", "pass"]))

    def test_stale_inherited_owner_does_not_bypass_lock(self):
        old = self.start([sys.executable, "-c",
                          "import json, os; print(json.dumps(dict(os.environ)))"])
        inherited = json.loads(self.assert_finished(old)[0])
        lock = self.hold_lock()
        waiter = self.start([sys.executable, "-c", "pass"], env=inherited)
        self.assert_waiting(waiter)
        lock.close()
        self.assert_finished(waiter)

    def test_independent_homes_do_not_block(self):
        holder = self.start([sys.executable, "-c", HOLD])
        self.assertEqual(self.read_line(holder.stdout), "entered")
        self.assert_finished(self.start(
            [sys.executable, "-c", "pass"], env={"HOME": str(self.root / "other home")},
        ))
        self.assertIsNone(holder.poll())
        self.assert_finished(holder, input="\n")

    def test_lock_errors_fail_before_command(self):
        other_home = self.root / "invalid home"
        other_home.mkdir()
        (other_home / ".pgrx").touch()
        process = self.start([sys.executable, "-c", "print('unexpected')"],
                             env={"HOME": str(other_home)})
        output, error = self.assert_finished(process, 1)
        self.assertEqual(output, "")
        self.assertIn("cannot acquire PostgreSQL test lock:", error)

    def test_exec_failure_releases_lock(self):
        process = self.start(["/nonexistent-pg-durable-test-command"])
        self.assertIn("cannot execute", self.assert_finished(process, 127)[1])
        self.assert_finished(self.start([sys.executable, "-c", "pass"]))

    def test_all_local_entry_points_wait_before_touching_postgres(self):
        worktree = self.worktree("entrypoints")
        self.hold_lock()
        for runner in RUNNERS:
            with self.subTest(runner=runner):
                process = self.start(["bash", f"scripts/{runner}"],
                                     cwd=worktree, wrapped=False)
                self.assert_waiting(process)
                process.send_signal(signal.SIGTERM)
                process.communicate(timeout=10)
                self.assertEqual(process.returncode, -signal.SIGTERM)
        for target in ("test-unit", "test-regress", "pg-install", "run"):
            with self.subTest(target=target):
                process = self.start(["make", "--no-print-directory", target],
                                     cwd=worktree, wrapped=False)
                self.assert_waiting(process)
                os.killpg(process.pid, signal.SIGTERM)
                process.communicate(timeout=10)
                self.assertNotEqual(process.returncode, 0)

    def test_help_does_not_wait(self):
        worktree = self.worktree("help")
        self.hold_lock()
        for runner in ("test-e2e-local.sh", "pg-start.sh",
                       "test-shutdown.sh", "test-epoch-race.sh"):
            with self.subTest(runner=runner):
                process = self.start(["bash", f"scripts/{runner}", "--help"],
                                     cwd=worktree, wrapped=False)
                output, error = self.assert_finished(process)
                self.assertIn("Usage:", output)
                self.assertNotIn("waiting for", error)

    def test_docker_only_stop_does_not_wait(self):
        worktree = self.worktree("docker")
        self.write_program(self.bin / "docker", "")
        self.hold_lock()
        self.assert_finished(self.start(["bash", "scripts/pg-stop.sh", "--docker"],
                                        cwd=worktree, wrapped=False))

    def test_forced_install_failure_does_not_start_another_worktrees_binary(self):
        worktree = self.worktree("failed build")
        config = self.lock_path.parent / "config.toml"
        config.write_text(f'[configs]\npg17 = "{self.bin / "pg_config"}"\n')
        process = self.start(["bash", "scripts/pg-start.sh", "--build"],
                             cwd=worktree, wrapped=False, env={"CARGO_EXIT": "23"})
        self.assert_finished(process, 23)
        self.assertFalse((self.lock_path.parent / "data-17").exists())

    def test_make_regress_holds_lock_through_installcheck(self):
        worktree = self.worktree("regress")
        record = self.root / "regress.jsonl"
        probe = """
import fcntl, json, os, sys
with open(os.environ["_PG_DURABLE_LOCK_PATH"], "a") as lock:
    try:
        fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        pass
    else:
        sys.exit("regression step ran without the outer lock")
with open(os.environ["REGRESS_RECORD"], "a") as record:
    record.write(json.dumps(sys.argv) + "\\n")
"""
        for helper in ("pg-reset.sh", "pg-start.sh"):
            self.write_program(worktree / "scripts" / helper, probe)
        make = self.bin / "nested-make"
        self.write_program(make, """
import os, sys
if sys.argv[1:] == ["_test-regress"]:
    os.execv(os.environ["REAL_MAKE"], [os.environ["REAL_MAKE"], "_test-regress"])
""" + probe + """
print("entered", flush=True)
sys.stdin.readline()
""")
        holder = self.start(
            ["make", "--no-print-directory", "test-regress", f"MAKE={make}", "PG_VERSION=pg18"],
            cwd=worktree, wrapped=False,
            env={"REGRESS_RECORD": str(record), "REAL_MAKE": shutil.which("make")},
        )
        deadline = time.monotonic() + 10
        while not record.exists() or len(record.read_text().splitlines()) < 3:
            self.assertIsNone(holder.poll(), "make exited before installcheck")
            self.assertLess(time.monotonic(), deadline, "make never reached installcheck")
            time.sleep(0.01)
        waiter = self.start([sys.executable, "-c", "print('next')"])
        self.assert_waiting(waiter)
        self.assert_finished(holder, input="\n")
        self.assertEqual(self.assert_finished(waiter)[0].strip(), "next")
        calls = [json.loads(line) for line in record.read_text().splitlines()]
        self.assertEqual(calls[0][1:], ["18"])
        self.assertEqual(calls[1][1:], ["--build", "--pg-version", "18"])
        self.assertEqual(calls[2][1:], ["-e", "installcheck"])


if __name__ == "__main__":
    unittest.main()
