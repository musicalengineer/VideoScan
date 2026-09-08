# Overnight themes

Rick, 2026-09-08: daytime is rapid dev and brainstorming, and it goes all
over the place on purpose. Nights should be the opposite: one theme, one
owner, a measurable goal, a stop rule, and a morning brief that says what
landed and what did not. "Make it better" is not a theme.

Rick also observed that the Claude ↔ codex hand-offs overnight tend to gum
up, and he spends the morning working out who dropped the ball. The
protocol below is designed around that: one owner per theme, and the other
agent only ever produces *issues*, never edits the owner's branch. By
2026-10-27 (96 GB Mac Studio) a local model may take the reviewer seat.

## What a theme spec must contain

| Field | Why |
|---|---|
| **Goal metric** | A number the brief can report a delta on (pass rate, open count, lines over limit). |
| **Scope cap** | How much per night: one file, three issues, one eval family. Overrun is the main way nights go wrong. |
| **Allowed files / surfaces** | What the owner may touch. Anything else becomes an issue, not an edit. |
| **Stop rule** | When to stop early: any red test in the focused suites, any change to a file outside scope, any decision that is Rick's. |
| **Evidence** | Which suites must be green before a merge, and what the brief must quote (SHAs, counts, log lines). |
| **Owner** | Exactly one of Claude / codex / local model. The other is reviewer-only. |
| **Machine** | Per `reference_rick_availability_schedule`: M4 midnight–10:00, M1/M5 for long runs; ollama host check before any Hallie replay. |

## Themes (initial set)

### T1 — GitHub High Priority sweep
- **Goal:** open issues labeled `High Priority` → 0 or blocked-with-reason.
- **Loop:** pick the oldest `High Priority` issue with a reproducible statement; branch `fix/gh-<n>`; red test → fix → green; merge when the focused suites pass; close the issue with a summary comment (what, why, SHA, tests). Issues without a repro get a comment asking for one and are skipped.
- **Cap:** 3 issues or 4 hours, whichever first.
- **Stop:** any issue touching archive layout, schema, log paths, or recovered MXF data → leave a plan comment, do not implement (Manager escalation list).
- **Brief:** table of issue → outcome → SHA.

### T2 — Hallie to 100 % on the testbed
- **Goal:** `scripts/hallie_eval.py` pass rate; report per-family delta.
- **Loop:** harvest Rick's live queries from the day (`scripts/hallie_harvest_queries.py`) into the corpus first; run the eval; pick the largest failing family; fix in the deterministic Swift composer (never by prompt-tuning alone); rerun; keep only if no other family regresses.
- **Cap:** one family per iteration, max three iterations.
- **Stop:** ollama host version/model mismatch (check first — 2026-09-07 non-deterministic brain), or any family drops.
- **Brief:** pass rate before/after, families touched, queries still failing with a one-line diagnosis each.

### T3 — Swift best-practice ledger (long files, long types)
- **Goal:** swiftlint `file_length` / `type_body_length` / `function_body_length` violations → down, behaviour unchanged.
- **Loop:** take ONE file from the metrics ledger (today: FamilyTreeView 1,725 lines / 1,366-line body; ContentView 94-line function; PersonFinderView+People); extract at most three cohesive pieces into sibling files (`X+Feature.swift`) with no signature changes; full focused suites + the UI smoke plan green.
- **Cap:** one file per night. Rick's "fix all modules that are too long" is refined to this because a multi-file refactor overnight is exactly the change nobody can review in the morning.
- **Stop:** any extraction that needs a behaviour change, an access-level change wider than `internal`, or touches a `@State`/`@StateObject` lifetime.
- **Brief:** before/after line counts, files created, suites run.

### T4 — Archive portability (GH #170)
- Three independently mergeable nights: App_State write-through → Adopt on first launch → first-run wizard. Spec, decisions, and acceptance are in the issue. Night 1 cannot start until Rick answers the two open decisions there.

### T5 — Review-and-file loop (reviewer seat: codex now, local model later)
- **Goal:** every commit merged to main that day gets an independent read; findings become GitHub issues with the `Refactor` or `bug` label and a concrete failure scenario — never edits.
- **Cap:** the day's merges only; no historical sweeps.
- **Stop:** nothing to review.
- **Brief:** commits reviewed, issues filed (linked), false-positive count from the owner's triage.
- This is the theme that keeps hand-offs one-directional: reviewer writes issues, T1 picks them up on a later night. Nobody waits on anybody at 3 a.m.

### T6 — Escaped-bug sensors
- **Goal:** each bug Rick hit this week that the suite did not catch gets a regression sensor at production scale (100k records / real media matrix), per `docs/testing_retrospective_2026_07_05.md`.
- **Cap:** three sensors.
- **Stop:** a sensor that would need a fixture larger than 50 MB or real family media.

### T7 — Suite health
- **Goal:** zero red or flaky tests in the nightly lane; total time under budget.
- **Loop:** rerun reds three times; classify flaky vs real; fix the test or file the bug; quarantine with a linked issue only as a last resort.
- **Cap:** the nightly's red list.

## Night protocol

1. Rick picks the theme before bed (`/loop` with the theme id, or a line in the team channel).
2. The owner writes a one-line plan to the brief file first (`docs/morning_brief_<date>.md`), then starts.
3. Every merge: focused suites green, SHA in the brief, one-line rationale.
4. Anything outside scope → a GitHub issue with the theme label, not an edit.
5. The reviewer (if any) runs T5 against the owner's merges after they land; findings are issues.
6. The brief ends with **Decisions for Rick** (max three) and **What was not done and why**.

## Refinement notes for Rick

- Themes with a number (T1, T2, T3, T7) run well unattended. T4 and T6 need a decision or a fixture from Rick first; they are queued, not autonomous.
- "Fix everything that breaks best practices" → T3 with a one-file cap. "Improve Hallie" → T2 with the harvest step first, because live misses outrank testbed wins.
- If a theme's brief shows the same blocker two nights running, the theme is wrong, not the night.
