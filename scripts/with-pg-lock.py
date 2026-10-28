#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
"""Run a command with exclusive access to the user's shared test PostgreSQL."""

import argparse
import errno
import fcntl
import os
from pathlib import Path
import sys


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

        # POSIX record locks survive exec, but are not inherited by forked
        # processes. Unlike flock, a postmaster left by --keep cannot retain this
        # lock after the runner exits. Exec also preserves signals and exit codes.
        os.set_inheritable(lock.fileno(), True)
        os.environ["_PG_DURABLE_LOCK_PATH"] = str(lock_path)
        os.environ["_PG_DURABLE_LOCK_OWNER"] = str(os.getpid())
        exec_command(command)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except OSError as error:
        print(f"pg_durable: cannot acquire PostgreSQL test lock: {error}", file=sys.stderr)
        sys.exit(1)
