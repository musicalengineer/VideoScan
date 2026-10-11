// SkippedRecordNeverVouchesTests.swift
// QA round 1 on the "skip is just a skip" change (2026-10-11).
//
// Once Migrate stopped labelling a skipped file `.manuallyDeleted` (and Show
// Again cleared the old false labels), the label no longer kept two drives
// from vouching for each other, and the witness note alone decided "accounted
// for" when retiring a drive. These pin the replacement rules:
//   BLOCKER 1  a record an earlier Migrate skipped (its own skip note) is NOT
//              a surviving copy for a later Migrate of another drive;
//   2a         a note carried to another path (copy / relink) or in the old
//              sourceless shape does not make a file accounted for;
//   2c         a skip whose witness has since left the catalog (Delete
//              Duplicates trashed it), sits on a retired drive, or is itself
//              a skipped record, is not accounted for;
//   2-retire   retiring re-proves a witness ON DISK at the file's size and
//              refuses, named, when one is gone;
//   2-relink   a skipped record is never a relink source (same predicate).

import Foundation
import Testing
@testable import VideoScan

@Suite("A record an earlier Migrate skipped never vouches")
@MainActor
struct SkippedRecordNeverVouchesTests {

    @Test func aRecordAnEarlierMigrateSkippedIsNotASurvivingCopy() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_skipped_vouch_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let driveA = root.appendingPathComponent("A"), driveB = root.appendingPathComponent("B")
        let dest = root.appendingPathComponent("dest")
        for d in [driveA, driveB, dest] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let fileA = driveA.appendingPathComponent("clip.mov"), fileB = driveB.appendingPathComponent("clip.mov")
        try Data(repeating: 3, count: 4096).write(to: fileA)
        try Data(repeating: 3, count: 4096).write(to: fileB)
        func rec(_ url: URL) -> VideoRecord {
            let r = VideoRecord(); r.filename = url.lastPathComponent; r.fullPath = url.path
            r.sizeBytes = 4096; r.partialMD5 = "HASH-SKIP"; return r
        }
        let onA = rec(fileA), onB = rec(fileB)
        // An earlier skip-dups Migrate of drive A skipped onA because onB existed.
        onA.notes = VideoScanModel.formatSafelyRedundantNote(stamp: "2026-10-11T10:00:00Z", source: onA.fullPath,
                                                              witnesses: [onB.fullPath], totalWitnessCount: 1)
        #expect(onA.archiveStage == .none)

        let result = RelocateReconcile.reconcile(
            records: [onB], allCatalogRecords: [onA, onB],
            sourceVolumeRootPath: driveB.path, destinationRoot: dest,
            sourceFiles: [.init(path: fileB.path, size: 4096)], destFiles: [],
            skipDupsOnOtherVolumes: true,
            witnessIndependent: RelocateReconcile.witnessIsNotTheSourceFile,
            hash: { _ in "HASH-SKIP" })

        #expect(result.safelyRedundant.isEmpty, "two drives vouched for each other")
        #expect(result.ready.map(\.id) == [onB.id], "drive B's file must be copied")
    }
}

@Suite("Retire — a skip counts only when its own witness still holds", .serialized)
@MainActor
struct RetireAccountedForTests {

    private func record(_ path: String, size: Int64 = 4096) -> VideoRecord {
        let r = VideoRecord(); r.fullPath = path; r.filename = (path as NSString).lastPathComponent
        r.sizeBytes = size; r.partialMD5 = "h"; return r
    }

    private func skipNote(source: String?, witness: String) -> String {
        VideoScanModel.formatSafelyRedundantNote(stamp: "2026-10-11T10:00:00Z", source: source,
                                                 witnesses: [witness], totalWitnessCount: 1)
    }

    @Test func aCarriedWitnessNoteDoesNotMakeTheOnlyCopyAccountedFor() {
        // The old sourceless shape, carried to a new drive by a later copy.
        let carried = record("/Volumes/NewDrive/clip.mov")
        carried.notes = skipNote(source: nil, witness: "/Volumes/RetiredRaid/clip.mov")
        #expect(!VideoScanModel.shouldOfferRetire(volumeRootPath: "/Volumes/NewDrive", in: [carried]),
                "the only copy was offered for retire on the strength of a carried note")
        // The new shape, but naming the path the record USED to have.
        let moved = record("/Volumes/NewDrive/clip.mov")
        moved.notes = skipNote(source: "/Volumes/OldDrive/clip.mov", witness: "/Volumes/Other/clip.mov")
        let witness = record("/Volumes/Other/clip.mov")
        #expect(!VideoScanModel.shouldOfferRetire(volumeRootPath: "/Volumes/NewDrive", in: [moved, witness]))
    }

    @Test func aSkipWhoseWitnessLeftTheCatalogIsNotAccountedFor() {
        let skipped = record("/Volumes/A/clip.mov")
        skipped.notes = skipNote(source: skipped.fullPath, witness: "/Volumes/B/clip.mov")
        // Delete Duplicates trashed the witness: its row is gone.
        #expect(!VideoScanModel.shouldOfferRetire(volumeRootPath: "/Volumes/A", in: [skipped]))
        // Positive control: the witness row is live.
        let witness = record("/Volumes/B/clip.mov")
        #expect(VideoScanModel.shouldOfferRetire(volumeRootPath: "/Volumes/A", in: [skipped, witness]))
        // Purged witness row: not a copy.
        witness.purgedAt = Date()
        #expect(!VideoScanModel.shouldOfferRetire(volumeRootPath: "/Volumes/A", in: [skipped, witness]))
        witness.purgedAt = nil
        // A witness on a retired drive: not a copy.
        #expect(!VideoScanModel.shouldOfferRetire(volumeRootPath: "/Volumes/A", in: [skipped, witness],
                                                  retiredRoots: ["/Volumes/B"]))
        // A witness that is itself a skipped record: two drives never vouch for each other.
        witness.notes = skipNote(source: witness.fullPath, witness: skipped.fullPath)
        #expect(!VideoScanModel.shouldOfferRetire(volumeRootPath: "/Volumes/A", in: [skipped, witness]))
    }

    @Test func retiringReprovesAWitnessOnDiskAndRefusesWhenItIsGone() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_retire_reprove_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let driveA = root.appendingPathComponent("A"), driveB = root.appendingPathComponent("B")
        for d in [driveA, driveB] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let witnessFile = driveB.appendingPathComponent("clip.mov")
        let model = VideoScanModel(logDirectory: root.appendingPathComponent("logs"))
        model.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog"))
        let skipped = record(driveA.appendingPathComponent("clip.mov").path, size: 100)
        let witness = record(witnessFile.path, size: 100)
        skipped.notes = skipNote(source: skipped.fullPath, witness: witness.fullPath)
        model.records = [skipped, witness]
        model.scanTargets = [CatalogScanTarget(searchPath: driveA.path)]
        let target = try #require(model.scanTargets.first)

        // The witness row is live, but its file is not on disk.
        #expect(!model.retireVolume(at: driveA.path, reason: "test", witnesses: [witness.fullPath]))
        #expect(!target.isRetired, "retired a drive whose skipped file has no copy on disk")

        try Data(repeating: 1, count: 100).write(to: witnessFile)
        #expect(model.retireVolume(at: driveA.path, reason: "test", witnesses: [witness.fullPath]))
        #expect(target.isRetired)
    }

    @Test func aSkippedRecordIsNeverARelinkSource() {
        let model = VideoScanModel()
        let skipped = record("/Volumes/A/clip.mov")
        skipped.notes = skipNote(source: skipped.fullPath, witness: "/Volumes/B/clip.mov")
        #expect(model.isRelinkProtectedCandidate(skipped, protected: VideoScanModel.RelinkProtectedRoots(roots: [])))
        let plain = record("/Volumes/A/other.mov")
        #expect(!model.isRelinkProtectedCandidate(plain, protected: VideoScanModel.RelinkProtectedRoots(roots: [])))
    }
}
