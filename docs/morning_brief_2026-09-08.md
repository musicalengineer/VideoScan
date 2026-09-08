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

| SHA | what | codex |
|---|---|---|
| `73ab8e15` (codex) | hallie_eval.py fails closed: exit 2 on missing turn / dead app / timeout; `grade --strict`; .summary.json + GRADE_SUMMARY; 51 tests | own |
| `3bfd62db` (codex) | DirectAncestorLineReviewTests — cycle, shortest chain, depth boundary | own |
| `1eefb0ac` | nightly Hallie replay: runner, strict manifest (15), nightly hookup r5, harness 9b (41/41) | pending review |
| `6a24809c` | TreeStatistics: denominator = whole population; unrecorded vs unclassifiable; recordedText matches a whole component (England ≠ New England) | #1180/#1181 → corrected, pending re-review |
| `5d83cbef` | statistics recognizer abstains on alive/dead, generations, sided scope; exact-year filter; region ≠ country | #1180 → corrected, pending |
| `6065801a` | guards fire only on what the sentence settles: relation REQUESTS only, mixed cues abstain, follow-ups refuse any relative | #1181 → corrected, pending |
| `19f4432e` | direct-line climb follows the primary family; bridge per slot | #1182 → corrected, pending |

Checkpoint for the four: full suite 6,904 passed / 2 failed / traps 0 — the same two timing sensors as the 3fe804a0 baseline (unresolved, not "green apart from").

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

## Reviewer-model bake-off (Rick authorised downloads)

Same commit (`ea588b97`), same adversarial prompt, same scorer (me, each claim
checked against the code). "Real" = a defect that exists or a test that is
genuinely missing; "wrong" = the claimed behaviour does not occur.

| model | size | time | claims | real | wrong | the real ones |
|---|---|---|---|---|---|---|
| qwen2.5-coder:32b (current nightly reviewer) | 20 GB | 57s | ~11 | 1 | 8 | compound "birth and death" should not be claimed as biography |
| qwen3-coder:30b (MoE, 3.3B active) | 18 GB | **13s** | ~12 | 1 | 7 | a bare statement ("He died in 1389") must not be treated as a question — checked: it is not (no "where"), so borderline; the mixed-cue abstention it asks for was already shipped in 6065801a |
| devstral:24b | 14 GB | 39s | ~12 | **3** | 6 | "Where was John's wife born?" nested subject (real; fixed 6065801a); "Tell me about John's death" claimed as biography (**real, still open — fix tonight**); compound relations "John's wife's brother" unhandled (real, abstains today by the two-relation rule) |

Wrong-claim examples common to all three: "in what country was he born" and
"which town did he die in" are said to be missed — both match. All three
review from the prompt, not the source; none noticed that the tests already
covered the model-disagrees case.

**Read:** devstral found one open defect the others did not, at a third of
qwen2.5-coder's latency. None is a source-reading reviewer; codex is. If a
local model stays in the nightly, devstral:24b is the candidate on this
sample — one sample. Tonight's first `qwen2.5-coder:32b` nightly digest over
37 commits is the fair comparison, tomorrow.

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

## Rick's question tonight: do all recorded queries fire nightly?

**No.** Verified 20:40 ET: nothing schedules a corpus replay — not
`scripts/nightly_local_tests.sh`, not any LaunchAgent, not the model-fitness
tools. The last full replay artifact is `demo-20260903-final-302` (09/03, 302
questions). The corpus is now 345 questions, 80 marked `followsPrevious`, 59
with "expectation unconfirmed".

Worse, `scripts/hallie_eval.py` could not gate anything even if scheduled:
`run` returned 0 when the app exited nonzero or questions produced no turn,
and `grade` returned 0 regardless of defects (codex #1186, confirmed at lines
339/420/687). **Fixed tonight** — see "What landed". Scheduling it is a
nightly-config change and therefore Rick's call:

**Proposed** (needs Rick): a separate LaunchAgent on the model host (M5) at
~03:00, after the M4 nightly, running `hallie_eval.py run` against a pinned
binary, model, tree and corpus SHA — all four stamped into the run id — then
`grade --fail-on-defects` over a **reviewed strict subset** (the live-miss rows
whose expected behaviour has been confirmed) and an advisory report over the
whole corpus. Codex's requirements list is in #1186: immutable run identity,
completion counts, timeout/missing = incomplete not green, never encode a
prior wrong answer as the oracle.

## Decisions that are Rick's

_(collected as they arise)_

- **Nightly Hallie replay**: approve the M5 LaunchAgent above, and which
  live-miss rows form the strict gate.
- Aggregate queries: whole tree or your ancestors when the question does not
  say? (`docs/hallie_tree_aggregate_queries.md`)
- Titles: parser must keep `1 TITL` — a record-shape change (codex's gate).
- Reviewer model: judge tonight's first `qwen2.5-coder:32b` nightly digest
  against the four nights of `qwen3.8:27b-mlx` findings before changing it.
- Raw dates spoken as recorded ("24 juin 1314") vs normalised — design choice.
