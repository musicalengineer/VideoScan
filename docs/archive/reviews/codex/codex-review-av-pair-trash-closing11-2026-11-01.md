# Codex review — Delete Selected Files: whole A/V pair groups — closing 11

- Range: `97b8a6b4..feat/trash-av-pair-groups`
- Credits spent: unavailable
- Tokens: 173461
- Finding count: 0
- Verdict: merge — no qualifying defect found at `807546c2` under the accepted pair-unit and reporting contract.
- Run: 2026-11-02T07:25:09Z (cycle #208, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 0
Verdict: merge — no qualifying defect found at `807546c2` under the accepted pair-unit and reporting contract.

The #207 closure carries warnings through completion, failure, Stop, quit, and suspend. I found no silent unit split, live-row bypass, lost settlement warning, or production ledger path omission.

**Validation:** `git diff --check` passed; worktree unchanged. Executed **0 Swift tests** because this session is read-only. HEAD’s commit records **821 passed, 0 failed, 8 known issues**, plus **623 sensors green**; these were not independently rerun.

Scoped file verdicts, including the later additions:

| File | Verdict |
|---|---|
| `CatalogPairGroups.swift` | read, no findings |
| `CatalogTrashGroupTurns.swift` | read, no findings |
| `PairMemberFingerprint.swift` | read, no findings |
| `VideoScanModel+TrashSelection.swift` | read, no findings |
| `VideoScanModel+JunkDelete.swift` | read, no findings |
| `RemovalReservations.swift` | read, no findings |
| `VideoScanModel+MediaLedger.swift` | read, no findings |
| `DeletionAudit.swift` | read, no findings |
| `CatalogTrashConfirmation.swift` | read, no findings |
| `CatalogContent+RelatedHalves.swift` | read, no findings |
| `CatalogRowContextMenu+FileOps.swift` | read, no findings |
| `TrashWarnings.swift` | read, no findings |
| `JunkDeletionReport.swift` | read, no findings |
| `CleanupTrashJob.swift` | read, no findings |
| `CleanupTrashJobDetailView.swift` | read, no findings |
| `VideoScanModel+PruneApply.swift` | read, no findings |
| `PruneApplyJob.swift` | read, no findings |
| `VideoScanModel+Workbench.swift` | read, no findings |
| `TriageView.swift` | read, no findings |
| `DeleteConfirmedJunkSheet.swift` | read, no findings |
| `VideoScanModel+Duplicates.swift` | read, no findings |
| `DeleteDuplicatesJob.swift` | read, no findings |
| `CatalogTrashPairGroupTests.swift` | read, no findings |
| `CatalogTrashPairGroupIsolationTests.swift` | read, no findings |
| `CatalogTrashPairGroupLiveCatalogTests.swift` | read, no findings |
| `CatalogTrashPairGroupFixtures.swift` | read, no findings |
| `CatalogTrashPairGroupSensorTests.swift` | read, no findings |
| `TrashWarningsDoorTests.swift` | read, no findings |
| `TrashWarningsSensorTests.swift` | read, no findings |
| `TrashLiveRowTests.swift` | read, no findings |
| `DeleteDuplicatesCodex1593Tests.swift` — named Stop/suspend regressions | read, no findings |

Additional reads were limited to direct caller/helper paths and `VideoRecord` decoding/cloning to investigate replacement-revision handling; no finding resulted.

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


---

## Delta after cycle #195 — range `7d8a7f18..5180e62b` (redesign: the pair is one atomic unit)

Four passes each found a new divergence between the look-ahead simulation and the real turn, so the simulation is removed. A confirmed pair is now ONE unit of the one Trash routine:

- `VideoScanModel+JunkDelete.swift` — `deleteConfirmedJunk` walks turns via `JunkTurnUnits.span` (one file, or a whole unit contiguous in the request; a unit member out of place is held, never moved alone). `junkUnitTurn` = phase 1 on the main actor for EVERY member: `junkTurnOfflineRefusal`, `fileGuard.authorize`, `junkTurnVerdict` (the same functions one file's turn runs). Then `JunkDiskTurn.runUnit` off-main, in one synchronous stretch: `RemovalReservations.reserveAll` (all or nothing), each member's `beforeRemoval` (⌘⌫: identity, then the copy proof with real `pin`s), `protectionRefusal`, existence. Any refusal: nothing moved, all held, all released. Phase 2: moves in order through `perform` → `MediaTrash.move`, each preceded by `atTheMove` (identity re-stat) under its own reservation; a refusal/failure after a move leaves the rest held — the one SPLIT. Cancellation is checked only between turns.
- `RemovalReservations.reserveAll` — new batch API: one lock, all-or-nothing, one physical file twice is held. Test `batchReservationIsAllOrNothing`.
- `CatalogTrashGroupTurns.problem` — now only the member's own checks (confirmed whole, the very file proved, row unchanged; links may name members or departed siblings — #195 F4). `activeGroups` feed the units; a stopped group's halves are held one by one.
- `CatalogPairGroups.Index.isGroupMember` — a row a live half links to is a group member even with no pair field (#195 F1); one-sided linkage resolves as unknown and holds; the plan's verdict never lets a gate-seen member fall through to ordinary.
- Removed: `catalogTrashLaterHalvesProblem`, `problemAhead`, `isLeaving`, `junkTurnWouldRefuse`, `mayCancelBefore`, the look-ahead disk check. Sensor `unitRunsTheRealTurn` pins the unit's use of the single-file functions, `reserveAll`, the one `perform`, and the absence of the look-ahead.

Please attack: can any member reach `perform` while another member is unreserved, or after another member's phase-1 refusal? Can two concurrent doors interleave reservations to split a pair? Does `span` ever hand a unit member to the single-file turn? Is the SPLIT report still truthful for every phase-2 stop?

Evidence (Debug, tree f4bb7bd6): pair suites 44 passed (39 + 5 sensor); 47 MediaOps/trash suites + CatalogMarkerVetoTests + ReadOnlyVolumeCodex258Tests: 357 passed, 0 failed; `sensor lane GREEN (618 tests)`; manifest validate 0 errors; run_catalog_tests app 1048 passed / 0 failed, core 0 failed (RED only on the pre-existing core floor/skip rule).


---

## Delta after cycle #197 — range `5180e62b..22db8623` (the live catalog decides membership)

Root of all four #197 findings: membership, departed status and the refusal set came from the plan's snapshot of the selection. Now:

- `VideoScanModel.liveSelection` (TrashSelection) — the plan and the routine work on the catalog's own row by id when it still describes the same file; a copy at another path stays as selected and the pair gate / turn hold it. The routine's marker-save gate, settlement and ledger therefore see live rows (#197 F2, F1).
- `CatalogTrashGroupTurns.problem` — at every member's turn (phase 1 of its unit) the group is resolved AGAIN from the live row fetched by id and the LIVE pair index (every link direction, live removal markers) and must EQUAL the confirmed members; a new, lost or restored member holds the unit, named (#197 F4). `catalogTrashTurnProblem` holds a single file that is in a pair NOW by the live index (#197 F3).
- `CatalogTrashGroupTurns.liveIndex` — cached per batch, rebuilt when `VideoRecord.pairLinkGeneration` (new in Core: a didSet counter on pairedWith / pendingPairedWithID / pairGroupID / combinedFromPairID), `identityGeneration`, the model's mutation revision or the row count changes.
- Sensor (`unitRunsTheRealTurn`): the turn gate reads only the row fetched by id and the live index — never rec.pairGroupID / pairedWith / pendingPairedWithID / removal / isPurged / combinedFromPairID.

Please attack in particular: (a) a catalog change made on the main actor WHILE a unit's disk stretch runs (phase 1b/2 are off-main; nothing re-reads the catalog after phase 1); (b) the live-index cache key — a row replaced by a decoded object (no didSet) with the same count and no mutation-revision bump; (c) `liveSelection` keeping a stale ordinary (non-pair) row at its old path.

Evidence (Debug, tree 110d3ce7): pair suites 48 passed (43 + 5 sensor); 47 MediaOps/trash suites + CatalogMarkerVetoTests + ReadOnlyVolumeCodex258Tests 361 passed, 0 failed; `sensor lane GREEN (618 tests)`; manifest validate 0 errors; VideoScanCore full: 2003 tests, 0 non-timing failures — 9 budget/timing tests failed while an xcodebuild ran beside it and all 115 tests of those 9 suites pass alone; run_catalog_tests app 1052 passed / 0 failed, core 0 failed (RED only on the pre-existing core floor/skip rule).


---

## Delta: the pair-unit contract — range `22db8623..f6e4bd46`

**Contract (DECISIONS 2026-11-01, ARCHITECTURE §10.3):** "A pair unit's membership is decided on the main actor at its turn; a catalog change during its off-main disk work is an accepted residual" — the settlement after the unit reports it in words, never as success; the same live-row rule applies to ordinary rows. Do NOT report the residual itself; DO attack whether the settlement truly reports every such change, and whether any path moves a non-catalog row.

- `VideoScanModel.trashSelectedRecords` → after the routine, one live-catalog pass (`CatalogPairGroups.Index`) and `CatalogPairGroups.linkedOutside(group, in:)`: live rows linked to a moved pair from outside its members (same pairGroupID, a link to a member, a member's link to it). Such a pair goes into `Summary.lateLinked` (never `moved`): alert "N moved while a half was linked to it — see below" + "Linked during the move: … was linked during the move — it keeps its pair protection; check it", console "PAIR CHANGED DURING THE MOVE", OUTCOME "· linked during the move N"; a SPLIT names it too. Test `lateLinkedSiblingIsReported` (a link injected through the file-operation seam after phase 1, before the first move).
- `CatalogTrashGroupTurns.liveIndex` key — includes the model's mutation revision, bumped by EVERY `records` assignment, so a decoded reload is seen. Test `liveIndexFollowsADecodedReload` (green before; red by mutation with the revision removed from the key).
- Ordinary rows: `CatalogTrashPlan.Refusal.changedInCatalog` at plan (a selected copy that is not the catalog's row now) and `record(forID:) !== rec` at the turn. Test `staleOrdinaryCopyIsHeld`.

Evidence (Debug, tree 48884999): pair suites 51 passed (46 + 5 sensor); 47 MediaOps/trash suites + CatalogMarkerVetoTests + ReadOnlyVolumeCodex258Tests 364 passed, 0 failed; `sensor lane GREEN (618 tests)`; manifest validate 0 errors; run_catalog_tests app 1055 passed / 0 failed, core 0 failed (RED only on the pre-existing core floor/skip rule).


---

## Delta after cycle #201 — range `f6e4bd46..HEAD` (the settlement's report)

Contract unchanged (DECISIONS 2026-11-01: a change during a unit's off-main disk work is an accepted residual, reported in words, never as success). #201's three P1s were in the report:

- **F1 outward link:** the settlement now walks with the SAME function as phase 1 — `CatalogPairGroups.resolve(_:in:treatAsLive:)` (the moved rows counted as members); `Index` also holds every row a half links to, so an outward link to a row with no pair fields resolves (one-sided → unknown) and is named. `linkedOutside` removed. Sensor: exactly two `resolve(` walks in `CatalogTrashGroupTurns` (phase 1 `problem`, settlement `changesDuringMove`).
- **F2 member-confined changes:** `CatalogTrashGroupTurns.changesDuringMove` compares each member's full live state with the confirmed snapshot via `drift(of:from:at:moved:)` — path, pairGroupID, object + pending links (now on `Group.pairedWithIDs` / `pendingIDs`), and the removal marker the move should have left (In the Trash if moved, none otherwise).
- **F3 presenter:** `JunkDeletionResult.groupNeedsAttention` → `JunkDeletionReport.hasNotes`, and `JunkDeletionReport.headline` ("Move to Trash — the catalog changed during the move" when nothing stayed) used by `CatalogContent.reportDeleteResult`.
- Test file split, no behaviour change: `CatalogTrashPairGroupTests`, `CatalogTrashPairGroupIsolationTests`, `CatalogTrashPairGroupLiveCatalogTests`, shared `CatalogTrashPairGroupFixtures`.

Evidence (Debug, tree 80423bc9): pair suites 53 passed; 49 MediaOps/trash suites + CatalogMarkerVetoTests + ReadOnlyVolumeCodex258Tests 366 passed, 0 failed; `sensor lane GREEN (618 tests)`; manifest validate 0 errors.


---

## Delta after cycle #202 — range `a6a2dc49..HEAD` (one fingerprint)

Contract unchanged (DECISIONS 2026-11-01). #202's three P1s were each a field the hand-made settlement comparison missed; the fix is the pattern:

- `MediaOps/PairMemberFingerprint.swift` — `PairMemberFingerprint.of(_:model:archiveVolume:)` is THE one builder of what the gate reads about a member (path, pairGroupID, object/pending links, combinedFromPairID, removal marker, setAsideReason, supersededByID, protected [Master Archive / Read only], offline, only-copy evidence). `PairGroupFingerprint.of(_:model:index:treatAsLive:)` adds the walk (joined siblings, `capped`, one-sided, missing on disk). Phase 1 (`CatalogTrashGroupTurns.problem`, first member) snapshots it; `changesDuringMove` builds it again after the moves and compares (`differences(from:)`), moved rows expected In the Trash. A cap always warns; it only limits listed names.
- The gate reads a member only through the fingerprint; sensor: no `live.` field read in the gate, one walk there, both phase 1 and the settlement call `PairGroupFingerprint.of`.
- `VideoScanModel+JunkDelete.applyJunkOutcomes` — detect, then write: if the row's `removalRevision` differs from the one frozen at its turn, the concurrent marker is kept (not overwritten) and logged; the ledger still records the move. Shared by every Trash door.

Attack: a gate input NOT in the fingerprint (e.g. the marker-save gate's catalog state, or a survivor copy's state, which are not member fields — the fingerprint covers the member's own claim only); whether "detect, then write" leaves any door's catalog inconsistent with a file that did move.

Evidence (Debug, tree e13204bb): pair suites all green (52 tests + 5 sensor); 49 MediaOps/trash suites + CatalogMarkerVetoTests + ReadOnlyVolumeCodex258Tests 369 passed, 0 failed; `sensor lane GREEN (618 tests)`; manifest validate 0 errors.


---

## Delta after cycle #203 — range `97647cb2..HEAD` (ledger destination; kept marker inside the fingerprint)

Contract unchanged (DECISIONS 2026-11-01).

- **F1:** `VideoScanModel+JunkDelete.applyJunkOutcomes` records every moved file's returned Trash path and passes it as `MediaLedgerEvent.Detail.trashPath` (new Core key) on its `copyTrashed` event, whatever the row's marker says; with a kept concurrent marker the console line names both the kept marker and the Trash path. Shared by every Trash door. Tests: `outcomeAndLedger` (per-event trashPath), `keptMarkerLedgerCarriesTheRealTrashPath` (real test-host Trash move; the new `trashSelectedRecords(… beforeEachMove:)` test hook, nil in production).
- **F2:** `PairMemberFingerprint` now carries `markerRevision` and `trashPath`; the settlement expects exactly the routine's own stamp (In the Trash, revision + 1, the path the move returned), so a kept marker — even another In-the-Trash one — is "changed during the move" inside the one comparison. `JunkDeletionResult.markerKept` lists kept rows. Test: `concurrentTrashMarkerRequiresAttention` (Codex's own regression).
- `CatalogTrashGroupTurns.summary` reads each unit through a small `UnitOutcome` value (complexity gate; no behaviour change).

Evidence (Debug, tree 9df90420): pair suites 58 tests green (53 + 5 sensor); 49 MediaOps/trash suites + CatalogMarkerVetoTests + ReadOnlyVolumeCodex258Tests 371 passed, 0 failed; VideoScanCore MediaLedger filter green; `sensor lane GREEN (618 tests)`; manifest validate 0 errors; run_catalog_tests app 1062 passed / 0 failed, core 0 failed (RED only on the pre-existing core floor/skip rule).


---

## Delta after cycle #204 — range `3efb62ff..HEAD` (kept marker on any row)

- `JunkDeletionResult.keptMarkerNotes` (routine-written: "<file> kept another action's marker (<state>) — it is in the Trash at <path>; its catalog row was not overwritten") and `carryingWarnings(to:)`, used by both result transforms (`mergedCatalogTrashResult`, `trashFailuresHeld` — which now also keeps the receipt).
- `JunkDeletionReport`: a kept marker makes `hasNotes` true for every door; its notes join the summary; the headline is "the catalog changed during the move" when nothing stayed.
- ⌘⌫ OUTCOME: `Summary.outcomeNote(keptMarkers:)` adds "· kept another action's marker N" (for ordinary rows too).
- Test hook `beforeEachMove` now also reaches a single file's turn (`CatalogTrashGroupDiskCheck.singleFileTestHook`, nil in production).
- Test: `ordinaryKeptMarkerRequiresAttention` (an ordinary row, marker stamped during its REAL test-host Trash move).

Evidence (Debug, tree ade441dc): pair suites 59 green; 49 MediaOps/trash suites + CatalogMarkerVetoTests + ReadOnlyVolumeCodex258Tests 372 passed, 0 failed; `sensor lane GREEN (618 tests)`; manifest validate 0 errors.


---
## Delta after cycle #205 — range `8fd95cb7..HEAD` (every door renders the routine's warnings)
#205's P1 (a kept concurrent marker read as clean success in Cleanup, Prune and Workbench Discard, which consumed only `result.items`) is closed at the boundary, not per door:
- NEW `MediaOps/TrashWarnings.swift` — the ONE presenter of a `JunkDeletionResult`'s settlement warnings (`groupNotes`, `groupNeedsAttention`, `keptMarkerNotes`): `lines`, `needsAttention`, `summaryClause`, `inlineClause`, `outcomeNote` (count + each sentence, which names the Trash path; first 5 listed).
- Every production caller of `deleteConfirmedJunk` passes its result through it in the calling function: ⌘⌫ (`trashSelectedRecords` OUTCOME via `Summary.outcomeNote(warnings:)`), Delete Junk (`trashFrozenJunk` OUTCOME note; the sheet already used JunkDeletionReport), Cleanup (`runFiles` folds each per-file result into `@Published warnings`; subtitle/finished summary + detail view + OUTCOME), Prune (`pruneMove` returns the warnings with the copy's result; `PruneCopyOutcome.warnings` → `PruneApplyOutcome.warnings` → summary and the job row's note), Workbench Discard (`discardWorkbenchResult`: console + OUTCOME; Triage shows the Delete Junk result sheet when `needsAttention`). `JunkDeletionReport` renders through it too.
- Sensor `TrashWarningsSensorTests.everyCallerRendersTheWarnings`: every app source calling `deleteConfirmedJunk(` must be a listed door and contain `TrashWarnings(` in the rest of the calling function; the listed set must equal the found set. Mutation-checked (red with the Cleanup call spelled `TrashWarnings.init(`).
- Delete Duplicates (its own engine): `settleDeletedDuplicate` now detects-then-writes like the routine — a live row whose `removalRevision` differs from the pair-start snapshot keeps its marker; the sentence (same words) goes to the console and, through `keptMarker:`, into the job's summary (`DeleteDuplicatesJob.summaryLine`); its copyTrashed event now carries `Detail.trashPath`.
Tests (red on 8fd95cb7 first): `TrashWarningsDoorTests` — cleanupKeptMarkerRequiresAttention (Codex's regression: real test-host Trash, marker stamped in `proofPassedForTesting`), workbenchKeptMarkerOnOutcome, deleteJunkKeptMarkerOnOutcome, pruneKeptMarkerInSummary, deleteDuplicatesKeepsAConcurrentMarker, deleteDuplicatesSummaryCarriesKeptMarkers.
Please attack: a door that presents a result without the warnings (any path the sensor's "rest of the function" heuristic misses); the Delete Duplicates snapshot (`preAwait` taken at pair start, not at the move) giving a false keep or a missed one; a Cleanup run stopped or failed before `conclude` losing the warnings.
Now in scope: TrashWarnings.swift, CleanupTrashJob.swift (runFiles, conclude), CleanupTrashJobDetailView.swift, VideoScanModel+PruneApply.swift (pruneMove, PruneCopyOutcome, PruneApplyOutcome), PruneApplyJob.swift (runItems loop, noteRow), VideoScanModel+Workbench.swift, TriageView.swift (discardUnderConstruction), DeleteConfirmedJunkSheet.swift (list guard), VideoScanModel+Duplicates.swift (settleDeletedDuplicate, duplicateKeptMarkerNote), DeleteDuplicatesJob.swift (settleRemoved, summaryLine), tests TrashWarningsDoorTests / TrashWarningsSensorTests.


---
## Delta after cycle #206 — range `8f0b3f52..HEAD`
- **F1 (Workbench bypassed the live-row rule) — closed inside the routine.** `VideoScanModel+JunkDelete.swift`: new `junkTurnLiveRowRefusal(rec)` = `record(forID: rec.id) === rec ? nil : .held(changedInCatalogHeldNote)`, asked at every single-file turn (`junkTurn`) and for every unit member in phase 1 (`junkUnitTurn`), on the main actor, right after offline and the door's own `authorize` (whose words, when it refuses, are the friendlier ones) and before the refusal list, reservations and any disk work. A row the catalog lacks, a copy/snapshot, or a row replaced while an earlier file moved is held; its file is never touched. Doors keep their own earlier checks (⌘⌫ plan `changedInCatalog`, Delete Junk `frozenJunkCatalogProblem`, Cleanup `resolve`, Prune `pruneLiveRecord`) as the friendlier refusal. Sensor `TrashLiveRowTests.routineAsksTheLiveRowRule` pins the function, the identity test, and exactly two calls.
- **F2 (Delete Duplicates lost kept markers on Stop / suspend).** `DeleteDuplicatesJob.noteKeptMarker` records each sentence the moment the pair settles — on the job AND in the plan's log (saved with the plan, so a suspended plan carries it); `finishCancelled`, `finishSuspended` and `finish(failed:)` append them (`withKeptMarkers` → `summaryLine`, the TrashWarnings words); the audit's OUTCOME (`auditRemainingAndFinish`) carries `TrashWarnings(keptMarkerNotes:).outcomeNote()` on every terminal path.
Tests (red on 8f0b3f52 first): `TrashLiveRowTests` — workbenchReplacedRowBeforeTurnIsHeld (Codex's repro), bareRoutineHoldsARowTheCatalogLacks, routineAsksTheLiveRowRule; `DeleteDuplicatesJobCodex1593Tests` — deleteDuplicatesStoppedResultCarriesKeptMarker (Stop + discard from `testHookBeforeFinalSave`), deleteDuplicatesSuspendedResultCarriesKeptMarker (resumable Stop during the first copy's Trash operation).
Please attack: any path into the routine whose target is legitimately not the catalog's row (and is now wrongly held); a resumed Delete Duplicates plan's summary (the earlier run's kept markers are in the plan log, not in the resumed job's summary).


---
## Delta after cycle #207 — range `97b8a6b4..HEAD` (every terminal path of every Trash job renders the warnings)
- **Prune (the finding):** each copy's warnings are on `outcome.warnings` as it settles; `PruneApplyJob.presented(_:)` (= `TrashWarnings(keptMarkerNotes:).appended(to:)`) renders them on EVERY terminal line — `finish(success:)`, `finish(failed:)`, `finishCancelled` (Stop and quit both land here). `PruneApplyOutcome.countsLine` is the counts alone; `summary` = countsLine + warnings (log / sheet). Prune has no DeletionAudit; its OUTCOME-equivalent is the `Archived — what next?: <summary>` log line, which carries them.
- **Audit of the other jobs:** Delete Duplicates and Cleanup restructured the same way — one `presented(_:)` renderer per job, applied inside every terminal function (Duplicates: finish(success:), finish(failed:), finishCancelled, finishSuspended; Cleanup: conclude's finished/stopped lines and finish(failed:)), never pre-baked into the line handed to them (so nothing renders twice). ⌘⌫, Delete Junk and Workbench Discard are not MFO jobs: one function call, one return, already pinned by `everyCallerRendersTheWarnings`.
- **Sensor:** `TrashWarningsSensorTests.everyTerminalPathRendersTheWarnings` — in PruneApplyJob, CleanupTrashJob and DeleteDuplicatesJob, every function that sets `state = .finished / .cancelled / .failed` must call `presented(`; the one `presented` must render through TrashWarnings; exemptions only where nothing ran (`dropFromLine`, `refuseToStart`), each checked to still exist. Mutation-checked (red with Prune's finishCancelled unwrapped).
- `TrashWarnings.appended(to:)` added (the inline clause after ` · `).
Test (red on 97b8a6b4 first): `TrashWarningsDoorTests.pruneStoppedResultCarriesKeptMarker(quit:)` — Codex's regression, Stop and quit, the marker stamped and the Stop issued on the main actor from inside the copy's file operation.


## Rulings and accepted limits for this pass
1. DECISIONS 2026-11-01 pair-unit contract (membership at the turn; a change during off-main disk work is accepted PROVIDED it is reported; rows by id, enforced inside the shared routine at every turn).
2. Accepted: the settlement walks once after the moves; catalog-level save state and other rows' copies are checked live at phase 1 and not compared afterwards — a finding there must show a FILE MOVED that should have been held.
3. Every door and every terminal path of every Trash job renders warnings through TrashWarnings (sensors over callers and terminal paths). Accepted UI detail (Rick's call, not a finding): the Prune detail row for a re-marked copy stays green with the warning in its help; the job subtitle, summary and log carry the warning. Accepted: a resumed Delete Duplicates run does not repeat the earlier run's kept markers in its subtitle.
Findings must show a file moved outside the live-row rule, a unit split silently, a changed unit or kept marker reported as clean success in ANY door or terminal state, a warning that reaches no surface the person sees, or a ledger event without the Trash path.
