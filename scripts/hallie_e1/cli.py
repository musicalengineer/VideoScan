#!/usr/bin/env python3
"""Hallie E1 harness — does a cloud agent loop beat today's Hallie? (spec: docs/design/hallie_e1_experiment.md)

    cli.py run       --models claude-haiku-5-5 [--corpus …] [--limit N] [--seeds N] [--budget-usd 10] [--dry-run]
    cli.py judge     --run <run folder> [--judge-model claude-fable-5-1] [--budget-usd 3] [--dry-run]
    cli.py report    --runs <run folder> [<run folder> …] [--baseline <hallie_eval run .jsonl>]
    cli.py estimate  [--corpus …] [--models …] [--seeds N]
    cli.py schema    [--out docs/hallie_tools.schema.json]

See scripts/hallie_e1/README.md for the exact commands. A real run bills the
Anthropic API key (env ANTHROPIC_API_KEY, else Keychain hallie-e1/anthropic);
--dry-run needs no key and no network.
"""
from __future__ import annotations

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from hallie_e1 import costs, scoring  # noqa: E402
from hallie_e1.judge import judge_run  # noqa: E402
from hallie_e1.loop import Budget  # noqa: E402
from hallie_e1.runner import ANTHROPIC_MODELS, RunConfig, RunRefused, run  # noqa: E402
from hallie_e1.toolbox import REPO, schema_document  # noqa: E402

DEFAULT_CORPUS = os.path.join(REPO, "tests", "hallie_acceptance_v1.json")
STRICT_CORPUS = os.path.join(REPO, "tests", "hallie_strict_regressions.json")
SCHEMA_PATH = os.path.join(REPO, "docs", "hallie_tools.schema.json")


def split_models(s: str) -> list[str]:
    if s == "all":
        return list(ANTHROPIC_MODELS)
    return [m.strip() for m in s.split(",") if m.strip()]


def cmd_run(a) -> int:
    corpus = STRICT_CORPUS if a.corpus == "strict" else DEFAULT_CORPUS if a.corpus == "acceptance" else a.corpus
    cfg = RunConfig(corpus=corpus, models=split_models(a.models), effort=a.effort, seeds=a.seeds,
                    budget_usd=a.budget_usd, dry_run=a.dry_run, cassettes=a.cassettes, record=a.record,
                    snapshots=a.snapshots, include_derived_text=a.include_derived_text, out=a.out,
                    budget=Budget(a.max_model_calls, a.max_tool_calls, a.deadline_s), max_tokens=a.max_tokens,
                    ollama_host=a.ollama_host, limit=a.limit, ids=a.ids.split(",") if a.ids else None,
                    allow_over_projection=a.allow_over_projection, strict_tools=a.strict_tools)
    try:
        res = run(cfg)
    except RunRefused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2
    return 0 if not res["meta"].get("stoppedReason") else 3


def cmd_judge(a) -> int:
    try:
        s = judge_run(a.run, model=a.judge_model, budget_usd=a.budget_usd, dry_run=a.dry_run, effort=a.effort,
                      only=a.only.split(",") if a.only else None)
    except RunRefused as e:
        print(f"REFUSED: {e}", file=sys.stderr)
        return 2
    return 0 if not s.get("stopped") else 3


def cmd_estimate(a) -> int:
    corpus = STRICT_CORPUS if a.corpus == "strict" else DEFAULT_CORPUS if a.corpus == "acceptance" else a.corpus
    rows, _ = scoring.load_corpus(corpus)
    prices = costs.load_prices()
    n = len(rows) * a.seeds
    print(f"{os.path.relpath(corpus, REPO)}: {len(rows)} turns × {a.seeds} seed(s), effort {a.effort}; prices "
          f"{prices['asOf']} ({'verified' if prices['verified'] else 'ESTIMATE'})")
    total = 0.0
    for m in split_models(a.models):
        if m.startswith("ollama:"):
            print(f"  {m:22} $0 (local)")
            continue
        per = costs.per_turn_estimate(costs.price_row(prices, m), a.effort)
        total += per * n
        print(f"  {m:22} ${per:.4f}/turn → ${per * n:.2f}")
    print(f"  total ≈ ${total:.2f} (spec §8 token model, ±35%; the run's hard cap is --budget-usd)")
    return 0


def cmd_schema(a) -> int:
    body = json.dumps(schema_document(), indent=1, ensure_ascii=False) + "\n"
    if a.check:
        with open(a.out, encoding="utf-8") as fh:
            same = fh.read() == body
        print("schema up to date" if same else f"schema STALE: regenerate with cli.py schema --out {a.out}")
        return 0 if same else 1
    with open(a.out, "w", encoding="utf-8") as fh:
        fh.write(body)
    print(f"wrote {a.out}")
    return 0


def cmd_report(a) -> int:
    for rd in a.runs:
        mpath = os.path.join(rd, "matrix.md")
        print(open(mpath, encoding="utf-8").read() if os.path.exists(mpath) else f"(no matrix.md in {rd})")
        for label in sorted(os.listdir(rd)):
            sp = os.path.join(rd, label, "summary.json")
            if os.path.exists(sp):
                card = json.load(open(sp, encoding="utf-8"))
                if "categories" in card:
                    print(scoring.scorecard_md(f"{os.path.basename(rd)} / {label}", card))
    if a.baseline:
        recs = []
        with open(a.baseline, encoding="utf-8") as fh:
            fh.readline()
            for line in fh:
                r = json.loads(line)
                r["flags"] = scoring.hallie_eval().grade_record(r)
                recs.append(r)
        card = scoring.summarize(recs)
        print(scoring.scorecard_md(f"baseline (today's lane): {a.baseline}", card))
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="run a corpus through the agent loop")
    r.add_argument("--models", default="claude-haiku-5-5",
                   help="comma list: claude-haiku-5-5, claude-sonnet-5-5, claude-opus-5-5, claude-fable-5-1, "
                        "ollama:<tag>, or 'all' (the four Anthropic models)")
    r.add_argument("--corpus", default="acceptance", help="acceptance | strict | <path>")
    r.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
    r.add_argument("--seeds", type=int, default=1, help="repeat each model N times (variance)")
    r.add_argument("--budget-usd", type=float, default=10.0, help="HARD spend cap for this whole invocation")
    r.add_argument("--allow-over-projection", action="store_true",
                   help="start even when the projected cost exceeds the cap (the cap still stops it)")
    r.add_argument("--limit", type=int, help="first N turns (a conversation is never cut in half)")
    r.add_argument("--ids", help="comma list of row or scenario ids")
    r.add_argument("--dry-run", action="store_true", help="scripted fake model (+ cassettes): no key, no network")
    r.add_argument("--cassettes", help="dry run: replay recorded responses from this folder first")
    r.add_argument("--record", help="save every request/response as a cassette under this folder")
    r.add_argument("--snapshots", help="snapshot folder (default: fixture for --dry-run, else newest export)")
    r.add_argument("--include-derived-text", action="store_true",
                   help="send transcript/caption TEXT to the model (default: redacted)")
    r.add_argument("--out", help="output folder (default ~/Library/Logs/VideoScan/hallie-eval/e1-<stamp>)")
    r.add_argument("--max-model-calls", type=int, default=6)
    r.add_argument("--max-tool-calls", type=int, default=8)
    r.add_argument("--deadline-s", type=float, default=20.0)
    r.add_argument("--max-tokens", type=int, default=6000)
    r.add_argument("--strict-tools", default="all", choices=["all", "submit", "none"],
                   help="strict: true on every tool (spec) | only submit_answer | none")
    r.add_argument("--ollama-host", default=os.environ.get("OLLAMA_HOST_E1", "http://localhost:11434"))
    r.set_defaults(fn=cmd_run)

    j = sub.add_parser("judge", help="LLM-judge pass over a finished run")
    j.add_argument("--run", required=True)
    j.add_argument("--judge-model", default="claude-fable-5-1")
    j.add_argument("--effort", default="medium", choices=["low", "medium", "high", "xhigh", "max"])
    j.add_argument("--budget-usd", type=float, default=3.0)
    j.add_argument("--dry-run", action="store_true")
    j.add_argument("--only", help="comma list of label substrings to judge, e.g. 's0' (seed 0 only) or 'sonnet'")
    j.set_defaults(fn=cmd_judge)

    rp = sub.add_parser("report", help="print scorecards of one or more runs (+ today's lane baseline)")
    rp.add_argument("--runs", nargs="+", required=True)
    rp.add_argument("--baseline", help="a hallie_eval.py run .jsonl of today's lane on the same corpus")
    rp.set_defaults(fn=cmd_report)

    e = sub.add_parser("estimate", help="projected $ before spending anything")
    e.add_argument("--corpus", default="acceptance")
    e.add_argument("--models", default="all")
    e.add_argument("--seeds", type=int, default=1)
    e.add_argument("--effort", default="medium")
    e.set_defaults(fn=cmd_estimate)

    s = sub.add_parser("schema", help="write (or --check) docs/hallie_tools.schema.json")
    s.add_argument("--out", default=SCHEMA_PATH)
    s.add_argument("--check", action="store_true")
    s.set_defaults(fn=cmd_schema)

    a = p.parse_args(argv)
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
