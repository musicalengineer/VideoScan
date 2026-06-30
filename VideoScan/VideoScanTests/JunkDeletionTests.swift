import Testing
import Foundation
@testable import VideoScan

// MARK: - Delete Confirmed Junk tests
//
// Feature spec (Manager dispatch 2026-05-25):
//   - VideoScanModel.deleteConfirmedJunk(_:mode:) drives both .toTrash and
//     .permanent flavors of the Delete Confirmed Junk workflow.
//   - All catalog mutations happen in-memory; catalog persistence is a
//     single debounced save() at end-of-batch.
//   - Per-record FileManager errors are accumulated; the batch does not
//     abort on the first failure.
//   - "Already missing" files are not errors — catalog row is still
//     updated with purgedAt + lifecycleStage and counted.
//   - LifecycleStage gains .trashed and .deletedPermanently; both must
//     round-trip through CatalogSnapshot encode/decode.
//   - Legacy catalog.json (no lifecycleStage key) still decodes as
//     .cataloged.
//
// 2026-05-26 async refactor (fix/junk-delete-async):
//   - deleteConfirmedJunk is now `async` so the FileManager loop can
//     hop off @MainActor onto a detached task. Every test that calls it
//     gains `async` + `await`. The result contract is unchanged.
//
// Tests own their tmp directory and clean up on exit. CatalogStore
// short-circuits I/O under tests, so we never touch user catalog.json.

@MainActor
struct JunkDeletionTests {

    // MARK: - Test helpers

    /// Build an isolated tmp dir for each test. Mirrors the pattern in
    /// CatalogRenameTests so cleanup semantics are consistent.
    private static func makeTmpDir(label: String) throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("JunkDeletionTests-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func writeFixture(at url: URL, bytes: String = "junk-fixture-content") throws {
        try bytes.data(using: .utf8)!.write(to: url)
    }

    /// Build a record pointing at a real on-disk file (so trashItem /
    /// removeItem actually have something to act on). Disposition is set
    /// to .confirmedJunk so the model's caller-side filter would normally
    /// pick it up; the deletion method itself doesn't gate on
    /// disposition, but we want the tests to mirror reality.
    private static func record(at url: URL) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = url.path
        r.filename = url.lastPathComponent
        r.ext = (url.pathExtension).uppercased()
        r.directory = url.deletingLastPathComponent().path
        r.mediaDisposition = .confirmedJunk
        r.sizeBytes = 1_000
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    // MARK: - 1. Positive: trashItem path

    // regression: feature spec — .toTrash mode moves files to Finder Trash,
    // stamps purgedAt + lifecycleStage = .trashed on every record, and
    // leaves fullPath unchanged (user can still see where the file used
    // to live in the Show Removed view).
    @Test func deleteToTrash_movesFilesAndStampsRecords() async throws {
        let tmp = try Self.makeTmpDir(label: "trash-happy")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let urls = (0..<3).map { tmp.appendingPathComponent("trashme_\($0).mov") }
        for url in urls { try Self.writeFixture(at: url) }
        let recs = urls.map { Self.record(at: $0) }
        let pathsBefore = recs.map { $0.fullPath }

        let model = VideoScanModel()
        model.records = recs

        let before = Date()
        let result = await model.deleteConfirmedJunk(recs, mode: .toTrash)
        let after = Date()

        #expect(result.attempted == 3, "All 3 records should be attempted")
        #expect(result.succeeded == 3, "All 3 files should be trashed successfully")
        #expect(result.alreadyMissing == 0)
        #expect(result.failed.isEmpty)

        for (i, rec) in recs.enumerated() {
            // Disk-side: file gone from original path (it's in the volume's
            // .Trashes/ now — we don't check there because Trash location
            // varies by volume; absence at the original path is sufficient).
            #expect(!FileManager.default.fileExists(atPath: urls[i].path),
                    "Trashed file should not exist at its original path")
            // Catalog mutation:
            #expect(rec.purgedAt != nil, "purgedAt must be stamped")
            if let stamp = rec.purgedAt {
                #expect(stamp >= before.addingTimeInterval(-2))
                #expect(stamp <= after.addingTimeInterval(2))
            }
            #expect(rec.lifecycleStage == .trashed,
                    "lifecycleStage must be .trashed")
            // fullPath unchanged — feature explicitly preserves it so the
            // user can see where the file used to live.
            #expect(rec.fullPath == pathsBefore[i],
                    "fullPath must be unchanged after trash op")
        }
    }

    // MARK: - 2. Positive: removeItem (permanent) path

    @Test func deletePermanent_removesFilesAndStampsRecords() async throws {
        let tmp = try Self.makeTmpDir(label: "perm-happy")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let urls = (0..<3).map { tmp.appendingPathComponent("nukeme_\($0).mov") }
        for url in urls { try Self.writeFixture(at: url) }
        let recs = urls.map { Self.record(at: $0) }
        let pathsBefore = recs.map { $0.fullPath }

        let model = VideoScanModel()
        model.records = recs

        let result = await model.deleteConfirmedJunk(recs, mode: .permanent)

        #expect(result.attempted == 3)
        #expect(result.succeeded == 3)
        #expect(result.alreadyMissing == 0)
        #expect(result.failed.isEmpty)

        for (i, rec) in recs.enumerated() {
            #expect(!FileManager.default.fileExists(atPath: urls[i].path),
                    "Permanently-deleted file should be gone from disk")
            #expect(rec.purgedAt != nil)
            #expect(rec.lifecycleStage == .deletedPermanently,
                    "lifecycleStage must be .deletedPermanently")
            #expect(rec.fullPath == pathsBefore[i],
                    "fullPath must be unchanged after permanent delete")
        }
    }

    // MARK: - 3. Codable round-trip: new lifecycle stages

    // regression: feature spec — the two new LifecycleStage cases must
    // survive a catalog.json save/load using the same encoder config
    // CatalogStore uses. Without this test the new cases could silently
    // be lost on app relaunch (record decoded as .cataloged via the
    // fallback in init(from:)).
    @Test func codable_roundTripPreservesNewLifecycleStages() throws {
        let r1 = VideoRecord()
        r1.filename = "trashed.mov"
        r1.fullPath = "/Volumes/V/trashed.mov"
        r1.lifecycleStage = .trashed
        r1.purgedAt = Date(timeIntervalSince1970: 1_720_000_000)

        let r2 = VideoRecord()
        r2.filename = "deleted.mov"
        r2.fullPath = "/Volumes/V/deleted.mov"
        r2.lifecycleStage = .deletedPermanently
        r2.purgedAt = Date(timeIntervalSince1970: 1_720_000_100)

        let snap = CatalogSnapshot(records: [r1, r2])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(CatalogSnapshotDTO(snap))

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode(CatalogSnapshot.self, from: data)

        #expect(loaded.records.count == 2)
        let byName = Dictionary(uniqueKeysWithValues:
                                    loaded.records.map { ($0.filename, $0) })
        let loadedTrashed = try #require(byName["trashed.mov"])
        let loadedDeleted = try #require(byName["deleted.mov"])
        #expect(loadedTrashed.lifecycleStage == .trashed,
                ".trashed must round-trip as .trashed")
        #expect(loadedDeleted.lifecycleStage == .deletedPermanently,
                ".deletedPermanently must round-trip as .deletedPermanently")
        #expect(loadedTrashed.purgedAt != nil)
        #expect(loadedDeleted.purgedAt != nil)
    }

    // MARK: - 4. Codable round-trip: legacy catalog (no lifecycleStage key)

    // regression: feature spec — pre-feature catalog.json (where the
    // lifecycleStage key is absent on a record) must still decode, with
    // lifecycleStage defaulting to .cataloged. Without this guarantee
    // every user-with-existing-catalog would see records decode as the
    // first enum case after a Swift compile reorder, or throw, depending
    // on the codable strategy. We pin .cataloged explicitly.
    @Test func codable_legacyRecordDecodesAsCataloged() throws {
        let legacyJSON = """
        {
          "version": 2,
          "savedAt": "2026-04-01T12:00:00Z",
          "savedFromHost": "TestHost",
          "records": [
            {
              "id": "00000000-0000-0000-0000-000000000111",
              "filename": "ancient.mov",
              "fullPath": "/Volumes/V/ancient.mov",
              "streamTypeRaw": "Video+Audio",
              "sizeBytes": 42
            }
          ]
        }
        """
        let data = Data(legacyJSON.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let snap = try decoder.decode(CatalogSnapshot.self, from: data)
        let rec = try #require(snap.records.first)
        #expect(rec.lifecycleStage == .cataloged,
                "Legacy record (no lifecycleStage key) must decode as .cataloged")
        #expect(rec.purgedAt == nil,
                "Legacy record must decode as active (purgedAt nil)")
    }

    // MARK: - 5. Negative: record points at missing file (already gone)

    // regression: feature spec — the file may have been deleted by the
    // user from Finder between tagging and the delete pass. We count it
    // as alreadyMissing, still stamp purgedAt + lifecycleStage so the
    // row doesn't keep showing as active confirmed-junk on the next
    // pass, and do not raise an error.
    @Test func deletes_recordsMissingFileAsAlreadyMissing() async throws {
        let tmp = try Self.makeTmpDir(label: "missing")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Build a record pointing at a file that never existed.
        let ghostURL = tmp.appendingPathComponent("ghost.mov")
        let rec = Self.record(at: ghostURL)
        // Sanity: file is genuinely absent.
        #expect(!FileManager.default.fileExists(atPath: ghostURL.path))

        let model = VideoScanModel()
        model.records = [rec]

        let result = await model.deleteConfirmedJunk([rec], mode: .toTrash)

        #expect(result.attempted == 1)
        #expect(result.succeeded == 0,
                "Missing file is NOT counted as succeeded")
        #expect(result.alreadyMissing == 1,
                "Missing file should be reported in alreadyMissing")
        #expect(result.failed.isEmpty,
                "Missing file is NOT a failure — no exception, no failed entry")
        #expect(rec.purgedAt != nil,
                "Record must still be soft-deleted so it stops showing as active confirmed junk")
        #expect(rec.lifecycleStage == .trashed,
                "Missing-file record adopts the requested lifecycleStage (.trashed for .toTrash mode)")
    }

    // Same idea but exercising the .permanent branch's missing-file
    // handling — the lifecycleStage should follow the requested mode.
    @Test func deletePermanent_recordsMissingFileAsAlreadyMissingWithDeletedStage() async throws {
        let tmp = try Self.makeTmpDir(label: "missing-perm")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let ghostURL = tmp.appendingPathComponent("ghost.mov")
        let rec = Self.record(at: ghostURL)
        let model = VideoScanModel()
        model.records = [rec]

        let result = await model.deleteConfirmedJunk([rec], mode: .permanent)

        #expect(result.alreadyMissing == 1)
        #expect(result.failed.isEmpty)
        #expect(rec.lifecycleStage == .deletedPermanently,
                "Missing-file record under .permanent should adopt .deletedPermanently")
    }

    // MARK: - 6. Negative: FileManager error caught into `failed`

    // regression: feature spec — FileManager errors are captured, not
    // propagated, so a partial batch still completes. Simulating a real
    // permissions denial without root would require deep FileManager
    // mocking; we instead drive the same code path by passing a record
    // with an empty fullPath. The model treats empty path as "doesn't
    // exist" (alreadyMissing) — not as a thrown error — so to exercise
    // the failed-array path we point at an UNWRITABLE-PARENT scenario:
    // a path that's NOT in the missing branch but IS guaranteed to fail
    // trashItem.
    //
    // The cleanest cross-OS way: create the file, set its parent dir's
    // permissions to 0o555 (read+execute, no write), and try to trash
    // it. macOS's APFS denies trashItem under that scenario with EACCES.
    // We restore permissions in defer so cleanup works.
    @Test func deletes_capturesFileManagerErrorsPerRecord() async throws {
        let tmp = try Self.makeTmpDir(label: "permerror")
        defer {
            // Restore perms before cleanup so removeItem(at: tmp) works.
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        // One good file (should succeed), one in a read-only subdir
        // (should fail).
        let okURL = tmp.appendingPathComponent("ok.mov")
        try Self.writeFixture(at: okURL)
        let okRec = Self.record(at: okURL)

        let lockedDir = tmp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: lockedDir,
                                                withIntermediateDirectories: true)
        let lockedURL = lockedDir.appendingPathComponent("trapped.mov")
        try Self.writeFixture(at: lockedURL)
        let lockedRec = Self.record(at: lockedURL)

        // Drop the parent dir to read-only AFTER putting the file in it.
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
        // We need to restore the perms in our defer too so the outer
        // cleanup can recurse.
        defer {
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        }

        let model = VideoScanModel()
        model.records = [okRec, lockedRec]

        let result = await model.deleteConfirmedJunk([okRec, lockedRec],
                                                     mode: .permanent)

        #expect(result.attempted == 2)
        // The unwritable-parent test is best-effort: on some filesystems
        // (e.g. tmpfs or volumes mounted with permissive options) the
        // permission bits won't bite and removeItem will succeed anyway.
        // Either branch is fine, but we DO require:
        //   - the ok file always succeeds
        //   - the count math always adds up
        #expect(okRec.purgedAt != nil,
                "OK record must be processed regardless of the locked record's outcome")
        #expect(okRec.lifecycleStage == .deletedPermanently)
        #expect(result.succeeded + result.failed.count + result.alreadyMissing == 2,
                "Result counts must sum to attempted, regardless of which bucket the locked record fell into")
        // Critical contract: locked-file outcome must NOT halt the batch.
        // okRec is always processed.
        // If the locked file landed in `failed`, the error map must point
        // at it — assert that defensively only when failure occurred.
        if !result.failed.isEmpty {
            #expect(result.failed.first?.record === lockedRec,
                    "Failure entry should reference the locked record, not the OK one")
            // And the locked record must NOT be soft-deleted (the file
            // is still there; the row should remain active so the user
            // can retry or inspect).
            #expect(lockedRec.purgedAt == nil,
                    "Failed record must NOT be stamped with purgedAt — file is still on disk")
            #expect(lockedRec.lifecycleStage == .cataloged,
                    "Failed record's lifecycleStage must not change")
        }
    }

    // MARK: - 7. Mixed batch: some succeed, some missing

    // regression: feature spec — a batch can mix succeeded/missing/failed
    // outcomes and the result counts must remain consistent. (This test
    // pairs succeeded + alreadyMissing; the failed case is exercised in
    // test 6 above.)
    @Test func deletes_mixedBatchSumsCorrectly() async throws {
        let tmp = try Self.makeTmpDir(label: "mixed")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 2 real files (will succeed) + 2 ghosts (will be alreadyMissing).
        let realURLs = (0..<2).map { tmp.appendingPathComponent("real_\($0).mov") }
        for u in realURLs { try Self.writeFixture(at: u) }
        let realRecs = realURLs.map { Self.record(at: $0) }

        let ghostURLs = (0..<2).map { tmp.appendingPathComponent("ghost_\($0).mov") }
        let ghostRecs = ghostURLs.map { Self.record(at: $0) }
        // Sanity: ghosts aren't on disk.
        for u in ghostURLs {
            #expect(!FileManager.default.fileExists(atPath: u.path))
        }

        let model = VideoScanModel()
        let all = realRecs + ghostRecs
        model.records = all

        let result = await model.deleteConfirmedJunk(all, mode: .toTrash)

        #expect(result.attempted == 4)
        #expect(result.succeeded == 2,
                "Exactly the 2 real files should land in succeeded")
        #expect(result.alreadyMissing == 2,
                "Exactly the 2 ghosts should land in alreadyMissing")
        #expect(result.failed.isEmpty)
        #expect(result.succeeded + result.alreadyMissing + result.failed.count
                == result.attempted,
                "Counts must always sum to attempted")
        // All four records should be soft-deleted (purgedAt stamped).
        for rec in all {
            #expect(rec.purgedAt != nil)
            #expect(rec.lifecycleStage == .trashed)
        }
    }

    // MARK: - 8. Edge: empty selection → no-op

    @Test func deletes_emptySelectionReturnsZeroResult() async {
        let model = VideoScanModel()
        model.records = []

        let result = await model.deleteConfirmedJunk([], mode: .toTrash)

        #expect(result.attempted == 0)
        #expect(result.succeeded == 0)
        #expect(result.alreadyMissing == 0)
        #expect(result.failed.isEmpty)
    }

    // MARK: - 9. confirmedJunkRecords helper

    // regression: feature spec — the helper that drives the toolbar count
    // returns ONLY active (non-purged) records tagged .confirmedJunk.
    // Records with other dispositions, and purged confirmed-junk records,
    // must NOT be in the set.
    // MARK: - 10. Offline volume: skippedOffline bucket

    // regression: feature/triage-offline-aware — when a record's volume
    // isn't currently mounted, the delete pass must:
    //   - count it in `skippedOffline` (NOT `failed`, NOT `alreadyMissing`)
    //   - NOT touch the record (purgedAt stays nil, lifecycleStage
    //     stays as it was — so the user can retry after remounting)
    //   - sum: succeeded + alreadyMissing + skippedOffline + failed.count
    //     == attempted
    //
    // We point the record at /Volumes/NonexistentVolume-<uuid>/foo.mp4.
    // The /Volumes/<name> prefix is what VolumeReachability uses to key
    // its cache; a guaranteed-not-present volume name returns false from
    // isReachable() without ever touching the actual file path.
    @Test func skippedOfflineIsCountedSeparately() async {
        VolumeReachability.invalidateCache()
        let fakeVol = "NonexistentVolume-\(UUID().uuidString)"
        let rec = VideoRecord()
        rec.fullPath = "/Volumes/\(fakeVol)/foo.mp4"
        rec.filename = "foo.mp4"
        rec.directory = "/Volumes/\(fakeVol)"
        rec.mediaDisposition = .confirmedJunk
        rec.sizeBytes = 1_000_000

        let model = VideoScanModel()
        model.records = [rec]

        let result = await model.deleteConfirmedJunk([rec], mode: .toTrash)

        #expect(result.attempted == 1)
        #expect(result.skippedOffline == 1,
                "Offline record must land in skippedOffline")
        #expect(result.succeeded == 0,
                "Offline record must NOT count as succeeded")
        #expect(result.alreadyMissing == 0,
                "Offline record must NOT count as alreadyMissing (different bucket — volume could come back)")
        #expect(result.failed.isEmpty,
                "Offline record must NOT count as a failure")
        // Critical: record must be untouched so a retry after remount
        // still finds it as active confirmed-junk.
        #expect(rec.purgedAt == nil,
                "Offline record must NOT be soft-deleted — volume might come back")
        #expect(rec.lifecycleStage == .cataloged,
                "Offline record's lifecycleStage must be unchanged")
        // Counts always reconcile.
        #expect(result.succeeded + result.alreadyMissing
                + result.skippedOffline + result.failed.count
                == result.attempted)
    }

    // MARK: - 11. Mixed batch: all four buckets land correctly

    // regression: feature/triage-offline-aware — a single batch can hit
    // every bucket. Build one of each:
    //   - reachable + present  → succeeded
    //   - reachable + missing  → alreadyMissing
    //   - offline              → skippedOffline
    //   - reachable + permission-denied parent → failed
    // (The last bucket inherits the best-effort caveat from test 6.)
    @Test func mixedBatchReportsAllBuckets() async throws {
        VolumeReachability.invalidateCache()
        let tmp = try Self.makeTmpDir(label: "mixed-buckets")
        defer {
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: tmp.path)
            try? FileManager.default.removeItem(at: tmp)
        }

        // (1) Reachable + present — should succeed.
        let okURL = tmp.appendingPathComponent("ok.mov")
        try Self.writeFixture(at: okURL)
        let okRec = Self.record(at: okURL)

        // (2) Reachable + missing — should be alreadyMissing.
        let ghostURL = tmp.appendingPathComponent("ghost.mov")
        let ghostRec = Self.record(at: ghostURL)
        #expect(!FileManager.default.fileExists(atPath: ghostURL.path))

        // (3) Offline volume — should be skippedOffline.
        let fakeVol = "NonexistentVolume-\(UUID().uuidString)"
        let offlineRec = VideoRecord()
        offlineRec.fullPath = "/Volumes/\(fakeVol)/junk.mp4"
        offlineRec.filename = "junk.mp4"
        offlineRec.directory = "/Volumes/\(fakeVol)"
        offlineRec.mediaDisposition = .confirmedJunk
        offlineRec.sizeBytes = 500_000

        // (4) Reachable + permission-denied parent — should fail (or
        // succeed on lenient filesystems; see test 6's caveat).
        let lockedDir = tmp.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: lockedDir,
                                                withIntermediateDirectories: true)
        let lockedURL = lockedDir.appendingPathComponent("trapped.mov")
        try Self.writeFixture(at: lockedURL)
        let lockedRec = Self.record(at: lockedURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: lockedDir.path)
        defer {
            _ = try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: lockedDir.path)
        }

        let all = [okRec, ghostRec, offlineRec, lockedRec]
        let model = VideoScanModel()
        model.records = all

        let result = await model.deleteConfirmedJunk(all, mode: .permanent)

        #expect(result.attempted == 4)
        // Hard contracts (independent of the lenient-filesystem caveat):
        #expect(result.succeeded >= 1,
                "OK record must always succeed")
        #expect(result.alreadyMissing == 1,
                "Ghost record must be the one in alreadyMissing")
        #expect(result.skippedOffline == 1,
                "Offline record must be the one in skippedOffline")
        // Counts always sum to attempted.
        #expect(result.succeeded + result.alreadyMissing
                + result.skippedOffline + result.failed.count == 4,
                "Bucket counts must sum to attempted")
        // OK record is processed regardless of locked record's outcome.
        #expect(okRec.purgedAt != nil)
        #expect(okRec.lifecycleStage == .deletedPermanently)
        // Ghost record is soft-deleted (alreadyMissing branch).
        #expect(ghostRec.purgedAt != nil)
        #expect(ghostRec.lifecycleStage == .deletedPermanently)
        // Offline record is UNTOUCHED — user can retry after remount.
        #expect(offlineRec.purgedAt == nil,
                "Offline record must NOT be touched")
        #expect(offlineRec.lifecycleStage == .cataloged)
    }

    // MARK: - 12. splitByReachability helper

    // regression: feature/triage-offline-aware — the split helper that
    // powers the confirmation sheet's breakdown must partition correctly
    // and preserve every input record exactly once (no drops, no dupes).
    @Test func splitByReachability_partitionsCleanly() {
        VolumeReachability.invalidateCache()
        let fakeVol = "NonexistentVolume-\(UUID().uuidString)"

        let onlineRec = VideoRecord()
        onlineRec.fullPath = "/tmp/online_\(UUID().uuidString).mov"

        let offlineRec = VideoRecord()
        offlineRec.fullPath = "/Volumes/\(fakeVol)/offline.mov"

        let emptyPathRec = VideoRecord()
        emptyPathRec.fullPath = ""

        let split = VideoScanModel.splitByReachability(
            [onlineRec, offlineRec, emptyPathRec])

        // No record is dropped, none duplicated.
        #expect(split.reachable.count + split.offline.count == 3)
        // Offline record is in the offline bucket.
        #expect(split.offline.contains { $0 === offlineRec })
        #expect(!split.reachable.contains { $0 === offlineRec })
        // Online record is in the reachable bucket.
        #expect(split.reachable.contains { $0 === onlineRec })
        // Empty-path record falls into reachable (deleteConfirmedJunk
        // will then bucket it as alreadyMissing).
        #expect(split.reachable.contains { $0 === emptyPathRec })
    }

    @Test func confirmedJunkRecords_filtersCorrectly() {
        let model = VideoScanModel()

        let activeJunk1 = VideoRecord(); activeJunk1.filename = "a.mov"
        activeJunk1.mediaDisposition = .confirmedJunk

        let activeJunk2 = VideoRecord(); activeJunk2.filename = "b.mov"
        activeJunk2.mediaDisposition = .confirmedJunk

        let suspectedJunk = VideoRecord(); suspectedJunk.filename = "c.mov"
        suspectedJunk.mediaDisposition = .suspectedJunk

        let purgedJunk = VideoRecord(); purgedJunk.filename = "d.mov"
        purgedJunk.mediaDisposition = .confirmedJunk
        purgedJunk.purgedAt = Date()

        let unreviewed = VideoRecord(); unreviewed.filename = "e.mov"
        unreviewed.mediaDisposition = .unreviewed

        model.records = [activeJunk1, activeJunk2, suspectedJunk, purgedJunk, unreviewed]

        let cj = model.confirmedJunkRecords
        let cjIDs = Set(cj.map { $0.id })

        #expect(cj.count == 2,
                "Helper must return exactly the 2 active confirmed-junk records")
        #expect(cjIDs == [activeJunk1.id, activeJunk2.id])
        #expect(!cjIDs.contains(suspectedJunk.id),
                "Suspected junk must NOT be in confirmedJunkRecords")
        #expect(!cjIDs.contains(purgedJunk.id),
                "Already-purged confirmed-junk must NOT be in confirmedJunkRecords (already actioned)")
        #expect(!cjIDs.contains(unreviewed.id),
                "Unreviewed must NOT be in confirmedJunkRecords")
    }

    // MARK: - 13. Main thread stays responsive during deletion (async refactor)
    //
    // regression: fix/junk-delete-async (2026-05-26) — the FileManager
    // loop used to run synchronously on @MainActor and pin the UI for
    // many seconds on batches of a few hundred files. After the refactor
    // the disk pass runs on a detached task, so the main thread MUST be
    // able to service other @MainActor work concurrently while
    // deleteConfirmedJunk is in flight.
    //
    // Mechanism: kick off the deletion as a Task, then race a "tick"
    // Task against it. The tick Task schedules a long sequence of cheap
    // @MainActor steps (via Task.yield()) and records how many it
    // completes before the deletion finishes. If main is blocked, the
    // tick count is small (or zero). If main is responsive — i.e. the
    // detached FileManager loop has correctly hopped off main — the tick
    // count is large.
    //
    // We use a generously-sized batch (200 fixture files) so on the
    // pre-refactor sync impl this test would visibly fail: the disk
    // loop would block main for seconds and zero (or near-zero) ticks
    // would land. On the async impl ticks fire freely while the
    // detached task chews through trashItem calls.
    //
    // Hard assertion: we expect at least 20 successful main-thread
    // yields during the deletion. That's a conservative lower bound —
    // local runs see hundreds of ticks — but it's high enough above
    // zero that a regression to a synchronous loop would trip it.
    @Test func mainThreadStaysResponsiveDuringDeletion() async throws {
        let tmp = try Self.makeTmpDir(label: "responsive")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 200 fixture files — big enough that a sync trashItem loop
        // pins main for several seconds on APFS. The async impl should
        // chew through them without blocking.
        let count = 200
        let urls = (0..<count).map {
            tmp.appendingPathComponent("resp_\($0).mov")
        }
        for url in urls { try Self.writeFixture(at: url) }
        let recs = urls.map { Self.record(at: $0) }

        let model = VideoScanModel()
        model.records = recs

        // Tick counter — incremented on @MainActor from a parallel Task
        // that yields back to the scheduler between increments. If main
        // is blocked, the yields don't get a chance to resume; if main
        // is free, the counter climbs.
        //
        // We store the counter in a single-element class so both Tasks
        // can mutate it; the @MainActor isolation comes from the Task's
        // own context (we explicitly tag the ticker Task @MainActor).
        final class TickCounter { var value: Int = 0 }
        let counter = TickCounter()
        // Set when the deletion Task finishes — the ticker stops then.
        final class DoneFlag { var done: Bool = false }
        let flag = DoneFlag()

        // Tick task: stay on @MainActor, repeatedly yield + increment
        // until the deletion finishes. Each Task.yield() returns
        // control to the scheduler; the deletion's await-on-detached
        // task ALSO yields control, so the two interleave freely if
        // the main thread isn't blocked.
        let ticker = Task { @MainActor in
            while !flag.done {
                counter.value += 1
                await Task.yield()
            }
        }

        // Kick the deletion and wait for it. Inside this Task, the
        // detached FileManager loop runs off-main; the await suspends
        // (doesn't block) this Task until done, leaving main free for
        // the ticker to run.
        let result = await model.deleteConfirmedJunk(recs, mode: .toTrash)
        flag.done = true
        // Let the ticker observe `done` and exit cleanly.
        _ = await ticker.value

        // Sanity: the deletion did its job.
        #expect(result.attempted == count)
        #expect(result.succeeded == count,
                "All fixture files should be trashed")

        // The actual responsiveness contract. On the pre-refactor sync
        // impl, ticks would land near zero (main was pinned in the
        // FileManager loop). On the async impl we see hundreds. 20 is
        // a deliberately conservative lower bound — high enough above
        // zero to catch a regression, low enough that a slow CI runner
        // still passes.
        #expect(counter.value >= 20,
                "Main thread should service at least 20 ticks during a 200-file deletion. Counter was \(counter.value); a regression to a synchronous on-main FileManager loop would drop this near zero.")
    }
}
