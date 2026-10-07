#!/usr/bin/env python3
"""Morning lines for the nightly Hallie advisory replay (Rick, 2026-10-06).

The 10/5 02:30 replay caught "People profiles are unavailable" on ~90
questions — decline rate 21.5% -> 28.8%, a brand-new decline reason — and
nothing surfaced it. This prints, from the local nightly artifacts
(~/Library/Logs/VideoScan/hallie-eval/nightly-<STAMP>-advisory.graded.jsonl,
written by scripts/nightly_hallie_replay.sh), ABOVE the test table:

  🔴 the decline rate rose more than --jump-points (5) night over night
  🔴 a decline reason that was absent the night before now covers at least
     --new-reason-min (5) questions (one-offs are name-specific noise)
  🟡 the newest run is incomplete, or older than --max-age-hours (36)
  one plain line every morning: pass rate, decline rate (and its change),
     the top decline reasons

A decline is a turn whose outcome (any clause's) is "declined"; its reason is
the turn's Basis line (else the answer's first sentence), normalised so
quoted words and numbers do not split one reason into many. A pass is a turn
with no defect flag — the same "clean" hallie_eval.py grade reports.

Read-only. Quiet on hosts without the log dir. Never fails the digest.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
from collections import Counter
from pathlib import Path

LOGDIR = Path.home() / "Library" / "Logs" / "VideoScan" / "hallie-eval"
RUN_GLOB = "nightly-*-advisory.graded.jsonl"
STAMP_RE = re.compile(r"nightly-(\d{8}T\d{6})-advisory")
TOP_REASONS = 3


def decline_reason(rec: dict) -> str:
    """One short, stable label for why a turn declined."""
    src = (rec.get("basis") or "").strip() or (rec.get("answer") or "").strip()
    s = re.sub(r"^(Basis|Checked):\s*", "", src)
    s = re.split(r"(?<=[.;:])\s", s, maxsplit=1)[0]
    s = re.sub(r"[“\"][^”\"]*[”\"]", "“…”", s)
    s = re.sub(r"\d+", "N", s)
    s = s.rstrip(" .;:")
    return (s[:80] or "(no reason given)")


def is_declined(rec: dict) -> bool:
    return rec.get("outcome") == "declined" or "declined" in (rec.get("outcomes") or [])


def is_pass(rec: dict) -> bool:
    return not [f for f in (rec.get("flags") or []) if not str(f).startswith("~")]


def summarize(records) -> dict:
    """Numbers for one run. `records` is any iterable of graded turns."""
    n = passed = declined = 0
    reasons: Counter = Counter()
    for r in records:
        n += 1
        passed += is_pass(r)
        if is_declined(r):
            declined += 1
            reasons[decline_reason(r)] += 1
    return {"n": n, "pass": passed, "declined": declined,
            "pass_rate": 100.0 * passed / n if n else 0.0,
            "decline_rate": 100.0 * declined / n if n else 0.0,
            "reasons": reasons}


def alert_lines(today: dict, prev: dict | None, *, when: str = "",
                jump_points: float = 5.0, new_reason_min: int = 5) -> list[str]:
    """🔴 lines first, then the one plain numbers line."""
    out: list[str] = []
    tag = f" ({when})" if when else ""
    delta = None
    if prev and prev.get("n"):
        delta = today["decline_rate"] - prev["decline_rate"]
        if delta > jump_points:
            out.append(f"🔴 Hallie eval{tag}: decline rate jumped {prev['decline_rate']:.1f}% → "
                       f"{today['decline_rate']:.1f}% (+{delta:.1f} pts, alarm at +{jump_points:g})")
        for reason, count in today["reasons"].most_common():
            if count < new_reason_min:
                break
            if reason not in prev["reasons"]:
                out.append(f"🔴 Hallie eval{tag}: NEW decline reason on {count} questions — “{reason}”")
    change = f" ({delta:+.1f})" if delta is not None else ""
    top = "; ".join(f"{c}× {r}" for r, c in today["reasons"].most_common(TOP_REASONS))
    out.append(f"Hallie eval{tag}: pass {today['pass_rate']:.1f}% · declines "
               f"{today['decline_rate']:.1f}%{change} of {today['n']}"
               + (f" · top: {top}" if top else ""))
    return out


def _runs(logdir: Path) -> list[tuple[str, Path]]:
    found = []
    for p in logdir.glob(RUN_GLOB):
        m = STAMP_RE.search(p.name)
        if m:
            found.append((m.group(1), p))
    return sorted(found)


def _read(path: Path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                yield json.loads(line)


def _complete(graded: Path) -> bool:
    """The grader's own verdict, from the sibling summary; absent = trust it."""
    summary = graded.with_name(graded.name.replace(".graded.jsonl", ".summary.json"))
    try:
        return json.loads(summary.read_text()).get("incomplete") is not True
    except (OSError, ValueError):
        return True


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dir", default=str(LOGDIR))
    ap.add_argument("--now", help="ISO datetime (tests)")
    ap.add_argument("--jump-points", type=float, default=5.0)
    ap.add_argument("--new-reason-min", type=int, default=5)
    ap.add_argument("--max-age-hours", type=float, default=36)
    args = ap.parse_args(argv)
    try:
        runs = [(s, p) for s, p in _runs(Path(args.dir)) if p.stat().st_size > 0]
        if not runs:
            return 0
        stamp, latest = runs[-1]
        started = dt.datetime.strptime(stamp, "%Y%m%dT%H%M%S")
        now = dt.datetime.fromisoformat(args.now) if args.now else dt.datetime.now()
        when = started.strftime("%a %b %d")
        out: list[str] = []
        if (now - started).total_seconds() > args.max_age_hours * 3600:
            out.append(f"🟡 Hallie eval has not run since {when} — check the nightly")
        if not _complete(latest):
            out.append(f"🟡 Hallie eval ({when}) incomplete — numbers below are partial; no comparison")
            prev = None
        else:
            prev_runs = [p for _, p in runs[:-1] if _complete(p)]
            prev = summarize(_read(prev_runs[-1])) if prev_runs else None
        out += alert_lines(summarize(_read(latest)), prev, when=when,
                           jump_points=args.jump_points, new_reason_min=args.new_reason_min)
        print("\n".join(out))
    except (OSError, ValueError) as e:  # never fail the digest, but say so
        print(f"🟡 Hallie eval numbers unavailable: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
