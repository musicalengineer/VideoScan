"""corpus_ui_lane.py — the corpus UI lane, host side (`scripts/corpus_run.sh run ui`).

The REAL app, driven by XCUITest on the M4, showing the real-data corpus's sealed
catalog read-only: VideoScan/VideoScanUITests/Gauntlet/CorpusUITests.swift drives it,
VideoScan/VideoScan/Shared/GauntletCorpusCatalog.swift is the in-app seal. It runs
through `scripts/m4_run.sh corpus --corpus-lane ui` like every corpus lane: the testbed
lock, the per-run LaunchAgent in the M4's GUI session (XCUITest needs the window server
and an unlocked console), the --ref checkout. corpus_run.py's `main` hands the lane here
with itself as `h` (one Seal, one Refused, one media sweep — no second copy).

  1. the seal (`h.Seal.check`) and the sealed catalog verified (`h.sealed_state_ready`);
  2. NORUN when a VideoScan app is already running on the M4: XCUIApplication.launch()
     terminates a running copy of the app it launches, and this lane never stops a
     process it did not start;
  3. before: the live App Support catalog files (size, mtime), the sealed state's catalog
     files, every corpus media file (`h.media_sweep`);
  4. a Debug build-for-testing of the commit into the testbed's DerivedData;
  5. the VideoScan-CorpusUI plan's .xctestrun, patched with the run's paths and every
     attachment lifetime `keepNever`; `xcodebuild test-without-building
     -collect-test-diagnostics never`, its output and result bundle INSIDE the run's
     work folder; the app's HOME and TMPDIR are folders in it too;
  6. after: the same sweeps (any difference is RED), crash reports VideoScan wrote since
     the start (counted), error and fault entries the VideoScan process wrote to the
     unified log (counted by subsystem:category — never their text);
  7. the summary, counts and words only; then the work folder goes whole — the app's
     caches about family media, the raw test output, the result bundle.

Verdict: GREEN every case passed and nothing moved · RED a case failed, no case ran, a
sweep changed, a crash report, or the seam refused · NORUN the ref has no corpus UI plan,
a VideoScan app was running, or the machine could not start UI automation (automation
mode / Accessibility — a person at the M4 once; docs/guides/operations.md §1).

PRIVACY. The corpus is real family media. Nothing here looks at pixels: the plan keeps no
screenshot or attachment, the test asserts through accessibility values only. The raw
xcodebuild output can name an element it clicked, so it stays in the work folder and is
removed; what reaches <out> is the case names and outcomes, `[corpus-ui]` lines that pass
`UI_LINE` (words and numbers only), failure lines with the message withheld unless it
passes `safe_text`, and counts.

Monkey: the seed comes from the commit (`seed_for`), so a finding replays with the same
--ref; `--limit N` sets its step count (default MONKEY_STEPS).

Memory: one test run's output, read line by line; the sweeps are a few hundred tuples.
Disk: the app's HOME under the run's work folder (its thumbnail and preview caches of the
corpus; bounded by the corpus, 234 files) and one result bundle; removed at the end.
"""
from __future__ import annotations

import glob
import json
import os
import plistlib
import re
import shutil
import subprocess
import time
from collections import Counter
from pathlib import Path
from typing import Dict, List, Optional, Tuple

LANE = "ui"
PLAN = "VideoScan-CorpusUI"
TEST_CLASS = "CorpusUITests"
MONKEY_STEPS = 120
TEST_ALLOWANCE = 900                 # seconds per case (xcodebuild's own test timeout)
APP_SUFFIX = "/VideoScan.app/Contents/MacOS/VideoScan"
LIVE_DIR = "Library/Application Support/VideoScan"
STATUS_FILE = "corpus-ui-seam.txt"   # GauntletCorpusCatalog.statusFileName
UI_LINE = re.compile(r"\[corpus-ui\] [A-Za-z0-9_]{1,80} [a-z_]{1,40}( [A-Za-z0-9_]{1,80})?( [a-z_]{1,20}=-?\d{1,12})*")
SEAM_LINE = re.compile(r"(refused [a-z_]{1,60}|loaded records=\d{1,9} volumes=\d{1,6})")
CASE_LINE = re.compile(r"Test Case '-\[VideoScanUITests\.CorpusUITests (test[A-Za-z0-9_]+)\]' (passed|failed|skipped)")
FAIL_LINE = re.compile(r"CorpusUITests\.swift:(\d+): error: -\[VideoScanUITests\.CorpusUITests (test[A-Za-z0-9_]+)\] : (.*)")
MACHINE_WORDS = ("Timed out while enabling automation mode", "not authorized for accessibility",
                 "Failed to initialize for UI testing", "Automation Mode")


def seed_for(sha: str) -> int:
    """The monkey's seed: the commit's first 8 hex digits — the same --ref replays it."""
    return int(sha[:8], 16)


def safe_text(text: str) -> bool:
    """A failure message may reach <out> only if it cannot carry a name: no slash, nothing
    shaped like a file name, no quotes around anything but a number, short."""
    bare = re.sub(r'"-?[0-9,]*"', "", text)            # XCTAssertEqual's quoted numbers ("12") are fine
    return (len(text) <= 240 and "/" not in text and not re.search(r"\.[A-Za-z0-9]{2,5}\b", text)
            and not re.search(r"[\"“”‘’]", bare))


def running_videoscan(ps_output: str) -> int:
    """How many VideoScan app processes are running (any build, anywhere)."""
    return sum(1 for row in ps_output.splitlines() if row.strip().endswith(APP_SUFFIX))


def stat_files(paths: List[Path]) -> Dict[str, Tuple[int, int]]:
    seen = {}
    for p in paths:
        try:
            st = os.lstat(str(p))
            seen[p.name if p.parent.name != "viewer-catalog" else "viewer-catalog/" + p.name] = (st.st_size, st.st_mtime_ns)
        except OSError:
            seen[p.name] = (-1, -1)
    return seen


def live_catalog_files(home: Path) -> List[Path]:
    """The live catalog's files: App Support/VideoScan/catalog* and viewer-catalog/*."""
    live = home / LIVE_DIR
    found = [p for p in live.glob("catalog*") if p.is_file() and not p.is_symlink()] if live.is_dir() else []
    viewer = live / "viewer-catalog"
    found += [p for p in viewer.iterdir() if p.is_file() and not p.is_symlink()] if viewer.is_dir() else []
    return sorted(found)


def changed(before: Dict, after: Dict) -> List[str]:
    return sorted(k for k in set(before) | set(after) if before.get(k) != after.get(k))


def find_plan_xctestrun(derived_data: Path) -> Optional[Path]:
    products = derived_data / "Build" / "Products"
    found = sorted((p for p in products.glob(f"*{PLAN}*.xctestrun") if not p.name.startswith("corpus-")),
                   key=lambda p: p.stat().st_mtime, reverse=True)
    return found[0] if found else None


def patch_ui_xctestrun(source: Path, dest: Path, environment: Dict[str, str]) -> None:
    """Every test target: the run's environment, and no attachment of any kind kept."""
    def patch(value):
        if isinstance(value, list):
            return [patch(v) for v in value]
        if isinstance(value, dict):
            out = {k: patch(v) for k, v in value.items()}
            if "TestBundlePath" in out:
                for key in ("EnvironmentVariables", "TestingEnvironmentVariables"):
                    env = dict(out.get(key) or {})
                    env.update(environment)
                    out[key] = env
                out["SystemAttachmentLifetime"] = "keepNever"
                out["UserAttachmentLifetime"] = "keepNever"
                out["PreferredScreenCaptureFormat"] = "screenshots"
            return out
        return value
    with open(source, "rb") as f:
        plist = plistlib.load(f)
    fd = os.open(str(dest), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    with os.fdopen(fd, "wb") as f:
        plistlib.dump(patch(plist), f)


def read_results(log: Path) -> dict:
    """The run's facts from the raw output, without keeping its text: cases and outcomes,
    the `[corpus-ui]` lines that pass UI_LINE, failures (message withheld unless safe),
    and whether the machine refused UI automation."""
    cases: Dict[str, str] = {}
    lines: List[str] = []
    failures: List[str] = []
    machine = False
    try:
        with open(log, "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                raw = raw.rstrip("\n")
                m = CASE_LINE.search(raw)
                if m:
                    cases[m.group(1)] = m.group(2)
                    continue
                i = raw.find("[corpus-ui] ")
                if i >= 0:
                    line = raw[i:].strip()
                    if UI_LINE.fullmatch(line):
                        lines.append(line)
                    continue
                m = FAIL_LINE.search(raw)
                if m:
                    message = m.group(3).strip()
                    failures.append(f"{m.group(2)} line {m.group(1)}: " + (message if safe_text(message) else "(message withheld)"))
                    continue
                if any(w.lower() in raw.lower() for w in MACHINE_WORDS):
                    machine = True
    except OSError:
        pass
    return {"cases": cases, "lines": lines, "failures": failures, "machine": machine}


def unified_log_errors(since: str) -> Counter:
    """Error and fault entries the VideoScan process wrote since `since`, counted by
    subsystem:category. The messages are parsed in memory and dropped."""
    counts: Counter = Counter()
    try:
        out = subprocess.run(["/usr/bin/log", "show", "--style", "ndjson", "--start", since, "--predicate",
                              'process == "VideoScan" AND (messageType == error OR messageType == fault)'],
                             capture_output=True, text=True, timeout=300).stdout
    except (OSError, subprocess.SubprocessError):
        counts["log_show_failed"] += 1
        return counts
    for row in out.splitlines():
        try:
            entry = json.loads(row)
        except ValueError:
            continue
        if not isinstance(entry, dict) or "messageType" not in entry:
            continue
        key = f"{entry.get('subsystem') or 'none'}:{entry.get('category') or 'none'}:{entry.get('messageType')}"
        counts[key] += 1
    return counts


def crash_reports_since(home: Path, t0: float) -> int:
    return sum(1 for p in glob.glob(str(home / "Library/Logs/DiagnosticReports" / "VideoScan*"))
               if os.path.getmtime(p) >= t0)


class UILane:
    """The lane on the host. `h` is the corpus_run module (its Seal, Refused, sweeps, words);
    `xcodebuild`, `ps` and `log_errors` are seams for the tests."""

    def __init__(self, h, seal, sha: str, stamp: str, out: Path, worktree: Path, derived_data: Path,
                 limit: Optional[int] = None, xcodebuild: str = "xcodebuild", ps=None, log_errors=None):
        self.h, self.seal, self.sha, self.stamp = h, seal, sha, stamp
        self.out, self.worktree, self.derived_data = Path(out), Path(worktree), Path(derived_data)
        self.steps = int(limit or MONKEY_STEPS)
        self.xcodebuild = xcodebuild
        self.ps = ps or (lambda: subprocess.run(["ps", "-axo", "command="], capture_output=True, text=True).stdout)
        self.log_errors = log_errors or unified_log_errors
        self.work = seal.work_root / f"{stamp}-{LANE}"
        self.lines: List[str] = []

    def say(self, verdict: str, body: List[str], code: int) -> int:
        head = f"corpus ui: {verdict} at {self.sha[:9]}"
        self.lines = [head + (" — " + body[0] if body else "")] + ["  " + b for b in body[1:]]
        self.seal.out_write(self.out, "corpus-summary.txt", "\n".join(self.lines) + "\n")
        return code

    def sweeps(self, entries) -> dict:
        h, seal = self.h, self.seal
        return {"live": stat_files(live_catalog_files(seal.home)),
                "state": stat_files([seal.state / "catalog.sqlite", seal.state / "catalog.cutover"]),
                "media": h.media_sweep(seal, entries)}

    def go(self) -> int:
        h, seal = self.h, self.seal.check()
        t_start = time.time()
        entries = h.load_manifest(seal)
        database = h.sealed_state_ready(seal, entries)
        seal.out_folder(self.out)
        if not (self.worktree / "VideoScan" / f"{PLAN}.xctestplan").is_file():
            return self.say("NORUN", ["this ref has no corpus UI plan (VideoScan-CorpusUI.xctestplan)"], h.EXIT_NORUN)
        if running_videoscan(self.ps()):
            return self.say("NORUN", ["a VideoScan app is running on the M4 — XCUITest would stop it, and this lane never "
                                      "stops a process it did not start; quit it and run again"], h.EXIT_NORUN)
        seal.mkdir(seal.work_root)
        try:
            os.mkdir(str(seal.writable(self.work)))
        except FileExistsError:
            raise h.Refused("refused: a work folder with this run's name is already there — it is not this run's")
        try:
            return self.run(entries, database, t_start)
        finally:
            self.remove_work()

    def run(self, entries, database: Path, t_start: float) -> int:
        h, seal = self.h, self.seal
        home, tmp = self.work / "home", self.work / "tmp"
        for folder in (home / "Library" / "Preferences", tmp):
            seal.mkdir(folder)
        before = self.sweeps(entries)
        since = time.strftime("%Y-%m-%d %H:%M:%S")
        t0 = time.time()
        build_rc = h._run([self.xcodebuild, "build-for-testing", "-project", str(self.worktree / "VideoScan/VideoScan.xcodeproj"),
                           "-scheme", "VideoScan", "-configuration", "Debug", "-destination", "platform=macOS",
                           "-derivedDataPath", str(self.derived_data), "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual"],
                          seal, self.out, "corpus-build.log", dict(os.environ), self.worktree)
        build_s = time.time() - t0
        if build_rc != 0:
            return self.say("RED", [f"the app did not build (corpus-build.log on the M4); build {build_s:.0f}s"], h.EXIT_RED)
        xctestrun = find_plan_xctestrun(self.derived_data)
        if xctestrun is None:
            return self.say("RED", ["the build produced no VideoScan-CorpusUI .xctestrun"], h.EXIT_RED)
        patched = xctestrun.with_name(f"corpus-{self.stamp}-ui.xctestrun")     # beside it: __TESTROOT__ is relative
        if os.path.lexists(str(patched)) or seal.pristine(patched) or h._under(patched, seal.corpus):
            raise h.Refused("refused: the patched test-run file would land somewhere it must not")
        seed = seed_for(self.sha)
        patch_ui_xctestrun(xctestrun, patched, {
            "VS_GAUNTLET": "1", "VS_UI_CORPUS": "1", "VS_UI_CORPUS_CATALOG": str(database),
            "VS_UI_CORPUS_HOME": str(home), "VS_UI_CORPUS_TMP": str(tmp) + "/",
            "VS_UI_CORPUS_SEED": str(seed), "VS_UI_CORPUS_STEPS": str(self.steps)})
        raw_log = self.work / "ui-test.log"
        seal.write_text(raw_log, "")
        t1 = time.time()
        try:
            with os.fdopen(h.guarded_open(seal.writable(raw_log), append=True), "ab") as f:
                test_rc = subprocess.call(
                    [self.xcodebuild, "test-without-building", "-xctestrun", str(patched), "-destination", "platform=macOS",
                     "-only-testing:VideoScanUITests/" + TEST_CLASS, "-collect-test-diagnostics", "never",
                     "-test-timeouts-enabled", "YES", "-default-test-execution-time-allowance", str(TEST_ALLOWANCE),
                     "-resultBundlePath", str(self.work / "ui.xcresult")],
                    cwd=str(self.worktree), stdin=subprocess.DEVNULL, stdout=f, stderr=subprocess.STDOUT,
                    pass_fds=self._lock_fd())
        finally:
            if patched.exists():
                shutil.move(str(patched), str(seal.writable(self.work / patched.name)))
        test_s = time.time() - t1
        results = read_results(raw_log)
        seam = self.seam_status(home)
        after = self.sweeps(entries)
        moved = {k: changed(before[k], after[k]) for k in ("live", "state")}
        media_moved = sum(1 for k in before["media"] if after["media"].get(k) != before["media"][k])
        crashes = crash_reports_since(seal.home, t_start)
        errors = self.log_errors(since)
        return self.verdict(results, seam, moved, media_moved, len(before["media"]) - 1, len(before["live"]),
                            crashes, errors, test_rc, build_s, test_s, seed)

    def verdict(self, results, seam, moved, media_moved, media_files, live_files, crashes, errors,
                test_rc, build_s, test_s, seed) -> int:
        h = self.h
        cases = results["cases"]
        passed = sum(1 for v in cases.values() if v == "passed")
        failed = sum(1 for v in cases.values() if v == "failed")
        skipped = sum(1 for v in cases.values() if v == "skipped")
        isolation_ok = not moved["live"] and not moved["state"] and media_moved == 0
        body = [f"{len(cases)} cases: {passed} passed, {failed} failed, {skipped} skipped "
                f"(build {build_s:.0f}s, tests {test_s:.0f}s, xcodebuild rc={test_rc})"]
        body.append("seam: " + (" · ".join(seam) if seam else "no status line (the app never reached the seam)"))
        body.append(f"isolation: live App Support catalog files {live_files} "
                    + ("unchanged" if not moved["live"] else "CHANGED: " + ", ".join(h.word(n.replace('/', '_').replace('.', '_')) for n in moved["live"]))
                    + " · sealed catalog " + ("unchanged" if not moved["state"] else "CHANGED")
                    + f" · corpus media {media_files} " + ("unchanged" if media_moved == 0 else f"CHANGED {media_moved}"))
        body.append(f"crash reports from VideoScan since the start: {crashes}")
        body.append("unified-log errors/faults from VideoScan: " + (", ".join(f"{h.word(k.replace('.', '_').replace(' ', '_'))} x{n}"
                                                                             for k, n in errors.most_common(12))
                                                                   if errors else "0"))
        body.append(f"monkey: seed {seed}, {self.steps} steps (replay: the same --ref, --limit <step+1>)")
        body += self.digest(results["lines"])
        body += ["failure: " + f for f in results["failures"][:20]]
        if results["machine"] and not cases:
            return self.say("NORUN", ["UI automation could not start on the M4 (automation mode / Accessibility; "
                                      "a person at the M4 once — docs/guides/operations.md §1)"] + body, h.EXIT_NORUN)
        red = (not cases or failed or skipped or passed == 0 or not isolation_ok or crashes
               or any(s.startswith("refused") for s in seam))
        return self.say("RED" if red else "GREEN", body, h.EXIT_RED if red else h.EXIT_GREEN)

    @staticmethod
    def digest(lines: List[str]) -> List[str]:
        """The `[corpus-ui]` lines, monkey steps folded into one line (count, slowest)."""
        out, steps, slowest, actions = [], 0, 0, Counter()
        for line in lines:
            if " monkey_step " in line:
                steps += 1
                m = re.search(r" ms=(\d+)", line)
                slowest = max(slowest, int(m.group(1)) if m else 0)
                parts = line.split()
                if len(parts) > 3 and "=" not in parts[3]:
                    actions[parts[3]] += 1
                continue
            out.append(line.replace("[corpus-ui] ", "", 1))
        if steps:
            out.append(f"monkey steps done: {steps}, slowest {slowest} ms — " + ", ".join(f"{a} {n}" for a, n in sorted(actions.items())))
        return out[:60]

    def seam_status(self, home: Path) -> List[str]:
        """The seam's own status lines (GauntletCorpusCatalog.writeStatus), validated."""
        path = home / STATUS_FILE
        try:
            text = self.seal.contained(path, self.work).read_text(encoding="utf-8", errors="replace")
        except (OSError, self.h.Refused):
            return []
        return [line for line in text.splitlines() if SEAM_LINE.fullmatch(line)][:10]

    @staticmethod
    def _lock_fd() -> Tuple[int, ...]:
        try:
            os.fstat(9)
            return (9,)
        except OSError:
            return ()

    def remove_work(self) -> None:
        work = str(self.seal.writable(self.work))
        if os.path.isdir(work):
            shutil.rmtree(work, ignore_errors=True)
        if os.path.isdir(work):
            note = "  the run's work folder could NOT be removed whole (it is still on the M4 under ~/corpus/work)"
            self.lines.append(note)
            try:
                self.seal.out_write(self.out, "corpus-summary.txt", note + "\n", append=True)
            except (OSError, self.h.Refused):
                pass
