#!/usr/bin/env python3
"""Morning lines for the nightly findings ticket (Rick 2026-10-02: "organized
in such a way as we won't ignore the issues").

scripts/morning_metrics.sh pipes metrics/nightly_findings_latest.json from
origin/metrics into this script. That file is the summary
tools/nightly_findings_to_issues.py writes, and the nightly's aggregate job
commits it. Output, printed ABOVE everything else in the morning digest:

  🔴 tonight's ticket has any NEW high or NEW medium finding (with the
     ticket URL and the first few items)
  ⚠️ a high-severity tracking issue has been open more than 7 days (with
     the issue numbers, their ages, and the ticket URL)
  🟡 the run was a dry run (writes off): what it would have written
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
STALE_TRACKING_DAYS = 7


def _ticket_ref(summary: dict) -> str:
    t = summary.get("ticket") or {}
    if t.get("url"):
        return str(t["url"])
    if summary.get("dry_run"):
        return "(dry run: no ticket written)"
    return "(ticket URL unavailable)"


def _day(s) -> _dt.date | None:
    try:
        return _dt.datetime.strptime(str(s)[:10], "%Y-%m-%d").date()
    except ValueError:
        return None


def alert_lines(summary: dict, now: _dt.datetime, max_age_hours: float = 36) -> list[str]:
    if not isinstance(summary, dict):
        return []
    day = _day(summary.get("date", ""))
    if day is None:
        return []
    # The summary date is the UTC night of the run. Measure age from the end
    # of that day, so a 05:00 UTC run read at 15:00 ET is still "last night".
    end_of_day = _dt.datetime.combine(day, _dt.time(), tzinfo=_dt.timezone.utc) + _dt.timedelta(days=1)
    if (now - end_of_day).total_seconds() / 3600 > max_age_hours:
        return []
    dry = bool(summary.get("dry_run"))
    ref = _ticket_ref(summary)
    out: list[str] = []

    highs = summary.get("new_high") or []
    mediums = summary.get("new_medium") or []
    if highs or mediums:
        out.append(f"🔴 Nightly findings {summary.get('date')}: {len(highs)} NEW high, "
                   f"{len(mediums)} NEW medium — {ref}")
        items = [("high", it) for it in highs] + [("medium", it) for it in mediums]
        for sev, it in items[:MAX_LISTED]:
            tag = ""
            if it.get("issue") and not dry:
                tag = f" (tracking #{it['issue']})"
            out.append(f"   [{sev}] {it.get('title', it.get('fp', '?'))}{tag}")
        if len(items) > MAX_LISTED:
            out.append(f"   … and {len(items) - MAX_LISTED} more in the ticket")

    tracking = summary.get("tracking") or {}
    stale = []
    for t in tracking.get("open_high") or []:
        since = _day(t.get("since"))
        if since is None or not t.get("issue"):
            continue
        age = (now.date() - since).days
        if age > STALE_TRACKING_DAYS:
            stale.append((age, t))
    if stale:
        stale.sort(key=lambda x: -x[0])
        listed = ", ".join(f"#{t['issue']} ({age} d)" for age, t in stale[:MAX_LISTED])
        more = f" and {len(stale) - MAX_LISTED} more" if len(stale) > MAX_LISTED else ""
        out.append(f"⚠️ {len(stale)} high-severity tracking issue(s) open more than "
                   f"{STALE_TRACKING_DAYS} days: {listed}{more} — {ref}")

    plan = summary.get("plan") or {}
    if dry and plan:
        tk = (plan.get("ticket") or {}).get("action", "?")
        out.append(
            f"🟡 Nightly findings DRY RUN ({summary.get('date')}): would {tk} the nightly ticket, "
            f"open {len(plan.get('would_open', []))} tracking issue(s), reopen "
            f"{len(plan.get('would_reopen', []))}, comment {len(plan.get('would_comment', []))}, "
            f"close {len(plan.get('would_close', []))}. Writes need repo variable "
            "NIGHTLY_FINDINGS_WRITE=true on main.")

    errs = summary.get("errors") or []
    if errs:
        out.append(f"🔴 Nightly findings pipeline had {len(errs)} gh error(s); the ticket may be stale — {ref}")
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
