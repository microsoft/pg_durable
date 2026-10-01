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

# Behavior families, each exercised by an N-1 instance suspended inside that
# structure and resumed under both the B1 (new binary / old schema) and B2
# (new binary / new schema) boundaries. Every #410 combinator plus the explicit
# else and break seeds is represented; df.sql is exercised by every shape.
FAMILIES = ["seq", "if-then", "if-else", "loop", "break", "join", "race"]

# Exact marker counts per structural path while the instance is still suspended
# ("before") and after it resumes and completes ("after"). Paths absent from a
# map are expected to have zero rows, so an unrun branch, a cancelled race loser,
# or a replayed duplicate is rejected. "captured" asserts that a completed value
# reused the pre-suspension variable capture; "result" pins the instance output.
SHAPES = {
    "seq": {"before": {"r.0": 1}, "after": {"r.0": 1, "r.1": 1},
            "before_values": {"r.0": [41]}, "after_values": {"r.0": [41]},
            "captured": {"r.1": 42},
            "result": {"rows": [{"value": 42}], "row_count": 1}},
    "if-then": {"before": {"r.t.0": 1}, "after": {"r.t.0": 1, "r.t.1": 1}},
    "if-else": {"before": {"r.e.0": 1}, "after": {"r.e.0": 1, "r.e.1": 1}},
    "loop": {"before": {"r.b": 1}, "after": {"r.b": 2, "r.c": 2}},
    "break": {"before": {"r.0": 1}, "after": {"r.0": 3},
              "before_values": {"r.0": [1]}, "after_values": {"r.0": [1, 2, 3]}},
    "join": {"before": {"r.0": 1, "r.b": 1}, "after": {"r.0": 1, "r.b": 1, "r.1": 1}},
    "race": {"before": {"r.w": 1}, "after": {"r.w": 1, "r.w2": 1}},
}


def path_counts(marks):
    counts = {}
    for mark in marks:
        counts[mark["path"]] = counts.get(mark["path"], 0) + 1
    return counts


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

    def set_vars(self, seed, increment):
        self.sql(f"SELECT df.setvar('lifecycle_seed', {literal(str(seed))}); "
                 f"SELECT df.setvar('lifecycle_increment', {literal(str(increment))});",
                 role=ROLE)

    def start_case(self, name, shape, waiting):
        self.sql(f"SELECT public.upgrade_lifecycle_start({literal(name)}, {literal(shape)}, "
                 f"{'true' if waiting else 'false'});", role=ROLE)

    def seed_families(self):
        # Capture 41/1 into every waiting instance, then move the live variables
        # so a correct resume must reuse the captured values, not the current ones.
        self.set_vars(41, 1)
        for family in FAMILIES:
            self.start_case(f"{family}-b1", family, True)
            self.start_case(f"{family}-b2", family, True)
        self.set_vars(999, 999)

    def start_sequence(self, name, waiting=False):
        self.set_vars(41, 1)
        self.start_case(name, "seq", waiting)
        self.set_vars(999, 999)

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
                    loser.instance_id AS race_loser_id,
                    lower(loser_e.status) AS race_loser_status,
                    EXISTS (SELECT FROM {self.schema}.history h
                            WHERE h.instance_id=loser.instance_id
                              AND h.execution_id=loser.current_execution_id
                              AND h.event_data::jsonb->>'type'='TimerCreated')
                        AS race_loser_timer_created,
                    -- Duroxide persists cancellation as an application failure,
                    -- not a separate execution status.
                    EXISTS (SELECT FROM {self.schema}.history h
                            WHERE h.instance_id=loser.instance_id
                              AND h.execution_id=loser.current_execution_id
                              AND h.event_data::jsonb->>'type'='OrchestrationFailed'
                              AND h.event_data::jsonb
                                  #> '{{details,Application,kind,Cancelled}}' IS NOT NULL)
                        AS race_loser_cancelled,
                    -- The 'resume' subscription is durable in the root execution
                    -- for simple shapes, or in a spawned join/race branch whose
                    -- child instance id is prefixed with the root id.
                    EXISTS (SELECT FROM {self.schema}.history h
                            WHERE ((h.instance_id=c.instance_id
                                    AND h.execution_id=i.current_execution_id)
                                   OR h.instance_id LIKE c.instance_id || '::%')
                              AND h.event_data::jsonb->>'type'='ExternalSubscribed'
                              AND h.event_data::jsonb->>'name'='resume') AS subscribed,
                    coalesce((SELECT jsonb_agg(jsonb_build_object(
                        'path', m.path, 'occurrence', m.occurrence,
                        'value', m.value, 'executed_by', m.executed_by)
                        ORDER BY m.path, m.occurrence) FROM public.upgrade_lifecycle_marks m
                        WHERE m.label=c.name), '[]'::jsonb) AS marks
                FROM public.upgrade_lifecycle_cases c
                LEFT JOIN {self.schema}.instances i ON i.instance_id=c.instance_id
                LEFT JOIN {self.schema}.executions e ON e.instance_id=i.instance_id
                    AND e.execution_id=i.current_execution_id
                LEFT JOIN df.nodes race ON c.shape='race'
                    AND race.instance_id=c.instance_id AND race.node_type='RACE'
                LEFT JOIN {self.schema}.instances loser ON loser.instance_id=
                    c.instance_id || '::' || i.current_execution_id::text || '::' || race.right_node
                LEFT JOIN {self.schema}.executions loser_e ON loser_e.instance_id=loser.instance_id
                    AND loser_e.execution_id=loser.current_execution_id
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
    shape = SHAPES[case["shape"]]
    waiting = case["waiting"]
    expected_status = "running" if waiting else "completed"
    if any(case[key] != expected_status for key in ("status", "engine_status", "info_status")):
        problems.append(f"expected {expected_status} in all monitoring surfaces")
    if not case["listed"]:
        problems.append("missing from df.list_instances")
    expected_counts = shape["before"] if waiting else shape["after"]
    actual_counts = path_counts(case["marks"])
    if actual_counts != expected_counts:
        problems.append(f"incorrect marker counts: {actual_counts} != {expected_counts}")
    if any(mark["executed_by"] != ROLE for mark in case["marks"]):
        problems.append("marker executed by unexpected role")
    for path, expected in shape.get("before_values" if waiting else "after_values", {}).items():
        values = [mark["value"] for mark in case["marks"] if mark["path"] == path]
        if values != expected:
            problems.append(f"incorrect marker values at {path}: {values} != {expected}")
    if case["shape"] == "race":
        if not case["race_loser_id"]:
            problems.append("race loser child is missing")
        if not case["race_loser_timer_created"]:
            problems.append("race loser timer is not yet durable")
        if waiting:
            if case["race_loser_status"] != "running" or case["race_loser_cancelled"]:
                problems.append("race loser must still be running before resume")
        elif case["race_loser_status"] != "failed" or not case["race_loser_cancelled"]:
            problems.append("race loser cancellation is not yet terminal")
    if waiting:
        if not case["subscribed"]:
            problems.append("signal subscription is not yet durable")
    else:
        for path, value in shape.get("captured", {}).items():
            values = [mark["value"] for mark in case["marks"] if mark["path"] == path]
            if values != [value]:
                problems.append(f"captured value at {path}: {values} != {[value]}")
        expected_result = shape.get("result")
        if expected_result is not None:
            result = json.loads(case["result"]) if case["result"] else None
            if result != expected_result:
                problems.append(f"incorrect result: {result}")
        if case["name"] in completed and completed[case["name"]] != case["result"]:
            problems.append("previously completed result changed")
    return problems


def exercise(cluster, previous, current, old_package, new_package, output):
    completed = {}
    names = [f"{family}-b1" for family in FAMILIES] + [f"{family}-b2" for family in FAMILIES]

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
        # Baseline: every family holds two N-1 instances at a durable suspension,
        # plus a completed seq instance to track a byte-identical result.
        cluster.seed_families()
        cluster.start_sequence("seq-done-baseline")
        names += ["seq-done-baseline"]
        check("baseline", previous, previous)

        # B1: also create new-binary history to resume across the schema upgrade.
        cluster.stop()
        install(new_package, cluster.prefix)
        cluster.start()
        cluster.ready()
        check("b1-before-resume", current, previous)
        for family in FAMILIES:
            cluster.release(f"{family}-b1")
        cluster.start_sequence("seq-done-b1")
        cluster.start_sequence("seq-binary-b2", waiting=True)
        names += ["seq-done-b1", "seq-binary-b2"]
        check("b1", current, previous)

        # B2: new binary, new schema. Resume every -b2 case and start a fresh one.
        cluster.sql(f"ALTER EXTENSION pg_durable UPDATE TO {literal(current)};")
        check("b2-before-resume", current, current)
        for family in FAMILIES:
            cluster.release(f"{family}-b2")
        cluster.release("seq-binary-b2")
        cluster.start_sequence("seq-done-b2")
        names += ["seq-done-b2"]
        check("b2", current, current)
    finally:
        cluster.stop()


def materialize_previous(output, previous):
    """Extract the previous release's source tree from its git tag.

    Returns ``(source_dir, commit)``. Shared by the lifecycle and the canary so
    the N-1 tree is prepared the same way whether it is built here or built once
    and reused across several lifecycle runs.
    """
    commit = run("git", "rev-parse", "--verify", f"v{previous}^{{commit}}", cwd=PROJECT)
    source = output / "previous-source"
    source.mkdir()
    archive = output / "previous.tar"
    run("git", "archive", "--format=tar", "-o", archive, commit, cwd=PROJECT)
    run("tar", "-xf", archive, "-C", source)
    archive.unlink()
    require_equal(tomllib.loads((source / "Cargo.toml").read_text())["package"]["version"], previous)
    return source, commit


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-config", type=Path, required=True)
    parser.add_argument("--previous-version", required=True)
    parser.add_argument("--previous-package", type=Path,
                        help="Prebuilt N-1 package dir to reuse instead of rebuilding it")
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
        if args.previous_package:
            old_package = args.previous_package.resolve()
            commit = run("git", "rev-parse", "--verify", f"v{previous}^{{commit}}", cwd=PROJECT)
        else:
            source, commit = materialize_previous(output, previous)
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
