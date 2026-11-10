#!/usr/bin/env python3
"""repo_traffic.py — a daily record of who is looking at the public GitHub repo.

Rick 2026-11-10: "I would like to know if anyone clones this repo."

What GitHub gives, and does not:
  * clones and page views per day, as COUNTS (total and unique). Never who.
    Kept for 14 days only, so this script saves each day to days.jsonl.
  * our own machinery is in those counts: every GitHub Actions job that checks
    the repo out is a clone, and each runner is a new "unique". The counts
    cannot be split into ours and outsiders'; the line says so by showing the
    day's Actions JOBS beside them (our_ci_jobs). A run is several jobs and
    each job checks out on its own fresh machine, so runs alone undercount us:
    2026-11-03 had 40 runs but 102 jobs (638 clones, 179 unique).
  * forks, stars and referring sites ARE named. A new one is an event.

Each run: fetch, merge the days into days.jsonl (a day's numbers keep rising
until it ends, so the larger reading wins), compare the named things with
seen.json, and write latest.json for the session-start banner. The last line
printed is one OUTCOME line. Exit 0 always: this is never a reason for a
nightly to fail.

State (not in git, nothing is published): ~/Library/Logs/VideoScan/repo-traffic/
Run: scripts/repo_traffic.py [--repo owner/name] [--dir <state dir>]
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Callable, Dict, List, Optional

REPO = "musicalengineer/VideoScan"
STATE = Path.home() / "Library" / "Logs" / "VideoScan" / "repo-traffic"
JOBS_RECHECK_DAYS = 2                                       # a recent day's job count is asked for again
GH_FALLBACKS = ("/opt/homebrew/bin/gh", "/usr/local/bin/gh")


def find_gh() -> Optional[str]:
    """launchd jobs run without Homebrew on PATH."""
    return shutil.which("gh") or next((p for p in GH_FALLBACKS if os.access(p, os.X_OK)), None)


def gh_api(path: str, gh: Optional[str] = None, run: Callable = subprocess.run):
    """One GET, parsed. Raises RuntimeError with gh's own words on any failure."""
    gh = gh or find_gh()
    if not gh:
        raise RuntimeError("gh is not installed")
    try:
        p = run([gh, "api", path], capture_output=True, text=True, timeout=60, stdin=subprocess.DEVNULL)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f"gh api {path}: {type(e).__name__}") from e
    if p.returncode != 0:
        raise RuntimeError(f"gh api {path}: {' '.join((p.stderr or '').split())[:160] or 'exit ' + str(p.returncode)}")
    try:
        return json.loads(p.stdout)
    except ValueError as e:
        raise RuntimeError(f"gh api {path}: not JSON") from e


def fetch(repo: str, api: Callable = gh_api) -> dict:
    """Everything one run needs, as plain values."""
    clones = api(f"repos/{repo}/traffic/clones").get("clones") or []
    views = api(f"repos/{repo}/traffic/views").get("views") or []
    days: Dict[str, dict] = {}
    for rows, total, unique in ((clones, "clones", "cloners"), (views, "views", "visitors")):
        for r in rows:
            day = str(r.get("timestamp", ""))[:10]
            if len(day) == 10:
                days.setdefault(day, {"day": day}).update({total: int(r.get("count") or 0), unique: int(r.get("uniques") or 0)})
    since = (min(days) if days else dt.date.today().isoformat())
    runs: Dict[str, list] = {}                              # day -> that day's run ids
    for page in range(1, 11):                               # at most 1,000 runs in the 14-day window
        got = api(f"repos/{repo}/actions/runs?per_page=100&page={page}&created=>={since}").get("workflow_runs") or []
        for r in got:
            runs.setdefault(str(r.get("created_at", ""))[:10], []).append(r.get("id"))
        if len(got) < 100:
            break
    for day, row in days.items():
        row["our_ci_runs"] = len(runs.get(day, []))
    return {
        "days": days,
        "run_ids": {day: ids for day, ids in runs.items() if day in days},
        "forks": sorted(str((f.get("owner") or {}).get("login") or "?") for f in api(f"repos/{repo}/forks?per_page=100")),
        "stars": sorted(str(s.get("login") or "?") for s in api(f"repos/{repo}/stargazers?per_page=100")),
        "referrers": sorted(str(r.get("referrer") or "?") for r in api(f"repos/{repo}/traffic/popular/referrers")),
    }


def count_jobs(repo: str, now: dict, saved: Dict[str, dict], today: str, api: Callable = gh_api) -> None:
    """Add our_ci_jobs to each fetched day that needs it: the sum of its runs'
    job counts. One API call per run, so it is asked only for a day that has no
    saved count yet, or for today and the two days before (their runs may still
    be finishing or be re-run). Worst case is the first run after this field
    was added: every run in the 14-day window, at most 1,000 calls; after that
    about three days' worth. A day not asked for gets no field here and keeps
    its saved count through merge_days. Any failure raises, before anything is
    written, like every other fetch."""
    recent = (dt.date.fromisoformat(today) - dt.timedelta(days=JOBS_RECHECK_DAYS)).isoformat()
    for day, row in now["days"].items():
        if day < recent and "our_ci_jobs" in saved.get(day, {}):
            continue
        row["our_ci_jobs"] = sum(
            int(api(f"repos/{repo}/actions/runs/{run_id}/jobs?per_page=1").get("total_count") or 0)
            for run_id in now.get("run_ids", {}).get(day, []) if run_id is not None)


def load_days(path: Path) -> Dict[str, dict]:
    days: Dict[str, dict] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if isinstance(row, dict) and isinstance(row.get("day"), str):
                days[row["day"]] = row
    except OSError:
        pass
    return days


def merge_days(old: Dict[str, dict], new: Dict[str, dict]) -> Dict[str, dict]:
    """Every day ever seen. A day still in GitHub's window takes the larger
    reading of each number (a day's counts only rise); a day that has left the
    window keeps what was saved."""
    out = {day: dict(row) for day, row in old.items()}
    for day, row in new.items():
        kept = out.setdefault(day, {"day": day})
        for key, value in row.items():
            if key != "day":
                kept[key] = max(int(kept.get(key) or 0), int(value or 0))
    return out


def events(seen: Optional[dict], now: dict) -> List[str]:
    """The named things that are new since the last run. On the very first run
    (no seen.json) everything present is reported once, marked as already there."""
    first = seen is None
    seen = seen or {}
    out = []
    for key, word in (("forks", "fork by"), ("stars", "star from"), ("referrers", "link from")):
        for name in now.get(key, []):
            if name not in (seen.get(key) or []):
                out.append(f"{'already there: ' if first else 'NEW '}{word} {name}")
    return out


def headline(days: Dict[str, dict], evs: List[str], today: str) -> str:
    """Yesterday's numbers (the last finished day) and any events."""
    done = sorted(d for d in days if d < today)
    if not done:
        return "no finished day in GitHub's window yet" + ("; " + "; ".join(evs) if evs else "")
    d = days[done[-1]]
    if "our_ci_jobs" in d:                                  # each job is one checkout, so one clone
        n = d["our_ci_jobs"]
        ours = f"our own CI made {n} checkout{'s' if n != 1 else ''} that day"
    else:                                                   # jobs never counted for this day: unknown, not 0
        n = d.get("our_ci_runs", 0)
        ours = f"our own CI ran {n} time{'s' if n != 1 else ''} that day"
    line = (f"{done[-1]}: {d.get('clones', 0)} clones ({d.get('cloners', 0)} unique), "
            f"{d.get('views', 0)} page views ({d.get('visitors', 0)} unique); {ours}")
    return line + ("; " + "; ".join(evs) if evs else "")


def write_atomic(path: Path, text: str) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.replace(tmp, path)


def run_once(repo: str, state: Path, today: str, api: Callable = gh_api) -> str:
    state.mkdir(parents=True, exist_ok=True)
    now = fetch(repo, api)
    saved = load_days(state / "days.jsonl")
    count_jobs(repo, now, saved, today, api)
    days = merge_days(saved, now["days"])
    try:
        seen = json.loads((state / "seen.json").read_text(encoding="utf-8"))
        seen = seen if isinstance(seen, dict) else None
    except (OSError, ValueError):
        seen = None
    evs = events(seen, now)
    line = headline(days, evs, today)
    write_atomic(state / "days.jsonl", "".join(json.dumps(days[d], sort_keys=True) + "\n" for d in sorted(days)))
    # Names are remembered for good: a fork deleted and made again is not news twice.
    remembered = {k: sorted(set((seen or {}).get(k) or []) | set(now[k])) for k in ("forks", "stars", "referrers")}
    write_atomic(state / "seen.json", json.dumps(remembered, indent=1, sort_keys=True) + "\n")
    write_atomic(state / "latest.json", json.dumps(
        {"date": today, "headline": line, "events": evs, "alert": any(e.startswith("NEW ") for e in evs)},
        indent=1, sort_keys=True) + "\n")
    return line


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--repo", default=REPO)
    ap.add_argument("--dir", default=str(STATE))
    a = ap.parse_args(argv)
    try:
        print("OUTCOME ok: " + run_once(a.repo, Path(a.dir).expanduser(), dt.date.today().isoformat()))
    except Exception as e:                                  # never a reason for the nightly to fail
        print(f"OUTCOME failed: {type(e).__name__}: {' '.join(str(e).split())[:200]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
