#!/usr/bin/env python3
"""Hallie conversational-quality evaluation harness (Rick, 2026-08-21).

Feeds a corpus of questions through the headless read-only Hallie shell in ONE
session (the 7k-record catalog loads once), then joins the questions to the
structured turns Hallie writes to her JSONL conversation log — route, outcome,
composedBy, basis, evidence — and grades them.

The point is a repeatable before/after number for "does she feel like a person
who knows this family", not a pass/fail gate. Grades are heuristic and
deliberately conservative: they flag what a human should read, they do not
pretend to judge warmth on their own.

Usage:
  scripts/hallie_eval.py run   --corpus tests/hallie_eval_corpus.json --out runs/base.jsonl
  scripts/hallie_eval.py grade --run runs/base.jsonl [--compare runs/prev.jsonl]
"""

import argparse
import json
import os
import re
import subprocess
import sys
import time
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
LOG_DIR = Path.home() / "Library/Logs/VideoScan/Hallie"
HALLIE = REPO / "scripts/hallie"

# ---------------------------------------------------------------- run


def load_corpus(path):
    with open(path) as f:
        data = json.load(f)
    qs = data["questions"] if isinstance(data, dict) else data
    return qs


def build_stdin(questions, reset_between=True):
    """One line per turn. `:reset` before every non-follow-up so an unrelated
    question never inherits the previous referent, while marked follow-up
    chains keep their context (that continuity is itself under test)."""
    lines = []
    for q in questions:
        if reset_between and not q.get("followsPrevious"):
            lines.append(":reset")
        lines.append(q["text"].replace("\n", " "))
    lines.append(":quit")
    return "\n".join(lines) + "\n"


def todays_log():
    return LOG_DIR / f"hallie-conversation-{date.today().isoformat()}.jsonl"


def read_log_turns(path, since_seq_marker):
    """Return the assistant turns written after our marker line count."""
    turns = []
    if not path.exists():
        return turns
    with open(path) as f:
        for i, line in enumerate(f):
            if i < since_seq_marker:
                continue
            try:
                turns.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    return turns


def run(args):
    questions = load_corpus(args.corpus)
    if args.limit:
        questions = questions[: args.limit]
    log = todays_log()
    before = sum(1 for _ in open(log)) if log.exists() else 0

    cmd = [str(HALLIE)]
    if not args.no_compose:
        cmd.append("--compose")
    if args.host:
        cmd += ["--host", args.host]

    print(f"[eval] {len(questions)} questions → {' '.join(cmd)}", flush=True)
    t0 = time.time()
    proc = subprocess.run(
        cmd,
        input=build_stdin(questions),
        capture_output=True,
        text=True,
        timeout=args.timeout,
        cwd=str(REPO),
    )
    elapsed = time.time() - t0
    print(f"[eval] session finished in {elapsed:.0f}s (exit {proc.returncode})", flush=True)

    turns = read_log_turns(log, before)
    # Pair: assistant turns carry `outcome`; user turns don't. Walk in order.
    pairs, pending = [], None
    for t in turns:
        if t.get("kind") == "user" or ("outcome" not in t and "route" not in t):
            pending = t.get("text", "")
            continue
        pairs.append((pending, t))
        pending = None

    # Align to corpus by order, skipping the :reset/:quit meta turns.
    records = []
    qi = 0
    for asked, ans in pairs:
        if asked is not None and asked.strip().startswith(":"):
            continue
        if qi >= len(questions):
            break
        q = questions[qi]
        qi += 1
        records.append(
            {
                "id": q.get("id"),
                "category": q.get("category"),
                "expect": q.get("expect"),
                "followsPrevious": bool(q.get("followsPrevious")),
                "question": asked if asked is not None else q["text"],
                "answer": ans.get("text", ""),
                "route": ans.get("route"),
                "outcome": ans.get("outcome"),
                "composedBy": ans.get("composedBy"),
                "basis": ans.get("basisLine"),
                "mediaEvidence": len(ans.get("mediaEvidence") or []),
                "knowledgeEvidence": len(ans.get("knowledgeEvidence") or []),
                "responder": ans.get("responder"),
            }
        )

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    with open(out, "w") as f:
        f.write(json.dumps({"meta": {"questions": len(questions), "paired": len(records),
                                     "elapsed_s": round(elapsed), "compose": not args.no_compose,
                                     "when": time.strftime("%Y-%m-%dT%H:%M:%S")}}) + "\n")
        for r in records:
            f.write(json.dumps(r) + "\n")
    print(f"[eval] wrote {len(records)} paired turns → {out}")
    if len(records) < len(questions):
        print(f"[eval] WARNING: {len(questions) - len(records)} questions produced no logged turn")
    if proc.returncode != 0:
        print(proc.stderr[-2000:], file=sys.stderr)
    return 0


# ---------------------------------------------------------------- grade

DECLINE_PAT = re.compile(
    r"don'?t have evidence|no evidence|couldn'?t find|i'?m not sure|cannot answer|"
    r"don'?t know|unable to",
    re.I,
)
# A sentence that starts mid-thought — the fragment bug class.
FRAGMENT_PAT = re.compile(r"^\s*(?:'s|s |and |but |or |of |in |at |the |a )", re.I)
HEDGE_PAT = re.compile(r"as an ai|i am an ai|language model", re.I)


def grade_record(r):
    """Return (flags, ok). Conservative: flags mean 'a human should look'."""
    flags = []
    a = (r.get("answer") or "").strip()
    expect = r.get("expect")
    outcome = r.get("outcome")

    if not a:
        flags.append("empty")
        return flags
    if r.get("route") in (None, "") and outcome is None:
        flags.append("no_route")

    declined = outcome == "declined" or bool(DECLINE_PAT.search(a))

    # Expectation mismatches
    if expect in ("catalog", "kinship", "biography") and declined:
        flags.append("declined_expected_answer")
    if expect == "social" and declined:
        flags.append("social_declined")          # the "no evidence" for "how are you" bug
    if expect == "social" and r.get("mediaEvidence"):
        flags.append("social_hit_catalog")
    if expect == "graceful_decline" and not declined:
        flags.append("answered_unknowable")      # invention risk

    # Prose quality
    if FRAGMENT_PAT.match(a):
        flags.append("fragment")
    if a and a[0].islower():
        flags.append("lowercase_start")
    if HEDGE_PAT.search(a):
        flags.append("ai_disclaimer")
    if len(a.split()) <= 3 and expect != "social":
        flags.append("terse")
    # Warmth proxy: a decline that offers nothing is a dead end.
    if declined and not re.search(r"\?|would you|want|try|i do have|i can", a, re.I):
        flags.append("dead_end_decline")

    return flags


def grade(args):
    recs = []
    with open(args.run) as f:
        meta = json.loads(f.readline())
        for line in f:
            recs.append(json.loads(line))

    by_cat, flag_counts, flagged = {}, {}, []
    for r in recs:
        flags = grade_record(r)
        r["flags"] = flags
        c = by_cat.setdefault(r.get("category", "?"), {"n": 0, "clean": 0})
        c["n"] += 1
        if not flags:
            c["clean"] += 1
        else:
            flagged.append(r)
        for fl in flags:
            flag_counts[fl] = flag_counts.get(fl, 0) + 1

    total = len(recs)
    clean = sum(c["clean"] for c in by_cat.values())
    print(f"\n=== Hallie eval: {args.run}")
    print(f"turns: {total}   clean: {clean} ({100*clean/max(total,1):.0f}%)   "
          f"elapsed: {meta.get('meta',{}).get('elapsed_s','?')}s\n")

    print(f"{'category':22} {'n':>4} {'clean':>6} {'%':>5}")
    for cat in sorted(by_cat):
        c = by_cat[cat]
        print(f"{cat:22} {c['n']:>4} {c['clean']:>6} {100*c['clean']/c['n']:>4.0f}%")

    print("\nflags:")
    for fl, n in sorted(flag_counts.items(), key=lambda kv: -kv[1]):
        print(f"  {n:>4}  {fl}")

    if args.show:
        print("\n--- flagged examples ---")
        for r in flagged[: args.show]:
            print(f"\n[{r.get('id')}] ({r.get('category')}, expect={r.get('expect')}, "
                  f"route={r.get('route')}, {','.join(r['flags'])})")
            print(f"  Q: {r.get('question')}")
            print(f"  A: {(r.get('answer') or '')[:300]}")

    if args.compare and Path(args.compare).exists():
        prev = []
        with open(args.compare) as f:
            f.readline()
            for line in f:
                prev.append(json.loads(line))
        pclean = sum(1 for r in prev if not grade_record(r))
        print(f"\ncompare {args.compare}: {pclean}/{len(prev)} "
              f"({100*pclean/max(len(prev),1):.0f}%) → this run "
              f"{clean}/{total} ({100*clean/max(total,1):.0f}%)  "
              f"delta {100*clean/max(total,1) - 100*pclean/max(len(prev),1):+.0f} pts")

    out = Path(args.run).with_suffix(".graded.jsonl")
    with open(out, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
    print(f"\ngraded → {out}")
    return 0


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    pr = sub.add_parser("run")
    pr.add_argument("--corpus", default=str(REPO / "tests/hallie_eval_corpus.json"))
    pr.add_argument("--out", required=True)
    pr.add_argument("--limit", type=int)
    pr.add_argument("--host")
    pr.add_argument("--no-compose", action="store_true")
    pr.add_argument("--timeout", type=int, default=5400)
    pr.set_defaults(func=run)

    pg = sub.add_parser("grade")
    pg.add_argument("--run", required=True)
    pg.add_argument("--compare")
    pg.add_argument("--show", type=int, default=0)
    pg.set_defaults(func=grade)

    args = p.parse_args()
    sys.exit(args.func(args))


if __name__ == "__main__":
    main()
