"""scripts/xctest_shards.py — the app test lane as K concurrent test hosts on the strand runner.

Pins: the DEAL (balanced by recorded per-suite seconds, by test count the first time, deterministic,
a suite shared by two files reaches one host); the SERIAL TAIL (the table's suites run in one host,
alone, after the parallel shards, each with its reason; every name in the table is a real suite);
the FAN-IN (run_tests' own parser over each shard's log, summed; every failure with its shard's log
path); the EXACT COUNT (a shard that ran fewer tests than its files declare, or left a suite at zero
tests, is RED); and a shard that DIES or times out is RED, never a gap. xcodebuild and xcresulttool
are faked (tests/fixtures are not needed: the fakes are written here); the real hosts are exercised
by running the script (the measurements are in the commit message)."""
from __future__ import annotations

import importlib.util
import json
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
SCRIPT = ROOT / "scripts" / "xctest_shards.py"


def _load(name: str):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, ROOT / "scripts" / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


rt = _load("run_tests")
xs = _load("xctest_shards")
G = xs.Group

# A fake xcodebuild: runs the suites named by -only-testing from a scenario file
# ({suite: {"tests": [...], "fail": [...], "skip": [...], "xctest": bool, "sleep": s, "die": bool,
#  "silent": bool, "hang": bool}}), prints the lines the real hosts print, writes a "result bundle"
# (a folder with tests.json in xcresulttool's shape) and a start/end stamp per invocation.
FAKE_XCODEBUILD = textwrap.dedent('''\
    import json, os, plistlib, sys, time
    args = sys.argv[1:]
    scenario = json.load(open(os.environ["FAKE_SCENARIO"]))
    xr = args[args.index("-xctestrun") + 1]
    try:
        plan = plistlib.load(open(xr, "rb"))
        host_env = [t.get("EnvironmentVariables") or {} for c in plan.get("TestConfigurations", []) for t in c.get("TestTargets", [])]
    except Exception as e:
        host_env = "unreadable: %s" % e
    bundle = args[args.index("-resultBundlePath") + 1]
    if "-derivedDataPath" in args:                         # what the real one writes there: its Logs/Test
        os.makedirs(os.path.join(args[args.index("-derivedDataPath") + 1], "Logs", "Test"), exist_ok=True)
        open(os.path.join(args[args.index("-derivedDataPath") + 1], "Logs", "Test", "session.log"), "w").write("x" * 1000)
    sels = [a.split("/", 1)[1] for a in args if a.startswith("-only-testing:")]
    stamp = os.path.join(os.environ["FAKE_STAMPS"], "%d.json" % os.getpid())
    t0 = time.time()
    print("TEST_HOST_STARTED epoch=%.3f pid=%d" % (t0, os.getpid()), flush=True)
    nodes, bad = [], False
    for sel in sels:
        suite, _, only = sel.partition("/")
        sc = scenario.get(suite, {})
        if sc.get("hang"):
            time.sleep(120)
        time.sleep(sc.get("sleep", 0))
        if sc.get("silent"):
            continue
        for t in sc.get("tests", []):
            if only and t != only:
                continue
            if sc.get("die") and t == sc["tests"][-1]:
                sys.stdout.flush()
                os._exit(9)
            sec = 0.25
            if t in sc.get("fail", []):
                bad = True
                if sc.get("xctest"):
                    print("/src/%s.swift:12: error: -[VideoScanTests.%s %s] : XCTAssertEqual failed: (1) is not (2)" % (suite, suite, t))
                    print("Test Case '-[VideoScanTests.%s %s]' failed (%.3f seconds)." % (suite, t, sec))
                elif t in sc.get("glue", []):
                    print("2026-11-20 21:15:39.799 VideoScan[1:2] [logging] os_unix.c:52992: (2) open(/private/var/\\u2718 Test %s failed after %.3f seconds with 1 issue." % (t, sec))
                else:
                    print("\\u2718 Test %s recorded an issue at %s.swift:9:5: Expectation failed: a == b" % (t, suite))
                    print("\\u2718 Test %s failed after %.3f seconds with 1 issue." % (t, sec))
                res = "Failed"
            elif t in sc.get("skip", []):
                print("\\u279c Test %s skipped." % t)
                res = "Skipped"
            elif sc.get("xctest"):
                print("Test Case '-[VideoScanTests.%s %s]' passed (%.3f seconds)." % (suite, t, sec))
                res = "Passed"
            elif t in sc.get("glue", []):
                print("TEST_HOST_HEARTBEAT epoch=1795227328.334 elapsed=40.0s\\u2714 Test %s passed after %.3f seconds." % (t, sec))
                res = "Passed"
            else:
                print("\\u2714 Test %s passed after %.3f seconds." % (t, sec))
                res = "Passed"
            nodes.append({"nodeType": "Test Case", "name": t, "nodeIdentifier": t if suite.endswith(")") else suite + "/" + t,
                          "result": res, "durationInSeconds": sc.get("seconds", sec),
                          "children": [{"nodeType": "Arguments", "name": "arg %d" % i, "result": res,
                                        "durationInSeconds": sc.get("seconds", sec)} for i in range(sc.get("args", 0))]})
    for leak in [s for sel in sels for s in scenario.get(sel.partition("/")[0], {}).get("leak", [])]:
        os.makedirs(os.path.join(host_env[0]["TMPDIR"], leak), exist_ok=True)     # a test that never cleans up
    sys.stdout.flush()
    os.makedirs(bundle)
    json.dump({"testNodes": [{"nodeType": "Test Plan", "name": "P", "children": [
        {"nodeType": "Unit test bundle", "name": "VideoScanTests", "children": nodes}]}]},
        open(os.path.join(bundle, "tests.json"), "w"))
    json.dump({"start": t0, "end": time.time(), "suites": sels, "xctestrun": xr, "host_env": host_env}, open(stamp, "w"))
    sys.exit(65 if bad else 0)
''')
FAKE_XCRESULTTOOL = textwrap.dedent('''\
    import os, sys
    a = sys.argv[1:]
    assert a[:3] == ["get", "test-results", "tests"], a
    sys.stdout.write(open(os.path.join(a[a.index("--path") + 1], "tests.json")).read())
''')


def write_xctestrun(path: Path) -> None:
    """A minimal .xctestrun (format v2): one configuration, the unit-test target with an environment."""
    import plistlib
    with open(path, "wb") as f:
        plistlib.dump({"__xctestrun_metadata__": {"FormatVersion": 2},
                       "TestConfigurations": [{"Name": "Test Scheme Action", "TestTargets": [
                           {"BlueprintName": "VideoScanTests", "TestBundlePath": "__TESTROOT__/Debug/VideoScanTests.xctest",
                            "EnvironmentVariables": {"KEEP_ME": "1", "HOME": "/Users/someone"}}]}]}, f)


class Bench:
    def __init__(self, tmp: Path) -> None:
        self.tmp = tmp
        (tmp / "fake_xcodebuild.py").write_text(FAKE_XCODEBUILD)
        (tmp / "fake_xcresulttool.py").write_text(FAKE_XCRESULTTOOL)
        (tmp / "stamps").mkdir()
        write_xctestrun(tmp / "x.xctestrun")
        self.timings = tmp / "timings.json"
        self.run_dir = tmp / "run"

    def go(self, scenario: dict, groups: list, jobs: int = 2, extra=(), timeout: float = 60.0):
        (self.tmp / "scenario.json").write_text(json.dumps(scenario))
        (self.tmp / "plan.json").write_text(json.dumps({"groups": groups}))
        env = dict(os.environ, FAKE_SCENARIO=str(self.tmp / "scenario.json"), FAKE_STAMPS=str(self.tmp / "stamps"))
        p = subprocess.run([sys.executable, str(SCRIPT), "--xctestrun", str(self.tmp / "x.xctestrun"),
                            "--plan", str(self.tmp / "plan.json"), "--jobs", str(jobs), "--run-dir", str(self.run_dir),
                            "--timings", str(self.timings), "--timeout", str(timeout),
                            "--xcodebuild", f"{sys.executable} {self.tmp / 'fake_xcodebuild.py'}",
                            "--xcresulttool", f"{sys.executable} {self.tmp / 'fake_xcresulttool.py'}", *extra],
                           capture_output=True, text=True, timeout=180, env=env)
        return p.returncode, p.stdout + p.stderr

    def stamps(self):
        return [json.loads(f.read_text()) for f in sorted((self.tmp / "stamps").glob("*.json"))]


@pytest.fixture
def bench(tmp_path):
    return Bench(tmp_path)


def grp(name, tests, **kw):
    return dict({"name": name + "File", "selectors": [name], "tests": tests}, **kw)


def last(out: str) -> str:
    return out.strip().splitlines()[-1]


# ───────────────────────────── the deal

def test_the_deal_balances_by_recorded_seconds_and_is_deterministic():
    groups = [G(f"F{i}", [f"S{i}"], 10) for i in range(8)]
    timings = {f"suite:S{i}": float(s) for i, s in enumerate([40, 30, 20, 10, 10, 5, 3, 2])}
    shards = xs.deal(groups, 3, timings)
    loads = [sum(xs.weight(g, timings) for g in s) for s in shards]
    assert len(shards) == 3 and sorted(g.name for s in shards for g in s) == sorted(g.name for g in groups)
    assert max(loads) == 40.0, f"the longest suite alone is the bound: {loads}"
    assert max(loads) - min(loads) <= 3.0, f"unbalanced: {loads}"
    assert xs.deal(list(reversed(groups)), 3, timings) == shards, "the deal depends on the input order"


def test_the_first_deal_goes_by_declared_test_count_and_never_makes_an_empty_shard():
    groups = [G("Big", ["Big"], 300), G("Mid", ["Mid"], 100), G("Small1", ["Small1"], 100), G("Small2", ["Small2"], 100)]
    shards = xs.deal(groups, 2, {})
    assert [[g.name for g in s] for s in shards] == [["Big"], ["Mid", "Small1", "Small2"]]
    assert len(xs.deal(groups[:2], 15, {})) == 2, "more shards than groups: a host with nothing to run"
    assert xs.deal([], 4, {}) == []
    # a suite measured once outweighs the count guess: 2 tests that take 200 s are the heavy group
    slow = xs.deal(groups + [G("Slow", ["Slow"], 2)], 2, {"suite:Slow": 200.0})
    assert [g.name for g in slow[0]] == ["Slow"], slow


def test_a_suite_named_by_two_files_reaches_one_host_once():
    groups = [G("Main", ["Shared", "Other"], 5), G("Ext", ["Shared"], 3), G("Lone", ["Lone"], 1),
              G("ByCase", ["Other/testA"], 1)]
    merged = xs.merge_shared(groups)
    assert [g.name for g in merged] == ["Main+Ext+ByCase", "Lone"]
    assert merged[0].selectors == ["Other", "Shared"], "a suite taken whole keeps no Suite/test selector"
    assert merged[0].tests == 9
    shards, _ = xs.plan_shards(groups, 4, {}, tail=False)
    sel = [s for sh in shards for g in sh for s in g.selectors]
    assert sorted(sel) == ["Lone", "Other", "Shared"], f"a suite would run in two hosts: {sel}"


def test_the_manifest_gives_every_app_file_as_a_group_and_the_command_names_one_host():
    manifest = {"assignments": [
        {"kind": "xcode", "path": "VideoScan/VideoScanTests/ATests.swift", "stage": "unit", "suites": ["A1", "A2"], "tests": ["a", "b", "c"]},
        {"kind": "package", "path": "x/CoreTests.swift", "stage": "unit", "suites": ["C"], "tests": ["a"]},
        {"kind": "xcode", "path": "VideoScan/VideoScanTests/PerfTests.swift", "stage": "performance", "suites": ["P"], "tests": ["a"]}]}
    groups = xs.groups_from_manifest(manifest)
    assert [(g.name, g.selectors, g.tests, g.stage) for g in groups] == \
        [("ATests", ["A1", "A2"], 3, "unit"), ("PerfTests", ["P"], 1, "performance")]
    assert [g.name for g in xs.groups_from_manifest(manifest, {"A2"})] == ["ATests"]
    cmd = xs.shard_cmd(["xcodebuild"], Path("/p/x.xctestrun"), ["A1", "A2/f(x:)"], Path("/r/s.xcresult"))
    assert cmd[:4] == ["xcodebuild", "test-without-building", "-xctestrun", "/p/x.xctestrun"]
    assert cmd[cmd.index("-parallel-testing-enabled") + 1] == "NO", "in-process parallelism starves the main actor"
    assert cmd[cmd.index("-resultBundlePath") + 1] == "/r/s.xcresult"
    # RED 2026-11-24: with no -derivedDataPath, each sealed .xctestrun copy (a new path per run) made
    # ~/Library/Developer/Xcode/DerivedData/VideoScan-<hash> that nothing removed (729 on the Ultra, 25 GB).
    assert cmd[cmd.index("-derivedDataPath") + 1] == "/r/xcode-dd", "the shard's own DerivedData, beside its bundle"
    assert cmd[-2:] == ["-only-testing:VideoScanTests/A1", "-only-testing:VideoScanTests/A2/f(x:)"]


def test_the_newest_xctestrun_of_the_plan_is_found(tmp_path):
    with pytest.raises(FileNotFoundError):
        xs.find_xctestrun(tmp_path)
    old = tmp_path / "VideoScan_VideoScan-CI_macosx26.0-arm64.xctestrun"
    new = tmp_path / "VideoScan_VideoScan-CI_macosx27.0-arm64.xctestrun"
    (tmp_path / "VideoScan_VideoScan-UI_macosx27.0-arm64.xctestrun").write_text("")
    old.write_text("")
    new.write_text("")
    os.utime(old, (1, 1))
    assert xs.find_xctestrun(tmp_path, "VideoScan-CI") == new


# ───────────────────────────── the serial tail

def test_the_serial_tail_table_names_real_suites_each_with_a_reason():
    manifest = json.loads((ROOT / "scripts" / "gauntlet" / "manifest.json").read_text())
    known = {s for e in manifest["assignments"] if e.get("kind") == "xcode" for s in e.get("suites") or []}
    stale = sorted(set(xs.SERIAL_TAIL) - known)
    assert not stale, f"SERIAL_TAIL names suites the manifest does not list (renamed or removed?): {stale}"
    assert xs.SERIAL_TAIL, "the table is empty"
    for suite, why in list(xs.SERIAL_TAIL.items()) + list(xs.SERIAL_STAGES.items()):
        assert re.match(r"^[a-zA-Z][\w /]+: \S.{10,}", why), f"{suite}: a reason reads 'kind: why', got {why!r}"
    stages = {e.get("stage") for e in manifest["assignments"]}
    assert set(xs.SERIAL_STAGES) <= stages


def test_a_file_holding_a_tail_suite_goes_to_the_tail_whole_and_nothing_else_does():
    table = {"Snap": "real App Support: it snapshots the real tree"}
    a, b, c = G("A", ["Snap", "Beside"], 4), G("B", ["Plain"], 2), G("C", ["Perf"], 1, True, "performance")
    assert xs.serial_reason(a, table, {}) == table["Snap"]
    assert xs.serial_reason(b, table, {"performance": "timing budget: x"}) is None
    assert xs.serial_reason(c, table, {"performance": "timing budget: budgets"}) == "timing budget: budgets"


def test_the_tail_runs_in_one_host_alone_after_the_parallel_shards(bench, monkeypatch):
    scenario = {s: {"tests": ["a()", "b()"], "sleep": 0.6} for s in ("P1", "P2", "P3", "T1", "T2")}
    groups = [grp("P1", 2), grp("P2", 2), grp("P3", 2),
              grp("T1", 2, stage="performance"), grp("T2", 2, stage="stress")]
    code, out = bench.go(scenario, groups, jobs=3)
    assert code == 0, out
    assert "+ a serial tail of 2 suites in one host" in out
    assert "xctest-shards: serial tail: T1 — timing budget:" in out, out
    stamps = bench.stamps()
    tail = [s for s in stamps if "T1" in s["suites"]]
    par = [s for s in stamps if "T1" not in s["suites"]]
    assert len(tail) == 1 and sorted(tail[0]["suites"]) == ["T1", "T2"], "the tail is one host"
    assert len(par) == 3
    assert tail[0]["start"] >= max(s["end"] for s in par), "the tail started while a parallel host was running"
    assert min(s["end"] for s in par) > max(s["start"] for s in par), "the parallel hosts did not run at once"
    assert last(out).startswith("xctest-shards: GREEN: 10 passed, 0 failed, 0 skipped (ran 10 of 10)"), last(out)
    assert "serial tail" in last(out)
    # --no-serial-tail (the diagnostic that finds real collisions): everything is dealt
    bench.run_dir = bench.tmp / "run2"
    code, out = bench.go(scenario, groups, jobs=5, extra=["--no-serial-tail"])
    assert code == 0 and "serial tail" not in out, out


# ───────────────────────────── fan-in

def test_shards_run_at_once_counts_are_summed_and_suite_seconds_are_remembered(bench):
    scenario = {"A": {"tests": ["a()", "b()", "c()"], "sleep": 1.0, "seconds": 2.5},
                "B": {"tests": ["testOne", "testTwo"], "xctest": True, "sleep": 1.0},
                "C": {"tests": ["x()", "y()"], "skip": ["y()"], "sleep": 1.0}}
    t0 = time.monotonic()
    code, out = bench.go(scenario, [grp("A", 3), grp("B", 2), grp("C", 2)], jobs=3)
    wall = time.monotonic() - t0
    assert code == 0, out
    assert last(out).startswith("xctest-shards: GREEN: 6 passed, 0 failed, 1 skipped (ran 7 of 7)"), last(out)
    assert wall < 2.8, f"three 1 s hosts took {wall:.1f}s — they did not run at once"
    assert len(re.findall(r"^xctest-shards: shard-\d\d: .* — GREEN$", out, re.M)) == 3, out
    assert "host up after" in out
    known = json.loads(bench.timings.read_text())
    assert known["suite:A"] == 7.5 and known["suite:B"] == 0.5, known        # 3 × 2.5 s; 2 × 0.25 s
    # the next deal uses them: A (7.5 s) alone, B and C together
    code, out = bench.go(scenario, [grp("A", 3), grp("B", 2), grp("C", 2)], jobs=2, extra=["--dry-run"])
    assert code == 0 and re.search(r"shard-01: 1 suites, 3 tests, ~8s", out) and "shard-02: 2 suites, 4 tests" in out, out


def test_every_failure_is_listed_with_its_message_and_its_shards_log(bench):
    scenario = {"A": {"tests": ["a()", "b()"], "fail": ["b()"]},
                "B": {"tests": ["testOne", "testTwo"], "fail": ["testTwo"], "xctest": True},
                "C": {"tests": ["x()"]}}
    code, out = bench.go(scenario, [grp("A", 2), grp("B", 2), grp("C", 1)], jobs=3)
    assert code == 1, out
    assert last(out).startswith("xctest-shards: RED: 3 passed, 2 failed, 0 skipped (ran 5 of 5)"), last(out)
    assert "2 red shard(s)" in last(out)
    st = re.search(r"^xctest-shards: failed: b\(\) — Expectation failed: a == b · (shard-\d\d) log: (\S+)$", out, re.M)
    xc = re.search(r"^xctest-shards: failed: B\.testTwo — XCTAssertEqual failed: \(1\) is not \(2\) · (shard-\d\d) log: (\S+)$", out, re.M)
    assert st and xc, out
    assert st.group(2) != xc.group(2) and "failed after" in Path(st.group(2)).read_text()
    assert "Test Case '-[VideoScanTests.B testTwo]' failed" in Path(xc.group(2)).read_text()


def test_the_shards_own_lines_are_forwarded_whole_and_ours_are_never_read_as_tests(bench):
    scenario = {"A": {"tests": [f"a{i}()" for i in range(40)], "fail": ["a7()"]},
                "B": {"tests": [f"test{i}" for i in range(40)], "xctest": True}}
    code, out = bench.go(scenario, [grp("A", 40), grp("B", 40)], jobs=2, extra=["--stream"])
    assert code == 1, out
    parser, counts = rt.LineParser(), {"OK": 0, "FAILED": 0, "SKIPPED": 0}
    ours = rt.LineParser()
    for line in out.splitlines():
        for ev in parser.feed(line + "\n"):
            counts[ev.status] += 1
        if line.startswith(xs.PREFIX):
            assert ours.feed(line + "\n") == [], f"run_tests would count our own line as a test: {line}"
    assert counts == {"OK": 79, "FAILED": 1, "SKIPPED": 0}, f"the stream run_tests parses does not add up: {counts}"
    assert parser.failed_events["a7()"].message == "Expectation failed: a == b"
    assert not any(l.startswith("# strand ") for l in out.splitlines())


def test_the_log_reader_is_run_tests_own_parser_on_real_line_shapes(tmp_path):
    log = tmp_path / "strand.log"
    log.write_text("\n".join([
        "# strand shard-01: xcodebuild test-without-building",
        "TEST_HOST_STARTED epoch=%.3f pid=1" % (time.time() + 9.0),
        "Test Suite 'CatalogLockRealBackupTests' started at 2026-11-20 20:19:28.953.",
        "Test Case '-[VideoScanTests.CatalogLockRealBackupTests testA]' passed (0.001 seconds).",
        "/x/T.swift:5: error: -[VideoScanTests.CatalogLockRealBackupTests testB] : XCTAssertTrue failed",
        "Test Case '-[VideoScanTests.CatalogLockRealBackupTests testB]' failed (0.010 seconds).",
        "◇ Test \"a display name, with: punctuation\" started.",
        "✔ Test \"a display name, with: punctuation\" passed after 0.004 seconds.",
        "✔ Test params(x:) with 3 test cases passed after 0.012 seconds.",
        "➜ Test needsTheGPU() skipped: \"no GPU under a confined home\"",
        "✘ Test broken() recorded an issue at T.swift:9:5: Expectation failed: 1 == 2",
        "✘ Test broken() failed after 0.002 seconds with 1 issue.",
        "✔ Test run with 4 tests in 2 suites passed after 0.5 seconds.", ""]))
    strand = xs.strands.Strand("shard-01", ["x"])
    rep = xs.fan_in("shard-01", [G("F", ["CatalogLockRealBackupTests", "S"], 6)],
                    xs.strands.Result(strand, 65, 12.0, log), tmp_path / "missing.xcresult", ["false"])
    assert (rep.passed, rep.failed, rep.skipped) == (3, 2, 1), (rep.passed, rep.failed, rep.skipped)
    assert [e.name for e in rep.failures] == ["CatalogLockRealBackupTests.testB", "broken()"]
    assert rep.failures[1].message == "Expectation failed: 1 == 2"
    assert rep.problems == [] and rep.notes == ["no per-suite counts (its result bundle could not be read)"]
    assert rep.launch is not None and 8.0 < rep.launch < 10.0


def test_the_count_is_the_result_bundles_when_a_verdict_line_is_glued_into_a_log_line(bench):
    """Seen with 15 real hosts: `…open(/private/var/✔ Test "x" passed after 0.204 seconds.` — the parser
    anchors at the line start and misses it. The host's own record (the result bundle) has the test."""
    scenario = {"A": {"tests": ["a()", "b()", "c()"], "glue": ["b()"]},
                "B": {"tests": ["x()", "y()"], "fail": ["y()"], "glue": ["y()"]}}
    code, out = bench.go(scenario, [grp("A", 3), grp("B", 2)], jobs=2)
    assert code == 1, out
    assert re.search(r"shard-01: 3 passed, 0 failed, 0 skipped \(ran 3 of 3\) .* — GREEN · note: 1 verdict line\(s\) "
                     r"garbled in the log; counts are the result bundle's$", out, re.M), out
    assert re.search(r"shard-02: 1 passed, 1 failed, 0 skipped \(ran 2 of 2\) .* — RED · note: 1 verdict line", out), out
    assert re.search(r"failed: B\.y\(\) — its verdict line is garbled in the log — see the result bundle · shard-02 log: \S+", out), out
    assert "no failed test" not in out, "exit 65 with a failed test in the bundle is a test failure, not a dead host"
    assert last(out).startswith("xctest-shards: RED: 4 passed, 1 failed, 0 skipped (ran 5 of 5)"), last(out)
    # run_tests takes the fan-in's verdict for its lane (its own stream parse missed the two glued lines)
    lane = rt.LaneResult("app", ran=True, passed=3, failed=0, skipped=0, rc=1, expected=5)
    rt.adopt_shard_verdict(lane, [l[len(xs.PREFIX):] for l in out.splitlines() if l.startswith(xs.PREFIX)])
    assert (lane.passed, lane.failed, lane.skipped) == (4, 1, 0)
    assert [e.name for e in lane.failures] == ["B.y()"] and "garbled" in lane.failures[0].message
    untouched = rt.LaneResult("app", ran=True, passed=3)
    rt.adopt_shard_verdict(untouched, ["shard-01: 3 passed, 0 failed, 0 skipped (ran 3 of 3) in 1.0s — GREEN"])
    assert untouched.passed == 3, "without a verdict line the stream's own count stands"


def test_a_parameterized_tests_seconds_are_the_sum_of_its_arguments(bench):
    """The bundle gives a parameterized test ONE argument's seconds on its own node and each argument's
    on a child (real, 2026-11-20: PictureFaultMatrixTests/fault(_:) says 11.3 s, its 20 arguments
    226 s). Dealt by the node's number, the shard holding it ran 431 s beside fourteen at ~200 s."""
    scenario = {"Matrix": {"tests": ["fault(_:)", "healthy()"], "seconds": 10.0, "args": 20},
                "Plain": {"tests": ["a()"], "seconds": 3.0}}
    code, out = bench.go(scenario, [grp("Matrix", 2), grp("Plain", 1)], jobs=2)
    assert code == 0, out
    assert last(out).startswith("xctest-shards: GREEN: 3 passed, 0 failed, 0 skipped (ran 3 of 3)"), \
        "an argument is not a test: the count is the test's"
    known = json.loads(bench.timings.read_text())
    assert known["suite:Matrix"] == 400.0 and known["suite:Plain"] == 3.0, known


# ───────────────────────────── exact counts; a dying shard

def test_a_shard_that_ran_fewer_tests_than_declared_is_red_with_n_of_m(bench):
    scenario = {"A": {"tests": ["a()", "b()"]}, "B": {"tests": ["x()"]}}
    code, out = bench.go(scenario, [grp("A", 5), grp("B", 1)], jobs=2)
    assert code == 1, out
    assert re.search(r"shard-01: 2 passed, 0 failed, 0 skipped \(ran 2 of 5\) .* — RED · ran 2 of 5 tests · "
                     r"short: AFile ran 2 of 5 · log: \S+strand\.log", out), out
    assert last(out).startswith("xctest-shards: RED: 3 passed, 0 failed, 0 skipped (ran 3 of 6)"), last(out)
    # more than declared is fine (a declaration is a floor: parameterized cases, inherited tests)
    bench.run_dir = bench.tmp / "run2"
    code, out = bench.go(scenario, [grp("A", 1), grp("B", 1)], jobs=2)
    assert code == 0 and "(ran 3 of 2)" in last(out), out


def test_a_suite_that_silently_ran_zero_tests_is_red_even_when_the_shards_count_adds_up(bench):
    # Loud has more tests than declared; Quiet runs none. The shard's total (4 of 4) hides it; the
    # per-suite reading of the result bundle does not.
    scenario = {"Loud": {"tests": ["a()", "b()", "c()", "d()"]}, "Quiet": {"tests": ["x()", "y()"], "silent": True}}
    code, out = bench.go(scenario, [{"name": "OneFile", "selectors": ["Loud", "Quiet"], "tests": 4}], jobs=2)
    assert code == 1, out
    assert "(ran 4 of 4)" in out and "— RED · 1 suite(s) ran zero tests: Quiet" in out, out
    # a count that is not exact (run_tests: a whole suite the source parse saw no test in) is no floor,
    # but a suite at zero is still red
    bench.run_dir = bench.tmp / "run2"
    code, out = bench.go(scenario, [{"name": "OneFile", "selectors": ["Loud", "Quiet"], "tests": 9, "exact": False}], jobs=2)
    assert code == 1 and "ran 4 of 0" in out and "ran zero tests: Quiet" in out and "short:" not in out, out


def test_a_shard_that_dies_is_red_and_the_others_still_count(bench):
    scenario = {"A": {"tests": ["a()", "b()", "c()"], "die": True}, "B": {"tests": ["x()", "y()"]}}
    code, out = bench.go(scenario, [grp("A", 3), grp("B", 2)], jobs=2)
    assert code == 1, out
    assert re.search(r"shard-01: 2 passed, 0 failed, 0 skipped \(ran 2 of 3\) .* — RED · xcodebuild exit 9 with no "
                     r"failed test .* · ran 2 of 3 tests · note: no per-suite counts .* · log: \S+", out), out
    assert re.search(r"shard-02: 2 passed, 0 failed, 0 skipped \(ran 2 of 2\) .* — GREEN$", out, re.M), out
    assert last(out).startswith("xctest-shards: RED: 4 passed, 0 failed, 0 skipped (ran 4 of 5)"), last(out)
    assert "1 red shard(s): shard-01" in last(out)


def test_a_shard_past_its_timeout_is_stopped_and_red(bench):
    scenario = {"A": {"tests": ["a()"], "hang": True}, "B": {"tests": ["x()"]}}
    t0 = time.monotonic()
    code, out = bench.go(scenario, [grp("A", 1), grp("B", 1)], jobs=2, timeout=2.0)
    assert code == 1 and time.monotonic() - t0 < 60, out
    assert re.search(r"shard-01: 0 passed.* — RED · TIMEOUT after 2s", out), out
    assert last(out).startswith("xctest-shards: RED: 1 passed, 0 failed, 0 skipped (ran 1 of 2)"), last(out)


def test_a_run_where_no_test_ran_is_red_and_usage_errors_exit_2(bench, tmp_path):
    code, out = bench.go({"A": {"tests": [], "silent": True}}, [{"name": "F", "selectors": ["A"], "tests": 0, "exact": False}])
    assert code == 1 and "RED" in last(out), out
    p = subprocess.run([sys.executable, str(SCRIPT), "--xctestrun", str(bench.tmp / "x.xctestrun"), "--jobs", "0", "--all"], capture_output=True, text=True)
    assert p.returncode == 2 and "--jobs must be at least 1" in p.stderr
    p = subprocess.run([sys.executable, str(SCRIPT), "--xctestrun", "x"], capture_output=True, text=True)
    assert p.returncode == 2 and "name what to run" in p.stderr
    p = subprocess.run([sys.executable, str(SCRIPT), "--products", str(tmp_path), "--all"], capture_output=True, text=True)
    assert p.returncode == 2 and "build-for-testing first" in p.stderr


def test_the_whole_manifest_deals_into_k_shards_with_every_suite_exactly_once():
    manifest = json.loads((ROOT / "scripts" / "gauntlet" / "manifest.json").read_text())
    t0 = time.monotonic()
    groups = xs.groups_from_manifest(manifest, root=ROOT)
    shards, held = xs.plan_shards(groups, 15, {})
    assert time.monotonic() - t0 < 10.0, "reading and dealing the whole manifest is slow"
    assert len(shards) == 15
    everything = [g for sh in shards for g in sh] + [g for g, _ in held]
    dealt = [s for g in everything for s in g.selectors]
    listed = {s for e in manifest["assignments"] if e.get("kind") == "xcode" for s in e.get("suites") or []}
    assert len(dealt) == len(set(dealt)), "a suite is dealt to two hosts"
    assert {s for s in dealt if not s.endswith(")")} == {s for s in listed if xs.real_selector(s)}, \
        "a suite of the manifest is not dealt"
    assert not ({"and", "filter", "rules"} & set(dealt)), "a word from a @Suite display name is dealt as a suite"
    loads = [sum(xs.weight(g, {}) for g in sh) for sh in shards]
    assert max(loads) / min(loads) < 1.05, f"15 shards of the whole suite are unbalanced: {loads}"
    assert all(r for _, r in held)
    # The counts are TRUE floors (the serial host on 2026-11-20 ran exactly these: 14,244 of the
    # manifest's 14,248 names — four are file-scope helpers called test…).
    by = {g.name: g for g in everything}
    declared = sum(len(e.get("tests") or []) for e in manifest["assignments"] if e.get("kind") == "xcode")
    helpers = declared - sum(g.tests for g in everything)
    assert 0 <= helpers <= 12, f"{helpers} declared names are not tests — a new file-scope `func test…` helper?"
    if "MediaStreamResolverTests" in by:
        src = (ROOT / by["MediaStreamResolverTests"].path).read_text()
        n = len(re.findall(r"^private func test\w+\(", src, re.M))
        listed_n = next(len(e["tests"]) for e in manifest["assignments"] if e["path"] == by["MediaStreamResolverTests"].path)
        assert by["MediaStreamResolverTests"].tests == listed_n - n
    if "FamilySearchPullTests" in by:
        g = by["FamilySearchPullTests"]
        assert g.suites == [] and len(g.loose) == g.tests >= 40, "the file-scope tests are not named one by one"
    assert "TestHelpers" not in by, "a file with no test is dealt"


def test_a_count_is_trued_up_from_the_source_helpers_come_off_file_scope_tests_are_named():
    text = textwrap.dedent('''\
        import Testing
        private func testURL(_ s: String) -> URL { URL(string: s)! }
        func testConfig(cap: Int = 2) -> Int { cap }
        @Test func looseOne() { #expect(true) }
        @Test("with a name", arguments: [1, 2]) func looseTwo(_ n: Int, label x: String = "") {}
        @Suite("a class and a filter") struct RealTests {
            @Test func inside() {}
            func testLooksLikeXCTestButIsInAType() {}
        }
        ''')
    g = xs.Group("F", ["RealTests"], 6, True, "unit", "F.swift")
    whole = xs.true_up(g, text, add_loose=True)
    assert whole.selectors == ["RealTests", "looseOne()", "looseTwo(_:label:)"] and whole.tests == 4
    assert whole.suites == ["RealTests"] and whole.loose == ["looseOne()", "looseTwo(_:label:)"]
    same = xs.true_up(g, text, add_loose=False)                # run_tests' picks: what the single host is given
    assert same.selectors == ["RealTests"] and same.tests == 2
    picked = xs.Group("F", ["RealTests/inside()"], 1, True, "unit", "F.swift")
    assert xs.true_up(picked, text, add_loose=True) == picked, "a pick by case is the picker's count"
    # the cheap pre-check that decides which files are parsed at all
    assert xs.FILE_SCOPE_TEST_FUNC.search(text) and not xs.FILE_SCOPE_TEST_FUNC.search("struct T {\n    func testA() {}\n}\n")
    # words the inventory took for suites out of a display name are not selectors
    plan = {"groups": [{"name": "F", "selectors": ["RealTests", "and", "filter"], "tests": 2}]}
    assert xs.groups_from_plan(plan)[0].selectors == ["RealTests"]
    assert [xs.real_selector(x) for x in ("A", "and", "f()", "A/testX", "")] == [True, False, True, True, False]


def test_a_file_scope_test_that_did_not_run_is_short_not_silent(bench):
    scenario = {"looseOne()": {"tests": ["looseOne()"]}, "looseTwo()": {"tests": ["looseTwo()"], "silent": True},
                "S": {"tests": ["a()"]}}
    code, out = bench.go(scenario, [{"name": "LooseFile", "selectors": ["looseOne()", "looseTwo()"], "tests": 2},
                                    {"name": "SFile", "selectors": ["S"], "tests": 1}], jobs=2)
    assert code == 1 and "short: LooseFile ran 1 of 2" in out, out


def test_a_green_shards_result_bundle_is_removed_and_a_red_shards_is_kept(bench):
    scenario = {"A": {"tests": ["a()"]}, "B": {"tests": ["b()"], "fail": ["b()"]}}
    code, out = bench.go(scenario, [grp("A", 1), grp("B", 1)], jobs=2)
    assert code == 1, out
    kept = sorted(p.parent.name for p in bench.run_dir.glob("*/shard.xcresult"))
    assert len(kept) == 1, f"result bundles kept: {kept}"
    red = re.search(r"failed: b\(\).* log: (\S+)", out).group(1)
    assert Path(red).parent.name == kept[0], "the kept bundle is not the red shard's"
    bench.run_dir = bench.tmp / "run2"
    bench.go(scenario, [grp("A", 1), grp("B", 1)], jobs=2, extra=["--keep-results"])
    assert len(list(bench.run_dir.glob("*/shard.xcresult"))) == 2


def test_no_shard_leaves_its_xcode_derived_data_behind(bench):
    # RED 2026-11-24: the shard's DerivedData (xcodebuild's Logs/Test) is regenerable; it goes once the
    # shard is read, green or red, kept bundles or not.
    scenario = {"A": {"tests": ["a()"]}, "B": {"tests": ["b()"], "fail": ["b()"]}}
    for extra in ([], ["--keep-results"]):
        bench.run_dir = bench.tmp / ("run-dd" + "".join(extra))
        bench.go(scenario, [grp("A", 1), grp("B", 1)], jobs=2, extra=extra)
        assert len(list(bench.run_dir.glob("*/strand.log"))) == 2, "the shards did not run"
        assert list(bench.run_dir.glob("*/xcode-dd")) == [], extra


# ───────────────────────────── run_tests' app lane

def app_picks():
    return [rt.Pick("app", "Catalog", "unit", "VideoScan/VideoScanTests/ATests.swift", ("A1", "A2"), 5),
            rt.Pick("app", "Catalog", "regression", "VideoScan/VideoScanTests/BTests.swift", ("B",), 2,
                    (("B", "f", "f(x:)"), ("B", "testG", "testG")))]


def lanes_with(monkeypatch, tmp_path, argv, wt, stream):
    monkeypatch.setattr(rt.Runner, "stream", stream)
    a = rt.parse_args(argv)
    a.kinds, a.stages_label = {"app"}, ["unit"]
    import io
    buf = io.StringIO()
    lanes = rt.run_lanes(a, app_picks(), wt, tmp_path, rt.Out(False, buf), tmp_path, "smoke")
    return lanes, buf.getvalue()


def test_run_tests_app_lane_runs_as_shards_by_default_and_as_one_host_with_jobs_1(monkeypatch, tmp_path):
    wt = tmp_path / "wt"
    (wt / "scripts").mkdir(parents=True)
    (wt / "scripts" / "xctest_shards.py").write_text("")
    seen = []

    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        seen.append((cmd, log_name, gui))
        if lane is not None:
            lane.passed += 7
        return 0, 1.0
    lanes, _ = lanes_with(monkeypatch, tmp_path, ["--jobs", "6"], wt, fake_stream)
    cmd = seen[-1][0]
    assert cmd[1] == str(wt / "scripts" / "xctest_shards.py") and seen[-1][1:] == ("app-test.log", True)
    assert cmd[cmd.index("--jobs") + 1] == "6" and "--stream" in cmd
    assert cmd[cmd.index("--products") + 1].endswith("/Build/Products")
    assert cmd[cmd.index("--run-dir") + 1] == str(tmp_path / "app-shards")
    plan = json.loads(Path(cmd[cmd.index("--plan") + 1]).read_text())
    assert plan == {"groups": [
        {"name": "ATests", "selectors": ["A1", "A2"], "tests": 5, "exact": True, "stage": "unit",
         "path": "VideoScan/VideoScanTests/ATests.swift"},
        {"name": "BTests", "selectors": ["B/f(x:)", "B/testG"], "tests": 2, "exact": True, "stage": "regression",
         "path": "VideoScan/VideoScanTests/BTests.swift"}]}
    assert lanes[0].word == "GREEN" and lanes[0].expected == 7
    # no --jobs: half the cores
    lanes_with(monkeypatch, tmp_path, [], wt, fake_stream)
    cmd = seen[-1][0]
    if (os.cpu_count() or 2) >= 4:
        assert cmd[cmd.index("--jobs") + 1] == str((os.cpu_count() or 2) // 2)
    # --jobs 1: the single host, as before — in a sealed home (scripts/sealed_home.py run, 2026-11-23)
    single = [sys.executable, str(ROOT / "scripts" / "sealed_home.py"), "run", "--", "xcodebuild", "test-without-building"]
    lanes_with(monkeypatch, tmp_path, ["--jobs", "1"], wt, fake_stream)
    cmd = seen[-1][0]
    assert cmd[:6] == single and "-only-testing:VideoScanTests/A1" in cmd
    # a commit whose worktree has no xctest_shards.py (an older ref): the single host
    lanes_with(monkeypatch, tmp_path, ["--jobs", "6"], tmp_path / "old-wt", fake_stream)
    assert seen[-1][0][:6] == single
    with pytest.raises(SystemExit):
        rt.parse_args(["--jobs", "0"])


def test_run_tests_shows_the_shard_lines_and_a_red_shard_is_the_lanes_reason(monkeypatch, tmp_path):
    wt = tmp_path / "wt"
    (wt / "scripts").mkdir(parents=True)
    (wt / "scripts" / "xctest_shards.py").write_text("")

    def fake_stream(self, cmd, log_name, budget, cwd=None, parser=None, on_line=None, lane=None, gui=False):
        if lane is None:
            return 0, 0.1                                          # the build
        for raw in ["xctest-shards: 3 suites, ~7 tests → 2 test hosts at once (jobs 2) · logs /r\n",
                    "✔ Test a() passed after 0.001 seconds.\n",
                    "xctest-shards: shard-01: 4 passed, 0 failed, 0 skipped (ran 4 of 5) in 3.0s — RED · "
                    "xcodebuild exit 9 with no failing test line (a crash, a dead test host or an xcodebuild error) · "
                    "ran 4 of 5 tests · log: /r/0000/strand.log\n",
                    "xctest-shards: shard-02: 2 passed, 0 failed, 0 skipped (ran 2 of 2) in 2.0s — GREEN\n",
                    "xctest-shards: RED: 6 passed, 0 failed, 0 skipped (ran 6 of 7) in 3.1s — 2 hosts at once · 1 red shard(s): shard-01\n"]:
            if on_line is not None:
                on_line(raw)
        if lane is not None:
            lane.passed += 6
        return 1, 3.1
    lanes, shown = lanes_with(monkeypatch, tmp_path, ["--jobs", "2"], wt, fake_stream)
    assert lanes[0].word == "RED", "a shard died and the lane is green"
    assert "shard-01: 4 passed" in lanes[0].reason and "exit 9" in lanes[0].reason, lanes[0].reason
    assert "2 test hosts at once" in shown and "shard-02: 2 passed" in shown and "/r/0000/strand.log" in shown
    assert rt.verdict(lanes) == (1, "RED")


def test_run_tests_end_to_end_through_the_real_shard_script_with_a_fake_xcodebuild(monkeypatch, tmp_path):
    """The real Runner.stream, the real xctest_shards.py child, a fake xcodebuild: the lane's counts
    are the parsed stream's, and a failing test in one shard makes the lane RED with its name."""
    wt = tmp_path / "wt"
    (wt / "scripts" / "gauntlet").mkdir(parents=True)
    for name in ("xctest_shards.py", "testbed_strands.py", "run_tests.py", "sealed_home.py", "catalog_db.py"):
        (wt / "scripts" / name).write_text((ROOT / "scripts" / name).read_text())
    b = Bench(tmp_path)
    (tmp_path / "scenario.json").write_text(json.dumps({
        "A1": {"tests": ["a()", "b()", "c()"]}, "A2": {"tests": ["testX", "testY"], "xctest": True},
        "B": {"tests": ["f(x:)", "testG"], "fail": ["testG"]}}))
    monkeypatch.setenv("FAKE_SCENARIO", str(tmp_path / "scenario.json"))
    monkeypatch.setenv("FAKE_STAMPS", str(tmp_path / "stamps"))
    # Under ssh, Runner sends a gui lane through a launchd job whose plist keeps only PATH/HOME/USER/
    # LANG/TMPDIR, so FAKE_SCENARIO would never reach the fake xcodebuild (2026-11-22: this test was red
    # on every run over ssh — the fleet's normal way in). This test is about the shard stream, not ssh.
    monkeypatch.delenv("SSH_CONNECTION", raising=False)
    monkeypatch.delenv("SSH_TTY", raising=False)
    real = rt.app_shards_cmd

    def with_fakes(wt_, plan, jobs, shard_dir, dd=None, v=rt.DEBUG):
        write_xctestrun(tmp_path / "x.xctestrun")
        cmd = real(wt_, plan, jobs, shard_dir, dd, v)
        i = cmd.index("--products")
        cmd[i:i + 2] = ["--xctestrun", str(tmp_path / "x.xctestrun")]
        return cmd + ["--timings", str(b.timings), "--xcodebuild", f"{sys.executable} {tmp_path / 'fake_xcodebuild.py'}",
                      "--xcresulttool", f"{sys.executable} {tmp_path / 'fake_xcresulttool.py'}"]
    monkeypatch.setattr(rt, "app_shards_cmd", with_fakes)
    monkeypatch.setattr(rt, "app_build_cmd", lambda wt_, dd=None, v=rt.DEBUG: ["/usr/bin/true"])
    a = rt.parse_args(["--jobs", "2"])
    a.kinds, a.stages_label = {"app"}, ["unit"]
    import io
    buf = io.StringIO()
    run_dir = tmp_path / "rundir"
    run_dir.mkdir()
    lanes = rt.run_lanes(a, app_picks(), wt, tmp_path, rt.Out(False, buf), run_dir, "smoke")
    lane, shown = lanes[0], buf.getvalue()
    assert (lane.passed, lane.failed, lane.skipped) == (6, 1, 0), shown
    assert lane.word == "RED" and [e.name for e in lane.failures] == ["testG"], shown
    assert "2 test hosts at once" in shown and "— RED" in shown
    assert (run_dir / "app-shards" / "0000" / "strand.log").exists() and (run_dir / "app-test.log").exists()


def test_sigterm_stops_every_test_host_and_the_run_says_it_is_incomplete(bench):
    """run_tests stops its lane by TERM to the child's process group; the shards are in groups of their
    own, so the child must stop them itself — a test host left running holds a slot's products."""
    import signal
    scenario = {s: {"tests": ["a()"], "hang": True} for s in ("A", "B", "C")}
    (bench.tmp / "scenario.json").write_text(json.dumps(scenario))
    (bench.tmp / "plan.json").write_text(json.dumps({"groups": [grp("A", 1), grp("B", 1), grp("C", 1)]}))
    env = dict(os.environ, FAKE_SCENARIO=str(bench.tmp / "scenario.json"), FAKE_STAMPS=str(bench.tmp / "stamps"))
    p = subprocess.Popen([sys.executable, str(SCRIPT), "--xctestrun", str(bench.tmp / "x.xctestrun"), "--plan", str(bench.tmp / "plan.json"),
                          "--jobs", "3", "--run-dir", str(bench.run_dir), "--timings", str(bench.timings),
                          "--xcodebuild", f"{sys.executable} {bench.tmp / 'fake_xcodebuild.py'}"],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, start_new_session=True)
    pids, deadline = [], time.monotonic() + 30
    while time.monotonic() < deadline and len(pids) < 3:
        time.sleep(0.1)
        pids = [int(m.group(1)) for log in bench.run_dir.glob("*/strand.log")
                for m in [re.search(r"TEST_HOST_STARTED epoch=\S+ pid=(\d+)", log.read_text())] if m]
    assert len(pids) == 3, "the three hosts never started"
    os.kill(p.pid, signal.SIGTERM)
    out, _ = p.communicate(timeout=40)
    assert p.returncode == 130, out
    assert "RED: interrupted" in out, out
    for pid in pids:
        with pytest.raises(ProcessLookupError):
            os.kill(pid, 0)

# R1 — scripts/testbed_strands.py:165-167 (+ xctest_shards.py:638)
def test_sigterm_during_the_serial_tail_stops_its_test_host_too(bench):
    scenario = {"T": {"tests": ["a()"], "hang": True}}
    (bench.tmp / "scenario.json").write_text(json.dumps(scenario))
    (bench.tmp / "plan.json").write_text(json.dumps({"groups": [grp("T", 1, stage="performance")]}))
    env = dict(os.environ, FAKE_SCENARIO=str(bench.tmp / "scenario.json"), FAKE_STAMPS=str(bench.tmp / "stamps"))
    p = subprocess.Popen([sys.executable, str(SCRIPT), "--xctestrun", str(bench.tmp / "x.xctestrun"), "--plan", str(bench.tmp / "plan.json"),
                          "--jobs", "3", "--run-dir", str(bench.run_dir), "--timings", str(bench.timings),
                          "--xcodebuild", f"{sys.executable} {bench.tmp / 'fake_xcodebuild.py'}"],
                         stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, env=env, start_new_session=True)
    pids, deadline = [], time.monotonic() + 30
    while time.monotonic() < deadline and not pids:
        time.sleep(0.1)
        pids = [int(m.group(1)) for log in bench.run_dir.glob("*/strand.log")
                for m in [re.search(r"TEST_HOST_STARTED epoch=\S+ pid=(\d+)", log.read_text())] if m]
    assert pids, "the serial-tail host never started"
    os.kill(p.pid, signal.SIGTERM)
    out, _ = p.communicate(timeout=40)
    try:
        assert p.returncode == 130 and "every shard's process group was stopped" in out, out
        with pytest.raises(ProcessLookupError):      # RED: the tail's host is still running, orphaned
            os.kill(pids[0], 0)
    finally:
        for pid in pids:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass


# R2 — scripts/xctest_shards.py:486-508 (the zero-test-suite guard is a NOTE when the bundle cannot be read)
def test_a_suite_at_zero_tests_is_red_even_when_the_result_bundle_cannot_be_read(bench):
    scenario = {"Loud": {"tests": ["a()", "b()", "c()", "d()"]}, "Quiet": {"tests": ["x()", "y()"], "silent": True}}
    code, out = bench.go(scenario, [{"name": "OneFile", "selectors": ["Loud", "Quiet"], "tests": 4}], jobs=2,
                         extra=["--xcresulttool", "/usr/bin/false"])
    assert code == 1 and "GREEN" not in last(out), out      # RED: exit 0, "GREEN: 4 passed … (ran 4 of 4)"


# R3 — scripts/xctest_shards.py:514-515 (`0 < ran_group(g)`: a file of file-scope tests that ran NONE is not "short")
def test_a_file_whose_file_scope_tests_all_did_not_run_is_red(bench):
    scenario = {"looseOne()": {"tests": ["looseOne()"], "silent": True}, "looseTwo()": {"tests": ["looseTwo()"], "silent": True},
                "S": {"tests": ["a()", "b()", "c()"]}}           # S runs more than declared (a floor)
    code, out = bench.go(scenario, [{"name": "LooseFile", "selectors": ["looseOne()", "looseTwo()"], "tests": 2},
                                    {"name": "SFile", "selectors": ["S"], "tests": 1}], jobs=1)
    assert code == 1 and "LooseFile" in out, out               # RED: "GREEN: 3 passed (ran 3 of 3)"


# R4 — scripts/xctest_shards.py:212 and :238 (a group left with no selector is dropped without a word)
def test_a_file_whose_only_suite_name_is_not_uppercamelcase_is_not_dropped_silently(bench):
    assert xs.groups_from_manifest({"assignments": [
        {"kind": "xcode", "path": "VideoScan/VideoScanTests/lower.swift", "stage": "unit",
         "suites": ["lowerSuite"], "tests": ["a", "b", "c"]}]}) != [], "3 declared tests vanished from the deal"


def test_a_plan_group_whose_selectors_are_all_rejected_is_red_not_dropped(bench):
    scenario = {"A": {"tests": ["a()"]}, "lowerSuite": {"tests": ["x()", "y()", "z()"]}}
    code, out = bench.go(scenario, [grp("A", 1), grp("lowerSuite", 3)], jobs=2)
    assert "lowerSuite" in out and (code == 1 or "4 passed" in last(out)), out   # RED: "GREEN: 1 passed (ran 1 of 1)"


# R5 — scripts/testbed_strands.py:175-181 (TERM-all first, but then one FULL grace period per strand)
def test_stop_is_one_grace_period_even_when_the_strands_ignore_term(tmp_path):
    import threading
    ts = xs.strands
    code = "import signal,time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN); print('up', flush=True); time.sleep(120)"
    work = [ts.Strand(name=f"s{i}", cmd=[sys.executable, "-c", code]) for i in range(3)]
    runner = ts.Runner(tmp_path / "run", jobs=3, timings_path=tmp_path / "t.json")
    th = threading.Thread(target=lambda: runner.run(work), daemon=True)
    th.start()
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and sum("up" in l.read_text() for l in (tmp_path / "run").glob("*/strand.log")) < 3:
        time.sleep(0.05)
    t0 = time.monotonic()
    runner.stop()
    took = time.monotonic() - t0
    th.join(10)
    assert took < ts.TERM_GRACE_S + 5.0, f"3 strands that ignore TERM took {took:.0f}s to stop: one grace period EACH"


# R6 — scripts/xctest_shards.py:253-254 (merge_shared keys on g.suites only: a file-scope test named in two files)
def test_a_file_scope_test_named_by_two_files_reaches_one_host_once():
    shards, _ = xs.plan_shards([G("One", ["smoke()"], 1), G("Two", ["smoke()"], 1)], 4, {}, tail=False)
    sel = [s for sh in shards for g in sh for s in g.selectors]
    assert len(sel) == len(set(sel)), f"-only-testing:VideoScanTests/smoke() goes to two hosts: {sel}"


# R7 — scripts/xctest_shards.py:664-669 (a RED shard's partial seconds are remembered as the suite's weight)
def test_a_suite_that_came_up_short_does_not_record_its_seconds(bench):
    code, out = bench.go({"A": {"tests": ["a()", "b()"]}}, [grp("A", 50)], jobs=1)
    assert code == 1 and "ran 2 of 50" in out, out
    known = json.loads(bench.timings.read_text()) if bench.timings.exists() else {}
    assert "suite:A" not in known, f"2 of 50 tests ran and the next deal weighs the suite at {known['suite:A']}s"


# ───────────────────────────── a file heavier than a shard's share; the stages of --all

def test_a_file_heavier_than_a_shards_share_is_dealt_suite_by_suite_only_when_the_split_is_exact(tmp_path):
    src = "\n".join(["import Testing",
                     "@Suite struct HeavyTests {\n @Test func healthy() {}\n @Test func table() {}\n}",
                     "@Suite struct HeavyPartATests {\n @Test(arguments: [1, 2]) func partA(_ n: Int) {}\n}",
                     "@Suite struct HeavyPartBTests {\n @Test(arguments: [3, 4]) func partB(_ n: Int) {}\n}", ""])
    (tmp_path / "HeavyTests.swift").write_text(src)
    heavy = G("HeavyTests", ["HeavyPartATests", "HeavyPartBTests", "HeavyTests"], 4, True, "integration", "HeavyTests.swift")
    light = [G(f"L{i}", [f"L{i}"], 10) for i in range(6)]
    timings = {"suite:HeavyTests": 14.0, "suite:HeavyPartATests": 110.0, "suite:HeavyPartBTests": 110.0,
               **{f"suite:L{i}": 20.0 for i in range(6)}}
    shards, _ = xs.plan_shards([heavy] + light, 3, timings, tail=False, root=tmp_path)
    loads = sorted(round(sum(xs.weight(g, timings) for g in sh)) for sh in shards)
    assert loads == [110, 120, 124], f"the 234 s file was not spread: {loads}"
    parts = {g.name: (g.selectors, g.tests) for sh in shards for g in sh if g.name.startswith("HeavyTests")}
    assert parts == {"HeavyTests:HeavyTests": (["HeavyTests"], 2), "HeavyTests:HeavyPartATests": (["HeavyPartATests"], 1),
                     "HeavyTests:HeavyPartBTests": (["HeavyPartBTests"], 1)}, parts
    # without the source, or when the per-suite counts do not add up to the file's, the file stays whole
    whole, _ = xs.plan_shards([heavy] + light, 3, timings, tail=False)
    assert max(sum(xs.weight(g, timings) for g in sh) for sh in whole) == 234.0
    off = G("HeavyTests", heavy.selectors, 5, True, "integration", "HeavyTests.swift")
    kept, _ = xs.plan_shards([off] + light, 3, timings, tail=False, root=tmp_path)
    assert any(g.name == "HeavyTests" for sh in kept for g in sh), "an inexact split was dealt"
    # a file under the share is never read (a path that does not exist is fine)
    xs.plan_shards([G("Small", ["A", "B"], 2, True, "", "missing.swift")] + light, 2, timings, tail=False, root=tmp_path)


def test_the_picture_fault_matrix_is_four_slices_that_can_go_to_four_hosts():
    """It was one parameterized test of 226 s that set the wall time of the whole sharded lane."""
    manifest = json.loads((ROOT / "scripts" / "gauntlet" / "manifest.json").read_text())
    [g] = [g for g in xs.groups_from_manifest(manifest, root=ROOT) if g.name == "PictureFaultMatrixTests"]
    assert len(g.suites) == 5 and g.tests == 7
    timings = {f"suite:{s}": 56.0 for s in g.suites}
    parts = xs.split_heavy([g] + [G(f"L{i}", [f"L{i}"], 1) for i in range(20)], 15, timings, ROOT)
    assert sorted(p.tests for p in parts if p.name.startswith("PictureFaultMatrixTests:")) == [1, 1, 1, 1, 3]


def test_all_leaves_the_performance_and_stress_stages_out_unless_asked(tmp_path):
    manifest = {"test_plan": "P", "assignments": [
        {"kind": "xcode", "path": "T/UTests.swift", "stage": "unit", "suites": ["U"], "tests": ["a"]},
        {"kind": "xcode", "path": "T/HTests.swift", "stage": "hallie", "suites": ["H"], "tests": ["a"]},
        {"kind": "xcode", "path": "T/PTests.swift", "stage": "performance", "suites": ["P"], "tests": ["a"]},
        {"kind": "xcode", "path": "T/STests.swift", "stage": "stress", "suites": ["S"], "tests": ["a"]}]}
    (tmp_path / "m.json").write_text(json.dumps(manifest))

    def dry(*extra):
        p = subprocess.run([sys.executable, str(SCRIPT), "--xctestrun", "x", "--manifest", str(tmp_path / "m.json"),
                            "--root", str(tmp_path), "--timings", str(tmp_path / "t.json"), "--jobs", "4", "--dry-run", *extra],
                           capture_output=True, text=True)
        return p.returncode, p.stdout + p.stderr
    code, out = dry("--all")
    assert code == 0 and len(re.findall(r"shard-\d\d:", out)) == 2 and "serial tail" not in out, out
    code, out = dry("--all", "--stages", "all")
    assert code == 0 and "serial tail: P — timing budget" in out and "serial tail: S — timing budget" in out, out
    code, out = dry("--all", "--stages", "performance")
    assert code == 0 and "shard-" not in out and "serial tail: P" in out, out
    code, out = dry("--stages", "unit", "U")
    assert code == 2 and "--stages goes with --all" in out, out


# ───────────────────────────────────────────── the nightly's client: --summary and --coverage (2026-11-21)

def summary_of(bench, scenario, groups, jobs=2, extra=(), timeout=60.0):
    path = bench.tmp / "summary.json"
    code, out = bench.go(scenario, groups, jobs=jobs, extra=("--summary", str(path), *extra), timeout=timeout)
    return code, out, json.loads(path.read_text())


def test_the_summary_is_the_run_as_data_counts_shards_and_the_tail(bench):
    scenario = {"A": {"tests": ["a()", "b()"], "skip": ["b()"]}, "B": {"tests": ["x()"]}, "T": {"tests": ["t()"]}}
    # T's file is in a serial stage, so it runs in the tail
    code, out, d = summary_of(bench, scenario, [grp("A", 2), grp("B", 1), dict(grp("T", 1), stage="performance")])
    assert code == 0, out
    assert (d["version"], d["verdict"], d["jobs"]) == (xs.NIGHTLY_SUMMARY_VERSION, "GREEN", 2)
    assert (d["passed"], d["failed"], d["skipped"], d["expected"]) == (3, 0, 1, 4)
    assert d["counts_from"] == "bundles" and d["expected_failures"] == 0 and d["failures"] == []
    assert d["planned_shards"] == len(d["shards"]) == 3, "a reader checks the summary against the run with this"
    assert [s["name"] for s in d["shards"]] == ["shard-01", "shard-02", "serial-tail"]
    tail = d["shards"][-1]
    assert tail["serial"] and "timing budget" in tail["serial"] and tail["passed"] == 1
    for i, s in enumerate(d["shards"]):
        assert s["green"] and s["codes"] == [] and s["bundle_read"] and not s["timed_out"] and s["rc"] == 0
        assert s["log"] == str(bench.run_dir / f"{i:04d}" / "strand.log")
        assert s["bundle"] == str(bench.run_dir / f"{i:04d}" / "shard.xcresult")
    # the verdict line is still the last line; the summary adds nothing to stdout
    assert last(out).startswith("xctest-shards: GREEN: 3 passed, 0 failed, 1 skipped (ran 4 of 4)"), last(out)


def test_the_summary_names_each_failed_test_once_also_one_whose_line_is_glued(bench):
    scenario = {"A": {"tests": ["a()", "b()", "c()"], "fail": ["a()", "c()"], "glue": ["c()"]},
                "X": {"tests": ["testOld"], "fail": ["testOld"], "xctest": True}}
    code, out, d = summary_of(bench, scenario, [grp("A", 3), grp("X", 1)])
    assert code == 1 and d["verdict"] == "RED" and d["failed"] == 3, out
    assert sorted((f["id"], f["name"]) for f in d["failures"]) == [("A/a()", "a()"), ("A/c()", "c()"), ("X/testOld", "testOld")]
    assert {f["shard"] for f in d["failures"]} == {"shard-01", "shard-02"}
    assert all(s["codes"] == [] and not s["green"] for s in d["shards"]), d["shards"]   # red on tests alone: no code


def test_the_summary_codes_say_how_a_shard_was_red_beyond_its_tests(bench):
    # died: exit 9 with no failed test, one test short, and no bundle → mixed counts, no known-issue number
    scenario = {"A": {"tests": ["a()", "b()", "c()"], "die": True}, "B": {"tests": ["x()", "y()"]}}
    code, out, d = summary_of(bench, scenario, [grp("A", 3), grp("B", 2)])
    assert code == 1, out
    a, b = d["shards"]
    assert a["codes"] == ["short", "died"] and a["rc"] == 9 and not a["bundle_read"] and not a["green"]
    assert b["codes"] == [] and b["green"] and b["bundle_read"]
    assert d["counts_from"] == "mixed" and d["expected_failures"] is None
    assert (d["passed"], d["expected"]) == (4, 5)


def test_the_summary_codes_a_timeout_a_short_file_and_a_silent_suite(bench):
    scenario = {"A": {"tests": ["a()"], "hang": True}, "B": {"tests": ["x()"]}}
    code, out, d = summary_of(bench, scenario, [grp("A", 1), grp("B", 1)], timeout=2.0)
    assert code == 1, out
    assert d["shards"][0]["codes"] == ["timeout", "short"] and d["shards"][0]["timed_out"]
    assert d["shards"][1]["codes"] == []
    bench.run_dir = bench.tmp / "run2"
    scenario = {"A": {"tests": ["a()"]}, "Quiet": {"tests": ["q()"], "silent": True}, "B": {"tests": ["x()"]}}
    code, out, d = summary_of(bench, scenario, [grp("A", 1), grp("Quiet", 1), grp("B", 1)], jobs=1)
    assert code == 1 and d["shards"][0]["codes"] == ["short"] and d["shards"][0]["rc"] == 0, (out, d)


def test_a_test_that_passed_with_a_known_issue_is_a_pass_and_is_counted_as_known():
    st = xs.SuiteStats()
    st.add("S/a()", 0.1, "Passed")
    st.add("S/b()", 0.1, "Expected Failure")
    st.add("S/c()", 0.1, "Skipped")
    st.add("S/d()", 0.1, "Some New Word")
    assert (st.passed, st.known, st.skipped, st.failed) == (2, 1, 1, 1)


def test_coverage_makes_every_host_record_into_its_own_bundle_and_keeps_them_all(bench):
    scenario = {"A": {"tests": ["a()"]}, "B": {"tests": ["x()"]}}
    code, out = bench.go(scenario, [grp("A", 1), grp("B", 1)], jobs=2, extra=("--coverage",))
    assert code == 0, out
    for i in range(2):
        head = (bench.run_dir / f"{i:04d}" / "strand.log").read_text().splitlines()[0]
        assert "-enableCodeCoverage YES" in head and f"{i:04d}/shard.xcresult" in head, head
        assert (bench.run_dir / f"{i:04d}" / "shard.xcresult").is_dir(), "a green shard's bundle holds its coverage"
    # without it: the command is the one run_tests has always given, and a green bundle is not kept
    assert "-enableCodeCoverage" not in " ".join(xs.shard_cmd(["xcodebuild"], Path("x"), ["A"], Path("r")))
    bench.run_dir = bench.tmp / "run2"
    code, out = bench.go(scenario, [grp("A", 1), grp("B", 1)], jobs=2)
    assert code == 0 and not (bench.run_dir / "0000" / "shard.xcresult").exists(), out


def test_the_nightly_only_shards_through_a_copy_that_carries_the_summary_version_line():
    """nightly_local_tests.sh greps this exact line (app_shards_usable): a copy without it is the single host."""
    assert re.search(r"(?m)^NIGHTLY_SUMMARY_VERSION = 1$", SCRIPT.read_text())
    nightly = (ROOT / "scripts" / "nightly_local_tests.sh").read_text()
    assert "grep -q '^NIGHTLY_SUMMARY_VERSION = 1$' \"$1\"" in nightly
    assert 'd.get("version") != 1' in nightly


# ───────────────────────────────────────────── a Release build does not compile `#if DEBUG` tests

DEBUG_GATED = '''import Testing
@Suite struct TrimLikeTests {
    @Test func always() {}
    #if DEBUG
    // a seam that exists only in Debug
    @Test func debugOnly() {}
    #endif  // DEBUG
    #if !DEBUG
    @Test func releaseOnly() {}
    @Test func releaseOnlyToo() {}
    #else
    @Test func debugElse() {}
    #endif
    #if canImport(AppKit)
    @Test func eitherWay() {}
    #endif
    func budget() -> Int {
        #if DEBUG
        return 3
        #else
        return 1
        #endif
    }
}
'''


def test_a_test_inside_if_debug_is_not_expected_of_a_release_build(tmp_path):
    (tmp_path / "T.swift").write_text(DEBUG_GATED)
    declared = len(rt.swift_cases(DEBUG_GATED))
    assert declared == 6
    g = [G("T", ["TrimLikeTests"], declared, True, "unit", "T.swift")]
    names = lambda debug: sorted(c[1] for c in rt.swift_cases(xs.active_source(DEBUG_GATED, debug)))
    assert names(True) == ["always", "debugElse", "debugOnly", "eitherWay"]
    assert names(False) == ["always", "eitherWay", "releaseOnly", "releaseOnlyToo"]
    assert xs.true_up_all(g, tmp_path, True, debug=False)[0].tests == 4       # Release
    assert xs.true_up_all(g, tmp_path, True, debug=True)[0].tests == 4        # Debug
    assert xs.true_up_all(g, tmp_path, True, debug=None)[0].tests == 6, "unknown configuration: the count is not touched"
    assert xs.active_source(DEBUG_GATED, False).count("\n") == DEBUG_GATED.count("\n"), "line numbers are kept"


def test_the_configuration_is_read_from_the_xctestrun_and_the_two_trim_files_lose_one_test_each_in_release(tmp_path):
    rel, dbg, odd = tmp_path / "r.xctestrun", tmp_path / "d.xctestrun", tmp_path / "o.xctestrun"
    rel.write_text("<string>__TESTROOT__/Release/VideoScan.app</string><string>__TESTROOT__/Release/X.xctest</string>")
    dbg.write_text("<string>__TESTROOT__/Debug/VideoScan.app</string>")
    odd.write_text("<string>__TESTROOT__/Debug/A</string><string>__TESTROOT__/Release/B</string>")
    assert xs.build_configuration_is_debug(rel) is False and xs.build_configuration_is_debug(dbg) is True
    assert xs.build_configuration_is_debug(odd) is None and xs.build_configuration_is_debug(tmp_path / "none") is None
    manifest = json.loads((ROOT / "scripts" / "gauntlet" / "manifest.json").read_text())
    count = lambda debug: {g.name: g.tests for g in xs.groups_from_manifest(
        manifest, {"TrimSensorTests", "TrimMediaMatrixTests"}, ROOT, debug)}
    debug, release = count(True), count(False)
    assert set(debug) == {"TrimSensorTests", "TrimMediaMatrixTests"}
    assert all(release[n] == debug[n] - 1 for n in debug), (debug, release)



# ───────────────────────────── the sealed home (DECISIONS 2026-11-22: tests never open the real catalog)

def test_every_test_host_runs_with_a_sealed_home_and_the_built_xctestrun_is_untouched(bench):
    original = (bench.tmp / "x.xctestrun").read_bytes()
    code, out = bench.go({"A": {"tests": ["a1()"]}, "B": {"tests": ["b1()"]}, "C": {"tests": ["c1()"]}},
                         [grp("A", 1), grp("B", 1), grp("C", 1)], jobs=2)
    assert code == 0, out
    home = bench.run_dir / "home"
    stamps = bench.stamps()
    assert len(stamps) >= 2
    for st in stamps:
        assert st["xctestrun"] != str(bench.tmp / "x.xctestrun"), "a host ran from the unsealed .xctestrun"
        assert Path(st["xctestrun"]).parent == bench.tmp, "the sealed copy sits beside the original (__TESTROOT__)"
        for env in st["host_env"]:
            assert env["HOME"] == env["CFFIXED_USER_HOME"] == str(home), env
            assert env["KEEP_ME"] == "1", "the build's own test environment is kept"
    assert not home.exists(), "the sealed home (a copy of App Support) was left behind after the run"
    assert (bench.tmp / "x.xctestrun").read_bytes() == original, "the build's .xctestrun was modified"
    assert not list(bench.tmp.glob("*.sealed-*.xctestrun")), "the sealed copy was left beside the build"
    assert "sealed home" in out


def test_an_unreadable_xctestrun_is_refused_and_nothing_runs_unsealed(bench):
    (bench.tmp / "x.xctestrun").write_text("not a plist")
    code, out = bench.go({"A": {"tests": ["a1()"]}}, [grp("A", 1)], jobs=1)
    assert code == 1 and "REFUSED" in out and "seal" in out, out
    assert bench.stamps() == [], "a test host ran although the home could not be sealed"



def test_test_hosts_get_their_own_tmp_and_what_they_leave_is_reported_then_freed(bench):
    code, out = bench.go({"A": {"tests": ["a1()"], "leak": ["SigVerify-8F0C2E4B-1111-2222-3333-444455556666"]},
                          "B": {"tests": ["b1()"], "leak": ["SigVerify-0A0B0C0D-1111-2222-3333-444455556666"]}},
                         [grp("A", 1), grp("B", 1)], jobs=2)
    assert code == 0, out
    home = bench.run_dir / "home"
    for st in bench.stamps():
        for env in st["host_env"]:
            assert env["TMPDIR"] == env["VIDEOSCAN_TEST_TMP"] == str(home / "tmp") + "/", env
    assert "left behind by tests: 2 folder(s)" in out and "SigVerify-<id> ×2" in out, out
    assert not home.exists(), "the sealed home (and its tmp) was not freed"


def test_a_symlinked_run_home_is_refused_and_its_target_never_removed(bench):
    # Codex 2026-11-23 (runner deletion review, round 2): the caller resolved run_dir/home before preparing it, then
    # rmtree'd the resolved path — a symlinked home would have its EXTERNAL target removed.
    outside = bench.tmp / "outside"
    outside.mkdir()
    (outside / "sentinel.txt").write_text("keep")
    bench.run_dir.mkdir(parents=True, exist_ok=True)
    (bench.run_dir / "home").symlink_to(outside)
    code, out = bench.go({"A": {"tests": ["a1()"]}}, [grp("A", 1)], jobs=1)
    assert code == 1 and "REFUSED" in out, out
    assert (outside / "sentinel.txt").read_text() == "keep" and sorted(p.name for p in outside.iterdir()) == ["sentinel.txt"]
    assert bench.stamps() == [], "a test host ran"
