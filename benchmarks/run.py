#!/usr/bin/env python3

import argparse
from contextlib import ExitStack
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import platform
import re
import signal
import statistics
import subprocess
import sys
import traceback
import uuid

from http_server import HttpFixture


ROOT = Path(__file__).resolve().parent


def positive_int(value):
    number = int(value)
    if number <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def nonnegative_int(value):
    number = int(value)
    if number < 0:
        raise argparse.ArgumentTypeError("must not be negative")
    return number


def summarize(log_files, expected_transactions, output):
    latencies = []
    for log_file in log_files:
        for line in log_file.read_text().splitlines():
            fields = line.split()
            if len(fields) != 6 or not fields[2].isdigit():
                raise ValueError(f"Failed or malformed transaction in {log_file.name}: {line}")
            latencies.append(int(fields[2]) / 1000)
    if len(latencies) != expected_transactions or not latencies:
        raise ValueError(
            f"Expected {expected_transactions} successful transactions, found {len(latencies)}"
        )
    throughput = re.search(r"^tps = ([0-9.]+) \(without initial connection time\)$", output, re.M)
    if throughput is None:
        raise ValueError("pgbench did not report completed-transaction throughput")
    latencies.sort()
    return {
        "transactions": len(latencies),
        "transactions_per_second": float(throughput.group(1)),
        "latency_ms": {
            "min": latencies[0],
            "mean": statistics.fmean(latencies),
            "p50": latencies[math.ceil(len(latencies) * 0.50) - 1],
            "p95": latencies[math.ceil(len(latencies) * 0.95) - 1],
            "p99": latencies[math.ceil(len(latencies) * 0.99) - 1],
            "max": latencies[-1],
        },
    }


def psql(query, variables):
    command = ["psql", "-X", "-w", "-A", "-t", "-v", "ON_ERROR_STOP=1"]
    for name, value in variables.items():
        command.extend(["-v", f"{name}={value}"])
    try:
        return subprocess.run(
            command, input=query, text=True, capture_output=True, check=True,
            timeout=30,
        ).stdout.strip()
    except subprocess.CalledProcessError as error:
        raise RuntimeError(f"psql failed: {error.stderr.strip()}") from error


def cancel_instances(variables):
    responses = json.loads(psql(
        "SELECT coalesce(json_agg(json_build_object('id', id, 'result', "
        "df.cancel(id, 'Benchmark stopped'))), '[]'::json) FROM df.instances "
        "WHERE label = :'run_label' AND lower(status) IN ('pending', 'running');", variables,
    ))
    remaining = json.loads(psql(
        "SELECT coalesce(json_agg(id), '[]'::json) FROM df.instances "
        "WHERE label = :'run_label' AND lower(status) IN ('pending', 'running');", variables,
    ))
    if remaining or any(response["result"].startswith("Failed to cancel:") for response in responses):
        raise RuntimeError(f"Benchmark cancellation failed: responses={responses}, active_instances={remaining}")


def git_output(*arguments):
    try:
        return subprocess.run(
            ["git", "-C", str(ROOT.parent), *arguments], text=True,
            capture_output=True, check=True, timeout=10,
        ).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return None


def run_pgbench(args, directory, script, variables, clients, transactions, name, fixture=None):
    prefix = directory / name
    command = [
        "pgbench", "-n", "-c", str(clients), "-j", str(min(args.jobs, clients)),
        "-t", str(transactions), "-f", f"{script}@1", "-l", "-r",
        "--log-prefix", str(prefix),
    ]
    for key, value in variables.items():
        command.extend(["-D", f"{key}={value}"])
    if fixture:
        before = fixture.snapshot()
        fixture.reset_peak()
    try:
        result = subprocess.run(
            command, text=True, capture_output=True, check=False, stdin=subprocess.DEVNULL,
            timeout=60 + transactions * (args.timeout + 1),
        )
    except subprocess.TimeoutExpired as error:
        prefix.with_suffix(".txt").write_bytes((error.stdout or b"") + (error.stderr or b""))
        raise RuntimeError(f"pgbench exceeded its process deadline; see {prefix.with_suffix('.txt')}") from error
    output = result.stdout + result.stderr
    prefix.with_suffix(".txt").write_text(output)
    if result.returncode:
        raise RuntimeError(f"pgbench failed; see {prefix.with_suffix('.txt')}")
    summary = summarize(
        sorted(directory.glob(f"{name}.[0-9]*")), clients * transactions, result.stdout
    )
    if fixture:
        summary["http"] = {
            key: value - before[key] for key, value in fixture.snapshot().items()
        }
        summary["http"]["peak_active_requests"] = fixture.peak_active
        if summary["http"]["requests"] != clients * transactions or summary["http"]["errors"]:
            raise ValueError(f"HTTP fixture did not observe one successful request per transaction: {summary['http']}")
    summary.update(clients=clients, jobs=min(args.jobs, clients), phase=name)
    return summary


def parser():
    result = argparse.ArgumentParser(description="Benchmark completed pg_durable workflows with pgbench.")
    result.add_argument("--workload", default="sql", help="sql, http, http-multipart, or a pgbench script path")
    result.add_argument("--clients", type=positive_int, nargs="+", default=[1, 8])
    result.add_argument("--jobs", type=positive_int, default=1)
    result.add_argument("--transactions", type=positive_int, default=50, help="Per client, per repetition")
    result.add_argument("--warmup", type=nonnegative_int, default=5, help="Transactions per client, excluded from results")
    result.add_argument("--repeat", type=positive_int, default=3)
    result.add_argument("--timeout", type=positive_int, default=30, help="Workflow timeout in seconds")
    result.add_argument("--poll-ms", type=positive_int, default=1)
    result.add_argument("--http-fixture", action="store_true", help="Also enable the local HTTP target for a custom workload")
    result.add_argument("--request-bytes", type=nonnegative_int, default=1024)
    result.add_argument("--response-bytes", type=nonnegative_int, default=1024)
    result.add_argument("--delay-ms", type=nonnegative_int, default=0, help="HTTP target delay per request")
    result.add_argument("--label", default="", help="Build/configuration label saved with results")
    result.add_argument("--output", type=Path, help="New results directory (default: target/benchmarks/<run ID>)")
    return result


def benchmark(args):
    if len(set(args.clients)) != len(args.clients):
        raise ValueError("--clients values must be unique")
    workload = Path(args.workload)
    if not workload.is_file():
        workload = ROOT / "workloads" / f"{args.workload}.sql"
    source = workload.read_text()
    use_http = args.http_fixture or workload.resolve() in {
        ROOT / "workloads" / "http.sql", ROOT / "workloads" / "http-multipart.sql",
    }
    run_id = uuid.uuid4().hex
    directory = (args.output or ROOT.parent / "target" / "benchmarks" / run_id).resolve()
    dirty = git_output("status", "--porcelain", "--untracked-files=all")
    source_metadata = {
        "revision": git_output("rev-parse", "HEAD"),
        "dirty": None if dirty is None else bool(dirty),
    }
    directory.mkdir(parents=True, exist_ok=False)
    variables = {
        "bench_schema": f"pgd_bench_{run_id}",
        "run_label": f"pgd-bench-{run_id}",
        "timeout_seconds": args.timeout,
        "poll_ms": args.poll_ms,
        "request_bytes": args.request_bytes,
    }
    script = directory / "workload.sql"
    script.write_text(source + "\nSELECT :bench_schema.await(':instance_id', :timeout_seconds, :poll_ms);\n")
    setup = (ROOT / "await.sql").read_text()
    (directory / "await.sql").write_text(setup)
    report = {
        "format_version": 1,
        "run_id": run_id,
        "started_at": datetime.now(timezone.utc).isoformat(),
        "label": args.label,
        "workload": str(workload.resolve()),
        "source": source_metadata,
        "parameters": {key: value for key, value in vars(args).items() if key != "output"},
        "status": "running",
        "runs": [],
    }
    (directory / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Results: {directory}", flush=True)
    try:
        with ExitStack() as cleanup:
            report["database"] = json.loads(psql(
                "SELECT json_build_object('postgres', version(), 'pg_durable', df.version(), "
                "'database', current_database(), 'instances_at_start', (SELECT count(*) FROM df.instances), "
                "'settings', (SELECT json_object_agg(name, json_build_object('value', setting, 'unit', unit)) "
                "FROM pg_settings WHERE name LIKE 'pg_durable.%' OR name IN "
                "('max_connections', 'max_worker_processes', 'shared_buffers', 'work_mem', "
                "'fsync', 'synchronous_commit', 'full_page_writes', 'jit')));", variables,
            ))
            report["pgbench"] = subprocess.run(
                ["pgbench", "--version"], text=True, capture_output=True, check=True,
            ).stdout.strip()
            report["machine"] = {
                "platform": platform.platform(), "python": platform.python_version(),
                "logical_cpus": os.cpu_count(),
            }
            fixture = None
            if use_http:
                fixture = cleanup.enter_context(HttpFixture(args.response_bytes, args.delay_ms))
                variables["http_url"] = fixture.url
                report["http_fixture"] = {
                    "url": fixture.url, "response_bytes": args.response_bytes, "delay_ms": args.delay_ms,
                }
                print("Loopback HTTP requires pg_durable.http_security = 'unrestricted' on a development server.", flush=True)
            psql(setup, variables)
            cleanup.callback(psql, 'DROP SCHEMA :"bench_schema" CASCADE;', variables)
            cleanup.callback(cancel_instances, variables)
            for clients in args.clients:
                if args.warmup:
                    run_pgbench(
                        args, directory, script, variables, clients, args.warmup,
                        f"c{clients}-warmup", fixture,
                    )
                for repetition in range(1, args.repeat + 1):
                    summary = run_pgbench(
                        args, directory, script, variables, clients, args.transactions,
                        f"c{clients}-r{repetition}", fixture,
                    )
                    report["runs"].append(summary)
                    print(
                        f"clients={clients} repetition={repetition}: "
                        f"{summary['transactions_per_second']:.2f} workflows/s, "
                        f"p50={summary['latency_ms']['p50']:.2f} ms, "
                        f"p95={summary['latency_ms']['p95']:.2f} ms",
                        flush=True,
                    )
        report["status"] = "completed"
    except BaseException as error:
        report["status"] = "failed"
        report["error"] = "".join(traceback.format_exception(type(error), error, error.__traceback__))
        raise
    finally:
        (directory / "results.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def terminate(signum, frame):
    raise SystemExit(128 + signum)


def main():
    os.environ.setdefault("PGCONNECT_TIMEOUT", "10")
    os.environ["LC_ALL"] = "C"
    previous_sigterm = signal.signal(signal.SIGTERM, terminate)
    try:
        benchmark(parser().parse_args())
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(f"Benchmark failed: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1
    finally:
        signal.signal(signal.SIGTERM, previous_sigterm)
    return 0


if __name__ == "__main__":
    sys.exit(main())