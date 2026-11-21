#!/usr/bin/env python3
"""Run the app's XCTest / Swift Testing suites as K concurrent test-host SHARDS, one summed verdict.

Why (Rick 2026-11-20: "we do not want to serialize when we can parallelize"): the app test lane was
ONE test host running every test one after another (VideoScan-CI.xctestplan: "parallelizable": false).
In-process parallelism starves the main actor (measured), so that stays off; instead each shard is its
own `xcodebuild test-without-building` — its own test-host PROCESS, with its own main thread — and K of
them run at once (K = half the cores). Measured 2026-11-20 on 489 verb tests: one host 162–214 s,
15 hosts 44 s.

How it fits: a shard is one Strand of scripts/testbed_strands.py (the testbed's one fan-out runner:
own process group, log and TMPDIR; a timeout; a strand that dies is a failure, never a gap). This file
adds only what is particular to xcodebuild:

  * DEAL. The unit dealt is a GROUP: one test file's suites (the manifest's entry, or a run_tests Pick),
    because a suite cannot be split across hosts by name and a file's suites share fixtures. Groups
    that name the same suite are merged first (a suite extended in a second file must not run twice).
    Groups go longest-first into the lightest of K shards (LPT — the classic bin-balancing greedy;
    ≈ C++: a std::priority_queue of bins, push the next-heaviest item onto top()). A group's weight is
    the sum of its suites' recorded seconds (the cache below); a suite never measured counts
    DEFAULT_TEST_SECONDS per declared test. Static bins, not the strand runner's dynamic queue: every
    host costs seconds to launch, so K hosts are started once, not one per suite.
  * SERIAL TAIL. A suite that touches state shared ACROSS PROCESSES (every host is the same user:
    the real ~/Library/Application Support/VideoScan, the app's UserDefaults domain, the real catalog
    lock, the GPU) or that asserts a wall-clock budget is named in SERIAL_TAIL with its reason. Those
    groups run in ONE host, alone, after the parallel phase (Strand.serial). Nothing else is serial.
  * FAN-IN. Each shard's log is read with run_tests' own LineParser (XCTest and Swift Testing lines),
    so the counts are the ones a single host would have produced. A shard is RED when a test failed,
    when it timed out or never ran, when xcodebuild exited non-zero without a failing test line (a
    crash or a host that died), when it ran FEWER tests than its groups declare ("ran N of M" — exact,
    per shard), or when a suite it was dealt ran zero tests (read from the shard's own result bundle
    with xcresulttool, which names each test's suite TYPE; the log only has display names). Every
    failure is printed with its shard's log path. Per-suite seconds from the result bundles are
    remembered for the next deal.

Output: every line this file prints starts with "xctest-shards:" (with --stream the shards' own raw
lines are forwarded between them, whole lines, as they are written — run_tests parses those live).
The LAST line is the verdict: "xctest-shards: GREEN|RED: P passed, F failed, S skipped …".
Exit: 0 every shard green · 1 a red shard, or no test ran · 2 usage · 130 interrupted.

usage:
  xctest_shards.py (--xctestrun FILE | --products DIR) [--jobs K] (--all | --plan FILE | Suite…)
                   [--run-dir DIR] [--timeout S] [--timings FILE] [--stream] [--dry-run] [--no-serial-tail]

Memory: logs are read a line at a time; held are the failures (one ≤300-char message each), one
result bundle's test list at a time (≤ ~15 MB of JSON for the whole 14k-test suite in one shard) and
the per-suite table (~2,300 short entries). Worst case ~50 MB. Disk: one run folder per run — K logs
and K result bundles (the caller prunes its runs; standalone keeps the newest KEEP_RUNS).

Tests: tests/test_xctest_shards.py.
"""
from __future__ import annotations

import argparse
import heapq
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))
import testbed_strands as strands  # noqa: E402
import run_tests as rt  # noqa: E402  (LineParser: the one reader of XCTest / Swift Testing lines)

SELF = Path(__file__).resolve()
PREFIX = "xctest-shards: "
TARGET = "VideoScanTests"
DEFAULT_TEST_SECONDS = 0.3                 # a suite never measured: seconds per declared test
SHARD_TIMEOUT = 3600.0                     # one shard's own budget (the whole lane was one hour)
DEFAULT_TIMINGS = Path.home() / "Library" / "Caches" / "videoscan-xctest-timings.json"
RUNS = Path.home() / "Library" / "Caches" / "videoscan-xctest-shards"
KEEP_RUNS = 10
DESTINATION = "platform=macOS,arch=arm64"

# ───────────────────────────────────────────────────────────── the serial tail
#
# THE one table of suites that must not run beside another test host, each with its reason. A group
# (test file) holding any of them runs in the tail: one host, alone, after the parallel shards.
# Each test host is a separate PROCESS of the same user, so what collides is what processes share:
#   real App Support   the suite snapshots or reads the real ~/Library/Application Support/VideoScan
#                      tree; a write there by any other host would convict the wrong test
#   defaults domain    the suite writes UserDefaults.standard — the app's one defaults domain, which
#                      cfprefsd shares between every host — and reads it back
#   timing budget      the suite asserts a wall-clock budget; K hosts at once is not a quiet machine
# Kept honest by tests/test_xctest_shards.py: every name here must be a suite the manifest lists.
REAL_APP_SUPPORT = "real App Support: snapshots the real ~/Library/Application Support/VideoScan tree"
DEFAULTS_DOMAIN = "defaults domain: writes UserDefaults.standard, shared by every test host"
TIMING_SEEN = "timing budget: a wall-clock budget that failed beside other test hosts"
REAL_LOG = "real user state: sizes the real ~/Library/Logs/VideoScan/videoscan.log before and after"
SERIAL_TAIL: Dict[str, str] = {
    # the isolation sensors: before/after snapshots of the real tree (AppSupportSnapshot.take() and kin)
    "AppSupportSnapshotTests": REAL_APP_SUPPORT,
    "CleanupIsolationTests": REAL_APP_SUPPORT,
    "EventsIsolationTests": REAL_APP_SUPPORT,
    "MasterArchivePromoteSensorTests": REAL_APP_SUPPORT,
    "MetadataCacheIsolationTests": REAL_APP_SUPPORT + " (the real metadata cache's size and mtime)",
    "PreviewDiskCacheTests": REAL_APP_SUPPORT + " (the real preview cache folder)",
    "VerifyArchiveCopiesIsolationTests": REAL_APP_SUPPORT + " and reads the real catalog lock's owner",
    "VerifyAudioIsolationTests": REAL_APP_SUPPORT,
    "VerifyVideoIsolationTests": REAL_APP_SUPPORT,
    "PersistentLogTestIsolationTests": REAL_LOG,
    # UserDefaults.standard writers (set / removeObject on the app's own domain, then read back)
    "CaptionOrchestratorQueueTests": DEFAULTS_DOMAIN,
    "HallieAppV2IntegrationTests": DEFAULTS_DOMAIN + " (the Ollama hosts key)",
    "HallieShellCLITests": DEFAULTS_DOMAIN + " (the Ollama hosts key)",
    "HallieTurnExecutorTests": DEFAULTS_DOMAIN + " (the Ollama hosts key)",
    "ReadOnlyVolumeCodex258Tests": DEFAULTS_DOMAIN + " (the read-only volumes key)",
    "ReadOnlyVolumeSettingsTests": DEFAULTS_DOMAIN + " (the read-only volumes key)",
    "ScanLocationVolumeModelTests": DEFAULTS_DOMAIN + " (the scan-target keys)",
    "ScanTargetPersistenceTests": DEFAULTS_DOMAIN + " (the scan-target keys)",
    "ScratchVolumeScreeningTests": DEFAULTS_DOMAIN + " (the volume-role keys)",
    "VolumeRoleTaxonomyMigrationTests": DEFAULTS_DOMAIN + " (the volume-role keys)",
    # wall-clock budgets outside the performance stage that FAILED beside 14 other hosts (each entry: the
    # run that showed it). 162 suites assert a budget (PerformanceLane.debugCeiling, expectWithinTimingBudget);
    # only the ones seen red under load are here — the rest pass with their 3x known-issue margin (GH #208).
    "POIUUIDMigrationTests": TIMING_SEEN + " (rename of 100 profiles x 1,000 files under 1 s; 2026-11-20 run 1)",
    "PreviewDiskCacheFilmstripTests": TIMING_SEEN + " (20k-file filmstrip probes under 5 s; 2026-11-20 run 1)",
    "CatalogLockRobustnessTests": TIMING_SEEN + " (200 lock acquire/release cycles under 0.25 s; 2026-11-20 run 2)",
    "ArchiveOffMainTests": TIMING_SEEN + " (100k records, main-actor work under 400 ms: 416 ms; 2026-11-20 run 3)",
    "FamilyTreeReadOnlyInFlightTests": TIMING_SEEN + " (a 5 s waitUntil deadline on a 20 ms poller; the same shard "
                                                    "run alone passed; 2026-11-20 run 4)",
    # not a budget: a race the load exposes, parked here until the test waits for a FRESH snapshot
    "CleanupTrashRunTests": "load race: its forced archive-volume snapshot was superseded while awaited (any volume "
                            "mount/rename on the Mac invalidates it), so the next line saw a provisional one and the "
                            "waiver test held a file it expected moved (2026-11-20 run 5)",
}
# A manifest stage whose every file runs in the tail.
SERIAL_STAGES: Dict[str, str] = {
    "performance": "timing budget: the performance stage asserts wall-clock budgets",
    "stress": "timing budget: the stress stage loads the machine by design",
}


# ───────────────────────────────────────────────────────────── groups and the deal

@dataclass
class Group:
    """One dealing unit: a test file's suites. selectors: `Suite` (whole) or `Suite/test`."""
    name: str
    selectors: List[str]
    tests: int = 0                         # declared tests (0: unknown)
    exact: bool = True                     # tests is an exact floor: fewer ran = RED
    stage: str = ""
    path: str = ""                         # the test file, relative to the repo (for true_up)

    @property
    def suites(self) -> List[str]:
        """The suite TYPES named (a file-scope test `f()` is not one: it has no type)."""
        return sorted({s.split("/", 1)[0] for s in self.selectors if "/" in s or not s.endswith(")")})

    @property
    def loose(self) -> List[str]:
        """The file-scope tests named by themselves (`f()`, `g(x:)`)."""
        return sorted(s for s in self.selectors if "/" not in s and s.endswith(")"))


# A suite is a Swift TYPE. The manifest's inventory also lists words it met after "class"/"struct" inside
# a @Suite display name ("… effective class and the live-group pick …" → a suite called `and`; also
# `filter`, `rules`): no test belongs to them, and `-only-testing:Target/and` would be a suite that ran
# zero tests. A name that is not UpperCamelCase is not dealt; if it ever were a real type, its file
# would come up short ("ran N of M") — red, never silent.
SWIFT_TYPE_NAME = re.compile(r"^[A-Z_][A-Za-z_0-9]*$")


def real_selector(s: str) -> bool:
    return bool(s) and ("/" in s or s.endswith(")") or bool(SWIFT_TYPE_NAME.match(s)))


FILE_SCOPE_TEST_FUNC = re.compile(r"^(?:(?:private|fileprivate|internal|public|nonisolated)\s+|@\w+\s+)*func\s+test\w*\s*[(<]", re.M)


def true_up(g: Group, text: str, add_loose: bool) -> Group:
    """Make a whole-file group's count a TRUE floor, from the file's source (run_tests' swift_cases):
      * a `func test…` at FILE scope is a helper, never a test — the manifest's inventory counts it
        (2026-11-20: testURL/testDefaults in MediaStreamResolverTests.swift, testConfig in
        MissingAudioFinderTests.swift, one in TestHelpers.swift), so it comes off the count;
      * a Swift Testing `@Test func f()` at FILE scope belongs to no suite: no `-only-testing:Suite`
        runs it (FamilySearchPullTests.swift is 42 of them). With add_loose it is named itself
        (`-only-testing:Target/f()`), so "every test of the manifest" really is every test.
    A group picked by case (`Suite/test`) is left as it is: its count is the picker's."""
    if any("/" in s for s in g.selectors):
        return g
    cases = rt.swift_cases(text)
    helpers = sum(1 for c in cases if not c[0] and c[2] == c[1])
    loose = sorted({c[2] for c in cases if not c[0] and c[2] != c[1]})
    selectors = sorted(set(g.selectors) | set(loose)) if add_loose else list(g.selectors)
    tests = max(g.tests - helpers - (0 if add_loose else len(loose)), 0)
    return Group(g.name, selectors, tests, g.exact, g.stage, g.path)


def true_up_all(groups: Sequence[Group], root: Optional[Path], add_loose: bool) -> List[Group]:
    """true_up for the groups whose file needs it: one with no suite at all, or one whose source has a
    `func test…` in column 0 (a cheap regex first: parsing all 1,200 files would take ~20 s)."""
    out: List[Group] = []
    for g in groups:
        if root is not None and g.path:
            try:
                text = (root / g.path).read_text(encoding="utf-8", errors="replace")
            except OSError:
                text = ""
            if text and (not g.selectors or FILE_SCOPE_TEST_FUNC.search(text)):
                g = true_up(g, text, add_loose)
        if g.selectors:
            out.append(g)
    return out


def groups_from_manifest(manifest: dict, only: Optional[Set[str]] = None, root: Optional[Path] = None) -> List[Group]:
    """Every app (kind xcode) test file of the manifest as a Group; `only`: just the files holding
    one of these suites. With `root` (the checkout) the counts are trued up from the sources and a
    file's file-scope tests are named too (true_up); without it a file with no suite is left out."""
    out: List[Group] = []
    for e in manifest.get("assignments", []):
        if e.get("kind") != "xcode":
            continue
        suites = sorted({s for s in (e.get("suites") or []) if real_selector(s)})
        if only is not None and not (set(suites) & only):
            continue
        out.append(Group(Path(e["path"]).stem, suites, len(e.get("tests") or []), True, e.get("stage") or "", e["path"]))
    return true_up_all(out, root, add_loose=True)


def groups_from_plan(plan: dict, root: Optional[Path] = None) -> List[Group]:
    """run_tests' picks. Their selectors are what the single host would be given (so the two run the
    same tests); only the count is trued up."""
    groups = [Group(str(g["name"]), [str(s) for s in g.get("selectors") or [] if real_selector(str(s))], int(g.get("tests") or 0),
                    bool(g.get("exact", True)), str(g.get("stage") or ""), str(g.get("path") or ""))
              for g in plan.get("groups", [])]
    return true_up_all([g for g in groups if g.selectors], root, add_loose=False)


def merge_shared(groups: Sequence[Group]) -> List[Group]:
    """Groups that name the same suite become one (a suite extended in a second file, or picked whole
    by one file and by case in another): a suite must reach exactly one host. A suite taken whole
    drops its own `Suite/test` selectors. Order kept by first appearance."""
    parent = list(range(len(groups)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    owner: Dict[str, int] = {}
    for i, g in enumerate(groups):
        for s in g.suites:
            if s in owner:
                a, b = find(owner[s]), find(i)
                if a != b:
                    parent[max(a, b)] = min(a, b)
            else:
                owner[s] = i
    merged: Dict[int, List[Group]] = {}
    for i, g in enumerate(groups):
        merged.setdefault(find(i), []).append(g)
    out: List[Group] = []
    for root in sorted(merged):
        gs = merged[root]
        if len(gs) == 1:
            out.append(gs[0])
            continue
        sel = {s for g in gs for s in g.selectors}
        whole = {s for s in sel if "/" not in s}
        sel = {s for s in sel if "/" not in s or s.split("/", 1)[0] not in whole}
        out.append(Group("+".join(g.name for g in gs), sorted(sel), sum(g.tests for g in gs),
                         all(g.exact for g in gs), gs[0].stage if len({g.stage for g in gs}) == 1 else ""))
    return out


def serial_reason(g: Group, table: Optional[Dict[str, str]] = None,
                  stages: Optional[Dict[str, str]] = None) -> Optional[str]:
    table = SERIAL_TAIL if table is None else table
    stages = SERIAL_STAGES if stages is None else stages
    for s in g.suites:
        if s in table:
            return table[s]
    return stages.get(g.stage)


def weight(g: Group, timings: Dict[str, float]) -> float:
    """Seconds this group is expected to take: its suites' recorded seconds; a suite never measured
    takes its share of DEFAULT_TEST_SECONDS per declared test."""
    suites = g.suites
    if not suites:
        return max(g.tests, len(g.selectors)) * DEFAULT_TEST_SECONDS
    known = [timings[f"suite:{s}"] for s in suites if f"suite:{s}" in timings]
    unknown = len(suites) - len(known)
    guess = max(g.tests, len(suites)) * DEFAULT_TEST_SECONDS * (unknown / len(suites)) if unknown else 0.0
    return max(sum(known) + guess, 0.01)


def deal(groups: Sequence[Group], k: int, timings: Dict[str, float]) -> List[List[Group]]:
    """At most k shards, balanced: heaviest group first into the lightest shard (LPT). Deterministic
    (ties by name, then by shard number). Never an empty shard."""
    k = max(1, min(k, len(groups)))
    if not groups:
        return []
    bins: List[List[Group]] = [[] for _ in range(k)]
    heap: List[Tuple[float, int]] = [(0.0, i) for i in range(k)]
    for g in sorted(groups, key=lambda g: (-weight(g, timings), g.name)):
        load, i = heapq.heappop(heap)
        bins[i].append(g)
        heapq.heappush(heap, (load + weight(g, timings), i))
    return [b for b in bins if b]


# ───────────────────────────────────────────────────────────── one shard

def find_xctestrun(products: Path, plan: str = "VideoScan-CI") -> Path:
    """<products>/<Scheme>_<plan>_macosx<sdk>-<arch>.xctestrun — the newest, when an SDK update left two."""
    found = sorted(Path(products).glob(f"*_{plan}_*.xctestrun"), key=lambda p: (p.stat().st_mtime, p.name))
    if not found:
        raise FileNotFoundError(f"no *_{plan}_*.xctestrun in {products} (build-for-testing first)")
    return found[-1]


def shard_cmd(xcodebuild: Sequence[str], xctestrun: Path, selectors: Sequence[str], result: Path,
              target: str = TARGET) -> List[str]:
    """One host: -parallel-testing-enabled NO keeps the tests inside it serial (the main actor), and its
    own -resultBundlePath keeps K xcodebuilds from racing for the default bundle name."""
    return (list(xcodebuild) + ["test-without-building", "-xctestrun", str(xctestrun), "-destination", DESTINATION,
                                "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result)]
            + [f"-only-testing:{target}/{s}" for s in selectors])


@dataclass
class SuiteStats:
    """What a result bundle says ran: (suite type path) → [test count, seconds]; a file-scope test is
    under the empty path, and by its own identifier in `loose`."""
    by_path: Dict[Tuple[str, ...], List[float]] = field(default_factory=dict)
    loose: Set[str] = field(default_factory=set)
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    failures: List[Tuple[str, str]] = field(default_factory=list)      # (identifier, name) of each failed test

    @property
    def total(self) -> int:
        return self.passed + self.failed + self.skipped

    def add(self, identifier: str, seconds: float, result: str = "Passed", name: str = "") -> None:
        # "Expected Failure" is a test that passed with a known issue (the log says "passed … with 1 known
        # issue"); anything that is not a pass or a skip is a failure — an unknown word is never green.
        if result in ("Passed", "Expected Failure"):
            self.passed += 1
        elif result == "Skipped":
            self.skipped += 1
        else:
            self.failed += 1
            self.failures.append((identifier, name or identifier))
        path = tuple(identifier.split("/")[:-1])
        if not path:
            self.loose.add(identifier)
        cell = self.by_path.setdefault(path, [0, 0.0])
        cell[0] += 1
        cell[1] += seconds

    def ran(self, suites: Iterable[str]) -> int:
        want = set(suites)
        return int(sum(c[0] for p, c in self.by_path.items() if want & set(p)))

    def ran_group(self, g: Group) -> int:
        return self.ran(g.suites) + sum(1 for t in g.loose if t in self.loose)

    def seconds(self, suite: str) -> float:
        return sum(c[1] for p, c in self.by_path.items() if suite in p)

    def saw(self, suite: str) -> bool:
        return any(suite in p for p in self.by_path)


def read_suite_stats(bundle: Path, tool: Sequence[str]) -> Optional[SuiteStats]:
    """What a result bundle says ran (`xcresulttool get test-results tests`): every Test Case node with
    its result, seconds and identifier `SuiteType[/Nested]/test`. None when the bundle cannot be read —
    then the shard's log is the only count, and no timing is recorded."""
    if not Path(bundle).exists():
        return None
    try:
        p = subprocess.run(list(tool) + ["get", "test-results", "tests", "--path", str(bundle), "--compact"],
                           capture_output=True, text=True, timeout=300, stdin=subprocess.DEVNULL)
        if p.returncode != 0:
            return None
        tree = json.loads(p.stdout)
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    stats = SuiteStats()
    todo = list(tree.get("testNodes") or [])
    while todo:
        n = todo.pop()
        if n.get("nodeType") == "Test Case":
            ident = n.get("nodeIdentifier") or ""
            if ident:
                # A parameterized test: its own node holds ONE argument's seconds, each `Arguments` child
                # its own (PictureFaultMatrixTests/fault(_:): 11 s on the node, 226 s over 20 arguments).
                args = sum(float(c.get("durationInSeconds") or 0.0) for c in (n.get("children") or [])
                           if c.get("nodeType") == "Arguments")
                stats.add(ident, max(float(n.get("durationInSeconds") or 0.0), args), str(n.get("result") or ""),
                          str(n.get("name") or ""))
            continue
        todo.extend(n.get("children") or [])
    return stats


HOST_STARTED = re.compile(r"^TEST_HOST_STARTED epoch=(\d+(?:\.\d+)?)")


@dataclass
class ShardReport:
    name: str
    log: Path
    groups: List[Group]
    seconds: float = 0.0
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    failures: List[rt.Event] = field(default_factory=list)
    problems: List[str] = field(default_factory=list)     # why RED beyond a failed test
    notes: List[str] = field(default_factory=list)
    launch: Optional[float] = None                        # strand start → the test host is up
    stats: Optional[SuiteStats] = None
    serial: Optional[str] = None

    @property
    def total(self) -> int:
        return self.passed + self.failed + self.skipped

    @property
    def expected(self) -> int:
        return sum(g.tests for g in self.groups if g.exact)

    @property
    def green(self) -> bool:
        return not self.failed and not self.problems


def _log_names(identifier: str, name: str) -> Set[str]:
    """The names run_tests' parser may have given a test the result bundle calls (identifier, name):
    Swift Testing `f()` or `"display name"`, XCTest `Class.method`."""
    last = identifier.split("/")[-1]
    return {name, f'"{name}"', last, identifier.replace("/", "."), identifier.replace("/", ".")[:-2]
            if identifier.endswith("()") else identifier}


def fan_in(name: str, groups: List[Group], result: strands.Result, bundle: Path,
           xcresulttool: Sequence[str]) -> ShardReport:
    """One shard's verdict from its log (LineParser), its exit and its result bundle.

    The COUNTS are the result bundle's when it can be read. The log is one pipe carrying the tests'
    verdict lines and the app's own log lines, and the two get glued mid-line (2026-11-20, 15 hosts:
    4 of 14,244 verdict lines began in the middle of another line, so the parser saw 14,240). The
    bundle is the test host's own record; the log gives the failure messages and the live display."""
    rep = ShardReport(name, result.log, groups, result.seconds, serial=result.strand.serial)
    parser = rt.LineParser()
    started: Optional[float] = None
    try:
        started = os.stat(result.log).st_birthtime
    except (OSError, AttributeError):
        pass
    try:
        with open(result.log, encoding="utf-8", errors="replace") as fh:
            for raw in fh:
                if rep.launch is None and started is not None:
                    m = HOST_STARTED.match(raw)
                    if m:
                        rep.launch = max(0.0, float(m.group(1)) - started)
                for ev in parser.feed(raw):
                    if ev.status == "OK":
                        rep.passed += 1
                    elif ev.status == "SKIPPED":
                        rep.skipped += 1
                    else:
                        rep.failed += 1
                        rep.failures.append(ev)
    except OSError:
        rep.problems.append("its log could not be read")
    ran = not result.timed_out and not (result.rc == 130 and result.seconds == 0.0)
    if ran:
        rep.stats = read_suite_stats(bundle, xcresulttool)
    if rep.stats is not None and rep.stats.total:
        st, in_log = rep.stats, rep.total
        if in_log != st.total:
            rep.notes.append(f"{abs(st.total - in_log)} verdict line(s) garbled in the log; counts are the result bundle's")
        seen = {e.name for e in rep.failures}
        for ident, shown in st.failures:
            if not (_log_names(ident, shown) & seen):
                rep.failures.append(rt.Event("FAILED", ident.replace("/", "."), None,
                                             "its verdict line is garbled in the log — see the result bundle"))
        rep.passed, rep.skipped, rep.failed = st.passed, st.skipped, max(st.failed, len(rep.failures))
    if result.timed_out:
        rep.problems.append(f"TIMEOUT after {result.strand.timeout:g}s (its process group was stopped)")
    elif not ran:
        rep.problems.append("never ran (the run was stopped first)")
    elif result.rc != 0 and not rep.failed:
        rep.problems.append(f"xcodebuild exit {result.rc} with no failed test (a crash, a dead test host "
                            f"or an xcodebuild error)")
    if rep.total < rep.expected:
        rep.problems.append(f"ran {rep.total} of {rep.expected} tests")
    if ran:
        if rep.stats is None:
            rep.notes.append("no per-suite counts (its result bundle could not be read)")
        else:
            silent = [s for g in groups for s in g.suites if not rep.stats.saw(s)]
            if silent:
                rep.problems.append(f"{len(silent)} suite(s) ran zero tests: {', '.join(silent[:8])}"
                                    + (" …" if len(silent) > 8 else ""))
            short = [(g.name, rep.stats.ran_group(g), g.tests) for g in groups
                     if g.exact and 0 < rep.stats.ran_group(g) < g.tests]
            if short:
                rep.problems.append("short: " + ", ".join(f"{n} ran {a} of {b}" for n, a, b in short[:8])
                                    + (" …" if len(short) > 8 else ""))
    return rep


# ───────────────────────────────────────────────────────────── live forwarding

class Follower(threading.Thread):
    """Forwards the shards' logs to stdout as they grow — whole lines only, so two shards never mix
    inside a line. Reads ≤ 1 MB per file per pass (bounded memory). ≈ C++: one thread doing `tail -f`
    over K files with a mutex on the output stream."""

    def __init__(self, logs: Sequence[Path], write: Callable[[str], None], interval: float = 0.25) -> None:
        super().__init__(daemon=True)
        self.logs, self.write, self.interval = list(logs), write, interval
        self.pos: Dict[Path, int] = {}
        self.buf: Dict[Path, bytes] = {}
        self.stopping = threading.Event()

    def pump(self, final: bool = False) -> None:
        for p in self.logs:
            while True:
                try:
                    with open(p, "rb") as fh:
                        fh.seek(self.pos.get(p, 0))
                        chunk = fh.read(1 << 20)
                        self.pos[p] = fh.tell()
                except OSError:
                    break
                data = self.buf.get(p, b"") + chunk
                lines = data.split(b"\n")
                self.buf[p] = lines.pop()
                for ln in lines:
                    text = ln.decode("utf-8", "replace")
                    if not text.startswith("# strand "):            # the strand runner's own header
                        self.write(text + "\n")
                if len(chunk) < (1 << 20):
                    break
            if final and self.buf.get(p):
                self.write(self.buf.pop(p).decode("utf-8", "replace") + "\n")

    def run(self) -> None:
        while not self.stopping.wait(self.interval):
            self.pump()

    def finish(self) -> None:
        self.stopping.set()
        self.join()                        # never pump from two threads: lines would mix
        self.pump(final=True)


# ───────────────────────────────────────────────────────────── the run

def say(text: str) -> None:
    sys.stdout.write(PREFIX + text + "\n")
    sys.stdout.flush()


def plan_shards(groups: Sequence[Group], jobs: int, timings: Dict[str, float], tail: bool = True
                ) -> Tuple[List[List[Group]], List[Tuple[Group, str]]]:
    """(the parallel shards, the serial tail as (group, reason))."""
    groups = merge_shared(groups)
    serial = [(g, serial_reason(g)) for g in groups] if tail else []
    held = [(g, r) for g, r in serial if r]
    names = {id(g) for g, _ in held}
    return deal([g for g in groups if id(g) not in names], jobs, timings), held


def run(groups: Sequence[Group], xctestrun: Path, jobs: int, run_dir: Path, timings_path: Path = DEFAULT_TIMINGS,
        timeout: float = SHARD_TIMEOUT, xcodebuild: Sequence[str] = ("xcodebuild",),
        xcresulttool: Sequence[str] = ("xcrun", "xcresulttool"), stream: bool = False, tail: bool = True,
        target: str = TARGET, keep_results: bool = False) -> int:
    timings = strands.load_timings(timings_path)
    shards, held = plan_shards(groups, jobs, timings, tail)
    run_dir.mkdir(parents=True, exist_ok=True)
    work: List[strands.Strand] = []
    dealt: List[List[Group]] = []
    for i, gs in enumerate(shards):
        sel = [s for g in gs for s in g.selectors]
        work.append(strands.Strand(name=f"shard-{i + 1:02d}", weight_key=f"xctest-shard:{i + 1:02d}",
                                   estimate=sum(weight(g, timings) for g in gs), timeout=timeout,
                                   env={"NSUnbufferedIO": "YES"},
                                   cmd=shard_cmd(xcodebuild, xctestrun, sel, run_dir / f"{len(work):04d}" / "shard.xcresult", target)))
        dealt.append(gs)
    if held:
        gs = [g for g, _ in held]
        reasons = sorted({r.split(":", 1)[0] for _, r in held})
        work.append(strands.Strand(name="serial-tail", weight_key="xctest-shard:tail", timeout=timeout,
                                   estimate=sum(weight(g, timings) for g in gs), env={"NSUnbufferedIO": "YES"},
                                   serial=f"{sum(len(g.suites) for g in gs)} suites that must not run beside "
                                          f"another test host ({', '.join(reasons)})",
                                   cmd=shard_cmd(xcodebuild, xctestrun, [s for g in gs for s in g.selectors],
                                                 run_dir / f"{len(work):04d}" / "shard.xcresult", target)))
        dealt.append(gs)
    n_suites = sum(len(g.suites) + len(g.loose) for gs in dealt for g in gs)
    n_tests = sum(g.tests for gs in dealt for g in gs)
    say(f"{n_suites} suites, ~{n_tests} tests → {len(shards)} test hosts at once (jobs {jobs})"
        + (f" + a serial tail of {sum(len(g.suites) for g, _ in held)} suites in one host" if held else "")
        + f" · logs {run_dir}")
    for g, r in held:
        say(f"serial tail: {', '.join(g.suites)} — {r}")
    if not work:
        say("RED: nothing to run")
        return 1

    lock = threading.Lock()

    def write(text: str) -> None:
        with lock:
            sys.stdout.write(text)
            sys.stdout.flush()
    follower = Follower([run_dir / f"{i:04d}" / "strand.log" for i in range(len(work))], write) if stream else None
    runner = strands.Runner(run_dir, jobs=jobs, timings_path=timings_path)
    t0 = time.monotonic()
    if follower:
        follower.start()
    try:
        results = runner.run(work)
    except KeyboardInterrupt:
        if follower:
            follower.finish()
        say("RED: interrupted — every shard's process group was stopped; the run is incomplete")
        return 130
    if follower:
        follower.finish()
    wall = time.monotonic() - t0

    reports = [fan_in(w.name, gs, r, run_dir / f"{i:04d}" / "shard.xcresult", xcresulttool)
               for i, (w, gs, r) in enumerate(zip(work, dealt, results))]
    for i, rep in enumerate(reports):
        if rep.green and not keep_results:
            # Read and done: a green shard's result bundle is not evidence of anything (the whole suite's
            # bundles are ~700 MB a run). A red shard's stays beside its log. Our own run folder only.
            shutil.rmtree(run_dir / f"{i:04d}" / "shard.xcresult", ignore_errors=True)
    for rep in reports:
        launch = f", host up after {rep.launch:.1f}s" if rep.launch is not None else ""
        say(f"{rep.name}: {rep.passed} passed, {rep.failed} failed, {rep.skipped} skipped "
            f"(ran {rep.total} of {rep.expected}) in {rep.seconds:.1f}s{launch} — "
            + ("GREEN" if rep.green else "RED") + "".join(f" · {p}" for p in rep.problems)
            + "".join(f" · note: {n}" for n in rep.notes)
            + ("" if rep.green else f" · log: {rep.log}"))
    for rep in reports:
        for ev in rep.failures:
            say(f"failed: {ev.name}" + (f" — {ev.message}" if ev.message else "") + f" · {rep.name} log: {rep.log}")

    # Remember each suite's seconds for the next deal (only from bundles that could be read).
    fresh = strands.load_timings(timings_path)             # the strand runner just wrote its own keys
    for rep in reports:
        if rep.stats is not None:
            for g in rep.groups:
                for s in g.suites:
                    if rep.stats.saw(s):
                        fresh[f"suite:{s}"] = round(rep.stats.seconds(s), 3)
    strands.save_timings(timings_path, fresh)

    passed = sum(r.passed for r in reports)
    failed = sum(r.failed for r in reports)
    skipped = sum(r.skipped for r in reports)
    expected = sum(r.expected for r in reports)
    red = [r for r in reports if not r.green]
    par = [r for r in reports if not r.serial]
    longest = max(par, key=lambda r: r.seconds) if par else None
    tail_s = sum(r.seconds for r in reports if r.serial)
    launches = [r.launch for r in reports if r.launch is not None]
    bounds = (f"{len(par)} hosts at once" + (f", longest {longest.name} {longest.seconds:.1f}s" if longest else "")
              + (f", serial tail {tail_s:.1f}s" if held else "")
              + (f", host launch {sum(launches) / len(launches):.1f}s avg" if launches else ""))
    word = "RED" if red or passed + failed + skipped == 0 else "GREEN"
    why = ""
    if red:
        why = f" · {len(red)} red shard(s): {', '.join(r.name for r in red)}"
    elif word == "RED":
        why = " · ZERO tests ran"
    say(f"{word}: {passed} passed, {failed} failed, {skipped} skipped (ran {passed + failed + skipped} of {expected}) "
        f"in {wall:.1f}s — {bounds}{why}")
    return 0 if word == "GREEN" else 1


def prune_runs(root: Path, keep: int = KEEP_RUNS) -> None:
    """Our own run folders only (logs and result bundles), newest `keep` kept."""
    try:
        runs = sorted(p for p in root.iterdir() if p.is_dir())
    except OSError:
        return
    for p in runs[:-keep]:
        shutil.rmtree(p, ignore_errors=True)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--xctestrun", type=Path, help="the .xctestrun build-for-testing wrote")
    src.add_argument("--products", type=Path, help="<DerivedData>/Build/Products (its newest xctestrun of --test-plan)")
    ap.add_argument("--test-plan", default=None, help="with --products (default: the manifest's test_plan)")
    ap.add_argument("--jobs", type=int, default=strands.default_jobs(), help="test hosts at once (default: half the cores)")
    ap.add_argument("--all", action="store_true", help="every app suite the manifest lists")
    ap.add_argument("--plan", type=Path, help='JSON {"groups": [{"name", "selectors", "tests", "exact", "stage"}]}')
    ap.add_argument("--manifest", type=Path, default=SELF.parent / "gauntlet" / "manifest.json")
    ap.add_argument("--root", type=Path, default=SELF.parent.parent,
                    help="the checkout whose test sources true up the counts (default: this script's)")
    ap.add_argument("--keep-results", action="store_true", help="keep every shard's result bundle (default: a red shard's)")
    ap.add_argument("--run-dir", type=Path, default=None)
    ap.add_argument("--timeout", type=float, default=SHARD_TIMEOUT, help="seconds, per shard")
    ap.add_argument("--timings", type=Path, default=DEFAULT_TIMINGS)
    ap.add_argument("--stream", action="store_true", help="forward the shards' own lines live (run_tests reads them)")
    ap.add_argument("--dry-run", action="store_true", help="print the deal and stop")
    ap.add_argument("--no-serial-tail", action="store_true",
                    help="diagnostic: deal the serial-tail suites too (to find out what really collides)")
    ap.add_argument("--xcodebuild", default="xcodebuild", help=argparse.SUPPRESS)
    ap.add_argument("--xcresulttool", default="xcrun xcresulttool", help=argparse.SUPPRESS)
    ap.add_argument("suites", nargs="*", help="suite type names (their test files come from the manifest)")
    a = ap.parse_args(argv)
    if a.jobs < 1:
        ap.error("--jobs must be at least 1")
    if sum(map(bool, (a.all, a.plan, a.suites))) != 1:
        ap.error("name what to run: --all, --plan FILE, or suite names (one of the three)")

    manifest: dict = {}
    if a.plan is None or (a.products and not a.test_plan):
        try:
            manifest = json.loads(a.manifest.read_text())
        except (OSError, ValueError) as e:
            if a.plan is None:
                ap.error(f"cannot read the manifest {a.manifest}: {e}")
    if a.plan is not None:
        try:
            groups = groups_from_plan(json.loads(a.plan.read_text()), a.root)
        except (OSError, ValueError, KeyError, TypeError) as e:
            ap.error(f"cannot read the plan {a.plan}: {e}")
    elif a.all:
        groups = groups_from_manifest(manifest, root=a.root)
    else:
        groups = groups_from_manifest(manifest, set(a.suites), a.root)
        known = {s for g in groups for s in g.suites}
        # A suite the manifest does not list still runs (its count unknown), in a group of its own.
        groups += [Group(s, [s], 0, False) for s in a.suites if s not in known]
    if not groups:
        ap.error("nothing to run: no app suite matched")
    try:
        xctestrun = a.xctestrun or find_xctestrun(a.products, a.test_plan or manifest.get("test_plan") or "VideoScan-CI")
    except FileNotFoundError as e:
        ap.error(str(e))

    if a.dry_run:
        timings = strands.load_timings(a.timings)
        shards, held = plan_shards(groups, a.jobs, timings, not a.no_serial_tail)
        for i, gs in enumerate(shards):
            say(f"shard-{i + 1:02d}: {sum(len(g.suites) for g in gs)} suites, {sum(g.tests for g in gs)} tests, "
                f"~{sum(weight(g, timings) for g in gs):.0f}s")
        for g, r in held:
            say(f"serial tail: {', '.join(g.suites)} — {r}")
        return 0

    run_dir = a.run_dir
    if run_dir is None:
        RUNS.mkdir(parents=True, exist_ok=True)
        prune_runs(RUNS, KEEP_RUNS - 1)
        run_dir = RUNS / f"{time.strftime('%Y%m%d-%H%M%S')}-{os.getpid()}"

    def interrupt(signum, frame):          # TERM / HUP stop the shards the way Ctrl-C does
        raise KeyboardInterrupt(signal.Signals(signum).name)
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, interrupt)
    try:
        return run(groups, xctestrun, a.jobs, run_dir, a.timings, a.timeout, shlex.split(a.xcodebuild),
                   shlex.split(a.xcresulttool), a.stream, not a.no_serial_tail, keep_results=a.keep_results)
    except KeyboardInterrupt:
        say("RED: interrupted — the run is incomplete")
        return 130


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(1)
