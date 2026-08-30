#!/usr/bin/env python3
"""Adversarial code-review bakeoff for candidate reviewer models.

WHY THIS EXISTS
---------------
Rick is deciding whether a local model can replace a paid cloud reviewer
(2026-08-30). The public leaderboards rank *Swift code generation*; the job
here is *adversarial review* — finding the defect the author already looked
at and believed was fine. Those are different skills, and the second is the
one that earned its keep.

Every case in tests/fixtures/reviewer_bench/cases.json is a real defect
found in THIS repository on 2026-08-29/30, by an independent reviewer,
after the author had tested the code and thought it correct. That makes it
a fair test: real idiom, real subtlety, known-correct answers.

SCORING, AND ITS LIMITS
-----------------------
Free-text review cannot be scored exactly. This reports two numbers and
saves every raw answer for a human to read:

  HIT      the answer names enough of the required concepts to show the
           model actually found the root cause, not a nearby smell
  NOISE    how many *other* problems it asserted. A reviewer that flags
           everything finds every bug and is still useless, because you
           stop reading it. Precision matters as much as recall.

Keyword matching is a proxy. Treat the score as triage and READ THE
ANSWERS — the saved transcript is the real deliverable.

Usage:
  scripts/reviewer_bench.py --model qwen3.6:35b-a3b-nvfp4
  scripts/reviewer_bench.py --model X --out results/x.json
"""
from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import time

ROOT = pathlib.Path(__file__).resolve().parents[1]
CASES = ROOT / "tests/fixtures/reviewer_bench/cases.json"

PROMPT = """You are reviewing a code change for defects.

Below is a snippet from a real codebase. It compiles, it runs, and its
tests pass. There is at least one genuine defect in it.

Identify the most serious defect. Say specifically WHY it is wrong and
what the consequence is. Be concise — a short paragraph. If you believe
there is no defect, say so plainly.

Language: {language}

```{language}
{code}
```
"""


def ask_ollama(model: str, prompt: str, timeout: int = 600) -> tuple[str, float]:
    started = time.time()
    proc = subprocess.run(
        ["ollama", "run", model, prompt],
        capture_output=True, text=True, timeout=timeout,
    )
    if proc.returncode != 0:
        return f"<ERROR rc={proc.returncode}: {proc.stderr.strip()[:400]}>", time.time() - started
    return proc.stdout.strip(), time.time() - started


def score(answer: str, concepts: list[str]) -> tuple[bool, list[str]]:
    """A hit needs >= 2 distinct required concepts.

    One keyword is too easy to hit by accident — "symlink" appears in any
    hand-waving about file paths. Two independent concepts is weak evidence
    of real understanding, which is all keyword matching can ever give.
    """
    lowered = answer.lower()
    matched = [c for c in concepts if c.lower() in lowered]
    return len(matched) >= 2, matched


def count_claims(answer: str) -> int:
    """Rough count of distinct problems asserted, for a noise signal."""
    markers = re.findall(
        r"(?m)^\s*(?:[-*•]|\d+[.)])\s+|(?i)\b(?:another|second|also|additionally"
        r"|furthermore|a further)\b", answer)
    return max(1, len(markers))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--out")
    ap.add_argument("--timeout", type=int, default=600)
    args = ap.parse_args()

    spec = json.loads(CASES.read_text())
    results, hits, total_seconds = [], 0, 0.0

    print(f"model: {args.model}\ncases: {len(spec['cases'])}\n" + "-" * 62)
    for case in spec["cases"]:
        answer, seconds = ask_ollama(
            args.model,
            PROMPT.format(language=case["language"], code=case["code"]),
            timeout=args.timeout)
        total_seconds += seconds
        hit, matched = score(answer, case["required_concepts"])
        hits += hit
        claims = count_claims(answer)
        print(f"{'HIT ' if hit else 'MISS'}  {case['id']:<18} "
              f"{seconds:6.1f}s  concepts={len(matched)}/{len(case['required_concepts'])}  "
              f"claims~{claims}")
        results.append({
            "id": case["id"], "hit": hit, "matched": matched,
            "seconds": round(seconds, 1), "claims": claims,
            "answer": answer, "expected": case["expected_finding"],
        })

    print("-" * 62)
    print(f"score: {hits}/{len(spec['cases'])}   total {total_seconds:.1f}s "
          f"({total_seconds / max(1, len(spec['cases'])):.1f}s per case)")
    print("Keyword scoring is a proxy. Read the answers before trusting it.")

    out = pathlib.Path(args.out) if args.out else \
        ROOT / f"reviewer_bench_{args.model.replace(':', '_').replace('/', '_')}.json"
    out.write_text(json.dumps(
        {"model": args.model, "hits": hits, "cases": len(spec["cases"]),
         "totalSeconds": round(total_seconds, 1), "results": results}, indent=2))
    print(f"transcript: {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
