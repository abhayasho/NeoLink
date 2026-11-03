#!/usr/bin/env python3
"""Offline regression checks for benchmark validity; never launches the GUI."""
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("bench_run", Path(__file__).with_name("bench-run.py"))
bench = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bench)


class BenchmarkChecks(unittest.TestCase):
    def test_default_command_invokes_build_before_any_benchmark(self):
        with patch.object(bench.sys, "argv", ["bench-run.py", "--label", "offline-test"]), \
             patch.object(bench, "source_digest", return_value="fixture"), \
             patch.object(bench, "build_release", side_effect=SystemExit("build stopped")) as build, \
             patch.object(bench, "run_once") as run:
            with self.assertRaisesRegex(SystemExit, "build stopped"):
                bench.main()
            build.assert_called_once()
            run.assert_not_called()

    def test_failed_build_aborts_before_resolving_or_running_a_binary(self):
        with patch.object(bench.subprocess, "run", return_value=subprocess.CompletedProcess([], 1)) as run:
            with self.assertRaisesRegex(SystemExit, "swift build failed"):
                bench.build_release()
            self.assertEqual(run.call_count, 1)

    def test_failed_binary_path_lookup_aborts(self):
        responses = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 1, stdout="", stderr="failure")]
        with patch.object(bench.subprocess, "run", side_effect=responses):
            with self.assertRaisesRegex(SystemExit, "resolve"):
                bench.build_release()

    def test_successful_build_uses_swiftpm_binary_path(self):
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory, "NeoLink")
            binary.write_text("fixture"); binary.chmod(0o700)
            responses = [subprocess.CompletedProcess([], 0), subprocess.CompletedProcess([], 0, stdout=directory + "\n")]
            with patch.object(bench.subprocess, "run", side_effect=responses):
                self.assertEqual(bench.build_release(), str(binary))

    def verdict(self, result):
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, "run-1.probe.log").write_text(json.dumps({"locked": False, "onScreen": True, "front": 123, "t": 0, "idle": 50}) + "\n")
            result = dict(result, scenario="ui-explorer-scroll")
            Path(directory, "run-1.json").write_text(json.dumps({"results": [result]}))
            return bench.validate(directory, 1, 123, False, "ui-explorer-scroll")

    def test_stationary_scroll_cannot_be_reported_as_valid(self):
        verdict = self.verdict({"scrollSamples": 350, "scrollRefreshesMoved": 1,
                                "scrollRefreshesRepeatedWhileMoving": 0, "scrollStutterPercent": 0})
        self.assertFalse(verdict["valid"])

    def test_small_jitter_does_not_count_as_meaningful_scrolling(self):
        verdict = self.verdict({"scrollRefreshesMoved": 200, "scrollRefreshesRepeatedWhileMoving": 0,
                                "scrollTravelPoints": 150, "scrollRangePoints": 3})
        self.assertFalse(verdict["valid"])

    def test_missing_samples_are_invalid(self):
        self.assertFalse(self.verdict({"scrollSamples": 0, "invalid": ["Insufficient explorer movement"]})["valid"])

    def test_real_geometry_travel_is_accepted_with_its_scope_caveat(self):
        verdict = self.verdict({"scrollRefreshesMoved": 200, "scrollRefreshesRepeatedWhileMoving": 10,
                                "scrollTravelPoints": 2000, "scrollRangePoints": 1000})
        self.assertTrue(verdict["valid"])


if __name__ == "__main__":
    unittest.main()
