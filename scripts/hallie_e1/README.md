# Hallie E1 — the real plumbing (latency, $ per question, model choice)

The take-two demo ([review](../../docs/reviews/hallie_demo_2026_10_10.md)) showed the brain works: a
Sonnet agent with tools scored 92–94% vs today's Hallie 29% on the frozen suite. E1 runs the same
tool kit through a **bounded API loop** — the shape the app would ship — and measures what the demo
could not: seconds per answer, dollars per question, and which model is worth it.
Spec: [hallie_e1_experiment.md](../../docs/design/hallie_e1_experiment.md).

Nothing here changes the app. The tools are `scripts/hallie_demo/tools.py` (imported, not copied).

## What one turn does

1. The question goes to the model with Hallie's librarian rules (`prompt.py`) and 8 tools
   (`docs/hallie_tools.schema.json`, generated from the tool kit; `strict: true`).
2. The model calls tools; results go back as data. Budget per turn: **≤ 6 model calls, ≤ 8 tool
   calls, 20 s**. Running out = an honest decline, counted by reason.
3. The turn ends when the model calls `submit_answer`. The **verifier** then drops any claim whose
   citation was not returned by a tool *in this turn*, deletes uncited sentences that state a name,
   date, number or place, and turns a wrong-subject answer into a decline.
4. Every model call's real usage (input, output, cache write, cache read) is priced from
   `prices.json`; a **hard cap** is checked before every call.

Caching: the tools + system prompt are the cached prefix (breakpoint on the system block, plus
automatic caching of the growing conversation). Thinking is adaptive (not sent); `--effort` is the
only knob. Forced tool choice is not used (the 5.5/5.1 models reject it).

## Before the first paid run (once)

**Price table.** `prices.json` is marked **ESTIMATE, unverified**: the figures come from the Claude
Code `claude-api` reference cached 2026-10-06 (the same as spec §8). Check them against
<https://platform.claude.com/docs/en/about-claude/pricing>, fix any that differ, and set
`"verified": true`. Every report prints which table it used.

**API key.** Store it in the Keychain (you'll be asked for the key; it is never echoed):

```
security add-generic-password -s hallie-e1 -a anthropic -w
```

The harness reads `ANTHROPIC_API_KEY` if set, else that Keychain item, else an `ant auth login`
profile. Only the *source* (`env`/`keychain`/`profile`) is written to `run.json`; every file and
console line passes through a scrubber, and a test plants a canary key to prove it.

**Snapshot.** Real runs read a text-only snapshot (no pixels, audio, frames or face embeddings). The
frozen suite's expected numbers were computed against catalog generation 3189; that snapshot is the
one the demo used. Export a fresh one with:

```
/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_demo/snapshot.py --out "/Users/rickb/Library/Application Support/VideoScan/hallie-e1/snapshots/2026-10-11"
```

The newest folder under `~/Library/Application Support/VideoScan/hallie-e1/snapshots/` is used by
default (`--snapshots DIR` to choose). A re-export of a changed catalog moves the stats rows.

## (a) Dry run — free, no key, no network

```
/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_e1/cli.py run --dry-run --models all
/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_e1/cli.py judge --dry-run --run <the folder it printed>
```

A scripted fake model answers over the synthetic fixture snapshot
(`tests/fixtures/hallie_e1/`). It proves the plumbing — loop, budgets, cap, verifier, files,
scoring, judge — and nothing about quality: dry-run tokens, $ and seconds are simulated and the
matrix says so. Tests: `/Users/rickb/dev/VideoScan/venv/bin/python -m pytest /Users/rickb/dev/VideoScan/tests/test_hallie_e1.py /Users/rickb/dev/VideoScan/tests/test_hallie_demo_tools.py -q`

## (b) Smoke run — Haiku, 3 questions, under $0.05

```
/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_e1/cli.py run --models claude-haiku-5-5 --limit 3 --budget-usd 0.05
```

Projected ≈ $0.005. The cap stops it at $0.05 no matter what. What to check: every turn has
`usage.cacheRead > 0` after the first call (caching works), no `fallbackReason` of
`api_error:400` (request shape accepted). If the API rejects the strict schemas as too large, re-run
with `--strict-tools submit` (only `submit_answer` strict) and tell Claude. A 400 costs nothing and
stops the run at once.

## (c) The full plan from the spec (~$25)

Projected with `cli.py estimate` (spec §8 token model, ±35%):

| step | command (abbreviated: `cli.py` = `/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_e1/cli.py`) | projected |
|---|---|---|
| 1. acceptance suite × 4 models × 3 seeds | `cli.py run --models all --seeds 3 --budget-usd 30` | $22.48 (Haiku 0.15, Sonnet 2.98, Opus 5.64, Fable 13.71) |
| 2. Sonnet on the strict set (67 rows) | `cli.py run --models claude-sonnet-5-5 --corpus strict --budget-usd 5` | $2.02 |
| 3. judge, seed 0 of every model, Fable as judge | `cli.py judge --run <step-1 folder> --only s0 --budget-usd 16` | ≈ $14 (132 turns) |

Steps 1+2 ≈ $24.50. The judge is a separate decision: Fable is ~$0.11 per judged turn; `--only
sonnet` judges one model (≈ $3.60 for 3 seeds), `--judge-model claude-opus-5-5` costs about half.
Each command has its own hard cap; a run that hits it stops, marks `STOPPED: spend_cap`, and keeps
everything written so far. Cheapest-first is the safe order: run Haiku alone first
(`--models claude-haiku-5-5 --seeds 3 --budget-usd 1`), then Sonnet, then the big two.

Other flags: `--effort low|medium|high|xhigh|max` (default medium), `--ids ac-st-03,ac-st-04`,
`--include-derived-text` (sends transcript/caption TEXT; default redacted — the report says which),
`--record <folder outside the repo>` (cassettes), `--models ollama:<tag> --ollama-host http://<m5-ultra>:11434`
(same loop on a local model, $0; Ollama Cloud: host `https://ollama.com`, key in env `OLLAMA_API_KEY`
or Keychain `-s hallie-e1 -a ollama`; reported as unpriced).

## Reading the results

Each run writes to `~/Library/Logs/VideoScan/hallie-eval/e1-<date-time>/`:

- **`matrix.md`** — start here. One row per model × seed: pattern-clean %, wrong-subject (must be 0),
  unverified facts (must be 0), decline-correctness, p50/p95 seconds (p95 must be ≤ 20), fallbacks,
  and $ for the run. The header says whether prices were verified and whether derived text was sent.
- **`<model>__<effort>__s<n>/scorecard.md`** — the review's per-category table (no_bluff, stats,
  multi_hop, conversation, loose_phrasing, story, each with its bar) and a per-row sheet. The
  **judge** column fills in after `cli.py judge`; ✅/❌ = met the category's bar.
- **`turns.jsonl`** — one line per question: the answer as the asker saw it, `answerRaw` (what the
  model wrote before the verifier), kept and dropped claims, the tool trace with timings, tokens
  and $. Read it when a row looks wrong.
- **`records.jsonl`** — today's `hallie_eval.py` shape, so
  `/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_eval.py grade --run <…>/records.jsonl` works unchanged.

Side by side with today's lane on the same suite:

```
/Users/rickb/dev/VideoScan/venv/bin/python /Users/rickb/dev/VideoScan/scripts/hallie_e1/cli.py report --runs <e1 folder> --baseline /Users/rickb/Library/Logs/VideoScan/hallie-eval/acceptance-v1-20261010.jsonl
```

How to judge a model (spec §1): **wrong-subject 0 and unverified 0 first** — any other number is
moot until those hold. Then judge % against each bar, then p95 latency against 20 s, then $ per
run. "pattern-clean" is the lexical grader; it flags things like `route_mismatch` and
`query_description_mismatch` that only describe today's lane shape (most visible on the strict set),
so trust the judge column for quality and use pattern-clean for regressions.

## Files

| file | what |
|---|---|
| `cli.py` | `run`, `judge`, `report`, `estimate`, `schema` |
| `runner.py` | corpus × models × seeds, output files, cap |
| `loop.py` | the bounded tool loop for one turn |
| `backends.py` | Anthropic (SDK) and Ollama (/api/chat) behind one interface; cassette recorder |
| `verifier.py` | turn-local citations, uncited-sentence removal, subject check |
| `toolbox.py` | imports the demo tool kit, generates schemas, `remote_serialize` (the one privacy gate) |
| `prompt.py` | the librarian system prompt (cached prefix — keep it free of dates/ids) |
| `costs.py`, `prices.json` | price table (dated, source noted), per-call cost, hard cap |
| `keys.py` | env → Keychain → profile; the scrubber |
| `fake.py` | scripted fake model, fake clock, cassette player (dry run) |
| `judge.py` | LLM-judge pass with its own cap |
| `scoring.py` | hallie_eval-shaped records, `grade_record`, scorecards |

Not done in E1 (left to the judge, or to the Swift lane): the verifier does not re-derive each
claim's value from the snapshot (exact date, re-run count, BFS path); there is no Message Batches
mode; bare kin words resolve only through the Python tool kit's rules (spec §4 fidelity notes).
