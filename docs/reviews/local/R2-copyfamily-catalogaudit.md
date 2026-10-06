# R2 report: CopyFamilyAssessor.assess + CatalogAuditor.run (GH #281)

**Afternoon of 2026-10-06, M4, local.** Branch `refactor/r2-copyfamily-catalogaudit`, based on `6db24a65`.
Owner: `refactor` agent. **Not merged and not pushed.** Next: qa review. No spot test is needed
beyond opening Show Copies and Audit Catalog once, because both functions are pure and the output is
pinned by whole-output snapshots.
Plan: `origin/cloud/N1006-D-next-refactors:docs/reviews/cloud/N1006-D-next-refactors.md` (steps A0–A2,
B0–B3). Background: `docs/reviews/qa/refactoring_assessment_2026_09_13.md`, "Acceptance bar" items 2–4
(pin the boundary first, no behaviour change hidden inside a refactor).

## Commits (each one built and green before the next)

| # | SHA | What | Kind |
|---|-----|------|------|
| 1 | `32b69963` | 16 pinning tests: the guards the plan marked ❌, plus one whole-output snapshot per function | tests first |
| 2 | `30361149` | `CatalogAuditor.run` → `CatalogAuditTally` (one pass) + ten `check…` functions called through an ordered table | pure move |
| 3 | `b3754154` | `CopyFamilyAssessor.assess` → rule phases in a file-scope extension; `swiftlint:disable:next` removed | pure move |
| 4 | `1264b5f5` | `isUnreadable` / `isDurationOff` / `provenByteIdentical` helpers; dead `signatureKey` deleted; `LifecycleStage` raw values instead of the `"Trashed"`/`"Deleted"` literals | simplify |
| 5 | (this report) | docs | |

Commits 2 and 3 were tested together (they touch different files and do not depend on each other),
then committed separately so each can be reviewed alone.
Review tip: `git show -w --color-moved=dimmed-zebra <sha>`.

## Before / after numbers

### lizard 1.22 (CCN / NLOC)

| Function | Before (`6db24a65`) | After |
|---|---|---|
| `CatalogAuditor.run` | **CCN 66, 165 NLOC** (189 lines) | **CCN 1, 17 NLOC** |
| largest new audit piece | — | `checkDuplicateGroups` CCN 11 / 26; `checkVolumeCache` 8; `addActive` 7; `tally` 6 |
| `CopyFamilyAssessor.assess` | **CCN 57, 193 NLOC** (254 lines), `swiftlint:disable:next` | **CCN 10, 47 NLOC** (no disable) |
| largest new assess phase | — | `roleByCodecClass` 9; `electOriginal` 7; `originalCautions` 7; `actions` 8; `assignRole` 6 |
| `recommendedInstance` (helper adopted) | CCN 13 | CCN 11 |
| `codecClass` (untouched) | CCN 16 | CCN 16 (baselined; the plan says leave it) |

Every new function is CCN ≤ 11, which meets the brief's target (≤ 15, none > 30). The complexity gate
passes on every commit and on the whole tree (`complexity_gate.py --all`: OK, 993 files).
The stale baseline entries for `assess` and `run` in `ci/baselines/complexity_debt.json` are left for
the nightly's `--shrink-baseline` to retire, since that is the job that owns the ratchet.

### Files (wc -l)

| File | Before | After |
|---|---|---|
| `Archive/CopyFamilyAssessor.swift` | 664 | 731 |
| `Catalog/CatalogAudit.swift` | 372 | 441 |

The files **grew** (function signatures, the `Draft`/`Election`/`CatalogAuditTally` types, and doc
comments). This refactor aimed at function complexity, not file size, and both files are well under
the 800-line limit. Nothing was split into new files, so no source sensor's path changed.

## Tests

Set: every Swift Testing suite and XCTest class in test files matching `CopyFamily*`, `CatalogAudit*`,
`Archive*` (which includes `ArchiveAngelShowCopiesTests` and `ArchiveAngelRecommendationsTests`, the
only other users of the assessor) and `Catalog*`, plus the two new suites: 269 `-only-testing` names.
Release, `ENABLE_TESTABILITY=YES`, worktree `.derivedData`, at most one of my runs at a time.

| Run | Swift Testing | XCTest | Result |
|---|---|---|---|
| Baseline `6db24a65` | 1,491 tests / 265 suites | 48 | green |
| after C1 (pinning tests) | 16 / 2 (the new suites alone) | — | green |
| after C2+C3 (moves) | **1,507 / 267** | 48 | green |
| after C4 (simplify) | **1,507 / 267** | 48 | green |

No new compiler warnings in either file. SwiftLint reports one existing `force_unwrapping`
(`groups[sig]!`, moved unchanged) and one in each new test file (the fixed-UUID helper).

### The 16 new tests and red-green

`CatalogAuditGuardTests` (8): A2 purged + "Deleted" is terminal · A8 a retired empty drive is not
offered for deletion · A9 the "members disagree" arm · A10 stale-group focus lists active members only ·
A11 the Master Archive check is skipped when there is no index · A12 a cold cache is "warming", not a
mismatch · A13 finding order and check names · **whole-report `dump` snapshot**.

`CopyFamilyGuardTests` (8): C6 presumed-election keys, one test per key (derivation target › lossless ›
earliest stamp). Each test is built so that the next key would give a *different* answer; my first
draft of the lossless test passed under its own mutation, and I rebuilt it. Also C7 two-native caution ·
C10 unknown codec by lineage · C12 damaged audio with no repair · C13 no "Create + Promote Lossless
Companion" for a presumed original · **whole-assessment `dump` snapshot** over 7 families plus the
empty one (the Clip 01 case, presumed root, external lineage, repaired + companion, damaged + truncated
+ no-streams, unknown codec, two natives).

The goldens were captured from `6db24a65`. They were **not edited** after the move or the simplify step.

Mutation runs: 14 targeted mutations in two batches (batch 2 holds the C6 keys 2/3, which would mask
each other). Each was run **before** the move against the old code and **again after** the move against
the new locations. All 14 targeted tests went red both times, and both snapshots went red under
batch 1. Then the code was restored.

Not pinned here: A15 (`project` falls back to `pendingPairedWithID`). `project` did not move, and the
plan marks it optional.

## Sensor changes

**None needed.** No source sensor reads `CopyFamilyAssessor.swift` or `CatalogAudit.swift` by name
(I grepped the test target, `tools/` and `scripts/`). The code stayed in its own files. The only
file-name-keyed check affected is the complexity gate's disable count: the grandfathered `swiftlint:disable`
in `CopyFamilyAssessor.swift` is now gone (1 → 0). That count can only fall, so the gate passes.

## API / visibility changes

- New internal type `CatalogAuditTally`, and new internal statics `CatalogAuditor.tally` and
  `check…` (×10). `run(_:now:)` keeps its signature.
- New internal statics `CopyFamilyAssessor.isUnreadable`, `isDurationOff` and `provenByteIdentical`.
  The phases (`makeDrafts`, `electOriginal`, `assignRole`, `originalCautions`, `actions`, …) are
  `fileprivate`/`private`, and so are `Draft` and `Election`.
- **Removed:** `CopyFamilyAssessor.signatureKey(_:)`. It had no caller in any target (`git grep`), and
  periphery listed it as unused on 2026-09-22.
- `Dictionary(uniqueKeysWithValues:)` in `makeDrafts` is kept on purpose (plan C4). It traps on
  duplicate ids, and the only caller (`ArchiveAngelShowCopies.walk`) keys the family by id, so that
  cannot happen.

## Behaviour notes for the Manager (NOT changed here; route to bug-fix)

- **Stage-0 R3 (`hasExternalLineage` computed but never read): already fixed, so this premise is
  stale.** `16e0f263` (2026-09-29) made the field drive the native election, the presumed reason and a
  caution, and `CopyFamilyExternalLineageTests` (3 tests) pins it. In the current code the field is read
  in three places (now `electOriginal` ×2 and `assess`). The new snapshot's "external" family pins the
  fixed wording too. I found no remaining false-reason path. One edge for qa: a mixed group (one member
  with an absent parent plus one with no `derivedFrom`) is deliberately **not** flagged, and keeps the
  "not derived from any other copy" reason. That is the documented intent, and
  `oneStaleDerivedFromInAnIdenticalGroupDoesNotDemoteTheOriginal` pins it.
- **F1** (plan): "Empty drives" counts only *active* records. A target whose records are all set
  aside or superseded is offered "Delete from list", and the plan sentence "No catalog records are
  affected" is then false. The fixer also does not re-check emptiness. Unchanged.
- **F2**: "Totals reconcile" subtracts `doubleClaimed.count`, so a record under three nested targets
  makes it FAIL. Unchanged (`checkTotals`).
- **F3**: `run` reads `ContinuousClock.now` twice for one duration (attoseconds from one reading,
  seconds from the other). It is cosmetic. The plan suggested fixing it inside the split; I left it,
  because a refactor commit should not carry a fix.
- **F4**: on a tie, `modalDuration` picks the **shortest** duration. My snapshot's "unknown codec"
  family (600 s vs 100 s) pins today's choice of 100 s, so whoever fixes F4 must regenerate that
  golden deliberately, in the same commit as the fix.

## What's left (propose-later)

- Plan item 3: `LifecycleStage.isTerminal` in VideoScanCore, shared by `tally` and
  `CatalogAuditFixer.apply(.setPurgedStages)`. That is a new core API, so I did not add it here.
- `CatalogAuditFixer.apply` (on the gate baseline) and `codecClass` (CCN 16) are untouched.
- Pluralisation is hand-rolled about 12 times across both files (backlog line in the plan).
- The stricter grouping key (bit depth and field order) that the deleted `signatureKey` hinted at would
  change behaviour. It is Rick's call, and it is not part of a refactor.
