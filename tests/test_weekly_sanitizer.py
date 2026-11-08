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
# race, #462, 15 reports and 15 host restarts on 11/08; mlx-swift null release,
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
    assert [(e["check"], e["pattern"], e["issue"]) for e in tsan] == [("race", "DatabasePool.close", 462)]
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
    assert [(r["code"], r["issue"], r["hits"]) for r in rows] == [("grdb-close-read-race", 462, 15)]
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
    assert [(s["code"], s["issue"], s["hits"]) for s in row["suppressed"]] == [("grdb-close-read-race", 462, 4)]
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


KNOWN = [{"code": "grdb-close-read-race", "issue": 462, "hits": 15}]


def test_the_digest_is_quiet_for_a_run_that_is_ok_apart_from_known_findings(tmp_path, capsys):
    assert alert.lines_for(_row("ok", suppressed=KNOWN), NOW, 8) == []
    src = tmp_path / "sanitizer.jsonl"
    src.write_text(json.dumps(_published(NOW.date().isoformat(), "thread", status="ok", tsan_issues=0, suppressed=KNOWN)) + "\n")
    alert.main(["--published", str(src), "--now", NOW.isoformat(), "--dir", str(tmp_path / "none")])
    assert capsys.readouterr().out == ""


def test_a_red_digest_line_says_which_known_findings_were_held_back(tmp_path, capsys):
    line = alert.lines_for(_row("tests-failed", failed_tests=["x"], suppressed=KNOWN), NOW, 8)[0]
    assert line.startswith("🔴") and "1 known finding suppressed (#462)" in line
    src = tmp_path / "sanitizer.jsonl"
    src.write_text(json.dumps(_published(NOW.date().isoformat(), "thread", tsan_issues=1, reports=1, suppressed=KNOWN)) + "\n")
    alert.main(["--published", str(src), "--now", NOW.isoformat(), "--dir", str(tmp_path / "none")])
    out = capsys.readouterr().out
    assert "1 finding(s); 1 known finding suppressed (#462)" in out


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
