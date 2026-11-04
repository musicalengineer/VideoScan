#!/usr/bin/env python3
"""hallie_replay_reason.py — WHY a Hallie replay lane answered nothing, as a code.

2026-11-04: both Macs replayed 0 of 56 strict questions; the lane's run log said
why in one line ("hallie: catalog.sqlite would not open for reading: the
database is read-only and its schema is not current"), and the metrics card said
"Hallie replay incomplete (a few)". nightly_hallie_replay.sh now asks this file
for the lane's reason when it completed nothing, and the row carries it as
hallie_<lane>_reason: a CODE (tools/publish_metrics.py CODE_RE) the page turns
into words. Never a path or a host: the row is public.

Usage: hallie_replay_reason.py <run.log> <completed>   # prints the code, or nothing
Memory: the run log is read once (a few KB; its size is bounded by the shell's
stderr for one session).
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Optional

# First match wins; the more specific words come first (a synced copy on an
# older schema says both "would not open for reading" and "schema is not current").
RULES = (
    ("schema is not current", "catalog-schema-not-current"),
    ("nothing synced from", "catalog-not-synced"),
    ("never switched to SQLite", "catalog-not-switched"),
    ("would not open for reading", "catalog-unreadable"),
    ("could not be read", "catalog-unreadable"),
    ("cannot read catalog", "catalog-unreadable"),
    ("no Debug or Release VideoScan executable", "no-app-binary"),
    ("VIDEOSCAN_APP_BIN is not an executable", "no-app-binary"),
)
UNKNOWN = "no-turns"


def reason(text: str, completed: int) -> Optional[str]:
    """The code for a lane that completed nothing; None when it answered anything."""
    if completed > 0:
        return None
    for needle, code in RULES:
        if needle in text:
            return code
    return UNKNOWN


def main(argv) -> int:
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[-2], file=sys.stderr)
        return 64
    try:
        text = Path(argv[1]).read_text(encoding="utf-8", errors="replace")
    except OSError:
        text = ""
    code = reason(text, int(argv[2]) if argv[2].isdigit() else 0)
    if code:
        print(code)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
