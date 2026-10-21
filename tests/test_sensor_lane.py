"""scripts/sensor_lane.py — the pre-merge sensor lane (GH #360 item 1).

Pins the DISCOVERY (what the lane runs is found from the test source, so it
must find the real sensors — including the one that stayed red 11 nights — and
leave ordinary behaviour tests out), the identifier shapes xcodebuild and
swift test need, and the verdict (a red sensor or an empty run is never green).
No build here: `run` itself is exercised by scripts/run_sensors.sh."""
from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

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


def test_an_empty_run_is_never_green(monkeypatch, tmp_path, capsys):
    # The app half "ran" zero tests (a filter that matched nothing): red.
    monkeypatch.setattr(sl, "run_app", lambda *a, **k: (0, 0, [], 0, 1.0))
    monkeypatch.setattr(sl, "run_core", lambda *a, **k: (3, 0, [], 0, 1.0))
    assert sl.main(["run", "--log-dir", str(tmp_path)]) == 1
    assert "SENSOR LANE RED" in capsys.readouterr().err
    monkeypatch.setattr(sl, "run_app", lambda *a, **k: (700, 0, [], 0, 1.0))
    assert sl.main(["run", "--log-dir", str(tmp_path)]) == 0
    monkeypatch.setattr(sl, "run_app", lambda *a, **k: (699, 1, ["x()"], 65, 1.0))
    assert sl.main(["run", "--log-dir", str(tmp_path)]) == 1
    assert "VideoScanTests: x()" in capsys.readouterr().err
