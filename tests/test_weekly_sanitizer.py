"""Weekly sanitizer runner + morning alert (2026-10-04): the log parser, the
status precedence, and the digest lines. Synthetic logs only."""
import datetime as dt
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
