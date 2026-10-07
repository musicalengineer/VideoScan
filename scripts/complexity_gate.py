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
  * the CCN 15 "no-worse" EXCESS ratchet (Rick 2026-10-07; functions over
    CCN 15 went 277 -> 345 in ten nights while the count over 30 stayed
    flat). A function's excess is max(0, CCN - 15):
      - pre-commit: the total excess across the touched files is higher
        in the staged copy than at HEAD (a new file is 0 at HEAD). The
        functions whose excess rose are listed, with before/after CCN -> RATCHET
      - pre-commit: any function above 15 whose CCN rose (or that rose
        past 15), even when the total fell because another function
        shrank more                                                   -> RATCHET-WORSE
      - CI (--all): the whole tree's total excess is above the committed
        ci/baselines/complexity_ccn15_excess.json (excess a recorded
        override let in is not counted)                               -> RATCHET

CCN is one signal for flagging a module, not a target to obey. That is why
the ratchet sums the EXCESS instead of counting functions over 15: splitting
PrunePlan.plan (CCN 52, excess 37) into two honest 26s lowers the total to
22 and passes; a 40 plus a 20 (25 + 5 = 30) passes too; a split that leaves
more excess than it started with, any growth of a function above 15, and a
new function above 15 that raises the touched files' total all block.
RATCHET-WORSE is kept beside the sum because the sum alone would let one
function grow as long as another shrank more in the same commit.

Existing offenders that do not get worse pass, so their files can still be
edited. The fix for a RATCHET block is to split along a real concept (an
enum, a value type, a focused protocol, a pure function), never to chunk the
function into step1/step2 helpers: see "Splitting a function" in
docs/practices/nightly-metrics-setup.md.

Function identity is the same `file::Type.function` key the nightly uses.
A function that is not on the baseline under its key is first matched against
baseline entries that vanished from the touched files (same bare name, CCN no
higher, at most 5 more lines): moving a known offender into a new file, as a
refactor does, passes; moving it AND growing it does not. Guarded disables
are counted per rule across the touched files, so a grandfathered
`swiftlint:disable:next` can move with its function. The CCN 15 ratchet
sums across ALL the touched files together, with the same move matching
(here without the line limit: it watches CCN only), so moving a function
between touched files, or splitting a file, passes. A function that moved
and also got more complex is paired with its old self by bare name and
judged RATCHET-WORSE.

The CI total is one number for the whole tree, so moves between files cannot
trip it. It only shrinks: the 2 AM nightly (scripts/complexity_baseline_nightly.py)
lowers it with the debt baseline; regenerate it deliberately with

    python3 scripts/complexity_metrics.py --update-ccn15-excess

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
functions are recorded exactly like NEW / WORSE ones, plus the excess each
let in (`ratchet_excess`), which CI credits back. CI preflight honors
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
RATCHET_HINT = ("CCN is a signal, not the goal. Split along a real concept (an enum, value type, focused "
                "protocol, pure function), never step1/step2 helpers. See \"Splitting a function\" in "
                "docs/practices/nightly-metrics-setup.md.")


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


def ratchet_violations(before_funcs: Sequence[cm.Func], after_funcs: Sequence[cm.Func]
                       ) -> Tuple[List[dict], Tuple[int, int], Dict[str, int]]:
    """The pre-commit CCN 15 excess ratchet over the touched files.

    Returns (violations, (total excess at HEAD, staged), {key: excess the
    function gained}). RATCHET entries are NEW functions above 15 (no HEAD
    counterpart), reported only when the touched files' total excess went
    up: an honest split, or a commit that adds one function and simplifies
    another by more, passes. RATCHET-WORSE entries are functions that exist
    at HEAD and gained excess (grew above 15, or crossed it), whatever the
    total did: the sum alone would let one function grow while another
    shrank."""
    before = {f.key: f for f in before_funcs}
    band = [f for f in after_funcs if cm.excess(f)]
    totals = (sum(cm.excess(f) for f in before_funcs), sum(cm.excess(f) for f in after_funcs))
    pairs = _pair_with_before(band, before, {f.key for f in after_funcs})
    out, fresh, gained = [], [], {}
    for f in band:
        prev = pairs.get(f.key)
        gain = cm.excess(f) - (cm.excess(prev) if prev is not None else 0)
        if gain <= 0:
            continue
        gained[f.key] = gain
        if prev is None:
            fresh.append(f)
        else:
            out.append({"kind": "ratchet-worse", "func": f, "ref": {"ccn": prev.ccn, "nloc": prev.nloc}})
    if totals[1] > totals[0]:
        out += [{"kind": "ratchet", "func": f, "ref": None} for f in fresh]
    return sorted(out, key=lambda v: (-v["func"].ccn, -v["func"].nloc, v["func"].key)), totals, gained


def excess_violation(funcs: Sequence[cm.Func], baseline: dict, allowed: Dict[str, dict]) -> Optional[dict]:
    """CI's CCN 15 ratchet: the whole tree's total excess against the committed one."""
    total = cm.excess_total(funcs, allowed)
    if total <= baseline["total_excess"]:
        return None
    files = cm.excess_by_file(funcs)
    grew = {p: n - baseline["files"].get(p, 0) for p, n in files.items() if n > baseline["files"].get(p, 0)}
    return {"total": total, "allowed": baseline["total_excess"], "grew": grew}


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
        return (f"RATCHET: new above CCN {RATCHET_CCN} (no HEAD version; CCN {v['func'].ccn}, "
                f"excess +{v['func'].ccn - RATCHET_CCN})")
    return (f"RATCHET-WORSE: CCN rose from {v['ref']['ccn']} to {v['func'].ccn} "
            f"(keep it at {max(v['ref']['ccn'], RATCHET_CCN)} or lower)")


def format_violations(funcs: List[dict], disables: List[dict],
                      ratchet_totals: Optional[Tuple[int, int]] = None,
                      tree_excess: Optional[dict] = None) -> List[str]:
    lines = []
    if ratchet_totals and ratchet_totals[1] > ratchet_totals[0]:
        lines.append(f"  BLOCKED  RATCHET: total excess over CCN {RATCHET_CCN} in the touched files went "
                     f"{ratchet_totals[0]} -> {ratchet_totals[1]}")
    for v in funcs:
        f = v["func"]
        lines.append(f"  BLOCKED  CCN {f.ccn:>3}  {f.nloc:>4} lines  {f.file} :: {f.display}  — {_what(v)}")
    for d in disables:
        lines.append(f"  BLOCKED  new `swiftlint:disable {d['rule']}` in {', '.join(d['files'])} "
                     f"({d['count']} now, {d['allowed']} grandfathered in these files)")
    if tree_excess:
        grew = ", ".join(f"{p} (+{n})" for p, n in sorted(tree_excess["grew"].items())) or "none by file (moves)"
        lines.append(f"  BLOCKED  RATCHET: total excess over CCN {RATCHET_CCN} in the tree is "
                     f"{tree_excess['total']}, {tree_excess['allowed']} allowed by {cm.DEFAULT_CCN15_EXCESS}. "
                     f"Files above their excess there: {grew}")
    return lines


def override_record(reason: str, funcs: List[dict], disables: List[dict], now: _dt.datetime,
                    author: str = "", ratchet_excess: Optional[Dict[str, int]] = None) -> dict:
    """The trace an override leaves. The commit SHA does not exist yet at
    pre-commit time; the nightly resolves it from the log's history. Author
    NAME only, never an email (public repo). `ratchet_excess` is the CCN 15
    excess each function gained, which CI credits back."""
    return {
        "ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "reason": reason,
        "author": author,
        "functions": {v["func"].key: {"ccn": v["func"].ccn, "nloc": v["func"].nloc} for v in funcs},
        "disables": {k: n for d in disables for k, n in d["counts"].items()},
        "ratchet_excess": dict(sorted((ratchet_excess or {}).items())),
    }


def run_gate(sources: Dict[str, str], baseline_path: str, overrides_path: str,
             override_reason: str = "", record_override: bool = True,
             out: Callable[[str], None] = print,
             now: Optional[_dt.datetime] = None, min_files: int = 0,
             read_untouched: Optional[Callable[[str], Optional[str]]] = None,
             author: str = "", before: Optional[Dict[str, str]] = None,
             excess_path: Optional[str] = None) -> int:
    """Check `sources` ({repo-relative path: text}; a deleted file is ""). The
    set of paths is what was touched. 0 = pass (or overridden), 1 = blocked.

    The CCN 15 excess ratchet runs when the caller gives it something to
    compare with: `before` ({path: text at HEAD}, "" or absent = new file)
    for the pre-commit check, or `excess_path` (the committed whole-tree
    total) for CI. An `excess_path` that does not exist fails closed."""
    scoped = {p: t for p, t in sources.items() if cm.in_scope(p)}
    if len(scoped) < min_files:
        out(f"complexity gate: only {len(scoped)} in-scope file(s) found, expected at least "
            f"{min_files}. Refusing to pass an empty or broken listing.")
        return 1
    excess_base = None
    if excess_path is not None:
        excess_base = cm.load_ccn15_excess(excess_path)
        if excess_base is None:
            out(f"complexity gate: no CCN {RATCHET_CCN} excess baseline at {excess_path}. Regenerate it "
                "from a known-good tree: python3 scripts/complexity_metrics.py --update-ccn15-excess")
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
    totals: Optional[Tuple[int, int]] = None
    gained: Dict[str, int] = {}
    if before is not None:
        before_funcs, _ = cm.analyze_sources({p: before.get(p) or "" for p in scoped})
        rv, totals, gained = ratchet_violations(before_funcs, funcs)
        shown = {v["func"].key for v in fv}
        rv = [v for v in rv if v["func"].key not in shown]     # a NEW / WORSE line already names it
    tree_excess = (excess_violation(funcs, excess_base, cm.excess_allowances(cm.load_overrides(overrides_path)))
                   if excess_base is not None else None)

    blocked_funcs = fv + rv
    ratchet_note = ""
    if totals is not None:
        ratchet_note = f"; excess over CCN {RATCHET_CCN}: {totals[0]} -> {totals[1]}"
    elif excess_base is not None:
        now_excess = cm.excess_total(funcs, cm.excess_allowances(cm.load_overrides(overrides_path)))
        ratchet_note = (f"; excess over CCN {RATCHET_CCN}: {now_excess} of "
                        f"{excess_base['total_excess']} allowed")
    total_rose = bool(totals and totals[1] > totals[0])
    if not blocked_funcs and not dv and not tree_excess and not total_rose:
        out(f"complexity gate: OK ({len(scoped)} file(s), {len(funcs)} function(s); "
            f"limit CCN {GATE_CCN} / {GATE_NLOC} lines{ratchet_note})")
        return 0

    problems = len(blocked_funcs) + len(dv) + (1 if tree_excess else 0)
    out(f"complexity gate: {max(problems, 1)} problem(s) "
        f"(limit CCN {GATE_CCN} / {GATE_NLOC} lines; known offenders may not grow; "
        f"no more complexity above CCN {RATCHET_CCN}{ratchet_note})")
    for line in format_violations(blocked_funcs, dv, totals, tree_excess):
        out(line)

    reason = (override_reason or "").strip()
    if reason:
        let_in = {v["func"].key: gained[v["func"].key] for v in blocked_funcs if v["func"].key in gained}
        rec = override_record(reason, blocked_funcs, dv, now or _dt.datetime.now(_dt.timezone.utc), author,
                              ratchet_excess=let_in)
        if record_override:
            os.makedirs(os.path.dirname(overrides_path) or ".", exist_ok=True)
            with open(overrides_path, "a", encoding="utf-8") as handle:
                handle.write(json.dumps(rec, separators=(",", ":")) + "\n")
        out(f"complexity gate: OVERRIDDEN by {author or 'unknown author'} — \"{reason}\". Recorded in "
            f"{os.path.relpath(overrides_path) if os.path.isabs(overrides_path) else overrides_path}; "
            "the morning digest will show it to Rick as a 🔴 item.")
        return 0

    if rv or tree_excess or total_rose:
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
    parser.add_argument("--ccn15-excess", default=cm.DEFAULT_CCN15_EXCESS,
                        help="CI's whole-tree CCN 15 total excess (--all only)")
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
                    min_files=ALL_MODE_MIN_FILES, excess_path=os.path.join(root, args.ccn15_excess))


if __name__ == "__main__":
    raise SystemExit(main())
