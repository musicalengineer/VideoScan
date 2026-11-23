"""scripts/core_lane.py — the VideoScanCore lane in two phases (2026-11-20).

Phase A: every test not marked quiet-machine, in parallel, timing not strict.
Phase B: the marked ones, serial, VIDEOSCAN_TIMING_STRICT as the caller set it.
Pinned here, with fake test processes (real pipes, no build):

  logic      the listing → the split (a suite's tag reaches its tests, an XCTest
             class is whole), the filter, the commands of each phase, the counts
  truth      the summary's numbers are the lines the children printed, by the
             nightly's own counting rules (the same fixture, both parsers)
  isolation  a listing without tags, a listing that lost a framework or the
             marks or disagrees with the test source, a quiet XCTest class the
             listing does not name, a phase (and each framework in it) that ran
             zero / fewer / more than its plan, a child that died, a failure in
             each phase: RED, by phase
  scale      100k tests: plan and count inside a budget
  sensor     the real tree: every test that reaches a timing or resident-size
             helper carries the mark; an unmarked one is named
  strands    phase B as K serial strands (2026-11-21): the deal covers every
             quiet test once; fail-beside/pass-alone is green with an AMBER
             line; fail-beside/fail-alone is RED by name; a strand that dies
             leaves its tests to the alone pass; one verdict line per test for
             the lane AND the nightly's parser; --quiet-jobs 1 is the old commands

The lane on a real bundle is measured in the commit message and exercised
nightly; scripts/test_nightly_failure_modes.sh section 14 pins the wiring.
"""
from __future__ import annotations

import importlib.util
import io
import json
import os
import re
import subprocess
import sys
import textwrap
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "scripts"))
spec = importlib.util.spec_from_file_location("core_lane", ROOT / "scripts" / "core_lane.py")
cl = importlib.util.module_from_spec(spec)
sys.modules["core_lane"] = cl
spec.loader.exec_module(cl)

M = "VideoScanCoreTests"


def rec(kind, ident, tags=(), version="6.4.0", with_tags=True):
    payload = {"kind": kind, "id": ident, "name": ident.split("/")[-1]}
    if with_tags:
        payload["tags"] = list(tags)
    return json.dumps({"kind": "test", "payload": payload, "version": version})


def fn(suite, name, line=10):
    return f"{M}.{suite}/{name}()/{suite.split('/')[0]}.swift:{line}:6"


def listing():
    """6 XCTest (4 loud in 2 classes, 2 quiet in 1 class) + 7 Swift Testing (4 loud, 3 quiet)."""
    stream = [
        rec("suite", f"{M}.StoreTests"),
        rec("function", fn("StoreTests", "roundTrip")),
        rec("function", fn("StoreTests", "commit")),
        rec("function", fn("StoreTests", "hundredThousandWithinBudget"), ["scale", "quietMachine"]),
        rec("suite", f"{M}.ScaleTests", ["quietMachine"]),
        rec("function", fn("ScaleTests", "load100k")),
        rec("suite", f"{M}.ScaleTests/Nested"),
        rec("function", fn("ScaleTests/Nested", "import100k")),
        rec("suite", f"{M}.ScaleTestsButNotReally"),              # a name that only STARTS like a tagged suite
        rec("function", fn("ScaleTestsButNotReally", "plain")),
        rec("function", fn("StoreTests", "skippedWithoutFfmpeg")),
    ]
    functions, quiet = cl.parse_swift_listing(stream)
    return cl.Listing(
        xctest={f"{M}.OldTests": ["testA", "testB"], f"{M}.PerfTests": ["testMemory", "testDecode"],
                f"{M}.MoreTests": ["testC", "testD"]},
        xctest_quiet={f"{M}.PerfTests"}, swift=functions, swift_quiet=quiet)


# ── logic: the listing and the split

def test_a_test_is_quiet_by_its_own_tag_or_a_suite_above_it_and_by_nothing_else():
    L = listing()
    assert L.swift_quiet == {fn("StoreTests", "hundredThousandWithinBudget"), fn("ScaleTests", "load100k"),
                             fn("ScaleTests/Nested", "import100k")}
    assert fn("ScaleTestsButNotReally", "plain") not in L.swift_quiet, "a suite id is a path, not a prefix of a name"
    assert len(L.swift) == 7


def test_the_two_plans_are_disjoint_and_together_are_every_test():
    L = listing()
    a, b = cl.plan_phases(L, None)
    assert (a.xctest_count, len(a.swift), a.expected) == (4, 4, 8)
    assert (b.xctest_count, len(b.swift), b.expected) == (2, 3, 5)
    assert a.expected + b.expected == sum(map(len, L.xctest.values())) + len(L.swift)
    assert not set(a.swift) & set(b.swift) and set(a.swift) | set(b.swift) == set(L.swift)
    assert a.xctest == ["OldTests", "MoreTests"] and b.xctest == ["PerfTests"]


def test_a_filter_narrows_both_phases_and_a_part_class_is_named_by_method():
    L = listing()
    a, b = cl.plan_phases(L, r"(\.|/)(StoreTests|PerfTests)/")
    assert (a.xctest, a.xctest_count) == ([], 0) and len(a.swift) == 3
    assert b.xctest == ["PerfTests"] and b.swift == [fn("StoreTests", "hundredThousandWithinBudget")]
    a, b = cl.plan_phases(L, r"OldTests/testA$|PerfTests/testMemory$")
    # no module in an XCTest selector: `xctest -XCTest Module.Class/method` runs nothing (measured, Xcode 27)
    assert a.xctest == ["OldTests/testA"] and b.xctest == ["PerfTests/testMemory"]
    assert (a.expected, b.expected) == (1, 1)


def fake_bundle(tmp_path, environ=None):
    return cl.Bundle(tmp_path, tmp_path / cl.BUNDLE, tmp_path / "exe", tmp_path / "pm",
                     dict(environ if environ is not None else {"PATH": os.environ["PATH"]}))


def test_phase_a_runs_both_frameworks_at_once_skipping_the_quiet_ids_and_phase_b_serializes(tmp_path):
    L = listing()
    a, b = cl.plan_phases(L, None)
    bd = fake_bundle(tmp_path)
    ca = dict(cl.phase_commands(bd, a, None))
    assert ca["XCTest"][:3] == ["xcrun", "xctest", "-XCTest"] and ca["XCTest"][3] == "OldTests,MoreTests"
    st = ca["Swift Testing"]
    assert "--no-parallel" not in st and "--filter" not in st
    skip = re.compile(st[st.index("--skip") + 1])
    assert all(skip.search(i) for i in L.swift_quiet) and not any(skip.search(i) for i in a.swift)
    cb = dict(cl.phase_commands(bd, b, None))
    assert cb["XCTest"][3] == "PerfTests"
    sb = cb["Swift Testing"]
    only = re.compile(sb[sb.index("--filter") + 1])
    assert "--no-parallel" in sb and "--skip" not in sb
    assert all(only.search(i) for i in b.swift) and not any(only.search(i) for i in a.swift)
    # with a filter, phase A passes it on (and still skips every quiet id); phase B names its ids itself
    a2, b2 = cl.plan_phases(L, "StoreTests")
    st2 = dict(cl.phase_commands(bd, a2, "StoreTests"))["Swift Testing"]
    assert st2[st2.index("--filter") + 1] == "StoreTests" and "--skip" in st2
    assert "XCTest" not in dict(cl.phase_commands(bd, a2, "StoreTests")), "no selector, no XCTest process"


def test_an_id_with_regex_characters_is_matched_literally():
    ident = f"{M}.A/f(x:)/A+B (1).swift:3:6"
    rx = re.compile(cl.swift_id_regex([ident]))
    assert rx.search(ident) and not rx.search(ident.replace("+", "")) and not rx.search(ident + "0")


# ── counting: the nightly's rules, on the nightly's own fixture shapes

ZW = "​"
PHASE_A_LOG = f"""\
Test Suite 'OldTests' started at 2026-11-20 02:10:00.000.
Test Case '-[{M}.OldTests testA]' started.
Test Case '-[{M}.OldTests testA]' passed (0.010 seconds).
Test Case '-[{M}.OldTests testB]' started.
Test Case '-[{M}.OldTests testB]' skipped (0.001 seconds).
\t Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected) in 0.010 (0.010) seconds
◇ Test roundTrip() started.
{ZW}✔ Test roundTrip() passed after 0.010 seconds.
◇ Test commit() started.
✘ Test commit() recorded an issue at StoreTests.swift:9:5: Expectation failed: x failed after y
✘ Test commit() failed after 0.020 seconds with 1 issue.
━ Test "a known one" recorded a known issue at StoreTests.swift:12:5: Issue recorded
━ Test "a known one" passed after 0.030 seconds with 1 known issue.
➜ Test skippedWithoutFfmpeg() skipped.
✔ Suite "Store" passed after 0.100 seconds.
✘ Test run with 4 tests in 1 suite failed after 0.100 seconds with 1 issue.
"""


def counted(text):
    c = cl.Counts()
    for line in text.splitlines():
        c.feed(line)
    return c


def test_counts_are_one_per_terminal_line_and_an_issue_line_or_run_summary_is_not_a_test():
    c = counted(PHASE_A_LOG)
    assert (c.passed, c.failed, c.skipped, c.known, c.total) == (3, 1, 2, 1, 6)
    assert c.failed_names == ["commit()"] and c.running == {}


def test_truth_the_lane_and_the_nightly_count_the_same_log_the_same(tmp_path):
    """The row's core_* numbers come from parse_test_counts on the lane's output; the lane's own
    per-phase check must agree with it line for line, or one of them is lying."""
    log = tmp_path / "core.log"
    log.write_text("core-lane: phase A (parallel, timing not strict): 6 tests planned (2 XCTest + 4 Swift Testing)\n"
                   + PHASE_A_LOG
                   + "core-lane: phase A (parallel, timing not strict): 3 passed / 1 failed / 2 skipped — 6 of 6 planned, 1 with known issues, 1 s\n"
                   + "core-lane: RED — phase A (parallel, timing not strict): FAILED commit()\n")
    nightly = (ROOT / "scripts" / "nightly_local_tests.sh").read_text()
    fns = "".join(re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", nightly, re.S | re.M).group(0)
                  for name in ("parse_crashed_tests", "parse_test_counts"))
    script = fns + f'\nparse_test_counts "{log}"\necho "$PASSED|$FAILED|$SKIPPED|$KNOWN_ISSUE_TESTS|$FAILED_NAMES_JSON"\n'
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)
    c = counted(log.read_text())
    assert p.stdout.strip() == f'{c.passed}|{c.failed}|{c.skipped}|{c.known}|["commit()"]', p.stderr[-400:]
    assert c.total == 6


def test_a_test_that_started_and_never_ended_is_named_at_a_stop():
    c = counted(f"◇ Test fast() started.\n✔ Test fast() passed after 0.1 seconds.\n◇ Test hung() started.\n"
                f"◇ Test \"also hung\" started.\nTest Case '-[{M}.OldTests testA]' started.\n")
    assert sorted(c.running) == ['"also hung"', f"-[{M}.OldTests testA]", "hung()"]
    out = io.StringIO()
    plan = cl.plan_phases(listing(), None)[0]
    import threading
    cl.say_what_was_running([cl.PhaseLive(plan, c, threading.Lock())], cl.Output(out))
    assert "stopped in phase A" in out.getvalue() and "hung()" in out.getvalue() and "fast()" not in out.getvalue()


# ── the lane end to end, with fake test processes on real pipes

def xc_lines(cls, methods, fail=()):
    return "".join(f"Test Case '-[{cls} {m}]' started.\nTest Case '-[{cls} {m}]' {'failed' if m in fail else 'passed'} (0.001 seconds).\n"
                   for m in methods)


def st_lines(ids, fail=(), skip=()):
    out = ""
    for i in ids:
        name = i.split("/")[-2]
        if name in skip:
            out += f"➜ Test {name} skipped.\n"
        elif name in fail:
            out += f"◇ Test {name} started.\n✘ Test {name} failed after 0.001 seconds with 1 issue.\n"
        else:
            out += f"◇ Test {name} started.\n✔ Test {name} passed after 0.001 seconds.\n"
    return out


class FakeRun:
    """Stands in for xctest / swiftpm-testing-helper: prints what a real run of that selection prints."""

    def __init__(self, L, fail=(), skip=(), drop=(), extra="", rc=None):
        self.L, self.fail, self.skip, self.drop, self.extra, self.rc = L, set(fail), set(skip), set(drop), extra, rc or {}
        self.calls = []                                     # (what, serial, strict)

    def __call__(self, cmd, env):
        L = self.L
        if cmd[:2] == ["xcrun", "xctest"]:
            what, text = "xctest", ""
            for sel in cmd[3].split(","):
                cls, _, method = sel.partition("/")
                assert "." not in cls, f"an XCTest selector with its module runs nothing: {sel}"
                cls = f"{M}.{cls}"
                text += xc_lines(cls, [m for m in L.xctest[cls] if (not method or m == method) and m not in self.drop], self.fail)
        else:
            what = "swift"
            ids = L.swift
            if "--filter" in cmd:
                rx = re.compile(cmd[cmd.index("--filter") + 1])
                ids = [i for i in ids if rx.search(i)]
            if "--skip" in cmd:
                rx = re.compile(cmd[cmd.index("--skip") + 1])
                ids = [i for i in ids if not rx.search(i)]
            text = st_lines([i for i in ids if i.split("/")[-2] not in self.drop], self.fail, self.skip) + self.extra
        self.calls.append((what, "--no-parallel" in cmd, env.get(cl.STRICT_KEY)))
        failed = any(f in text and ("failed" in text) for f in self.fail)
        rc = self.rc.get(what, 1 if failed else 0)
        code = f"import sys; sys.stdout.write({text!r}); sys.exit({rc})"
        return subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def run(tmp_path, monkeypatch, fake, regex=None, environ=None, lister=None, witness=None):
    L = fake.L
    monkeypatch.setattr(cl, "open_bundle", lambda products: fake_bundle(tmp_path, environ))
    out = io.StringIO()
    rc = cl.run_lane(str(tmp_path), regex, cl.Output(out), spawn=fake, lister=lister or (lambda b: L),
                     witness=(lambda: witness) if witness is not None else None)
    return rc, out.getvalue()


def test_green_both_phases_ran_their_plan_and_the_total_is_their_sum(tmp_path, monkeypatch):
    fake = FakeRun(listing(), skip={"skippedWithoutFfmpeg()"})
    rc, text = run(tmp_path, monkeypatch, fake, environ={"PATH": os.environ["PATH"], cl.STRICT_KEY: "1"})
    assert rc == 0, text
    assert "phase A (parallel, timing not strict): 7 passed / 0 failed / 1 skipped — 8 of 8 planned" in text
    assert "phase B (serial, quiet machine, strict): 5 passed / 0 failed / 0 skipped — 5 of 5 planned" in text
    assert "total 12 passed / 0 failed / 1 skipped — 13 of 13 planned" in text and "→ GREEN" in text
    c = counted(text)                                       # truth: the summary is what the children printed
    assert (c.passed, c.failed, c.skipped) == (12, 0, 1)


def test_phase_a_is_never_strict_and_phase_b_keeps_the_callers_strictness(tmp_path, monkeypatch):
    fake = FakeRun(listing())
    run(tmp_path, monkeypatch, fake, environ={"PATH": os.environ["PATH"], cl.STRICT_KEY: "1"})
    assert sorted(fake.calls, key=str) == sorted([("swift", False, None), ("swift", True, "1"),
                                                  ("xctest", False, None), ("xctest", False, "1")], key=str)
    fake = FakeRun(listing())
    rc, text = run(tmp_path, monkeypatch, fake)             # a developer's run: nobody pinned strict
    assert rc == 0 and {c[2] for c in fake.calls} == {None} and "quiet machine, strict" not in text
    assert [c for c in fake.calls if c[0] == "swift" and c[1]] == [("swift", True, None)], "phase B is serial either way"


def test_a_failure_names_its_phase_and_the_lane_is_red(tmp_path, monkeypatch):
    rc, text = run(tmp_path, monkeypatch, FakeRun(listing(), fail={"load100k()"}))
    assert rc == cl.EXIT_FAILED
    assert "core-lane: RED — phase B (serial, quiet machine): FAILED load100k()" in text
    assert "phase A (parallel, timing not strict): 8 passed / 0 failed" in text and "→ RED" in text
    rc, text = run(tmp_path, monkeypatch, FakeRun(listing(), fail={"testA"}))
    assert rc == cl.EXIT_FAILED and f"RED — phase A (parallel, timing not strict): FAILED -[{M}.OldTests testA]" in text


def test_a_phase_that_ran_zero_tests_is_red_even_when_every_child_exited_zero(tmp_path, monkeypatch):
    L = listing()
    quiet_names = {i.split("/")[-2] for i in L.swift_quiet} | {"testMemory", "testDecode"}
    rc, text = run(tmp_path, monkeypatch, FakeRun(L, drop=quiet_names))
    assert rc == cl.EXIT_COUNT
    assert "RED — phase B (serial, quiet machine): XCTest ran ZERO of its 2 tests" in text
    assert "RED — phase B (serial, quiet machine): Swift Testing ran ZERO of its 3 tests" in text
    assert "phase A (parallel, timing not strict): 8 passed" in text, "phase A's green does not cover phase B"


def test_a_phase_that_ran_fewer_or_more_than_its_plan_is_red(tmp_path, monkeypatch):
    rc, text = run(tmp_path, monkeypatch, FakeRun(listing(), drop={"roundTrip()"}))
    assert rc == cl.EXIT_COUNT and "RED — phase A (parallel, timing not strict): Swift Testing ran 3 of its 4 tests" in text
    assert "XCTest ran" not in text, "XCTest ran its plan: only the framework that fell short is named"
    rc, text = run(tmp_path, monkeypatch, FakeRun(listing(), extra="✔ Test unlisted() passed after 0.001 seconds.\n"))
    assert rc == cl.EXIT_COUNT and "phase A (parallel, timing not strict): Swift Testing ran 5 of its 4 tests" in text
    assert "phase B (serial, quiet machine): Swift Testing ran 4 of its 3 tests" in text


def test_a_child_that_dies_without_a_failed_test_is_red_by_phase(tmp_path, monkeypatch):
    rc, text = run(tmp_path, monkeypatch, FakeRun(listing(), rc={"swift": 134}))
    assert rc == cl.EXIT_FAILED
    assert "RED — phase A (parallel, timing not strict): Swift Testing exited 134 with no failed test" in text
    assert "RED — phase B (serial, quiet machine): Swift Testing exited 134" in text


def test_a_listing_without_tags_is_refused_never_read_as_nothing_is_quiet(tmp_path, monkeypatch):
    old = [rec("function", fn("StoreTests", "a"), version=0, with_tags=False)]
    with pytest.raises(cl.ListingError, match="carries no tags"):
        cl.parse_swift_listing(old)
    with pytest.raises(cl.ListingError, match="not JSON"):
        cl.parse_swift_listing(["{torn"])
    fake = FakeRun(listing())

    def lister(b):
        return (_ for _ in ()).throw(cl.ListingError("the Swift Testing listing carries no tags"))
    rc, text = run(tmp_path, monkeypatch, fake, lister=lister)
    assert rc == cl.EXIT_COUNT and "RED — the Swift Testing listing carries no tags" in text and fake.calls == []


def test_no_bundle_and_an_empty_bundle_are_red(tmp_path, monkeypatch):
    out = io.StringIO()
    assert cl.run_lane(str(tmp_path), None, cl.Output(out)) == cl.EXIT_FAILED and "no built test bundle" in out.getvalue()
    rc, text = run(tmp_path, monkeypatch, FakeRun(cl.Listing()))
    assert rc == cl.EXIT_COUNT and "lists ZERO XCTest tests" in text and "lists ZERO Swift Testing tests" in text


def test_a_filter_that_selects_only_loud_xctest_runs_no_other_process_and_is_green(tmp_path, monkeypatch):
    fake = FakeRun(listing())
    rc, text = run(tmp_path, monkeypatch, fake, regex=r"(\.|/)(OldTests)/")
    assert rc == 0 and fake.calls == [("xctest", False, None)], text
    assert "2 of 2 planned" in text and "phase B (serial, quiet machine): 0 passed / 0 failed / 0 skipped — 0 of 0 planned" in text


def test_release_builds_get_enable_testing_and_debug_does_not():
    assert cl.build_command("/p", "release", "/s") == ["swift", "build", "--build-tests", "--package-path", "/p",
                                                       "-c", "release", "--scratch-path", "/s", "-Xswiftc", "-enable-testing"]
    assert cl.build_command("/p", "debug", None) == ["swift", "build", "--build-tests", "--package-path", "/p", "-c", "debug"]


# ── scale

def test_scale_a_hundred_thousand_tests_plan_and_count_inside_a_budget():
    n = 100_000
    stream = [rec("suite", f"{M}.Big", []), rec("suite", f"{M}.Quiet", ["quietMachine"])]
    stream += [rec("function", fn("Big", f"t{i}", i)) for i in range(n - 1000)]
    stream += [rec("function", fn("Quiet", f"q{i}", i)) for i in range(1000)]
    t0 = time.monotonic()
    functions, quiet = cl.parse_swift_listing(stream)
    a, b = cl.plan_phases(cl.Listing(swift=functions, swift_quiet=quiet), None)
    c = cl.Counts()
    for i in a.swift:
        name = i.split("/")[-2]
        c.feed(f"◇ Test {name} started.")
        c.feed(f"✔ Test {name} passed after 0.001 seconds.")
    elapsed = time.monotonic() - t0
    assert (len(a.swift), len(b.swift), c.passed, len(c.running)) == (n - 1000, 1000, n - 1000, 0)
    assert re.compile(cl.swift_id_regex(b.swift)).search(b.swift[-1])
    assert elapsed < 20, f"100k tests took {elapsed:.1f} s to plan and count"


# ── sensor: the source pin

def test_sensor_every_core_test_that_judges_time_or_resident_size_is_marked_quiet_machine():
    bad = cl.check_tags(cl.CORE_TESTS)
    assert bad == [], "\n".join(bad)


SWIFT = textwrap.dedent('''
    import Testing
    import XCTest
    @Suite("plain") struct PlainTests {
        @Test func unmarkedDirect() { expectWithinTimingBudget("x", measured: d, budget: b, loadBefore: l) }
        @Test(.tags(.quietMachine)) func markedDirect() { expectRatio(TimingBudget.judgeGrowth("x", small: a, large: b, sizeRatio: 4, limit: 6)) }
        @Test func unmarkedThroughAHelper() { let d = oneRow(); _ = d }
        @Test("named", .timeLimit(.minutes(1)), .tags(.scale, .quietMachine)) func markedThroughAHelper() { _ = oneRow() }
        @Test func pureRuleOnly() { _ = TimingBudget.judge("x", budget: b, measured: m, before: s, after: s) }
        @Test func saysItInAString() { print("expectWithinTimingBudget is only a word here") }
        func oneRow() -> Duration { let d = measure(); expectWithinTimingBudget("row", measured: d, budget: b, loadBefore: l); return d }
    }
    @Suite("whole suite", .tags(.quietMachine)) struct ScaleTests {
        @Test func coveredByTheSuite() { recordTimingJudgement(j) }
        @Suite struct Inner { @Test func coveredByTheOuterSuite() { recordTimingJudgement(j) } }
    }
    struct MemoryTests {
        static func residentMB() -> Double { var info = mach_task_basic_info(); return Double(info.resident_size) }
        @Test func unmarkedResident() { #expect(Self.residentMB() < 500) }
    }
    final class OldPerfTests: XCTestCase {
        func testUnmarkedXCTest() throws { try assertTimingJudgements([j]) }
        func testPlain() {}
    }
    final class NewPerfTests: QuietMachineXCTestCase {
        func testMarkedXCTest() throws { try assertTimingJudgements([j]) }
    }
''')


def test_sensor_an_unmarked_test_is_named_directly_through_a_helper_and_in_xctest(tmp_path):
    (tmp_path / "SampleTests.swift").write_text(SWIFT)
    (tmp_path / "TimingBudgetExpectations.swift").write_text(
        "func expectWithinTimingBudget() { recordTimingJudgement() }\nfunc recordTimingJudgement() {}\n")
    bad = cl.check_tags(tmp_path)
    named = sorted(re.search(r"/(\w+) reaches", b).group(1) for b in bad)
    assert named == ["testUnmarkedXCTest", "unmarkedDirect", "unmarkedResident", "unmarkedThroughAHelper"], "\n".join(bad)
    by = {re.search(r"/(\w+) reaches", b).group(1): b for b in bad}
    assert "SampleTests.swift:5 PlainTests/unmarkedDirect reaches expectWithinTimingBudget" in by["unmarkedDirect"]
    assert "add .tags(.quietMachine)" in by["unmarkedDirect"]
    assert "inherit QuietMachineXCTestCase" in by["testUnmarkedXCTest"]


def test_sensor_the_cli_is_red_with_the_names_and_green_on_the_real_tree(tmp_path):
    (tmp_path / "SampleTests.swift").write_text(SWIFT)
    lane = str(ROOT / "scripts" / "core_lane.py")
    p = subprocess.run([sys.executable, lane, "check", "--tests", str(tmp_path)], capture_output=True, text=True, timeout=120)
    assert p.returncode == 1 and "unmarkedDirect" in p.stdout and "4 test(s)" in p.stdout
    p = subprocess.run([sys.executable, lane, "check"], capture_output=True, text=True, timeout=120)
    assert p.returncode == 0 and "0 test(s)" in p.stdout, p.stdout[-2000:]


def test_the_sensor_lane_runs_the_check_and_the_nightly_and_run_tests_run_this_lane():
    assert "core_lane.check_tags(CORE_TESTS)" in (ROOT / "scripts" / "sensor_lane.py").read_text()
    nightly = (ROOT / "scripts" / "nightly_local_tests.sh").read_text()
    lane_fn = re.search(r"^run_core_package_tests\(\) \{\n.*?^\}\n", nightly, re.S | re.M).group(0)
    assert 'core_command=(python3 -u "$core_lane" run --package-path "$package_path"' in lane_fn
    # the one serial whole-lane pass left is the fallback for a checkout that has no core_lane.py
    assert lane_fn.count("--no-parallel") == 2 and lane_fn.index('if [ -f "$core_lane" ]') < lane_fn.index("swift test --package-path")


def test_the_mark_is_declared_once_and_names_what_the_lane_reads():
    src = (cl.CORE_TESTS / "QuietMachine.swift").read_text()
    assert f"@Tag static var {cl.QUIET_TAG}: Self" in src and f'"{cl.XCTEST_LIST_KEY}"' in src
    others = [p for p in cl.CORE_TESTS.rglob("*.swift") if p.name != "QuietMachine.swift"
              and re.search(rf"static var {cl.QUIET_TAG}\b", p.read_text(errors="replace"))]
    assert others == [], f"the tag is declared again in {others}"


# ───────────────────────────── review of 802f027ce (2026-11-21): the reviewer's eight RED tests, as written
# (their file imported this one as `t`; here `t` is this module), then what the fixes add.

import copy, stat                                                  # noqa: E402,E401
t = sys.modules[__name__]


# F1 — scripts/core_lane.py:344-350 (no Swift Testing process when the listing has no Swift ids)
#      and :341 (same for XCTest); :452 is the only floor ("ZERO tests" overall).
def test_F1_a_listing_that_lost_a_whole_framework_is_not_green(tmp_path, monkeypatch):
    truth = t.listing()                                           # what the bundle really holds: 6 XCTest + 7 Swift Testing
    lost = copy.deepcopy(truth); lost.swift, lost.swift_quiet = [], set()   # the helper wrote an empty stream and exited 0
    fake = t.FakeRun(truth)
    rc, text = t.run(tmp_path, monkeypatch, fake, lister=lambda b: lost)
    assert rc != cl.EXIT_GREEN, "GREEN with 7 Swift Testing tests never started:\n" + text
    lost = copy.deepcopy(truth); lost.xctest, lost.xctest_quiet = {}, set()
    rc, text = t.run(tmp_path, monkeypatch, t.FakeRun(truth), lister=lambda b: lost)
    assert rc != cl.EXIT_GREEN, "GREEN with 6 XCTest tests never started:\n" + text


# F2 — scripts/core_lane.py:445-446: a full run whose listing marks nothing quiet skips phase B and is GREEN;
#      every budget test then runs in phase A, parallel, with VIDEOSCAN_TIMING_STRICT removed (:384).
def test_F2_a_full_run_with_no_quiet_machine_test_is_refused(tmp_path, monkeypatch):
    truth = t.listing()
    untagged = copy.deepcopy(truth); untagged.swift_quiet, untagged.xctest_quiet = set(), set()   # tags key present, mark lost
    fake = t.FakeRun(untagged)
    rc, text = t.run(tmp_path, monkeypatch, fake, lister=lambda b: untagged,
                     environ={"PATH": os.environ["PATH"], cl.STRICT_KEY: "1"})
    assert rc != cl.EXIT_GREEN, "GREEN, strict never applied to anything:\n" + text


# F2b — scripts/core_lane.py:382-384: nothing tells a test process which phase it is in, so the run-time pin
#       (TimingBudgetExpectations.swift:39-43) can only check the tag, not that the lane honoured it.
def test_F2b_a_test_process_can_tell_the_parallel_phase_from_the_serial_one(tmp_path, monkeypatch):
    seen = {}
    inner = t.FakeRun(t.listing())
    def spawn(cmd, env):
        seen["B" if "--no-parallel" in cmd else "A" if "--skip" in cmd else "x"] = dict(env)
        return inner(cmd, env)
    monkeypatch.setattr(cl, "open_bundle", lambda products: t.fake_bundle(tmp_path))
    cl.run_lane(str(tmp_path), None, cl.Output(io.StringIO()), spawn=spawn, lister=lambda b: inner.L)
    assert seen["A"] != seen["B"], "phase A and phase B hand their tests the same environment"


# F3 — scripts/core_lane.py:173: `& set(out.xctest)` drops a quiet class the tree names differently, silently.
def test_F3_a_quiet_xctest_class_the_tree_does_not_name_is_refused_not_dropped(tmp_path):
    pm = tmp_path / "pm"; pm.mkdir()
    tree = {"tests": [{"name": "VideoScanCoreTests.xctest", "tests": [
        {"name": f"{M}.PerfTests", "tests": [{"name": "testMemory"}]}]}]}
    (pm / "swiftpm-xctest-helper").write_text(
        "#!/bin/sh\ncat > \"$2\" <<'J'\n" + json.dumps(tree) + "\nJ\n"
        "echo '_TtC18VideoScanCoreTestsP33_0123456789ABCDEF0123456789ABCDEF9PerfTests' >> \"$VIDEOSCAN_QUIET_XCTEST_LIST\"\n")
    stream = t.rec("function", t.fn("StoreTests", "roundTrip"))
    (pm / "swiftpm-testing-helper").write_text(
        "#!/bin/sh\nwhile [ $# -gt 0 ]; do [ \"$1\" = --event-stream-output-path ] && out=\"$2\"; shift; done\n"
        "cat > \"$out\" <<'J'\n" + stream + "\nJ\n")
    for f in pm.iterdir():
        f.chmod(f.stat().st_mode | stat.S_IXUSR)
    b = cl.Bundle(tmp_path, tmp_path / cl.BUNDLE, tmp_path / "exe", pm, {"PATH": os.environ["PATH"]})
    with pytest.raises(cl.ListingError):
        cl.list_bundle(b)                                         # today: returns, xctest_quiet == set()


# F4 — scripts/core_lane.py:511-515 (JUDGING_HELPERS / RESIDENT_RE are the whole rule) vs QuietMachine.swift:14-17
#      ("or with a bare #expect(elapsed < …)") and nightly_local_tests.sh:464-465 ("no test there judges a budget").
def test_F4_a_bare_wall_time_assertion_needs_the_mark_too(tmp_path):
    (tmp_path / "BareTests.swift").write_text(textwrap.dedent('''
        import Testing
        struct BareTests {
            @Test func bareBudget() {
                let clock = ContinuousClock()
                let elapsed = clock.measure { work() }
                #expect(elapsed < .seconds(2), "took \\(elapsed)")
            }
        }
    '''))
    assert any("bareBudget" in b for b in cl.check_tags(tmp_path)), "an unmarked bare budget passes the pin"


def test_F4_real_tree_the_one_unmarked_wall_time_ratio():
    src = (cl.CORE_TESTS / "Background" / "EraJobRetryReviewTests.swift").read_text()
    i = src.index("func recordingATryDoesNotRewriteEveryEntry")
    # two clock.measure windows compared (line 169); since 2026-11-21 through the helper that marks it a budget
    assert "expectBudget(large, under: small * 4" in src[i:]
    assert ".quietMachine" in src[src.rindex("@Test", 0, i):i], "judges wall time in the parallel phase"


# F5 — scripts/core_lane.py:375-376: one sum for both frameworks; a short XCTest run is hidden by a long Swift one.
def test_F5_each_framework_is_held_to_its_own_plan(tmp_path, monkeypatch):
    fake = t.FakeRun(t.listing(), drop={"testA"})                 # XCTest one short ...
    def spawn(cmd, env):
        fake.extra = "✔ Test unlisted() passed after 0.001 seconds.\n" if "--skip" in cmd else ""   # ... phase A Swift one over
        return fake(cmd, env)
    monkeypatch.setattr(cl, "open_bundle", lambda products: t.fake_bundle(tmp_path))
    out = io.StringIO()
    rc = cl.run_lane(str(tmp_path), None, cl.Output(out), spawn=spawn, lister=lambda b: fake.L)
    assert rc != cl.EXIT_GREEN, out.getvalue()


# F6 — scripts/core_lane.py:234,263 (XC_RE anchored, .match): a stdout fragment glued in front of XCTest's line.
def test_F6_a_glued_xctest_verdict_line_still_counts():
    c = cl.Counts()
    c.feed(f"EraAttemptStore: 100 recordsTest Case '-[{M}.OldTests testA]' passed (0.010 seconds).")
    assert c.total == 1


# ── what the fixes add

def witness_of(L, **change):
    base = dict(xctest=sum(map(len, L.xctest.values())), swift=len(L.swift),
                xctest_quiet=sum(len(L.xctest[c]) for c in L.xctest_quiet), swift_quiet=len(L.swift_quiet))
    return cl.SourceCounts(**dict(base, **change))


def test_F1_the_refusal_names_the_framework_and_runs_nothing(tmp_path, monkeypatch):
    truth = listing()
    lost = copy.deepcopy(truth); lost.swift, lost.swift_quiet = [], set()
    fake = FakeRun(truth)
    rc, text = run(tmp_path, monkeypatch, fake, lister=lambda b: lost)
    assert rc == cl.EXIT_COUNT and fake.calls == [], "a refused listing starts no test process"
    assert "RED — the bundle lists ZERO Swift Testing tests" in text and "no test was run" in text
    # a FILTERED run may select one framework only: that is a selection, not a lost listing
    rc, text = run(tmp_path, monkeypatch, FakeRun(truth), regex=r"(\.|/)(OldTests)/")
    assert rc == cl.EXIT_GREEN, text


def test_F1_the_listing_is_cross_checked_against_the_source_count(tmp_path, monkeypatch):
    L = listing()
    rc, text = run(tmp_path, monkeypatch, FakeRun(L), witness=witness_of(L))
    assert rc == cl.EXIT_GREEN and "the test source declares 6 XCTest + 7 Swift Testing tests, 2 + 3 of them quiet-machine" in text
    rc, text = run(tmp_path, monkeypatch, FakeRun(L), witness=witness_of(L, swift=7 + cl.SOURCE_SLACK))
    assert rc == cl.EXIT_GREEN, "inside the stated tolerance (the source side is a lexer): " + text
    fake = FakeRun(L)
    rc, text = run(tmp_path, monkeypatch, fake, witness=witness_of(L, swift=2400))     # the listing came back cut short
    assert rc == cl.EXIT_COUNT and fake.calls == []
    assert "the bundle lists 7 Swift Testing tests but the test source declares 2400 (allowed difference 48)" in text
    rc, text = run(tmp_path, monkeypatch, FakeRun(L), witness=witness_of(L, xctest=230))
    assert rc == cl.EXIT_COUNT and "lists 6 XCTest tests but the test source declares 230" in text


def test_F2_marks_the_build_lost_are_refused_by_number(tmp_path, monkeypatch):
    L = listing()
    fake = FakeRun(L)
    rc, text = run(tmp_path, monkeypatch, fake, witness=witness_of(L, swift_quiet=150))   # 3 listed quiet, 150 in source
    assert rc == cl.EXIT_COUNT and fake.calls == []
    assert "lists 3 quiet-machine Swift Testing tests but the test source declares 150" in text
    untagged = copy.deepcopy(L); untagged.swift_quiet = set()                              # XCTest marks kept, Swift ones gone
    rc, text = run(tmp_path, monkeypatch, FakeRun(untagged))
    assert rc == cl.EXIT_COUNT and "lists ZERO quiet-machine Swift Testing tests" in text and "judge strictly" in text


def test_F2_the_real_run_always_has_a_witness_and_no_source_is_red(tmp_path, monkeypatch, capsys):
    seen = {}

    def fake_run_lane(products, regex, out, live=None, witness=None, **_strands):   # + quiet_jobs, timings (2026-11-21)
        seen["witness"] = witness() if witness else None
        return 0
    monkeypatch.setattr(cl, "run_lane", fake_run_lane)
    assert cl.main(["run", "--products", str(tmp_path)]) == 0
    real = cl.scan_source(cl.CORE_TESTS).counts
    assert seen["witness"] == real and real.swift > 2000 and real.xctest > 200 and real.swift_quiet > 100 and real.xctest_quiet > 50
    seen.clear()
    assert cl.main(["run", "--products", str(tmp_path), "--tests", str(tmp_path / "nowhere")]) == cl.EXIT_COUNT
    assert seen == {} and "no test source at" in capsys.readouterr().out


def test_F2b_each_phase_names_itself_to_its_test_processes(tmp_path, monkeypatch):
    envs = {}
    inner = FakeRun(listing())

    def spawn(cmd, env):
        envs.setdefault(env[cl.PHASE_KEY], []).append("--no-parallel" in cmd or (cmd[:2] == ["xcrun", "xctest"] and "PerfTests" in cmd[3]))
        return inner(cmd, env)
    monkeypatch.setattr(cl, "open_bundle", lambda products: fake_bundle(tmp_path))
    assert cl.run_lane(str(tmp_path), None, cl.Output(io.StringIO()), spawn=spawn, lister=lambda b: inner.L) == 0
    assert envs == {"parallel": [False, False], "serial": [True, True]}
    swift = (cl.CORE_TESTS / "QuietMachine.swift").read_text()
    assert f'static let environmentKey = "{cl.PHASE_KEY}"' in swift and 'static let parallel = "parallel"' in swift
    # every door a judgement goes through asks the phase
    assert "QuietMachinePhase.problem()" in (cl.CORE_TESTS / "TimingBudgetExpectations.swift").read_text()
    assert "QuietMachinePhase.problem()" in (cl.CORE_TESTS / "TimingBudgetXCTestSupport.swift").read_text()
    assert "override func setUp()" in swift and swift.count("QuietMachinePhase.problem()") >= 1


def test_F3_a_list_that_cannot_be_written_stops_the_listing(tmp_path):
    swift = (cl.CORE_TESTS / "QuietMachine.swift").read_text()
    body = swift[swift.index("override class var defaultTestSuite"):swift.index("override func setUp()")]
    assert "fatalError(" in body and "guard fd >= 0, write(fd, line, line.count) == line.count else" in body
    # and a listing process that died is a ListingError, never an empty list
    pm = tmp_path / "pm"; pm.mkdir()
    (pm / "swiftpm-xctest-helper").write_text("#!/bin/sh\necho 'Fatal error: cannot record' >&2\nexit 133\n")
    (pm / "swiftpm-xctest-helper").chmod(0o755)
    b = cl.Bundle(tmp_path, tmp_path / cl.BUNDLE, tmp_path / "exe", pm, {"PATH": os.environ["PATH"]})
    with pytest.raises(cl.ListingError, match="exit 133"):
        cl.list_bundle(b)


BARE = textwrap.dedent('''
    import Testing
    import XCTest
    struct BareTests {
        @Test func ratioOfTwoWindows() throws {
            let clock = ContinuousClock()
            let small = try clock.measure { try work(100) }
            let large = try clock.measure { try work(20_000) }
            #expect(large < small * 4, "\\(small) → \\(large)")
        }
        @Test func inlineClock() {
            let start = Date()
            work()
            #expect(Date().timeIntervalSince(start) < 2.0)
        }
        @Test func throughAHelperThatReturnsATime() {
            let d = Self.profile { work() }
            #expect(d.p95 < 60)
        }
        @Test func multiLine() {
            let elapsed = -start.timeIntervalSinceNow
            #expect(
                elapsed < 5.0,
                "took \\(elapsed)")
        }
        @Test func aLowerBoundOnADelayIsOptedOut() {
            let started = ContinuousClock.now
            // quiet-machine: not a budget — a lower bound on a scripted delay
            #expect(ContinuousClock.now - started >= .milliseconds(100))
        }
        @Test func onlyPrintsTheTime() {
            let clock = ContinuousClock()
            let elapsed = clock.measure { work() }
            #expect(rows.count < 10, "in \\(elapsed)")
        }
        @Test func equalityIsNotABudget() {
            let elapsed = clock.measure { work() }
            #expect(elapsed == elapsed)
        }
        @Test func aPollThatReturnsBool() async {
            let ok = await waitUntil { done }
            #expect(ok)
            #expect(count < 3)
        }
        @Test(.tags(.quietMachine)) func markedBare() {
            let elapsed = clock.measure { work() }
            #expect(elapsed < .seconds(1))
        }
        static func ms(_ body: () -> Void) -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            body()
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        }
        static func profile(_ body: () -> Void) -> (cold: Double, p95: Double) { let a = ms(body); return (a, a) }
        func waitUntil(_ c: () -> Bool) async -> Bool { let clock = ContinuousClock(); return clock.now < clock.now }
    }
    final class OldBare: XCTestCase {
        func testBareXCTest() {
            let start = Date()
            let elapsed = -start.timeIntervalSinceNow
            XCTAssertLessThan(elapsed, 5.0, "took \\(elapsed)s")
        }
    }
''')


def test_F4_the_bare_rule_flags_orderings_of_a_clock_reading_and_nothing_else(tmp_path):
    (tmp_path / "BareTests.swift").write_text(BARE)
    bad = cl.check_tags(tmp_path)
    named = sorted(re.search(r"/(\w+) reaches", b).group(1) for b in bad)
    assert named == ["inlineClock", "multiLine", "ratioOfTwoWindows", "testBareXCTest", "throughAHelperThatReturnsATime"], "\n".join(bad)
    by = {re.search(r"/(\w+) reaches", b).group(1): b for b in bad}
    assert "BareTests.swift:9 " in by["ratioOfTwoWindows"] and "(large)" in by["ratioOfTwoWindows"]
    assert f"`// {cl.OPT_OUT} — <why>`" in by["ratioOfTwoWindows"], "the message says how to let a non-budget through"
    assert "inherit QuietMachineXCTestCase" in by["testBareXCTest"]


def test_F4_an_opt_out_is_one_line_and_removing_it_is_red(tmp_path):
    (tmp_path / "BareTests.swift").write_text(BARE.replace("// quiet-machine: not a budget — a lower bound on a scripted delay\n", ""))
    assert any("aLowerBoundOnADelayIsOptedOut" in b for b in cl.check_tags(tmp_path))
    real = [p for p in cl.CORE_TESTS.rglob("*.swift") if cl.OPT_OUT in p.read_text(errors="replace") and p.name != "QuietMachine.swift"]
    assert sorted(p.name for p in real) == ["AudioFingerprintStoreTests.swift", "JobSupervisorScaleTests.swift",
                                             "ScriptedExecutorFidelityTests.swift", "ThrottledMainActorUpdateTests.swift"], \
        "a new opt-out is a reviewed decision: add the file here with it"


def test_F4_the_pure_rules_are_not_judging_helpers_and_their_tests_are_not_marked():
    assert not {"judgeGrowth", "judgeRelative", "debugCeiling"} & set(cl.JUDGING_HELPERS)
    src = (cl.CORE_TESTS / "TimingBudgetTests.swift").read_text()
    for name in ("localCeilingIsTheBudget", "hostedIsTripled", "growthPassesUpToTheLimitAndFailsBeyondIt"):
        i = src.index(f"func {name}(")
        assert ".quietMachine" not in src[src.rindex("@Test", 0, i):i], f"{name} injects every number and measures nothing"


def test_F4_a_mark_in_a_comment_is_not_a_mark(tmp_path):
    (tmp_path / "CommentTests.swift").write_text(textwrap.dedent('''
        // every test here would need .tags(.quietMachine) if it judged time
        import Testing
        struct CommentTests {
            @Test func plain() {}
            /// not marked: see .quietMachine
            @Test func bare() { let e = clock.measure { work() }; #expect(e < .seconds(1)) }
        }
    '''))
    scan = cl.scan_source(tmp_path)
    assert scan.counts == cl.SourceCounts(xctest=0, swift=2, xctest_quiet=0, swift_quiet=0)
    assert len(scan.violations) == 1 and "bare" in scan.violations[0]


def test_F5_the_short_framework_is_named(tmp_path, monkeypatch):
    rc, text = run(tmp_path, monkeypatch, FakeRun(listing(), drop={"testA"}))
    assert rc == cl.EXIT_COUNT and "RED — phase A (parallel, timing not strict): XCTest ran 3 of its 4 tests" in text
    c = counted(PHASE_A_LOG)
    assert (c.xctest_total, c.swift_total, c.total) == (2, 4, 6)


def test_F6_the_glued_line_is_written_as_two_and_both_counters_agree(tmp_path, monkeypatch):
    glued = f"EraAttemptStore: 100 recordsTest Case '-[{M}.OldTests testA]' passed (0.010 seconds)."
    assert cl.unglue(glued) == ["EraAttemptStore: 100 records", f"Test Case '-[{M}.OldTests testA]' passed (0.010 seconds)."]
    clean = f"Test Case '-[{M}.OldTests testA]' failed (1.5 seconds)."
    assert cl.unglue(clean) == [clean]
    # look-alikes are not XCTest verdicts: a Swift Testing line that quotes one, and prose that does not END as one
    for line in (f"✔ Test \"prints Test Case '-[{M}.OldTests testA]' passed (0.010 seconds).\" passed after 0.001 seconds.",
                 f"↳ Test Case '-[{M}.OldTests testA]' passed (0.010 seconds).",
                 f"Test Case '-[{M}.OldTests testA]' passed (0.010 seconds). and then more",
                 "Test Case 'a display name' passed (0.010 seconds)."):
        c = cl.Counts(); c.feed(line)
        assert c.xctest_total == 0 and cl.unglue(line) == [line], line
    # end to end: the lane's log holds the verdict on its own line, so parse_test_counts (anchored) counts it too
    L = listing()

    class Glue(FakeRun):
        def __call__(self, cmd, env):
            proc = super().__call__(cmd, env)
            if cmd[:2] != ["xcrun", "xctest"]:
                return proc
            text = proc.communicate()[0].decode().replace(f"Test Case '-[{M}.OldTests testA]' passed", f"100 recordsTest Case '-[{M}.OldTests testA]' passed")
            return subprocess.Popen([sys.executable, "-c", f"import sys; sys.stdout.write({text!r})"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    rc, text = run(tmp_path, monkeypatch, Glue(L))
    assert rc == cl.EXIT_GREEN, text
    log = tmp_path / "core.log"; log.write_text(text)
    nightly = (ROOT / "scripts" / "nightly_local_tests.sh").read_text()
    fns = "".join(re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", nightly, re.S | re.M).group(0)
                  for name in ("parse_crashed_tests", "parse_test_counts"))
    p = subprocess.run(["bash", "-c", fns + f'\nparse_test_counts "{log}"\necho "$PASSED|$FAILED|$SKIPPED"\n'], capture_output=True, text=True, timeout=60)
    assert p.stdout.strip() == "13|0|0", p.stdout + p.stderr[-300:]


def test_ids_are_escaped_for_both_regex_dialects():
    ident = f"{M}.A/`a test - #1 (x) [y] {{z}} a+b $ ^ | ?*`()/Odd #name - (1).swift:3:6"
    lit = cl.regex_literal(ident)
    assert re.fullmatch(lit, ident)
    assert "\\ " not in lit and "\\#" not in lit and "\\-" not in lit, "only the metacharacters both dialects share are escaped"
    assert re.search(cl.swift_id_regex([ident, "x"]), ident) and not re.search(cl.swift_id_regex([ident]), ident + "0")


# ───────────────────────────── phase B as K serial strands (2026-11-21)

class StrandFake:
    """xctest / swiftpm-testing-helper for strand runs: prints what a real run of the selection prints
    and, when asked for one, writes the Swift Testing event stream (ids, not display names).
    beside: names that fail the FIRST time they run (beside the others) and pass after;
    always: names that fail every time; die / die_always: the process exits 134 on starting that test
    (the first time / every time); mute: names whose failure the event stream does not record.
    budget: the failures are budget judgements — their issue text carries the marker the timing helpers
    write. Without it a failure is a plain wrong value, as any `#expect(a == b)` reports it."""

    def __init__(self, L, beside=(), always=(), die=(), die_always=(), mute=(), exit_after=None, budget=False, also_logic=()):
        self.L, self.beside, self.always = L, set(beside), set(always)
        self.why = f"{cl.BUDGET_MARKER} 31.0 s is over the 30 s budget" if budget else "took too long"
        self.also_logic = set(also_logic)                   # names whose failure has a second, unmarked issue
        self.die, self.die_always, self.mute, self.exit_after = set(die), set(die_always), set(mute), exit_after or {}
        self.seen, self.cmds, self.envs = {}, [], []

    def _fate(self, name):
        n = self.seen[name] = self.seen.get(name, 0) + 1
        if name in self.die_always or (name in self.die and n == 1):
            return "die"
        return "fail" if name in self.always or (name in self.beside and n == 1) else "pass"

    def __call__(self, cmd, env):
        self.envs.append(dict(env))
        what, text, rc = self._xctest(cmd) if cmd[:2] == ["xcrun", "xctest"] else self._swift(cmd)
        rc = self.exit_after.get(what, rc) if rc == 0 else rc
        code = f"import sys; sys.stdout.write({text!r}); sys.exit({rc})"
        return subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def _xctest(self, cmd):
        ran, text, rc = [], "", 0
        for sel in cmd[3].split(","):
            cls, _, method = sel.partition("/")
            ran += [(cls, m) for m in self.L.xctest[f"{M}.{cls}"] if not method or m == method]
        self.cmds.append(("xctest", [f"{c}/{m}" for c, m in ran], cmd))
        for cls, m in ran:
            fate = self._fate(m)
            text += f"Test Case '-[{M}.{cls} {m}]' started.\n"
            if fate == "die":
                return "xctest", text, 134
            if fate == "fail":
                text += f"/x/{cls}.swift:9: error: -[{M}.{cls} {m}] : failed - {self.why}\n"
                if m in self.also_logic:
                    text += f"/x/{cls}.swift:12: error: -[{M}.{cls} {m}] : XCTAssertEqual failed: (\"99999\") is not equal to (\"100000\")\n"
            text += f"Test Case '-[{M}.{cls} {m}]' {'failed' if fate == 'fail' else 'passed'} (0.250 seconds).\n"
            rc = 1 if fate == "fail" else rc
        return "xctest", text, rc

    def _selected(self, cmd):
        ids = self.L.swift
        for flag, keep in (("--filter", True), ("--skip", False)):
            if flag in cmd:
                rx = re.compile(cmd[cmd.index(flag) + 1])
                ids = [i for i in ids if bool(rx.search(i)) == keep]
        return ids

    def _swift(self, cmd):
        ids, text, rc, events, clock = self._selected(cmd), "", 0, [], 100.0
        self.cmds.append(("swift", ids, cmd))
        for i in ids:
            name = i.split("/")[-2]
            fate = self._fate(name)
            text += f"◇ Test {name} started.\n"
            events.append({"kind": "testStarted", "testID": i, "instant": {"absolute": clock}})
            if fate == "die":
                rc = 134
                break
            clock += 2.0
            if fate == "fail":
                text += f"✘ Test {name} recorded an issue at X.swift:1:1: Expectation failed: {self.why}\n"
                if name in self.also_logic:
                    text += f"✘ Test {name} recorded an issue at X.swift:2:1: Expectation failed: (rows.count → 99999) == 100000\n"
                text += f"✘ Test {name} failed after 2.000 seconds with 1 issue.\n"
                if name not in self.mute:
                    events.append({"kind": "issueRecorded", "testID": i, "issue": {"isKnown": False, "isFailure": True}})
                rc = 1
            else:
                text += f"✔ Test {name} passed after 2.000 seconds.\n"
            events.append({"kind": "testEnded", "testID": i, "instant": {"absolute": clock}})
        if rc != 134:
            text += f"{'✘' if rc else '✔'} Test run with {len(ids)} tests in 1 suite {'failed' if rc else 'passed'} after 0.1 seconds.\n"
        if "--event-stream-output-path" in cmd:
            torn = '{"kind": "event", "payload": {"kind": "testEn' if rc == 134 else ""          # a process that died mid-write
            Path(cmd[cmd.index("--event-stream-output-path") + 1]).write_text(
                "".join(json.dumps({"kind": "event", "payload": e, "version": "6.4.0"}) + "\n" for e in events) + torn)
        return "swift", text, rc


def strands_listing():
    """listing() plus more quiet tests, so four strands each have work: 6 quiet XCTest in 3 classes, 7 quiet Swift."""
    L = listing()
    L.xctest[f"{M}.MemTests"] = ["testResident", "testGrowth"]
    L.xctest[f"{M}.ClockTests"] = ["testBudgetA", "testBudgetB"]
    L.xctest_quiet |= {f"{M}.MemTests", f"{M}.ClockTests"}
    more = [fn("TimingTests", f"budget{n}", line=20 + n) for n in range(4)]
    L.swift += more
    L.swift_quiet |= set(more)
    return L


def run_strands(tmp_path, monkeypatch, fake, jobs=4, regex=None, environ=None, timings=None):
    monkeypatch.setattr(cl, "open_bundle", lambda products: fake_bundle(tmp_path, environ))
    out = io.StringIO()
    rc = cl.run_lane(str(tmp_path), regex, cl.Output(out), spawn=fake, lister=lambda b: fake.L,
                     quiet_jobs=jobs, timings=timings)
    return rc, out.getvalue()


def nightly_counts(tmp_path, text):
    """The nightly's own parse_test_counts on the lane's output: (passed, failed, skipped, failed names json)."""
    log = tmp_path / "lane-output.log"
    log.write_text(text)
    nightly = (ROOT / "scripts" / "nightly_local_tests.sh").read_text()
    fns = "".join(re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", nightly, re.S | re.M).group(0)
                  for name in ("parse_crashed_tests", "parse_test_counts"))
    script = fns + f'\nparse_test_counts "{log}"\necho "$PASSED|$FAILED|$SKIPPED|$FAILED_NAMES_JSON"\n'
    p = subprocess.run(["bash", "-c", script], capture_output=True, text=True, timeout=60)
    passed, failed, skipped, names = p.stdout.strip().split("|", 3)
    return int(passed), int(failed), int(skipped), json.loads(names)


def phase_b_work(fake):
    """(XCTest tests, Swift ids) each phase-B process was given, strands first (they carry `--event-stream…`
    or are XCTest in the serial phase); phase A's processes are left out."""
    quiet_cls = {c.split(".", 1)[1] for c in fake.L.xctest_quiet}
    return [(what, sel) for what, sel, cmd in fake.cmds
            if (what == "swift" and "--no-parallel" in cmd) or (what == "xctest" and sel and sel[0].split("/")[0] in quiet_cls)]


def test_strands_the_default_is_min_4_and_a_quarter_of_the_cores():
    assert [cl.default_quiet_jobs(n, 96) for n in (30, 16, 12, 10, 8, 4, 2, 1)] == [4, 4, 3, 2, 2, 1, 1, 1]


@pytest.mark.parametrize("jobs", [1, 2, 3, 4, 6, 50])
def test_strands_the_deal_covers_every_quiet_test_exactly_once_and_is_deterministic(jobs):
    _, b = cl.plan_phases(strands_listing(), None)
    units = cl.quiet_units(b)
    assert sum(u.count for u in units) == b.expected == 13
    dealt = cl.deal(units, jobs, {})
    assert len(dealt) == min(jobs, len(units)) and all(dealt), "never an empty strand, never more strands than units"
    flat = [u for s in dealt for u in s]
    assert sorted(u.key for u in flat) == sorted(u.key for u in units) and len(flat) == len(set(flat))
    assert sorted(t for u in flat for t in u.tests) == sorted(b.xctest_tests)
    assert sorted(u.selectors[0] for u in flat if u.kind == "swift") == sorted(b.swift)
    assert dealt == cl.deal(list(reversed(units)), jobs, {}), "the deal does not depend on the order it is handed"


def test_strands_the_deal_is_longest_first_by_recorded_seconds_to_the_lightest_strand():
    L = strands_listing()
    _, b = cl.plan_phases(L, None)
    units = cl.quiet_units(b)
    key = lambda name: next(u.key for u in units if name in u.key)
    seconds = {u.key: 1.0 for u in units}
    seconds[key("load100k")], seconds[key("import100k")] = 300.0, 200.0
    dealt = cl.deal(units, 2, seconds)
    assert dealt[0][0].key == key("load100k") and dealt[1][0].key == key("import100k"), "the two long tests lead different strands"
    load = [sum(seconds[u.key] for u in s) for s in dealt]
    assert load == [300.0, 208.0], "everything else goes to the lighter strand until it catches up"
    assert "swift:" + f"{M}.ScaleTests/load100k()" == key("load100k"), "the cache key has no line number"
    # a filter that leaves part of a class: the unit names its methods
    _, part = cl.plan_phases(L, r"PerfTests/testMemory$|TimingTests")
    assert [u.selectors for u in cl.quiet_units(part) if u.kind == "xctest"] == [("PerfTests/testMemory",)]


def test_strands_green_every_test_one_verdict_each_strand_serial_strict_and_told_it_is_the_serial_phase(tmp_path, monkeypatch):
    fake = StrandFake(strands_listing())
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=4, environ={"PATH": os.environ["PATH"], cl.STRICT_KEY: "1"})
    assert rc == 0, text
    assert "core-lane: phase B runs as 4 serial strands (--quiet-jobs 4)" in text
    assert "phase B (serial, quiet machine, strict): 13 passed / 0 failed / 0 skipped — 13 of 13 planned" in text
    assert "4 strands, 0 passed alone after failing beside the others" in text and "AMBER" not in text
    assert "total 21 passed / 0 failed / 0 skipped — 21 of 21 planned" in text and "→ GREEN" in text
    work = phase_b_work(fake)
    assert len([w for w in work if w[0] == "swift"]) == 4, "one Swift Testing process per strand, no alone pass"
    ran = [t for _, sel in work for t in sel]
    _, b = cl.plan_phases(fake.L, None)
    assert sorted(ran) == sorted([f"{c}/{m}" for c, m in b.xctest_tests] + b.swift), "every quiet test ran exactly once"
    for (what, sel, cmd), env in zip(fake.cmds, fake.envs):
        if (what, sel) in work:
            assert env[cl.PHASE_KEY] == "serial" and env[cl.STRICT_KEY] == "1"
            if what == "swift":
                assert "--no-parallel" in cmd and cmd[cmd.index("--event-stream-version") + 1] == cl.EVENT_STREAM_VERSION
        else:
            assert env[cl.PHASE_KEY] == "parallel" and cl.STRICT_KEY not in env
    assert nightly_counts(tmp_path, text) == (21, 0, 0, []), "the nightly's parser reads the same totals"


@pytest.mark.parametrize("name, shown", [("load100k()", f"{M}.ScaleTests/load100k()"), ("testMemory", "PerfTests/testMemory")])
def test_strands_a_test_that_fails_beside_the_others_and_passes_alone_is_green_and_named(tmp_path, monkeypatch, name, shown):
    fake = StrandFake(strands_listing(), beside={name}, budget=True)
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=4)
    assert rc == 0, text
    assert re.search(r"core-lane: strand \d: failed beside the other strands — to be run again alone: .*" + re.escape(name), text)
    assert "every strand has ended; running 1 test(s) again ALONE" in text
    assert f"core-lane: AMBER — phase B (serial, quiet machine): passed alone after failing beside 3 other strands: {shown}" in text
    assert "13 passed / 0 failed / 0 skipped — 13 of 13 planned" in text and "4 strands, 1 passed alone" in text
    assert "→ GREEN" in text and "RED" not in text
    assert fake.seen[name] == 2 and all(n == 1 for k, n in fake.seen.items() if k != name), "only the failed test ran again"
    alone = phase_b_work(fake)[-1]
    assert len(alone[1]) == 1 and name.rstrip("()") in alone[1][0], "the alone pass is that one test, by itself"
    c = counted(text)
    assert (c.passed, c.failed, c.total) == (21, 0, 21), "the withheld failing line is not a second verdict"
    assert nightly_counts(tmp_path, text) == (21, 0, 0, []), "nor for the nightly's parser"


@pytest.mark.parametrize("name, console", [("load100k()", "load100k()"), ("testMemory", f"-[{M}.PerfTests testMemory]")])
def test_strands_a_test_that_fails_beside_the_others_and_alone_is_red_by_name_and_counted_once(tmp_path, monkeypatch, name, console):
    fake = StrandFake(strands_listing(), always={name}, budget=True)
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=4)
    assert rc == cl.EXIT_FAILED, text
    assert f"core-lane: RED — phase B (serial, quiet machine): FAILED {console} — failed when run ALONE too" in text
    assert "12 passed / 1 failed / 0 skipped — 13 of 13 planned" in text and "0 passed alone" in text and "AMBER" not in text
    assert fake.seen[name] == 2
    assert nightly_counts(tmp_path, text) == (20, 1, 0, [console]), "one FAILED line, not two"


def test_strands_a_strand_that_dies_is_red_by_its_exit_and_its_unfinished_tests_still_get_one_verdict_each(tmp_path, monkeypatch):
    L = strands_listing()
    fake = StrandFake(L, die={"budget1()"})
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=2)
    assert rc == cl.EXIT_FAILED, text
    assert re.search(r"RED — phase B \(serial, quiet machine\): strand \d Swift Testing exited 134 with no failed test", text)
    dead = next(sel for what, sel in phase_b_work(fake) if what == "swift" and fn("TimingTests", "budget1", line=21) in sel)
    unfinished = dead[dead.index(fn("TimingTests", "budget1", line=21)):]
    assert f"running {len(unfinished)} test(s) again ALONE" in text
    for ident in unfinished:
        assert re.search(r"AMBER — phase B \(serial, quiet machine\): passed alone after strand \d's Swift Testing process ended "
                         r"\(exit 134\) before it finished: " + re.escape(cl.swift_name(ident)), text), ident
    assert "13 passed / 0 failed / 0 skipped — 13 of 13 planned" in text, "never lost: every test has its verdict"
    finished_before = dead[:dead.index(fn("TimingTests", "budget1", line=21))]
    assert all(fake.seen[i.split("/")[-2]] == 1 for i in finished_before), "a test that had its verdict is not run again"
    assert nightly_counts(tmp_path, text)[:3] == (21, 0, 0)
    # the same for an XCTest process
    fake = StrandFake(L, die={"testGrowth"})
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=2)
    assert rc == cl.EXIT_FAILED and "13 of 13 planned" in text, text
    assert re.search(r"RED — .*strand \d XCTest exited 134", text)
    assert fake.seen["testResident"] == 1 and fake.seen["testGrowth"] == 2


def test_strands_a_test_that_kills_its_process_alone_too_is_red_by_name_and_the_rest_still_run(tmp_path, monkeypatch):
    L = strands_listing()
    fake = StrandFake(L, die_always={"budget1()"})
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=2)
    assert rc == cl.EXIT_FAILED, text
    assert re.search(r"RED — phase B \(serial, quiet machine\): Swift Testing \(alone\) died \(exit 134\) while running "
                     + re.escape(f"{M}.TimingTests/budget1()"), text)
    assert "RED — phase B (serial, quiet machine): Swift Testing ran 6 of its 7 tests" in text, "the missing verdict is counted as missing"
    assert "12 passed / 0 failed / 0 skipped — 12 of 13 planned" in text
    others = [k for k in fake.seen if k != "budget1()"]
    assert all(fake.seen[k] >= 1 for k in others) and len(fake.seen) == 21, "every other test still got its turn"
    assert fake.seen["budget1()"] == 2, "beside, then alone: not a third time"


def test_strands_failures_the_event_stream_does_not_name_are_not_guessed_at_they_stand(tmp_path, monkeypatch):
    fake = StrandFake(strands_listing(), beside={"load100k()"}, mute={"load100k()"}, budget=True)
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=4)
    assert rc == cl.EXIT_FAILED, text
    assert re.search(r"RED — phase B \(serial, quiet machine\): strand \d Swift Testing printed 1 failed test\(s\) but its event stream "
                     r"names 0: they could not be run again alone and stand as failed", text)
    assert "RED — phase B (serial, quiet machine): FAILED load100k()\n" in text, "no claim that it failed alone"
    assert fake.seen["load100k()"] == 1 and "12 passed / 1 failed / 0 skipped — 13 of 13 planned" in text
    assert nightly_counts(tmp_path, text) == (20, 1, 0, ["load100k()"])


def test_strands_a_process_that_exits_nonzero_with_every_test_judged_and_none_failed_is_red_as_in_one_pass(tmp_path, monkeypatch):
    fake = StrandFake(strands_listing(), exit_after={"swift": 134})
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=2)
    assert rc == cl.EXIT_FAILED
    assert re.search(r"RED — phase B \(serial, quiet machine\): strand \d Swift Testing exited 134 with no failed test", text)


def test_strands_quiet_jobs_1_runs_exactly_the_commands_of_the_single_serial_pass(tmp_path, monkeypatch):
    L = strands_listing()
    today, one = StrandFake(L), StrandFake(L)
    monkeypatch.setattr(cl, "open_bundle", lambda products: fake_bundle(tmp_path))
    out_today, out_one = io.StringIO(), io.StringIO()
    assert cl.run_lane(str(tmp_path), None, cl.Output(out_today), spawn=today, lister=lambda b: L) == 0
    assert cl.run_lane(str(tmp_path), None, cl.Output(out_one), spawn=one, lister=lambda b: L, quiet_jobs=1,
                       timings=tmp_path / "t.json") == 0
    key = lambda c: (c[0], c[2])
    assert sorted(map(key, one.cmds), key=str) == sorted(map(key, today.cmds), key=str), "argument for argument"
    _, b = cl.plan_phases(L, None)
    bd = fake_bundle(tmp_path)
    assert [c[2] for c in one.cmds if "--no-parallel" in c[2]] == [dict(cl.phase_commands(bd, b, None))["Swift Testing"]]
    assert not any("--event-stream-output-path" in c[2] for c in one.cmds) and not (tmp_path / "t.json").exists()
    # phase A's two processes interleave as they please: compare the lines, not their order
    strip = lambda t: sorted(re.sub(r"\d+ s", "N s", t).splitlines())
    assert strip(out_one.getvalue()) == strip(out_today.getvalue()), "and line for line the same output"
    assert "strand" not in out_one.getvalue()
    # one unit only: nothing to run side by side, so it is the single pass whatever K says
    solo = StrandFake(L)
    rc, text = run_strands(tmp_path, monkeypatch, solo, jobs=4, regex=r"ScaleTests/load100k")
    assert rc == 0 and "strand" not in text and not any("--event-stream-output-path" in c[2] for c in solo.cmds)


def test_strands_the_cli_passes_quiet_jobs_and_the_cache_and_defaults_to_the_machines_k(tmp_path, monkeypatch):
    seen = {}
    monkeypatch.setattr(cl, "run_lane", lambda products, regex, out, **kw: seen.update(kw) or 0)
    monkeypatch.setenv(cl.QUIET_TIMINGS_KEY, str(tmp_path / "cache.json"))
    tests = str(cl.CORE_TESTS)
    assert cl.main(["run", "--products", str(tmp_path), "--tests", tests, "--quiet-jobs", "1"]) == 0
    assert seen["quiet_jobs"] == 1 and seen["timings"] == tmp_path / "cache.json"
    assert cl.main(["run", "--products", str(tmp_path), "--tests", tests]) == 0
    assert seen["quiet_jobs"] == cl.default_quiet_jobs()
    assert cl.main(["run", "--products", str(tmp_path), "--tests", tests, "--quiet-jobs", "6"]) == 0 and seen["quiet_jobs"] == 6
    with pytest.raises(SystemExit):
        cl.main(["run", "--products", str(tmp_path), "--tests", tests, "--quiet-jobs", "0"])
    assert cl.strand_options(None, {}) == (cl.default_quiet_jobs(), cl.DEFAULT_QUIET_TIMINGS)
    assert cl.strand_options(3, {cl.QUIET_TIMINGS_KEY: "/x/t.json"}, mem_gb=64) == (3, Path("/x/t.json"))
    assert cl.DEFAULT_QUIET_TIMINGS.name == "videoscan-core-quiet-timings.json"


def test_strands_measured_seconds_are_remembered_per_build_flavour_and_shape_the_next_deal(tmp_path, monkeypatch):
    L = strands_listing()
    cache = tmp_path / "timings.json"
    rc, _ = run_strands(tmp_path, monkeypatch, StrandFake(L), jobs=2, timings=cache)
    assert rc == 0
    saved = json.loads(cache.read_text())
    flavour = tmp_path.name.lower()
    assert saved[f"{flavour}|swift:{M}.ScaleTests/load100k()"] == 2.0, "from the event stream's instants"
    assert saved[f"{flavour}|xctest:PerfTests"] == 0.5, "a class weighs the sum of its tests' own seconds"
    assert len(saved) == 3 + 7 and all(k.startswith(flavour + "|") for k in saved)
    # a recorded long test leads its strand on the next run, and another flavour's numbers are not read
    saved[f"{flavour}|swift:{M}.TimingTests/budget3()"] = 500.0
    saved[f"other|swift:{M}.TimingTests/budget0()"] = 9000.0
    cache.write_text(json.dumps(saved))
    fake = StrandFake(L)
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=2, timings=cache)
    assert rc == 0
    firsts = [sel[0] for what, sel in phase_b_work(fake) if what == "swift"]
    assert fn("TimingTests", "budget3", line=23) in firsts and fn("TimingTests", "budget0", line=20) not in firsts
    assert re.search(r"strand 1: \d+ tests, ~500 s recorded", text)
    assert json.loads(cache.read_text())[f"other|swift:{M}.TimingTests/budget0()"] == 9000.0, "the other flavour's record is kept"


def test_strands_the_event_stream_parse_reads_ids_failures_and_seconds_and_skips_a_torn_line(tmp_path):
    a, b, c = fn("S", "a"), fn("S", "b"), fn("S", "c")
    ev = lambda kind, ident, at=None, **more: json.dumps({"kind": "event", "version": "6.4.0", "payload": dict(
        {"kind": kind, "testID": ident}, **({"instant": {"absolute": at}} if at is not None else {}), **more)})
    stream = tmp_path / "e.jsonl"
    stream.write_text("\n".join([
        rec("function", a),                                                       # the listing records come first: not events
        ev("testStarted", f"{M}.S", 1.0), ev("testStarted", a, 1.0),
        ev("issueRecorded", a, issue={"isKnown": True, "isFailure": False}), ev("testEnded", a, 4.5),
        ev("testStarted", b, 5.0), ev("issueRecorded", b, issue={"isKnown": False, "isFailure": True}), ev("testEnded", b, 6.0),
        ev("testSkipped", "other"), ev("testStarted", c, 7.0),
        '{"kind": "event", "payload": {"kind": "testEnded", "testID": "' + c[:10]]))
    started, ended, failed, seconds = cl.parse_event_stream(stream, {a, b, c})
    assert started == {a, b, c} and ended == {a, b} and failed == {b}, "a known issue is not a failure; c never ended"
    assert seconds == {a: 3.5, b: 1.0}
    assert cl.parse_event_stream(tmp_path / "missing.jsonl", {a}) == (set(), set(), set(), {})


def test_strands_the_nightly_logs_the_amber_lines_and_the_decision_is_recorded():
    nightly = (ROOT / "scripts" / "nightly_local_tests.sh").read_text()
    assert "'^core-lane: (phase [AB] \\(.*planned, |total |RED |AMBER |stopped )'" in nightly
    decisions = (ROOT / "docs" / "DECISIONS.md").read_text()
    assert "2026-11-21 — The Core lane's quiet-machine phase runs as K serial strands; only a BUDGET miss earns a run alone" in decisions
    assert '"core_amber_count": len(amber), "core_amber_names": amber' in nightly
    assert "AMBER (`core_amber_names`" in (ROOT / "docs" / "BACKLOG.md").read_text()


# ───────────────────────────── review of 9148e09dc (2026-11-21): the reviewer's red tests, then what the fixes add

class CrashAfterAFailure(StrandFake):
    """A strand process in which one test fails beside the others AND which then dies (SIGABRT, 134) after
    its last verdict — a trap in a detached task, an atexit handler. Alone, the test passes and exits 0."""
    def __call__(self, cmd, env):
        self.envs.append(dict(env))
        what, text, rc = self._xctest(cmd) if cmd[:2] == ["xcrun", "xctest"] else self._swift(cmd)
        rc = 134 if rc == 1 else rc
        code = f"import sys; sys.stdout.write({text!r}); sys.exit({rc})"
        return subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


@pytest.mark.parametrize("budget", [False, True])
@pytest.mark.parametrize("name", ["load100k()", "testMemory"])
def test_R1_a_strand_that_crashed_is_not_explained_away_by_a_test_that_failed_in_it(tmp_path, monkeypatch, name, budget):
    fake = CrashAfterAFailure(strands_listing(), beside={name}, budget=budget)
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=4)
    assert "exited 134" in text and rc == cl.EXIT_FAILED, "a process that died with 134 is RED whatever else failed in it:\n" + text[-900:]
    if budget:
        assert fake.seen[name] == 2 and "13 of 13 planned" in text, "the budget miss still gets its run alone, and one verdict"


class NoStream(StrandFake):
    """The helper runs and prints every verdict but its event stream never reaches the disk."""
    def _swift(self, cmd):
        return super()._swift([c for c in cmd if c != "--event-stream-output-path"])


def test_R2_a_green_strand_whose_event_stream_is_missing_does_not_run_and_count_every_test_twice(tmp_path, monkeypatch):
    fake = NoStream(strands_listing())
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=2)
    c = counted(text)
    assert c.total == 21, f"each planned test has ONE verdict line; got {c.total}:\n" + text[-700:]
    assert rc == 0 and "event stream missing — its " in text and "again ALONE" not in text
    assert all(n == 1 for n in fake.seen.values())


def test_R2_a_missing_event_stream_on_a_strand_that_failed_is_red_and_still_counts_once(tmp_path, monkeypatch):
    fake = NoStream(strands_listing(), beside={"load100k()"}, budget=True)
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=2)
    assert rc == cl.EXIT_FAILED and counted(text).total == 21, text[-700:]
    assert "left no event stream: which tests failed or never finished cannot be told" in text
    assert "RED — phase B (serial, quiet machine): FAILED load100k()\n" in text and fake.seen["load100k()"] == 1


def test_R3_the_default_k_fits_the_machines_memory(capsys):
    import inspect
    assert "mem" in inspect.signature(cl.default_quiet_jobs).parameters
    assert [cl.default_quiet_jobs(30, m) for m in (96, 64, 32, 24, 16, 8, 4)] == [4, 4, 4, 3, 2, 1, 1]
    assert cl.default_quiet_jobs(10, 64) == 2, "the smaller of the two bounds"
    assert cl.strand_options(6, {}, mem_gb=96)[0] == 6 and cl.strand_options(6, {}, mem_gb=16)[0] == 2, "an asked-for K is capped too"
    assert cl.memory_cap(4, 4) == 1, "never zero"
    assert (cl.physical_memory_gb() or 0) >= 8, "this Mac's memory is readable"
    with pytest.raises(SystemExit):
        cl.main(["run", "--help"])
    assert "never more than physical memory / 8 GB" in " ".join(capsys.readouterr().out.split()), "--help says so"


def test_R4_view_a_failure_that_is_not_a_timing_budget_is_not_given_a_second_run(tmp_path, monkeypatch):
    fake = StrandFake(strands_listing(), beside={"load100k()"})
    orig = fake._swift
    def swift(cmd):
        what, text, rc = orig(cmd)
        return what, text.replace("Expectation failed: took too long", "Expectation failed: (rows.count → 99999) == 100000"), rc
    fake._swift = swift
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=4)
    assert rc != 0, "a wrong row count that happens once in two runs is a flaky data bug, reported GREEN/AMBER:\n" + text[-500:]


@pytest.mark.parametrize("name, console, mixed", [
    ("load100k()", "load100k()", False), ("testMemory", f"-[{M}.PerfTests testMemory]", False),
    ("load100k()", "load100k()", True), ("testMemory", f"-[{M}.PerfTests testMemory]", True)])
def test_strands_only_a_budget_judgement_earns_a_run_alone(tmp_path, monkeypatch, name, console, mixed):
    """A wrong value — alone, or beside a budget miss in the same test — is RED at once, as in the single pass."""
    fake = StrandFake(strands_listing(), beside={name}, budget=mixed, also_logic={name} if mixed else ())
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=4)
    assert rc == cl.EXIT_FAILED, text[-600:]
    assert fake.seen[name] == 1, "no second run"
    assert f"RED — phase B (serial, quiet machine): FAILED {console} — not a budget judgement: no second run" in text
    assert re.search(r"core-lane: strand \d: not a budget judgement \(no \[quiet-budget\] in every issue\) — no second run: " + re.escape(console), text)
    assert "12 passed / 1 failed / 0 skipped — 13 of 13 planned" in text and "AMBER" not in text and "again ALONE" not in text
    assert nightly_counts(tmp_path, text) == (20, 1, 0, [console])


def test_strands_each_failure_says_which_kind_it_was(tmp_path, monkeypatch):
    """One run: a budget miss that fails alone too, and a budget miss that passes alone — the suffix is per failure."""
    fake = StrandFake(strands_listing(), beside={"budget0()"}, always={"load100k()"}, budget=True)
    rc, text = run_strands(tmp_path, monkeypatch, fake, jobs=4)
    assert rc == cl.EXIT_FAILED
    assert "FAILED load100k() — failed when run ALONE too" in text
    assert f"AMBER — phase B (serial, quiet machine): passed alone after failing beside 3 other strands: {M}.TimingTests/budget0()" in text
    assert "12 passed / 1 failed / 0 skipped — 13 of 13 planned" in text and "1 passed alone" in text


def test_strands_the_marker_is_the_one_the_swift_helpers_write():
    src = (cl.CORE_TESTS / "QuietMachine.swift").read_text()
    assert f'let quietBudgetMarker = "{cl.BUDGET_MARKER}"' in src
    for name in ("TimingBudgetExpectations.swift", "TimingBudgetXCTestSupport.swift"):
        assert "quietBudgetMarker" in (cl.CORE_TESTS / name).read_text(), name
    assert {"expectBudget", "XCTAssertBudget"} <= set(cl.JUDGING_HELPERS), "a test that calls them must carry the mark"


def test_the_core_bundle_runs_with_a_sealed_home_never_the_real_one(tmp_path):
    # DECISIONS 2026-11-22: tests never open the real catalog. Core tests that resolve App Support,
    # Logs or Preferences through FileManager land in a scratch home made for this run.
    exe = tmp_path / "products" / cl.BUNDLE / "Contents" / "MacOS" / "VideoScanCoreTests"
    exe.parent.mkdir(parents=True)
    exe.write_text("")
    real = os.path.expanduser("~")
    b = cl.open_bundle(str(tmp_path / "products"), {"HOME": real, "PATH": "/usr/bin:/bin"})
    home = b.env["HOME"]
    # a run's scratch home may sit under ~/Library/Caches (run_tests' runs); never under the real App Support,
    # Logs or Preferences (2026-11-23: '~/Library' was too strict — red inside a real run_tests smoke)
    assert home == b.env["CFFIXED_USER_HOME"] and home != real, b.env
    assert not any(home.startswith(os.path.join(real, "Library", sub)) for sub in ("Application Support", "Logs", "Preferences"))
    assert os.path.isdir(os.path.join(home, "Library", "Application Support")), "the sealed home is not prepared"
    assert b.env["TMPDIR"] == b.env["VIDEOSCAN_TEST_TMP"] == os.path.join(home, "tmp") + "/" and os.path.isdir(b.env["TMPDIR"]), \
        "Core test processes use the system temp dir (2026-11-23: tests' leftovers outlived the run)"
    assert b.env["PATH"] == "/usr/bin:/bin", "the rest of the caller's environment is kept"
