"""scripts/sensor_lane.py — the pre-merge sensor lane (GH #360 item 1).

Pins the DISCOVERY (what the lane runs is found from the test source, so it
must find the real sensors — including the one that stayed red 11 nights — and
leave ordinary behaviour tests out), the identifier shapes xcodebuild and
swift test need, and the verdict (a red sensor or an empty run is never green).
No build here: `run` itself is exercised by scripts/run_sensors.sh."""
from __future__ import annotations

import importlib.util
import json
import re
import shutil
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("sensor_lane", ROOT / "scripts" / "sensor_lane.py")
sl = importlib.util.module_from_spec(spec)
sys.modules["sensor_lane"] = sl
spec.loader.exec_module(sl)

APP = sl.discover(sl.APP_TESTS, "VideoScanTests")
CORE = sl.discover(sl.CORE_TESTS, "VideoScanCoreTests")
APP_IDS = {s.xcode_id for s in APP}
CORE_IDS = {s.xcode_id for s in CORE}


def test_the_sensor_that_stayed_red_eleven_nights_is_in_the_lane():
    # FixityStampVolumeIdentityTests walks the tree from #filePath (no SourceTree).
    assert any(i.endswith("/noStoredStampIsComparedByDeviceNumberOutsideTheOneComparison()") for i in APP_IDS)


def test_known_source_scan_sensors_are_found_both_ways():
    # SourceTree-based, in a *Sensor* suite, and the helper's own suite.
    assert any(i.startswith("VideoScanTests/CatalogJSONReadSensorTests/") for i in APP_IDS)
    assert any(i.startswith("VideoScanTests/AtomicFilePublishSensorTests/") for i in APP_IDS)
    assert any(i.startswith("VideoScanTests/SourceTreeTests/") for i in APP_IDS)
    assert any(i.startswith("VideoScanCoreTests/CatalogStoreSensorTests/") for i in CORE_IDS)


def test_the_lane_is_a_slice_not_the_suite():
    # ~12k app tests exist; the lane is the source-scan slice. If discovery
    # ever swallows everything (a helper-name collision did, in development),
    # the lane stops being "seconds" — this catches it.
    total_tests = sum(len(re.findall(r"@Test\b", p.read_text(errors="replace")))
                      for p in sl.swift_files(sl.APP_TESTS))
    assert 200 < len(APP) < total_tests // 5, (len(APP), total_tests)
    assert 0 < len(CORE) < 200


def test_identifiers_have_the_shapes_the_tools_expect():
    for s in APP + CORE:
        assert re.match(r"^VideoScan(Core)?Tests/[A-Za-z_]\w*(/[A-Za-z_]\w*)*/[A-Za-z_]\w*(\([A-Za-z_:]*\))?$", s.xcode_id), s.xcode_id
    swift_testing = next(s for s in APP if s.params != "xctest")
    assert swift_testing.xcode_id.endswith("()") or swift_testing.xcode_id.endswith(":)")
    for s in CORE:
        assert re.compile(s.core_filter).search(f"{s.target}.{'.'.join(s.type_path)}/{s.func}"
                                                + ("" if s.params == "xctest" else f"({s.params})"))


def test_helper_resolution_is_scoped_to_its_file_or_type():
    src = '''
    struct ReadsSourceTests {
        static func source() throws -> String { try SourceTree.appSource(named: "A.swift") }
        @Test func usesTheHelper() throws { #expect(try Self.source().contains("x")) }
        @Test func doesNot() { #expect(1 == 1) }
    }
    '''
    decls = sl.parse(src)
    tests = {d.name for d in decls if d.kind == "func" and d.is_test}
    assert tests == {"usesTheHelper", "doesNot"}
    helper = next(d for d in decls if d.name == "source")
    assert sl.reads_source(src[helper.start:helper.end])
    assert not helper.local


def test_braces_in_strings_and_comments_do_not_break_spans():
    src = '''
    struct T {
        // a stray { in a comment
        @Test func a() { let s = "}{"; let r = #"}"#; _ = (s, r) }
        @Test func b() { /* } */ }
    }
    '''
    names = [(d.name, d.type_path) for d in sl.parse(src) if d.kind == "func"]
    assert names == [("a", ["T"]), ("b", ["T"])]


def test_parameterised_and_xctest_identifiers():
    src = '''
    struct P { @Test(arguments: [1, 2]) func each(_ n: Int) {} }
    final class X: XCTestCase { func testThing() {} func helper() {} }
    '''
    by = {d.name: d for d in sl.parse(src) if d.kind == "func"}
    assert by["each"].is_test and by["each"].params == "_:"
    assert by["testThing"].is_test and by["testThing"].params == "xctest"
    assert not by["helper"].is_test


def test_counting_the_log_names_every_failure():
    log = "\n".join([
        "✔ Test good() passed after 0.001 seconds.",
        "✘ Test noStoredStampIsComparedByDeviceNumberOutsideTheOneComparison() recorded an issue at F.swift:1:1: Expectation failed",
        "✘ Test noStoredStampIsComparedByDeviceNumberOutsideTheOneComparison() failed after 0.010 seconds with 1 issue.",
        "Test Case '-[VideoScanCoreTests.CatalogStoreSensorTests testOnlyTheStoreOpensTheDB]' failed (0.002 seconds).",
        "✘ Test run with 3 tests in 2 suites failed after 0.5 seconds with 2 issues.",
    ])
    passed, failed, names = sl.count(log)
    assert passed == 1 and failed == 2
    assert "noStoredStampIsComparedByDeviceNumberOutsideTheOneComparison()" in names
    assert "VideoScanCoreTests.CatalogStoreSensorTests.testOnlyTheStoreOpensTheDB" in names


def test_a_line_torn_by_parallel_hosts_is_still_counted_and_a_torn_failure_is_named():
    """RED 2026-11-09: the same tree counted 716 passed on one run and 717 on the next.
    One "Test case … passed on" line had lost its "Test " to another host's output."""
    log = "\n".join([
        "Test case 'A/one()' passed on 'My Mac - VideoScan (1)' (0.001 seconds)",
        "Test ",
        "case 'HallieShellCLITests/eileensChildren()' passed on 'My Mac - VideoScan (1)' (0.150 seconds)",
        "case 'B/two()' failed on 'My Mac - VideoScan (2)' (0.010 seconds)",
        "Test case 'C/three(_:)' passed on 'My Mac - VideoScan (2)' (0.002 seconds)",
        "a line that only mentions case 'D/four()' passed on something is not at the start",
    ])
    passed, failed, names = sl.count(log)
    assert (passed, failed, names) == (3, 1, ["B/two()"])


def test_a_torn_pass_line_never_hides_a_failure_printed_the_other_way():
    """Codex #276 F8 (RED first): once a torn parallel PASS line was recognised, a
    "✘ Test broken() failed after" line in the same log was no longer counted."""
    log = "\n".join([
        "✘ Test broken() failed after 0.01 seconds.",
        "Test ",
        "case 'Good/ok()' passed on 'My Mac (1)' (0.001 seconds)",
    ])
    assert sl.count(log) == (1, 1, ["broken()"])
    # The same failure printed both ways is one failure, named once by its fuller name.
    both = "\n".join([
        "✘ Test alsoBroken() failed after 0.01 seconds with 1 issue.",
        "Test case 'Suite/alsoBroken()' failed on 'My Mac (1)' (0.010 seconds)",
        "Test case 'Good/ok()' passed on 'My Mac (1)' (0.001 seconds)",
        "✘ Test run with 2 tests in 2 suites failed after 0.5 seconds with 1 issue.",
    ])
    assert sl.count(both) == (1, 1, ["Suite/alsoBroken()"])
    # The XCTest form beside a torn parallel pass (Codex #277).
    xc = "\n".join([
        "Test Case '-[VideoScanTests.Suite testBroken]' failed (0.01 seconds).",
        "case 'Good/ok()' passed on 'My Mac (1)' (0.001 seconds)",
    ])
    assert sl.count(xc) == (1, 1, ["VideoScanTests.Suite.testBroken"])
    # One XCTest failure printed in both forms is one failure (Codex #279).
    twice = "\n".join([
        "Test Case '-[VideoScanTests.Suite testBroken]' failed (0.01 seconds).",
        "Test case 'Suite/testBroken()' failed on 'My Mac (1)' (0.010 seconds)",
        "Test case 'Good/ok()' passed on 'My Mac (1)' (0.001 seconds)",
    ])
    assert sl.count(twice) == (1, 1, ["Suite/testBroken()"])


def test_an_empty_run_is_never_green(monkeypatch, tmp_path, capsys):
    # The app half "ran" zero tests (a filter that matched nothing): red.
    monkeypatch.setattr(sl, "manifest_check", lambda *a, **k: ([], 0.0))
    monkeypatch.setattr(sl, "run_app", lambda *a, **k: (0, 0, [], 0, 1.0))
    monkeypatch.setattr(sl, "run_core", lambda *a, **k: (3, 0, [], 0, 1.0))
    assert sl.main(["run", "--log-dir", str(tmp_path)]) == 1
    assert "SENSOR LANE RED" in capsys.readouterr().err
    monkeypatch.setattr(sl, "run_app", lambda *a, **k: (700, 0, [], 0, 1.0))
    assert sl.main(["run", "--log-dir", str(tmp_path)]) == 0
    monkeypatch.setattr(sl, "run_app", lambda *a, **k: (699, 1, ["x()"], 65, 1.0))
    assert sl.main(["run", "--log-dir", str(tmp_path)]) == 1
    assert "VideoScanTests: x()" in capsys.readouterr().err


# ---- GH #400: the gauntlet manifest is validated in the lane ----------------

STAGES = ["unit", "regression", "integration", "performance", "hallie", "stress", "ui"]


def _tree_with_manifest(root: Path, listed: list, declared: list) -> Path:
    """A minimal checkout: one Python test file declaring `declared`, and a
    manifest that lists `listed` for it (python is unadapted, so it is blocked)."""
    (root / "tests").mkdir(parents=True)
    (root / "tests" / "test_x.py").write_text("".join(f"def {n}():\n    pass\n\n" for n in declared))
    (root / "scripts" / "gauntlet").mkdir(parents=True)
    manifest = {
        "schema": 1,
        "assignments": [{"path": "tests/test_x.py", "kind": "python", "stage": "unit", "suites": ["test_x.py"],
                         "tests": listed, "blocked_reason": "no python adapter"}],
        "stages": [{"name": n, "expected_floor": 1, "selectors": [], "package_selectors": [],
                    "blocked": [{"name": "tests/test_x.py", "reason": "no python adapter"}] if n == "unit" else []}
                   for n in STAGES],
    }
    (root / "scripts" / "gauntlet" / "manifest.json").write_text(json.dumps(manifest))
    return root


needs_swift = pytest.mark.skipif(sys.platform != "darwin" or shutil.which("swift") is None,
                                 reason="macOS-only: runs scripts/gauntlet/inventory.swift with swift")


@needs_swift
def test_a_test_added_to_an_existing_file_without_a_manifest_edit_is_an_error(tmp_path):
    """RED first (GH #400, 2026-10-30 and 11/06, 11/08, 11/10): a new test function in
    an EXISTING file passed pre-commit and the lane, and blocked the M4 gauntlet in 1 s."""
    stale = _tree_with_manifest(tmp_path / "stale", listed=["test_a"], declared=["test_a", "test_b"])
    errors, _ = sl.manifest_check(stale)
    assert errors == ["tests inventory changed (unassigned or stale): tests/test_x.py"]


@needs_swift
def test_a_manifest_that_matches_the_source_has_no_errors(tmp_path):
    good = _tree_with_manifest(tmp_path / "good", listed=["test_a", "test_b"], declared=["test_a", "test_b"])
    assert sl.manifest_check(good)[0] == []


@needs_swift
def test_a_manifest_that_cannot_be_checked_is_an_error_not_a_pass(tmp_path):
    # No manifest at all, and one that is not JSON: the validator exits 2 with no
    # errors list. "Could not check" must never read as "nothing wrong".
    (tmp_path / "none").mkdir()
    errors, _ = sl.manifest_check(tmp_path / "none")
    assert len(errors) == 1 and "could not be validated" in errors[0]
    bad = _tree_with_manifest(tmp_path / "bad", listed=["test_a"], declared=["test_a"])
    (bad / "scripts" / "gauntlet" / "manifest.json").write_text("{ not json")
    errors, _ = sl.manifest_check(bad)
    assert len(errors) == 1 and "could not be validated" in errors[0]


@needs_swift
def test_this_checkouts_manifest_is_current():
    # Truth: the real validator on the real tree (what the gauntlet preflight runs).
    errors, _ = sl.manifest_check(ROOT)
    assert errors == [], errors


def test_a_stale_manifest_makes_the_lane_red_and_says_how_to_refresh(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(sl, "run_app", lambda *a, **k: (700, 0, [], 0, 1.0))
    monkeypatch.setattr(sl, "run_core", lambda *a, **k: (3, 0, [], 0, 1.0))
    monkeypatch.setattr(sl, "manifest_check",
                        lambda *a, **k: (["tests inventory changed (unassigned or stale): tests/test_x.py"], 5.0))
    assert sl.main(["run", "--log-dir", str(tmp_path)]) == 1
    out = capsys.readouterr()
    assert "SENSOR LANE RED" in out.err
    assert "gauntlet manifest: tests inventory changed (unassigned or stale): tests/test_x.py" in out.err
    assert "inventory.swift --discover" in out.err and "scripts/gauntlet/manifest.json" in out.err
    assert "sensor lane GREEN" not in out.out
    # ... also when only one half is asked for: the stamp covers the tree either way.
    assert sl.main(["run", "--app-only", "--log-dir", str(tmp_path)]) == 1
    assert sl.main(["run", "--core-only", "--log-dir", str(tmp_path)]) == 1
    monkeypatch.setattr(sl, "manifest_check", lambda *a, **k: ([], 5.0))
    assert sl.main(["run", "--log-dir", str(tmp_path)]) == 0
    assert "sensor lane GREEN (703 tests)" in capsys.readouterr().out
