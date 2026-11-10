"""Sensors for tools/nightly_coverage.py (GH #239) — folder aggregation only, no xcodebuild."""
import importlib.util
import json
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


def test_sensor_a_night_without_core_coverage_says_missing_in_capitals():
    text = (ROOT / "tools" / "nightly_coverage.py").read_text()
    assert "export_core_coverage(DD / \"core-build\", since=core_started)" in text
    assert "core coverage MISSING" in text and 'meta["core_coverage"] = "missing"' in text
