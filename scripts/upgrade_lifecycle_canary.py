#!/usr/bin/env python3
# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.
"""Negative controls that prove the upgrade lifecycle still catches replay breaks.

Fresh-execution unit and E2E tests cannot establish replay compatibility: a
change can keep every new instance correct while making histories created by the
previous binary fail to replay. The real previous-binary lifecycle
(`scripts/upgrade_lifecycle.py`) is what catches that class of break. These
canaries prove the lifecycle is actually sensitive to it, rather than passing
vacuously.

Each canary applies one small, exact source mutation to a throwaway git
worktree, runs `scripts/upgrade_lifecycle.py` against it, and requires the
lifecycle to FAIL during resume with a duroxide schedule mismatch. A canary that
instead passes the lifecycle is itself a failure: it means the lifecycle stopped
detecting a compatibility break it is designed to detect. Requiring the N-1
baseline to validate first distinguishes a genuine replay rejection from a build
or baseline failure.

This control is expensive — the N-1 binary is built once and reused, but each
canary still builds its own candidate binary and runs a private PostgreSQL
cluster — so it is a manual/scheduled pre-release job, not a required per-PR
gate. The ordinary lifecycle stays in required CI. The anchors each mutation
targets are additionally checked by the fast unit tests in
`scripts/test_upgrade_lifecycle_canary.py`, so anchor drift is caught in
milliseconds rather than after a multi-minute build.
"""

import argparse
import math
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib

import upgrade_lifecycle as lifecycle


PROJECT = Path(__file__).resolve().parents[1]

# Substring the lifecycle reports when duroxide rejects a replay because the
# orchestration no longer produces the recorded durable operations. Its presence
# proves the failure is a determinism/replay rejection, not an unrelated fault.
SCHEDULE_MISMATCH = "nondeterministic: schedule mismatch"

# The lifecycle prints a line starting with this only after the real N-1 binary
# built and its baseline instances validated. Requiring it proves a canary broke
# *replay*, not the build or the previous-binary baseline.
BASELINE_MARKER = "baseline:"


class Mutation:
    """One replay-incompatible source change and the coverage it proves.

    ``edits`` is a list of ``(old, new)`` string replacements applied to
    ``file``; each ``old`` must appear exactly once so a refactor that moves the
    anchor fails loudly instead of silently mutating the wrong place.
    """

    def __init__(self, name, file, proves, rationale, edits, evidence=SCHEDULE_MISMATCH):
        self.name = name
        self.file = file
        self.proves = proves
        self.rationale = rationale
        self.edits = edits
        self.evidence = evidence


MUTATIONS = [
    Mutation(
        name="activity-input-bytes",
        file="src/orchestrations/execute_function_graph.rs",
        proves="#409 (real previous-binary histories)",
        rationale=(
            "Adds a semantically ignored field to the execute_sql activity input. "
            "Deserialization stays backward compatible and every new instance is "
            "unaffected, but the scheduled activity input bytes no longer match the "
            "bytes recorded by N-1 histories. Only a test that replays real old "
            "histories can catch this."
        ),
        edits=[(
            '    let input = serde_json::json!({\n'
            '        "query": final_query,\n'
            '        "submitted_by": node.submitted_by,\n'
            '        "database": node.database,\n'
            '    });',
            '    let input = serde_json::json!({\n'
            '        "compat_version": 2,\n'
            '        "query": final_query,\n'
            '        "submitted_by": node.submitted_by,\n'
            '        "database": node.database,\n'
            '    });',
        )],
    ),
    Mutation(
        name="join-branch-order",
        file="src/orchestrations/execute_function_graph.rs",
        proves="#411 (one suspended instance per DSL behavior family)",
        rationale=(
            "Schedules JOIN branches right-to-left and reverses the collected "
            "results so fresh instances keep left-to-right output. The observable "
            "result is unchanged, so unit and E2E tests pass, but a JOIN history "
            "suspended with one branch complete replays the branches in the "
            "recorded order. The suspended JOIN family #411 added is required to "
            "catch this; the #409 lifecycle, with no suspended JOIN history, does "
            "not."
        ),
        edits=[
            (
                "    for child_root in &branch_ids {",
                "    for child_root in branch_ids.iter().rev() {",
            ),
            (
                "    let results_vec = ctx.join(durable_futures).await;",
                "    let mut results_vec = ctx.join(durable_futures).await;\n"
                "    results_vec.reverse();",
            ),
        ],
    ),
]


def run(*args, cwd=None):
    return subprocess.run(
        [str(arg) for arg in args], cwd=cwd, check=True,
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout.strip()


def apply_mutation(root, mutation):
    """Apply a mutation's edits to a checkout rooted at ``root``.

    Raises if any anchor is missing or appears more than once, so anchor drift
    is a hard failure rather than a silent no-op or a wrong-site edit.
    """
    path = Path(root) / mutation.file
    text = path.read_text()
    for old, new in mutation.edits:
        count = text.count(old)
        if count != 1:
            raise RuntimeError(
                f"{mutation.name}: anchor occurs {count} times in {mutation.file}, "
                "expected exactly 1"
            )
        text = text.replace(old, new, 1)
    path.write_text(text)


def canary_problems(mutation, returncode, stdout, evidence_text):
    """Return reasons this canary did not behave as a negative control should.

    An empty list means the lifecycle correctly rejected the mutation: it failed
    (nonzero exit), the real N-1 baseline validated first, and the failure
    carries the expected replay-rejection evidence.
    """
    if returncode == 0:
        return ["lifecycle passed; the replay-incompatible change was not detected"]
    problems = []
    if BASELINE_MARKER not in stdout:
        problems.append(
            "N-1 baseline did not validate; the failure is a build/baseline fault, "
            "not a replay rejection"
        )
    if mutation.evidence not in evidence_text:
        problems.append(f"missing expected replay-rejection evidence {mutation.evidence!r}")
    return problems


def run_canary(mutation, pg_config, previous, previous_package, base_commit, output_root, timeout):
    worktree = output_root / f"worktree-{mutation.name}"
    evidence_dir = output_root / f"lifecycle-{mutation.name}"
    run("git", "worktree", "add", "--detach", worktree, base_commit, cwd=PROJECT)
    try:
        apply_mutation(worktree, mutation)
        proc = subprocess.run(
            [sys.executable, "scripts/upgrade_lifecycle.py",
             "--pg-config", str(pg_config),
             "--previous-version", previous,
             "--previous-package", str(previous_package),
             "--output-dir", str(evidence_dir),
             "--timeout", str(timeout)],
            cwd=worktree, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        error_file = evidence_dir / "error.txt"
        evidence_text = (error_file.read_text() if error_file.is_file() else "") + proc.stderr
        return canary_problems(mutation, proc.returncode, proc.stdout, evidence_text)
    finally:
        run("git", "worktree", "remove", "--force", worktree, cwd=PROJECT)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pg-config", type=Path, required=True)
    parser.add_argument("--previous-version", required=True)
    parser.add_argument("--base-ref", default="HEAD",
                        help="commit the mutated worktrees are created from (default: HEAD)")
    parser.add_argument("--only", action="append", metavar="NAME",
                        help="run only the named canary; repeatable")
    parser.add_argument("--output-dir", type=Path,
                        help="new directory for worktrees and lifecycle evidence")
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if not re.fullmatch(r"\d+\.\d+\.\d+", args.previous_version):
        parser.error("--previous-version must be a release version, e.g. 0.2.8")
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be finite and positive")

    names = {mutation.name for mutation in MUTATIONS}
    selected = MUTATIONS
    if args.only:
        unknown = sorted(set(args.only) - names)
        if unknown:
            parser.error(f"unknown canary name(s): {', '.join(unknown)}; known: {', '.join(sorted(names))}")
        selected = [mutation for mutation in MUTATIONS if mutation.name in set(args.only)]

    output = args.output_dir
    if output is None:
        parent = PROJECT / "target/upgrade-canary"
        parent.mkdir(parents=True, exist_ok=True)
        output = Path(tempfile.mkdtemp(dir=parent))
    else:
        output = output.resolve()
        output.mkdir(parents=True)
    print(f"Upgrade lifecycle canary evidence: {output}", flush=True)

    pg_config = args.pg_config.resolve()
    current = tomllib.loads((PROJECT / "Cargo.toml").read_text())["package"]["version"]
    previous = args.previous_version
    if not (PROJECT / f"sql/pg_durable--{previous}--{current}.sql").is_file():
        print(f"No direct upgrade script from {previous} to {current}", file=sys.stderr)
        return 1
    base_commit = run("git", "rev-parse", "--verify", f"{args.base_ref}^{{commit}}", cwd=PROJECT)

    # Build the N-1 binary once; every canary reuses it. Only the candidate
    # binary genuinely differs per mutation, so this halves the build cost
    # without weakening isolation (each mutation still gets its own candidate
    # build, worktree, and lifecycle run).
    pg_major = lifecycle.run(pg_config, "--version").split()[1].split(".")[0]
    print(f"Building the shared N-1 ({previous}) package once...", flush=True)
    source, _commit = lifecycle.materialize_previous(output, previous)
    previous_package = lifecycle.build(source, output / "previous", pg_config, pg_major)

    failures = {}
    for mutation in selected:
        print(f"\n=== canary {mutation.name} (proves {mutation.proves}) ===", flush=True)
        problems = run_canary(mutation, pg_config, previous, previous_package,
                              base_commit, output, args.timeout)
        if problems:
            failures[mutation.name] = problems
            print(f"CANARY FAILED: {mutation.name}", flush=True)
            for problem in problems:
                print(f"  - {problem}", flush=True)
        else:
            print(f"OK: lifecycle detected the break for {mutation.name}", flush=True)

    print()
    if failures:
        print(f"Canary result: {len(failures)} of {len(selected)} canaries did not detect "
              f"their break. See {output}", file=sys.stderr)
        return 1
    print(f"Canary result: all {len(selected)} canaries detected their break.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
