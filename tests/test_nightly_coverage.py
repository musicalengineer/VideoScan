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
