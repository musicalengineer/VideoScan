#!/usr/bin/env python3
"""sensor_lane.py — the pre-merge SENSOR LANE (GH #360 item 1, Rick 2026-10-21).

"Green means green": ~30 % of the nightly's failures over 30 nights were
source-scan sensors — tests that read the repo's own Swift source and pin its
shape (`SourceTree.appSource(named:)`, a `#filePath` walk of the app tree, the
"sensor"/"ratchet" suites). They run in seconds, yet one stayed red eleven
nights in a row because nobody ran it before merging. This lane runs ALL of
them, and only them, so every agent and every merge can afford to.

What counts as a sensor (found from the test SOURCE every run, so a new sensor
joins the lane the day it is written — there is no list to forget to update):

  * a test whose body reads source text — it uses `SourceTree.` or walks the
    tree from `#filePath` towards `.swift` files — or calls a helper (a func,
    var or let declared in the test target) that does;
  * every test in a suite whose type name contains "Sensor" or "Ratchet"
    (both targets) when that suite's file reads source (an architecture
    sensor; a behaviour sensor that drives the model stays in the nightly);
  * minus tests that measure time/scale or snapshot real global state
    (NOT_A_LANE_TEST_RE) and the SLOW_EXCLUDED list.

Usage (Debug, from any checkout or worktree; paths are absolute):

  python3 scripts/sensor_lane.py list               # what the lane runs
  python3 scripts/sensor_lane.py run                # build + run; exit 1 on a red sensor
  python3 scripts/sensor_lane.py run --app-only     # skip the VideoScanCore half
  scripts/run_sensors.sh                            # the same `run`, as a shell entry

`run` uses `xcodebuild test -only-testing:…` for the app target (Debug, its own
DerivedData under ~/Library/Caches/videoscan-sensor-dd/<checkout>, so a second
run is incremental) and `swift test --filter …` for VideoScanCore. It prints
every failing test name and exits non-zero; a run where the lane executed ZERO
tests is a failure too (an empty filter must never read as green).

Memory: one test file's text at a time; the discovered list is a few thousand
short strings.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Set, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))      # scripts/ — also when loaded by importlib (tests)
from warning_ratchet import check as ratchet_check            # noqa: E402

REPO = Path(__file__).resolve().parent.parent
APP_TESTS = REPO / "VideoScan" / "VideoScanTests"
CORE_PKG = REPO / "VideoScan" / "VideoScanCore"
CORE_TESTS = CORE_PKG / "Tests" / "VideoScanCoreTests"
PROJECT = REPO / "VideoScan" / "VideoScan.xcodeproj"

# NOT in the lane, though they live in a sensor suite or read source: tests
# that measure time or scale (100k records, budgets, baselines — they belong to
# the performance graph, GH #360 item 2, and are load-sensitive) and tests that
# snapshot REAL global state (App Support, UserDefaults: another app or agent
# writing there makes them fail for reasons that are not the code). They stay
# in the nightly. Matched against the test's suite names, its @Test display
# name, its function name and its body.
NOT_A_LANE_TEST_RE = re.compile(
    r"\bscale\b|SCALE|At100k|100k\b|100_000|[Bb]udget|\bperf|[Pp]erformance|[Bb]aseline|[Tt]iming"
    r"|[Ss]tress|ContinuousClock|\.measure\b|timeLimit|clock\.measure"
    r"|ISOLATION|[Pp]oison|appSupportSnapshot|UserDefaults\.standard")
# Individual exclusions by identifier (Target/Type/func()), each with its why.
SLOW_EXCLUDED: Dict[str, str] = {}

SUITE_NAME_RE = re.compile(r"(Sensor|Ratchet)", re.IGNORECASE)
# What reading the repo's own source looks like inside a test or helper.
SOURCE_TREE_RE = re.compile(r"\bSourceTree\s*\.")
FILEPATH_RE = re.compile(r"#filePath\b|#file\b")
SOURCEISH_RE = re.compile(r"\.swift\"|enumerator\s*\(|\"VideoScan\"|\"VideoScanCore|\"Sources\"|Sources/VideoScanCore|appendingPathComponent\(\"VideoScan")


# ---------------------------------------------------------------- lexing

_STRING_OPEN = re.compile(r'(#*)("""|")')
_WORD = re.compile(r"\b([A-Za-z_]\w{3,})\b")


def mask(text: str) -> str:
    """`text` with every comment and string-literal body blanked to spaces
    (newlines kept), so braces can be counted and declarations found without
    being fooled by a `{` in a string. Handles // and nested /* */, "…" with
    escapes and \\( interpolation, \"\"\" blocks, and raw strings #"…"# /
    #\"\"\"…\"\"\"#. Not a Swift lexer; good enough for test files."""
    out = list(text)
    n = len(text)
    i = 0
    # stack entries: ("str", hashes, multiline) or ("interp", depth)
    stack: List[tuple] = []

    def blank(a: int, b: int) -> None:
        for k in range(a, min(b, n)):
            if out[k] != "\n":
                out[k] = " "

    while i < n:
        top = stack[-1] if stack else None
        c = text[i]
        if top is not None and top[0] == "str":
            _, hashes, multi = top
            close = ('"""' if multi else '"') + "#" * hashes
            if c == "\\" and text.startswith("#" * hashes + "(", i + 1):
                j = i + 1 + hashes + 1
                blank(i, j - 1)
                stack.append(("interp", 0))
                i = j
                continue
            if c == "\\" and hashes == 0 and i + 1 < n:
                blank(i, i + 2)
                i += 2
                continue
            if text.startswith(close, i):
                stack.pop()
                i += len(close)
                continue
            if c == "\n" and not multi:
                stack.pop()          # unterminated single-line string: recover
                i += 1
                continue
            blank(i, i + 1)
            i += 1
            continue
        # code (file level or inside an interpolation)
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            blank(i, j)
            i = j
            continue
        if text.startswith("/*", i):
            depth, j = 1, i + 2
            while j < n and depth:
                if text.startswith("/*", j):
                    depth += 1; j += 2
                elif text.startswith("*/", j):
                    depth -= 1; j += 2
                else:
                    j += 1
            blank(i, j)
            i = j
            continue
        m = _STRING_OPEN.match(text, i) if c in '"#' else None
        if m and (m.group(1) or c == '"'):
            hashes = len(m.group(1))
            multi = m.group(2) == '"""'
            i += len(m.group(0))
            stack.append(("str", hashes, multi))
            continue
        if top is not None and top[0] == "interp":
            if c == "(":
                stack[-1] = ("interp", top[1] + 1)
            elif c == ")":
                if top[1] == 0:
                    stack.pop()
                    blank(i, i + 1)
                    i += 1
                    continue
                stack[-1] = ("interp", top[1] - 1)
            blank(i, i + 1)      # interpolation code is inside a string: blank it
            i += 1
            continue
        i += 1
    return "".join(out)


def match_brace(masked: str, open_idx: int) -> int:
    """Index just past the `}` that closes the `{` at open_idx."""
    depth = 0
    for k in range(open_idx, len(masked)):
        ch = masked[k]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return k + 1
    return len(masked)


# ---------------------------------------------------------------- model

@dataclass
class Decl:
    kind: str            # "type" | "func" | "var"
    name: str
    start: int
    end: int
    body_start: int
    type_path: List[str] = field(default_factory=list)
    is_test: bool = False
    params: str = ""
    local: bool = False      # declared inside a function body
    attr_start: int = -1     # where its attribute run (@Test("…")) begins


TYPE_RE = re.compile(r"\b(struct|class|extension|enum|actor)\s+([A-Za-z_][\w.]*)")
FUNC_RE = re.compile(r"\bfunc\s+([A-Za-z_]\w*)\s*(<[^>{]*>)?\s*\(")
VAR_RE = re.compile(r"\b(?:var|let)\s+([A-Za-z_]\w*)\b")


def _params_label(masked: str, paren: int) -> Tuple[str, int]:
    """`(x: Int, _ y: String)` -> "x:_:" and the index after `)`."""
    depth, k = 0, paren
    while k < len(masked):
        if masked[k] == "(":
            depth += 1
        elif masked[k] == ")":
            depth -= 1
            if depth == 0:
                break
        k += 1
    inner = masked[paren + 1:k]
    labels = []
    depth = 0
    part = ""
    for ch in inner + ",":
        if ch in "([<":
            depth += 1
        elif ch in ")]>":
            depth -= 1
        if ch == "," and depth == 0:
            p = part.strip()
            if p:
                head = p.split(":", 1)[0].split()
                labels.append((head[0] if head else "_") + ":")
            part = ""
        else:
            part += ch
    return "".join(labels), k + 1


def parse(text: str, masked: Optional[str] = None) -> List[Decl]:
    """Types, funcs and vars/lets with their spans, each with its enclosing
    type path. Attributes are looked back from the declaration for @Test."""
    masked = mask(text) if masked is None else masked
    decls: List[Decl] = []
    # types first (spans), then everything nests by position
    for m in TYPE_RE.finditer(masked):
        brace = masked.find("{", m.end())
        semi = masked.find("\n", m.end())
        if brace < 0:
            continue
        # a type header can span lines (conformances / where clauses), but
        # never contains another declaration keyword before its brace.
        header = masked[m.end():brace]
        if re.search(r"\b(func|var|let|struct|class|enum|actor|extension)\b", header):
            continue
        if m.group(2) in ("func", "var", "let", "init", "subscript", "case"):
            continue                       # `class func` / `class var`
        name = m.group(2).split(".")[-1]
        decls.append(Decl("type", name, m.start(), match_brace(masked, brace), brace))
    for m in FUNC_RE.finditer(masked):
        labels, after = _params_label(masked, m.end() - 1)
        brace = masked.find("{", after)
        nl_ok = brace >= 0 and not re.search(r"\b(func|var|let|struct|class|enum)\b", masked[after:brace])
        if not nl_ok:
            continue
        end = match_brace(masked, brace)
        attrs = masked[max(0, m.start() - 600):m.start()]
        # the attribute run directly above: @Test(...) possibly multi-line
        last_decl_end = max(attrs.rfind("}"), attrs.rfind(";"))
        attr_text = attrs[last_decl_end + 1:] if last_decl_end >= 0 else attrs
        is_test = bool(re.search(r"@Test\b", attr_text))
        decls.append(Decl("func", m.group(1), m.start(), end, brace, is_test=is_test, params=labels,
                          attr_start=m.start() - len(attr_text)))
    for m in VAR_RE.finditer(masked):
        # a stored/computed var or let: span to the end of its initializer
        # line, or its brace block when it is a closure / computed property.
        line_end = masked.find("\n", m.end())
        line_end = len(masked) if line_end < 0 else line_end
        brace = masked.find("{", m.end(), line_end)
        end = match_brace(masked, brace) if brace >= 0 else line_end
        decls.append(Decl("var", m.group(1), m.start(), end, brace))
    types = [d for d in decls if d.kind == "type"]
    for d in decls:
        enclosing = sorted((t for t in types if t.body_start < d.start < t.end and t is not d),
                           key=lambda t: t.start)
        d.type_path = [t.name for t in enclosing]
    funcs = [d for d in decls if d.kind == "func"]
    for d in decls:
        if d.kind != "type":
            d.local = any(f.body_start < d.start < f.end for f in funcs if f is not d)
            if d.local:
                d.is_test = False      # a func nested in a test is not a test
    # XCTest: `func testX()` inside a class that inherits from XCTestCase
    for t in types:
        header = masked[t.start:t.body_start]
        if "XCTestCase" in header:
            for d in decls:
                if d.kind == "func" and t.body_start < d.start < t.end and d.name.startswith("test") \
                        and d.params == "" and d.type_path and d.type_path[-1] == t.name:
                    d.is_test = True
                    d.params = "xctest"
    return decls


def reads_source(snippet: str) -> bool:
    if SOURCE_TREE_RE.search(snippet):
        return True
    return bool(FILEPATH_RE.search(snippet) and SOURCEISH_RE.search(snippet))


@dataclass(frozen=True)
class Sensor:
    target: str          # VideoScanTests | VideoScanCoreTests
    type_path: Tuple[str, ...]
    func: str
    params: str
    file: str

    @property
    def xcode_id(self) -> str:
        if self.params == "xctest":
            return f"{self.target}/{'/'.join(self.type_path)}/{self.func}"
        return f"{self.target}/{'/'.join(self.type_path)}/{self.func}({self.params})"

    @property
    def core_filter(self) -> str:
        # swift test --filter matches "<Module>.<Type>/<func>" (XCTest) and
        # "<Module>.<Type>/<func>(<labels>)" (Swift Testing); a regex.
        base = f"{self.target}.{'.'.join(self.type_path)}/{self.func}"
        return re.escape(base) + (r"$" if self.params == "xctest" else re.escape("(" + self.params + ")"))


def swift_files(root: Path) -> Iterable[Path]:
    for p in sorted(root.rglob("*.swift")):
        if "Fixtures" in p.parts:
            continue
        yield p


def discover(root: Path, target: str) -> List[Sensor]:
    """Every sensor test under `root`. A helper (a func / var / let declared at
    file or type level — never a local inside a function) reads source when
    its own text does, or when it calls another such helper. A test may use a
    helper declared in its own file, in a type of the same name (an extension
    in another file), or in a shared `*Support*` / `*Helpers*` file — never a
    same-named helper of an unrelated file (`source`, `model` are everywhere)."""
    # (path, text, masked, decls): `text` for the source-reading markers (they
    # live in string literals: ".swift\"", "VideoScan"), `masked` for names.
    parsed: List[Tuple[Path, str, str, List[Decl]]] = []
    for path in swift_files(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        masked = mask(text)
        parsed.append((path, text, masked, parse(text, masked)))

    def shared(path: Path) -> bool:
        return bool(re.search(r"(Support|Helpers?|SourceTree)\.swift$", path.name))

    def is_helper(d: Decl) -> bool:
        return d.kind in ("func", "var") and not d.is_test and not d.local and len(d.name) >= 3

    def homes(path: Path, d: Decl) -> List[Tuple[str, str]]:
        return [("file", str(path))] + ([("type", d.type_path[-1])] if d.type_path else []) \
            + ([("shared", "")] if shared(path) else [])

    def visible(path: Path, type_path: List[str]) -> List[Tuple[str, str]]:
        return [("file", str(path)), ("shared", "")] + [("type", t) for t in type_path]

    # helper scope ("file", path) | ("type", name) | ("shared", "") -> reader names
    readers: Dict[Tuple[str, str], Set[str]] = {}
    pending: List[Tuple[Path, Decl, str]] = []          # helpers not (yet) known to read
    for path, text, masked, decls in parsed:
        for d in decls:
            if not is_helper(d):
                continue
            if reads_source(text[d.start:d.end]):
                for k in homes(path, d):
                    readers.setdefault(k, set()).add(d.name)
            else:
                pending.append((path, d, masked[d.start:d.end]))
    # transitive closure: a helper that calls a visible reader reads.
    changed = True
    while changed:
        changed = False
        still: List[Tuple[Path, Decl, str]] = []
        for path, d, body in pending:
            names: Set[str] = set().union(*(readers.get(k, set()) for k in visible(path, d.type_path)))
            if _calls_any(body, names, exclude=d.name):
                for k in homes(path, d):
                    readers.setdefault(k, set()).add(d.name)
                changed = True
            else:
                still.append((path, d, body))
        pending = still

    sensors: List[Sensor] = []
    for path, text, masked, decls in parsed:
        # A *Sensor*/*Ratchet* suite is an ARCHITECTURE sensor only when its
        # file reads source; one that drives the model (log destinations, a
        # job's outcome lines) is a behaviour sensor and stays in the nightly
        # — it shares real state and cannot run beside the scans in parallel.
        file_reads_source = reads_source(text)
        for d in decls:
            if d.kind != "func" or not d.is_test or not d.type_path:
                continue
            whole = text[d.attr_start if d.attr_start >= 0 else d.start:d.end]
            if NOT_A_LANE_TEST_RE.search(whole) or any(NOT_A_LANE_TEST_RE.search(t) for t in d.type_path):
                continue
            in_named_suite = file_reads_source and any(SUITE_NAME_RE.search(t) for t in d.type_path)
            names = set().union(*(readers.get(k, set()) for k in visible(path, d.type_path)))
            if in_named_suite or reads_source(text[d.start:d.end]) \
                    or _calls_any(masked[d.start:d.end], names, exclude=d.name):
                s = Sensor(target, tuple(d.type_path), d.name, d.params, str(path.relative_to(REPO)))
                if s.xcode_id not in SLOW_EXCLUDED:
                    sensors.append(s)
    # one per id (a func declared in two extensions of one type is one test)
    uniq: Dict[str, Sensor] = {}
    for s in sensors:
        uniq.setdefault(s.xcode_id, s)
    return sorted(uniq.values(), key=lambda s: s.xcode_id)


def _calls_any(body: str, names: Set[str], exclude: str) -> bool:
    if not names:
        return False
    for m in _WORD.finditer(body):        # body is already masked
        n = m.group(1)
        if n != exclude and n in names:
            return True
    return False


# ---------------------------------------------------------------- running

FAIL_LINE_RE = re.compile(r"✘ Test (.+?) (?:failed after|recorded an issue)")
XC_FAIL_RE = re.compile(r"^Test Case '-\[(\S+) (\S+)\]' failed", re.M)
FAILING_BLOCK_RE = re.compile(r"^Failing tests:\n((?:[ \t]+.+\n)+)", re.M)
PASS_RE = re.compile(r"(✔ Test .* passed after |━ Test .* passed after |^Test Case .* passed)", re.M)
FAILCOUNT_RE = re.compile(r"(✘ Test .* failed after |^Test Case .* failed)", re.M)
PAR_FAIL_RE = re.compile(r"^Test case '(.+?)' failed on ", re.M)


PAR_PASS_RE = re.compile(r"^Test case '.+?' passed on ", re.M)


def count(log: str) -> Tuple[int, int, List[str]]:
    """(passed, failed, failing names) from an xcodebuild / swift test log.
    With parallel testing xcodebuild reports EVERY test (XCTest and Swift
    Testing) as "Test case '<Suite>/<f>()' passed|failed on '<Mac> (pid)'";
    without it, Swift Testing prints "✔/✘ Test …" and XCTest "Test Case '-[…]'".
    The parallel lines win when present, so nothing is counted twice. Every
    name in xcodebuild's "Failing tests:" block is a failure too (a host that
    died prints no line of its own)."""
    names: Set[str] = set()
    par_pass = len(PAR_PASS_RE.findall(log))
    par_fail = PAR_FAIL_RE.findall(log)
    if par_pass or par_fail:
        passed, failed = par_pass, len(par_fail)
        names.update(par_fail)
    else:
        passed = len(PASS_RE.findall(log)) - len(re.findall(r"Test run with \d+ tests?.* passed after", log))
        failed_lines = [l for l in log.splitlines() if FAILCOUNT_RE.search(l) and " recorded an issue " not in l
                        and not re.search(r"Test run with \d+ test", l)]
        failed = len(failed_lines)
        for l in failed_lines:
            m = re.search(r"✘ Test (.+?) failed after", l)
            if m:
                names.add(m.group(1))
        for m in XC_FAIL_RE.finditer(log):
            names.add(f"{m.group(1)}.{m.group(2)}")
    for m in FAILING_BLOCK_RE.finditer(log):
        for entry in m.group(1).splitlines():
            if entry.strip():
                names.add(entry.strip())
    return max(passed, 0), failed, sorted(names)


def checkout_key() -> str:
    return hashlib.sha1(str(REPO).encode()).hexdigest()[:10]


def run_app(sensors: List[Sensor], log_dir: Path, dd: Path) -> Tuple[int, int, List[str], int, float]:
    args = ["xcodebuild", "test", "-project", str(PROJECT), "-scheme", "VideoScan",
            "-configuration", "Debug", "-destination", "platform=macOS,arch=arm64",
            "-derivedDataPath", str(dd), "-skip-testing:VideoScanUITests",
            # The test plan says parallelizable=false for the whole suite (shared
            # state in behaviour tests). Source scans only READ files: run them
            # in parallel, which is what keeps the lane inside its budget.
            "-parallel-testing-enabled", "YES",
            "CODE_SIGN_IDENTITY=-", "CODE_SIGNING_REQUIRED=NO", "CODE_SIGN_ENTITLEMENTS=",
            "ONLY_ACTIVE_ARCH=YES"]
    args += [f"-only-testing:{s.xcode_id}" for s in sensors]
    return _run(args, log_dir / "sensor-lane-app.log")


def run_core(sensors: List[Sensor], log_dir: Path) -> Tuple[int, int, List[str], int, float]:
    pattern = "|".join(s.core_filter for s in sensors)
    args = ["swift", "test", "--package-path", str(CORE_PKG), "--filter", pattern]
    return _run(args, log_dir / "sensor-lane-core.log")


def _run(args: List[str], log_path: Path) -> Tuple[int, int, List[str], int, float]:
    t0 = time.monotonic()
    with open(log_path, "w") as fh:
        rc = subprocess.run(args, stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL).returncode
    elapsed = time.monotonic() - t0
    log = log_path.read_text(errors="replace")
    passed, failed, names = count(log)
    return passed, failed, names, rc, elapsed


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ls = sub.add_parser("list", help="print the sensors the lane runs")
    ls.add_argument("--ids", action="store_true", help="one identifier per line, nothing else")
    rn = sub.add_parser("run", help="build (Debug) and run the lane")
    rn.add_argument("--app-only", action="store_true")
    rn.add_argument("--core-only", action="store_true")
    rn.add_argument("--derived-data", default=None,
                    help="DerivedData for the app half (default: ~/Library/Caches/videoscan-sensor-dd/<checkout>)")
    rn.add_argument("--log-dir", default=None, help="where the two logs go (default: a temp dir, printed)")
    a = ap.parse_args(argv)

    app = discover(APP_TESTS, "VideoScanTests")
    core = discover(CORE_TESTS, "VideoScanCoreTests")
    if a.cmd == "list":
        for s in app + core:
            print(s.xcode_id if a.ids else f"{s.xcode_id}    ({s.file})")
        if not a.ids:
            print(f"# {len(app)} app sensors, {len(core)} core sensors", file=sys.stderr)
        return 0

    if not app and not a.core_only:
        print("SENSOR LANE FAILED: discovered ZERO app sensors — the discovery broke, not a green run", file=sys.stderr)
        return 1
    log_dir = Path(a.log_dir).expanduser() if a.log_dir else Path(os.environ.get("TMPDIR", "/tmp")) / f"sensor-lane-{checkout_key()}"
    log_dir.mkdir(parents=True, exist_ok=True)
    dd = Path(a.derived_data).expanduser() if a.derived_data else \
        Path.home() / "Library" / "Caches" / "videoscan-sensor-dd" / checkout_key()
    print(f"sensor lane: {len(app)} app + {len(core)} core sensors (Debug) — logs in {log_dir}", flush=True)

    red: List[str] = []
    ran_total = 0
    produced: List[Path] = []          # this run's logs, for the warning ratchet
    if not a.core_only:
        p, f, names, rc, el = run_app(app, log_dir, dd)
        produced.append(log_dir / "sensor-lane-app.log")
        ran_total += p + f
        print(f"  app  (xcodebuild -only-testing): {p} passed, {f} failed, rc={rc}, {el:.0f}s", flush=True)
        if f or rc != 0 or p == 0:
            red += [f"VideoScanTests: {n}" for n in names] or [f"VideoScanTests: rc={rc}, {p} passed — see {log_dir}/sensor-lane-app.log"]
    if not a.app_only and core:
        p, f, names, rc, el = run_core(core, log_dir)
        produced.append(log_dir / "sensor-lane-core.log")
        ran_total += p + f
        print(f"  core (swift test --filter):      {p} passed, {f} failed, rc={rc}, {el:.0f}s", flush=True)
        if f or rc != 0 or p == 0:
            red += [f"VideoScanCoreTests: {n}" for n in names] or [f"VideoScanCoreTests: rc={rc}, {p} passed — see {log_dir}/sensor-lane-core.log"]
    # Warning ratchet (Swift 6 stage 0, docs/design/swift6_migration_2026_10_25.md):
    # no (file, category) may carry more compiler warnings than
    # scripts/warnings_baseline.tsv records. Per file, so this lane's incremental
    # build is enough; only a clean build rewrites the baseline
    # (`warning_ratchet.py update --clean`). A missing baseline is one red line.
    ratchet_red, n_warn, n_files = ratchet_check(produced)
    print(f"  warning ratchet:                 {n_warn} warning(s) in {n_files} compiled file(s), "
          f"{'RED' if ratchet_red else 'green'} against the baseline", flush=True)
    red += [f"warning ratchet: {r}" for r in ratchet_red]
    if red:
        print("\nSENSOR LANE RED — fix these before merging / reporting done:", file=sys.stderr)
        for r in red:
            print(f"  ✘ {r}", file=sys.stderr)
        return 1
    print(f"sensor lane GREEN ({ran_total} tests)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
