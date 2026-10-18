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
    venv/bin/python3 scripts/complexity_backfill.py --modules [--no-publish]   # per-module history
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


# ---------------------------------------------------------------- per-module history (--modules)
#
# The metrics page's Module health table needs per-MODULE history (lines,
# max CCN, files over 1,000 lines, fix commits) that the rows above never
# carried. `--modules` measures the last commit of each of the last
# --module-days days (default 60) and writes one COUNTS-ONLY row per day to
# metrics/modules.jsonl (no names, no paths: privacy gate as above).
#
# Cheap by construction: `git ls-tree` lists each commit's blobs, and lizard
# runs once per DISTINCT blob (cached across commits, read with one
# `git cat-file --batch`), so 60 days costs about one full scan plus the
# files that changed — not 60 scans. Sequential, one process.

DEFAULT_MODULES_OUT = Path.home() / "Library/Logs/VideoScan/modules_backfill.jsonl"


class BlobCache:
    """blob sha -> (line count, [ccn, ...]) measured once."""

    def __init__(self, repo: str):
        self.repo = repo
        self.seen: Dict[str, Tuple[int, List[int]]] = {}
        self.measured = 0
        self._cat = subprocess.Popen(["git", "-C", repo, "cat-file", "--batch"],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE)

    def _read(self, blob: str) -> str:
        self._cat.stdin.write((blob + "\n").encode())
        self._cat.stdin.flush()
        header = self._cat.stdout.readline().split()
        size = int(header[2])
        data = self._cat.stdout.read(size)
        self._cat.stdout.read(1)                     # trailing newline
        return data.decode("utf-8", "replace")

    def measure(self, entries: Sequence[Tuple[str, str]]) -> None:
        """entries: (path, blob). Measures the blobs not seen yet."""
        todo: Dict[str, str] = {}
        queued = set()
        for path, blob in entries:
            if blob not in self.seen and blob not in queued:
                todo[path] = blob
                queued.add(blob)
        if not todo:
            return
        sources = {path: self._read(blob) for path, blob in todo.items()}
        funcs, _ = cm.analyze_sources(sources, ".")
        ccns: Dict[str, List[int]] = {p: [] for p in sources}
        for f in funcs:
            ccns.setdefault(f.file, []).append(f.ccn)
        for path, blob in todo.items():
            self.seen[blob] = (sources[path].count("\n"), ccns.get(path, []))
        self.measured += len(todo)

    def close(self) -> None:
        try:
            self._cat.stdin.close()
            self._cat.wait(timeout=10)
        except (OSError, subprocess.SubprocessError):
            self._cat.kill()


def tree_entries(repo: str, sha: str) -> List[Tuple[str, str]]:
    """(path, blob) for the production Swift files of a commit."""
    out = _git(repo, "ls-tree", "-r", "-z", sha, "--", *cm.SWIFT_ROOTS)
    entries = []
    for rec in out.split("\0"):
        if not rec or "\t" not in rec:
            continue
        meta, path = rec.split("\t", 1)
        parts = meta.split()
        if len(parts) == 3 and parts[1] == "blob" and cm.in_scope(path):
            entries.append((path, parts[2]))
    return entries


def module_row(entries: Sequence[Tuple[str, str]], cache: BlobCache, sha: str, when: _dt.datetime,
               mapper, fixes: Optional[Dict[str, Dict[str, int]]]) -> dict:
    """One counts-only modules.jsonl row (the nightly's `modules` minus names)."""
    file_lines = {path: cache.seen[blob][0] for path, blob in entries}
    funcs = [(path, ccn) for path, blob in entries for ccn in cache.seen[blob][1]]
    ok = sum(1 for p in file_lines if mapper(p))
    return {
        "schemaVersion": 1,
        "ts": when.astimezone(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "sha": sha[:8],
        "run_kind": "backfill",
        "modules": cm.module_counts(funcs, file_lines, mapper, fixes),
        "files_mapped_pct": round(100.0 * ok / len(file_lines), 1) if file_lines else None,
    }


def run_modules(a) -> int:
    t0, c0 = time.monotonic(), time.process_time()
    stop_at = t0 + a.budget_minutes * 60
    today = _dt.date.today()
    picks = choose_commits(main_history(a.repo, a.ref), today - _dt.timedelta(days=a.module_days), today,
                           a.module_days)
    current = cm.list_files(a.repo)
    mapper = cm.module_mapper(current)
    fix_mapper = cm.module_mapper(current, by_name_first=True)
    commits = cm.fix_commits(a.repo, a.ref)
    print(f"START module backfill: {len(picks)} days, budget {a.budget_minutes} min")
    cache = BlobCache(a.repo)
    rows: List[dict] = []
    skipped = 0
    try:
        for i, (sha, when) in enumerate(picks):
            if time.monotonic() >= stop_at:
                skipped = len(picks) - i
                break
            entries = tree_entries(a.repo, sha)
            cache.measure(entries)
            fixes = cm.fix_counts(commits, when.timestamp(), fix_mapper) if commits is not None else None
            row = module_row(entries, cache, sha, when, mapper, fixes)
            rows.append(row)
            print(f"  {row['ts'][:10]} {sha[:8]}  modules {len(row['modules']):>2}  "
                  f"lines {sum(m['lines'] for m in row['modules'].values()):>7}  "
                  f"mapped {row['files_mapped_pct']}%  blobs measured {cache.measured}", flush=True)
    finally:
        cache.close()
    out = Path(a.modules_out).expanduser()
    out.parent.mkdir(parents=True, exist_ok=True)
    by_day = {}
    if out.exists():
        for line in out.read_text().splitlines():
            try:
                r = json.loads(line)
                by_day[r["ts"][:10]] = r
            except (ValueError, KeyError, TypeError):
                continue
    for r in rows:
        by_day[r["ts"][:10]] = r
    out.write_text("".join(json.dumps(by_day[k], sort_keys=True, separators=(",", ":")) + "\n"
                           for k in sorted(by_day)))
    elapsed, cpu = time.monotonic() - t0, time.process_time() - c0
    result = "not published (--no-publish)"
    if not a.no_publish and rows:
        import publish_metrics as pm
        try:
            result = pm.publish({"modules.jsonl": rows}, folders=pm.source_folders())
        except (pm.PrivacyError, pm.PublishError, OSError, subprocess.SubprocessError) as exc:
            print(f"OUTCOME failed: {len(rows)} module rows in {elapsed:.0f}s, publish failed: {exc}")
            return 1
    print(f"OUTCOME ok: {len(rows)} module rows in {elapsed:.0f}s ({cpu:.0f}s CPU here, {cache.measured} blobs "
          f"through lizard, {skipped} days skipped for time); {result}; local copy {out}")
    return 0


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--modules", action="store_true",
                    help="per-module history for the Module health table (metrics/modules.jsonl)")
    ap.add_argument("--module-days", type=int, default=60)
    ap.add_argument("--modules-out", default=str(DEFAULT_MODULES_OUT))
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
    if a.modules:
        return run_modules(a)

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
