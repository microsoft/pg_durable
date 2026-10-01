# Copyright (c) Microsoft Corporation.
# Licensed under the PostgreSQL License.

from pathlib import Path
import tempfile
import unittest

import upgrade_lifecycle_canary as canary


class AnchorTests(unittest.TestCase):
    """Fast guards so anchor drift fails in milliseconds, not after a build."""

    def test_every_mutation_anchor_matches_current_source_exactly_once(self):
        for mutation in canary.MUTATIONS:
            text = (canary.PROJECT / mutation.file).read_text()
            for index, (old, _new) in enumerate(mutation.edits):
                with self.subTest(mutation=mutation.name, edit=index):
                    self.assertEqual(
                        text.count(old), 1,
                        f"{mutation.name} edit {index} anchor must occur exactly once",
                    )

    def test_mutations_are_uniquely_named(self):
        names = [mutation.name for mutation in canary.MUTATIONS]
        self.assertEqual(len(names), len(set(names)))

    def test_both_guaranteed_coverage_areas_are_represented(self):
        proves = " ".join(mutation.proves for mutation in canary.MUTATIONS)
        self.assertIn("#409", proves)
        self.assertIn("#411", proves)


class ApplyMutationTests(unittest.TestCase):
    def _mutation(self, edits):
        return canary.Mutation("probe", "target.rs", "#x", "why", edits)

    def test_applies_all_edits_in_order(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "target.rs").write_text("alpha\nbeta\n")
            canary.apply_mutation(root, self._mutation([("alpha", "ALPHA"), ("beta", "BETA")]))
            self.assertEqual((root / "target.rs").read_text(), "ALPHA\nBETA\n")

    def test_rejects_missing_anchor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "target.rs").write_text("alpha\n")
            with self.assertRaisesRegex(RuntimeError, "occurs 0 times"):
                canary.apply_mutation(root, self._mutation([("absent", "x")]))

    def test_rejects_ambiguous_anchor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "target.rs").write_text("dup\ndup\n")
            with self.assertRaisesRegex(RuntimeError, "occurs 2 times"):
                canary.apply_mutation(root, self._mutation([("dup", "x")]))


class CanaryProblemsTests(unittest.TestCase):
    def setUp(self):
        self.mutation = canary.MUTATIONS[0]
        self.stdout = "baseline: 15 instances validated\n"
        self.evidence = f"Instance failed: {canary.SCHEDULE_MISMATCH}"

    def test_detected_break_has_no_problems(self):
        self.assertEqual(
            canary.canary_problems(self.mutation, 1, self.stdout, self.evidence), [])

    def test_lifecycle_passing_is_a_canary_failure(self):
        problems = canary.canary_problems(self.mutation, 0, self.stdout, self.evidence)
        self.assertEqual(len(problems), 1)
        self.assertIn("not detected", problems[0])

    def test_missing_baseline_is_flagged_as_build_or_baseline_fault(self):
        problems = canary.canary_problems(self.mutation, 1, "", self.evidence)
        self.assertTrue(any("baseline" in problem for problem in problems))

    def test_missing_schedule_mismatch_evidence_is_flagged(self):
        problems = canary.canary_problems(
            self.mutation, 1, self.stdout, "some unrelated panic")
        self.assertTrue(any("evidence" in problem for problem in problems))

    def test_build_failure_reports_both_baseline_and_evidence_problems(self):
        problems = canary.canary_problems(self.mutation, 1, "", "error[E0433]: build broke")
        self.assertEqual(len(problems), 2)


if __name__ == "__main__":
    unittest.main()
