#!/usr/bin/env python3
"""Claude Code status line: the codex review cycles, one short line.

Reads the same review-cycles.json that tools/codex_review.py writes and the
menu-bar monitor shows, and prints the newest cycles that are still open
(plus one that closed in the last 10 minutes, so a finish is visible). Prints
nothing when there is nothing to show, so the status line stays empty.

Colours match the monitor: green < 10 min in a phase (or closed), yellow
10–30 min, red > 30 min, a `running` cycle whose codex pid is gone, or
`failed`. Claude Code passes session JSON on stdin; it is not needed here.
"""
import json
import os
import sys
from datetime import datetime, timezone

STATE = os.environ.get(
    "VIDEOSCAN_REVIEW_CYCLES",
    os.path.expanduser(
        "~/Library/Application Support/VideoScan/team-channel/review-cycles.json"
    ),
)
GREEN, YELLOW, RED, DIM, RESET = "\033[32m", "\033[33m", "\033[31m", "\033[2m", "\033[0m"


def parse(ts):
    try:
        return datetime.fromisoformat(ts.replace("Z", "+00:00"))
    except Exception:
        return None


def alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def age_words(seconds):
    m = int(seconds // 60)
    return f"{m}m" if m < 60 else f"{m // 60}h{m % 60:02d}m"


def main():
    try:
        sys.stdin.read()
    except Exception:
        pass
    try:
        data = json.load(open(STATE))
    except Exception:
        return
    cycles = data.get("cycles", data) if isinstance(data, dict) else data
    if not isinstance(cycles, list):
        return
    now = datetime.now(timezone.utc)
    parts = []
    for c in reversed(cycles[-5:]):
        if not isinstance(c, dict):
            continue
        phase = c.get("phase", "?")
        since = parse(c.get("phaseSince", "")) or now
        secs = max(0, (now - since).total_seconds())
        if phase == "closed" and secs > 600:
            continue
        colour = GREEN
        if phase == "failed" or (phase == "running" and c.get("pid") and not alive(c["pid"])):
            colour = RED
        elif phase == "fixing":   # an agent's fix round: 60 min / 2 h
            colour = RED if secs >= 7200 else YELLOW if secs >= 3600 else GREEN
        elif phase != "closed":
            colour = RED if secs >= 1800 else YELLOW if secs >= 600 else GREEN
        words = {"briefed": "briefed", "running": "codex running", "verdict": "reading verdict",
                 "fixing": f"fixing {c.get('findings', '?')}", "closed": "closed", "failed": "FAILED"}.get(phase, phase)
        parts.append(f"{colour}● {c.get('title', '?')} — {words} {age_words(secs)}{RESET}")
        if len(parts) == 3:
            break
    if parts:
        print(f"{DIM}codex:{RESET} " + "  ".join(parts))


if __name__ == "__main__":
    main()
