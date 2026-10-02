#!/usr/bin/env python3
"""Morning lines for the nightly findings → issues pipeline.

scripts/morning_metrics.sh pipes metrics/nightly_findings_latest.json from
origin/metrics into this script. That file is the summary
tools/nightly_findings_to_issues.py writes, and the nightly's aggregate job
commits it. Output, printed ABOVE everything else in the morning digest:

  🔴 new high-severity findings last night (filed, or would be filed)
  🟡 while writes are off (dry run, the default until Rick sets the repo
     variable NIGHTLY_FINDINGS_WRITE=true): exactly what the nightly WOULD
     have done: open / comment / close counts, the would-open titles, and
     the low-severity digest deltas
  🔴 the pipeline itself had gh errors

Quiet for an empty or unparseable input, and for a summary older than
--max-age-hours (36). A stale alarm teaches people to ignore the alarm.

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
    if not isinstance(summary, dict):
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
    dry = bool(summary.get("dry_run"))
    out: list[str] = []
    highs = summary.get("new_high") or []
    if highs:
        verb = "would be filed — writes are off" if dry else "filed"
        out.append(f"🔴 {len(highs)} NEW high-severity nightly finding(s) ({summary.get('date')}, {verb}):")
        for it in highs[:MAX_LISTED]:
            if dry or not it.get("issue"):
                ref = "(would open)" if it.get("issue") else "(overflow digest)"
            else:
                ref = f"#{it['issue']}"
            out.append(f"   {ref} {it.get('title', it.get('fp', '?'))}")
        if len(highs) > MAX_LISTED:
            out.append(f"   … and {len(highs) - MAX_LISTED} more")
    plan = summary.get("plan") or {}
    if dry and plan:
        out.append(
            f"🟡 Nightly findings DRY RUN ({summary.get('date')}): would open "
            f"{len(plan.get('would_open', []))}, reopen {len(plan.get('would_reopen', []))}, "
            f"comment {len(plan.get('would_comment', []))}, close {len(plan.get('would_close', []))}; "
            f"overflow {summary.get('overflow', 0)}. Turn on with repo variable NIGHTLY_FINDINGS_WRITE=true.")
        for o in (plan.get("would_open") or [])[:MAX_LISTED]:
            out.append(f"   would open [{o.get('severity', '?')}] {o.get('title', '?')}")
        lows = summary.get("low_digests") or {}
        if lows:
            parts = [f"{t} {d.get('count', 0)} (+{d.get('new', 0)}/−{d.get('gone', 0)})"
                     for t, d in lows.items()]
            out.append("   low digests: " + ", ".join(parts))
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
