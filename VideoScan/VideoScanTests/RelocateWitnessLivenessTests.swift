import Testing
import Foundation
@testable import VideoScan

// MARK: - RelocateWitnessLivenessTests
//
// Pins N1007-R-MediaOps-prune-F1 (P1) and F5: Relocate's Bucket E
// ("safely redundant") must never count a dead or absent catalog row as
// the surviving copy. Bucket E marks the source record deleted and leads
// to "Retire <drive>", so a false witness means the last copy goes out
// with the retired drive.
//
// Invariant: a record is safely redundant ONLY when at least one witness
// is (a) a live catalog row (not purged, not trashed/deleted, not
// .manuallyDeleted) AND (b) present on disk now at its recorded size.
// Refuse over guess: anything else falls through to the A/C/B cascade.
//
// Fixtures are synthetic temp dirs ("test_*" names); never real media.
// Each test builds three sibling "volumes" under one temp root:
//   src/      the drive being relocated
//   witness/  a third volume holding the would-be witness
//   dest/     the destination (empty)

@MainActor
struct RelocateWitnessLivenessTests {

    private struct Fixture {
        let root: URL
        let src: URL
        let witnessVol: URL
        let dest: URL
        let srcFile: URL
        let witnessFile: URL
        let size: Int64 = 4096
        let md5 = "HASH-LIVE"

        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("test_relocate_witness_\(UUID().uuidString)")
            src = root.appendingPathComponent("src")
            witnessVol = root.appendingPathComponent("witness")
            dest = root.appendingPathComponent("dest")
            for d in [src, witnessVol, dest] {
                try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            }
            srcFile = src.appendingPathComponent("test_family.mov")
            witnessFile = witnessVol.appendingPathComponent("test_family.mov")
            try Data(repeating: 7, count: Int(size)).write(to: srcFile)
            try Data(repeating: 7, count: Int(size)).write(to: witnessFile)
        }

        func record(at url: URL) -> VideoRecord {
            let r = VideoRecord()
            r.filename = url.lastPathComponent
            r.fullPath = url.path
            r.sizeBytes = size
            r.partialMD5 = md5
            return r
        }

        func reconcile(source: VideoRecord, witness: VideoRecord) -> ReconcileResult {
            RelocateReconcile.reconcile(
                records: [source],
                allCatalogRecords: [source, witness],
                sourceVolumeRootPath: src.path,
                destinationRoot: dest,
                sourceFiles: [.init(path: srcFile.path, size: size)],
                destFiles: [],
                skipDupsOnOtherVolumes: true,
                hash: { [md5, srcFile, witnessFile] path in
                    (path == srcFile.path || path == witnessFile.path) ? md5 : ""
                }
            )
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    /// Expect the source record NOT to be retired as redundant; it must
    /// stay in the copy path (Bucket A, since its own file still reads).
    private func expectMustCopy(_ result: ReconcileResult, _ source: VideoRecord,
                                _ comment: Comment) {
        #expect(result.safelyRedundant.isEmpty, comment)
        #expect(result.ready.map(\.id) == [source.id], comment)
    }

    // MARK: - Positive control

    @Test func liveWitnessPresentOnDiskStillMakesTheRecordSafelyRedundant() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        let result = fx.reconcile(source: source, witness: witness)
        #expect(result.safelyRedundant.map(\.rec.id) == [source.id])
        #expect(result.safelyRedundant.first?.witnesses == [fx.witnessFile.path])
    }

    // MARK: - F1: dead catalog rows are not witnesses

    @Test func trashedWitnessRecordIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        witness.purgedAt = Date()
        witness.lifecycleStage = .trashed
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a witness trashed by Delete Duplicates / ⌘⌫ must not vouch")
    }

    @Test func purgedButNotTrashedWitnessRecordIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        witness.purgedAt = Date()      // Remove from Catalog
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a removed-from-catalog witness must not vouch")
    }

    @Test func permanentlyDeletedWitnessRecordIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        witness.lifecycleStage = .deletedPermanently
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a deleted-permanently witness must not vouch")
    }

    @Test func manuallyDeletedWitnessRecordIsNotASurvivingCopy() throws {
        // Two drives vouching for each other: an earlier relocate marked
        // the witness .manuallyDeleted (itself "safely redundant").
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        witness.archiveStage = .manuallyDeleted
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a witness an earlier relocate marked deleted must not vouch")
    }

    // MARK: - F5: the witness file must exist now, at its recorded size

    @Test func liveWitnessWhoseFileIsGoneIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        try FileManager.default.removeItem(at: fx.witnessFile)
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a stale catalog row whose file is gone must not vouch")
    }

    @Test func liveWitnessWhoseFileChangedSizeIsNotASurvivingCopy() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let witness = fx.record(at: fx.witnessFile)
        try Data(repeating: 7, count: 100).write(to: fx.witnessFile)
        expectMustCopy(fx.reconcile(source: source, witness: witness), source,
                       "a witness whose file no longer matches its recorded size must not vouch")
    }

    @Test func oneDeadAndOneLiveWitnessStillVouchesWithOnlyTheLiveOne() throws {
        let fx = try Fixture(); defer { fx.cleanup() }
        let source = fx.record(at: fx.srcFile)
        let live = fx.record(at: fx.witnessFile)
        let deadURL = fx.witnessVol.appendingPathComponent("test_family_copy.mov")
        try Data(repeating: 7, count: Int(fx.size)).write(to: deadURL)
        let dead = fx.record(at: deadURL)
        dead.purgedAt = Date()
        dead.lifecycleStage = .trashed
        let result = RelocateReconcile.reconcile(
            records: [source],
            allCatalogRecords: [source, dead, live],
            sourceVolumeRootPath: fx.src.path,
            destinationRoot: fx.dest,
            sourceFiles: [],
            destFiles: [],
            skipDupsOnOtherVolumes: true,
            hash: { _ in fx.md5 }
        )
        #expect(result.safelyRedundant.map(\.rec.id) == [source.id])
        #expect(result.safelyRedundant.first?.witnesses == [fx.witnessFile.path],
                "only the live, present witness may be recorded as the surviving copy")
    }
}
