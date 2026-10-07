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
  * the CCN 15 "no-worse" ratchet (Rick 2026-10-07; functions over CCN 15
    went 277 -> 345 in ten nights while the count over 30 stayed flat):
      - pre-commit: across the touched files, more functions over CCN 15
        in the staged copy than at HEAD (a new file counts 0 at HEAD).
        Every function that newly crossed 15 is listed               -> RATCHET
      - pre-commit: a function that was in the 15-30 band at HEAD and
        whose CCN rose (lowering it or leaving it alone passes)       -> RATCHET-WORSE
      - CI (--all): more functions over CCN 15 in the whole tree than
        the committed count, ci/baselines/complexity_ccn15_counts.json
        (functions let in by a recorded override are not counted)    -> RATCHET

Existing offenders that do not get worse pass, so their files can still be
edited. The fix for a RATCHET block is to split along a real concept (a
decision, a phase with its own data, a type's responsibility), not to chunk
the function into step1/step2 helpers: see "Splitting a function" in
docs/practices/nightly-metrics-setup.md.

Function identity is the same `file::Type.function` key the nightly uses.
A function that is not on the baseline under its key is first matched against
baseline entries that vanished from the touched files (same bare name, CCN no
higher, at most 5 more lines): moving a known offender into a new file, as a
refactor does, passes; moving it AND growing it does not. Guarded disables
are counted per rule across the touched files, so a grandfathered
`swiftlint:disable:next` can move with its function. The CCN 15 ratchet
counts across ALL the touched files together, with the same move matching
(here without the line limit: it watches CCN only), so moving a function
between touched files, or splitting a file, passes. A function that moved
and also got more complex is paired with its old self by bare name and
judged RATCHET-WORSE.

The CI count is one number for the whole tree, so moves between files cannot
trip it. It only shrinks: the 2 AM nightly (scripts/complexity_baseline_nightly.py)
lowers it with the debt baseline; regenerate it deliberately with

    python3 scripts/complexity_metrics.py --update-ccn15-counts

and say why in the commit.

Escape hatch (Rick's alone; leaves a trace, never silent)
---------------------------------------------------------
Rick 2026-10-05: only Rick may sweep debt under the rug. Agents are denied
COMPLEXITY_OVERRIDE and `git commit --no-verify` in .claude/settings.json.
Every override is a 🔴 item in the next morning digest (function, CCN,
lines, reason, commit, author) and is listed on the metrics page.

    COMPLEXITY_OVERRIDE="why this has to go in now" git commit ...

The gate prints what it let through and appends a record (time, reason, the
functions and disables, their CCN/lines) to ci/baselines/complexity_overrides.jsonl
and stages that file into the same commit. RATCHET and RATCHET-WORSE
functions are recorded exactly like NEW / WORSE ones. CI preflight honors
recorded overrides (at the recorded size: growing further blocks again); the
nightly lists every override from the last 48 h in the morning digest and on
its summary. `git commit --no-verify` skips the hook entirely, but CI
preflight then fails on the same function, because no override was recorded.

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
from typing import Callable, Dict, List, Optional, Sequence, Tuple

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import complexity_metrics as cm  # noqa: E402

GATE_CCN = cm.GATE_CCN      # defined once, in complexity_metrics
GATE_NLOC = cm.GATE_NLOC
RATCHET_CCN = cm.CCN_LIMIT  # 15: the no-worse ratchet's line, same as the nightly report's
NLOC_SLACK = cm.MOVE_NLOC_SLACK   # a known big function may grow this much in total, no more
ANY_LENGTH = 10 ** 9        # the CCN 15 ratchet watches CCN only; a moved function may be any length
ALL_MODE_MIN_FILES = 500   # --all on this repo sees ~1,080; fewer = broken listing

HOW_TO_FIX = ("Split it: pull branches or steps out into named helpers. If it truly has to go in "
              "as is: COMPLEXITY_OVERRIDE=\"<reason>\" git commit ... (recorded and reported nightly).")
RATCHET_HINT = ("Bring it to CCN 15 or below by splitting along a real concept (a decision, a phase with "
                "its own data, a type's responsibility; see \"Splitting a function\" in "
                "docs/practices/nightly-metrics-setup.md). Don't chunk it into step1/step2 helpers.")


over_gate = cm.over_gate


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
    moved = cm.match_unknown(unknown, vanished, NLOC_SLACK)
    out += [{"kind": "new", "func": f, "ref": None} for f in unknown if f.key not in moved]
    return sorted(out, key=lambda v: (-v["func"].ccn, -v["func"].nloc, v["func"].key))


def _pair_with_before(band: Sequence[cm.Func], before: Dict[str, cm.Func],
                      after_keys: set) -> Dict[str, cm.Func]:
    """{after key: the same function at HEAD} for every after-side function
    over CCN 15 that can be traced: by key, then by the shared move matching
    (bare name, CCN no higher), then, for one that moved AND grew, by bare
    name alone (same file first, then the closest CCN). Each HEAD function
    is used once."""
    pairs = {f.key: before[f.key] for f in band if f.key in before}
    unknown = [f for f in band if f.key not in before]
    vanished = {k: {"ccn": b.ccn, "nloc": b.nloc} for k, b in before.items() if k not in after_keys}
    moves = cm.match_unknown(unknown, vanished, ANY_LENGTH)
    pairs.update({new: before[old] for new, old in moves.items()})
    pool = {k for k in vanished if k not in set(moves.values())}
    for f in sorted((f for f in unknown if f.key not in moves), key=lambda f: (-f.ccn, f.key)):
        same = [k for k in pool if cm.key_bare_name(k) == f.bare_name]
        if same:
            best = min(same, key=lambda k: (cm.key_file(k) != f.file, abs(before[k].ccn - f.ccn), k))
            pairs[f.key] = before[best]
            pool.discard(best)
    return pairs


def ratchet_violations(before_funcs: Sequence[cm.Func],
                       after_funcs: Sequence[cm.Func]) -> Tuple[List[dict], Tuple[int, int]]:
    """The pre-commit CCN 15 ratchet over the touched files.

    Returns (violations, (count at HEAD, count staged)). RATCHET entries are
    the functions that newly crossed CCN 15 (new, or rose from 15 or below),
    reported only when the touched files' count went up: a commit that adds
    one and fixes another nets zero and passes. RATCHET-WORSE entries are
    functions that were in the 15-30 band at HEAD and whose CCN rose;
    above 30 the debt baseline (WORSE) is the judge."""
    before = {f.key: f for f in before_funcs}
    band = [f for f in after_funcs if f.ccn > RATCHET_CCN]
    counts = (sum(1 for f in before_funcs if f.ccn > RATCHET_CCN), len(band))
    pairs = _pair_with_before(band, before, {f.key for f in after_funcs})
    out, entrants = [], []
    for f in band:
        prev = pairs.get(f.key)
        if prev is None or prev.ccn <= RATCHET_CCN:
            entrants.append(f)
        elif prev.ccn <= GATE_CCN and f.ccn > prev.ccn:
            out.append({"kind": "ratchet-worse", "func": f, "ref": {"ccn": prev.ccn, "nloc": prev.nloc}})
    if counts[1] > counts[0]:
        out += [{"kind": "ratchet", "func": f, "ref": None} for f in entrants]
    return sorted(out, key=lambda v: (-v["func"].ccn, -v["func"].nloc, v["func"].key)), counts


def count_violation(funcs: Sequence[cm.Func], counts: dict, allowed: Dict[str, dict]) -> Optional[dict]:
    """CI's CCN 15 ratchet: the whole tree against the committed count."""
    total = cm.band_total(funcs, allowed)
    if total <= counts["total"]:
        return None
    files = cm.band_counts(funcs)
    grew = {p: n - counts["files"].get(p, 0) for p, n in files.items() if n > counts["files"].get(p, 0)}
    return {"total": total, "allowed": counts["total"], "grew": grew}


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


def _what(v: dict) -> str:
    kind = v["kind"]
    if kind == "new":
        return "NEW function over the gate"
    if kind == "worse":
        return f"got WORSE (baseline CCN {v['ref']['ccn']}, {v['ref']['nloc']} lines)"
    if kind == "ratchet":
        return f"RATCHET: new over CCN {RATCHET_CCN}"
    return f"RATCHET-WORSE: CCN rose from {v['ref']['ccn']} (keep it at {v['ref']['ccn']} or lower)"


def format_violations(funcs: List[dict], disables: List[dict],
                      ratchet_counts: Optional[Tuple[int, int]] = None,
                      tree_count: Optional[dict] = None) -> List[str]:
    lines = []
    if ratchet_counts and ratchet_counts[1] > ratchet_counts[0]:
        lines.append(f"  BLOCKED  RATCHET: functions over CCN {RATCHET_CCN} in the touched files went "
                     f"{ratchet_counts[0]} -> {ratchet_counts[1]}")
    for v in funcs:
        f = v["func"]
        lines.append(f"  BLOCKED  CCN {f.ccn:>3}  {f.nloc:>4} lines  {f.file} :: {f.display}  — {_what(v)}")
    for d in disables:
        lines.append(f"  BLOCKED  new `swiftlint:disable {d['rule']}` in {', '.join(d['files'])} "
                     f"({d['count']} now, {d['allowed']} grandfathered in these files)")
    if tree_count:
        grew = ", ".join(f"{p} (+{n})" for p, n in sorted(tree_count["grew"].items())) or "none by file (moves)"
        lines.append(f"  BLOCKED  RATCHET: {tree_count['total']} functions over CCN {RATCHET_CCN} in the tree, "
                     f"{tree_count['allowed']} allowed by {cm.DEFAULT_CCN15_COUNTS}. "
                     f"Files above their count there: {grew}")
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
             author: str = "", before: Optional[Dict[str, str]] = None,
             counts_path: Optional[str] = None) -> int:
    """Check `sources` ({repo-relative path: text}; a deleted file is ""). The
    set of paths is what was touched. 0 = pass (or overridden), 1 = blocked.

    The CCN 15 ratchet runs when the caller gives it something to compare
    with: `before` ({path: text at HEAD}, "" or absent = new file) for the
    pre-commit check, or `counts_path` (the committed whole-tree count) for
    CI. A `counts_path` that does not exist fails closed."""
    scoped = {p: t for p, t in sources.items() if cm.in_scope(p)}
    if len(scoped) < min_files:
        out(f"complexity gate: only {len(scoped)} in-scope file(s) found, expected at least "
            f"{min_files}. Refusing to pass an empty or broken listing.")
        return 1
    counts = None
    if counts_path is not None:
        counts = cm.load_ccn15_counts(counts_path)
        if counts is None:
            out(f"complexity gate: no CCN {RATCHET_CCN} count baseline at {counts_path}. Regenerate it "
                "from a known-good tree: python3 scripts/complexity_metrics.py --update-ccn15-counts")
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

    rv: List[dict] = []
    ratchet_counts: Optional[Tuple[int, int]] = None
    if before is not None:
        before_funcs, _ = cm.analyze_sources({p: before.get(p) or "" for p in scoped})
        rv, ratchet_counts = ratchet_violations(before_funcs, funcs)
        shown = {v["func"].key for v in fv}
        rv = [v for v in rv if v["func"].key not in shown]     # a NEW / WORSE line already names it
    tree_count = count_violation(funcs, counts, allowed_funcs) if counts is not None else None

    blocked_funcs = fv + rv
    ratchet_note = ""
    if ratchet_counts is not None:
        ratchet_note = f"; over CCN {RATCHET_CCN}: {ratchet_counts[0]} -> {ratchet_counts[1]}"
    elif counts is not None:
        ratchet_note = f"; over CCN {RATCHET_CCN}: {cm.band_total(funcs, allowed_funcs)} of {counts['total']} allowed"
    count_rose = bool(ratchet_counts and ratchet_counts[1] > ratchet_counts[0])
    if not blocked_funcs and not dv and not tree_count and not count_rose:
        out(f"complexity gate: OK ({len(scoped)} file(s), {len(funcs)} function(s); "
            f"limit CCN {GATE_CCN} / {GATE_NLOC} lines{ratchet_note})")
        return 0

    problems = len(blocked_funcs) + len(dv) + (1 if tree_count else 0)
    out(f"complexity gate: {max(problems, 1)} problem(s) "
        f"(limit CCN {GATE_CCN} / {GATE_NLOC} lines; known offenders may not grow; "
        f"no more functions over CCN {RATCHET_CCN}{ratchet_note})")
    for line in format_violations(blocked_funcs, dv, ratchet_counts, tree_count):
        out(line)

    reason = (override_reason or "").strip()
    if reason:
        rec = override_record(reason, blocked_funcs, dv, now or _dt.datetime.now(_dt.timezone.utc), author)
        if record_override:
            os.makedirs(os.path.dirname(overrides_path) or ".", exist_ok=True)
            with open(overrides_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(rec, separators=(",", ":")) + "\n")
        out(f"complexity gate: OVERRIDDEN by {author or 'unknown author'} — \"{reason}\". Recorded in "
            f"{os.path.relpath(overrides_path) if os.path.isabs(overrides_path) else overrides_path}; "
            "the morning digest will show it to Rick as a 🔴 item.")
        return 0

    if rv or tree_count:
        out("  " + RATCHET_HINT)
    if fv or dv:
        out("  " + HOW_TO_FIX)
    else:
        out("  If it truly has to go in as is: COMPLEXITY_OVERRIDE=\"<reason>\" git commit ... "
            "(recorded and reported nightly).")
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


def head_sources(root: str, paths: Sequence[str]) -> Dict[str, str]:
    """HEAD's copy of each path; "" for a file HEAD does not have (new
    file, or the first commit)."""
    out: Dict[str, str] = {}
    for path in paths:
        try:
            out[path] = _git(root, "show", f"HEAD:{path}").decode("utf-8", "replace")
        except (OSError, subprocess.CalledProcessError):
            out[path] = ""
    return out


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--staged", action="store_true", help="check staged files (pre-commit)")
    mode.add_argument("--all", action="store_true", help="check the whole tree (CI preflight)")
    parser.add_argument("--root", default="")
    parser.add_argument("--baseline", default=cm.DEFAULT_SEED)
    parser.add_argument("--overrides", default=cm.DEFAULT_OVERRIDES)
    parser.add_argument("--ccn15-counts", default=cm.DEFAULT_CCN15_COUNTS,
                        help="CI's whole-tree CCN 15 count (--all only)")
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
                        read_untouched=read_index, author=author_name(root),
                        before=head_sources(root, list(sources)))
        if code == 0 and os.environ.get("COMPLEXITY_OVERRIDE", "").strip() and os.path.exists(overrides):
            try:
                _git(root, "add", "--", args.overrides)
            except (OSError, subprocess.CalledProcessError):
                print(f"complexity gate: could not stage {args.overrides}; add it to the commit yourself.")
        return code

    # --all: CI honors recorded overrides only; an override env var here is ignored.
    return run_gate(cm.read_tree(root), baseline, overrides, override_reason="", record_override=False,
                    min_files=ALL_MODE_MIN_FILES, counts_path=os.path.join(root, args.ccn15_counts))


if __name__ == "__main__":
    raise SystemExit(main())
