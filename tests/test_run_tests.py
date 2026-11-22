"""scripts/run_tests.py — Rick's `run_tests.sh` front door (2026-11-19).

Pins: the smoke SELECTION is deterministic and comes from the manifest (no hand list); the
PARSER reads the line shapes our runners really print (XCTest, Swift Testing, xcodebuild's
parallel form, pytest -v) including failures and their first message; the VERDICT never
calls a zero-test lane or a lane that did not run green; --host handling; and the side
worktree refuses Rick's checkout, a main checkout, Xcode's DerivedData and a dirty tree.
No build and no host here: the live run is exercised by running the script."""
from __future__ import annotations

import importlib.util
import contextlib
import io
import json
import fcntl
import os
import re
import signal
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("run_tests", ROOT / "scripts" / "run_tests.py")
rt = importlib.util.module_from_spec(spec)
sys.modules["run_tests"] = rt
spec.loader.exec_module(rt)


# ───────────────────────────── parser, on recorded lines (nightly logs 11-18/11-19, sensor lane)

def feed_all(lines):
    p = rt.LineParser()
    evs = []
    for l in lines:
        evs += p.feed(l + "\n")
    return evs


def test_xctest_pass_skip_and_fail_with_its_message():
    evs = feed_all([
        "Test Case '-[VideoScanCoreTests.AdoptionSafetyRegressionTests testAdoptionMustNotOverwrite]' started.",
        "Test Case '-[VideoScanCoreTests.AdoptionSafetyRegressionTests testAdoptionMustNotOverwrite]' passed (0.018 seconds).",
        "/Users/x/RealFamilyData.swift:26: -[VideoScanCoreTests.GedcomCompiledTreeTests testRealExport] : Test skipped - real family data: set VIDEOSCAN_REAL_DATA",
        "Test Case '-[VideoScanCoreTests.GedcomCompiledTreeTests testRealExport]' skipped (0.000 seconds).",
        "/Users/x/ArchiveFixityTests.swift:41: error: -[VideoScanTests.ArchiveFixityTests testDetectsBitRot] : XCTAssertEqual failed: (\"1\") is not equal to (\"2\")",
        "Test Case '-[VideoScanTests.ArchiveFixityTests testDetectsBitRot]' failed (0.034 seconds).",
    ])
    assert [(e.status, e.name) for e in evs] == [
        ("OK", "AdoptionSafetyRegressionTests.testAdoptionMustNotOverwrite"),
        ("SKIPPED", "GedcomCompiledTreeTests.testRealExport"),
        ("FAILED", "ArchiveFixityTests.testDetectsBitRot")]
    assert evs[0].seconds == pytest.approx(0.018)
    assert evs[2].message.startswith("XCTAssertEqual failed")


def test_swift_testing_pass_known_issue_param_skip_and_fail():
    evs = feed_all([
        "◇ Test run started.",
        "◇ Suite AdvRetractedResearchPassageTests started.",
        "◇ Test aRetractedPassageIsNeverReturnedAsTold() started.",
        "✔ Test aRetractedPassageIsNeverReturnedAsTold() passed after 0.002 seconds.",
        "​✔ Test zeroWidthPrefixed() passed after 0.001 seconds.",
        "━ Test \"positive pair\" recorded a known issue with 1 argument c → A at AudioFingerprintAcceptanceTests.swift:133:33: Issue recorded",
        "━ Test \"positive pair\" with 16 test cases passed after 2.902 seconds with 1 known issue.",
        "​​➜ Test measureOnACatalogCopy() skipped: \"set VIDEOSCAN_PREFLIGHT_DB to a .backup copy of a catalog\"",
        "✘ Test persistVerdictPathNeverWritesTheRealCatalog() recorded an issue at VerifyAudioSchemaTests.swift:290:9: Expectation failed: appSupportSnapshot() == before",
        "✘ Test persistVerdictPathNeverWritesTheRealCatalog() failed after 1.787 seconds with 1 issue.",
        "✘ Suite \"VerifyAudio — persistence isolation\" failed after 1.791 seconds with 1 issue.",
        "✔ Suite AdvRetractedResearchPassageTests passed after 0.003 seconds.",
        "✘ Test run with 13288 tests in 2122 suites failed after 1623.583 seconds with 14 issues (including 13 known issues).",
        "━ Test run with 2365 tests in 339 suites passed after 921.586 seconds with 16 known issues.",
    ])
    assert [(e.status, e.name) for e in evs] == [
        ("OK", "aRetractedPassageIsNeverReturnedAsTold()"),
        ("OK", "zeroWidthPrefixed()"),
        ("OK", "\"positive pair\""),
        ("SKIPPED", "measureOnACatalogCopy()"),
        ("FAILED", "persistVerdictPathNeverWritesTheRealCatalog()")]
    assert evs[-1].message == "Expectation failed: appSupportSnapshot() == before"
    assert evs[-1].seconds == pytest.approx(1.787)


def test_a_display_name_that_says_skipped_or_failed_is_still_a_pass():
    # Ultra smoke 2026-11-19: two passing tests showed as SKIPPED because their names say "skipped".
    evs = feed_all([
        '✔ Test "exclusions are whole top-level components: team-channel/… is skipped, x/team-channel is seen" passed after 0.002 seconds.',
        '✔ Test "keyless and removed files are skipped, copies fold into one member" passed after 0.001 seconds.',
        '✔ Test "a run that failed after a crash is retried" passed after 0.010 seconds.',
        '➜ Test "the skipped one is skipped, really" skipped: "set VIDEOSCAN_REAL_DATA"',
        '✘ Test "a test whose name says passed after 1 seconds" failed after 0.020 seconds with 1 issue.',
    ])
    assert [e.status for e in evs] == ["OK", "OK", "OK", "SKIPPED", "FAILED"]
    assert evs[3].name == '"the skipped one is skipped, really"' and evs[3].message == "set VIDEOSCAN_REAL_DATA"
    assert evs[4].name == '"a test whose name says passed after 1 seconds"'


def test_xcodebuild_parallel_lines_count_once():
    evs = feed_all([
        "Test case 'CatalogLockRobustnessTests.testErrorCodesAreStableAndDistinct()' passed on 'My Mac - VideoScan (70854)' (0.001 seconds)",
        "case 'HallieShellCLITests/torn()' passed on 'My Mac - VideoScan (70851)' (0.002 seconds)",   # a torn line (sensor_lane.py 11-09)
        "Test case 'ArchiveSearchSharedSensorTests/timelineHidesNonMatch()' failed on 'My Mac - VideoScan (70851)' (0.004 seconds)",
        # the same test again in another form must not count twice once parallel lines are seen
        "✔ Test timelineShowsIndexedMatch() passed after 0.001 seconds.",
    ])
    assert [e.status for e in evs] == ["OK", "OK", "FAILED"]
    assert evs[2].name == "ArchiveSearchSharedSensorTests.timelineHidesNonMatch()"


def test_pytest_verbose_lines_and_summary_message_without_double_count():
    evs = feed_all([
        "tests/test_x.py::test_a PASSED                                      [ 25%]",
        "tests/test_x.py::TestC::test_b FAILED                               [ 50%]",
        "tests/test_x.py::test_c SKIPPED (needs ffmpeg)                      [ 75%]",
        "tests/test_x.py::test_d[param one] PASSED                           [100%]",
        "=========================== short test summary info ============================",
        "FAILED tests/test_x.py::TestC::test_b - AssertionError: assert 1 == 2",
        "ERROR tests/test_broken.py - ModuleNotFoundError: No module named 'foo'",
        "==================== 1 failed, 2 passed, 1 skipped in 0.31s ====================",
    ])
    assert [(e.status, e.name) for e in evs] == [
        ("OK", "tests/test_x.py::test_a"),
        ("FAILED", "tests/test_x.py::TestC::test_b"),
        ("SKIPPED", "tests/test_x.py::test_c"),
        ("OK", "tests/test_x.py::test_d[param one]"),
        ("FAILED", "tests/test_broken.py")]          # a module that failed to collect ran nothing
    assert evs[1].message == "AssertionError: assert 1 == 2"


def test_noise_lines_are_not_tests():
    assert feed_all([
        "Test Suite 'All tests' started at 2026-11-19 02:00:14.602.",
        "Test Suite 'AdoptionSafetyRegressionTests' passed at 2026-11-19 02:00:14.628.",
        "     Executed 2 tests, with 0 failures (0 unexpected) in 0.026 (0.027) seconds",
        "** TEST EXECUTE SUCCEEDED **",
        "Compiling VideoScanCore ArchiveFixity.swift",
        "",
    ]) == []


# ───────────────────────────── selection

def tree_and_manifest():
    files = [
        "VideoScan/VideoScan/Catalog/CatalogQueries.swift",
        "VideoScan/VideoScan/Archive/ArchiveFixity.swift",
        "VideoScan/VideoScan/ArchiveAngel/Promote/Promoter.swift",
        "VideoScan/VideoScanCore/Sources/VideoScanCore/FamilyMap/FamilyMapUnits.swift",
        "VideoScan/VideoScanCore/Sources/VideoScanCore/GedcomFamilyGraph.swift",
    ]
    A = "VideoScan/VideoScanTests/"
    C = "VideoScan/VideoScanCore/Tests/VideoScanCoreTests/"
    assign = [
        {"kind": "xcode", "stage": "unit", "path": A + "CatalogQueriesDecadeTests.swift", "suites": ["CatalogQueriesDecadeTests"], "tests": ["a", "b", "c"]},
        {"kind": "xcode", "stage": "unit", "path": A + "CatalogQueriesSortTests.swift", "suites": ["CatalogQueriesSortTests"], "tests": ["a"]},
        {"kind": "xcode", "stage": "unit", "path": A + "CatalogQueriesAaaTests.swift", "suites": ["CatalogQueriesAaaTests"], "tests": ["z"]},   # tie: path order
        {"kind": "xcode", "stage": "unit", "path": A + "CatalogQueriesEmptyTests.swift", "suites": ["E"], "tests": []},
        {"kind": "xcode", "stage": "regression", "path": A + "ArchiveFixityTests.swift", "suites": ["ArchiveFixityTests"], "tests": ["x"],
         "blocked_reason": "filesystem/global-state/subprocess isolation audit pending"},   # a gauntlet-adapter reason: runs here
        {"kind": "xcode", "stage": "unit", "path": A + "ArchiveRealRunTests.swift", "suites": ["ArchiveRealRunTests"], "tests": ["x"],
         "blocked_reason": "opt-in real run: runs only when observations/siglip2/realrun.json names a .backup copy"},
        {"kind": "xcode", "stage": "unit", "path": A + "ArchiveAngelPromoteTests.swift", "suites": ["ArchiveAngelPromoteTests"], "tests": ["p"]},
        {"kind": "xcode", "stage": "unit", "path": A + "ZebraTests.swift", "suites": ["ZebraTests"], "tests": ["z"]},
        {"kind": "xcode", "stage": "hallie", "path": A + "HallieEvalTests.swift", "suites": ["HallieEvalTests"], "tests": ["h"]},
        {"kind": "ui", "stage": "ui", "path": "VideoScan/VideoScanUITests/SmokeUITests.swift", "suites": ["SmokeUITests"], "tests": ["u"]},
        {"kind": "package", "stage": "unit", "path": C + "Store/CatalogStoreTests.swift", "suites": ["CatalogStoreTests"], "tests": ["s"]},
        {"kind": "package", "stage": "unit", "path": C + "FamilyMapKeyTests.swift", "suites": ["FamilyMapKeyTests"], "tests": ["k"]},
        {"kind": "package", "stage": "unit", "path": C + "GedcomMergeTests.swift", "suites": ["GedcomMergeTests"], "tests": ["m"]},
        {"kind": "python", "stage": "unit", "path": "tests/test_gauntlet_runner.py", "suites": ["test_gauntlet_runner.py"], "tests": ["t1", "t2"]},
        {"kind": "python", "stage": "unit", "path": "tests/test_gauntlet_publish.py", "suites": ["test_gauntlet_publish.py"], "tests": ["t1"]},
    ]
    return files, {"assignments": assign}


def test_modules_map_from_the_source_folders():
    files, _ = tree_and_manifest()
    idx = rt.build_index(files)
    A, C = "VideoScan/VideoScanTests/", "VideoScan/VideoScanCore/Tests/VideoScanCoreTests/"
    assert rt.module_of(A + "CatalogQueriesDecadeTests.swift", idx) == "Catalog"
    assert rt.module_of(A + "ArchiveFixityTests.swift", idx) == "Archive"
    assert rt.module_of(A + "ArchiveAngelPromoteTests.swift", idx) == "ArchiveAngel"    # folder name, longest first
    assert rt.module_of(A + "ZebraTests.swift", idx) == "Other"
    assert rt.module_of(C + "Store/CatalogStoreTests.swift", idx) == "Core/Store"
    assert rt.module_of(C + "FamilyMapKeyTests.swift", idx) == "Core/FamilyMap"
    assert rt.module_of(C + "GedcomMergeTests.swift", idx) == "Core/Gedcom"
    assert rt.module_of("tests/test_gauntlet_runner.py", idx) == "py/gauntlet"


def test_smoke_picks_the_smallest_file_per_module_and_stage_deterministically():
    files, man = tree_and_manifest()
    picks = rt.select(man, files, rt.STAGES, {"app", "core", "python"})
    again = rt.select(json.loads(json.dumps(man)), list(reversed(files)), rt.STAGES, {"app", "core", "python"})
    assert picks == again
    by = {(p.kind, p.module, p.stage): [x.path.rsplit("/", 1)[-1] for x in picks if (x.kind, x.module, x.stage) == (p.kind, p.module, p.stage)] for p in picks}
    # 3 runnable Catalog unit files (< 4): one pick, the fewest tests, ties by path
    assert by[("app", "Catalog", "unit")] == ["CatalogQueriesAaaTests.swift"]
    assert by[("app", "Archive", "regression")] == ["ArchiveFixityTests.swift"]       # gauntlet-adapter block: runs here
    assert ("app", "Archive", "unit") not in by                                           # opt-in real run: not here
    assert by[("python", "py/gauntlet", "unit")] == ["test_gauntlet_publish.py"]
    assert not any(p.stage in ("hallie", "ui") for p in picks)
    assert not any(p.tests == 0 for p in picks)


def test_a_big_group_also_gets_its_median_file():
    files, man = tree_and_manifest()
    for i in range(4):
        man["assignments"].append({"kind": "xcode", "stage": "unit", "path": f"VideoScan/VideoScanTests/CatalogQueriesN{i}Tests.swift",
                                   "suites": [f"N{i}"], "tests": ["t"] * (10 + i)})
    picks = [p for p in rt.select(man, files, rt.STAGES, {"app"}) if p.module == "Catalog"]
    assert len(picks) == 2 and picks[0].tests == 1 and picks[1].tests > 1


def test_a_python_group_takes_only_its_smallest_file():
    files, man = tree_and_manifest()
    for i in range(4):
        man["assignments"].append({"kind": "python", "stage": "unit", "path": f"tests/test_gauntlet_n{i}.py",
                                   "suites": [f"test_gauntlet_n{i}.py"], "tests": ["t"] * (10 + i)})
    picks = [p for p in rt.select(man, files, rt.STAGES, {"python"}) if p.module == "py/gauntlet"]
    assert [p.path for p in picks] == ["tests/test_gauntlet_publish.py"]


def test_stage_and_kind_flags_narrow():
    files, man = tree_and_manifest()
    a = rt.parse_args(["--regression"])
    picks = rt.select(man, files, a.stages, a.kinds)
    assert {p.stage for p in picks} == {"regression"} and "corpus" not in a.kinds
    a = rt.parse_args(["--python"])
    assert a.kinds == {"python"}
    assert {p.kind for p in rt.select(man, files, a.stages, a.kinds)} == {"python"}
    assert rt.parse_args([]).kinds == {"app", "core", "python", "corpus"}
    # the smoke leaves the long, load-sensitive stages out unless asked; --full has them all
    assert rt.parse_args([]).stages == ["unit", "regression", "integration"]
    assert rt.parse_args(["--perf"]).stages == ["performance"]
    assert rt.parse_args(["--full"]).stages == rt.STAGES
    assert rt.parse_args(["--unit", "--python"]).kinds == {"app", "core", "python"}


def test_the_real_manifest_selects_a_deterministic_nonempty_smoke():
    man = json.loads((ROOT / "scripts/gauntlet/manifest.json").read_text())
    files = subprocess.run(["git", "-C", str(ROOT), "ls-files"], capture_output=True, text=True).stdout.splitlines()
    picks = rt.select(man, files, rt.STAGES, {"app", "core", "python"})
    assert picks == rt.select(man, files, rt.STAGES, {"app", "core", "python"})
    kinds = {p.kind for p in picks}
    assert {"app", "core", "python"} <= kinds
    assert 300 < sum(p.tests for p in picks) < 4000          # a smoke, not the 14,000-test suite
    assert all(rt.runnable_here(e) is False for e in man["assignments"]
               if "opt-in" in (e.get("blocked_reason") or ""))


# ───────────────────────────── verdict

def L(name, **kw):
    return rt.LaneResult(name, **kw)


def test_all_green_is_exit_0():
    assert rt.verdict([L("app", ran=True, passed=5, rc=0), L("core", ran=True, passed=3, rc=0)]) == (0, "GREEN")


def test_a_failure_is_red():
    assert rt.verdict([L("app", ran=True, passed=5, failed=1, rc=65), L("core", ran=True, passed=3, rc=0)]) == (1, "RED")


def test_a_zero_test_lane_is_red_even_with_exit_0():
    lane = L("core", ran=True, passed=0, rc=0)
    assert lane.word == "RED"
    assert rt.verdict([L("app", ran=True, passed=5, rc=0), lane]) == (1, "RED")


def test_only_skips_is_red():
    assert L("x", ran=True, skipped=4, rc=0).word == "RED"


def test_a_nonzero_exit_with_passes_is_red():
    # xcodebuild exit 65 with every parsed test passing (a crashed host, a lost line): not green
    assert L("app", ran=True, passed=10, rc=65).word == "RED"


def test_not_run_is_never_green_and_nothing_run_is_red():
    nr = L("corpus", reason="M4 only")
    assert nr.word == "NOT RUN"
    assert rt.verdict([L("app", ran=True, passed=1, rc=0), nr]) == (0, "GREEN")
    assert rt.verdict([nr]) == (1, "RED")
    assert rt.verdict([]) == (1, "RED")


# ───────────────────────────── arguments and --host

def test_mode_defaults_and_exclusive_flags():
    assert rt.parse_args([]).mode == "smoke"
    assert rt.parse_args(["--full"]).mode == "full"
    with pytest.raises(SystemExit) as e:
        rt.parse_args(["--smoke", "--full"])
    assert e.value.code == 2
    with pytest.raises(SystemExit) as e:
        rt.parse_args(["--host", "m9"])
    assert e.value.code == 2


def test_host_words_map_to_ssh_names_or_local():
    assert rt.ssh_target("m4", "RicksUltra") == "ricksm4.local"
    assert rt.ssh_target("m5pro", "RicksUltra") == "ricksm5.local"
    assert rt.ssh_target("m1", "RicksUltra") == "ricksm1.local"
    assert rt.ssh_target("ultra", "RicksUltra") is None          # the Mac it is typed on
    assert rt.ssh_target("m5pro", "ricksm5.local") is None
    assert rt.ssh_target(None, "RicksM4") is None
    assert rt.local_host_key("RicksM4") == "m4"
    assert rt.local_host_key("someone-else") is None


def test_remote_command_pins_the_commit_and_never_passes_host_on():
    copy, run = rt.remote_commands("ricksm4.local", "a" * 40, "main",
                                   ["--smoke", "--host", "m4", "--verbose", "--ref", "main", "--unit"])
    assert copy[:1] == ["ssh"] and "BatchMode=yes" in copy and copy[-1].startswith("mkdir -p ~/Library/Caches/videoscan-runall")
    assert run[:2] == ["ssh", "-t"] and run[-2] == "ricksm4.local"
    cmd = run[-1]
    assert "git -C ~/dev/VideoScan fetch -q origin" in cmd
    assert "--on-host" in cmd and f"--ref {'a' * 40}" in cmd and "--verbose" in cmd and "--unit" in cmd
    assert "--host" not in cmd and "--ref main" not in cmd
    assert "/usr/bin/python3" in cmd                                # nothing to install on a fleet Mac


def test_app_tests_over_ssh_go_through_the_gui_domain():
    assert rt.under_ssh({"SSH_CONNECTION": "10.0.0.1 5 10.0.0.2 22"})
    assert not rt.under_ssh({"TERM": "xterm"})
    pl = rt.gui_plist("com.videoscan.runtests.1.2", ["/bin/bash", "-c", "a && b < c"],
                      {"PATH": "/opt/homebrew/bin:/usr/bin", "SECRET": "x"}, "/tmp/wt")
    assert "<string>a &amp;&amp; b &lt; c</string>" in pl            # XML-escaped, never raw
    assert "PATH" in pl and "SECRET" not in pl                         # a short env allow-list
    assert "<key>Label</key><string>com.videoscan.runtests.1.2</string>" in pl


def test_the_corpus_call_keeps_ref_and_its_commit_together():
    # M4 smoke 2026-11-19: "--limit 10" was spliced between --ref and the commit → "m4_run: unexpected argument 10"
    c = rt.corpus_cmd(Path("/r"), "abc123", True)
    assert c[c.index("--ref") + 1] == "abc123"
    assert c[-1] == "--wait" and c[2:4] == ["run", "check"]
    assert "--smoke" not in rt.corpus_cmd(Path("/r"), "abc123", False)


def test_the_smoke_corpus_step_is_the_harness_stratified_smoke_not_the_first_n_files(monkeypatch, tmp_path):
    # M4 2026-11-20: "--limit 10" took the first 10 files by SHA — 2.7 GB of tapes — and the smoke's
    # corpus step ran 28 min (target: the whole smoke in 15). The harness's --smoke takes the smallest
    # file per codec mix.
    c = rt.corpus_cmd(Path("/r"), "abc123", True)
    assert "--smoke" in c and "--limit" not in c
    seen = {}

    def fake_corpus(out, script_repo, sha_, run_dir, verbose, smoke):
        seen["smoke"] = smoke
        return rt.LaneResult("corpus", ran=True, passed=60, rc=0)
    text, host_rc = host_summary_text(["--corpus"])
    drive_remote(monkeypatch, tmp_path, ["--corpus", "--host", "m4", "--yes"], text, host_rc)
    monkeypatch.setattr(rt, "run_corpus", fake_corpus)
    assert rt.main(["--corpus", "--host", "m4", "--yes"]) == 0
    assert seen["smoke"] is True


def test_the_corpus_lane_counts_this_runs_files_and_stops_before_older_runs():
    # recorded from the M4 run 2026-11-19 18:47 (counts and outcome words only)
    lines = [
        "m4_run: corpus on M4 at 431753b90 (431753b90fd02ab00866f5701faaf6cbe5fa20dd)",
        "m4_run: started — output /Users/x/m4run/out/20261119_184700_64053-corpus (run.log, summary.txt)",
        "  some build line we never show",
        "M4: idle",
        "OUTCOME GREEN 2026-11-19 18:49:27 lane=corpus sha=431753b90",
        "  corpus check: GREEN 10 files (3.3 GB, 0.3 h of media) at 431753b90 — wall 141s (build 127s), 1 launch(es)",
        "OUTCOME GREEN 2026-11-19 00:23:15 lane=suite sha=431753b90",
        "  corpus proof  AMBER   1369s  8 files — balance: balanced 8 · proof: not_proven 5, same_content 3",
    ]
    c = rt.CorpusLines()
    shown = [x for x in (c.feed(l) for l in lines) if x is not None]
    assert c.files == 10
    assert shown[-1].startswith("corpus check: GREEN 10 files")
    assert not any("lane=suite" in x or "corpus proof" in x or "build line" in x for x in shown)


def test_the_caller_reads_the_hosts_own_total():
    text = ("[\x1b[32m==========\x1b[0m] noise\n\r[ 5/9 ] "
            "\x1b[31m[==========]\x1b[0m RED · lanes: GREEN 3 · RED 1 · 2320 tests · 17m14s\n"
            "\x1b[31m[  FAILED  ]\x1b[0m CatalogTests.testX\n[  FAILED  ] app: exit 65\nlogs: /x\n")
    n, nf, names = rt.remote_counts(text)
    assert (n, nf) == (2320, 2) and names[0] == "CatalogTests.testX"
    assert rt.remote_counts("ssh: connect to host ricksm4.local port 22: Operation timed out\n") == (0, 0, [])


def test_commands_use_debug_the_side_dd_and_only_testing():
    wt = Path("/x/wt")
    b = rt.app_build_cmd(wt)
    assert "build-for-testing" in b and "Debug" in b and str(rt.DD) in b
    t = rt.app_test_cmd(wt, ["SuiteA", "SuiteB"])
    assert "test-without-building" in t and "-only-testing:VideoScanTests/SuiteA" in t
    import re
    f = re.compile(rt.core_filter(["CatalogStoreTests", "Foo"]))
    assert f.search("VideoScanCoreTests.CatalogStoreTests/testX")
    assert f.search("VideoScanCoreTests.Outer/Foo/bar()")
    assert not f.search("VideoScanCoreTests.CatalogStoreTestsExtra/testX")
    assert not f.search("VideoScanCoreTests.NotFoo/bar()")


# ───────────────────────────── the side worktree

def git(*a, cwd):
    subprocess.run(["git", "-C", str(cwd)] + list(a), check=True, capture_output=True)


@pytest.fixture
def repo(tmp_path):
    r = tmp_path / "repo"
    r.mkdir()
    git("init", "-q", cwd=r)
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "one", cwd=r)
    (r / "f.txt").write_text("1")
    git("add", "f.txt", cwd=r)
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "-m", "two", cwd=r)
    return r


def sha(r, ref="HEAD"):
    return subprocess.run(["git", "-C", str(r), "rev-parse", ref], capture_output=True, text=True).stdout.strip()


def test_refuses_the_checkout_itself(repo, tmp_path):
    with pytest.raises(rt.Refused):
        rt.prepare_worktree(repo, repo, sha(repo), tmp_path / "dd")


def test_refuses_ricks_checkout_and_xcode_derived_data(tmp_path):
    with pytest.raises(rt.Refused):
        rt.check_paths(tmp_path, Path.home() / "dev" / "VideoScan", tmp_path / "dd")
    with pytest.raises(rt.Refused):
        rt.check_paths(tmp_path, tmp_path / "wt", rt.XCODE_DD / "VideoScan-abc")


def test_refuses_any_main_checkout(repo, tmp_path):
    other = tmp_path / "other"
    other.mkdir()
    git("init", "-q", cwd=other)
    with pytest.raises(rt.Refused):
        rt.prepare_worktree(repo, other, sha(repo), tmp_path / "dd")


def test_adds_then_moves_the_side_worktree_and_refuses_it_dirty(repo, tmp_path):
    wt = tmp_path / "wt" / "run-all"
    rt.prepare_worktree(repo, wt, sha(repo, "HEAD~1"), tmp_path / "dd")
    assert sha(wt) == sha(repo, "HEAD~1")
    rt.prepare_worktree(repo, wt, sha(repo), tmp_path / "dd")       # moves, detached
    assert sha(wt) == sha(repo)
    assert subprocess.run(["git", "-C", str(repo), "rev-parse", "--abbrev-ref", "HEAD"],
                          capture_output=True, text=True).stdout.strip() in ("master", "main")   # the checkout's branch: untouched
    (wt / "f.txt").write_text("changed")
    with pytest.raises(rt.Refused, match="local changes"):
        rt.prepare_worktree(repo, wt, sha(repo, "HEAD~1"), tmp_path / "dd")
    assert (wt / "f.txt").read_text() == "changed"                    # never discarded


def test_the_lock_refuses_a_second_holder(tmp_path):
    fd = rt.take_lock(tmp_path / "lock", "first run")
    with pytest.raises(rt.Busy, match="first run"):
        rt.take_lock(tmp_path / "lock", "second")
    import os
    os.close(fd)
    os.close(rt.take_lock(tmp_path / "lock", "third"))


def test_the_shell_entry_is_a_thin_exec():
    sh = (ROOT / "scripts" / "run_tests.sh").read_text()
    assert "/usr/bin/python3" in sh and "run_tests.py" in sh


def test_list_runs_without_a_build(tmp_path):
    p = subprocess.run([sys.executable, str(ROOT / "scripts" / "run_tests.py"), "--list", "--ref", "HEAD"],
                       capture_output=True, text=True, timeout=120)
    assert p.returncode == 0, p.stderr
    assert "UI tests" in p.stdout and "# total" in p.stdout


# ───────────────────────────── review 2026-11-19 (R1–R7 and the dry-run findings)
# Each of these was RED on 693c2e5b8. Nothing here touches the real caches or a host:
# CACHE / RUN_WT are temp folders, ssh and git are faked.

def quiet_out():
    return rt.Out(False, io.StringIO())


def alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def test_r1_a_silent_hang_is_cut_at_the_budget(tmp_path):
    # the budget was looked at only when the child printed a line
    r = rt.Runner(quiet_out(), tmp_path, dict(os.environ))
    t0 = time.monotonic()
    rc, _ = r.stream(["/bin/sleep", "6"], "hang.log", budget=1)
    took = time.monotonic() - t0
    assert rc == 124, f"a child that prints nothing ran past its 1 s budget (exit {rc} after {took:.1f}s)"
    assert took < 4


def test_r1_a_chatty_child_still_streams_every_line_and_its_exit_code(tmp_path):
    lane = rt.LaneResult("py", ran=True)
    r = rt.Runner(quiet_out(), tmp_path, dict(os.environ))
    script = "; ".join(f"echo 'tests/t.py::test_{i} PASSED'" for i in range(500)) + "; exit 0"
    rc, _ = r.stream(["/bin/sh", "-c", script], "chatty.log", budget=30, parser=rt.LineParser(), lane=lane)
    assert (rc, lane.passed) == (0, 500)
    assert sum(l.startswith("tests/t.py::") for l in (tmp_path / "chatty.log").read_text().splitlines()) == 500
    assert r.child is None


@pytest.mark.parametrize("sig", [signal.SIGHUP, signal.SIGTERM])
def test_r2_a_hangup_or_term_takes_the_child_down_too(tmp_path, sig):
    # no SIGHUP/SIGTERM handling + start_new_session=True: a dropped ssh session left the child running
    pidfile = tmp_path / "child.pid"
    driver = tmp_path / "driver.py"
    driver.write_text(textwrap.dedent(f"""
        import importlib.util, io, os, sys
        from pathlib import Path
        spec = importlib.util.spec_from_file_location("run_tests", {str(ROOT / 'scripts' / 'run_tests.py')!r})
        rt = importlib.util.module_from_spec(spec); sys.modules["run_tests"] = rt; spec.loader.exec_module(rt)
        r = rt.Runner(rt.Out(False, io.StringIO()), Path({str(tmp_path)!r}), dict(os.environ))
        try:
            r.stream(["/bin/sh", "-c", "echo $$ > {pidfile}; exec /bin/sleep 60"], "x.log", budget=120)
        except KeyboardInterrupt:
            r.stop()
    """))
    p = subprocess.Popen([sys.executable, str(driver)])
    child = None
    try:
        for _ in range(200):
            if pidfile.exists() and pidfile.read_text().strip():
                break
            time.sleep(0.05)
        child = int(pidfile.read_text())
        p.send_signal(sig)
        p.wait(timeout=30)
        time.sleep(1.0)
        assert not alive(child), f"the runner died on {sig.name} and its child (pid {child}) is still running"
    finally:
        if child and alive(child):
            os.kill(child, signal.SIGKILL)
        if p.poll() is None:
            p.kill()


def test_r2_the_signal_handlers_are_restored_after_a_stream(tmp_path):
    before = signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGHUP)
    rt.Runner(quiet_out(), tmp_path, dict(os.environ)).stream(["/usr/bin/true"], "t.log", budget=10)
    assert (signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGHUP)) == before


class FakeDone:
    returncode = 0


def fake_git_for(sha):
    def fake_git(repo, *args, check=True):
        if args[:1] == ("show",):
            return '{"assignments": []}'
        if args[:2] == ("rev-parse", "--verify"):
            return sha
        if args[:2] == ("rev-parse", "--abbrev-ref"):
            return "main"
        if args[:1] == ("branch",):
            return "origin/main"
        return ""
    return fake_git


def drive_remote(monkeypatch, tmp_path, argv, host_text, host_rc):
    """main() as the Ultra runs it for --host m4; the 'host' is a local process printing host_text."""
    calls = {"corpus": 0, "host": 0}

    def fake_corpus(out, script_repo, sha_, run_dir, verbose, limit):
        calls["corpus"] += 1
        return rt.LaneResult("corpus", ran=True, passed=10, rc=0)

    real_popen = subprocess.Popen
    script = tmp_path / "host.py"
    script.write_text(f"import sys\nsys.stdout.write({host_text!r})\nsys.exit({host_rc})\n")

    def fake_popen(cmd, **k):
        calls["host"] += 1
        return real_popen([sys.executable, str(script)], **k)
    monkeypatch.setattr(rt, "git", fake_git_for("a" * 40))
    monkeypatch.setattr(rt, "local_host_key", lambda hostname=None: "ultra")
    monkeypatch.setattr(rt, "run_corpus", fake_corpus)
    monkeypatch.setattr(rt, "CACHE", tmp_path / "cache")
    monkeypatch.setattr(rt.subprocess, "run", lambda *a, **k: FakeDone())
    monkeypatch.setattr(rt.subprocess, "Popen", fake_popen)
    return rt.main(argv), calls


def host_summary_text(argv):
    """What the host prints for these args when no lane is selected: the real run_lanes + summary."""
    a = rt.parse_args(argv + ["--on-host"])
    a.stages_label = list(a.stages)
    buf = io.StringIO()
    out = rt.Out(False, buf)
    lanes = rt.run_lanes(a, [], Path("/nonexistent"), Path("/nonexistent"), out, Path("/nonexistent"), "smoke")
    code = rt.summary(out, lanes, 0.0, None)
    return buf.getvalue(), code


def test_r3_corpus_only_on_the_m4_runs_no_host_smoke_and_is_green_when_the_corpus_is(monkeypatch, tmp_path):
    runs = tmp_path / "cache" / "runs"
    for i in range(25):                                   # caller-side folders are pruned like run folders
        (runs / f"20260101-0000{i:02d}-corpus").mkdir(parents=True)
    text, host_rc = host_summary_text(["--corpus"])
    code, calls = drive_remote(monkeypatch, tmp_path, ["--corpus", "--host", "m4", "--yes"], text, host_rc)
    assert calls == {"corpus": 1, "host": 0}
    assert code == 0, "the only lane asked for (corpus) was GREEN, yet the run is RED"
    assert len(list(runs.iterdir())) == rt.KEEP_RUNS


def test_r4_ctrl_c_on_the_host_exits_130_and_the_corpus_lane_is_not_started(monkeypatch, tmp_path):
    buf = io.StringIO()
    out = rt.Out(False, buf)
    out.line("FAILED", "interrupted (Ctrl-C) — the run is incomplete", "FAILED")
    host_rc = rt.summary(out, [rt.LaneResult("interrupted", ran=True, rc=130, reason="interrupted")], 12.0, None)
    assert host_rc == 130
    code, calls = drive_remote(monkeypatch, tmp_path, ["--host", "m4", "--yes"], buf.getvalue(), host_rc)
    assert calls["corpus"] == 0, "the user pressed Ctrl-C; the corpus check was launched on the M4 anyway"
    assert code == 130


def test_r4_a_busy_host_does_not_start_the_corpus_lane(monkeypatch, tmp_path):
    code, calls = drive_remote(monkeypatch, tmp_path, ["--host", "m4", "--yes"], "run_tests: busy\n", 3)
    assert (code, calls["corpus"]) == (3, 0)


def test_r5_full_python_lane_names_an_interpreter_that_has_pytest(monkeypatch, tmp_path):
    seen = {}

    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        seen["cmd"], seen["env"] = cmd, dict(self.env)
        (self.run_dir / log_name).write_text("400 passed in 1.0s\n")
        return 0, 1.0
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    monkeypatch.setattr(rt, "python_for_tests", lambda repos: (["/some/venv/bin/python"], "/some/venv/bin/python"))
    a = rt.parse_args(["--full", "--python"])
    lanes = rt.run_full(a, quiet_out(), tmp_path, "ultra")
    assert seen["cmd"][-1].endswith("run_python_tests.sh")
    assert seen["env"].get("PYTHON") == "/some/venv/bin/python", \
        "run_python_tests.sh is started with no PYTHON=: in the venv-less side worktree it uses bare python3"
    assert lanes[0].passed == 400 and lanes[0].word == "GREEN"


def test_full_passes_jobs_to_the_nightly_runner_and_leaves_its_default_alone_otherwise(monkeypatch, tmp_path):
    # 2026-11-21: the nightly runner shards its own app phase (half the cores). --full --jobs N is its
    # NIGHTLY_APP_JOBS (1 = the single host); without --jobs the variable is whatever the caller's was.
    seen = []

    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        if any(str(c).endswith("nightly_local_tests.sh") for c in cmd):
            seen.append((cmd, dict(self.env)))
        (self.run_dir / log_name).write_text("1 passed in 1.0s\n")
        return 0, 1.0
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    monkeypatch.setattr(rt, "python_for_tests", lambda repos: (["/some/venv/bin/python"], "/some/venv/bin/python"))
    monkeypatch.delenv("NIGHTLY_APP_JOBS", raising=False)
    rt.run_full(rt.parse_args(["--full", "--jobs", "1"]), quiet_out(), tmp_path, "ultra")
    rt.run_full(rt.parse_args(["--full"]), quiet_out(), tmp_path, "ultra")
    assert len(seen) == 2 and all("--on-demand" in cmd for cmd, _ in seen), seen
    assert seen[0][1].get("NIGHTLY_APP_JOBS") == "1"
    assert "NIGHTLY_APP_JOBS" not in seen[1][1]


def _full_with_runner_output(monkeypatch, tmp_path, row, suite_log, py_log="", py_rc=0, runner_rc=1):
    """--full with fakes: the nightly runner writes `row`/`suite_log` into <run>/full; the python lane
    writes `py_log` and exits `py_rc`. Returns (lanes, summary text)."""
    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        if any(str(c).endswith("nightly_local_tests.sh") for c in cmd):
            full = self.run_dir / "full"
            full.mkdir(exist_ok=True)
            if row is not None:
                (full / "suite-row.json").write_text(json.dumps(row))
            (full / "suite.log").write_text(suite_log)
            return runner_rc, 1.0
        (self.run_dir / log_name).write_text(py_log)
        return py_rc, 1.0
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    monkeypatch.setattr(rt, "python_for_tests", lambda repos: (["/some/venv/bin/python"], "/some/venv/bin/python"))
    monkeypatch.setattr(rt.time, "sleep", lambda s: None)
    lanes = rt.run_full(rt.parse_args(["--full"]), quiet_out(), tmp_path, "ultra")
    buf = io.StringIO()
    rt.summary(rt.Out(False, buf), lanes, 1.0, tmp_path)
    return lanes, buf.getvalue()


SETUP_LOG = ("[13:08:01] MACHINE SETUP: Xcode's first launch is not done (xcodebuild -checkFirstLaunchStatus failed)\n"
             "[13:08:01]   fix (once, at the Mac): sudo xcodebuild -runFirstLaunch\n"
             "[13:08:01] FATAL: this Mac is not set up to host the tests (machine-setup:xcode-first-launch)\n")


def test_full_app_core_lane_says_the_runners_reason_not_no_test_counted(monkeypatch, tmp_path):
    # RED 2026-11-22 (M5 Pro, Xcode 27.2 first launch not done): the summary said only
    # "app+core (nightly runner, Release): no test counted"; the reason and its fix were in full/.
    row = {"passed": 0, "failed": 0, "skipped": 0, "status": "failed", "reason": "machine-setup:xcode-first-launch",
           "core_status": "not-run"}
    lanes, shown = _full_with_runner_output(monkeypatch, tmp_path, row, SETUP_LOG, "5 passed in 1.0s\n")
    app = lanes[0]
    assert app.word == "RED"
    assert "machine-setup:xcode-first-launch" in app.reason, app.reason
    assert "sudo xcodebuild -runFirstLaunch" in app.reason, app.reason
    assert "no test counted" not in shown and "sudo xcodebuild -runFirstLaunch" in shown, shown


def test_full_app_core_lane_takes_counts_and_names_from_the_runners_row(monkeypatch, tmp_path):
    # the live tail can miss lines (it polls); the runner's own row is the count of record
    row = {"passed": 140, "failed": 1, "skipped": 6, "failed_names": ["testAppBroke"], "status": "failed",
           "reason": "failed-tests:1", "core_passed": 50, "core_failed": 1, "core_skipped": 2,
           "core_failed_names": ["coreBroke()"]}
    lanes, shown = _full_with_runner_output(monkeypatch, tmp_path, row, "[02:00] runner log\n", "5 passed in 1.0s\n")
    app = lanes[0]
    assert (app.passed, app.failed, app.skipped) == (190, 2, 8), (app.passed, app.failed, app.skipped)
    assert sorted(e.name for e in app.failures) == ["coreBroke()", "testAppBroke"]
    assert app.word == "RED" and "testAppBroke" in shown and "coreBroke()" in shown


def test_full_python_lane_counts_and_names_a_red_run(monkeypatch, tmp_path):
    # RED 2026-11-22: the log ended "1 failed, 2855 passed, …" with the FAILED node id, and the summary
    # said "python (run_python_tests.sh): no test counted" — the summary line was read only on exit 0.
    py_log = ("short test summary (all strands)\n"
              "FAILED tests/test_xctest_shards.py::test_end_to_end\n"
              "1 failed, 2855 passed, 21 skipped, 1 warning, 280 subtests passed in 143.45s\n")
    row = {"passed": 10, "failed": 0, "skipped": 0, "status": "ok", "reason": ""}
    lanes, shown = _full_with_runner_output(monkeypatch, tmp_path, row, "", py_log, py_rc=1, runner_rc=0)
    py = lanes[1]
    assert (py.passed, py.failed, py.skipped) == (2855, 1, 21), (py.passed, py.failed, py.skipped)
    assert [e.name for e in py.failures] == ["tests/test_xctest_shards.py::test_end_to_end"]
    assert "no test counted" not in shown and "test_end_to_end" in shown, shown


def test_full_python_lane_never_reads_subtests_as_tests(monkeypatch, tmp_path):
    row = {"passed": 10, "failed": 0, "skipped": 0, "status": "ok", "reason": ""}
    lanes, _ = _full_with_runner_output(monkeypatch, tmp_path, row, "",
                                        "2872 passed, 4 skipped, 280 subtests passed in 154.70s\n", runner_rc=0)
    assert (lanes[1].passed, lanes[1].skipped, lanes[1].word) == (2872, 4, "GREEN")


def test_r5_full_python_lane_without_pytest_anywhere_is_not_run_with_the_reason(monkeypatch, tmp_path):
    monkeypatch.setattr(rt.Runner, "stream", lambda *a, **k: pytest.fail("ran without pytest"))
    monkeypatch.setattr(rt, "python_for_tests", lambda repos: (None, "no pytest in x"))
    lanes = rt.run_full(rt.parse_args(["--full", "--python"]), quiet_out(), tmp_path, "ultra")
    assert lanes[0].word == "NOT RUN" and lanes[0].reason == "no pytest in x"


def test_r6_a_lane_that_ran_a_sliver_of_its_selection_is_not_green(monkeypatch, tmp_path):
    # a lane was GREEN on ANY one pass: an -only-testing / --filter that matches nothing exits 0
    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        if lane is not None:
            lane.passed += 1                      # one test ran, of ~500 selected
        return 0, 1.0
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    picks = [rt.Pick("core", "Core/Store", "unit", "x/ATests.swift", ("ATests",), 250),
             rt.Pick("core", "Core/Store", "unit", "x/BTests.swift", ("BTests",), 250)]
    a = rt.parse_args(["--unit"])
    a.kinds = {"core"}
    a.stages_label = ["unit"]
    buf = io.StringIO()
    lanes = rt.run_lanes(a, picks, tmp_path, tmp_path, rt.Out(False, buf), tmp_path, "smoke")
    assert rt.verdict(lanes) == (1, "RED"), "1 of ~500 selected tests ran and the run is GREEN"
    assert "selection shrank: ran 1 of ~500" in buf.getvalue()
    assert lanes[0].reason == "selection shrank: ran 1 of ~500"


def test_r6_the_floor_is_half_the_plan_and_unknown_plans_have_none():
    assert L("core", ran=True, passed=250, rc=0, expected=500).word == "GREEN"
    assert L("core", ran=True, passed=249, rc=0, expected=500).word == "RED"
    assert L("core", ran=True, passed=900, rc=0, expected=500).word == "GREEN"     # parametrised cases: more is fine
    assert L("full", ran=True, passed=3, rc=0).word == "GREEN"                       # --full: its runner's own floors


def test_r7_a_stage_flag_with_full_is_refused(capsys):
    with pytest.raises(SystemExit) as e:
        rt.parse_args(["--full", "--unit"])
    assert e.value.code == 2
    assert "narrows a --smoke only" in capsys.readouterr().err


def drive_local(monkeypatch, tmp_path, argv, tty=False, git=None, preflight=None):
    """main() on this Mac (the Ultra) with git and the tool preflight faked; any side effect fails the test."""
    monkeypatch.setattr(rt, "preflight", preflight or (lambda lanes, env, **k: {}))
    def touched(*a, **k):
        raise AssertionError("a side effect ran before the refusal / countdown")
    monkeypatch.setattr(rt, "git", git or fake_git_for("b" * 40))
    monkeypatch.setattr(rt, "local_host_key", lambda hostname=None: "ultra")
    monkeypatch.setattr(rt, "CACHE", tmp_path / "cache")
    monkeypatch.setattr(rt, "RUN_WT", tmp_path / "wt")
    monkeypatch.setattr(rt, "prepare_worktree", touched)
    monkeypatch.setattr(rt, "take_lock", touched)
    monkeypatch.setattr(rt, "prune_runs", touched)
    monkeypatch.setattr(rt.subprocess, "Popen", touched)

    class TtyOut(rt.Out):
        def __init__(self, verbose, stream=None):
            super().__init__(verbose, sys.stdout)            # capsys sees it
            self.tty = tty
    monkeypatch.setattr(rt, "Out", TtyOut)
    return rt.main(argv)


def test_nothing_to_run_here_is_refused_up_front_and_touches_nothing(monkeypatch, tmp_path, capsys):
    assert drive_local(monkeypatch, tmp_path, ["--corpus", "--yes"]) == 2
    assert "nothing to run here: corpus runs only on the M4 (--host m4" in capsys.readouterr().err
    assert not (tmp_path / "cache").exists() and not (tmp_path / "wt").exists()
    assert drive_local(monkeypatch, tmp_path, ["--python", "--yes"]) == 2           # empty selection
    assert "nothing to run here: the selection is empty" in capsys.readouterr().err


def test_corpus_from_a_mac_that_cannot_launch_it_is_refused(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(rt, "git", fake_git_for("a" * 40))
    monkeypatch.setattr(rt, "local_host_key", lambda hostname=None: "m5pro")
    monkeypatch.setattr(rt.subprocess, "Popen", lambda *a, **k: pytest.fail("ssh started"))
    assert rt.main(["--corpus", "--host", "m4", "--yes"]) == 2
    assert "nothing to run here" in capsys.readouterr().err


def test_full_with_a_host_other_than_the_m4_is_refused(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(rt, "local_host_key", lambda hostname=None: "ultra")
    monkeypatch.setattr(rt, "git", lambda *a, **k: pytest.fail("git ran before the refusal"))
    for host in ("m5pro", "m1"):
        assert rt.main(["--full", "--host", host]) == 2
        assert "type scripts/run_tests.sh --full on that Mac" in capsys.readouterr().err


TESTBED_GREEN = """m4_run: testbed on M4 at aaaaaaaaa
M4: idle
last run: /Users/rickb/m4run/out/x-testbed
  OUTCOME AMBER 2026-11-20 13:00:00 lane=testbed sha=aaaaaaaaa — suite GREEN · corpus check GREEN · corpus proof AMBER
  testbed: AMBER at aaaaaaaaa — 3 lanes, wall 5199s
    suite         GREEN   3246s  app 14152 passed, 0 failed, 67 skipped; core 2587 passed, 0 failed, 7 skipped
    corpus check  GREEN    584s  6351 files
"""


def drive_m4_full(monkeypatch, tmp_path, text, rc, argv=("--full", "--host", "m4", "--yes")):
    seen = {}

    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        seen["cmd"], seen["budget"] = cmd, budget
        for line in text.splitlines():
            on_line(line)
        return rc, 60.0
    monkeypatch.setattr(rt, "git", fake_git_for("a" * 40))
    monkeypatch.setattr(rt, "local_host_key", lambda hostname=None: "ultra")
    monkeypatch.setattr(rt, "CACHE", tmp_path / "cache")
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    monkeypatch.setattr(rt.subprocess, "Popen", lambda *a, **k: pytest.fail("ssh smoke started for --full"))
    monkeypatch.setattr(rt, "run_corpus", lambda *a, **k: pytest.fail("the smoke corpus step ran for --full"))
    return rt.main(list(argv)), seen


def test_full_host_m4_runs_the_m4_testbed_and_counts_its_suite(monkeypatch, tmp_path, capsys):
    # Rick 2026-11-20: "use the new scripts" — --full --host m4 was a refusal pointing at m4_run.sh.
    code, seen = drive_m4_full(monkeypatch, tmp_path, TESTBED_GREEN, 0)
    cmd = seen["cmd"]
    assert cmd[1].endswith("scripts/m4_run.sh") and cmd[2] == "testbed"
    assert cmd[cmd.index("--ref") + 1] == "a" * 40 and cmd[cmd.index("--host") + 1] == "m4" and "--wait" in cmd
    assert "--force" not in cmd
    assert seen["budget"] >= 22500 + 2 * 21600, "the waiter would stop before m4_run.sh's own testbed budget"
    o = capsys.readouterr().out
    assert code == 0
    assert "16739 tests" in o, o
    assert "corpus proof AMBER" in o, "the testbed's own lines are not shown"


def test_full_host_m4_counts_only_this_testbed_not_the_previous_suite_run(monkeypatch, tmp_path, capsys):
    # M4 2026-11-20 13:03 (recorded, counts and words only): the status after the testbed also prints the
    # 06:00 suite run (2 app + 1 core failed); the lane said "16740 passed, 3 failed" for a suite that was
    # 14151 + 2587 passed, 0 failed.
    text = """m4_run: testbed on M4 at 2b031dc15
M4: idle
last run: /Users/rickb/m4run/out/20261120_121609_18757-testbed
  OUTCOME RED 2026-11-20 13:03:33 lane=testbed sha=2b031dc15 — suite GREEN · corpus check RED · corpus proof RED
  testbed: RED at 2b031dc15 — 3 lanes, wall 2838s
    suite         GREEN   2797s  app 14151 passed, 0 failed, 67 skipped; core 2587 passed, 0 failed, 7 skipped
    corpus check  RED       20s  no facts file (see the lane's own lines)
  suite: GREEN app 14151 passed, 0 failed, 67 skipped; core 2587 passed, 0 failed, 7 skipped (sha=2b031dc15, 2797s)
  corpus check: RED refused by the harness (rc=2; the reason is in corpus.log on the M4)
last suite run: /Users/rickb/m4run/out/20261120_060035_19272-suite
  suite: RED failed-tests:2 — app 14154 passed, 2 failed, 67 skipped; core 2586 passed, 1 failed, 7 skipped (sha=2b031dc15, 3789s)
push watcher: 2026-11-20 07:07:50 2b031dc15 suite RED — suite: RED failed-tests:2 — app 14154 passed, 2 failed, 67 skipped; core 2586 passed, 1 failed
"""
    code, _ = drive_m4_full(monkeypatch, tmp_path, text, 1)
    o = capsys.readouterr().out
    assert code == 1
    assert "16738 passed, 0 failed" in o, o
    assert "3 failed" not in o


def test_full_host_m4_red_busy_and_countless_runs_are_never_green(monkeypatch, tmp_path, capsys):
    red = TESTBED_GREEN.replace("app 14152 passed, 0 failed", "app 14150 passed, 2 failed")
    assert drive_m4_full(monkeypatch, tmp_path, red, 1)[0] == 1
    assert drive_m4_full(monkeypatch, tmp_path, "m4_run: the testbed is busy\n", 3)[0] == 1
    assert "busy" in capsys.readouterr().out
    assert drive_m4_full(monkeypatch, tmp_path, "OUTCOME GREEN\n", 0)[0] == 1, "GREEN with no suite count"
    code, seen = drive_m4_full(monkeypatch, tmp_path, TESTBED_GREEN, 0, ("--full", "--host", "m4", "--yes", "--force"))
    assert "--force" in seen["cmd"]


def test_full_host_m4_dry_run_prints_the_testbed_command(monkeypatch, tmp_path, capsys):
    code, seen = drive_m4_full(monkeypatch, tmp_path, "", 0, ("--full", "--host", "m4", "--dry-run"))
    assert code == 0 and not seen
    assert "m4_run.sh testbed --host m4 --ref " + "a" * 40 + " --wait" in capsys.readouterr().out


def test_a_bad_ref_says_unknown_ref_cleanly(monkeypatch, capsys):
    def fake_git(repo, *args, check=True):
        if args[:2] == ("rev-parse", "--verify"):
            raise rt.Refused("git rev-parse --verify -q nope^{commit}: ")
        return ""
    monkeypatch.setattr(rt, "git", fake_git)
    assert rt.main(["--ref", "nope", "--dry-run"]) == 2
    assert capsys.readouterr().err.strip() == "run_tests: unknown ref nope"


def test_the_full_plan_line_names_the_runners_not_zero_tests():
    a = rt.parse_args(["--full"])
    line = rt.plan_line(a, "RicksUltra", "main", "c" * 40, [], "", False)
    assert "all suites (nightly runners)" in line and "~0 tests" not in line


def test_every_selection_flag_has_help(capsys):
    with pytest.raises(SystemExit):
        rt.parse_args(["--help"])
    text = capsys.readouterr().out
    for f in ("--unit", "--regression", "--integration", "--perf", "--stress", "--python", "--corpus"):
        line = next(l for l in text.splitlines() if l.strip().startswith(f))
        assert len(line.strip()) > len(f) + 2, f"{f} has no help text"


def test_the_countdown_comes_before_any_side_effect(monkeypatch, tmp_path):
    def ctrl_c(out, secs=5):
        raise KeyboardInterrupt
    monkeypatch.setattr(rt, "countdown", ctrl_c)
    files, man = tree_and_manifest()

    def fake_git(repo, *args, check=True):
        if args[:1] == ("show",):
            return json.dumps(man)
        if args[:1] == ("ls-tree",):
            return "\n".join(files)
        return fake_git_for("b" * 40)(repo, *args, check=check)
    assert drive_local(monkeypatch, tmp_path, ["--unit"], tty=True, git=fake_git) == 130
    assert not (tmp_path / "cache").exists() and not (tmp_path / "wt").exists()



# ───────────────────────────── preflight (M5 Pro 2026-11-19: no Metal Toolchain → app build exit 65;
# no node → 9 Python FileNotFoundError failures). Fake which / xcrun: nothing is installed or probed for real.

class FakeRun:
    def __init__(self, rc):
        self.rc, self.calls = rc, []

    def __call__(self, cmd, **k):
        self.calls.append((cmd, k.get("env", {}).get("PATH", "")))
        r = FakeDone()
        r.returncode = self.rc
        return r


def fake_which(present, seen=None):
    def which(name, path=None):
        if seen is not None:
            seen.append(path)
        return f"/opt/homebrew/bin/{name}" if name in present else None
    return which


def test_preflight_names_each_missing_tool_against_the_lanes_that_need_it():
    seen = []
    run = FakeRun(rc=1)                                         # xcrun: "cannot execute tool 'metal'"
    m = rt.preflight({"app", "core", "python"}, {"PATH": "/usr/bin:/bin"}, which=fake_which({"ffmpeg", "ffprobe"}, seen),
                     run=run, find_python=lambda repos: (None, "no pytest"))
    assert m == {"app": ["Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)"],
                 "python": ["node (brew install node)",
                            "a Python with pytest (scripts/install_dev_tools.sh makes venv/)"]}
    assert run.calls[0][0] == ["xcrun", "metal", "--version"]
    assert run.calls[0][1].startswith("/opt/homebrew/bin:") and all(p.startswith("/opt/homebrew/bin:") for p in seen)


def test_preflight_all_present_is_empty_and_only_probes_what_the_lanes_need():
    run = FakeRun(rc=0)
    allp = fake_which({"ffmpeg", "ffprobe", "node"})
    assert rt.preflight({"app", "core", "python"}, {}, which=allp, run=run, find_python=lambda r: (["/p"], "/p")) == {}
    run = FakeRun(rc=1)
    assert rt.preflight({"core"}, {}, which=allp, run=run, find_python=lambda r: pytest.fail("probed")) == {}
    assert run.calls == []                                      # no app lane: no xcrun
    m = rt.preflight({"core"}, {}, which=fake_which(set()), run=run, find_python=lambda r: (["/p"], "/p"))
    assert m == {"core": ["ffmpeg (brew install ffmpeg)", "ffprobe (brew install ffmpeg)"]}


def test_preflight_survives_a_missing_xcrun():
    def boom(*a, **k):
        raise FileNotFoundError("xcrun")
    m = rt.preflight({"app"}, {}, which=fake_which({"ffmpeg", "ffprobe"}), run=boom)
    assert list(m) == ["app"]


def test_a_lane_missing_a_tool_is_not_run_setup_and_the_others_still_run(monkeypatch, tmp_path):
    ran = []

    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        ran.append(log_name)
        if lane is not None:
            lane.passed += 3
        return 0, 1.0
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    picks = [rt.Pick("core", "Core/Store", "unit", "x/ATests.swift", ("ATests",), 3),
             rt.Pick("python", "py/x", "unit", "tests/test_x.py", ("test_x.py",), 9)]
    a = rt.parse_args(["--unit", "--python"])
    a.stages_label = ["unit"]
    a.kinds = {"core", "python"}
    buf = io.StringIO()
    out = rt.Out(False, buf)
    lanes = rt.run_lanes(a, picks, tmp_path, tmp_path, out, tmp_path, "smoke",
                         missing={"python": ["node (brew install node)"]})
    assert ran == ["core-build.log", "core.log"]          # Core builds, then tests from the bundle; Python never starts
    py = [l for l in lanes if l.name == "python"][0]
    assert (py.word, py.setup, py.reason) == ("NOT RUN", ["node (brew install node)"], "setup: missing node (brew install node)")
    code = rt.summary(out, lanes, 1.0, None)
    text = buf.getvalue()
    assert code == 1 and "NOT READY: setup" in text and "[  FAILED  ]" not in text
    assert "python: setup: missing node (brew install node)" in text


def test_red_outranks_not_ready_and_setup_alone_is_not_ready():
    red = L("core", ran=True, passed=1, failed=1, rc=1)
    setup = rt.setup_lane("python", ["node (brew install node)"])
    assert rt.verdict([red, setup]) == (1, "RED")
    assert rt.verdict([L("core", ran=True, passed=3, rc=0), setup]) == (1, "NOT READY: setup")
    assert rt.verdict([setup]) == (1, "NOT READY: setup")


def test_when_every_lane_is_missing_a_tool_no_worktree_is_made(monkeypatch, tmp_path, capsys):
    files, man = tree_and_manifest()

    def fake_git(repo, *args, check=True):
        if args[:1] == ("show",):
            return json.dumps(man)
        if args[:1] == ("ls-tree",):
            return "\n".join(files)
        return fake_git_for("b" * 40)(repo, *args, check=check)
    monkeypatch.setattr(rt.socket, "gethostname", lambda: "RicksM5.local")
    code = drive_local(monkeypatch, tmp_path, ["--unit", "--yes"], git=fake_git,
                       preflight=lambda lanes, env, **k: {l: ["Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)"]
                                                          for l in lanes})
    assert code == 1
    text = capsys.readouterr()
    assert "RicksM5 is missing: Metal Toolchain" in text.out + text.err
    assert not (tmp_path / "cache").exists() and not (tmp_path / "wt").exists()


def test_the_missing_block_names_the_mac_and_the_install_commands():
    b = rt.missing_block("RicksM5", {"app": ["Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)"],
                                     "python": ["node (brew install node)"]})
    assert b.startswith("RicksM5 is missing: Metal Toolchain (xcodebuild -downloadComponent MetalToolchain), "
                        "node (brew install node)")
    assert "NOT RUN (setup): app, python" in b


def test_the_caller_reads_a_hosts_not_ready_as_setup_not_red(monkeypatch, tmp_path):
    host = rt.setup_lane("python", ["node (brew install node)"])
    buf = io.StringIO()
    host_rc = rt.summary(rt.Out(False, buf), [host], 1.0, None)
    assert rt.remote_word(buf.getvalue()) == "NOT READY: setup"
    code, calls = drive_remote(monkeypatch, tmp_path, ["--host", "m4", "--yes"], buf.getvalue(), host_rc)
    assert calls["corpus"] == 1 and code == 1                    # the corpus still runs; the verdict is NOT READY


def test_interrupt_summary_names_the_incomplete_lane_in_words():
    """Live run 2026-11-19 (Ultra, Ctrl-C 75 s into the app lane) printed "interrupted ()",
    "app: no test counted" after 174 tests ran, and "interrupted: interrupted"."""
    buf = io.StringIO()
    out = rt.Out(False, buf)
    app = rt.LaneResult("app", ran=True, rc=-2)   # the stopped xcodebuild's exit
    app.passed = 174
    lanes = [app]
    rt.mark_interrupted(out, lanes, KeyboardInterrupt())
    code = rt.summary(out, lanes, 75.0, None)
    text = buf.getvalue()
    assert code == 130
    assert "interrupted (Ctrl-C)" in text
    assert "()" not in text
    assert "no test counted" not in text
    assert "interrupted: interrupted" not in text
    assert "after 174 tests" in text


# ───────────────────────────── 2026-11-20: concurrent runs, the registry, --status, --filter
# Rick: "run_tests.sh blocks so I can't run MFO verbs and in another shell a specific unit test …
# we should minimize the lock … I cannot query the testbed runner about what is running."

# --filter grammar (gtest's --gtest_filter)

def test_filter_parses_positives_negatives_and_globs():
    f = rt.TestFilter.parse("Catalog*:MFOVerbsParallelTests.theCrowd*-CatalogSlowTests:*.testHuge*")
    assert f.pos == ["Catalog*", "MFOVerbsParallelTests.theCrowd*"]
    assert f.neg == ["CatalogSlowTests", "*.testHuge*"]
    assert f.wants("CatalogStoreTests", "testInsert")
    assert not f.wants("CatalogSlowTests", "testInsert")                 # a negative suite
    assert not f.wants("CatalogStoreTests", "testHugeImport")             # a negative test
    assert f.wants("MFOVerbsParallelTests", "theCrowdCoversEveryVerb")
    assert not f.wants("MFOVerbsParallelTests", "everyVerbAlone")
    assert not f.wants("ArchiveFixityTests", "testX")


def test_filter_suite_star_equals_the_suite_and_a_dotted_pattern_names_tests():
    for text in ("CatalogStoreTests", "CatalogStoreTests.*", "Catalog*.*"):
        f = rt.TestFilter.parse(text)
        assert f.whole("CatalogStoreTests") and f.wants("CatalogStoreTests", "anything"), text
    f = rt.TestFilter.parse("CatalogStoreTests.testInsert")
    assert not f.whole("CatalogStoreTests") and f.touches("CatalogStoreTests")
    assert f.wants("CatalogStoreTests", "testInsert") and not f.wants("CatalogStoreTests", "testInsertMany")
    assert rt.TestFilter.parse("S.f()").wants("S", "f")                      # Swift Testing's () is optional
    assert not rt.TestFilter.parse("catalog*").wants("CatalogStoreTests", "t")  # case-sensitive, like gtest


def test_filter_with_only_negatives_means_everything_else_and_empty_is_usage(capsys):
    f = rt.TestFilter.parse("-*Perf*")
    assert f.pos == ["*"] and f.wants("A", "b") and not f.wants("APerfTests", "b")
    with pytest.raises(rt.Usage):
        rt.TestFilter.parse("  ")
    with pytest.raises(SystemExit) as e:
        rt.parse_args(["--filter", ""])
    assert e.value.code == 2
    with pytest.raises(SystemExit) as e:
        rt.parse_args(["--full", "--filter", "X"])
    assert e.value.code == 2 and "--filter narrows a --smoke" in capsys.readouterr().err


def test_a_filter_picks_from_every_stage_and_never_asks_for_the_corpus():
    a = rt.parse_args(["--filter", "X*"])
    assert a.stages == rt.STAGES and a.kinds == {"app", "core", "python"}
    a = rt.parse_args(["--filter", "X*", "--unit"])
    assert a.stages == ["unit"]
    assert rt.parse_args(["--filter", "X*", "--python"]).kinds == {"python"}


# the source parsers (same rules as scripts/gauntlet/inventory.swift)

SWIFT_SRC = '''
import Testing
import XCTest

final class CatalogStoreTests: XCTestCase {
    func testInsert() throws {
        struct Boom: Error {}          // a helper type inside a test is not a suite
        func helper() {}
    }
    func testDelete() {}
    func notATest() {}
}

@Suite("VerifyAudio — persistence isolation")
struct VerifyAudioIsolationTests {
    @Test("never writes the real catalog") func neverWrites() {}
    @Test("each fixture decodes", arguments: ["a", "b"])
    func decodes(name: String) throws {}
    @Test(
        "multi-line attribute and labels",
        arguments: [1, 2], [3]
    )
    func pairs(_ a: Int,
               second b: Int) async throws {}
    // @Test func commentedOut() {}
    struct Nested {
        @Test func inner() {}
    }
}
'''


def test_swift_cases_credit_the_type_name_and_carry_swift_testing_identifiers():
    cases = rt.swift_cases(SWIFT_SRC)
    assert cases == [
        ("CatalogStoreTests", "testInsert", "testInsert"),
        ("CatalogStoreTests", "testDelete", "testDelete"),
        ("VerifyAudioIsolationTests", "neverWrites", "neverWrites()"),
        ("VerifyAudioIsolationTests", "decodes", "decodes(name:)"),          # parameterized: one id, all cases
        ("VerifyAudioIsolationTests", "pairs", "pairs(_:second:)"),
        ("Nested", "inner", "inner()"),
    ]


def test_python_cases_give_pytest_node_ids():
    src = textwrap.dedent('''
        import pytest

        def test_a():
            def test_nested_helper():
                pass

        class TestC:
            def test_b(self):
                pass

            @pytest.mark.parametrize("x", [1, 2])
            def test_c(self, x):
                pass

        @pytest.mark.parametrize("y", [1])
        def test_d(y):
            pass

        def helper():
            pass
    ''')
    assert rt.python_cases(src, "test_mod") == [
        ("test_mod", "test_a", "test_a"), ("test_mod", "test_b", "TestC::test_b"),
        ("test_mod", "test_c", "TestC::test_c"), ("test_mod", "test_d", "test_d")]


# the filter over a pool, and its mapping per lane

def filter_pool():
    A, C = "VideoScan/VideoScanTests/", "VideoScan/VideoScanCore/Tests/VideoScanCoreTests/"
    pool = [rt.Pick("app", "Catalog", "unit", A + "CatalogStoreTests.swift",
                    ("CatalogStoreTests", "Nested", "VerifyAudioIsolationTests"), 6),
            rt.Pick("app", "Other", "unit", A + "ZebraTests.swift", ("ZebraTests",), 3),
            rt.Pick("core", "Core/Store", "unit", C + "CoreStoreTests.swift", ("CoreStoreTests",), 2),
            rt.Pick("python", "py/run", "unit", "tests/test_mod.py", ("test_mod.py",), 4)]
    texts = {A + "CatalogStoreTests.swift": SWIFT_SRC,
             C + "CoreStoreTests.swift": "final class CoreStoreTests: XCTestCase {\n func testA() {}\n func testB() {}\n}\n",
             "tests/test_mod.py": "def test_a():\n    pass\n\nclass TestC:\n    def test_b(self):\n        pass\n"
                                  "    def test_c(self):\n        pass\n\ndef test_d():\n    pass\n"}
    return pool, texts


def run_filter(text):
    pool, texts = filter_pool()
    asked = []

    def read(paths):
        asked.extend(paths)
        return {p: texts[p] for p in paths}
    return rt.apply_filter(pool, rt.TestFilter.parse(text), read), asked


def test_whole_suites_need_no_source_and_keep_the_manifest_count():
    picks, asked = run_filter("Zebra*:CoreStoreTests")
    assert [(p.path.rsplit("/", 1)[-1], p.tests, p.cases) for p in picks] == [
        ("ZebraTests.swift", 3, ()), ("CoreStoreTests.swift", 2, ())]
    assert asked == []                                  # nothing to read: whole suites


def test_a_partial_file_runs_only_the_named_tests_and_suites_match_by_type_name():
    picks, asked = run_filter("VerifyAudioIsolationTests.decodes:CatalogStoreTests")
    assert asked == ["VideoScan/VideoScanTests/CatalogStoreTests.swift"]   # only the file it must split
    (p,) = picks
    assert p.suites == ("CatalogStoreTests", "VerifyAudioIsolationTests") and p.tests == 3
    assert p.cases == (("VerifyAudioIsolationTests", "decodes", "decodes(name:)"),)
    assert rt.app_selectors(picks) == ["CatalogStoreTests", "VerifyAudioIsolationTests/decodes(name:)"]
    # the display name is not the suite's name
    assert run_filter("VerifyAudio — persistence isolation")[0] == []
    assert run_filter("VerifyAudio*.*")[0][0].tests == 3


def test_negatives_split_a_suite_and_every_lane_maps_its_cases():
    picks, _ = run_filter("*-CoreStoreTests.testB:test_mod.test_c:CatalogStoreTests:Nested")
    by = {p.kind: p for p in picks}
    assert by["core"].cases == (("CoreStoreTests", "testA", "testA"),) and by["core"].tests == 1
    rx = re.compile(rt.core_filter(by["core"].suites, by["core"].cases))
    assert rx.search("VideoScanCoreTests.CoreStoreTests/testA")
    assert not rx.search("VideoScanCoreTests.CoreStoreTests/testB")
    assert not rx.search("VideoScanCoreTests.CoreStoreTests/testAB")
    assert rt.python_targets(picks) == ["tests/test_mod.py::test_a", "tests/test_mod.py::TestC::test_b",
                                        "tests/test_mod.py::test_d"]
    sel = rt.app_selectors(picks)
    assert "VerifyAudioIsolationTests" in sel and "ZebraTests" in sel and not any("Catalog" in s or "Nested" in s for s in sel)


def test_core_regex_for_swift_testing_identifiers_and_whole_suites_together():
    rx = re.compile(rt.core_filter(["Whole", "Split"], [("Split", "f", "f(x:)")]))
    assert rx.search("VideoScanCoreTests.Whole/anything()")
    assert rx.search("VideoScanCoreTests.Split/f(x:)")
    assert rx.search("VideoScanCoreTests.Outer/Split/f()")
    assert not rx.search("VideoScanCoreTests.Split/fg()")
    assert not rx.search("VideoScanCoreTests.Split/g()")


def test_a_filter_that_matches_nothing_is_refused_before_anything_is_built(monkeypatch, tmp_path, capsys):
    files, man = tree_and_manifest()

    def fake_git(repo, *args, check=True):
        if args[:1] == ("show",):
            return json.dumps(man)
        if args[:1] == ("ls-tree",):
            return "\n".join(files)
        return fake_git_for("b" * 40)(repo, *args, check=check)
    monkeypatch.setattr(rt, "cat_files", lambda repo, sha_, paths: {})
    assert drive_local(monkeypatch, tmp_path, ["--filter", "NoSuch*", "--yes"], git=fake_git) == 2
    assert "--filter 'NoSuch*' matches no test" in capsys.readouterr().err
    assert not (tmp_path / "cache").exists() and not (tmp_path / "wt").exists()
    # a filter that names only tests that cannot run here says so
    assert drive_local(monkeypatch, tmp_path, ["--filter", "ArchiveRealRunTests", "--yes"], git=fake_git) == 2
    err = capsys.readouterr().err
    assert "cannot run here" in err and "opt-in real run" in err


def test_list_with_a_filter_shows_the_matched_cases(monkeypatch, capsys):
    files, man = tree_and_manifest()
    man["assignments"][0]["tests"] = ["testA", "testB", "testC"]

    def fake_git(repo, *args, check=True):
        if args[:1] == ("show",):
            return json.dumps(man)
        if args[:1] == ("ls-tree",):
            return "\n".join(files)
        return fake_git_for("b" * 40)(repo, *args, check=check)
    src = "final class CatalogQueriesDecadeTests: XCTestCase {\n func testA() {}\n func testB() {}\n func testC() {}\n}\n"
    monkeypatch.setattr(rt, "git", fake_git)
    monkeypatch.setattr(rt, "cat_files", lambda repo, sha_, paths: {p: src for p in paths})
    assert rt.main(["--list", "--filter", "CatalogQueriesDecadeTests.testB:Zebra*"]) == 0
    o = capsys.readouterr().out
    assert "--filter 'CatalogQueriesDecadeTests.testB:Zebra*'" in o
    assert "CatalogQueriesDecadeTests.testB" in o and "testA" not in o
    assert "# total ~2 tests" in o


def test_a_filtered_lane_expects_the_filtered_count(monkeypatch, tmp_path):
    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        if lane is not None:
            lane.passed += 1
        return 0, 1.0
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    picks = [rt.Pick("core", "Core/Store", "unit", "x/ATests.swift", ("ATests",), 1, (("ATests", "testA", "testA"),))]
    a = rt.parse_args(["--filter", "ATests.testA"])
    a.kinds, a.stages_label = {"core"}, ["unit"]
    lanes = rt.run_lanes(a, picks, tmp_path, tmp_path, quiet_out(), tmp_path, "smoke")
    assert lanes[0].expected == 1 and lanes[0].word == "GREEN"


def test_cat_files_reads_each_path_at_the_commit(repo):
    out = rt.cat_files(repo, sha(repo), ["f.txt", "missing.txt"])
    assert out == {"f.txt": "1"}


def test_the_core_test_phase_runs_the_built_bundle_not_swift_test(tmp_path):
    cmd = rt.core_test_cmd(Path("/wt"), "(\\.|/)(A)/")           # a commit from before scripts/core_lane.py
    assert cmd[1:3] == [str(rt.SELF), "--core-exec"] and cmd[3].endswith("VideoScanCore/.build/debug")
    assert "swift" not in cmd[0] and "test" not in cmd
    # 2026-11-20: a checkout that has scripts/core_lane.py runs ITS two-phase lane on the built bundle
    # (the quiet-machine tests serial, the rest parallel) — the same engine as the nightly's Core lane.
    (tmp_path / "wt" / "scripts").mkdir(parents=True)
    (tmp_path / "wt" / "scripts" / "core_lane.py").write_text("")
    cmd = rt.core_test_cmd(tmp_path / "wt", "(\\.|/)(A)/")
    assert cmd[1:4] == ["-u", str(tmp_path / "wt" / "scripts" / "core_lane.py"), "run"]
    assert cmd[4:] == ["--products", str(tmp_path / "wt" / "VideoScan" / "VideoScanCore" / ".build" / "debug"),
                       "--filter", "(\\.|/)(A)/"]
    assert "swift" not in cmd[0] and "test" not in cmd and "--no-parallel" not in cmd
    assert rt.core_build_cmd(Path("/wt"))[:3] == ["swift", "build", "--build-tests"]
    p = subprocess.run([sys.executable, str(ROOT / "scripts" / "run_tests.py"), "--core-exec", str(tmp_path), "x"],
                       capture_output=True, text=True, timeout=60)
    assert p.returncode == 1 and "no built test bundle" in p.stdout


# slots: one worktree + DerivedData pair per commit, shared by runs at that commit

@pytest.fixture
def slots(monkeypatch, tmp_path, repo):
    monkeypatch.setattr(rt, "CACHE", tmp_path / "cache")
    monkeypatch.setattr(rt, "RUN_WT", tmp_path / "wt" / "run-all")
    monkeypatch.setattr(rt, "DD", tmp_path / "dd" / "videoscan-runall-dd")
    held = []
    yield held
    for s in held:
        s.release()


def take(held, repo, ref):
    s = rt.acquire_slot(repo, sha(repo, ref))
    held.append(s)
    return s


def test_runs_at_different_commits_use_different_slots_and_share_no_lock(slots, repo):
    a = take(slots, repo, "HEAD~1")
    b = take(slots, repo, "HEAD")                  # does not wait for, or refuse because of, a
    assert a.wt != b.wt and a.dd != b.dd
    assert sha(a.wt) == sha(repo, "HEAD~1") and sha(b.wt) == sha(repo, "HEAD")
    assert {a.wt.name, b.wt.name} <= {"run-all", "run-all-2", "run-all-3"}
    assert "videoscan-runall-dd" in {a.dd.name, b.dd.name}       # slot 1 keeps the old warm DerivedData


def test_runs_at_one_commit_share_its_slot(slots, repo):
    a = take(slots, repo, "HEAD")
    b = take(slots, repo, "HEAD")
    assert a.index == b.index and a.wt == b.wt


def test_a_slot_a_live_run_holds_is_never_moved_or_pruned(slots, repo, monkeypatch, tmp_path):
    monkeypatch.setattr(rt, "N_SLOTS", 2)
    live = take(slots, repo, "HEAD~1")             # a live run at HEAD~1 (held shared)
    other = take(slots, repo, "HEAD")
    other.release()                                # idle now, and the most recently used
    os.utime(str(rt.slot_dir() / f"{live.index}.used"), (1, 1))   # the live one looks least recently used
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "three", cwd=repo)
    t = take(slots, repo, "HEAD")                  # a third commit: one slot must move
    assert t.index == other.index, "the slot a live run holds was moved"
    assert sha(live.wt) == sha(repo, "HEAD~2")     # untouched
    with pytest.raises(rt.Busy, match="in use by live runs"):
        rt.acquire_slot(repo, sha(repo, "HEAD~1"))  # both held, at other commits: refused, nothing moved
    assert sha(live.wt) == sha(repo, "HEAD~2") and sha(t.wt) == sha(repo)


def test_an_old_run_tests_holding_the_whole_run_lock_keeps_slot_one(slots, repo, monkeypatch):
    old = rt.take_lock(rt.CACHE / "lock", "run_tests smoke sha=old (an older checkout)")
    try:
        s = take(slots, repo, "HEAD")
        assert s.index != 0 and not (rt.RUN_WT / ".git").exists()
        line = rt.slot_lines([], disk=False)[0]
        assert "in use by an older run_tests" in line and "sha=old" in line   # live 11-20: it said "idle"
    finally:
        os.close(old)


def test_a_dirty_slot_worktree_is_refused_never_touched(slots, repo, monkeypatch):
    monkeypatch.setattr(rt, "N_SLOTS", 1)          # the only slot (F7: with others free, the next is used)
    s = take(slots, repo, "HEAD")
    (s.wt / "f.txt").write_text("changed")
    with pytest.raises(rt.Refused, match="local changes"):
        rt.acquire_slot(repo, sha(repo))
    assert (s.wt / "f.txt").read_text() == "changed"


def test_a_second_run_at_the_same_commit_waits_only_for_the_build_then_tests(slots, repo, monkeypatch, tmp_path):
    s = take(slots, repo, "HEAD")
    head = sha(repo)
    # run 1 is building: it holds the slot's app build lock
    lock = rt.slot_dir() / f"{s.index}.build-app"
    fd = rt._lock_fd(lock)
    fcntl_mod = rt.fcntl
    fcntl_mod.flock(fd, fcntl_mod.LOCK_EX)
    Path(str(lock) + ".info").write_text(f"4242 {head} {time.time():.0f} app\n")
    streams = []

    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        streams.append(log_name)
        if lane is not None:
            lane.passed += 1
        return 0, 1.0
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    picks = [rt.Pick("app", "Catalog", "unit", "x/ATests.swift", ("ATests",), 1)]
    a = rt.parse_args(["--unit"])
    a.kinds, a.stages_label = {"app"}, ["unit"]
    buf = io.StringIO()
    result = {}
    import threading
    th = threading.Thread(target=lambda: result.update(lanes=rt.run_lanes(
        a, picks, s.wt, repo, rt.Out(False, buf), tmp_path, "smoke", slot=s, sha=head)))
    th.start()
    for _ in range(200):
        if "waiting for the build" in buf.getvalue():
            break
        time.sleep(0.02)
    assert f"waiting for the build of {head[:9]} (pid 4242, since " in buf.getvalue()
    assert streams == []                           # nothing ran while the build was going
    rt.mark_built(s, "app", head)                  # run 1's build succeeded …
    os.close(fd)                                   # … and it let go of the lock
    th.join(10)
    assert streams == ["app-test.log"], "the second run rebuilt instead of testing from the built products"
    assert "already built at" in buf.getvalue() and result["lanes"][0].word == "GREEN"


def test_a_slot_moved_to_another_commit_forgets_its_builds(slots, repo, monkeypatch):
    monkeypatch.setattr(rt, "N_SLOTS", 1)
    s = take(slots, repo, "HEAD~1")
    rt.mark_built(s, "app", sha(repo, "HEAD~1"))
    s.release()
    t = take(slots, repo, "HEAD")
    assert rt.built_at(t, "app") is None


def test_each_run_has_its_own_run_folder(monkeypatch, tmp_path):
    monkeypatch.setattr(rt, "CACHE", tmp_path)
    d = rt.new_run_dir("smoke")
    assert d.name.endswith(f"-smoke-{os.getpid()}") and d.is_dir()
    t = rt.app_test_cmd(Path("/wt"), ["S"], Path("/dd"), d / "app.xcresult")
    assert t[t.index("-resultBundlePath") + 1] == str(d / "app.xcresult") and "/dd" in t
    assert any(x.startswith("--basetemp=") for x in rt.pytest_cmd(["py"], ["t.py"], d / "pytest-tmp"))


# the run registry and --status

def dead_pid():
    p = subprocess.Popen(["/usr/bin/true"])
    p.wait()
    return p.pid


def test_the_registry_is_written_updated_and_removed(monkeypatch, tmp_path):
    monkeypatch.setattr(rt, "CACHE", tmp_path)
    live = rt.LiveRun({"argv": ["--filter", "X*"], "mode": "smoke", "filter": "X*", "sha": "a" * 40, "slot": "2",
                       "phase": "starting"})
    f = tmp_path / "live" / f"{os.getpid()}.json"
    assert json.loads(f.read_text())["filter"] == "X*"
    live.update(phase="app: testing", done=0, total=9)
    assert json.loads(f.read_text())["phase"] == "app: testing"
    live.update(done=5)                            # progress: at most a write a second
    live.last = 0.0
    live.update(done=6)
    assert json.loads(f.read_text())["done"] == 6
    (runs,) = rt.live_runs()
    assert runs["pid"] == os.getpid()
    live.close()
    assert not f.exists() and rt.live_runs() == []


def test_a_stale_registry_file_is_ignored_and_cleaned(monkeypatch, tmp_path):
    monkeypatch.setattr(rt, "CACHE", tmp_path)
    (tmp_path / "live").mkdir()
    stale = tmp_path / "live" / "99.json"
    stale.write_text(json.dumps({"pid": dead_pid(), "sha": "b" * 40}))
    (tmp_path / "live" / "junk.json").write_text("{not json")
    assert rt.live_runs() == []
    assert not stale.exists()


def test_status_lists_every_live_run_the_slots_and_the_m4_holder(monkeypatch, tmp_path, capsys):
    monkeypatch.setattr(rt, "CACHE", tmp_path / "cache")
    monkeypatch.setattr(rt, "RUN_WT", tmp_path / "wt" / "run-all")
    monkeypatch.setattr(rt, "DD", tmp_path / "dd")
    live = rt.LiveRun({"argv": [], "mode": "smoke", "filter": "MFOVerbs*", "sha": "c" * 40, "slot": "1",
                       "phase": "app: testing", "done": 3, "total": 5})
    now = time.time()
    st = {"state": "running", "lock": "suite sha=b42d38c38 since " + time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(now - 600))
          + " out=/x", "last": {"lane": "suite", "running": True},
          "testbed": {"lanes": [{"name": "suite", "seconds": 2797, "verdict": "GREEN"}]}}
    monkeypatch.setattr(rt, "m4_status_json", lambda repo, timeout=25: st)
    try:
        assert rt.main(["--status"]) == 0
    finally:
        live.close()
    o = capsys.readouterr().out
    assert "1 live run" in o
    assert f"pid {os.getpid()} · smoke --filter 'MFOVerbs*' · ccccccccc · slot 1 · app: testing 3/5" in o
    assert "slot 1  run-all" in o and "slot 3  run-all-3" in o
    assert "M4 testbed: busy — suite sha=b42d38c38" in o and "est. finish ~" in o and "46m37s in the last testbed" in o


def test_the_m4_estimate_comes_from_that_lanes_last_finished_run_else_its_planned_length():
    now = time.mktime(time.strptime("2026-11-20 18:00:00", "%Y-%m-%d %H:%M:%S"))
    st = {"state": "running", "lock": "testbed sha=abc since 2026-11-20 17:30:00 out=/x",
          "testbed": {"lane": "testbed", "running": False, "started": "2026-11-20 12:16:12", "ended": "2026-11-20 13:03:33"}}
    line = rt.m4_lock_line(st, now)
    assert "est. finish ~18:17" in line and "the last testbed run took 47m21s" in line
    st = {"state": "running", "lock": "corpus sha=abc since 2026-11-20 17:50:00 out=/x"}
    assert "est. finish ~18:35" in rt.m4_lock_line(st, now) and "planned at 45 min" in rt.m4_lock_line(st, now)
    st = {"state": "running", "lock": "corpus sha=abc since 2026-11-20 10:00:00 out=/x"}
    assert "past its usual length" in rt.m4_lock_line(st, now)
    assert rt.m4_lock_line({"state": "idle", "lock": None}, now) == "M4 testbed: idle"


def test_a_busy_refusal_prints_the_status_block_not_one_opaque_line(monkeypatch, tmp_path, capsys):
    files, man = tree_and_manifest()

    def fake_git(repo, *args, check=True):
        if args[:1] == ("show",):
            return json.dumps(man)
        if args[:1] == ("ls-tree",):
            return "\n".join(files)
        return fake_git_for("b" * 40)(repo, *args, check=check)
    monkeypatch.setattr(rt, "git", fake_git)
    monkeypatch.setattr(rt, "preflight", lambda lanes, env, **k: {})
    monkeypatch.setattr(rt, "local_host_key", lambda hostname=None: "ultra")
    monkeypatch.setattr(rt, "CACHE", tmp_path / "cache")
    monkeypatch.setattr(rt, "RUN_WT", tmp_path / "wt" / "run-all")

    def busy(base, sha_):
        raise rt.Busy("all 3 side worktrees are in use by live runs at other commits")
    monkeypatch.setattr(rt, "acquire_slot", busy)
    assert rt.main(["--unit", "--yes"]) == 3
    err = capsys.readouterr().err
    assert "busy — all 3 side worktrees are in use" in err
    assert "run_tests on " in err and "slot 1" in err
    assert not list((tmp_path / "cache" / "live").glob("*.json")), "the refused run left a registry entry"


def test_the_m4_lock_stays_and_its_busy_message_names_the_holder(monkeypatch, tmp_path, capsys):
    files, man = tree_and_manifest()

    def fake_git(repo, *args, check=True):
        if args[:1] == ("show",):
            return json.dumps(man)
        if args[:1] == ("ls-tree",):
            return "\n".join(files)
        return fake_git_for("b" * 40)(repo, *args, check=check)
    monkeypatch.setattr(rt, "git", fake_git)
    monkeypatch.setattr(rt, "preflight", lambda lanes, env, **k: {})
    monkeypatch.setattr(rt, "local_host_key", lambda hostname=None: "m4")
    monkeypatch.setattr(rt, "CACHE", tmp_path / "cache")
    monkeypatch.setattr(rt, "RUN_WT", tmp_path / "wt" / "run-all")
    monkeypatch.setattr(rt, "M4_LOCKDIR", tmp_path / "m4lock")
    monkeypatch.setattr(rt, "acquire_slot", lambda *a: pytest.fail("took a slot past the busy M4 lock"))
    real = time.strftime
    monkeypatch.setattr(rt.time, "strftime", lambda fmt, *a: "1200" if fmt == "%H%M" else real(fmt, *a))
    fd = rt.take_lock(tmp_path / "m4lock", "suite sha=b42d38c38 since 2026-11-20 17:55:40")
    try:
        assert rt.main(["--unit", "--yes"]) == 3
    finally:
        os.close(fd)
    err = capsys.readouterr().err
    assert "the M4 testbed lock is held: suite sha=b42d38c38 since 2026-11-20 17:55:40" in err
    assert "run_tests on " in err


def test_a_host_run_carries_the_filter_quoted_and_a_no_match_never_reaches_ssh(monkeypatch, tmp_path, capsys):
    _, run = rt.remote_commands("ricksm4.local", "a" * 40, "main", ["--host", "m4", "--filter", "Catalog*-*.testHuge*"])
    assert "--filter 'Catalog*-*.testHuge*'" in run[-1]
    monkeypatch.setattr(rt, "cat_files", lambda repo, sha_, paths: {})
    monkeypatch.setattr(rt.subprocess, "Popen", lambda *a, **k: pytest.fail("ssh started for a filter that matches nothing"))
    monkeypatch.setattr(rt.subprocess, "run", lambda *a, **k: pytest.fail("ssh copy started"))
    monkeypatch.setattr(rt, "git", fake_git_for("a" * 40))
    monkeypatch.setattr(rt, "local_host_key", lambda hostname=None: "ultra")
    assert rt.main(["--host", "m4", "--filter", "Nope*", "--yes"]) == 2
    assert "matches no test" in capsys.readouterr().err


# ───────────────────────────── review 2026-11-20 of 83763f8fa (F1–F9): each was RED on that commit

# ── F1  run_tests.py:729-731  core_exec returns the Swift Testing helper's 69 ("no test matched") as a failure:
#        any Core selection that is XCTest-only (33 Core files; every `--filter <XCTestCase class>`) is RED.
#        Measured on this Mac: swiftpm-testing-helper … --filter ZZZ/ → exit 69. `swift test` reads 69 as "none here".
def test_f1_core_xctest_only_selection_is_not_red_because_swift_testing_matched_nothing(monkeypatch, tmp_path):
    exe = tmp_path / "VideoScanCoreTests.xctest" / "Contents" / "MacOS" / "VideoScanCoreTests"
    exe.parent.mkdir(parents=True)
    exe.write_text("")
    tree = {"tests": [{"name": "VideoScanCoreTests.xctest", "tests": [
        {"name": "VideoScanCoreTests.OldXCTests", "tests": [{"name": "testA"}, {"name": "testB"}]}]}]}

    class P:
        returncode, stdout, stderr = 0, "/x/usr/bin/swift", ""

    def fake_run(cmd, **kw):
        if "swiftpm-xctest-helper" in str(cmd[0]):
            Path(cmd[2]).write_text(json.dumps(tree))
        return P()

    def fake_call(cmd, **kw):
        return 69 if "swiftpm-testing-helper" in str(cmd[0]) else 0     # xctest passed; Swift Testing: none matched
    monkeypatch.setattr(rt.subprocess, "run", fake_run)
    monkeypatch.setattr(rt.subprocess, "call", fake_call)
    assert rt.core_exec(str(tmp_path), r"(\.|/)(OldXCTests)/") == 0, \
        "XCTest ran and passed; Swift Testing's 'no test matched' (69) made the Core lane RED"


SWIFT_BRACE_IN_STRING = textwrap.dedent('''
    import Testing
    struct ASensorTests {
        func cut(_ rest: String) -> Bool { let end = "\\n    }\\n"; return rest.contains(end) }
        @Test func sensor() {}
        @Test func sensorTwo() {}
    }
    struct AModelTests {
        @Test func first() {}
    }
''')


# ── F2  run_tests.py:512-521 + 574-577  swift_cases counts braces inside string literals, so the tests after one
#        fall out of their suite; apply_filter then DROPS a suite the filter names whole and the manifest lists.
#        Real at this commit: `--filter '*SensorTests'` drops FamilyTreeNoteCorrectionSensorTests (2 tests;
#        FamilyTreeNoteCorrectionTests.swift:361 has "\n    }\n") and the run is GREEN on the other 138 suites.
def test_f2_a_suite_the_filter_names_whole_is_never_dropped_by_the_source_parser():
    pick = rt.Pick("app", "M", "unit", "x/ATests.swift", ("AModelTests", "ASensorTests"), 3)
    out = rt.apply_filter([pick], rt.TestFilter.parse("*SensorTests"), lambda ps: {"x/ATests.swift": SWIFT_BRACE_IN_STRING})
    assert out and "ASensorTests" in out[0].suites, "the suite the filter named (and the manifest lists) was dropped"
    assert rt.app_selectors(out) == ["ASensorTests"]


def test_f2b_the_real_file_at_this_commit():
    path = "VideoScan/VideoScanTests/FamilyTreeNoteCorrectionTests.swift"
    m = json.loads((ROOT / "scripts" / "gauntlet" / "manifest.json").read_text())
    e = next(x for x in m["assignments"] if x["path"] == path)
    pick = rt.Pick("app", "FamilyTree", e["stage"], path, tuple(sorted(e["suites"])), len(e["tests"]))
    out = rt.apply_filter([pick], rt.TestFilter.parse("*SensorTests"), lambda ps: {p: (ROOT / p).read_text() for p in ps})
    assert out and "FamilyTreeNoteCorrectionSensorTests" in out[0].suites


# ── F3  run_tests.py:582 + 634-635  the same misattribution puts the empty suite "" into a Pick; app_selectors
#        then emits `-only-testing:VideoScanTests/` (no suite). Real: `--filter=-ScanLocationVolumeTests`.
def test_f3_no_selector_is_ever_the_bare_target():
    pick = rt.Pick("app", "M", "unit", "x/ATests.swift", ("AModelTests", "ASensorTests"), 3)
    out = rt.apply_filter([pick], rt.TestFilter.parse("-AModelTests"), lambda ps: {"x/ATests.swift": SWIFT_BRACE_IN_STRING})
    sel = rt.app_selectors(out)
    assert all(s and not s.startswith("/") for s in sel), sel
    assert all(s for p in out for s in p.suites), [p.suites for p in out]


# ── F4  run_tests.py:1122-1133, 1684  the built-<kind> stamp is a bare sha in the cache folder: a checkout the
#        new code did not make (an OLDER run_tests on run-all — `--python` there never builds — or anyone's
#        `git checkout`) leaves it saying "built at X" while DerivedData holds another commit's products.
#        The next run at X prints "already built" and tests them: a GREEN for X on Y's binaries.
def test_f4_a_checkout_made_behind_the_stamp_invalidates_it(slots, repo, monkeypatch):
    monkeypatch.setattr(rt, "N_SLOTS", 1)
    x, y = sha(repo, "HEAD"), sha(repo, "HEAD~1")
    s = take(slots, repo, "HEAD")
    rt.mark_built(s, "app", x)                       # new run_tests built X in run-all
    s.release()
    slots.clear()
    git("checkout", "-q", "--detach", y, cwd=s.wt)   # an older run_tests (whole-run lock) moves run-all to Y, builds Y
    git("checkout", "-q", "--detach", x, cwd=s.wt)   # … and another moves it back to X without an app build (--python)
    t = take(slots, repo, "HEAD")
    assert rt.built_at(t, "app") != x, "the stamp says X is built; DerivedData holds Y's products"


# ── F5  run_tests.py:1649-1653, 2307  prune_runs keeps the newest 20 folders by name; with runs side by side a
#        long live run (a --full, an hour or more) is the OLDEST name: 20 quick --filter runs delete its logs, its
#        TMPDIR, its pytest basetemp and (over ssh) the .rc file _stream_in_gui waits for.
def test_f5_prune_never_deletes_a_live_runs_folder(monkeypatch, tmp_path):
    monkeypatch.setattr(rt, "CACHE", tmp_path)
    mine = tmp_path / "runs" / f"20261120-100000-full-{os.getpid()}"
    mine.mkdir(parents=True)
    live = rt.LiveRun({"argv": ["--full"], "mode": "full", "sha": "a" * 40, "slot": "1", "phase": "full"})
    try:
        for i in range(rt.KEEP_RUNS):
            (tmp_path / "runs" / f"20261120-11{i:02d}00-smoke-{90000 + i}").mkdir()
        rt.prune_runs(tmp_path / "runs", rt.KEEP_RUNS - 1)      # what the 21st run does on its way in
        assert mine.is_dir(), "a live run's folder was pruned under it"
    finally:
        live.close()


# ── F6  run_tests.py:1466-1468 (close_fds) + 1011-1020  the slot's shared lock lives in the runner only. kill -9
#        the runner (the bar's own case): its xcodebuild/swift child (own session) goes on building or testing
#        in the slot, the kernel has dropped the lock, and the next run may MOVE that slot under it.
def test_f6_a_killed_runners_child_still_holds_the_slot(tmp_path):
    lock = tmp_path / "0.lock"
    pidfile = tmp_path / "child.pid"
    code = textwrap.dedent(f"""
        import fcntl, importlib.util, io, sys
        from pathlib import Path
        spec = importlib.util.spec_from_file_location("run_tests", {str(ROOT / 'scripts' / 'run_tests.py')!r})
        rt = importlib.util.module_from_spec(spec); sys.modules["run_tests"] = rt; spec.loader.exec_module(rt)
        fd = rt._lock_fd(Path({str(lock)!r}))
        assert rt._flock(fd, fcntl.LOCK_SH)                      # what acquire_slot holds for the run's life
        r = rt.Runner(rt.Out(False, io.StringIO()), Path({str(tmp_path)!r}), dict(__import__("os").environ))
        r.stream(["/bin/sh", "-c", "echo $$ > {pidfile}; exec sleep 60"], "x.log", 120)
    """)
    runner = subprocess.Popen([sys.executable, "-c", code])
    try:
        for _ in range(200):
            if pidfile.exists() and pidfile.read_text().strip():
                break
            time.sleep(0.05)
        child = int(pidfile.read_text())
        runner.kill()                                            # kill -9: no stop(), no finally
        runner.wait()
        os.kill(child, 0)                                        # the build/test child is still alive …
        fd = rt._lock_fd(lock)
        try:
            moved = rt._flock(fd, fcntl.LOCK_EX)                 # … what a mover asks before `git checkout`
        finally:
            os.close(fd)
        assert not moved, "the slot can be moved to another commit while the killed run's child still works in it"
    finally:
        with __import__("contextlib").suppress(Exception):
            os.killpg(int(pidfile.read_text()), signal.SIGKILL)
        runner.kill()


# ── F7  run_tests.py:1066-1080  one dirty slot refuses every run at a new commit while it is the least recently
#        used — a failed move never touches .used, so it stays first — though the other slots are idle and clean.
def test_f7_a_dirty_idle_slot_does_not_take_the_clean_ones_down(slots, repo, monkeypatch):
    monkeypatch.setattr(rt, "N_SLOTS", 2)
    a = take(slots, repo, "HEAD")
    b = take(slots, repo, "HEAD~1")
    (a.wt / "f.txt").write_text("a test wrote into the checkout (GH #495)")
    a.release()
    b.release()
    slots.clear()
    os.utime(str(rt.slot_dir() / f"{a.index}.used"), (1, 1))     # the dirty one is the least recently used
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "three", cwd=repo)
    c = take(slots, repo, "HEAD")                                # b's slot is idle and clean
    assert c.index == b.index and (a.wt / "f.txt").read_text().startswith("a test wrote")


# ── F8  run_tests.py:1142-1153  "alive" = any process whose command line contains "run_tests": after a kill -9
#        and pid reuse, an editor on run_tests.py or `pytest tests/test_run_tests.py` is listed as a live run.
def test_f8_the_registry_does_not_take_an_unrelated_process_for_a_live_run(monkeypatch, tmp_path):
    monkeypatch.setattr(rt, "CACHE", tmp_path)
    other = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)", "notes-about-run_tests.txt"])
    try:
        (tmp_path / "live").mkdir()
        (tmp_path / "live" / f"{other.pid}.json").write_text(json.dumps({"pid": other.pid, "sha": "b" * 40, "slot": "2"}))
        assert rt.live_runs() == [], "a process that is not a run_tests run is reported as one"
    finally:
        other.kill()


# ── F9  run_tests.py:273-275 + 666  a --host run executes ONE shared file on the host and the Core lane re-reads
#        it later (`python3 <SELF> --core-exec`): a second caller's `cat >` (truncate in place; an older checkout's
#        copy has no --core-exec) changes the program under a live run → its Core lane exits 2, zero tests, RED.
def test_f9_the_host_copy_is_not_overwritten_in_place_under_a_live_run():
    copy, run = rt.remote_commands("ricksm4.local", "a" * 40, "main", ["--unit"])
    assert "cat > ~/Library/Caches/videoscan-runall/run_tests.py" not in copy[-1], \
        "the one shared host copy is truncated and rewritten in place (per-content name, or tmp + mv)"


def test_a_filtered_lane_short_by_one_is_red_and_says_ran_n_of_m(monkeypatch, tmp_path):
    # reviewer's note: a filter's plan is exact, so the under-half floor let 1 of 2 named tests pass GREEN
    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        if lane is not None:
            lane.passed += 1
        return 0, 1.0
    monkeypatch.setattr(rt.Runner, "stream", fake_stream)
    picks = [rt.Pick("core", "Core/Store", "unit", "x/ATests.swift", ("ATests",), 2,
                     (("ATests", "testA", "testA"), ("ATests", "testB", "testB")))]
    a = rt.parse_args(["--filter", "ATests.testA:ATests.testB"])
    a.kinds, a.stages_label = {"core"}, ["unit"]
    buf = io.StringIO()
    lanes = rt.run_lanes(a, picks, tmp_path, tmp_path, rt.Out(False, buf), tmp_path, "smoke")
    assert lanes[0].word == "RED" and "ran 1 of 2 the filter named (red)" in buf.getvalue()
    # skipped by their own trait still reported: not short
    assert L("core", ran=True, passed=1, skipped=1, rc=0, expected=2, exact=True).word == "GREEN"
    assert L("core", ran=True, passed=3, rc=0, expected=2, exact=True).word == "GREEN"     # parameterized: more is fine
    assert L("core", ran=True, passed=1, rc=0, expected=2).word == "GREEN"                 # the smoke keeps its half floor


def test_swift_code_only_blanks_strings_and_comments_keeping_lines():
    src = ('let a = "}"; let b = #"raw " } "#\n'
           'let c = """\n  { } \\"""\n  """\n'
           '/* { /* nested } */ } */ let d = 1 // }\n'
           'func f() { }\n')
    code = rt.swift_code_only(src)
    assert code.count("\n") == src.count("\n") and len(code) == len(src)
    assert code.count("{") == 1 and code.count("}") == 1 and "func f() { }" in code


def test_every_dirty_slot_refuses_with_each_reason_and_status_shows_it(slots, repo, monkeypatch):
    monkeypatch.setattr(rt, "N_SLOTS", 2)
    a = take(slots, repo, "HEAD")
    b = take(slots, repo, "HEAD~1")
    for s in (a, b):
        (s.wt / "f.txt").write_text("dirty")
        s.release()
    slots.clear()
    git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "three", cwd=repo)
    with pytest.raises(rt.Refused, match="(?s)no usable side worktree: slot 1: .*local changes.*slot 2: "):
        rt.acquire_slot(repo, sha(repo))
    assert all("REFUSED (skipped)" in line for line in rt.slot_lines([], disk=False))


# ── --config / --coverage (2026-11-22) ──────────────────────────────────────────────────────────

def test_config_defaults_debug_for_the_smoke_and_release_for_full_and_full_refuses_debug_and_coverage(capsys):
    assert rt.parse_args([]).config == "debug"
    assert rt.parse_args(["--config", "release"]).config == "release"
    assert rt.parse_args(["--full"]).config == "release"
    for bad, why in ((["--full", "--config", "debug"], "always Release"), (["--full", "--coverage"], "records coverage")):
        with pytest.raises(SystemExit) as e:
            rt.parse_args(bad)
        assert e.value.code == 2 and why in capsys.readouterr().err


def test_each_variant_builds_into_its_own_products_and_plain_debug_keeps_todays_paths(tmp_path):
    dd, wt = tmp_path / "dd", tmp_path / "wt"
    debug, rel, cov, relcov = rt.Variant(), rt.Variant("release"), rt.Variant("debug", True), rt.Variant("release", True)
    assert [v.dd(dd) for v in (debug, rel, cov, relcov)] == \
        [dd, Path(f"{dd}-release"), Path(f"{dd}-cov"), Path(f"{dd}-release-cov")]
    b = rt.app_build_cmd(wt, dd, relcov)
    assert b[b.index("-configuration") + 1] == "Release" and b[b.index("-derivedDataPath") + 1] == f"{dd}-release-cov"
    assert b[-2:] == ["-enableCodeCoverage", "YES"]
    assert "-enableCodeCoverage" not in rt.app_build_cmd(wt, dd)
    assert rt.app_build_cmd(wt, dd)[rt.app_build_cmd(wt, dd).index("-configuration") + 1] == "Debug"
    s = rt.app_shards_cmd(wt, tmp_path / "p.json", 4, tmp_path / "sh", dd, cov)
    assert s[s.index("--products") + 1] == f"{dd}-cov/Build/Products" and s[-1] == "--coverage"
    t = rt.app_test_cmd(wt, ["S"], dd, tmp_path / "a.xcresult", cov)
    assert "-enableCodeCoverage" in t
    # Core: release adds -c release + -enable-testing; coverage its own .build; plain unchanged
    assert rt.core_build_cmd(wt) == ["swift", "build", "--build-tests", "--package-path", str(rt.core_package(wt))]
    c = rt.core_build_cmd(wt, relcov)
    assert "--enable-code-coverage" in c and c[c.index("--scratch-path") + 1].endswith(".build/coverage")
    assert c[-4:] == ["-c", "release", "-Xswiftc", "-enable-testing"]
    assert rt.core_products(wt) == rt.core_package(wt) / ".build" / "debug"
    assert rt.core_products(wt, relcov) == rt.core_package(wt) / ".build" / "coverage" / "release"
    assert str(rt.core_products(wt, relcov)) in rt.core_test_cmd(wt, "x", relcov)


def test_a_variant_has_its_own_build_stamp_so_already_built_is_never_the_other_configuration(monkeypatch, tmp_path):
    kinds = []

    @contextlib.contextmanager
    def fake_lock(slot, kind, sha, out, live=None):
        kinds.append(kind)
        yield
    monkeypatch.setattr(rt, "build_lock", fake_lock)
    monkeypatch.setattr(rt.Runner, "stream", lambda self, *a, **k: (1, 0.0))   # the build fails: stop there
    picks = [rt.Pick("app", "App/X", "unit", "x/ATests.swift", ("ATests",), 3),
             rt.Pick("core", "Core/X", "unit", "x/BTests.swift", ("BTests",), 3)]
    for argv in ([], ["--config", "release"], ["--coverage"], ["--config", "release", "--coverage"]):
        a = rt.parse_args(argv + ["--unit"])
        a.kinds, a.stages_label = {"app", "core"}, ["unit"]
        rt.run_lanes(a, picks, tmp_path, tmp_path, quiet_out(), tmp_path, "smoke")
    assert kinds == ["app", "core", "app-release", "core-release", "app-cov", "core-cov",
                     "app-release-cov", "core-release-cov"]


def test_app_coverage_reports_the_union_and_its_html_and_the_summary_names_it(tmp_path):
    wt, run_dir = tmp_path / "wt", tmp_path / "run"
    (wt / "scripts").mkdir(parents=True)
    for n in ("0000", "0001"):
        (run_dir / "app-shards" / n / "shard.xcresult").mkdir(parents=True)
    # a fake xccov_union.py: records its argv, writes the report, prints the line
    (wt / "scripts" / "xccov_union.py").write_text(
        "import sys, json, pathlib\n"
        "a = sys.argv[1:]\n"
        "pathlib.Path(a[a.index('--html') + 1]).mkdir(parents=True, exist_ok=True)\n"
        "(pathlib.Path(a[a.index('--html') + 1]) / 'index.html').write_text('x')\n"
        "pathlib.Path(sys.argv[0]).with_name('argv.json').write_text(json.dumps(a))\n"
        "print('coverage-union: 41.250% (825/2000 distinct lines of VideoScan.app, logic only; union of 2 bundle(s))')\n")
    lane = rt.LaneResult("app", ran=True, passed=10, rc=0)
    buf = io.StringIO()
    rt.app_coverage(None, rt.Out(False, buf), wt, run_dir, lane)
    argv = json.loads((wt / "scripts" / "argv.json").read_text())
    assert sum(x.endswith("shard.xcresult") for x in argv) == 2 and "--logic" in argv
    assert lane.coverage == "app 41.250% (825/2000 lines, logic only)"
    assert lane.coverage_html == run_dir / "coverage" / "app" / "index.html"
    out = io.StringIO()
    rt.summary(rt.Out(False, out), [lane], 1.0, run_dir)
    assert "app 41.250%" in out.getvalue() and "open " + str(lane.coverage_html) in out.getvalue()
    assert "partial" in out.getvalue(), "a smoke's coverage must say it is partial"


def test_coverage_is_not_measured_when_nothing_ran_and_says_why(tmp_path):
    buf = io.StringIO()
    lane = rt.LaneResult("app", ran=True)
    rt.app_coverage(None, rt.Out(False, buf), tmp_path, tmp_path, lane)
    assert lane.coverage == "" and "not measured — no app test ran" in buf.getvalue()
    lane = rt.LaneResult("core", ran=True, passed=3)
    rt.core_coverage(None, rt.Out(False, buf), tmp_path, tmp_path, lane, rt.Variant("debug", True))
    assert lane.coverage == "" and "core: not measured — no profile was written" in buf.getvalue()
