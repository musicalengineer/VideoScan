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
    host costs seconds to launch, so K hosts are started once, not one per suite. A file heavier than
    one shard's fair share is dealt suite by suite when its source gives each suite an exact count
    (split_heavy), so one long file does not set the wall time.
  * SERIAL TAIL. A suite that touches state shared ACROSS PROCESSES (every host is the same user:
    the real ~/Library/Application Support/VideoScan, the app's UserDefaults domain, the real catalog
    lock, the GPU) or that asserts a wall-clock budget is named in SERIAL_TAIL with its reason. Those
    groups run in ONE host, alone, after the parallel phase (Strand.serial). Nothing else is serial.
  * FAN-IN. Each shard's log is read with run_tests' own LineParser (XCTest and Swift Testing lines),
    so the counts are the ones a single host would have produced. A shard is RED when a test failed,
    when it timed out or never ran, when xcodebuild exited non-zero without a failing test line (a
    crash or a host that died), when it ran FEWER tests than its groups declare ("ran N of M" — exact,
    per shard), when a suite it was dealt ran zero tests (read from the shard's own result bundle
    with xcresulttool, which names each test's suite TYPE; the log only has display names), or when
    it exited 0 and that bundle cannot be read (nothing then proves each suite ran). A file none of
    whose suites can be named to xcodebuild is RED by name. Every
    failure is printed with its shard's log path. Per-suite seconds from the result bundles are
    remembered for the next deal.

Output: every line this file prints starts with "xctest-shards:" (with --stream the shards' own raw
lines are forwarded between them, whole lines, as they are written — run_tests parses those live).
The LAST line is the verdict: "xctest-shards: GREEN|RED: P passed, F failed, S skipped …".
Exit: 0 every shard green · 1 a red shard, or no test ran · 2 usage · 130 interrupted.

usage:
  xctest_shards.py (--xctestrun FILE | --products DIR) [--jobs K] (--all [--stages A,B|all] | --plan FILE | Suite…)
                   [--run-dir DIR] [--timeout S] [--timings FILE] [--stream] [--dry-run] [--no-serial-tail]
                   [--coverage] [--summary FILE]
  --coverage / --summary are the nightly's (scripts/nightly_local_tests.sh): every host records coverage
  into its own result bundle, kept for the caller to merge, and the run is written as JSON.
  --all leaves the performance and stress stages out (as run_tests' default does); `--stages all` runs
  every stage, those two in the serial tail.

Memory: logs are read a line at a time; held are the failures (one ≤300-char message each), one
result bundle's test list at a time (≤ ~15 MB of JSON for the whole 14k-test suite in one shard) and
the per-suite table (~2,300 short entries). Worst case ~50 MB. Disk: one run folder per run — K logs
and K result bundles (the caller prunes its runs; standalone keeps the newest KEEP_RUNS).

Tests: tests/test_xctest_shards.py.
"""
from __future__ import annotations

import argparse
import contextlib
import heapq
import json
import os
import re
import shlex
import shutil
import signal
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, Iterable, List, NamedTuple, Optional, Sequence, Set, Tuple

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
# The schema of --summary FILE. scripts/nightly_local_tests.sh shards its app phase only through a
# checkout whose copy of this file carries this exact line (it greps for it): an older copy has no
# --summary / --coverage, and that commit gets the nightly's single host instead.
NIGHTLY_SUMMARY_VERSION = 1

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
    "FamilyTreeScaleTests": TIMING_SEEN + " (a 5,000-person pedigree laid out under 500 ms, load-aware ceiling; "
                            "2026-11-20 run 6, load average 50)",
    # the nightly's runs (Release, VIDEOSCAN_TIMING_STRICT=1, coverage on; M5 Ultra, K=15, other agents building)
    "JunkDeleteActionRegressionTests": TIMING_SEEN + " (onAct's deferred work for 10k files inside a 15 s deadline, "
                                                    "and a 5 ms return; 2026-11-21 nightly run 1, load average 40)",
    "VolumeRenameMigrationTests": TIMING_SEEN + " (a 100k-record migration under 15 s; beside 14 hosts its rename "
                                               "candidate was not there after the rebuild it awaited, so the migration "
                                               "aborted before the budget was judged; 2026-11-21 nightly run 1)",
    # the M4 (16 cores, K=8), the nightly's on-demand run of 4fcf28776, Release, strict
    "ArchiveAngelBufferHygieneClearTests": TIMING_SEEN + " (Clear all over a 100k-record catalog, the synchronous part "
                                                        "under 400 ms; 2026-11-21 M4 run, beside 7 other hosts)",
    "VerifyAudioPacketShapeTests": TIMING_SEEN + " (Verify Audio's diagnosis of a one-sample file under one pre-fix "
                                                "levels pass: 8.8 s against 8.3 s, a quiet run is ~0.7x; 2026-11-27 M4 "
                                                "run of 9b45a543c, shard 6 beside 7 other hosts, GH #536)",
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

# A suite is a Swift TYPE. The manifest's inventory also lists words it met after "class"/"struct" inside
# a @Suite display name ("… effective class and the live-group pick …" → a suite called `and`; also
# `filter`, `rules`): no test belongs to them, and `-only-testing:Target/and` would be a suite that ran
# zero tests. A name that is not UpperCamelCase is REJECTED, never passed to xcodebuild: beside real
# suites its file comes up short if it ever was a real type ("ran N of M"), and a file left with
# nothing but rejected names is RED by name (undealable) — never dropped without a word.
SWIFT_TYPE_NAME = re.compile(r"^[A-Z_][A-Za-z_0-9]*$")


class Sel(NamedTuple):
    """What a selector string IS — decoded here and nowhere else (≈ C++: a tagged union).
    suite `Type` · case `Type/test` or `Type/f(x:)` · loose `f()` (a file-scope test, no type) · rejected."""
    kind: str
    text: str

    @property
    def suite(self) -> str:
        return self.text.split("/", 1)[0] if self.kind in ("suite", "case") else ""


def sel(text: str) -> Sel:
    if "/" in text:
        return Sel("case" if text.split("/", 1)[0] else "rejected", text)
    if text.endswith(")"):
        return Sel("loose", text)
    return Sel("suite" if SWIFT_TYPE_NAME.match(text) else "rejected", text)


def real_selector(s: str) -> bool:
    return sel(s).kind != "rejected"


@dataclass
class Group:
    """One dealing unit: a test file's suites. selectors: only what xcodebuild can be given (see Sel);
    rejected: the names that were not (kept so a file left with none is reported, not lost)."""
    name: str
    selectors: List[str]
    tests: int = 0                         # declared tests (0: unknown)
    exact: bool = True                     # tests is an exact floor: fewer ran = RED
    stage: str = ""
    path: str = ""                         # the test file, relative to the repo (for true_up)
    rejected: List[str] = field(default_factory=list)

    @property
    def suites(self) -> List[str]:
        """The suite TYPES named (a file-scope test `f()` is not one: it has no type)."""
        return sorted({sel(s).suite for s in self.selectors} - {""})

    @property
    def loose(self) -> List[str]:
        """The file-scope tests named by themselves (`f()`, `g(x:)`)."""
        return sorted(s for s in self.selectors if sel(s).kind == "loose")

    @property
    def by_case(self) -> bool:
        return any(sel(s).kind == "case" for s in self.selectors)

    @property
    def undealable(self) -> bool:
        """Declares tests, and not one of its names can be given to xcodebuild."""
        return not self.selectors and bool(self.rejected) and self.tests > 0


def make_group(name: str, raw: Iterable[str], tests: int, exact: bool = True, stage: str = "", path: str = "") -> Group:
    raw = sorted({str(x) for x in raw if x})
    return Group(name, [x for x in raw if real_selector(x)], tests, exact, stage, path,
                 [x for x in raw if not real_selector(x)])


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
    if g.by_case:
        return g
    cases = rt.swift_cases(text)
    helpers = sum(1 for c in cases if not c[0] and c[2] == c[1])
    loose = sorted({c[2] for c in cases if not c[0] and c[2] != c[1]})
    selectors = sorted(set(g.selectors) | set(loose)) if add_loose else list(g.selectors)
    tests = max(g.tests - helpers - (0 if add_loose else len(loose)), 0)
    return Group(g.name, selectors, tests, g.exact, g.stage, g.path, g.rejected)


DEBUG_IF = re.compile(r"^\s*#if\s+(!?)DEBUG\s*(?://.*)?$")
DEBUG_IF_ANYWHERE = re.compile(r"^\s*#if\s+!?DEBUG\b", re.M)


def active_source(text: str, debug: bool) -> str:
    """The source as the compiler sees it in one build configuration: the lines of a `#if DEBUG` /
    `#if !DEBUG` branch that is not compiled are blanked (line numbers kept). Any other condition
    (`#if canImport(…)`, a custom flag, an `#elseif`) is not judged: both its branches stay.
    ≈ C++: running only the DEBUG half of the preprocessor."""
    out: List[str] = []
    stack: List[List[bool]] = []           # [this branch is compiled, the condition is plain DEBUG / !DEBUG]
    for line in text.split("\n"):
        t = line.strip()
        if t.startswith("#if"):
            m = DEBUG_IF.match(line)
            stack.append([(m.group(1) == "") == debug, True] if m else [True, False])
        elif t.startswith("#elseif") and stack:
            stack[-1] = [True, False]
        elif t.startswith("#else") and stack:
            if stack[-1][1]:
                stack[-1][0] = not stack[-1][0]
        elif t.startswith("#endif") and stack:
            stack.pop()
        else:
            out.append(line if all(b[0] for b in stack) else "")
            continue
        out.append("")
    return "\n".join(out)


def compiled_count(g: Group, text: str, debug: bool) -> Group:
    """A whole-file group's count less the tests this build configuration does not compile: a test
    inside `#if DEBUG` does not exist in a Release build (2026-11-21, the nightly's Release run:
    TrimSensorTests ran 6 of 7, TrimMediaMatrixTests 10 of 11 — one `#if DEBUG` test each), so
    without this every Release shard holding one would be RED "short" for a test that cannot run."""
    if g.by_case:
        return g
    gone = len(rt.swift_cases(text)) - len(rt.swift_cases(active_source(text, debug)))
    if gone <= 0:
        return g
    return Group(g.name, g.selectors, max(g.tests - gone, 0), g.exact, g.stage, g.path, g.rejected)


def build_configuration_is_debug(xctestrun: Path) -> Optional[bool]:
    """True for a Debug build, False for any other (Release), None when the .xctestrun does not say:
    its product paths are `__TESTROOT__/<Configuration>/…`. None = no `#if DEBUG` adjustment."""
    try:
        found = set(re.findall(r"__TESTROOT__/([A-Za-z0-9_-]+)/", Path(xctestrun).read_text(errors="replace")))
    except OSError:
        return None
    if len(found) != 1:
        return None
    return next(iter(found)) == "Debug"


def true_up_all(groups: Sequence[Group], root: Optional[Path], add_loose: bool,
                debug: Optional[bool] = None) -> List[Group]:
    """true_up for the groups whose file needs it: one with no suite at all, or one whose source has a
    `func test…` in column 0 (a cheap regex first: parsing all 1,200 files would take ~20 s); and, when
    the build configuration is known (`debug`), compiled_count for a file with a `#if DEBUG` in it."""
    out: List[Group] = []
    for g in groups:
        if root is not None and g.path:
            try:
                text = (root / g.path).read_text(encoding="utf-8", errors="replace")
            except OSError:
                text = ""
            if text and debug is not None and DEBUG_IF_ANYWHERE.search(text):
                g = compiled_count(g, text, debug)
            if text and (not g.selectors or FILE_SCOPE_TEST_FUNC.search(text)):
                g = true_up(g, text, add_loose)
        if g.selectors or g.undealable:
            out.append(g)
    return out


def groups_from_manifest(manifest: dict, only: Optional[Set[str]] = None, root: Optional[Path] = None,
                         debug: Optional[bool] = None) -> List[Group]:
    """Every app (kind xcode) test file of the manifest as a Group; `only`: just the files holding
    one of these suites. With `root` (the checkout) the counts are trued up from the sources and a
    file's file-scope tests are named too (true_up); without it a file with no suite is left out."""
    out: List[Group] = []
    for e in manifest.get("assignments", []):
        if e.get("kind") != "xcode":
            continue
        g = make_group(Path(e["path"]).stem, e.get("suites") or [], len(e.get("tests") or []), True,
                       e.get("stage") or "", e["path"])
        if only is not None and not (set(g.selectors) & only):
            continue
        out.append(g)
    return true_up_all(out, root, add_loose=True, debug=debug)


def groups_from_plan(plan: dict, root: Optional[Path] = None, debug: Optional[bool] = None) -> List[Group]:
    """run_tests' picks. Their selectors are what the single host would be given (so the two run the
    same tests); only the count is trued up."""
    groups = [make_group(str(g["name"]), g.get("selectors") or [], int(g.get("tests") or 0),
                         bool(g.get("exact", True)), str(g.get("stage") or ""), str(g.get("path") or ""))
              for g in plan.get("groups", [])]
    return true_up_all([g for g in groups if g.selectors or g.undealable], root, add_loose=False, debug=debug)


def merge_shared(groups: Sequence[Group]) -> List[Group]:
    """Groups that name the same suite — or the same file-scope test — become one (a suite extended in
    a second file, or picked whole by one file and by case in another; `smoke()` at file scope in two
    files is ONE selector): each must reach exactly one host. A suite taken whole drops its own
    `Suite/test` selectors. Order kept by first appearance."""
    parent = list(range(len(groups)))

    def find(i: int) -> int:
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i
    owner: Dict[str, int] = {}
    for i, g in enumerate(groups):
        for s in g.suites + g.loose:
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
        names = {x for g in gs for x in g.selectors}
        whole = {x for x in names if sel(x).kind == "suite"}
        names = {x for x in names if sel(x).kind != "case" or sel(x).suite not in whole}
        out.append(Group("+".join(g.name for g in gs), sorted(names), sum(g.tests for g in gs),
                         all(g.exact for g in gs), gs[0].stage if len({g.stage for g in gs}) == 1 else "",
                         "", sorted({x for g in gs for x in g.rejected})))
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


def split_heavy(groups: Sequence[Group], k: int, timings: Dict[str, float], root: Optional[Path]) -> List[Group]:
    """A file heavier than one shard's fair share (total / k) is dealt suite by suite, so its suites can
    go to different hosts (PictureFaultMatrixTests.swift: five suites, ~240 s). Only when the split is
    exact: the file's source (run_tests' swift_cases) credits every one of its suites with tests and
    the per-suite counts add up to the file's — otherwise the file stays whole. No file is read
    unless it is over the share."""
    if root is None or k < 2 or not groups:
        return list(groups)
    share = sum(weight(g, timings) for g in groups) / k
    out: List[Group] = []
    for g in groups:
        if weight(g, timings) <= share or len(g.suites) < 2 or g.loose or g.by_case or not g.path or not g.exact:
            out.append(g)
            continue
        try:
            cases = rt.swift_cases((root / g.path).read_text(encoding="utf-8", errors="replace"))
        except OSError:
            out.append(g)
            continue
        count = {x: sum(1 for c in cases if c[0] == x) for x in g.suites}
        if min(count.values()) < 1 or sum(count.values()) != g.tests:
            out.append(g)
            continue
        out += [Group(f"{g.name}:{x}", [x], n, True, g.stage, g.path) for x, n in sorted(count.items())]
    return out


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
              target: str = TARGET, coverage: bool = False) -> List[str]:
    """One host: -parallel-testing-enabled NO keeps the tests inside it serial (the main actor), and its
    own -resultBundlePath keeps K xcodebuilds from racing for the default bundle name. coverage: the
    host writes its profile into its own result bundle (the caller merges the K bundles).
    -derivedDataPath <shard folder>/xcode-dd: without it xcodebuild makes ~/Library/Developer/Xcode/
    DerivedData/VideoScan-<hash of the sealed .xctestrun path> per run and nothing removes it (2026-11-24:
    729 folders, 25 GB on the Ultra). run() removes it when the run ends, however it ends."""
    return (list(xcodebuild) + ["test-without-building", "-xctestrun", str(xctestrun),
                                "-derivedDataPath", str(result.parent / "xcode-dd"), "-destination", DESTINATION,
                                "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result)]
            + (["-enableCodeCoverage", "YES"] if coverage else [])
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
    known: int = 0                                                      # of `passed`: result "Expected Failure"
    failures: List[Tuple[str, str]] = field(default_factory=list)      # (identifier, name) of each failed test

    @property
    def total(self) -> int:
        return self.passed + self.failed + self.skipped

    def add(self, identifier: str, seconds: float, result: str = "Passed", name: str = "") -> None:
        # "Expected Failure" is a test that passed with a known issue (the log says "passed … with 1 known
        # issue"); anything that is not a pass or a skip is a failure — an unknown word is never green.
        if result in ("Passed", "Expected Failure"):
            self.passed += 1
            self.known += result == "Expected Failure"
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
    codes: List[str] = field(default_factory=list)        # the same, as words a caller can switch on (PROBLEM_CODES)
    notes: List[str] = field(default_factory=list)
    rc: int = 0
    timed_out: bool = False
    short: Set[str] = field(default_factory=set)          # the groups (files) that ran fewer tests than declared
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


# What `codes` may hold, most telling first (the nightly's reason is the first one any shard has):
#   timeout    the shard hit its own --timeout and its process group was stopped
#   never-ran  the run was stopped before the shard started
#   short      it ran fewer tests than its files declare, or a suite it was dealt ran none
#   died       xcodebuild exited non-zero and no test failed (a crash, a dead host, an xcodebuild error)
#   unproven   exit 0, but its result bundle (or its log) could not be read: nothing proves the count
PROBLEM_CODES = ("timeout", "never-ran", "short", "died", "unproven")


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
    rep = ShardReport(name, result.log, groups, result.seconds, serial=result.strand.serial,
                      rc=result.rc, timed_out=result.timed_out)
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
        rep.codes.append("unproven")
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
        rep.codes.append("timeout")
    elif not ran:
        rep.problems.append("never ran (the run was stopped first)")
        rep.codes.append("never-ran")
    elif result.rc != 0 and not rep.failed:
        rep.problems.append(f"xcodebuild exit {result.rc} with no failed test (a crash, a dead test host "
                            f"or an xcodebuild error)")
        rep.codes.append("died")
    if rep.total < rep.expected:
        rep.problems.append(f"ran {rep.total} of {rep.expected} tests")
        rep.codes.append("short")
    if ran:
        if rep.stats is None and result.rc == 0:
            # Exit 0 and no readable bundle: the log alone cannot say that every suite ran (a silent suite
            # hides behind another's surplus, and glued lines make its count soft). Not provable = RED.
            rep.problems.append("its result bundle could not be read, so no suite's count is proven "
                                "(xcresulttool failed) — the log's count alone is not a green")
            rep.codes.append("unproven")
        elif rep.stats is None:
            rep.notes.append("no per-suite counts (its result bundle could not be read)")
        else:
            silent = [s for g in groups for s in g.suites if not rep.stats.saw(s)]
            if silent:
                rep.problems.append(f"{len(silent)} suite(s) ran zero tests: {', '.join(silent[:8])}"
                                    + (" …" if len(silent) > 8 else ""))
                rep.codes.append("short")
            # A suite at zero is named above; a file of file-scope tests has no suite to name, so its
            # zero is "short" here.
            short = [(g.name, rep.stats.ran_group(g), g.tests) for g in groups
                     if g.exact and rep.stats.ran_group(g) < g.tests and (rep.stats.ran_group(g) > 0 or not g.suites)]
            rep.short = {g.name for g in groups if g.exact and rep.stats.ran_group(g) < g.tests}
            if short:
                rep.problems.append("short: " + ", ".join(f"{n} ran {a} of {b}" for n, a, b in short[:8])
                                    + (" …" if len(short) > 8 else ""))
                rep.codes.append("short")
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


def plan_shards(groups: Sequence[Group], jobs: int, timings: Dict[str, float], tail: bool = True,
                root: Optional[Path] = None) -> Tuple[List[List[Group]], List[Tuple[Group, str]]]:
    """(the parallel shards, the serial tail as (group, reason)). Undealable groups are in neither:
    the caller reports them (run: RED)."""
    groups = merge_shared([g for g in groups if not g.undealable])
    serial = [(g, serial_reason(g)) for g in groups] if tail else []
    held = [(g, r) for g, r in serial if r]
    names = {id(g) for g, _ in held}
    parallel = split_heavy([g for g in groups if id(g) not in names], jobs, timings, root)
    return deal(parallel, jobs, timings), held


def say_undealable(groups: Sequence[Group]) -> int:
    lost = [g for g in groups if g.undealable]
    for g in lost:
        say(f"RED: {g.name}: declares {g.tests} tests and none of its suites can be named to xcodebuild "
            f"({', '.join(g.rejected)}: not a Swift type name) — nothing of it would run")
    return len(lost)


def summary_dict(reports: Sequence[ShardReport], bundles: Sequence[Path], jobs: int, wall: float, lost: int,
                 word: str, planned: Optional[int] = None) -> dict:
    """The run as data (--summary FILE), for a caller that publishes its own row (the nightly). Counts
    are each shard's fan-in counts (its result bundle's when that could be read). `failures` names every
    failed test once: by its bundle identifier when the bundle has it, else as the log named it."""
    failures: List[dict] = []
    for r in reports:
        from_bundle = list(r.stats.failures) if r.stats is not None else []
        known: Set[str] = set()
        for ident, shown in from_bundle:
            failures.append({"id": ident, "name": shown, "shard": r.name})
            known |= _log_names(ident, shown)
        failures += [{"id": "", "name": e.name, "shard": r.name} for e in r.failures if e.name not in known
                     and not (e.message or "").startswith("its verdict line is garbled")]
    read = [r.stats is not None and r.stats.total > 0 for r in reports]
    return {
        "version": NIGHTLY_SUMMARY_VERSION, "verdict": word, "jobs": jobs, "wall_s": round(wall, 1),
        "passed": sum(r.passed for r in reports), "failed": sum(r.failed for r in reports),
        "skipped": sum(r.skipped for r in reports), "expected": sum(r.expected for r in reports),
        # Tests whose bundle result is "Expected Failure" (None when a bundle could not be read). NOT the
        # count of tests that passed with a known issue: a parameterized Swift Testing test that did is
        # plain "Passed" in the bundle (2026-11-21: 18 here, 23 "passed … with N known issues" lines in
        # the logs), so the nightly keeps counting those from the logs.
        "expected_failures": sum(r.stats.known for r in reports if r.stats is not None) if all(read) else None,
        "counts_from": "bundles" if all(read) else ("logs" if not any(read) else "mixed"),
        "undealable_files": lost, "failures": failures,
        # How many hosts the deal started (the parallel shards + the tail). A reader checks it against
        # `shards` and against the run folder: a summary that does not account for every host is no verdict.
        "planned_shards": len(reports) if planned is None else planned,
        "shards": [{"name": r.name, "serial": r.serial, "rc": r.rc, "timed_out": r.timed_out,
                    "seconds": round(r.seconds, 1), "passed": r.passed, "failed": r.failed, "skipped": r.skipped,
                    "expected": r.expected, "green": r.green, "codes": [c for c in PROBLEM_CODES if c in r.codes],
                    "problems": list(r.problems), "notes": list(r.notes), "log": str(r.log),
                    "bundle": str(b), "bundle_read": ok, "suites": sum(len(g.suites) + len(g.loose) for g in r.groups)}
                   for r, b, ok in zip(reports, bundles, read)],
    }


def write_summary(path: Optional[Path], data: dict) -> None:
    """Whole or not at all (a temp file, then a rename): a reader never sees half a verdict."""
    if path is None:
        return
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(data, indent=1, sort_keys=True) + "\n")
    os.replace(tmp, path)


def sqlite3_error():
    import sqlite3
    return sqlite3.Error


class SealRefused(Exception):
    """The test hosts' home could not be sealed: nothing runs (never unsealed)."""


def seal_xctestrun(xctestrun: Path, run_dir: Path) -> Tuple[Path, Path]:
    """(the sealed copy of the .xctestrun, the home it points at). Every test target's host gets
    HOME = CFFIXED_USER_HOME = <per-user temp>/videoscan-shards-home-<pid>-* — a fresh scratch home, so ~/Library/Application Support,
    ~/Library/Logs resolve inside the run, never to Rick's real catalog or logs — but NOT his defaults:
    cfprefsd ignores HOME / CFFIXED_USER_HOME (2026-11-25), so tests keep off .standard themselves
    (VideoScanTests TestPreferences) (DECISIONS 2026-11-22: tests never open the real catalog; the corpus runner's and the
    gauntlet's seal, applied to every app test run). The copy sits BESIDE the original (its paths are
    __TESTROOT__-relative), is a new file (O_EXCL, never through a link) and is removed by the caller;
    the build's own .xctestrun is never modified. xcodebuild itself keeps the real home (its caches).
    Raises SealRefused when the file cannot be read or names no test target."""
    import plistlib
    try:
        with open(xctestrun, "rb") as f:
            plan = plistlib.load(f)
    except (OSError, ValueError, plistlib.InvalidFileException) as e:
        raise SealRefused(f"cannot read {xctestrun} to seal the test hosts' home ({type(e).__name__})")
    import sealed_home
    src = os.environ.get("VIDEOSCAN_SEAL_SOURCE_HOME")       # tests: a fake source; never changes the destination
    made: Optional[Path] = None
    try:
        # The home is made in the per-user temp dir (sealed_home.make_home), NOT under run_dir: a caller's
        # --run-dir may sit anywhere (the M4 suite lane's is ~/m4run/out/<run>/…), and the app's test-host icon
        # guard trusts a test temp root only inside the per-user temp dir, /private/tmp or ~/Library/Caches
        # (TestHostScratch.PinnedRoot; 3 iconGuard tests RED on the M4 2026-11-24). Logs stay in run_dir.
        # mkdtemp makes a new real folder (never a link), and the cleanup removes that same path.
        made = sealed_home.make_home(f"videoscan-shards-home-{os.getpid()}-")
        home = sealed_home.prepare(made, Path(src) if src else None)
    except (sealed_home.Refused, OSError, sqlite3_error()) as e:
        if made is not None:
            shutil.rmtree(made, ignore_errors=True)            # whoever allocates frees, a refusal included
        raise SealRefused(f"cannot prepare the sealed home ({type(e).__name__}: {e})")
    # Temp folders: the test host is launched from this file, not from xcodebuild's environment. TMPDIR reaches
    # child processes (python, shell); Foundation on macOS IGNORES TMPDIR (NSTemporaryDirectory is the system
    # per-user dir — measured 2026-11-23), so the tests' scratch helpers take their root from VIDEOSCAN_TEST_TMP.
    tmp = str(home / "tmp") + "/"
    sealed = {"HOME": str(home), "CFFIXED_USER_HOME": str(home), "TMPDIR": tmp, "VIDEOSCAN_TEST_TMP": tmp}
    targets = [0]

    def patch(value):
        if isinstance(value, list):
            return [patch(v) for v in value]
        if isinstance(value, dict):
            out = {k: patch(v) for k, v in value.items()}
            if "TestBundlePath" in out:
                env = dict(out.get("EnvironmentVariables") or {})
                env.update(sealed)
                out["EnvironmentVariables"] = env
                targets[0] += 1
            return out
        return value
    patched = patch(plan)
    if targets[0] == 0:
        shutil.rmtree(home, ignore_errors=True)
        raise SealRefused(f"{xctestrun} names no test target: nothing to seal")
    dest = xctestrun.with_name(f"{xctestrun.stem}.sealed-{os.getpid()}-{run_dir.name}.xctestrun")
    try:
        fd = os.open(str(dest), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    except OSError as e:
        shutil.rmtree(home, ignore_errors=True)
        raise SealRefused(f"cannot write the sealed copy beside {xctestrun} ({e.strerror})")
    with os.fdopen(fd, "wb") as f:
        plistlib.dump(patched, f)
    return dest, home


def claim_derived_data(run_dir: Path, index: int) -> Tuple[Path, Tuple[int, int]]:
    """<run>/<NNNN>/xcode-dd, made HERE before the shard starts (Codex #360 F1: the cleanup used to remove
    whatever sat at that name, through a symlinked shard folder too): the shard folder is a real folder of
    the run folder's volume (made now or already ours), and xcode-dd is created exclusively. Returns the
    path and its (device, inode), the identity the cleanup checks; SealRefused otherwise."""
    shard = run_dir / f"{index:04d}"
    try:
        root = os.lstat(run_dir)
        with contextlib.suppress(FileExistsError):
            os.mkdir(shard)
        folder = os.lstat(shard)
        if (stat.S_ISLNK(root.st_mode) or not stat.S_ISDIR(folder.st_mode) or folder.st_dev != root.st_dev):
            raise SealRefused(f"{shard} is not a real folder of the run folder's volume: its DerivedData is not made")
        dd = shard / "xcode-dd"
        os.mkdir(dd)                                       # exclusive: a name already there is not ours
        made = os.lstat(dd)
    except OSError as e:
        raise SealRefused(f"cannot make {shard}/xcode-dd as a new folder of its own ({e.strerror})")
    if not stat.S_ISDIR(made.st_mode) or made.st_dev != root.st_dev:
        raise SealRefused(f"{shard}/xcode-dd is not the folder just made")
    return dd, (made.st_dev, made.st_ino)


def free_derived_data(claimed: Sequence[Tuple[Path, Tuple[int, int]]]) -> None:
    """Remove each xcode-dd claim_derived_data made, and only while it is still that folder, reached
    through a shard folder that is not a link (rmtree itself never follows a link inside: fd-based)."""
    for dd, identity in claimed:
        try:
            if stat.S_ISLNK(os.lstat(dd.parent).st_mode):
                continue
            info = os.lstat(dd)
        except OSError:
            continue
        if stat.S_ISDIR(info.st_mode) and (info.st_dev, info.st_ino) == identity:
            shutil.rmtree(dd, ignore_errors=True)


def run(groups: Sequence[Group], xctestrun: Path, jobs: int, run_dir: Path, timings_path: Path = DEFAULT_TIMINGS,
        timeout: float = SHARD_TIMEOUT, xcodebuild: Sequence[str] = ("xcodebuild",),
        xcresulttool: Sequence[str] = ("xcrun", "xcresulttool"), stream: bool = False, tail: bool = True,
        target: str = TARGET, keep_results: bool = False, root: Optional[Path] = None,
        coverage: bool = False, summary: Optional[Path] = None) -> int:
    keep_results = keep_results or coverage        # the caller merges the K bundles' profiles
    timings = strands.load_timings(timings_path)
    shards, held = plan_shards(groups, jobs, timings, tail, root)
    lost = say_undealable(groups)
    run_dir.mkdir(parents=True, exist_ok=True)
    try:
        sealed_run, home = seal_xctestrun(xctestrun, run_dir)
    except SealRefused as e:
        say(f"REFUSED: {e} — no test host is started unsealed")
        write_summary(summary, summary_dict([], [], jobs, 0.0, lost, "RED", planned=0))
        return 1
    say(f"sealed home: every test host runs with HOME = CFFIXED_USER_HOME = {home} (a copy of App Support)")
    claimed: List[Tuple[Path, Tuple[int, int]]] = []
    try:
        return _run_sealed(groups, shards, held, lost, sealed_run, jobs, run_dir, timings_path, timeout, xcodebuild,
                           xcresulttool, stream, target, keep_results, coverage, summary, claimed)
    except SealRefused as e:
        say(f"REFUSED: {e} — no test host is started")
        write_summary(summary, summary_dict([], [], jobs, 0.0, lost, "RED", planned=0))
        return 1
    finally:
        # Each shard's own DerivedData (xcodebuild's Logs, shard_cmd) is regenerable: what this run made goes,
        # whatever the run's end, an interrupt included (review 2026-11-24), and nothing else (Codex #360 F1).
        free_derived_data(claimed)
        with contextlib.suppress(OSError):
            os.unlink(sealed_run)
        import sealed_home
        line = sealed_home.leftovers_line(home / "tmp")
        if line:
            say(line)
        shutil.rmtree(home, ignore_errors=True)       # a copy: the database backups are ~1 GB a run


def _run_sealed(groups, shards, held, lost, xctestrun: Path, jobs: int, run_dir: Path, timings_path: Path, timeout: float,
                xcodebuild: Sequence[str], xcresulttool: Sequence[str], stream: bool, target: str, keep_results: bool,
                coverage: bool, summary: Optional[Path], claimed: List[Tuple[Path, Tuple[int, int]]]) -> int:
    timings = strands.load_timings(timings_path)
    for i in range(len(shards) + (1 if held else 0)):            # each shard's DerivedData, made before any starts
        claimed.append(claim_derived_data(run_dir, i))
    work: List[strands.Strand] = []
    dealt: List[List[Group]] = []
    for i, gs in enumerate(shards):
        sel = [s for g in gs for s in g.selectors]
        work.append(strands.Strand(name=f"shard-{i + 1:02d}", weight_key=f"xctest-shard:{i + 1:02d}",
                                   estimate=sum(weight(g, timings) for g in gs), timeout=timeout,
                                   env={"NSUnbufferedIO": "YES"},
                                   cmd=shard_cmd(xcodebuild, xctestrun, sel, run_dir / f"{len(work):04d}" / "shard.xcresult",
                                                 target, coverage)))
        dealt.append(gs)
    if held:
        gs = [g for g, _ in held]
        reasons = sorted({r.split(":", 1)[0] for _, r in held})
        work.append(strands.Strand(name="serial-tail", weight_key="xctest-shard:tail", timeout=timeout,
                                   estimate=sum(weight(g, timings) for g in gs), env={"NSUnbufferedIO": "YES"},
                                   serial=f"{sum(len(g.suites) for g in gs)} suites that must not run beside "
                                          f"another test host ({', '.join(reasons)})",
                                   cmd=shard_cmd(xcodebuild, xctestrun, [s for g in gs for s in g.selectors],
                                                 run_dir / f"{len(work):04d}" / "shard.xcresult", target, coverage)))
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
        write_summary(summary, summary_dict([], [], jobs, 0.0, lost, "RED", planned=0))
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

    bundles = [run_dir / f"{i:04d}" / "shard.xcresult" for i in range(len(work))]
    reports = [fan_in(w.name, gs, r, b, xcresulttool) for w, gs, r, b in zip(work, dealt, results, bundles)]
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
                if g.name in rep.short:
                    continue               # a file that came up short: its seconds are not the suite's weight
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
    word = "RED" if red or lost or passed + failed + skipped == 0 else "GREEN"
    why = ""
    if red:
        why = f" · {len(red)} red shard(s): {', '.join(r.name for r in red)}"
    elif passed + failed + skipped == 0:
        why = " · ZERO tests ran"
    if lost:
        why += f" · {lost} file(s) could not be dealt (named above)"
    write_summary(summary, summary_dict(reports, bundles, jobs, wall, lost, word, planned=len(work)))
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
    ap.add_argument("--all", action="store_true",
                    help="every app suite the manifest lists, in the stages of --stages")
    ap.add_argument("--stages", default=None, metavar="A,B",
                    help="with --all: manifest stages to run (default: every stage but performance and stress — "
                         "run_tests leaves them out the same way; 'all' = every stage, those two in the serial tail)")
    ap.add_argument("--plan", type=Path, help='JSON {"groups": [{"name", "selectors", "tests", "exact", "stage"}]}')
    ap.add_argument("--manifest", type=Path, default=SELF.parent / "gauntlet" / "manifest.json")
    ap.add_argument("--root", type=Path, default=SELF.parent.parent,
                    help="the checkout whose test sources true up the counts (default: this script's)")
    ap.add_argument("--keep-results", action="store_true", help="keep every shard's result bundle (default: a red shard's)")
    ap.add_argument("--coverage", action="store_true",
                    help="each host records code coverage into its result bundle (-enableCodeCoverage YES; the build "
                         "must have it too) and every bundle is kept: the caller merges them")
    ap.add_argument("--summary", type=Path, default=None, metavar="FILE",
                    help="write the run as JSON (counts, each shard's verdict and problem codes, the failed tests)")
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
    try:
        xctestrun = a.xctestrun or find_xctestrun(a.products, a.test_plan or manifest.get("test_plan") or "VideoScan-CI")
    except FileNotFoundError as e:
        ap.error(str(e))
    # Debug or Release decides which `#if DEBUG` tests exist (compiled_count).
    debug = build_configuration_is_debug(xctestrun)
    if a.plan is not None:
        try:
            groups = groups_from_plan(json.loads(a.plan.read_text()), a.root, debug)
        except (OSError, ValueError, KeyError, TypeError) as e:
            ap.error(f"cannot read the plan {a.plan}: {e}")
    elif a.all:
        groups = groups_from_manifest(manifest, root=a.root, debug=debug)
        if a.stages != "all":
            want = set(a.stages.split(",")) if a.stages else None
            groups = [g for g in groups if (g.stage in want if want is not None else g.stage not in SERIAL_STAGES)]
    else:
        groups = groups_from_manifest(manifest, set(a.suites), a.root, debug)
        known = {s for g in groups for s in g.suites}
        # A suite the manifest does not list still runs (its count unknown), in a group of its own.
        groups += [Group(s, [s], 0, False) for s in a.suites if s not in known]
    if a.stages and not a.all:
        ap.error("--stages goes with --all (a plan or suite names already say what to run)")
    if not groups:
        ap.error("nothing to run: no app suite matched")

    if a.dry_run:
        timings = strands.load_timings(a.timings)
        shards, held = plan_shards(groups, a.jobs, timings, not a.no_serial_tail, a.root)
        say_undealable(groups)
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
                   shlex.split(a.xcresulttool), a.stream, not a.no_serial_tail, keep_results=a.keep_results,
                   root=a.root, coverage=a.coverage, summary=a.summary)
    except KeyboardInterrupt:
        say("RED: interrupted — the run is incomplete")
        return 130


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(1)
