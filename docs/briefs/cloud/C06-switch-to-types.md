# C06 — Switches that should be types: find the worst offenders (design review, read-only)

Brief id: `C06-switch-to-types`. Inherits every rule in `docs/briefs/cloud/README.md`.
Output: ONE report at `docs/reviews/cloud/C06-switch-to-types.md`, on branch `cloud/C06-switch-to-types`.
Time box: ~60 minutes. This is a DESIGN review (refactor targets), not a bug hunt; rule 5's
"failing scenario / pinning test" becomes "the guarantee the new shape must keep, and the test
that pins it".

## Why (Rick, 2026-10-09)
A big `switch` is a hand-written jump table. `MediaFileOperationKind.style` was a 27-arm
`switch self` returning constants (badge, log verb, colour) plus a second exhaustive switch
(`hasDetailView`). It was replaced by DATA: a struct with one `static let` per kind whose
style is a required init argument (commit `0d8c999eb`, read
`VideoScan/VideoScan/MediaOps/MediaFileOperations.swift` around `struct MediaFileOperationKind`
as the exemplar, and `MediaFileOperationKindTests` in
`VideoScan/VideoScanTests/MediaFileOperationsTests.swift` for the sensors that replaced
compiler exhaustiveness). Top CCN in that file went 27 → 10, with no behaviour change. A second,
smaller exemplar: `VolumesWindow.protectionItems(for:)` (a real menu section split out of
`contextMenuItems`). Rick wants the rest of the app's worst cases found the same way.

## Input (already computed on the Mac — do not recompute)
`docs/reviews/census/switch_census_2026_10_09.md`: lizard CCN, `case` arm and `else if`
counts per function; subjects switched on in 4+ places; files with 3+ constant-returning
`switch self` blocks. Start from it. Read only the files you pick from it (plus callees you
must follow; list them).

## Classify every candidate you examine into exactly one shape
1. **Leave it.** A single exhaustive switch over an enum that matches on ASSOCIATED VALUES,
   is a state machine, or is the one place a decision is made. This is good Swift; the
   compiler's exhaustiveness is worth keeping. Say so; do not churn it. Error enums stay enums.
2. **One table, keep the enum.** N parallel `switch self` computed properties returning
   constants → ONE `var info: Info { switch self … }` (a struct of the attributes), when
   callers pattern-match on the cases, or the enum is `Codable`/`CaseIterable`/persisted.
3. **Data, not control flow.** The cases carry no associated values, nobody switches on them
   for behaviour, they are identity + attributes → a struct with `static let` instances and
   required init arguments (the `MediaFileOperationKind` shape). Note the cost: `CaseIterable`
   becomes an explicit `all` list plus a sensor test.
4. **Behaviour dispatch.** The SAME subject is switched on in several places to choose what to
   DO → a protocol with one conforming type per case (C++: abstract base + virtual), so each
   case's behaviour lives in one place. Count the switch sites.
5. **Ordered rules.** A long `if / else if` ladder over CONDITIONS (not cases) → an ordered
   array of rule values `(matches, produce)` evaluated first-match-wins, with an oracle test
   over the old ladder's outputs. (This is the verdict cloud N1007-D already reached for Hallie, in
   `docs/reviews/cloud/N1007-D-Hallie-rewrite-eval.md`; cite it rather than re-arguing.)
6. **Parser.** CLI `parse` / argument switches → a declarative option table, or Swift
   ArgumentParser (NOT a dependency today; a new package needs Rick's OK, so say so).

## Banned (Rick's "no CCN gimmicks" rule)
No closure dictionaries keyed by case (they lose exhaustiveness and hide control flow), no
`step1/step2` helper chunking, no widening access to split a function, no `default:` added to
silence exhaustiveness. A proposal only counts if it is better design WITHOUT the CCN number.

## Priority order (stop where the time box ends; list the rest under "Not covered")
1. Data-risk folders first (see `docs/guides/source_layout.md`): `MediaOps/`, `Archive/`,
   `ArchiveAngel/`, `Steward/`, `Catalog/` (incl. `deleteConfirmedJunk`, `DeleteDuplicatesJob.init`,
   `ArchiveAngelJob.prepare`, `ArchiveAngelScorer+Rules.floorFires`, `VerifyVideoRules.noteFragment`).
2. The constant-table files (`PersonFinderTypes.swift`: 14 parallel switches,
   `VolumeStatusEnums+Presentation.swift`, `AnalyzeCyclers.swift`, `TranscodePreset.swift`, …).
3. The most-switched subjects (`kind`: 82 sites, `status`, `outcome`, `state`, `phase`):
   which TYPES are these, and is any one type switched on for behaviour in 4+ places?
4. Hallie (`HallieTurnExecutor.execute`, `HallieLineageQuestion.answer`,
   `PronunciationVariations.*`): brief notes only; N1007-D covered Hallie's design.

## Report body
- **Top 15 table**, ranked by payoff (design clarity × how often the code changes × risk):
  rank · symbol · file:line · CCN · shape (1–6) · switch sites for this subject · data-risk? ·
  effort (S/M/L).
- **For each of the top 8:** a 5–15 line Swift sketch of the new shape; one line saying it in
  C++ terms (Rick reads C++); the guarantee the old code gave (exhaustiveness, ordering,
  defaults) and how the new shape keeps it; the pinning/sensor test; expected CCN after; what
  could break (callers, persisted raw values, accessibility ids, log strings).
- **"Leave it" list:** at least 5 high-CCN switches you judged GOOD as they are, with one line
  why each, so the refactor nights don't churn them.
- **Batching proposal:** group the accepted items into refactor batches by folder (the nightly
  refactor runs one folder per night), data-risk batches flagged for a codex pass.

Header per README rule 4; for this brief, "Finding count" = number of refactor candidates in the
top 15, REAL = shapes 2–6 you would do, NOISE = the leave-it list.
