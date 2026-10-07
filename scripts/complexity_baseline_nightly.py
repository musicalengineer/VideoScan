#!/usr/bin/env python3
"""2 AM nightly (M4): commit the shrunk complexity baseline to main itself.

Rick 2026-10-05: the baseline (ci/baselines/complexity_debt.json) only
shrinks, and the nightly does the shrinking, so fixed debt is locked in
without anyone remembering to run `--shrink-baseline`.

Rules
-----
* REMOVALS ONLY, verified before committing: the new baseline may drop
  entries and lower CCN/NLOC values and grandfathered disable counts. If it
  would add an entry or raise any value, nothing is committed and the
  outcome is a 🔴 for the morning digest.
* The CCN 15 count (ci/baselines/complexity_ccn15_counts.json, Rick
  2026-10-07) rides in the same commit under the same rules: its `total`
  may only go down, checked on disk against origin/main, and the whole-tree
  gate must stay green with it.
* Never touches Rick's checkout (the nightly's dirty-tree rule: a dirty
  tree is never pulled, reset or committed to). All work happens in a
  dedicated worktree, detached at origin/main:
      ~/Library/Caches/VideoScan/complexity-baseline-wt
  The main checkout is asked only to `fetch`, `worktree prune` and
  `worktree add`. If that worktree itself is dirty (a crashed run), it is
  NOT reset: 🔴 and stop.
* Push is `HEAD:refs/heads/main`, never forced. A rejected push refetches,
  redoes the shrink on the new origin/main once, and retries.
* The outcome (OUTCOME line on stdout, and a JSON status file in
  ~/Library/Logs/VideoScan/complexity_baseline_commit.json) is read by
  scripts/morning_metrics.sh: 🔴 on refused / failed, ✅ on a commit,
  silent when nothing changed.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import json
import os
import subprocess
import sys
from typing import Callable, List, Optional, Sequence

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import complexity_metrics as cm  # noqa: E402

BASELINE_REL = os.path.join("ci", "baselines", "complexity_debt.json")
# The CCN 15 count CI checks (Rick 2026-10-07). Shrunk in the same commit, by
# the same rules: lower only, verified against origin/main, gate green.
COUNTS_REL = cm.DEFAULT_CCN15_COUNTS
DEFAULT_WT = os.path.expanduser("~/Library/Caches/VideoScan/complexity-baseline-wt")
DEFAULT_STATUS = os.path.expanduser("~/Library/Logs/VideoScan/complexity_baseline_commit.json")

Git = Callable[..., subprocess.CompletedProcess]


def real_git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    return subprocess.run(["git", *args], capture_output=True, text=True, check=check)


def _ok(git: Git, *args: str) -> bool:
    return git(*args, check=False).returncode == 0


def run_gate_all(wt: str) -> int:
    """`complexity_gate.py --all` on the worktree, against the baseline file
    as it now stands there (the NEW one). Quiet unless it fails."""
    import complexity_gate as gate
    lines: List[str] = []
    counts = os.path.join(wt, COUNTS_REL)
    code = gate.run_gate(cm.read_tree(wt), os.path.join(wt, BASELINE_REL),
                         os.path.join(wt, cm.DEFAULT_OVERRIDES), record_override=False,
                         out=lines.append, min_files=gate.ALL_MODE_MIN_FILES,
                         counts_path=counts if os.path.exists(counts) else None)
    if code:
        print("\n".join(lines))
    return code


def prepare_worktree(git: Git, repo: str, wt: str) -> Optional[str]:
    """Fresh worktree detached at origin/main. Returns a problem, or None."""
    if not _ok(git, "-C", repo, "fetch", "origin", "main", "--quiet"):
        return "fetch origin main failed"
    if os.path.isdir(os.path.join(wt, ".git")) or os.path.isfile(os.path.join(wt, ".git")):
        status = git("-C", wt, "status", "--porcelain", check=False)
        if status.returncode != 0:
            return f"worktree {wt} is unreadable"
        if status.stdout.strip():
            return f"worktree {wt} is dirty (left by an earlier run); not touching it"
        if not _ok(git, "-C", wt, "checkout", "--detach", "--quiet", "origin/main"):
            return "could not move the worktree to origin/main"
        return None
    _ok(git, "-C", repo, "worktree", "prune")
    if not _ok(git, "-C", repo, "worktree", "add", "--detach", wt, "origin/main"):
        return f"worktree add {wt} failed"
    return None


def default_count_plan(wt: str, counts_path: str) -> dict:
    return cm.ccn15_shrink_plan(wt, counts_path, os.path.join(wt, cm.DEFAULT_OVERRIDES))


def write_and_verify_debt(git: Git, wt: str, p: dict) -> Optional[str]:
    """Write the shrunk debt baseline and check it, on disk, against HEAD.
    Returns a refusal / failure reason ("!"-prefixed = failed), or None."""
    baseline_path = os.path.join(wt, BASELINE_REL)
    cm.write_baseline(baseline_path, p["entries"], p["disables"])
    old = git("-C", wt, "show", f"HEAD:{BASELINE_REL}", check=False)
    if old.returncode != 0:
        return "!cannot read the committed baseline"
    old_data = json.loads(old.stdout)
    new_entries, new_dis = cm.load_baseline(baseline_path), cm.load_disables(baseline_path)
    old_entries = {k: {"ccn": int(v["ccn"]), "nloc": int(v["nloc"])}
                   for k, v in old_data.get("entries", {}).items()}
    old_dis = {k: int(v) for k, v in old_data.get("swiftlint_disables", {}).items()}
    problems = cm.verify_removals_only(old_entries, new_entries, old_dis, new_dis)
    return "not removals-only: " + "; ".join(problems[:10]) if problems else None


def write_and_verify_counts(git: Git, wt: str, cp: dict) -> Optional[str]:
    """Write the lowered CCN 15 count and check it, on disk, against HEAD:
    it may only go down."""
    counts_path = os.path.join(wt, COUNTS_REL)
    cm.write_ccn15_counts(counts_path, cp["after"], cp["files"])
    old = git("-C", wt, "show", f"HEAD:{COUNTS_REL}", check=False)
    if old.returncode != 0:
        return "!cannot read the committed CCN 15 count"
    old_total, new_total = int(json.loads(old.stdout)["total"]), cm.load_ccn15_counts(counts_path)["total"]
    if new_total > old_total:
        return f"CCN 15 count would rise {old_total} -> {new_total}"
    return None


def run(repo: str, wt: str, git: Git = real_git,
        plan: Callable[[str, str], dict] = cm.shrink_plan,
        now: Optional[_dt.datetime] = None,
        gate_check: Optional[Callable[[str], int]] = None,
        count_plan: Optional[Callable[[str, str], dict]] = None) -> dict:
    """One attempt-with-one-retry. Returns the status record. The CCN 15
    count file is shrunk in the same commit when origin/main has one."""
    now = now or _dt.datetime.now(_dt.timezone.utc)
    gate_check = gate_check or run_gate_all
    count_plan = count_plan or default_count_plan
    status = {"ts": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "outcome": "", "detail": "",
              "before": None, "after": None, "fixed": 0, "commit": ""}
    for attempt in (1, 2):
        problem = prepare_worktree(git, repo, wt)
        if problem:
            return {**status, "outcome": "failed", "detail": problem}
        baseline_path = os.path.join(wt, BASELINE_REL)
        if not os.path.exists(baseline_path):
            return {**status, "outcome": "failed", "detail": f"no {BASELINE_REL} on origin/main"}
        p = plan(wt, baseline_path)
        status.update(before=p["before"], after=p["after"], fixed=len(p["fixed"]))
        if p["problems"]:
            return {**status, "outcome": "refused",
                    "detail": "not removals-only: " + "; ".join(p["problems"][:10])}
        counts_path = os.path.join(wt, COUNTS_REL)
        cp = count_plan(wt, counts_path) if os.path.exists(counts_path) else None
        if cp is not None:
            status.update(ccn15_before=cp["before"], ccn15_after=cp["after"])
            if cp["problems"]:
                return {**status, "outcome": "refused",
                        "detail": "CCN 15 count: " + "; ".join(cp["problems"][:10])}
        count_changed = bool(cp and cp["changed"])
        if not p["changed"] and not count_changed:
            return {**status, "outcome": "unchanged", "detail": "nothing fixed since the last baseline"}
        touched = ([BASELINE_REL] if p["changed"] else []) + ([COUNTS_REL] if count_changed else [])
        # Verify what is actually on disk against what origin/main has.
        why = (write_and_verify_debt(git, wt, p) if p["changed"] else None) \
            or (write_and_verify_counts(git, wt, cp) if count_changed else None)
        if why:
            _ok(git, "-C", wt, "checkout", "--", *touched)
            if why.startswith("!"):
                return {**status, "outcome": "failed", "detail": why[1:]}
            return {**status, "outcome": "refused", "detail": why}
        # Last line of defence (QA round 2): the shrunk baseline must keep
        # CI's whole-tree gate green on this very tree, or it is not committed.
        if gate_check(wt) != 0:
            _ok(git, "-C", wt, "checkout", "--", *touched)
            return {**status, "outcome": "refused",
                    "detail": "the shrunk baseline would turn CI's complexity gate red (complexity_gate.py --all)"}
        counts_note = f"; CCN 15 count {cp['before']} -> {cp['after']}" if count_changed else ""
        msg = (f"chore(complexity): nightly baseline shrink {p['before']} -> {p['after']} "
               f"({len(p['fixed'])} fixed{counts_note})\n\nRemovals only, verified before commit by "
               "scripts/complexity_baseline_nightly.py (2 AM nightly on the M4).")
        if not (_ok(git, "-C", wt, "add", "--", *touched)
                and _ok(git, "-C", wt, "-c", "user.name=VideoScan nightly",
                        "-c", "user.email=nightly@videoscan.invalid", "commit", "-q", "-m", msg)):
            _ok(git, "-C", wt, "reset", "--quiet", "--hard", "HEAD")
            return {**status, "outcome": "failed", "detail": "commit failed (hook or git error)"}
        if _ok(git, "-C", wt, "push", "origin", "HEAD:refs/heads/main"):
            sha = git("-C", wt, "rev-parse", "--short", "HEAD", check=False).stdout.strip()
            return {**status, "outcome": "committed", "commit": sha,
                    "detail": f"baseline {p['before']} -> {p['after']}{counts_note}"}
        # Rejected (main moved). Drop our commit (our own worktree, clean
        # before we started) and redo once on the new origin/main.
        _ok(git, "-C", wt, "reset", "--quiet", "--hard", "origin/main")
    return {**status, "outcome": "failed", "detail": "push rejected twice"}


def alert_lines(status: dict) -> List[str]:
    out = status.get("outcome")
    if out == "refused":
        return [f"🔴 Complexity baseline NOT committed by the nightly ({str(status.get('ts'))[:10]}): "
                f"{status.get('detail')}"]
    if out == "failed":
        return [f"🔴 Complexity baseline nightly commit FAILED ({str(status.get('ts'))[:10]}): "
                f"{status.get('detail')}"]
    if out == "committed":
        return [f"✅ Complexity baseline shrunk and committed ({status.get('commit')}): {status.get('detail')}"]
    return []


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--repo", default=os.path.expanduser("~/dev/VideoScan"))
    parser.add_argument("--worktree", default=DEFAULT_WT)
    parser.add_argument("--status-out", default=DEFAULT_STATUS)
    parser.add_argument("--alert", metavar="STATUS_JSON", help="print digest lines for a status file")
    args = parser.parse_args(argv)
    if args.alert:
        try:
            with open(args.alert, encoding="utf-8") as handle:
                for line in alert_lines(json.load(handle)):
                    print(line)
        except (OSError, ValueError):
            pass
        return 0
    try:
        status = run(args.repo, args.worktree)
    except Exception as exc:  # the nightly must get an OUTCOME, whatever happened
        status = {"ts": _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
                  "outcome": "failed", "detail": f"{type(exc).__name__}: {exc}"}
    os.makedirs(os.path.dirname(args.status_out) or ".", exist_ok=True)
    with open(args.status_out, "w", encoding="utf-8") as handle:
        json.dump(status, handle, indent=1)
        handle.write("\n")
    print(f"OUTCOME complexity-baseline {status['outcome']}: {status.get('detail', '')}")
    return 0 if status["outcome"] in ("committed", "unchanged") else 1


if __name__ == "__main__":
    raise SystemExit(main())
