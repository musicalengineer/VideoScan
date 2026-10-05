#!/usr/bin/env python3
"""Backfill the complexity trend from git history (one-off, re-runnable).

Rick reads the clean-code TREND LINE; one nightly data point is not a trend.
This measures past commits on main with the same collector the nightly uses
(scripts/complexity_metrics.py) and publishes the rows into
metrics/complexity.jsonl through the normal local publisher
(tools/publish_metrics.py: privacy gate, own worktree, no force push).

Which commits
-------------
First-parent history of origin/main: the last commit of each week from
2026-04-15 (configurable), plus the last commit of each of the last 14 days.

How
---
Each commit is read with `git archive <sha> -- <roots> | tar -x` (Python's
tarfile) into a temp dir: never the working tree, never a checkout. The temp
tree is not a git repo, so files are found by walking it (venvs, .build and
checkouts skipped, as in the nightly).

Rows carry `"backfill": true`, `run_kind: "backfill"` and the COMMIT's date
as ts. Old trees had a flat app layout (VideoScan/VideoScan/*.swift), so
Swift files are mapped to today's folder by FILE NAME where that file still
exists; if less than 90 % of a commit's Swift functions can be mapped,
`swift_by_folder` is null and the dashboard plots totals only for that row.
Backfill rows have no top-15 and no debt/ratchet fields (no file paths or
function names leave this machine through the privacy-gated publisher).

Budget: commits run in parallel processes; nothing new is started after
--budget-minutes (default 10) or after --deadline (default 01:45 local), so
the 2 AM nightly gets the M4.

Usage
-----
    venv/bin/python3 scripts/complexity_backfill.py            # measure + publish
    venv/bin/python3 scripts/complexity_backfill.py --no-publish
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as _dt
import io
import json
import os
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(HERE.parent / "tools"))

import complexity_metrics as cm  # noqa: E402

DEFAULT_OUT = Path.home() / "Library/Logs/VideoScan/complexity_backfill.jsonl"
ROOTS = cm.SWIFT_ROOTS + cm.PYTHON_ROOTS
MAP_FLOOR = 0.90


# ---------------------------------------------------------------- commit choice (pure)

def choose_commits(history: Sequence[Tuple[str, _dt.datetime]], start: _dt.date, today: _dt.date,
                   daily_days: int = 14) -> List[Tuple[str, _dt.datetime]]:
    """history: (sha, commit time) newest first, first-parent main. Picks the
    last commit of each 7-day week from `start`, and of each of the last
    `daily_days` days. Oldest first, no duplicates."""
    picks: Dict[str, _dt.datetime] = {}

    def last_before(limit: _dt.date) -> Optional[Tuple[str, _dt.datetime]]:
        for sha, when in history:                      # newest first
            if when.date() < limit:
                return sha, when
        return None

    week_end = start + _dt.timedelta(days=7)
    while week_end <= today + _dt.timedelta(days=7):
        hit = last_before(min(week_end, today + _dt.timedelta(days=1)))
        if hit and hit[1].date() >= week_end - _dt.timedelta(days=7):
            picks[hit[0]] = hit[1]
        week_end += _dt.timedelta(days=7)
    for back in range(daily_days):
        day = today - _dt.timedelta(days=back)
        hit = last_before(day + _dt.timedelta(days=1))
        if hit and hit[1].date() == day:
            picks[hit[0]] = hit[1]
    return sorted(picks.items(), key=lambda kv: kv[1])


def folder_mapper(current_paths: Sequence[str]):
    """Map a historical path to today's folder: by path when its folder still
    exists, else by file name. Returns (fn, is_mapped)."""
    today_folders = {cm.folder_of(p) for p in current_paths if p.endswith(".swift")}
    by_name: Dict[str, str] = {}
    for p in current_paths:
        if p.endswith(".swift"):
            by_name.setdefault(os.path.basename(p), cm.folder_of(p))

    def mapped(path: str) -> Optional[str]:
        if not path.endswith(".swift"):
            return cm.folder_of(path)
        folder = cm.folder_of(path)
        if folder != "(app root)" and folder in today_folders:
            return folder
        return by_name.get(os.path.basename(path))

    return mapped


def backfill_row(funcs: Sequence[cm.Func], file_lines: Dict[str, int], sha: str, when: _dt.datetime,
                 mapped, lizard_version: Optional[str]) -> dict:
    swift_funcs = [f for f in funcs if f.lang == "swift"]
    ok = sum(1 for f in swift_funcs if mapped(f.file))
    pct = round(100.0 * ok / len(swift_funcs), 1) if swift_funcs else None
    agg = cm.aggregate(funcs, file_lines, folder_fn=lambda p: mapped(p) or "(unmapped)")
    swift_folders = agg["swift_by_folder"] if pct is not None and pct >= MAP_FLOOR * 100 else None
    if swift_folders is not None:
        swift_folders = {k: v for k, v in swift_folders.items() if k != "(unmapped)"}
    return {
        "schemaVersion": 1,
        "ts": when.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sha": sha[:8],
        "run_kind": "backfill",
        "backfill": True,
        "lizard_version": lizard_version,
        "thresholds": {"ccn": cm.CCN_LIMIT, "nloc": cm.NLOC_LIMIT, "file_lines": cm.FILE_LINES_LIMIT},
        "totals": agg["totals"],
        "swift_by_folder": swift_folders,
        "python_by_folder": agg["python_by_folder"] or None,
        "folders_mapped_pct": pct,
    }


# ---------------------------------------------------------------- git + measuring

def _git(repo: str, *args: str, binary: bool = False):
    out = subprocess.run(["git", "-C", repo, *args], capture_output=True, check=True)
    return out.stdout if binary else out.stdout.decode("utf-8", "replace")


def main_history(repo: str, ref: str) -> List[Tuple[str, _dt.datetime]]:
    text = _git(repo, "log", ref, "--first-parent", "--format=%H %cI")
    out = []
    for line in text.splitlines():
        sha, iso = line.split(" ", 1)
        out.append((sha, _dt.datetime.fromisoformat(iso)))
    return out


def extract(repo: str, sha: str, dest: str) -> None:
    """`git archive <sha> -- <roots that exist> | tar -x` into dest."""
    present = [r for r in ROOTS if _git(repo, "ls-tree", "--name-only", sha, "--", r).strip()]
    if not present:
        return
    blob = _git(repo, "archive", "--format=tar", sha, "--", *present, binary=True)
    with tarfile.open(fileobj=io.BytesIO(blob), mode="r:") as tar:
        members = [m for m in tar.getmembers() if m.isfile() and cm.lang_of(m.name)]
        tar.extractall(dest, members=members, filter="data")


def measure(args: Tuple[str, str, str, List[str]]) -> dict:
    repo, sha, iso, current_paths = args
    import lizard
    when = _dt.datetime.fromisoformat(iso)
    with tempfile.TemporaryDirectory(prefix="cx-backfill-") as tmp:
        extract(repo, sha, tmp)
        funcs, file_lines, _ = cm.scan(tmp)
    return backfill_row(funcs, file_lines, sha, when, folder_mapper(current_paths),
                        getattr(lizard, "version", None) if isinstance(getattr(lizard, "version", None), str) else None)


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=str(HERE.parent))
    ap.add_argument("--ref", default="origin/main")
    ap.add_argument("--start", default="2026-04-15")
    ap.add_argument("--daily-days", type=int, default=14)
    ap.add_argument("--workers", type=int, default=6)
    ap.add_argument("--budget-minutes", type=float, default=10.0)
    ap.add_argument("--deadline", default="01:45", help="local HH:MM; no new work after it")
    ap.add_argument("--out", default=str(DEFAULT_OUT))
    ap.add_argument("--no-publish", action="store_true")
    a = ap.parse_args(argv)

    t0 = time.monotonic()
    now = _dt.datetime.now()
    hh, mm = (int(x) for x in a.deadline.split(":"))
    deadline = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
    if deadline <= now:
        deadline += _dt.timedelta(days=1)
    stop_at = min(t0 + a.budget_minutes * 60, t0 + (deadline - now).total_seconds())

    picks = choose_commits(main_history(a.repo, a.ref), _dt.date.fromisoformat(a.start), _dt.date.today(),
                           a.daily_days)
    current = cm.list_files(a.repo)
    print(f"START complexity backfill: {len(picks)} commits, {a.workers} workers, "
          f"budget {a.budget_minutes} min, deadline {deadline:%H:%M}")
    rows: List[dict] = []
    skipped = 0
    with cf.ProcessPoolExecutor(max_workers=a.workers) as pool:
        pending = {}
        queue = list(picks)
        while queue or pending:
            while queue and len(pending) < a.workers:
                if time.monotonic() >= stop_at:
                    skipped += len(queue)
                    queue.clear()
                    break
                sha, when = queue.pop(0)
                pending[pool.submit(measure, (a.repo, sha, when.isoformat(), current))] = sha
            if not pending:
                break
            done, _ = cf.wait(pending, return_when=cf.FIRST_COMPLETED)
            for fut in done:
                sha = pending.pop(fut)
                try:
                    row = fut.result()
                    rows.append(row)
                    t = row["totals"]["all"]
                    print(f"  {row['ts'][:10]} {sha[:8]}  functions {t['functions']:>6}  mean CCN {t['mean_ccn']}  "
                          f"CCN>30 {t['ccn_over_30']:>4}  offenders {t['offenders']:>4}  "
                          f"folders {'mapped' if row['swift_by_folder'] else 'totals only'} ({row['folders_mapped_pct']}%)",
                          flush=True)
                except Exception as exc:  # one bad commit must not sink the rest
                    print(f"  {sha[:8]} FAILED: {type(exc).__name__}: {exc}")
    rows.sort(key=lambda r: r["ts"])
    out = Path(a.out).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    existing = {}
    if out.exists():
        for line in out.read_text().splitlines():
            try:
                r = json.loads(line)
                existing[(r["ts"], r["sha"])] = r
            except (ValueError, KeyError):
                continue
    for r in rows:
        existing[(r["ts"], r["sha"])] = r
    out.write_text("".join(json.dumps(r, sort_keys=True, separators=(",", ":")) + "\n"
                           for r in sorted(existing.values(), key=lambda r: r["ts"])))
    elapsed = time.monotonic() - t0
    if rows:
        first, last = rows[0]["totals"]["all"], rows[-1]["totals"]["all"]
        print(f"TREND {rows[0]['ts'][:10]} -> {rows[-1]['ts'][:10]}: CCN>30 {first['ccn_over_30']} -> "
              f"{last['ccn_over_30']}, mean CCN {first['mean_ccn']} -> {last['mean_ccn']}, "
              f"functions {first['functions']} -> {last['functions']}")
    result = "not published (--no-publish)"
    if not a.no_publish and rows:
        import publish_metrics as pm
        try:
            result = pm.publish({"complexity.jsonl": rows}, folders=pm.source_folders())
        except (pm.PrivacyError, pm.PublishError, OSError, subprocess.SubprocessError) as exc:
            print(f"OUTCOME failed: {len(rows)} rows measured in {elapsed:.0f}s, publish failed: {exc}")
            return 1
    print(f"OUTCOME ok: {len(rows)} rows in {elapsed:.0f}s ({skipped} skipped for time); {result}; local copy {out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
