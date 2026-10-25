"""scripts/analysis_lane.py — the nightly Swift 6 analysis lane's verdicts (stage 2).

Pins the failure modes CLAUDE.md rule 9 names: a missing build log is red, a
sanitizer finding is red, a warning regression overnight is red, a stage that
prints no number is red, a stage result that never got written is red — and
the decision of 2026-10-25: the lane says "baseline can be lowered" and never
writes scripts/warnings_baseline.tsv. Synthetic logs only; nothing builds.
"""
import datetime as dt
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / "scripts"))
spec = importlib.util.spec_from_file_location("analysis_lane", REPO / "scripts/analysis_lane.py")
lane = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lane)
wr = lane.wr

A = REPO / "VideoScan/VideoScan/App/A.swift"
A_REL = "VideoScan/VideoScan/App/A.swift"
DEPRECATED = "'foo' is deprecated"


def warn(path, line, text):
    return f"{path}:{line}:5: warning: {text}"


def compiled(*paths):
    names = ",\\ ".join(p.name for p in paths)
    return f"SwiftCompile normal arm64 Compiling\\ {names} " + " ".join(str(p) for p in paths) + " (in target 'VideoScan' from project 'VideoScan')"


def write(d: Path, name: str, text: str) -> Path:
    p = d / name
    p.write_text(text)
    return p


def baseline(d: Path, counts: dict, start: int) -> Path:
    b = d / "baseline.tsv"
    wr.write_baseline(counts, {"start_total": str(start), "recorded": "2026-10-25"}, b)
    return b


class Ratchet(unittest.TestCase):
    def test_a_missing_build_log_is_red_with_no_number(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 1}, 1)
            app = write(d, "app.log", compiled(A) + "\n" + warn(A, 1, DEPRECATED) + "\n")
            r = lane.ratchet(app, d / "absent-core.log", 0, 0, True, b)
        self.assertEqual(r["status"], "red")
        self.assertIsNone(r["number"])
        self.assertIn("Core log missing", r["line"])

    def test_a_failed_build_is_red_even_with_fewer_warnings(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 3}, 3)
            app = write(d, "app.log", "** BUILD FAILED **\n")
            core = write(d, "core.log", "Compile X.swift\n")
            self.assertEqual(lane.ratchet(app, core, 0, 0, True, b)["status"], "red")
            app = write(d, "app.log", compiled(A) + "\n")
            self.assertEqual(lane.ratchet(app, core, 65, 0, True, b)["status"], "red", "exit code is evidence")

    def test_a_regression_overnight_is_red_and_names_the_file(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 1}, 1)
            app = write(d, "app.log", "\n".join([compiled(A), warn(A, 1, DEPRECATED), warn(A, 2, DEPRECATED)]) + "\n")
            core = write(d, "core.log", "Compile X.swift\n")
            r = lane.ratchet(app, core, 0, 0, True, b)
        self.assertEqual(r["status"], "red")
        self.assertEqual(r["number"], 2)
        self.assertIn("RED", r["line"])
        self.assertTrue(any(A_REL in x for x in r["detail"]), r["detail"])

    def test_a_clean_build_below_the_baseline_says_lowerable_and_writes_nothing(self):
        """The decision: the nightly reports; the merging session lowers the file."""
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 3}, 3)
            before = b.read_text()
            app = write(d, "app.log", "\n".join([compiled(A), warn(A, 1, DEPRECATED)]) + "\n")
            core = write(d, "core.log", "Compile X.swift\n")
            r = lane.ratchet(app, core, 0, 0, True, b)
            self.assertEqual(r["status"], "ok")
            self.assertEqual(r["number"], 1)
            self.assertIn("baseline can be lowered: 3 → 1", r["line"])
            self.assertEqual(r["extra"]["lowerable_to"], 1)
            self.assertEqual(b.read_text(), before, "the baseline file is never written by the lane")
            self.assertIn("Swift 6 progress", r["extra"]["progress_markdown"])
            self.assertIn("distinct warnings", r["extra"]["categories"])

    def test_an_unproven_fall_is_reported_not_claimed(self):
        """A file that had warnings, exists, and shows no compile line: `update` would refuse, so the lane says so."""
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            still_here = "VideoScan/VideoScanCore/Package.swift"
            b = baseline(d, {(A_REL, "deprecated"): 1, (still_here, "deprecated"): 7}, 8)
            app = write(d, "app.log", "\n".join([compiled(A), warn(A, 1, DEPRECATED)]) + "\n")
            core = write(d, "core.log", "Compile X.swift\n")
            r = lane.ratchet(app, core, 0, 0, True, b)
        self.assertEqual(r["status"], "ok")
        self.assertIn("NOT lowerable", r["line"])

    def test_an_incremental_run_does_not_probe_the_baseline(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 3}, 3)
            app = write(d, "app.log", warn(A, 1, DEPRECATED) + "\n")
            core = write(d, "core.log", "x\n")
            r = lane.ratchet(app, core, 0, 0, False, b)
        self.assertEqual(r["status"], "ok")
        self.assertNotIn("lowered", r["line"])


class ToolStages(unittest.TestCase):
    def test_lint_counts_repo_findings_only_and_a_missing_report_is_red(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            rows = [{"file": str(A), "rule_id": "unused_import", "line": 1},
                    {"file": str(A), "rule_id": "unused_declaration", "line": 9},
                    {"file": str(REPO / "VideoScan/VideoScanCore/.build/checkouts/GRDB.swift/X.swift"), "rule_id": "unused_import"},
                    {"file": "/tmp/DerivedData/SourcePackages/checkouts/Y.swift", "rule_id": "unused_import"}]
            rep = write(d, "lint.json", json.dumps(rows))
            r = lane.lint(rep, 0)
            self.assertEqual((r["status"], r["number"]), ("ok", 2))
            self.assertEqual(r["extra"]["by_rule"], {"unused_import": 1, "unused_declaration": 1})
            self.assertEqual(lane.lint(d / "absent.json", 0)["status"], "red")
            self.assertEqual(lane.lint(write(d, "empty.json", ""), 0)["status"], "red")
            self.assertEqual(lane.lint(rep, 1)["status"], "red", "swiftlint exit 1 = the tool failed, not findings")
            self.assertEqual(lane.lint(rep, 2)["status"], "ok", "exit 2 = violations at error severity")

    def test_periphery_excludes_third_party_and_counts_kinds(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            rows = [{"location": f"{A}:10:5", "kind": "var.instance", "name": "x"},
                    {"location": f"{A}:20:5", "kind": "function.method.instance", "name": "f"},
                    {"location": f"{REPO}/VideoScan/VideoScanCore/.build/checkouts/GRDB.swift/A.swift:1:1", "kind": "struct"}]
            rep = write(d, "p.json", json.dumps(rows))
            r = lane.periphery(rep, 0)
            self.assertEqual((r["status"], r["number"]), ("ok", 2))
            self.assertEqual(r["extra"]["third_party_excluded"], 1)
            self.assertEqual(r["extra"]["by_kind"], {"property": 1, "method": 1})
            self.assertEqual(lane.periphery(rep, 3)["status"], "red")
            self.assertEqual(lane.periphery(write(d, "bad.json", "{not json"), 0)["status"], "red")

    def test_memsafe_counts_strict_memory_safety_diagnostics_and_handles_an_unsupported_toolchain(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            probe = write(d, "probe.txt", "Apple Swift version 6.4\nprobe.swift:1:45: warning: expression uses unsafe constructs but is not marked with 'unsafe' [#StrictMemorySafety]\n")
            app = write(d, "ms-app.log", "\n".join([
                compiled(A),
                warn(A, 3, "expression uses unsafe constructs but is not marked with 'unsafe' [#StrictMemorySafety]"),
                warn(A, 3, "expression uses unsafe constructs but is not marked with 'unsafe' [#StrictMemorySafety]"),   # summary repeat
                warn(A, 4, DEPRECATED)]) + "\n")
            core = write(d, "ms-core.log", warn(REPO / "VideoScan/VideoScanCore/Sources/VideoScanCore/B.swift", 1,
                                                 "reference to unsafe type 'UnsafeMutablePointer<Int>' [#StrictMemorySafety]") + "\n")
            r = lane.memsafe(0, probe, app, core, 0, 0)
            self.assertEqual((r["status"], r["number"]), ("ok", 2))
            unsupported = write(d, "probe-old.txt", "Apple Swift version 6.1\nerror: unknown argument: '-strict-memory-safety'\n")
            r = lane.memsafe(1, unsupported, app, core, 0, 0)
            self.assertEqual(r["status"], "unavailable")
            self.assertIn("rejects -strict-memory-safety", r["line"])
            silent = write(d, "probe-silent.txt", "Apple Swift version 6.2\n")
            self.assertEqual(lane.memsafe(0, silent, app, core, 0, 0)["status"], "unavailable", "accepted but not diagnosing is not evidence")
            self.assertEqual(lane.memsafe(0, probe, app, d / "absent.log", 0, 0)["status"], "red")
            self.assertEqual(lane.memsafe(0, probe, app, core, 65, 0)["status"], "red")

    def test_sanitizer_findings_are_red_and_a_missing_row_is_red(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            green = write(d, "latest-thread.json", json.dumps({"status": "ok", "unique_findings": [], "tests": 1900,
                                                               "configuration": "Release", "targets": ["app", "core"],
                                                               "subset": "full", "log": "/x.log"}))
            r = lane.sanitizer("thread", green)
            self.assertEqual((r["status"], r["number"]), ("ok", 0))
            self.assertIn("1900 tests", r["line"])
            red = write(d, "latest-thread-red.json", json.dumps({"status": "findings", "tests": 1900, "log": "/x.log",
                                                                 "unique_findings": ["ThreadSanitizer: data race VideoRecord.swift:42 in setter"]}))
            r = lane.sanitizer("thread", red)
            self.assertEqual((r["status"], r["number"]), ("red", 1))
            self.assertIn("data race", r["detail"][0])
            failed = write(d, "latest-address.json", json.dumps({"status": "tests-failed", "tests": 10, "unique_findings": [],
                                                                 "failed_tests": ["hundredThousandRecordsPageInBudget"], "log": "/y.log"}))
            r = lane.sanitizer("address", failed)
            self.assertEqual(r["status"], "red")
            self.assertTrue(any("hundredThousand" in x for x in r["detail"]))
            self.assertEqual(lane.sanitizer("address", d / "absent.json")["status"], "red")
            empty = write(d, "latest-empty.json", json.dumps({"status": "no-tests-ran", "tests": 0, "unique_findings": [], "log": "/z"}))
            r = lane.sanitizer("address", empty)
            self.assertEqual(r["status"], "red")
            self.assertIsNone(r["number"], "zero tests and zero findings is not a number, it is nothing")


class Report(unittest.TestCase):
    def _stage(self, d: Path, name: str, status="ok", number=1, line=None, extra=None):
        (d / f"{name}.json").write_text(json.dumps(lane.result(name, status, number, line or f"{name}: {number} thing(s)", [], extra)))

    def test_a_missing_stage_result_or_no_number_is_red_whatever_the_stage_said(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            self._stage(d, "ratchet", number=460)
            self._stage(d, "census", status="ok", number=None, line="census: ok (no number)")
            # periphery.json deliberately never written
            status, reasons = lane.verdict({s: (json.loads((d / f"{s}.json").read_text()) if (d / f"{s}.json").exists() else None)
                                            for s in ("ratchet", "census", "periphery")}, ["ratchet", "census", "periphery"])
        self.assertEqual(status, "red")
        self.assertEqual(len(reasons), 2, reasons)
        self.assertTrue(any("printed no number" in r for r in reasons))
        self.assertTrue(any("periphery: no result" in r for r in reasons))

    def test_unavailable_is_yellow_not_green_and_never_red(self):
        results = {"ratchet": lane.result("ratchet", "ok", 5, "ratchet: 5"),
                   "memsafe": lane.result("memsafe", "unavailable", None, "memsafe: n/a — rejects flag")}
        self.assertEqual(lane.verdict(results, ["ratchet", "memsafe"]), ("yellow", []))
        results["ratchet"]["status"] = "red"
        self.assertEqual(lane.verdict(results, ["ratchet", "memsafe"])[0], "red")

    def test_a_boolean_is_not_a_number(self):
        results = {"census": lane.result("census", "ok", True, "census: True")}
        self.assertEqual(lane.verdict(results, ["census"])[0], "red")

    def test_report_writes_latest_runs_and_markdown_with_the_numbers(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            stages = d / "stages"; stages.mkdir()
            self._stage(stages, "ratchet", number=460, line="ratchet: 460 warning(s) — GREEN; baseline can be lowered: 460 → 455",
                        extra={"progress_markdown": "## Swift 6 progress: 1%", "categories": "460 distinct warnings"})
            self._stage(stages, "census", number=1386, extra={"kinds": {}, "targets": {"app": {"total": 285, "kinds": {"try!": 3}}}, "todo": "report mode"})
            self._stage(stages, "sanitizer-thread", status="red", number=2, line="sanitizer thread: 2 unique finding(s) — RED: findings")
            row = lane.report(stages, ["ratchet", "census", "sanitizer-thread"], d / "latest.json", d / "runs.jsonl",
                              d / "report.md", "abc1234", "RicksM4", 123.0)
            self.assertEqual(row["status"], "red")
            self.assertIn("ratchet 460", row["headline"])
            self.assertIn("census 1386", row["headline"])
            latest = json.loads((d / "latest.json").read_text())
            self.assertEqual(latest["status"], "red")
            self.assertEqual(latest["stages"]["ratchet"]["number"], 460)
            self.assertNotIn("extra", latest["stages"]["ratchet"], "latest.json carries the lines, not the full markdown")
            self.assertEqual(len((d / "runs.jsonl").read_text().splitlines()), 1)
            md = (d / "report.md").read_text()
            self.assertIn("## Swift 6 progress", md)
            self.assertIn("baseline can be lowered", md)
            self.assertIn("| app |", md)
            self.assertIn("never writes `scripts/warnings_baseline.tsv`", md)

    def test_alert_lines_red_fresh_stale_and_silent(self):
        now = dt.datetime.fromisoformat("2026-10-26T09:00:00-04:00")
        fresh_red = {"ts": "2026-10-26T05:10:00-04:00", "date": "2026-10-26", "status": "red",
                     "headline": "🔴 Swift 6 analysis lane RED (abc, M4): ratchet 462", "reasons": ["ratchet: +2"], "report": "/r.md"}
        lines = lane.alert_lines(fresh_red, now)
        self.assertTrue(lines[0].startswith("🔴"))
        self.assertIn("✘ ratchet: +2", lines[1])
        self.assertIn("report: /r.md", lines[2])
        fresh_green = {**fresh_red, "status": "ok", "headline": "🟢 Swift 6 analysis lane OK (abc, M4): ratchet 455", "reasons": []}
        self.assertEqual(lane.alert_lines(fresh_green, now), ["🟢 Swift 6 analysis lane OK (abc, M4): ratchet 455"])
        stale = {**fresh_green, "ts": "2026-10-20T05:10:00-04:00"}
        self.assertTrue(lane.alert_lines(stale, now)[0].startswith("🟡"))
        self.assertEqual(lane.alert_lines(None, now), [])
        self.assertTrue(lane.alert_lines({"date": "x"}, now)[0].startswith("🔴"), "an unreadable row is loud")


class CLI(unittest.TestCase):
    def test_each_stage_subcommand_prints_one_line_and_writes_its_json(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            rep = write(d, "p.json", "[]")
            import contextlib, io
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = lane.main(["--out-dir", str(d / "stages"), "periphery", "--report", str(rep), "--rc", "0"])
            self.assertEqual(rc, 0)
            self.assertEqual(buf.getvalue().strip().splitlines(), ["periphery: 0 unused declaration(s) in 0 file(s) (none; 0 third-party excluded)"])
            self.assertTrue((d / "stages/periphery.json").exists())
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = lane.main(["--out-dir", str(d / "stages"), "periphery", "--report", str(d / "absent.json")])
            self.assertEqual(rc, 1)
            self.assertIn("RED", buf.getvalue())


if __name__ == "__main__":
    unittest.main()
