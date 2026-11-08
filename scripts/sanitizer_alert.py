#!/usr/bin/env python3
"""Morning lines for the weekly sanitizer runs (scripts/weekly_sanitizer.py).

Printed by scripts/morning_metrics.sh ABOVE the test table:
  🔴 a run found sanitizer reports (with the unique findings and the log path)
  🔴 a run failed to build, failed tests, timed out, or ran no tests
  🟡 a run was skipped because the M4 was busy
Quiet when every run in the window is ok, and for rows older than
--max-age-days (8): one weekly run per kind is "current" for a week.

The runs happen on the M4; the latest-<kind>.json files are there only. On any
other Mac (the Ultra, where Rick reads the digest) `--published FILE|-` reads
metrics/sanitizer.jsonl, the counts tools/publish_metrics.py publishes from the
M4 (2026-11-04: the 11/01 TSan race and the 10/31 UBSan report never reached
the Ultra). Local files win when they exist. A published row carries counts,
not the findings' text; the line says where the logs are.

Known findings (2026-11-08): reports matched by scripts/sanitizer/*.supp are
never printed, so they are not findings and do not make a line red; a red line
for some other reason says how many known findings were held back and their
issues. A run that is ok apart from suppressed findings stays quiet, the same
rule as the metrics card (red = something new to go and look at).

Findings only in test code (Rick 2026-11-08; status "test-findings": every
frame of ours is in VideoScanTests/ or a package's Tests/) are a grey ⚪ line,
"fix when convenient", never red.
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
COUNTS = (("asan_issues", "ASan"), ("ubsan_issues", "UBSan"), ("tsan_issues", "TSan"))
M4_LOGS = "on the M4 (~/Library/Logs/VideoScan/sanitizer/)"


def suppressed_words(row: dict) -> str:
    """'; 1 known finding suppressed (#462)' or '' — for the end of a red line."""
    known = [s for s in (row.get("suppressed") or []) if isinstance(s, dict)]
    if not known:
        return ""
    issues = ", ".join(f"#{s['issue']}" for s in known if isinstance(s.get("issue"), int))
    return f"; {len(known)} known finding{'' if len(known) == 1 else 's'} suppressed" + (f" ({issues})" if issues else "")


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
        count = row.get("finding_count") or len(findings) or row.get("reports", 0)
        restarts = row.get("host_restarts") or 0
        crashed = f"; the test host restarted {restarts}× (some tests never ran)" if restarts else ""
        out = [f"🔴 {name} ({when}, {row.get('sha', '?')}): {count} "
               f"finding(s){crashed}{suppressed_words(row)} — log {row.get('log', '?')}"]
        out += [f"     • {f}" for f in findings[:MAX_LISTED]]
        if len(findings) > MAX_LISTED:
            out.append(f"     • …and {len(findings) - MAX_LISTED} more")
        return out
    if status == "test-findings":
        findings = row.get("test_only_findings") or []
        count = row.get("test_only_issues") or len(findings) or 1
        out = [f"⚪ {name} ({when}, {row.get('sha', '?')}): {count} finding(s) in test code only — "
               f"fix when convenient{suppressed_words(row)} — log {row.get('log', '?')}"]
        return out + [f"     • {f}" for f in findings[:MAX_LISTED]]
    if status == "skipped-busy":
        return [f"🟡 {name} ({when}) skipped — {row.get('reason', 'M4 busy')}"]
    detail = {"build-failed": "build failed", "tests-failed": "tests failed",
              "timeout": "timed out", "no-tests-ran": "no tests ran",
              "config-error": f"suppression file refused, nothing ran ({row.get('reason', 'see the runner')})",
              "host-crashed": f"the test host crashed {row.get('host_restarts', 1)}× and was relaunched "
                              "(some tests never ran — see the .ips in DiagnosticReports)"}.get(status, status or "unknown")
    failed = row.get("failed_tests") or []
    tail = f": {', '.join(failed[:MAX_LISTED])}" if failed else ""
    return [f"🔴 {name} ({when}, {row.get('sha', '?')}): {detail}{tail}{suppressed_words(row)} — log {row.get('log', '?')}"]


def from_published(row: dict, now: dt.datetime) -> dict | None:
    """A metrics/sanitizer.jsonl row in the shape lines_for() reads, or None."""
    try:
        started = dt.datetime.combine(dt.date.fromisoformat(row["date"]), dt.time(12), tzinfo=now.tzinfo)
    except (KeyError, TypeError, ValueError):
        return None
    counts = [(label, row[key]) for key, label in COUNTS
              if isinstance(row.get(key), int) and not isinstance(row.get(key), bool)]
    return {"kind": row.get("kind"), "started": started.isoformat(), "sha": row.get("sha") or "?",
            "status": row.get("status"), "reports": row.get("reports") or 0,
            "host_restarts": row.get("host_restarts") or 0, "finding_count": sum(v for _, v in counts),
            "unique_findings": [f"{label}: {v} unique finding{'' if v == 1 else 's'}" for label, v in counts if v],
            "failed_tests": [], "log": M4_LOGS,
            "suppressed": [s for s in (row.get("suppressed") or []) if isinstance(s, dict)],
            "test_only_issues": row.get("test_only_issues") if isinstance(row.get("test_only_issues"), int) else None}


def published_latest(text: str, now: dt.datetime) -> dict:
    """kind -> the newest published row of that kind, alert-shaped."""
    latest: dict = {}
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        shaped = from_published(row, now) if isinstance(row, dict) else None
        if shaped and shaped["kind"] in NAMES and (shaped["kind"] not in latest
                                                    or latest[shaped["kind"]]["started"] <= shaped["started"]):
            latest[shaped["kind"]] = shaped
    return latest


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(LOGDIR))
    ap.add_argument("--now", help="ISO datetime (tests)")
    ap.add_argument("--max-age-days", type=float, default=8)
    ap.add_argument("--published", help="metrics/sanitizer.jsonl (a path, or - for stdin): used for each "
                                        "kind that has no local latest-<kind>.json")
    args = ap.parse_args(argv)
    now = dt.datetime.fromisoformat(args.now) if args.now else dt.datetime.now().astimezone()
    published: dict = {}
    if args.published:
        try:
            text = sys.stdin.read() if args.published == "-" else Path(args.published).read_text()
        except OSError:
            text = ""
        published = published_latest(text, now)
    out: list[str] = []
    for kind in ("address", "thread"):
        f = Path(args.dir) / f"latest-{kind}.json"
        try:
            row = json.loads(f.read_text())
        except (OSError, ValueError):
            row = published.get(kind)
            if row is None:
                continue
        out += lines_for(row, now, args.max_age_days)
    if out:
        print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
