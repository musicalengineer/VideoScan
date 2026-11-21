"""scripts/core_lane.py — the VideoScanCore lane in two phases (2026-11-20).

Phase A: every test not marked quiet-machine, in parallel, timing not strict.
Phase B: the marked ones, serial, VIDEOSCAN_TIMING_STRICT as the caller set it.
Pinned here, with fake test processes (real pipes, no build):

  logic      the listing → the split (a suite's tag reaches its tests, an XCTest
             class is whole), the filter, the commands of each phase, the counts
  truth      the summary's numbers are the lines the children printed, by the
             nightly's own counting rules (the same fixture, both parsers)
  isolation  a listing without tags, a phase that ran zero / fewer / more than
             its plan, a child that died, a failure in each phase: RED, by phase
  scale      100k tests: plan and count inside a budget
  sensor     the real tree: every test that reaches a timing or resident-size
             helper carries the mark; an unmarked one is named

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
    assert a.xctest == [f"{M}.OldTests", f"{M}.MoreTests"] and b.xctest == [f"{M}.PerfTests"]


def test_a_filter_narrows_both_phases_and_a_part_class_is_named_by_method():
    L = listing()
    a, b = cl.plan_phases(L, r"(\.|/)(StoreTests|PerfTests)/")
    assert (a.xctest, a.xctest_count) == ([], 0) and len(a.swift) == 3
    assert b.xctest == [f"{M}.PerfTests"] and b.swift == [fn("StoreTests", "hundredThousandWithinBudget")]
    a, b = cl.plan_phases(L, r"OldTests/testA$|PerfTests/testMemory$")
    assert a.xctest == [f"{M}.OldTests/testA"] and b.xctest == [f"{M}.PerfTests/testMemory"]
    assert (a.expected, b.expected) == (1, 1)


def fake_bundle(tmp_path, environ=None):
    return cl.Bundle(tmp_path, tmp_path / cl.BUNDLE, tmp_path / "exe", tmp_path / "pm",
                     dict(environ if environ is not None else {"PATH": os.environ["PATH"]}))


def test_phase_a_runs_both_frameworks_at_once_skipping_the_quiet_ids_and_phase_b_serializes(tmp_path):
    L = listing()
    a, b = cl.plan_phases(L, None)
    bd = fake_bundle(tmp_path)
    ca = dict(cl.phase_commands(bd, a, None))
    assert ca["XCTest"][:3] == ["xcrun", "xctest", "-XCTest"] and ca["XCTest"][3] == f"{M}.OldTests,{M}.MoreTests"
    st = ca["Swift Testing"]
    assert "--no-parallel" not in st and "--filter" not in st
    skip = re.compile(st[st.index("--skip") + 1])
    assert all(skip.search(i) for i in L.swift_quiet) and not any(skip.search(i) for i in a.swift)
    cb = dict(cl.phase_commands(bd, b, None))
    assert cb["XCTest"][3] == f"{M}.PerfTests"
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


def run(tmp_path, monkeypatch, fake, regex=None, environ=None, lister=None):
    L = fake.L
    monkeypatch.setattr(cl, "open_bundle", lambda products: fake_bundle(tmp_path, environ))
    out = io.StringIO()
    rc = cl.run_lane(str(tmp_path), regex, cl.Output(out), spawn=fake, lister=lister or (lambda b: L))
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
    assert "RED — phase B (serial, quiet machine): ran ZERO of its 5 tests" in text
    assert "phase A (parallel, timing not strict): 8 passed" in text, "phase A's green does not cover phase B"


def test_a_phase_that_ran_fewer_or_more_than_its_plan_is_red(tmp_path, monkeypatch):
    rc, text = run(tmp_path, monkeypatch, FakeRun(listing(), drop={"roundTrip()"}))
    assert rc == cl.EXIT_COUNT and "RED — phase A (parallel, timing not strict): ran 7 of its 8 tests" in text
    rc, text = run(tmp_path, monkeypatch, FakeRun(listing(), extra="✔ Test unlisted() passed after 0.001 seconds.\n"))
    assert rc == cl.EXIT_COUNT and "ran 9 of its 8 tests" in text and "ran 4 of its 3" not in text.replace("5 tests", "")


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
    assert rc == cl.EXIT_COUNT and "lists ZERO tests" in text


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
