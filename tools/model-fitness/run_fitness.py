#!/usr/bin/env python3
"""Model fitness for VideoScan's actual needs.

tools/qwen-bench measures ONE thing well: whether a model produces the right
initial read-only tool plan.  Rick, 2026-08-31: "test how well this
qwen3.8:27b-mlx or another performs for OUR needs ... a mix of code review,
general, maybe a bit of western european and american history, etc., along
with nat lang AST capabilities."

This harness covers the dimensions qwen-bench does not:

  code_review        can it find a real defect, and — the half that decides
                     whether it is usable — does it stay quiet on correct code
  history_us         dates that anchor family media (Ellis Island, Pearl Harbor)
  history_eu         the Irish famine and emigration window, early photography
  abstention         refuses to invent a birthplace it does not have
  general_knowledge  plain definitions plus the project's own domain (MXF,
                     GEDCOM, ffmpeg stream copy)
  ast_planning       the exact natural-language -> JSON distinctions that broke
                     in production today ("brothers" != "siblings",
                     "where born" != "when born")

GRADING IS DETERMINISTIC, NOT AN LLM JUDGE.  Every case carries
`must_include` (a list of OR-groups; all groups must hit) and
`must_not_include` (any hit fails).  Substring, case-insensitive.  That is
crude, and it is auditable at 3am without a second model in the loop, which a
judge is not.  Every raw response is written to the run file so a
disagreement can be re-scored by hand later.

Code review is scored twice, because a single pass rate hides the thing that
matters.  A reviewer that flags everything scores well on recall and is
useless.  So:

  recall     = defect cases correctly identified
  precision  = correct-code cases NOT falsely flagged

Usage:
    python3 tools/model-fitness/run_fitness.py validate
    python3 tools/model-fitness/run_fitness.py run \\
        --model qwen3.8:27b-mlx --host http://localhost:11434
    python3 tools/model-fitness/run_fitness.py compare RUN_A.jsonl RUN_B.jsonl
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
import urllib.error
import urllib.request
from collections import defaultdict
from pathlib import Path

HERE = Path(__file__).resolve().parent
DEFAULT_CORPUS = HERE / "fitness_corpus.jsonl"

# One instruction for every case so two models are asked the same way.
SYSTEM = (
    "You are assisting with a private family media archive project. "
    "Answer directly and concisely. If you do not know something, say so "
    "plainly rather than guessing. Never invent names, dates, places or "
    "citations."
)


# ── corpus ────────────────────────────────────────────────────────────────

def load_corpus(path: Path) -> list[dict]:
    cases = []
    for lineno, raw in enumerate(path.read_text().splitlines(), 1):
        raw = raw.strip()
        if not raw:
            continue
        try:
            case = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise SystemExit(f"{path}:{lineno}: {exc}") from exc
        for field in ("id", "category", "prompt", "must_include"):
            if field not in case:
                raise SystemExit(f"{path}:{lineno}: missing {field!r}")
        case.setdefault("must_not_include", [])
        cases.append(case)
    ids = [c["id"] for c in cases]
    dupes = {i for i in ids if ids.count(i) > 1}
    if dupes:
        raise SystemExit(f"duplicate case ids: {sorted(dupes)}")
    return cases


# ── grading ───────────────────────────────────────────────────────────────

def grade(case: dict, answer: str) -> tuple[bool, list[str]]:
    """(passed, reasons). Reasons name what was missing or forbidden."""
    haystack = answer.lower()
    reasons: list[str] = []

    for group in case["must_include"]:
        if not any(term.lower() in haystack for term in group):
            reasons.append(f"missing any of {group}")

    for term in case["must_not_include"]:
        for hit in _hits(haystack, term.lower()):
            if _negated_before(haystack, hit):
                continue    # "the bug is NOT limited to brothers" is a PASS
            reasons.append(f"forbidden: {term!r}")
            break

    return (not reasons), reasons


def _hits(haystack: str, needle: str):
    start = haystack.find(needle)
    while start != -1:
        yield start
        start = haystack.find(needle, start + 1)


# Negation markers, and how far back to look. Deliberately small: a marker
# three words earlier flips the clause, one three sentences earlier does not.
_NEGATIONS = ("not", "n't", "never", "no longer", "isn't", "aren't",
              "far from", "rather than", "instead of", "nor ")
_LOOKBACK = 40


def _negated_before(haystack: str, index: int) -> bool:
    """True when a negation marker sits just before `index`.

    Substring grading is crude and this is where it bites: on 2026-08-31 the
    candidate model answered "The bug is **not** limited to brothers and
    sisters" — correct, and scored as a failure because the forbidden phrase
    "limited to brother" was sitting inside the negation. Grading the
    negation as the claim understates every model that phrases a correct
    answer as a contradiction of the question.
    """
    window = haystack[max(0, index - _LOOKBACK):index]
    return any(marker in window for marker in _NEGATIONS)


# ── model ─────────────────────────────────────────────────────────────────

def ask(host: str, model: str, prompt: str, seed: int,
        timeout: float) -> tuple[str, float, str | None]:
    """Returns (answer, seconds, error)."""
    body = json.dumps({
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": prompt},
        ],
        "stream": False,
        "options": {"temperature": 0, "seed": seed},
    }).encode()

    request = urllib.request.Request(
        f"{host.rstrip('/')}/api/chat",
        data=body,
        headers={"Content-Type": "application/json"},
    )
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = json.loads(response.read())
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        return "", time.monotonic() - started, str(exc)
    except json.JSONDecodeError as exc:
        return "", time.monotonic() - started, f"bad JSON: {exc}"

    elapsed = time.monotonic() - started
    answer = (payload.get("message") or {}).get("content", "")
    # Reasoning models emit <think>…</think>; grade the ANSWER, not the
    # scratchpad, or a model that muses about "no defect" fails a case it
    # actually got right.
    answer = re.sub(r"<think>.*?</think>", "", answer, flags=re.S)
    return answer.strip(), elapsed, None


# ── run ───────────────────────────────────────────────────────────────────

def run(args: argparse.Namespace) -> int:
    cases = load_corpus(Path(args.corpus))
    if args.only:
        cases = [c for c in cases if c["category"] in args.only]
    out = Path(args.out or f"/private/tmp/fitness-{args.model.replace(':', '_')}"
                           f"-{int(time.time())}.jsonl")

    print(f"model   {args.model}")
    print(f"host    {args.host}")
    print(f"cases   {len(cases)}   seed {args.seed}")
    print(f"raw     {out}\n", flush=True)

    records = []
    with out.open("w") as sink:
        for index, case in enumerate(cases, 1):
            answer, elapsed, error = ask(
                args.host, args.model, case["prompt"], args.seed, args.timeout)
            if error:
                passed, reasons = False, [f"transport: {error}"]
            else:
                passed, reasons = grade(case, answer)

            record = {
                "id": case["id"], "category": case["category"],
                "defect": case.get("defect"), "passed": passed,
                "reasons": reasons, "seconds": round(elapsed, 2),
                "model": args.model, "seed": args.seed,
                "answer": answer, "error": error,
            }
            records.append(record)
            sink.write(json.dumps(record) + "\n")
            sink.flush()

            mark = "PASS" if passed else "FAIL"
            print(f"[{index:>2}/{len(cases)}] {mark}  {case['id']:<28} "
                  f"{elapsed:>6.1f}s"
                  + ("" if passed else f"   {reasons[0]}"), flush=True)

    report(records, args.model)
    return 0


# ── report ────────────────────────────────────────────────────────────────

def report(records: list[dict], label: str) -> dict:
    by_category: dict[str, list[dict]] = defaultdict(list)
    for record in records:
        by_category[record["category"]].append(record)

    print(f"\n{'=' * 62}\n{label}\n{'=' * 62}")
    print(f"{'category':<20} {'pass':>10}   rate")
    print("-" * 62)

    summary = {}
    for category in sorted(by_category):
        rows = by_category[category]
        won = sum(r["passed"] for r in rows)
        rate = won / len(rows)
        summary[category] = rate
        print(f"{category:<20} {won:>4}/{len(rows):<5} {rate:>6.0%}")

    review = by_category.get("code_review", [])
    if review:
        defects = [r for r in review if r["defect"] is True]
        clean = [r for r in review if r["defect"] is False]
        recall = sum(r["passed"] for r in defects) / len(defects) if defects else 0
        precision = sum(r["passed"] for r in clean) / len(clean) if clean else 0
        print("-" * 62)
        print(f"{'  code review recall':<20} {sum(r['passed'] for r in defects):>4}"
              f"/{len(defects):<5} {recall:>6.0%}   (defects found)")
        print(f"{'  code review prec.':<20} {sum(r['passed'] for r in clean):>4}"
              f"/{len(clean):<5} {precision:>6.0%}   (correct code left alone)")
        summary["_review_recall"] = recall
        summary["_review_precision"] = precision

    total = sum(r["passed"] for r in records)
    seconds = sum(r["seconds"] for r in records)
    print("-" * 62)
    print(f"{'OVERALL':<20} {total:>4}/{len(records):<5} "
          f"{total / len(records):>6.0%}")
    print(f"{'wall clock':<20} {seconds / 60:>10.1f} min "
          f"({seconds / len(records):.1f}s/case)")
    summary["_overall"] = total / len(records)
    return summary


def compare(args: argparse.Namespace) -> int:
    runs = []
    for path in args.runs:
        records = [json.loads(line) for line in Path(path).read_text().splitlines()
                   if line.strip()]
        label = records[0]["model"] if records else Path(path).name
        runs.append((label, records, report(records, label)))

    print(f"\n{'=' * 62}\nHEAD TO HEAD\n{'=' * 62}")
    keys = sorted({k for _, _, s in runs for k in s})
    width = max(len(label) for label, _, _ in runs) + 2
    print(f"{'metric':<22}" + "".join(f"{label:>{width}}" for label, _, _ in runs))
    print("-" * 62)
    for key in keys:
        row = "".join(f"{summary.get(key, float('nan')):>{width}.0%}"
                      for _, _, summary in runs)
        print(f"{key:<22}{row}")

    # Which cases changed verdict — the only part worth reading twice.
    if len(runs) == 2:
        (label_a, records_a, _), (label_b, records_b, _) = runs
        by_id_b = {r["id"]: r for r in records_b}
        flips = [(r["id"], r["passed"], by_id_b[r["id"]]["passed"])
                 for r in records_a
                 if r["id"] in by_id_b and r["passed"] != by_id_b[r["id"]]["passed"]]
        if flips:
            print(f"\nchanged verdict ({label_a} -> {label_b}):")
            for case_id, was, now in sorted(flips, key=lambda f: (f[1], f[0])):
                arrow = "FIXED " if now else "BROKE "
                print(f"  {arrow} {case_id}")
    return 0


def rescore(args: argparse.Namespace) -> int:
    """Re-grade saved answers against the current corpus, contacting no model.

    The whole reason every raw response is kept. Substring grading is
    auditable but brittle — on 2026-08-31 it failed four correct answers
    before it failed a wrong one — so the grader gets corrected more often
    than the models do, and a corrected grader must be able to re-judge
    history without paying for inference again.
    """
    cases = {c["id"]: c for c in load_corpus(Path(args.corpus))}
    records = [json.loads(line) for line in Path(args.run).read_text().splitlines()
               if line.strip()]
    changed = 0
    for record in records:
        case = cases.get(record["id"])
        if case is None or record.get("error"):
            continue
        passed, reasons = grade(case, record["answer"])
        if passed != record["passed"]:
            changed += 1
            print(f"  {'now PASS' if passed else 'now FAIL'}  {record['id']}")
        record["passed"], record["reasons"] = passed, reasons

    out = Path(args.out or args.run)
    with out.open("w") as sink:
        for record in records:
            sink.write(json.dumps(record) + "\n")
    print(f"{changed} verdict(s) changed -> {out}\n")
    report(records, records[0]["model"] if records else args.run)
    return 0


def validate(args: argparse.Namespace) -> int:
    cases = load_corpus(Path(args.corpus))
    counts: dict[str, int] = defaultdict(int)
    for case in cases:
        counts[case["category"]] += 1
    print(f"{len(cases)} cases, valid JSON, unique ids")
    for category in sorted(counts):
        print(f"  {category:<20} {counts[category]}")
    review = [c for c in cases if c["category"] == "code_review"]
    print(f"\ncode_review: {sum(1 for c in review if c.get('defect'))} with a defect, "
          f"{sum(1 for c in review if c.get('defect') is False)} correct-code "
          f"(precision) cases")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)

    v = sub.add_parser("validate", help="check the corpus, contact no model")
    v.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    v.set_defaults(func=validate)

    r = sub.add_parser("run", help="run the corpus against one model")
    r.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    r.add_argument("--model", required=True, help="exact Ollama model tag")
    r.add_argument("--host", default="http://localhost:11434")
    r.add_argument("--seed", type=int, default=101)
    r.add_argument("--timeout", type=float, default=300.0)
    r.add_argument("--only", nargs="*", help="limit to these categories")
    r.add_argument("--out", help="raw JSONL path")
    r.set_defaults(func=run)

    s_ = sub.add_parser("rescore", help="re-grade a saved run; contacts no model")
    s_.add_argument("--run", required=True)
    s_.add_argument("--corpus", default=str(DEFAULT_CORPUS))
    s_.add_argument("--out", help="default: rewrite the run in place")
    s_.set_defaults(func=rescore)

    c = sub.add_parser("compare", help="report and diff two or more runs")
    c.add_argument("runs", nargs="+")
    c.set_defaults(func=compare)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
