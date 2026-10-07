#!/usr/bin/env python3
"""The morning "problem files" table: one row per file, every debt signal.

Rick (2026-10-07): one table, worst first, that the nightly refactor picks
from. It joins what the other nightly metrics already know, per app file:

  offenders       complexity offenders on the committed baseline
                  (ci/baselines/complexity_debt.json: CCN > 15 or NLOC > 80)
  worst_ccn       the highest CCN among them
  new_or_worse    tonight's NEW or WORSE complexity offenders in the file
                  (complexity_debt_latest.json from scripts/complexity_metrics.py)
  lines           file length (> 800 is the complexity report's file limit)
  could_be_private, widened_for_split
                  from scripts/exposure_metrics.py's per-file map
  churn_7d        commits that touched the file in the last 7 days

The score (FORMULA_VERSION 1), simple on purpose:

  debt  = 2 x offenders
        + (worst_ccn - 15) / 5          when worst_ccn > 15
        + 5 x new_or_worse
        + (lines - 800) / 200           when lines > 800
        + could_be_private / 2
        + widened_for_split / 4
  score = debt x (1 + min(churn_7d, 10) / 5)

Debt says how much is wrong; churn says how often someone is in there paying
for it (the classic hotspot: complexity x change frequency). Churn alone
scores nothing: a busy, clean file is not a problem file. New or worse
offenders weigh most, because tonight is the cheapest time to undo them.

Outputs `--out problem_files_latest.json` (published to the metrics branch);
`--table FILE|-` prints the morning-digest table (top 15).
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import subprocess
import sys
from typing import Dict, List, Optional, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import complexity_metrics as cm  # noqa: E402

FORMULA_VERSION = 1
TOP_N = 15
CHURN_DAYS = 7
CHURN_CAP = 10
SCHEMA_VERSION = 1


def score(offenders: int, worst_ccn: int, new_or_worse: int, lines: int,
          could_be_private: int, widened_for_split: int, churn: int) -> float:
    """The documented score (see the module docstring)."""
    debt = (2 * offenders
            + max(0, worst_ccn - cm.CCN_LIMIT) / 5
            + 5 * new_or_worse
            + max(0, lines - cm.FILE_LINES_LIMIT) / 200
            + could_be_private / 2
            + widened_for_split / 4)
    return round(debt * (1 + min(churn, CHURN_CAP) / 5), 1)


def complexity_by_file(baseline: Dict[str, dict]) -> Dict[str, dict]:
    out: Dict[str, dict] = {}
    for key, v in baseline.items():
        rec = out.setdefault(cm.key_file(key), {"offenders": 0, "worst_ccn": 0})
        rec["offenders"] += 1
        rec["worst_ccn"] = max(rec["worst_ccn"], int(v.get("ccn", 0)))
    return out


def new_or_worse_by_file(debt: Optional[dict]) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for f in ((debt or {}).get("new") or []) + ((debt or {}).get("worse") or []):
        path = f.get("file")
        if path:
            out[path] = out.get(path, 0) + 1
    return out


def churn_by_file(root: str, days: int = CHURN_DAYS) -> Dict[str, int]:
    """Commits per file in the last `days` days (merges excluded, so a merge
    does not double-count its branch's commits)."""
    try:
        out = subprocess.run(["git", "-C", root, "log", f"--since={days}.days.ago", "--no-merges",
                              "--name-only", "--format=%x00"], capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return {}
    counts: Dict[str, int] = {}
    for commit in out.split("\0"):
        for path in {p.strip() for p in commit.splitlines() if p.strip()}:
            counts[path] = counts.get(path, 0) + 1
    return counts


def build_rows(exposure_files: Dict[str, dict], cx_baseline: Dict[str, dict],
               cx_debt: Optional[dict], churn: Dict[str, int]) -> List[dict]:
    """One row per file with any debt, worst first."""
    cx = complexity_by_file(cx_baseline)
    nw = new_or_worse_by_file(cx_debt)
    files = set(exposure_files) | set(cx) | set(nw)
    rows = []
    for path in files:
        if not cm.in_scope(path) or not path.endswith(".swift"):
            continue
        ex = exposure_files.get(path) or {}
        c = cx.get(path) or {"offenders": 0, "worst_ccn": 0}
        row = {
            "file": path,
            "offenders": c["offenders"],
            "worst_ccn": c["worst_ccn"],
            "new_or_worse": nw.get(path, 0),
            "lines": int(ex.get("lines") or 0),
            "could_be_private": len(ex.get("could_be_private") or []),
            "widened_for_split": len(ex.get("widened_for_split") or []),
            "churn_7d": churn.get(path, 0),
        }
        row["score"] = score(row["offenders"], row["worst_ccn"], row["new_or_worse"], row["lines"],
                             row["could_be_private"], row["widened_for_split"], row["churn_7d"])
        if row["score"] > 0:
            rows.append(row)
    rows.sort(key=lambda r: (-r["score"], r["file"]))
    return rows


def report(rows: Sequence[dict], ts: str, sha: str, limit: int = TOP_N) -> dict:
    return {"schemaVersion": SCHEMA_VERSION, "ts": ts, "sha": sha,
            "formula_version": FORMULA_VERSION, "files_scored": len(rows),
            "rows": list(rows[:limit])}


def table_lines(rep: dict, limit: int = TOP_N) -> List[str]:
    rows = (rep.get("rows") or [])[:limit]
    if not rows:
        return []
    out = [f"Problem files ({str(rep.get('ts', ''))[:10]}, worst first; the nightly refactor picks from here)",
           f"{'#':>2} {'Score':>6} {'Cx':>3} {'CCN':>4} {'N/W':>3} {'Lines':>6} {'Priv':>4} {'Wide':>4} "
           f"{'Chg7d':>5}  File"]
    for i, r in enumerate(rows, 1):
        path = str(r.get("file", ""))
        short = f"{cm.folder_of(path)}/{os.path.basename(path)}"
        flag = "🔴" if r.get("new_or_worse") else "  "
        out.append(f"{i:>2} {r.get('score', 0):>6.1f} {r.get('offenders', 0):>3} {r.get('worst_ccn', 0):>4} "
                   f"{r.get('new_or_worse', 0):>3} {r.get('lines', 0):>6} {r.get('could_be_private', 0):>4} "
                   f"{r.get('widened_for_split', 0):>4} {r.get('churn_7d', 0):>5}  {flag}{short}")
    out.append("   Cx offenders · CCN worst · N/W new-or-worse tonight · Priv could-be-private · "
               "Wide widened-for-split · Chg7d commits in 7 days (score: scripts/problem_files.py)")
    return out


def _load_json(path: str) -> Optional[dict]:
    if not path:
        return None
    try:
        with open(path, "r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return None


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--exposure-files", default="", help="exposure_metrics.py --files-out JSON")
    parser.add_argument("--complexity-baseline", default=cm.DEFAULT_SEED)
    parser.add_argument("--complexity-debt", default="", help="complexity_metrics.py --debt-out JSON")
    parser.add_argument("--out", default="", help="problem_files_latest.json; default stdout")
    parser.add_argument("--table", metavar="JSON", help="print the digest table for a report ('-' = stdin)")
    parser.add_argument("--sha", default=os.environ.get("GITHUB_SHA", ""))
    args = parser.parse_args(argv)

    if args.table:
        try:
            text = sys.stdin.read() if args.table == "-" else open(args.table, encoding="utf-8").read()
            for line in table_lines(json.loads(text)):
                print(line)
        except (OSError, ValueError):
            pass
        return 0

    exposure = (_load_json(args.exposure_files) or {}).get("files") or {}
    base_path = args.complexity_baseline
    if not os.path.isabs(base_path):
        base_path = os.path.join(args.root, base_path)
    rows = build_rows(exposure, cm.load_baseline(base_path), _load_json(args.complexity_debt),
                      churn_by_file(args.root))
    ts = _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    sha = (args.sha or "")[:8] or "unknown"
    rep = report(rows, ts, sha)
    text = json.dumps(rep, indent=1) + "\n"
    if args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(text)
    else:
        sys.stdout.write(text)
    print("\n".join(table_lines(rep)), file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
