"""scripts/run_tests.py — Rick's `run_tests.sh` front door (2026-11-19).

Pins: the smoke SELECTION is deterministic and comes from the manifest (no hand list); the
PARSER reads the line shapes our runners really print (XCTest, Swift Testing, xcodebuild's
parallel form, pytest -v) including failures and their first message; the VERDICT never
calls a zero-test lane or a lane that did not run green; --host handling; and the side
worktree refuses Rick's checkout, a main checkout, Xcode's DerivedData and a dirty tree.
No build and no host here: the live run is exercised by running the script."""
from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
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
    c = rt.corpus_cmd(Path("/r"), "abc123", 10)
    assert c[c.index("--ref") + 1] == "abc123"
    assert c[c.index("--limit") + 1] == "10"
    assert c[-1] == "--wait" and c[2:4] == ["run", "check"]
    assert "--limit" not in rt.corpus_cmd(Path("/r"), "abc123", None)


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
