from concurrent.futures import ThreadPoolExecutor
from contextlib import redirect_stderr, redirect_stdout
from http.client import HTTPConnection
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

from http_server import HttpFixture
from run import benchmark, cancel_instances, parser, psql, run_pgbench, summarize


class SummaryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.log = Path(self.directory.name) / "pgbench.123"
        self.output = "tps = 12.500000 (without initial connection time)\n"

    def test_latency_units_and_nearest_rank_percentiles(self):
        self.log.write_text("0 1 4000 0 100 0\n0 2 1000 0 100 0\n0 3 2000 0 100 0\n")
        result = summarize([self.log], 3, self.output)
        self.assertEqual(result["transactions"], 3)
        self.assertEqual(result["transactions_per_second"], 12.5)
        self.assertEqual(result["latency_ms"]["p50"], 2)
        self.assertEqual(result["latency_ms"]["p95"], 4)
        self.assertAlmostEqual(result["latency_ms"]["mean"], 7 / 3)

    def test_failed_and_incomplete_runs_are_not_successful_samples(self):
        for content in ("0 1 failed 0 100 0\n", "0 1 skipped 0 100 0\n", "", "bad record\n"):
            with self.subTest(content=content), self.assertRaises(ValueError):
                self.log.write_text(content)
                summarize([self.log], 1, self.output)

    def test_missing_throughput_is_not_reported_as_zero(self):
        self.log.write_text("0 1 1000 0 100 0\n")
        with self.assertRaisesRegex(ValueError, "throughput"):
            summarize([self.log], 1, "")

    def test_multiple_client_logs(self):
        other_log = self.log.with_suffix(".456")
        self.log.write_text("0 1 1000 0 100 0\n")
        other_log.write_text("1 1 3000 0 100 0\n")
        self.assertEqual(summarize([self.log, other_log], 2, self.output)["latency_ms"]["mean"], 2)

    def test_pgbench_output_is_not_read_as_a_transaction_log(self):
        self.log.write_text("0 1 1000 0 100 0\n")
        result = subprocess.CompletedProcess([], 0, self.output, "")
        with patch("run.subprocess.run", return_value=result):
            summary = run_pgbench(
                parser().parse_args([]), self.log.parent, Path("workload.sql"),
                {}, 1, 1, "pgbench",
            )
        self.assertEqual(summary["transactions"], 1)
        self.assertEqual(self.log.with_suffix(".txt").read_text(), self.output)

    def test_nonzero_exit_is_not_a_successful_measurement(self):
        self.log.write_text("0 1 1000 0 100 0\n")
        result = subprocess.CompletedProcess([], 2, self.output, "aborted")
        with patch("run.subprocess.run", return_value=result), self.assertRaisesRegex(RuntimeError, "pgbench failed"):
            run_pgbench(parser().parse_args([]), self.log.parent, Path("workload.sql"), {}, 1, 1, "pgbench")
        self.assertIn("aborted", self.log.with_suffix(".txt").read_text())

    def test_process_deadline_retains_partial_output(self):
        error = subprocess.TimeoutExpired("pgbench", 60, output=b"partial output", stderr=b"blocked")
        with patch("run.subprocess.run", side_effect=error), self.assertRaisesRegex(RuntimeError, "deadline"):
            run_pgbench(parser().parse_args([]), self.log.parent, Path("workload.sql"), {}, 1, 1, "pgbench")
        self.assertEqual(self.log.with_suffix(".txt").read_text(), "partial outputblocked")

    def test_http_request_mismatch_is_not_a_successful_measurement(self):
        self.log.write_text("0 1 1000 0 100 0\n")
        result = subprocess.CompletedProcess([], 0, self.output, "")
        for requests in (0, 2):
            fixture = Mock(peak_active=1)
            fixture.snapshot.side_effect = [
                {"requests": 0, "errors": 0}, {"requests": requests, "errors": 0},
            ]
            with self.subTest(requests=requests), patch("run.subprocess.run", return_value=result):
                with self.assertRaisesRegex(ValueError, "HTTP fixture"):
                    run_pgbench(
                        parser().parse_args([]), self.log.parent, Path("workload.sql"),
                        {}, 1, 1, "pgbench", fixture,
                    )


class ArgumentTests(unittest.TestCase):
    def test_warmup_can_be_disabled(self):
        self.assertEqual(parser().parse_args(["--warmup", "0"]).warmup, 0)

    def test_invalid_sizes_and_counts_are_rejected(self):
        for arguments in (["--clients", "0"], ["--timeout", "0"], ["--poll-ms", "0"], ["--request-bytes", "-1"]):
            with self.subTest(arguments=arguments), redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                parser().parse_args(arguments)

    def test_duplicate_concurrency_levels_cannot_overwrite_logs(self):
        with self.assertRaisesRegex(ValueError, "unique"):
            benchmark(parser().parse_args(["--clients", "1", "1"]))


class SourceMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.benchmarks = self.root / "benchmarks"
        (self.benchmarks / "workloads").mkdir(parents=True)
        for relative in ("await.sql", "workloads/sql.sql"):
            (self.benchmarks / relative).write_text((Path(__file__).resolve().parent / relative).read_text())
        subprocess.run(["git", "init", "--quiet", str(self.root)], check=True, capture_output=True)
        (self.root / ".git" / "info" / "exclude").write_text("/benchmarks/\n")
        self.output = self.root / "benchmark-output"
        self.args = parser().parse_args([
            "--clients", "1", "--transactions", "1", "--repeat", "1", "--warmup", "0",
            "--output", str(self.output),
        ])

    def run_benchmark(self):
        execute = subprocess.run

        def run_command(command, **options):
            if command == ["pgbench", "--version"]:
                return subprocess.CompletedProcess(command, 0, "pgbench test version", "")
            return execute(command, **options)

        summary = {"transactions_per_second": 1, "latency_ms": {"p50": 1, "p95": 1}}
        with patch("run.ROOT", self.benchmarks), patch("run.psql", side_effect=["{}", "", "[]", "[]", ""]):
            with patch("run.run_pgbench", return_value=summary), patch("run.subprocess.run", side_effect=run_command):
                with redirect_stdout(io.StringIO()):
                    return benchmark(self.args)

    def test_output_creation_does_not_mark_clean_source_dirty(self):
        report = self.run_benchmark()
        self.assertIs(report["source"]["dirty"], False)
        self.assertTrue((self.output / "results.json").is_file())

    def test_untracked_source_is_dirty_even_when_git_hides_untracked_files(self):
        subprocess.run(
            ["git", "-C", str(self.root), "config", "status.showUntrackedFiles", "no"],
            check=True, capture_output=True,
        )
        (self.root / "untracked.sql").write_text("SELECT 1;\n")
        self.assertIs(self.run_benchmark()["source"]["dirty"], True)


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.output = Path(self.directory.name) / "results"
        self.args = parser().parse_args([
            "--clients", "1", "--transactions", "1", "--repeat", "1", "--warmup", "0",
            "--output", str(self.output),
        ])

    def test_cleanup_failure_marks_results_failed(self):
        summary = {"transactions_per_second": 1, "latency_ms": {"p50": 1, "p95": 1}}
        with patch("run.psql", side_effect=["{}", "", "[]", "[]", RuntimeError("cleanup failed")]):
            with patch("run.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "version", "")):
                with patch("run.run_pgbench", return_value=summary), redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "cleanup failed"):
                        benchmark(self.args)
        self.assertEqual(json.loads((self.output / "results.json").read_text())["status"], "failed")

    def test_cancellation_failure_still_removes_schema(self):
        with patch("run.psql", side_effect=["{}", "", RuntimeError("cancel failed"), ""]) as database:
            with patch("run.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "version", "")):
                with patch("run.run_pgbench", side_effect=RuntimeError("workload failed")), redirect_stdout(io.StringIO()):
                    with self.assertRaisesRegex(RuntimeError, "cancel failed"):
                        benchmark(self.args)
            self.assertIn("df.cancel", database.call_args_list[-2].args[0])
            self.assertIn("DROP SCHEMA", database.call_args.args[0])
        report = json.loads((self.output / "results.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertIn("workload failed", report["error"])
        self.assertIn("cancel failed", report["error"])

    def test_interruption_cleans_up_and_records_failure(self):
        with patch("run.psql", side_effect=["{}", "", "[]", "[]", ""]) as database:
            with patch("run.subprocess.run", return_value=subprocess.CompletedProcess([], 0, "version", "")):
                with patch("run.run_pgbench", side_effect=KeyboardInterrupt), redirect_stdout(io.StringIO()):
                    with self.assertRaises(KeyboardInterrupt):
                        benchmark(self.args)
            self.assertIn("DROP SCHEMA", database.call_args.args[0])
        self.assertEqual(json.loads((self.output / "results.json").read_text())["status"], "failed")

    def test_report_retains_psql_diagnostics(self):
        error = subprocess.CalledProcessError(2, ["psql"], stderr="could not connect to server")
        with patch("run.subprocess.run", side_effect=error), redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "could not connect"):
                benchmark(self.args)
        self.assertIn("could not connect to server", json.loads((self.output / "results.json").read_text())["error"])

    def test_cancel_checks_returned_failures_and_remaining_instances(self):
        for responses, remaining in (
            ([{"id": "failed", "result": "Failed to cancel: unavailable"}], []),
            ([{"id": "active", "result": "Instance active cancelled: Benchmark stopped"}], ["active"]),
        ):
            with self.subTest(responses=responses), patch("run.psql", side_effect=[json.dumps(responses), json.dumps(remaining)]):
                with self.assertRaisesRegex(RuntimeError, "cancellation failed"):
                    cancel_instances({"run_label": "this-run"})

    def test_successful_cancellation_checks_only_this_runs_instances(self):
        with patch("run.psql", side_effect=['[{"id":"done","result":"Instance done cancelled: Benchmark stopped"}]', "[]"]) as database:
            cancel_instances({"run_label": "this-run"})
        for call in database.call_args_list:
            self.assertIn("WHERE label = :'run_label'", call.args[0])
            self.assertEqual(call.args[1], {"run_label": "this-run"})

    def test_sigterm_records_run_identity_and_runs_cleanup(self):
        probe = """
import json
import os
import signal
import subprocess
import sys
from unittest.mock import patch
import run

def interrupt(args, *unused):
    report = json.loads((args.output / 'results.json').read_text())
    assert report['status'] == 'running'
    print('run_id=' + report['run_id'], flush=True)
    os.kill(os.getpid(), signal.SIGTERM)

def database(query, variables):
    if 'df.cancel' in query:
        print('cancelled', flush=True)
        return '[]'
    if 'json_agg(id)' in query:
        return '[]'
    if 'DROP SCHEMA' in query:
        print('dropped', flush=True)
    return '{}'

with patch('run.psql', side_effect=database), patch('run.run_pgbench', side_effect=interrupt):
    with patch('run.subprocess.run', return_value=subprocess.CompletedProcess([], 0, 'version', '')):
        sys.exit(run.main())
"""
        result = subprocess.run(
            [sys.executable, "-c", probe, "--clients", "1", "--warmup", "0", "--output", str(self.output)],
            env={**os.environ, "PYTHONPATH": str(Path(__file__).resolve().parent)},
            capture_output=True, text=True, timeout=10,
        )
        self.assertEqual(result.returncode, 143, result.stderr)
        self.assertIn("cancelled\ndropped", result.stdout)
        report = json.loads((self.output / "results.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertIn("run_id=" + report["run_id"], result.stdout)


class HttpFixtureTests(unittest.TestCase):
    def request(self, fixture, body=b"request"):
        connection = HTTPConnection("127.0.0.1", fixture.server_port, timeout=5)
        self.addCleanup(connection.close)
        connection.request("POST", "/", body)
        response = connection.getresponse()
        self.assertEqual(response.status, 200)
        response.read()
        connection.close()

    def test_keepalive_drains_request_bodies(self):
        with HttpFixture(17, 0) as fixture:
            connection = HTTPConnection("127.0.0.1", fixture.server_port, timeout=5)
            self.addCleanup(connection.close)
            for body in (b"first", b"second" * 20000, b""):
                connection.request("POST", "/", body)
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                self.assertEqual(response.read(), b"x" * 17)
            connection.close()
            self.assertEqual(fixture.snapshot(), {
                "connections": 1, "requests": 3, "request_bytes": 120005,
                "response_bytes": 51, "errors": 0,
            })

    def test_concurrent_requests_are_not_serialized_by_the_fixture(self):
        with HttpFixture(0, 100) as fixture, ThreadPoolExecutor(max_workers=4) as executor:
            list(executor.map(self.request, [fixture] * 4))
            self.assertGreater(fixture.peak_active, 1)
            self.assertEqual(fixture.snapshot()["requests"], 4)

    def test_shutdown_closes_keepalive_connections_and_joins_handlers(self):
        with HttpFixture(1, 0) as fixture:
            connection = HTTPConnection("127.0.0.1", fixture.server_port, timeout=5)
            self.addCleanup(connection.close)
            connection.request("POST", "/", b"")
            self.assertEqual(connection.getresponse().read(), b"x")
            handlers = tuple(fixture._threads)
        self.assertEqual(connection.sock.recv(1), b"")
        self.assertFalse(any(handler.is_alive() for handler in handlers))
        self.assertEqual(fixture.connections, set())

    def test_shutdown_interrupts_delayed_responses(self):
        delaying = threading.Event()
        with HttpFixture(1, 5000) as fixture:
            wait = fixture.stopping.wait

            def delayed_response(timeout):
                delaying.set()
                return wait(timeout)

            connection = HTTPConnection("127.0.0.1", fixture.server_port, timeout=5)
            self.addCleanup(connection.close)
            with patch.object(fixture.stopping, "wait", side_effect=delayed_response):
                connection.request("POST", "/", b"")
                self.assertTrue(delaying.wait(5))
            started = time.monotonic()
        self.assertLess(time.monotonic() - started, 3)
        self.assertEqual(connection.sock.recv(1), b"")

    def test_invalid_framing_does_not_count_as_success(self):
        with HttpFixture(0, 0) as fixture:
            connection = HTTPConnection("127.0.0.1", fixture.server_port, timeout=5)
            self.addCleanup(connection.close)
            connection.request("POST", "/", b"", {"Content-Length": "-1"})
            response = connection.getresponse()
            self.assertEqual(response.status, 400)
            response.read()
            connection.close()
            self.assertEqual(fixture.snapshot()["requests"], 0)


@unittest.skipUnless(os.environ.get("PGD_BENCH_INTEGRATION") == "1", "requires a disposable pg_durable database")
class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.output = self.root / "results @ test"

    def arguments(self, *extra):
        return parser().parse_args([
            "--clients", "1", "--transactions", "1", "--repeat", "1", "--warmup", "0",
            "--output", str(self.output), *extra,
        ])

    def assert_cleaned_up(self, report):
        self.assertEqual(psql(
            "SELECT count(*) FROM pg_namespace WHERE nspname = :'schema';",
            {"schema": f"pgd_bench_{report['run_id']}"},
        ), "0")
        self.assertEqual(psql(
            "SELECT count(*) FROM df.instances WHERE label = :'label' AND lower(status) IN ('pending', 'running');",
            {"label": f"pgd-bench-{report['run_id']}"},
        ), "0")

    def test_completion_and_warmup_exclusion(self):
        with redirect_stdout(io.StringIO()):
            report = benchmark(self.arguments("--clients", "1", "2", "--warmup", "1", "--repeat", "2"))
        self.assertEqual(report["status"], "completed")
        self.assertEqual([sample["transactions"] for sample in report["runs"]], [1, 1, 2, 2])
        self.assertIn("settings", report["database"])
        self.assertEqual(psql(
            "SELECT count(*) FROM df.instances WHERE label = :'label';",
            {"label": f"pgd-bench-{report['run_id']}"},
        ), "9")
        self.assert_cleaned_up(report)

    def test_failed_workflow_is_not_reported_as_completed(self):
        script = self.root / "failed.sql"
        script.write_text("SELECT df.start('SELECT 1 / 0', ':run_label') AS instance_id\n\\gset\n")
        with redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
            benchmark(self.arguments("--workload", str(script)))
        report = json.loads((self.output / "results.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["runs"], [])
        self.assertIn("ended with status failed", (self.output / "c1-r1.txt").read_text())
        self.assertIn("division by zero", (self.output / "c1-r1.txt").read_text())
        self.assert_cleaned_up(report)

    def test_timeout_cancels_only_the_benchmark_workflow(self):
        sentinel = psql("SELECT df.start(df.sleep(60), 'benchmark-cleanup-sentinel');", {})
        self.addCleanup(psql, "SELECT df.cancel(:'sentinel');", {"sentinel": sentinel})
        script = self.root / "timeout.sql"
        script.write_text("SELECT df.start(df.sleep(60), ':run_label') AS instance_id\n\\gset\n")
        started = time.monotonic()
        with redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
            benchmark(self.arguments("--workload", str(script), "--timeout", "1", "--poll-ms", "5000"))
        self.assertLess(time.monotonic() - started, 4)
        report = json.loads((self.output / "results.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertIn("timed out", (self.output / "c1-r1.txt").read_text())
        self.assert_cleaned_up(report)
        self.assertIn(psql("SELECT df.status(:'sentinel');", {"sentinel": sentinel}), {"pending", "running"})

    def test_completion_observed_after_deadline_is_not_success(self):
        script = self.root / "late.sql"
        script.write_text("SELECT df.start(df.sleep(2), ':run_label') AS instance_id\n\\gset\n")
        with redirect_stdout(io.StringIO()), self.assertRaises(RuntimeError):
            benchmark(self.arguments("--workload", str(script), "--timeout", "1", "--poll-ms", "5000"))
        report = json.loads((self.output / "results.json").read_text())
        self.assertEqual(report["status"], "failed")
        self.assertEqual(report["runs"], [])
        self.assertIn("timed out", (self.output / "c1-r1.txt").read_text())
        self.assertEqual(psql(
            "SELECT lower(status) FROM df.instances WHERE label = :'label';",
            {"label": f"pgd-bench-{report['run_id']}"},
        ), "cancelled")
        self.assert_cleaned_up(report)

    @unittest.skipUnless(os.environ.get("PGD_BENCH_HTTP") == "1", "requires development-only unrestricted HTTP")
    def test_http_workloads(self):
        for workload in ("http", "http-multipart"):
            with self.subTest(workload=workload), redirect_stdout(io.StringIO()):
                report = benchmark(self.arguments(
                    "--workload", workload, "--clients", "1", "4", "--warmup", "1",
                    "--transactions", "2", "--delay-ms", "50", "--request-bytes", "4096",
                    "--output", str(self.root / workload),
                ))
                self.assertEqual(report["status"], "completed")
                self.assertEqual([sample["http"]["requests"] for sample in report["runs"]], [2, 8])
                self.assertTrue(all(sample["http"]["errors"] == 0 for sample in report["runs"]))
                self.assert_cleaned_up(report)


if __name__ == "__main__":
    unittest.main()