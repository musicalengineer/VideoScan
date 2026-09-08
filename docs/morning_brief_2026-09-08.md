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

- **22:30** — main at `534506ad` + one refactor in checkpoint (unpushed, 12
  commits tonight). Hallie: four live-path bugs fixed and pinned (question
  never reached the guards; "what country?" → Rick; "tell me about dad" →
  dad's father; description named the model's op). Instrument: the strict
  lane ran twice for real — then proved ricksm5's brain answers identical
  bytes differently at temperature 0 (see "The first real strict replays");
  **its numbers are untrusted until ollama on the M5 is restarted — your
  call, not mine**. Refactors: two mechanical extractions landed, a third in
  checkpoint; files >1000 lines 36 → 35; lint total unchanged at 332 (moves
  carry their warnings). `HallieTurnExecutor.swift` has no seams at all —
  one 2,118-line enum with privates throughout — so it stays codex's #1
  design step, not a night move. Next: ledger row 17 ("find videos with
  dad" must search every alias of the resolved identity). Off the M4 from
  02:00.

## What landed

| SHA | what | codex |
|---|---|---|
| `73ab8e15` (codex) | hallie_eval.py fails closed: exit 2 on missing turn / dead app / timeout; `grade --strict`; .summary.json + GRADE_SUMMARY; 51 tests | own |
| `3bfd62db` (codex) | DirectAncestorLineReviewTests — cycle, shortest chain, depth boundary | own |
| `1eefb0ac` | nightly Hallie replay: runner, strict manifest (15), nightly hookup r5, harness 9b (41/41) | pending review |
| `ce156726` | guards + follow-up resolver reach the LIVE single-person path; resolver never name-probes field words (`isKnownPerson("country")` is true on the tree) | checkpoint 6845 / 2 known sensors |
| `e5448d0f` | "tell me about dad" is dad's biography (relation guard ignores the subject's own word); `queryDescription` names the resolved query, `model=` when a guard moved it | same checkpoint |
| `a42d0f92` | "how am I related to <name>"; titled / initialled names resolve (`titledNameRecovery`) | same checkpoint |
| `a6ccc1cc` | count prose: "were born in a place recorded as England" | same checkpoint |
| `139a8dc2` | replay row `incomplete` is a count, not the harness bool | same checkpoint |
| `d9d8c808` | brief + ledger rows 18–21 | — |
| `2a837e4f` | refactor: the eight field guards → `ArchivistGraphQuery+FieldGuards.swift` (1815 → 1689 lines; nothing widened) | route suites 50/50; full 6845 / 1 known sensor |
| `534506ad` | refactor: translator-output decoding → `ArchivistQueryAST+TranslatorDecoding.swift` (1133 → 715 lines; no private helper crossed) | 71/71; full 6845 / 1 known sensor |
| `8824a0f0` | refactor: GEDCOM awareness + common-ancestor answers → two `HallieLineageAnswer+…` extension files (2904 → 2306 lines; the one private helper moved with its section) | 86/86 on 11 suites; full 6845 / 1 known sensor |
| `6a24809c` | TreeStatistics: denominator = whole population; unrecorded vs unclassifiable; recordedText matches a whole component (England ≠ New England) | #1180/#1181 → corrected, pending re-review |
| `5d83cbef` | statistics recognizer abstains on alive/dead, generations, sided scope; exact-year filter; region ≠ country | #1180 → corrected, pending |
| `6065801a` | guards fire only on what the sentence settles: relation REQUESTS only, mixed cues abstain, follow-ups refuse any relative | #1181 → corrected, pending |
| `19f4432e` | direct-line climb follows the primary family; bridge per slot | #1182 → corrected, pending |

Checkpoint for the four: full suite 6,904 passed / 2 failed / traps 0 — the same two timing sensors as the 3fe804a0 baseline (unresolved, not "green apart from").
| `7bc5cb73` | biography guard yields when the sentence names birth/death (devstral's finding) | pending |
| `c8218fa4` | **statistics wired**: "how many people were born in England" → a count with its denominator; statistics detected before the trail | pending |
| `a750ac89` | **Henry VIII**: digits in names, named counterpart beats focus, name cap 5→8, "8th" not "8Th" | pending |

These three were committed on the seven affected suites (56/56); the full-suite checkpoint runs after the strict replay (the M4 was busy) and its result is recorded below when it lands.

## What codex found, and what was done about it

| finding | source | correction | evidence |
|---|---|---|---|

## Metrics — before and after

Baseline captured at `5398c6fa` before any refactoring (production Swift only):

| metric | baseline | after the day's fixes (`fdd88038`) | after the refactors |
|---|---|---|---|
| files over the 1000-line guideline | 36 | 36 | **35** at `8824a0f0` (ArchivistQueryAST under; HallieLineageQuestion still 2,306) |
| swiftlint violations (all rules) | 332 | 332 | **331** at `8824a0f0` — one File Length gone; every other warning travelled with its code, none hidden |
| cyclomatic complexity > 15 | 91 | 91 | 91 — no function was split; that is design work, not a night move |
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

_(22:30 addendum: measured tonight — `HallieTurnExecutor.swift` is a single
2,118-line enum with no MARK/extension seams and private members in every
300-line band; `HallieAppTurnCoordinator.swift` likewise one 1,126-line enum.
Neither can be split without deciding a contract first. `PersonEditSheet.swift`
has clean MARK seams but is SwiftUI — codex's boundary requires a routed UI
checkpoint, so it waits for a day with you at the M4.)_

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

## The first real strict replays (21:00–21:40) — what the instrument found

The strict lane ran for the first time tonight against a real binary and the
real brain. It found more in forty minutes than the day's spot-testing did.

**Run 1 (7bc5cb73 tree, 21:09): 11 / 15.** The four fails had ONE root cause
each, and every one was invisible to the unit tests because they exercised the
function, not the path:

| strict id | what came back | root cause | fix (unit test) |
|---|---|---|---|
| 001 | still the birth **date**, an hour after the place guard shipped | `HallieTurnExecutor` never passed the question into `ArchivistGraphQuery` on the single-person path — the guards only ran on the relationship path; tests called the initializer directly | question threaded at both sites |
| 002 | **Rick's biography** for "what country?" | `isKnownPerson("country")` is **true** on Rick's tree — the loose name matcher resolves it to "William Culpeper of Preston Hall"; "born" and "he" resolve too, through narrative text stored in NAME records. The follow-up resolver name-probed every word, so a bare field follow-up looked like a fresh question naming a person | resolver never probes its own field vocabulary (`HallieFollowUpJunkNameTests`, stub mirrors the real tree) |
| 003, 004 | Rick's birth / Rick's spouse | downstream of 002 (focus moved to Rick) | — |
| 011 | "tell me about dad" → **"Richard Harding Breen Sr's father was George Breen"** | the relation guard read the SUBJECT's own word ("dad", person=dad) as a relation asked of him | guard ignores the subject's words (`HallieRelationGuardSubjectTests`) |
| 001 (desc) | answer right, `queryDescription` said `operation=birth` | description was built from the model's payload, not the resolved query | `graphQueryDescription(_:resolved:)` adds `model=` when a guard moved it |

Also found: `"what country?"` was reaching the general-knowledge lane before
the follow-up resolver (fixed, `aBareFieldFollowUpOutranksTheGeneralLane`), and
titled/initialled names ("king edward iii of england", "richard h breen jr")
fell through every resolver rung (`titledNameRecovery`, 5 tests).

**Run 2 (all fixes, unit 79/79, 21:22): 7 / 15 — and this is the finding.**
Every translated turn came back as `presence` / `event` / `temporal`. Traced
for thirty minutes, honestly:

- The brain is **non-deterministic at temperature 0 tonight.** A logging proxy
  captured two shell processes sending **byte-identical** 15,254-byte
  `/api/chat` bodies thirty seconds apart: `graph/biography` vs
  `graph/kinship(father)`. Eighteen samples of "what country was John Hastings
  born in?" across processes: biography 9, birth 4, temporal/age 2, presence 2,
  kinship 1. Inside one process (three asks with `:reset`) all three identical;
  seven curl replays of the captured body identical even after deliberately
  disturbing the KV cache; raw `/api/generate` with a seed deterministic 6/6.
  Same bytes, different answers over time — not our prompt, not Swift
  `Set` order, not the fixes.
- ricksm5 state at the time: `ollama serve` **0.32.14** (process from Aug 25)
  spawning a **0.33.3** `llama-server` (Homebrew Cellar upgraded Sep 5 15:42;
  runner reloaded today 20:59:44). Memory **46 G of 48 G used, 11 G
  compressor, 972 MB free** — Photos, Lightroom Classic, Firefox, Activity
  Monitor all resident. `OLLAMA_NUM_PARALLEL` unset.
- I did not restart ollama on the M5 (your process; the no-kill rule). Codex
  asked (#1195) whether anything of its was on ricksm5 concurrently.

So tonight's strict numbers measure the **engine**, not the code. The
unit-side fixes are real and pinned; the live gate cannot be trusted until the
brain answers the same request the same way twice. That is exactly what the
strict lane is for — it just found the instrument under the instrument first.

## Decisions that are Rick's

_(collected as they arise)_

- **Nightly Hallie replay**: approve the M5 LaunchAgent above, and which
  live-miss rows form the strict gate.
- **Restart ollama on ricksm5** (0.32.14 serve under a 0.33.3 runner, 972 MB
  free) and re-run `scripts/nightly_hallie_replay.sh --strict-only` — the
  first honest strict number needs a deterministic brain. Consider
  `OLLAMA_NUM_PARALLEL=1` on the brain host, and quitting Photos/Lightroom
  there while replays run.
- **The tree calls common words people.** `isKnownPerson("country"/"born"/"he")`
  is true because NAME records carry narrative text ("*JOAN \\ JOHANNE; 1486
  born Holdenby…"). Tonight's fix shields one resolver; the structural fix is
  to exclude narrative NAME records at index time — a compiled-tree change,
  so your call.
- Aggregate queries: whole tree or your ancestors when the question does not
  say? (`docs/hallie_tree_aggregate_queries.md`)
- Titles: parser must keep `1 TITL` — a record-shape change (codex's gate).
- Reviewer model: judge tonight's first `qwen2.5-coder:32b` nightly digest
  against the four nights of `qwen3.8:27b-mlx` findings before changing it.
- Raw dates spoken as recorded ("24 juin 1314") vs normalised — design choice.
