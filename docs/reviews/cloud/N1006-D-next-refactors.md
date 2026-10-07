Brief: N1006-D-next-refactors | Source: main@c86b926 | Wall clock: 30 | Files read: 10
Finding count: 4 (REAL 3 / NEEDS-MAC 1 / NOISE 0)
Verdict: Both functions can be split without behaviour change, but each has guards with no test that fails if the guard is removed. Write those 9 pinning tests first. Two small defects should be fixed in their own commits, never inside a "pure move" commit.

## Scope and method

- Scope (from the row): `Archive/CopyFamilyAssessor.swift` (`assess`) and `Catalog/CatalogAudit.swift` (`run`). The Catalog table was not covered (R1 is handling it tonight).
- Callees and tests I followed to settle guards: `CatalogAuditFixer.apply` (it consumes the `fix` payloads that `run` produces), `VideoScanModel.deleteScanTarget`, `pfActiveRecords`, `LifecycleStage` raw values, `ArchiveAngelShowCopies.walk`/`projectInputs`/`request` (the only production caller of `assess`), `ArchiveAngelShowCopiesView` (uses of `recommended*`), `CatalogAuditTests`, `CopyFamilyAssessorTests` and `CopyFamilyExternalLineageTests`.
- Step 0: `origin/metrics` has no `metrics/complexity.jsonl` at this SHA (only `history`, `static_analysis`, `coverage`, …). So there was no nightly top-15 or new-offender list to start from. The numbers below are tonight's, from lizard 1.22.

### Measurements (lizard, CCN > 15 or length > 80)

| Function | CCN | NLOC | Length | Note |
|---|---|---|---|---|
| `CatalogAuditor.run` | **66** | 165 | 189 | one pass + 10 checks, all inline |
| `CopyFamilyAssessor.assess` | **57** | 193 | 254 | 8 phases inline, 1 nested func, 1 local struct |
| `CopyFamilyAssessor.codecClass` | 16 | 15 | 17 | table-like; leave it (just over the line) |

Neither file is over 800 lines (664 and 372).

### Debt found besides complexity

- **Dead code:** `CopyFamilyAssessor.signatureKey` has no callers in the app or the tests (grep). It is also a *second answer* to "are these the same encoding?" (see F4).
- **Duplicated literals:** `run` hard-codes `["Trashed", "Deleted"]`. These duplicate `LifecycleStage.trashed/.deletedPermanently.rawValue` (`VideoScanCore/ArchiveModels.swift:29,34`). The fixer uses the enum, so the two halves of one check spell the stage set two different ways.
- **Duplicated predicate inside `assess`:** "unreadable" (`!isPlayable || streamType == .ffprobeFailed || .noStreams`) is written twice, at `CopyFamilyAssessor.swift:316` and `:355`. "Duration off" is also written twice (`:318`, `:356`). Both are worth one helper each.
- **Duplicated "proven byte-identical" test:** it appears 3 times: `recommendedInstance` (`:616-617`), the caution at `:489-490`, and `CopyRepresentation.instancesByteIdentical`. They agree today. One helper on `[CopyFamilyInput]` would stop them drifting apart.
- **Elapsed time in `run`** (`CatalogAudit.swift:368-369`) reads `ContinuousClock.now` twice: attoseconds from one reading and seconds from the other. See F3.

---

## Findings

### N1006-D-next-refactors-F1: P3 · REAL · `CatalogAuditor.run` (empty-targets) + `CatalogAuditFixer.apply(.deleteEmptyTargets)` · CatalogAudit.swift:275, CatalogAuditFixer.swift:79-85

"Empty" is counted from **active** records only, because of the `guard r.isActive` at `:213`. `pfActiveRecords` excludes set-aside and superseded records, which are still in the catalog. So a non-retired target whose records are all set aside (Tidy) or superseded counts as `perTarget == 0`, and the audit offers **"Delete from list"**. The plan sentence (`CatalogAudit.swift:96`) says: "No catalog records are affected (there are none under them)." That is false: they are there. `deleteScanTarget` keeps the records but throws away the target's metadata (notes, capacity, media tech, purchase year, retire fields; see its doc comment), and the records become orphans.

In the same area: the fixer does not check emptiness again when it applies the fix. The sheet runs the audit when it opens (`CatalogAuditSheet.swift:40`) and the fix is applied later. If a scan adds records to that target in between, the user still gets "Delete from list" (NEEDS-MAC to confirm that ordering can happen in practice. The set-aside case above is pure logic and is REAL).

- Scenario: target `/Volumes/T` (not retired) has 3 records, all `isSetAside`. Audit → "Empty drives" warns, with fix `.deleteEmptyTargets(["/Volumes/T"])` → Apply → the target's notes and retire metadata are gone, and 3 records are now unplaced.
- Pinning test (fails today): build `CatalogAuditInputs` with a target and one record under it with `isActive: false, isPurged: false`. Expect "Empty drives" to be `.pass` (or at least `fix == nil`). The fix belongs in `project`/`run`: count *non-purged* records per target for the empty check, and keep active-only counts for the totals.
- Ordering: fix this **after** the split (step A3 below), in its own commit, because it changes behaviour.

### N1006-D-next-refactors-F2: P3 · REAL · `CatalogAuditor.run` (Totals reconcile) · CatalogAudit.swift:240

The formula `sumPerTarget + orphans − doubleClaimed.count == active` assumes each record has at most 2 claims. A record under 3 nested targets adds 3 to `sumPerTarget`, but `doubleClaimed` subtracts only 1.

- Scenario: targets `/V`, `/V/A`, `/V/A/B`, and one active record at `/V/A/B/x.mov` → 3 + 0 − 1 = 2 ≠ 1 → **FAIL "Arithmetic does not close"**, when the real problem is only a nesting warning. Overall status becomes FAIL.
- Pinning test: exactly that input. Expect "Totals reconcile" to be `.warn`, not `.fail`. Fix: subtract `Σ(claims − 1)` instead of `doubleClaimed.count` (keep a running `extraClaims` in the tally).

### N1006-D-next-refactors-F3: P3 · REAL · `CatalogAuditor.run` (duration) · CatalogAudit.swift:368-369

`(now − clock).components.attoseconds` and `(now − clock).components.seconds` come from two separate clock readings. If a whole-second boundary falls between the two reads, the result is off by up to about 1 s (for example 0.9999 + 1 → 1.9999 s, when the real value is about 1.0 s). It is cosmetic: the value only appears in the report text. Fix: `let elapsed = ContinuousClock.now - clock` once, and use the existing `Duration`→seconds helper or `Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds)/1e18`. No pinning test is needed beyond "duration ≥ 0". Do it in the split commit, because it is a one-liner that does not change any test-visible behaviour.

### N1006-D-next-refactors-F4: P3 · NEEDS-MAC · `CopyFamilyAssessor.modalDuration` (tie-break) · CopyFamilyAssessor.swift:553

When the duration buckets tie on count, `max(by:)` with `$0.key > $1.key` picks the **shortest** duration as the family reference. With one complete copy and one playable truncated copy of the same encoding (different content hashes), the truncated copy becomes the reference. The complete copy is then grouped as "— duration differs" and becomes `unconfirmedVariant`, with the reason "…truncated, extended, or a different cut". If the truncated copy has no `derivedFrom`, it wins `originalSource` with the reason "not derived from any other copy", and Show Copies puts the crown on it.

- Scenario: `assess([dv(3604 s, hash A), dv(1800 s, hash B)])` → `recommendedRepresentation.durationSeconds == 1800`.
- Why NEEDS-MAC: the pure-function result is certain. Whether such a pair actually ends up in one family depends on `ArchiveAngelShowCopies.walk`: it joins through duplicate group, lineage, archive links or a shared content hash, and a truncated copy would need to share a duplicate group with the full one. Run that check against the real catalog on the Mac.
- Pinning test (fails today): the scenario above. Expect the 3604 s copy to be recommended, or `recommendedRepresentation == nil` with a caution. Rick has to decide which, because it is a rule-1 policy choice. The safer default is to break ties toward the **longer** duration: a complete recording is never worse than a truncated one.
- Related (debt, not a defect): `assess` groups by the *human* `signature()`, not by `signatureKey()`. `signature` drops `bitDepth` and folds every interlaced field order into "interlaced". So an 8-bit and a 10-bit HEVC (same everything else) are one representation. The dead `signatureKey` shows someone meant the stricter key. **Do not switch keys during the refactor.** Delete `signatureKey` (dead), and raise the stricter key with Rick as a separate change if he wants it.

---

## Guards and the test that must go red: the gate before any move

✅ = an existing test goes red if the guard line is deleted. ❌ = no test does, so **write it first**.

### CatalogAuditor.run (+ project / fixer edges it feeds)

| # | Guard (line) | Pinned by | |
|---|---|---|---|
| A1 | purged counts as staged unless the stage is Trashed (`:207`) | `cleanCatalogPassesEverything` (purged+Trashed passes) | ✅ |
| A2 | …or Deleted (`:207`) | none | ❌ add: purged + `"Deleted"` → "Purged records" `.pass` |
| A3 | dangling pair: missing partner (`:210`) | `eachDefectIsCaught` (ghost) | ✅ |
| A4 | dangling pair: purged partner (`:210`) | `fixesEachDeterministicDefect…` (a↔purged) | ✅ |
| A5 | `guard r.isActive` (`:213`) | `cleanCatalogPassesEverything` (`activeRecords == 3`) | ✅ |
| A6 | orphans / double-claim (`:232-233`) | `eachDefectIsCaught`, `actionableFindingsCarryDestinations` | ✅ |
| A7 | reconcile closes with ≤2 claims (`:240`) | `eachDefectIsCaught` (`.warn`) | ✅ (and F2 test for 3 claims) |
| A8 | empty targets exclude **retired** (`:275`) | none. The fixer has its own `!t.isRetired`, but the finding and its plan would still name the drive | ❌ add: retired target with 0 records → "Empty drives" `.pass`, `fix == nil` |
| A9 | dup groups: "members disagree" arm (`:303`) | none (the existing test only hits the claimed≠members arm) | ❌ add: 2 members in a group claiming 2 and 3 → `.warn`, `fix` lists the group |
| A10 | dup-group focus lists **active** members only (`:309`) | none | ❌ add: a purged member of a stale group is not in `focusRecords.ids` |
| A11 | Master Archive check skipped when the index is nil (`:343`) | none | ❌ add: `archiveIndexPromoted: nil` → no finding with that check name |
| A12 | per-drive cache: cold (nil) is skipped, not a mismatch (`:356`) | none (`eachDefectIsCaught` gives `/Volumes/A/sub` nil, but A=99 already warns) | ❌ add: all targets cold → `.pass` with "warming" in the headline |
| A13 | **finding order + check names** (the sheet and the tests key on `check`) | indirectly only | ❌ add: `run(clean).findings.map(\.check) == [the 10 names in order]` (9 when the index is nil) |
| A14 | 100k under 1 s | `hundredThousandUnderBudget` | ✅ |
| A15 | `project`: `pairedWithID` falls back to `pendingPairedWithID` (`:167`) | none | ❌ (`@MainActor` model test; optional for this refactor because `project` does not move) |

### CopyFamilyAssessor.assess

| # | Guard (line) | Pinned by | |
|---|---|---|---|
| C1 | empty input → no actions (`:291`) | `emptyAndSingle` | ✅ |
| C2 | unreadable copies split out of their encoding group (`:316`) | `damagedCopyNeverRecommended` | ✅ |
| C3 | duration-off copies split out (`:318`) | `truncatedCopyIsUnconfirmed` | ✅ |
| C4 | `idToSig` uses `uniqueKeysWithValues`, which **traps** on duplicate ids (`:333`) | guarded one level up: `walk` keys `family` by id. No test feeds duplicates | ⚠️ keep the caller's guarantee, or switch to `uniquingKeysWith` in the split (behaviour-neutral for unique input) |
| C5 | a native root with external lineage drops to presumed (`:378`) | `CopyFamilyExternalLineageTests` ×3 | ✅ |
| C6 | presumed election order: others derive from it › lossless › earliest stamp › sig (`:392-401`) | `noNativeCodecPicksLineageRootNotBiggest` covers only the first key | ❌ add: two roots, neither a derivation target; the FFV1 one beats the H.264 one; with no lossless, the earlier `embeddedCreationDate` wins |
| C7 | "More than one native encoding" caution (`:385`) | negative only (`aGenuineNativeRootBeatsANativeOrphan`) | ❌ add: DV-in-.dv plus DV-in-.mov, both roots → caution present |
| C8 | repaired-copy role requires derivation from the original's sig, or nil (`:430-432`) | `balancedDerivative…`, `cleanUpRepair…` | ✅ |
| C9 | preservation companion only when derived from the original (`:443`) | `ffv1WithProvenanceIsACompanion` + Clip case | ✅ |
| C10 | `.unknown` codec: derived → access, else unconfirmed (`:461`) | none | ❌ add: one codec string that is unknown, with and without `derivedFrom` |
| C11 | unproven-equivalence caution (`:490`) | `preparedAnchorBeats…` / `provenIdentical…` | ✅ |
| C12 | audio caution chain: repaired › damaged › unverified (`:507-515`) | repaired ✅, unverified ✅ (Clip case); **damaged-without-repair** ❌ | ❌ add: original with `audio: "damaged"` and no repair → `verifyAudioFirst` first, caution mentions "reported a problem" |
| C13 | actions: companion › create-companion only if not presumed (`:532-533`) | `ffv1WithProvenance…`, `emptyAndSingle`; the presumed branch ❌ | ❌ add: presumed original → no `createAndPromoteCompanion` |
| C14 | representation sort: role rank then signature (`:468`) | headline counts only | ❌ fold into C-snapshot below |
| C15 | rule-6 instance election | `rule6Orders…`, evidence suite | ✅ |
| C16 | 2,000 members under 300 ms | `scaleTwoThousandMembers` | ✅ |

**Snapshot sensor (recommended for both).** Before the move, add one golden test per function that runs ~6 fixed families (or audit inputs) and asserts the **whole** output struct (`CopyFamilyAssessment` and `CatalogAuditReport` are `Equatable`; set `startedAt`/`duration` to fixed values, and use fixed UUIDs). That one test catches reordering, wording drift and any changed role, all of which the targeted tests above miss. Then do the split, and the snapshot must stay green with **zero** edits to it.

---

## Ranked refactor plan

### 1. `CatalogAuditor.run` → tally + one function per check. Size **M**, risk **low**

It is pure, has no I/O, a 100k budget test already exists, and the output is `Equatable`.

- **A0 (tests first):** add A2, A8–A13 and the audit snapshot. Commit them. Green on main.
- **A1 (pure move):** pull the single loop out into `static func tally(_ inputs:, roots:) -> AuditTally` (a struct holding perTarget/bytes, orphans, doubleClaimed, badSizes, purgedButStaged, groupMembers/claims/mismatch, promoted, dangling, active, activeBytes). Keep it **one pass** (the scale dimension). Then add one `static func check…(_ t: AuditTally, _ inputs:) -> CatalogAuditFinding?` per check (10 of them; the Master Archive one returns nil when the index is nil). `run` becomes `[checkTotals, checkOrphans, …].compactMap { $0(t, inputs) }` in today's order. Replace the `["Trashed","Deleted"]` literal with the `LifecycleStage` raw values. Fix F3 here. Each `check` will have a CCN under 6. Expected `run` CCN is about 3.
- **A2 (gate):** the snapshot and every existing audit test pass with no edits. The 100k test is still under its budget.
- **A3 (behaviour fixes, separate commits, each with its own test first):** F2 (extra-claims arithmetic), then F1 (count non-purged records for the empty check, and make `CatalogAuditFixer.apply(.deleteEmptyTargets)` re-check emptiness against `model.records` before deleting). F1 touches a list-delete path, so give it a qa look. The records are not touched, so it does not need codex under the spend policy.
- Not in scope: `project` (`@MainActor`, CCN is fine) and the fixer, apart from the F1 re-check.

### 2. `CopyFamilyAssessor.assess` → phases. Size **M/L**, risk **medium**

It feeds the Show Copies Keep/Promote decision. The rules are lexicographic, so the order of the code *is* the spec.

- **B0 (tests first):** add C6, C7, C10, C12 (damaged branch), C13 (presumed branch) and the assessor snapshot (about 6 families: the Clip 01 case, a presumed root, external lineage, repaired + companion, damaged + truncated, unknown codec). Commit, green.
- **B1 (helpers, pure move):** add `isUnreadable(_:)`, `isDurationOff(_:ref:)` and `provenIdentical(_:)`, and use them at the 6 duplicated sites. Delete the dead `signatureKey`.
- **B2 (phases, pure move):** keep one private `Draft` type at file scope. Then:
  - `makeDrafts(inputs, ref) -> [Draft]` (`:314-369`)
  - `electOriginal(drafts) -> (index, role, reason, cautions)` (`:372-414`)
  - `assignRole(draft, i, original, drafts, ref) -> (role, reason, caution?)` (`:418-467`). This removes the `continue` special case: the repaired branch just returns.
  - `cautionsForOriginal(...)` (`:486-516`, which returns `audioNeedsWork`)
  - `actions(rec, reps, audioNeedsWork)` (`:519-535`)

  `assess` then reads as the 8 rule steps in order. Keep the caution **append order** exactly as it is today, because the snapshot pins it. Expected CCN is ≤ 12 for each piece.
- **B3 (gate):** the snapshot plus the full Copy family / Show Copies / Recommendations suites, with no edits. The 2,000-member test still passes under 300 ms.
- **B4 (Rick decides):** the F4 tie-break, as a separate commit after the split, plus the pinning test. Do not touch the grouping key (see F4 "Related").

### 3. Shared: one stage set for "terminal lifecycle". Size **S**

Add `LifecycleStage.isTerminal` (trashed, deletedPermanently) in VideoScanCore and use it in `run` and `CatalogAuditFixer.apply(.setPurgedStages)`. That gives one answer to one question. Pin it with A2.

### 4. `codecClass`. Size **S**, optional

CCN 16, just over the line. If anything, turn the prefix rules into a table. It is fully pinned by `cameraAVCHDIsNative`, so leave it unless the ratchet complains.

### Backlog (one line each)
- `CatalogAuditReport.text`: inline pluralisation is repeated about 12 times across the audit and assessor. A `plural(n, "drive")` helper would shrink both.
- `composeSummary` hand-rolls pluralisation the same way, so it would use the same helper.
- `CatalogAuditFix.plan` for `.deleteEmptyTargets` joins *every* path into one sentence, with no cap the way `examples` has.

## Not covered
- `ArchiveAngelShowCopies.walk`: whether a full copy and a truncated copy can share a family (decides how bad F4 is). Needs the Mac catalog.
- `CatalogAuditSheet` timing between opening and Apply (the F1 stale-report case). Needs the Mac.
- Ledger: I did not edit `LEDGER.md` (one-report rule). Manager: please add the row `N1006-D-next-refactors | 10-06 | … | 3/1/0 | … | cloud/N1006-D-next-refactors`.
