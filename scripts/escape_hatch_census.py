#!/usr/bin/env python3
"""escape_hatch_census.py — count the holes in the Swift 6 proof (stage 2, §7).

Swift 6 language mode proves the absence of data races on all TRACKED state.
Each of these constructs steps outside the proof, so the migration policy
(docs/design/swift6_migration_2026_10_25.md §5) is: every one carries a comment
saying why it is safe, and the nightly counts them. This is the count.

  python3 scripts/escape_hatch_census.py                    # the line, nothing persisted
  python3 scripts/escape_hatch_census.py --state <json>     # compare with and then replace the previous census
  python3 scripts/escape_hatch_census.py --json             # the full census on stdout

Per TARGET (app / app tests / Core / Core tests), per KIND:

  nonisolated(unsafe)   opt-out of isolation checking for one declaration
  @unchecked Sendable   "trust me" conformance; the compiler checks nothing
  assumeIsolated        a runtime assertion standing in for a compile-time proof
  unchecked-lock        withLockUnchecked / uncheckedState (lock payload not Sendable)
  Unsafe*Pointer        Unsafe[Mutable][Raw][Buffer]Pointer — nothing is proven across it
  unsafeBitCast         reinterpret_cast
  try!                  a throw becomes a trap
  as!                   a failed cast becomes a trap
  force-unwrap          `x!` — counted by swiftlint's force_unwrapping rule (the only
                        reliable way; a regex cannot tell `x!` from `!flag` or `!=`)

Comments and string literals are masked before the regexes run (sensor_lane.mask),
so a `// Swift 6: nonisolated(unsafe) because …` justification is not a hatch.
The force-unwrap count needs `swiftlint` on PATH; without it the census is RED,
not "0" — a dimension that silently reads zero is the failure mode rule 9 names.

Deltas: with --state, the previous census (the same JSON this run writes) is
read first and every (target, file, kind) whose count moved is listed. The
state lives where the nightly keeps its other local state
(~/Library/Logs/VideoScan/…), never in git.

Report mode (2026-10-25). TODO(stage 2 → ratchet): once the per-kind counts
have been quiet for a week, turn a rise in nonisolated(unsafe) / @unchecked
Sendable / assumeIsolated without a `// Swift 6:` comment into RED. Today a
rise is a report line.

Memory: one Swift file's text at a time; the census itself is a dict of
non-zero (file, kind) counts — a few thousand small entries at worst.
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import shutil
import subprocess
import sys
from collections import Counter
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

sys.path.insert(0, str(Path(__file__).resolve().parent))      # scripts/ — also when loaded by importlib (tests)
from sensor_lane import mask                                   # noqa: E402

REPO = Path(__file__).resolve().parent.parent

# target label -> repo-relative root. Order is the report order.
TARGETS: List[Tuple[str, str]] = [
    ("app", "VideoScan/VideoScan"),
    ("app tests", "VideoScan/VideoScanTests"),
    ("Core", "VideoScan/VideoScanCore/Sources"),
    ("Core tests", "VideoScan/VideoScanCore/Tests"),
]
NOT_OURS = {".build", "DerivedData", "SourcePackages", "checkouts", "Fixtures", "fixtures"}

# kind -> regex over MASKED text (comments and strings blanked). Order is the report order.
HATCHES: List[Tuple[str, re.Pattern]] = [
    ("nonisolated(unsafe)", re.compile(r"\bnonisolated\(unsafe\)")),
    ("@unchecked Sendable", re.compile(r"@unchecked\s+Sendable\b")),
    ("assumeIsolated", re.compile(r"\.assumeIsolated\b")),
    ("unchecked-lock", re.compile(r"\bwithLockUnchecked\b|\buncheckedState\b")),
    ("Unsafe*Pointer", re.compile(r"\bUnsafe(?:Mutable)?(?:Raw)?(?:Buffer)?Pointer\b")),
    ("unsafeBitCast", re.compile(r"\bunsafeBitCast\b")),
    ("try!", re.compile(r"\btry!")),
    ("as!", re.compile(r"\bas!")),
]
FORCE_UNWRAP = "force-unwrap"
KINDS = [k for k, _ in HATCHES] + [FORCE_UNWRAP]

Census = Dict[str, object]     # see census()


def swift_files(root: Path) -> Iterable[Path]:
    for p in sorted(root.rglob("*.swift")):
        if NOT_OURS.intersection(p.relative_to(root).parts):
            continue
        yield p


def count_file(text: str) -> Dict[str, int]:
    """Regex hatches in one file's masked text (force-unwrap is swiftlint's)."""
    masked = mask(text)
    return {kind: len(rx.findall(masked)) for kind, rx in HATCHES if rx.search(masked)}


def force_unwraps(paths: List[Path], swiftlint: Optional[str]) -> Tuple[Optional[Dict[str, int]], str]:
    """(repo-relative path -> force_unwrapping violations, note). None when the
    rule could not run; the note says why. swiftlint's JSON reporter is one
    object per violation with an absolute `file`."""
    exe = shutil.which(swiftlint or "swiftlint")
    if not exe:
        return None, f"swiftlint not found ({swiftlint or 'swiftlint'}) — force-unwrap not counted"
    cmd = [exe, "lint", "--quiet", "--only-rule", "force_unwrapping", "--reporter", "json", "--force-exclude",
           "--config", str(REPO / ".swiftlint.yml")] + [str(p) for p in paths]
    try:
        run = subprocess.run(cmd, capture_output=True, text=True, cwd=str(REPO), timeout=1800)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"swiftlint failed to run: {e}"
    # swiftlint exits 0 (clean), 2 (violations as errors) — the JSON is on stdout either way.
    try:
        rows = json.loads(run.stdout or "[]")
    except ValueError:
        return None, f"swiftlint produced no JSON (rc={run.returncode}): {run.stderr.strip()[:200]}"
    counts: Counter = Counter()
    for r in rows:
        if r.get("rule_id") != "force_unwrapping":
            continue
        try:
            rel = Path(r["file"]).resolve().relative_to(REPO).as_posix()
        except (KeyError, ValueError):
            continue
        counts[rel] += 1
    return dict(counts), f"swiftlint {exe}"


def census(repo: Path = REPO, swiftlint: Optional[str] = "swiftlint", with_force_unwrap: bool = True) -> Census:
    """The whole census. Shape:
      {"date", "targets": {label: {"files": n, "kinds": {kind: n}, "total": n,
                                   "per_file": {rel: {kind: n}}}},
       "kinds": {kind: n}, "total": n, "force_unwrap_note": str, "red": [reasons]}"""
    out: Census = {"date": dt.date.today().isoformat(), "targets": {}, "kinds": {}, "total": 0,
                   "force_unwrap_note": "", "red": []}
    all_paths: List[Path] = []
    per_target_files: Dict[str, List[Path]] = {}
    for label, rel_root in TARGETS:
        root = repo / rel_root
        files = list(swift_files(root)) if root.is_dir() else []
        per_target_files[label] = files
        all_paths += files
        if not files:
            out["red"].append(f"{label}: no Swift files under {rel_root}")
    fu: Optional[Dict[str, int]] = {}
    if with_force_unwrap:
        fu, note = force_unwraps(all_paths, swiftlint)
        out["force_unwrap_note"] = note
        if fu is None:
            out["red"].append(note)
    grand: Counter = Counter()
    for label, files in per_target_files.items():
        kinds: Counter = Counter()
        per_file: Dict[str, Dict[str, int]] = {}
        for p in files:
            rel = p.relative_to(repo).as_posix()
            counts = count_file(p.read_text(encoding="utf-8", errors="replace"))
            if fu and fu.get(rel):
                counts[FORCE_UNWRAP] = fu[rel]
            if counts:
                per_file[rel] = counts
                kinds.update(counts)
        grand.update(kinds)
        out["targets"][label] = {"files": len(files), "kinds": dict(kinds), "total": sum(kinds.values()),
                                 "per_file": per_file}
    out["kinds"] = {k: grand.get(k, 0) for k in KINDS}
    out["total"] = sum(grand.values())
    return out


def deltas(prev: Optional[Census], cur: Census) -> List[Tuple[str, str, str, int, int]]:
    """(target, file, kind, before, after) for every per-file count that moved."""
    if not prev:
        return []
    out = []
    for label in cur["targets"]:
        a = (prev.get("targets") or {}).get(label, {}).get("per_file", {})
        b = cur["targets"][label]["per_file"]
        for rel in sorted(set(a) | set(b)):
            for kind in KINDS:
                x, y = a.get(rel, {}).get(kind, 0), b.get(rel, {}).get(kind, 0)
                if x != y:
                    out.append((label, rel, kind, x, y))
    return out


def summary_line(cur: Census, prev: Optional[Census] = None) -> str:
    kinds = " · ".join(f"{k} {cur['kinds'].get(k, 0)}" for k in KINDS)
    targets = " / ".join(f"{label} {cur['targets'][label]['total']}" for label, _ in TARGETS if label in cur["targets"])
    line = f"escape hatches: {cur['total']} total ({kinds}) — {targets}"
    if prev:
        moved = deltas(prev, cur)
        up = sum(y - x for _, _, _, x, y in moved if y > x)
        down = sum(x - y for _, _, _, x, y in moved if y < x)
        line += f" — Δ +{up}/−{down} vs {prev.get('date', '?')} (total {prev.get('total', '?')})"
    else:
        line += " — no previous census"
    if cur.get("red"):
        line += " — RED: " + "; ".join(cur["red"])
    return line


def load_state(path: Path) -> Optional[Census]:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", type=Path, default=REPO)
    ap.add_argument("--state", type=Path, default=None, help="previous census to diff against; overwritten with this one")
    ap.add_argument("--swiftlint", default="swiftlint")
    ap.add_argument("--no-force-unwrap", action="store_true", help="skip swiftlint (tests); the census is then RED by design")
    ap.add_argument("--json", action="store_true", help="print the full census as JSON instead of the line")
    ap.add_argument("--deltas", action="store_true", help="also print one line per moved (file, kind)")
    a = ap.parse_args(argv)

    cur = census(a.repo, a.swiftlint, with_force_unwrap=not a.no_force_unwrap)
    if a.no_force_unwrap:
        cur["red"].append("force-unwrap not counted (--no-force-unwrap)")
    prev = load_state(a.state) if a.state else None
    if a.json:
        print(json.dumps({**cur, "deltas": deltas(prev, cur)}, indent=1))
    else:
        print(summary_line(cur, prev))
        if a.deltas:
            for label, rel, kind, x, y in deltas(prev, cur):
                print(f"  {'+' if y > x else '−'} {label}: {rel} [{kind}] {x} → {y}")
    if a.state:
        a.state.parent.mkdir(parents=True, exist_ok=True)
        a.state.write_text(json.dumps(cur, indent=1) + "\n")
    return 1 if cur["red"] else 0


if __name__ == "__main__":
    sys.exit(main())
