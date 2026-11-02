# Codex review — Delete Selected Files: whole A/V pair groups — closing 2

- Range: `37213a24..feat/trash-av-pair-groups`
- Credits spent: unavailable
- Tokens: 122872
- Finding count: 4
- Verdict: fix — three deterministic split paths remain at `7d8a7f18`, plus one incorrect refusal of a departed sibling’s group.
- Run: 2026-11-02T02:34:43Z (cycle #195, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4  
Verdict: fix — three deterministic split paths remain at `7d8a7f18`, plus one incorrect refusal of a departed sibling’s group.

1. **P1 — A reverse-only link lets one half move outside the group gate.**  
   [CatalogPairGroups.swift:73](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogPairGroups.swift:73), [VideoScanModel+TrashSelection.swift:154](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:154).

   Reproduction: create V/A, retain `A.pairedWith = V`, but clear V’s `pairGroupID`, `pairedWith`, and `pendingPairedWithID`. Select both. The index excludes V; A is held because its link cannot resolve. V is classified as ordinary and moves. No confirmed group exists, so the result also omits SPLIT.

   Proposed regression: `reverseOnlySiblingNeverMoves`; assert the plan admits neither file, then assert zero moves and both paths present. Also test selecting V alone while A remains in the catalog.

2. **P1 — Look-ahead accepts a physical alias that the later half’s own pin rejects.**  
   [VideoScanModel+TrashSelection.swift:616](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:616).

   `isLeaving` reproduces only part of `pin`’s survivor rule: `pin` also rejects the target’s own physical identity.

   Reproduction: V/A are paired; A’s only claimed survivor C is a hardlink to A, carrying matching `archiveFixity` without `contentFixity`. Create the link **before** capturing A’s fixity. The confirmation warns only for V. At V’s turn, C is not reserved and its full hash matches, so look-ahead passes and V moves. At A’s turn, `pin` rejects C because its device/inode equals A’s; A stays.

   Proposed regression: `laterHalfAliasSurvivorHoldsThePair`; assert zero moves and both halves remain. This requires no concurrent change.

3. **P1 — Later halves can vouch for each other before the first half moves.**  
   [VideoScanModel+TrashSelection.swift:442](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:442), [VideoScanModel+TrashSelection.swift:577](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:577).

   Reproduction: group `[V, A1, A2]`, with byte-identical A1/A2 and an outside copy C. Confirm while C survives, so only V receives the only-copy warning. Remove C from the survivor set before execution. At V’s turn, A1 proves against A2 and A2 against A1; neither has been handed on or reserved. V moves. At A1’s turn, its reservation prevents A2 from using it, so the routine holds both audio halves and reports SPLIT.

   Proposed regression: extend `laterHalfBecameOnlyCopyHoldsThePair` with a second identical audio half; assert zero moves and all three paths present. Look-ahead must establish survivors that remain after the group’s planned moves.

4. **P2 — A departed sibling’s lingering link prevents the admitted remainder from moving.**  
   [CatalogTrashGroupTurns.swift:117](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogTrashGroupTurns.swift:117).

   Reproduction: pair V/A, mark A `removedFromCatalog`, then select V. The planner admits `[V]` and the confirmation names A as already removed. At execution, `stillAsPlanned` rejects `V.pairedWith == A` because A is absent from the live member set.

   Proposed regression: extend `departedSibling` through `trashSelectedRecords` using real fixtures; expect V to move. The existing test stops at the planner and sheet.

The proposed regressions above are **not executed RED tests**. My Debug attempt targeting both pair suites exited 74 before test execution because the read-only sandbox denied DerivedData/package-cache writes: **0 tests executed**. The supplied green counts remain prior evidence.

Other scoped files:

- `VideoScanModel+JunkDelete.swift` — read, no findings.
- `VideoScanModel+MediaLedger.swift` — read, no findings.
- `DeletionAudit.swift` — read, no findings.
- `CatalogTrashConfirmation.swift` — read, no findings.
- `CatalogContent+RelatedHalves.swift` — read, no findings.
- `CatalogRowContextMenu+FileOps.swift` — read, no findings.
- `CatalogTrashPairGroupTests.swift` — read, no findings beyond the coverage gaps identified above.
- `CatalogTrashPairGroupSensorTests.swift` — read, no findings.
- `RemovalReservations.swift` — read, no findings.

To substantiate the findings, I additionally inspected the copy-proof helpers and `VideoRecord` linkage/removal property definitions. No files or branches were changed.

## Brief

# Codex review brief — Delete Selected Files takes a whole recovered A/V pair

**Workflow in one sentence (the user's words):** "Select every half of an orphaned Avid clip I judge junk and move them all to the Trash together" (DECISIONS 2026-11-01, "Delete Selected Files may take a whole recovered A/V pair group at once").

**Range:** `9d6ca34b..1be1cb3d` on branch `feat/trash-av-pair-groups` · **Worktree:** `/Users/rickb/dev/VideoScan-wt/trash-pairs`

**In scope (read these and their direct callers; nothing else):**
- `VideoScan/VideoScan/MediaOps/CatalogPairGroups.swift` — `PairHalfIdentity.capture`, `CatalogPairGroups.isHalf`, `Index`, `resolve`, `gate`, `relatedSelection`
- `VideoScan/VideoScan/MediaOps/CatalogTrashGroupTurns.swift` — `CatalogTrashGroupTurns.problem`, `stillAsPlanned`, `settled`, `summary`; `CatalogTrashGroupDiskCheck.problem`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift` — `CatalogTrashPlan.Refusal.alone`, `CatalogTrashPlan.init(assembling:alone:gate:)`, `verdict`, static `catalogTrashPlan(for:catalog:isMasterArchive:isOffline:identity:)`, model `catalogTrashPlan`, `trashSelectedRecords`, `catalogTrashTurnProblem(… groups:pairGate:)`, `catalogTrashLaterHalvesProblem`, `CatalogTrashMoveProofs.problemAhead`, `mergedCatalogTrashResult`, `catalogTrashRefusalOutcome`
- `VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift` — only the new `JunkDeletionGuard.ledgerDetail`, `JunkDeletionResult.groupNotes`, and `applyJunkOutcomes(… ledgerDetail:)`; the turn order in `deleteConfirmedJunk` / `junkTurn` / `JunkDiskTurn.run` is unchanged but is what the group gate relies on
- `VideoScan/VideoScan/Archive/VideoScanModel+MediaLedger.swift` — `ledgerCopyRemoved(… detailFor:)`
- `VideoScan/VideoScan/MediaOps/DeletionAudit.swift` — `finish(note:)`, `finish(_:note:)`
- `VideoScan/VideoScan/Catalog/CatalogTrashConfirmation.swift` — `groupLines`, `title`, `words`
- `VideoScan/VideoScan/Catalog/CatalogContent+RelatedHalves.swift`, the `Select Related Halves` item in `CatalogRowContextMenu+FileOps.swift`
- Tests: `VideoScan/VideoScanTests/CatalogTrashPairGroupTests.swift`, `CatalogTrashPairGroupSensorTests.swift`

**Invariants to attack** (docs/ARCHITECTURE.md §10.3 removal contract, §10.4 ArchiveVolumeProtection):
1. **A group is never split.** Every half of a confirmed pair moves, or none does. Show a sequence (selection order, interleaved ordinary rows, a half held by the routine's own gates — offline, archive, marker-save refusal, reservation held, only-copy proof — a re-correlate, a purge, a relink, a cancel mid-batch) in which one half reaches `MediaTrash.move` and a sibling stays at its path, other than a failure of the second half's own move after the first moved (that case is named SPLIT; check it is never reported as success and that it says where each file is).
2. **A missing, offline or changed sibling holds the whole group** — before anything of it moves. Missing = not in the selection, or not found by the catalog's links (`pairGroupID`, `pairedWith`, `pendingPairedWithID`, reverse links); offline at plan or at the first half's turn; changed = device + inode + size + mtime differ from the plan's lstat, or the catalog row's path / pairGroupID / links changed. Look for a link `resolve` does not follow, a stale `pairedWith` object, a group whose plan-time identity is taken from a different file than the one moved, and the `departed` rule (a purged sibling no longer holds the rest) — is that ever unsafe?
3. **The confirmation is the ceiling.** A group admitted now but not admitted (with the same members) in the plan the person confirmed never moves; a member of a confirmed group that the catalog no longer pairs still meets the group gate. Attack the `confirmed.groups` vs fresh-plan comparison in `trashSelectedRecords`.
4. **Proofs and the single trash call unchanged.** `MediaTrash.move` is still the only `trashItem` call and is reached only through `JunkDiskTurn.perform`; the new disk check runs inside the routine's `RemovalReservations` reservation and before the copy proof; refuse before mutating; the only-copy warning and its deliberate-click rule still apply to halves; a Combine output keeps its refusal and is never a member.
5. **FamilyArchive untouched.** No half on the Master Archive tree or volume (or a Read-only drive) moves, and a sibling there holds the whole group — at plan time and at the turn (archive designated mid-batch).
6. **Truth.** The sheet's group lines and "N files · M pair groups" title come from the plan that is handed to the move; the OUTCOME line's `pair groups: moved · held · failed · split` counts and the per-group held lines match the per-file outcomes; each moved half's `copyTrashed` ledger event carries `pairGroup` and `pairGroupFiles`.

**Evidence already run:** Debug, tree b898f532 (HEAD 1be1cb3d): CatalogTrashPairGroupTests 24 + CatalogTrashPairGroupSensorTests 4 green; the 47 MediaOps/trash suites (CatalogTrash*, Junk*, OneEngine*, DeletionAudit*, RemovalReservation*, CleanupTrash*, ReadOnlyVolume*, ArchiveVolumeProtection*, MediaLedger*, CatalogMenu*, …) 332 passed, 0 failed; `sensor lane GREEN (618 tests)`; run_catalog_tests app 1032 passed / 0 failed, core 0 failed (the lane prints RED on a pre-existing core floor/skip shortfall, Core untouched). Red/green table in the commit message: the probe red on main; two real SPLIT paths (a later half's copy gone in the catalog / rewritten on disk) red on the first cut, closed by asking the later halves' gates and copy proofs at the earlier half's turn; three mutation reds (disk identity check, catalog turn checks, later-half protection check).

**Known and accepted (do not report):**
- A second half whose own Trash move fails (or whose drive drops in the microseconds after the first half moved) leaves the pair split; it is reported as SPLIT with both locations and a put-back instruction, not rolled back automatically (safety-critical Part 1: no rollback machinery the workflow sentence does not need). Rick to rule if he wants automatic Put Back.
- The later halves' disk-level archive/read-only verdict (volume-UUID probe) is asked only at their own turn; at the earlier half's turn the catalog-level `bulkDeleteRefusal` (archive tree + volume, Read-only marks) is asked for them. A volume whose identity flips in the milliseconds between is a SPLIT, named.
- A brand-new row joining an existing `pairGroupID` mid-batch is not re-detected at the turn (the correlator always mints a fresh group id; links of the confirmed members are re-checked).
- "Select Related Halves" reports a hidden half on the console line (the app has no separate Catalog status bar); the confirmation also names the missing sibling.
- Cleanup / Tidy / Delete Junk keep their per-row pair refusal unchanged (out of scope).

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.


---

## Delta for the closing pass (after cycle #191) — range `1be1cb3d..HEAD of feat/trash-av-pair-groups`

Cycle #191 returned fix, 7 × P1. All seven are closed in the branch head commit, each by the regression Codex proposed, run RED on 1be1cb3d first (red/green table in the commit message). Please re-attack the same six invariants, starting with these closures:

- **F1 stale sibling:** `CatalogPairGroups.resolve` now starts from the catalog's own row; `gate` holds a pair whose selected row's path differs from the catalog row's; `CatalogTrashGroupTurns.problem` refuses a target whose `fullPath` is not `g.paths[k]`. Test: `staleSelectedSiblingNeverMoves`.
- **F2 unconfirmed membership:** `trashSelectedRecords` calls `groupTurns.holdGroups(notIn: plan.groups, …)`, so every confirmed pair the fresh plan sees with other members is stopped before any turn; summary dedupes it. Test: `unconfirmedMembershipHoldsTheGroup`.
- **F3 relink hid SPLIT:** `mergedCatalogTrashResult(… targets:routine:)` matches by position and keeps the routine's reported record. This also changes the ⌘⌫ result for non-pair rows (the pre-existing defect Codex named). Test: `relinkDoesNotHideASplit`.
- **F4 reserved later half:** `CatalogTrashGroupDiskCheck.problem` asks `RemovalReservations.shared.isReserved` for every later half. Test: `reservedLaterHalfHoldsTheGroup`.
- **F5 reverse pending link:** `Index.pointingAt` indexes `pairedWith` and `pendingPairedWithID` separately. Test: `reversePendingLinkIsFollowed`.
- **F6 missing ≠ departed:** only `inTrash` / `removedFromCatalog` markers depart; `.missing` (or no marker) goes into `Resolution.missingOnDisk` and holds the pair. Test: `missingSiblingHoldsTheGroup`.
- **F7 cancel between halves:** new `JunkDeletionGuard.mayCancelBefore` (the shared routine asks it before honouring `Task.isCancelled`); ⌘⌫ answers `groupTurns.mayCancel(before:)`. Test: `cancelBetweenHalvesNeverSplits`.

Additional files now in scope: none beyond the list above (the routine change is one line in `VideoScanModel+JunkDelete.swift`, `deleteConfirmedJunk`).

Evidence (Debug, tree fb87e8db): pair suites 35 passed; the 47 MediaOps/trash suites 339 passed, 0 failed; `sensor lane GREEN (618 tests)`; manifest validate 0 errors; run_catalog_tests app 1039 passed / 0 failed, core 0 failed (RED only on the pre-existing core floor/skip rule).

Still accepted (unchanged): the second half's own Trash failure after the first moved is a named SPLIT; the reservation and protection look-ahead is a check, not a hold, so a reservation taken in the microseconds between the halves' turns is a named SPLIT.


---

## Delta after the closing cycle #194 — range `37213a24..HEAD`

#194 returned fix (2 × P1, 1 × P2). All three closed in one commit, each with Codex's proposed regression run RED on 37213a24 first:

- **F1 reserved survivor of a later half:** `CatalogTrashMoveProofs.problemAhead` uses the move's own survivor rule — copies for which `RemovalReservations.shared.isLeaving` is true (the condition `pin` refuses) do not count; none left → hold. Test `laterHalfReservedSurvivorHoldsThePair`. This is a check, not a hold (no reentrant reservations): a reservation taken in the microseconds between the halves' turns stays a named SPLIT.
- **F2 marker-save refusal:** the turn's refusals before its disk half are one list in `VideoScanModel+JunkDelete.swift` — `junkTurnOfflineRefusal` + `junkTurnVerdict` (Master Archive / Read only / `CatalogMarkerRelay.saveRefusal`). `junkTurn` runs exactly those; `junkTurnWouldRefuse` (the same two) is what `catalogTrashLaterHalvesProblem` asks of every live later half. Sensor `lookAheadUsesTheTurnsRefusalList`. Test `laterHalfMarkerRefusalHoldsTheGroup` (SQLite scene, write hold, a same-path clone of V selected).
- **F3 SPLIT location:** `CatalogTrashGroupTurns.location(planned:now:)` — the current catalog path at report time, "(relinked from …)", "not found there now". Test `relinkedLaterHalfReportsItsCurrentLocation`.

Now in scope as well: `junkTurn`, `junkTurnOfflineRefusal`, `junkTurnWouldRefuse`, `junkTurnVerdict` in `VideoScanModel+JunkDelete.swift`; `RemovalReservations.isLeaving`.

Evidence (Debug, tree 3b21348c): pair suites 39 passed; 47 MediaOps/trash suites + CatalogMarkerVetoTests 345 passed, 0 failed; `sensor lane GREEN (619 tests)`; manifest validate 0 errors.
