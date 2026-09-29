#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
"""Test real N-1 instances through a binary-only upgrade and ALTER EXTENSION."""

import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import tomllib


PROJECT = Path(__file__).resolve().parents[1]
ROLE = "upgrade_lifecycle_user"


def run(*args, cwd=None, env=None):
    return subprocess.run(
        [str(arg) for arg in args], cwd=cwd, env=env, check=True,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout.strip()


def require_equal(actual, expected):
    if actual != expected:
        raise RuntimeError(f"Expected {expected!r}, got {actual!r}")


def literal(value):
    return "'" + value.replace("'", "''") + "'"


def build(source, output, pg_config, pg_major):
    output.mkdir()
    lock = source / "Cargo.lock"
    before = lock.read_bytes()
    # Both versions emit libpg_durable.so; never share their final build artifacts.
    target = PROJECT / "target" if source == PROJECT else PROJECT / f"target/upgrade-previous-pg{pg_major}"
    env = dict(os.environ, CARGO_TARGET_DIR=str(target))
    features = ["--no-default-features", "--features", f"pg{pg_major}"]
    manifest = ["--manifest-path", str(source / "Cargo.toml")]
    print(f"Building {source}; log: {output / 'build.log'}", flush=True)
    try:
        with (output / "build.log").open("w") as log:
            for command in (
                ["cargo", "metadata", "--locked", "--format-version", "1", *manifest, *features],
                ["cargo", "pgrx", "package", "--debug", "--pg-config", str(pg_config),
                 "--out-dir", str(output / "package"), *manifest, *features],
            ):
                subprocess.run(command, cwd=source, env=env, check=True,
                               stdout=log, stderr=subprocess.STDOUT)
    finally:
        if lock.read_bytes() != before:
            raise RuntimeError(f"Build changed the pinned lockfile: {lock}")
    return output / "package"


def install(package, prefix):
    pg_config = prefix / "bin/pg_config"
    libdir = Path(run(pg_config, "--pkglibdir"))
    extension_dir = Path(run(pg_config, "--sharedir")) / "extension"
    for directory in (libdir, extension_dir):
        if not directory.resolve().is_relative_to(prefix.resolve()):
            raise RuntimeError(f"PostgreSQL installation did not relocate: {directory}")
    libraries = list(package.rglob("pg_durable.so"))
    controls = list(package.rglob("pg_durable.control"))
    if len(libraries) != 1 or len(controls) != 1:
        raise RuntimeError(f"Incomplete or ambiguous package: {package}")
    shutil.copy2(libraries[0], libdir / "pg_durable.so")
    for path in controls[0].parent.glob("pg_durable*"):
        if path.suffix in (".sql", ".control"):
            shutil.copy2(path, extension_dir / path.name)


class Cluster:
    def __init__(self, prefix, output, timeout):
        self.prefix = prefix
        self.data = output / "data"
        self.log = output / "postgres.log"
        self.timeout = timeout
        self.schema = None
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]

    def initialize(self):
        run(self.prefix / "bin/initdb", "-D", self.data, "-U", "postgres",
            "--no-locale", "-A", "trust")

    def start(self):
        options = (
            f"-p {self.port} -c listen_addresses=127.0.0.1 -c unix_socket_directories='' "
            "-c shared_preload_libraries=pg_durable -c pg_durable.worker_role=postgres "
            "-c pg_durable.database=postgres"
        )
        run(self.prefix / "bin/pg_ctl", "-D", self.data, "-l", self.log,
            "-w", "-t", "60", "-o", options, "start",
            env=dict(os.environ, PGHOST="127.0.0.1", PGPORT=str(self.port)))

    def stop(self):
        if (self.data / "postmaster.pid").exists():
            run(self.prefix / "bin/pg_ctl", "-D", self.data, "-m", "fast",
                "-w", "-t", "60", "stop")

    def sql(self, query, role=None):
        if role:
            query = 'SET ROLE "' + role.replace('"', '""') + '"; ' + query
        return run(self.prefix / "bin/psql", "-X", "-qAt", "-h", "127.0.0.1",
                   "-p", self.port, "-U", "postgres", "-d", "postgres",
                   "-v", "ON_ERROR_STOP=1", "-c", query,
                   env=dict(os.environ, PGCONNECT_TIMEOUT=str(max(1, math.ceil(self.timeout))),
                            PGOPTIONS=f"-c statement_timeout={max(1, math.ceil(self.timeout * 1000))}"))

    def versions(self, binary, schema):
        require_equal(self.sql("SELECT split_part(df.version(), ' ', 1);"), binary)
        require_equal(self.sql(
            "SELECT extversion FROM pg_extension WHERE extname='pg_durable';"), schema)

    def ready(self):
        self.schema = (
            self.sql("SELECT df.duroxide_schema();")
            if self.sql("SELECT to_regprocedure('df.duroxide_schema()') IS NOT NULL;") == "t"
            else "duroxide"
        )
        if self.schema not in ("duroxide", "_duroxide"):
            raise RuntimeError(f"Unexpected provider schema: {self.schema}")
        deadline = time.monotonic() + self.timeout
        while time.monotonic() < deadline:
            if self.sql(f"SELECT to_regclass('{self.schema}._worker_ready') IS NOT NULL;") == "t":
                if self.sql(f"SELECT EXISTS (SELECT FROM {self.schema}._worker_ready "
                            "WHERE schema_version >= 1);") == "t":
                    return
            time.sleep(0.1)
        raise RuntimeError(f"Worker readiness timed out; see {self.log}")

    def start_cases(self, cohort, waits):
        self.sql("SELECT df.setvar('lifecycle_seed', '41'); "
                 "SELECT df.setvar('lifecycle_increment', '1');", role=ROLE)
        for suffix, waiting in [("completed", False), *[(name, True) for name in waits]]:
            name = f"{cohort}-{suffix}"
            self.sql(
                f"SELECT public.upgrade_lifecycle_start({literal(name)}, "
                f"{'true' if waiting else 'false'});", role=ROLE)
        # A resumed instance must use its captured variables, not the current value.
        self.sql("SELECT df.setvar('lifecycle_seed', '999'); "
                 "SELECT df.setvar('lifecycle_increment', '999');", role=ROLE)

    def release(self, name):
        self.sql(f"SELECT df.signal(instance_id, 'resume', '{{}}') "
                 f"FROM public.upgrade_lifecycle_cases WHERE name={literal(name)};",
                 role=ROLE)
        self.sql(f"UPDATE public.upgrade_lifecycle_cases SET waiting=false "
                 f"WHERE name={literal(name)};")

    def state(self):
        return json.loads(self.sql(f"""
            SELECT coalesce(jsonb_agg(to_jsonb(c) ORDER BY name), '[]'::jsonb)
            FROM (
                SELECT c.*, df.status(c.instance_id) AS status,
                    df.result(c.instance_id) AS result,
                    (SELECT lower(status) FROM df.instance_info(c.instance_id)) AS info_status,
                    EXISTS (SELECT FROM df.list_instances(NULL, 100) l
                            WHERE l.instance_id=c.instance_id) AS listed,
                    lower(e.status) AS engine_status,
                    e.output AS engine_output,
                    EXISTS (SELECT FROM {self.schema}.history h
                            WHERE h.instance_id=c.instance_id
                              AND h.execution_id=i.current_execution_id
                              AND h.event_data::jsonb->>'type'='ExternalSubscribed'
                              AND h.event_data::jsonb->>'name'='resume') AS subscribed,
                    coalesce((SELECT jsonb_agg(jsonb_build_object(
                        'step', m.step, 'value', m.value, 'executed_by', m.executed_by)
                        ORDER BY m.step) FROM public.upgrade_lifecycle_marks m
                        WHERE m.label=c.name), '[]'::jsonb) AS marks
                FROM public.upgrade_lifecycle_cases c
                LEFT JOIN {self.schema}.instances i ON i.instance_id=c.instance_id
                LEFT JOIN {self.schema}.executions e ON e.instance_id=i.instance_id
                    AND e.execution_id=i.current_execution_id
            ) c;
        """, role=ROLE))

    def validate(self, expected_names, completed):
        deadline = time.monotonic() + self.timeout
        while True:
            state = self.state()
            require_equal({case["name"] for case in state}, set(expected_names))
            problems = [f"{case['name']}: {problem}" for case in state
                        for problem in case_problems(case, completed)]
            if not problems:
                for case in state:
                    if not case["waiting"]:
                        completed[case["name"]] = case["result"]
                return state
            if any(case["engine_status"] in ("failed", "cancelled") for case in state):
                raise RuntimeError(f"Instance failed: {json.dumps(state)}")
            if time.monotonic() >= deadline:
                raise RuntimeError(f"Validation timed out: {problems}; state={json.dumps(state)}")
            time.sleep(0.1)


def case_problems(case, completed):
    problems = []
    expected_status = "running" if case["waiting"] else "completed"
    if any(case[key] != expected_status for key in ("status", "engine_status", "info_status")):
        problems.append(f"expected {expected_status} in all monitoring surfaces")
    if not case["listed"]:
        problems.append("missing from df.list_instances")
    expected_marks = [
        {"step": step, "value": 40 + step, "executed_by": ROLE}
        for step in range(1, 2 if case["waiting"] else 3)
    ]
    if case["marks"] != expected_marks:
        problems.append(f"incorrect side effects: {case['marks']}")
    if case["waiting"]:
        if not case["subscribed"]:
            problems.append("signal subscription is not yet durable")
    else:
        result = json.loads(case["result"]) if case["result"] else None
        if result != {"rows": [{"value": 42}], "row_count": 1}:
            problems.append(f"incorrect result: {result}")
        if case["name"] in completed and completed[case["name"]] != case["result"]:
            problems.append("previously completed result changed")
    return problems


def exercise(cluster, previous, current, old_package, new_package, output):
    completed = {}
    names = ["old-completed", "old-b1", "old-b2"]

    def check(phase, binary, schema):
        cluster.versions(binary, schema)
        require_equal(cluster.sql("SELECT df.getvar('lifecycle_increment');", role=ROLE), "999")
        state = cluster.validate(names, completed)
        (output / f"{phase}.json").write_text(json.dumps(state, indent=2) + "\n")
        print(f"{phase}: {len(state)} instances validated (binary {binary}, schema {schema})",
              flush=True)

    cluster.initialize()
    try:
        install(old_package, cluster.prefix)
        cluster.start()
        cluster.sql(f"CREATE EXTENSION pg_durable VERSION {literal(previous)};")
        cluster.ready()
        cluster.versions(previous, previous)
        cluster.sql((PROJECT / "tests/upgrade/lifecycle.sql").read_text())
        cluster.sql(f"GRANT USAGE ON SCHEMA {cluster.schema} TO {ROLE}; "
                    f"GRANT SELECT ON {cluster.schema}.instances, {cluster.schema}.executions, "
                    f"{cluster.schema}.history TO {ROLE};")
        cluster.start_cases("old", ["b1", "b2"])
        check("baseline", previous, previous)

        cluster.stop()
        install(new_package, cluster.prefix)
        cluster.start()
        cluster.ready()
        check("b1-before-resume", current, previous)
        cluster.release("old-b1")
        cluster.start_cases("binary", ["b2"])
        names += ["binary-completed", "binary-b2"]
        check("b1", current, previous)

        cluster.sql(f"ALTER EXTENSION pg_durable UPDATE TO {literal(current)};")
        check("b2-before-resume", current, current)
        cluster.release("old-b2")
        cluster.release("binary-b2")
        cluster.start_cases("schema", [])
        names += ["schema-completed"]
        check("b2", current, current)
    finally:
        cluster.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-config", type=Path, required=True)
    parser.add_argument("--previous-version", required=True)
    parser.add_argument("--output-dir", type=Path, help="New directory for builds, logs and phase results")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.previous_version):
        parser.error("--previous-version must be a release version, e.g. 0.2.8")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")
    output = args.output_dir
    if output is None:
        parent = PROJECT / "target/upgrade-lifecycle"
        parent.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(dir=parent))
    else:
        output = output.resolve()
        output.mkdir(parents=True)
    print(f"Upgrade lifecycle evidence: {output}", flush=True)
    try:
        pg_config = args.pg_config.resolve()
        pg_major = run(pg_config, "--version").split()[1].split(".")[0]
        current = tomllib.loads((PROJECT / "Cargo.toml").read_text())["package"]["version"]
        previous = args.previous_version
        if not (PROJECT / f"sql/pg_durable--{previous}--{current}.sql").is_file():
            raise RuntimeError(f"No direct upgrade script from {previous} to {current}")
        commit = run("git", "rev-parse", "--verify", f"v{previous}^{{commit}}", cwd=PROJECT)
        source = output / "previous-source"
        source.mkdir()
        archive = output / "previous.tar"
        run("git", "archive", "--format=tar", "-o", archive, commit, cwd=PROJECT)
        run("tar", "-xf", archive, "-C", source)
        archive.unlink()
        require_equal(tomllib.loads((source / "Cargo.toml").read_text())["package"]["version"], previous)
        old_package = build(source, output / "previous", pg_config, pg_major)
        new_package = build(PROJECT, output / "candidate", pg_config, pg_major)
        (output / "versions.json").write_text(json.dumps({
            "previous": previous, "previous_commit": commit, "candidate": current,
            "postgres": run(pg_config, "--version"),
        }, indent=2) + "\n")
        prefix = output / "postgres"
        shutil.copytree(pg_config.parent.parent, prefix)
        exercise(Cluster(prefix, output, args.timeout), previous, current,
                 old_package, new_package, output)
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        message = getattr(error, "stderr", None) or str(error)
        (output / "error.txt").write_text(message + "\n")
        print(f"Upgrade lifecycle FAILED: {message}\nSee {output}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
