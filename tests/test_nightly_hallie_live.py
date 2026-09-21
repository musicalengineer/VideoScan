"""Replay CLI integration tests with stub harness and Ollama tags, never an app."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "scripts/nightly_hallie_replay.sh"
QUERY = "\x1b[36mQuery: where is Donna?\x1b[0m"
ANSWER = "\x1b[32mHallie: Here she is.\x1b[0m"
FLAG = "\x1b[33mFlag: review expected behavior\x1b[0m"
HARNESS = r'''
import json, os, pathlib, sys, time
args = sys.argv[1:]
def arg(key): return args[args.index(key) + 1]
if args[0] == "run":
    print("ordinary harness diagnostics", flush=True)
    if "--live" in args:
        print("\x1b[36mQuery: where is Donna?\x1b[0m", file=sys.stderr, flush=True)
        print("\x1b[32mHallie: Here she is.\x1b[0m", file=sys.stderr, flush=True)
        print("\x1b[33mFlag: review expected behavior\x1b[0m", file=sys.stderr, flush=True)
    time.sleep(float(os.environ.get("STUB_DELAY", "0")))
    if not os.environ.get("STUB_NO_RUN_ARTIFACT"):
        pathlib.Path(arg("--out")).write_text("{}")
    sys.exit(int(os.environ.get("STUB_RUN_RC", "0")))
else:
    strict = "--strict" in args
    rc = int(os.environ.get("STUB_GRADE_RC", "0")) if strict else 0
    summary = {"status": "failed" if rc else "ok", "expected": 2 if strict else 3,
               "completed": 2 if strict else 3, "clean": (2 if strict else 3) - bool(rc),
               "defects": int(bool(rc)), "incomplete": 0}
    if not os.environ.get("STUB_NO_YELLOW"):
        summary["meta"] = {"liveReviewFlags": 1 if strict else 2}
    pathlib.Path(arg("--run")).with_suffix(".summary.json").write_text(json.dumps(summary))
    sys.exit(rc)
'''


class LiveReplayTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="hallie-live-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        (self.root / "tests").mkdir()
        (self.root / "bin").mkdir()
        (self.root / "scripts/hallie_eval.py").write_text(HARNESS)
        for name in ("hallie_strict_regressions.json", "hallie_eval_corpus.json"):
            (self.root / "tests" / name).write_text("[]")
        curl = self.root / "bin/curl"
        curl.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"models":[{"name":"test-brain"}]}\'\n')
        curl.chmod(0o755)
        self.env = dict(os.environ, REPO=str(self.root), PY=sys.executable,
                        LOGDIR=str(self.root / "logs"),
                        PATH=str(self.root / "bin") + os.pathsep + os.environ["PATH"])
        self.env.pop("VIDEOSCAN_HALLIE_REPLAY_HOST", None)
        self.env.pop("VIDEOSCAN_HALLIE_REPLAY_MODEL", None)

    def command(self, *args):
        return ["bash", str(RUNNER), "--model", "test-brain", *args]

    def run_replay(self, *args):
        return subprocess.run(self.command(*args), env=self.env, capture_output=True,
                              text=True, timeout=15)

    def test_live_defaults_stream_both_lanes_and_preserve_json_and_logs(self):
        result = self.run_replay("--live")
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        for line in (QUERY, ANSWER, FLAG):
            self.assertEqual(result.stderr.count(line), 2)
            self.assertNotIn(line, result.stdout)
        self.assertNotIn("ordinary harness diagnostics", result.stderr)
        files = list((self.root / "logs").glob("replay-*.summary.json"))
        self.assertEqual(len(files), 1)
        self.assertIn(str(files[0]), result.stderr)
        summary = json.loads(files[0].read_text())
        self.assertEqual(summary["hallie_strict_pass"], 2)
        self.assertEqual(summary["hallie_advisory_pass"], 3)
        self.assertEqual(summary["hallie_strict_yellow"], 1)
        self.assertEqual(summary["hallie_advisory_yellow"], 2)
        self.assertIn(FLAG + "\n\n\n\n" + "=" * 64 + "\nDONE", result.stderr)
        self.assertEqual(result.stderr.count("DONE"), 1)
        self.assertLess(result.stderr.rindex(ANSWER), result.stderr.index("DONE"))
        self.assertIn("Strict: 2 passed, 0 failed, 0 incomplete; yellow: 1", result.stderr)
        self.assertIn("Advisory: 3 clean, 0 flagged, 0 incomplete; yellow: 2", result.stderr)
        for logfile in (self.root / "logs").glob("*.run.log"):
            self.assertIn(QUERY, logfile.read_text())
            self.assertIn("ordinary harness diagnostics", logfile.read_text())

    def test_live_reaches_terminal_before_lane_finishes(self):
        self.env["STUB_DELAY"] = "1"
        process = subprocess.Popen(self.command("--live", "--strict-only"), env=self.env,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            lines = [process.stderr.readline() for _ in range(2)]
            self.assertIn(QUERY, "".join(lines))
            self.assertIsNone(process.poll())
            process.communicate(timeout=15)
            self.assertEqual(process.returncode, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.communicate()

    def test_explicit_output_and_strict_failure_preserved(self):
        self.env["STUB_GRADE_RC"] = "1"
        output = self.root / "chosen summary.json"
        result = self.run_replay("--live", "--strict-only", "--out", str(output))
        self.assertEqual(result.returncode, 1)
        summary = json.loads(output.read_text())
        self.assertEqual(summary["hallie_replay_status"], "failed")
        self.assertEqual(summary["hallie_strict_fail"], 1)
        self.assertEqual(summary["hallie_advisory_status"], "not-run")
        self.assertIn(ANSWER, result.stderr)
        self.assertIn("Strict: 1 passed, 1 failed, 0 incomplete; yellow: 1", result.stderr)
        self.assertIn("Advisory: not run", result.stderr)
        self.assertFalse(list((self.root / "logs").glob("replay-*.summary.json")))

    def test_run_failure_is_not_hidden_by_successful_grading(self):
        self.env["STUB_RUN_RC"] = "1"
        output = self.root / "summary.json"
        result = self.run_replay("--live", "--strict-only", "--out", str(output))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(output.read_text())["hallie_replay_status"], "failed")

    def test_nonlive_keeps_terminal_clean(self):
        output = self.root / "summary.json"
        result = self.run_replay("--out", str(output))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertNotIn("\x1b", result.stdout)
        self.assertEqual(json.loads(output.read_text())["hallie_advisory_pass"], 3)

    def test_nonlive_requires_output(self):
        result = self.run_replay()
        self.assertEqual(result.returncode, 64)
        self.assertIn("--out is required", result.stderr)

    def test_unknown_yellow_is_not_reported_as_zero(self):
        self.env["STUB_NO_YELLOW"] = "1"
        result = self.run_replay("--live", "--strict-only")
        self.assertEqual(result.returncode, 0)
        self.assertIn("yellow: not measured", result.stderr)

    def test_interrupted_harness_does_not_print_done_or_run_next_lane(self):
        self.env["STUB_RUN_RC"] = "130"
        self.env["STUB_NO_RUN_ARTIFACT"] = "1"
        result = self.run_replay("--live")
        self.assertEqual(result.returncode, 130)
        self.assertNotIn("DONE", result.stderr)
        self.assertEqual(result.stderr.count(QUERY), 1)

    def test_help_and_missing_value(self):
        result = self.run_replay("--help")
        self.assertEqual(result.returncode, 0)
        self.assertIn("--live", result.stdout)
        result = self.run_replay("--out")
        self.assertEqual(result.returncode, 64)
        self.assertIn("requires a value", result.stderr)


if __name__ == "__main__":
    unittest.main()
