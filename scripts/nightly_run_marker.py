#!/usr/bin/env python3
"""nightly_run_marker.py — the record of a nightly run that is still going.

Why (2026-11-09): the M4's 14:00 testbed was cut off 41 minutes in by a macOS
update. Nothing was published, nothing was logged, and the metrics page went on
showing the previous day's run with no hint that today's never finished.

scripts/nightly_local_tests.sh writes this marker when it starts, updates the
phase as it goes, and removes it the moment a result row is published or queued.
A marker whose process is gone is a run that never finished: the NEXT launch
publishes it as a "did not run · interrupted:<phase>" row dated when it started.

    begin <marker> <pid> <commit>   write the marker for this run (phase "start");
                                    exit 3 and write nothing when ANOTHER live run owns it
    phase <marker> <name> <pid>     record the phase — only in the marker <pid> owns
    stale <marker>                  exit 0 and print "<started>\\t<phase>\\t<commit>\\t<pid>"
                                    when the marker's process is gone; exit 1 otherwise
                                    (no marker, unreadable marker, or still running)
    end   <marker> <pid>            remove the marker — only when <pid> owns it
    accounted <started> <host> <rows.jsonl|->…
                                    exit 0 when a nightly row from <host> is dated AFTER
                                    <started> in any of the files ("-" = stdin): that run
                                    did publish (or queue) its result; exit 1 otherwise

Ownership (Codex #275 F3): only the run whose pid is in the marker may change or
remove it, and a run never replaces a live run's marker — two launches at once
used to be able to leave one run's marker behind for the other to "recover".
Recovery asks `accounted` first, so a run whose result is already on the branch
or in the queue is never also reported as interrupted (F2/F3).

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


def _live(data: dict, start_of: Callable[[int], Optional[str]]) -> bool:
    """The marker's run is still going: its pid exists with the start time recorded."""
    live = start_of(data["pid"])
    return live is not None and live == data.get("pid_started")


def begin(marker: Path, pid: int, commit: str, now: Optional[datetime] = None,
          start_of: Callable[[int], Optional[str]] = process_start) -> bool:
    """Write this run's marker. False (nothing written) when another LIVE run owns it."""
    now = now or datetime.now(timezone.utc)
    marker.parent.mkdir(parents=True, exist_ok=True)
    current = _read(marker) if marker.exists() else None
    if current is not None and current["pid"] != pid and _live(current, start_of):
        return False
    _write(marker, {"pid": pid, "pid_started": start_of(pid), "phase": "start",
                    "started": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "commit": commit if COMMIT_RE.match(commit) else "unknown"})
    return True


def phase(marker: Path, name: str, pid: int) -> bool:
    data = _read(marker)
    if data is None or data["pid"] != pid or not PHASE_RE.match(name):
        return False
    data["phase"] = name
    _write(marker, data)
    return True


def end(marker: Path, pid: int) -> bool:
    """Remove the marker when `pid` owns it. False (untouched) otherwise."""
    data = _read(marker)
    if data is None or data["pid"] != pid:
        return False
    marker.unlink(missing_ok=True)
    return True


def accounted(started: str, host: str, sources) -> bool:
    """True when any line of `sources` (iterables of text lines) is a nightly row from
    `host` dated after `started`: the run that began then did publish or queue a result.
    Lines that are not such a row are ignored. Streams; one line in memory at a time."""
    if not TS_RE.match(started):
        return False
    for lines in sources:
        for line in lines:
            line = line.strip()
            if not line or '"nightly-local"' not in line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            ts = row.get("ts") if isinstance(row, dict) else None
            if (isinstance(ts, str) and TS_RE.match(ts) and ts > started
                    and row.get("source") == "nightly-local" and row.get("host") == host):
                return True
    return False


def stale(marker: Path, start_of: Callable[[int], Optional[str]] = process_start) -> Optional[tuple]:
    """(started, phase, commit, pid) when the marker's run is gone; None otherwise."""
    if not marker.exists():
        return None
    data = _read(marker)
    if data is None:
        marker.unlink(missing_ok=True)      # torn or foreign: never a row made of guesses
        return None
    if _live(data, start_of):
        return None                         # that run is still going
    commit = data.get("commit")
    return (data["started"], data["phase"], commit if isinstance(commit, str) and COMMIT_RE.match(commit) else "unknown",
            str(data["pid"]))


def main(argv: Optional[list] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 2:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    verb, marker = args[0], Path(args[1]).expanduser()
    if verb == "accounted" and len(args) >= 4:
        def lines_of(path: str):
            if path == "-":
                yield from sys.stdin
                return
            try:
                with open(os.path.expanduser(path), errors="replace") as f:
                    yield from f
            except OSError:
                return
        return 0 if accounted(args[1], args[2], (lines_of(p) for p in args[3:])) else 1
    if verb == "begin" and len(args) == 4 and args[2].isdigit():
        return 0 if begin(marker, int(args[2]), args[3]) else 3
    if verb == "phase" and len(args) == 4 and args[3].isdigit():
        return 0 if phase(marker, args[2], int(args[3])) else 1
    if verb == "stale" and len(args) == 2:
        found = stale(marker)
        if found is None:
            return 1
        print("\t".join(found))
        return 0
    if verb == "end" and len(args) == 3 and args[2].isdigit():
        return 0 if end(marker, int(args[2])) else 1
    print(f"nightly_run_marker: bad arguments {args}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
