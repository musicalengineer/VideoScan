#!/usr/bin/env python3
"""nightly_run_marker.py — the record of a nightly run that is still going.

Why (2026-11-09): the M4's 14:00 testbed was cut off 41 minutes in by a macOS
update. Nothing was published, nothing was logged, and the metrics page went on
showing the previous day's run with no hint that today's never finished.

scripts/nightly_local_tests.sh writes this marker when it starts, updates the
phase as it goes, and removes it the moment a result row is published or queued.
A marker whose process is gone is a run that never finished: the NEXT launch
publishes it as a "did not run · interrupted:<phase>" row dated when it started.

    begin <marker> <pid> <commit>   write the marker for this run (phase "start")
    phase <marker> <name>           record the phase the run has reached
    stale <marker>                  exit 0 and print "<started>\\t<phase>\\t<commit>" when
                                    the marker's process is gone; exit 1 otherwise
                                    (no marker, unreadable marker, or still running)
    end   <marker>                  remove the marker

A pid can be reused after a reboot, so the marker also holds the process's
start time (`ps -o lstart=`); the run is alive only when both still match.
An unreadable marker is removed by `stale` and reported as not stale: a torn
file must never publish a row made of guesses.

Memory: one small JSON file. Tests: tests/test_nightly_run_marker.py.
"""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable, Optional

PHASE_RE = re.compile(r"^[a-z][a-z0-9-]{0,23}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{7,40}$")
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def process_start(pid: int) -> Optional[str]:
    """`ps`'s start time for pid, or None when no such process exists."""
    try:
        proc = subprocess.run(["ps", "-o", "lstart=", "-p", str(pid)], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return None
    words = proc.stdout.strip()
    return words if proc.returncode == 0 and words else None


def _write(marker: Path, data: dict) -> None:
    tmp = marker.with_name(marker.name + ".tmp")
    tmp.write_text(json.dumps(data, sort_keys=True) + "\n")
    os.replace(tmp, marker)


def _read(marker: Path) -> Optional[dict]:
    try:
        data = json.loads(marker.read_text())
    except (OSError, ValueError):
        return None
    ok = (isinstance(data, dict) and isinstance(data.get("pid"), int) and not isinstance(data.get("pid"), bool)
          and isinstance(data.get("started"), str) and TS_RE.match(data["started"])
          and isinstance(data.get("phase"), str) and PHASE_RE.match(data["phase"]))
    return data if ok else None


def begin(marker: Path, pid: int, commit: str, now: Optional[datetime] = None,
          start_of: Callable[[int], Optional[str]] = process_start) -> None:
    now = now or datetime.now(timezone.utc)
    marker.parent.mkdir(parents=True, exist_ok=True)
    _write(marker, {"pid": pid, "pid_started": start_of(pid), "phase": "start",
                    "started": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "commit": commit if COMMIT_RE.match(commit) else "unknown"})


def phase(marker: Path, name: str) -> bool:
    data = _read(marker)
    if data is None or not PHASE_RE.match(name):
        return False
    data["phase"] = name
    _write(marker, data)
    return True


def stale(marker: Path, start_of: Callable[[int], Optional[str]] = process_start) -> Optional[tuple]:
    """(started, phase, commit) when the marker's run is gone; None otherwise."""
    if not marker.exists():
        return None
    data = _read(marker)
    if data is None:
        marker.unlink(missing_ok=True)      # torn or foreign: never a row made of guesses
        return None
    live = start_of(data["pid"])
    if live is not None and live == data.get("pid_started"):
        return None                         # that run is still going
    commit = data.get("commit")
    return (data["started"], data["phase"], commit if isinstance(commit, str) and COMMIT_RE.match(commit) else "unknown")


def main(argv: Optional[list] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 2:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    verb, marker = args[0], Path(args[1]).expanduser()
    if verb == "begin" and len(args) == 4 and args[2].isdigit():
        begin(marker, int(args[2]), args[3])
        return 0
    if verb == "phase" and len(args) == 3:
        return 0 if phase(marker, args[2]) else 1
    if verb == "stale" and len(args) == 2:
        found = stale(marker)
        if found is None:
            return 1
        print("\t".join(found))
        return 0
    if verb == "end" and len(args) == 2:
        marker.unlink(missing_ok=True)
        return 0
    print(f"nightly_run_marker: bad arguments {args}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
