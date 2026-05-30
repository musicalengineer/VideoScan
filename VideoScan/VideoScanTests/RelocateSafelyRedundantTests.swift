import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateSafelyRedundantTests
//
// End-to-end exercises for the safelyRedundant rule (docs/relocate_volume_plan.md
// §1A addendum). Covers the mutation, audit-trail format, and snapshot
// rollback path. Hermetic — uses /tmp source + dest + catalog dirs.

@Suite(.serialized) @MainActor
struct RelocateSafelyRedundantTests {

    // MARK: - Fixtures

    private static func makeWorkspace() throws -> (root: URL, source: URL, dest: URL, catalog: URL) {
        let root = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("vs-relocate-safe-\(UUID().uuidString)",
                                    isDirectory: true)
        let source = root.appendingPathComponent("source")
        let dest = root.appendingPathComponent("dest")
        let catalog = root.appendingPathComponent("catalog")
        let fm = FileManager.default
        for url in [source, dest, catalog] {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return (root, source, dest, catalog)
    }

    @discardableResult
    private func writeFile(at url: URL, bytes: Int) throws -> (size: Int64, md5: String) {
        var buf = Data(count: bytes)
        for i in 0..<bytes { buf[i] = UInt8((i &* 17) % 251) }
        try buf.write(to: url)
        return (Int64(bytes), FileHasher.partialMD5(path: url.path))
    }

    private func makeRecord(fullPath: String, size: Int64, md5: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = md5
        return r
    }

    private func waitForRelocateDone(_ model: VideoScanModel, timeout: TimeInterval = 60) async {
        let deadline = Date().addingTimeInterval(timeout)
        while model.isRelocating && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Mutation marks .manuallyDeleted with witness audit trail

    @Test
    func safelyRedundantMutation_marksManuallyDeleted_andPersistsWitnessesInNote() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Source file exists on disk + in catalog. A witness record points
        // at a path on a third (offline) volume. Reconcile classifies the
        // source record as safelyRedundant; mutation marks it deleted.
        let src = ws.source.appendingPathComponent("kids.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 2048)
        let sourceRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        // Witness path doesn't need to exist on disk — the rule operates
        // on catalog metadata, not file presence.
        let witnessPath = "/Volumes/MyBook3Terabytes/kids.bin"
        let witnessRec = makeRecord(fullPath: witnessPath, size: sx, md5: hx)

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [sourceRec, witnessRec]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForRelocateDone(model)

        // Source record is now marked deleted.
        #expect(sourceRec.archiveStage == .manuallyDeleted)
        // Source file on disk is untouched — catalog-only mutation.
        #expect(FileManager.default.fileExists(atPath: src.path))
        // Dashboard counter incremented.
        #expect(model.dashboard.relocateSafelyRedundant == 1)
        #expect(model.dashboard.relocateSafelyRedundantBytes == sx)
        // Audit trail: structured note carrying the witness list.
        #expect(sourceRec.notes.contains("reason=dup-on-other-volume"))
        #expect(sourceRec.notes.contains(witnessPath))
        #expect(sourceRec.notes.contains("totalWitnesses=1"))
        // Provenance is NOT stamped — we didn't relocate this record.
        #expect(sourceRec.originalFullPath == nil)
        // Witness record is untouched.
        #expect(witnessRec.archiveStage == .none)
    }

    // MARK: - Toggle OFF makes the rule a no-op

    @Test
    func skipDupsToggleOff_classifiesAsReady_andCopiesNormally() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        let src = ws.source.appendingPathComponent("photo.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 1024)
        let sourceRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        // Witness on a third volume.
        let witnessRec = makeRecord(
            fullPath: "/Volumes/MyBook3Terabytes/photo.bin",
            size: sx, md5: hx
        )

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [sourceRec, witnessRec]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: false   // <-- toggle OFF
        ))
        await waitForRelocateDone(model)

        // With the rule off, falls through to Bucket A and copies normally.
        #expect(model.dashboard.relocateSafelyRedundant == 0)
        #expect(model.dashboard.relocateSucceeded == 1)
        // Record's path is rewritten to dest, provenance stamped.
        #expect(sourceRec.fullPath.hasPrefix(ws.dest.path))
        #expect(sourceRec.originalFullPath == src.path)
        #expect(sourceRec.archiveStage != .manuallyDeleted)
    }

    // MARK: - Snapshot rollback restores pre-mutation state

    @Test
    func snapshotRollback_restoresSafelyRedundantRecordsExactly() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        let src = ws.source.appendingPathComponent("clip.bin")
        let (sx, hx) = try writeFile(at: src, bytes: 4096)
        let sourceRec = makeRecord(fullPath: src.path, size: sx, md5: hx)
        let witnessRec = makeRecord(
            fullPath: "/Volumes/MyBook3Terabytes/clip.bin",
            size: sx, md5: hx
        )

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [sourceRec, witnessRec]
        // Persist BEFORE running so the pre-relocate snapshot captures
        // the pristine state. archiveStage starts as .none.
        model.catalogStore.saveNow(records: model.records)

        // Capture the snapshot file path by listing catalog dir before/after.
        let beforeFiles = Set(try FileManager.default.contentsOfDirectory(atPath: ws.catalog.path))

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForRelocateDone(model)

        // Confirm mutation happened.
        #expect(sourceRec.archiveStage == .manuallyDeleted)
        #expect(model.dashboard.relocateSafelyRedundant == 1)

        // Find the snapshot file.
        let afterFiles = Set(try FileManager.default.contentsOfDirectory(atPath: ws.catalog.path))
        let newFiles = afterFiles.subtracting(beforeFiles)
        let snapshotName = try #require(newFiles.first(where: { $0.hasPrefix("catalog.pre-relocate.") }))
        let snapshotURL = ws.catalog.appendingPathComponent(snapshotName)

        // Decode the snapshot and verify it restores the pre-mutation state.
        // We simulate rollback by loading the snapshot JSON and decoding.
        let data = try Data(contentsOf: snapshotURL)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let snap = try dec.decode(CatalogSnapshot.self, from: data)

        let restoredSource = try #require(snap.records.first { $0.id == sourceRec.id })
        // The .manuallyDeleted mutation is reverted by rollback.
        #expect(restoredSource.archiveStage == .none)
        // The structured witness note is not present in the pre-mutation snapshot.
        #expect(!restoredSource.notes.contains("dup-on-other-volume"))
        // fullPath was never rewritten for safelyRedundant — confirm it
        // matches both the post-run live record AND the snapshot.
        #expect(restoredSource.fullPath == src.path)
        #expect(restoredSource.fullPath == sourceRec.fullPath)
    }

    // MARK: - Empty-hash + zero-size guards (no false positives)

    @Test
    func emptyHashRecord_neverClassifiedAsSafelyRedundant_endToEnd() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        // Legacy record with size but no hash. Same applies for witness.
        let missingPath = ws.source.appendingPathComponent("legacy.bin").path
        let srcRec = makeRecord(fullPath: missingPath, size: 1024, md5: "")
        let witnessRec = makeRecord(
            fullPath: "/Volumes/MyBook/legacy.bin",
            size: 1024, md5: ""
        )

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForRelocateDone(model)

        // Empty-hash records never enter Bucket E.
        #expect(model.dashboard.relocateSafelyRedundant == 0)
    }

    @Test
    func zeroSizeRecord_neverClassifiedAsSafelyRedundant_endToEnd() async throws {
        let ws = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }

        let missingPath = ws.source.appendingPathComponent("empty.bin").path
        let srcRec = makeRecord(fullPath: missingPath, size: 0, md5: "HASH-EMPTY")
        let witnessRec = makeRecord(
            fullPath: "/Volumes/MyBook/empty.bin",
            size: 0, md5: "HASH-EMPTY"
        )

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: ws.catalog)
        model.records = [srcRec, witnessRec]
        model.catalogStore.saveNow(records: model.records)

        model.relocateVolume(RelocateOptions(
            sourceVolumeRootPath: ws.source.path,
            destinationRoot: ws.dest,
            maxConcurrency: 1,
            dryRun: false,
            skipAlreadyRelocated: true,
            skipDupsOnOtherVolumes: true
        ))
        await waitForRelocateDone(model)

        #expect(model.dashboard.relocateSafelyRedundant == 0)
    }
}
