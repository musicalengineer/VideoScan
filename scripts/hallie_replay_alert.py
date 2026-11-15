#!/usr/bin/env python3
"""One banner line when the newest nightly's Hallie replay did not pass (2026-11-15).

By design the replay lane can never touch the nightly's own status (it only
ADDS fields to the row), so a replay that did not run rode under a green
nightly unseen: 11/05, 11/06 and 11/15, Ollama was down on the Ultra each time.

The nightly keeps the replay runner's output beside its log
(nightly_test_<stamp>.log.hallie-replay); the runner's last
"hallie replay <status>…" line is the verdict. This prints

  🔴 Hallie replay, nightly of <day>: <verdict>     anything but "ok"
  🔴 Hallie replay left no verdict …                 no file, or cut off
  (nothing)                                          ok, or no nightly here

Read-only. Never fails the banner (exit 0 always).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

LOGS = Path.home() / "Library" / "Logs" / "VideoScan"
PREFIX = "hallie replay "
MAX_WORDS = 300


def verdict_line(text: str) -> str:
    """The runner's verdict: its last "hallie replay <status>" line. Its progress
    lines start "hallie replay: " and are not verdicts."""
    for line in reversed([l.strip() for l in text.splitlines()]):
        if line.startswith(PREFIX) and not line.startswith("hallie replay:"):
            return line
    return ""


def alert(logs: Path) -> str:
    nightlies = sorted(logs.glob("nightly_test_*.log"))
    if not nightlies:
        return ""
    newest = nightlies[-1]
    stamp = newest.name[len("nightly_test_"):-len(".log")]
    day = f"{stamp[0:4]}-{stamp[4:6]}-{stamp[6:8]}" if len(stamp) >= 8 and stamp[:8].isdigit() else stamp
    try:
        text = Path(str(newest) + ".hallie-replay").read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
    verdict = verdict_line(text)
    if not verdict:
        return f"🔴 Hallie replay left no verdict in the nightly of {day} (it did not run, or was cut off)"
    if verdict.startswith(PREFIX + "ok"):
        return ""
    return f"🔴 Hallie replay, nightly of {day}: {verdict[len(PREFIX):][:MAX_WORDS]}"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--logs", default=str(LOGS))
    args = ap.parse_args(argv)
    try:
        line = alert(Path(args.logs))
        if line:
            print(line)
    except Exception as e:  # never fail the banner, but say so
        print(f"🟡 Hallie replay verdict unavailable: {e}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
