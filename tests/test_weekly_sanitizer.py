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


# ── 2026-11-04: the findings never reached the Mac Rick reads ──
# RED: the 11/01 TSan race (8 reports, the test host restarted 8×) and the 10/31
# UBSan report lived only in latest-*.json on the M4. sanitizer_alert.py read only
# local files, so on the Ultra it was silent; and a "findings" line never said the
# host had crashed, so the tests that never ran went unmentioned too.

def _published(date, kind, **kw):
    row = {"schemaVersion": 1, "date": date, "kind": kind, "source": "weekly", "configuration": "Debug",
           "subset": "full", "status": "findings", "sha": "4fc66b944", "tests": 10333, "host_restarts": 0,
           "reports": 0, "asan_issues": None, "ubsan_issues": None, "tsan_issues": None}
    row.update(kw)
    return row


def test_a_findings_line_says_the_host_restarted():
    line = alert.lines_for(_row("findings", unique_findings=["ThreadSanitizer: data race"], host_restarts=8), NOW, 8)[0]
    assert line.startswith("🔴") and "1 finding(s)" in line and "test host restarted 8×" in line


def test_published_rows_reach_a_mac_without_the_local_files(tmp_path, capsys):
    now = dt.datetime.fromisoformat("2026-11-02T09:00:00-05:00")
    rows = [_published("2026-10-24", "address", status="tests-failed", asan_issues=0, ubsan_issues=0),
            _published("2026-10-31", "address", sha="30e415296", host_restarts=2, reports=2,
                       asan_issues=0, ubsan_issues=1),
            _published("2026-11-01", "thread", host_restarts=8, reports=8, tsan_issues=1)]
    src = tmp_path / "sanitizer.jsonl"
    src.write_text("".join(json.dumps(r) + "\n" for r in rows) + "not json\n")
    assert alert.main(["--published", str(src), "--now", now.isoformat(), "--dir", str(tmp_path / "none")]) == 0
    out = capsys.readouterr().out.splitlines()
    assert out[0].startswith("🔴 Address Sanitizer (Sat Oct 31, 30e415296): 1 finding(s)")
    assert "test host restarted 2×" in out[0] and "on the M4" in out[0]
    assert out[1] == "     • UBSan: 1 unique finding"
    assert out[2].startswith("🔴 Thread Sanitizer (Sun Nov 01, 4fc66b944): 1 finding(s)") and "restarted 8×" in out[2]
    assert out[3] == "     • TSan: 1 unique finding"
    assert len(out) == 4


def test_published_rows_older_than_the_window_or_green_are_quiet(tmp_path, capsys):
    now = dt.datetime.fromisoformat("2026-11-20T09:00:00-05:00")
    src = tmp_path / "sanitizer.jsonl"
    src.write_text(json.dumps(_published("2026-11-01", "thread", tsan_issues=1)) + "\n"
                   + json.dumps(_published("2026-11-15", "address", status="ok", asan_issues=0, ubsan_issues=0)) + "\n")
    alert.main(["--published", str(src), "--now", now.isoformat(), "--dir", str(tmp_path / "none")])
    assert capsys.readouterr().out == ""


def test_local_files_win_over_published_rows_on_the_m4(tmp_path, capsys):
    (tmp_path / "latest-thread.json").write_text(json.dumps({**_row("tests-failed"), "kind": "thread",
                                                             "failed_tests": ["raceTest"]}))
    src = tmp_path / "sanitizer.jsonl"
    src.write_text(json.dumps(_published(NOW.date().isoformat(), "thread", tsan_issues=4)) + "\n")
    alert.main(["--dir", str(tmp_path), "--published", str(src), "--now", NOW.isoformat()])
    out = capsys.readouterr().out
    assert "raceTest" in out and "TSan: 4" not in out


def test_morning_digest_falls_back_to_the_published_rows():
    script = (ROOT / "scripts" / "morning_metrics.sh").read_text()
    assert "metrics/sanitizer.jsonl" in script and "sanitizer_alert.py\" --published -" in script


# ── 2026-11-08: known findings are suppressed with a reason; red means NEW ──
# RED: every weekly run was "findings" for the same two known reports (GRDB close
# race, #423, 15 reports and 15 host restarts on 11/08; mlx-swift null release,
# #463, 2 restarts on 11/07). The runner now hands scripts/sanitizer/*.supp to the
# runtimes, refuses an entry without an issue and a reason, and lists each entry
# with its hits in the row.

import pytest  # noqa: E402

TSAN_SUPPRESSED_TAIL = ("ThreadSanitizer: Matched 1 suppressions (pid=60898):\n"
                        "15 race:DatabasePool.close\n")


def test_the_real_suppression_files_are_all_known_findings_with_an_issue_and_a_reason():
    import re
    code_re = re.compile(r"^[a-z][a-z0-9-]{0,31}$")         # publishable as a metrics code
    for kind, files in ws.SUPPRESSION_FILES.items():
        for _var, name, _extra in files:
            entries = ws.load_suppressions(ws.SUPP_DIR / name)
            assert entries, f"{name} is empty: drop it from SUPPRESSION_FILES instead"
            for e in entries:
                assert code_re.match(e["code"]) and e["issue"] > 0 and len(e["reason"]) > 40, e
    tsan = ws.load_suppressions(ws.SUPP_DIR / "tsan.supp")
    assert [(e["check"], e["pattern"], e["issue"]) for e in tsan] == [("race", "DatabasePool.close", 423)]
    ubsan = ws.load_suppressions(ws.SUPP_DIR / "ubsan.supp")
    assert [(e["check"], e["pattern"], e["issue"]) for e in ubsan] == [("null", "*mlx/backend/metal/device.cpp", 463)]


@pytest.mark.parametrize("text, why", [
    ("race:Anything\n", "no `# known:` header"),
    ("# known: code=x issue=1\nrace:Anything\n", "no `# reason:`"),
    ("# known: code=x\n# reason: r\nrace:Anything\n", "needs code"),
    ("# known: code=x issue=abc\n# reason: r\nrace:Anything\n", "needs code"),
    ("# known: code=x issue=1\n# reason: r\n", "has no pattern"),
    ("# known: code=x issue=1\n# reason: r\n# known: code=y issue=2\n# reason: r\nrace:A\n", "before the previous"),
    ("# known: code=x issue=1\n# reason: r\nAnything\n", "not <check>:<pattern>"),
])
def test_an_unexplained_suppression_is_refused(tmp_path, text, why):
    f = tmp_path / "tsan.supp"
    f.write_text("# preamble comments are fine\n\n" + text)
    with pytest.raises(ws.SuppressionError, match=why):
        ws.load_suppressions(f)


def test_env_hands_the_files_to_the_runtime_and_the_hosted_test_process(tmp_path):
    env, known = ws.sanitizer_env("thread", {"PATH": "/bin", "TSAN_OPTIONS": "halt_on_error=0"})
    supp = ws.SUPP_DIR / "tsan.supp"
    assert env["TSAN_OPTIONS"] == f"halt_on_error=0:suppressions={supp}:print_suppressions=1"
    assert env["TEST_RUNNER_TSAN_OPTIONS"] == f"suppressions={supp}:print_suppressions=1"
    assert "UBSAN_OPTIONS" not in env and [e["code"] for e in known] == ["grdb-close-read-race"]
    env, known = ws.sanitizer_env("address", {})
    assert env["UBSAN_OPTIONS"] == env["TEST_RUNNER_UBSAN_OPTIONS"] == f"suppressions={ws.SUPP_DIR / 'ubsan.supp'}:print_stacktrace=1"
    assert "TSAN_OPTIONS" not in env
    # No file -> no suppressions, nothing in force; the reporting options stay.
    assert ws.sanitizer_env("thread", {"A": "1"}, tmp_path) == (
        {"A": "1", "TSAN_OPTIONS": "print_suppressions=1", "TEST_RUNNER_TSAN_OPTIONS": "print_suppressions=1"}, [])


def test_matched_suppressions_sum_over_every_process_and_ignore_lookalikes():
    log = ("12 race:NotInABlock\n" + TSAN_SUPPRESSED_TAIL + "Test Suite 'x' started\n"
           "ThreadSanitizer: Matched 2 suppressions (pid=7):\n  3 race:DatabasePool.close\n  1 race:Other\n\n9 race:After\n")
    assert ws.matched_suppressions(log) == {"race:DatabasePool.close": 18, "race:Other": 1}


def test_a_run_whose_only_race_was_suppressed_is_ok_and_says_what_was_held_back():
    """Production shape of the 11/08 run after the change: no report printed, no
    restart, the matched block at exit."""
    p = ws.parse_log(GREEN_LOG + TSAN_SUPPRESSED_TAIL)
    assert ws.status_for(p, timed_out=False) == "ok" and p["reports"] == 0
    rows = ws.suppression_rows(ws.load_suppressions(ws.SUPP_DIR / "tsan.supp"), p["suppressed_hits"], "thread")
    assert [(r["code"], r["issue"], r["hits"]) for r in rows] == [("grdb-close-read-race", 423, 15)]
    ub = ws.suppression_rows(ws.load_suppressions(ws.SUPP_DIR / "ubsan.supp"), {}, "address")
    assert [(r["code"], r["hits"]) for r in ub] == [("mlx-null-linked-functions", None)], "UBSan hits are not observable: null, never 0"


def test_a_new_race_beside_a_suppressed_one_is_still_a_finding():
    log = TSAN_SUPPRESSED_TAIL + "WARNING: ThreadSanitizer: data race (pid=1)\nSUMMARY: ThreadSanitizer: data race Store.swift:9 in commit\n" + GREEN_LOG
    p = ws.parse_log(log)
    assert ws.status_for(p, timed_out=False) == "findings" and p["suppressed_hits"] == {"race:DatabasePool.close": 15}


def _fake_tools(tmp_path, monkeypatch, app_out):
    fake = tmp_path / "bin"; fake.mkdir()
    (fake / "xcodebuild").write_text("#!/bin/sh\nprintf '%s\\n' \"$TEST_RUNNER_TSAN_OPTIONS\" > \"$FAKE_ENV\"\n"
                                     f"printf '{app_out}'\n")
    (fake / "xcodebuild").chmod(0o755)
    monkeypatch.setenv("PATH", f"{fake}:{os.environ['PATH']}")
    monkeypatch.setenv("FAKE_ENV", str(tmp_path / "env.txt"))


def test_main_passes_the_suppressions_and_records_each_with_its_hits(tmp_path, monkeypatch):
    _fake_tools(tmp_path, monkeypatch, "✔ Test run with 12 tests in 2 suites passed after 1.0 seconds.\\n"
                                       "** TEST SUCCEEDED **\\nThreadSanitizer: Matched 1 suppressions (pid=9):\\n4 race:DatabasePool.close\\n")
    logdir = tmp_path / "logs"
    assert ws.main(["--sanitizer", "thread", "--no-wait", "--log-dir", str(logdir), "--dd-root", str(tmp_path / "dd"),
                    "--timeout-hours", "0.01"]) == 0
    row = json.loads((logdir / "latest-thread.json").read_text())
    assert row["status"] == "ok" and row["tests"] == 12
    assert [(s["code"], s["issue"], s["hits"]) for s in row["suppressed"]] == [("grdb-close-read-race", 423, 4)]
    assert f"suppressions={ws.SUPP_DIR / 'tsan.supp'}" in (tmp_path / "env.txt").read_text()


def test_main_with_an_unexplained_suppression_writes_a_config_error_row_and_runs_nothing(tmp_path, monkeypatch):
    _fake_tools(tmp_path, monkeypatch, "should not run\\n")
    supp = tmp_path / "supp"; supp.mkdir()
    (supp / "tsan.supp").write_text("race:Everything\n")
    logdir = tmp_path / "logs"
    assert ws.main(["--sanitizer", "thread", "--no-wait", "--log-dir", str(logdir), "--dd-root", str(tmp_path / "dd"),
                    "--suppressions-dir", str(supp)]) == 0
    row = json.loads((logdir / "latest-thread.json").read_text())
    assert row["status"] == "config-error" and "no `# known:` header" in row["reason"] and row["tests"] == 0
    assert not (tmp_path / "env.txt").exists()
    line = alert.lines_for(row, dt.datetime.fromisoformat(row["started"]) + dt.timedelta(hours=1), 8)[0]
    assert line.startswith("🔴 Thread Sanitizer") and "suppression file" in line


KNOWN = [{"code": "grdb-close-read-race", "issue": 423, "hits": 15}]


def test_the_digest_is_quiet_for_a_run_that_is_ok_apart_from_known_findings(tmp_path, capsys):
    assert alert.lines_for(_row("ok", suppressed=KNOWN), NOW, 8) == []
    src = tmp_path / "sanitizer.jsonl"
    src.write_text(json.dumps(_published(NOW.date().isoformat(), "thread", status="ok", tsan_issues=0, suppressed=KNOWN)) + "\n")
    alert.main(["--published", str(src), "--now", NOW.isoformat(), "--dir", str(tmp_path / "none")])
    assert capsys.readouterr().out == ""


def test_a_red_digest_line_says_which_known_findings_were_held_back(tmp_path, capsys):
    line = alert.lines_for(_row("tests-failed", failed_tests=["x"], suppressed=KNOWN), NOW, 8)[0]
    assert line.startswith("🔴") and "1 known finding suppressed (#423)" in line
    src = tmp_path / "sanitizer.jsonl"
    src.write_text(json.dumps(_published(NOW.date().isoformat(), "thread", tsan_issues=1, reports=1, suppressed=KNOWN)) + "\n")
    alert.main(["--published", str(src), "--now", NOW.isoformat(), "--dir", str(tmp_path / "none")])
    out = capsys.readouterr().out
    assert "1 finding(s); 1 known finding suppressed (#423)" in out


# ── 2026-11-08 (Rick): a finding whose OUR frames are all test code is grey ──
# "Keep running sanitizers over everything, but a finding whose stack frames (our
# frames) are entirely in test code shows grey — fix when convenient. Red stays for
# findings that touch product code." Classification is by frame: source path first
# (VideoScanTests/, */Tests/ = test; VideoScan/VideoScan/, VideoScanCore/Sources/ =
# product), then the Swift symbol's module, then the binary module. Third-party and
# runtime frames are not ours. No frame of ours at all = product (never hide it).

REPO_PATH = "/Users/rickb/dev/VideoScan/VideoScan"


@pytest.mark.parametrize("frame, side", [
    ("    #0 closure #1 in VideoScanTests.FooTests.bar() FooTests.swift:12 (VideoScanTests:arm64+0x10)", "test"),
    (f"    #1 0x1 in Foo.helper() {REPO_PATH}/VideoScanTests/Support/Helpers.swift:9", "test"),
    (f"    #1 Foo.bar() {REPO_PATH}/VideoScanCore/Tests/VideoScanCoreTests/Store/X.swift:9 (VideoScanCoreTests:arm64+0x1)", "test"),
    ("    #6 VideoScanCoreTests.StoreTests.helper() Helpers.swift:3 (VideoScanCoreTests:arm64+0x3)", "test"),
    (f"    #3 0x104 in VideoScan.CatalogStore.save() {REPO_PATH}/VideoScan/Store/CatalogStore.swift:40", "product"),
    (f"    #3 0x104 in x() {REPO_PATH}/VideoScanCore/Sources/VideoScanCore/Store/Repo.swift:40", "product"),
    ("    #2 closure #1 in static VideoScanCore.GRDBCatalogRepository.decideAtClose(GRDB.DatabasePool) <null> "
     "(VideoScanCore_-7D3187DD9FB04CEE_PackageProduct:arm64+0xf6ec6c)", "product"),
    ("    #5 VideoScanCore.Store.commit() Store.swift:9 (VideoScanCoreTests:arm64+0x2)", "product"),
    ("    #7 static VideoScan.CatalogLaunchWait.run() <null> (VideoScan.debug.dylib:arm64+0x2)", "product"),
    ("    #8 closure #1 () -> () in VideoScanTests.FooTests.testX() <null> (VideoScan.debug.dylib:arm64+0x2)", "test"),
    ("    #0 $defer #1 () -> () in closure #1 () throws -> () in GRDB.DatabasePool.close() throws -> () <null> "
     "(GRDB_5DC4DB053_PackageProduct:arm64+0xa32c0)", None),
    ("    #1 swift::runJobInEstablishedExecutorContext(swift::Job*) <null> (libswift_Concurrency.dylib:arm64e+0x2c4c)", None),
    ("    #0 0x1 in mlx::core::metal::Device::get_kernel_(std::string) /x/SourcePackages/checkouts/mlx-swift/"
     "Source/Cmlx/mlx/mlx/backend/metal/device.cpp:717:21", None),
    ("not a frame at all", None),
])
def test_each_frame_is_ours_in_tests_ours_in_product_or_not_ours(frame, side):
    assert ws.frame_side(frame) == side


def _tsan(frames, summary="SUMMARY: ThreadSanitizer: data race FooTests.swift:12 in bar"):
    return ("WARNING: ThreadSanitizer: data race (pid=1)\n  Write of size 8 at 0x1 by thread T1:\n"
            + "".join(f"    #{i} {f}\n" for i, f in enumerate(frames)) + summary + "\n==================\n")


TEST_FRAME = "closure #1 in VideoScanTests.FooTests.bar() FooTests.swift:12 (VideoScanTests:arm64+0x10)"
PRODUCT_FRAME = "VideoScan.CatalogStore.save() <null> (VideoScan.debug.dylib:arm64+0x20)"
GRDB_FRAME = "GRDB.DatabasePool.close() <null> (GRDB_5DC4DB053_PackageProduct:arm64+0xa32c0)"


def test_a_report_is_test_only_when_every_frame_of_ours_is_test_code():
    assert ws.classify_report(_tsan([GRDB_FRAME, TEST_FRAME])) == "test"
    assert ws.classify_report(_tsan([GRDB_FRAME, TEST_FRAME, PRODUCT_FRAME])) == "product"
    assert ws.classify_report(_tsan([GRDB_FRAME])) == "product", "no frame of ours: never hidden"
    ub_no_stack = "/x/checkouts/mlx-swift/device.cpp:717:21: runtime error: member call on null pointer\n"
    assert ws.classify_report(ub_no_stack) == "product"
    ub_test = (f"{REPO_PATH}/VideoScanTests/MLXSafetyTests.swift:40:9: runtime error: load of misaligned address\n"
               f"    #0 0x1 in VideoScanTests.MLXSafetyTests.x() {REPO_PATH}/VideoScanTests/MLXSafetyTests.swift:40\n")
    assert ws.classify_report(ub_test) == "test"


def test_a_run_with_only_test_code_findings_is_grey_and_its_halted_host_is_explained():
    p = ws.parse_log("Test Suite 'VideoScanTests.xctest' started at x\n" + _tsan([GRDB_FRAME, TEST_FRAME])
                     + "Test Suite 'VideoScanTests.xctest' started at y\n" + GREEN_LOG)
    assert p["unique_findings"] == [] and p["test_only_findings"] == ["ThreadSanitizer: data race FooTests.swift:12 in bar"]
    assert p["reports"] == 1 and p["test_only_reports"] == 1 and p["host_restarts"] == 1
    assert ws.status_for(p, timed_out=False) == "test-findings"
    # A second restart nothing explains is a crash.
    p2 = ws.parse_log(_tsan([TEST_FRAME]) + "Test Suite 'VideoScanTests.xctest' started at x\n" * 3 + GREEN_LOG)
    assert ws.status_for(p2, timed_out=False) == "host-crashed"
    # Red failures still outrank it.
    p3 = ws.parse_log(_tsan([TEST_FRAME]) + "✘ Test fooBar() failed after 0.1 seconds.\n✘ Test run with 3 tests in 1 suite failed after 1 seconds.\n")
    assert ws.status_for(p3, timed_out=False) == "tests-failed"


def test_a_product_finding_beside_a_test_only_one_is_red():
    log = _tsan([TEST_FRAME]) + _tsan([TEST_FRAME, PRODUCT_FRAME], "SUMMARY: ThreadSanitizer: data race CatalogStore.swift:40 in save") + GREEN_LOG
    p = ws.parse_log(log)
    assert p["unique_findings"] == ["ThreadSanitizer: data race CatalogStore.swift:40 in save"]
    assert p["test_only_findings"] == ["ThreadSanitizer: data race FooTests.swift:12 in bar"]
    assert ws.status_for(p, timed_out=False) == "findings"
    m = ws.merge([p, ws.parse_log(_tsan([TEST_FRAME], "SUMMARY: ThreadSanitizer: data race B.swift:1 in b") + GREEN_LOG)])
    assert m["test_only_reports"] == 2 and len(m["test_only_findings"]) == 2


def test_the_digest_shows_test_code_findings_grey_not_red(tmp_path, capsys):
    line = alert.lines_for(_row("test-findings", test_only_findings=["ThreadSanitizer: data race FooTests.swift:12"]), NOW, 8)
    assert line[0].startswith("⚪ Address Sanitizer") and "1 finding(s) in test code only" in line[0]
    assert "fix when convenient" in line[0] and "🔴" not in "".join(line)
    src = tmp_path / "sanitizer.jsonl"
    src.write_text(json.dumps(_published(NOW.date().isoformat(), "thread", status="test-findings", tsan_issues=0,
                                         reports=1, test_only_issues=1)) + "\n")
    alert.main(["--published", str(src), "--now", NOW.isoformat(), "--dir", str(tmp_path / "none")])
    out = capsys.readouterr().out
    assert out.startswith("⚪ Thread Sanitizer") and "1 finding(s) in test code only" in out


def test_ubsan_prints_its_stack_so_its_frames_can_be_classified():
    env, _ = ws.sanitizer_env("address", {})
    assert "print_stacktrace=1" in env["UBSAN_OPTIONS"] and "print_stacktrace=1" in env["TEST_RUNNER_UBSAN_OPTIONS"]


# ── #469: a relaunched host is explained by POSITION, not by counting reports ──
# RED: status_for let every test-only report explain one restart, wherever the
# report was. A test-only UBSan report the host ran on from, plus a genuine host
# crash an hour later, read "test-findings" (grey); the crash went unmentioned.
#
# The rule (ws.RESTART_RULE): a restart is explained only by a sanitizer report
# printed immediately before it, whatever the sanitizer; "immediately" = no test
# or suite started or finished between the report's last line and the restart.
# A test-only report explains it grey; a report of a known finding (an entry of
# scripts/sanitizer/*.supp that printed anyway) explains it by that issue; no
# report, a report the host ran on from, or a new product report is a crash.
#
# The fixtures are the shapes of the M4's logs (tool output only, shortened):
#   2026-11-07-address.log  2 UBSan reports (mlx device.cpp:717, #463), each
#                           followed by TEST_HOST_STARTED, a blank, "Restarting
#                           after unexpected exit…" (2 of 2; 10/31: 2 of 2)
#   2026-11-08-thread.log   15 TSan reports (GRDB close race, #423), each followed
#                           by the ====== rule, then the same lines (15 of 15;
#                           11/01: 8 of 8, with two os_log lines of the new host)
#   2026-10-05-thread.log   1 restart with no report at all (TSan-runtime SIGSEGV)
#   verify-2026-11-08       a UBSan report, then the SAME test passes: no restart

HOST_START = "Test Suite 'VideoScanTests.xctest' started at 2026-11-07 07:03:18.935.\n"
RESTARTING = "Restarting after unexpected exit, crash, or test timeout; summary will include totals from previous launches.\n"
NEW_HOST_OSLOG = ("2026-11-01 05:06:55.908826-0500 VideoScan[15123:5150029] [Connection] Unable to get remote object proxy\n"
                  "2026-11-01 05:06:55.909038-0500 VideoScan[15123:5150029] [Application] Error registering app\n")


def _relaunch(oslog=""):
    """What xcodebuild prints when the hosted test process died: the next host's
    banner (and, some weeks, two os_log lines of it), the Restarting line, the
    empty XCTest half of the new launch."""
    return ("TEST_HOST_STARTED epoch=1794056175.505 pid=35307\n" + oslog + "\n" + RESTARTING + "\n"
            "Test Suite 'Selected tests' started at 2026-11-07 07:56:16.396.\n"
            "Test Suite 'VideoScanTests.xctest' started at 2026-11-07 07:56:16.397.\n"
            "Test Suite 'VideoScanTests.xctest' passed at 2026-11-07 07:56:16.397.\n"
            "\t Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds\n"
            "◇ Test run started.\n")


def _started(name):
    return f"◇ Test {name} started.\n"


def _passed(name):
    return f"◇ Test {name} started.\n✔ Test {name} passed after 0.006 seconds.\n"


MLX_PATH = "/Users/x/Library/Caches/VideoScan/sanitizer-dd/address/SourcePackages/checkouts/mlx-swift/Source/Cmlx"
UBSAN_MLX = (f"{MLX_PATH}/mlx/mlx/backend/metal/device.cpp:717:21: runtime error: member call on null pointer of type "
             "'NS::Referencing<MTL::LinkedFunctions>'\n"
             f"SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior {MLX_PATH}/mlx/mlx/backend/metal/device.cpp:717:21 \n")
UBSAN_MLX_CALLEE = (f"{MLX_PATH}/metal-cpp/Foundation/NSObject.hpp:112:49: runtime error: member call on null pointer of type "
                    "'NS::Referencing<MTL::LinkedFunctions> *'\n"
                    f"SUMMARY: UndefinedBehaviorSanitizer: undefined-behavior {MLX_PATH}/metal-cpp/Foundation/NSObject.hpp:112:49 \n")
UBSAN_TEST_ONLY = (f"{REPO_PATH}/VideoScanTests/MLXSafetyTests.swift:40:9: runtime error: load of misaligned address\n"
                   f"    #0 0x1 in VideoScanTests.MLXSafetyTests.x() {REPO_PATH}/VideoScanTests/MLXSafetyTests.swift:40\n"
                   "SUMMARY: UndefinedBehaviorSanitizer: misaligned-pointer-use MLXSafetyTests.swift:40:9\n")
TSAN_GRDB = _tsan(["$defer #1 () -> () in closure #1 () throws -> () in GRDB.DatabasePool.close() throws -> () <null> "
                   "(GRDB_5DC4DB053_PackageProduct:arm64+0xa32c0)",
                   "closure #1 in static VideoScanCore.GRDBCatalogRepository.decideAtClose(GRDB.DatabasePool) <null> "
                   "(VideoScanCore_-7D3187DD9FB04CEE_PackageProduct:arm64+0xf6ec6c)"],
                  "SUMMARY: ThreadSanitizer: data race (/x/GRDB_5DC4DB053_PackageProduct:arm64+0xa32c0) in $defer #1 () -> () "
                  "in closure #1 () throws -> () in GRDB.DatabasePool.close() throws -> ()+0x70")
HAPPY, SYNC = '"happy-path MLX call inside runMLX returns normally"', '"synchronous runMLX returns normally"'
ADDRESS_1107 = (HOST_START + _passed('"shape mismatch throws instead of crashing the process"')
                + _started(HAPPY) + UBSAN_MLX + _relaunch()
                + _started(SYNC) + UBSAN_MLX + _relaunch()
                + _passed('"error in one runMLX does not contaminate the next"') + GREEN_LOG)
THREAD_1108 = (HOST_START + _started("notesTypedDuringTheScanReachCatalogSQLite()") + TSAN_GRDB + _relaunch()
               + _started('"a file missing at its path is not an attempt"') + TSAN_GRDB + _relaunch(NEW_HOST_OSLOG)
               + _passed("somethingElse()") + GREEN_LOG)


def _known(name):
    return ws.load_suppressions(ws.SUPP_DIR / name)


def _status(log, known=()):
    return ws.status_for(ws.parse_log(log, known), timed_out=False)


def test_a_test_only_report_the_host_ran_on_from_does_not_explain_a_later_crash():
    """The bug as filed: the report is nowhere near the restart."""
    log = (HOST_START + _started("misaligned()") + UBSAN_TEST_ONLY + "✔ Test misaligned() passed after 0.1 seconds.\n"
           + _passed("aThousandTestsLater()") + _started("theOneThatCrashed()") + _relaunch() + GREEN_LOG)
    p = ws.parse_log(log)
    assert p["test_only_reports"] == 1 and p["host_restarts"] == 1 and p["unexplained_restarts"] == 1
    assert ws.status_for(p, timed_out=False) == "host-crashed"
    assert p["restarts"] == [{"explained_by": None, "issue": None, "during": "theOneThatCrashed()"}]
    # The grey finding is still in the row; red only outranks it.
    assert p["test_only_findings"] == ["UndefinedBehaviorSanitizer: misaligned-pointer-use MLXSafetyTests.swift:40:9"]


@pytest.mark.parametrize("report", [UBSAN_TEST_ONLY, _tsan([GRDB_FRAME, TEST_FRAME])])
def test_a_test_only_report_right_before_the_restart_explains_it_whatever_the_sanitizer(report):
    """Position, not kind: the M4's 11/07 log shows a UBSan report followed by the
    host's exit, so "UBSan never stops the host" is not a rule."""
    log = HOST_START + _started("x()") + report + _relaunch() + GREEN_LOG
    p = ws.parse_log(log)
    assert p["host_restarts"] == 1 and p["unexplained_restarts"] == 0
    assert p["restarts"] == [{"explained_by": "test-only", "issue": None, "during": "x()"}]
    assert ws.status_for(p, timed_out=False) == "test-findings"
    # The same report explains ONE restart: a second relaunch straight after is a crash.
    assert _status(HOST_START + _started("x()") + report + _relaunch() + _started("y()") + _relaunch() + GREEN_LOG) == "host-crashed"


@pytest.mark.parametrize("between", [
    "✔ Test x() passed after 0.1 seconds.\n",                      # the verify-2026-11-08 shape: the test carried on
    "◇ Test another() started.\n",
    "✔ Suite MKVDossierPipelineTests passed after 0.195 seconds.\n",
    "Test Case '-[VideoScanTests.OldTests testThing]' started.\n",
    "Test Case '-[VideoScanTests.OldTests testThing]' passed (0.1 seconds).\n",
])
def test_immediately_before_means_no_test_or_suite_started_or_finished_in_between(between):
    log = HOST_START + _started("x()") + UBSAN_TEST_ONLY + between + _relaunch() + GREEN_LOG
    p = ws.parse_log(log)
    assert p["unexplained_restarts"] == 1 and ws.status_for(p, timed_out=False) == "host-crashed"
    assert ws.RESTART_RULE.startswith("a restart is explained only by a sanitizer report printed immediately before it")


def test_what_the_real_logs_put_between_report_and_restart_does_not_break_the_rule():
    """TSan's ====== rule, the next host's banner, its os_log lines, blanks (11/01: 8 of 8)."""
    log = HOST_START + _started("x()") + _tsan([TEST_FRAME]) + _relaunch(NEW_HOST_OSLOG) + GREEN_LOG
    assert ws.parse_log(log)["unexplained_restarts"] == 0


def test_the_address_log_of_1107_reads_as_the_known_mlx_finding_not_as_a_crash():
    """Two reports of #463 (suppressed in ubsan.supp), each followed by the host's
    exit: both restarts belong to #463, nothing is new, nothing is red."""
    p = ws.parse_log(ADDRESS_1107, _known("ubsan.supp"))
    assert p["reports"] == 2 and p["known_reports"] == 2 and p["host_restarts"] == 2 and p["unexplained_restarts"] == 0
    assert p["unique_findings"] == [] and p["test_only_reports"] == 0
    assert p["restarts"] == [{"explained_by": "known", "issue": 463, "during": HAPPY},
                             {"explained_by": "known", "issue": 463, "during": SYNC}]
    assert ws.status_for(p, timed_out=False) == "ok"
    row = _row("ok", **p, suppressed=[{"code": "mlx-null-linked-functions", "issue": 463, "hits": None}])
    line = alert.lines_for(row, NOW, 8)
    assert len(line) == 1 and line[0].startswith("⚪ Address Sanitizer") and "🔴" not in line[0]
    assert "#463" in line[0] and "restarted 2×" in line[0] and "happy-path MLX" in line[0]


def test_the_thread_log_of_1108_reads_as_the_known_grdb_race():
    p = ws.parse_log(THREAD_1108, _known("tsan.supp"))
    assert p["known_reports"] == 2 and p["unexplained_restarts"] == 0 and p["unique_findings"] == []
    assert [(r["explained_by"], r["issue"]) for r in p["restarts"]] == [("known", 423), ("known", 423)]
    assert ws.status_for(p, timed_out=False) == "ok"


@pytest.mark.parametrize("log", [ADDRESS_1107, THREAD_1108])
def test_without_a_known_entry_the_same_log_is_a_new_finding_and_its_restarts_are_crashes(log):
    """A new product finding before a restart explains nothing: the row is red
    (findings outrank everything) and both relaunches count as crashes."""
    p = ws.parse_log(log)
    assert ws.status_for(p, timed_out=False) == "findings" and len(p["unique_findings"]) == 1
    assert p["known_reports"] == 0 and p["unexplained_restarts"] == 2
    assert [r["explained_by"] for r in p["restarts"]] == [None, None]
    assert "test host restarted 2×" in alert.lines_for(_row("findings", **p), NOW, 8)[0]


def test_a_restart_with_no_report_before_it_is_a_crash_and_names_the_test_that_was_running():
    """The 10/05 shape (TSan-runtime SIGSEGV), and the shape a suppressed report
    would leave if the host still exited: the log holds no report, no signal and
    no crash line, only the test that started and never finished."""
    log = HOST_START + _passed("fine()") + _started(HAPPY) + _relaunch() + _passed("later()") + GREEN_LOG
    p = ws.parse_log(log, _known("ubsan.supp"))
    assert p["reports"] == 0 and p["restarts"] == [{"explained_by": None, "issue": None, "during": HAPPY}]
    assert ws.status_for(p, timed_out=False) == "host-crashed"
    line = alert.lines_for(_row("host-crashed", **p), NOW, 8)[0]
    assert line.startswith("🔴") and "crashed 1×" in line and "no sanitizer report" in line and "happy-path MLX" in line
    # Nothing was running (the last test had finished): the line does not invent one.
    quiet = ws.parse_log(HOST_START + _passed("fine()") + _relaunch() + GREEN_LOG)
    assert quiet["restarts"] == [{"explained_by": None, "issue": None, "during": None}]
    xct = ws.parse_log(HOST_START + "Test Case '-[VideoScanTests.OldTests testThing]' started.\n" + _relaunch() + GREEN_LOG)
    assert xct["restarts"][0]["during"] == "VideoScanTests.OldTests testThing"


def test_a_known_report_explains_its_own_restart_and_no_other():
    log = (HOST_START + _started(HAPPY) + UBSAN_MLX + _relaunch()          # known, explained
           + _passed("fine()") + _started("crasher()") + _relaunch() + GREEN_LOG)   # nothing before it
    p = ws.parse_log(log, _known("ubsan.supp"))
    assert p["host_restarts"] == 2 and p["unexplained_restarts"] == 1
    assert [(r["explained_by"], r["during"]) for r in p["restarts"]] == [("known", HAPPY), (None, "crasher()")]
    assert ws.status_for(p, timed_out=False) == "host-crashed"
    line = alert.lines_for(_row("host-crashed", **p), NOW, 8)[0]
    assert "crashed 1×" in line and "running then: crasher()" in line and "happy-path" not in line.split("also restarted")[0]
    assert "also restarted 1× right after a known or test-only report (#463)" in line
    # Red for another reason: the explained relaunches are still said, and a long test name is cut.
    known_only = ws.parse_log(ADDRESS_1107.replace(HAPPY, '"' + "x" * 200 + '"'), _known("ubsan.supp"))
    red = alert.lines_for(_row("tests-failed", **{**known_only, "failed_tests": ["fooBar"]}), NOW, 8)[0]
    assert red.startswith("🔴") and "tests failed: fooBar; the test host also restarted 2×" in red and "(#463)" in red
    grey = alert.lines_for(_row("ok", **known_only), NOW, 8)[0]
    assert '"' + "x" * 69 + "…" in grey and "x" * 70 not in grey      # 70 characters, the opening quote among them


def test_a_printed_report_is_known_only_when_an_entry_matches_its_check_and_its_place():
    ub, ts = _known("ubsan.supp"), _known("tsan.supp")
    assert ws.known_entry_for(UBSAN_MLX, ub)["issue"] == 463
    assert ws.known_entry_for(TSAN_GRDB, ts)["issue"] == 423
    # The verify-2026-11-08 run: the same null call reported one frame down is NOT the entry's file.
    assert ws.known_entry_for(UBSAN_MLX_CALLEE, ub) is None
    assert _status(HOST_START + _started(HAPPY) + UBSAN_MLX_CALLEE + "✔ Test x passed after 0.155 seconds.\n" + GREEN_LOG, ub) == "findings"
    # Another check in the same file, the other sanitizer's entries, an unknown check word: never grey.
    overflow = UBSAN_MLX.replace("member call on null pointer of type", "signed integer overflow in")
    assert ws.known_entry_for(overflow, ub) is None
    assert ws.known_entry_for(UBSAN_MLX, ts) is None and ws.known_entry_for(TSAN_GRDB, ub) is None
    assert ws.known_entry_for(_tsan([TEST_FRAME, PRODUCT_FRAME]), ts) is None
    # Only the two racing accesses count, as in the runtime: not where the memory or a thread was made.
    elsewhere = ("WARNING: ThreadSanitizer: data race (pid=1)\n  Write of size 8 at 0x1 by thread T1:\n"
                 f"    #0 {PRODUCT_FRAME}\n\n  Previous read of size 8 at 0x1 by thread T2:\n    #0 {PRODUCT_FRAME}\n\n"
                 f"  Location is heap block of size 48 at 0x1 allocated by thread T3:\n    #0 {GRDB_FRAME}\n"
                 "SUMMARY: ThreadSanitizer: data race CatalogStore.swift:40 in save\n")
    assert ws.known_entry_for(elsewhere, ts) is None
    assert ws.known_entry_for(elsewhere.replace(f"T2:\n    #0 {PRODUCT_FRAME}", f"T2:\n    #0 {GRDB_FRAME}"), ts)["issue"] == 423
    assert ws.known_entry_for(UBSAN_MLX, [{"check": "vptr", "pattern": "*device.cpp", "issue": 1, "code": "x"}]) is None
    # The runtime's template: a substring unless anchored; * is any run.
    assert ws.template_matches("DatabasePool.close", "in GRDB.DatabasePool.close() throws")
    assert ws.template_matches("*mlx/backend/metal/device.cpp", f"{MLX_PATH}/mlx/mlx/backend/metal/device.cpp")
    assert not ws.template_matches("^DatabasePool.close", "in GRDB.DatabasePool.close()")
    assert ws.template_matches("^GRDB.*close$", "GRDB.DatabasePool.close") and not ws.template_matches("close$", "close()")
    assert not ws.template_matches("DatabasePoolXclose", "DatabasePool.close"), "a dot is a dot"


def test_a_known_report_beside_a_new_one_is_still_red():
    log = HOST_START + UBSAN_MLX + _relaunch() + UBSAN_MLX_CALLEE + GREEN_LOG
    p = ws.parse_log(log, _known("ubsan.supp"))
    assert p["known_reports"] == 1 and len(p["unique_findings"]) == 1 and "NSObject.hpp" in p["unique_findings"][0]
    assert ws.status_for(p, timed_out=False) == "findings"


def test_merge_adds_the_restart_accounts_of_each_target():
    app = ws.parse_log(ADDRESS_1107, _known("ubsan.supp"))
    core = ws.parse_log(_tsan([TEST_FRAME]) + GREEN_LOG)            # swift test: no hosted bundle, no restart
    m = ws.merge([app, core])
    assert (m["host_restarts"], m["unexplained_restarts"], m["known_reports"], m["test_only_reports"]) == (2, 0, 2, 1)
    assert len(m["restarts"]) == 2 and ws.status_for(m, timed_out=False) == "test-findings"
    crashed = ws.parse_log(HOST_START + _started("c()") + _relaunch() + GREEN_LOG)
    assert ws.status_for(ws.merge([app, crashed]), timed_out=False) == "host-crashed"
    # A row written before the field: every restart counts as unexplained (red), never as explained.
    old = {k: v for k, v in app.items() if k not in ("unexplained_restarts", "restarts", "known_reports")}
    assert ws.status_for({**old, "reports": 0}, timed_out=False) == "host-crashed"


def test_main_attributes_each_restart_by_position_end_to_end(tmp_path, monkeypatch):
    """The real call site: main() hands the entries in force to parse_log, per target and merged."""
    fake = tmp_path / "bin"; fake.mkdir()
    out = tmp_path / "app-out.txt"
    (fake / "xcodebuild").write_text(f"#!/bin/sh\ncat '{out}'\n")
    (fake / "xcodebuild").chmod(0o755)
    monkeypatch.setenv("PATH", f"{fake}:{os.environ['PATH']}")

    def run(text, name):
        out.write_text(text)
        logdir = tmp_path / name
        assert ws.main(["--sanitizer", "address", "--no-wait", "--log-dir", str(logdir), "--dd-root", str(tmp_path / "dd"),
                        "--timeout-hours", "0.01"]) == 0
        row = json.loads((logdir / "latest-address.json").read_text())
        return row, alert.lines_for(row, dt.datetime.fromisoformat(row["started"]) + dt.timedelta(hours=1), 8)

    row, lines = run(ADDRESS_1107, "known")
    assert row["status"] == "ok" and row["per_target"]["app"]["status"] == "ok"
    assert (row["host_restarts"], row["unexplained_restarts"], row["known_reports"]) == (2, 0, 2)
    assert [r["issue"] for r in row["restarts"]] == [463, 463]
    assert lines[0].startswith("⚪ Address Sanitizer") and "#463" in lines[0]

    bug = (HOST_START + _started("misaligned()") + UBSAN_TEST_ONLY + "✔ Test misaligned() passed after 0.1 seconds.\n"
           + _started("theOneThatCrashed()") + _relaunch() + GREEN_LOG)
    row, lines = run(bug, "bug")
    assert row["status"] == "host-crashed" and row["per_target"]["app"]["status"] == "host-crashed"
    assert row["unexplained_restarts"] == 1 and row["test_only_reports"] == 1
    assert lines[0].startswith("🔴 Address Sanitizer") and "crashed 1×" in lines[0] and "theOneThatCrashed()" in lines[0]


def test_the_digest_words_for_explained_and_published_restarts(tmp_path, capsys):
    # Grey, test code: the line says the host went down with it.
    p = ws.parse_log(HOST_START + _started("x()") + UBSAN_TEST_ONLY + _relaunch() + GREEN_LOG)
    line = alert.lines_for(_row("test-findings", **p), NOW, 8)[0]
    assert line.startswith("⚪") and "in test code only" in line and "restarted 1×" in line
    # A row without the account (published, or from before #469) is not given a reason it never established.
    assert "no sanitizer report" not in alert.lines_for(_row("host-crashed", host_restarts=1), NOW, 8)[0]
    # ok with nothing known printed and no restart stays quiet (the 11/08 rule).
    assert alert.lines_for(_row("ok", host_restarts=0, known_reports=0, suppressed=KNOWN), NOW, 8) == []
    # A published row carries counts only: ok + restarts is still said, grey.
    src = tmp_path / "sanitizer.jsonl"
    src.write_text(json.dumps(_published(NOW.date().isoformat(), "address", status="ok", asan_issues=0, ubsan_issues=0,
                                         host_restarts=2, reports=2,
                                         suppressed=[{"code": "mlx-null-linked-functions", "issue": 463, "hits": None}])) + "\n")
    alert.main(["--published", str(src), "--now", NOW.isoformat(), "--dir", str(tmp_path / "none")])
    out = capsys.readouterr().out
    assert out.startswith("⚪ Address Sanitizer") and "restarted 2×" in out and "#463" in out and "🔴" not in out


def test_scale_a_full_size_log_with_fifteen_restarts_parses_inside_the_budget():
    """The 11/08 thread log: ~220k lines, 15 reports, 15 relaunches. One pass per
    question; nothing quadratic in the restarts."""
    import time
    filler = "".join(_passed(f"test{i}()") + f"2026-11-08 05:06:43.{i:06d}-0500 VideoScan[1:2] [catalog] committed {i} rows\n"
                     for i in range(4600))                       # ~13.8k lines per launch
    log = HOST_START + "".join(filler + _started(f"racy{i}()") + TSAN_GRDB + _relaunch() for i in range(15)) + filler + GREEN_LOG
    assert log.count("\n") > 200_000
    t0 = time.monotonic()
    p = ws.parse_log(log, _known("tsan.supp"))
    assert time.monotonic() - t0 < 5.0
    assert (p["host_restarts"], p["known_reports"], p["unexplained_restarts"]) == (15, 15, 0)
    assert [r["during"] for r in p["restarts"]] == [f"racy{i}()" for i in range(15)]
    assert ws.status_for(p, timed_out=False) == "ok"
