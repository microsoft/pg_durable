#!/usr/bin/env python3
"""Alternating B1/B2 upgrade-chain checks in an isolated PostgreSQL installation."""

import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import time
import tomllib


PROJECT = Path(__file__).resolve().parents[1]
VERSIONS = ("0.2.2", "0.2.5", "0.2.7", "0.2.9")


def phases():
    yield {"phase": 1, "scenario": "baseline", "binary": VERSIONS[0], "schema": VERSIONS[0]}
    for previous, current in zip(VERSIONS, VERSIONS[1:]):
        yield {"phase": 2, "scenario": "B1", "binary": current, "schema": previous}
        yield {"phase": 1, "scenario": "B2", "binary": current, "schema": current}


def run(*args, cwd=None, env=None):
    return subprocess.run(
        [str(arg) for arg in args], cwd=cwd, env=env, check=True,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout.strip()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def export_source(ref, destination):
    commit = run("git", "rev-parse", f"{ref}^{{commit}}", cwd=PROJECT)
    destination.mkdir(parents=True, exist_ok=True)
    with subprocess.Popen(["git", "archive", commit], cwd=PROJECT, stdout=subprocess.PIPE) as archive:
        subprocess.run(["tar", "-x", "-C", str(destination)], stdin=archive.stdout, check=True)
        archive.stdout.close()
        if archive.wait() != 0:
            raise RuntimeError(f"Could not export {ref}")
    return commit


def build_package(source, output, pg_config, target_dir):
    output.mkdir(parents=True)
    lock_hash = digest(source / "Cargo.lock")
    environment = dict(os.environ, CARGO_TARGET_DIR=str(target_dir))
    command = [
        "cargo", "pgrx", "package", "--debug", "--pg-config", str(pg_config),
        "--no-default-features", "--features", "pg17", "--out-dir", str(output / "package"),
    ]
    with (output / "build.log").open("w") as log:
        subprocess.run(
            command, cwd=source, env=environment, stdout=log,
            stderr=subprocess.STDOUT, check=True,
        )
    if digest(source / "Cargo.lock") != lock_hash:
        raise RuntimeError(f"Build changed the pinned lockfile: {source}")
    libraries = list((output / "package").rglob("pg_durable.so"))
    if len(libraries) != 1:
        raise RuntimeError(f"Expected one shared library in {output}")
    manifest = tomllib.loads((source / "Cargo.toml").read_text())
    provenance = {
        "version": manifest["package"]["version"],
        "lock_sha256": lock_hash,
        "library_sha256": digest(libraries[0]),
        "postgres": run(pg_config, "--version"),
        "rustc": run("rustc", "--version", cwd=source),
        "features": ["pg17"],
        "profile": "debug",
    }
    return provenance


def install_package(package, prefix):
    config = prefix / "bin" / "pg_config"
    library_dir = Path(run(config, "--pkglibdir"))
    extension_dir = Path(run(config, "--sharedir")) / "extension"
    for directory in (library_dir, extension_dir):
        if not directory.resolve().is_relative_to(prefix.resolve()):
            raise RuntimeError(f"PostgreSQL installation did not relocate: {directory}")
    libraries = list(package.rglob("pg_durable.so"))
    controls = list(package.rglob("pg_durable.control"))
    if len(libraries) != 1 or len(controls) != 1:
        raise RuntimeError(f"Incomplete or ambiguous package: {package}")
    shutil.copy2(libraries[0], library_dir / "pg_durable.so")
    for source in controls[0].parent.glob("pg_durable*"):
        if source.suffix in (".sql", ".control"):
            shutil.copy2(source, extension_dir / source.name)


def require_version(actual, expected):
    if actual != expected:
        raise RuntimeError(f"Expected extension {expected}, got {actual}")


def source_digest(source):
    files = []
    for name in ("Cargo.toml", "Cargo.lock", "build.rs", "pg_durable.control", "rust-toolchain.toml", "src", "sql"):
        path = source / name
        files.extend(sorted(path.rglob("*")) if path.is_dir() else [path])
    return hashlib.sha256("\n".join(
        f"{path.relative_to(source)}:{digest(path)}"
        for path in files if path.is_file()
    ).encode()).hexdigest()


def prepare_artifact(source, output, commit, pg_config, target_dir):
    source_hash = source_digest(source)
    metadata = output / "provenance.json"
    if metadata.exists():
        provenance = json.loads(metadata.read_text())
        if provenance["source_sha256"] != source_hash or provenance["commit"] != commit:
            raise RuntimeError(f"Source changed; use a new output directory: {output}")
        if provenance["postgres"] != run(pg_config, "--version") or provenance["rustc"] != run("rustc", "--version", cwd=source):
            raise RuntimeError(f"Build toolchain changed; use a new output directory: {output}")
        for name, expected in provenance["package_sha256"].items():
            if digest(output / "package" / name) != expected:
                raise RuntimeError(f"Cached artifact changed: {name}")
        return provenance
    if output.exists():
        raise RuntimeError(f"Incomplete previous build; use a new output directory: {output}")
    print(f"Building {source.name}; log: {output / 'build.log'}", flush=True)
    provenance = build_package(source, output, pg_config, target_dir)
    provenance.update(commit=commit, source_sha256=source_hash)
    provenance["package_sha256"] = {
        str(path.relative_to(output / "package")): digest(path)
        for path in sorted((output / "package").rglob("*")) if path.is_file()
    }
    shutil.copy2(source / "Cargo.lock", output / "Cargo.lock")
    write_json(metadata, provenance)
    return provenance


def sql_literal(value):
    return "'" + value.replace("'", "''") + "'"


def check_live_progress(case, previous_count, current_count):
    problems = []
    if case["engine_status"] != "running" or case["df_status"] != "running":
        problems.append(f"expected running, engine={case['engine_status']}, df={case['df_status']}")
    if current_count <= previous_count:
        problems.append(f"no progress: {previous_count} -> {current_count}")
    return problems


class Cluster:
    def __init__(self, prefix, directory):
        self.prefix = prefix
        self.directory = directory
        self.data = directory / "data"
        self.log = directory / "postgres.log"
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            self.port = listener.getsockname()[1]

    def initialize(self):
        self.directory.mkdir(parents=True)
        run(self.prefix / "bin/initdb", "-D", self.data, "-U", "postgres", "--no-locale", "-A", "trust")

    def start(self):
        options = (
            f"-p {self.port} -c listen_addresses=127.0.0.1 -c unix_socket_directories='' "
            "-c shared_preload_libraries=pg_durable -c pg_durable.worker_role=postgres "
            "-c pg_durable.database=postgres -c pg_durable.enable_superuser_instances=on "
            "-c log_min_messages=info"
        )
        run(self.prefix / "bin/pg_ctl", "-D", self.data, "-l", self.log, "-w", "-t", "60", "-o", options, "start",
            env=dict(os.environ, PGHOST="127.0.0.1", PGPORT=str(self.port)))

    def stop(self):
        if (self.data / "postmaster.pid").exists():
            run(self.prefix / "bin/pg_ctl", "-D", self.data, "-w", "-t", "60", "-m", "fast", "stop")

    def sql(self, statement, variables=None):
        command = [
            str(self.prefix / "bin/psql"), "-X", "-qAt", "-h", "127.0.0.1", "-p", str(self.port),
            "-U", "postgres", "-d", "postgres", "-v", "ON_ERROR_STOP=1",
        ]
        for name, value in (variables or {}).items():
            command.extend(["-v", f"{name}={value}"])
        result = subprocess.run(
            command, input=statement, text=True, check=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=30,
            env=dict(os.environ, PGOPTIONS="-c statement_timeout=20000", PSQL_PAGER="cat"),
        )
        return result.stdout.strip()

    def rows(self, query):
        return json.loads(self.sql(f"SELECT coalesce(jsonb_agg(row_to_json(replay_row)), '[]') FROM ({query}) replay_row;"))

    def schema(self):
        return self.sql("SELECT nspname FROM pg_namespace WHERE nspname IN ('duroxide', '_duroxide') AND to_regclass(quote_ident(nspname) || '.history') IS NOT NULL;")

    def ready(self, timeout):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            schema = self.schema()
            if schema in ("duroxide", "_duroxide"):
                ready = self.sql(f"SELECT to_regclass('{schema}._worker_ready') IS NOT NULL;")
                if ready == "t" and self.sql(f"SELECT count(*) FROM {schema}._worker_ready;") == "1":
                    return schema
            time.sleep(0.1)
        raise RuntimeError(f"Worker not ready; see {self.log}")

    def state(self, schema):
        return {
            "extension_version": self.sql("SELECT extversion FROM pg_extension WHERE extname = 'pg_durable';"),
            "cases": self.rows(f"""
                SELECT c.name, c.kind, c.created_phase, c.instance_id, lower(e.status) AS engine_status,
                       i.current_execution_id, e.output AS engine_output,
                       df.status(c.instance_id) AS df_status, df.result(c.instance_id) AS result
                FROM replay_cases c
                LEFT JOIN {schema}.instances i ON i.instance_id = c.instance_id
                LEFT JOIN {schema}.executions e ON e.instance_id = i.instance_id
                     AND e.execution_id = i.current_execution_id ORDER BY c.name
            """),
            "marks": self.rows("SELECT label, count(*) AS count FROM replay_marks GROUP BY label ORDER BY label"),
        }

    def diagnostics(self, schema, directory):
        for table in ("instances", "executions", "history", "orchestrator_queue", "worker_queue"):
            write_json(directory / f"{table}.json", self.rows(f"SELECT * FROM {schema}.{table}"))
        write_json(directory / "state.json", self.state(schema))

    def inspect(self, instance_id):
        literal = sql_literal(instance_id)
        details = {
            "info": self.rows(f"SELECT * FROM df.instance_info({literal})"),
            "nodes": self.rows(f"SELECT * FROM df.instance_nodes({literal})"),
            "executions": self.rows(f"SELECT * FROM df.instance_executions({literal})"),
            "explain": self.sql(f"SELECT df.explain({literal});"),
        }
        if not all(details.values()):
            raise RuntimeError(f"Empty diagnostic output for {instance_id}")
        return details


def check_finite(case, count, previous_result=None):
    problems = []
    if case["engine_status"] != "completed" or case["df_status"] != "completed":
        problems.append(f"engine={case['engine_status']}, df={case['df_status']}")
    if count != 1:
        problems.append(f"expected one side effect, got {count}")
    try:
        result = json.loads(case["result"]) if case["result"] else None
    except (ValueError, TypeError):
        result = None
    if result != {"rows": [{"value": "done"}], "row_count": 1}:
        problems.append("incorrect finite result")
    if previous_result is not None and previous_result != case["result"]:
        problems.append("completed result changed")
    return problems


def record_failure(failures, name, phase, problems):
    if problems and name not in failures:
        failures[name] = {"phase": phase, "problems": problems}


def known_break(case, phase, problems):
    return (
        phase == "01-0.2.5-phase2"
        and case["name"] == "00-0.2.2-phase1-live"
        and case["engine_status"] == "failed"
        and (case.get("engine_output") or "").startswith("nondeterministic: schedule mismatch:")
        and 'name: "pg_durable::activity::update-node-status"' in case["engine_output"]
        and len(problems) == 2
        and problems[0].startswith("expected running, engine=failed")
        and problems[1].startswith("no progress:")
    )


def exit_status(report, allow_known_breaks=False):
    if report["errors"] or len(report["outcomes"]) != len(list(phases())):
        return 2
    statuses = {case["outcome"] for phase in report["outcomes"] for case in phase["cases"]}
    return int("failure" in statuses or ("known_break" in statuses and not allow_known_breaks))


def validate_phase(cluster, schema, phase, timeout, observe_seconds, failures, completed, directory):
    before = cluster.state(schema)
    if not before["cases"]:
        raise RuntimeError("Empty fixture suite")
    counts = {item["label"]: item["count"] for item in before["marks"]}
    write_json(directory / "before.json", before)
    deadline = time.monotonic() + timeout
    observe_until = time.monotonic() + observe_seconds
    while True:
        state = cluster.state(schema)
        marks = {item["label"]: item["count"] for item in state["marks"]}
        checks = {}
        for case in state["cases"]:
            name = case["name"]
            if name in failures:
                continue
            if case["kind"] == "live":
                checks[name] = check_live_progress(case, counts.get(name, 0), marks.get(name, 0))
            else:
                checks[name] = check_finite(case, marks.get(name, 0), completed.get(name))
        pending = [case for case in state["cases"] if checks.get(case["name"]) and case["engine_status"] not in ("failed", "cancelled")]
        if (not pending and time.monotonic() >= observe_until) or time.monotonic() >= deadline:
            break
        time.sleep(0.1)
    outcomes = []
    listed = cluster.rows("SELECT * FROM df.list_instances(NULL, 100)")
    write_json(directory / "list_instances.json", listed)
    for case in state["cases"]:
        name = case["name"]
        prior_failure = failures.get(name)
        problems = checks.get(name, [])
        try:
            details = cluster.inspect(case["instance_id"])
            write_json(directory / f"{name}-debug.json", details)
            if case["instance_id"] not in {item["instance_id"] for item in listed}:
                problems.append("missing from df.list_instances")
        except (RuntimeError, subprocess.SubprocessError) as error:
            problems.append(f"inspection failed: {getattr(error, 'stderr', None) or error}")
        record_failure(failures, name, phase, problems)
        if not problems and not prior_failure and case["kind"] == "finite":
            completed[name] = case["result"]
        outcome = "previously_failed" if prior_failure else "passed"
        if problems:
            outcome = "known_break" if known_break(case, phase, problems) else "failure"
        outcomes.append(dict(case, before_count=counts.get(name, 0), after_count=marks.get(name, 0),
                             problems=problems, prior_failure=prior_failure, outcome=outcome))
    return outcomes


def exercise_chain(artifacts, prefix, directory, timeout, observe_seconds, report, report_path):
    cluster = Cluster(prefix, directory)
    cluster.initialize()
    failures = {}
    completed = {}
    schema = None
    phase_dir = directory
    try:
        for index, phase in enumerate(phases()):
            name = f"{index:02d}-{phase['binary']}-phase{phase['phase']}"
            phase_dir = directory / name
            phase_dir.mkdir()
            print(f"Testing {name}: {phase['scenario']}, schema {phase['schema']}", flush=True)
            if phase["scenario"] != "B2":
                cluster.stop()
                artifact = "candidate" if phase["binary"] == VERSIONS[-1] else phase["binary"]
                install_package(artifacts / artifact / "package", prefix)
                cluster.start()
                if index == 0:
                    cluster.sql("CREATE EXTENSION pg_durable VERSION '0.2.2';")
            else:
                cluster.sql(f"ALTER EXTENSION pg_durable UPDATE TO {sql_literal(phase['schema'])};")
            schema = cluster.ready(timeout)
            require_version(cluster.sql("SELECT extversion FROM pg_extension WHERE extname = 'pg_durable';"), phase["schema"])
            cluster.sql((PROJECT / "tests/upgrade/replay.sql").read_text(), {"cohort": name})
            phase_result = dict(phase, name=name)
            phase_result["cases"] = validate_phase(cluster, schema, name, timeout, observe_seconds, failures, completed, phase_dir)
            if len(phase_result["cases"]) != 2 * (index + 1):
                raise RuntimeError(f"Missing or extra workflow instances in {name}")
            cluster.diagnostics(schema, phase_dir)
            report["outcomes"].append(phase_result)
            report["first_failures"] = failures
            write_json(report_path, report)
    except BaseException:
        if schema and (cluster.data / "postmaster.pid").exists():
            try:
                cluster.diagnostics(schema, phase_dir)
            except (RuntimeError, OSError, subprocess.SubprocessError) as error:
                report["errors"].append({"diagnostics": str(error)})
        raise
    finally:
        cluster.stop()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pg-config", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=45)
    parser.add_argument("--observe-seconds", type=float, default=3)
    parser.add_argument("--allow-known-breaks", action="store_true",
                        help="Accept only the documented 0.2.2 -> 0.2.5 update-node-status replay failure")
    parser.add_argument("--build-only", action="store_true")
    args = parser.parse_args()
    if not (math.isfinite(args.timeout) and math.isfinite(args.observe_seconds) and 1 < args.observe_seconds < args.timeout):
        parser.error("Require 1 < --observe-seconds < --timeout, both finite")
    output = args.output_dir.resolve()
    pg_config = args.pg_config.resolve()
    output.mkdir(parents=True, exist_ok=True)
    artifacts = output / "artifacts"
    target_dir = PROJECT / "target"
    provenance = {}
    report = {"outcomes": [], "errors": [], "provenance": provenance,
              "allow_known_breaks": args.allow_known_breaks, "observe_seconds": args.observe_seconds,
              "fixture_sha256": digest(PROJECT / "tests/upgrade/replay.sql"),
              "runner_sha256": digest(Path(__file__)), "timeout": args.timeout}
    try:
        postgres_version = run(pg_config, "--version")
        if not postgres_version.startswith("PostgreSQL 17."):
            raise RuntimeError("This initial suite supports PostgreSQL 17 only")
        for version in VERSIONS[:-1]:
            source = output / "sources" / version
            commit = run("git", "rev-parse", f"v{version}^{{commit}}", cwd=PROJECT)
            if not (source / "Cargo.lock").exists():
                export_source(f"v{version}", source)
            provenance[version] = prepare_artifact(source, artifacts / version, commit, pg_config, target_dir)
        provenance["candidate"] = prepare_artifact(
            PROJECT, artifacts / "candidate", run("git", "rev-parse", "HEAD", cwd=PROJECT), pg_config, target_dir,
        )
        require_version(provenance["candidate"]["version"], "0.2.9")
        if args.build_only:
            report["build_only"] = True
            report["exit_status"] = 0
            return 0
        prefix = output / "postgres"
        if not prefix.exists():
            shutil.copytree(pg_config.parent.parent, prefix, symlinks=True)
        run_dir = output / "runs" / str(time.time_ns())
        report["run_directory"] = str(run_dir)
        exercise_chain(artifacts, prefix, run_dir, args.timeout, args.observe_seconds, report, output / "report.json")
        for outcome in report["outcomes"]:
            failed = sum(bool(case["problems"]) for case in outcome["cases"])
            known = sum(case["outcome"] == "known_break" for case in outcome["cases"])
            print(f"{outcome['name']}: {len(outcome['cases'])} instances inspected, {failed} failing checks ({known} known breaks)")
        report["exit_status"] = exit_status(report, args.allow_known_breaks)
        return report["exit_status"]
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        message = getattr(error, "stderr", None) or str(error)
        if isinstance(message, bytes):
            message = message.decode(errors="replace")
        report["errors"].append({"error": message})
        report["exit_status"] = 2
        return 2
    finally:
        write_json(output / "report.json", report)
        print(f"Report: {output / 'report.json'}", flush=True)
        for error in report["errors"]:
            print(error, file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())