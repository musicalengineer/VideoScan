"""Sensors for tools/nightly_coverage.py (GH #239) — folder aggregation only, no xcodebuild."""
import importlib.util
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("nightly_coverage", ROOT / "tools/nightly_coverage.py")
nc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(nc)


def p(rel):
    return str(nc.REPO / rel)


def test_folders_split_logic_from_views_and_core_from_app():
    files = [
        (p("VideoScan/VideoScan/FamilyTree/RecordFinderFiling.swift"), 80, 100),
        (p("VideoScan/VideoScan/FamilyTree/FamilyTreeView.swift"), 0, 400),
        (p("VideoScan/VideoScanCore/Sources/VideoScanCore/RollCall.swift"), 90, 100),
        (p("VideoScan/VideoScanTests/Whatever.swift"), 5, 5),  # not production → ignored
    ]
    f = nc.aggregate(files)
    assert set(f) == {"FamilyTree", "Core"}
    assert f["FamilyTree"]["executable"] == 500
    assert f["FamilyTree"]["logic_pct"] == 80.0      # view excluded from logic %
    assert f["FamilyTree"]["pct"] == 16.0
    assert f["Core"]["pct"] == 90.0


def test_zero_coverage_logic_files_are_flagged_but_small_ones_are_not():
    files = [
        (p("VideoScan/VideoScan/Archive/Big.swift"), 0, 120),
        (p("VideoScan/VideoScan/Archive/Tiny.swift"), 0, 10),
        (p("VideoScan/VideoScan/Archive/ArchiveSheet.swift"), 0, 300),  # a view: never flagged
    ]
    f = nc.aggregate(files)["Archive"]
    assert f["zero_files"] == ["VideoScan/VideoScan/Archive/Big.swift"]


def test_core_codecov_json_keeps_only_core_sources(tmp_path):
    blob = {"data": [{"files": [
        {"filename": "/x/VideoScan/VideoScanCore/Sources/VideoScanCore/A.swift",
         "summary": {"lines": {"count": 10, "covered": 7}}},
        {"filename": "/x/.build/checkouts/dep/B.swift", "summary": {"lines": {"count": 10, "covered": 0}}},
    ]}]}
    path = tmp_path / "cov.json"
    path.write_text(json.dumps(blob))
    out = nc.core_files(path)
    assert out == [("/x/VideoScan/VideoScanCore/Sources/VideoScanCore/A.swift", 7, 10)]


def test_a_file_declaring_a_swiftui_view_counts_as_a_view(tmp_path):
    f = tmp_path / "SomePanel.swift"
    f.write_text("import SwiftUI\nstruct SomePanel: View {\n var body: some View { Text(\"x\") }\n}\n")
    g = tmp_path / "Logic.swift"
    g.write_text("struct Logic { func f() -> Int { 1 } }\n")
    assert nc.is_view(str(f))
    assert not nc.is_view(str(g))


class _Tool:
    """Stands in for xcrun: records the calls, answers like llvm-profdata / llvm-cov."""

    def __init__(self, export_stdout, merge_rc=0, export_rc=0):
        self.calls, self.export_stdout, self.merge_rc, self.export_rc = [], export_stdout, merge_rc, export_rc

    def __call__(self, argv, **kw):
        from types import SimpleNamespace
        self.calls.append(argv)
        if argv[1] == "llvm-profdata":
            return SimpleNamespace(returncode=self.merge_rc, stdout="", stderr="")
        return SimpleNamespace(returncode=self.export_rc, stdout=self.export_stdout, stderr="")


def _scratch(tmp_path, profiles=2, binary=True):
    debug = tmp_path / "core-build" / "debug"
    (debug / "codecov").mkdir(parents=True)
    for i in range(profiles):
        (debug / "codecov" / f"run{i}.profraw").write_bytes(b"raw")
    if binary:
        exe = debug / "VideoScanCorePackageTests.xctest" / "Contents" / "MacOS"
        exe.mkdir(parents=True)
        (exe / "VideoScanCorePackageTests").write_bytes(b"bin")
    return tmp_path / "core-build"


def test_core_coverage_is_built_from_raw_profiles_when_swiftpm_exported_none(tmp_path):
    """RED 2026-11-09: five nights running, one failed Core test meant no codecov JSON,
    so the Core folders were silently missing from the page's coverage number."""
    report = json.dumps({"data": [{"files": [
        {"filename": "/r/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/A.swift", "summary": {"lines": {"count": 10, "covered": 7}}},
        {"filename": "/r/VideoScan/VideoScanCore/Tests/VideoScanCoreTests/ATests.swift", "summary": {"lines": {"count": 5, "covered": 5}}}]}]})
    scratch = _scratch(tmp_path)
    tool = _Tool(report)
    out = nc.export_core_coverage(scratch, since=0, run=tool)
    assert out is not None and out.name == "fallback.json"
    assert nc.core_files(out) == [("/r/VideoScan/VideoScanCore/Sources/VideoScanCore/Store/A.swift", 7, 10)]
    merge, export = tool.calls
    assert merge[:4] == ["xcrun", "llvm-profdata", "merge", "-sparse"] and sum(a.endswith(".profraw") for a in merge) == 2
    assert export[:3] == ["xcrun", "llvm-cov", "export"] and export[-1].endswith("MacOS/VideoScanCorePackageTests")
    assert any(a.startswith("-instr-profile=") and a.endswith("fallback.profdata") for a in export)


def test_no_profile_no_binary_or_a_failed_tool_is_no_coverage_never_a_guess(tmp_path):
    good = json.dumps({"data": []})
    assert nc.export_core_coverage(_scratch(tmp_path / "a", profiles=0), since=0, run=_Tool(good)) is None
    assert nc.export_core_coverage(_scratch(tmp_path / "b", binary=False), since=0, run=_Tool(good)) is None
    assert nc.export_core_coverage(_scratch(tmp_path / "c"), since=0, run=_Tool(good, merge_rc=1)) is None
    assert nc.export_core_coverage(_scratch(tmp_path / "d"), since=0, run=_Tool(good, export_rc=1)) is None
    assert nc.export_core_coverage(_scratch(tmp_path / "e"), since=0, run=_Tool("{ torn")) is None
    assert nc.export_core_coverage(_scratch(tmp_path / "f"), since=0, run=_Tool("")) is None
    assert not (tmp_path / "e" / "core-build" / "debug" / "codecov" / "fallback.json").exists()


def test_profiles_from_before_todays_run_are_not_todays_coverage(tmp_path):
    """Codex #275 F7 (RED first): yesterday's failed run left profiles and a binary in
    the cache; today's build failed before replacing them; the fallback published
    yesterday's 90 % under today's date and commit."""
    import os
    import time
    report = json.dumps({"data": [{"files": [
        {"filename": "/r/VideoScan/VideoScanCore/Sources/VideoScanCore/A.swift", "summary": {"lines": {"count": 10, "covered": 9}}}]}]})
    scratch = _scratch(tmp_path)
    yesterday = time.time() - 86_400
    for profile in (scratch / "debug" / "codecov").glob("*.profraw"):
        os.utime(profile, (yesterday, yesterday))
    started = time.time() - 60
    tool = _Tool(report)
    assert nc.export_core_coverage(scratch, since=started, run=tool) is None
    assert tool.calls == [], "no tool is run over stale profiles"
    # One profile written by today's run: only it is merged.
    todays = scratch / "debug" / "codecov" / "today.profraw"
    todays.write_bytes(b"raw")
    out = nc.export_core_coverage(scratch, since=started, run=tool)
    assert out is not None
    merged = [a for a in tool.calls[0] if a.endswith(".profraw")]
    assert merged == [str(todays)]


def test_yesterdays_swiftpm_export_is_not_todays_coverage(tmp_path):
    """Codex #276 F7 (RED first): SwiftPM names the same JSON path every day; a build
    that failed today left yesterday's file there and it was read as today's 90 %."""
    import os
    import time
    export = tmp_path / "VideoScanCore.json"
    export.write_text("{}")
    started = time.time() - 60
    assert nc.written_since(str(export), started)
    yesterday = time.time() - 86_400
    os.utime(export, (yesterday, yesterday))
    assert not nc.written_since(str(export), started)
    assert not nc.written_since("", started) and not nc.written_since(str(tmp_path / "absent.json"), started)
    text = (ROOT / "tools" / "nightly_coverage.py").read_text()
    assert "if written_since(cov_path, core_started):" in text
    assert "if cov_path and Path(cov_path).exists():" not in text


def test_sensor_a_night_without_core_coverage_says_missing_in_capitals():
    text = (ROOT / "tools" / "nightly_coverage.py").read_text()
    assert "export_core_coverage(DD / \"core-build\", since=core_started)" in text
    assert "core coverage MISSING" in text and 'meta["core_coverage"] = "missing"' in text


# ── The lane's verdict (worker A, 2026-11-18). RED first: from 2026-10-02 the M4's 04:00 lane
# logged "core tests finished: exit 1" and then "OUTCOME ok: 23 folders …" on almost every
# night — a Core suite with 20 failed tests read as a good night. Coverage is still measured
# and published; the OUTCOME word says whether the tests under it passed.

_ST_FAILED = """\
✘ Test hundredThousandPeopleWalkAndCheckOffMain() failed after 50.601 seconds with 1 issue.
✘ Test "pause holds the job" failed after 61.587 seconds with 2 issues.
✔ Test sketchEstimatesAreWithinTolerance() passed after 0.2 seconds.
✘ Test run with 2365 tests in 339 suites failed after 432.384 seconds with 70 issues (including 27 known issues).
Executed 5 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds
Executed 222 tests, with 0 failures (0 unexpected) in 12.0 (12.1) seconds
"""
_ST_PASSED = """\
✔ Test run with 2365 tests in 339 suites passed after 300.0 seconds with 27 known issues.
Executed 222 tests, with 0 failures (0 unexpected) in 12.0 (12.1) seconds
"""


def test_core_counts_read_both_runners_and_name_the_failed_tests(tmp_path):
    log = tmp_path / "core.log"
    log.write_text(_ST_FAILED)
    counts = nc.core_counts(log)
    assert counts["tests"] == 2365 + 222 and counts["failed"] == 2
    assert counts["failed_names"][0] == "hundredThousandPeopleWalkAndCheckOffMain()"
    log.write_text(_ST_PASSED)
    assert nc.core_counts(log) == {"tests": 2587, "failed": 0, "failed_names": []}
    assert nc.core_counts(tmp_path / "absent.log") == {"tests": 0, "failed": 0, "failed_names": []}


def test_a_failed_core_suite_is_red_even_when_coverage_was_measured():
    word, why = nc.verdict(app_rc=0, core_rc=1, core={"tests": 2587, "failed": 2, "failed_names": ["a()", "b"]})
    assert word == "RED" and "core tests exit 1" in why and "2 failed" in why and "a()" in why
    assert nc.verdict(app_rc=65, core_rc=0, core={"tests": 2587, "failed": 0, "failed_names": []})[0] == "RED"
    assert nc.verdict(app_rc=0, core_rc=0, core={"tests": 2587, "failed": 0, "failed_names": []}) == ("ok", "")


def test_a_core_suite_with_no_number_is_red():
    word, why = nc.verdict(app_rc=0, core_rc=0, core={"tests": 0, "failed": 0, "failed_names": []})
    assert word == "RED" and "no Core test count" in why


def test_sensor_main_writes_the_verdict_word_and_exits_non_zero_on_red():
    text = (ROOT / "tools" / "nightly_coverage.py").read_text()
    assert "word, why = verdict(app_rc, core_rc, core_counts(" in text
    assert 'log(f"OUTCOME ok:' not in text, "the OUTCOME word comes from verdict(), never a constant ok"
    assert "return 0 if word == \"ok\" else 1" in text


# ── Its own scratch (worker A, 2026-11-18; DECISIONS 2026-11-18: once a run is summarized its scratch
# goes). The M4 kept every night's app-<day>.xcresult (~320 MB) and app log (~50 MB) under
# ~/Library/Logs/VideoScan/coverage: 2.9 GB on 11/18, growing ~370 MB a night.

def _night(out, day, xcresult=True):
    (out / f"app-{day}.log").write_text("app\n")
    (out / f"core-{day}.log").write_text("core\n")
    if xcresult:
        (out / f"app-{day}.xcresult" / "Data").mkdir(parents=True)
        (out / f"app-{day}.xcresult" / "Data" / "blob").write_bytes(b"x" * 1000)
    (out / f"coverage-{day}.json").write_text("{}")
    (out / f"coverage-{day}.md").write_text("# c\n")


def test_tidy_drops_every_result_bundle_and_keeps_a_week_of_logs(tmp_path):
    out = tmp_path / "coverage"
    out.mkdir()
    days = [f"2026-11-{d:02d}" for d in range(1, 13)]
    for day in days:
        _night(out, day)
    (out / "latest.json").write_text("{}")
    outside = tmp_path / "outside"
    (outside / "Data").mkdir(parents=True)
    (outside / "Data" / "keep").write_text("keep")
    os.symlink(outside, out / "app-2026-10-01.xcresult")
    words = nc.tidy_outputs(out, keep_logs=7)
    left = sorted(p.name for p in out.iterdir())
    assert not [n for n in left if n.endswith(".xcresult")], left
    assert [n for n in left if n.startswith("app-") and n.endswith(".log")] == [f"app-{d}.log" for d in days[-7:]]
    assert [n for n in left if n.startswith("core-")] == [f"core-{d}.log" for d in days[-7:]]
    assert all((out / f"coverage-{d}.json").exists() and (out / f"coverage-{d}.md").exists() for d in days)
    assert (out / "latest.json").exists()
    assert (outside / "Data" / "keep").read_text() == "keep", "a link was followed"
    assert not (out / "app-2026-10-01.xcresult").is_symlink(), "the link goes as itself"
    assert "result bundles 13" in words and "logs 10" in words


def test_sensor_main_tidies_after_the_report_is_written():
    text = (ROOT / "tools" / "nightly_coverage.py").read_text()
    report, tidy = text.index("    write_report(folders, meta)\n    publish_metrics()"), text.index("tidy_outputs(OUT")
    assert tidy > report, "the scratch goes only once the report is written"
