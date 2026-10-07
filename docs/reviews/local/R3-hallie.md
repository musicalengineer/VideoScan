# R3 report: the Hallie stream (GH #281)

**Night of 2026-10-06/07, M4, local.** Branch `refactor/r3-hallie`, based on `ebcd2f09`.
Owner: `refactor` agent. **Not merged and not pushed.**
Inputs: the brief (five functions), the cloud evaluation
`origin/cloud/N1007-D-Hallie-rewrite-eval` (refactor in place to ordered tables behind a
back-to-back oracle; F3 / F5 pin lists), §9 of
`docs/reviews/qa/refactoring_assessment_2026_09_13.md`, and the R1 report as the template.

## Commits (test commit first, recorded from the old code, then the refactor)

| # | SHA | What |
|---|---|---|
| 1 | `3b915267` | test: persona back-to-back oracle (frozen legacy copy) + sentence set + N1007-F3 pins |
| 2 | `35deaf1d` | refactor: `HalliePersonaQuestion.detect` → ordered phrase tables |
| 3 | `17197d55` | test: `HallieGoldenSnapshot` helper + relationship snapshots |
| 4 | `2d0b4c3b` | refactor: `executeRelationship` extract-function (move only) |
| 5 | `004fd4cd` | refactor: `relationshipSlot` simplify (owner outcome, not-found extracted) |
| 6 | `c89f6f4d` | test: shell `answer` session snapshots |
| 7 | `a485eecc` | refactor: `HallieShellCLI.answer` split into its routing steps |
| 8 | `54ab7e90` | test: superlative snapshots |
| 9 | `ff1b7b8c` | refactor: `superlative` split (scope / pool / rule / answer) |
| 10 | `9d4a1434` | test: `executeGroup` snapshots |
| 11 | `6532c6d7` | refactor: `executeGroup` split (frame / verdicts) |
| 12 | (this) | report + ignore `*.actual.json` |

Every new test file is assigned in `scripts/gauntlet/manifest.json` in its own commit
(hallie stage; the temporal suite in unit, beside `ArchivistTemporalExecutorTests`).

## Before / after (lizard 1.22.1 through `scripts/complexity_metrics.py`, regex literals neutralised)

| # | Function | Before CCN / NLOC | After CCN / NLOC | Largest new helper |
|---|---|---|---|---|
| 1 | `HalliePersonaQuestion.detect` | **80 / 92** | **8 / 12** | `normalizedWords` 14 / 23 |
| 2 | `HallieTurnExecutor.executeRelationship` | **50 / 250** | **12 / 69** | `relationshipSlot` 12 / 33 (19 after the move commit) |
| 3 | `HallieShellCLI.answer` | **64 / 419** | **10 / 61** | `translatedTurn` 10 / 70 |
| 4 | `HallieLineageAnswer.superlative` | **52 / 237** | **8 / 28** | `rankingRule` 12 / 37 |
| 5 | `ArchivistTemporalExecutor.executeGroup` | **56 / 188** | **11 / 35** | `ageVerdict` 13 / 45 |

All new functions ≤ 15 CCN and ≤ 80 NLOC; the pre-commit complexity gate passed on every
commit (no override, no `--no-verify`). `complexity_metrics.py --debt-out` at the head lists
all five as **fixed**, none new. SwiftLint reports nothing on any touched function; the
remaining warnings in these files are on untouched functions (`handleCommand` 27, `run`,
`parse`, `execute`, `executePresentAge`, `ageProse`) and file length.

Did not improve: `HallieShellCLI.swift` grew 1,952 → 2,133 lines (step signatures and doc
comments). Splitting `answer` into `HallieShellCLI+Answer.swift` is proposed below.

## Parity nets

**Persona oracle** (`HalliePersonaParserOracleTests`): a VERBATIM frozen copy of the old
`detect` (own vocabularies) vs production over `tests/fixtures/hallie_parser_sentences.json`
— **8,519 sentences**: 1,053 corpus questions from all six corpora (incl.
`hallie_strict_regressions.json`) and 7,924 2+-word literals from every `Hallie*` /
`Archivist*` test file (`scripts/hallie_parser_sentences.py` regenerates it) — plus a
586-sentence generated grid (every phrase alternative × every kin word, and two-cue
sentences that pin table order), each in 5 variants (as typed, lowercased, vocative before /
after, "Hallie Mae " prefix): **45,525 inputs × 2 identity oracles = 91,050 comparisons, 0
disagreements.** Also fails if any Ask kind or any kin word is never produced.

**Executor goldens** (`tests/fixtures/hallie_snapshots/`, recorded from `ebcd2f09` and
re-run green in a second process before any refactor commit):

| Suite | Snapshots |
|---|---|
| `HallieRelationshipSnapshotTests` | 32 (14 answered, 14 declined, 4 which-one) |
| `HallieShellAnswerSnapshotTests` | 5 sessions, ~780 rendered lines |
| `HallieSuperlativeSnapshotTests` | 405 (124 answered, 227 declined, 54 which-one) |
| `ArchivistTemporalGroupSnapshotTests` | 336 |

N1007-F5: (c) overlay-before-no-tree (scenario 23, "Dawn is your wife" with no GEDCOM) and
(d) the people-count guard are pinned. (a) a stale chip and (b) a failed chip retry are **not
reachable through the public API** (both need a continuation whose context changed under the
same token), so they stay unpinned defensive guards. Also unexercised: the overlay's
"(taking …)" aside (my assumed-bridge scenario did not link through the overlay).

## Test runs (Release, `ENABLE_TESTABILITY=YES`, own derived data, `test-without-building`, CI plan)

| Run | Result |
|---|---|
| Goldens recorded on `ebcd2f09`, then re-run | 5 tests / 5 suites green |
| Baseline, old code: 266 Hallie* / Archivist* suites (+ PeopleTabPrecedence, KinshipInference) | **2,209 tests, green** |
| Same set, refactored code | **2,209 tests, green** |
| Move-only relationship commit: relationship + owner-binding + People-tab suites | 51 tests, green |
| Same 266 suites at branch head | **2,209 tests, green** |
| **Full `VideoScanTests` at branch head** | **10,388 tests / 1,547 suites passed** (11 known issues), 1,367 s |

## Red checks (deliberate mutations, each built and run, then reverted)

| Round | Persona | Relationship | Superlative | Temporal | Shell |
|---|---|---|---|---|---|
| 1 | drop " you ever marry " → **red** (30 of 90,490) | no-tree guard above the overlay (F5c) → **red** | latestDied picks min → **red** (8) | day-precision `<=` → `<` → **red** (4) | needsClarification → answered → *survived* |
| 2 | age after origin → *survived* | ladder stops at first not-found → **red** | 2 winners shown, not 3 → **red** (9) | died-before `>` → `>=` → **red** (3) | telling opening needs > 40 chars → **red** |
| 3 | drop " you have a <kin> " → **red** (305) | drop the "tried …" basis → **red** | other side keeps `.otherSideOf` → **red** (27) | month lead-in uses day form → **red** (15) | general lane never taken → **red** |

The two survivors were real gaps in the nets, closed before committing: the oracle grid gained
two-cue sentences (table order), and the shell snapshot gained a `--once` which-one session
(the turn's outcome / exit code). Re-run with both mutations: **both red** (80 of 91,050;
1 of 5 sessions). The shell golden was re-recorded on the old code; its four earlier sessions
were byte-identical to the first recording. Net result: **every executor 3/3 red, persona 3/3.**

## Sensors

No sensor needed repointing: the shell source sensors
(`HallieShellCLITests.mainRoutesHallieBeforeSwiftUI…`, `.productionSourceHasNoCatalogWriter…`,
`HallieTurnExecutorTests.sharedExecutorIsUIAndMediaNeutral…`) pin strings that are still in
`HallieShellCLI.swift`; no other sensor reads the five files' bodies. None weakened.

## Process notes

- Rick's Debug app ran from 20:56 through the night; no tests ran until the coordinator's
  02:45 rule. I built everything meanwhile and kept prebuilt product sets (old, new, three
  mutation rounds, move-only) so the morning runs needed no rebuilds. An offline
  `swiftc` legacy-vs-new persona run (0 diffs) was the only check before 02:57.
- Every intermediate commit was not run on its own: each refactor commit touches one file
  whose own net (snapshot / oracle) ran green against that exact file content, and the full
  suite ran at the head. The move-only relationship commit did run on its own.

## Leads (not acted on)

- Pre-existing gauntlet drift on main: `ArchiveAngelNoSoundMediaMatrixTests.swift` and
  `ArchiveAngelNoSoundTests.swift` are unassigned (`inventory.swift --validate`). Not mine.
- Ratchet at head reports `AngelRuleLanguage.swift::ArchiveAngelRejection.name` worse
  (27 → 28) — from main's v15 noSound floor, not this branch.
- `complexity_metrics.py` at the worktree root also reported ~98 Python offenders "fixed";
  looks like a measurement artifact of running it from a worktree. Worth a look by metrics.
- Shell file length: move `answer` + steps to `HallieShellCLI+Answer.swift` and point the
  three shell sensors at both files (strictly stronger for their `!contains` checks).
- Next offenders in these files: `handleCommand` (33), `run` (23), `ArchivistTemporalExecutor.execute` (29), `ageProse` (22).
- N1007-F2 (11 unpinned lineage branches, one dead pattern) and F4 (pics / documents
  media-noun split) belong with the `detectShape` table conversion, not this queue.

## What's left

Nothing from the queue. Next: qa review of the branch, then merge. The legacy persona copy
can be deleted in its own commit once the refactor has lived on main for a while.
