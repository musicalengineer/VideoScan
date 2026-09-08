# Morning brief — 2026-09-08

Overnight shift authorised by Rick 2026-09-07 evening. Working agreement:
team-channel #1178, amended by codex #1179. Codex's independent review
checkpoint: `docs/codex-overnight-review-2026-09-08.md` (codex owns; linked,
not merged into this file).

Hard rules held all night: no push, no schema/codec changes, no nightly config
changes, no deletions, behaviour-preserving refactors only, full unit suite
before every commit.

## Status at a glance

_(filled in as the night goes; latest entry on top)_

## What landed

_(one line per commit, with the codex verdict beside it)_

## What codex found, and what was done about it

| finding | source | correction | evidence |
|---|---|---|---|

## Metrics — before and after

Baseline captured at `5398c6fa` before any refactoring (production Swift only):

| metric | baseline | now |
|---|---|---|
| files over the 1000-line guideline | 36 | |
| swiftlint violations (all rules) | 332 | |
| cyclomatic complexity > 15 | 91 | |
| function body > 80 lines | 100 | |
| file length > 1000 | 36 | |
| force unwraps | 33 | |
| production lines | 229,996 | |

## Modules that need PROPER redesign, not tidying

Ranked by RISK (codex #1182), not line count. Line count is in brackets only
so nobody mistakes it for the criterion.

1. **Intent and identity boundary** — `HallieTurnExecutor` (+Conversation,
   +SpeakerKinship), `ArchivistGraphExecutor`, `ArchivistFollowUpResolver`.
   Every wrong-person and wrong-field failure of 09/07 lived here. The
   contract change (recognised / abstain / conflict for BOTH field and
   entity) is a design step — `docs/hallie_intent_recognizer_design.md`.
2. **`HallieLineageQuestion`** [2817] — parsing, identity, traversal and prose
   in one enum with functions at complexity 34 and 32. Extract pure
   recognition and result construction behind route characterisation tests;
   preserve detection precedence.
3. **`FamilyTreeLiveModel`** [1813] — async load and coordinated publication
   of graph/identity/selection/caches. `installSteps` ordering is
   deliberate; splitting without stale-load tests risks mixed-generation UI.
4. **`ArchivistChatWindow`** [2714] — request lifetime, clarification chips,
   transcript writes. Pure chip builders are safe to extract; task ownership
   is not, headless.
5. **Large views** — `FamilyTreeDemoView` [1721] owns sheets, selection and
   edit state; extract stateless rendering only.

## Found while Rick tested (evening 09/07)

- **Henry Adams** — Rick clicked a Henry Adams and both "Line to" buttons were
  grey. Correct, but unexplained: of three Henry Adams records in his tree and
  six in Donna's, the Braintree immigrant (`LYNX-9NC`, b. 1583; duplicated as
  `PXFH-LS9` in Rick's pull) is a **direct ancestor of both at generation 13**,
  while `PWQP-NG9` (b. Dec 1622) and `P6T3-8FH` have **no `FAMC` link to anyone**
  — floating records, related by no recorded line. Backlog: a grey "Line to"
  should say why ("not on any recorded line above; nearest connection: none").
  Also a data-quality note: the immigrant exists under two FamilySearch ids
  across the two pulls — the merge did not fold them.

## Decisions that are Rick's

_(collected as they arise)_

- Aggregate queries: whole tree or your ancestors when the question does not
  say? (`docs/hallie_tree_aggregate_queries.md`)
- Titles: parser must keep `1 TITL` — a record-shape change (codex's gate).
- Reviewer model: judge tonight's first `qwen2.5-coder:32b` nightly digest
  against the four nights of `qwen3.8:27b-mlx` findings before changing it.
- Raw dates spoken as recorded ("24 juin 1314") vs normalised — design choice.
