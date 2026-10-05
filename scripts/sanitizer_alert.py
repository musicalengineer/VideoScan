#!/usr/bin/env python3
"""Morning lines for the weekly sanitizer runs (scripts/weekly_sanitizer.py).

Printed by scripts/morning_metrics.sh ABOVE the test table:
  🔴 a run found sanitizer reports (with the unique findings and the log path)
  🔴 a run failed to build, failed tests, timed out, or ran no tests
  🟡 a run was skipped because the M4 was busy
Quiet when every run in the window is ok, and for rows older than
--max-age-days (8): one weekly run per kind is "current" for a week.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import sys
from pathlib import Path

LOGDIR = Path.home() / "Library" / "Logs" / "VideoScan" / "sanitizer"
NAMES = {"address": "Address Sanitizer", "thread": "Thread Sanitizer"}
MAX_LISTED = 4


def lines_for(row: dict, now: dt.datetime, max_age_days: float) -> list[str]:
    try:
        started = dt.datetime.fromisoformat(row["started"])
    except (KeyError, ValueError):
        return []
    if (now - started).total_seconds() > max_age_days * 86400:
        return []
    name = NAMES.get(row.get("kind", ""), row.get("kind", "sanitizer"))
    when = started.strftime("%a %b %d")
    status = row.get("status")
    if status == "ok":
        return []
    if status == "findings":
        findings = row.get("unique_findings") or []
        out = [f"🔴 {name} ({when}, {row.get('sha', '?')}): {len(findings) or row.get('reports', 0)} "
               f"finding(s) — log {row.get('log', '?')}"]
        out += [f"     • {f}" for f in findings[:MAX_LISTED]]
        if len(findings) > MAX_LISTED:
            out.append(f"     • …and {len(findings) - MAX_LISTED} more")
        return out
    if status == "skipped-busy":
        return [f"🟡 {name} ({when}) skipped — {row.get('reason', 'M4 busy')}"]
    detail = {"build-failed": "build failed", "tests-failed": "tests failed",
              "timeout": "timed out", "no-tests-ran": "no tests ran"}.get(status, status or "unknown")
    failed = row.get("failed_tests") or []
    tail = f": {', '.join(failed[:MAX_LISTED])}" if failed else ""
    return [f"🔴 {name} ({when}, {row.get('sha', '?')}): {detail}{tail} — log {row.get('log', '?')}"]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(LOGDIR))
    ap.add_argument("--now", help="ISO datetime (tests)")
    ap.add_argument("--max-age-days", type=float, default=8)
    args = ap.parse_args(argv)
    now = dt.datetime.fromisoformat(args.now) if args.now else dt.datetime.now().astimezone()
    out: list[str] = []
    for kind in ("address", "thread"):
        f = Path(args.dir) / f"latest-{kind}.json"
        try:
            row = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        out += lines_for(row, now, args.max_age_days)
    if out:
        print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
