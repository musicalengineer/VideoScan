"""Weekly sanitizer runner + morning alert (2026-10-04): the log parser, the
status precedence, and the digest lines. Synthetic logs only."""
import datetime as dt
import os
import importlib.util
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def _load(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


ws = _load("weekly_sanitizer")
alert = _load("sanitizer_alert")

ASAN_LOG = """
◇ Test run started.
==4242==ERROR: AddressSanitizer: heap-use-after-free on address 0x6020 at pc 0x1
READ of size 8 at 0x6020 thread T0
SUMMARY: AddressSanitizer: heap-use-after-free ArchiveView.swift:78 in closure
==4242==ERROR: AddressSanitizer: heap-use-after-free on address 0x6030 at pc 0x1
SUMMARY: AddressSanitizer: heap-use-after-free ArchiveView.swift:78 in closure
✔ Test run with 990 tests in 158 suites passed after 120.0 seconds.
** TEST SUCCEEDED **
"""

GREEN_LOG = "✔ Test run with 990 tests in 158 suites passed after 120.0 seconds.\n** TEST SUCCEEDED **\n"


def test_findings_are_counted_and_deduplicated():
    p = ws.parse_log(ASAN_LOG)
    assert p["reports"] == 2
    assert p["unique_findings"] == ["AddressSanitizer: heap-use-after-free ArchiveView.swift:78 in closure"]
    assert p["tests"] == 990 and p["suites"] == 158
    assert ws.status_for(p, timed_out=False) == "findings"


def test_findings_beat_timeout_and_failures():
    p = ws.parse_log(ASAN_LOG + "** BUILD FAILED **\n")
    assert ws.status_for(p, timed_out=True) == "findings"


def test_status_precedence_without_findings():
    assert ws.status_for(ws.parse_log(GREEN_LOG), timed_out=False) == "ok"
    assert ws.status_for(ws.parse_log(GREEN_LOG), timed_out=True) == "timeout"
    assert ws.status_for(ws.parse_log("** BUILD FAILED **\n"), timed_out=False) == "build-failed"
    failing = "✘ Test fooBar() failed after 0.1 seconds.\n✘ Test run with 3 tests in 1 suite failed after 1 seconds.\n"
    p = ws.parse_log(failing)
    assert ws.status_for(p, timed_out=False) == "tests-failed"
    assert p["failed_tests"] == ["fooBar"]
    assert ws.status_for(ws.parse_log("nothing here"), timed_out=False) == "no-tests-ran"


def test_tsan_report_shape():
    log = "WARNING: ThreadSanitizer: data race (pid=1)\nSUMMARY: ThreadSanitizer: data race VideoRecord.swift:42 in setter\n" + GREEN_LOG
    p = ws.parse_log(log)
    assert p["unique_findings"] == ["ThreadSanitizer: data race VideoRecord.swift:42 in setter"]
    assert ws.status_for(p, timed_out=False) == "findings"


def _row(status, started="2026-10-10T07:00:00-04:00", **extra):
    return {"kind": "address", "started": started, "sha": "abc1234", "status": status, "log": "/tmp/x.log", **extra}


NOW = dt.datetime.fromisoformat("2026-10-11T12:00:00-04:00")


def test_alert_is_quiet_when_green_or_stale():
    assert alert.lines_for(_row("ok"), NOW, 8) == []
    assert alert.lines_for(_row("findings", started="2026-09-01T07:00:00-04:00"), NOW, 8) == []


def test_alert_shouts_findings_with_the_list():
    lines = alert.lines_for(_row("findings", unique_findings=["AddressSanitizer: x", "AddressSanitizer: y"]), NOW, 8)
    assert lines[0].startswith("🔴 Address Sanitizer") and "2 finding(s)" in lines[0]
    assert lines[1:] == ["     • AddressSanitizer: x", "     • AddressSanitizer: y"]


def test_alert_flags_failures_and_skips():
    assert alert.lines_for(_row("build-failed"), NOW, 8)[0].startswith("🔴")
    assert "timed out" in alert.lines_for(_row("timeout"), NOW, 8)[0]
    assert alert.lines_for(_row("skipped-busy", reason="another xcodebuild is running"), NOW, 8)[0].startswith("🟡")


def test_alert_main_reads_latest_files(tmp_path, capsys):
    (tmp_path / "latest-thread.json").write_text(json.dumps({**_row("tests-failed"), "kind": "thread",
                                                             "failed_tests": ["raceTest"]}))
    (tmp_path / "latest-address.json").write_text("not json")
    alert.main(["--dir", str(tmp_path), "--now", NOW.isoformat()])
    out = capsys.readouterr().out
    assert "Thread Sanitizer" in out and "raceTest" in out


def test_a_link_failure_reads_as_build_failed_not_no_tests():
    log = ("ld: symbol(s) not found for architecture arm64\nclang: error: linker command failed with exit code 1\n"
           "Testing failed:\n\tTesting cancelled because the build failed.\n** TEST FAILED **\n")
    assert ws.status_for(ws.parse_log(log), timed_out=False) == "build-failed"


def test_a_relaunched_test_host_is_a_crash_not_a_pass():
    log = ("Test Suite 'VideoScanTests.xctest' started at 2026-10-05 04:51:05.147.\n"
           "Test Suite 'VideoScanTests.xctest' started at 2026-10-05 05:01:15.667.\n" + GREEN_LOG)
    p = ws.parse_log(log)
    assert p["host_restarts"] == 1
    assert ws.status_for(p, timed_out=False) == "host-crashed"
    line = alert.lines_for(_row("host-crashed", host_restarts=1), NOW, 8)[0]
    assert line.startswith("🔴") and "crashed 1×" in line


# ── Stage 2 (2026-10-25): Release, Core + app, UBSan beside ASan, a catalog subset ──

def test_ubsan_runtime_errors_count_as_findings():
    log = ("VideoScan/Media/Frame.swift:40:12: runtime error: signed integer overflow: 2147483647 + 1\n"
           "SUMMARY: UndefinedBehaviorSanitizer: signed-integer-overflow Frame.swift:40:12\n" + GREEN_LOG)
    p = ws.parse_log(log)
    assert p["reports"] == 1
    assert p["unique_findings"] == ["UndefinedBehaviorSanitizer: signed-integer-overflow Frame.swift:40:12"]
    assert ws.status_for(p, timed_out=False) == "findings"


def test_xctest_executed_line_adds_to_the_count_and_an_xctest_failure_is_a_failure():
    """Core and the app mix XCTest and Swift Testing; `Test run with N tests` is only the latter half."""
    log = ("Test Case '-[VideoScanCoreTests.GRDBTests testOpen]' passed (0.1 seconds).\n"
           "Test Suite 'All tests' passed at 2026-10-25 05:00:00.000.\n"
           "\t Executed 223 tests, with 0 failures (0 unexpected) in 9.1 (9.2) seconds\n"
           "✔ Test run with 1650 tests in 200 suites passed after 300.0 seconds.\n")
    p = ws.parse_log(log)
    assert p["tests"] == 1873
    assert ws.status_for(p, timed_out=False) == "ok"
    red = ("Test Case '-[VideoScanCoreTests.GRDBTests testOpen]' failed (0.1 seconds).\n"
           "\t Executed 223 tests, with 1 failure (0 unexpected) in 9.1 (9.2) seconds\n"
           "✔ Test run with 1650 tests in 200 suites passed after 300.0 seconds.\n")
    p = ws.parse_log(red)
    assert p["failed_tests"] == ["testOpen"]
    assert ws.status_for(p, timed_out=False) == "tests-failed"


def test_merge_folds_targets_findings_win_and_counts_add():
    app = ws.parse_log(GREEN_LOG)
    core = ws.parse_log("WARNING: ThreadSanitizer: data race (pid=1)\nSUMMARY: ThreadSanitizer: data race Store.swift:9 in commit\n"
                        "\t Executed 1873 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\n")
    m = ws.merge([app, core])
    assert m["tests"] == 990 + 1873
    assert m["unique_findings"] == ["ThreadSanitizer: data race Store.swift:9 in commit"]
    assert ws.status_for(m, timed_out=False) == "findings"
    assert ws.status_for(ws.merge([]), timed_out=False) == "no-tests-ran"


def test_commands_carry_the_sanitizer_the_configuration_and_the_subset(tmp_path):
    app = ws.app_command("address", "Release", tmp_path / "dd", ["VideoScanTests/CatalogTests"])
    assert "-enableAddressSanitizer" in app and "-enableUndefinedBehaviorSanitizer" in app
    assert "ENABLE_TESTABILITY=YES" in app and "-only-testing:VideoScanTests/CatalogTests" in app
    assert app[app.index("-configuration") + 1] == "Release"
    debug = ws.app_command("thread", "Debug", tmp_path / "dd", [])
    assert "ENABLE_TESTABILITY=YES" not in debug and "-enableThreadSanitizer" in debug and not any(a.startswith("-only-testing") for a in debug)
    core = ws.core_command("thread", "Release", tmp_path / "scratch")
    assert core[:2] == ["swift", "test"] and ["--sanitize", "thread"] == core[-2:] and "release" in core
    core_a = ws.core_command("address", "Debug", tmp_path / "scratch")
    assert core_a.count("--sanitize") == 2 and "undefined" in core_a


def test_catalog_subset_comes_from_the_gauntlet_manifest(tmp_path):
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"assignments": [
        {"kind": "xcode", "path": "VideoScan/VideoScanTests/CatalogSearchTests.swift", "suites": ["CatalogSearchTests", "CatalogSearchScaleTests"]},
        {"kind": "xcode", "path": "VideoScan/VideoScanTests/MediaFileOperationsTests.swift", "suites": ["MediaFileOperationsTests"]},
        {"kind": "xcode", "path": "VideoScan/VideoScanTests/HallieVoiceTests.swift", "suites": ["HallieVoiceTests"]},
        {"kind": "package", "path": "VideoScan/VideoScanCore/Tests/VideoScanCoreTests/Store/CatalogStoreTests.swift", "suites": ["CatalogStoreTests"]},
        {"kind": "python", "path": "tests/test_catalog_db.py", "suites": ["test_catalog_db.py"]},
    ]}))
    assert ws.subset_selectors(manifest) == ["VideoScanTests/CatalogSearchScaleTests", "VideoScanTests/CatalogSearchTests",
                                             "VideoScanTests/MediaFileOperationsTests"]
    assert ws.subset_selectors(tmp_path / "absent.json") == []


def test_the_real_manifest_yields_a_catalog_subset_of_hundreds_of_suites():
    """The subset must stay meaningful: the catalog/MFO/Archive suites are a few hundred, not none."""
    sel = ws.subset_selectors(ws.MANIFEST)
    assert 200 <= len(sel) <= 2000, len(sel)
    assert all(s.startswith("VideoScanTests/") for s in sel)


def test_main_runs_both_targets_with_fake_tools_and_writes_one_row(tmp_path, monkeypatch):
    """End to end on fakes: a TSan finding in Core turns the row red even though the app half is green."""
    fake = tmp_path / "bin"; fake.mkdir()
    (fake / "xcodebuild").write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$FAKE_ARGS_APP\"\n"
                                     "printf '✔ Test run with 12 tests in 2 suites passed after 1.0 seconds.\\n** TEST SUCCEEDED **\\n'\n")
    (fake / "swift").write_text("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"$FAKE_ARGS_CORE\"\n"
                                "printf 'WARNING: ThreadSanitizer: data race (pid=7)\\nSUMMARY: ThreadSanitizer: data race Store.swift:9 in commit\\n'\n"
                                "printf '\\t Executed 5 tests, with 0 failures (0 unexpected) in 1.0 (1.0) seconds\\n'\n")
    for f in fake.iterdir():
        f.chmod(0o755)
    monkeypatch.setenv("PATH", f"{fake}:{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_ARGS_APP", str(tmp_path / "app-args.txt"))
    monkeypatch.setenv("FAKE_ARGS_CORE", str(tmp_path / "core-args.txt"))
    logdir = tmp_path / "logs"
    rc = ws.main(["--sanitizer", "thread", "--configuration", "Release", "--target", "all", "--no-wait",
                  "--log-dir", str(logdir), "--dd-root", str(tmp_path / "dd"), "--source", "analysis-lane", "--timeout-hours", "0.01"])
    assert rc == 0
    row = json.loads((logdir / "latest-thread.json").read_text())
    assert row["status"] == "findings" and row["tests"] == 17 and row["targets"] == ["app", "core"]
    assert row["configuration"] == "Release" and row["source"] == "analysis-lane"
    assert row["per_target"]["app"]["status"] == "ok" and row["per_target"]["core"]["status"] == "findings"
    assert row["unique_findings"] == ["ThreadSanitizer: data race Store.swift:9 in commit"]
    app_args = (tmp_path / "app-args.txt").read_text()
    assert "-enableThreadSanitizer" in app_args and "ENABLE_TESTABILITY=YES" in app_args
    core_args = (tmp_path / "core-args.txt").read_text().split()
    assert core_args[:1] == ["test"] and "thread" in core_args and "release" in core_args
    assert Path(row["log"]).exists() and Path(row["per_target"]["core"]["log"]).exists()
    assert len((logdir / "runs.jsonl").read_text().splitlines()) == 1
    # The morning alert still reads the row (additive fields only).
    line = alert.lines_for(row, dt.datetime.fromisoformat(row["started"]) + dt.timedelta(hours=1), 8)[0]
    assert line.startswith("🔴 Thread Sanitizer") and "1 finding(s)" in line
