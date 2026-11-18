#!/usr/bin/env python3
"""corpus_coverage.py — which of OUR code the real corpus runs that the test suite never does.

Rick, 2026-11-18: "does test coverage get higher when we're using real-world data?" This is
the measurement, as an opt-in corpus lane: `scripts/corpus_run.sh run coverage [--ref <rev>]`
(through `m4_run.sh corpus`: the testbed lock, the per-run LaunchAgent, the --ref checkout;
M4 only, under the corpus seal of corpus_run.py).

One instrumented Debug build (`-enableCodeCoverage YES`, its own DerivedData
<dd>-coverage, kept like the lanes' cache), then, at ONE commit:
  check · proof · verbs   the corpus lanes exactly as `run <lane>` runs them (corpus_run.Lane /
                          VerbsLane: same drivers, seal, report, baseline diff), each launch with
                          xcodebuild's own coverage collection on;
  suite (app)             the same build's VideoScanTests (the CI plan's list, the corpus
                          drivers skipped), with the plan's own environment — what the 04:00
                          coverage lane (tools/nightly_coverage.py) measures;
  suite (Core)            `swift test --enable-code-coverage` of the Core package (own scratch
                          <dd>-coverage-core), as the 04:00 lane does.
Coverage is collected by xcodebuild into each launch's result bundle (kept in this run's work
folder) and read with xccov, exactly as the 04:00 lane reads the suite: `--archive --json` for
lines, `--report --json` for functions (exact executable lines, readable names). A bare
LLVM_PROFILE_FILE does not work (the test host is ended without its exit handlers), and with
-xctestrun xcodebuild leaves no raw profile on disk — both measured on the M4, 2026-11-18.
Core's own suite: SwiftPM's profiles merged (llvm-profdata) and exported as LCOV (llvm-cov). The lines and functions of OUR sources (VideoScan/VideoScan/, VideoScanCore/Sources/)
are then compared: suite alone, corpus alone, the union, what only the corpus reaches (by area,
by lane, and the functions ranked by size), and what only the suite reaches.

Same build for the app suite and the corpus: their line maps are identical, so a line is a
line. Core's own suite is a second binary of the same sources; its lines are matched by
(file, line). A FUNCTION is (file, first line): Swift's closures and accessors are functions
of their own; accessors that start on one line count once. A function's SIZE is xccov's count
of its executable lines (from Core's LCOV: the lines up to the next function's start); the
lines the corpus ADDS inside a function are counted up to the next function's start.

PRIVACY. Coverage holds counters and the names of OUR functions — nothing of the media. What
this file writes is numbers, area names, our source files' names and our functions'
names. Result bundles, xccov views and LCOV live in ~/corpus/work/<stamp>-coverage/ and go with
it at the end; the report stays under ~/corpus/reports/coverage/<commit>/<stamp>/ on the M4.

Worst-case resources: the instrumented DerivedData (~15 GB) and Core scratch (~3 GB), kept
between runs (one of each; SwiftPM leaves its raw profiles there, a few MB per run). Per run, in the
work folder and removed at the end: four or more result bundles (~0.1-0.5 GB each), their xccov
views (report ~15 MB, archive ~45 MB each; measured 2026-11-18) and Core's LCOV. Memory: one
archive view parsed at a time (~45 MB of JSON, under 1 GB in Python) plus the sets of covered
lines per side (~400k lines x 5 sides, a few hundred MB at most). Wall: build 15-25 min cold, the app suite ~40 min, Core
~15 min, then the three lanes (~10 + ~25 + ~5 min) — about 2 h, inside the corpus lane's
6 h watchdog. Python 3.9 floor (the M4's /usr/bin/python3).
"""
from __future__ import annotations

import bisect
import json
import os
import shutil
import subprocess
import time
from collections import defaultdict
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

import corpus_run as cr

APP_PREFIX = "VideoScan/VideoScan/"
CORE_PREFIX = "VideoScan/VideoScanCore/Sources/VideoScanCore/"
SUBLANES = ("check", "proof", "verbs")
DRIVER_CLASSES = ("CorpusCheckDriver", "CorpusProofDriver", "CorpusVerbsDriver")
SUITE_SIDES = ("suite-app", "suite-core")
LISTED = 15                      # functions per list in the summary (all ranked ones go to coverage.json, capped)
KEPT = 400                       # functions per list in coverage.json
TOOL_TIMEOUT = 1800              # seconds for one xccov view, llvm-profdata merge or llvm-cov export
EXIT_MEASURED, EXIT_NOT_MEASURED = cr.EXIT_GREEN, cr.EXIT_RED


# ── Reading LCOV into lines and functions of our sources ──────────────────

def relative(path: str, roots: Iterable[str]) -> Optional[str]:
    """`path` as a repo-relative name when it is one of OUR Swift sources under a root; else None
    (the test target, the corpus drivers, packages, the SDK)."""
    for root in roots:
        root = root.rstrip("/") + "/"
        if path.startswith(root):
            rel = path[len(root):]
            if rel.endswith(".swift") and rel.startswith((APP_PREFIX, CORE_PREFIX)):
                return rel
    return None


def area_of(rel: str) -> str:
    """The folder a source belongs to: the app's top folder, or Core/<its top folder>."""
    if rel.startswith(CORE_PREFIX):
        rest = rel[len(CORE_PREFIX):]
        return "Core/" + rest.split("/", 1)[0] if "/" in rest else "Core"
    rest = rel[len(APP_PREFIX):]
    return rest.split("/", 1)[0] if "/" in rest else "(app root)"


class Coverage:
    """Executable lines and function starts of our sources (the union over every side read),
    and per side the lines and functions that ran."""

    def __init__(self) -> None:
        self.lines: Dict[str, Set[int]] = defaultdict(set)
        self.starts: Dict[str, Dict[int, Set[str]]] = defaultdict(lambda: defaultdict(set))
        self.hit_lines: Dict[str, Dict[str, Set[int]]] = {}
        self.hit_functions: Dict[str, Set[Tuple[str, int]]] = {}
        self.sizes: Dict[Tuple[str, int], int] = {}      # exact executable lines of a function, when xccov says

    def read_lcov(self, side: str, text: Iterable[str], roots: Iterable[str]) -> int:
        """One LCOV stream (llvm-cov export -format=lcov) into `side`. Returns the number of our
        source files it held. FN lines may be `FN:<start>,<name>` or `FN:<start>,<end>,<name>`."""
        roots = list(roots)
        lines = self.hit_lines.setdefault(side, defaultdict(set))
        functions = self.hit_functions.setdefault(side, set())
        rel: Optional[str] = None
        named: Dict[str, int] = {}
        files = 0
        for raw in text:
            line = raw.rstrip("\n")
            if line.startswith("SF:"):
                rel = relative(line[3:], roots)
                named = {}
                files += rel is not None
            elif rel is None:
                continue
            elif line.startswith("DA:"):
                parts = line[3:].split(",")
                try:
                    number, count = int(parts[0]), int(float(parts[1]))
                except (ValueError, IndexError):
                    continue
                self.lines[rel].add(number)
                if count > 0:
                    lines[rel].add(number)
            elif line.startswith("FN:"):
                parts = line[3:].split(",", 2)
                try:
                    start = int(parts[0])
                except ValueError:
                    continue
                name = parts[2] if len(parts) == 3 and parts[1].isdigit() else ",".join(parts[1:])
                named[name] = start
                self.starts[rel][start].add(name)
            elif line.startswith("FNDA:"):
                count_text, _, name = line[5:].partition(",")
                try:
                    count = int(float(count_text))
                except ValueError:
                    continue
                if count > 0 and name in named:
                    functions.add((rel, named[name]))
            elif line == "end_of_record":
                rel = None
        return files

    def read_xccov(self, side: str, report: dict, archive: dict, roots: Iterable[str]) -> int:
        """One result bundle's coverage into `side`: `archive` is `xccov view --archive --json`
        ({path: [{line, isExecutable, executionCount}]}), `report` is `xccov view --report --json`
        (targets -> files -> functions {name, lineNumber, executionCount, executableLines}).
        Returns the number of our source files the archive held."""
        roots = list(roots)
        lines = self.hit_lines.setdefault(side, defaultdict(set))
        functions = self.hit_functions.setdefault(side, set())
        files = 0
        for path, entries in (archive.items() if isinstance(archive, dict) else ()):
            rel = relative(str(path), roots)
            if rel is None or not isinstance(entries, list):
                continue
            files += 1
            for entry in entries:
                if isinstance(entry, dict) and entry.get("isExecutable") and isinstance(entry.get("line"), int):
                    self.lines[rel].add(entry["line"])
                    if (entry.get("executionCount") or 0) > 0:
                        lines[rel].add(entry["line"])
        for target in (report.get("targets") or []) if isinstance(report, dict) else ():
            for f in target.get("files") or []:
                rel = relative(str(f.get("path", "")), roots)
                if rel is None:
                    continue
                for fn in f.get("functions") or []:
                    start = fn.get("lineNumber")
                    if not isinstance(start, int):
                        continue
                    self.starts[rel][start].add(str(fn.get("name", "?")))
                    size = fn.get("executableLines")
                    if isinstance(size, int):
                        self.sizes[(rel, start)] = max(size, self.sizes.get((rel, start), 0))
                    if (fn.get("executionCount") or 0) > 0:
                        functions.add((rel, start))
        return files

    def side_lines(self, sides: Iterable[str]) -> Dict[str, Set[int]]:
        merged: Dict[str, Set[int]] = defaultdict(set)
        for side in sides:
            for rel, numbers in self.hit_lines.get(side, {}).items():
                merged[rel] |= numbers
        return merged

    def side_functions(self, sides: Iterable[str]) -> Set[Tuple[str, int]]:
        merged: Set[Tuple[str, int]] = set()
        for side in sides:
            merged |= self.hit_functions.get(side, set())
        return merged

    def owners(self, rel: str) -> Dict[int, Set[int]]:
        """Each function start of `rel` -> the executable lines it owns (up to the next start)."""
        starts = sorted(self.starts.get(rel, {}))
        owned: Dict[int, Set[int]] = {s: set() for s in starts}
        for number in self.lines.get(rel, ()):
            i = bisect.bisect_right(starts, number) - 1
            if i >= 0:
                owned[starts[i]].add(number)
        return owned


def pct(part: int, whole: int) -> Optional[float]:
    return round(100.0 * part / whole, 1) if whole else None


def measure(cov: Coverage, suite_sides: Iterable[str], corpus_sides: Iterable[str]) -> dict:
    """The comparison, as numbers and lists (no names demangled yet)."""
    suite_sides, corpus_sides = list(suite_sides), list(corpus_sides)
    suite, corpus = cov.side_lines(suite_sides), cov.side_lines(corpus_sides)
    fsuite, fcorpus = cov.side_functions(suite_sides), cov.side_functions(corpus_sides)
    areas: Dict[str, Dict[str, int]] = defaultdict(lambda: defaultdict(int))
    total: Dict[str, int] = defaultdict(int)
    only_corpus_files: Dict[str, int] = {}
    for rel, executable in cov.lines.items():
        s, c = suite.get(rel, set()) & executable, corpus.get(rel, set()) & executable
        row = areas[area_of(rel)]
        for bucket in (row, total):
            bucket["lines"] += len(executable)
            bucket["suite"] += len(s)
            bucket["corpus"] += len(c)
            bucket["union"] += len(s | c)
            bucket["corpus_only"] += len(c - s)
            bucket["suite_only"] += len(s - c)
        if c - s:
            only_corpus_files[rel] = len(c - s)
    functions = [(rel, start) for rel, starts in cov.starts.items() for start in starts]
    for rel, start in functions:
        row = areas[area_of(rel)]
        hit_s, hit_c = (rel, start) in fsuite, (rel, start) in fcorpus
        for bucket in (row, total):
            bucket["functions"] += 1
            bucket["f_suite"] += hit_s
            bucket["f_corpus"] += hit_c
            bucket["f_union"] += hit_s or hit_c
            bucket["f_corpus_only"] += hit_c and not hit_s
    unreached, further = [], []          # functions the suite never enters · functions the corpus takes further
    for rel in {r for r, _ in fcorpus}:
        owned = cov.owners(rel)
        new = corpus.get(rel, set()) - suite.get(rel, set())
        for start, body in owned.items():
            if (rel, start) not in fcorpus:
                continue
            lanes = [side for side in corpus_sides if (rel, start) in cov.hit_functions.get(side, set())]
            entry = {"file": rel, "area": area_of(rel), "start": start, "size": cov.sizes.get((rel, start), len(body)),
                     "new_lines": len(body & new), "lanes": lanes, "names": sorted(cov.starts[rel][start])}
            if (rel, start) not in fsuite:
                unreached.append(entry)
            elif entry["new_lines"]:
                further.append(entry)
    unreached.sort(key=lambda e: (-e["size"], e["file"], e["start"]))
    further.sort(key=lambda e: (-e["new_lines"], e["file"], e["start"]))
    lanes = {}
    for side in corpus_sides:
        lines = cov.side_lines([side])
        covered = sum(len(lines.get(rel, set()) & ex) for rel, ex in cov.lines.items())
        adds = sum(len((lines.get(rel, set()) - suite.get(rel, set())) & ex) for rel, ex in cov.lines.items())
        fs = cov.side_functions([side])
        lanes[side] = {"lines": covered, "corpus_only": adds, "functions": len(fs), "f_corpus_only": len(fs - fsuite)}

    def finish(bucket: Dict[str, int]) -> dict:
        out = dict(bucket)
        for key in ("suite", "corpus", "union"):
            out[key + "_pct"] = pct(bucket[key], bucket["lines"])
            out["f_" + key + "_pct"] = pct(bucket["f_" + key], bucket["functions"])
        return out

    return {"total": finish(total), "areas": {k: finish(v) for k, v in sorted(areas.items())}, "lanes": lanes,
            "unreached": unreached, "further": further,
            "files_corpus_only": sorted(only_corpus_files.items(), key=lambda kv: (-kv[1], kv[0]))}


# ── Names: our functions, demangled ───────────────────────────────────────

def demangle(names: List[str], xcrun: str = "xcrun") -> Dict[str, str]:
    """Mangled -> readable (swift-demangle --simplified). A private function's profile name
    carries its file in front (`File.swift:$s…` / `…;$s…`); that part is dropped. When the tool
    fails, the mangled name stands. Names that are not mangled (xccov's) are kept as they are."""
    names = [n for n in names if "$s" in n]
    if not names:
        return {}
    bare = [n[n.find("$s"):] for n in names]
    try:
        done = subprocess.run([xcrun, "swift-demangle", "--simplified", "--compact"], input="\n".join(bare) + "\n",
                              capture_output=True, text=True, timeout=300)
        out = done.stdout.splitlines()
    except (OSError, subprocess.SubprocessError):
        out = []
    if len(out) != len(names):
        out = bare
    return {name: text.strip()[:160] for name, text in zip(names, out)}


def label(entry: dict, names: Dict[str, str]) -> str:
    shown = sorted({names.get(n, n) for n in entry["names"]}, key=lambda t: (len(t), t))
    return shown[0] if shown else "?"


# ── The report ────────────────────────────────────────────────────────────

def _p(value: Optional[float]) -> str:
    return "-" if value is None else f"{value:.1f}%"


def render(result: dict, names: Dict[str, str], sha: str, lane_lines: List[str], suite_note: str) -> List[str]:
    t = result["total"]
    lines = [f"corpus coverage: MEASURED at {sha[:9]} — our code, {t['lines']} executable lines, {t['functions']} functions",
             f"  suite (app + Core tests)  lines {_p(t['suite_pct'])}  functions {_p(t['f_suite_pct'])}   {suite_note}",
             f"  corpus (check+proof+verbs) lines {_p(t['corpus_pct'])}  functions {_p(t['f_corpus_pct'])}",
             f"  union                     lines {_p(t['union_pct'])}  functions {_p(t['f_union_pct'])}"
             f"   (+{t['corpus_only']} lines, +{t['f_corpus_only']} functions only the corpus runs)",
             f"  the suite alone runs {t['suite_only']} lines the corpus never reaches"]
    lines.append("  by lane: " + " · ".join(
        f"{side} {v['lines']} lines (+{v['corpus_only']} not in the suite, {v['f_corpus_only']} functions)"
        for side, v in result["lanes"].items()))
    adding = sorted(((a, v) for a, v in result["areas"].items() if v["corpus_only"]), key=lambda kv: -kv[1]["corpus_only"])
    if adding:
        lines.append("  areas the corpus adds to (lines; suite -> union):")
        for area, v in adding[:12]:
            lines.append(f"    {area:<18} +{v['corpus_only']:<5} {_p(v['suite_pct'])} -> {_p(v['union_pct'])}"
                         f"  (+{v['f_corpus_only']} functions)")
    if result["unreached"]:
        lines.append(f"  functions the corpus runs and the suite never enters ({len(result['unreached'])}; by size):")
        for i, e in enumerate(result["unreached"][:LISTED], 1):
            lines.append(f"    {i:>2}. {label(e, names)}  [{e['area']} {Path(e['file']).name}:{e['start']}; "
                         f"{e['size']} lines; {'+'.join(e['lanes'])}]")
    if result["further"]:
        lines.append(f"  functions both enter where the corpus reaches lines the suite does not ({len(result['further'])}; by lines):")
        for i, e in enumerate(result["further"][:LISTED], 1):
            lines.append(f"    {i:>2}. {label(e, names)}  [{e['area']} {Path(e['file']).name}:{e['start']}; "
                         f"+{e['new_lines']} of {e['size']} lines; {'+'.join(e['lanes'])}]")
    return lines + ["  lanes (their own verdicts, against their own baselines):"] + ["    " + x for x in lane_lines]


# ── The run (on the M4, inside the corpus seal) ───────────────────────────

class CoverageRun:
    """`host coverage`: the three corpus lanes on an instrumented build, the suite on the same
    build, Core's suite, then the comparison. A lane's own verdict is its own (stored and
    judged as `run <lane>` does); this run's word is whether coverage was MEASURED."""

    def __init__(self, seal: cr.Seal, sha: str, stamp: str, out: Path, worktree: Path, derived_data: Path,
                 bin_dir: Path, deadline: Optional[int] = None, limit: Optional[int] = None,
                 xcodebuild: str = "xcodebuild", cp: str = "/bin/cp", xcrun: str = "xcrun", swift: str = "swift"):
        self.seal, self.sha, self.stamp = seal, sha, stamp
        self.out, self.worktree, self.bin_dir = Path(out), Path(worktree), Path(bin_dir)
        self.dd = Path(str(derived_data) + "-coverage")
        self.core_scratch = Path(str(derived_data) + "-coverage-core")
        self.deadline, self.limit = deadline, limit
        self.xcodebuild, self.cp, self.xcrun, self.swift = xcodebuild, cp, xcrun, swift
        self.work = seal.work_root / f"{stamp}-coverage"
        self.report_dir = seal.reports / "coverage" / sha / stamp
        self.lines: List[str] = []
        self.lane_lines: List[str] = []
        self.problems: List[str] = []
        self.suite_note = ""
        self.cov = Coverage()
        self.read: Dict[str, int] = {}
        self.roots = sorted({str(self.worktree), os.path.realpath(str(self.worktree))})

    def tool(self, command: List[str], log_name: str, stdout_to: Optional[Path] = None) -> int:
        """One tool, its output into this run's log in <out> (or `stdout_to`), bounded."""
        with os.fdopen(self.seal.out_open(self.out, log_name, append=True), "ab") as log:
            log.write(("\n$ " + " ".join(str(c) for c in command[:4]) + " …\n").encode())
            log.flush()
            try:
                if stdout_to is not None:
                    with os.fdopen(cr.guarded_open(self.seal.writable(stdout_to)), "wb") as sink:
                        return subprocess.call(command, stdin=subprocess.DEVNULL, stdout=sink, stderr=log,
                                               timeout=TOOL_TIMEOUT)
                return subprocess.call(command, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                       timeout=TOOL_TIMEOUT)
            except subprocess.TimeoutExpired:
                return 124

    def read_bundles(self, side: str) -> int:
        """Every result bundle of `side` (raw/<side>/result-N.xcresult; a lane relaunched after a
        crash has several) read with xccov into the coverage, as the 04:00 lane reads its own.
        Returns our source files read; a problem is said when there is none."""
        bundles = sorted((self.work / "raw" / side).glob("*.xcresult"))
        if not bundles:
            self.problems.append(f"{side}: no result bundle was written")
            return 0
        files = 0
        for n, bundle in enumerate(bundles, 1):
            views = {}
            for view in ("report", "archive"):
                dest = self.work / f"{side}-{n}.{view}.json"
                if self.tool([self.xcrun, "xccov", "view", f"--{view}", "--json", str(bundle)], "coverage-tools.log",
                             stdout_to=dest) != 0:
                    self.problems.append(f"{side}: xccov could not read a result bundle ({view})")
                    break
                try:
                    with open(str(dest), encoding="utf-8") as f:
                        views[view] = json.load(f)
                except (OSError, ValueError):
                    self.problems.append(f"{side}: xccov's {view} was not JSON")
                    break
            else:
                files = max(files, self.cov.read_xccov(side, views["report"], views["archive"], self.roots))
        if not files:
            self.problems.append(f"{side}: its result bundles hold no coverage of our sources")
        self.read[side] = files
        return files

    def read_lcov_side(self, side: str, profiles: List[Path], binaries: List[Path]) -> int:
        """Core's own suite: SwiftPM's raw profiles merged and exported as LCOV over its test binary."""
        if not profiles or not binaries:
            self.problems.append(f"{side}: " + ("no profile was written" if not profiles else "no test binary was found"))
            return 0
        merged, lcov = self.work / f"{side}.profdata", self.work / f"{side}.lcov"
        if self.tool([self.xcrun, "llvm-profdata", "merge", "-sparse", *map(str, profiles), "-o",
                      str(self.seal.writable(merged))], "coverage-tools.log") != 0:
            self.problems.append(f"{side}: llvm-profdata could not merge its profiles")
            return 0
        if self.tool([self.xcrun, "llvm-cov", "export", "-format=lcov", f"-instr-profile={merged}", str(binaries[0])],
                     "coverage-tools.log", stdout_to=lcov) != 0:
            self.problems.append(f"{side}: llvm-cov could not export")
            return 0
        with open(str(lcov), encoding="utf-8", errors="replace") as stream:
            self.read[side] = self.cov.read_lcov(side, stream, self.roots)
        return self.read[side]

    def run_lanes(self) -> bool:
        """The three lanes, each read as soon as it ends. False, at once, when a lane ran and its
        bundles hold no coverage of our sources: the next ~90 min would measure nothing."""
        for name in SUBLANES:
            out = self.out / f"corpus-{name}"
            if not out.is_dir():
                os.mkdir(str(out))
            kind = cr.VerbsLane if name == "verbs" else cr.Lane
            extra = {"cp": self.cp} if name == "verbs" else {}
            lane = kind(self.seal, name, self.sha, self.stamp, out, self.worktree, self.dd, self.bin_dir,
                        self.deadline, self.limit, self.xcodebuild, **extra)
            lane.profiles = self.seal.mkdir(self.work / "raw" / name)
            try:
                lane.go()
                self.lane_lines += lane.lines[:2] or [f"corpus {name}: wrote no summary"]
            except cr.Refused as refusal:
                self.lane_lines.append(f"corpus {name}: RED {refusal}")
            if lane.launches and not self.read_bundles(name):
                self.problems.append(f"{name}: no coverage from its test host — stopped before the rest")
                return False
        return True

    def run_suite(self) -> None:
        """The plan's VideoScanTests on the same instrumented build, the drivers skipped."""
        try:
            products = self.dd / "Build" / "Products"
            plans = sorted(products.glob("*VideoScan-CI*.xctestrun"))
            xctestrun = plans[0] if plans else cr.find_xctestrun(self.dd)
        except (cr.Refused, OSError):
            self.problems.append("suite-app: the instrumented build left no test-run file")
            return
        raw = self.seal.mkdir(self.work / "raw" / "suite-app")
        rc = cr._run([self.xcodebuild, "test-without-building", "-xctestrun", str(xctestrun),
                      "-destination", "platform=macOS,arch=arm64", "-only-testing:VideoScanTests",
                      *[f"-skip-testing:VideoScanTests/{c}" for c in DRIVER_CLASSES],
                      "-enableCodeCoverage", "YES", "-resultBundlePath", str(self.seal.writable(raw / "result-1.xcresult"))],
                     self.seal, self.out, "coverage-suite.log", dict(os.environ), self.worktree)
        self.suite_note = "app tests " + ("passed" if rc == 0 else f"exit {rc} (some failed; coverage still read)")

    def run_core(self) -> Optional[Tuple[List[Path], List[Path]]]:
        since = time.time() - 2
        rc = cr._run([self.swift, "test", "--package-path", str(self.worktree / "VideoScan" / "VideoScanCore"),
                      "--enable-code-coverage", "--scratch-path", str(self.core_scratch)],
                     self.seal, self.out, "coverage-core.log", dict(os.environ), self.worktree)
        self.suite_note += "; Core tests " + ("passed" if rc == 0 else f"exit {rc}")
        debug = self.core_scratch / "debug"

        def fresh(path: Path) -> bool:
            try:
                return path.stat().st_mtime >= since
            except OSError:
                return False
        profiles = [p for p in sorted((debug / "codecov").glob("*.profraw")) if fresh(p)]    # today's, not a leftover
        binaries = sorted(debug.glob("*.xctest/Contents/MacOS/*"))
        return profiles, binaries[:1]

    def go(self) -> int:
        seal = self.seal.check()
        seal.out_folder(self.out)
        seal.mkdir(seal.work_root)
        try:
            os.mkdir(str(seal.writable(self.work)))
        except FileExistsError:
            raise cr.Refused("refused: a work folder with this run's name is already there — it is not this run's")
        t0 = time.time()
        try:
            if self.run_lanes():
                self.run_suite()
                self.read_bundles("suite-app")
                for side in SUBLANES[1:]:
                    if side not in self.read:
                        self.problems.append(f"{side}: the lane did not run")
                self.read_lcov_side("suite-core", *self.run_core())
            cov, read = self.cov, self.read
            missing = [s for s in ("suite-app",) + SUBLANES if not read.get(s)]
            if missing or not cov.lines:
                self.lines = [f"corpus coverage: RED not measured at {self.sha[:9]} — no coverage for "
                              + (", ".join(missing) or "our sources")] + ["  " + p for p in self.problems] \
                    + ["  lanes:"] + ["    " + x for x in self.lane_lines]
                seal.out_write(self.out, "corpus-summary.txt", "\n".join(self.lines) + "\n")
                return EXIT_NOT_MEASURED
            if not read.get("suite-core"):
                self.suite_note += " — Core's own suite NOT counted (" + "; ".join(
                    p for p in self.problems if p.startswith("suite-core")) + ")"
            corpus_sides = [s for s in SUBLANES if read.get(s)]
            result = measure(cov, [s for s in SUITE_SIDES if read.get(s)], corpus_sides)
            shown = {n for key in ("unreached", "further") for e in result[key][:KEPT] for n in e["names"]}
            names = demangle(sorted(shown), self.xcrun)
            self.lines = render(result, names, self.sha, self.lane_lines, self.suite_note)
            self.lines.append(f"  wall {time.time() - t0:.0f}s; files read per side: "
                              + ", ".join(f"{k} {v}" for k, v in sorted(read.items())))
            for key in ("unreached", "further"):
                result[key] = [dict(e, name=label(e, names)) for e in result[key][:KEPT]]
            result.update(sha=self.sha, stamp=self.stamp, suite_note=self.suite_note, problems=self.problems,
                          files_read=read, wall_s=round(time.time() - t0, 1))
            result["files_corpus_only"] = result["files_corpus_only"][:KEPT]
            seal.mkdir(self.report_dir)
            seal.write_json(self.report_dir / "coverage.json", result)
            seal.write_text(self.report_dir / "coverage.txt", "\n".join(self.lines) + "\n")
            seal.out_write(self.out, "corpus-summary.txt", "\n".join(self.lines) + "\n")
            return EXIT_MEASURED
        finally:
            self.remove_work()

    def remove_work(self) -> None:
        """The result bundles, xccov views and Core's LCOV go with this run's work folder (the M4's own test scratch,
        DECISIONS 2026-11-18)."""
        work = str(self.seal.writable(self.work))
        if os.path.isdir(work):
            shutil.rmtree(work, ignore_errors=True)
        if os.path.isdir(work):
            self.lines.append("  the run's work folder could NOT be removed whole (it is still on the M4 under ~/corpus/work)")
