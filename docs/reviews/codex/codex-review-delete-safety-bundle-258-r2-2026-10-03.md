# Codex review — Delete-safety bundle #258 r2

- Range: `4c616916..fix/258-delete-planner-honours-angel`
- Credits spent: unavailable
- Tokens: 235910
- Finding count: 4
- Verdict: block — Read-only holds can still permit removal or upgrade another copy to permanent deletion, and stale drive evidence can survive cache invalidation.
- Run: 2026-10-03T22:01:29Z (cycle #35, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 4
Verdict: block — Read-only holds can still permit removal or upgrade another copy to permanent deletion, and stale drive evidence can survive cache invalidation.

Reviewed the scoped branch changes through `ffea3de9`; scoped production code is unchanged from `117d4f70`. Main and the worktree were untouched. These are source-derived reproductions. I did not execute new Swift tests or mutants in this read-only session; the supplied passing-test evidence remains separate.

1. **P1 — F1 reopened: a disk-origin Read-only refusal becomes a countable survivor.**

   [DeleteDuplicatesJob.swift:230](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:230) converts a nontransient Read-only refusal into ordinary `.refused`. [Settlement:1519](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:1519) marks the record Review. [DeleteDuplicatesPlan.swift:761](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:761) consequently puts it in `decided`, and [the survivor rule:381](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/VideoScanModel+Duplicates.swift:381) counts it by sibling rules.

   **Reproduction:** K, H and A contain identical bytes on V; R is a verified Review sibling on another physical device. Catalog V through an alias, and mark H’s canonical folder Read only. The string gates miss H; the worker’s physical check catches it. Order the planned rows H, X, A, where X belongs to an unrelated family. X ensures A’s dispatch captures H’s settled status rather than an earlier pending snapshot.

   | Outcome | Main `8aa4acde` | Branch |
   |---|---|---|
   | H | Trash; K + R remain | Refused, retained, changed to Review |
   | A | Trash; K + R remain | Permanent; K + H + R counted |

   This violates both no weakening and the explicit exclusion of rows retained for Read-only protection. The same classification occurs when the captured removal check catches Read-only protection in phase two.

   **Regression test:** exercise the worker’s Read-only refusal, settle it, then gather A through `plan.runScope`. Assert H remains `.extraCopy`, its row is a hold skip, and A counts only K + R and earns Trash. The present canonical-path hold fixtures do not exercise this route.

2. **P1 — F6 reopened: a late mark is missed through another alias or an identity-only match.**

   [VideoScanModel+Duplicates.swift:337](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/VideoScanModel+Duplicates.swift:337) asks the live string-only `readOnlyVolumeRefusal`. The UUID/realpath check uses `item.archiveCheck`, captured before the pair began at [DeleteDuplicatesJob.swift:1036](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift:1036).

   **Reproduction:** catalog the duplicate and keeper through alias L to V. Start with no Read-only marks. Block the duplicate’s phase-two reread, mark canonical V Read only, then release the read. The captured check contains no mark; the live check sees path L outside the mark’s stored prefixes. Removal proceeds although a fresh `verdictAtRemoval` would refuse it.

   A proposed red test, placed inside the existing hold-boundary suite, pins the missing live identity check without requiring another real drive:

   ```swift
   @Test func aLateIdentityMarkStopsTheRemovalBoundary() async {
       let rig = makeRig("late_identity")
       defer { rig.cleanup() }
       rig.model.masterArchive = nil
       rig.model.scanTargets = []
       let copy = rig.copies[0]
       let ask = DeleteDuplicatesJob.removalBoundaryHold(
           model: rig.model, recordID: copy.id, path: copy.fullPath)

       let target = scanTarget("/Volumes/TestMarked")
       target.readOnlyMark = VolumeReadOnlyMark(
           markedAt: .distantPast, volumeUUID: "TEST-U")
       rig.model.scanTargets = [target]

       let fresh = MasterArchiveDesignation.$volumeUUIDProbe
           .withValue({ _ in "TEST-U" }) {
               rig.model.archiveRemovalCheck()
           }
       #expect(fresh?.refusal(forPath: copy.fullPath) != nil)
       #expect(await Task.detached { ask() }.value != nil)
       // Current boundary answer: nil.
   }
   ```

   The boundary needs today’s Read-only snapshot followed by its removal-time identity check on the disk thread.

3. **P1 — A4: delayed mount invalidation can leave a phantom second drive in the final facts.**

   [DeleteDuplicatesDrives.swift:233](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesDrives.swift:233) caches by `st_dev|node`. Mount invalidation reaches that cache through a main-actor task at [VideoScanModel+ArchiveVolumeSnapshot.swift:205](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/Archive/VideoScanModel+ArchiveVolumeSnapshot.swift:205). Already-built resolver memos and tier facts have no invalidation generation. [DeletionTierFacts.recheck:453](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift:453) returns the original drive evidence whenever file stamps reproduce.

   **Reproduction schedule:** cache mounted volume X as physical device P. Unmount X; mount a volume on device Q that reuses X’s `st_dev` and node. Before the queued invalidation runs, gather a family whose three survivors now all reside on Q. The reused volume receives cached key P; the others receive Q. Deliver invalidation before removal. All gathered file stamps still reproduce, so the final verdict retains two drives and permanently deletes the duplicate.

   This is a logical cache race despite the lock: clearing the cache does not revoke evidence obtained before clearing it.

   **Synthetic red test:** use `VolumeCache` to seed P under the reused key, gather actual unchanged fixture files using Q for the other copies and the stale cached P for the reused volume, clear the cache, then recheck. Expected final tier: Trash. Current result: permanent. Add a production cache/lookup seam to test the complete invalidation schedule.

4. **P2 — F10 reopened: forecast uses the parent volume for a symlinked file.**

   [DeleteDuplicatesDrives.swift:164](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesDrives.swift:164) stats the parent folder for forecast, whereas gather resolves the stat’ed file. The forecast calls that folder-based route at [DeleteDuplicatesForecast.swift:443](/Users/rickb/dev/VideoScan/.claude/worktrees/agent-ace49c157d541ff27/VideoScan/VideoScan/MediaOps/DeleteDuplicatesForecast.swift:443).

   **Reproduction:** K and verified sibling S1 are on A. Verified sibling S2 is cataloged as `A/test_link.mov`, a file symlink to a distinct file on B. The duplicate being cleaned is an ordinary file on A. Forecast assigns every survivor A and predicts Trash; gather resolves S2 onto B and earns permanent deletion. Reverse the placement for the opposite mismatch.

   The current alias fixture links a **directory**. The identity override also answers before the parent-stat route, masking this distinction. Pin a symlinked sibling file across two synthetic mounted identities.

| Round-1 finding | Round-2 verdict |
|---|---|
| F1 — no weakening | **Reopened:** finding 1 |
| F2 — alias/custom mount mark | **Closed:** mark creation retains resolved location and mounted-volume identity |
| F3 — import identity | **Closed:** an existing mark is retained intact |
| F4 — provisional folder mark | **Closed:** removal check matches UUID plus subpath |
| F5 — mid-batch Junk Delete/Trash mark | **Closed:** snapshot is requested per file and checked physically |
| F6 — phase-two hold/mark | **Reopened:** finding 2; Angel hold handling itself is closed |
| F7 — Prepare hand-over/disk truth/generation | **Closed:** hand-over and numbered publication cover the reported gaps |
| F8 — mixed UUID/device keys | **Closed:** production gather no longer mixes those key namespaces |
| F9 — image/unidentified volume | **Closed:** neither adds a drive |
| F10 — forecast drive equality | **Reopened:** finding 4 |
| F11 — second-drive sibling read | **Closed:** prover, reservation, forecast and Steward use the revised rule |

**A–D assessment beyond those findings:**

- **A — physical devices:** ordinary partitions and single-store APFS volumes follow the same device path. Digest collisions merge keys, so they only deny permanent deletion. Missing/empty local device paths become `.unknown`; the `dev:` physical fallback is exercised through the test seam. Cache access/reset is locked and reset occurs at run start; finding 3 prevents certifying remount safety.
  
  **Fusion, CoreStorage and multi-store APFS remain uncertified.** Apple’s published implementation selects the first ancestor conforming to `IOBlockStorageDevice` and records its path; it does not return the complete backing-store set. Inferring disjoint physical storage from one such path is therefore unsupported for overlapping multi-store layouts. [Apple DiskArbitration source](https://github.com/apple-oss-distributions/DiskArbitration/blob/main/diskarbitrationd/DADisk.c).
  
  **Network limitation accepted explicitly:** server/share is a logical proxy. Two shares backed by the same server disk can count as two drives; this code cannot see their backend storage. That limits the physical-independence promise.

- **B — bulk verbs:** Workbench Discard’s per-file physical check is correct. Junk Delete’s scoped loop is correct. I cannot certify the implementations of `JunkDeleteAction`, Prune Apply, Transcode or the publishing engine; the scoped sensor checks call-site text, and the publisher test supplies its check directly.

- **C — concurrency:** no scoped deadlock found. Pause/cancel/`stopForQuit` do not synchronously join workers; draining and quit helpers suspend asynchronously. Angel refresh runs off-main. This does not certify an outside-scope caller that blocks the main actor. Buffer reading costs approximately **O(rows × total buffered entries)** across turn and removal checks. It has no demonstrated scale budget here; slow buffer I/O can delay progress and cancellation, although I found no refresh-induced logical starvation.

- **D — regressions:** additive optional fields preserve older-plan decoding; resumed pending rows gather fresh facts. Ledger keys, row-log structure and log paths remain unchanged; reasons gain device/volume wording. No weakening of the Master Archive volume rule found. A verified copy on another Read-only drive still receives ordinary sibling standing. Finding 1 also affects resumed plans carrying a disk-origin Read-only refusal.

**Mutations I believe could survive the supplied coverage, not executed here:**

- Remove the device-node component from the production cache key: the cache unit test supplies keys itself.
- Leave cache clearing intact but omit invalidation of already-gathered drive evidence.
- Break an outside-scope bulk-verb connection while retaining the sensor’s expected text in a comment.
- Preserve directory-alias handling while misclassifying file symlinks through the forecast’s parent memo.

**Scoped changes read, no findings:**

`DeleteDuplicatesSiblingProof.swift`; `VideoScanModel+JunkDelete.swift`; `VideoScanModel+Workbench.swift`; `ReadOnlyVolumeProtection.swift`; `ArchiveVolumeProtection.swift`; `VideoScanModel+MasterArchive.swift`; `ScanTargetPersistence.swift`; `BundleModels.swift`; `ArchiveAngel.swift`; `ArchiveAngelJob.swift`; `StewardEvidence.swift`; `docs/practices/invariants/MediaOps.md`.

**Tests read, no findings in their existing assertions:** `DeleteDuplicatesCodex258TierTests.swift`, `ReadOnlyVolumeCodex258Tests.swift`, `DeleteDuplicatesCodex258HoldBoundaryTests.swift`, `DeleteDuplicatesPhysicalDriveTests.swift`, and the edited `DeleteDuplicatesAngelHoldTests.swift`, `DeleteDuplicatesTwoDrivesTests.swift`, `StewardRulesTests.swift`, `FixityStampVolumeIdentityTests.swift`. Their missing boundary combinations are identified above.

## Brief

Scoped data-risk RE-REVIEW (round 2) — delete-safety bundle (GH #258 + Read-only volumes + two-drives rule), 2026-10-03. Range 4c616916..fix/258-delete-planner-honours-angel (tip ffea3de9; code under test 117d4f70). Round 1: docs/reviews/codex/codex-review-delete-safety-bundle-258-2026-10-03.md (block, 11 findings) — the branch's copy of that file carries a "Findings closed" table. The branch is NOT checked out in ~/dev/VideoScan (main stays on main for the 2 AM nightly): read it with `git diff 4c616916..fix/258-delete-planner-honours-angel -- <path>`, `git show fix/258-delete-planner-honours-angel:<path>`, or the worktree at .claude/worktrees/agent-ace49c157d541ff27. Do not check out the branch in ~/dev/VideoScan. Do not explore outside the files below. For "no weakening" the baseline is still main's behaviour at 8aa4acde.

Files in scope:
- VideoScan/VideoScan/MediaOps/VideoScanModel+Duplicates.swift — duplicateSurvivorStandingRule(in:) (~374), duplicateDeletionHoldRule, duplicateDeletionSelection, authorizeDuplicateDeletion, removal-boundary hold (~335)
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesPlan.swift — runScope (~724), DeletionTierFacts (gather, counted drives), DeletionTierDecision (earnsPermanent, decide, reason text with drives)
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesDrives.swift (new) — the drive key: statfs f_mntfromname → DiskArbitration kDADiskDescriptionDevicePathKey (physical device), model/protocol → disk image; network share = server+share; unknown never adds a drive; process-wide cache keyed by st_dev + device node, emptied at run start and on mount/unmount/rename; test seam DuplicateDrives.identityOverride
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesJob.swift — final verdict (~379), removalBoundaryHold (~1472), per-copy disk re-read of Angel batches (~929), drive reservation for sibling reads (~784), the DispatchQueue.main.sync hop from the disk thread
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesSiblingProof.swift — worthReading (~130, ~197)
- VideoScan/VideoScan/MediaOps/DeleteDuplicatesForecast.swift — drive keys via the same function (~442, ~276)
- VideoScan/VideoScan/MediaOps/VideoScanModel+JunkDelete.swift (~308, per-file re-ask), VideoScan/VideoScan/Catalog/VideoScanModel+Workbench.swift (Discard asks ArchiveRemovalCheck.bulkRefusal(forPath:) per file)
- VideoScan/VideoScan/Archive/ReadOnlyVolumeProtection.swift — readOnlyMark(forPath:) (~492), parts(of:) (~140), make (~186), UUID+subpath matching in the provisional snapshot (~273); ArchiveVolumeProtection.swift, VideoScanModel+ArchiveVolumeSnapshot.swift, VideoScanModel+MasterArchive.swift
- VideoScan/VideoScan/Volumes/ScanTargetPersistence.swift (~326: an import never changes an existing mark's identity), App/BundleModels.swift (additive resolvedPath / mountPoint)
- VideoScan/VideoScan/ArchiveAngel/Facade/ArchiveAngel.swift (~521–552: hand-over of held ids, generation-numbered buffer readings), ArchiveAngel/Prepare/ArchiveAngelJob.swift (~67)
- VideoScan/VideoScan/Steward/StewardEvidence.swift — the steward's proof through the same survivor-standing and drive functions
- docs/practices/invariants/MediaOps.md (MOPS-2)
- Tests: VideoScanTests/DeleteDuplicatesCodex258TierTests.swift, ReadOnlyVolumeCodex258Tests.swift, DeleteDuplicatesCodex258HoldBoundaryTests.swift, DeleteDuplicatesPhysicalDriveTests.swift, and the edited DeleteDuplicatesAngelHoldTests / DeleteDuplicatesTwoDrivesTests / StewardRulesTests / FixityStampVolumeIdentityTests

Per round-1 finding, answer "closed" or re-open with a concrete reproduction (file:line; ideally a Swift Testing red test with synthetic data):
F1 (no weakening via held copies) — the rule as now stated: while the run cleaning drive V decides one copy, another family member is NEVER counted when it is (a) a row of this run still to be decided, (b) a row this run settled by leaving it alone for a hold or Read-only mark, (c) an extra copy on V that is not a row of this run (held, on a Read-only folder, or never planned). Everything else counts by main's sibling rules. Attack it: any input where the branch removes what main@8aa4acde would leave/refuse, or unlinks what main would Trash. Note the stated strictness: an extra on V that appeared after planning is not counted.
F2 alias / custom mount point; F3 import vs existing mark identity; F4 folder mark on an external drive during a provisional snapshot; F5 mark made mid Junk Delete / Move to Trash; F6 hold or mark acquired during phase two; F7 Prepare-finish hand-over, disk truth at the turn and at the removal, generation guard; F8 mixed keys; F9 disk image / unidentified volume never adds a drive; F10 forecast == run for drive counting; F11 a sibling on a second drive is read.

New since round 1 — attack these as first-class:
A. PHYSICAL DEVICE as the drive. (1) Can two copies on ONE physical device still produce two keys (APFS container spanning two physical stores — which store is keyed; Fusion/CoreStorage; a partitioned external disk; a hub/enclosure; the same device re-enumerated with a different device path after replug during a run — is the cache invalidated, and can a stale cache entry add a drive)? (2) Can two DIFFERENT devices collapse to one key in a way that wrongly DENIES (safe) — fine, note only. (3) The 12-hex digest of the device path: collision → two devices seen as one (safe direction) — confirm no path lets a collision or an empty/absent path ADD a drive. (4) The process-wide cache: thread-safety from the disk worker and main; emptied at run start; a volume unmounted and a different one mounted at the same st_dev/node mid-run. (5) Network shares keyed by server+share: two shares of the SAME server disk count as two drives — acceptable? say so explicitly as a limit if you agree it cannot be seen.
B. Workbench Discard's per-file check and the "already correct" claims for JunkDeleteAction, Prune Apply and Transcode Replace Existing (their implementations are outside this scope — judge only from the call sites in scope and the sensor; name anything you cannot certify).
C. Concurrency: DispatchQueue.main.sync from the disk thread in the final verdict — find any path where the main actor can be waiting on that worker (deadlock), including quit/suspend (stopForQuit), pause, cancel, and the Angel's refresh; the per-copy buffer re-read's cost and whether it can starve the run.
D. Regression risk in what was NOT meant to change: resume of an older plan.json; the ledger/log line formats; the Master Archive volume rule; survival counting of a copy on a Read-only drive when ANOTHER drive is cleaned (must still count).

Known and accepted (do not report): a hardware RAID presents as one device and counts as one drive, its redundancy is not a second drive; two disks in one enclosure presenting as two devices count as two; the Angel's extraCopy exclusion is a switchable policy default pinned by a guard test; Catalog Rename and add-a-file verbs are not blocked on a Read-only drive (ruling pending); the network-share key is pinned by a source sensor only (no live share in unit tests); two-real-drives cases go through the identity seam; SwiftLint length/complexity warnings; the gauntlet manifest is not regenerated.

Evidence already run (Debug, by suite, counts confirmed nonzero): full set on the final code 117d4f70 — 968 Swift Testing tests / 170 suites + 13 XCTest (4 skipped), 0 failures (every *Sensor*/*Boundary* suite, all DeleteDuplicates*, ReadOnlyVolume*, ArchiveVolumeProtection*, Steward*, AnalyzeReclaimable*, ArchiveAngel facade/guard, TriageSnapshot*, PruneApplyTests, WorkbenchActionsTests). Round 1 fixes: 16 new tests red on 4c616916 before any fix (3 after a behaviour-neutral seam); 36 mutants all red. Round 2 (A, B): 4 new tests red first; 8 mutants all red (the network-share key by source sensor only). Measured on the M4 (volume names only): the archive volume and a second volume on the same RAID → one device; boot and data volumes → one device; two different external drives → different devices; a RAM disk image → never a drive.

Output contract (required):
- First line exactly: Credits spent: <amount> | Finding count: <N>
- A line: Verdict: <merge | fix | block> — <one-line reason>

Wanted: "closed"/re-opened per F1–F11; findings for A–D ranked by data-loss risk; mutations you believe would survive; "read, no findings" per clean file. Privacy: public repo — no real family names, addresses or dates in any suggested fixture.
