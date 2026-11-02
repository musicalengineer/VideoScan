# Codex review — Delete Selected Files: whole A/V pair groups — closing

- Range: `1be1cb3d..feat/trash-av-pair-groups`
- Credits spent: unavailable
- Tokens: 137571
- Finding count: 3
- Verdict: fix — Two deterministic gate omissions can still split a pair, and SPLIT reporting can name an incorrect recovery location.
- Run: 2026-11-02T02:12:35Z (cycle #194, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: fix — Two deterministic gate omissions can still split a pair, and SPLIT reporting can name an incorrect recovery location.

Reviewed `1be1cb3d..37213a24`. The seven closure fixes address their supplied reproductions, but these cases remain:

1. **P1 — A later half’s already-reserved surviving copy does not hold the group.**  
   [VideoScanModel+TrashSelection.swift:607](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:607)

   `problemAhead` checks content proof without checking whether its surviving copies can be pinned. The later half’s actual `problemAtTheMove` rejects those copies when another removal has reserved them.

   **Reproduction:** Create pair V/A, with A’s sole surviving copy C. Confirm `[V, A]`, warning only for V. Reserve C **before starting the batch**, keeping that reservation throughout. V’s look-ahead accepts C and V moves; A’s own proof cannot pin C, so A stays. No reservation changes between turns and neither Trash move fails.

   **Regression:** Adapt `laterHalfCopyNotProvenHoldsThePair`: reserve `aCopy.fullPath` instead of rewriting its bytes. Assert `result.succeeded == 0` and both halves remain. The current code path produces one moved half and SPLIT.

   The look-ahead needs the same survivor-eligibility rules as the actual proof.

2. **P1 — The later-half look-ahead omits the marker-save refusal.**  
   [VideoScanModel+TrashSelection.swift:426](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:426)

   The look-ahead asks protection and confirmation/copy gates, but never `CatalogMarkerRelay.saveRefusal(for:)`. The routine asks that separately at each half’s turn.

   **Reproduction:** In a SQLite-backed fixture, keep live V/A in the model but select `[V.snapshotClone(), A]`, preserving V’s ID, path and pair metadata. Confirm both, then take the catalog write hold before starting. The same-path clone passes the group checks. The committer’s ownership predicate excludes that clone, so its marker gate returns nil and V moves. Live A’s marker gate sees the existing write hold and refuses. The pair splits without any mid-batch state change.

   **Regression:** `laterHalfMarkerRefusalHoldsTheGroup`, combining the pair fixture with the SQLite/write-hold setup from `CatalogMarkerVetoTests`. First assert that the clone’s marker refusal is nil and live A’s is nonnil; then assert zero moves and both paths intact.

   Ask the marker-save gate for the canonical live later halves before moving the first.

3. **P2 — SPLIT reporting claims a relinked sibling remained at its obsolete path.**  
   [CatalogTrashGroupTurns.swift:205](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogTrashGroupTurns.swift:205)

   Every unmoved member is reported as “stayed at `g.paths[i]`,” irrespective of the outcome’s record or whether that path still exists.

   **Reproduction:** Confirm V/A. In V’s move seam, move V, relocate A to another fixture path and update A’s catalog path. A’s turn correctly refuses the changed path, but the SPLIT report says A stayed at its original, now nonexistent location.

   **Regression:** `relinkedLaterHalfReportsItsCurrentLocation`: assert SPLIT remains reported, the old A path is absent, and the recovery text does not claim A stayed there. Report the evidenced current location, or explicitly identify the old path as last known.

Files read with no additional findings:

- `CatalogPairGroups.swift` — read, no findings.
- `VideoScanModel+JunkDelete.swift` — read, no findings.
- `VideoScanModel+MediaLedger.swift` — read, no findings.
- `DeletionAudit.swift` — read, no findings.
- `CatalogTrashConfirmation.swift` — read, no findings.
- `CatalogContent+RelatedHalves.swift` — read, no findings.
- `CatalogRowContextMenu+FileOps.swift` — read, no findings.
- `CatalogTrashPairGroupTests.swift` — read, no findings beyond the coverage gaps above.
- `CatalogTrashPairGroupSensorTests.swift` — read, no findings.

**Validation:** Attempted both named suites in Debug; `xcodebuild` exited 74 before executing tests because the read-only sandbox denied DerivedData/package writes. The regression recipes above are **not executed RED tests**. Supplied test counts were not independently reproduced.

Scope expansion was limited to direct dependencies/callers and the marker ownership, committer and SQLite test setup needed to substantiate findings 1–2. Worktree remains clean.

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
