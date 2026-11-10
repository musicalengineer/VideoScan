#!/usr/bin/env python3
"""nightly_run_marker.py — the record of a nightly run that has not published its result yet.

Why (2026-11-09): the M4's 14:00 testbed was cut off 41 minutes in by a macOS
update. Nothing was published, nothing was logged, and the metrics page went on
showing the previous day's run with no hint that today's never finished.

scripts/nightly_local_tests.sh holds a KERNEL LOCK for the whole run
(scripts/testbed_lock.py on fd 8: one nightly run per Mac, atomic, released by
the kernel when the last process of the run dies). Under that lock it writes
this marker when it starts, updates the phase as it goes, and removes it the
moment its result row is durable (on the branch, or in the pending queue).

So a launch that HOLDS THE LOCK and finds a marker knows the run that wrote it
is dead and never made a result durable — no pid, no start time, no liveness
guess (Codex #275–#277: every pid/ownership protocol had a check-then-act
window). It publishes that run as "did not run · interrupted:<phase>", dated
when it started — unless `accounted` finds that run's row already on the
branch or in the queue (killed between its publish and its marker's removal).

    begin <marker> <commit>     write the marker (phase "start"), replacing any
    phase <marker> <name>       record the phase the run has reached
    read  <marker>              print "<started>\\t<phase>\\t<commit>" and exit 0; exit 1
                                when there is none. An unreadable marker is removed
                                and reported as none: a torn file must never
                                publish a row made of guesses.
    end   <marker>              remove the marker
    accounted <started> <host> <rows.jsonl|->…
                                exit 0 when a nightly row from <host> dated AT OR
                                AFTER <started> is in any file ("-" = stdin)

Every verb assumes the caller holds the run lock. Memory: one small JSON file;
`accounted` streams, one line at a time. Tests: tests/test_nightly_run_marker.py.
"""
from __future__ import annotations

import json
import os
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

PHASE_RE = re.compile(r"^[a-z][a-z0-9-]{0,23}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{7,40}$")
TS_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def _write(marker: Path, data: dict) -> None:
    tmp = marker.with_name(marker.name + ".tmp")
    tmp.write_text(json.dumps(data, sort_keys=True) + "\n")
    os.replace(tmp, marker)


def _read(marker: Path) -> Optional[dict]:
    try:
        data = json.loads(marker.read_text())
    except (OSError, ValueError):
        return None
    ok = (isinstance(data, dict)
          and isinstance(data.get("started"), str) and TS_RE.match(data["started"])
          and isinstance(data.get("phase"), str) and PHASE_RE.match(data["phase"]))
    return data if ok else None


def begin(marker: Path, commit: str, now: Optional[datetime] = None) -> None:
    now = now or datetime.now(timezone.utc)
    marker.parent.mkdir(parents=True, exist_ok=True)
    _write(marker, {"phase": "start", "started": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
                    "commit": commit if COMMIT_RE.match(commit) else "unknown"})


def phase(marker: Path, name: str) -> bool:
    data = _read(marker)
    if data is None or not PHASE_RE.match(name):
        return False
    data["phase"] = name
    _write(marker, data)
    return True


def read(marker: Path) -> Optional[tuple]:
    """(started, phase, commit) of the marker, or None. A torn marker is removed."""
    if not marker.exists():
        return None
    data = _read(marker)
    if data is None:
        marker.unlink(missing_ok=True)
        return None
    commit = data.get("commit")
    return (data["started"], data["phase"], commit if isinstance(commit, str) and COMMIT_RE.match(commit) else "unknown")


def accounted(started: str, host: str, sources) -> bool:
    """True when any line of `sources` (iterables of text lines) is a nightly row from
    `host` dated at or after `started`: the run that began then did publish or queue a
    result. Only one run per Mac exists at a time (the run lock), so such a row is that
    run's. The interrupted row itself is never dated later than `started`, and it is
    written only after this check. Lines that are not such a row are ignored."""
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
            if (isinstance(ts, str) and TS_RE.match(ts) and ts >= started
                    and row.get("source") == "nightly-local" and row.get("host") == host
                    and not str(row.get("reason") or "").startswith("interrupted:")):
                return True
    return False


def _lines_of(path: str):
    if path == "-":
        yield from sys.stdin
        return
    try:
        with open(os.path.expanduser(path), errors="replace") as f:
            yield from f
    except OSError:
        return


def main(argv: Optional[list] = None) -> int:
    args = list(sys.argv[1:] if argv is None else argv)
    if len(args) < 2:
        print(__doc__.split("\n\n")[0], file=sys.stderr)
        return 2
    verb = args[0]
    if verb == "accounted" and len(args) >= 4:
        return 0 if accounted(args[1], args[2], (_lines_of(p) for p in args[3:])) else 1
    marker = Path(args[1]).expanduser()
    if verb == "begin" and len(args) == 3:
        begin(marker, args[2])
        return 0
    if verb == "phase" and len(args) == 3:
        return 0 if phase(marker, args[2]) else 1
    if verb == "read" and len(args) == 2:
        found = read(marker)
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
