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
from typing import Dict, Iterable, List, Optional, Sequence, Tuple

CCN_LIMIT = 15
NLOC_LIMIT = 80
FILE_LINES_LIMIT = 800
TOP_N = 15

SWIFT_ROOTS = ("VideoScan/VideoScan", "VideoScan/VideoScanCore/Sources", "swift_cli")
PYTHON_ROOTS = ("scripts", "tools")
SKIP_DIRS = {".build", "build", "DerivedData", "checkouts", "node_modules",
             "__pycache__", ".venv", "venv", ".git", ".trash"}

DEFAULT_SEED = os.path.join("ci", "baselines", "complexity_debt.json")

# Shrink guard: refuse to rewrite the baseline when this much vanished at once.
SHRINK_GUARD_FRACTION = 0.5
SHRINK_GUARD_MIN = 20


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
        """Type.parent.name: what a human reads in the top-15 and digests."""
        return ".".join(x for x in (self.container, self.parent, self.name) if x)

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

    file::name                 when the name is unique in the file
    file::Type.name            when it repeats but the enclosing type tells
                               them apart (several SwiftUI `body`s per file);
                               a nested function also carries its parent
                               function (Type.prop.get)
    file::Type.long_name       ... else with lizard's parameter list (overloads)
    file::Type.long_name#n     ... else an ordinal in source order (last resort)
    """
    by_file: Dict[str, List[Func]] = {}
    for f in funcs:
        by_file.setdefault(f.file, []).append(f)
    for path, items in by_file.items():
        items = sorted(items, key=lambda f: f.start_line)

        def counts(labels: List[str]) -> Dict[str, int]:
            out: Dict[str, int] = {}
            for label in labels:
                out[label] = out.get(label, 0) + 1
            return out

        names = counts([f.name for f in items])
        qual = lambda f: f.display
        quals = counts([qual(f) for f in items if names[f.name] > 1])
        longq = lambda f: ".".join(x for x in (f.container, f.parent, _norm(f.long_name) or f.name) if x)
        longs = counts([longq(f) for f in items if names[f.name] > 1 and quals[qual(f)] > 1])
        seen: Dict[str, int] = {}
        for f in items:
            if names[f.name] == 1:
                f.key = f"{path}::{f.name}"
            elif quals[qual(f)] == 1:
                f.key = f"{path}::{qual(f)}"
            elif longs[longq(f)] == 1:
                f.key = f"{path}::{longq(f)}"
            else:
                seen[longq(f)] = seen.get(longq(f), 0) + 1
                f.key = f"{path}::{longq(f)}#{seen[longq(f)]}"


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
    return {"files": 0, "functions": 0, "ccn_sum": 0, "ccn_over_15": 0,
            "nloc_over_80": 0, "offenders": 0, "files_over_800": 0}


def _finish(bucket: dict) -> dict:
    out = dict(bucket)
    ccn_sum = out.pop("ccn_sum")
    out["mean_ccn"] = round(ccn_sum / out["functions"], 2) if out["functions"] else None
    return out


def aggregate(funcs: Sequence[Func], file_lines: Dict[str, int]) -> dict:
    """Per-folder and total numbers. `file_lines` maps every measured file
    (even ones with no functions) to its line count."""
    folders: Dict[str, Dict[str, dict]] = {"swift": {}, "python": {}}
    totals: Dict[str, dict] = {"swift": _empty_bucket(), "python": _empty_bucket(),
                               "all": _empty_bucket()}

    def buckets(path: str) -> List[dict]:
        lang = lang_of(path)
        folder = folders[lang].setdefault(folder_of(path), _empty_bucket())
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
    new = sorted((f for k, f in current.items() if k not in baseline),
                 key=lambda f: (-f.ccn, -f.nloc, f.key))
    worse = sorted((f for k, f in current.items() if k in baseline and got_worse(f, baseline[k])),
                   key=lambda f: (-f.ccn, -f.nloc, f.key))
    fixed = sorted(k for k in baseline if k not in current)

    nxt: Dict[str, dict] = {}
    for key, base in baseline.items():
        cur = current.get(key)
        if cur is None:
            continue
        nxt[key] = {"ccn": min(base["ccn"], cur.ccn), "nloc": min(base["nloc"], cur.nloc)}

    shrink_skipped = None
    if not funcs:
        shrink_skipped = "no functions measured: the scan found nothing"
    elif len(fixed) > SHRINK_GUARD_MIN and len(fixed) > SHRINK_GUARD_FRACTION * len(baseline):
        shrink_skipped = (f"{len(fixed)} of {len(baseline)} baseline entries vanished in one run: "
                          "more likely a broken scan than a refactor")
    if shrink_skipped:
        nxt = dict(baseline)
    return {"new": new, "worse": worse, "fixed": fixed, "next_baseline": nxt,
            "shrink_skipped": shrink_skipped}


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
    """Morning-digest lines. Empty when there is nothing new or worse."""
    new, worse = debt.get("new") or [], debt.get("worse") or []
    lines: List[str] = []
    if new or worse:
        lines.append(f"🟡 Complexity debt ({str(debt.get('ts', ''))[:10]}): "
                     f"{len(new)} NEW offender(s), {len(worse)} got worse "
                     f"(CCN > {CCN_LIMIT} or NLOC > {NLOC_LIMIT}; report only)")
        for f in (new + worse)[:limit]:
            tag = "new  " if f in new else "worse"
            was = f" (was {f['base_ccn']}/{f['base_nloc']})" if "base_ccn" in f else ""
            lines.append(f"   {tag} CCN {f['ccn']:>3} NLOC {f['nloc']:>4}  "
                         f"{os.path.basename(f['file'])} :: {f['function']}{was}")
        extra = len(new) + len(worse) - limit
        if extra > 0:
            lines.append(f"   … and {extra} more in metrics/complexity_debt_latest.json")
    for rec in debt.get("overrides_recent") or []:
        lines.append(f"🟠 Complexity gate OVERRIDDEN {str(rec.get('ts', ''))[:16]}: \"{rec.get('reason', '')}\" "
                     f"({len(rec.get('functions') or [])} function(s), {len(rec.get('disables') or [])} disable(s))")
    if debt.get("fixed"):
        lines.append(f"✅ Complexity debt: {len(debt['fixed'])} baseline offender(s) fixed. Lock it in: "
                     "python3 scripts/complexity_metrics.py --shrink-baseline (commit the result).")
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
# scanning (needs lizard; everything above is pure)

def install_swift_property_support() -> None:
    """Teach lizard's Swift reader that `var NAME ... {` on one line is a
    function named NAME (computed property / SwiftUI body). Idempotent."""
    from lizard_languages.swift import SwiftStates
    if getattr(SwiftStates, "_videoscan_props", False):
        return
    original = SwiftStates._state_global

    def _state_global(self, token):
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
            out.append({"ts": rec.get("ts"), "reason": rec.get("reason", ""),
                        "functions": sorted((rec.get("functions") or {}).keys()),
                        "disables": sorted((rec.get("disables") or {}).keys())})
    return out


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
    """Grandfathered disables only shrink: gone keys drop, counts go down."""
    return {k: min(v, current[k]) for k, v in baseline.items() if current.get(k, 0) > 0}


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

    funcs, file_lines, extras = scan(args.root, duplication=not (args.update_baseline or args.shrink_baseline))

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
        write_baseline(args.baseline, result["next_baseline"], next_disables)
        print(f"Baseline shrunk: {len(baseline)} -> {len(result['next_baseline'])} offenders "
              f"({len(result['fixed'])} fixed); nothing was added. Commit {args.baseline}.")
        return 0

    records = load_overrides(os.path.join(args.root, args.overrides))
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
