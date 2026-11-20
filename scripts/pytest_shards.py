#!/usr/bin/env python3
"""Run the tracked pytest modules as N concurrent shards and print ONE pytest-shaped summary.

Why (Rick 2026-11-20: "2 hour testbeds in serial is not performant design"): the Python lane was one
`pytest` process over every module — 37 min on the Ultra, 20 min on the M4 — with 30 / 16 cores idle.
No new dependency (pytest-xdist is not installed on the fleet): modules are dealt to N shards, longest
first by the last run's measured time per module (cache under ~/Library/Caches), each shard is one
`pytest` process, and the shards run at once.

Output contract (scripts/script_tests_lane.py and run_tests.py read it): each failing shard's own
output is printed whole; every FAILED / ERROR line is printed; the LAST line is pytest's own summary
grammar summed over the shards — "1 failed, 2615 passed, 4 skipped, 130 subtests passed in 181.20s".
Exit 0 only when every shard exited 0. N=1 is one pytest over every module, as before.

usage: pytest_shards.py --python PY [--jobs N] [--timings FILE] [--] module...
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, List, Sequence, Tuple

SUMMARY = re.compile(r"^=*\s*((?:\d+ [a-z]+(?: [a-z]+)?, )*\d+ [a-z]+(?: [a-z]+)?) in \d+(?:\.\d+)?s(?: \([\d:]+\))?\s*=*$")
PART = re.compile(r"(\d+) ([a-z]+(?: [a-z]+)?)")
NO_TESTS = re.compile(r"^=*\s*no tests ran\b")
FAIL_LINE = re.compile(r"^(?:FAILED|ERROR) \S+")
# pytest's own order for the summary words; anything else follows in the order first seen.
ORDER = ["failed", "passed", "skipped", "deselected", "xfailed", "xpassed", "warnings", "warning", "error", "errors",
         "rerun", "subtests failed", "subtests passed", "subtests skipped"]
DEFAULT_TIMINGS = Path.home() / "Library" / "Caches" / "videoscan-pytest-timings.json"


def default_jobs() -> int:
    """Half the cores (Rick 2026-11-20): leaves the machine room; at least 1."""
    return max(1, (os.cpu_count() or 2) // 2)


def load_timings(path: Path) -> Dict[str, float]:
    try:
        data = json.loads(path.read_text())
        return {str(k): float(v) for k, v in data.items() if isinstance(v, (int, float))}
    except (OSError, ValueError, AttributeError):
        return {}


def weight(module: str, timings: Dict[str, float]) -> float:
    """Seconds the module took last time; unknown modules are weighed by size (~2 KB per second)
    and never below the slowest known module's median, so a new big module is not packed last."""
    if module in timings:
        return timings[module]
    try:
        return max(os.path.getsize(module) / 2000.0, 1.0)
    except OSError:
        return 1.0


def deal(modules: Sequence[str], jobs: int, timings: Dict[str, float]) -> List[List[str]]:
    """Longest-processing-time-first: each module to the currently lightest shard. Deterministic
    (ties by name). Never more shards than modules; empty shards are dropped."""
    jobs = max(1, min(jobs, len(modules)))
    bins: List[Tuple[float, int, List[str]]] = [(0.0, i, []) for i in range(jobs)]
    for m in sorted(modules, key=lambda m: (-weight(m, timings), m)):
        load, i, mods = min(bins, key=lambda b: (b[0], b[1]))
        bins[i] = (load + weight(m, timings), i, mods + [m])
    return [sorted(b[2]) for b in bins if b[2]]


def summary_counts(text: str) -> Dict[str, int]:
    """{kind: n} from the shard's LAST summary line; {} when none (then the shard's rc decides)."""
    for line in reversed(text.splitlines()):
        m = SUMMARY.match(line.strip())
        if m:
            return {kind: int(n) for n, kind in PART.findall(m.group(1))}
        if NO_TESTS.match(line.strip()):
            return {}
    return {}


def merge(counts: Sequence[Dict[str, int]]) -> Dict[str, int]:
    total: Dict[str, int] = {}
    for c in counts:
        for k, v in c.items():
            total[k] = total.get(k, 0) + v
    # pytest says "1 warning" / "2 warnings", "1 error" / "2 errors": normalise the sum's word.
    for one, many in (("warning", "warnings"), ("error", "errors")):
        n = total.pop(one, 0) + total.pop(many, 0)
        if n:
            total[one if n == 1 else many] = n
    return total


def summary_line(total: Dict[str, int], seconds: float) -> str:
    keys = [k for k in ORDER if total.get(k)] + [k for k in total if k not in ORDER and total[k]]
    if not keys:
        return f"no tests ran in {seconds:.2f}s"
    return ", ".join(f"{total[k]} {k}" for k in keys) + f" in {seconds:.2f}s"


def module_seconds(junit: Path) -> Dict[str, float]:
    """Seconds per test file from a shard's junit xml (xunit1 carries the file attribute)."""
    import xml.etree.ElementTree as ET
    out: Dict[str, float] = {}
    try:
        root = ET.parse(str(junit)).getroot()
    except (OSError, ET.ParseError):
        return out
    for case in root.iter("testcase"):
        f = case.get("file")
        if f:
            out[f] = out.get(f, 0.0) + float(case.get("time") or 0.0)
    return out


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--python", required=True)
    ap.add_argument("--jobs", type=int, default=default_jobs())
    ap.add_argument("--timings", type=Path, default=DEFAULT_TIMINGS)
    ap.add_argument("modules", nargs="+")
    a = ap.parse_args(argv)

    timings = load_timings(a.timings)
    shards = deal(a.modules, a.jobs, timings)
    print(f"pytest shards: {len(shards)} at once over {len(a.modules)} modules "
          f"(--jobs {a.jobs}; dealt by {'last run timings' if timings else 'file size'})", flush=True)
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="pytest-shards-") as tmp:
        procs = []
        for i, mods in enumerate(shards):
            log = Path(tmp) / f"shard-{i}.log"
            junit = Path(tmp) / f"shard-{i}.xml"
            fh = open(log, "w")
            cmd = [a.python, "-m", "pytest", "-q", "-rfEs", "-p", "no:cacheprovider", "-o", "junit_family=xunit1",
                   f"--junitxml={junit}", *mods]
            procs.append((i, mods, log, junit, fh, subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT)))
        results = []
        try:
            for i, mods, log, junit, fh, p in procs:
                rc = p.wait()
                fh.close()
                results.append((i, mods, log.read_text(errors="replace"), junit, rc))
        except KeyboardInterrupt:
            for *_, p in procs:
                p.terminate()
            raise
        elapsed = time.monotonic() - t0

        counts, fails, worst = [], [], 0
        new_timings = dict(timings)
        for i, mods, text, junit, rc in results:
            c = summary_counts(text)
            counts.append(c)
            new_timings.update(module_seconds(junit))
            shard_fails = [l for l in text.splitlines() if FAIL_LINE.match(l)]
            fails += shard_fails
            if rc != 0:
                worst = worst or rc
                print(f"\n----- shard {i} exit {rc} ({len(mods)} modules) — its own output -----")
                print(text.rstrip())
                if not c:
                    fails.append(f"ERROR shard-{i}: exit {rc} with no pytest summary")
            else:
                print(f"shard {i}: {summary_line(merge([c]), 0).rsplit(' in ', 1)[0]} ({len(mods)} modules)")
        try:
            a.timings.parent.mkdir(parents=True, exist_ok=True)
            a.timings.write_text(json.dumps(new_timings, indent=0, sort_keys=True))
        except OSError:
            pass
    if fails:
        print("\nshort test summary (all shards)")
        for line in fails:
            print(line)
    print(summary_line(merge(counts), elapsed), flush=True)
    return worst


if __name__ == "__main__":
    sys.exit(main())
