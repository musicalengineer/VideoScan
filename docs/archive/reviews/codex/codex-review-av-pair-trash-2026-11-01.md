# Codex review — Delete Selected Files: whole recovered A/V pair groups

- Range: `9d6ca34b..feat/trash-av-pair-groups`
- Credits spent: unavailable
- Tokens: 132541
- Finding count: 7
- Verdict: fix — the group gate permits avoidable splits, can move an unchecked path, and can conceal a real SPLIT.
- Run: 2026-11-02T01:43:48Z (cycle #191, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 7  
Verdict: fix — the group gate permits avoidable splits, can move an unchecked path, and can conceal a real SPLIT.

The regression recipes below are **not executed RED tests**. Xcode exited 74 because the read-only sandbox denied cache, DerivedData, and package writes; **0 tests ran**. Your supplied green results remain separate evidence.

1. **P1 — A stale selected sibling can move a different file from the one checked.**  
   [VideoScanModel+TrashSelection.swift:268](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:268), [CatalogTrashGroupTurns.swift:231](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogTrashGroupTurns.swift:231).  
   Reproduce with selected `[V, staleA]`, while the catalog contains `[V, liveA]`: `staleA` and `liveA` share an ID but have different paths. Resolution captures `liveA`’s identity; `targets` retains `staleA`. The turn validates `liveA`, then moves `staleA.fullPath`. That path has no disk-check entry, which returns `nil`; an acknowledged only-copy warning allows it through.  
   **Regression:** confirm and execute this stale selection with distinct fixture files. Assert zero moves; currently V and the unchecked old A path can move while live A stays.

2. **P1 — Fresh groups with unconfirmed membership are identified but not stopped.**  
   [VideoScanModel+TrashSelection.swift:260](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:260).  
   Confirm `[V, A, X]` with V/A paired and X ordinary. Before execution, set `X.pairedWith = V`. The fresh plan correctly discovers `[V, A, X]` and puts it in `unconfirmedGroups`, but that collection only feeds reporting. V/A pass their original group checks and move; X is held. Reporting then calls the expanded group “held” despite two members moving. This happens before execution, outside the accepted mid-batch group-ID exception.  
   **Regression:** assert all three files remain and `succeeded == 0`; the current path permits two moves.

3. **P1 — Relinking can erase a moved outcome and conceal an actual SPLIT.**  
   [VideoScanModel+TrashSelection.swift:468](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:468), [CatalogTrashGroupTurns.swift:175](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogTrashGroupTurns.swift:175).  
   Extend `secondHalfFailsIsASplit`: move V, then relink V’s catalog row before its disk turn returns; make A’s move throw. The routine correctly reports V through its frozen snapshot. The merge matches by object identity, loses that snapshot’s moved outcome, and substitutes a hold. The new group summary therefore reports a failed group with “every half is where it was,” instead of SPLIT.  
   **Regression:** assert one moved file, one SPLIT, and V’s actual Trash location. The underlying merge defect predates this range, but the new group reporting inherits it.

4. **P1 — An already-reserved later half does not hold the first half.**  
   [CatalogTrashGroupTurns.swift:230](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogTrashGroupTurns.swift:230), [VideoScanModel+TrashSelection.swift:599](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:599).  
   Confirm `[V, A]`, both warned as only copies. Reserve A through `RemovalReservations.shared.reserve(a.fullPath)` and retain that reservation throughout execution. V’s lookahead checks identity and copy evidence, but never A’s reservation eligibility. V moves; A’s own `JunkDiskTurn.run` refuses its reservation. Nothing changed between halves, and A’s Trash operation never failed.  
   **Regression:** hold A’s reservation, execute the pair, and assert both remain. Currently the path produces one moved and one held.

5. **P1 — Reverse indexing drops a pending link when an object link exists.**  
   [CatalogPairGroups.swift:76](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogPairGroups.swift:76).  
   Create separate pairs V/A and X/Y; give X both `pairedWith = Y` and `pendingPairedWithID = V.id`. Select only V/A. The reverse index records X→Y through `??`, discarding X→V. Resolution from V therefore admits V/A without discovering the unselected X/Y siblings, although forward resolution follows both link fields.  
   **Regression:** assert this selection is held. Currently it is admitted; execution can move V/A alone. Index both links independently.

6. **P1 — A missing sibling is treated as an intentionally departed sibling.**  
   [CatalogPairGroups.swift:103](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogPairGroups.swift:103).  
   `isPurged` includes `.missing`, not just deliberate removal. Create three halves sharing a group ID without object links—the existing three-half fixture supports this—and mark the third `.missing`. Selecting the two present halves excludes the missing sibling from membership and describes it as already removed. Both present halves can then move.  
   **Regression:** use `.missing(noticedAt:lastSeen:reason:)` on the third half; assert the plan refuses the other two. Currently it admits them. Missing media must remain a blocker.

7. **P1 — Cancellation is honored between halves of an admitted group.**  
   [VideoScanModel+TrashSelection.swift:320](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+TrashSelection.swift:320), [VideoScanModel+JunkDelete.swift:329](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:329).  
   In the first half’s injected operation, move V and pause before returning. Cancel the parent task, then release the operation. The detached disk turn completes successfully; the unchanged per-file loop marks A cancelled without attempting it. Contiguous ordering does not make cancellation respect group boundaries.  
   **Regression:** synchronize this sequence and assert the group is never partially moved. Currently it produces one moved and one cancelled. This is outside the accepted second-move failure exception.

Remaining scoped files/portions:

- `VideoScanModel+JunkDelete.swift` — new ledger/detail plumbing: read, no findings; turn integration covered above.
- `VideoScanModel+MediaLedger.swift` — read, no findings.
- `DeletionAudit.swift` — read, no findings.
- `CatalogTrashConfirmation.swift` — read, no findings.
- `CatalogContent+RelatedHalves.swift` — read, no findings.
- `CatalogRowContextMenu+FileOps.swift`, scoped item — read, no findings.
- `CatalogTrashPairGroupTests.swift` — read, no findings.
- `CatalogTrashPairGroupSensorTests.swift` — read, no findings.

Scope expansion was limited to validating these findings: reservation and copy-proof implementations, marker relay/committer behavior, and `VideoRecord`/removal-marker definitions, plus direct callers. No files or branches changed.

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
