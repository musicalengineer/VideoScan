#!/usr/bin/env python3
"""Nightly complexity + tech-debt metrics, and a report-only debt ratchet.

Why this exists
---------------
Rick (2026-10-05): spot over-complex code automatically, every night, while it
is still cheap to refactor. The repo already counts FILE size
(`files_over_1000` in metrics/history.jsonl); nothing measured FUNCTION
complexity. SwiftLint's `cyclomatic_complexity` rule (warning 15) is the
nearest thing, but its count is folded into one SwiftLint total and says
nothing about where the debt is or whether it is growing.

What it measures
----------------
`lizard` (pure Python, no Node) over production code only:

  Swift   VideoScan/VideoScan, VideoScan/VideoScanCore/Sources, swift_cli
  Python  scripts, tools

Folder keys for Swift are the same as `swift_by_folder` in
scripts/collect_metrics.sh (top-level app folder, "Core", "swift_cli",
"(app root)"), so the two series line up on the metrics page. Python folders
are "scripts" and "tools". Files come from `git ls-files` (so venvs, .build,
SwiftPM checkouts and anything untracked are never measured), with an os.walk
fallback that skips the same directories.

One row per run goes to metrics/complexity.jsonl:

  ts, sha, run_kind, lizard_version, thresholds,
  swift_by_folder / python_by_folder:
      {folder: {files, functions, mean_ccn, ccn_over_15, nloc_over_80,
                files_over_800}}
  totals: {swift: {...}, python: {...}, all: {...}}   (same fields + offenders)
  top15:  [{file, function, ccn, nloc, lang}]         worst by CCN, then NLOC
  debt_*: offenders / baseline / new / worse / fixed counts (see below)

Swift computed properties
-------------------------
Stock lizard does not treat `var body: some View { ... }` as a function: its
code lands in no function at all, so the largest SwiftUI bodies in this repo —
the exact family that hit "unable to type-check in reasonable time" on the
runner — would be invisible. `install_swift_property_support()` teaches the
Swift reader that `var NAME ... {` on one line is a function named NAME.
Stored properties (`var x: Int`, `var x = ...`), loop bindings (`for var i in`)
and multi-line declarations are left alone.

The debt ratchet (REPORT ONLY — never fails the build)
------------------------------------------------------
An OFFENDER is a function with CCN > 15 or NLOC > 80. The baseline is the set
of offenders we already know about, keyed by FUNCTION IDENTITY:

    <repo-relative file>::<function name>

No line numbers, so moving code does not resurrect anything. When a name
occurs more than once in a file (Swift `init`, `get`, several SwiftUI `body`s)
the key adds the enclosing type and parent function (`Type.prop.get`), then
lizard's long name (name plus parameters), and an ordinal `#n` in source
order only if that is still ambiguous (5 of 514 offenders on 2026-10-05).

Each night:
  NEW    an offender whose key is not on the baseline
  WORSE  a baseline offender whose CCN rose, or whose NLOC grew by more than
         max(5, 10 %) over the baseline value
  FIXED  a baseline key that is no longer an offender (or no longer exists)

The baseline only ever SHRINKS: fixed keys are dropped and improved values
are lowered to today's. New offenders are never added automatically, so they
keep showing up every morning until they are fixed or someone deliberately
re-baselines (`--update-baseline`, explained in the commit). A renamed or
moved function reads as one FIXED plus one NEW.

Where the baseline lives: ONE committed file, ci/baselines/complexity_debt.json.
The nightly (GitHub) cannot commit to main, so it publishes the shrunk
version as metrics/complexity_baseline_proposed.json and the morning digest
says how many entries are fixed; `--shrink-baseline` applies exactly that
locally (drop + lower, never add) for a commit. The blocking gate
(scripts/complexity_gate.py: pre-commit + CI preflight, CCN > 30 / 300 lines)
reads the same file. The new-offender list goes to
metrics/complexity_debt_latest.json, next to nightly_findings_latest.json,
and scripts/morning_metrics.sh prints it (`--alert`), together with every
gate override from the last 48 h (ci/baselines/complexity_overrides.jsonl).

The CCN 15 excess (Rick 2026-10-07): ci/baselines/complexity_ccn15_excess.json
holds one checked number, the total excess over CCN 15 in the whole tree,
sum of max(0, CCN - 15) (minus what recorded overrides let in), for the
gate's CI-side RATCHET. CCN is a signal for flagging a module, not a target
to obey: the excess falls when a big function is split honestly, so splits
pass and growth does not. Same life cycle as the debt baseline:
`--shrink-baseline` and the 2 AM nightly lower it, never raise it;
`--update-ccn15-excess` regenerates it deliberately.

Shrink guard: if more than half of the baseline (and more than 20 keys)
vanished in one run, that is far likelier a broken scan than a refactor, so
nothing is shrunk and the report says why.

Duplication: lizard's own `-Eduplicate` extension (pure Python, ~8 s extra),
reported as duplicate_rate_pct / duplicate_blocks. Trend only; not ratcheted.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from typing import Callable, Dict, Iterable, List, Optional, Sequence, Tuple

CCN_LIMIT = 15
NLOC_LIMIT = 80
FILE_LINES_LIMIT = 800
TOP_N = 15
# The blocking gate's lines (scripts/complexity_gate.py imports these: one
# definition, so the nightly ratchet and the gate can never disagree).
GATE_CCN = 30          # same as .swiftlint.yml cyclomatic_complexity: error
GATE_NLOC = 300        # same as .swiftlint.yml function_body_length: error
GATE_CCN_LINE = GATE_CCN

SWIFT_ROOTS = ("VideoScan/VideoScan", "VideoScan/VideoScanCore/Sources", "swift_cli")
# App code only (Rick 2026-10-06): test beds and support scripts are not measured.
PYTHON_ROOTS: tuple = ()
SKIP_DIRS = {".build", "build", "DerivedData", "checkouts", "node_modules",
             "__pycache__", ".venv", "venv", ".git", ".trash"}

DEFAULT_SEED = os.path.join("ci", "baselines", "complexity_debt.json")

# Shrink guard: refuse to rewrite the baseline when this much vanished at once.
SHRINK_GUARD_FRACTION = 0.5
SHRINK_GUARD_MIN = 20
# A moved offender may be this many lines longer than its baseline entry and
# still count as the same function (re-indent, an extracted helper's call).
MOVE_NLOC_SLACK = 5


# ---------------------------------------------------------------------------
# records

@dataclass
class Func:
    """One measured function. `key` is filled in by assign_keys()."""
    file: str           # repo-relative, forward slashes
    name: str
    long_name: str
    ccn: int
    nloc: int
    start_line: int
    lang: str           # "swift" | "python"
    container: str = "" # nearest enclosing type, best effort (see containers_for)
    end_line: int = 0
    parent: str = ""    # enclosing FUNCTION (e.g. the property owning a `get`)
    key: str = ""

    @property
    def display(self) -> str:
        """Type.parent.name: what a human reads, and the base of the key.
        (lizard already names nested Python functions `outer.inner`.)"""
        parent = "" if self.name.startswith(self.parent + ".") else self.parent
        return ".".join(x for x in (self.container, parent, self.name) if x)

    @property
    def bare_name(self) -> str:
        return self.name.rsplit(".", 1)[-1]

    @property
    def is_offender(self) -> bool:
        return self.ccn > CCN_LIMIT or self.nloc > NLOC_LIMIT


def lang_of(path: str) -> Optional[str]:
    if path.endswith(".swift"):
        return "swift"
    if path.endswith(".py"):
        return "python"
    return None


def folder_of(path: str) -> str:
    """Same buckets as swift_by_folder in scripts/collect_metrics.sh."""
    if path.startswith("VideoScan/VideoScanCore/"):
        return "Core"
    if path.startswith("swift_cli/"):
        return "swift_cli"
    if path.startswith("VideoScan/VideoScanTests/"):
        return "Tests"
    if path.startswith("VideoScan/VideoScan/"):
        rest = path[len("VideoScan/VideoScan/"):]
        return rest.split("/", 1)[0] if "/" in rest else "(app root)"
    return path.split("/", 1)[0]          # scripts, tools


def _norm(text: str) -> str:
    return re.sub(r"\s+", " ", text).strip()


def assign_keys(funcs: Sequence[Func]) -> None:
    """Give every function a stable identity within its file, no line numbers.

    file::Type.parent.name         always (the qualified name, `display`)
    file::Type.parent.long_name    only when that repeats in the file (overloads)
    file::...long_name#n           ordinal in source order, last resort

    A function's key never depends on whether some OTHER function with the
    same bare name exists elsewhere in the file (QA 2026-10-05: adding a small
    `body` to another type used to rename an untouched offender).
    """
    by_file: Dict[str, List[Func]] = {}
    for f in funcs:
        by_file.setdefault(f.file, []).append(f)
    for path, items in by_file.items():
        items = sorted(items, key=lambda f: f.start_line)
        quals: Dict[str, int] = {}
        for f in items:
            quals[f.display] = quals.get(f.display, 0) + 1
        longq = lambda f: f.display[: -len(f.name)] + (_norm(f.long_name) or f.name)
        longs: Dict[str, int] = {}
        for f in items:
            if quals[f.display] > 1:
                longs[longq(f)] = longs.get(longq(f), 0) + 1
        seen: Dict[str, int] = {}
        for f in items:
            if quals[f.display] == 1:
                f.key = f"{path}::{f.display}"
            elif longs[longq(f)] == 1:
                f.key = f"{path}::{longq(f)}"
            else:
                seen[longq(f)] = seen.get(longq(f), 0) + 1
                f.key = f"{path}::{longq(f)}#{seen[longq(f)]}"


def key_file(key: str) -> str:
    return key.split("::", 1)[0]


def key_bare_name(key: str) -> str:
    """`file::Type.prop.get` -> `get`; `file::Type.init x : Int#2` -> `init`."""
    rest = key.split("::", 1)[-1].split("#", 1)[0].split(" ", 1)[0]
    return rest.rsplit(".", 1)[-1]


def over_gate(f: Func) -> bool:
    return f.ccn > GATE_CCN or f.nloc > GATE_NLOC


def match_unknown(unknown: Sequence[Func], vanished: Dict[str, dict],
                  slack: int = MOVE_NLOC_SLACK) -> Dict[str, str]:
    """THE move matching, shared by the gate and the nightly ratchet (QA
    round 2: they used to differ, so a nightly shrink could hand a moved
    320-line function's old key to an unrelated mid-size `body`, and the next
    CI run read the big one as NEW). Functions over the GATE are matched
    first, exactly as the gate does it; report-level offenders only get what
    is left. Returns {new key: vanished baseline key}."""
    gate_level = [f for f in unknown if over_gate(f)]
    moves = match_moves(gate_level, vanished, slack)
    left = {k: v for k, v in vanished.items() if k not in set(moves.values())}
    rest = [f for f in unknown if not over_gate(f)]
    moves.update(match_moves(rest, left, slack))
    return moves


def match_moves(new: Sequence[Func], vanished: Dict[str, dict], slack: int) -> Dict[str, str]:
    """Pair NEW offenders with baseline offenders that disappeared, so a moved
    or rekeyed function that did not grow is recognised. Same bare name, CCN no
    higher, NLOC at most `slack` more. Biggest first, each baseline key once.
    Returns {new key: vanished baseline key}."""
    pool = dict(vanished)
    out: Dict[str, str] = {}
    for f in sorted(new, key=lambda f: (-f.ccn, -f.nloc, f.key)):
        fits = [k for k, v in pool.items()
                if key_bare_name(k) == f.bare_name and f.ccn <= v["ccn"] and f.nloc <= v["nloc"] + slack]
        if fits:
            # Prefer the same file, then the closest size.
            best = min(fits, key=lambda k: (key_file(k) != f.file, pool[k]["ccn"] - f.ccn, k))
            out[f.key] = best
            del pool[best]
    return out


_SWIFT_TYPE = re.compile(r"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|"
                         r"open|final|indirect|nonisolated)\s+)*(?:struct|class|enum|actor|extension|protocol)"
                         r"\s+([A-Za-z_][\w.]*)")
_PY_CLASS = re.compile(r"^(\s*)class\s+([A-Za-z_]\w*)")
_SWIFT_STRING = re.compile(r'"(?:\\.|[^"\\])*"')


def containers_for(source: str, lang: str) -> List[str]:
    """Per source line (1-based index), the innermost type enclosing the start
    of that line. Best effort and deliberately simple: Swift counts braces
    after a struct/class/enum/actor/extension line (string literals and //
    comments stripped first); Python takes the innermost `class` whose
    indentation is shallower than the line. Used only to tell apart functions
    whose names repeat in one file, and to make the top-15 readable."""
    out = [""]
    if lang == "swift":
        depth = 0
        stack: List[Tuple[str, int]] = []   # (type name, depth inside its body)
        pending = ""
        for line in source.split("\n"):
            m = _SWIFT_TYPE.match(line)
            if m:
                pending = m.group(1)
            out.append(stack[-1][0] if stack else "")
            code = _SWIFT_STRING.sub('""', line).split("//", 1)[0]
            for ch in code:
                if ch == "{":
                    depth += 1
                    if pending:
                        stack.append((pending, depth))
                        pending = ""
                elif ch == "}":
                    while stack and stack[-1][1] >= depth:
                        stack.pop()
                    depth = max(0, depth - 1)
        return out
    py_stack: List[Tuple[int, str]] = []
    for line in source.split("\n"):
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped and not stripped.startswith("#"):
            while py_stack and py_stack[-1][0] >= indent:
                py_stack.pop()
        out.append(py_stack[-1][1] if py_stack else "")
        m = _PY_CLASS.match(line)
        if m:
            py_stack.append((len(m.group(1)), m.group(2)))
    return out


def funcs_from_lizard(file_infos: Iterable, root: str,
                      sources: Optional[Dict[str, str]] = None) -> List[Func]:
    """Convert lizard FileInformation objects (duck-typed: .filename and
    .function_list of objects with name, long_name, cyclomatic_complexity,
    nloc, start_line) into keyed Func records. `sources` (repo-relative path
    -> text) lets repeated names be told apart by their enclosing type."""
    sources = sources or {}
    out: List[Func] = []
    root_abs = os.path.abspath(root)
    for info in file_infos:
        if info is None:
            continue
        path = info.filename
        if os.path.isabs(path):
            path = os.path.relpath(path, root_abs)
        path = path.replace(os.sep, "/")
        if path.startswith("./"):
            path = path[2:]
        lang = lang_of(path)
        if lang is None:
            continue
        owners = containers_for(sources[path], lang) if path in sources else []
        mine: List[Func] = []
        for fn in info.function_list:
            start = int(fn.start_line)
            mine.append(Func(file=path, name=str(fn.name), long_name=str(fn.long_name),
                             ccn=int(fn.cyclomatic_complexity), nloc=int(fn.nloc),
                             start_line=start, lang=lang,
                             container=owners[start] if 0 < start < len(owners) else "",
                             end_line=int(getattr(fn, "end_line", start) or start)))
        for f in mine:
            enclosing = [g for g in mine if g is not f and g.start_line <= f.start_line
                         and g.end_line >= f.end_line and (g.start_line, g.end_line) != (f.start_line, f.end_line)]
            if enclosing:
                f.parent = min(enclosing, key=lambda g: g.end_line - g.start_line).name
        out.extend(mine)
    assign_keys(out)
    return out


# ---------------------------------------------------------------------------
# aggregation

def _empty_bucket() -> dict:
    return {"files": 0, "functions": 0, "ccn_sum": 0, "ccn_over_15": 0, "ccn_over_30": 0,
            "nloc_over_80": 0, "offenders": 0, "files_over_800": 0}


def _finish(bucket: dict) -> dict:
    out = dict(bucket)
    ccn_sum = out.pop("ccn_sum")
    out["mean_ccn"] = round(ccn_sum / out["functions"], 2) if out["functions"] else None
    return out


def aggregate(funcs: Sequence[Func], file_lines: Dict[str, int],
              folder_fn: Callable[[str], str] = None) -> dict:
    """Per-folder and total numbers. `file_lines` maps every measured file
    (even ones with no functions) to its line count. `folder_fn` overrides
    the folder of a path (the backfill maps old flat layouts by file name)."""
    folder_fn = folder_fn or folder_of
    folders: Dict[str, Dict[str, dict]] = {"swift": {}, "python": {}}
    totals: Dict[str, dict] = {"swift": _empty_bucket(), "python": _empty_bucket(),
                               "all": _empty_bucket()}

    def buckets(path: str) -> List[dict]:
        lang = lang_of(path)
        folder = folders[lang].setdefault(folder_fn(path), _empty_bucket())
        return [folder, totals[lang], totals["all"]]

    for path, lines in file_lines.items():
        if lang_of(path) is None:
            continue
        for b in buckets(path):
            b["files"] += 1
            if lines > FILE_LINES_LIMIT:
                b["files_over_800"] += 1
    for f in funcs:
        for b in buckets(f.file):
            b["functions"] += 1
            b["ccn_sum"] += f.ccn
            b["ccn_over_15"] += f.ccn > CCN_LIMIT
            b["ccn_over_30"] += f.ccn > GATE_CCN_LINE
            b["nloc_over_80"] += f.nloc > NLOC_LIMIT
            b["offenders"] += f.is_offender
    return {
        "swift_by_folder": {k: _finish(v) for k, v in sorted(folders["swift"].items())},
        "python_by_folder": {k: _finish(v) for k, v in sorted(folders["python"].items())},
        "totals": {k: _finish(v) for k, v in totals.items()},
    }


def top_worst(funcs: Sequence[Func], limit: int = TOP_N) -> List[dict]:
    worst = sorted(funcs, key=lambda f: (-f.ccn, -f.nloc, f.file, f.key))[:limit]
    return [{"file": f.file, "function": f.display, "ccn": f.ccn, "nloc": f.nloc, "lang": f.lang}
            for f in worst]


# ---------------------------------------------------------------------------
# ratchet

def offenders(funcs: Sequence[Func]) -> Dict[str, Func]:
    return {f.key: f for f in funcs if f.is_offender}


def load_baseline(path: str) -> Dict[str, dict]:
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {str(k): {"ccn": int(v["ccn"]), "nloc": int(v["nloc"])}
            for k, v in data.get("entries", {}).items()}


def load_disables(path: str) -> Dict[str, int]:
    """Grandfathered `swiftlint:disable` counts, {"file|rule": count}."""
    if not path or not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {str(k): int(v) for k, v in data.get("swiftlint_disables", {}).items()}


# The SwiftLint size/complexity rules whose disabling the gate refuses.
GUARDED_RULES = ("cyclomatic_complexity", "function_body_length", "file_length", "type_body_length")
_DISABLE = re.compile(r"swiftlint:disable(?::next|:this|:previous)?\b([^\n]*)")


def count_disables(path: str, source: str) -> Dict[str, int]:
    """{"file|rule": n} for every swiftlint:disable of a guarded rule."""
    out: Dict[str, int] = {}
    if not path.endswith(".swift"):
        return out
    for m in _DISABLE.finditer(source):
        rules = set(re.findall(r"[a-z_]+", m.group(1)))
        for rule in GUARDED_RULES:
            if rule in rules or "all" in rules:
                key = f"{path}|{rule}"
                out[key] = out.get(key, 0) + 1
    return out


def write_baseline(path: str, entries: Dict[str, dict],
                   disables: Optional[Dict[str, int]] = None) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    payload = {
        "note": ("Complexity debt baseline: functions with CCN > "
                 f"{CCN_LIMIT} or NLOC > {NLOC_LIMIT}, keyed file::function (no "
                 "line numbers), plus grandfathered swiftlint:disable counts for "
                 "the size/complexity rules. The nightly REPORTS offenders not on "
                 "this list; the pre-commit hook and CI preflight BLOCK new or "
                 "worse functions over the gate limits (scripts/complexity_gate.py). "
                 "It only shrinks (`--shrink-baseline`); regrow it deliberately with "
                 "`scripts/complexity_metrics.py --update-baseline` and say why in "
                 "the commit."),
        "thresholds": {"ccn": CCN_LIMIT, "nloc": NLOC_LIMIT},
        "entry_count": len(entries),
        "entries": {k: {"ccn": v["ccn"], "nloc": v["nloc"]} for k, v in sorted(entries.items())},
        "swiftlint_disables": dict(sorted((disables or {}).items())),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=1)
        handle.write("\n")


def got_worse(cur: Func, base: dict) -> bool:
    if cur.ccn > base["ccn"]:
        return True
    return cur.nloc - base["nloc"] > max(5, base["nloc"] * 0.10)


def ratchet(funcs: Sequence[Func], baseline: Dict[str, dict]) -> dict:
    """Compare tonight's offenders with the baseline. Pure; writes nothing.

    Returns {"new", "worse", "fixed", "next_baseline", "shrink_skipped"}.
    `next_baseline` is the baseline with fixed keys dropped and improved
    values lowered — never with anything added or raised."""
    current = offenders(funcs)
    unmatched_new = [f for k, f in current.items() if k not in baseline]
    vanished = {k: v for k, v in baseline.items() if k not in current}
    # A moved / rekeyed offender that did not grow is neither NEW nor FIXED:
    # its baseline entry follows it to the new key.
    moves = match_unknown(unmatched_new, vanished, MOVE_NLOC_SLACK)
    new = sorted((f for f in unmatched_new if f.key not in moves),
                 key=lambda f: (-f.ccn, -f.nloc, f.key))
    worse = sorted((f for k, f in current.items() if k in baseline and got_worse(f, baseline[k])),
                   key=lambda f: (-f.ccn, -f.nloc, f.key))
    moved_from = set(moves.values())
    fixed = sorted(k for k in vanished if k not in moved_from)

    nxt: Dict[str, dict] = {}
    for key, base in baseline.items():
        cur = current.get(key)
        if cur is None:
            continue
        nxt[key] = {"ccn": min(base["ccn"], cur.ccn), "nloc": min(base["nloc"], cur.nloc)}
    for new_key, old_key in moves.items():
        cur, base = current[new_key], baseline[old_key]
        nxt[new_key] = {"ccn": min(base["ccn"], cur.ccn), "nloc": min(base["nloc"], cur.nloc)}

    shrink_skipped = None
    if not funcs:
        shrink_skipped = "no functions measured: the scan found nothing"
    elif len(fixed) > SHRINK_GUARD_MIN and len(fixed) > SHRINK_GUARD_FRACTION * len(baseline):
        shrink_skipped = (f"{len(fixed)} of {len(baseline)} baseline entries vanished in one run: "
                          "more likely a broken scan than a refactor")
    if shrink_skipped:
        nxt = dict(baseline)
    return {"new": new, "worse": worse, "fixed": fixed, "next_baseline": nxt,
            "shrink_skipped": shrink_skipped, "moved": moves}


def _fdict(f: Func, base: Optional[dict] = None) -> dict:
    d = {"key": f.key, "file": f.file, "function": f.display, "ccn": f.ccn, "nloc": f.nloc, "lang": f.lang}
    if base is not None:
        d["base_ccn"], d["base_nloc"] = base["ccn"], base["nloc"]
    return d


def debt_report(result: dict, baseline: Dict[str, dict], offender_count: int,
                ts: str, sha: str, overrides: Optional[List[dict]] = None,
                override_total: int = 0) -> dict:
    return {
        "overrides_recent": overrides or [],
        "overrides_total": override_total,
        "ts": ts, "sha": sha,
        "thresholds": {"ccn": CCN_LIMIT, "nloc": NLOC_LIMIT},
        "offenders": offender_count,
        "baseline_before": len(baseline),
        "baseline_after": len(result["next_baseline"]),
        "new": [_fdict(f) for f in result["new"]],
        "worse": [_fdict(f, baseline[f.key]) for f in result["worse"]],
        "fixed": result["fixed"],
        "shrink_skipped": result["shrink_skipped"],
    }


def alert_lines(debt: dict, limit: int = 10) -> List[str]:
    """Morning-digest lines (Rick 2026-10-05: nothing gets quietly baselined).
    🔴 for every NEW or WORSE offender, listed for Rick's decision, and 🔴 for
    every gate override with its function, CCN, lines, reason, commit and
    author. Empty when there is nothing to decide."""
    new, worse = debt.get("new") or [], debt.get("worse") or []
    lines: List[str] = []
    for rec in debt.get("overrides_recent") or []:
        lines.append(f"🔴 Complexity gate OVERRIDDEN {str(rec.get('ts', ''))[:16]} by "
                     f"{rec.get('author') or 'unknown author'} in commit {rec.get('commit') or 'unknown'}: "
                     f"\"{rec.get('reason', '')}\"")
        for f in rec.get("function_details") or []:
            lines.append(f"   CCN {f.get('ccn')!s:>3} NLOC {f.get('nloc')!s:>4}  "
                         f"{os.path.basename(f.get('file', ''))} :: {f.get('function')}")
        for d in rec.get("disables") or []:
            lines.append(f"   swiftlint:disable {d.split('|', 1)[-1]} in {os.path.basename(d.split('|', 1)[0])}")
    if new or worse:
        lines.append(f"🔴 Complexity debt ({str(debt.get('ts', ''))[:10]}): "
                     f"{len(new)} NEW offender(s), {len(worse)} got worse "
                     f"(CCN > {CCN_LIMIT} or NLOC > {NLOC_LIMIT}) — Rick's decision: split it, "
                     "or accept it with `--update-baseline` and say why in the commit")
        for f in (new + worse)[:limit]:
            tag = "new  " if f in new else "worse"
            was = f" (was {f['base_ccn']}/{f['base_nloc']})" if "base_ccn" in f else ""
            lines.append(f"   {tag} CCN {f['ccn']:>3} NLOC {f['nloc']:>4}  "
                         f"{os.path.basename(f['file'])} :: {f['function']}{was}")
        extra = len(new) + len(worse) - limit
        if extra > 0:
            lines.append(f"   … and {extra} more in metrics/complexity_debt_latest.json")
    if debt.get("fixed"):
        lines.append(f"✅ Complexity debt: {len(debt['fixed'])} baseline offender(s) fixed "
                     "(the 2 AM nightly commits the shrunk baseline).")
    if debt.get("shrink_skipped"):
        lines.append(f"⚠️  Complexity baseline not shrunk: {debt['shrink_skipped']}")
    return lines


def markdown_report(row: dict, debt: dict) -> str:
    t = row["totals"]
    lines = ["## Complexity and debt (report only)", "",
             "| | Swift | Python |", "|---|---:|---:|"]
    for label, key in (("Functions", "functions"), ("Mean CCN", "mean_ccn"),
                       (f"CCN > {CCN_LIMIT}", "ccn_over_15"), (f"NLOC > {NLOC_LIMIT}", "nloc_over_80"),
                       (f"Files > {FILE_LINES_LIMIT} lines", "files_over_800")):
        lines.append(f"| {label} | {t['swift'][key]} | {t['python'][key]} |")
    if row.get("duplicate_rate_pct") is not None:
        lines.append(f"| Duplicate code (lizard -Eduplicate) | {row['duplicate_rate_pct']}% "
                     f"({row['duplicate_blocks']} blocks, both languages) | |")
    lines += ["", f"Debt ratchet: **{len(debt['new'])} new**, **{len(debt['worse'])} worse**, "
                  f"{len(debt['fixed'])} fixed; baseline {debt['baseline_before']} → {debt['baseline_after']}.", ""]
    if debt.get("shrink_skipped"):
        lines += [f"⚠️ Baseline not shrunk: {debt['shrink_skipped']}", ""]
    for rec in debt.get("overrides_recent") or []:
        lines += [f"🟠 Gate overridden {rec.get('ts')}: \"{rec.get('reason', '')}\" — "
                  f"{', '.join((rec.get('functions') or []) + (rec.get('disables') or []))}", ""]
    for title, items in (("New offenders", debt["new"]), ("Worse than baseline", debt["worse"])):
        if items:
            lines += [f"<details open><summary>{title} ({len(items)})</summary>", "", "```"]
            lines += [f"CCN {f['ccn']:>3} NLOC {f['nloc']:>4}  {f['file']} :: {f['function']}" for f in items[:50]]
            lines += ["```", "", "</details>", ""]
    lines += ["| # | CCN | NLOC | Function | File |", "|---:|---:|---:|---|---|"]
    for i, f in enumerate(row["top15"], 1):
        lines.append(f"| {i} | {f['ccn']} | {f['nloc']} | `{f['function']}` | `{f['file']}` |")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Swift regex literals (pure; runs before lizard sees a Swift file)
#
# lizard's Swift reader predates Swift 5.7 regex literals. Inside
# `/\b(?:get|fetch)\b/` it sees `get` as a property accessor and splits or
# merges functions around it (cloud review N1007: `isFetchClause.get` CCN 93
# was three functions of 7, 11 and 10; `detectShape` lost 74 lines). So every
# regex literal becomes `""` plus the newlines it spanned: same line count,
# so line numbers stay true. A small tokenizer (strings, raw strings,
# interpolation, nested block comments) decides what is code, then Swift's own
# rule decides what is a bare regex: `/` where an expression starts, not
# followed by `/` or `*`, not starting or ending with a space or tab, closed
# on the same line. Anything else is the division operator and is untouched.
#
# The same tokenizer fixes lizard's other `#` blind spot: its tokenizer reads
# every `#` as a C preprocessor line and drops the REST OF THE LINE, so
# `.range(of: #"\b"#) != nil }` lost its closing brace and
# `if #available(macOS 26, *) {` its opening one, and the functions around
# them ended in the wrong place. Raw strings (`#"…"#`, `#"""…"""#`) become
# `""` plus their newlines, and a `#` that is not a line-leading compiler
# directive (`#available`, `#selector`, `#Preview`, `#file`) becomes a space.
# `#if` / `#else` / `#endif` lines are left for lizard to skip as before.

_SWIFT_DIRECTIVES = frozenset({"if", "elseif", "else", "endif", "warning", "error",
                               "sourceLocation"})
_SWIFT_EXPR_KEYWORDS = frozenset({
    "return", "case", "in", "where", "if", "guard", "while", "try", "await",
    "throw", "throws", "else", "switch", "repeat", "is", "as", "yield", "then",
    "some", "any", "do", "catch", "default",
})
_SWIFT_WORD = re.compile(r"[A-Za-z0-9_$@`\u0080-\U0010ffff]+")


def swift_lizard_spans(src: str) -> List[Tuple[int, int, str]]:
    """(start, end, kind) of everything lizard misreads in Swift source:
    "regex" (a regex literal), "raw" (a raw string literal) or "hash" (one
    `#` that is not part of a line-leading compiler directive)."""
    n = len(src)
    spans: List[Tuple[int, int, str]] = []

    def skip_block_comment(i: int) -> int:          # src[i:i+2] == "/*"
        depth, i = 1, i + 2
        while i < n and depth:
            if src.startswith("/*", i):
                depth, i = depth + 1, i + 2
            elif src.startswith("*/", i):
                depth, i = depth - 1, i + 2
            else:
                i += 1
        return i

    def skip_string(i: int, hashes: int) -> int:     # src[i] == '"' after `hashes` #s
        quotes = 3 if src.startswith('"""', i) else 1
        close = '"' * quotes + "#" * hashes
        escape = "\\" + "#" * hashes
        i += quotes
        while i < n:
            if src.startswith(escape, i):
                j = i + len(escape)
                if j < n and src[j] == "(":
                    i = scan(j + 1, nested=True)
                else:
                    i = j + 1
            elif src.startswith(close, i):
                return i + len(close)
            elif src[i] == "\n" and quotes == 1:
                return i                              # unterminated: stop at the line
            else:
                i += 1
        return n

    def bare_regex_end(i: int) -> int:               # src[i] == "/"; -1 if not a regex
        if i + 1 >= n or src[i + 1] in " \t\n\r/*":
            return -1
        j, klass = i + 1, 0
        while j < n and src[j] != "\n":
            ch = src[j]
            if ch == "\\":
                j += 2
                continue
            if ch == "[":
                klass += 1
            elif ch == "]" and klass:
                klass -= 1
            elif ch == "/" and not klass:
                return -1 if src[j - 1] in " \t" else j + 1
            j += 1
        return -1

    def extended_regex_end(i: int, hashes: int) -> int:   # src[i] == "/" after the #s
        close = "/" + "#" * hashes
        j = i + 1
        multi = src[j:].split("\n", 1)[0].strip() == ""
        while j < n:
            if src[j] == "\\":
                j += 2
                continue
            if src.startswith(close, j):
                return j + len(close)
            if src[j] == "\n" and not multi:
                return -1
            j += 1
        return -1

    def scan(i: int, nested: bool = False) -> int:
        prev = "start"          # start | op (an expression may start) | value
        parens = 0
        while i < n:
            c = src[i]
            if c in " \t\r\n":
                i += 1
                continue
            if src.startswith("//", i):
                nl = src.find("\n", i)
                i = n if nl < 0 else nl
                continue
            if src.startswith("/*", i):
                i = skip_block_comment(i)
                continue
            if c == '"':
                i, prev = skip_string(i, 0), "value"
                continue
            if c == "#":
                j = i
                while j < n and src[j] == "#":
                    j += 1
                if j < n and src[j] == '"':
                    end = skip_string(j, j - i)
                    spans.append((i, end, "raw"))
                    i, prev = end, "value"
                    continue
                if j < n and src[j] == "/":
                    end = extended_regex_end(j, j - i)
                    if end > 0:
                        spans.append((i, end, "regex"))
                        i, prev = end, "value"
                        continue
                m = _SWIFT_WORD.match(src, j)
                line_start = src.rfind("\n", 0, i) + 1
                directive = (j == i + 1 and m is not None and m.group(0) in _SWIFT_DIRECTIVES
                             and not src[line_start:i].strip())
                if not directive:
                    spans.extend((k, k + 1, "hash") for k in range(i, j))
                i, prev = (m.end() if m else j), "value"     # #available(...), #selector(...)
                continue
            if c == "/":
                end = bare_regex_end(i) if prev != "value" else -1
                if end > 0:
                    spans.append((i, end, "regex"))
                    i, prev = end, "value"
                else:
                    i, prev = i + 1, "op"
                continue
            m = _SWIFT_WORD.match(src, i)
            if m:
                prev = "op" if m.group(0) in _SWIFT_EXPR_KEYWORDS else "value"
                i = m.end()
                continue
            if c == "(":
                parens += 1
                prev = "op"
            elif c == ")":
                if nested and parens == 0:
                    return i + 1                    # end of a string interpolation
                parens -= 1
                prev = "value"
            elif c in "]}":
                prev = "value"
            elif c in "!?" and prev == "value" and i and src[i - 1] not in " \t\r\n":
                pass                                # postfix: x! / y, opt? / y
            else:
                prev = "op"
            i += 1
        return n

    scan(0)
    return spans


def swift_regex_literal_spans(src: str) -> List[Tuple[int, int]]:
    """[start, end) offsets of every regex literal in Swift source."""
    return [(a, b) for a, b, kind in swift_lizard_spans(src) if kind == "regex"]


def neutralize_swift_for_lizard(src: str) -> str:
    """Swift source as lizard can read it: every regex and raw string literal
    replaced by `""` plus the newlines it spanned, every non-directive `#` by
    a space. Same line count, so every line number stays where it was."""
    spans = swift_lizard_spans(src)
    if not spans:
        return src
    out, last = [], 0
    for start, end, kind in spans:
        out.append(src[last:start])
        out.append(" " if kind == "hash" else '""' + "\n" * src.count("\n", start, end))
        last = end
    out.append(src[last:])
    return "".join(out)


# ---------------------------------------------------------------------------
# scanning (needs lizard; everything above is pure)

_SWIFT_DECL_WORDS = frozenset({"init", "subscript", "get", "set", "willSet", "didSet", "deinit"})


def install_swift_property_support() -> None:
    """Teach lizard's Swift reader that `var NAME ... {` on one line is a
    function named NAME (computed property / SwiftUI body), and that
    `.init` / `.get` after a dot (`map(String.init)`) is a member reference,
    not the start of an initializer or accessor (stock lizard opened a
    function there and swallowed the rest of the body: cloud review N1007,
    `HalliePersonaQuestion.init` was really `detect`). Idempotent."""
    from lizard_languages.swift import SwiftStates
    if getattr(SwiftStates, "_videoscan_props", False):
        return
    original = SwiftStates._state_global

    def _state_global(self, token):
        if token in _SWIFT_DECL_WORDS and self.last_token == ".":
            return      # `String.init`, `cache.get(k)`: a member reference, not a declaration
        if token == "var":
            self._vs_line = self.context.current_line
            self._state = self._vs_var_name
            return
        original(self, token)

    def _vs_var_name(self, token):
        if re.fullmatch(r"`?\w+`?", token):
            self._vs_name = token.strip("`")
            self._state = self._vs_after_var_name
        else:                       # tuple pattern etc.: not ours
            self._state = self._state_global
            self._state_global(token)

    def _vs_after_var_name(self, token):
        if self.context.current_line != self._vs_line or token in ("=", "in", ";", ",", "}", "var", "let"):
            self._state = self._state_global
            self._state_global(token)
        elif token == "{":
            self.context.push_new_function(self._vs_name)
            self.next(self._function_impl, token)

    SwiftStates._state_global = _state_global
    SwiftStates._vs_var_name = _vs_var_name
    SwiftStates._vs_after_var_name = _vs_after_var_name
    SwiftStates._videoscan_props = True


def list_files(root: str) -> List[str]:
    """Repo-relative production files. git ls-files when possible."""
    roots = SWIFT_ROOTS + PYTHON_ROOTS
    paths: List[str] = []
    try:
        out = subprocess.run(["git", "-C", root, "ls-files", "-z", "--", *roots],
                             capture_output=True, check=True)
        paths = [p for p in out.stdout.decode("utf-8", "replace").split("\0") if p]
    except (OSError, subprocess.CalledProcessError):
        for top in roots:
            for dirpath, dirnames, filenames in os.walk(os.path.join(root, top)):
                dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS and not d.startswith("venv")]
                for name in filenames:
                    paths.append(os.path.relpath(os.path.join(dirpath, name), root).replace(os.sep, "/"))
    return sorted(p for p in paths if in_scope(p))


def in_scope(path: str) -> bool:
    """Production Swift / Python under the measured roots, outside build dirs,
    venvs and checkouts. (`VideoScan/VideoScan/` with the slash, so
    VideoScanTests is out.)"""
    parts = path.split("/")
    if any(seg in SKIP_DIRS or seg.startswith("venv") for seg in parts[:-1]):
        return False
    lang = lang_of(path)
    if lang == "swift":
        return path.startswith(tuple(r + "/" for r in SWIFT_ROOTS))
    if lang == "python":
        return path.startswith(tuple(r + "/" for r in PYTHON_ROOTS))
    return False


def analyze_sources(sources: Dict[str, str], root: str = ".",
                    duplication: bool = False) -> Tuple[List[Func], Optional[dict]]:
    """lizard over {repo-relative path: text}. Used by the nightly (whole
    tree, files on disk) and the pre-commit gate (STAGED blobs)."""
    import lizard
    install_swift_property_support()
    sources = {rel: (neutralize_swift_for_lizard(text) if lang_of(rel) == "swift" else text)
               for rel, text in sources.items()}
    dup = None
    if duplication:
        from lizard_ext.lizardduplicate import LizardExtension as Duplicates
        dup = Duplicates()
        analyzer = lizard.FileAnalyzer(lizard.get_extensions([dup]))
    else:
        analyzer = lizard.analyze_file
    infos = [analyzer.analyze_source_code(rel, text) for rel, text in sources.items()]
    stats = None
    if dup is not None:
        infos = list(dup.cross_file_process(infos))
        blocks = list(dup.get_duplicates())
        rate = dup.duplicate_rate()
        stats = {"duplicate_blocks": len(blocks),
                 "duplicate_rate_pct": round(rate * 100, 2) if isinstance(rate, (int, float)) else None}
    return funcs_from_lizard(infos, root, sources), stats


def read_tree(root: str) -> Dict[str, str]:
    sources: Dict[str, str] = {}
    for rel in list_files(root):
        try:
            with open(os.path.join(root, rel), "r", encoding="utf-8", errors="replace") as handle:
                sources[rel] = handle.read()
        except OSError:
            continue
    return sources


def scan(root: str, duplication: bool = False) -> Tuple[List[Func], Dict[str, int], dict]:
    """Whole-tree scan. Returns (funcs, file line counts, extras) where extras
    holds the swiftlint-disable counts and, if asked, duplication stats
    (lizard's own -Eduplicate: pure Python, ~10 s on this tree)."""
    sources = read_tree(root)
    funcs, dup = analyze_sources(sources, root, duplication)
    disables: Dict[str, int] = {}
    for rel, text in sources.items():
        disables.update(count_disables(rel, text))
    file_lines = {rel: text.count("\n") for rel, text in sources.items()}
    return funcs, file_lines, {"disables": disables, "duplication": dup}


# ---------------------------------------------------------------------------
# overrides (written by the pre-commit gate; read by CI and the nightly)

DEFAULT_OVERRIDES = os.path.join("ci", "baselines", "complexity_overrides.jsonl")


def load_overrides(path: str) -> List[dict]:
    if not path or not os.path.exists(path):
        return []
    out = []
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except ValueError:
                continue
            if isinstance(rec, dict):
                out.append(rec)
    return out


def override_allowances(records: Sequence[dict]) -> Tuple[Dict[str, dict], Dict[str, int]]:
    """What overrides have let through so far: per function the highest
    CCN/NLOC accepted, per file|rule the highest disable count accepted."""
    keys: Dict[str, dict] = {}
    disables: Dict[str, int] = {}
    for rec in records:
        for key, v in (rec.get("functions") or {}).items():
            cur = keys.setdefault(key, {"ccn": 0, "nloc": 0})
            cur["ccn"] = max(cur["ccn"], int(v.get("ccn", 0)))
            cur["nloc"] = max(cur["nloc"], int(v.get("nloc", 0)))
        for key, n in (rec.get("disables") or {}).items():
            disables[key] = max(disables.get(key, 0), int(n))
    return keys, disables


def recent_overrides(records: Sequence[dict], now: _dt.datetime, hours: float = 48) -> List[dict]:
    out = []
    for rec in records:
        try:
            ts = _dt.datetime.strptime(str(rec.get("ts")), "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=_dt.timezone.utc)
        except ValueError:
            continue
        if (now - ts).total_seconds() <= hours * 3600:
            funcs = rec.get("functions") or {}
            out.append({"ts": rec.get("ts"), "reason": rec.get("reason", ""),
                        "author": rec.get("author", ""), "commit": rec.get("commit", ""),
                        "functions": sorted(funcs.keys()),
                        "function_details": [{"key": k, "file": key_file(k),
                                              "function": k.split("::", 1)[-1],
                                              "ccn": v.get("ccn"), "nloc": v.get("nloc")}
                                             for k, v in sorted(funcs.items())],
                        "disables": sorted((rec.get("disables") or {}).keys())})
    return out


def resolve_override_commits(records: List[dict], root: str, overrides_rel: str) -> None:
    """Fill `commit` on each override record: the commit that added its line
    to the override log (the hook cannot know its own commit's SHA). Needs
    history (the nightly job checks out with fetch-depth 0). Best effort."""
    for rec in records:
        if rec.get("commit") or not rec.get("ts"):
            continue
        try:
            out = subprocess.run(["git", "-C", root, "log", "--format=%h", "-S", f'"ts":"{rec["ts"]}"',
                                  "--", overrides_rel], capture_output=True, text=True, check=True).stdout
            shas = out.split()
            rec["commit"] = shas[-1] if shas else "not committed yet"
        except (OSError, subprocess.CalledProcessError):
            rec["commit"] = "unknown"


def build_row(funcs: Sequence[Func], file_lines: Dict[str, int], debt: dict,
              ts: str, sha: str, lizard_version: Optional[str],
              duplication: Optional[dict] = None) -> dict:
    agg = aggregate(funcs, file_lines)
    dup = duplication or {}
    return {
        "ts": ts, "sha": sha, "run_kind": "nightly",
        "lizard_version": lizard_version,
        "thresholds": {"ccn": CCN_LIMIT, "nloc": NLOC_LIMIT, "file_lines": FILE_LINES_LIMIT},
        **agg,
        "top15": top_worst(funcs),
        "debt_offenders": debt["offenders"],
        "debt_baseline": debt["baseline_after"],
        "debt_new": len(debt["new"]),
        "debt_worse": len(debt["worse"]),
        "debt_fixed": len(debt["fixed"]),
        "gate_overrides_recent": len(debt.get("overrides_recent") or []),
        "duplicate_rate_pct": dup.get("duplicate_rate_pct"),
        "duplicate_blocks": dup.get("duplicate_blocks"),
    }


def shrink_disables(baseline: Dict[str, int], current: Dict[str, int]) -> Dict[str, int]:
    """Grandfathered disables only shrink, per RULE: a rule's entries are
    lowered only when the whole tree now has fewer of that rule than the
    baseline allows, and never below what the tree really has. (A disable
    that moved with its function keeps its old file's allowance; the gate
    counts per rule across the touched files.)"""
    def total(counts: Dict[str, int], rule: str) -> int:
        return sum(n for k, n in counts.items() if k.split("|", 1)[1] == rule)
    out = dict(baseline)
    for rule in {k.split("|", 1)[1] for k in baseline}:
        have, allowed = total(current, rule), total(baseline, rule)
        if have >= allowed:
            continue
        excess = allowed - have
        # Drop allowances from files that no longer use them first.
        for k in sorted((k for k in baseline if k.split("|", 1)[1] == rule),
                        key=lambda k: (current.get(k, 0) - baseline[k], k)):
            if excess <= 0:
                break
            cut = min(excess, max(0, out[k] - current.get(k, 0)))
            out[k] -= cut
            excess -= cut
            if out[k] <= 0:
                out.pop(k)
    return out


def strict_shrink(baseline: Dict[str, dict], result: dict) -> Dict[str, dict]:
    """The baseline the nightly may COMMIT: removals and lowerings only. A
    moved offender keeps its OLD key (the gate matches moves), so nothing is
    ever added."""
    if result.get("shrink_skipped"):
        return dict(baseline)
    out = {k: v for k, v in result["next_baseline"].items() if k in baseline}
    for new_key, old_key in (result.get("moved") or {}).items():
        cur = result["next_baseline"].get(new_key, baseline[old_key])
        out[old_key] = {"ccn": min(baseline[old_key]["ccn"], cur["ccn"]),
                        "nloc": min(baseline[old_key]["nloc"], cur["nloc"])}
    return out


def verify_removals_only(old: Dict[str, dict], new: Dict[str, dict],
                         old_dis: Dict[str, int], new_dis: Dict[str, int]) -> List[str]:
    """Why a baseline change is NOT a pure shrink. Empty = safe to commit."""
    problems = [f"adds {k}" for k in sorted(set(new) - set(old))]
    for k in sorted(set(new) & set(old)):
        for field in ("ccn", "nloc"):
            if new[k][field] > old[k][field]:
                problems.append(f"raises {field} of {k}: {old[k][field]} -> {new[k][field]}")
    problems += [f"adds disable {k}" for k in sorted(set(new_dis) - set(old_dis))]
    problems += [f"raises disable {k}: {old_dis[k]} -> {new_dis[k]}"
                 for k in sorted(set(new_dis) & set(old_dis)) if new_dis[k] > old_dis[k]]
    return problems


def shrink_plan(root: str, baseline_path: str) -> dict:
    """Scan `root`, compute the removals-only baseline and verify it.
    {"changed", "problems", "entries", "disables", "fixed", "before", "after"}."""
    funcs, _, extras = scan(root)
    baseline = load_baseline(baseline_path)
    base_dis = load_disables(baseline_path)
    result = ratchet(funcs, baseline)
    if result["shrink_skipped"]:
        return {"changed": False, "problems": [f"shrink guard: {result['shrink_skipped']}"],
                "entries": baseline, "disables": base_dis, "fixed": [], "before": len(baseline),
                "after": len(baseline)}
    shrunk = strict_shrink(baseline, result)
    dis = shrink_disables(base_dis, extras["disables"])
    return {"changed": shrunk != baseline or dis != base_dis,
            "problems": verify_removals_only(baseline, shrunk, base_dis, dis),
            "entries": shrunk, "disables": dis, "fixed": result["fixed"],
            "before": len(baseline), "after": len(shrunk)}


# ---------------------------------------------------------------------------
# CCN 15 EXCESS ratchet (Rick 2026-10-07): the whole-tree side of the gate's
# RATCHET. CCN is one signal for flagging a module, not a target to obey, so
# what is ratcheted is the complexity ABOVE the line, not the number of
# functions over it: excess(f) = max(0, CCN - 15), summed. Splitting a CCN-52
# function into two honest 26s lowers it (37 -> 22) and passes; growing a
# function above 15, or adding one, raises it.
#
# One number is checked (`total_excess`, minus the excess recorded overrides
# let in); `files` is a per-file excess snapshot written alongside it so a CI
# failure can say which files grew. Only `total_excess` is ratcheted, and
# only ever down.

DEFAULT_CCN15_EXCESS = os.path.join("ci", "baselines", "complexity_ccn15_excess.json")


def excess(f: Func) -> int:
    """How far a function is above the CCN 15 line (0 at or below it)."""
    return max(0, f.ccn - CCN_LIMIT)


def excess_by_file(funcs: Sequence[Func]) -> Dict[str, int]:
    """{file: total excess over CCN 15}, files with none left out."""
    out: Dict[str, int] = {}
    for f in funcs:
        if excess(f):
            out[f.file] = out.get(f.file, 0) + excess(f)
    return dict(sorted(out.items()))


def excess_allowances(records: Sequence[dict]) -> Dict[str, dict]:
    """What overrides let in, per function: the highest CCN recorded and the
    total excess the overrides added (`ratchet_excess`; a record without
    that field gives no excess credit)."""
    out: Dict[str, dict] = {}
    for rec in records:
        for key, n in (rec.get("ratchet_excess") or {}).items():
            cur = out.setdefault(key, {"ccn": 0, "excess": 0})
            cur["excess"] += int(n)
            cur["ccn"] = max(cur["ccn"], int(((rec.get("functions") or {}).get(key) or {}).get("ccn", 0)))
    return out


def excess_override_credit(funcs: Sequence[Func], allowed: Dict[str, dict]) -> int:
    """Excess a recorded override let in, for functions still at or below
    the CCN it recorded (growing past it loses the credit)."""
    return sum(min(allowed[f.key]["excess"], excess(f)) for f in funcs
               if excess(f) and f.key in allowed and f.ccn <= allowed[f.key]["ccn"])


def excess_total(funcs: Sequence[Func], allowed: Dict[str, dict]) -> int:
    return sum(excess(f) for f in funcs) - excess_override_credit(funcs, allowed)


def load_ccn15_excess(path: str) -> Optional[dict]:
    """{"total_excess": int, "files": {file: excess}}, or None when there is no such file."""
    if not path or not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    return {"total_excess": int(data["total_excess"]),
            "files": {str(k): int(v) for k, v in (data.get("files") or {}).items()}}


def write_ccn15_excess(path: str, total_excess: int, files: Dict[str, int]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    payload = {
        "note": (f"CCN {CCN_LIMIT} excess ratchet (Rick 2026-10-07): CI preflight "
                 "(scripts/complexity_gate.py --all) fails when the tree's total excess, "
                 f"the sum of max(0, CCN - {CCN_LIMIT}) over every function, is above "
                 "`total_excess` (excess a recorded override let in is not counted). CCN "
                 "is a signal, not the goal. `files` is a per-file snapshot for the error "
                 "message only. `total_excess` only shrinks: the 2 AM nightly lowers it; "
                 "regenerate deliberately with `scripts/complexity_metrics.py "
                 "--update-ccn15-excess` and say why in the commit."),
        "threshold_ccn": CCN_LIMIT,
        "total_excess": int(total_excess),
        "files": dict(sorted(files.items())),
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=1)
        handle.write("\n")


def ccn15_excess_shrink_plan(root: str, excess_path: str, overrides_path: str,
                             funcs: Optional[Sequence[Func]] = None) -> dict:
    """The total excess the nightly may commit: today's, if lower; never
    higher. {"changed", "problems", "before", "after", "files"}. Same
    broken-scan guard as the debt baseline: nothing measured, or more than
    half gone at once (and more than SHRINK_GUARD_MIN), is refused."""
    old = load_ccn15_excess(excess_path)
    if old is None:
        return {"changed": False, "problems": [f"no {excess_path}"], "before": None, "after": None, "files": {}}
    if funcs is None:
        funcs = scan(root)[0]
    was = old["total_excess"]
    keep = {"changed": False, "before": was, "after": was, "files": old["files"]}
    if not funcs:
        return {**keep, "problems": ["shrink guard: no functions measured: the scan found nothing"]}
    now = excess_total(funcs, excess_allowances(load_overrides(overrides_path)))
    drop = was - now
    if drop > SHRINK_GUARD_MIN and drop > SHRINK_GUARD_FRACTION * was:
        return {**keep, "problems": [f"shrink guard: CCN {CCN_LIMIT} excess {was} -> {now} in one run: "
                                     "more likely a broken scan than a refactor"]}
    if now >= was:
        return {**keep, "problems": []}
    return {"changed": True, "problems": [], "before": was, "after": now, "files": excess_by_file(funcs)}


def _set_output(name: str, value) -> None:
    target = os.environ.get("GITHUB_OUTPUT")
    if target:
        with open(target, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--baseline", default=DEFAULT_SEED,
                        help="the committed baseline (default ci/baselines/complexity_debt.json)")
    parser.add_argument("--baseline-out", default="",
                        help="also write the proposed shrunk baseline here (the nightly publishes it)")
    parser.add_argument("--row-out", default="", help="metrics row (one JSON line); default stdout")
    parser.add_argument("--debt-out", default="", help="new/worse/fixed report JSON")
    parser.add_argument("--update-baseline", action="store_true",
                        help="rewrite --baseline from today's offenders (deliberate re-baseline)")
    parser.add_argument("--shrink-baseline", action="store_true",
                        help="drop fixed entries from --baseline and lower improved ones; never adds")
    parser.add_argument("--overrides", default=DEFAULT_OVERRIDES,
                        help="gate override log (repo-relative), reported by the nightly")
    parser.add_argument("--ccn15-excess", default=DEFAULT_CCN15_EXCESS,
                        help="the CCN 15 excess baseline CI checks (default ci/baselines/complexity_ccn15_excess.json)")
    parser.add_argument("--update-ccn15-excess", action="store_true",
                        help="rewrite --ccn15-excess from today's tree (deliberate; may raise it)")
    parser.add_argument("--alert", metavar="DEBT_JSON",
                        help="print morning-digest lines for a debt report ('-' = stdin) and exit")
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    args = parser.parse_args(argv)

    if args.alert:
        try:
            text = sys.stdin.read() if args.alert == "-" else open(args.alert, encoding="utf-8").read()
            for line in alert_lines(json.loads(text)):
                print(line)
        except (OSError, ValueError):
            pass
        return 0

    try:
        import lizard
        version = getattr(lizard, "version", None)
        version = version if isinstance(version, str) else getattr(sys.modules.get("lizard_ext.version"), "version", None)
    except ImportError:
        print("lizard is not installed (pip install lizard)", file=sys.stderr)
        return 2

    sha = (args.sha or "")[:8]
    if not sha:
        try:
            sha = subprocess.run(["git", "-C", args.root, "rev-parse", "--short=8", "HEAD"],
                                 capture_output=True, text=True, check=True).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            sha = "unknown"
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    funcs, file_lines, extras = scan(args.root, duplication=not (args.update_baseline or args.shrink_baseline
                                                                 or args.update_ccn15_excess))

    if args.update_ccn15_excess:
        allowed = excess_allowances(load_overrides(os.path.join(args.root, args.overrides)))
        files, total = excess_by_file(funcs), excess_total(funcs, allowed)
        write_ccn15_excess(args.ccn15_excess, total, files)
        print(f"CCN {CCN_LIMIT} excess written: {args.ccn15_excess} (total excess {total} over "
              f"{sum(1 for f in funcs if excess(f))} function(s) in {len(files)} file(s))")
        return 0

    if args.update_baseline:
        entries = {k: {"ccn": f.ccn, "nloc": f.nloc} for k, f in offenders(funcs).items()}
        write_baseline(args.baseline, entries, extras["disables"])
        print(f"Baseline written: {args.baseline} ({len(entries)} offenders, "
              f"{sum(extras['disables'].values())} grandfathered swiftlint disables)")
        return 0

    baseline = load_baseline(args.baseline)
    base_disables = load_disables(args.baseline)
    result = ratchet(funcs, baseline)
    next_disables = base_disables if result["shrink_skipped"] else shrink_disables(base_disables, extras["disables"])

    if args.shrink_baseline:
        if result["shrink_skipped"]:
            print(f"Not shrinking: {result['shrink_skipped']}")
            return 1
        shrunk = strict_shrink(baseline, result)
        problems = verify_removals_only(baseline, shrunk, base_disables, next_disables)
        if problems:
            print("🔴 Refusing to shrink: the result is not removals-only: " + "; ".join(problems[:10]))
            return 1
        write_baseline(args.baseline, shrunk, next_disables)
        print(f"Baseline shrunk: {len(baseline)} -> {len(shrunk)} offenders "
              f"({len(result['fixed'])} fixed); nothing was added or raised.")
        if load_ccn15_excess(args.ccn15_excess) is not None:
            cp = ccn15_excess_shrink_plan(args.root, args.ccn15_excess, os.path.join(args.root, args.overrides), funcs)
            if cp["problems"]:
                print(f"CCN {CCN_LIMIT} excess not shrunk: " + "; ".join(cp["problems"]))
                return 1
            if cp["changed"]:
                write_ccn15_excess(args.ccn15_excess, cp["after"], cp["files"])
            print(f"CCN {CCN_LIMIT} total excess: {cp['before']} -> {cp['after']}.")
        return 0

    records = load_overrides(os.path.join(args.root, args.overrides))
    resolve_override_commits(records, args.root, args.overrides)
    debt = debt_report(result, baseline, len(offenders(funcs)), ts, sha,
                       recent_overrides(records, _dt.datetime.now(_dt.timezone.utc)), len(records))
    row = build_row(funcs, file_lines, debt, ts, sha, version, extras["duplication"])

    line = json.dumps(row, separators=(",", ":"))
    if args.row_out:
        with open(args.row_out, "w", encoding="utf-8") as handle:
            handle.write(line + "\n")
    else:
        print(line)
    if args.debt_out:
        with open(args.debt_out, "w", encoding="utf-8") as handle:
            json.dump(debt, handle, indent=1)
            handle.write("\n")
    if args.baseline_out:
        write_baseline(args.baseline_out, result["next_baseline"], next_disables)

    report = markdown_report(row, debt)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(report)
    print(report, file=sys.stderr)

    _set_output("offenders", debt["offenders"])
    _set_output("new_offenders", len(debt["new"]))
    _set_output("worse_offenders", len(debt["worse"]))
    _set_output("fixed_offenders", len(debt["fixed"]))
    _set_output("overrides_recent", len(debt["overrides_recent"]))
    return 0          # report only: debt never fails the build


if __name__ == "__main__":
    raise SystemExit(main())
