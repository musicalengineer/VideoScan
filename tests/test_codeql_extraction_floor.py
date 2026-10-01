#!/usr/bin/env python3
"""Tests for scripts/codeql_extraction_floor.py (GH #171).

The guard exists because CodeQL once reported "0 alerts" while extracting
1 of 1,283 files. So the important tests are the FAIL-CLOSED ones: a
missing SARIF, or a SARIF with no extraction diagnostics, must fail the
job, never pass it.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FIX = REPO / "tests" / "fixtures" / "nightly_findings"
sys.path.insert(0, str(REPO / "scripts"))

import codeql_extraction_floor as cf  # noqa: E402

TRACKED = [
    "VideoScan/VideoScan/App/A.swift",
    "VideoScan/VideoScan/App/B.swift",
    "VideoScan/VideoScanCore/Sources/VideoScanCore/C.swift",
    "VideoScan/VideoScanCore/Sources/VideoScanCore/D.swift",
    "VideoScan/VideoScanCore/Package.swift",
    "VideoScan/VideoScanTests/ATests.swift",
    "VideoScan/VideoScanUITests/UITests.swift",
    "VideoScan/VideoScanCore/Tests/VideoScanCoreTests/CTests.swift",
    "VideoScan/VideoScanCore/Sources/videoscan-tree-ingest/main.swift",
    "TestDriver/TestDriver/main.swift",
    "tools/foo/bar.swift",
    "scripts/x.swift",
    "swift_cli/PersonFinder.swift",
    "VideoScan/SourcePackages/checkouts/mlx-swift/Source/MLX/Array.swift",
]


def write_tracked(tmp_path: Path) -> Path:
    p = tmp_path / "tracked.txt"
    p.write_text("\n".join(TRACKED) + "\n")
    return p


def test_scope_excludes_tests_tools_and_vendored():
    scope = [p for p in TRACKED if cf.in_scope(p)]
    assert scope == [
        "VideoScan/VideoScan/App/A.swift",
        "VideoScan/VideoScan/App/B.swift",
        "VideoScan/VideoScanCore/Sources/VideoScanCore/C.swift",
        "VideoScan/VideoScanCore/Sources/VideoScanCore/D.swift",
        "VideoScan/VideoScanCore/Package.swift",
    ]


def test_fixture_counts_and_floor(tmp_path):
    extracted, errors = cf.read_extraction(FIX / "codeql.sarif")
    r = cf.evaluate(TRACKED, extracted, errors, 0.80)
    # A, B, C extracted of A, B, C, D, Package.swift = 3/5 = 60%.
    assert (r["extracted_in_scope"], r["in_scope"]) == (3, 5)
    assert not r["ok"]
    assert r["extraction_errors"] == 1
    assert r["files_with_extraction_errors"] == {"VideoScan/VideoScan/App/B.swift": 1}
    assert cf.evaluate(TRACKED, extracted, errors, 0.60)["ok"]


def test_main_exit_codes(tmp_path):
    tracked = write_tracked(tmp_path)
    out = tmp_path / "cov.json"
    assert cf.main([str(FIX / "codeql.sarif"), "--floor", "0.8", "--tracked-list", str(tracked),
                    "--json-out", str(out)]) == 1
    assert json.loads(out.read_text())["ratio"] == 0.6
    assert cf.main([str(FIX / "codeql.sarif"), "--floor", "0.5", "--tracked-list", str(tracked)]) == 0


def test_missing_sarif_fails_closed(tmp_path):
    assert cf.main([str(tmp_path / "nope.sarif"), "--tracked-list", str(write_tracked(tmp_path))]) == 1


def test_sarif_without_extraction_diagnostics_fails_closed(tmp_path):
    sarif = tmp_path / "empty.sarif"
    sarif.write_text(json.dumps({"runs": [{"results": [], "invocations": [{}]}]}))
    assert cf.main([str(sarif), "--floor", "0.0", "--tracked-list", str(write_tracked(tmp_path))]) == 1


def test_uri_normalisation():
    assert cf.normalise_uri("file:///Users/runner/work/VideoScan/VideoScan/VideoScan/X.swift") == "VideoScan/X.swift"
    assert cf.normalise_uri("./VideoScan/X.swift") == "VideoScan/X.swift"
    assert cf.normalise_uri("VideoScan/X.swift") == "VideoScan/X.swift"


def test_sensor_real_repo_scope_is_app_plus_core():
    """Sensor: the live denominator. If someone adds a new top-level Swift
    target the scope rules do not know about, this keeps it from silently
    landing in (or out of) the floor."""
    tracked = cf.tracked_swift_files(REPO)
    scope = [p for p in tracked if cf.in_scope(p)]
    assert len(scope) > 800
    assert all(p.startswith(("VideoScan/VideoScan/", "VideoScan/VideoScanCore/")) for p in scope)
    assert not any("/VideoScanTests/" in p or "/Tests/" in p for p in scope)
