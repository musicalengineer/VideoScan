Brief: C01 | Source: main@13ec3533 | Wall clock: 5 | Files read: 20
Finding count: 2 (REAL 2 / NEEDS-MAC 0 / NOISE 0)
Verdict: The steward has no delete route of its own, and every rule-2 decision is checked again live by the job. One shown-vs-done gap remains: when scan targets are nested, the card and the planner disagree about which drive a file is on. The DeviceID sweep is clean, apart from a sensor that does not cover one of the six sites.

# C01: the content steward's route to deletion, and the DeviceID sweep

Run as a local Claude Code session (macOS worktree), read-only. No source,
test or project file was changed.

## Files read

In scope (read in full): `Steward/StewardPaneView.swift`, `Steward/StewardCardView.swift`,
`Steward/StewardCaseBuilder.swift`, `Steward/StewardEvidence.swift`,
`Steward/VideoScanModel+Steward.swift`, `MediaOps/DeleteDuplicatesFlow.swift`,
`VideoScanCore/DeviceID.swift`. I read only parts of `Steward/StewardWords.swift` and
`Steward/StewardCase.swift`. I checked `StewardEvents.swift` and `StewardSkipStore.swift`
only by grep, looking for any filesystem or disposition write (see "Not covered").

Callees I followed to settle findings (only the relevant functions):
- `MediaOps/VideoScanModel+Duplicates.swift`: `authorizeDuplicateDeletion`,
  `duplicateDeletionSelection`, `volumesWithDeletableDuplicates`, `keepersByGroupID`,
  `volumeRoot(for:)`
- `MediaOps/DuplicateDetector.swift`: `reelectKeepersDetached`, to check that each group has one keeper
- `Catalog/TriageView.swift`: `reviewFromSteward`
- `ArchiveAngel/Seams/AppConformances.swift`: `showInCatalog(focus:label:)`
- `Volumes/VolumeDashboard.swift`: `normalizedRoot`, `isUnder`
- `Analyze/AnalyzeCoverage.swift`: `volumeFacts`
- DeviceID sweep (repo-wide grep, as the brief allows): `MediaOps/DeleteDuplicatesDrives.swift`,
  `MediaOps/TranscodeDestination.swift`, `VideoScanCore/ContentFixity.swift`,
  `VideoScanTests/DeleteDuplicatesCodex258Round2Tests.swift` and `Round3Tests.swift` (the
  sensor)

## Invariant results

1. **The steward's only route to removal is `DeleteDuplicatesFlow`. HOLDS.** I grepped all 9
   Steward files. None of them calls remove, trash, move, unlink, rename, replace or write,
   and none assigns a disposition. The card actions:
   - Show in Catalog and Review copies go through `showInCatalog`, which sets focus and
     clears the selection.
   - Review below goes through `reviewFromSteward`, which filters the Triage table and sets
     `selectedIDs = []`.
   - Open footage group opens a sheet.
   - Compare starts `startFootageSpectrum`, which is read-only.
   - Skip and Bring back write to UserDefaults only.
   - Delete opens the shared picker → forecast → `startDeleteDuplicates`.
2. **What a card shows as staying matches what the planner keeps. Mostly holds; see C01-F1.**
   The keeper is the stored `.keep` record. The detector leaves one per group, and the job
   checks the keeper again live in `authorizeDuplicateDeletion`. The per-copy proof calls the
   planner's own functions. The gap is the drive-root rule.
3. **Rule 2 cannot sweep in a protected or person-decided clip. HOLDS.** The off-main gate
   can be stale by the time a card is drawn, but it never authorizes anything. Before each
   copy is removed, `authorizeDuplicateDeletion` asks `bulkDeleteRefusal` (archive tree,
   archive drive, Read-only) and `duplicateDeletionHoldRule` (Angel, promoted copy) again,
   live. A stale gate can only make a card describe a copy wrongly. It cannot cause a delete.
   Junk and event cards never select anything (see 1).
4. **DeviceID. CLEAN in production.** There are six `DeviceID.from` sites:
   ArchivePromoteEngine:139, DeleteDuplicatesDrives:209 and :329, PartialFileNaming:127,
   SignatureVerification:992 and ContentFixity:240. The other `st_dev` uses compare raw
   `dev_t` with raw `dev_t` (PartialFileNaming:484, ContentFixity:233), so there is no
   conversion that could mismatch. `TranscodeDestination.isSameVolume` compares two
   `.systemNumber` NSNumbers from the same API and never meets a DeviceID value. Stamps
   (ContentFixity) and live lookups (DeleteDuplicatesDrives) convert the same way, so the
   "same drive" comparisons agree. The remaining `UInt64(x.st_dev)` uses are in tests only, on
   the temp folder, `/` and home (Round2Tests:251, Round3Tests:207,
   PhysicalDriveTests:254–255). Those are positive on any real volume, so they are not findings.

## Findings

### C01-F1: on nested scan targets, a copy the card shows as "left alone" is deleted by the run it offers
- **Severity:** P2 (shown vs. done; the survival rule still applies, so no copy is lost without proven survivors)
- **Class:** REAL
- **Symbol:** `StewardCaseBuilder.driveRoot(of:scanRoots:)`, StewardCaseBuilder.swift:787. It
  is used by `StewardCaseBuilder.reclaimGroupCases` (:457–486) and disagrees with
  `VideoScanModel.duplicateDeletionSelection(onVolume:)` (VideoScanModel+Duplicates.swift:1162),
  `authorizeDuplicateDeletion` (:665) and `volumeRoot(for:)` (:1261).
- **The mismatch:** for paths outside `/Volumes`, the steward assigns a file to the LONGEST
  scan root that contains it. The planner does not ask which root a file is on. It asks
  whether the keeper's path is inside the drive being cleaned
  (`PathScope.contains(keeper.fullPath, within: volumePath)`). The menu's `volumeRoot(for:)`
  takes the FIRST scan target that matches, in list order. The header comment at :786 says
  the two give the same answer; with nested targets they do not.
- **Scenario:**
  - Scan targets are outer `/Users/u` (listed first) and inner `/Users/u/Movies`. CatalogAudit
    already treats nested targets as a real catalog state.
  - "Also clean up working copies" is OFF.
  - The keeper is `/Users/u/Movies/a.mov`. A high-confidence extra copy is `/Users/u/b.mov`.
  - Steward: the keeper's root is `/Users/u/Movies` and the copy's is `/Users/u`. They differ,
    so the copy gets standing `.keeperOnAnotherDrive` and the card says *"Left alone for now —
    the copy to keep is on another drive."* The action's target drive is `/Users/u`.
  - `volumesWithDeletableDuplicates` gives `/Users/u` for both files, so the drive is offered.
    `offeredPath` is therefore non-nil and **"Delete duplicates on u…" is enabled** on this
    card.
  - The run on `/Users/u`: `duplicateDeletionSelection` finds the keeper inside `/Users/u` and
    makes the copy a same-volume target. `authorizeDuplicateDeletion` agrees at :665. The copy
    goes to the Trash or is deleted, depending on what the survival rule allows.
  - Result: the person was told this copy stays, pressed the card's own button, and the copy
    went.
- **Smallest pinning test:**
  - Set up: a model with scan targets `["/Users/u", "/Users/u/Movies"]`, one group with
    keeper `/Users/u/Movies/a.mov` and extra copy `/Users/u/b.mov` (`.extraCopy`, high), mode
    off.
  - Steward side: build with `StewardCaseBuilder.build(inputs:volumes: volumeFacts(targets)…)`.
    The copy's standing is `.keeperOnAnotherDrive`.
  - Planner side: `model.duplicateDeletionSelection(onVolume: "/Users/u").targets` contains it.
  - Assert they agree: standing `.wouldBeChecked` exactly when the copy is in the selection
    targets. This fails today. It needs no disk and no Mac-only API beyond the app test host.

### C01-F2: the st_dev sensor misses one of the six DeviceID sites
- **Severity:** P3
- **Class:** REAL
- **Symbol:** `DeviceIDSourceSensorTests.noRawStDevConversionInProductionCode`,
  DeleteDuplicatesCodex258Round3Tests.swift:370.
- **Scenario:** the sensor scans four files: DeleteDuplicatesDrives, SignatureVerification,
  ArchivePromoteEngine and PartialFileNaming. It does not scan `VideoScanCore/ContentFixity.swift`.
  ContentFixity:240 builds `FileIdentityStamp.device`, the value that
  `DeleteDuplicatesDrives.volume(device: stamp.device, …)` (:191) compares with live
  `DeviceID.from` values. If ContentFixity:240 went back to `UInt64(info.st_dev)`, the sensor
  would stay green. On a negative device number (a network mount, or devfs on CI), the next
  stamp would trap inside the delete and promote paths. That is the crash 9783f286 fixed.
  Today the code is correct; only the guard has a gap.
- **Smallest pinning test:** add ContentFixity.swift to the sensor. `SourceTree.appCode`
  probably reads only the app target, so it needs a Core variant or a direct read of the file
  path. Check that the new list entry fails if line 240 is changed to `UInt64(info.st_dev)`.

## Considered and dropped (no concrete failing scenario)
- **Keeper chosen differently.** The steward takes `members.first(where: isKeeper)` from
  records that are not hidden. The planner's `keepersByGroupID` takes the last `.keep` from
  all records. These differ only when a group has two `.keep` records, and only the detector
  writes `.keep` (one per group). If the planner's keeper is hidden (set aside, superseded or
  purged), the steward shows no card at all, so it shows nothing wrong. Dropped.
- **Stale rule-2 gate.** Dropped. The job checks it again live for each copy (invariant 3).
- **`deleteCase` left set after a cancelled picker.** It only affects which case a later
  `onStarted` log line names. It never changes what is deleted. Dropped.

## Not covered
- `StewardEvents.swift` (681 lines) and `StewardSkipStore.swift` (175 lines) were checked only
  by grep: no filesystem calls and no disposition writes. Their event logic is out of scope
  (Events lane ranking). The skip store writes UserDefaults only.
