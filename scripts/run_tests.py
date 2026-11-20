#!/usr/bin/env python3
"""run_tests.py — the front door Rick types: a smoke (or full) test run, narrated live.

    scripts/run_tests.sh [--smoke | --full] [--unit] [--regression] [--integration] [--perf]
                         [--stress] [--python] [--corpus] [--verbose] [--host m4|ultra|m5pro|m1]
                         [--ref <rev>] [--list] [--dry-run] [--yes] [--force]

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
    on THIS Mac only. `--full --host <another Mac>` is refused (exit 2): app-hosted tests cannot
    start inside an ssh session, and the M4 already has the right door — scripts/m4_run.sh suite
    --host m4 --ref <sha> --wait (the same runner, in the M4's GUI session); on any other Mac, type
    run_tests.sh --full there. A stage flag with --full is refused too (--full runs every stage).
  * display — a googletest-style stream: [ RUN ] / [ OK ] / [ FAILED ] / [ SKIPPED ] per test
    with --verbose (coloured on a TTY), one line per lane otherwise plus a live [ n/N ] counter.
    The parser reads the three line shapes our runners print (XCTest, Swift Testing, pytest -v)
    and xcodebuild's parallel "Test case '…' passed on" form; nothing to install (no xcbeautify).

Where it runs: on this Mac, or on --host over `ssh -t` (this file is copied to the host's
~/Library/Caches/videoscan-runall/ and run there with /usr/bin/python3: the host's own
checkout is never touched). Always in the side worktree ~/dev/VideoScan-wt/run-all, detached
at the ref (default: the HEAD commit of the checkout this script is run from), DerivedData
~/Library/Caches/videoscan-runall-dd — never Rick's checkout or Xcode's DerivedData (CLAUDE.md
rule 11; tests have been seen writing into a checkout, GH #495). A dirty side worktree is refused.

Corpus lane: only from the Ultra with --host m4 (scripts/corpus_run.sh run check --limit 10
--wait); elsewhere it says NOT RUN and why. Only the harness's own summary lines are shown.
`--corpus --host m4` alone runs the corpus lane only (no host smoke). A selection with nothing to
run on this Mac (e.g. --corpus without --host m4) is refused before anything is touched (exit 2).

Verdict: a lane is GREEN only with no failure, exit 0, at least one test, and at least half of the
tests its selection planned (a filter that matches nothing exits 0: "selection shrank"). A lane
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
here, --full with --host or a stage flag) · 3 busy (the M4 testbed lock, another run_tests on this
Mac, or the M4's nightly window without --force) · 130 interrupted (the caller of a --host run
then skips its corpus step, as it does on 2 and 3).

Memory: output is streamed line by line; held are the failure names and one message line each
(≤ 300 chars), and the selection (a few hundred short records). Worst case a few MB.
Disk: one run folder of raw logs per run (and per caller-side corpus step) under
~/Library/Caches/videoscan-runall/runs (newest 20 kept), one Debug DerivedData (~15 GB), with
--full also the nightly runner's Release DerivedData + Core scratch (videoscan-runall-dd-full,
~7 GB), the side worktree and its SwiftPM .build.
The reader thread's line queue is bounded (QUEUE_LINES lines, ~a few MB at worst).

Tests: tests/test_run_tests.py.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
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

LANE_BUDGET = {"app": 3600, "core": 3600, "python": 1800, "build": 3600, "corpus": 7200}
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
    ap.add_argument("--on-host", action="store_true", help=argparse.SUPPRESS)   # set by the ssh caller
    a = ap.parse_args(list(argv))                    # exits 2 on a usage error
    a.mode = "full" if a.full else "smoke"
    # The smoke leaves performance and stress out unless asked: they are load-sensitive and long
    # (Core's 100k-row scale tests take ~3 min each; Ultra smoke 11-19: 4.5 of its 10 minutes).
    a.stages = [STAGE_FLAGS[f] for f in STAGE_FLAGS if getattr(a, f)] or \
        (list(STAGES) if a.mode == "full" else list(SMOKE_STAGES))
    a.stage_flags = any(getattr(a, f) for f in STAGE_FLAGS)
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
        kinds = {"app", "core", "python"} | (set() if a.stage_flags else {"corpus"})
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
    dest = "~/Library/Caches/videoscan-runall/run_tests.py"
    copy = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=15", target,
            f"mkdir -p ~/Library/Caches/videoscan-runall && cat > {dest}"]
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


def select(manifest: dict, files: Sequence[str], stages: Sequence[str], kinds: set, full: bool = False) -> List[Pick]:
    """The deterministic smoke selection (or, with full, every runnable file — used for counts)."""
    index = build_index(files)
    groups: Dict[Tuple[str, str, str], List[dict]] = {}
    for e in manifest.get("assignments", []):
        kind, stage = e.get("kind"), e.get("stage")
        k = {"xcode": "app", "package": "core", "python": "python", "shell": "shell"}.get(kind)
        if k is None or stage not in stages:
            continue
        if (k in ("python", "shell") and "python" not in kinds) or (k in ("app", "core") and k not in kinds):
            continue
        if not runnable_here(e) or len(e.get("tests") or []) < 1:
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


# ───────────────────────────────────────────────────────────── commands

def xcode_flags(project: Path) -> List[str]:
    return ["-project", str(project), "-scheme", "VideoScan", "-configuration", "Debug",
            "-destination", "platform=macOS,arch=arm64", "-derivedDataPath", str(DD)]


SIGN = ["CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS=", "ONLY_ACTIVE_ARCH=YES"]


def app_build_cmd(wt: Path) -> List[str]:
    return ["xcodebuild", "build-for-testing"] + xcode_flags(wt / "VideoScan" / "VideoScan.xcodeproj") + SIGN


def app_test_cmd(wt: Path, suites: Sequence[str]) -> List[str]:
    return (["xcodebuild", "test-without-building"] + xcode_flags(wt / "VideoScan" / "VideoScan.xcodeproj")
            + ["-parallel-testing-enabled", "NO"] + [f"-only-testing:VideoScanTests/{s}" for s in suites])


def core_filter(suites: Sequence[str]) -> str:
    # matches "VideoScanCoreTests.Suite/testX" (XCTest) and "VideoScanCoreTests.Outer/Suite/f()" (Swift Testing)
    return r"(\.|/)(" + "|".join(re.escape(s) for s in sorted(set(suites))) + r")/"


def core_cmd(wt: Path, suites: Sequence[str]) -> List[str]:
    return ["swift", "test", "--package-path", str(wt / "VideoScan" / "VideoScanCore"), "--filter", core_filter(suites)]


def pytest_cmd(py: List[str], files: Sequence[str]) -> List[str]:
    return py + ["-m", "pytest", "-v", "-rfE", "-p", "no:cacheprovider", "--color=no"] + list(files)


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
    setup: List[str] = field(default_factory=list)   # missing tools (preflight): NOT RUN, not RED

    @property
    def total(self) -> int:
        return self.passed + self.failed + self.skipped

    @property
    def shrank(self) -> bool:
        return self.expected > 0 and self.total < self.expected * SHRANK

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
    except OSError:
        try:
            who = (lockdir / "info").read_text().strip().split(" ", 1)[-1]
        except OSError:
            who = "(no info)"
        os.close(fd)
        raise Busy(who)
    (lockdir / "info").write_text(f"{os.getpid()} {info}\n")
    return fd


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
                                      text=True, encoding="utf-8", errors="replace", bufsize=1)
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
    import shutil
    runs = sorted([p for p in root.iterdir() if p.is_dir()], key=lambda p: p.name)
    for p in runs[:-keep]:
        shutil.rmtree(p, ignore_errors=True)          # our own raw logs only, never media or a checkout


def run_lanes(a, picks: List[Pick], wt: Path, base: Path, out: Out, run_dir: Path, header: str,
              missing: Optional[Dict[str, List[str]]] = None) -> List[LaneResult]:
    """The smoke lanes. `missing` (preflight): a lane named there is NOT RUN (setup), the rest run."""
    missing = missing or {}
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
    r = Runner(out, run_dir, env)
    lanes: List[LaneResult] = []
    app = [p for p in picks if p.kind == "app"]
    core = [p for p in picks if p.kind == "core"]
    py = [p for p in picks if p.kind in ("python", "shell")]
    out.expected = sum(p.tests for p in picks)
    out.line("==========", header)
    try:
        if "app" in a.kinds and app and "app" in missing:
            lanes.append(setup_lane("app", missing["app"]))
        elif "app" in a.kinds:
            lane = LaneResult("app")
            lanes.append(lane)
            if not app:
                lane.reason = "no app suites selected"
            else:
                out.line("BUILD", "VideoScan Debug build-for-testing …", "BUILD")
                rc, el = r.stream(app_build_cmd(wt), "app-build.log", LANE_BUDGET["build"])
                if rc != 0:
                    lane.ran, lane.rc, lane.seconds = True, rc, el
                    lane.reason = f"build failed (exit {rc}) — see {run_dir}/app-build.log"
                    out.line("FAILED", f"VideoScan Debug build-for-testing {fmt_secs(el)}: exit {rc}", "FAILED")
                else:
                    out.line("BUILD", f"VideoScan Debug build-for-testing {'.' * 8} {fmt_secs(el)}", "BUILD")
                    suites = sorted({s for p in app for s in p.suites})
                    out.line("RUN", f"app {'+'.join(a.stages_label)} ({len(suites)} suites, ~{sum(p.tests for p in app)} tests)")
                    lane.ran, lane.expected = True, sum(p.tests for p in app)
                    lane.rc, lane.seconds = r.stream(app_test_cmd(wt, suites), "app-test.log", LANE_BUDGET["app"],
                                                     parser=LineParser(), lane=lane, gui=True)
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
                out.line("RUN", f"core swift test, Debug ({len(suites)} suites, ~{sum(p.tests for p in core)} tests; builds first)")
                lane.ran, lane.expected = True, sum(p.tests for p in core)
                t_build = time.monotonic()
                seen = {"started": False}

                def mark(raw: str) -> None:
                    if not seen["started"] and ("Test Suite 'All tests' started" in raw or "Test run started" in raw):
                        seen["started"] = True
                        out.line("BUILD", f"VideoScanCore (swift build) {'.' * 8} {fmt_secs(time.monotonic() - t_build)}", "BUILD")
                lane.rc, lane.seconds = r.stream(core_cmd(wt, suites), "core.log", LANE_BUDGET["core"],
                                                 parser=LineParser(), lane=lane, on_line=mark)
                lane_end(out, lane, run_dir / "core.log")
        if "python" in a.kinds and py and "python" in missing:
            lanes.append(setup_lane("python", missing["python"]))
        elif "python" in a.kinds:
            lane = LaneResult("python")
            lanes.append(lane)
            pyfiles = [p.path for p in py if p.kind == "python"]
            interp, why = python_for_tests([base, BASE_REPO])
            if not pyfiles:
                lane.reason = "no Python tests selected"
            elif interp is None:
                lane.reason = why
            else:
                lane.ran, lane.expected = True, sum(p.tests for p in py if p.kind == "python")
                out.line("RUN", f"python pytest via {interp[0]} ({len(pyfiles)} files, "
                                f"~{sum(p.tests for p in py if p.kind == 'python')} tests)")
                lane.rc, lane.seconds = r.stream(pytest_cmd(interp, pyfiles), "python.log", LANE_BUDGET["python"],
                                                 cwd=wt, parser=LineParser(), lane=lane)
                # pytest exit 1 = some test failed (each one counted and named): the counts say it
                if lane.rc == 1 and lane.failed:
                    lane.rc = 0
                lane_end(out, lane, run_dir / "python.log")
            shfiles = [p.path for p in py if p.kind == "shell"]
            if shfiles:
                sl = LaneResult("shell", ran=True, rc=0)
                lanes.append(sl)
                out.line("RUN", f"shell self-tests ({len(shfiles)})")
                for sh in shfiles:
                    rc, el = r.stream(["/bin/bash", sh], "shell.log", 900, cwd=wt)
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
        out.line("FAILED", f"interrupted ({e or 'Ctrl-C'}) — the run is incomplete", "FAILED")
        lanes.append(LaneResult("interrupted", ran=True, rc=130, reason="interrupted"))
    return lanes


def lane_end(out: Out, lane: LaneResult, log: Path) -> None:
    extra = ""
    if lane.rc not in (0, None) and not lane.failed:
        extra = f", exit {lane.rc}" + (" (timed out)" if lane.rc == 124 else "")
    if lane.total == 0:
        extra += " — ZERO tests ran (red)"
    elif lane.shrank:
        lane.reason = lane.reason or f"selection shrank: ran {lane.total} of ~{lane.expected}"
        extra += f" — selection shrank: ran {lane.total} of ~{lane.expected} (red)"
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


def corpus_cmd(script_repo: Path, sha: str, limit: Optional[int]) -> List[str]:
    return (["/bin/bash", str(script_repo / "scripts" / "corpus_run.sh"), "run", "check", "--ref", sha]
            + (["--limit", str(limit)] if limit else []) + ["--wait"])


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


def run_corpus(out: Out, script_repo: Path, sha: str, run_dir: Path, verbose: bool, limit: Optional[int]) -> LaneResult:
    lane = LaneResult("corpus")
    cmd = corpus_cmd(script_repo, sha, limit)
    out.line("RUN", f"corpus check on the M4{f' (--limit {limit})' if limit else ''} — the harness's own summary lines only")
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
    if a.mode == "smoke" and not a.stage_flags:
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

    if target and a.mode == "full":
        print("run_tests: --full runs on this Mac only (app-hosted tests cannot start inside an ssh session). "
              "For the M4: scripts/m4_run.sh suite --host m4 --ref <commit> --wait (the same nightly runner, in "
              "its GUI session); for another Mac: type scripts/run_tests.sh --full on that Mac.", file=sys.stderr)
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
                print(f"+ scripts/corpus_run.sh run check --limit 10 --ref {sha} --wait")
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
            lane = run_corpus(out, SCRIPT_REPO or BASE_REPO, sha, run_dir,
                              a.verbose, 10 if a.mode == "smoke" else None)
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
        print(f"+ worktree {RUN_WT} detached at {sha[:9]} (from {base}); DerivedData {DD}")
        if a.mode == "full":
            for c in full_commands(a, local_key):
                print("+ " + " ".join(shlex.quote(x) for x in c))
            return 0
        app = sorted({s for p in picks if p.kind == "app" for s in p.suites})
        core = sorted({s for p in picks if p.kind == "core" for s in p.suites})
        if app:
            print("+ " + " ".join(shlex.quote(x) for x in app_build_cmd(RUN_WT)))
            print("+ " + " ".join(shlex.quote(x) for x in app_test_cmd(RUN_WT, app)))
        if core:
            print("+ " + " ".join(shlex.quote(x) for x in core_cmd(RUN_WT, core)))
        pyf = [p.path for p in picks if p.kind == "python"]
        if pyf:
            print("+ " + " ".join(shlex.quote(x) for x in pytest_cmd(["<python>"], pyf)))
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
    held: List[int] = []
    try:
        held.append(take_lock(CACHE / "lock", info))
        if local_key == "m4":
            held.append(take_lock(M4_LOCKDIR, info))
    except Busy as e:
        print(f"run_tests: busy — {e} (try again when it is done; nothing queued)", file=sys.stderr)
        return 3
    try:
        prepare_worktree(base, RUN_WT, sha)
    except Refused as e:
        print(f"run_tests: REFUSED — {e}", file=sys.stderr)
        return 1
    (CACHE / "runs").mkdir(exist_ok=True)
    prune_runs(CACHE / "runs", KEEP_RUNS - 1)
    run_dir = CACHE / "runs" / time.strftime(f"%Y%m%d-%H%M%S-{a.mode}")
    run_dir.mkdir(parents=True, exist_ok=True)

    t0 = time.monotonic()
    if a.mode == "full":
        lanes = run_full(a, out, run_dir, local_key, missing)
    else:
        nlanes = len([k for k in ("app", "core", "python") if k in a.kinds])
        header = (f"smoke · {host_label} · {ref_label} {sha[:9]} · {nlanes} lanes, "
                  f"~{sum(p.tests for p in picks)} tests")
        lanes = run_lanes(a, picks, RUN_WT, base, out, run_dir, header, missing)
    if "corpus" in a.kinds and not a.on_host:
        lanes.append(LaneResult("corpus", reason=corpus_why or "runs from the Ultra with --host m4"))
    return summary(out, lanes, time.monotonic() - t0, run_dir)


def full_commands(a, local_key: Optional[str]) -> List[List[str]]:
    wt = RUN_WT
    cmds = []
    if a.kinds & {"app", "core"}:
        cmds.append(["/bin/bash", str(wt / "scripts" / "nightly_local_tests.sh"), "--on-demand", "<run dir>/full",
                     "--repo", str(wt), "--dd", str(DD) + "-full"])
    if "python" in a.kinds:
        cmds.append(["PYTHON=<python with pytest>", "/bin/bash", str(wt / "scripts" / "run_python_tests.sh")])
    return cmds


def run_full(a, out: Out, run_dir: Path, local_key: Optional[str],
             missing: Optional[Dict[str, List[str]]] = None) -> List[LaneResult]:
    """--full: the nightly's own runners, unchanged (one engine). Their logs are parsed for the
    live display; their own verdict (exit code) decides the lane. `missing` as in run_lanes."""
    missing = missing or {}
    swift_missing = list(dict.fromkeys(missing.get("app", []) + missing.get("core", [])))
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + env.get("PATH", "/usr/bin:/bin")
    r = Runner(out, run_dir, env)
    lanes: List[LaneResult] = []
    out.line("==========", f"full · nightly_local_tests.sh --on-demand + run_python_tests.sh")
    try:
        if a.kinds & {"app", "core"} and swift_missing:
            lanes.append(setup_lane("app+core (nightly runner, Release)", swift_missing))
        elif a.kinds & {"app", "core"}:
            lane = LaneResult("app+core (nightly runner, Release)", ran=True)
            lanes.append(lane)
            (run_dir / "full").mkdir(exist_ok=True)
            cmd = ["/bin/bash", str(RUN_WT / "scripts" / "nightly_local_tests.sh"), "--on-demand", str(run_dir / "full"),
                   "--repo", str(RUN_WT), "--dd", str(DD) + "-full"]
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
                lane.rc, lane.seconds = r.stream(["/bin/bash", str(RUN_WT / "scripts" / "run_python_tests.sh")],
                                                 "python-full.log", 3600, cwd=RUN_WT, parser=LineParser(), lane=lane)
                if lane.total == 0 and lane.rc == 0:
                    # run_python_tests.sh uses -q (dots, not names): trust its own summary line
                    txt = (run_dir / "python-full.log").read_text(errors="replace")
                    m = re.findall(r"(\d+) passed", txt)
                    lane.passed = int(m[-1]) if m else 0
                lane_end(out, lane, run_dir / "python-full.log")
    except KeyboardInterrupt as e:
        r.stop()
        out.line("FAILED", f"interrupted ({e or 'Ctrl-C'}) — the run is incomplete", "FAILED")
        lanes.append(LaneResult("interrupted", ran=True, rc=130, reason="interrupted"))
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
    print(f"{a.mode} selection at {ref_label} {sha[:9]} (from scripts/gauntlet/manifest.json)")
    if a.mode == "full":
        print("  --full runs what the nightly runs: nightly_local_tests.sh --on-demand (app + Core, Release),"
              " run_python_tests.sh")
        return 0
    for (kind, mod) in sorted(by):
        ps = by[(kind, mod)]
        print(f"  {kind:6} {mod:28} " + "; ".join(f"{p.stage}: {', '.join(p.suites)} ({p.tests})" for p in ps))
    for kind in ("app", "core", "python"):
        ks = [p for p in picks if (p.kind if p.kind != "shell" else "python") == kind]
        if ks:
            print(f"# {kind}: {len(ks)} files, {len({s for p in ks for s in p.suites})} suites, ~{sum(p.tests for p in ks)} tests")
    print(f"# total ~{sum(p.tests for p in picks)} tests")
    if not a.stage_flags:
        print("# not in the default smoke: performance, stress (add --perf / --stress)")
    print("# not in v1: UI tests (need the GUI session; broken, GH #408) · the hallie stage (the hallie eval's)")
    print("# corpus: only from the Ultra with --host m4 (corpus_run.sh run check --limit 10 --wait)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(1)
