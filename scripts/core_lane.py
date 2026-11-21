#!/usr/bin/env python3
"""core_lane.py — the VideoScanCore package tests in TWO PHASES (2026-11-20).

Rick, 2026-11-20: "we do not want to serialize when we can parallelize". The
Core lane ran every test one at a time (`swift test --no-parallel`, 16–19 min)
because a handful of them judge wall time or resident size and need a quiet
machine (GH #208). Now:

  phase A — every test NOT marked quiet-machine, in parallel (Swift Testing's
            in-process parallelism; the XCTest classes in their own process
            beside it), VIDEOSCAN_TIMING_STRICT removed from the environment;
  phase B — only the marked tests, one at a time (`--no-parallel`), with
            VIDEOSCAN_TIMING_STRICT exactly as the caller set it.

The mark is declared AT THE TEST (Tests/VideoScanCoreTests/QuietMachine.swift:
`.tags(.quietMachine)`, or the XCTest base class QuietMachineXCTestCase) and
read here from the BUILT bundle, never from a list in a script:
  * Swift Testing: `swiftpm-testing-helper --list-tests --event-stream-version
    6.4` writes one JSON record per test and suite with its `tags`; a suite's
    tag applies to every test under it;
  * XCTest: the listing (swiftpm-xctest-helper) runs with
    VIDEOSCAN_QUIET_XCTEST_LIST=<file>; each QuietMachineXCTestCase subclass
    writes its name there.

Why the built bundle and not `swift test --parallel`: (1) exact counts — this
route prints one terminal line per test for both frameworks, the lines the
nightly and run_tests.py already count, while `swift test --parallel` folds
XCTest into a progress line; (2) the split needs the listing before anything
runs, and the listing comes from the same binary that then runs; (3) no
SwiftPM .build lock, so two runs at one commit go side by side (run_tests.py).

Counts: each phase's plan is the listing (after `--filter`); each phase must
run exactly its plan. A phase that planned tests and ran none, ran fewer, or
ran more is RED, and every failure line names its phase. The lane's totals
are the sum of the two.

Usage:
  core_lane.py run --package-path <VideoScanCore> [-c debug|release]
                   [--scratch-path <dir>] [--skip-build] [--filter <regex>]
  core_lane.py run --products <dir with VideoScanCoreTests.xctest> [--filter <regex>]
  core_lane.py list --products <dir>        # the quiet-machine tests, from the bundle
  core_lane.py check [--tests <dir>]        # source pin: a test that reaches a timing /
                                            # resident-size helper carries the mark
Exit: 0 green; 1 a test failed or a child exited non-zero; 2 a phase's count is
not its plan (or nothing could be listed); 3 the build failed.

Memory: this script holds the two listings (a few thousand short records) and
one output line at a time; test output is streamed, never held. The test
processes: phase A's Swift Testing process runs ~2,400 tests on every core at
once — its peak resident size is printed on the total line (ru_maxrss of the
children; 2026-11-20, Release, the Ultra: see the commit); phase B is one test
at a time in one process, as the serial lane always was (its 100k import is
the largest: ~7.5 GB resident at its peak).
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import resource
import signal
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, IO, List, Optional, Sequence, Set, Tuple

STRICT_KEY = "VIDEOSCAN_TIMING_STRICT"
QUIET_TAG = "quietMachine"
XCTEST_LIST_KEY = "VIDEOSCAN_QUIET_XCTEST_LIST"
BUNDLE = "VideoScanCoreTests.xctest"
EVENT_STREAM_VERSION = "6.4"            # the first whose test records carry `tags`
NO_TEST_MATCHED = 69                    # swiftpm-testing-helper: the filter matched nothing (EX_UNAVAILABLE)

EXIT_GREEN, EXIT_FAILED, EXIT_COUNT, EXIT_BUILD = 0, 1, 2, 3


# ───────────────────────────────────────────────────────────── the bundle and its tools

@dataclass
class Bundle:
    products: Path
    bundle: Path
    exe: Path
    pm: Path                             # <toolchain>/usr/libexec/swift/pm
    env: Dict[str, str]                  # the caller's environment + what the bundle needs to load


def open_bundle(products: str, environ: Optional[Dict[str, str]] = None) -> Optional[Bundle]:
    """The built test bundle under `products` and the toolchain helpers that run it, or None when
    it was never built. Same environment SwiftPM gives the bundle (run_tests.py core_exec, 2026-11-20)."""
    prod = Path(products)
    bundle = prod / BUNDLE
    exe = bundle / "Contents" / "MacOS" / "VideoScanCoreTests"
    if not exe.exists():
        return None
    xrun = lambda *a: subprocess.run(["xcrun"] + list(a), capture_output=True, text=True).stdout.strip()
    plat = xrun("--sdk", "macosx", "--show-sdk-platform-path")
    pm = Path(xrun("--find", "swift")).parent.parent / "libexec" / "swift" / "pm"
    env = dict(os.environ if environ is None else environ, NO_COLOR="1",
               DYLD_FRAMEWORK_PATH=f"{plat}/Developer/Library/Frameworks:{plat}/Developer/Library/PrivateFrameworks",
               DYLD_LIBRARY_PATH=f"{prod.resolve()}:{plat}/Developer/usr/lib")
    return Bundle(prod, bundle, exe, pm, env)


# ───────────────────────────────────────────────────────────── the listing → the plan

@dataclass
class Listing:
    """Every test in the bundle and which of them are marked quiet-machine."""
    xctest: Dict[str, List[str]] = field(default_factory=dict)   # "Module.Class" → methods, in listing order
    xctest_quiet: Set[str] = field(default_factory=set)          # classes
    swift: List[str] = field(default_factory=list)               # test-function ids
    swift_quiet: Set[str] = field(default_factory=set)


class ListingError(Exception):
    pass


def parse_swift_listing(lines: Sequence[str]) -> Tuple[List[str], Set[str]]:
    """(function ids, the quiet ones) from the event stream of `--list-tests`. A function is quiet when
    it carries the tag or any suite above it does (a suite's id + "/" starts its tests' ids). Records
    without a `tags` key mean a toolchain older than the 6.4 stream: refuse, never read as "no tags"."""
    functions: List[str] = []
    own: Set[str] = set()
    quiet_suites: List[str] = []
    for raw in lines:
        raw = raw.strip()
        if not raw:
            continue
        try:
            record = json.loads(raw)
        except ValueError as exc:
            raise ListingError(f"the Swift Testing listing has a line that is not JSON: {raw[:120]!r}") from exc
        if record.get("kind") != "test":
            continue
        p = record.get("payload") or {}
        if "tags" not in p:
            raise ListingError("the Swift Testing listing carries no tags (event stream "
                               f"{record.get('version')!r}; this lane needs the {EVENT_STREAM_VERSION} stream, Swift 6.4+)")
        ident = p.get("id") or ""
        tagged = QUIET_TAG in [str(t).lstrip(".") for t in p["tags"]]
        if p.get("kind") == "suite":
            if tagged:
                quiet_suites.append(ident + "/")
        elif p.get("kind") == "function":
            functions.append(ident)
            if tagged:
                own.add(ident)
    quiet = own | {f for f in functions if any(f.startswith(s) for s in quiet_suites)}
    return functions, quiet


def list_bundle(b: Bundle) -> Listing:
    """Ask the bundle itself (see the module header). Raises ListingError when either listing fails."""
    out = Listing()
    with tempfile.TemporaryDirectory(prefix="core-lane-list-") as tmp:
        tree_path, quiet_path, stream_path = Path(tmp) / "xctest.json", Path(tmp) / "quiet.txt", Path(tmp) / "swift.jsonl"
        quiet_path.write_text("")
        p = subprocess.run([str(b.pm / "swiftpm-xctest-helper"), str(b.bundle), str(tree_path)],
                           env=dict(b.env, **{XCTEST_LIST_KEY: str(quiet_path)}), capture_output=True, text=True)
        if p.returncode != 0 or not tree_path.exists():
            raise ListingError(f"listing the XCTest cases failed (exit {p.returncode}): {p.stderr.strip()[:300]}")
        for top in json.loads(tree_path.read_text()).get("tests", []):
            for cls in top.get("tests", []):
                out.xctest[cls["name"]] = [t["name"] for t in cls.get("tests", [])]
        out.xctest_quiet = {l.strip() for l in quiet_path.read_text().splitlines() if l.strip()} & set(out.xctest)
        p = subprocess.run([str(b.pm / "swiftpm-testing-helper"), "--test-bundle-path", str(b.exe), str(b.exe),
                            "--testing-library", "swift-testing", "--list-tests",
                            "--event-stream-output-path", str(stream_path),
                            "--event-stream-version", EVENT_STREAM_VERSION],
                           env=b.env, capture_output=True, text=True)
        if p.returncode != 0 or not stream_path.exists():
            raise ListingError(f"listing the Swift Testing tests failed (exit {p.returncode}): {p.stderr.strip()[:300]}")
        out.swift, out.swift_quiet = parse_swift_listing(stream_path.read_text().splitlines())
    return out


@dataclass
class PhasePlan:
    key: str                             # "A" | "B"
    title: str
    xctest: List[str]                    # -XCTest selectors (a whole class, or Class/method)
    xctest_count: int
    swift: List[str]                     # function ids (phase B runs exactly these; phase A: for the count)
    swift_skip: List[str]                # phase A: the quiet ids its `--skip` names

    @property
    def expected(self) -> int:
        return self.xctest_count + len(self.swift)


def swift_id_regex(ids: Sequence[str]) -> str:
    """One regex that matches exactly these Swift Testing ids ("Module.Suite/f()/File.swift:L:C")."""
    return "^(?:" + "|".join(re.escape(i) for i in ids) + ")$"


def plan_phases(listing: Listing, regex: Optional[str]) -> Tuple[PhasePlan, PhasePlan]:
    """Split the (filtered) listing. `regex` is run_tests.py's Core filter: an XCTest test is
    `Module.Class/test`, a Swift Testing test its id; both are kept when the regex is found in them."""
    rx = re.compile(regex) if regex else None
    keep = (lambda name: bool(rx.search(name))) if rx else (lambda name: True)
    sel: Dict[bool, List[str]] = {False: [], True: []}
    n: Dict[bool, int] = {False: 0, True: 0}
    for cls, methods in listing.xctest.items():
        hit = [m for m in methods if keep(f"{cls}/{m}")]
        quiet = cls in listing.xctest_quiet
        sel[quiet] += [cls] if hit and len(hit) == len(methods) else [f"{cls}/{m}" for m in hit]
        n[quiet] += len(hit)
    swift = [i for i in listing.swift if keep(i)]
    loud = [i for i in swift if i not in listing.swift_quiet]
    quiet_ids = [i for i in swift if i in listing.swift_quiet]
    a = PhasePlan("A", "parallel, timing not strict", sel[False], n[False], loud,
                  sorted(listing.swift_quiet))
    b = PhasePlan("B", "serial, quiet machine", sel[True], n[True], quiet_ids, [])
    return a, b


# ───────────────────────────────────────────────────────────── counting (the nightly's rules)

RUN_SUMMARY_RE = re.compile(r"Test run with [0-9]+ test")
ST_PASS_RE = re.compile(r"✔ Test .* passed after ")
ST_KNOWN_RE = re.compile(r"━ Test .* passed after .* known issues?\.?$")
ST_FAIL_RE = re.compile(r"✘ Test (.+) failed after ")
ST_SKIP_RE = re.compile(r"➜ Test .* skipped")
ST_START_RE = re.compile(r"◇ Test (.+) started\.?$")
ST_END_RE = re.compile(r"(?:✔|✘|━|➜) Test (.+?) (?:passed after|failed after|skipped)")
XC_RE = re.compile(r"^Test Case '(.+)' (passed|failed|skipped|started)")


@dataclass
class Counts:
    """What one phase printed, by scripts/nightly_local_tests.sh parse_test_counts' rules: one terminal
    line per test; a Swift Testing "recorded an issue" line and the run summary are not tests."""
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    known: int = 0
    failed_names: List[str] = field(default_factory=list)
    running: Dict[str, int] = field(default_factory=dict)        # started and not yet ended (name → how many)

    @property
    def total(self) -> int:
        return self.passed + self.failed + self.skipped

    def _begin(self, name: str) -> None:
        self.running[name] = self.running.get(name, 0) + 1

    def _end(self, name: str) -> None:
        left = self.running.get(name, 0) - 1
        if left > 0:
            self.running[name] = left
        else:
            self.running.pop(name, None)

    def feed(self, line: str) -> None:
        x = XC_RE.match(line)
        if x:
            name, what = x.group(1), x.group(2)
            if what == "started":
                self._begin(name)
                return
            self._end(name)
            if what == "passed":
                self.passed += 1
            elif what == "skipped":
                self.skipped += 1
            else:
                self.failed += 1
                self.failed_names.append(name)
            return
        s = ST_START_RE.search(line)
        if s:
            self._begin(s.group(1))
            return
        if " recorded an issue " in line or " recorded a known issue " in line or RUN_SUMMARY_RE.search(line):
            return
        e = ST_END_RE.search(line)
        if e:
            self._end(e.group(1))
        if ST_KNOWN_RE.search(line):
            self.passed += 1
            self.known += 1
        elif ST_PASS_RE.search(line):
            self.passed += 1
        elif ST_SKIP_RE.search(line):
            self.skipped += 1
        else:
            f = ST_FAIL_RE.search(line)
            if f:
                self.failed += 1
                self.failed_names.append(f.group(1))


# ───────────────────────────────────────────────────────────── running a phase

class Output:
    """Whole lines to stdout, one writer at a time, flushed as they come (the nightly's stall watchdog
    reads the log's growth; two children writing one fd tear each other's lines — sensor_lane.py,
    2026-11-09)."""

    def __init__(self, stream: Optional[IO[str]] = None) -> None:
        self.stream = stream or sys.stdout
        self.lock = threading.Lock()

    def line(self, text: str) -> None:
        with self.lock:
            self.stream.write(text.rstrip("\n") + "\n")
            self.stream.flush()


def _pump(proc: subprocess.Popen, counts: Counts, out: Output, lock: threading.Lock) -> None:
    assert proc.stdout is not None
    for raw in iter(proc.stdout.readline, b""):
        line = raw.decode("utf-8", errors="replace").rstrip("\n")
        with lock:
            counts.feed(line)
        out.line(line)


Spawn = Callable[[List[str], Dict[str, str]], subprocess.Popen]


def _spawn(cmd: List[str], env: Dict[str, str]) -> subprocess.Popen:
    # Same process group as this script: the nightly's watchdog stops (and samples) the group.
    return subprocess.Popen(cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL)


def phase_commands(b: Bundle, plan: PhasePlan, regex: Optional[str]) -> List[Tuple[str, List[str]]]:
    """[(what, argv)] for one phase. Phase A: XCTest and Swift Testing side by side, Swift Testing with
    its default in-process parallelism, the user's filter, and the quiet ids skipped. Phase B: the same
    two, one after the other, Swift Testing `--no-parallel` on exactly the quiet ids."""
    cmds: List[Tuple[str, List[str]]] = []
    if plan.xctest:
        cmds.append(("XCTest", ["xcrun", "xctest", "-XCTest", ",".join(plan.xctest), str(b.bundle)]))
    helper = [str(b.pm / "swiftpm-testing-helper"), "--test-bundle-path", str(b.exe), str(b.exe),
              "--testing-library", "swift-testing"]
    if plan.swift and plan.key == "A":
        cmd = helper + (["--filter", regex] if regex else [])
        if plan.swift_skip:
            cmd += ["--skip", swift_id_regex(plan.swift_skip)]
        cmds.append(("Swift Testing", cmd))
    elif plan.swift:
        cmds.append(("Swift Testing", helper + ["--no-parallel", "--filter", swift_id_regex(plan.swift)]))
    return cmds


@dataclass
class PhaseResult:
    plan: PhasePlan
    counts: Counts
    rcs: List[Tuple[str, int]]
    seconds: float
    strict: bool
    peak_mb: float = 0.0                 # the largest test process so far (this phase or an earlier one)

    @property
    def problems(self) -> List[str]:
        """Why this phase is RED (empty: green). Every sentence names the phase."""
        c, p, out = self.counts, self.plan, []
        label = f"phase {p.key} ({p.title})"
        for name in c.failed_names:
            out.append(f"{label}: FAILED {name}")
        for what, rc in self.rcs:
            if rc != 0 and not (rc == NO_TEST_MATCHED and what == "Swift Testing" and c.total >= p.expected):
                out.append(f"{label}: {what} exited {rc}" + ("" if c.failed else " with no failed test (a crash, or a child that died)"))
        if p.expected > 0 and c.total == 0:
            out.append(f"{label}: ran ZERO of its {p.expected} tests")
        elif c.total != p.expected:
            out.append(f"{label}: ran {c.total} of its {p.expected} tests")
        return out


def run_phase(b: Bundle, plan: PhasePlan, regex: Optional[str], out: Output, spawn: Spawn = _spawn,
              live: Optional[List["PhaseLive"]] = None) -> PhaseResult:
    env = dict(b.env)
    if plan.key == "A":
        env.pop(STRICT_KEY, None)        # a parallel phase is not a quiet machine: never strict (2026-10-31 ruling)
    strict = env.get(STRICT_KEY) == "1"
    counts, lock = Counts(), threading.Lock()
    if live is not None:
        live.append(PhaseLive(plan, counts, lock))
    cmds = phase_commands(b, plan, regex)
    out.line(f"core-lane: phase {plan.key} ({plan.title}{', ' + STRICT_KEY + '=1' if strict else ''}): "
             f"{plan.expected} tests planned ({plan.xctest_count} XCTest + {len(plan.swift)} Swift Testing)")
    t0 = time.monotonic()
    rcs: List[Tuple[str, int]] = []

    def one(what: str, cmd: List[str]) -> None:
        proc = spawn(cmd, env)
        _pump(proc, counts, out, lock)
        rcs.append((what, proc.wait()))

    # Children are always pumped on worker threads, also in the serial phase: the main thread holds
    # no lock, so the stop handler (say_what_was_running) can always take them.
    if plan.key == "A":
        threads = [threading.Thread(target=one, args=c, daemon=True) for c in cmds]
    else:
        threads = [threading.Thread(target=lambda: [one(*c) for c in cmds], daemon=True)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / (1 << 20)        # macOS: bytes; the largest so far
    return PhaseResult(plan, counts, sorted(rcs), time.monotonic() - t0, strict, peak)


@dataclass
class PhaseLive:
    plan: PhasePlan
    counts: Counts
    lock: threading.Lock


def summary_line(r: PhaseResult) -> str:
    c = r.counts
    return (f"core-lane: phase {r.plan.key} ({r.plan.title}{', strict' if r.strict else ''}): "
            f"{c.passed} passed / {c.failed} failed / {c.skipped} skipped — {c.total} of {r.plan.expected} planned, "
            f"{c.known} with known issues, {r.seconds:.0f} s"
            + (f", largest test process so far {r.peak_mb:.0f} MB" if r.peak_mb else ""))


def run_lane(products: str, regex: Optional[str] = None, out: Optional[Output] = None, spawn: Spawn = _spawn,
             lister: Callable[[Bundle], Listing] = list_bundle, live: Optional[List[PhaseLive]] = None) -> int:
    """List, split, run phase A then phase B, print one summary line per phase and the verdict."""
    out = out or Output()
    b = open_bundle(products)
    if b is None:
        out.line(f"core-lane: no built test bundle at {Path(products) / BUNDLE} (did the Core build run?)")
        return EXIT_FAILED
    try:
        listing = lister(b)
    except ListingError as exc:
        out.line(f"core-lane: RED — {exc}")
        return EXIT_COUNT
    a, bq = plan_phases(listing, regex)
    out.line(f"core-lane: {len(listing.xctest_quiet)} XCTest classes and {len(listing.swift_quiet)} Swift Testing tests "
             f"are marked quiet-machine, of {sum(map(len, listing.xctest.values()))} + {len(listing.swift)} in the bundle")
    results = [run_phase(b, plan, regex, out, spawn, live) if plan.expected else
               PhaseResult(plan, Counts(), [], 0.0, False) for plan in (a, bq)]
    problems = [p for r in results for p in r.problems]
    for r in results:
        out.line(summary_line(r))
    total = sum(r.counts.total for r in results)
    expected = sum(r.plan.expected for r in results)
    if expected == 0 and not regex:
        problems.append("the bundle lists ZERO tests")
    tot = lambda f: sum(getattr(r.counts, f) for r in results)
    out.line(f"core-lane: total {tot('passed')} passed / {tot('failed')} failed / {tot('skipped')} skipped — "
             f"{total} of {expected} planned, {sum(r.seconds for r in results):.0f} s → {'RED' if problems else 'GREEN'}")
    for p in problems:
        out.line(f"core-lane: RED — {p}")
    if not problems:
        return EXIT_GREEN
    if any(r.counts.failed or any(rc not in (0, NO_TEST_MATCHED) for _, rc in r.rcs) for r in results):
        return EXIT_FAILED
    return EXIT_COUNT


def say_what_was_running(live: List[PhaseLive], out: Output) -> None:
    """On a stop (the watchdog's TERM): in a parallel phase the last "started" line is not the hung
    test, so name every test that started and never ended."""
    for pl in live:
        with pl.lock:
            names = sorted(pl.counts.running)
        if names:
            out.line(f"core-lane: stopped in phase {pl.plan.key} ({pl.plan.title}); started and not finished: "
                     + "; ".join(names[:40]) + (f"; … {len(names) - 40} more" if len(names) > 40 else ""))


# ───────────────────────────────────────────────────────────── the build

def build_command(package: str, configuration: str, scratch: Optional[str]) -> List[str]:
    """`swift build --build-tests`. Release needs -enable-testing for the tests' `@testable import`
    (`swift test -c release` adds it itself; `swift build` does not: "unable to resolve Swift module
    dependency to a compatible module: 'VideoScanCore'", measured 2026-11-20)."""
    cmd = ["swift", "build", "--build-tests", "--package-path", package, "-c", configuration]
    if scratch:
        cmd += ["--scratch-path", scratch]
    if configuration == "release":
        cmd += ["-Xswiftc", "-enable-testing"]
    return cmd


def build(package: str, configuration: str, scratch: Optional[str], out: Output) -> Tuple[int, str]:
    """(exit, products dir). Output is streamed; the products dir is what `--show-bin-path` says."""
    cmd = build_command(package, configuration, scratch)
    out.line("core-lane: build: " + " ".join(cmd))
    proc = _spawn(cmd, dict(os.environ))
    assert proc.stdout is not None
    for raw in iter(proc.stdout.readline, b""):
        out.line(raw.decode("utf-8", errors="replace").rstrip("\n"))
    rc = proc.wait()
    if rc != 0:
        return rc, ""
    p = subprocess.run(cmd + ["--show-bin-path"], capture_output=True, text=True)
    return p.returncode, p.stdout.strip().splitlines()[-1] if p.stdout.strip() else ""


# ───────────────────────────────────────────────────────────── the source pin (sensor lane)

# The helpers that JUDGE a measurement (TimingBudgetExpectations.swift, TimingBudgetXCTestSupport.swift,
# TimingBudget.swift). `TimingBudget.judge` itself is the pure rule and is not here: its unit tests
# inject every input and measure nothing.
JUDGING_HELPERS = ("expectWithinTimingBudget", "expectWithinReferenceTimingBudget", "recordTimingJudgement",
                   "assertTimingJudgements", "expectRatio", "judgeNow", "judgeGrowth", "judgeRelative",
                   "loadAwareDebugCeiling", "debugCeiling", "measureThreadCPUTime")
JUDGING_RE = re.compile(r"\b(" + "|".join(JUDGING_HELPERS) + r")\b")
RESIDENT_RE = re.compile(r"\b(resident_size|resident_size_max|phys_footprint|mach_task_basic_info|task_vm_info)\b")
QUIET_MARK_RE = re.compile(r"\.quietMachine\b")
QUIET_BASE_RE = re.compile(r"\bQuietMachineXCTestCase\b")
# Where the helpers are defined: their own bodies name each other and are not tests.
HELPER_FILES = ("TimingBudgetExpectations.swift", "TimingBudgetXCTestSupport.swift", "QuietMachine.swift")


def check_tags(tests_root: Path) -> List[str]:
    """Violations, one sentence each: a test under `tests_root` that reaches a judging or resident-size
    helper — in its own body, or through a helper declared in its file, in a type of the same name, or
    in a shared *Support*/*Helpers* file (sensor_lane.py's visibility rule) — without the quiet-machine
    mark (`.quietMachine` on its @Test or on a suite above it; for XCTest, the class inherits
    QuietMachineXCTestCase). Source scan only; memory: one file's text at a time plus the helper names."""
    import sensor_lane as sl                      # the lexer and declaration parser (scripts/sensor_lane.py)
    parsed = []
    for path in sl.swift_files(tests_root):
        text = path.read_text(encoding="utf-8", errors="replace")
        masked = sl.mask(text)
        parsed.append((path, text, masked, sl.parse(text, masked)))
    reaches = lambda body: bool(JUDGING_RE.search(body) or RESIDENT_RE.search(body))
    shared = lambda path: bool(re.search(r"(Support|Helpers?)\.swift$", path.name))
    is_helper = lambda d: d.kind == "func" and not d.is_test and not d.local and len(d.name) >= 3
    homes = lambda path, d: [("file", str(path))] + ([("type", d.type_path[-1])] if d.type_path else []) \
        + ([("shared", "")] if shared(path) else [])
    visible = lambda path, tp: [("file", str(path)), ("shared", "")] + [("type", t) for t in tp]
    carriers: Dict[Tuple[str, str], Set[str]] = {}
    pending = []
    for path, text, masked, decls in parsed:
        if path.name in HELPER_FILES:
            continue
        for d in decls:
            if not is_helper(d):
                continue
            body = masked[d.start:d.end]
            if reaches(body):
                for k in homes(path, d):
                    carriers.setdefault(k, set()).add(d.name)
            else:
                pending.append((path, d, body))
    changed = True
    while changed:
        changed, still = False, []
        for path, d, body in pending:
            names = set().union(*(carriers.get(k, set()) for k in visible(path, d.type_path)))
            if sl._calls_any(body, names, exclude=d.name):
                for k in homes(path, d):
                    carriers.setdefault(k, set()).add(d.name)
                changed = True
            else:
                still.append((path, d, body))
        pending = still

    def attributes(masked: str, text: str, start: int) -> str:
        """The attribute run directly above a declaration (back to the previous `}` / `;` / `{`)."""
        back = masked[max(0, start - 800):start]
        cut = max(back.rfind("}"), back.rfind(";"), back.rfind("{"))
        return text[start - len(back) + cut + 1:start]

    marked_types: Set[str] = set()                 # suites that carry the mark, by type name (any file)
    for path, text, masked, decls in parsed:
        for d in decls:
            if d.kind == "type" and (QUIET_MARK_RE.search(attributes(masked, text, d.start))
                                     or QUIET_BASE_RE.search(masked[d.start:d.body_start])):
                marked_types.add(d.name)
    bad: List[str] = []
    for path, text, masked, decls in parsed:
        if path.name in HELPER_FILES:
            continue
        for d in decls:
            if d.kind != "func" or not d.is_test:
                continue
            body = masked[d.start:d.end]
            names = set().union(*(carriers.get(k, set()) for k in visible(path, d.type_path)))
            direct = JUDGING_RE.search(body) or RESIDENT_RE.search(body)
            if not direct and not sl._calls_any(body, names, exclude=d.name):
                continue
            own = text[d.attr_start if d.attr_start >= 0 else d.start:d.start]
            if QUIET_MARK_RE.search(own) or any(t in marked_types for t in d.type_path):
                continue
            via = direct.group(1) if direct else "a helper that judges time or resident size"
            line = text.count("\n", 0, d.start) + 1
            how = ("make the class inherit QuietMachineXCTestCase" if d.params == "xctest"
                   else "add .tags(.quietMachine) to its @Test (or its @Suite)")
            bad.append(f"{path.relative_to(tests_root)}:{line} {'.'.join(d.type_path)}/{d.name} reaches {via} "
                       f"but is not marked quiet-machine — {how} (QuietMachine.swift)")
    return bad


# ───────────────────────────────────────────────────────────── entry

REPO = Path(__file__).resolve().parent.parent
CORE_TESTS = REPO / "VideoScan" / "VideoScanCore" / "Tests" / "VideoScanCoreTests"


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    rn = sub.add_parser("run", help="build (unless --products / --skip-build) and run the two phases")
    rn.add_argument("--package-path")
    rn.add_argument("-c", "--configuration", default="debug", choices=("debug", "release"))
    rn.add_argument("--scratch-path")
    rn.add_argument("--skip-build", action="store_true")
    rn.add_argument("--products", help="a built products dir; nothing is built")
    rn.add_argument("--filter", dest="regex", help="only tests the regex is found in (run_tests.py's Core filter)")
    ls = sub.add_parser("list", help="the quiet-machine tests, read from the built bundle")
    ls.add_argument("--products", required=True)
    ck = sub.add_parser("check", help="source pin: every test that reaches a timing / resident-size helper is marked")
    ck.add_argument("--tests", default=str(CORE_TESTS))
    a = ap.parse_args(argv)
    out = Output()

    if a.cmd == "check":
        bad = check_tags(Path(a.tests))
        for line in bad:
            print(f"✘ {line}")
        print(f"core-lane check: {len(bad)} test(s) judge time or resident size without the quiet-machine mark")
        return 1 if bad else 0

    if a.cmd == "list":
        b = open_bundle(a.products)
        if b is None:
            print(f"core-lane: no built test bundle at {Path(a.products) / BUNDLE}", file=sys.stderr)
            return EXIT_FAILED
        try:
            listing = list_bundle(b)
        except ListingError as exc:
            print(f"core-lane: {exc}", file=sys.stderr)
            return EXIT_COUNT
        for cls in sorted(listing.xctest_quiet):
            print(f"{cls}    (XCTest class, {len(listing.xctest[cls])} tests)")
        for ident in sorted(listing.swift_quiet):
            print(ident)
        return 0

    products = a.products
    if not products:
        if not a.package_path:
            ap.error("run needs --package-path or --products")
        if a.skip_build:
            p = subprocess.run(build_command(a.package_path, a.configuration, a.scratch_path) + ["--show-bin-path"],
                               capture_output=True, text=True)
            products = p.stdout.strip().splitlines()[-1] if p.returncode == 0 and p.stdout.strip() else ""
        else:
            rc, products = build(a.package_path, a.configuration, a.scratch_path, out)
            if rc != 0:
                out.line(f"core-lane: RED — the build failed (exit {rc}); no test ran")
                return EXIT_BUILD
        if not products:
            out.line("core-lane: RED — swift build --show-bin-path named no products directory")
            return EXIT_BUILD
    live: List[PhaseLive] = []

    def stopped(signum: int, _frame: object) -> None:
        say_what_was_running(live, out)
        signal.signal(signum, signal.SIG_DFL)
        os.kill(os.getpid(), signum)

    with contextlib.suppress(ValueError):          # not the main thread (imported and driven by a test)
        signal.signal(signal.SIGTERM, stopped)
        signal.signal(signal.SIGINT, stopped)
    return run_lane(products, a.regex, out, live=live)


if __name__ == "__main__":
    sys.exit(main())
