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


ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# Reasoning models emit their chain first and mark the end. Everything
# before this is exploration, including paths they then reject.
THINKING_END = "...done thinking."


def ask_ollama(model: str, prompt: str, timeout: int = 900,
               endpoint: str = "http://localhost:11434") -> tuple[str, str, float]:
    """Returns (final answer, thinking chain, seconds).

    Two things learned running this against qwen3.6 on 2026-08-30:

    1. `ollama run` streams with terminal redraw escapes that corrupt any
       naive keyword match — so this now uses the HTTP API, where the
       answer and the thinking chain arrive as separate fields.
    2. A reasoning model's chain is most of the output and explores WRONG
       hypotheses on the way. Score the final answer only; keep the chain
       for a human to read.

    2026-09-01: `ollama run` also cannot set a context window, so the
    model ran at its 262K maximum and a 32B reviewer on a 48 GB Mac came
    back empty. The API call carries num_ctx.
    """
    import json as _json
    import urllib.request
    body = _json.dumps({
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "stream": False,
        "options": {"temperature": 0, "seed": 101, "num_ctx": 32768},
    }).encode()
    request = urllib.request.Request(
        f"{endpoint.rstrip('/')}/api/chat", data=body,
        headers={"Content-Type": "application/json"})
    started = time.time()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = _json.loads(response.read())
    except Exception as exc:                      # noqa: BLE001 - report, never raise
        return f"<ERROR: {str(exc)[:400]}>", "", time.time() - started
    elapsed = time.time() - started
    message = payload.get("message") or {}
    answer = ANSI.sub("", message.get("content") or "")
    thinking = message.get("thinking") or ""
    if THINKING_END in answer:
        thinking, _, answer = answer.partition(THINKING_END)
    if not answer.strip():
        return "<ERROR: empty reply " + _json.dumps(payload)[:300] + ">", thinking.strip(), elapsed
    return answer.strip(), thinking.strip(), elapsed


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
    # Global inline flags must lead the pattern on Python 3.11+; a mid-pattern
    # (?i) raised re.error and took every bench run down (2026-09-01).
    markers = re.findall(
        r"(?im)^\s*(?:[-*•]|\d+[.)])\s+|\b(?:another|second|also|additionally"
        r"|furthermore|a further)\b", answer)
    return max(1, len(markers))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--out")
    ap.add_argument("--timeout", type=int, default=900)
    args = ap.parse_args()

    spec = json.loads(CASES.read_text())
    results, hits, total_seconds = [], 0, 0.0

    print(f"model: {args.model}\ncases: {len(spec['cases'])}\n" + "-" * 62)
    for case in spec["cases"]:
        answer, thinking, seconds = ask_ollama(
            args.model,
            PROMPT.format(language=case["language"], code=case["code"]),
            timeout=args.timeout)
        total_seconds += seconds
        hit, matched = score(answer, case["required_concepts"])
        hits += hit
        claims = count_claims(answer)
        print(f"{'HIT ' if hit else 'MISS'}  {case['id']:<18} "
              f"{seconds:6.1f}s  concepts={len(matched)}/{len(case['required_concepts'])}  "
              f"claims~{claims}  think={len(thinking)}c")
        results.append({
            "id": case["id"], "hit": hit, "matched": matched,
            "seconds": round(seconds, 1), "claims": claims,
            "answer": answer, "expected": case["expected_finding"],
            "thinkingChars": len(thinking), "thinking": thinking,
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
