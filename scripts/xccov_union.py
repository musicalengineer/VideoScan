#!/usr/bin/env python3
"""Line coverage of ONE build from K test hosts' result bundles: the exact union, or a refusal.

Why (2026-11-21, review of the sharded nightly): the app tests run as K hosts (scripts/xctest_shards.py),
each with its own result bundle. `xcrun xcresulttool merge` / `xccov merge` do NOT give the union of
their coverage: they merge per FUNCTION by name, and on 16 real Release bundles the merged report had
more executable lines than the build has (342,125 for 341,680; 31 files inflated) while, in 60 files,
ONE shard alone covered more lines than the merge said (FamilyTreeCards.swift 730 vs 561). A coverage
number that is silently half a point low is not a fact (CLAUDE.md rule 1).

What this does instead — nothing is estimated:
  * each bundle's per-LINE archive is read (`xccov view --archive --json`: every line of every file,
    executable or not, and how often it ran) and its target's file list (`xccov view --report --json`);
  * a line is COVERED when it ran in ANY bundle; the DENOMINATOR is the build's executable lines;
  * it REFUSES (exit 1, a line saying why, no number) unless
      (a) every bundle names the same files for the target and, per file, the SAME executable lines
          (one build: a bundle from another build, or a truncated archive, is caught here), and
      (b) per file, the union covers at least what the best single bundle covers, and nothing outside
          the executable lines (true of a union by construction — checked anyway, on the result);
    a bundle that cannot be read, or a target that is in no bundle, is a refusal too.

The number is DISTINCT lines. Xcode's report (`xccov view --report`, what the single-host nightly
publishes) adds up each FUNCTION's lines, so a line inside a closure counts once for the closure and
once for the function around it (PreviewService.swift: 356 executable lines, 560 in the report). The
two are different rulers: for one bundle this tool prints both (`report_*` is the bundle's own report,
summed with the same file filter), so a series can be compared like with like.

usage:
  xccov_union.py --target VideoScan.app [--logic] [--json OUT] [--html DIR] BUNDLE.xcresult [BUNDLE.xcresult …]
  --logic   leave out SwiftUI-shaped files by name, exactly the nightly's filter (LOGIC_EXCLUDE)
  --html    also a static report (run_tests.py --coverage): DIR/index.html, files by lines never run, and
            one page per file with its source shaded ran / never ran / not code (2026-11-22)
Output: one line "coverage-union: …" on stdout (and OUT as JSON). Exit 0 a number · 1 refused · 2 usage.

Memory: one bundle's archive at a time. Its JSON is ~38 MB (1.6 M line records over ~2,500 files); each
record is turned into one int as it is parsed (object_hook), so held are ~1.6 M ints for the bundle in
hand plus, for the target's ~1,150 files, one set of executable and one of covered line numbers
(~0.6 M ints) — but the JSON text and the parser's working set are whole in memory while one archive
is read. Measured 2026-11-21 (16 real Release bundles): peak resident size 555 MB, 39 s. No bundle is modified.

Tests: tests/test_xccov_union.py (fakes, and the real bundles under ~/Library/Caches when present).
"""
from __future__ import annotations

import argparse
import json
import re
import shlex
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, FrozenSet, List, Optional, Sequence, Set, Tuple

PREFIX = "coverage-union: "
CALL_SECONDS = 600.0          # one xccov call
TOTAL_SECONDS = 1200.0        # the whole union (measured: 39 s for 16 real bundles); past it: refuse
# The nightly's "logic-only" filter (scripts/nightly_local_tests.sh, the awk over `xccov view --report
# --files-for-target`): a file whose name ends in one of these is a SwiftUI surface, not logic.
LOGIC_EXCLUDE = re.compile(r"(View|Window|Sheet|Dashboard|App|Bar|Row|SplitView)\.swift$")


class Refused(Exception):
    """The union cannot be vouched for. The message says which bundle and which file."""


def _line_code(d: dict):
    """json object_hook: a line record → +line (ran), -line (executable, never ran), 0 (not code).
    A sub-range record (a part of one line) → None: the line's own count already says whether it ran.
    Anything else (the top-level path → lines object) is left alone. ≈ C++: parsing straight into a
    packed int instead of building a struct per line."""
    if "line" in d and "isExecutable" in d:
        if not d["isExecutable"]:
            return 0
        n = int(d["line"])
        return n if int(d.get("executionCount") or 0) > 0 else -n
    if "column" in d or "length" in d:
        return None
    return d


def _tool_json(xcrun: Sequence[str], args: Sequence[str], bundle: Path, hook=None, deadline: Optional[float] = None):
    left = CALL_SECONDS if deadline is None else min(CALL_SECONDS, deadline - time.monotonic())
    if left <= 0:
        raise Refused(f"{bundle}: out of time before xccov view {' '.join(args)} "
                      f"(the whole union is given {TOTAL_SECONDS:g} s)")
    try:
        p = subprocess.run(list(xcrun) + ["xccov", "view"] + list(args) + ["--json", str(bundle)],
                           capture_output=True, text=True, timeout=left, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        raise Refused(f"{bundle}: xccov view {' '.join(args)} did not finish in {left:.0f} s "
                      f"(one call is given {CALL_SECONDS:g} s, the whole union {TOTAL_SECONDS:g} s)")
    except OSError as e:
        raise Refused(f"{bundle}: xccov view {' '.join(args)} could not run ({type(e).__name__})")
    if p.returncode != 0:
        raise Refused(f"{bundle}: xccov view {' '.join(args)} failed (exit {p.returncode}: "
                      f"{(p.stderr or p.stdout).strip().splitlines()[-1][:200] if (p.stderr or p.stdout).strip() else 'no output'})")
    try:
        return json.loads(p.stdout, object_hook=hook)
    except ValueError:
        raise Refused(f"{bundle}: xccov view {' '.join(args)} did not print JSON")


class BundleCoverage:
    """One bundle, one target: per file its executable lines and the ones that ran; and the bundle's
    own report numbers (function-summed) for the same files."""

    def __init__(self, bundle: Path, target: str, xcrun: Sequence[str], deadline: Optional[float] = None) -> None:
        report = _tool_json(xcrun, ["--report"], bundle, deadline=deadline)
        found = [t for t in (report.get("targets") or []) if t.get("name") == target] if isinstance(report, dict) else []
        if len(found) != 1:
            raise Refused(f"{bundle}: its coverage report has {len(found)} targets named {target!r}")
        files = found[0].get("files") or []
        nameless = [f for f in files if not isinstance(f, dict) or not isinstance(f.get("path"), str) or not f["path"]]
        if nameless:
            raise Refused(f"{bundle}: {len(nameless)} file(s) of {target!r} in its coverage report have no path")
        self.report: Dict[str, Tuple[int, int]] = {
            f["path"]: (int(f.get("coveredLines") or 0), int(f.get("executableLines") or 0)) for f in files}
        if not self.report:
            raise Refused(f"{bundle}: target {target!r} lists no files")
        archive = _tool_json(xcrun, ["--archive"], bundle, hook=_line_code, deadline=deadline)
        if not isinstance(archive, dict):
            raise Refused(f"{bundle}: its coverage archive is not a path → lines table")
        self.executable: Dict[str, FrozenSet[int]] = {}
        self.covered: Dict[str, FrozenSet[int]] = {}
        for path in self.report:
            lines = archive.get(path)
            if not isinstance(lines, list):
                raise Refused(f"{bundle}: {path} is in the report and not in the archive")
            ran = frozenset(n for n in lines if isinstance(n, int) and n > 0)
            self.covered[path] = ran
            self.executable[path] = ran | frozenset(-n for n in lines if isinstance(n, int) and n < 0)


def union(bundles: Sequence[Path], target: str, xcrun: Sequence[str] = ("xcrun",), keep_lines: bool = False) -> dict:
    """The union over the bundles, checked (a) and (b), as {files: {path: [covered, executable]}, …};
    keep_lines: also {lines: {path: (covered set, executable set)}} for the HTML report. Raises Refused."""
    if not bundles:
        raise Refused("no result bundle to read")
    executable: Dict[str, FrozenSet[int]] = {}
    covered: Dict[str, Set[int]] = {}
    best: Dict[str, int] = {}
    report: Dict[str, Tuple[int, int]] = {}
    first: Optional[Path] = None
    deadline = time.monotonic() + TOTAL_SECONDS
    for bundle in bundles:
        one = BundleCoverage(Path(bundle), target, xcrun, deadline)   # one archive in memory at a time
        if first is None:
            first, executable = Path(bundle), one.executable
            covered = {p: set(s) for p, s in one.covered.items()}
            best = {p: len(s) for p, s in one.covered.items()}
            report = one.report
            continue
        if set(one.executable) != set(executable):
            odd = sorted(set(one.executable) ^ set(executable))
            raise Refused(f"{bundle} and {first} do not name the same files for {target} "
                          f"({len(odd)} differ, e.g. {odd[0]}): not one build")
        for path, lines in one.executable.items():
            if lines != executable[path]:
                raise Refused(f"{bundle}: {path} has {len(lines)} executable lines, {first} has "
                              f"{len(executable[path])} (or other lines): not one build — no union")
            covered[path] |= one.covered[path]
            best[path] = max(best[path], len(one.covered[path]))
        if len(bundles) > 1:
            report = {}                     # a function-summed number exists for ONE bundle only
    files: Dict[str, List[int]] = {}
    for path, lines in executable.items():
        if not covered[path] <= lines:
            raise Refused(f"{path}: {len(covered[path] - lines)} covered line(s) are not executable lines")
        if len(covered[path]) < best[path]:
            raise Refused(f"{path}: the union covers {len(covered[path])} lines, one bundle alone {best[path]}")
        files[path] = [len(covered[path]), len(lines)]
    u = {"target": target, "bundles": len(bundles), "files": files, "report": report}
    if keep_lines:
        u["lines"] = {p: (frozenset(covered[p]), executable[p]) for p in executable}
    return u


HTML_CSS = """
body{font:13px -apple-system,system-ui,sans-serif;margin:24px;color:#1d1d1f;background:#fff}
h1{font-size:18px;margin:0 0 4px}p.sub{color:#6e6e73;margin:0 0 16px}
table{border-collapse:collapse;width:100%}th,td{padding:3px 8px;text-align:right;border-bottom:1px solid #e5e5ea}
th:first-child,td:first-child{text-align:left}th{position:sticky;top:0;background:#f5f5f7}
a{color:#0066cc;text-decoration:none}a:hover{text-decoration:underline}
.bar{display:inline-block;width:80px;height:8px;background:#e5e5ea;vertical-align:middle}
.bar i{display:block;height:8px;background:#34c759}
pre{font:12px ui-monospace,Menlo,monospace;margin:0}
pre span{display:block;white-space:pre}pre b{display:inline-block;width:5em;color:#8e8e93;font-weight:normal;user-select:none}
.c{background:#e6f6ea}.u{background:#fde8e7}
@media (prefers-color-scheme:dark){body{color:#f5f5f7;background:#1c1c1e}th{background:#2c2c2e}
th,td{border-color:#3a3a3c}.bar{background:#3a3a3c}.c{background:#1f3a26}.u{background:#4a2020}a{color:#4da3ff}}
"""


def write_html(u: dict, out_dir: Path, logic: bool, title: str) -> Path:
    """A static report: index.html (every file, most uncovered lines first) and one page per file with
    its source shaded covered / never ran / not code. The source is read from the paths the bundles name
    (the build's checkout); a file that cannot be read gets a page that says so. No JS, no network."""
    import html as h
    out_dir.mkdir(parents=True, exist_ok=True)
    lines = u["lines"]
    rows = sorted(((p, v[0], v[1]) for p, v in u["files"].items() if not (logic and LOGIC_EXCLUDE.search(p))),
                  key=lambda r: (-(r[2] - r[1]), r[0]))
    common = ""
    if rows:
        import os.path
        common = os.path.commonpath([r[0] for r in rows]) if len(rows) > 1 else str(Path(rows[0][0]).parent)
    cov, exe = total(u["files"], logic)
    body = []
    for i, (path, c, e) in enumerate(rows):
        name = f"f{i:04d}.html"
        rel = path[len(common):].lstrip("/") if common and path.startswith(common) else path
        per = pct(c, e)
        body.append(f'<tr><td><a href="{name}">{h.escape(rel)}</a></td><td>{e - c}</td><td>{c}</td><td>{e}</td>'
                    f'<td>{"" if per is None else f"{per:.1f}%"}</td>'
                    f'<td><span class="bar"><i style="width:{0 if per is None else per:.0f}%"></i></span></td></tr>')
        ran, code = lines[path]
        try:
            src = Path(path).read_text(errors="replace").splitlines()
            spans = []
            for n, text in enumerate(src, 1):
                cls = "c" if n in ran else ("u" if n in code else "")
                spans.append(f'<span class="{cls}"><b>{n}</b>{h.escape(text)}</span>')
            shown = "<pre>" + "".join(spans) + "</pre>"
        except OSError as ex:
            shown = f"<p>source not readable here: {h.escape(str(ex))}</p>"
        (out_dir / name).write_text(
            f"<!doctype html><meta charset=utf-8><title>{h.escape(rel)}</title><style>{HTML_CSS}</style>"
            f'<p><a href="index.html">&larr; {h.escape(title)}</a></p><h1>{h.escape(rel)}</h1>'
            f'<p class="sub">{c} of {e} executable lines ran ({"" if per is None else f"{per:.1f}%"}) · '
            f"green ran · red never ran · plain not code</p>{shown}", encoding="utf-8")
    overall = pct(cov, exe)
    (out_dir / "index.html").write_text(
        f"<!doctype html><meta charset=utf-8><title>{h.escape(title)}</title><style>{HTML_CSS}</style>"
        f"<h1>{h.escape(title)}</h1><p class=sub>{'' if overall is None else f'{overall:.2f}%'} — {cov} of {exe} "
        f"distinct executable lines of {h.escape(u['target'])} ran{' (logic only)' if logic else ''}; union of "
        f"{u['bundles']} result bundle(s); {len(rows)} files under {h.escape(common)}. Only the tests that ran "
        f"count: a smoke or filtered run is a partial number.</p>"
        f"<table><tr><th>file</th><th>not run</th><th>ran</th><th>lines</th><th>%</th><th></th></tr>"
        + "".join(body) + "</table>", encoding="utf-8")
    return out_dir / "index.html"


def total(files: Dict[str, Sequence[int]], logic: bool) -> Tuple[int, int]:
    kept = [v for p, v in files.items() if not (logic and LOGIC_EXCLUDE.search(p))]
    return sum(v[0] for v in kept), sum(v[1] for v in kept)


def pct(covered: int, executable: int) -> Optional[float]:
    return round(covered * 100.0 / executable, 3) if executable > 0 else None


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    ap.add_argument("--target", required=True, help="the coverage target, e.g. VideoScan.app")
    ap.add_argument("--logic", action="store_true", help="leave out SwiftUI-shaped files (the nightly's filter)")
    ap.add_argument("--json", type=Path, default=None, metavar="OUT", help="also write the result as JSON")
    ap.add_argument("--html", type=Path, default=None, metavar="DIR",
                    help="also write a browsable report: DIR/index.html and one shaded source page per file")
    ap.add_argument("--title", default=None, help=argparse.SUPPRESS)
    ap.add_argument("--xcrun", default="xcrun", help=argparse.SUPPRESS)
    ap.add_argument("bundles", nargs="+", type=Path)
    a = ap.parse_args(argv)
    try:
        u = union(a.bundles, a.target, shlex.split(a.xcrun), keep_lines=a.html is not None)
        covered, executable = total(u["files"], a.logic)
        number = pct(covered, executable)
        if number is None:
            raise Refused(f"{a.target} has no executable line{' outside the excluded files' if a.logic else ''}")
    except Refused as e:
        print(PREFIX + f"REFUSED — {e}", flush=True)
        if a.json:
            a.json.write_text(json.dumps({"ok": False, "why": str(e)}) + "\n")
        return 1
    out = {"ok": True, "target": a.target, "bundles": u["bundles"], "logic_only": a.logic, "files": len(u["files"]),
           "pct": number, "covered": covered, "executable": executable}
    words = (f"{number:.3f}% ({covered}/{executable} distinct lines of {a.target}"
             f"{', logic only' if a.logic else ''}; union of {u['bundles']} bundle(s), {len(u['files'])} files; "
             f"same executable lines in every bundle; union >= best bundle in every file)")
    if u["report"]:
        rc, rx = total({p: v for p, v in u["report"].items()}, a.logic)
        out.update(report_pct=pct(rc, rx), report_covered=rc, report_executable=rx)
        words += f" · the bundle's own report (function-summed): {pct(rc, rx)}% ({rc}/{rx})"
    print(PREFIX + words, flush=True)
    if a.html is not None:
        index = write_html(u, a.html, a.logic, a.title or f"{a.target} line coverage")
        print(f"coverage-html: {index}", flush=True)
    if a.json:
        a.json.write_text(json.dumps(out, sort_keys=True) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
