#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
"""Run a non-interactive command with exclusive access to the shared test PostgreSQL."""

import argparse
from collections import deque
import errno
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


def inherited_lock(lock_path):
    if os.environ.get("_PG_DURABLE_LOCK_PATH") != str(lock_path):
        return False
    try:
        owner = int(os.environ.get("_PG_DURABLE_LOCK_OWNER", "0"))
    except ValueError:
        return False
    if owner <= 0:
        return False
    try:
        os.kill(owner, 0)
    except ProcessLookupError:
        return False
    return True


def exec_command(command):
    os.environ["_PG_DURABLE_LOCK_EXEC_PID"] = str(os.getpid())
    try:
        os.execvp(command[0], command)
    except OSError as error:
        print(f"pg_durable: cannot execute {command[0]}: {error}", file=sys.stderr)
        sys.exit(127 if error.errno == errno.ENOENT else 126)


def live_processes():
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,pgid=,stat="], check=True, capture_output=True, text=True,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        detail = str(error)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr.strip():
            detail += f": {error.stderr.strip()}"
        raise RuntimeError(f"cannot inspect process groups with ps: {detail}") from error

    if not result.stdout.strip():
        raise RuntimeError("ps returned an empty process listing")
    try:
        # An orphaned zombie can keep a group alive without doing any more work.
        processes = {}
        for line in result.stdout.splitlines():
            pid, group, state = line.split()
            pid = int(pid)
            group = int(group)
            if not state.startswith("Z"):
                processes[pid] = group
        return processes
    except ValueError as error:
        raise RuntimeError("ps returned an invalid process listing") from error


def supervise_command(command):
    # Fail before starting work if process-group monitoring is unavailable.
    live_processes()
    pending = deque()
    cancelled_by = None
    command_state_changed = False

    def remember_signal(signum, _frame):
        nonlocal cancelled_by
        cancelled_by = signum
        pending.append(signum)

    def child_changed(_signum, _frame):
        nonlocal command_state_changed
        command_state_changed = True

    previous_handlers = {
        signum: signal.signal(signum, remember_signal)
        for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    }
    previous_handlers[signal.SIGCHLD] = signal.signal(signal.SIGCHLD, child_changed)
    had_error = False
    last_error = None

    def write_status(message):
        nonlocal had_error
        try:
            print(f"pg_durable: {message}", file=sys.stderr, flush=True)
        except OSError:
            # Losing the diagnostic pipe must not release a live command's lock.
            had_error = True

    def report_error(message):
        nonlocal had_error, last_error
        had_error = True
        if message != last_error:
            write_status(f"{message}; retaining the PostgreSQL test lock")
            last_error = message

    try:
        if cancelled_by is not None:
            return 128 + cancelled_by
        try:
            # The inherited-lock path sets the re-exec marker to the child's PID.
            child = subprocess.Popen(
                [sys.executable, str(Path(__file__).resolve()), "--", *command],
                start_new_session=True,
            )
        except OSError as error:
            raise RuntimeError(f"cannot start the supervised command: {error}") from error

        reported_wait = False
        while True:
            signal_error = None
            while pending:
                signum = pending.popleft()
                write_status(f"forwarding {signal.Signals(signum).name} to process "
                             f"group {child.pid}; waiting for work to finish")
                try:
                    os.killpg(child.pid, signum)
                except ProcessLookupError:
                    pass
                except OSError as error:
                    signal_error = f"cannot signal process group {child.pid}: {error}"

            if command_state_changed:
                try:
                    processes = live_processes()
                    if child.pid not in processes.values():
                        break
                except RuntimeError as error:
                    report_error(str(error))
                else:
                    if child.pid not in processes and not reported_wait:
                        write_status(f"waiting for remaining work in process group {child.pid}")
                        reported_wait = True
            if signal_error is not None:
                report_error(signal_error)
            time.sleep(0.1)

        # Keep the leader unreaped until its group stops, reserving the PGID
        # while cancellation might still signal surviving descendants.
        returncode = child.wait()
    finally:
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)

    if cancelled_by is not None:
        return 128 + cancelled_by
    if had_error:
        return 1
    return returncode if returncode >= 0 else 128 - returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    command = parser.parse_args().command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required")

    # Use one lock for all versions: runners also share version-independent logs.
    lock_path = (Path.home() / ".pgrx" / "pg_durable-test.lock").resolve()
    if inherited_lock(lock_path):
        exec_command(command)

    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lock:
        try:
            fcntl.lockf(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print(f"pg_durable: waiting for shared PostgreSQL lock: {lock_path}",
                  file=sys.stderr, flush=True)
            fcntl.lockf(lock, fcntl.LOCK_EX)

        # Only the supervisor owns the lock, not the command or a kept server.
        os.environ["_PG_DURABLE_LOCK_PATH"] = str(lock_path)
        os.environ["_PG_DURABLE_LOCK_OWNER"] = str(os.getpid())
        return supervise_command(command)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except OSError as error:
        print(f"pg_durable: cannot acquire PostgreSQL test lock: {error}", file=sys.stderr)
        sys.exit(1)
    except RuntimeError as error:
        print(f"pg_durable: {error}", file=sys.stderr)
        sys.exit(1)
