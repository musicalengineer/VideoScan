#!/usr/bin/env python3
"""Make the `-warn-long-*` compile-time metric readable, then ratchet it.

Why this exists
---------------
The nightly workflow has always built with

    -warn-long-function-bodies=100 -warn-long-expression-type-checking=100

and then counted the resulting lines with `grep | sort -u`. Its own comment
admits the trend is roughly two-thirds noise, and it is right: the warning
text embeds the measured time.

    ContentView.swift:490:5: warning: getter for 'body' took 412ms to type-check
    ContentView.swift:490:5: warning: getter for 'body' took 418ms to type-check

Those are the SAME slow function on two consecutive nights. `sort -u` sees two
distinct strings and reports one of them as new, every night, forever. The
count moves, means nothing, and the signal — *which* functions are slow and
whether a new one appeared — is unreadable.

The fix is to key on FUNCTION IDENTITY: file + symbol, with the millisecond
value carried as a VALUE, never as part of the key. Then the same slow function
is the same entry night over night, the top-20 list is stable enough to read,
and "a new function crossed the line" becomes a real, actionable event.

Why it matters more than tidiness
---------------------------------
Giant SwiftUI bodies in this project type-check fine on Rick's M4 and fail on
the GitHub runner. The main CI lane was red from 2026-09-01 for exactly that
family of reason: `CatalogView.body` (495 lines) hit "the compiler is unable to
type-check this expression in reasonable time" on the runner's Swift 6.2.4
while compiling locally. A function does not jump from 100 ms to "unable" in
one commit — it climbs. This metric is the climb, and right now it cannot be
read. So this parser also treats the "unable to type-check in reasonable time"
error as a first-class entry with an infinite cost: it is the same measurement,
saturated.

Identity rules
--------------
  named decl   file :: "<kind> '<name>'"   e.g. ContentView.swift::getter for 'body'
               Stable across edits, line moves and reformatting.
  closure      file :: "closure body"      aggregated per file (Swift emits no
                                           name; a line number would jitter).
  expression   file :: "expression"        same, aggregated per file.
  unable       file :: "unable to type-check in reasonable time"

Each identity carries max_ms and a hit count. Aggregating by max is what makes
xcodebuild's repeated emission of the same warning (several targets, several
passes) collapse to one entry.

Memory: streams the log line by line; only the identity table is retained.
Worst case is O(distinct identities), a few thousand small dicts — under a
megabyte for any log this build can produce.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Dict, Iterable, List, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ratchet_baseline import set_output  # noqa: E402

# ---------------------------------------------------------------------------
# The one number that decides red vs green. A brand-new function that takes
# longer than this to type-check fails the nightly job.
#
# 500 ms is chosen deliberately: the compiler's own warning floor in this
# workflow is 100 ms (far too chatty to gate on), and the bodies that actually
# died on the GH runner were the multi-hundred-millisecond ones on Rick's M4.
# The runner is slower than an M4 Max, so 500 ms locally is already well into
# the danger band.
NEW_FUNCTION_THRESHOLD_MS = 500
# ---------------------------------------------------------------------------

DEFAULT_BASELINE = os.path.join("ci", "baselines", "typecheck_timing.json")
TOP_N = 20

# `<path>:<line>:<col>: warning: <kind> '<name>' took <ms>ms to type-check (limit: <n>ms)`
NAMED_BODY = re.compile(
    r"^(?P<path>[^\s:][^:]*):(?P<line>\d+):(?P<col>\d+):\s+warning:\s+"
    r"(?P<kind>[A-Za-z][A-Za-z ]*?)\s+'(?P<name>[^']+)'\s+took\s+(?P<ms>\d+)ms\s+to type-check"
)
# `... warning: closure body took <ms>ms to type-check (limit: <n>ms)`
CLOSURE_BODY = re.compile(
    r"^(?P<path>[^\s:][^:]*):(?P<line>\d+):(?P<col>\d+):\s+warning:\s+"
    r"closure body took\s+(?P<ms>\d+)ms\s+to type-check"
)
# `... warning: expression took <ms>ms to type-check (limit: <n>ms)`
EXPRESSION = re.compile(
    r"^(?P<path>[^\s:][^:]*):(?P<line>\d+):(?P<col>\d+):\s+warning:\s+"
    r"expression took\s+(?P<ms>\d+)ms\s+to type-check"
)
# The saturated case — the one that turned CI red on 2026-09-01.
UNABLE = re.compile(
    r"^(?P<path>[^\s:][^:]*):(?P<line>\d+):(?P<col>\d+):\s+error:\s+"
    r"the compiler is unable to type-check this expression in reasonable time"
)

GH_RUNNER_PREFIX = re.compile(r"^.*?/work/[^/]+/[^/]+/")

UNABLE_KIND = "unable to type-check in reasonable time"
# Sorting sentinel for the saturated case: it is worse than any measured value.
UNABLE_MS = math.inf


@dataclass
class Entry:
    """One slow-to-type-check identity, with the ms carried as a VALUE."""
    path: str
    kind: str
    name: Optional[str]
    max_ms: float = 0.0
    hits: int = 0
    sample_line: int = 0
    lines: List[int] = field(default_factory=list)

    @property
    def symbol(self) -> str:
        return f"{self.kind} '{self.name}'" if self.name else self.kind

    @property
    def identity(self) -> str:
        """file + symbol. NO milliseconds, NO line number."""
        return f"{self.path}::{self.symbol}"

    @property
    def is_saturated(self) -> bool:
        return self.max_ms == UNABLE_MS

    def ms_text(self) -> str:
        return "unable" if self.is_saturated else f"{int(self.max_ms)}ms"

    def as_dict(self) -> dict:
        return {
            "identity": self.identity,
            "path": self.path,
            "symbol": self.symbol,
            "max_ms": "unable" if self.is_saturated else int(self.max_ms),
            "hits": self.hits,
            "lines": sorted(set(self.lines))[:10],
        }


def normalise_path(raw: str, workspace: Optional[str]) -> str:
    """Runner-absolute path -> repo-relative, so identities survive the CI box."""
    path = raw.strip()
    if workspace:
        try:
            if os.path.isabs(path) and os.path.commonpath(
                    [os.path.abspath(path), os.path.abspath(workspace)]) == os.path.abspath(workspace):
                return os.path.relpath(path, workspace).replace(os.sep, "/")
        except ValueError:
            pass
    if path.startswith("/"):
        stripped = GH_RUNNER_PREFIX.sub("", path)
        if stripped != path:
            return stripped
        parts = path.strip("/").split("/")
        return "/".join(parts[-3:]) if len(parts) > 3 else "/".join(parts)
    return path


def parse_log(lines: Iterable[str], workspace: Optional[str] = None) -> Dict[str, Entry]:
    """Fold a build log into {identity: Entry}. Streams; never holds the log."""
    table: Dict[str, Entry] = {}

    def record(path: str, kind: str, name: Optional[str], ms: float, line_no: int) -> None:
        entry = Entry(path=normalise_path(path, workspace), kind=kind, name=name)
        existing = table.get(entry.identity)
        if existing is None:
            entry.max_ms = ms
            entry.hits = 1
            entry.sample_line = line_no
            entry.lines = [line_no]
            table[entry.identity] = entry
        else:
            existing.hits += 1
            if ms > existing.max_ms:
                existing.max_ms = ms
                existing.sample_line = line_no
            existing.lines.append(line_no)

    for raw in lines:
        line = raw.rstrip("\n")
        if "to type-check" not in line and "unable to type-check" not in line:
            continue
        match = UNABLE.match(line)
        if match:
            record(match.group("path"), UNABLE_KIND, None,
                   UNABLE_MS, int(match.group("line")))
            continue
        match = CLOSURE_BODY.match(line)
        if match:
            record(match.group("path"), "closure body", None,
                   float(match.group("ms")), int(match.group("line")))
            continue
        match = EXPRESSION.match(line)
        if match:
            record(match.group("path"), "expression", None,
                   float(match.group("ms")), int(match.group("line")))
            continue
        match = NAMED_BODY.match(line)
        if match:
            record(match.group("path"), match.group("kind").strip(),
                   match.group("name"), float(match.group("ms")),
                   int(match.group("line")))
            continue
    return table


def top_offenders(table: Dict[str, Entry], limit: int = TOP_N) -> List[Entry]:
    """Worst-to-type-check first. Saturated entries sort above every number."""
    return sorted(table.values(),
                  key=lambda e: (-e.max_ms, e.path, e.symbol))[:limit]


def load_baseline(path: str) -> Dict[str, float]:
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    out: Dict[str, float] = {}
    for key, value in data.get("entries", {}).items():
        out[str(key)] = UNABLE_MS if value in ("unable", "inf") else float(value)
    return out


def write_baseline(path: str, table: Dict[str, Entry]) -> None:
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    entries = {
        key: ("unable" if entry.is_saturated else int(entry.max_ms))
        for key, entry in sorted(table.items())
    }
    payload = {
        "note": (
            "Type-check timing baseline, keyed by FUNCTION IDENTITY (file + symbol). "
            "The ms value is data, never part of the key — that is the whole point. "
            f"A NEW identity over {NEW_FUNCTION_THRESHOLD_MS}ms fails the nightly job; "
            "entries already here are grandfathered."
        ),
        "threshold_ms": NEW_FUNCTION_THRESHOLD_MS,
        "entry_count": len(entries),
        "entries": entries,
    }
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2)
        handle.write("\n")


def new_over_threshold(table: Dict[str, Entry],
                       baseline: Dict[str, float],
                       threshold_ms: int = NEW_FUNCTION_THRESHOLD_MS) -> List[Entry]:
    """Identities absent from the baseline and over the line. The ratchet."""
    return sorted(
        (entry for key, entry in table.items()
         if key not in baseline and entry.max_ms >= threshold_ms),
        key=lambda e: (-e.max_ms, e.path, e.symbol),
    )


def regressions(table: Dict[str, Entry],
                baseline: Dict[str, float],
                growth_factor: float = 1.5,
                threshold_ms: int = NEW_FUNCTION_THRESHOLD_MS) -> List[Entry]:
    """Known-slow entries that got substantially slower. REPORTED, NOT GATED —
    the ms value jitters on shared runners and gating on it would rebuild the
    exact noise this script exists to remove."""
    out = []
    for key, entry in table.items():
        before = baseline.get(key)
        if before is None:
            continue
        if entry.max_ms >= threshold_ms and entry.max_ms >= before * growth_factor:
            out.append(entry)
    return sorted(out, key=lambda e: (-e.max_ms, e.path))


def markdown_report(table: Dict[str, Entry],
                    baseline: Dict[str, float],
                    new_bad: List[Entry],
                    grown: List[Entry]) -> str:
    saturated = [e for e in table.values() if e.is_saturated]
    over = [e for e in table.values() if e.max_ms >= NEW_FUNCTION_THRESHOLD_MS]
    lines: List[str] = ["## Type-check timing (identity-keyed)", ""]
    lines.append("| Metric | Value |")
    lines.append("|---|---:|")
    lines.append(f"| Distinct slow identities | {len(table)} |")
    lines.append(f"| Over {NEW_FUNCTION_THRESHOLD_MS}ms | {len(over)} |")
    lines.append(f"| Saturated (\"unable to type-check\") | {len(saturated)} |")
    lines.append(f"| NEW over threshold (gated) | {len(new_bad)} |")
    lines.append(f"| Known entries >{int((1.5 - 1) * 100)}% slower (informational) | {len(grown)} |")
    lines.append("")
    lines.append(
        "Identities are `file::symbol`. The millisecond value is data, not part of "
        "the key, so the same slow function is the same row night over night — "
        "unlike the old `grep | sort -u`, which re-counted it every run."
    )
    lines.append("")

    if saturated:
        lines.append("❌ **The compiler gave up on at least one expression.** "
                     "This is what turns the build red on the runner even when it "
                     "compiles on an M4. Split the body.")
        lines.append("")

    if new_bad:
        lines.append(f"❌ **{len(new_bad)} NEW identit{'y' if len(new_bad) == 1 else 'ies'} "
                     f"over {NEW_FUNCTION_THRESHOLD_MS}ms.**")
        lines.append("")
        lines.append("```")
        for entry in new_bad:
            lines.append(f"{entry.path}:{entry.sample_line}: {entry.ms_text():>8}  {entry.symbol}")
        lines.append("```")
        lines.append("")
    else:
        lines.append(f"✅ **No new function over {NEW_FUNCTION_THRESHOLD_MS}ms.**")
        lines.append("")

    top = top_offenders(table)
    if top:
        lines.append(f"<details open><summary>Top {len(top)} worst to type-check</summary>")
        lines.append("")
        lines.append("| # | ms | Symbol | File |")
        lines.append("|---:|---:|---|---|")
        for rank, entry in enumerate(top, 1):
            lines.append(
                f"| {rank} | {entry.ms_text()} | `{entry.symbol}` | "
                f"`{entry.path}:{entry.sample_line}` |")
        lines.append("")
        lines.append("</details>")
        lines.append("")

    if grown:
        lines.append(f"<details><summary>Known-slow entries that grew ({len(grown)}) — "
                     "informational, not gated</summary>")
        lines.append("")
        lines.append("```")
        for entry in grown:
            before = baseline.get(entry.identity, 0)
            before_text = "unable" if before == UNABLE_MS else f"{int(before)}ms"
            lines.append(f"{entry.path}: {entry.symbol}: {before_text} -> {entry.ms_text()}")
        lines.append("```")
        lines.append("")
        lines.append("</details>")
        lines.append("")

    return "\n".join(lines)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("log", nargs="?", default="-",
                        help="build log (xcodebuild output); '-' for stdin")
    parser.add_argument("--baseline", default=DEFAULT_BASELINE)
    parser.add_argument("--update-baseline", action="store_true")
    parser.add_argument("--json-out", default="")
    parser.add_argument("--top-out", default="",
                        help="write the stable top-N list here as plain text")
    parser.add_argument("--workspace", default=os.environ.get("GITHUB_WORKSPACE", ""))
    parser.add_argument("--threshold-ms", type=int, default=NEW_FUNCTION_THRESHOLD_MS)
    args = parser.parse_args(argv)

    if args.log == "-":
        table = parse_log(sys.stdin, args.workspace or None)
    else:
        if not os.path.exists(args.log):
            print(f"No build log at {args.log} — nothing to parse.")
            set_output("typecheck_identities", 0)
            set_output("typecheck_new_over_threshold", 0)
            return 0
        with open(args.log, "r", encoding="utf-8", errors="replace") as handle:
            table = parse_log(handle, args.workspace or None)

    if args.update_baseline:
        write_baseline(args.baseline, table)
        print(f"Baseline written: {args.baseline} ({len(table)} identities)")
        for entry in top_offenders(table, TOP_N):
            print(f"  {entry.ms_text():>8}  {entry.symbol}  ({entry.path}:{entry.sample_line})")
        return 0

    baseline = load_baseline(args.baseline)
    new_bad = new_over_threshold(table, baseline, args.threshold_ms)
    grown = regressions(table, baseline, threshold_ms=args.threshold_ms)
    report = markdown_report(table, baseline, new_bad, grown)

    step_summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if step_summary:
        with open(step_summary, "a", encoding="utf-8") as handle:
            handle.write(report)
            handle.write("\n")
    print(report)

    if args.json_out:
        os.makedirs(os.path.dirname(args.json_out) or ".", exist_ok=True)
        with open(args.json_out, "w", encoding="utf-8") as handle:
            json.dump(
                {
                    "threshold_ms": args.threshold_ms,
                    "identity_count": len(table),
                    "new_over_threshold": [e.as_dict() for e in new_bad],
                    "grown": [e.as_dict() for e in grown],
                    "top": [e.as_dict() for e in top_offenders(table)],
                    "all": [e.as_dict() for e in sorted(
                        table.values(), key=lambda x: (-x.max_ms, x.path))],
                },
                handle, indent=2)
            handle.write("\n")

    if args.top_out:
        with open(args.top_out, "w", encoding="utf-8") as handle:
            for rank, entry in enumerate(top_offenders(table), 1):
                handle.write(f"{rank:>3}. {entry.ms_text():>8}  {entry.symbol}  "
                             f"({entry.path}:{entry.sample_line})\n")

    set_output("typecheck_identities", len(table))
    set_output("typecheck_new_over_threshold", len(new_bad))
    set_output("typecheck_saturated",
               sum(1 for e in table.values() if e.is_saturated))
    return 1 if new_bad else 0


if __name__ == "__main__":
    raise SystemExit(main())
