#!/usr/bin/env python3
"""Morning 🔴 line for new high-severity nightly findings.

scripts/morning_metrics.sh pipes metrics/nightly_findings_latest.json from
origin/metrics into this script. That file is the summary
tools/nightly_findings_to_issues.py writes, and the nightly's aggregate job
commits it. When last night produced a NEW high-severity finding, this
prints a 🔴 block, which morning_metrics.sh shows above everything else.
Otherwise it prints nothing.

Quiet on purpose for: an empty or unparseable input, a dry-run summary
(branch validation runs), and a summary older than --max-age-hours (36).
A stale alarm teaches people to ignore the alarm. A broken findings
pipeline (gh errors) is reported too, because it means issues stopped
being filed.

Usage:  git show origin/metrics:metrics/nightly_findings_latest.json \
            | python3 scripts/nightly_findings_alert.py
        python3 scripts/nightly_findings_alert.py --file summary.json --now 2026-10-02
"""
from __future__ import annotations

import argparse
import datetime as _dt
import json
import sys

MAX_LISTED = 5


def alert_lines(summary: dict, now: _dt.datetime, max_age_hours: float = 36) -> list[str]:
    if not isinstance(summary, dict) or summary.get("dry_run"):
        return []
    try:
        day = _dt.datetime.strptime(str(summary.get("date", "")), "%Y-%m-%d").replace(
            tzinfo=_dt.timezone.utc)
    except ValueError:
        return []
    # The summary date is the UTC night of the run. Measure age from the end
    # of that day, so a 05:00 UTC run read at 15:00 ET is still "last night".
    age_h = (now - (day + _dt.timedelta(days=1))).total_seconds() / 3600
    if age_h > max_age_hours:
        return []
    out: list[str] = []
    highs = summary.get("new_high") or []
    if highs:
        out.append(f"🔴 {len(highs)} NEW high-severity nightly finding(s) ({summary.get('date')}):")
        for it in highs[:MAX_LISTED]:
            ref = f"#{it['issue']}" if it.get("issue") else "(in digest)"
            out.append(f"   {ref} {it.get('title', it.get('fp', '?'))}")
        if len(highs) > MAX_LISTED:
            out.append(f"   … and {len(highs) - MAX_LISTED} more. Label: High Priority + nightly-finding")
    errs = summary.get("errors") or []
    if errs:
        out.append(f"🔴 Nightly findings → issues pipeline had {len(errs)} gh error(s); issues may be stale.")
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--file")
    ap.add_argument("--now", help="ISO date/time (tests); default: now, UTC")
    ap.add_argument("--max-age-hours", type=float, default=36)
    args = ap.parse_args(argv)
    raw = open(args.file, encoding="utf-8").read() if args.file else sys.stdin.read()
    try:
        summary = json.loads(raw) if raw.strip() else {}
    except json.JSONDecodeError:
        return 0
    if args.now:
        now = _dt.datetime.fromisoformat(args.now)
        if now.tzinfo is None:
            now = now.replace(tzinfo=_dt.timezone.utc)
    else:
        now = _dt.datetime.now(_dt.timezone.utc)
    for line in alert_lines(summary, now, args.max_age_hours):
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
