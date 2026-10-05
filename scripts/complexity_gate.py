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

Function identity is the same `file::Type.function` key the nightly uses.
A function that is not on the baseline under its key is first matched against
baseline entries that vanished from the touched files (same bare name, CCN no
higher, at most 5 more lines): moving a known offender into a new file, as a
refactor does, passes; moving it AND growing it does not. Guarded disables
are counted per rule across the touched files, so a grandfathered
`swiftlint:disable:next` can move with its function.

Escape hatch (Rick's alone; leaves a trace, never silent)
---------------------------------------------------------
Rick 2026-10-05: only Rick may sweep debt under the rug. Agents are denied
COMPLEXITY_OVERRIDE and `git commit --no-verify` in .claude/settings.json.
Every override is a 🔴 item in the next morning digest (function, CCN,
lines, reason, commit, author) and is listed on the metrics page.

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
ALL_MODE_MIN_FILES = 500   # --all on this repo sees ~1,080; fewer = broken listing

HOW_TO_FIX = ("Split it: pull branches or steps out into named helpers. If it truly has to go in "
              "as is: COMPLEXITY_OVERRIDE=\"<reason>\" git commit ... (recorded and reported nightly).")


def over_gate(f: cm.Func) -> bool:
    return f.ccn > GATE_CCN or f.nloc > GATE_NLOC


def function_violations(funcs: Sequence[cm.Func], baseline: Dict[str, dict],
                        allowed: Dict[str, dict], touched: Optional[set] = None,
                        still_present: Optional[Callable[[str], bool]] = None) -> List[dict]:
    """NEW / WORSE functions over the gate.

    Before anything is called NEW it is matched against baseline entries that
    VANISHED from the files being checked (`touched`: the staged files,
    deletions included, or the whole tree): same bare name, CCN no higher,
    at most NLOC_SLACK more lines. So moving a known offender to another
    file, or a key change, passes as long as the function did not grow.

    A baseline entry in a file that was NOT touched is asked about through
    `still_present(key)` (pre-commit reads the staged copy of that file); if it
    is still there, the new function is a copy, not a move, and stays NEW.
    Without the callback it is assumed gone; CI's whole-tree run, where every
    file is touched, is the backstop for copies."""
    touched = touched if touched is not None else {f.file for f in funcs}
    present = {f.key for f in funcs}
    out, unknown = [], []
    for f in funcs:
        if not over_gate(f):
            continue
        refs = [r for r in (baseline.get(f.key), allowed.get(f.key)) if r]
        if not refs:
            unknown.append(f)
            continue
        ref = {"ccn": max(r["ccn"] for r in refs), "nloc": max(r["nloc"] for r in refs)}
        if f.ccn > ref["ccn"] or f.nloc > ref["nloc"] + NLOC_SLACK:
            out.append({"kind": "worse", "func": f, "ref": ref})
    names = {f.bare_name for f in unknown}
    vanished = {k: v for src in (baseline, allowed) for k, v in src.items()
                if k not in present and cm.key_bare_name(k) in names
                and (cm.key_file(k) in touched or not (still_present and still_present(k)))}
    moved = cm.match_moves(unknown, vanished, NLOC_SLACK)
    out += [{"kind": "new", "func": f, "ref": None} for f in unknown if f.key not in moved]
    return sorted(out, key=lambda v: (-v["func"].ccn, -v["func"].nloc, v["func"].key))


def disable_violations(current: Dict[str, int], baseline: Dict[str, int],
                       allowed: Dict[str, int], touched: Optional[set] = None) -> List[dict]:
    """Per RULE, across the files being checked: more guarded
    `swiftlint:disable`s than the grandfathered (+ overridden) ones in those
    same files. Counting per rule rather than per file lets a disable move
    with its function."""
    touched = touched if touched is not None else {k.split("|", 1)[0] for k in current}

    def per_rule(counts: Dict[str, int]) -> Dict[str, int]:
        out: Dict[str, int] = {}
        for key, n in counts.items():
            path, rule = key.split("|", 1)
            if path in touched:
                out[rule] = out.get(rule, 0) + n
        return out

    cur, base, extra = per_rule(current), per_rule(baseline), per_rule(allowed)
    out = []
    for rule, n in sorted(cur.items()):
        limit = base.get(rule, 0) + extra.get(rule, 0)
        if n > limit:
            files = sorted(k.split("|", 1)[0] for k in current if k.endswith("|" + rule))
            out.append({"rule": rule, "count": n, "allowed": limit,
                        "files": files, "counts": {f"{p}|{rule}": current[f"{p}|{rule}"] for p in files}})
    return out


def format_violations(funcs: List[dict], disables: List[dict]) -> List[str]:
    lines = []
    for v in funcs:
        f = v["func"]
        what = ("NEW function over the gate" if v["kind"] == "new"
                else f"got WORSE (baseline CCN {v['ref']['ccn']}, {v['ref']['nloc']} lines)")
        lines.append(f"  BLOCKED  CCN {f.ccn:>3}  {f.nloc:>4} lines  {f.file} :: {f.display}  — {what}")
    for d in disables:
        lines.append(f"  BLOCKED  new `swiftlint:disable {d['rule']}` in {', '.join(d['files'])} "
                     f"({d['count']} now, {d['allowed']} grandfathered in these files)")
    return lines


def override_record(reason: str, funcs: List[dict], disables: List[dict], now: _dt.datetime,
                    author: str = "") -> dict:
    """The trace an override leaves. The commit SHA does not exist yet at
    pre-commit time; the nightly resolves it from the log's history. Author
    NAME only, never an email (public repo)."""
    return {
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "reason": reason,
        "author": author,
        "functions": {v["func"].key: {"ccn": v["func"].ccn, "nloc": v["func"].nloc} for v in funcs},
        "disables": {k: n for d in disables for k, n in d["counts"].items()},
    }


def run_gate(sources: Dict[str, str], baseline_path: str, overrides_path: str,
             override_reason: str = "", record_override: bool = True,
             out: Callable[[str], None] = print,
             now: Optional[_dt.datetime] = None, min_files: int = 0,
             read_untouched: Optional[Callable[[str], Optional[str]]] = None,
             author: str = "") -> int:
    """Check `sources` ({repo-relative path: text}; a deleted file is ""). The
    set of paths is what was touched. 0 = pass (or overridden), 1 = blocked."""
    scoped = {p: t for p, t in sources.items() if cm.in_scope(p)}
    if len(scoped) < min_files:
        out(f"complexity gate: only {len(scoped)} in-scope file(s) found, expected at least "
            f"{min_files}. Refusing to pass an empty or broken listing.")
        return 1
    touched = set(scoped)
    funcs, _ = cm.analyze_sources(scoped)
    current_disables: Dict[str, int] = {}
    for path, text in scoped.items():
        current_disables.update(cm.count_disables(path, text))

    allowed_funcs, allowed_disables = cm.override_allowances(cm.load_overrides(overrides_path))
    cache: Dict[str, set] = {}

    def still_present(key: str) -> bool:
        path = cm.key_file(key)
        if read_untouched is None:
            return False
        if path not in cache:
            text = read_untouched(path)
            cache[path] = set() if text is None else {f.key for f in cm.analyze_sources({path: text})[0]}
        return key in cache[path]

    fv = function_violations(funcs, cm.load_baseline(baseline_path), allowed_funcs, touched, still_present)
    dv = disable_violations(current_disables, cm.load_disables(baseline_path), allowed_disables, touched)

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
        rec = override_record(reason, fv, dv, now or _dt.datetime.now(_dt.timezone.utc), author)
        if record_override:
            os.makedirs(os.path.dirname(overrides_path) or ".", exist_ok=True)
            with open(overrides_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(rec, separators=(",", ":")) + "\n")
        out(f"complexity gate: OVERRIDDEN by {author or 'unknown author'} — \"{reason}\". Recorded in "
            f"{os.path.relpath(overrides_path) if os.path.isabs(overrides_path) else overrides_path}; "
            "the morning digest will show it to Rick as a 🔴 item.")
        return 0

    out("  " + HOW_TO_FIX)
    return 1


# ---------------------------------------------------------------------------
# git plumbing (kept thin; tests call run_gate directly)

def _git(root: str, *args: str) -> bytes:
    return subprocess.run(["git", "-C", root, *args], capture_output=True, check=True).stdout


def author_name(root: str) -> str:
    """The commit's author NAME (GIT_AUTHOR_NAME or user.name); no email."""
    if os.environ.get("GIT_AUTHOR_NAME"):
        return os.environ["GIT_AUTHOR_NAME"]
    try:
        ident = _git(root, "var", "GIT_AUTHOR_IDENT").decode("utf-8", "replace")
        return ident.split("<", 1)[0].strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


def staged_sources(root: str) -> Dict[str, str]:
    """Staged blobs of added/changed files, and "" for deleted ones (a
    deletion is a touched file: an offender may have moved out of it).
    --no-renames so a rename shows as delete + add, both touched."""
    raw = _git(root, "diff", "--cached", "--name-status", "--no-renames",
               "--diff-filter=ACMD", "-z").decode("utf-8", "replace")
    parts = [p for p in raw.split("\0") if p]
    out: Dict[str, str] = {}
    for status, path in zip(parts[0::2], parts[1::2]):
        if not cm.in_scope(path):
            continue
        out[path] = "" if status == "D" else _git(root, "show", f":{path}").decode("utf-8", "replace")
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
        def read_index(path: str) -> Optional[str]:
            try:
                return _git(root, "show", f":{path}").decode("utf-8", "replace")
            except (OSError, subprocess.CalledProcessError):
                return None
        code = run_gate(sources, baseline, overrides,
                        override_reason=os.environ.get("COMPLEXITY_OVERRIDE", ""),
                        read_untouched=read_index, author=author_name(root))
        if code == 0 and os.environ.get("COMPLEXITY_OVERRIDE", "").strip() and os.path.exists(overrides):
            try:
                _git(root, "add", "--", args.overrides)
            except (OSError, subprocess.CalledProcessError):
                print(f"complexity gate: could not stage {args.overrides}; add it to the commit yourself.")
        return code

    # --all: CI honors recorded overrides only; an override env var here is ignored.
    return run_gate(cm.read_tree(root), baseline, overrides, override_reason="", record_override=False,
                    min_files=ALL_MODE_MIN_FILES)


if __name__ == "__main__":
    raise SystemExit(main())
