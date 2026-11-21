#!/usr/bin/env python3
"""run_tests.py — the front door Rick types: a smoke (or full) test run, narrated live.

    scripts/run_tests.sh [--smoke | --full] [--unit] [--regression] [--integration] [--perf]
                         [--stress] [--python] [--corpus] [--verbose] [--host m4|ultra|m5pro|m1]
                         [--ref <rev>] [--filter PATTERNS] [--jobs N] [--list] [--dry-run] [--yes] [--force]
    scripts/run_tests.sh --status

A THIN layer over the runners that already exist (Rick 2026-11-19: TestDriver was retired
because it could not keep up with features). It adds only SELECTION and DISPLAY:

  * selection — `--smoke` (default) picks, from scripts/gauntlet/manifest.json AT THE REF,
    1–2 test files per module × stage (the file with the fewest tests ≥ 1, ties by path, plus
    the median-sized one when the group has ≥ 4 files). Module = the app source folder the
    test file's name maps to (VideoScan/VideoScan/<Module>/ by longest basename prefix), Core
    tests → Core/<area>, Python tests → py/<first word>. Nothing to maintain per feature: a
    new test file joins the day the manifest lists it. UI tests are left out (they need the
    GUI session and are broken, GH #408); the hallie stage is the hallie eval's, not a smoke.
    `--full` delegates to what the nightly runs: scripts/nightly_local_tests.sh --on-demand
    (app + Core, Release) and scripts/run_python_tests.sh (PYTHON= an interpreter with pytest),
    on THIS Mac. `--full --host m4` (from the Ultra) runs the M4's everything — scripts/m4_run.sh
    testbed --ref <sha> --wait: the full suite in the M4's GUI session, then the whole real-corpus
    check and proof — and shows the testbed's own summary (counts and words only). `--full --host`
    another Mac is refused (exit 2): app-hosted tests cannot start inside an ssh session; type
    run_tests.sh --full on that Mac. A stage flag with --full is refused too (--full runs every stage).
  * display — a googletest-style stream: [ RUN ] / [ OK ] / [ FAILED ] / [ SKIPPED ] per test
    with --verbose (coloured on a TTY), one line per lane otherwise plus a live [ n/N ] counter.
    The parser reads the three line shapes our runners print (XCTest, Swift Testing, pytest -v)
    and xcodebuild's parallel "Test case '…' passed on" form; nothing to install (no xcbeautify).

  * --filter PATTERNS (2026-11-20, Rick: "like gtest — module.*") — googletest's grammar,
    `Pos1:Pos2-Neg1:Neg2`: ':'-separated globs, the part after the first '-' excludes, matched
    against `Suite.test`. Suite = the Swift type name (a Swift Testing suite by its TYPE name, never
    its display name) or XCTest class, or the Python/shell module stem; test = the function name.
    A pattern without '.' names suites (`Catalog*` = `Catalog*.*`); `Suite.f()` = `Suite.f`.
    The pool is every runnable manifest file of the stages asked (all five without a stage flag;
    a stage flag narrows) — not the smoke's few; the sources at the commit tell which suite holds
    which test. Each lane gets only what matched: -only-testing:VideoScanTests/Suite[/testX |
    /f(x:)] (Swift Testing's identifier, labels included; a parameterized test is one id, all its
    cases), the Core regex, pytest node ids. `--list` shows the matched tests. A filter that
    matches nothing is refused (exit 2) before a worktree, a lock or a build, and says so when
    it matched only tests that cannot run here, or picks a test that is not inside a type (-only-testing
    cannot name it). A filtered lane's plan is exact: it says "ran N of M" and ANY shortfall is RED
    (skipped tests count as ran; parameterized cases may add more). The source parser blanks string
    literals and comments before counting braces (it agrees with the manifest on every Swift file).
  * --jobs N (2026-11-20, DECISIONS "parallel strands") — the app lane runs as N concurrent test HOSTS
    (default: half the cores), each one `xcodebuild test-without-building -xctestrun … -only-testing:…`
    with its own main thread, log and result bundle: <worktree>/scripts/xctest_shards.py on
    scripts/testbed_strands.py deals the selected test files to N shards by their suites' recorded
    seconds, keeps the suites that share state across processes in a serial tail (its SERIAL_TAIL
    table, a reason each), and is RED for a shard that dies, times out, runs fewer tests than its
    files declare or leaves a suite at zero tests. Its lines are parsed here as they come, so the
    display and the counts are the single host's. `--jobs 1` is the single host, as before; so is a
    commit whose worktree has no xctest_shards.py. --full's app lane is inside
    scripts/nightly_local_tests.sh (one script: Core, the Release build, the app suite, the row), which
    since 2026-11-21 runs it through the same xctest_shards.py (half the cores; every stage, the
    performance and stress stages in the serial tail). --full --jobs N is passed to it as
    NIGHTLY_APP_JOBS=N (1 = its single host).
  * --status — every live run_tests on this Mac (pid, filter, commit, slot, lane, n/N, since), the
    three slots (commit, in use or idle, DerivedData size) and, when reachable, who holds the M4
    testbed lock with an estimated finish (that lane's last finished run, else its planned length;
    scripts/m4_run.sh status --json). Every busy refusal prints the same block.

Where it runs: on this Mac, or on --host over `ssh -t` (this file is copied to the host's
~/Library/Caches/videoscan-runall/ and run there with /usr/bin/python3: the host's own
checkout is never touched). Never Rick's checkout or Xcode's DerivedData (CLAUDE.md rule 11;
tests have been seen writing into a checkout, GH #495). The commit: the ref (default: the HEAD
commit of the checkout this script is run from).

Concurrency (2026-11-20, Rick: "we should minimize the lock … the only ones that should lock … is
something that requires a unique resource"). Runs on one Mac go side by side; only these are shared:
  * a SLOT — one side worktree, detached at a commit, + its Debug DerivedData: ~/dev/VideoScan-wt/
    run-all[-2|-3] + ~/Library/Caches/videoscan-runall-dd[-2|-3] (N_SLOTS = 3, the newest three
    commits). A run at a commit some slot is at shares it; else the least recently used slot that
    no live run holds is moved there (fixed paths, so the build is incremental, not clean). Every
    live run holds its slot SHARED (flock) for its life, so a slot in use is never moved or pruned;
    all three held at other commits → busy (exit 3, nothing queued). A dirty slot is never touched:
    it is skipped for the next one and marked REFUSED in --status; refused only if none is usable.
    Every lock fd a run holds is passed to its children (pass_fds): flock lives with the open file,
    so a runner killed with -9 leaves its building/testing child still holding the slot.
  * a BUILD — per slot and lane (app, Core), an exclusive flock held only while building. A second
    run at the same commit prints "waiting for the build of <sha9> (pid N, since HH:MM)", then
    skips the build and tests from the same products. The "built" stamp lives INSIDE the products
    (<DerivedData>/.run_tests-built-app, <Core>/.build/.run_tests-built-core) and holds the commit
    plus a checkout token (HEAD, the worktree's HEAD reflog size, HEAD's mtime): any checkout —
    ours, an older run_tests', anyone's — makes it stale, and deleting the products drops it.
    App tests: xcodebuild test-without-building with this run's own -resultBundlePath. Core tests:
    the built bundle run directly (xctest + swiftpm-testing-helper, see core_exec): `swift test`,
    even --skip-build, takes SwiftPM's .build lock and serialized two runs (measured).
    Python: nothing shared (its own TMPDIR and pytest --basetemp in the run folder, no .pyc writes).
  * the M4 testbed lock (~/m4run/lock), on the M4 only, for the whole run: its daily run has strict
    timing budgets. The old whole-run lock (~/Library/Caches/videoscan-runall/lock) is held SHARED
    by slot 1's users, so a run_tests from an older checkout cannot move run-all under them.
Registry: each live run writes ~/Library/Caches/videoscan-runall/live/<pid>.json (argv, filter, commit,
slot, run folder, lane, n/N, started), updated as it goes and removed on exit, and holds <pid>.lock
exclusive for its life: a reader that can take that lock knows the run is gone (crash, kill -9, reused
pid) and removes both. Each run keeps its own run folder (<stamp>-<mode>-<pid>); the newest-20 prune
never removes a live run's folder.
Over --host the runner is copied to the host as run_tests-<content hash>.py (tmp + mv), so a second
caller never rewrites the file a live host run re-reads.

Corpus lane: only from the Ultra with --host m4 (scripts/corpus_run.sh run check --smoke --wait:
the harness's stratified subset, the smallest file of each codec mix; a first-N --limit picked
multi-GB tapes and ran 40 min on 2026-11-20); elsewhere it says NOT RUN and why. Only the harness's own summary lines are shown.
`--corpus --host m4` alone runs the corpus lane only (no host smoke). A selection with nothing to
run on this Mac (e.g. --corpus without --host m4) is refused before anything is touched (exit 2).

Verdict: a lane is GREEN only with no failure, exit 0, at least one test, and at least half of the
tests its selection planned (all of them under --filter) (a filter that matches nothing exits 0: "selection shrank"). A lane
past its budget is stopped (its process group: TERM, then KILL) and RED, whether or not it prints.

Preflight (on the Mac that runs the lanes, before the worktree or a build): the tools the
selected lanes need — the Metal Toolchain (`xcrun metal --version`; app), ffmpeg + ffprobe (app,
Core, Python), node (Python), a Python with pytest (Python) — probed with /opt/homebrew/bin first
on PATH (an ssh session may not have it). Anything missing is one block ("RicksM5 is missing: …"
with the install command); the lanes that need it are NOT RUN (setup), the others still run, and
the verdict is "NOT READY: setup" (exit 1) unless a lane that ran is RED.

Stopping: Ctrl-C, SIGHUP (a dropped ssh session) and SIGTERM all take the same path — the running
child's process group is stopped (or, over ssh, its one LaunchAgent job booted out) before exit.

Exit: 0 every lane that ran is green · 1 a failure, or a lane that ran zero tests (or under half
its selection), or nothing ran, or NOT READY: setup · 2 usage (also: a --host ref that is not on origin, nothing to run
here, a --filter that matches nothing, --full with a --host other than m4, a stage flag or --filter) · 3 busy (the M4
testbed lock, all three slots held at other commits, or the M4's nightly window without --force) · 130 interrupted (the
caller of a --host run then skips its corpus step, as it does on 2 and 3).

Memory: output is streamed line by line; held are the failure names and one message line each
(≤ 300 chars), and the selection (a few hundred short records). Worst case a few MB.
Disk: one run folder of raw logs per run (and per caller-side corpus step) under
~/Library/Caches/videoscan-runall/runs (newest 20 kept), up to three slots — each a side worktree
with its SwiftPM .build (~2 GB) and a Debug DerivedData (5–15 GB) — and, with --full, the nightly
runner's Release DerivedData + Core scratch per slot used (<slot dd>-full, ~7 GB). --status shows
each DerivedData's size.
The reader thread's line queue is bounded (QUEUE_LINES lines, ~a few MB at worst).

Tests: tests/test_run_tests.py.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import fnmatch
import json
import os
import re
import shlex
import shutil
import signal
import socket
import subprocess
import queue
import sys
import threading
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

HOME = Path.home()
SELF = Path(__file__).resolve()
# The checkout this script is run from (None when it runs from the host-side copy).
SCRIPT_REPO: Optional[Path] = SELF.parent.parent if (SELF.parent.parent / ".git").exists() else None
BASE_REPO = HOME / "dev" / "VideoScan"                       # every fleet Mac: the same account, same path
RUN_WT = HOME / "dev" / "VideoScan-wt" / "run-all"
CACHE = HOME / "Library" / "Caches" / "videoscan-runall"
DD = HOME / "Library" / "Caches" / "videoscan-runall-dd"
XCODE_DD = HOME / "Library" / "Developer" / "Xcode" / "DerivedData"
M4_LOCKDIR = HOME / "m4run" / "lock"                        # the M4 testbed lock (scripts/testbed_lock.py)
KEEP_RUNS = 20
N_SLOTS = 3        # side worktree + DerivedData pairs kept per Mac (the newest three commits; ~5-15 GB of DD each)

# --host words → (ssh name, `hostname -s` lower-cased). Not IPs: the TB bridge moves (Rick, 11-19).
HOSTS: Dict[str, Tuple[str, str]] = {
    "m4": ("ricksm4.local", "ricksm4"),
    "ultra": ("ricksultra.local", "ricksultra"),
    "m5pro": ("ricksm5.local", "ricksm5"),
    "m1": ("ricksm1.local", "ricksm1"),
}
HOST_NAMES = {"m4": "M4", "ultra": "M5 Ultra", "m5pro": "M5 Pro", "m1": "M1"}

STAGES = ["unit", "regression", "integration", "performance", "stress"]
SMOKE_STAGES = ["unit", "regression", "integration"]     # --perf / --stress add the others
STAGE_FLAGS = {"unit": "unit", "regression": "regression", "integration": "integration",
               "perf": "performance", "stress": "stress"}
# A blocked_reason that means "cannot run in a plain Debug run on a dev Mac" (opt-in real data,
# a sanitizer, model weights, the GPU under a confined home, a phase-2 UI plan). Every other
# reason is about the GAUNTLET's adapters/audits — those tests run in the nightly and here.
NOT_HERE_RE = re.compile(r"opt-in|TSan|SANITIZER|real run|real-data|real catalog|real family|weights|MLX|"
                         r"POI profiles|phase 2|LiveCatalogCopy|live catalog", re.I)

LANE_BUDGET = {"app": 3600, "core": 3600, "python": 1800, "build": 3600, "corpus": 7200,
               "m4full": 22500 + 2 * 21600 + 1800}   # m4_run.sh's own TESTBED_WAIT_BUDGET, plus a margin
SHRANK = 0.5               # a lane that ran under half of the tests its selection planned is RED
QUEUE_LINES = 10000        # the reader thread's queue bound: the child blocks, nothing is dropped


# ───────────────────────────────────────────────────────────── arguments

class Usage(Exception):
    pass


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    ap = argparse.ArgumentParser(prog="run_tests.sh", description="Smoke or full test run, narrated live.")
    mode = ap.add_mutually_exclusive_group()
    mode.add_argument("--smoke", action="store_true", help="a few suites per module and stage (default)")
    mode.add_argument("--full", action="store_true",
                      help="everything, by the nightly's own runners, on this Mac (not with --host or a stage flag)")
    for f, h in (("unit", "only the unit stage (with the Swift lanes)"),
                 ("regression", "only the regression stage (with the Swift lanes)"),
                 ("integration", "only the integration stage (with the Swift lanes)"),
                 ("perf", "the performance stage (left out of the default smoke)"),
                 ("stress", "the stress stage (left out of the default smoke)"),
                 ("python", "the Python lane (alone, or with the stage flags given)"),
                 ("corpus", "the M4 corpus check (only from the Ultra with --host m4)")):
        ap.add_argument(f"--{f}", action="store_true", help=h)
    ap.add_argument("--verbose", "-v", action="store_true", help="one line per test")
    ap.add_argument("--host", choices=sorted(HOSTS), default=None, help="run on that fleet Mac (default: this one)")
    ap.add_argument("--ref", default=None, help="commit to test (default: HEAD of this checkout)")
    ap.add_argument("--list", action="store_true", help="print the selection and stop")
    ap.add_argument("--dry-run", action="store_true", help="print what would run and stop")
    ap.add_argument("--yes", "-y", action="store_true", help="no 5 s pause before starting")
    ap.add_argument("--force", action="store_true", help="run on the M4 inside its nightly window")
    ap.add_argument("--filter", default=None, metavar="PATTERNS",
                    help="gtest-style: 'Pos1:Pos2-Neg1:Neg2', globs on Suite.test (a pattern without '.' names "
                         "suites); picks from every runnable test file, not the smoke's few")
    ap.add_argument("--jobs", type=int, default=None, metavar="N",
                    help="app test hosts at once (default: half the cores; 1 = the single host). With --full: "
                         "the nightly runner's NIGHTLY_APP_JOBS")
    ap.add_argument("--status", action="store_true", help="what run_tests is running on this Mac (and the M4 lock), then stop")
    ap.add_argument("--on-host", action="store_true", help=argparse.SUPPRESS)   # set by the ssh caller
    a = ap.parse_args(list(argv))                    # exits 2 on a usage error
    a.mode = "full" if a.full else "smoke"
    if a.jobs is not None and a.jobs < 1:
        ap.error("--jobs must be at least 1")
    a.stage_flags = any(getattr(a, f) for f in STAGE_FLAGS)
    if a.filter is not None:
        if a.full:
            ap.error("--filter narrows a --smoke; --full runs everything")
        try:
            a.test_filter = TestFilter.parse(a.filter)
        except Usage as e:
            ap.error(str(e))
    else:
        a.test_filter = None
    # The smoke leaves performance and stress out unless asked: they are load-sensitive and long
    # (Core's 100k-row scale tests take ~3 min each; Ultra smoke 11-19: 4.5 of its 10 minutes).
    # A --filter names the tests itself: every stage, unless a stage flag narrows it.
    a.stages = [STAGE_FLAGS[f] for f in STAGE_FLAGS if getattr(a, f)] or \
        (list(STAGES) if (a.mode == "full" or a.test_filter) else list(SMOKE_STAGES))
    if a.full and a.stage_flags:
        ap.error("--full runs every stage; a stage flag (--unit, --regression, …) narrows a --smoke only")
    # Kinds: --python / --corpus pick those; with a stage flag the Swift lanes come too.
    if a.python or a.corpus:
        kinds = set()
        if a.python:
            kinds.add("python")
        if a.corpus:
            kinds.add("corpus")
        if a.stage_flags:
            kinds |= {"app", "core"}
    else:
        kinds = {"app", "core", "python"} | (set() if (a.stage_flags or a.test_filter) else {"corpus"})
    a.kinds = kinds
    return a


def local_host_key(hostname: Optional[str] = None) -> Optional[str]:
    h = (hostname or socket.gethostname()).split(".")[0].lower()
    for k, (_, short) in HOSTS.items():
        if h == short:
            return k
    return None


def ssh_target(host: Optional[str], local_hostname: Optional[str] = None) -> Optional[str]:
    """The ssh name to run on, or None when the target is this Mac."""
    if host is None or host == local_host_key(local_hostname):
        return None
    return HOSTS[host][0]


def passthrough_args(argv: Sequence[str]) -> List[str]:
    """argv minus --host/--ref (the caller pins the commit and the host is where it lands)."""
    out, skip = [], False
    for x in argv:
        if skip:
            skip = False
            continue
        if x in ("--host", "--ref"):
            skip = True
            continue
        if x.startswith(("--host=", "--ref=")):
            continue
        out.append(x)
    return out


def remote_commands(target: str, sha: str, ref_label: str, argv: Sequence[str]) -> Tuple[List[str], List[str]]:
    """(copy this runner to the host, run it there over a tty). The host fetches origin
    into ~/dev/VideoScan (objects and remote refs only — its branch and tree are untouched)."""
    # One file per content (review F9): a live host run re-reads its own file for --core-exec, so a second
    # caller never rewrites it in place — it writes its own version beside it (tmp + mv, atomic).
    import hashlib
    h = hashlib.sha256(SELF.read_bytes()).hexdigest()[:12]
    d = "~/Library/Caches/videoscan-runall"
    dest = f"{d}/run_tests-{h}.py"
    copy = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", target,
            f"mkdir -p {d} && cat > {d}/.run_tests-{h}.py.$$ && mv -f {d}/.run_tests-{h}.py.$$ {dest}"]
    args = " ".join(shlex.quote(x) for x in passthrough_args(argv))
    run = ["ssh", "-t", "-o", "ConnectTimeout=15", target,
           f"git -C ~/dev/VideoScan fetch -q origin && /usr/bin/python3 {dest} --on-host --yes "
           f"--ref {shlex.quote(sha)} --ref-label {shlex.quote(ref_label)} {args}".rstrip()]
    return copy, run


# ───────────────────────────────────────────────────────────── selection

@dataclass(frozen=True)
class Pick:
    kind: str           # app | core | python | shell
    module: str
    stage: str
    path: str
    suites: Tuple[str, ...]
    tests: int
    # --filter: the (suite, test, identifier) cases picked inside a suite that is NOT taken whole;
    # a suite in `suites` with no case here runs whole. Empty: the whole file.
    cases: Tuple[Tuple[str, str, str], ...] = ()
    exact: bool = True                   # tests is the exact count (False: a whole suite the parse saw no test in)


def build_index(files: Sequence[str]) -> Tuple[List[Tuple[str, str]], List[str], List[str]]:
    """(app source basenames → module, app module folders, Core source sub-areas) from a repo
    file list. Longest names first, so the longest prefix wins."""
    app, folders, core_areas = [], set(), set()
    for f in files:
        p = f.split("/")
        if len(p) >= 4 and p[0] == "VideoScan" and p[1] == "VideoScan" and f.endswith(".swift"):
            folders.add(p[2])
            app.append((Path(f).stem, p[2]))
        if len(p) >= 6 and p[:4] == ["VideoScan", "VideoScanCore", "Sources", "VideoScanCore"]:
            core_areas.add(p[4])
    app.sort(key=lambda t: (-len(t[0]), t[0]))
    return app, sorted(folders, key=lambda s: (-len(s), s)), sorted(core_areas, key=lambda s: (-len(s), s))


def _first_word(name: str) -> str:
    m = re.match(r"[A-Z][a-z0-9]*|[a-z0-9]+", name)
    return m.group(0) if m else name


def module_of(path: str, index) -> str:
    app, folders, core_areas = index
    stem = Path(path).stem
    p = path.split("/")
    if p[:2] == ["VideoScan", "VideoScanTests"]:
        for base, mod in app:
            if len(base) >= 4 and stem.startswith(base):
                return mod
        for mod in folders:
            if stem.startswith(mod):
                return mod
        return "Other"
    if p[:4] == ["VideoScan", "VideoScanCore", "Tests", "VideoScanCoreTests"]:
        if len(p) > 5:
            return f"Core/{p[4]}"
        for area in core_areas:
            if stem.startswith(area):
                return f"Core/{area}"
        return f"Core/{_first_word(stem)}"
    if path.endswith(".py"):
        word = stem[5:] if stem.startswith("test_") else stem
        return "py/" + word.split("_")[0]
    return "sh"


def runnable_here(entry: dict) -> bool:
    r = entry.get("blocked_reason") or ""
    return not NOT_HERE_RE.search(r)


def select(manifest: dict, files: Sequence[str], stages: Sequence[str], kinds: set, full: bool = False,
           everything: bool = False) -> List[Pick]:
    """The deterministic smoke selection (or, with full, every runnable file — the --filter pool).
    everything: also the files that cannot run here (only to say why a filter matched nothing)."""
    index = build_index(files)
    groups: Dict[Tuple[str, str, str], List[dict]] = {}
    for e in manifest.get("assignments", []):
        kind, stage = e.get("kind"), e.get("stage")
        k = {"xcode": "app", "package": "core", "python": "python", "shell": "shell"}.get(kind)
        if k is None or stage not in stages:
            continue
        if (k in ("python", "shell") and "python" not in kinds) or (k in ("app", "core") and k not in kinds):
            continue
        if (not everything and not runnable_here(e)) or len(e.get("tests") or []) < 1:
            continue
        groups.setdefault((k, module_of(e["path"], index), stage), []).append(e)
    picks: List[Pick] = []
    for (k, mod, stage) in sorted(groups):
        cands = sorted(groups[(k, mod, stage)], key=lambda e: (len(e["tests"]), e["path"]))
        # Swift groups also take their median-sized file (≥ 4 files): a substantial suite, not just the
        # smallest. Python groups are already one per word (~70 files), and a median there cost 6.5 of
        # the lane's 10 minutes on 11-19 (test_nightly_shell_selftests.py): smallest only.
        median = k in ("app", "core") and len(cands) >= 4
        chosen = cands if full else ([cands[0]] + ([cands[len(cands) // 2]] if median else []))
        for e in chosen:
            picks.append(Pick(k, mod, stage, e["path"], tuple(sorted(e.get("suites") or [])), len(e["tests"])))
    return picks


# ───────────────────────────────────────────────────────────── --filter (gtest-style)

class TestFilter:
    """`Pos1:Pos2-Neg1:Neg2` (googletest's --gtest_filter grammar): ':'-separated globs, the part after
    the first '-' excludes. Matched against `Suite.test` — Suite is the Swift type name (never a
    Swift Testing display name) or the XCTest class, or a Python/shell module stem; test is the
    function name. A pattern without '.' names suites (`Catalog*` = `Catalog*.*`); a trailing `()`
    is ignored (`Suite.f()` = `Suite.f`). Case-sensitive, like gtest. No positive part = `*`."""
    __test__ = False                     # pytest: not a test class despite the name

    def __init__(self, text: str, pos: List[str], neg: List[str]) -> None:
        self.text, self.pos, self.neg = text, pos, neg

    @staticmethod
    def _norm(p: str) -> str:
        p = p.strip()
        if p.endswith("()"):
            p = p[:-2]
        if p.endswith(".*"):
            p = p[:-2]                   # Suite.* is the suite whole
        return p

    @classmethod
    def parse(cls, text: str) -> "TestFilter":
        if not text or not text.strip():
            raise Usage("--filter needs at least one pattern (e.g. 'CatalogStore*' or 'Suite.test')")
        head, _, tail = text.partition("-")
        pos = [cls._norm(x) for x in head.split(":") if x.strip()]
        neg = [cls._norm(x) for x in tail.split(":") if x.strip()]
        if not pos and not neg:
            raise Usage(f"--filter {text!r} has no pattern")
        return cls(text, pos or ["*"], neg)

    @staticmethod
    def _match(pat: str, suite: str, test: Optional[str]) -> bool:
        if "." in pat:
            return test is not None and fnmatch.fnmatchcase(f"{suite}.{test}", pat)
        return fnmatch.fnmatchcase(suite, pat)

    @staticmethod
    def _suite_part(pat: str) -> str:
        return pat.split(".", 1)[0]

    def wants(self, suite: str, test: str) -> bool:
        return any(self._match(p, suite, test) for p in self.pos) and \
            not any(self._match(n, suite, test) for n in self.neg)

    def touches(self, suite: str) -> bool:
        """Some positive could pick a test of this suite."""
        return any(fnmatch.fnmatchcase(suite, self._suite_part(p)) for p in self.pos)

    def whole(self, suite: str) -> bool:
        """The suite is picked whole, with no need to know its tests."""
        return any("." not in p and fnmatch.fnmatchcase(suite, p) for p in self.pos) and \
            not any(fnmatch.fnmatchcase(suite, self._suite_part(n)) for n in self.neg)


SW_TYPE = re.compile(r"^\s*(?:@\S.*?\s+)?(?:(?:final|private|fileprivate|public|internal)\s+)*"
                     r"(?:struct|class|extension|enum|actor)\s+([A-Za-z_][A-Za-z_0-9]*)")
SW_FUNC = re.compile(r"\bfunc\s+([A-Za-z_][A-Za-z_0-9]*)\s*(?:<[^>{}]*>)?\s*\(")
SW_TEST_ATTR = re.compile(r"@Test\b")


def _swift_labels(lines: List[str], row: int, col: int) -> str:
    """The argument labels of the parameter list opening at lines[row][col] == '(':
    `(_ a: Int, b c: [String: Int] = [:])` → `_:b:`. Swift Testing names a test `f(_:b:)`."""
    buf: List[str] = []
    depth = 0
    for r in range(row, min(row + 40, len(lines))):
        s = lines[r]
        for ch in s[col if r == row else 0:]:
            if ch in "([":
                depth += 1
                if depth == 1:
                    continue
            elif ch in ")]":
                depth -= 1
                if depth == 0:
                    return _labels_of("".join(buf))
            buf.append(ch)
        buf.append(" ")
    return _labels_of("".join(buf))


def _labels_of(params: str) -> str:
    parts, depth, cur = [], 0, []
    for ch in params:
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append("".join(cur))
            cur = []
        else:
            cur.append(ch)
    parts.append("".join(cur))
    out = ""
    for p in parts:
        words = p.split(":", 1)[0].split()
        if words and ":" in p:
            out += words[0] + ":"
    return out


def swift_code_only(text: str) -> str:
    '''The text with every string literal's contents and every comment blanked (same length and line
    breaks), so braces and `@Test` inside a string ("\\n    }\\n", review F2) or a comment never move a
    test to another suite. Handles "..." with escapes, multi-line triple-quoted strings, raw #"..."#
    and ##"..."##, `//`, and nested /* */. An interpolation inside a string is blanked with it.'''
    out = list(text)
    i, n = 0, len(text)

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "
    while i < n:
        c = text[i]
        if c == "/" and text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
        elif c == "/" and text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth, j = depth + 1, j + 2
                elif text.startswith("*/", j):
                    depth, j = depth - 1, j + 2
                else:
                    j += 1
            blank(i, j)
            i = j
        elif c == "#" or c == '"':
            j = i
            while j < n and text[j] == "#":
                j += 1
            hashes = j - i
            if j >= n or text[j] != '"':
                i = j if hashes else i + 1
                continue
            multi = text.startswith('"""', j)
            close = ('"""' if multi else '"') + "#" * hashes
            k = j + (3 if multi else 1)
            while k < n:
                if hashes == 0 and text[k] == "\\":
                    k += 2
                    continue
                if text.startswith(close, k):
                    break
                if not multi and text[k] == "\n":
                    break                    # an unterminated one-line string: stop at the line end
                k += 1
            end = k + len(close) if k < n and text.startswith(close, k) else k
            blank(j + (3 if multi else 1), k)
            i = end
        else:
            i += 1
    return "".join(out)


def swift_cases(text: str) -> List[Tuple[str, str, str]]:
    """(suite type, function, identifier) for every test declared in a Swift file — the same rules as
    scripts/gauntlet/inventory.swift (a test credits the innermost enclosing type, by brace depth).
    identifier: XCTest `testX`; Swift Testing `f()` / `f(x:)` (parameterized: one id, all its cases)."""
    lines = swift_code_only(text).split("\n")
    out: List[Tuple[str, str, str]] = []
    depth = 0
    open_types: List[Tuple[str, int]] = []
    pending_type: Optional[str] = None
    st_pending = False
    for row, line in enumerate(lines):
        trimmed = line.strip()
        if trimmed.startswith("//"):
            continue
        attr = bool(SW_TEST_ATTR.search(line))
        fm = SW_FUNC.search(line)
        if not (attr or (fm and fm.group(1).startswith("test"))):
            tm = SW_TYPE.match(line)
            if tm:
                pending_type = tm.group(1)
        if attr:
            st_pending = True
        if fm:
            name = fm.group(1)
            suite = open_types[-1][0] if open_types else ""
            if st_pending:
                out.append((suite, name, f"{name}({_swift_labels(lines, row, fm.end() - 1)})"))
                st_pending = False
            elif name.startswith("test"):
                out.append((suite, name, name))
        for ch in line:
            if ch == "{":
                depth += 1
                if pending_type is not None:
                    open_types.append((pending_type, depth))
                    pending_type = None
            elif ch == "}":
                depth -= 1
                while open_types and open_types[-1][1] > depth:
                    open_types.pop()
    return out


PY_CLASS = re.compile(r"^class\s+([A-Za-z_]\w*)")
PY_DEF = re.compile(r"^(\s*)(?:async\s+)?def\s+(test_\w+)\s*\(")


def python_cases(text: str, stem: str) -> List[Tuple[str, str, str]]:
    """(module stem, function, pytest node-id tail): `test_x` or `TestC::test_x`. Parametrized tests:
    one node id selects every parameter."""
    out: List[Tuple[str, str, str]] = []
    cls: Optional[str] = None
    for line in text.split("\n"):
        m = PY_CLASS.match(line)
        if m:
            cls = m.group(1)
            continue
        if line and not line[0].isspace() and not line.startswith("#"):
            cls = None                   # any top-level statement ends the class
        d = PY_DEF.match(line)
        if d:
            if d.group(1) == "":
                out.append((stem, d.group(2), d.group(2)))
            elif cls is not None:
                out.append((stem, d.group(2), f"{cls}::{d.group(2)}"))
    return out


def pick_suites(p: Pick) -> List[str]:
    return [Path(p.path).stem] if p.kind in ("python", "shell") else list(p.suites)


def file_cases(p: Pick, text: str) -> List[Tuple[str, str, str]]:
    if p.kind == "shell":
        return [(Path(p.path).stem, "shell_suite", "")]
    if p.kind == "python":
        return python_cases(text, Path(p.path).stem)
    return swift_cases(text)


def apply_filter(picks: Sequence[Pick], flt: TestFilter, read) -> List[Pick]:
    """Narrow a pool of picks to what the filter names. `read(paths) -> {path: text}` gives the sources
    (at the commit) of the files whose tests must be known: only those a positive touches and that
    are not taken whole. Memory: those files' text at once (a few MB for a whole-repo pattern).
    A suite the filter takes whole and the manifest lists stays whole whatever the parse says (review
    F2); a picked test that is not inside a type cannot be named by -only-testing: Refused (F3)."""
    touched = [p for p in picks if any(flt.touches(s) for s in pick_suites(p))]
    need = [p for p in touched if not all(flt.whole(s) for s in pick_suites(p))]
    texts = read([p.path for p in need]) if need else {}
    out: List[Pick] = []
    for p in touched:
        names = pick_suites(p)
        if all(flt.whole(s) for s in names):
            out.append(p)
            continue
        whole = {s for s in names if flt.whole(s)}
        cases = file_cases(p, texts.get(p.path, ""))
        if p.kind == "python":
            whole = set()                # one module = one suite: handled by the cases below
        sel = [c for c in cases if c[0] not in whole and flt.wants(c[0], c[1])]
        loose = [c for c in sel if not c[0]]
        if loose and p.kind in ("app", "core"):
            raise Refused(f"--filter picks {loose[0][1]} in {p.path}, a test that is not inside a type: "
                          f"-only-testing cannot name it alone — select the file's suites whole instead")
        if not sel and not whole:
            continue
        if not whole and len(sel) == len(cases):
            out.append(p)                # every test of the file: the file as the smoke would run it
            continue
        in_whole = sum(1 for c in cases if c[0] in whole)
        full = {s for s in {c[0] for c in sel} if all(flt.wants(c[0], c[1]) for c in cases if c[0] == s)}
        suites = tuple(sorted(whole | {c[0] for c in sel}))
        out.append(Pick(p.kind, p.module, p.stage, p.path, suites, in_whole + len(sel),
                        tuple(c for c in sel if c[0] not in full),
                        exact=all(any(c[0] == w for c in cases) for w in whole)))
    return out


def cat_files(repo: Path, sha: str, paths: Sequence[str]) -> Dict[str, str]:
    """Each path's text at the commit, through one `git cat-file --batch` (no worktree needed)."""
    if not paths:
        return {}
    p = subprocess.run(["git", "-C", str(repo), "cat-file", "--batch"], input="".join(f"{sha}:{x}\n" for x in paths).encode(),
                       capture_output=True)
    data, out, i = p.stdout, {}, 0
    for path in paths:
        nl = data.index(b"\n", i)
        head = data[i:nl].split()
        i = nl + 1
        if len(head) < 3 or head[1] == b"missing":
            continue
        n = int(head[2])
        out[path] = data[i:i + n].decode("utf-8", "replace")
        i += n + 1
    return out


# ───────────────────────────────────────────────────────────── commands

def xcode_flags(project: Path, dd: Optional[Path] = None) -> List[str]:
    return ["-project", str(project), "-scheme", "VideoScan", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(dd or DD)]


SIGN = ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS=", "ONLY_ACTIVE_ARCH=YES"]


def app_build_cmd(wt: Path, dd: Optional[Path] = None) -> List[str]:
    return ["xcodebuild", "build-for-testing"] + xcode_flags(wt / "VideoScan" / "VideoScan.xcodeproj", dd) + SIGN


def app_test_cmd(wt: Path, suites: Sequence[str], dd: Optional[Path] = None, result: Optional[Path] = None) -> List[str]:
    """suites: `Suite` or `Suite/test` selectors (app_selectors). Each run its own -resultBundlePath:
    two runs from one DerivedData must not race for xcodebuild's default result bundle name."""
    return (["xcodebuild", "test-without-building"] + xcode_flags(wt / "VideoScan" / "VideoScan.xcodeproj", dd)
            + ["-parallel-testing-enabled", "NO"] + (["-resultBundlePath", str(result)] if result else [])
            + [f"-only-testing:VideoScanTests/{s}" for s in suites])


def app_jobs(a) -> int:
    """Test hosts at once for the app lane: --jobs, else half the cores (testbed_strands.default_jobs)."""
    n = getattr(a, "jobs", None)
    return max(1, n if n else (os.cpu_count() or 2) // 2)


def shards_script(wt: Path) -> Path:
    return wt / "scripts" / "xctest_shards.py"


def shard_plan(picks: Sequence[Pick]) -> dict:
    """What xctest_shards.py --plan reads: one group per app test file — its selectors (as the single
    host would get them), the tests it declares and whether that count is an exact floor."""
    return {"groups": [{"name": Path(p.path).stem, "selectors": app_selectors([p]), "tests": p.tests,
                        "exact": p.exact, "stage": p.stage, "path": p.path} for p in picks if p.kind == "app"]}


def app_shards_cmd(wt: Path, plan: Path, jobs: int, shard_dir: Path, dd: Optional[Path] = None) -> List[str]:
    """The app test phase as `jobs` concurrent test hosts (one child: it fans out, streams and fans in)."""
    return [sys.executable, str(shards_script(wt)), "--products", str((dd or DD) / "Build" / "Products"),
            "--plan", str(plan), "--jobs", str(jobs), "--run-dir", str(shard_dir), "--stream"]


SHARD_LINE = "xctest-shards: "
SHARD_VERDICT = re.compile(r"^(GREEN|RED): (\d+) passed, (\d+) failed, (\d+) skipped\b")
SHARD_FAILED = re.compile(r"^failed: (.+?)(?: — (.*?))? · \S+ log: \S+$")


def adopt_shard_verdict(lane: "LaneResult", lines: Sequence[str]) -> None:
    """The fan-in's last verdict line is the lane's count. The stream parsed here is the K hosts' logs,
    where a test's verdict line is now and then glued into the middle of an app log line and missed
    (4 of 14,244 on 2026-11-20); the fan-in counts from each shard's result bundle. A failure it names
    that the stream did not show is added, so no failed test is ever only a number."""
    verdict = None
    named: List[Tuple[str, str]] = []
    for text in lines:
        m = SHARD_VERDICT.match(text)
        if m:
            verdict = m
        m = SHARD_FAILED.match(text)
        if m:
            named.append((m.group(1), m.group(2) or ""))
    if verdict is None:
        return
    seen = {e.name for e in lane.failures}
    for name, msg in named:
        if name not in seen:
            lane.failures.append(Event("FAILED", name, None, _short(msg)))
    lane.passed, lane.skipped = int(verdict.group(2)), int(verdict.group(4))
    lane.failed = max(int(verdict.group(3)), len(lane.failures))


def app_selectors(picks: Sequence[Pick]) -> List[str]:
    """-only-testing selectors: a whole suite as `Suite`, a filtered one as `Suite/testX` (XCTest) or
    `Suite/f(x:)` (Swift Testing's identifier, argument labels included)."""
    sel = set()
    for p in picks:
        cased = {c[0] for c in p.cases}
        sel |= {s for s in p.suites if s and s not in cased}
        sel |= {f"{c[0]}/{c[2]}" for c in p.cases if c[0] and c[2]}
    return sorted(sel)


def core_filter(suites: Sequence[str], cases: Sequence[Tuple[str, str, str]] = ()) -> str:
    # matches "VideoScanCoreTests.Suite/testX" (XCTest) and "VideoScanCoreTests.Outer/Suite/f()" (Swift Testing)
    whole = sorted(set(suites) - {c[0] for c in cases})
    rx = r"(\.|/)(" + "|".join(re.escape(s) for s in whole) + r")/" if whole else ""
    if not cases:
        return rx
    one = [r"(\.|/)" + (re.escape(c[0]) + "/" if c[0] else "") + re.escape(c[1]) + r"(\(|$)"
           for c in sorted(set(cases))]
    return "|".join(([f"(?:{rx})"] if rx else []) + [f"(?:{x})" for x in one])


def core_package(wt: Path) -> Path:
    return wt / "VideoScan" / "VideoScanCore"


def core_build_cmd(wt: Path) -> List[str]:
    return ["swift", "build", "--build-tests", "--package-path", str(core_package(wt))]


def core_products(wt: Path) -> Path:
    # .build/debug is SwiftPM's link to the products in both build systems (native, swiftbuild's out/Products)
    return core_package(wt) / ".build" / "debug"


def core_test_cmd(wt: Path, regex: str) -> List[str]:
    """The Core test phase, run as one child on the built bundle — no `swift test`, so no SwiftPM .build
    lock, so runs at one commit go side by side. The engine is the checkout-under-test's own
    scripts/core_lane.py (2026-11-20; the nightly's Core lane runs the same script): phase A, every test
    not marked quiet-machine, in parallel; phase B, the marked ones (wall-time budgets, resident-size
    bounds), one at a time; each phase's count checked against the bundle's listing. A commit from
    before core_lane.py keeps the old single pass (this file's --core-exec, core_exec below)."""
    lane = wt / "scripts" / "core_lane.py"
    if lane.exists():
        return [sys.executable, "-u", str(lane), "run", "--products", str(core_products(wt)), "--filter", regex]
    return [sys.executable, str(SELF), "--core-exec", str(core_products(wt)), regex]


def pytest_cmd(py: List[str], files: Sequence[str], basetemp: Optional[Path] = None) -> List[str]:
    return (py + ["-m", "pytest", "-v", "-rfE", "-p", "no:cacheprovider", "--color=no"]
            + ([f"--basetemp={basetemp}"] if basetemp else []) + list(files))


def python_targets(picks: Sequence[Pick]) -> List[str]:
    """pytest arguments: a whole file as its path, a filtered one as node ids (path::test, path::Class::test)."""
    out: List[str] = []
    for p in picks:
        if p.kind != "python":
            continue
        if p.cases:
            out += [f"{p.path}::{c[2]}" for c in p.cases]
        else:
            out.append(p.path)
    return list(dict.fromkeys(out))


# ───────────────────────────────────────────────────────────── the Core test phase (child)

def core_exec(products: str, regex: str) -> int:
    """Only for a commit that has no scripts/core_lane.py (core_test_cmd): one pass, Swift Testing in
    parallel, the quiet-machine tests beside the rest.
    `run_tests.py --core-exec <products> <regex>`: what `swift test --skip-build --filter <regex>` runs,
    without SwiftPM (whose .build lock serializes every `swift test` on one package, even --skip-build:
    "Another instance of SwiftPM … waiting", measured 2026-11-20). XCTest: list the bundle's tests with
    swiftpm-xctest-helper, keep those whose `Module.Class/test` the regex finds, run them with `xcrun
    xctest -XCTest`. Swift Testing: swiftpm-testing-helper --filter <regex>. Same counts as swift test
    on the smoke's Core selection (57 XCTest + 685 Swift Testing). Exit: the first non-zero."""
    bundle = Path(products) / "VideoScanCoreTests.xctest"
    exe = bundle / "Contents" / "MacOS" / "VideoScanCoreTests"
    if not exe.exists():
        print(f"core-exec: no built test bundle at {bundle} (did the Core build run?)", flush=True)
        return 1
    xrun = lambda *a: subprocess.run(["xcrun"] + list(a), capture_output=True, text=True).stdout.strip()
    plat = xrun("--sdk", "macosx", "--show-sdk-platform-path")
    pm = Path(xrun("--find", "swift")).parent.parent / "libexec" / "swift" / "pm"
    env = dict(os.environ, NO_COLOR="1",
               DYLD_FRAMEWORK_PATH=f"{plat}/Developer/Library/Frameworks:{plat}/Developer/Library/PrivateFrameworks",
               DYLD_LIBRARY_PATH=f"{Path(products).resolve()}:{plat}/Developer/usr/lib")
    listing = Path(os.environ.get("TMPDIR", "/tmp")) / f"run_tests-xctest-{os.getpid()}.json"
    try:
        p = subprocess.run([str(pm / "swiftpm-xctest-helper"), str(bundle), str(listing)], env=env,
                           capture_output=True, text=True)
        if p.returncode != 0:
            print(f"core-exec: listing the XCTest cases failed (exit {p.returncode}): {p.stderr.strip()[:300]}", flush=True)
            return 1
        tree = json.loads(listing.read_text())
    finally:
        with contextlib.suppress(OSError):
            listing.unlink()
    rx = re.compile(regex)
    specs: List[str] = []
    for b in tree.get("tests", []):
        for c in b.get("tests", []):
            names = [f"{c['name']}/{t['name']}" for t in c.get("tests", [])]
            hit = [n for n in names if rx.search(n)]
            specs += [c["name"]] if hit and len(hit) == len(names) else hit
    rc = 0
    print(f"core-exec: XCTest {len(specs)} selectors", flush=True)
    if specs:
        rc = subprocess.call(["xcrun", "xctest", "-XCTest", ",".join(specs), str(bundle)], env=env)
    rc2 = subprocess.call([str(pm / "swiftpm-testing-helper"), "--test-bundle-path", str(exe), str(exe),
                           "--testing-library", "swift-testing", "--filter", regex], env=env)
    if rc2 == 69:
        rc2 = 0                          # swiftpm-testing-helper: "no test matched" (an XCTest-only selection,
                                         # review F1); `swift test` reads it the same way. Zero tests ran
                                         # overall is still RED by the zero-test / shortfall rules.
    return rc or rc2


# ───────────────────────────────────────────────────────────── parsing

@dataclass
class Event:
    status: str                  # OK | FAILED | SKIPPED
    name: str
    seconds: Optional[float] = None
    message: str = ""


_ZW = "​﻿ "
XC_CASE = re.compile(r"^Test Case '-\[(\S+) (\S+)\]' (passed|failed|skipped) \((\d+\.\d+) seconds\)")
XC_ERR = re.compile(r"^.*?:\d+: error: -\[(\S+) (\S+)\] : (.*)$")
PAR_CASE = re.compile(r"^(?:Test )?case '(.+?)' (passed|failed|skipped) on '.*?' \((\d+\.\d+) seconds\)")
ST_PASS = re.compile(r"^[✔━] Test (.+) passed after (\d+(?:\.\d+)?) seconds(?: with .*)?\.$")
ST_FAIL = re.compile(r"^✘ Test (.+) failed after (\d+(?:\.\d+)?) seconds(?: with .*)?\.$")
ST_SKIP = re.compile(r"^[➜↪] Test (.+?) skipped(?:: \"(.*)\")?\.?$")
ST_ISSUE = re.compile(r"^✘ Test (.+?) recorded an issue(?: with \d+ arguments? .*?)? at [^\s:]+:\d+(?::\d+)?: (.*)$")
PY_LINE = re.compile(r"^(\S+::\S+(?: \S+)*?) (PASSED|FAILED|SKIPPED|ERROR|XFAIL|XPASS)\b")
PY_SUMMARY = re.compile(r"^(FAILED|ERROR) (\S+?)(?: - (.*))?$")
ST_SECS = re.compile(r"(\d+\.\d+) seconds")


def _short(msg: str) -> str:
    msg = " ".join(msg.split())
    return msg[:300]


class LineParser:
    """Feed it lines of runner output; it returns the tests that FINISHED on each line.
    Keeps the first failure message per test (an issue line comes before its verdict line)."""

    def __init__(self) -> None:
        self.pending: Dict[str, str] = {}
        self.parallel = False
        self.failed_events: Dict[str, Event] = {}

    def feed(self, raw: str) -> List[Event]:
        line = raw.rstrip("\n").lstrip(_ZW)
        m = PAR_CASE.match(line)
        if m:
            self.parallel = True
            name = m.group(1).replace("/", ".")
            st = {"passed": "OK", "failed": "FAILED", "skipped": "SKIPPED"}[m.group(2)]
            return [self._ev(st, name, float(m.group(3)), m.group(1).split("/")[-1])]
        m = XC_ERR.match(line)
        if m:
            key = f"{m.group(1).split('.')[-1]}.{m.group(2)}"
            if not m.group(3).startswith("Test skipped"):
                self.pending.setdefault(key, _short(m.group(3)))
            return []
        if self.parallel:
            return []
        m = XC_CASE.match(line)
        if m:
            name = f"{m.group(1).split('.')[-1]}.{m.group(2)}"
            st = {"passed": "OK", "failed": "FAILED", "skipped": "SKIPPED"}[m.group(3)]
            return [self._ev(st, name, float(m.group(4)))]
        # Swift Testing. A display name is free text ("… is skipped, …" is a real one, 11-19), so
        # the marker decides the kind and each verb is anchored to the line's end.
        for rx, st in ((ST_PASS, "OK"), (ST_FAIL, "FAILED")):
            m = rx.match(line)
            if m:
                if m.group(1).startswith("run with "):
                    return []
                name = re.sub(r" with \d+ test cases?$", "", m.group(1))
                return [self._ev(st, name, float(m.group(2)))]
        m = ST_SKIP.match(line)
        if m:
            return [self._ev("SKIPPED", m.group(1), None, message=_short(m.group(2) or ""))]
        m = ST_ISSUE.match(line)
        if m:
            self.pending.setdefault(m.group(1), _short(m.group(2)))
            return []
        m = PY_LINE.match(line)
        if m:
            st = {"PASSED": "OK", "XFAIL": "OK", "XPASS": "OK", "SKIPPED": "SKIPPED"}.get(m.group(2), "FAILED")
            return [self._ev(st, m.group(1), None)]
        m = PY_SUMMARY.match(line)
        if m:
            name, msg = m.group(2), _short(m.group(3) or "")
            if name in self.failed_events:          # the -v line already counted it: just its message
                if msg and not self.failed_events[name].message:
                    self.failed_events[name].message = msg
                return []
            if "::" not in name:                    # a module that failed to collect: it ran nothing
                return [self._ev("FAILED", name, None, message=msg or "collection error")]
        return []

    def _ev(self, st: str, name: str, sec: Optional[float], alt: str = "", message: str = "") -> Event:
        ev = Event(st, name, sec, message)
        if st == "FAILED":
            ev.message = self.pending.pop(name, "") or self.pending.pop(alt, "") or message
            self.failed_events[name] = ev
        return ev


# ───────────────────────────────────────────────────────────── verdict

@dataclass
class LaneResult:
    name: str
    ran: bool = False
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    rc: Optional[int] = None
    seconds: float = 0.0
    reason: str = ""                       # why NOT RUN, or why RED beyond the counts
    failures: List[Event] = field(default_factory=list)
    expected: int = 0                      # tests the selection planned (0: unknown, no floor)
    exact: bool = False                    # a --filter's plan is exact: ANY shortfall is RED, not under half
    setup: List[str] = field(default_factory=list)   # missing tools (preflight): NOT RUN, not RED

    @property
    def total(self) -> int:
        return self.passed + self.failed + self.skipped

    @property
    def shrank(self) -> bool:
        if self.expected <= 0:
            return False
        # skipped tests count as ran (a trait or XCTSkip said why); only a test that never reported is short
        return self.total < self.expected if self.exact else self.total < self.expected * SHRANK

    @property
    def word(self) -> str:
        if not self.ran:
            return "NOT RUN"
        if self.failed or self.passed == 0 or self.shrank or \
                (self.rc not in (0, None) and not self.reason.startswith("amber")):
            return "RED"
        return "GREEN"


def verdict(lanes: Sequence[LaneResult]) -> Tuple[int, str]:
    """0 GREEN when every lane that ran is green and at least one ran; else 1 RED.
    A lane that ran zero tests is RED (CLAUDE.md: a zero-test run is red); a lane that
    did not run is NOT RUN, never green — and if nothing ran the run is RED."""
    ran = [l for l in lanes if l.ran]
    if any(l.word == "RED" for l in ran):
        return 1, "RED"
    if any(l.setup for l in lanes):
        return 1, "NOT READY: setup"       # a missing tool is the Mac's setup, not a test failure
    if not ran:
        return 1, "RED"
    return 0, "GREEN"


# ───────────────────────────────────────────────────────────── safety

class Refused(Exception):
    pass


def git(repo: Path, *args: str, check: bool = True) -> str:
    p = subprocess.run(["git", "-C", str(repo)] + list(args), capture_output=True, text=True, stdin=subprocess.DEVNULL)
    if check and p.returncode != 0:
        raise Refused(f"git {' '.join(args)}: {p.stderr.strip() or p.stdout.strip()}")
    return p.stdout.strip()


def check_paths(base: Path, wt: Path, dd: Path) -> None:
    """Never Rick's checkout (or any main checkout), never Xcode's DerivedData (rule 11)."""
    wt_r, base_r, dd_r = wt.expanduser().resolve(), base.expanduser().resolve(), dd.expanduser().resolve()
    if wt_r == base_r or wt_r == (HOME / "dev" / "VideoScan").resolve():
        raise Refused(f"refusing to run in {wt_r}: that is a main checkout, not the side worktree")
    if (wt_r / ".git").is_dir():
        raise Refused(f"refusing {wt_r}: it is a main checkout (.git is a folder), not a worktree")
    xdd = XCODE_DD.resolve()
    if dd_r == xdd or xdd in dd_r.parents:
        raise Refused(f"refusing DerivedData {dd_r}: that is Xcode's own")


def prepare_worktree(base: Path, wt: Path, sha: str, dd: Path = DD) -> None:
    check_paths(base, wt, dd)
    if wt.exists():
        if not (wt / ".git").is_file():
            raise Refused(f"{wt} exists and is not a git worktree; move it aside (to .trash/) and run again")
        dirty = git(wt, "status", "--porcelain", "--untracked-files=no")
        if dirty:
            raise Refused(f"side worktree {wt} has local changes — not touching it:\n{dirty}")
        git(wt, "checkout", "-q", "--detach", sha)
    else:
        wt.parent.mkdir(parents=True, exist_ok=True)
        git(base, "worktree", "add", "-q", "--detach", str(wt), sha)
    if git(wt, "rev-parse", "HEAD") != sha:
        raise Refused(f"{wt} is not at {sha[:9]} after checkout")


class Busy(Exception):
    pass


def take_lock(lockdir: Path, info: str) -> int:
    """A kernel flock held on an fd we keep open until exit (scripts/testbed_lock.py's protocol:
    the same file, the same info line, so m4_run.sh status names us)."""
    lockdir.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(lockdir / "flock"), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        _HELD.add(fd)                    # the M4 lock, too, lives as long as the work (F6)
    except OSError:
        try:
            who = (lockdir / "info").read_text().strip().split(" ", 1)[-1]
        except OSError:
            who = "(no info)"
        os.close(fd)
        raise Busy(who)
    (lockdir / "info").write_text(f"{os.getpid()} {info}\n")
    return fd


# ───────────────────────────────────────────────────────────── slots: the only shared resources
#
# A SLOT is one side worktree + its Debug DerivedData (and the worktree's SwiftPM .build). N_SLOTS of
# them, at fixed paths, so a slot moved to a new commit builds INCREMENTALLY (Xcode and SwiftPM key
# their caches on absolute paths: a fresh path per commit would make every new commit a clean build).
# Slot 1 is the pre-2026-11-20 pair (run-all, videoscan-runall-dd), so its warm build is kept.
#
#   <CACHE>/slots/<i>.lock        flock SHARED by every live run using slot i, for its whole life;
#                                 EXCLUSIVE (non-blocking) only to move it to another commit — so a
#                                 slot a live run uses is never moved or pruned (C++: shared_mutex,
#                                 try_lock() to write, lock_shared() to read).
#   <CACHE>/slots/<i>.build-app   flock EXCLUSIVE while building (xcodebuild build-for-testing); a second
#   <CACHE>/slots/<i>.build-core  run at the same commit waits here, then tests from the same products.
#   <CACHE>/slots/<i>.built-<k>   the commit whose <k> build succeeded in this slot (cleared on a move).
#   <CACHE>/slots/<i>.full        flock EXCLUSIVE for a --full run (its own Release DerivedData).
#   <CACHE>/slots/<i>.used        mtime = last use; the least recently used free slot is moved first.
#   <CACHE>/lock                  the old whole-run lock: slot 1's users hold it SHARED, so a run_tests
#                                 from an older checkout (which takes it exclusive) cannot move run-all
#                                 under us, and we skip slot 1 while one of those holds it.
#
# Everything else is per run: its run folder (logs, -resultBundlePath, pytest --basetemp, TMPDIR).

@dataclass
class Slot:
    index: int
    wt: Path
    dd: Path
    fds: List[int] = field(default_factory=list)

    @property
    def label(self) -> str:
        return str(self.index + 1)

    def release(self) -> None:
        for fd in self.fds:
            _close(fd)
        self.fds = []


def slot_dir() -> Path:
    return CACHE / "slots"


def slot_paths(i: int) -> Tuple[Path, Path]:
    if i == 0:
        return RUN_WT, DD
    return RUN_WT.parent / f"{RUN_WT.name}-{i + 1}", DD.parent / f"{DD.name}-{i + 1}"


# Lock fds this process holds for its work (slot, build, --full, M4). Every child gets them (pass_fds):
# flock belongs to the open file description, so the lock lives as long as ANY holder — a runner killed
# with -9 leaves its own-session xcodebuild/swift child holding the slot, which then cannot be moved
# under it (review F6). C++: a shared_ptr every child copies. The registry's own lock is not passed.
_HELD: set = set()


def _lock_fd(path: Path) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(str(path), os.O_RDWR | os.O_CREAT, 0o644)
    _HELD.add(fd)
    return fd


def _close(fd: int) -> None:
    _HELD.discard(fd)
    with contextlib.suppress(OSError):
        os.close(fd)


def held_fds() -> Tuple[int, ...]:
    out = []
    for fd in sorted(_HELD):
        try:
            os.fstat(fd)
            out.append(fd)
        except OSError:
            _HELD.discard(fd)
    return tuple(out)


def _flock(fd: int, how: int, block: bool = False) -> bool:
    try:
        fcntl.flock(fd, how | (0 if block else fcntl.LOCK_NB))
        return True
    except OSError:
        return False


def slot_head(wt: Path) -> Optional[str]:
    if not (wt / ".git").is_file():
        return None
    return git(wt, "rev-parse", "HEAD", check=False) or None


def _hold_slot(i: int, how: int, block: bool) -> Optional[List[int]]:
    fds = [_lock_fd(slot_dir() / f"{i}.lock")]
    if i == 0:
        fds.append(_lock_fd(CACHE / "lock" / "flock"))
    ok = _flock(fds[0], how, block) and (i != 0 or _flock(fds[1], fcntl.LOCK_SH, False))
    if not ok:
        for fd in fds:
            _close(fd)
        return None
    return fds


def _used(i: int) -> float:
    try:
        return (slot_dir() / f"{i}.used").stat().st_mtime
    except OSError:
        return 0.0


def _touch(path: Path, text: Optional[str] = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if text is not None:
        path.write_text(text)
    else:
        path.touch()
        os.utime(str(path), None)


def acquire_slot(base: Path, sha: str) -> Slot:
    """A slot at `sha`, held SHARED until this process exits. One already at the commit is shared
    (its build reused); else the least recently used slot no live run holds is moved there. Raises
    Busy when every slot is held at another commit (nothing is queued), Refused for a dirty or
    foreign worktree (never touched); a dirty slot is skipped for the next one (review F7) and the
    run is refused only when no slot is usable."""
    refused: Dict[int, str] = {}
    for _ in range(3):
        for i in range(N_SLOTS):
            wt, dd = slot_paths(i)
            if slot_head(wt) != sha:
                continue
            fds = _hold_slot(i, fcntl.LOCK_SH, block=True)   # blocks only while a mover holds it (seconds)
            if fds is None:
                continue
            slot = Slot(i, wt, dd, fds)
            if slot_head(wt) == sha:
                try:
                    check_paths(base, wt, dd)
                    dirty = git(wt, "status", "--porcelain", "--untracked-files=no")
                except Refused as e:
                    slot.release()
                    refused[i] = str(e)
                    continue
                if dirty:
                    slot.release()
                    refused[i] = f"side worktree {wt} has local changes — not touching it:\n{dirty}"
                    _touch(slot_dir() / f"{i}.refused", refused[i] + "\n")
                    continue
                _used_now(i)
                return slot
            slot.release()
        for i in sorted(range(N_SLOTS), key=_used):
            wt, dd = slot_paths(i)
            fds = _hold_slot(i, fcntl.LOCK_EX, block=False)
            if fds is None:
                continue
            slot = Slot(i, wt, dd, fds)
            try:
                prepare_worktree(base, wt, sha, dd)      # the checkout changes the stamps' token: no stale "built"
            except Refused as e:
                slot.release()                           # a dirty or foreign slot: never touched; try the next (F7)
                refused[i] = str(e)
                _touch(slot_dir() / f"{i}.refused", str(e) + "\n")
                continue
            except BaseException:
                slot.release()
                raise
            fcntl.flock(fds[0], fcntl.LOCK_SH)     # moved: other runs at this commit may share it now
            if slot_head(wt) == sha:
                _used_now(i)
                return slot
            slot.release()
            break
    if refused:
        raise Refused("no usable side worktree: " + "; ".join(f"slot {i + 1}: {m}" for i, m in sorted(refused.items()))
                      + (" (the others are in use)" if len(refused) < N_SLOTS else ""))
    raise Busy(f"all {N_SLOTS} side worktrees are in use by live runs at other commits")


def _used_now(i: int) -> None:
    _touch(slot_dir() / f"{i}.used")
    with contextlib.suppress(OSError):
        (slot_dir() / f"{i}.refused").unlink()


def _lock_info(path: Path) -> Tuple[str, str, str]:
    """(pid, HH:MM, sha9) from a build lock's info file ("pid sha epoch kind")."""
    try:
        w = path.read_text().split()
        return w[0], time.strftime("%H:%M", time.localtime(float(w[2]))), w[1][:9]
    except (OSError, IndexError, ValueError):
        return "?", "?", "?"


@contextlib.contextmanager
def build_lock(slot: Optional[Slot], kind: str, sha: str, out: "Out", live: Optional["LiveRun"] = None):
    """EXCLUSIVE while building `kind` in the slot. A second run at the same commit says whom it waits
    for, then (the build stamp being current) skips the build and tests from the same products."""
    if slot is None:
        yield
        return
    path = slot_dir() / f"{slot.index}.build-{kind}"
    fd = _lock_fd(path)
    try:
        if not _flock(fd, fcntl.LOCK_EX):
            pid, since, who_sha = _lock_info(Path(str(path) + ".info"))
            msg = f"waiting for the build of {who_sha} (pid {pid}, since {since})"
            out.line("WAIT", msg, "BUILD")
            if live is not None:
                live.update(phase=msg)
            fcntl.flock(fd, fcntl.LOCK_EX)
        Path(str(path) + ".info").write_text(f"{os.getpid()} {sha} {time.time():.0f} {kind}\n")
        yield
    finally:
        _close(fd)


def _stamp(slot: Slot, kind: str) -> Path:
    """INSIDE what it describes: deleting the DerivedData (or .build) drops it (review F4)."""
    return (slot.dd / ".run_tests-built-app") if kind == "app" else (core_package(slot.wt) / ".build" / ".run_tests-built-core")


def checkout_token(wt: Path) -> str:
    """Changes with ANY checkout in the worktree — ours, an older run_tests', anyone's `git checkout`:
    HEAD's commit, the size of the worktree's HEAD reflog (each checkout appends a line) and the HEAD
    file's mtime (rewritten by a checkout)."""
    gd = Path(git(wt, "rev-parse", "--absolute-git-dir", check=False) or "/nonexistent")
    def stat(p: Path) -> str:
        try:
            st = p.stat()
            return f"{st.st_size}:{st.st_mtime_ns}"
        except OSError:
            return "-"
    return f"{git(wt, 'rev-parse', 'HEAD', check=False)} {stat(gd / 'logs' / 'HEAD')} {stat(gd / 'HEAD')}"


def built_at(slot: Optional[Slot], kind: str) -> Optional[str]:
    """The commit whose `kind` products this slot holds — only if no checkout happened since they were built."""
    if slot is None:
        return None
    try:
        sha, token = _stamp(slot, kind).read_text().strip().split(" ", 1)
    except (OSError, ValueError):
        return None
    return sha if token == checkout_token(slot.wt) and token.startswith(sha) else None


def mark_built(slot: Optional[Slot], kind: str, sha: str) -> None:
    if slot is not None:
        _touch(_stamp(slot, kind), f"{sha} {checkout_token(slot.wt)}\n")


# ───────────────────────────────────────────────────────────── the run registry and --status

def live_dir() -> Path:
    return CACHE / "live"


class LiveRun:
    """<CACHE>/live/<pid>.json while this run lives: argv, commit, slot, run folder, the lane now and
    n/N done. Rewritten atomically (tmp + rename) on each phase and at most once a second for
    progress; removed on exit. Liveness is a lock, not a guess (review F8): the run holds
    <pid>.lock EXCLUSIVE for its life; a reader that can take it knows the run is gone (a crash,
    a kill -9, a reused pid all release it) and removes both files."""

    def __init__(self, info: dict) -> None:
        self.info = dict(info, pid=os.getpid(), started=time.time())
        self.path = live_dir() / f"{os.getpid()}.json"
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = self.path.with_suffix(".lock")
        self.fd = os.open(str(self.lock), os.O_RDWR | os.O_CREAT, 0o644)   # not passed to children
        fcntl.flock(self.fd, fcntl.LOCK_EX)
        self.last = 0.0
        self.write()

    def write(self) -> None:
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.info, sort_keys=True))
        os.replace(str(tmp), str(self.path))
        self.last = time.monotonic()

    def update(self, **kw) -> None:
        progress_only = set(kw) <= {"done"}
        self.info.update(kw)
        if not progress_only or time.monotonic() - self.last >= 1.0:
            self.write()

    def close(self) -> None:
        for f in (self.path, self.lock):
            with contextlib.suppress(OSError):
                f.unlink()
        with contextlib.suppress(OSError):
            os.close(self.fd)


def live_runs() -> List[dict]:
    out: List[dict] = []
    root = live_dir()
    if not root.is_dir():
        return out
    for f in sorted(root.glob("*.json")):
        lock = f.with_suffix(".lock")
        alive = False
        if lock.exists():
            fd = os.open(str(lock), os.O_RDWR)
            try:
                alive = not _flock(fd, fcntl.LOCK_EX)
            finally:
                os.close(fd)
        if not alive:
            for g in (f, lock):
                with contextlib.suppress(OSError):
                    g.unlink()           # stale: its run is gone
            continue
        try:
            out.append(json.loads(f.read_text()))
        except (OSError, ValueError):
            continue
    return out


def _hm(epoch: float) -> str:
    return time.strftime("%H:%M", time.localtime(epoch))


def run_line(r: dict, now: Optional[float] = None) -> str:
    now = time.time() if now is None else now
    what = r.get("phase") or "starting"
    if r.get("total"):
        what += f" {r.get('done', 0)}/{r['total']}"
    flt = f" --filter {r['filter']!r}" if r.get("filter") else ""
    return (f"pid {r.get('pid')} · {r.get('mode', 'smoke')}{flt} · {str(r.get('sha', ''))[:9]} · "
            f"slot {r.get('slot', '?')} · {what} · since {_hm(r.get('started', now))} "
            f"({fmt_secs(max(0, now - r.get('started', now)))})")


def du_gb(path: Path, timeout: int = 30) -> Optional[float]:
    if not path.exists():
        return None
    try:
        p = subprocess.run(["du", "-sk", str(path)], capture_output=True, text=True, timeout=timeout)
        return int(p.stdout.split()[0]) / 1048576
    except (subprocess.TimeoutExpired, ValueError, IndexError, OSError):
        return None


def slot_lines(runs: Sequence[dict], disk: bool = True) -> List[str]:
    lines = []
    for i in range(N_SLOTS):
        wt, dd = slot_paths(i)
        head = slot_head(wt)
        users = [r for r in runs if str(r.get("slot")) == str(i + 1)]
        fd = _lock_fd(slot_dir() / f"{i}.lock")
        held = not _flock(fd, fcntl.LOCK_EX)
        _close(fd)
        old = ""
        if i == 0 and not held:          # an older run_tests (whole-run lock) using run-all
            fd = _lock_fd(CACHE / "lock" / "flock")
            if not _flock(fd, fcntl.LOCK_SH):
                try:
                    old = (CACHE / "lock" / "info").read_text().strip()
                except OSError:
                    old = "(no info)"
            _close(fd)
        try:
            bad = (slot_dir() / f"{i}.refused").read_text().strip().splitlines()[0][:90]
        except (OSError, IndexError):
            bad = ""
        state = (f"in use by an older run_tests: pid {old}" if old else
                 f"REFUSED (skipped): {bad}" if bad and not (held or users) else
                 f"in use by {len(users) or 'a'} run{'s' if len(users) > 1 else ''}" if held or users
                 else (f"idle, last used {time.strftime('%m-%d %H:%M', time.localtime(_used(i)))}" if _used(i) else "idle"))
        size = du_gb(dd) if disk else None
        lines.append(f"  slot {i + 1}  {wt.name:12} {('at ' + head[:9]) if head else 'empty':13} {state:28} "
                     f"DerivedData {f'{size:.1f} GB' if size is not None else '—'}")
    return lines


M4_DEFAULT_MIN = {"testbed": 120, "all": 90, "suite": 75, "deep": 60, "corpus": 45, "ui": 30, "run_tests": 20}


def _ts(s: Optional[str]) -> Optional[float]:
    try:
        return time.mktime(time.strptime(s or "", "%Y-%m-%d %H:%M:%S"))
    except ValueError:
        return None


def m4_lock_line(st: dict, now: Optional[float] = None) -> str:
    """One line from `m4_run.sh status --json`: who holds the M4 testbed lock and, from that lane's last
    finished run (else the testbed's own expected length), when it should be done."""
    now = time.time() if now is None else now
    holder = st.get("lock")
    if st.get("state") != "running" or not holder:
        return "M4 testbed: idle"
    lane = holder.split()[0]
    m = re.search(r"since (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)", holder)
    since = _ts(m.group(1)) if m else None
    est, basis = None, ""
    for key in ("last", "suite", "testbed"):
        r = st.get(key) or {}
        if r.get("lane") == lane and not r.get("running") and _ts(r.get("ended")) and _ts(r.get("started")):
            est, basis = _ts(r["ended"]) - _ts(r["started"]), f"the last {lane} run took {fmt_secs(_ts(r['ended']) - _ts(r['started']))}"
            break
    if est is None:
        for ln in ((st.get("testbed") or {}).get("lanes") or []):
            if ln.get("name") == lane and ln.get("seconds"):
                est, basis = float(ln["seconds"]), f"its {lane} lane took {fmt_secs(ln['seconds'])} in the last testbed"
                break
    if est is None:
        est, basis = M4_DEFAULT_MIN.get(lane, 60) * 60.0, f"a {lane} run is planned at {M4_DEFAULT_MIN.get(lane, 60)} min"
    eta = ""
    if since is not None:
        end = since + est
        eta = (f" — est. finish ~{_hm(end)} ({basis})" if end > now
               else f" — past its usual length ({basis}); see scripts/m4_run.sh status --host m4")
    return f"M4 testbed: busy — {holder}{eta}"


def m4_status_json(script_repo: Path, timeout: int = 25) -> Optional[dict]:
    sh = script_repo / "scripts" / "m4_run.sh"
    if not sh.exists():
        return None
    try:
        p = subprocess.run(["/bin/bash", str(sh), "status", "--host", "m4", "--json"], capture_output=True,
                           text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        return json.loads(p.stdout) if p.returncode == 0 else None
    except (subprocess.TimeoutExpired, ValueError, OSError):
        return None


def status_block(local_name: str, with_m4: bool = True, disk: bool = True, m4=None) -> List[str]:
    """What --status prints and every busy refusal prints instead of one opaque line."""
    runs = live_runs()
    lines = [f"run_tests on {local_name} at {time.strftime('%H:%M')}: "
             + (f"{len(runs)} live run{'s' if len(runs) != 1 else ''}" if runs else "nothing running")]
    lines += ["  " + run_line(r) for r in runs]
    lines += slot_lines(runs, disk)
    if with_m4:
        st = (m4 or m4_status_json)(SCRIPT_REPO or BASE_REPO)
        lines.append(m4_lock_line(st) if st else "M4 testbed: not reachable (scripts/m4_run.sh status --host m4)")
    return lines


# ───────────────────────────────────────────────────────────── display

def fmt_secs(s: float) -> str:
    s = int(round(s))
    return f"{s // 60}m{s % 60:02d}s" if s >= 60 else f"{s}s"


class Out:
    COLORS = {"OK": "\033[32m", "FAILED": "\033[31m", "SKIPPED": "\033[33m", "GREEN": "\033[32m",
              "RED": "\033[31m", "NOT RUN": "\033[33m", "BUILD": "\033[36m", "NOT READY: setup": "\033[33m"}

    def __init__(self, verbose: bool, stream=None) -> None:
        self.s = stream or sys.stdout
        self.tty = self.s.isatty()
        self.verbose = verbose
        self.done = 0
        self.expected = 0
        self.counter_shown = False
        self.on_progress = None              # LiveRun.update(done=n), at most a write a second

    def c(self, word: str, text: str) -> str:
        return f"{self.COLORS.get(word, '')}{text}\033[0m" if self.tty and word in self.COLORS else text

    def line(self, tag: str, text: str, word: str = "") -> None:
        self.clear_counter()
        self.s.write(self.c(word, f"[{tag:^10}]") + " " + text + "\n")
        self.s.flush()

    def plain(self, text: str) -> None:
        self.clear_counter()
        self.s.write(text + "\n")
        self.s.flush()

    def event(self, ev: Event) -> None:
        self.done += 1
        if self.on_progress is not None:
            self.on_progress(self.done)
        ms = f" ({int(ev.seconds * 1000)} ms)" if ev.seconds is not None else ""
        if ev.status == "FAILED":
            self.line("FAILED", ev.name + ms, "FAILED")
            if ev.message:
                self.plain(" " * 13 + ev.message)
        elif self.verbose:
            tag = {"OK": "OK", "SKIPPED": "SKIPPED"}[ev.status]
            self.line(tag if tag != "OK" else "      OK", ev.name + ms + (f" — {ev.message}" if ev.message and ev.status == "SKIPPED" else ""), ev.status)
        if not self.verbose and self.tty:
            self.s.write(f"\r[ {self.done}/{self.expected} ] ")
            self.s.flush()
            self.counter_shown = True

    def clear_counter(self) -> None:
        if self.counter_shown:
            self.s.write("\r\033[K")
            self.counter_shown = False


# ───────────────────────────────────────────────────────────── running

def under_ssh(env: Optional[Dict[str, str]] = None) -> bool:
    e = os.environ if env is None else env
    return bool(e.get("SSH_CONNECTION") or e.get("SSH_TTY"))


def _xml(s: str) -> str:
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def gui_plist(label: str, args: List[str], env: Dict[str, str], cwd: str) -> str:
    keep = {k: env[k] for k in ("PATH", "HOME", "USER", "LANG", "TMPDIR") if k in env}
    return ("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            "<plist version=\"1.0\"><dict>\n"
            f"<key>Label</key><string>{_xml(label)}</string>\n"
            "<key>ProgramArguments</key><array>" + "".join(f"<string>{_xml(a)}</string>" for a in args) + "</array>\n"
            "<key>EnvironmentVariables</key><dict>" + "".join(f"<key>{_xml(k)}</key><string>{_xml(v)}</string>"
                                                                for k, v in sorted(keep.items())) + "</dict>\n"
            f"<key>WorkingDirectory</key><string>{_xml(cwd)}</string>\n"
            "<key>RunAtLoad</key><true/><key>ProcessType</key><string>Interactive</string>\n"
            "</dict></plist>\n")


@contextlib.contextmanager
def stop_signals():
    """While inside: SIGHUP (a dropped ssh session) and SIGTERM (`kill`) raise KeyboardInterrupt, so
    they take the same stop() path as Ctrl-C instead of ending the runner with its child (its own
    session, start_new_session) still running. Restored on the way out. signal.signal works on the
    main thread only; elsewhere this is a no-op. (C++: an RAII guard around sigaction.)"""
    if threading.current_thread() is not threading.main_thread():
        yield
        return

    def interrupt(signum, frame):
        raise KeyboardInterrupt(signal.Signals(signum).name)
    old = {sig: signal.signal(sig, interrupt) for sig in (signal.SIGHUP, signal.SIGTERM)}
    try:
        yield
    finally:
        for sig, handler in old.items():
            signal.signal(sig, handler)


class Runner:
    gui_label: Optional[str] = None

    def __init__(self, out: Out, run_dir: Path, env: Dict[str, str]) -> None:
        self.out, self.run_dir, self.env = out, run_dir, env
        self.child: Optional[subprocess.Popen] = None

    def stream(self, cmd: List[str], log_name: str, budget: int, cwd: Optional[Path] = None,
               parser: Optional[LineParser] = None, on_line=None, lane: Optional[LaneResult] = None,
               gui: bool = False) -> Tuple[int, float]:
        """Run cmd in its own process group, raw output to <run>/<log>, each line parsed live.
        Past the budget the group gets TERM, then KILL (our own child only), printing or not: a
        reader thread feeds a bounded queue and this thread waits on it with the deadline as its
        timeout. Exit 124 on timeout. Any exception here (Ctrl-C, HUP/TERM via stop_signals, a
        broken stdout pipe) stops the child before it propagates."""
        with stop_signals():
            try:
                return self._stream(cmd, log_name, budget, cwd, parser, on_line, lane, gui)
            except BaseException:
                self.stop()
                raise

    def _stream(self, cmd, log_name, budget, cwd, parser, on_line, lane, gui) -> Tuple[int, float]:
        t0 = time.monotonic()

        def handle(raw: str) -> None:
            if parser is not None and lane is not None:
                for ev in parser.feed(raw):
                    if ev.status == "OK":
                        lane.passed += 1
                    elif ev.status == "SKIPPED":
                        lane.skipped += 1
                    else:
                        lane.failed += 1
                        lane.failures.append(ev)
                    self.out.event(ev)
            if on_line is not None:
                on_line(raw)

        if gui and under_ssh():
            return self._stream_in_gui(cmd, log_name, budget, cwd, handle, t0)
        log = open(self.run_dir / log_name, "a", encoding="utf-8", errors="replace")
        log.write("$ " + " ".join(shlex.quote(x) for x in cmd) + "\n")
        self.child = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                      cwd=str(cwd) if cwd else None, env=self.env, start_new_session=True,
                                      text=True, encoding="utf-8", errors="replace", bufsize=1,
                                      pass_fds=held_fds())
        timed_out = False
        deadline = t0 + budget
        child = self.child
        stdout = child.stdout
        assert stdout is not None
        lines: "queue.Queue[Optional[str]]" = queue.Queue(maxsize=QUEUE_LINES)

        def read() -> None:                      # EOF (the child and its group gone) → None
            try:
                for raw in stdout:
                    lines.put(raw)
            except (OSError, ValueError):
                pass
            lines.put(None)
        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        try:
            while True:
                left = deadline - time.monotonic()
                if left <= 0:
                    timed_out = True
                    self.stop()
                    break
                try:
                    raw = lines.get(timeout=min(left, 1.0))
                except queue.Empty:
                    continue
                if raw is None:
                    break
                log.write(raw)
                handle(raw)
            rc = child.wait()
        finally:
            log.close()
        reader.join(2)
        self.child = None
        return (124 if timed_out else rc), time.monotonic() - t0

    def _stream_in_gui(self, cmd: List[str], log_name: str, budget: int, cwd: Optional[Path], handle, t0: float):
        """App-hosted tests started from an ssh session need the user's GUI launchd domain (testing.md
        §4 gotchas; m4_run.sh does the same): run cmd as a one-shot LaunchAgent in gui/<uid>, its output
        to the log, and follow the log. Stopping = `launchctl bootout` of that one job (ours)."""
        uid = os.getuid()
        label = f"com.videoscan.runtests.{os.getpid()}.{int(t0)}"
        log_path = self.run_dir / log_name
        rc_path = self.run_dir / (log_name + ".rc")
        plist = self.run_dir / (label + ".plist")
        with open(log_path, "a") as fh:
            fh.write("$ (gui/%d) %s\n" % (uid, " ".join(shlex.quote(x) for x in cmd)))
        script = "%s >> %s 2>&1; echo $? > %s" % (" ".join(shlex.quote(x) for x in cmd),
                                                  shlex.quote(str(log_path)), shlex.quote(str(rc_path)))
        plist.write_text(gui_plist(label, ["/bin/bash", "-c", script], self.env, str(cwd) if cwd else str(HOME)))
        boot = subprocess.run(["launchctl", "bootstrap", f"gui/{uid}", str(plist)], capture_output=True, text=True)
        if boot.returncode != 0:
            with open(log_path, "a") as fh:
                fh.write(f"launchctl bootstrap gui/{uid} failed: {boot.stderr.strip()} — is anyone logged in at the console?\n")
            self.out.plain(" " * 13 + f"cannot start the test host in gui/{uid} (no GUI login on this Mac?): "
                                      f"{boot.stderr.strip()[:200]}")
            return 1, time.monotonic() - t0
        self.gui_label = f"gui/{uid}/{label}"
        pos, buf, timed_out = 0, "", False
        try:
            while True:
                done = rc_path.exists()
                with open(log_path, encoding="utf-8", errors="replace") as fh:
                    fh.seek(pos)
                    chunk = fh.read()
                    pos = fh.tell()
                lines = (buf + chunk).split("\n")
                buf = lines.pop()
                for ln in lines:
                    handle(ln + "\n")
                if done:
                    break
                if time.monotonic() > t0 + budget:
                    timed_out = True
                    break
                time.sleep(0.5)
        finally:
            subprocess.run(["launchctl", "bootout", self.gui_label], capture_output=True)
            self.gui_label = None
        if timed_out:
            return 124, time.monotonic() - t0
        try:
            rc = int(rc_path.read_text().strip() or "1")
        except (OSError, ValueError):
            rc = 1
        return rc, time.monotonic() - t0

    def stop(self) -> None:
        """Idempotent: our one LaunchAgent job, or our child's process group (TERM, then KILL)."""
        if getattr(self, "gui_label", None):
            subprocess.run(["launchctl", "bootout", self.gui_label], capture_output=True)
            self.gui_label = None
        child, self.child = self.child, None
        if child is None:
            return
        for sig in (signal.SIGTERM, signal.SIGKILL):
            try:
                os.killpg(child.pid, sig)
            except OSError:
                return
            try:
                child.wait(timeout=10)
                return
            except subprocess.TimeoutExpired:
                continue


def python_for_tests(repos: Sequence[Path]) -> Tuple[Optional[List[str]], str]:
    """The first interpreter with pytest: <repo>/venv of the checkout we came from, then
    ~/dev/VideoScan/venv (the side worktree has none: venv/ is not in git), then Apple's."""
    cands = [str(r / "venv" / "bin" / "python") for r in repos] + ["/usr/bin/python3"]
    seen = []
    for c in cands:
        if c in seen or not Path(c).exists():
            continue
        seen.append(c)
        p = subprocess.run([c, "-m", "pytest", "--version"], capture_output=True, stdin=subprocess.DEVNULL)
        if p.returncode == 0:
            return [c], c
    return None, f"no pytest in {', '.join(dict.fromkeys(cands))} (scripts/install_dev_tools.sh makes venv/)"


PROBE_PATH = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
# tool → (the lanes that need it, how to get it). Lane names are run_lanes' (app, core, python).
TOOLS = {
    "metal": (("app",), "Metal Toolchain (xcodebuild -downloadComponent MetalToolchain)"),
    "ffmpeg": (("app", "core", "python"), "ffmpeg (brew install ffmpeg)"),
    "ffprobe": (("app", "core", "python"), "ffprobe (brew install ffmpeg)"),
    "node": (("python",), "node (brew install node)"),
    "pytest": (("python",), "a Python with pytest (scripts/install_dev_tools.sh makes venv/)"),
}


def preflight(lanes: set, env: Dict[str, str], which=shutil.which, run=subprocess.run,
              find_python=None) -> Dict[str, List[str]]:
    """{lane: [what is missing]} for the lanes about to run (app, core, python), probed on THIS Mac
    with /opt/homebrew/bin first. Cheap: a few `which` lookups and one `xcrun metal --version`."""
    path = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", PROBE_PATH)
    probe_env = dict(env, PATH=path)
    missing: List[str] = []
    if "app" in lanes:
        try:
            ok = run(["xcrun", "metal", "--version"], capture_output=True, env=probe_env,
                     stdin=subprocess.DEVNULL, timeout=60).returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            ok = False
        if not ok:
            missing.append("metal")
    for tool in ("ffmpeg", "ffprobe", "node"):
        if lanes & set(TOOLS[tool][0]) and not which(tool, path=path):
            missing.append(tool)
    if "python" in lanes:
        interp, _ = (find_python or python_for_tests)([SCRIPT_REPO or BASE_REPO, BASE_REPO])
        if interp is None:
            missing.append("pytest")
    out: Dict[str, List[str]] = {}
    for tool in missing:
        for lane in TOOLS[tool][0]:
            if lane in lanes:
                out.setdefault(lane, []).append(TOOLS[tool][1])
    return out


def missing_block(host: str, missing: Dict[str, List[str]]) -> str:
    items = list(dict.fromkeys(x for xs in missing.values() for x in xs))
    return f"{host} is missing: " + ", ".join(items) + f" — lanes NOT RUN (setup): {', '.join(sorted(missing))}"


def setup_lane(name: str, missing: List[str]) -> LaneResult:
    return LaneResult(name, reason="setup: missing " + ", ".join(missing), setup=list(missing))


def corpus_applies(target_host: Optional[str], local_key: Optional[str]) -> Tuple[bool, str]:
    if target_host == "m4" and local_key == "ultra":
        return True, ""
    return False, "M4 only, launched from the Ultra with --host m4"


def prune_runs(root: Path, keep: int = KEEP_RUNS) -> None:
    """Keep the newest `keep` run folders — never one a live run uses (review F5: side by side, an hour-long
    --full is the oldest name while twenty quick runs come and go; its logs, TMPDIR and, over ssh, the .rc
    file _stream_in_gui waits for live there)."""
    import shutil
    live = live_runs()
    pids = {str(r.get("pid")) for r in live}
    dirs = {str(r.get("run_dir")) for r in live if r.get("run_dir")}
    runs = sorted([p for p in root.iterdir() if p.is_dir()], key=lambda p: p.name)
    for p in runs[:-keep]:
        if p.name.rsplit("-", 1)[-1] in pids or str(p) in dirs:
            continue
        shutil.rmtree(p, ignore_errors=True)          # our own raw logs only, never media or a checkout


def run_lanes(a, picks: List[Pick], wt: Path, base: Path, out: Out, run_dir: Path, header: str,
              missing: Optional[Dict[str, List[str]]] = None, slot: Optional[Slot] = None,
              live: Optional[LiveRun] = None, sha: str = "") -> List[LaneResult]:
    """The smoke lanes. `missing` (preflight): a lane named there is NOT RUN (setup), the rest run.
    `slot`: the worktree/DerivedData pair this run shares; each build happens under that slot's build
    lock, once per commit (the built-<kind> stamp), and the tests run from its products side by side
    with any other run at the same commit. Without a slot (tests): no lock, the default DerivedData."""
    missing = missing or {}
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    r = Runner(out, run_dir, env)
    # Python and shell tests: their own TMPDIR and pytest --basetemp in this run's folder (as
    # testbed_strands gives each strand), no .pyc written into the shared worktree. The Swift lanes
    # keep the system TMPDIR (their tests make their own unique temp folders).
    py_env = dict(env, TMPDIR=str(run_dir / "tmp") + "/", PYTHONDONTWRITEBYTECODE="1")
    rp = Runner(out, run_dir, py_env)
    dd = slot.dd if slot is not None else None
    lanes: List[LaneResult] = []
    app = [p for p in picks if p.kind == "app"]
    core = [p for p in picks if p.kind == "core"]
    py = [p for p in picks if p.kind in ("python", "shell")]
    out.expected = sum(p.tests for p in picks)
    phase = (lambda **kw: live.update(**kw)) if live is not None else (lambda **kw: None)
    exact = lambda ps: bool(getattr(a, "test_filter", None)) and all(p.exact for p in ps)
    out.line("==========", header)

    def build(kind: str, cmd: List[str], log: str, label: str) -> Tuple[int, float]:
        """(exit, seconds) of the build, or (0, 0.0) when this commit's products are already built."""
        with build_lock(slot, kind, sha, out, live):
            if slot is not None and slot_head(slot.wt) != sha:      # cannot happen while we hold the slot; say so if it does
                out.line("FAILED", f"slot {slot.label} is no longer at {sha[:9]} — not building or testing there", "FAILED")
                return 1, 0.0
            if slot is not None and built_at(slot, kind) == sha:
                out.line("BUILD", f"{label} — already built at {sha[:9]} in slot {slot.label}", "BUILD")
                return 0, 0.0
            phase(phase=f"{kind}: building")
            out.line("BUILD", f"{label} …", "BUILD")
            rc, el = r.stream(cmd, log, LANE_BUDGET["build"])
            if rc == 0:
                mark_built(slot, kind, sha)
            return rc, el
    try:
        if "app" in a.kinds and app and "app" in missing:
            lanes.append(setup_lane("app", missing["app"]))
        elif "app" in a.kinds:
            lane = LaneResult("app")
            lanes.append(lane)
            if not app:
                lane.reason = "no app suites selected"
            else:
                rc, el = build("app", app_build_cmd(wt, dd), "app-build.log", "VideoScan Debug build-for-testing")
                if rc != 0:
                    lane.ran, lane.rc, lane.seconds = True, rc, el
                    lane.reason = f"build failed (exit {rc}) — see {run_dir}/app-build.log"
                    out.line("FAILED", f"VideoScan Debug build-for-testing {fmt_secs(el)}: exit {rc}", "FAILED")
                else:
                    if el:
                        out.line("BUILD", f"VideoScan Debug build-for-testing {'.' * 8} {fmt_secs(el)}", "BUILD")
                    sel = app_selectors(app)
                    out.line("RUN", f"app {'+'.join(a.stages_label)} ({len({s for p in app for s in p.suites})} suites, "
                                    f"~{sum(p.tests for p in app)} tests)")
                    lane.ran, lane.expected = True, sum(p.tests for p in app)
                    lane.exact = exact(app)
                    phase(phase="app: testing", done=out.done, total=out.expected)
                    jobs = app_jobs(a)
                    if jobs > 1 and shards_script(wt).exists():
                        # N test hosts at once (scripts/xctest_shards.py). Its own lines say the deal, the
                        # serial tail and each shard's verdict; a RED one is the lane's reason.
                        plan = run_dir / "app-shards-plan.json"
                        plan.write_text(json.dumps(shard_plan(app)))
                        red: List[str] = []
                        said: List[str] = []

                        def shard_line(raw: str) -> None:
                            if raw.startswith(SHARD_LINE):
                                text = raw[len(SHARD_LINE):].rstrip()
                                said.append(text)
                                if " — RED" in text or text.startswith("RED"):
                                    red.append(text)
                                if not text.startswith("failed: "):      # the test's own line already said it
                                    out.plain(" " * 13 + text)
                        lane.rc, lane.seconds = r.stream(app_shards_cmd(wt, plan, jobs, run_dir / "app-shards", dd),
                                                         "app-test.log", LANE_BUDGET["app"], parser=LineParser(),
                                                         lane=lane, gui=True, on_line=shard_line)
                        adopt_shard_verdict(lane, said)
                        if lane.rc not in (0, None) and not lane.failed and red:
                            lane.reason = _short("; ".join(red[:3]))
                    else:
                        lane.rc, lane.seconds = r.stream(app_test_cmd(wt, sel, dd, run_dir / "app.xcresult"), "app-test.log",
                                                         LANE_BUDGET["app"], parser=LineParser(), lane=lane, gui=True)
                    lane_end(out, lane, run_dir / "app-test.log")
        if "core" in a.kinds and core and "core" in missing:
            lanes.append(setup_lane("core", missing["core"]))
        elif "core" in a.kinds:
            lane = LaneResult("core")
            lanes.append(lane)
            if not core:
                lane.reason = "no Core suites selected"
            else:
                suites = sorted({s for p in core for s in p.suites})
                rc, el = build("core", core_build_cmd(wt), "core-build.log", "VideoScanCore swift build --build-tests")
                if rc != 0:
                    lane.ran, lane.rc, lane.seconds = True, rc, el
                    lane.reason = f"build failed (exit {rc}) — see {run_dir}/core-build.log"
                    out.line("FAILED", f"VideoScanCore swift build {fmt_secs(el)}: exit {rc}", "FAILED")
                else:
                    if el:
                        out.line("BUILD", f"VideoScanCore (swift build --build-tests) {'.' * 8} {fmt_secs(el)}", "BUILD")
                    out.line("RUN", f"core, Debug, from the built bundle, two phases ({len(suites)} suites, ~{sum(p.tests for p in core)} tests)")
                    lane.ran, lane.expected = True, sum(p.tests for p in core)
                    lane.exact = exact(core)
                    phase(phase="core: testing", done=out.done, total=out.expected)
                    cases = [c for p in core for c in p.cases]
                    lane.rc, lane.seconds = r.stream(core_test_cmd(wt, core_filter(suites, cases)), "core.log",
                                                     LANE_BUDGET["core"], parser=LineParser(), lane=lane)
                    lane_end(out, lane, run_dir / "core.log")
        if "python" in a.kinds and py and "python" in missing:
            lanes.append(setup_lane("python", missing["python"]))
        elif "python" in a.kinds:
            lane = LaneResult("python")
            lanes.append(lane)
            targets = python_targets(py)
            interp, why = python_for_tests([base, BASE_REPO])
            if not targets:
                lane.reason = "no Python tests selected"
            elif interp is None:
                lane.reason = why
            else:
                n = sum(p.tests for p in py if p.kind == "python")
                lane.ran, lane.expected = True, n
                lane.exact = exact([p for p in py if p.kind == "python"])
                out.line("RUN", f"python pytest via {interp[0]} ({len({p.path for p in py if p.kind == 'python'})} files, ~{n} tests)")
                phase(phase="python: testing", done=out.done, total=out.expected)
                with contextlib.suppress(OSError):
                    (run_dir / "tmp").mkdir(parents=True, exist_ok=True)
                lane.rc, lane.seconds = rp.stream(pytest_cmd(interp, targets, run_dir / "pytest-tmp"), "python.log",
                                                 LANE_BUDGET["python"], cwd=wt, parser=LineParser(), lane=lane)
                # pytest exit 1 = some test failed (each one counted and named): the counts say it
                if lane.rc == 1 and lane.failed:
                    lane.rc = 0
                lane_end(out, lane, run_dir / "python.log")
            shfiles = [p.path for p in py if p.kind == "shell"]
            if shfiles:
                sl = LaneResult("shell", ran=True, rc=0)
                lanes.append(sl)
                out.line("RUN", f"shell self-tests ({len(shfiles)})")
                phase(phase="shell: testing")
                for sh in shfiles:
                    with contextlib.suppress(OSError):
                        (run_dir / "tmp").mkdir(parents=True, exist_ok=True)
                    rc, el = rp.stream(["/bin/bash", sh], "shell.log", 900, cwd=wt)
                    sl.seconds += el
                    ev = Event("OK" if rc == 0 else "FAILED", sh, el, "" if rc == 0 else f"exit {rc} — see {run_dir}/shell.log")
                    if rc == 0:
                        sl.passed += 1
                    else:
                        sl.failed += 1
                        sl.failures.append(ev)
                    out.event(ev)
                lane_end(out, sl, run_dir / "shell.log")
    except KeyboardInterrupt as e:
        r.stop()
        rp.stop()
        mark_interrupted(out, lanes, e)
    return lanes


def mark_interrupted(out: Out, lanes: List[LaneResult], e: BaseException) -> None:
    """Ctrl-C / SIGHUP / SIGTERM: the lane that was running is incomplete, not failed; say so in words."""
    why = str(e) or "Ctrl-C"               # a bare KeyboardInterrupt has no text (was printed as "()")
    for l in lanes:
        if l.ran and l.word == "RED" and not l.failures and not l.reason:
            l.reason = f"stopped by the interrupt after {l.total} tests (incomplete, not a test failure)"
    out.line("FAILED", f"interrupted ({why}) — the run is incomplete", "FAILED")
    lanes.append(LaneResult("interrupted", ran=True, rc=130, reason="the run is incomplete"))


def lane_end(out: Out, lane: LaneResult, log: Path) -> None:
    extra = ""
    if lane.rc not in (0, None) and not lane.failed:
        extra = f", exit {lane.rc}" + (" (timed out)" if lane.rc == 124 else "")
    if lane.total == 0:
        extra += " — ZERO tests ran (red)"
    elif lane.shrank and lane.exact:
        lane.reason = lane.reason or f"ran {lane.total} of {lane.expected} the filter named"
        extra += f" — ran {lane.total} of {lane.expected} the filter named (red)"
    elif lane.shrank:
        lane.reason = lane.reason or f"selection shrank: ran {lane.total} of ~{lane.expected}"
        extra += f" — selection shrank: ran {lane.total} of ~{lane.expected} (red)"
    elif lane.exact and lane.ran:
        extra += f" — ran {lane.total} of {lane.expected} the filter named"
    out.line("----------", f"{lane.name}: {lane.passed} passed, {lane.failed} failed, {lane.skipped} skipped"
                           f"{extra} ({fmt_secs(lane.seconds)})", lane.word)
    if lane.word == "RED" and not lane.failed:
        out.plain(" " * 13 + f"log: {log}")


def summary(out: Out, lanes: List[LaneResult], elapsed: float, run_dir: Optional[Path]) -> int:
    code, word = verdict(lanes)
    for l in lanes:
        if not l.ran:
            out.line("NOT RUN", f"{l.name}: {l.reason}", "NOT RUN")
    green = sum(1 for l in lanes if l.ran and l.word == "GREEN")
    red = sum(1 for l in lanes if l.ran and l.word == "RED")
    notrun = sum(1 for l in lanes if not l.ran)
    total = sum(l.total for l in lanes)
    out.line("==========", f"{word} · lanes: GREEN {green} · RED {red}"
                           f"{f' · NOT RUN {notrun}' if notrun else ''} · {total} tests · {fmt_secs(elapsed)}", word)
    fails = [e for l in lanes for e in l.failures]
    for e in fails:
        out.line("FAILED", e.name, "FAILED")
    for l in lanes:
        if l.ran and l.word == "RED" and not l.failures:
            out.line("FAILED", f"{l.name}: {l.reason or 'no test counted'}", "FAILED")
    if run_dir is not None:
        out.plain(f"logs: {run_dir}")
    if any(l.name == "interrupted" for l in lanes):
        return 130                         # the --host caller skips its corpus step on this
    return code


# ───────────────────────────────────────────────────────────── corpus (caller side)

CORPUS_SUMMARY = re.compile(r"^\s*(corpus \w+|OUTCOME|m4_run: |M4: )")


def corpus_cmd(script_repo: Path, sha: str, smoke: bool) -> List[str]:
    return (["/bin/bash", str(script_repo / "scripts" / "corpus_run.sh"), "run", "check", "--ref", sha]
            + (["--smoke"] if smoke else []) + ["--wait"])


def m4_full_cmd(script_repo: Path, sha: str, force: bool) -> List[str]:
    """--full --host m4: the M4's everything, through its own door (a LaunchAgent in its GUI session)."""
    return (["/bin/bash", str(script_repo / "scripts" / "m4_run.sh"), "testbed", "--host", "m4", "--ref", sha, "--wait"]
            + (["--force"] if force else []))


M4_SUITE_COUNTS = re.compile(r"\b(app|core) (\d+) passed, (\d+) failed")


def this_testbed_block(lines: Sequence[str]) -> List[str]:
    """Only this run's block of m4_run's status: from "last run:" to the next "last …:" or "push watcher"
    block. The status also prints the previous suite run (M4 2026-11-20: its 3 failures were counted as
    this testbed's)."""
    block: List[str] = []
    inside = False
    for line in lines:
        s = line.strip()
        if s.startswith("last run:"):
            inside = True
            continue
        if inside and (s.startswith("last ") or s.startswith("push watcher")):
            break
        if inside:
            block.append(line)
    return block


def m4_full_lane(lines: Sequence[str], rc: int, seconds: float) -> LaneResult:
    """The testbed's verdict as one lane: its exit (0 GREEN/AMBER · 1 RED · 2 could not run · 3 busy ·
    5 window), its suite counts (the last app/core pair it printed), never a green without a count."""
    lane = LaneResult("M4 testbed (suite + corpus check + proof)", rc=rc, seconds=seconds)
    if rc in (3, 5):
        lane.reason = "the M4 is busy (testbed lock)" if rc == 3 else "the M4's nightly/quiet window (--force runs anyway)"
        return lane
    lane.ran = True
    counts: Dict[str, Tuple[int, int]] = {}
    for line in this_testbed_block(lines):
        for kind, passed, failed in M4_SUITE_COUNTS.findall(line):
            counts.setdefault(kind, (int(passed), int(failed)))
    lane.passed = sum(c[0] for c in counts.values())
    lane.failed = sum(c[1] for c in counts.values())
    if any("AMBER" in l for l in lines if l.lstrip().startswith(("OUTCOME", "testbed:"))) and rc == 0:
        lane.reason = "amber: see the testbed summary above"
    elif rc != 0:
        lane.reason = f"m4_run.sh testbed exit {rc}" + (" (could not run)" if rc == 2 else "")
    elif not counts:
        lane.reason = "the testbed printed no suite count"
    return lane


def run_m4_full(out: Out, script_repo: Path, sha: str, force: bool) -> Tuple[LaneResult, Path]:
    runs = CACHE / "runs"
    runs.mkdir(parents=True, exist_ok=True)
    prune_runs(runs, KEEP_RUNS - 1)
    run_dir = runs / time.strftime("%Y%m%d-%H%M%S-m4full")
    run_dir.mkdir(parents=True, exist_ok=True)
    out.line("RUN", "M4 testbed: full suite, then the whole corpus check and proof (m4_run.sh's own lines)")
    seen: List[str] = []

    def show(raw: str) -> None:
        s = raw.rstrip()
        if s:
            seen.append(s)
            out.plain(" " * 13 + s)
    rc, el = Runner(out, run_dir, dict(os.environ)).stream(m4_full_cmd(script_repo, sha, force), "m4-testbed.log",
                                                          LANE_BUDGET["m4full"], on_line=show)
    lane = m4_full_lane(seen, rc, el)
    if lane.ran:
        out.line("----------", f"M4 testbed: {lane.passed} passed, {lane.failed} failed, exit {rc} ({fmt_secs(el)})", lane.word)
    return lane, run_dir


REMOTE_TOTAL = re.compile(r"\[==========\] (GREEN|RED|NOT READY: setup) · [^\n]*?· (\d+) tests · ")


def remote_word(text: str) -> str:
    """The host's own verdict word from its last ==== line ("" when there is none)."""
    clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text).replace("\r", "\n")
    ms = list(REMOTE_TOTAL.finditer(clean))
    return ms[-1].group(1) if ms else ""


def remote_counts(text: str) -> Tuple[int, int, List[str]]:
    """(tests, failed, failed names) from the remote run's own final block (its last ==== line)."""
    clean = re.sub(r"\x1b\[[0-9;]*[A-Za-z]", "", text).replace("\r", "\n")   # \r ends the live counter
    ms = list(REMOTE_TOTAL.finditer(clean))
    if not ms:
        return 0, 0, []
    last = ms[-1]
    names = re.findall(r"^\[  FAILED  \] (.+)$", clean[last.end():], re.M)
    return int(last.group(2)), len(names), names


class CorpusLines:
    """Which of corpus_run.sh's lines to show: its own summary words only (never a path or a corpus file
    name), and only up to THIS run's "corpus check: <VERDICT> N files" line — m4_run's status block after
    it lists older runs' lanes (11-19: "8 files" of an old testbed run was read as this run's count)."""
    LINE = re.compile(r"^\s*corpus check: (GREEN|AMBER|RED)\b.*?\b(\d+) files\b")

    def __init__(self) -> None:
        self.files = 0
        self.done = False

    def feed(self, raw: str) -> Optional[str]:
        s = raw.strip()
        if self.done or not CORPUS_SUMMARY.match(s):
            return None
        m = self.LINE.match(s)
        if m:
            self.files = int(m.group(2))
            self.done = True
        return s


def run_corpus(out: Out, script_repo: Path, sha: str, run_dir: Path, verbose: bool, smoke: bool) -> LaneResult:
    lane = LaneResult("corpus")
    cmd = corpus_cmd(script_repo, sha, smoke)
    out.line("RUN", f"corpus check on the M4{' (--smoke: the smallest file of each codec mix)' if smoke else ''} — the harness's own summary lines only")
    r = Runner(out, run_dir, dict(os.environ))
    picker = CorpusLines()

    def show(raw: str) -> None:
        s = picker.feed(raw)
        if s is not None:
            out.plain(" " * 13 + s)
    rc, el = r.stream(cmd, "corpus.log", LANE_BUDGET["corpus"], on_line=show)
    files = {"n": picker.files}
    lane.seconds, lane.rc = el, rc
    if rc in (3, 5):
        lane.reason = "the M4 is busy (testbed lock) or in its window" if rc == 3 else "the M4's nightly/quiet window"
        return lane
    lane.ran = True
    lane.passed = files["n"] if rc == 0 else 0
    lane.failed = 0 if rc == 0 else max(files["n"], 1)
    if rc != 0:
        lane.reason = f"corpus_run.sh exit {rc}"
        lane.failures.append(Event("FAILED", "corpus check", el, f"exit {rc} — see {run_dir}/corpus.log"))
    out.line("----------", f"corpus: {files['n']} files, exit {rc} ({fmt_secs(el)})", lane.word)
    return lane


# ───────────────────────────────────────────────────────────── main

def resolve(repo: Path, ref: str) -> str:
    return git(repo, "rev-parse", "--verify", "-q", ref + "^{commit}")


def on_origin(repo: Path, sha: str) -> bool:
    return bool(git(repo, "branch", "-r", "--contains", sha, check=False).strip())


def plan_line(a, host_label: str, ref_label: str, sha: str, picks: List[Pick], corpus_note: str, dirty: bool) -> str:
    kinds = [k for k in ("app", "core", "python") if k in a.kinds]
    n = f"~{sum(p.tests for p in picks)} tests" if a.mode == "smoke" else "all suites (nightly runners)"
    est = "~10 min with a warm build" if a.mode == "smoke" else "1–2 h"
    s = (f"{a.mode} · {host_label} · {ref_label} {sha[:9]} · {', '.join(kinds) or '—'}"
         f"{f' ({corpus_note})' if corpus_note else ''} · {n} · {est}")
    if getattr(a, "test_filter", None):
        s += f" · --filter {a.filter!r}"
    elif a.mode == "smoke" and not a.stage_flags:
        s += " · perf/stress left out (--perf --stress)"
    if dirty:
        s += "\n  uncommitted changes in your checkout are NOT included (it tests the commit)"
    return s


def countdown(out: Out, secs: int = 5) -> None:
    out.plain(f"  Ctrl-C within {secs} s to cancel")
    time.sleep(secs)


def main(argv: Optional[Sequence[str]] = None) -> int:
    # HUP/TERM become KeyboardInterrupt for the whole run: every path that handles Ctrl-C
    # (the countdown, the lanes, the ssh caller) handles a dropped session and `kill` the same way.
    with stop_signals():
        return _main(argv)


def nothing_here(a, picks: List[Pick]) -> bool:
    """True when this Mac's own lanes would run nothing (corpus is never a local lane)."""
    if a.mode == "full":
        return not (a.kinds & {"app", "core", "python"})
    return not picks


def _main(argv: Optional[Sequence[str]] = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if argv[:1] == ["--core-exec"] and len(argv) == 3:       # internal: the Core lane's test child
        return core_exec(argv[1], argv[2])
    # --ref-label is internal (the ssh caller passes the name the user typed)
    ref_label = None
    if "--ref-label" in argv:
        i = argv.index("--ref-label")
        ref_label = argv[i + 1] if i + 1 < len(argv) else None
        del argv[i:i + 2]
    a = parse_args(argv)
    a.stages_label = list(a.stages)
    out = Out(a.verbose)
    local_key = local_host_key()
    local_name = socket.gethostname().split(".")[0]
    target = None if a.on_host else ssh_target(a.host, None)
    base = BASE_REPO if (a.on_host or SCRIPT_REPO is None) else SCRIPT_REPO

    if a.status:
        for line in status_block(local_name):
            print(line)
        return 0

    if target and a.mode == "full" and a.host != "m4":
        print("run_tests: --full --host runs only on the M4 (its testbed, in its GUI session); app-hosted tests "
              "cannot start inside an ssh session elsewhere — type scripts/run_tests.sh --full on that Mac.",
              file=sys.stderr)
        return 2

    # The commit: --ref, else HEAD of the checkout this script runs from.
    if not a.on_host:
        git(base, "fetch", "-q", "origin", check=False)
    ref = a.ref or "HEAD"
    try:
        sha = resolve(base, ref)
    except Refused:
        print(f"run_tests: unknown ref {ref}", file=sys.stderr)
        return 2
    if ref_label is None:
        ref_label = ref if a.ref else (git(base, "rev-parse", "--abbrev-ref", "HEAD", check=False) or "HEAD")
    dirty = (not a.on_host and a.ref is None and
             bool(git(base, "status", "--porcelain", "--untracked-files=no", check=False)))

    manifest = json.loads(git(base, "show", f"{sha}:scripts/gauntlet/manifest.json"))
    files = git(base, "ls-tree", "-r", "--name-only", sha).splitlines()
    picks = select(manifest, files, a.stages, a.kinds) if a.mode == "smoke" else []
    if a.test_filter is not None:          # also before a --host run: a no-match never reaches ssh
        # The pool is every runnable file of the stages and kinds asked (not the smoke's few); the
        # filter names the tests. Nothing matched: refused here, before a worktree, a lock or a build.
        pool = select(manifest, files, a.stages, a.kinds, full=True)
        picks = apply_filter(pool, a.test_filter, lambda paths: cat_files(base, sha, paths))
        if not picks:
            blocked = apply_filter([p for p in select(manifest, files, a.stages, a.kinds, full=True, everything=True)
                                    if p not in pool], a.test_filter, lambda paths: cat_files(base, sha, paths))
            why = ""
            if blocked:
                reasons = {e["path"]: e.get("blocked_reason", "") for e in manifest.get("assignments", [])}
                why = "; it matches only tests that cannot run here: " + "; ".join(
                    f"{Path(p.path).name} ({reasons.get(p.path, '')[:80]})" for p in blocked[:5])
            print(f"run_tests: --filter {a.filter!r} matches no test at {sha[:9]} "
                  f"({', '.join(sorted(a.kinds))}; {', '.join(a.stages)}){why}", file=sys.stderr)
            return 2

    if a.list:
        return print_list(a, picks, sha, ref_label)

    effective_host = a.host or local_key
    corpus_ok, corpus_why = corpus_applies(effective_host, local_key if not a.on_host else None)
    corpus_runs = bool(target) and corpus_ok and "corpus" in a.kinds
    corpus_note = ""
    if "corpus" in a.kinds and not a.on_host:
        corpus_note = "corpus on the M4 after" if corpus_runs else f"corpus: NOT RUN — {corpus_why}"
    host_label = HOST_NAMES.get(a.host, a.host) if target else local_name
    # Over ssh the host makes its own selection (and refuses an empty one); the corpus alone needs no host run.
    host_run = bool(target) and bool(a.kinds - {"corpus"})

    # --full --host m4 (other hosts were refused above): the M4's testbed, waited on from here.
    if target and a.mode == "full":
        if not on_origin(base, sha):
            print(f"run_tests: {ref_label} {sha[:9]} is not on origin — push it first (the M4 fetches from origin), "
                  f"or pass --ref of a pushed commit", file=sys.stderr)
            return 2
        cmd = m4_full_cmd(SCRIPT_REPO or BASE_REPO, sha, a.force)
        if a.dry_run:
            print("+ " + " ".join(shlex.quote(x) for x in cmd))
            return 0
        out.plain(f"full · M4 · {ref_label} {sha[:9]} · m4_run.sh testbed: the full suite (~1 h), then corpus check "
                  f"and proof over the whole real corpus (hours) · Ctrl-C stops the wait, not the M4's run")
        if out.tty and not a.yes:
            try:
                countdown(out)
            except KeyboardInterrupt:
                out.plain("cancelled")
                return 130
        t0 = time.monotonic()
        try:
            lane, run_dir = run_m4_full(out, SCRIPT_REPO or BASE_REPO, sha, a.force)
        except KeyboardInterrupt:
            out.line("FAILED", "interrupted — the wait stopped; the testbed goes on on the M4 "
                               "(scripts/m4_run.sh status --host m4)", "FAILED")
            return 130
        return summary(out, [lane], time.monotonic() - t0, run_dir)

    # Nothing to run: refused before anything is touched (no worktree, no lock, no run folder).
    if (not target and nothing_here(a, picks)) or (target and not host_run and not corpus_runs):
        if "corpus" in a.kinds and not (a.kinds - {"corpus"}):
            why = "corpus runs only on the M4 (--host m4, from the Ultra)"
        else:
            why = f"the selection is empty at {sha[:9]} ({', '.join(sorted(a.kinds))}; {', '.join(a.stages)})"
        print(f"run_tests: nothing to run here: {why}", file=sys.stderr)
        return 2

    if target:
        if host_run and not on_origin(base, sha):
            print(f"run_tests: {ref_label} {sha[:9]} is not on origin — push it first (the {HOST_NAMES[a.host]} "
                  f"fetches from origin), or pass --ref of a pushed commit", file=sys.stderr)
            return 2
        copy, run = remote_commands(target, sha, ref_label, argv)
        if a.dry_run:
            if host_run:
                print("+ " + " ".join(shlex.quote(x) for x in copy) + f" < {SELF}")
                print("+ " + " ".join(shlex.quote(x) for x in run))
            if corpus_runs:
                print(f"+ scripts/corpus_run.sh run check --ref {sha} --smoke --wait")
            return 0
        out.plain(plan_line(a, host_label, ref_label, sha, picks, corpus_note, dirty))
        if out.tty and not a.yes:
            try:
                countdown(out)
            except KeyboardInterrupt:
                out.plain("cancelled")
                return 130
        t0 = time.monotonic()
        rc, tail = 0, b""
        if host_run:
            with open(SELF, "rb") as fh:
                p = subprocess.run(copy, stdin=fh)
            if p.returncode != 0:
                print(f"run_tests: cannot reach {target} over ssh (exit {p.returncode}). If the key is refused: "
                      f"ssh-copy-id {target}", file=sys.stderr)
                return 1
            # Stream the host's bytes as they come (the live [ n/N ] counter has no newline), keeping
            # the tail to read the host's own total. Memory: the last 256 KB.
            proc = subprocess.Popen(run, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            assert proc.stdout is not None
            try:
                while True:
                    chunk = os.read(proc.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    sys.stdout.buffer.write(chunk)
                    sys.stdout.buffer.flush()
                    tail = (tail + chunk)[-262144:]
                rc = proc.wait()
            except KeyboardInterrupt:
                # With `ssh -t` the local tty is raw, so a Ctrl-C usually reaches the HOST runner, not
                # this one; here when this side gets HUP/TERM. Ending ssh closes the host's pty, the host
                # runner gets SIGHUP and stops its own child (stop_signals → Runner.stop).
                proc.terminate()
                proc.wait()
                return 130
            # 130 interrupted, 3 busy, 2 refused: the user did not get the run they asked for —
            # never go on to start the corpus lane on the M4.
            if rc in (2, 3, 130) or not corpus_runs:
                return rc
        # The corpus lane, from this Mac (corpus_run.sh is launched from the Ultra), after the
        # remote run released the M4's testbed lock.
        runs = CACHE / "runs"
        runs.mkdir(parents=True, exist_ok=True)
        prune_runs(runs, KEEP_RUNS - 1)
        run_dir = runs / time.strftime("%Y%m%d-%H%M%S-corpus")
        run_dir.mkdir(parents=True, exist_ok=True)
        try:
            lane = run_corpus(out, SCRIPT_REPO or BASE_REPO, sha, run_dir, a.verbose, a.mode == "smoke")
        except KeyboardInterrupt:
            out.line("FAILED", "interrupted — the corpus step is incomplete", "FAILED")
            return 130
        if not lane.ran:
            out.line("NOT RUN", f"corpus: {lane.reason}", "NOT RUN")
        lanes = [lane]
        if host_run and remote_word(tail.decode("utf-8", "replace")) == "NOT READY: setup" \
                and not remote_counts(tail.decode("utf-8", "replace"))[1]:
            lanes.insert(0, setup_lane(f"{HOST_NAMES[a.host]} smoke", ["tools (the host's block above)"]))
        elif host_run:
            n, nf, names = remote_counts(tail.decode("utf-8", "replace"))
            lanes.insert(0, LaneResult(f"{HOST_NAMES[a.host]} smoke", ran=True, passed=max(n - nf, 0), failed=nf,
                                       rc=rc, reason=f"exit {rc}", failures=[Event("FAILED", x) for x in names]))
        return summary(out, lanes, time.monotonic() - t0, run_dir)

    # ── on this Mac ──
    if a.dry_run:
        print(plan_line(a, host_label, ref_label, sha, picks, corpus_note, dirty))
        wt, dd = slot_paths(0)
        print(f"+ a side worktree slot at {sha[:9]} (one of {N_SLOTS}: {RUN_WT}[-2|-3], from {base}); "
              f"its DerivedData ({DD}[-2|-3]) — shown here for slot 1")
        if a.mode == "full":
            for c in full_commands(a, local_key):
                print("+ " + " ".join(shlex.quote(x) for x in c))
            return 0
        app = [p for p in picks if p.kind == "app"]
        core = [p for p in picks if p.kind == "core"]
        if app:
            print("+ " + " ".join(shlex.quote(x) for x in app_build_cmd(wt, dd)))
            if app_jobs(a) > 1:
                print("+ " + " ".join(shlex.quote(x) for x in app_shards_cmd(
                    wt, Path("<run>/app-shards-plan.json"), app_jobs(a), Path("<run>/app-shards"), dd))
                      + f"   # {app_jobs(a)} test hosts at once; --jobs 1 = one host")
            else:
                print("+ " + " ".join(shlex.quote(x) for x in app_test_cmd(wt, app_selectors(app), dd, Path("<run>/app.xcresult"))))
        if core:
            print("+ " + " ".join(shlex.quote(x) for x in core_build_cmd(wt)))
            print("+ " + " ".join(shlex.quote(x) for x in core_test_cmd(
                wt, core_filter(sorted({s for p in core for s in p.suites}), [c for p in core for c in p.cases]))))
        pyf = python_targets(picks)
        if pyf:
            print("+ " + " ".join(shlex.quote(x) for x in pytest_cmd(["<python>"], pyf, Path("<run>/pytest-tmp"))))
        return 0

    if a.mode == "full" and local_key == "ultra":
        out.plain("note: a --full run loads this Mac for an hour or more (DECISIONS: no full suite on Rick's "
                  "machine while he works) — proceeding because you asked")
    if local_key == "m4" and not a.force:
        hhmm = int(time.strftime("%H%M"))
        if 130 <= hhmm < 600:
            print("run_tests: the M4's nightly window (01:30–06:00) — not now; --force to run anyway", file=sys.stderr)
            return 3
    # Preflight: the tools the selected lanes need, on this Mac, before the worktree or a build.
    want = {k for k in ("app", "core", "python") if k in a.kinds and
            (a.mode == "full" or any((p.kind if p.kind != "shell" else "python") == k for p in picks))}
    missing = preflight(want, dict(os.environ))
    # The plan and the 5 s to cancel come BEFORE any side effect: Ctrl-C here changes nothing.
    out.plain(plan_line(a, host_label, ref_label, sha, picks, corpus_note, dirty))
    if missing:
        out.line("NOT READY", missing_block(local_name, missing), "NOT RUN")
        if not (want - set(missing)):           # nothing left that can run: no worktree, no build
            lanes = [setup_lane(k, missing[k]) for k in sorted(missing)]
            if "corpus" in a.kinds and not a.on_host:
                lanes.append(LaneResult("corpus", reason=corpus_why or "runs from the Ultra with --host m4"))
            return summary(out, lanes, 0.0, None)
    if out.tty and not a.yes:
        try:
            countdown(out)
        except KeyboardInterrupt:
            out.plain("cancelled")
            return 130
    CACHE.mkdir(parents=True, exist_ok=True)
    info = f"run_tests {a.mode} sha={sha[:9]} since {time.strftime('%F %T')}"
    # The only whole-run lock left is the M4 testbed's (its daily run has strict timing budgets).
    # Here, the shared things are the slots (worktree + DerivedData) and their builds: see acquire_slot.
    if local_key == "m4":
        try:
            take_lock(M4_LOCKDIR, info)
        except Busy as e:
            print(f"run_tests: busy — the M4 testbed lock is held: {e} (nothing queued)", file=sys.stderr)
            for line in status_block(local_name, with_m4=False, disk=False):
                print(line, file=sys.stderr)
            return 3
    live = LiveRun({"argv": argv, "mode": a.mode, "filter": a.filter, "sha": sha, "host": local_name,
                    "phase": "taking a side worktree", "slot": "?"})
    try:
        try:
            slot = acquire_slot(base, sha)
        except Busy as e:
            print(f"run_tests: busy — {e} (nothing queued; try again when one finishes)", file=sys.stderr)
            for line in status_block(local_name, with_m4=False, disk=False):
                print(line, file=sys.stderr)
            return 3
        except Refused as e:
            print(f"run_tests: REFUSED — {e}", file=sys.stderr)
            return 1
        except KeyboardInterrupt:
            out.plain("cancelled (while taking a side worktree; nothing ran)")
            return 130
        live.update(slot=slot.label, phase="starting")
        out.on_progress = lambda n: live.update(done=n)
        (CACHE / "runs").mkdir(exist_ok=True)
        prune_runs(CACHE / "runs", KEEP_RUNS - 1)
        run_dir = new_run_dir(a.mode)
        live.update(run_dir=str(run_dir))

        t0 = time.monotonic()
        if a.mode == "full":
            lanes = run_full(a, out, run_dir, local_key, missing, slot=slot, live=live)
        else:
            nlanes = len([k for k in ("app", "core", "python") if k in a.kinds])
            flt = f" · --filter {a.filter!r}" if a.filter else ""
            header = (f"smoke · {host_label} · {ref_label} {sha[:9]} · slot {slot.label} · {nlanes} lanes, "
                      f"~{sum(p.tests for p in picks)} tests{flt}")
            lanes = run_lanes(a, picks, slot.wt, base, out, run_dir, header, missing, slot=slot, live=live, sha=sha)
        if "corpus" in a.kinds and not a.on_host:
            lanes.append(LaneResult("corpus", reason=corpus_why or "runs from the Ultra with --host m4"))
        return summary(out, lanes, time.monotonic() - t0, run_dir)
    finally:
        live.close()


def new_run_dir(mode: str) -> Path:
    """This run's own folder (concurrent runs: the pid keeps two started in one second apart)."""
    d = CACHE / "runs" / f"{time.strftime('%Y%m%d-%H%M%S')}-{mode}-{os.getpid()}"
    d.mkdir(parents=True, exist_ok=True)
    return d


def full_commands(a, local_key: Optional[str], slot: Optional[Slot] = None) -> List[List[str]]:
    wt, dd = (slot.wt, slot.dd) if slot is not None else slot_paths(0)
    cmds = []
    if a.kinds & {"app", "core"}:
        cmds.append(["/bin/bash", str(wt / "scripts" / "nightly_local_tests.sh"), "--on-demand", "<run dir>/full",
                     "--repo", str(wt), "--dd", str(dd) + "-full"])
    if "python" in a.kinds:
        cmds.append(["PYTHON=<python with pytest>", "/bin/bash", str(wt / "scripts" / "run_python_tests.sh")])
    return cmds


def run_full(a, out: Out, run_dir: Path, local_key: Optional[str],
             missing: Optional[Dict[str, List[str]]] = None, slot: Optional[Slot] = None,
             live: Optional[LiveRun] = None) -> List[LaneResult]:
    """--full: the nightly's own runners, unchanged (one engine). Their logs are parsed for the
    live display; their own verdict (exit code) decides the lane. `missing` as in run_lanes.
    In the slot's worktree; the Release DerivedData (<slot dd>-full) is one --full run's at a time
    (the slot's .full lock — a second --full at that commit waits, a smoke there does not)."""
    missing = missing or {}
    wt, dd = (slot.wt, slot.dd) if slot is not None else slot_paths(0)
    full_fd = None
    swift_missing = list(dict.fromkeys(missing.get("app", []) + missing.get("core", [])))
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "/usr/bin:/bin")
    if getattr(a, "jobs", None):
        # The nightly runner shards its app phase itself (half the cores); --jobs is its override (1: one host).
        env["NIGHTLY_APP_JOBS"] = str(a.jobs)
    r = Runner(out, run_dir, env)
    lanes: List[LaneResult] = []
    out.line("==========", f"full · nightly_local_tests.sh --on-demand + run_python_tests.sh")
    try:
        if slot is not None and a.kinds & {"app", "core"}:
            full_fd = _lock_fd(slot_dir() / f"{slot.index}.full")
            if not _flock(full_fd, fcntl.LOCK_EX):
                out.line("WAIT", f"waiting for the other --full run in slot {slot.label} (its Release DerivedData)", "BUILD")
                if live is not None:
                    live.update(phase="waiting for another --full run")
                fcntl.flock(full_fd, fcntl.LOCK_EX)
        if live is not None:
            live.update(phase="full: nightly runners")
        if a.kinds & {"app", "core"} and swift_missing:
            lanes.append(setup_lane("app+core (nightly runner, Release)", swift_missing))
        elif a.kinds & {"app", "core"}:
            lane = LaneResult("app+core (nightly runner, Release)", ran=True)
            lanes.append(lane)
            (run_dir / "full").mkdir(exist_ok=True)
            cmd = ["/bin/bash", str(wt / "scripts" / "nightly_local_tests.sh"), "--on-demand", str(run_dir / "full"),
                   "--repo", str(wt), "--dd", str(dd) + "-full"]
            out.line("RUN", lane.name + f" — its own log: {run_dir}/full/suite.log")
            # The runner writes its test output to files, not stdout: tail them live.
            lane.rc, lane.seconds = tail_while(r, cmd, [run_dir / "full" / "suite-core-test.log",
                                                        run_dir / "full" / "suite-app-test.log"], lane)
            lane_end(out, lane, run_dir / "full" / "suite.log")
        if "python" in a.kinds and "python" in missing:
            lanes.append(setup_lane("python (run_python_tests.sh)", missing["python"]))
        elif "python" in a.kinds:
            lane = LaneResult("python (run_python_tests.sh)")
            lanes.append(lane)
            # The side worktree has no venv/ (not in git): without PYTHON= the script falls back to
            # a bare python3 that has no pytest on the fleet. Same interpreter choice as the smoke.
            interp, why = python_for_tests([SCRIPT_REPO or BASE_REPO, BASE_REPO])
            if interp is None:
                lane.reason = why
            else:
                lane.ran = True
                r.env["PYTHON"] = interp[0]
                out.line("RUN", f"{lane.name} via {interp[0]}")
                lane.rc, lane.seconds = r.stream(["/bin/bash", str(wt / "scripts" / "run_python_tests.sh")],
                                                 "python-full.log", 3600, cwd=wt, parser=LineParser(), lane=lane)
                if lane.total == 0 and lane.rc == 0:
                    # run_python_tests.sh uses -q (dots, not names): trust its own summary line
                    txt = (run_dir / "python-full.log").read_text(errors="replace")
                    m = re.findall(r"(\d+) passed", txt)
                    lane.passed = int(m[-1]) if m else 0
                lane_end(out, lane, run_dir / "python-full.log")
    except KeyboardInterrupt as e:
        r.stop()
        mark_interrupted(out, lanes, e)
    finally:
        if full_fd is not None:
            _close(full_fd)
    return lanes


def tail_while(r: Runner, cmd: List[str], logs: List[Path], lane: LaneResult) -> Tuple[int, float]:
    """Run cmd (its stdout to full-runner.log) and parse the given log files as they grow."""
    import threading
    parser = LineParser()
    stop = threading.Event()

    def follow() -> None:
        pos: Dict[Path, int] = {}
        buf: Dict[Path, str] = {}
        while not stop.is_set():
            for p in logs:
                try:
                    with open(p, encoding="utf-8", errors="replace") as fh:
                        fh.seek(pos.get(p, 0))
                        chunk = fh.read(1 << 20)
                        pos[p] = fh.tell()
                except OSError:
                    continue
                text = buf.get(p, "") + chunk
                lines = text.split("\n")
                buf[p] = lines.pop()
                for ln in lines:
                    for ev in parser.feed(ln):
                        if ev.status == "OK":
                            lane.passed += 1
                        elif ev.status == "SKIPPED":
                            lane.skipped += 1
                        else:
                            lane.failed += 1
                            lane.failures.append(ev)
                        r.out.event(ev)
            stop.wait(1.0)
    th = threading.Thread(target=follow, daemon=True)
    th.start()
    try:
        rc, el = r.stream(cmd, "full-runner.log", 6 * 3600)
    finally:
        time.sleep(1.5)
        stop.set()
        th.join(5)
    return rc, el


def print_list(a, picks: List[Pick], sha: str, ref_label: str) -> int:
    by: Dict[Tuple[str, str], List[Pick]] = {}
    for p in picks:
        by.setdefault((p.kind if p.kind != "shell" else "python", p.module), []).append(p)
    flt = getattr(a, "test_filter", None)
    print(f"{a.mode} selection at {ref_label} {sha[:9]} (from scripts/gauntlet/manifest.json)"
          + (f" · --filter {a.filter!r} over every runnable file of {', '.join(a.stages)}" if flt else ""))
    if a.mode == "full":
        print("  --full runs what the nightly runs: nightly_local_tests.sh --on-demand (app + Core, Release),"
              " run_python_tests.sh")
        return 0
    for (kind, mod) in sorted(by):
        ps = by[(kind, mod)]
        print(f"  {kind:6} {mod:28} " + "; ".join(f"{p.stage}: {', '.join(p.suites)} ({p.tests})" for p in ps))
        if flt:
            for p in ps:
                for c in p.cases:
                    print(f"  {'':6} {'':28}   {c[0] or Path(p.path).name}.{c[1]}" + (f"  [{c[2]}]" if c[2] and c[2] != c[1] else ""))
    for kind in ("app", "core", "python"):
        ks = [p for p in picks if (p.kind if p.kind != "shell" else "python") == kind]
        if ks:
            print(f"# {kind}: {len(ks)} files, {len({s for p in ks for s in p.suites})} suites, ~{sum(p.tests for p in ks)} tests")
    print(f"# total ~{sum(p.tests for p in picks)} tests")
    if not a.stage_flags and not flt:
        print("# not in the default smoke: performance, stress (add --perf / --stress)")
    print("# not in v1: UI tests (need the GUI session; broken, GH #408) · the hallie stage (the hallie eval's)")
    print("# corpus: only from the Ultra with --host m4 (corpus_run.sh run check --smoke --wait)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(1)
