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
            VIDEOSCAN_TIMING_STRICT exactly as the caller set it. Since
            2026-11-21 as K serial STRANDS (`--quiet-jobs K`, default
            min(4, cores/4); 1 = the single serial pass): see "Phase B in
            strands" below.

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

Counts: each phase's plan is the listing (after `--filter`), held PER
FRAMEWORK: XCTest and Swift Testing must each run exactly their part of the
plan (a short XCTest run is not hidden by a long Swift Testing one). A phase
that ran none, fewer or more is RED, and every failure line names its phase.
The lane's totals are the sum of the two.

The listing is not trusted alone (review 2026-11-21). On an unfiltered run:
  * a listing with no XCTest or no Swift Testing tests, or with no
    quiet-machine test in either, is refused — an empty answer from a helper
    that exited 0 must not read as "nothing to run" / "nothing is strict";
  * the listing is cross-checked against an independent witness, the test
    SOURCE (scan_source: the same parse the `check` pin uses): tests and
    quiet-machine tests per framework must agree within SOURCE_TOLERANCE;
  * a quiet XCTest class the listing does not name is refused, not dropped.
Each test process is told its phase (VIDEOSCAN_CORE_PHASE=parallel|serial);
the judging helpers record an issue when they run under `parallel`.

Phase B in strands (2026-11-21; DECISIONS, same date). The single serial pass was
the lane's floor (~735–790 s on the Ultra against 38 s for phase A). A STRAND is
one share of the quiet tests run one at a time in its own processes (XCTest,
then Swift Testing `--no-parallel`): K strands run side by side, each test still
never beside another test of its own process, strict timing kept, the phase
marker still `serial`. The quiet tests are dealt to the strands by their last
recorded seconds, longest first, each to the strand with the least so far
(scripts/testbed_strands.py's timing cache, its own file).
  * A test whose only failures in a strand are BUDGET judgements is not judged
    there. A budget judgement is an issue whose text carries `[quiet-budget]`:
    the timing / resident-size helpers write it (TimingBudgetExpectations.swift,
    TimingBudgetXCTestSupport.swift: recordTimingJudgement, expectRatio,
    assertTimingJudgements, expectBudget, XCTAssertBudget). Its failing line is
    replaced by a `core-lane: strand N: failed beside …` note (so no reader
    counts a verdict twice) and, when every strand has ended and nothing else of
    the lane is running, it is RUN AGAIN ALONE — the single serial pass, on those
    tests only. RED only if it fails alone too.
  * Every other failure is RED at once, as in the single pass: an issue without
    the marker (a wrong value, a bare `#expect(elapsed < …)`), a failure with no
    issue text, a crash. Noise from the other strands can stretch a time; it
    cannot change a row count.
  * A test that failed beside the others and passed alone is GREEN and is named:
    `core-lane: AMBER — phase B (…): passed alone after failing beside K-1 other
    strands: <test>`, and counted on the phase's summary line. Drift is visible.
  * A strand whose process dies (any exit but 0, or 1 with a failed test) is RED
    by its exit code, whatever else failed in it. Its unfinished tests still go
    to the alone pass, so each has its verdict: never lost, never counted twice.
    A test that kills its process alone is RED by name and the rest still runs.
  * Which Swift Testing tests failed or never finished is read from the strand's
    event stream (`--event-stream-output-path`: test ids, not display names);
    XCTest names its tests on its own lines. When the stream and the console
    disagree about how many failed, nothing is guessed: those failures stand.
    A stream that names no test at all is "missing": the console verdicts stand
    and nothing is run again (RED unless the process exited 0).
  * The exact-plan rule is unchanged: every planned test has exactly ONE verdict
    line in the output, per framework, and the nightly counts those lines.
`--quiet-jobs 1` runs the commands of the single serial pass, argument for argument.

Usage:
  core_lane.py run --package-path <VideoScanCore> [-c debug|release]
                   [--scratch-path <dir>] [--skip-build] [--filter <regex>]
                   [--quiet-jobs K]
  core_lane.py run --products <dir with VideoScanCoreTests.xctest> [--filter <regex>]
  core_lane.py list --products <dir>        # the quiet-machine tests, from the bundle
  core_lane.py check [--tests <dir>]        # source pin: a test that reaches a timing /
                                            # resident-size helper, or orders a clock reading
                                            # in an assertion, carries the mark
Exit: 0 green; 1 a test failed or a child exited non-zero; 2 a phase's count is
not its plan (or nothing could be listed); 3 the build failed.

Memory: this script holds the two listings (a few thousand short records) and
one output line at a time; test output is streamed, never held. The test
processes: phase A's Swift Testing process runs ~2,400 tests on every core at
once — its peak resident size is printed on the total line (ru_maxrss of the
children; 2026-11-20, Release, the Ultra: see the commit); phase B is one test
at a time per process, as the serial lane always was (its 100k import is
the largest: ~3.4 GB resident at its peak; a build that ran first is not counted).
With K strands the worst case is K of the largest quiet tests at once: K × ~3.4 GB
(K=4: ~14 GB), which is why K stops at 4, is cores/4 on a small Mac, and is never
more than physical memory / 8 GB (a 16 GB Mac: 2; 8 GB: 1), asked for or not. Per strand
this script also holds its event stream's verdicts (one short record per test) and
the failing lines it withheld.
"""
from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import resource
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, IO, List, Optional, Sequence, Set, Tuple

STRICT_KEY = "VIDEOSCAN_TIMING_STRICT"
PHASE_KEY = "VIDEOSCAN_CORE_PHASE"      # read by QuietMachinePhase (QuietMachine.swift)
PHASE_VALUE = {"A": "parallel", "B": "serial"}
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
    home = sealed_home()
    env = dict(os.environ if environ is None else environ, NO_COLOR="1",
               DYLD_FRAMEWORK_PATH=f"{plat}/Developer/Library/Frameworks:{plat}/Developer/Library/PrivateFrameworks",
               DYLD_LIBRARY_PATH=f"{prod.resolve()}:{plat}/Developer/usr/lib",
               HOME=home, CFFIXED_USER_HOME=home)
    return Bundle(prod, bundle, exe, pm, env)


def sealed_home() -> str:
    """A fresh scratch home for this lane's test processes (DECISIONS 2026-11-22: tests never open the
    real catalog): FileManager's App Support, Logs and Preferences resolve inside it, never to Rick's.
    Removed when this process exits. ≈ C++: a chroot for the user's dotfiles, not the filesystem."""
    import atexit
    import tempfile
    home = tempfile.mkdtemp(prefix="videoscan-core-home-")
    for sub in ("Library/Application Support", "Library/Logs", "Library/Preferences", "Library/Caches"):
        os.makedirs(os.path.join(home, sub), exist_ok=True)
    atexit.register(shutil.rmtree, home, True)
    return home


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
        named = {l.strip() for l in quiet_path.read_text().splitlines() if l.strip()}
        unknown = sorted(named - set(out.xctest))
        if unknown:
            # A private or nested class reports a mangled runtime name the tree does not use. Dropping it
            # would put a quiet-machine class in the parallel phase without a word (review F3).
            raise ListingError("quiet-machine XCTest class(es) the XCTest listing does not name: " + ", ".join(unknown[:5])
                               + " — make the class internal and top-level, so its runtime name is Module.Class")
        out.xctest_quiet = named
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
    xctest_tests: List[Tuple[str, str]] = field(default_factory=list)    # (bare class, method), every planned one

    @property
    def expected(self) -> int:
        return self.xctest_count + len(self.swift)


_REGEX_META = re.compile(r"([\\^$.|?*+()\[\]{}])")


def regex_literal(text: str) -> str:
    """`text` as a literal in BOTH regex dialects that read it: Python's `re` (the plan) and Swift's
    Regex (Swift Testing's --filter / --skip). Only the metacharacters the two share are escaped.
    Not re.escape: it also writes `\\ `, `\\#`, `\\-`, and an escaped space, `#` or `-` is one more
    thing a second dialect has to agree about (review 2026-11-21; both forms were accepted by the 6.4
    toolchain for an id with a space, `#`, `-` and parentheses — see the commit)."""
    return _REGEX_META.sub(r"\\\1", text)


def swift_id_regex(ids: Sequence[str]) -> str:
    """One regex that matches exactly these Swift Testing ids ("Module.Suite/f()/File.swift:L:C")."""
    return "^(?:" + "|".join(regex_literal(i) for i in ids) + ")$"


def plan_phases(listing: Listing, regex: Optional[str]) -> Tuple[PhasePlan, PhasePlan]:
    """Split the (filtered) listing. `regex` is run_tests.py's Core filter: an XCTest test is
    `Module.Class/test`, a Swift Testing test its id; both are kept when the regex is found in them."""
    rx = re.compile(regex) if regex else None
    keep = (lambda name: bool(rx.search(name))) if rx else (lambda name: True)
    sel: Dict[bool, List[str]] = {False: [], True: []}
    n: Dict[bool, int] = {False: 0, True: 0}
    each: Dict[bool, List[Tuple[str, str]]] = {False: [], True: []}
    for cls, methods in listing.xctest.items():
        hit = [m for m in methods if keep(f"{cls}/{m}")]
        quiet = cls in listing.xctest_quiet
        # The selector is the class WITHOUT its module: `xcrun xctest -XCTest Module.Class/method` runs
        # nothing and exits 0 (Xcode 27, measured 2026-11-21 — a filtered XCTest method never ran through
        # this route); `Class` and `Class/method` both run. One bundle, so the bare name is unambiguous.
        bare = cls.split(".", 1)[-1]
        sel[quiet] += [bare] if hit and len(hit) == len(methods) else [f"{bare}/{m}" for m in hit]
        n[quiet] += len(hit)
        each[quiet].extend(zip([bare] * len(hit), hit))
    swift = [i for i in listing.swift if keep(i)]
    loud = [i for i in swift if i not in listing.swift_quiet]
    quiet_ids = [i for i in swift if i in listing.swift_quiet]
    a = PhasePlan("A", "parallel, timing not strict", sel[False], n[False], loud,
                  sorted(listing.swift_quiet), each[False])
    b = PhasePlan("B", "serial, quiet machine", sel[True], n[True], quiet_ids, [], each[True])
    return a, b


# ───────────────────────────────────────────────────────────── counting (the nightly's rules)

RUN_SUMMARY_RE = re.compile(r"Test run with [0-9]+ test")
ST_PASS_RE = re.compile(r"✔ Test .* passed after ")
ST_KNOWN_RE = re.compile(r"━ Test .* passed after .* known issues?\.?$")
ST_FAIL_RE = re.compile(r"✘ Test (.+) failed after ")
ST_SKIP_RE = re.compile(r"➜ Test .* skipped")
ST_START_RE = re.compile(r"◇ Test (.+) started\.?$")
ST_END_RE = re.compile(r"(?:✔|✘|━|➜) Test (.+?) (?:passed after|failed after|skipped)")
# XCTest's own line, wherever it starts. A test that printed without a newline leaves its fragment
# glued in front ("…100 recordsTest Case '-[M.C t]' passed (0.010 seconds)."): the test ran, so it is
# COUNTED (review F6) — an anchored pattern lost it and made a green run a count mismatch. Guards against
# a look-alike: the whole XCTest shape must END the line (-[Class method], the verdict, the seconds), and a
# Swift Testing line (its symbols) that merely quotes one is never an XCTest verdict. _pump also writes the
# fragment and the verdict as two lines, so the nightly's anchored parse_test_counts counts the same.
XC_RE = re.compile(r"Test Case '(-\[\S+ [^\]\s]+\])' (?:(passed|failed|skipped) \(\d+(?:\.\d+)? seconds\)|(started))\.?\s*$")
SWIFT_TESTING_SYMBOLS = ("✔", "✘", "━", "➜", "◇", "↳")


def xctest_line(line: str) -> Optional["re.Match[str]"]:
    if any(s in line for s in SWIFT_TESTING_SYMBOLS):
        return None
    return XC_RE.search(line)


def unglue(line: str) -> List[str]:
    """[line], or [fragment, XCTest's line] when something is glued in front of it."""
    x = xctest_line(line)
    return [line[:x.start()], line[x.start():]] if x and x.start() > 0 else [line]


@dataclass
class Counts:
    """What one phase printed, by scripts/nightly_local_tests.sh parse_test_counts' rules: one terminal
    line per test; a Swift Testing "recorded an issue" line and the run summary are not tests."""
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    known: int = 0
    xctest_total: int = 0                                        # terminal lines by framework (review F5):
    swift_total: int = 0                                         # each is held to its own part of the plan
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
        x = xctest_line(line)
        if x:
            name, what = x.group(1), x.group(2) or x.group(3)
            if what == "started":
                self._begin(name)
                return
            self._end(name)
            self.xctest_total += 1
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
        before = self.total
        self._swift_verdict(line)
        self.swift_total += self.total - before

    def _swift_verdict(self, line: str) -> None:
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
        for line in unglue(raw.decode("utf-8", errors="replace").rstrip("\n")):
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
    strands: int = 0                     # phase B: how many strands ran side by side (0: the single serial pass)
    passed_alone: List[Tuple[str, str]] = field(default_factory=list)    # (test, why it was run alone): green, AMBER
    extra: List[str] = field(default_factory=list)                       # strand-mode RED reasons that are not a count or an exit
    failed_alone: Set[str] = field(default_factory=set)                  # console names of the failures the ALONE pass printed
    stood: Set[str] = field(default_factory=set)                         # … of failures that were not budget judgements: no second run

    @property
    def problems(self) -> List[str]:
        """Why this phase is RED (empty: green). Every sentence names the phase."""
        c, p, out = self.counts, self.plan, []
        label = f"phase {p.key} ({p.title})"
        for name in c.failed_names:
            how = (" — failed when run ALONE too" if name in self.failed_alone else
                   " — not a budget judgement: no second run" if name in self.stood else "")
            out.append(f"{label}: FAILED {name}{how}")
        out += [f"{label}: {e}" for e in self.extra]
        for what, rc in self.rcs:
            if rc != 0 and not (rc == NO_TEST_MATCHED and what.startswith("Swift Testing") and c.swift_total >= len(p.swift)):
                out.append(f"{label}: {what} exited {rc}" + ("" if c.failed else " with no failed test (a crash, or a child that died)"))
        for what, ran, planned in (("XCTest", c.xctest_total, p.xctest_count), ("Swift Testing", c.swift_total, len(p.swift))):
            if planned > 0 and ran == 0:
                out.append(f"{label}: {what} ran ZERO of its {planned} tests")
            elif ran != planned:
                out.append(f"{label}: {what} ran {ran} of its {planned} tests")
        return out


def _children_peak_mb() -> float:
    return resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss / (1 << 20)          # macOS: bytes


def run_phase(b: Bundle, plan: PhasePlan, regex: Optional[str], out: Output, spawn: Spawn = _spawn,
              live: Optional[List["PhaseLive"]] = None, floor_mb: float = 0.0,
              quiet_jobs: int = 1, timings: Optional[Path] = None) -> PhaseResult:
    if plan.key == "B" and quiet_jobs > 1 and len(quiet_units(plan)) > 1:
        return run_quiet_strands(b, plan, out, spawn, live, floor_mb, quiet_jobs, timings)
    env = dict(b.env, **{PHASE_KEY: PHASE_VALUE[plan.key]})      # the test process knows its phase (review F2)
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
    peak = _children_peak_mb()
    # ru_maxrss is the largest child EVER: when a build ran first (the compiler, ~7 GB) and no test
    # process has passed it, the number says nothing about the tests — print none.
    return PhaseResult(plan, counts, sorted(rcs), time.monotonic() - t0, strict, peak if peak > floor_mb else 0.0)


# ───────────────────────────────────────────────────────────── phase B in strands (2026-11-21)

QUIET_TIMINGS_KEY = "VIDEOSCAN_CORE_QUIET_TIMINGS"      # overrides the cache path (tests; a second checkout)
DEFAULT_QUIET_TIMINGS = Path.home() / "Library" / "Caches" / "videoscan-core-quiet-timings.json"
XC_SECONDS_RE = re.compile(r"\((\d+(?:\.\d+)?) seconds\)")
XC_NAME_RE = re.compile(r"-\[(?:[^\s.]+\.)?(\S+) ([^\]\s]+)\]")
XC_ERROR_RE = re.compile(r": error: (-\[\S+ [^\]\s]+\]) : ")
ST_ISSUE_RE = re.compile(r"✘ Test (.+) recorded an issue (?:at |with )")


def strand_count(text: str) -> int:
    """argparse type for --quiet-jobs: a whole number, 1 or more."""
    n = int(text)
    if n < 1:
        raise argparse.ArgumentTypeError("--quiet-jobs must be 1 or more")
    return n


BUDGET_MARKER = "[quiet-budget]"                       # QuietMachine.swift `quietBudgetMarker`: only these failures get a run alone
GB_PER_STRAND = 8                                       # the largest quiet test peaks at ~3.4 GB resident; leave it room twice over


def physical_memory_gb() -> Optional[int]:
    try:
        return int(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE") // (1 << 30))
    except (ValueError, OSError, AttributeError):
        return None


def memory_cap(jobs: int, mem_gb: Optional[int] = None) -> int:
    """`jobs`, but never more strands than physical memory / 8 GB (unknown memory: unchanged); at least 1."""
    mem_gb = physical_memory_gb() if mem_gb is None else mem_gb
    return max(1, jobs if not mem_gb else min(jobs, mem_gb // GB_PER_STRAND))


def strand_options(asked: Optional[int], environ: Optional[Dict[str, str]] = None,
                   mem_gb: Optional[int] = None) -> Tuple[int, Path]:
    """(K, the timing cache) for a real run: --quiet-jobs or this machine's default, either one capped
    by memory; the cache where VIDEOSCAN_CORE_QUIET_TIMINGS says, else under ~/Library/Caches."""
    environ = os.environ if environ is None else environ
    jobs = memory_cap(asked, mem_gb) if asked else default_quiet_jobs(mem=mem_gb)
    return jobs, Path(environ.get(QUIET_TIMINGS_KEY) or DEFAULT_QUIET_TIMINGS)


def default_quiet_jobs(cpus: Optional[int] = None, mem: Optional[int] = None) -> int:
    """min(4, cores/4, physical memory / 8 GB), at least 1 (Ultra 30 cores / 96 GB → 4, M4 Max 16 / 64 → 4,
    M1 Max 10 / 32 → 2, a 16 GB Mac → 2, 8 GB → 1). Not half the cores as for ordinary strands
    (testbed_strands.default_jobs): these tests judge time, so each strand keeps several cores to
    itself, and K of the largest at once must fit in memory (module header)."""
    return memory_cap(min(4, (cpus if cpus is not None else (os.cpu_count() or 4)) // 4), mem)


@dataclass(frozen=True)
class QuietUnit:
    """What is dealt to a strand whole: one XCTest class's planned tests, or one Swift Testing test."""
    kind: str                                    # "xctest" | "swift"
    key: str                                     # the timing-cache key (no line numbers: they move with every edit)
    selectors: Tuple[str, ...]                   # xctest: -XCTest selectors; swift: the one test id
    tests: Tuple[Tuple[str, str], ...] = ()      # xctest: (bare class, method)

    @property
    def count(self) -> int:
        return len(self.tests) if self.kind == "xctest" else 1


def swift_name(ident: str) -> str:
    """A Swift Testing id without its File.swift:line:column — how the lane names a test in its own lines."""
    return ident.rsplit("/", 1)[0] if re.search(r"/[^/]+\.swift:\d+:\d+$", ident) else ident


def quiet_units(plan: PhasePlan) -> List[QuietUnit]:
    """Phase B's plan as units, in plan order. Every planned test is in exactly one unit."""
    by_class: Dict[str, List[str]] = {}
    for cls, method in plan.xctest_tests:
        by_class.setdefault(cls, []).append(method)
    whole = {s for s in plan.xctest if "/" not in s}
    units = [QuietUnit("xctest", f"xctest:{cls}", (cls,) if cls in whole else tuple(f"{cls}/{m}" for m in methods),
                       tuple((cls, m) for m in methods)) for cls, methods in by_class.items()]
    return units + [QuietUnit("swift", f"swift:{swift_name(i)}", (i,)) for i in plan.swift]


def deal(units: Sequence[QuietUnit], jobs: int, seconds: Dict[str, float]) -> List[List[QuietUnit]]:
    """Longest first by recorded seconds, each unit to the strand with the least so far (LPT: the greedy
    4/3-approximation of the shortest longest strand). A unit with no record weighs the median of those
    that have one (1 s when none has), so a first run deals by count. Deterministic: ties by key, then
    by strand number. Never more strands than units; every unit in exactly one strand."""
    known = sorted(seconds[u.key] for u in units if u.key in seconds)
    typical = known[len(known) // 2] if known else 1.0
    weight = lambda u: seconds.get(u.key, typical * u.count)
    strands: List[List[QuietUnit]] = [[] for _ in range(max(1, min(jobs, len(units))))]
    load = [0.0] * len(strands)
    for u in sorted(units, key=lambda u: (-weight(u), u.key)):
        n = min(range(len(strands)), key=lambda i: (load[i], i))
        strands[n].append(u)
        load[n] += weight(u)
    return strands


@dataclass
class StreamVerdicts:
    """What a Swift Testing event stream says about the test FUNCTIONS it was asked about, by test id.
    Failed: an issue that is a failure (not a known issue) was recorded against the test."""
    started: Set[str] = field(default_factory=set)
    ended: Set[str] = field(default_factory=set)
    failed: Set[str] = field(default_factory=set)
    seconds: Dict[str, float] = field(default_factory=dict)
    began: Dict[str, float] = field(default_factory=dict)
    ended_order: List[str] = field(default_factory=list)

    def note(self, payload: Dict[str, object]) -> None:
        """One event record's payload."""
        ident, kind = str(payload["testID"]), payload.get("kind")
        instant = payload.get("instant")
        at = instant.get("absolute") if isinstance(instant, dict) else None
        if kind == "testStarted":
            self.started.add(ident)
            if isinstance(at, (int, float)):
                self.began[ident] = float(at)
        elif kind in ("testEnded", "testSkipped"):
            self.ended.add(ident)
            self.ended_order.append(ident)
            if isinstance(at, (int, float)) and ident in self.began:
                self.seconds[ident] = max(0.0, float(at) - self.began[ident])
        elif kind == "issueRecorded":
            issue = payload.get("issue")
            issue = issue if isinstance(issue, dict) else {}
            if issue.get("isFailure", not issue.get("isKnown", False)):
                self.failed.add(ident)


def stream_events(path: Path, ids: Set[str]) -> List[Dict[str, object]]:
    """The event payloads about `ids` in a Swift Testing event stream, in order. A line that is not
    JSON (the torn last line of a process that died mid-write) is skipped: what it would have said
    did not happen. A stream that cannot be read is no events."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return []
    found = []
    for raw in lines:
        try:
            record = json.loads(raw)
        except ValueError:
            continue
        payload = record.get("payload") if isinstance(record, dict) else None
        if isinstance(payload, dict) and record.get("kind") == "event" and payload.get("testID") in ids:
            found.append(payload)
    return found


def parse_event_stream(path: Path, ids: Set[str]) -> Tuple[Set[str], Set[str], Set[str], Dict[str, float]]:
    """(started, ended, failed, seconds) for the test functions in `ids`."""
    v = StreamVerdicts()
    for payload in stream_events(path, ids):
        v.note(payload)
    return v.started, v.ended, v.failed, v.seconds


@dataclass
class _Proc:
    """One test process of a strand or of the alone pass, and what it reported, by test KEY
    (XCTest: (bare class, method); Swift Testing: the test id)."""
    what: str
    rc: int = 0
    started: Set[object] = field(default_factory=set)
    finished: Set[object] = field(default_factory=set)
    failed: List[object] = field(default_factory=list)
    seconds: Dict[object, float] = field(default_factory=dict)
    held: List[str] = field(default_factory=list)        # Swift Testing failing lines withheld from the output
    unidentified: Optional[str] = None                   # why its failures could not be told apart (they then stand)
    stood: List[str] = field(default_factory=list)       # console names of failures that stand: not a budget judgement
    issues: Dict[str, List[bool]] = field(default_factory=dict)      # console name → per issue: does it carry the marker
    open_issue: Optional[str] = None                     # Swift Testing: the test whose issue's detail lines are being read
    fail_lines: List[bool] = field(default_factory=list)             # Swift Testing: per failing verdict, in order: withheld?
    probe: Counts = field(default_factory=Counts)        # Swift Testing: this process's own verdict lines, counted

    def budget_only(self, name: str) -> bool:
        """Did `name` fail on budget judgements and nothing else? No issue text at all is not a budget."""
        marks = self.issues.get(name, [])
        return bool(marks) and all(marks)

    def split(self, pending: Sequence[object]) -> Tuple[List[object], List[object], List[object]]:
        """`pending` as (passed, left without a verdict, of those: started and never ended)."""
        passed = [t for t in pending if t in self.finished and t not in self.failed]
        left = [t for t in pending if t not in self.finished]
        return passed, left, [t for t in left if t in self.started]


class _QuietRun:
    """The shared state of phase B's processes: one Counts (what was PRINTED, so the summary is what
    the nightly counts), one lock, the spawn function."""

    def __init__(self, b: Bundle, env: Dict[str, str], out: Output, spawn: Spawn, counts: Counts,
                 lock: threading.Lock, tmp: Path) -> None:
        self.b, self.env, self.out, self.spawn, self.counts, self.lock, self.tmp = b, env, out, spawn, counts, lock, tmp
        self.serial = 0

    def _lines(self, proc: subprocess.Popen, on_line: Callable[[str], None]) -> int:
        assert proc.stdout is not None
        for raw in iter(proc.stdout.readline, b""):
            for line in unglue(raw.decode("utf-8", errors="replace").rstrip("\n")):
                on_line(line)
        return proc.wait()

    def _say(self, line: str) -> None:
        with self.lock:
            self.counts.feed(line)
        self.out.line(line)

    def _withhold(self, name: str, hold: str) -> None:
        """A strand's failing line is not a verdict: say what it was, in a line no counter reads as a test."""
        with self.lock:
            self.counts._end(name)
        self.out.line(f"core-lane: {hold}: failed beside the other strands — to be run again alone: {name}")

    def _stands(self, p: _Proc, name: str, line: str, hold: str) -> None:
        """A strand failure that is not a budget judgement: its verdict line is printed and counted, now."""
        p.stood.append(name)
        self.out.line(f"core-lane: {hold}: not a budget judgement (no {BUDGET_MARKER} in every issue) — no second run: {name}")
        self._say(line)

    def _xctest_line(self, p: _Proc, line: str, hold: Optional[str]) -> None:
        issue = XC_ERROR_RE.search(line)
        if issue:                                           # "File.swift:12: error: -[M.C m] : <text>"
            p.issues.setdefault(issue.group(1), []).append(BUDGET_MARKER in line)
        x = xctest_line(line)
        named = XC_NAME_RE.match(x.group(1)) if x else None
        if not (x and named):
            return self._say(line)
        key, verdict = (named.group(1), named.group(2)), x.group(2)
        if verdict is None:
            p.started.add(key)
            return self._say(line)
        p.finished.add(key)
        took = XC_SECONDS_RE.search(line)
        if took:
            p.seconds[key] = float(took.group(1))
        if verdict != "failed":
            return self._say(line)
        if hold and not p.budget_only(x.group(1)):
            return self._stands(p, x.group(1), line, hold)
        p.failed.append(key)
        return self._withhold(x.group(1), hold) if hold else self._say(line)

    def xctest(self, selectors: Sequence[str], hold: Optional[str], what: str) -> _Proc:
        """One XCTest process on `selectors`. `hold` (a strand's name): a failing verdict whose every
        issue is a budget judgement is withheld (the test is owed a run alone); any other stands."""
        p = _Proc(what)
        cmd = ["xcrun", "xctest", "-XCTest", ",".join(selectors), str(self.b.bundle)]
        p.rc = self._lines(self.spawn(cmd, self.env), lambda line: self._xctest_line(p, line, hold))
        return p

    def _swift_issue(self, p: _Proc, line: str) -> None:
        """Follow the console's issue blocks: "✘ Test X recorded an issue at …: text", then its "↳ …"
        detail lines. In a serial process they are X's and nobody else's."""
        opened = ST_ISSUE_RE.search(line)
        if opened:
            p.open_issue = opened.group(1)
            p.issues.setdefault(p.open_issue, []).append(BUDGET_MARKER in line)
        elif p.open_issue and line.lstrip("\u200b ").startswith("↳"):
            p.issues[p.open_issue][-1] = p.issues[p.open_issue][-1] or BUDGET_MARKER in line
        else:
            p.open_issue = None

    def _swift_line(self, p: _Proc, line: str, hold: Optional[str]) -> None:
        self._swift_issue(p, line)
        p.probe.feed(line)                                  # this process's own counter: how many verdicts did it print?
        f = ST_FAIL_RE.search(line)
        verdict = f and " recorded an issue " not in line and " recorded a known issue " not in line and not RUN_SUMMARY_RE.search(line)
        if not (hold and verdict):
            return self._say(line)
        withheld = p.budget_only(f.group(1))
        p.fail_lines.append(withheld)
        if not withheld:
            return self._stands(p, f.group(1), line, hold)
        p.held.append(line)
        self._withhold(f.group(1), hold)

    def swift(self, ids: Sequence[str], hold: Optional[str], what: str) -> _Proc:
        """One Swift Testing process, `--no-parallel`, on exactly `ids`, with an event stream that says
        which test ids started, ended and failed. A strand's failing verdicts are matched to the stream's
        failed ids by ORDER (a serial process ends its tests in the order it prints them); when the two
        do not agree, or the stream is missing, nothing is guessed (`_reconcile`)."""
        p = _Proc(what)
        with self.lock:
            self.serial += 1
            stream = self.tmp / f"events-{self.serial}.jsonl"
        cmd = [str(self.b.pm / "swiftpm-testing-helper"), "--test-bundle-path", str(self.b.exe), str(self.b.exe),
               "--testing-library", "swift-testing", "--no-parallel", "--filter", swift_id_regex(ids),
               "--event-stream-output-path", str(stream), "--event-stream-version", EVENT_STREAM_VERSION]
        p.rc = self._lines(self.spawn(cmd, self.env), lambda line: self._swift_line(p, line, hold))
        v = StreamVerdicts()
        for payload in stream_events(stream, set(ids)):
            v.note(payload)
        p.started, p.finished, p.seconds = set(v.started), set(v.ended), dict(v.seconds)
        self._reconcile(p, ids, [i for i in v.ended_order if i in v.failed], hold)
        return p

    def _reconcile(self, p: _Proc, ids: Sequence[str], failed: List[str], hold: Optional[str]) -> None:
        """Turn what the console and the event stream said into: which ids are owed a run alone
        (`p.failed`), and — when they cannot be reconciled — why not (`p.unidentified`)."""
        verdicts = p.probe.total
        if not p.started and verdicts:
            # The stream names no test although tests ran: it never reached the disk. Reading that as
            # "nothing finished" would run every test again and count it twice: the console stands.
            for line in p.held:
                self._say(line)
            p.finished, p.held = set(ids), []
            p.failed = [] if hold or p.rc == 0 else list(ids)       # alone: without ids, none may be called "passed alone"
            self.out.line(f"core-lane: {p.what}: event stream missing — its {verdicts} console verdict(s) stand, nothing is run again")
            if p.rc != 0:
                p.unidentified = (f"{p.what} exited {p.rc} and left no event stream: which tests failed or never "
                                  "finished cannot be told, so nothing was run again alone")
            return
        if not hold:
            p.failed = failed
            return
        if len(failed) != len(p.fail_lines):
            # Which tests failed cannot be told from names alone (a display name is not an id). Refuse to
            # guess: the withheld lines are printed after all, and count as the failures they are.
            for line in p.held:
                self._say(line)
            p.unidentified = (f"{p.what} printed {len(p.fail_lines)} failed test(s) but its event stream names {len(failed)}: "
                              "they could not be run again alone and stand as failed")
            p.failed, p.held = [], []
            return
        p.failed = [ident for ident, withheld in zip(failed, p.fail_lines) if withheld]


class _QuietStrands:
    """Phase B's bookkeeping across its strands: which tests are owed a run alone and why, what was
    measured, and every RED reason that is not a count. Strand threads share it under `guard`."""

    def __init__(self, run: _QuietRun, plan: PhasePlan, strands: List[List[QuietUnit]]) -> None:
        self.run, self.plan, self.strands = run, plan, strands
        self.retry_x: Dict[object, str] = {}          # test → why it is run alone
        self.retry_s: Dict[object, str] = {}
        self.measured: Dict[str, float] = {}
        self.extra: List[str] = []
        self.rcs: List[Tuple[str, int]] = []
        self.stood: Set[str] = set()                  # console names of strand failures that were not budget judgements
        self.failed_alone: Set[str] = set()           # console names of the failures the alone pass printed
        self.guard = threading.Lock()
        others = len(strands) - 1
        self.beside = f"failing beside {others} other strand{'s' if others != 1 else ''}"

    def run_strands(self) -> None:
        """Every strand side by side, each on its own worker thread (as in run_phase: the main thread
        holds no lock, so the stop handler can always say what was running)."""
        threads = [threading.Thread(target=self._strand, args=(n, units), daemon=True) for n, units in enumerate(self.strands)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

    def _strand(self, n: int, units: List[QuietUnit]) -> None:
        name = f"strand {n + 1}"
        try:
            xc = [u for u in units if u.kind == "xctest"]
            ids = [u.selectors[0] for u in units if u.kind == "swift"]
            if xc:
                self._strand_xctest(name, xc)
            if ids:
                self._strand_swift(name, ids)
        except Exception as exc:                            # a bug here must not read as "that strand had nothing to say"
            with self.guard:
                self.extra.append(f"{name} was not run to its end by the lane itself ({exc!r}); its tests have no verdict")

    def _strand_xctest(self, name: str, units: List[QuietUnit]) -> None:
        p = self.run.xctest([s for u in units for s in u.selectors], name, f"{name} XCTest")
        self._hand_over(p, [t for u in units for t in u.tests], self.retry_x, f"{name}'s XCTest", (0,))
        with self.guard:
            for u in units:
                if all(t in p.seconds for t in u.tests):
                    self.measured[u.key] = sum(p.seconds[t] for t in u.tests)

    def _strand_swift(self, name: str, ids: List[str]) -> None:
        p = self.run.swift(ids, name, f"{name} Swift Testing")
        self._hand_over(p, ids, self.retry_s, f"{name}'s Swift Testing", (0, NO_TEST_MATCHED))
        with self.guard:
            for ident, took in p.seconds.items():
                self.measured[f"swift:{swift_name(str(ident))}"] = took

    def _hand_over(self, p: _Proc, planned: Sequence[object], retry: Dict[object, str], whose: str,
                   clean: Tuple[int, ...]) -> None:
        """After a strand's process: the tests that failed on budget judgements only, and the ones it
        never finished, are owed a run alone. Its exit code is RED unless it is clean, or 1 with every
        failure owed that run: a failed test explains exit 1 and nothing else — a process that died
        (134, a signal) is reported whatever failed in it, and so is one whose failures stand."""
        _, left, _ = p.split(planned)
        with self.guard:
            retry.update({t: self.beside for t in p.failed})
            retry.update({t: f"{whose} process ended (exit {p.rc}) before it finished" for t in left})
            self.stood.update(p.stood)
            if p.unidentified:
                self.extra.append(p.unidentified)
            explained = p.rc == 1 and p.failed and not p.stood and not p.unidentified
            if p.rc not in clean and not explained:
                self.rcs.append((p.what, p.rc))

    def alone(self) -> List[Tuple[str, str]]:
        """The alone pass: every strand has ended, nothing else of the lane is running. One process per
        framework, one test at a time — the single serial pass, on these tests only. Returns
        (test, why it was run alone) for each that passed."""
        if self.retry_x or self.retry_s:
            self.run.out.line(f"core-lane: phase {self.plan.key}: every strand has ended; running "
                              f"{len(self.retry_x) + len(self.retry_s)} test(s) again ALONE (one at a time, nothing else of the lane running)")
        xc = self._alone([t for t in self.plan.xctest_tests if t in self.retry_x], self.retry_x, "XCTest (alone)",
                         lambda tests: self.run.xctest([f"{c}/{m}" for c, m in tests], None, "XCTest (alone)"),
                         lambda t: f"{t[0]}/{t[1]}")
        st = self._alone([i for i in self.plan.swift if i in self.retry_s], self.retry_s, "Swift Testing (alone)",
                         lambda ids: self.run.swift(ids, None, "Swift Testing (alone)"), lambda i: swift_name(str(i)))
        return xc + st

    def _alone(self, pending: List[object], why: Dict[object, str], what: str,
               start: Callable[[List[object]], _Proc], show: Callable[[object], str]) -> List[Tuple[str, str]]:
        """Run `pending` alone. A test that kills its process here is RED by name, and the rest of the
        list still gets its turn (each round judges or removes at least one test)."""
        passed_alone: List[Tuple[str, str]] = []
        counts = self.run.counts
        while pending:
            printed = len(counts.failed_names)
            p = start(pending)
            self.failed_alone.update(counts.failed_names[printed:])
            self.rcs.append((p.what, p.rc))
            passed, left, running = p.split(pending)
            passed_alone += [(show(t), why[t]) for t in passed]
            if not left or p.rc == 0 or (not running and len(left) == len(pending)):
                break                                       # all judged; or nothing a rerun could change (the count says what is missing)
            self.extra += [f"{what} died (exit {p.rc}) while running {show(t)} — it was run alone after {why[t]}" for t in running]
            pending = [t for t in left if t not in running]
        return passed_alone


def run_quiet_strands(b: Bundle, plan: PhasePlan, out: Output, spawn: Spawn, live: Optional[List["PhaseLive"]],
                      floor_mb: float, jobs: int, timings_path: Optional[Path]) -> PhaseResult:
    """Phase B as `jobs` serial strands, then the alone pass (module header). The returned counts are
    the verdict lines that were printed: one per planned test when nothing was lost."""
    import testbed_strands as ts                  # the timing-cache pattern (scripts/testbed_strands.py)
    env = dict(b.env, **{PHASE_KEY: PHASE_VALUE["B"]})           # a strand IS the serial phase to its tests
    strict = env.get(STRICT_KEY) == "1"
    counts, lock = Counts(), threading.Lock()
    if live is not None:
        live.append(PhaseLive(plan, counts, lock))
    cached = ts.load_timings(timings_path) if timings_path else {}
    flavour = b.products.name.lower() + "|"       # debug and release times differ several-fold
    seconds = {k[len(flavour):]: v for k, v in cached.items() if k.startswith(flavour)}
    strands = deal(quiet_units(plan), jobs, seconds)
    out.line(f"core-lane: phase {plan.key} ({plan.title}{', ' + STRICT_KEY + '=1' if strict else ''}): "
             f"{plan.expected} tests planned ({plan.xctest_count} XCTest + {len(plan.swift)} Swift Testing)")
    out.line(f"core-lane: phase {plan.key} runs as {len(strands)} serial strands (--quiet-jobs {jobs}); a test whose only failures beside "
             "the others are budget judgements is run again alone before it is judged — "
             + "; ".join(f"strand {n + 1}: {sum(u.count for u in units)} tests, ~{sum(seconds.get(u.key, 0.0) for u in units):.0f} s recorded"
                         for n, units in enumerate(strands)))
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="core-lane-strands-") as tmp:
        q = _QuietStrands(_QuietRun(b, env, out, spawn, counts, lock, Path(tmp)), plan, strands)
        q.run_strands()
        passed_alone = q.alone()
    if timings_path:
        cached.update({flavour + k: round(v, 2) for k, v in q.measured.items()})
        ts.save_timings(timings_path, cached)
    peak = _children_peak_mb()
    return PhaseResult(plan, counts, sorted(q.rcs), time.monotonic() - t0, strict, peak if peak > floor_mb else 0.0,
                       strands=len(strands), passed_alone=passed_alone, extra=q.extra,
                       failed_alone=q.failed_alone, stood=q.stood)


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
            + (f", {r.strands} strands, {len(r.passed_alone)} passed alone after failing beside the others" if r.strands else "")
            + (f", largest test process so far {r.peak_mb:.0f} MB" if r.peak_mb else ""))


def amber_lines(r: PhaseResult) -> List[str]:
    """One line per test that is green only because it was run again alone: drift, said out loud."""
    return [f"core-lane: AMBER — phase {r.plan.key} ({r.plan.title}): passed alone after {why}: {name}"
            for name, why in r.passed_alone]


def report_lines(results: Sequence[PhaseResult]) -> List[str]:
    """What the lane says of its phases once they have run: each one's summary line, then every AMBER."""
    return [summary_line(r) for r in results] + [line for r in results for line in amber_lines(r)]


@dataclass(frozen=True)
class SourceCounts:
    """What the test SOURCE declares (scan_source): the listing's independent witness."""
    xctest: int
    swift: int
    xctest_quiet: int
    swift_quiet: int


# How far the built bundle's listing may differ from the source count, per number: 2 %, at least 3.
# Why not exact: the source side is a lexer, not the compiler. It counts a test function once however
# the bundle lists it, misses a test declared by a macro or inside `#if`, and reads a suite's mark by
# type NAME. Measured 2026-11-21 on this tree: XCTest 230 listed / 230 in source, Swift Testing
# 2416 / 2407 (0.4 %: nine tests the lexer does not see), quiet 104 / 104 and 150 / 150. On its first
# run the check found the scanner reading a mark out of a comment (154 against 150). What it is for is two orders larger: a
# framework's listing that came back empty or cut short, or the marks lost (review F1, F2).
SOURCE_TOLERANCE = 0.02
SOURCE_SLACK = 3


def listing_problems(listing: Listing, witness: Optional[SourceCounts]) -> List[str]:
    """Why an UNFILTERED run must not start on this listing (empty: it may)."""
    n_xc = sum(map(len, listing.xctest.values()))
    n_xc_quiet = sum(len(listing.xctest[c]) for c in listing.xctest_quiet if c in listing.xctest)
    listed = (("XCTest tests", n_xc), ("Swift Testing tests", len(listing.swift)),
              ("quiet-machine XCTest tests", n_xc_quiet), ("quiet-machine Swift Testing tests", len(listing.swift_quiet)))
    out = [f"the bundle lists ZERO {what} — a listing that lost them must not read as nothing to "
           + ("judge strictly" if "quiet" in what else "run") for what, n in listed if n == 0]
    if witness is not None:
        source = (witness.xctest, witness.swift, witness.xctest_quiet, witness.swift_quiet)
        for (what, n), s in zip(listed, source):
            allowed = max(SOURCE_SLACK, int(s * SOURCE_TOLERANCE))
            if n and abs(n - s) > allowed:
                out.append(f"the bundle lists {n} {what} but the test source declares {s} (allowed difference {allowed}) "
                           "— a stale or cut-short listing, or marks the build lost")
    return out


def run_lane(products: str, regex: Optional[str] = None, out: Optional[Output] = None, spawn: Spawn = _spawn,
             lister: Callable[[Bundle], Listing] = list_bundle, live: Optional[List[PhaseLive]] = None,
             witness: Optional[Callable[[], SourceCounts]] = None,
             quiet_jobs: int = 1, timings: Optional[Path] = None) -> int:
    """List, split, run phase A then phase B, print one summary line per phase and the verdict.
    `witness` (main always passes it) is the source count an unfiltered listing is cross-checked against.
    `quiet_jobs`: phase B's strands (1: the single serial pass; main passes --quiet-jobs or the default);
    `timings`: the cache the deal reads and writes (None: no cache, every test weighs the same)."""
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
    if not regex:
        counts = witness() if witness is not None else None
        if counts is not None:
            out.line(f"core-lane: the test source declares {counts.xctest} XCTest + {counts.swift} Swift Testing tests, "
                     f"{counts.xctest_quiet} + {counts.swift_quiet} of them quiet-machine")
        refused = listing_problems(listing, counts)
        for r in refused:
            out.line(f"core-lane: RED — {r}; no test was run")
        if refused:
            return EXIT_COUNT
    before_tests = _children_peak_mb()            # the build and the listings, if they were children of this process
    results = [run_phase(b, plan, regex, out, spawn, live, before_tests, quiet_jobs, timings) if plan.expected else
               PhaseResult(plan, Counts(), [], 0.0, False) for plan in (a, bq)]
    problems = [p for r in results for p in r.problems]
    for line in report_lines(results):
        out.line(line)
    total = sum(r.counts.total for r in results)
    expected = sum(r.plan.expected for r in results)
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
# TimingBudget.swift) or take one. The pure rules are not here — `TimingBudget.judge`, `judgeGrowth`,
# `judgeRelative`, `debugCeiling(_:environment:)` compute a verdict from numbers handed to them, and
# their unit tests inject every number and measure nothing; a test that feeds them a REAL measurement
# reaches `measureThreadCPUTime` / a clock (below) or hands the verdict to a helper that is here.
JUDGING_HELPERS = ("expectWithinTimingBudget", "expectWithinReferenceTimingBudget", "recordTimingJudgement",
                   "assertTimingJudgements", "expectRatio", "judgeNow", "loadAwareDebugCeiling",
                   "measureThreadCPUTime", "interleavedMinimumCPUTime", "expectBudget", "XCTAssertBudget")
JUDGING_RE = re.compile(r"\b(" + "|".join(JUDGING_HELPERS) + r")\b")
RESIDENT_RE = re.compile(r"\b(resident_size|resident_size_max|phys_footprint|mach_task_basic_info|task_vm_info)\b")
QUIET_MARK_RE = re.compile(r"\.quietMachine\b")
QUIET_BASE_RE = re.compile(r"\bQuietMachineXCTestCase\b")
# Where the helpers are defined: their own bodies name each other and are not tests.
HELPER_FILES = ("TimingBudgetExpectations.swift", "TimingBudgetXCTestSupport.swift", "QuietMachine.swift")

# A BARE wall-time assertion (review F4): no helper, just a clock reading compared in an assertion —
# `#expect(elapsed < .seconds(2))`, `XCTAssertLessThan(elapsed, 5.0)`, two `clock.measure` windows
# compared. A heuristic, and it errs toward flagging: an assertion that orders (`<` `>` `<=` `>=`,
# XCTAssertLess…/Greater…) something read from a clock — in the assertion itself, or through a local
# whose initializer read one or called a helper that reads one (`let d = profile { … }`), transitively.
# A reviewed comparison that is NOT a budget (a lower bound
# on a deliberate delay, two timestamps compared as data) is let through one line at a time with
#     // quiet-machine: not a budget — <why>
# on the assertion's line or the line above it.
CLOCK_RE = re.compile(r"\.measure\b|\bContinuousClock\b|\bSuspendingClock\b|\bclock\s*\.\s*now\b|\btimeIntervalSince(?:Now\b|\s*\()"
                      r"|\bCFAbsoluteTimeGetCurrent\b|\bDispatchTime\s*\.\s*now\b|\bsystemUptime\b|\.duration\s*\(\s*to\b"
                      r"|\bmach_absolute_time\b|\bclock_gettime\w*\b|\bcurrentThreadCPUTime\b")
ASSERT_RE = re.compile(r"(#expect|#require|\bXCTAssert\w*|\bprecondition)\s*\(")
ORDERING_RE = re.compile(r"(?<![-=<>])\s(<=?|>=?)\s(?![=>])")
ORDERING_ASSERT_RE = re.compile(r"XCTAssert(Less|Greater)Than")
LOCAL_RE = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\b[^=\n{]*=(?!=)([^\n]*)")
OPT_OUT = "quiet-machine: not a budget"


def bare_time_assertions(text: str, masked: str, start: int, end: int,
                         clock_helpers: Sequence[str] = ()) -> List[Tuple[int, str]]:
    """[(line number, what it compares)] for the ordering assertions on a clock reading in
    masked[start:end] that carry no opt-out comment. `masked` has strings and comments blanked, so a
    message that only prints the time is not a comparison; `text` is read for the opt-out.
    `clock_helpers`: names of helpers visible here whose bodies read a clock."""
    body = masked[start:end]
    # a CALL of the helper as a free or Self./self. function — never another object's member of that name
    reads_clock = CLOCK_RE if not clock_helpers else re.compile(
        CLOCK_RE.pattern + r"|(?:(?<![\w.])|\b[Ss]elf\s*\.\s*)(?:" + "|".join(map(re.escape, sorted(clock_helpers))) + r")\s*[({]")
    return _bare_time_assertions(text, masked, start, end, body, reads_clock)


def _bare_time_assertions(text: str, masked: str, start: int, end: int, body: str,
                          CLOCK_RE: "re.Pattern[str]") -> List[Tuple[int, str]]:
    if not CLOCK_RE.search(body):
        return []
    timed: Set[str] = set()
    locals_ = [(m.group(1), m.group(2)) for m in LOCAL_RE.finditer(body)]
    grew = True
    while grew:                                    # a local is timed when its initializer reads a clock or a timed local
        grew = False
        for name, rhs in locals_:
            if name not in timed and (CLOCK_RE.search(rhs) or any(re.search(rf"\b{re.escape(t)}\b", rhs) for t in timed)):
                timed.add(name)
                grew = True
    found: List[Tuple[int, str]] = []
    for m in ASSERT_RE.finditer(body):
        open_paren = start + m.end() - 1
        depth, k = 0, open_paren
        while k < end:
            if masked[k] == "(":
                depth += 1
            elif masked[k] == ")":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        expr = masked[open_paren:k + 1]
        if not (ORDERING_RE.search(expr) or ORDERING_ASSERT_RE.match(m.group(1))):
            continue
        clock = CLOCK_RE.search(expr)
        via = clock.group(0).strip(". (") if clock else next((t for t in sorted(timed) if re.search(rf"\b{re.escape(t)}\b", expr)), None)
        if via is None:
            continue
        at = start + m.start()
        line_start = text.rfind("\n", 0, at) + 1
        above_start = text.rfind("\n", 0, max(line_start - 1, 0)) + 1
        line_end = text.find("\n", at)
        if OPT_OUT in text[above_start:len(text) if line_end < 0 else line_end]:
            continue
        found.append((text.count("\n", 0, at) + 1, via))
    return found


@dataclass
class SourceScan:
    counts: SourceCounts
    violations: List[str]


def scan_source(tests_root: Path) -> SourceScan:
    """One pass over the test source under `tests_root`, for two readers:

    * `violations` (the sensor-lane pin, `check`): a test that reaches a judging or resident-size
      helper, or makes a bare wall-time assertion — in its own body, or through a helper declared in
      its file, in a type of the same name, or in a shared *Support*/*Helpers* file (sensor_lane.py's
      visibility rule) — without the quiet-machine mark (`.quietMachine` on its @Test or on a suite
      above it; for XCTest, the class inherits QuietMachineXCTestCase);
    * `counts` (run_lane's witness): how many tests each framework declares and how many carry the mark.

    Source scan only; memory: every test file's text and declarations at once (a few MB)."""
    import sensor_lane as sl                      # the lexer and declaration parser (scripts/sensor_lane.py)
    parsed = []
    for path in sl.swift_files(tests_root):
        text = path.read_text(encoding="utf-8", errors="replace")
        masked = sl.mask(text)
        parsed.append((path, text, masked, sl.parse(text, masked)))

    shared = lambda path: bool(re.search(r"(Support|Helpers?)\.swift$", path.name))
    is_helper = lambda d: d.kind == "func" and not d.is_test and not d.local and len(d.name) >= 2
    homes = lambda path, d: [("file", str(path))] + ([("type", d.type_path[-1])] if d.type_path else []) \
        + ([("shared", "")] if shared(path) else [])
    visible = lambda path, tp: [("file", str(path)), ("shared", "")] + [("type", t) for t in tp]

    def calls(body: str, names: Set[str], exclude: str) -> bool:
        """Does (masked) `body` name one of `names`? Any length: a helper called `ms` counts
        (sensor_lane's own matcher skips names under four letters)."""
        names = names - {exclude}
        return bool(names) and bool(re.search(r"\b(?:" + "|".join(map(re.escape, sorted(names))) + r")\b", body))

    def closure(direct) -> Dict[Tuple[str, str], Set[str]]:
        """Helper names by scope: those `direct(path, text, masked, d)` holds for, and every helper that
        calls one it can see."""
        found: Dict[Tuple[str, str], Set[str]] = {}
        waiting = []
        for path, text, masked, decls in parsed:
            if path.name in HELPER_FILES:
                continue
            for d in decls:
                if not is_helper(d):
                    continue
                if direct(path, text, masked, d):
                    for k in homes(path, d):
                        found.setdefault(k, set()).add(d.name)
                else:
                    waiting.append((path, d, masked[d.start:d.end]))
        grew = True
        while grew:
            grew, still = False, []
            for path, d, body in waiting:
                names = set().union(*(found.get(k, set()) for k in visible(path, d.type_path)))
                if calls(body, names, d.name):
                    for k in homes(path, d):
                        found.setdefault(k, set()).add(d.name)
                    grew = True
                else:
                    still.append((path, d, body))
            waiting = still
        return found

    # helpers that read a clock AND return a number or a duration (`func ms(_ body:) -> Double`, `profile`
    # that calls it): a local they initialize is a clock reading. A helper that only uses a clock inside
    # (a poll with a deadline that returns Bool, a loader) hands back no time to compare.
    returns_a_time = lambda masked, d: bool(re.search(
        r"->[^{]*\b(Duration|Double|TimeInterval|CFAbsoluteTime|Float|U?Int(?:64)?)\b", masked[d.start:d.body_start]))
    clock_helpers = closure(lambda path, text, masked, d: returns_a_time(masked, d)
                            and bool(CLOCK_RE.search(masked[d.start:d.end])))

    def reason(path: Path, text: str, masked: str, d) -> Optional[Tuple[str, int]]:
        """(what it reaches, line) when this declaration itself judges time or resident size."""
        body = masked[d.start:d.end]
        m = JUDGING_RE.search(body) or RESIDENT_RE.search(body)
        if m:
            return m.group(1), text.count("\n", 0, d.start + m.start()) + 1
        names = set().union(*(clock_helpers.get(k, set()) for k in visible(path, d.type_path))) - {d.name}
        bare = bare_time_assertions(text, masked, d.start, d.end, sorted(names))
        return (f"a bare assertion on a clock reading ({bare[0][1]})", bare[0][0]) if bare else None

    carriers = closure(lambda path, text, masked, d: reason(path, text, masked, d) is not None)
    def attributes(masked: str, start: int) -> str:
        """The attribute run directly above a declaration (back to the previous `}` / `;` / `{`), with
        comments and strings blanked: a comment that mentions the mark is not the mark."""
        back = masked[max(0, start - 800):start]
        cut = max(back.rfind("}"), back.rfind(";"), back.rfind("{"))
        return back[cut + 1:]

    marked_types: Set[str] = set()                 # suites that carry the mark, by type name (any file)
    for path, text, masked, decls in parsed:
        for d in decls:
            if d.kind == "type" and (QUIET_MARK_RE.search(attributes(masked, d.start))
                                     or QUIET_BASE_RE.search(masked[d.start:d.body_start])):
                marked_types.add(d.name)
    bad: List[str] = []
    n = {"xctest": 0, "swift": 0, "xctest_quiet": 0, "swift_quiet": 0}
    seen: Set[Tuple[str, str, str]] = set()        # a test declared in two extensions of one type is one test
    for path, text, masked, decls in parsed:
        for d in decls:
            if d.kind != "func" or not d.is_test:
                continue
            own = masked[d.attr_start if d.attr_start >= 0 else d.start:d.start]
            marked = bool(QUIET_MARK_RE.search(own)) or any(t in marked_types for t in d.type_path)
            ident = ("/".join(d.type_path), d.name, d.params)
            if ident not in seen:
                seen.add(ident)
                kind = "xctest" if d.params == "xctest" else "swift"
                n[kind] += 1
                n[kind + "_quiet"] += marked
            if marked or path.name in HELPER_FILES:
                continue
            why = reason(path, text, masked, d)
            if why is None:
                names = set().union(*(carriers.get(k, set()) for k in visible(path, d.type_path)))
                if not calls(masked[d.start:d.end], names, d.name):
                    continue
                why = ("a helper that judges time or resident size", text.count("\n", 0, d.start) + 1)
            how = ("make the class inherit QuietMachineXCTestCase" if d.params == "xctest"
                   else "add .tags(.quietMachine) to its @Test (or its @Suite)")
            escape = (f"; if that comparison is not a budget, write `// {OPT_OUT} — <why>` on its line"
                      if why[0].startswith("a bare assertion") else "")
            bad.append(f"{path.relative_to(tests_root)}:{why[1]} {'.'.join(d.type_path)}/{d.name} reaches {why[0]} "
                       f"but is not marked quiet-machine — {how} (QuietMachine.swift){escape}")
    return SourceScan(SourceCounts(n["xctest"], n["swift"], n["xctest_quiet"], n["swift_quiet"]), bad)


def check_tags(tests_root: Path) -> List[str]:
    """The sensor-lane pin: scan_source's violations, one sentence each."""
    return scan_source(tests_root).violations


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
    rn.add_argument("--tests", help="the test SOURCE the listing is cross-checked against on an unfiltered run "
                                    "(default: <package>/Tests/VideoScanCoreTests, else this checkout's)")
    rn.add_argument("--quiet-jobs", type=strand_count, default=None, metavar="K",
                    help="phase B as K serial strands side by side (default min(4, cores/4); 1 = one serial pass); "
                         "never more than physical memory / 8 GB, asked for or not. A test whose only failures "
                         "beside the others are budget judgements ([quiet-budget]) is run again alone before it is judged")
    ls = sub.add_parser("list", help="the quiet-machine tests, read from the built bundle")
    ls.add_argument("--products", required=True)
    ck = sub.add_parser("check", help="source pin: every test that reaches a timing / resident-size helper is marked")
    ck.add_argument("--tests", default=str(CORE_TESTS))
    a = ap.parse_args(argv)
    out = Output()

    if a.cmd == "check":
        scan = scan_source(Path(a.tests))
        for line in scan.violations:
            print(f"✘ {line}")
        c = scan.counts
        print(f"core-lane check: {len(scan.violations)} test(s) judge time or resident size without the quiet-machine mark "
              f"(source: {c.xctest} XCTest + {c.swift} Swift Testing tests, {c.xctest_quiet} + {c.swift_quiet} marked)")
        return 1 if scan.violations else 0

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
    tests_root = Path(a.tests) if a.tests else (Path(a.package_path) / "Tests" / "VideoScanCoreTests" if a.package_path else CORE_TESTS)

    def witness() -> SourceCounts:
        return scan_source(tests_root).counts

    if not a.regex and not tests_root.is_dir():
        out.line(f"core-lane: RED — no test source at {tests_root} to cross-check the bundle's listing against; no test was run")
        return EXIT_COUNT
    jobs, cache = strand_options(a.quiet_jobs)
    return run_lane(products, a.regex, out, live=live, witness=witness, quiet_jobs=jobs, timings=cache)


if __name__ == "__main__":
    sys.exit(main())
