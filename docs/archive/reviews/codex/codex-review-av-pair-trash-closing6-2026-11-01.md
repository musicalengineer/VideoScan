# Codex review — Delete Selected Files: whole A/V pair groups — closing 6 (fingerprint)

- Range: `a6a2dc49..feat/trash-av-pair-groups`
- Credits spent: unavailable
- Tokens: 163378
- Finding count: 2
- Verdict: fix — the ledger loses the Trash destination, and a preserved concurrent marker can still produce a false “moved whole” result.
- Run: 2026-11-02T04:52:21Z (cycle #203, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2
Verdict: fix — the ledger loses the Trash destination, and a preserved concurrent marker can still produce a false “moved whole” result.

Reviewed `a6a2dc49..97647cb2`. Both findings are P1.

1. **The `copyTrashed` ledger event omits the actual Trash path.**  
   [VideoScanModel+JunkDelete.swift:517](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift:517), [VideoScanModel+MediaLedger.swift:124](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/Archive/VideoScanModel+MediaLedger.swift:124).

   `applyJunkOutcomes` passes records to the ledger without their move outcomes. The ledger writes the original `fullPath`, volume, mode and pair details; it never writes the returned Trash destination. When a concurrent marker is preserved, that marker also need not contain the destination. This violates ruling 2’s explicit condition.

   **Reproduction / proposed RED:** extend `outcomeAndLedger`. For each moved item, extract its non-nil outcome `trashPath`, find its `copyTrashed` event, and assert the event contains that destination. This fails even without concurrent mutation. Also cover the preserved-marker case; the destination must come from the move outcome, not the retained marker.

2. **A concurrent `inTrash` marker is mistaken for the routine’s own successful settlement.**  
   [PairMemberFingerprint.swift:50](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/PairMemberFingerprint.swift:50), [CatalogTrashGroupTurns.swift:141](/Users/rickb/dev/VideoScan-wt/trash-pairs/VideoScan/VideoScan/MediaOps/CatalogTrashGroupTurns.swift:141).

   The fingerprint retains only `removal.state`. After a concurrent action stamps an `inTrash` marker with another destination, the new revision check preserves it. Settlement expects `.inTrash`, sees `.inTrash`, and reports “1 moved whole”; `groupNeedsAttention` remains false. The console detects the concurrent write, but the group summary and presenter still report success.

   **Proposed RED**, using the existing helper in `CatalogTrashPairGroupLiveCatalogTests`:

   ```swift
   @Test func concurrentTrashMarkerRequiresAttention() async throws {
       let (result, d) = try await runWithMutation("pgmarkerlocation") {
           _, a, _, _ in
           VideoScanModel.stampRemoval(
               a, .inTrash(movedAt: Date(),
                           trashPath: "/another-trash/A.mxf",
                           reason: .junk))
       }
       defer { d.sb.cleanup() }
       #expect(result.groupNeedsAttention)
       #expect(!result.groupNotes.contains { $0.contains("1 moved whole") })
       #expect(JunkDeletionReport(result).hasNotes)
   }
   ```

   Preserve the concurrent marker as ruled, but carry that detected conflict into the settlement result.

Remaining scoped files:

- `CatalogPairGroups.swift` — read, no findings.
- `VideoScanModel+TrashSelection.swift` — read, no findings.
- `RemovalReservations.swift` — read, no findings.
- `DeletionAudit.swift` — read, no findings.
- `CatalogTrashConfirmation.swift` — read, no findings.
- `CatalogContent+RelatedHalves.swift` — read, no findings.
- `CatalogRowContextMenu+FileOps.swift` — scoped item read, no findings.
- `CatalogTrashPairGroupTests.swift` — read, no findings.
- `CatalogTrashPairGroupIsolationTests.swift` — read, no findings.
- `CatalogTrashPairGroupLiveCatalogTests.swift` — read, no findings.
- `CatalogTrashPairGroupSensorTests.swift` — read, no findings.
- `CatalogTrashPairGroupFixtures.swift` — read, no findings.

No additional unit-splitting path found under the accepted limits. Inspection beyond the named files covered only directly related helpers and presenters needed to trace these behaviors.

**Validation:** no tests executed or files changed; this session’s read-only sandbox prevents Xcode test execution and adding probes. The proposed REDs above are unexecuted; the supplied green counts remain author-provided evidence.

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


## Rulings and accepted limits for this pass
1. DECISIONS 2026-11-01 (pair unit membership at the turn; a change during off-main disk work is an accepted residual PROVIDED the settlement reports it, never as success; rows by id only).
2. Accepted: the settlement walks once after the moves. Accepted: a concurrent marker change is kept, not overwritten, and logged; the ledger event records that the file left the disk and where (the Trash path) — if the Trash path is NOT in the ledger event, that is a finding.
3. The fingerprint carries the member's own state; catalog-level state (write hold, read-only) and other rows' copies are checked live at phase 1 and are not in the settlement comparison — a finding here must show a FILE MOVED that should have been held, not merely a comparison omission.
