#!/usr/bin/env python3
"""Run the tracked pytest modules as N concurrent shards and print ONE pytest-shaped summary.

Why (Rick 2026-11-20: "2 hour testbeds in serial is not performant design"): the Python lane was one
`pytest` process over every module — 37 min on the Ultra, 20 min on the M4 — with 30 / 16 cores idle.
No new dependency (pytest-xdist is not installed on the fleet): each module is one strand of
scripts/testbed_strands.py — the testbed's one fan-out runner — N at a time, longest first by the
last run's measured seconds, each in its own process group and TMPDIR.

Output contract (scripts/script_tests_lane.py and run_tests.py read it): each failing shard's own
output is printed whole; every FAILED / ERROR line is printed; the LAST line is pytest's own summary
grammar summed over the shards — "1 failed, 2615 passed, 4 skipped, 130 subtests passed in 181.20s".
Exit 0 only when every shard exited 0. N=1 is one pytest over every module, as before.

usage: pytest_shards.py --python PY [--jobs N] [--timings FILE] [--] module...
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Sequence

sys.path.insert(0, str(Path(__file__).resolve().parent))
import testbed_strands as strands  # noqa: E402

SUMMARY = re.compile(r"^=*\s*((?:\d+ [a-z]+(?: [a-z]+)?, )*\d+ [a-z]+(?: [a-z]+)?) in \d+(?:\.\d+)?s(?: \([\d:]+\))?\s*=*$")
PART = re.compile(r"(\d+) ([a-z]+(?: [a-z]+)?)")
NO_TESTS = re.compile(r"^=*\s*no tests ran\b")
FAIL_LINE = re.compile(r"^(?:FAILED|ERROR) \S+")
NO_TESTS_COLLECTED = 5                     # pytest's exit code when a file holds no test
# pytest's own order for the summary words; anything else follows in the order first seen.
ORDER = ["failed", "passed", "skipped", "deselected", "xfailed", "xpassed", "warnings", "warning", "error", "errors",
         "rerun", "subtests failed", "subtests passed", "subtests skipped"]


def estimate(module: str) -> float:
    """First-run guess for a module with no measured time: ~2 KB of test source per second."""
    try:
        return max(os.path.getsize(module) / 2000.0, 1.0)
    except OSError:
        return 1.0


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


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--python", required=True)
    ap.add_argument("--jobs", type=int, default=strands.default_jobs())
    ap.add_argument("--timings", type=Path, default=strands.DEFAULT_TIMINGS)
    ap.add_argument("modules", nargs="+")
    a = ap.parse_args(argv)

    work = [strands.Strand(name=m, weight_key="pytest:" + m, estimate=estimate(m),
                           cmd=[a.python, "-m", "pytest", "-q", "-rfEs", "-p", "no:cacheprovider", m])
            for m in a.modules]
    print(f"pytest strands: {len(work)} modules, {min(a.jobs, len(work))} at a time "
          f"(scripts/testbed_strands.py; longest first by the last run)", flush=True)
    t0 = time.monotonic()
    with tempfile.TemporaryDirectory(prefix="pytest-strands-") as tmp:
        results = strands.Runner(Path(tmp), jobs=a.jobs, timings_path=a.timings).run(work)
        elapsed = time.monotonic() - t0
        counts, fails, worst, empty = [], [], 0, []
        for r in results:
            text = r.text()
            c = summary_counts(text)
            counts.append(c)
            fails += [l for l in text.splitlines() if FAIL_LINE.match(l)]
            if r.rc == NO_TESTS_COLLECTED and not r.timed_out:
                # One file pytest found no test in (the tracked-file glob also matches helpers such as
                # scripts/ci_test_verdict.py). Not a failure of that file; an import error is exit 2
                # and stays RED, and a lane that ran no test at all is still RED by its total.
                empty.append(r.strand.name)
                continue
            if not r.ok:
                worst = worst or (r.rc if r.rc > 0 else 1)
                why = "TIMEOUT" if r.timed_out else f"exit {r.rc}"
                print(f"\n----- {r.strand.name}: {why} ({r.seconds:.1f}s) — its own output -----")
                print(text.rstrip())
                if not c:
                    fails.append(f"ERROR {r.strand.name}: {why} with no pytest summary")
    if empty:
        print(f"no tests in {len(empty)} file(s): {', '.join(sorted(empty))}")
    slowest = sorted(results, key=lambda r: -r.seconds)[:3]
    print("slowest strands: " + ", ".join(f"{r.strand.name} {r.seconds:.0f}s" for r in slowest))
    if fails:
        print("\nshort test summary (all strands)")
        for line in fails:
            print(line)
    total = merge(counts)
    print(summary_line(total, elapsed), flush=True)
    if not worst and not total.get("passed"):
        return 1                           # a lane that ran no test is red (CLAUDE.md rule 9)
    return worst


if __name__ == "__main__":
    sys.exit(main())
