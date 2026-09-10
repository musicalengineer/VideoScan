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

### T8 — Birthplace trails that a computer should find easy
- **Rick, 2026-09-08:** Donna and Tim asked for birthplaces along a side of the family — "list all the birthplaces on my paternal side until you get to a place in England", "back 10 generations", countries/towns/whatever the GEDCOM has — and Hallie could not. `HallieBirthplaceTrail.swift` already handles the demo forms (maternal line until outside the USA; how many generations to Europe) but not: a **named stop** (England, Ireland, a town), an explicit **depth** ("back 10 generations", "10 generations of birthplaces"), **paternal** phrasing variants, and the plain **list** form ("list/read/give me the birthplaces …"). Codex's nightly review also found the continent stop-key bug (`replacingOccurrences(of: " ", with: " ")` no-op in `trailStopKey`).
- **Goal:** every harvested birthplace question passes on the eval corpus AND against the real tree (Rick's paternal/maternal lines, Donna's), with the answer read in generation order, one line per person: name, year, place, and a final line naming where the stop was hit or that the trail ran out (with the last known place).
- **Loop:** harvest the exact phrasings from Rick/Donna/Tim first (ask; do not invent); add them to `tests/hallie_eval_corpus.json` with answer-shaped expectations; extend the cue grammar (stop = country | continent | town | "outside <place>"; depth = N generations | until stop | whole line; side = paternal/maternal/father's/mother's/dad's/mom's/<name>'s <side>); fix the stop-key bug; verify on the real tree by replay.
- **Sibling equivalence (Rick, 2026-09-08):** full siblings share every ancestral line. A trail asked about Beth, Tim or Ellen (Rick's siblings in the People tab) resolves to the same parents as a trail asked about Rick, whether or not the sibling has their own tree pin — derive the root from the People-tab relation ("sibling of Rick" → Rick's mother/father), never from name matching. Same rule for Donna and her sisters (Bonnie, Paula — TBD, not yet in People). Half-siblings share only the common parent's line; the rule must check both parents before treating a sibling as equivalent.
- **Cap:** one night for parser + list form + named stop + sibling equivalence; a second for depth/count variants if needed.
- **Stop:** any change to the deterministic-composer rule (no LLM phrasing of facts); any GEDCOM place that needs geocoding to classify (file an issue instead — country/continent come from `BirthplaceClassifier`).
- **Brief:** the questions, before/after pass, and the real-tree answers verbatim so Rick can check them against FamilySearch in the morning.

### T9 — Static-analysis morning report (Rick's Coverity habit)
- **Rick, 2026-09-08:** at his medical-software company Coverity ran overnight and the morning report flagged recent code — dataflow findings no lint, compiler or reviewer catches. Swift's nearest equivalents, layered: **GitHub CodeQL** (dataflow engine, 28 Swift security-and-quality queries, free on this public repo), the **Swift compiler with `-strict-concurrency=complete` + upcoming features** (the checker for the bug class this codebase actually ships: actor isolation, `nonisolated async` traps), **Thread/Address Sanitizer** under the test suite (dynamic, self-hosted Mac only), **Periphery** (dead code), SwiftLint analyzer rules. SonarCloud (free for public repos, has Swift rules) is an optional second opinion — Rick's call.
- **State today:** `.github/workflows/nightly-analysis.yml` already implements this design and has been red every night since 2026-08-20; CodeQL scanned 1 of 1,283 files. GH #171.
- **Goal:** the workflow green; CodeQL scanning all Swift files; a morning report that lists **new-since-yesterday** findings (fingerprint-deduped) as GH issues labelled `analysis`, which T1 tackles a few at a time. Then CodeQL on every push/PR.
- **Cap:** night 1 = #171 (make the two jobs real) + a `workflow_dispatch` run as evidence; night 2 = PR trigger + issue emitter; night 3 = TSan lane on the M1 runner.
- **Stop:** any finding that needs a design change (file it, do not fix); any runner cost surprise.
- **Brief:** files scanned, warnings by category, new findings with file:line, and the false-positive rate from the owner's triage.

### T10 — Archive Angel top-50 hygiene (added 2026-09-10; Rick's pick for the night of 9/10→11)
- **Goal:** false-positive classes visible in the top 50 A/B candidates → 0; brief quotes A/B counts and the top-50 table before and after. Tonight's three known classes: (1) machine-only face evidence carrying non-camera files (Gladiator.mp4, Kill Bill Vol 2.mp4, downloaded spinning DVDs) into grade A; (2) both members of a duplicate group in one batch (FranklinAndCapeCod_July1991.mov ≡ DVD1992_5Chapters.mov); (3) derivative exports (`_balanced`, `_fixed`, `_NV12`, `.vs.edit`, `_preserve`) picked beside their originals.
- **Loop:** one heuristic at a time: red test → scorer change → `rulesVersion` bump → 8 Angel suites green → commit on `fix/angel-hygiene-<n>` → checkpoint to codex → merge to main when green and no blocker within 30 min → re-profile the top 50 from `archive-angel/evidence.json` + `catalog.json` (headless Python, no app).
- **Cap:** 3 heuristics or 4 hours; stop by 06:00 ET.
- **Allowed files:** `ArchiveAngelScorer.swift`, `ArchiveAngelScorerTests.swift`, `ArchiveAngelCandidate+Record.swift` (projection only, additive), `docs/archive_angel_design.md`. Anything else → GH issue.
- **Stop:** a red Angel suite not green after one bounded repair; any need to touch the promoter, Promote, the archive tree, `VideoRecord` schema, sweep scheduling, UI; any taste call (e.g. are Avid `clip-135-…` fragments worth archiving? is a 455 kbit/s 1.5 h export an original?) → brief as a question, not a change.
- **Evidence:** 8 Angel suites (`ArchiveAngelFloor/Evidence/Selection/Sweep/EvidenceStore/EvidencePick/Promoter/PromoterIdentity`) green per merge; SHAs; top-50 before/after; rejected-by-reason deltas.
- **Owner:** Claude. **Reviewer:** codex (or a local qwen if codex is unavailable) — issues only, never edits.
- **Machine:** M4 after Rick steps away; own derivedData under /private/tmp; no app launches; the assessment sidecar is read, never written, overnight.
- **Fallback (Rick):** if blocked or idle, T2 Hallie — harvest 9/10 live turns first (`scripts/hallie_harvest_queries.py`), run `scripts/hallie_eval.py`, one family per iteration, same reviewer rule.

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

## Check-in protocol (added 2026-09-10 — Rick: "make sure you and codex check with each other and don't allow one or the other to drop off into silence")

- **Manager = Claude** for the night. The owner posts a checkpoint on the team channel **every 30 minutes** while working (what landed, SHA, suites, next step) and a **"holding"** line when waiting.
- **Reviewer replies within 30 minutes** of a checkpoint: `blocker: <reason>` (owner stops merging that commit until resolved), `advisory: <notes>` (owner merges, notes go to the brief), or `clear`. **No reply in 30 min = clear** — the owner logs "reviewer silent at <time>" and proceeds; the brief lists every silent window.
- **Silence rule both ways:** if either agent has heard nothing for 60 minutes, it posts a ping; after two unanswered pings it writes the fact into the brief and continues alone. Nobody waits on the other for more than an hour.
- **Blockers before merge, advisory after.** A reviewer finding on an already-merged commit is advisory unless it is a safety or data-loss defect, which is filed as a GH issue labeled High Priority and named in the brief.
- **Merge authority:** the owner merges to main on green focused suites + no blocker (or 30-min timeout). Rick's approval is still the gate for anything on the Manager escalation list; those never merge overnight.
- **Caps are hard:** time cap, scope cap, and the stop-by hour end the night even mid-heuristic — an unfinished branch is left with a note, never merged.
- **Machines:** the M4 is Rick's; it is available overnight only when Rick says he has stepped away (not by assumption). Long or model-bound runs go to the M5; check the ollama model/version before any Hallie replay.
- **Morning brief** (owner writes; reviewer appends): CI/nightly status first, 🔴 important issues in bold at the top, then the metric delta, the SHA table, silent windows, and the questions for Rick.
