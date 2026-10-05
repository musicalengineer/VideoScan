#!/usr/bin/env python3
"""Blocking complexity gate: pre-commit (staged files) and CI preflight (whole tree).

Why this exists (GH #281)
-------------------------
`.swiftlint.yml` has had error thresholds for years (cyclomatic_complexity 30,
function_body_length 300), but scripts/git-hooks/pre-commit ran SwiftLint with
`|| true`, so nothing ever stopped a commit, and ci.yml stopped running
SwiftLint on 2026-06-02. Functions grew past both lines unchecked. The nightly
complexity report (scripts/complexity_metrics.py) shows the debt; this gate
stops NEW debt at the door.

What blocks
-----------
  * a function over the gate (CCN > 30 or NLOC > 300) that is NOT on the
    committed baseline (ci/baselines/complexity_debt.json)            -> NEW
  * a baseline function over the gate whose CCN rose, or whose length grew
    by more than 5 lines over its baseline value                      -> WORSE
  * a `swiftlint:disable` of cyclomatic_complexity, function_body_length,
    file_length or type_body_length beyond the grandfathered count for
    that file (the four that existed on 2026-10-05 are baselined)     -> DISABLE

Existing offenders that do not get worse pass, so their files can still be
edited. Functions between the report limits (CCN 15 / 80 lines) and the gate
are reported by the nightly only.

Function identity is the same `file::Type.function` key the nightly uses, so
a moved or renamed big function reads as NEW. That is deliberate: it is the
moment to split it, or to override with a reason.

Escape hatch (leaves a trace, never silent)
-------------------------------------------
    COMPLEXITY_OVERRIDE="why this has to go in now" git commit ...

The gate prints what it let through and appends a record (time, reason, the
functions and disables, their CCN/lines) to ci/baselines/complexity_overrides.jsonl
and stages that file into the same commit. CI preflight honors recorded
overrides (at the recorded size: growing further blocks again); the nightly
lists every override from the last 48 h in the morning digest and on its
summary. `git commit --no-verify` skips the hook entirely, but CI preflight
then fails on the same function, because no override was recorded.

Caveat: `git commit <paths>` commits from a temporary index, so the override
record staged by the hook is NOT part of that commit. Use `git add` + plain
`git commit` when overriding.

Usage
-----
    python3 scripts/complexity_gate.py --staged   # the pre-commit hook
    python3 scripts/complexity_gate.py --all      # CI preflight
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import subprocess
import sys
from typing import Callable, Dict, List, Optional, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import complexity_metrics as cm  # noqa: E402

GATE_CCN = 30          # same as .swiftlint.yml cyclomatic_complexity: error
GATE_NLOC = 300        # same as .swiftlint.yml function_body_length: error
NLOC_SLACK = 5         # a known big function may grow this much in total, no more

HOW_TO_FIX = ("Split it: pull branches or steps out into named helpers. If it truly has to go in "
              "as is: COMPLEXITY_OVERRIDE=\"<reason>\" git commit ... (recorded and reported nightly).")


def over_gate(f: cm.Func) -> bool:
    return f.ccn > GATE_CCN or f.nloc > GATE_NLOC


def function_violations(funcs: Sequence[cm.Func], baseline: Dict[str, dict],
                        allowed: Dict[str, dict]) -> List[dict]:
    out = []
    for f in funcs:
        if not over_gate(f):
            continue
        refs = [r for r in (baseline.get(f.key), allowed.get(f.key)) if r]
        if not refs:
            out.append({"kind": "new", "func": f, "ref": None})
            continue
        ref = {"ccn": max(r["ccn"] for r in refs), "nloc": max(r["nloc"] for r in refs)}
        if f.ccn > ref["ccn"] or f.nloc > ref["nloc"] + NLOC_SLACK:
            out.append({"kind": "worse", "func": f, "ref": ref})
    return sorted(out, key=lambda v: (-v["func"].ccn, -v["func"].nloc, v["func"].key))


def disable_violations(current: Dict[str, int], baseline: Dict[str, int],
                       allowed: Dict[str, int]) -> List[dict]:
    out = []
    for key, n in sorted(current.items()):
        limit = max(baseline.get(key, 0), allowed.get(key, 0))
        if n > limit:
            out.append({"key": key, "count": n, "allowed": limit})
    return out


def format_violations(funcs: List[dict], disables: List[dict]) -> List[str]:
    lines = []
    for v in funcs:
        f = v["func"]
        what = ("NEW function over the gate" if v["kind"] == "new"
                else f"got WORSE (baseline CCN {v['ref']['ccn']}, {v['ref']['nloc']} lines)")
        lines.append(f"  BLOCKED  CCN {f.ccn:>3}  {f.nloc:>4} lines  {f.file} :: {f.display}  — {what}")
    for d in disables:
        path, rule = d["key"].split("|", 1)
        lines.append(f"  BLOCKED  new `swiftlint:disable {rule}` in {path} "
                     f"({d['count']} now, {d['allowed']} grandfathered)")
    return lines


def override_record(reason: str, funcs: List[dict], disables: List[dict], now: _dt.datetime) -> dict:
    return {
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "reason": reason,
        "functions": {v["func"].key: {"ccn": v["func"].ccn, "nloc": v["func"].nloc} for v in funcs},
        "disables": {d["key"]: d["count"] for d in disables},
    }


def run_gate(sources: Dict[str, str], baseline_path: str, overrides_path: str,
             override_reason: str = "", record_override: bool = True,
             out: Callable[[str], None] = print,
             now: Optional[_dt.datetime] = None) -> int:
    """Check `sources` ({repo-relative path: text}). 0 = pass (or overridden), 1 = blocked."""
    scoped = {p: t for p, t in sources.items() if cm.in_scope(p)}
    funcs, _ = cm.analyze_sources(scoped)
    current_disables: Dict[str, int] = {}
    for path, text in scoped.items():
        current_disables.update(cm.count_disables(path, text))

    allowed_funcs, allowed_disables = cm.override_allowances(cm.load_overrides(overrides_path))
    fv = function_violations(funcs, cm.load_baseline(baseline_path), allowed_funcs)
    dv = disable_violations(current_disables, cm.load_disables(baseline_path), allowed_disables)

    if not fv and not dv:
        out(f"complexity gate: OK ({len(scoped)} file(s), {len(funcs)} function(s); "
            f"limit CCN {GATE_CCN} / {GATE_NLOC} lines)")
        return 0

    out(f"complexity gate: {len(fv) + len(dv)} problem(s) "
        f"(limit CCN {GATE_CCN} / {GATE_NLOC} lines; known offenders may not grow)")
    for line in format_violations(fv, dv):
        out(line)

    reason = (override_reason or "").strip()
    if reason:
        rec = override_record(reason, fv, dv, now or _dt.datetime.now(_dt.timezone.utc))
        if record_override:
            os.makedirs(os.path.dirname(overrides_path) or ".", exist_ok=True)
            with open(overrides_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(rec, separators=(",", ":")) + "\n")
        out(f"complexity gate: OVERRIDDEN — \"{reason}\". Recorded in "
            f"{os.path.relpath(overrides_path) if os.path.isabs(overrides_path) else overrides_path}; "
            "the nightly will report it.")
        return 0

    out("  " + HOW_TO_FIX)
    return 1


# ---------------------------------------------------------------------------
# git plumbing (kept thin; tests call run_gate directly)

def _git(root: str, *args: str) -> bytes:
    return subprocess.run(["git", "-C", root, *args], capture_output=True, check=True).stdout


def staged_sources(root: str) -> Dict[str, str]:
    names = _git(root, "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z").decode("utf-8", "replace")
    out: Dict[str, str] = {}
    for path in (p for p in names.split("\0") if p and cm.in_scope(p)):
        out[path] = _git(root, "show", f":{path}").decode("utf-8", "replace")
    return out


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true", help="check staged files (pre-commit)")
    mode.add_argument("--all", action="store_true", help="check the whole tree (CI preflight)")
    parser.add_argument("--root", default="")
    parser.add_argument("--baseline", default=cm.DEFAULT_SEED)
    parser.add_argument("--overrides", default=cm.DEFAULT_OVERRIDES)
    args = parser.parse_args(argv)

    try:
        import lizard  # noqa: F401
    except ImportError:
        print("complexity gate: lizard is not installed for this python "
              f"({sys.executable}). Install it: <repo>/venv/bin/pip install lizard==1.22.1")
        return 1

    root = args.root
    if not root:
        try:
            root = _git(".", "rev-parse", "--show-toplevel").decode().strip()
        except (OSError, subprocess.CalledProcessError):
            root = "."
    baseline = os.path.join(root, args.baseline)
    overrides = os.path.join(root, args.overrides)

    if args.staged:
        sources = staged_sources(root)
        if not sources:
            return 0
        code = run_gate(sources, baseline, overrides,
                        override_reason=os.environ.get("COMPLEXITY_OVERRIDE", ""))
        if code == 0 and os.environ.get("COMPLEXITY_OVERRIDE", "").strip() and os.path.exists(overrides):
            try:
                _git(root, "add", "--", args.overrides)
            except (OSError, subprocess.CalledProcessError):
                print(f"complexity gate: could not stage {args.overrides}; add it to the commit yourself.")
        return code

    # --all: CI honors recorded overrides only; an override env var here is ignored.
    return run_gate(cm.read_tree(root), baseline, overrides, override_reason="", record_override=False)


if __name__ == "__main__":
    raise SystemExit(main())
