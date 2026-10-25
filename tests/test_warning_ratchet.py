"""scripts/warning_ratchet.py — warnings may fall, never rise (Swift 6 stage 0).

Pins: distinct-diagnostic parsing (xcodebuild repeats a warning in its
summary; ANSI colour from `swift build`; package checkouts inside the repo do
not count), the per-(file, category) rule on an INCREMENTAL log, `update`'s
refusal to raise a count or to accept an unproven fall, the first baseline,
clean headers across updates, and the progress figure (99 % until the app
target is in Swift 6 mode). The five tests marked "review 2026-10-25" were
RED on the first version of the script.
"""
import importlib.util
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("warning_ratchet", REPO / "scripts/warning_ratchet.py")
ratchet = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ratchet)

A = REPO / "VideoScan/VideoScan/App/A.swift"
B = REPO / "VideoScan/VideoScan/Catalog/B.swift"
A_REL, B_REL = "VideoScan/VideoScan/App/A.swift", "VideoScan/VideoScan/Catalog/B.swift"
FOREIGN = Path("/tmp/DerivedData/SourcePackages/checkouts/GRDB.swift/Sources/GRDB/X.swift")
GRDB_IN_TREE = REPO / "VideoScan/VideoScanCore/.build/checkouts/GRDB.swift/GRDB/Core/Database.swift"
DEPRECATED, STATIC = "'foo' is deprecated", "static property 'x' is not concurrency-safe because non-'Sendable' type"


def log(*lines: str) -> str:
    return "\n".join(lines) + "\n"


def warn(path: Path, line: int, text: str, col: int = 5) -> str:
    return f"{path}:{line}:{col}: warning: {text}"


def compiled(*paths: Path) -> str:
    """One xcodebuild SwiftCompile line naming these files (compile evidence)."""
    names = ",\\ ".join(p.name for p in paths)
    return f"SwiftCompile normal arm64 Compiling\\ {names} " + " ".join(str(p) for p in paths) + " (in target 'VideoScan' from project 'VideoScan')"


def baseline(d: Path, counts: dict, start: int | None = None) -> Path:
    b = d / "baseline.tsv"
    meta = {"recorded": "2026-10-25"}
    if start is not None:
        meta["start_total"] = str(start)
    ratchet.write_baseline(counts, meta, b)
    return b


class Parsing(unittest.TestCase):
    def test_distinct_diagnostics_in_repo_files_only(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "build.log"
            p.write_text(log(
                warn(A, 10, STATIC),
                "\x1b[1m" + warn(A, 10, STATIC) + "\x1b[0m",        # xcodebuild summary repeat, coloured
                warn(A, 20, DEPRECATED),
                warn(B, 3, "capture of 'y' with non-Sendable type 'Z' in a '@Sendable' closure"),
                warn(FOREIGN, 1, "third-party warning"),
                f"{A}:30:1: error: not a warning",
            ))
            diags = ratchet.parse_logs([p])
        self.assertEqual(ratchet.per_file(diags), {A_REL: 2, B_REL: 1})
        self.assertEqual(ratchet.counts_of(diags),
                         {(A_REL, "global-static"): 1, (A_REL, "deprecated"): 1, (B_REL, "sendable-capture"): 1})

    def test_package_checkouts_inside_the_repo_do_not_count(self):
        """review 2026-10-25: `swift test` puts checkouts in <pkg>/.build, inside REPO."""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "log"
            p.write_text(log(warn(GRDB_IN_TREE, 1, "third-party")))
            self.assertEqual(ratchet.per_file(ratchet.parse_logs([p])), {})

    def test_compile_evidence_from_xcodebuild_and_very_verbose_swiftpm(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "log"
            p.write_text(log(compiled(A, B),
                             f"swift-frontend -frontend -c -primary-file {GRDB_IN_TREE} -primary-file {B} -o x.o",
                             "Compile RollCallTests.swift",                       # swift build -vv
                             "    builtin-SwiftPerFileCompile RollCallTests.swift",
                             "Compiling Clang module ptrauth"))                   # not a Swift file
            self.assertEqual(ratchet.compiled_files([p]), ({A_REL, B_REL}, {"RollCallTests.swift"}))

    def test_swiftpm_evidence_by_file_name_proves_a_fall(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            test_file = "VideoScan/VideoScanCore/Tests/VideoScanCoreTests/RollCallTests.swift"
            self.assertTrue((REPO / test_file).exists())
            b = baseline(d, {(test_file, "deprecated"): 3}, start=3)
            p = d / "clean.log"
            p.write_text(log("Compiling Clang module ptrauth"))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 1, "no evidence")
            p.write_text(log("Compile RollCallTests.swift"))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 0)
            self.assertEqual(ratchet.read_baseline(b)[0], {})

    def test_a_warning_glued_to_another_streams_echo_still_counts(self):
        """2026-10-25: `swift build -v` interleaved `cd /Users/rickb/dev/V` with a warning line;
        the baseline missed two warnings the sensor lane then saw as rises."""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "log"
            p.write_text(log(f"    cd /Users/rickb/dev/V{A}:111:17: \x1b[1;33mwarning: \x1b[1;39mresult of call to 'decode(_:type:)' is unused\x1b[0;0m [#NoUsage]"))
            self.assertEqual(ratchet.per_file(ratchet.parse_logs([p])), {A_REL: 1})

    def test_a_missing_log_is_skipped(self):
        self.assertEqual(ratchet.parse_logs([Path("/nonexistent/sensor-lane-core.log")]), set())


class Check(unittest.TestCase):
    def test_incremental_log_is_judged_per_file(self):
        """Only A was recompiled: its count is exact; B's absence means nothing."""
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 2, (B_REL, "deprecated"): 7})
            p = d / "incremental.log"
            p.write_text(log(warn(A, 10, DEPRECATED), warn(A, 11, DEPRECATED)))
            self.assertEqual(ratchet.check([p], b), ([], 2, 1))
            p.write_text(log(warn(A, 10, DEPRECATED), warn(A, 11, DEPRECATED), warn(A, 12, DEPRECATED)))
            red, n, _ = ratchet.check([p], b)
            self.assertEqual(n, 3)
            self.assertEqual(red, [f"{A_REL} [deprecated]: 3 warning(s), baseline 2 (+1)"])

    def test_a_new_swift6_blocker_behind_a_fixed_deprecation_is_red(self):
        """review 2026-10-25: a per-file COUNT let a deprecation fix pay for a new blocker."""
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 1})
            p = d / "log"
            p.write_text(log(warn(A, 1, STATIC)))
            red, _, _ = ratchet.check([p], b)
            self.assertEqual(red, [f"{A_REL} [global-static]: 1 warning(s), baseline 0 (+1)"])

    def test_a_new_file_with_a_warning_is_red(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 1})
            p = d / "log"
            p.write_text(log(warn(B, 1, "fresh warning in a new file")))
            red, _, _ = ratchet.check([p], b)
            self.assertEqual(red, [f"{B_REL} [other]: 1 warning(s), baseline 0 (+1)"])

    def test_missing_baseline_is_one_loud_red_not_one_per_file(self):
        """review 2026-10-25: a fresh checkout must not read as 325 red files."""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "log"
            p.write_text(log(warn(A, 1, "w"), warn(B, 1, "w")))
            red, _, _ = ratchet.check([p], Path(d) / "absent.tsv")
            self.assertEqual(len(red), 1, red)
            self.assertIn("absent.tsv", red[0])


class Update(unittest.TestCase):
    def test_fewer_warnings_is_green_and_update_lowers(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 2}, start=2)
            p = d / "clean.log"
            p.write_text(log(compiled(A), warn(A, 10, DEPRECATED)))
            self.assertEqual(ratchet.check([p], b)[0], [])
            rc = ratchet.main(["--baseline", str(b), "update", str(p), "--clean", "--recorded", "2026-10-26"])
            self.assertEqual(rc, 0)
            counts, meta = ratchet.read_baseline(b)
            self.assertEqual(counts, {(A_REL, "deprecated"): 1})
            self.assertEqual(meta["start_total"], "2", "the denominator never moves")
            self.assertEqual(meta["recorded"], "2026-10-26")

    def test_update_refuses_a_rise_without_force_and_without_clean(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 1}, start=1)
            p = d / "clean.log"
            p.write_text(log(compiled(A), warn(A, 10, DEPRECATED), warn(A, 11, DEPRECATED)))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p)]), 2, "needs --clean")
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 1)
            self.assertEqual(ratchet.read_baseline(b)[0], {(A_REL, "deprecated"): 1}, "untouched")
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean", "--force"]), 0)
            self.assertEqual(ratchet.read_baseline(b)[0], {(A_REL, "deprecated"): 2})

    def test_update_refuses_a_collapse_without_force(self):
        """review 2026-10-25: --clean was a self-assertion. A file that had warnings, still
        exists and shows neither warnings nor a compile line is an unproven fall."""
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            still_here = REPO / "VideoScan/VideoScanCore/Package.swift"   # a real .swift on disk that "had warnings"
            rel = still_here.relative_to(REPO).as_posix()
            b = baseline(d, {(A_REL, "deprecated"): 2, (rel, "deprecated"): 7}, start=9)
            p = d / "incremental.log"
            p.write_text(log(compiled(A), warn(A, 1, DEPRECATED), warn(A, 2, DEPRECATED)))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 1)
            self.assertEqual(ratchet.read_baseline(b)[0].get((rel, "deprecated")), 7, "untouched")
            # The same log WITH compile evidence for the file is a proven fall.
            p.write_text(log(compiled(A, still_here), warn(A, 1, DEPRECATED), warn(A, 2, DEPRECATED)))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 0)
            self.assertEqual(ratchet.read_baseline(b)[0], {(A_REL, "deprecated"): 2})

    def test_a_deleted_file_may_vanish_without_evidence(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = baseline(d, {(A_REL, "deprecated"): 2, ("VideoScan/Gone.swift", "deprecated"): 3}, start=5)
            p = d / "clean.log"
            p.write_text(log(compiled(A), warn(A, 1, DEPRECATED), warn(A, 2, DEPRECATED)))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 0)
            self.assertEqual(ratchet.read_baseline(b)[0], {(A_REL, "deprecated"): 2})

    def test_first_baseline_is_written_and_fixes_the_denominator(self):
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = d / "new.tsv"
            p = d / "clean.log"
            p.write_text(log(warn(A, 1, "w"), warn(B, 1, "w"), warn(B, 2, "w")))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 0)
            counts, meta = ratchet.read_baseline(b)
            self.assertEqual(sum(counts.values()), 3)
            self.assertEqual(meta["start_total"], "3")

    def test_baseline_header_survives_a_second_update_without_duplicates(self):
        """review 2026-10-25: `# total` and the column comment were read back as meta."""
        with tempfile.TemporaryDirectory() as d:
            d = Path(d)
            b = d / "b.tsv"
            p = d / "log"
            p.write_text(log(compiled(A), warn(A, 1, "w"), warn(A, 2, "w")))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 0)
            p.write_text(log(compiled(A), warn(A, 1, "w")))
            self.assertEqual(ratchet.main(["--baseline", str(b), "update", str(p), "--clean"]), 0)
            text = b.read_text().splitlines()
            self.assertEqual([l for l in text if l.startswith("# total")], ["# total 1"])
            self.assertEqual(len([l for l in text if l.startswith("# start_total")]), 1)
            self.assertEqual(len([l for l in text if l.startswith("# count")]), 1)


class Progress(unittest.TestCase):
    def test_percent_is_cleared_over_start_and_99_until_the_app_flips(self):
        with tempfile.TemporaryDirectory() as d:
            b = Path(d) / "baseline.tsv"
            ratchet.write_baseline({(A_REL, "deprecated"): 100}, {"start_total": "400", "recorded": "x"}, b)
            line = ratchet.progress(b)
            self.assertIn("75%", line)
            self.assertIn("100 of 400 warnings remain", line)
            ratchet.write_baseline({}, {"start_total": "400", "recorded": "x"}, b)
            line = ratchet.progress(b)
            _, app = ratchet.language_modes()
            if app == "Swift 6":
                self.assertIn("100%", line)
            else:
                self.assertIn("99%", line, "zero warnings is not 100 % until SWIFT_VERSION = 6")
                self.assertIn("flips at 0", line)

    def test_core_is_in_swift_6_mode(self):
        """Stage 1 (2026-10-25): VideoScanCore compiles in Swift 6 language mode."""
        core, _ = ratchet.language_modes()
        self.assertEqual(core, "Swift 6")

    def test_the_committed_baseline_exists_and_is_well_formed(self):
        """Stage 0 (2026-10-25): the baseline is part of the tree, with its denominator."""
        counts, meta = ratchet.read_baseline()
        self.assertTrue(ratchet.BASELINE.exists(), "scripts/warnings_baseline.tsv is committed")
        self.assertIn("start_total", meta)
        self.assertGreater(int(meta["start_total"]), 0)
        self.assertLessEqual(sum(counts.values()), int(meta["start_total"]), "the ratchet only goes down")


if __name__ == "__main__":
    unittest.main()
