# Codex review — Delete-safety bundle #258 r3

- Range: `ffea3de9..fix/258-delete-planner-honours-angel`
- Credits spent: unavailable
- Tokens: 184703
- Finding count: 3
- Verdict: block — delayed mount notifications can preserve a phantom second drive, and unchanged cache fingerprints can conceal an Angel hold.
- Run: 2026-10-03T22:49:29Z (cycle #36, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 3
Verdict: block — delayed mount notifications can preserve a phantom second drive, and unchanged cache fingerprints can conceal an Angel hold.

Reviewed `ffea3de9..8103fcdf` through the named worktree; its scoped files are clean. Neither checkout was changed. Findings and proposed red tests below are source-derived; I did not execute Swift tests or mutants in this read-only session. The supplied passing results remain separate evidence.

| Round-2 finding | Verdict |
|---|---|
| R2-1 / F1 | **Closed.** Disk-origin and captured-check Read-only refusals become hold skips without marking Review. Older refused rows are recognized by their notes. The exclusion persists after release/re-acquisition and across resume. Archive refusals and transient archive uncertainty retain baseline behavior; I found no additional no-weakening counterexample. |
| R2-2 / F6 | **Closed.** The boundary obtains today’s Read-only snapshot on main, then checks the current quarantine path physically off-main. A mark arriving afterward falls within the accepted final-check window. That interval has no hard microsecond bound because probes and survivor stats perform I/O. Pause, cancellation, quit and Angel refresh suspend asynchronously; no scoped circular wait found. |
| R2-3 / A4 | **Reopened:** finding 1 below. The original different-volume/cache-reuse reproduction is fixed, but notification delivery still bounds evidence freshness. |
| R2-4 / F10 | **Closed.** Production forecast stats the file; run and forecast follow filesystem symlinks and firmlinks to the same mounted filesystem. Broken or vanished paths supply no forecast drive. Subsequent disappearance can make the forecast stale, but removal uses independently gathered and rechecked evidence. No removal authority comes from the forecast. |

1. **P1 — R2-3 reopened: the same volume can retain its old device identity until notification delivery.**

   The observer advances the generation only when its `.main` callback executes at [VideoScanModel+ArchiveVolumeSnapshot.swift:203](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/VideoScanModel+ArchiveVolumeSnapshot.swift:203). This removes the additional main-actor-task delay; it does not establish ordering between the actual mount change and the disk worker.

   The cache still accepts an unchanged `st_dev | node | UUID` at [DeleteDuplicatesDrives.swift:287](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesDrives.swift:287), and unchanged generation plus reproducing stamps returns the original evidence at [DeleteDuplicatesPlan.swift:478](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:478).

   **Reproduction schedule:** cache volume X under physical-device path P. Re-enumerate its disk through another attachment path; X retains its UUID, and its device number/node are reused. Before the observer runs, gather three surviving copies: one on X receives cached P, while copies on another volume of that same disk receive the current device path Q. Their current file stamps reproduce at final recheck. The unchanged generation preserves two keys and permits permanent deletion despite one physical disk.

   The attachment-path change is an inference from Apple’s implementation: the reported identity is an IOKit service path, rather than a durable disk identifier. [Apple’s DiskArbitration implementation](https://github.com/apple-oss-distributions/DiskArbitration/blob/main/diskarbitrationd/DADisk.c).

   **Synthetic red test:** extend `driveEvidenceGatheredBeforeAMountChangeDoesNotSurviveIt`, immediately **before** its `resetVolumeCache()`:

   ```swift
   // The physical change happened; its notification has not arrived.
   let beforeNotification = DuplicateDrives.$cacheScope.withValue(scope) {
       DuplicateDrives.$lookupOverride.withValue({ _, _ in q }) {
           DuplicateDrives.$identityOverride.withValue(others) {
               DeletionTierFacts.gather(c, digest: fileDigest).recheck()
           }
       }
   }
   #expect(beforeNotification.distinctDriveCount == 1)
   #expect(DeletionTierDecision.decide(
       facts: beforeNotification, preferTrash: false).tier == .trash)
   ```

   Under an isolated schedule with no intervening reset, current code retains cached P and returns permanent. The existing test exercises notification delivery **before** recheck.

   This is evidence cached before the final check, not the accepted check-to-unlink race. Permanent authorization needs fresh topology evidence independent of delayed notifications.

   Other requested checks: production removal facts gathered here carry a nonnil generation; nil seam/manual facts do not enter the scoped production removal route. Reset increments rather than zeroes the counter; UInt64 wrap is not operationally credible. Unknown re-derived identities do not add drives. Missing stamp UUIDs disable the shared local-volume cache but do **not** independently guarantee detection of a volume replacement whose remaining stamp fields reproduce.

2. **P1 — E: an unchanged fingerprint can conceal newly held media indefinitely.**

   [ArchiveAngelPlan.swift:576](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift:576) fingerprints inode, mtime and size. [The cache hit at line 602](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift:602) trusts those fields without reading content or examining ctime.

   **Reproduction:** warm a ready batch containing record A. Rewrite its entry ID to B in place—UUID strings have identical length—and preserve the original nanosecond mtime. The folder name, inode, size and fingerprint remain unchanged. An uncached reading holds B; cached readings continue holding A. With no other façade/live hold for B, deletion can proceed, including permanent deletion when the survivor tier permits it.

   A deterministic regression can reuse the existing buffer fixture:

   ```swift
   var edited = try #require(lastPlan)
   let incoming = UUID()
   edited.entries[0].id = incoming

   let url = edited.planURL
   var before = stat()
   #require(stat(url.path, &before) == 0)
   let fingerprint = ArchiveAngelPlanStore.bufferFingerprint(bufferRoot: root)

   let encoder = JSONEncoder()
   encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
   encoder.dateEncodingStrategy = .iso8601
   let bytes = try encoder.encode(edited)
   #require(bytes.count == Int(before.st_size))

   let handle = try FileHandle(forWritingTo: url)
   try handle.write(contentsOf: bytes)       // Same inode; deliberately in place.
   try handle.close()
   var times = [before.st_atimespec, before.st_mtimespec]
   #require(utimensat(AT_FDCWD, url.path, &times, 0) == 0)

   #expect(ArchiveAngelPlanStore.bufferFingerprint(bufferRoot: root) == fingerprint)
   #expect(ArchiveAngelPlanStore.inFlightRecordIDs(bufferRoot: root).contains(incoming))
   #expect(ArchiveAngelPlanStore.inFlightRecordIDsForHolds(
       bufferRoot: root).contains(incoming)) // Predicted red.
   ```

   Add `import Darwin`. Normal `ArchiveAngelPlanStore.save` uses atomic replacement and avoids this reproduction. The gap requires an in-place writer, timestamp-preserving restoration, or an equivalent same-tick edit on a coarse timestamp filesystem. It is nevertheless a persistent false-negative hold, not a momentary race.

   **The rule is applied fresh on every call:** current time, interruption and live-batch checks are reevaluated. Entry IDs and statuses remain cached, so fresh rule evaluation cannot repair stale plan contents. Adding ctime would catch the demonstrated rewrite; final hold authorization still needs an explicit freshness guarantee.

3. **P2 — G: block comments defeat the new code-only sensors.**

   [SourceTree.swift:111](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScanTests/SourceTree.swift:111) strips `//` comments but retains Swift `/* … */` comments. Consequently, the sensor-only mount mutation can survive: replace the observer’s reset with

   ```swift
   /* DuplicateDrives.resetVolumeCache() */
   ```

   The real reset remains in the later main-actor task, while the sensor still finds its expected text before that task. The directly invoked cache-reset behavior tests do not exercise this observer ordering.

   A small predicted red test:

   ```swift
   #expect(!SourceTree.strippingComments(
       "/* DuplicateDrives.resetVolumeCache() */"
   ).contains("DuplicateDrives.resetVolumeCache()"))
   ```

   Commenting out phase two’s `refusal.leavesAlone` block likewise preserves the sensor strings while reverting its behavior. These are predicted surviving mutations, not executed results. Extend stripping to nested Swift block comments and add behavioral coverage for the admitted sensor-only branches.

**F — multi-store assessment:** yes, selecting one reported store can make overlapping storage count as two drives. For example, stores `{A, B}` reported as A and `{B, C}` reported as C produce different keys despite sharing B. Apple’s implementation stops at the first `IOBlockStorageDevice` ancestor; I could not establish a public DiskArbitration/IOKit key guaranteeing the complete backing-store set across Fusion, CoreStorage and multi-store APFS. **“Documented limit” is the honest outcome**, as MOPS-2 now states. This is separate from notification freshness. [Apple implementation](https://github.com/apple-oss-distributions/DiskArbitration/blob/main/diskarbitrationd/DADisk.c), [published description keys](https://developer.apple.com/documentation/diskarbitration/diskarbitration-constants).

**Scoped sections/changed hunks read, no findings:**

- `VideoScanModel+MasterArchive.swift`
- `ArchiveVolumeProtection.swift`
- `VideoScanModel+Duplicates.swift`
- `DeleteDuplicatesJob.swift` — no independent finding beyond consuming the stale evidence/cache above.
- `ArchiveAngel.swift` — no independent finding beyond consuming the hold cache.
- `docs/practices/invariants/MediaOps.md`
- `DeleteDuplicatesCodex258HoldBoundaryTests.swift`
- `DeleteDuplicatesCodex258TierTests.swift`
- `DeleteDuplicatesPhysicalDriveTests.swift`
- `ReadOnlyVolumeTests.swift`

`VideoScanModel+ArchiveVolumeSnapshot.swift`, `DeleteDuplicatesDrives.swift`, `DeleteDuplicatesPlan.swift`, `ArchiveAngelPlan.swift`, `SourceTree.swift`, and the new round-2 tests were read; their findings or coverage gaps are identified above.

## Brief

Scoped data-risk RE-REVIEW (round 3) — delete-safety bundle (GH #258 + Read-only volumes + two-drives rule), 2026-10-03. Range ffea3de9..fix/258-delete-planner-honours-angel (tip 8103fcdf; fix commit 84e31c12 + a merge of main, docs only). Round 2: docs/reviews/codex/codex-review-delete-safety-bundle-258-r2-2026-10-03.md (block, 4 findings). The branch is NOT checked out in ~/dev/VideoScan: read it with `git diff ffea3de9..fix/258-delete-planner-honours-angel -- <path>`, `git show fix/258-delete-planner-honours-angel:<path>`, or the worktree at .claude/worktrees/agent-ace49c157d541ff27. Do not check out the branch in ~/dev/VideoScan. Do not explore outside the files below. The "no weakening" baseline is still main's behaviour at 8aa4acde.

Files in scope:
- VideoScan/VideoScan/Archive/VideoScanModel+MasterArchive.swift (~720 `BulkDeleteRefusal.leavesAlone`), Archive/ArchiveVolumeProtection.swift (~574 `ArchiveRemovalCheck.refusal`), Archive/VideoScanModel+ArchiveVolumeSnapshot.swift (mount observer moves the generation synchronously)
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift (~235, ~379 final verdict, ~1493 `removalBoundaryHold`), MediaOps/VideoScanModel+Duplicates.swift (~341, ~1261)
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesDrives.swift (~190, ~213 forecast stats the file; ~251–267 cache key `st_dev | device node | volume UUID`, `DuplicateDrives.generation`, `resetVolumeCache()`)
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift (~267 `driveGeneration` recorded by gather, ~338, ~464 `recheck` re-derives drives when the generation moved)
- VideoScan/VideoScan/ArchiveAngel/Prepare/ArchiveAngelPlan.swift + Facade/ArchiveAngel.swift (buffer-reading cache keyed by batch folder names + each plan.json's inode / mtime ns / size)
- docs/practices/invariants/MediaOps.md (MOPS-2 limits)
- Tests: VideoScanTests/DeleteDuplicatesCodex258Round2Tests.swift (new, 10 tests), SourceTree.swift (`appCode(named:)` comment stripper), and the test files that followed API changes

Per round-2 finding, answer "closed" or re-open with a concrete reproduction (file:line; ideally a Swift Testing red test with synthetic data):
R2-1 (F1) — a Read-only (or hold) refusal found on the disk thread or by the captured check in phase two now settles as a HOLD SKIP (row stays .extraCopy, never Review, "left alone" in runScope, never counted for another copy); a plan from an earlier build with such a row stored as refused classifies the same way. Attack: any remaining route by which a retained copy becomes a countable survivor for another copy of the SAME run (other refusal kinds that should also be holds? transient refusals? a hold released and re-acquired mid-run? resume?). Any input where the branch removes what main@8aa4acde would leave/refuse, or unlinks what main would Trash.
R2-2 (F6) — the removal boundary takes TODAY's Read-only snapshot on the main actor, then runs the removal-time check (path, real path, the file's own volume UUID) on the disk thread against the file's path at that moment. Attack: the window between that snapshot and the unlink/trash; a mark made after the snapshot (accepted as the same microsecond-class window as any final check? say so or re-open); the main-actor hop from the disk thread (deadlock/starvation with pause, cancel, stopForQuit, the Angel refresh).
R2-3 (A4) — generation scheme: one process-wide lock-protected counter moved at every run start and synchronously inside the mount/unmount/rename observer; gather records it; `recheck` in the final verdict re-derives every counted copy's device when it has moved and re-decides the tier; the cache key now includes the volume UUID and a volume without a UUID is never cached; a different volume now at a counted copy's path fails that copy's stamp (the stamp carries the volume UUID). Attack: a mount change that does NOT fire the observer before the final verdict reads the counter (ordering between the notification and the disk thread); a counted copy whose stamp lacks a volume UUID; facts built through the test seam store nil generation and are "never re-derived" — can production facts ever have nil; generation wrap or reset; evidence re-derivation that fails (device unknown) → must not ADD a drive.
R2-4 (F10) — the forecast stats the FILE (as the run's stamp does) and asks the same identity function with the resolved path. Attack: forecast ≠ run for file symlinks, directory aliases, broken symlinks, firmlinks, and files that vanish between forecast and run (the run re-decides — confirm the forecast never promises a MORE permissive outcome than the run can deliver in a way that changes what is removed; a forecast that is merely stale is a P3).

Also assess:
E. The Angel buffer-reading cache: can a batch change without changing folder names or any plan.json's inode/mtime(ns)/size (in-place rewrite with identical size within the same mtime tick; atomic replace keeps a new inode — fine)? If the cache can serve a stale reading, a copy newly placed in a batch could be removed — rate it. The hold rule "is applied fresh on every call" — confirm.
F. Multi-store volumes (Fusion / CoreStorage / multi-store APFS) are DOCUMENTED as a limit in MOPS-2 rather than detected (keyed by the one store DiskArbitration reports). State whether that can make two copies on overlapping physical storage count as two drives; if yes and you can name a reliable public signal (DiskArbitration / IOKit key) to detect it, give it; otherwise confirm "documented limit" is the honest outcome.
G. Mutations you believe would survive (three are admitted to be caught by source sensors only: phase two's captured check holding instead of refusing; the forecast statting the file rather than its folder; the generation moving synchronously in the mount observer).

Known and accepted (do not report): hardware RAID = one device, its redundancy is not a second drive; two disks in one enclosure presenting as two devices count as two; two network shares backed by one server disk count as two (cannot be seen); the microsecond window between any final check and unlink(2)/trash; Catalog Rename and add-a-file verbs not blocked on a Read-only drive (ruling pending); the Angel's extraCopy exclusion is a switchable policy default pinned by a guard test; two-real-drives cases go through the identity seam; SwiftLint length/complexity warnings; the gauntlet manifest is not regenerated; older sensors elsewhere still read raw source (only the new ones strip comments).

Evidence already run (Debug, by suite, counts confirmed nonzero): final full run on the merged tree 8103fcdf — 983 Swift Testing tests / 172 suites + 13 XCTest (4 skipped), 0 failures (every *Sensor*/*Boundary* suite; delete, read-only, steward, angel, triage suites; PruneApplyTests; WorkbenchActionsTests; SourceTreeTests with 2 pre-existing known issues). Round-2 fixes: 5 finding tests red first (on ffea3de9 + two behaviour-neutral seams); 17 mutants all red. Buffer cache: 2,000 readings of 50 batches × 100 rows in 5.7 s Debug (budget 20 s), one decode; a changed/added/removed batch is seen at the next reading.

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: "closed"/re-opened per R2-1..R2-4; findings for E–G ranked by data-loss risk; "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.

## Closed

Closed by `rick-ruling-2026-10-04` at 2026-10-04T15:48:57Z. Merged per Rick's ruling (best effort, not perfection); residual edge cases tracked in GH #268.
