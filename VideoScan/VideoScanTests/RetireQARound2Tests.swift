// QA round 2 red tests (2026-10-11).
import Foundation
import Testing
@testable import VideoScan

@Suite("Retire QA round 2", .serialized)
@MainActor
struct RetireQARound2Tests {

    private func record(_ path: String, size: Int64 = 100) -> VideoRecord {
        let r = VideoRecord(); r.fullPath = path; r.filename = (path as NSString).lastPathComponent
        r.sizeBytes = size; r.partialMD5 = "h"; return r
    }

    // R2-1: source="…" escapes `"` but not `\`; the parser treats `\` as an
    // escape, so a skipped file whose name contains a backslash never matches
    // its own note -> not accounted for -> it is a LIVE witness again (B1 reopens
    // for that file). Pins VideoScanModel+Relocate.swift:170 / +RetireVolume.swift:279.
    @Test func aSkippedFileWithABackslashInItsNameIsAccountedForAndNeverVouches() {
        let path = "/Volumes/X/Tape 3\\4 capture.mov"
        let r = record(path)
        r.notes = VideoScanModel.formatSafelyRedundantNote(stamp: "2026-10-11T10:00:00Z", source: path,
                                                           witnesses: ["/Volumes/Y/clip.mov"], totalWitnessCount: 1)
        #expect(VideoScanModel.isAccountedForRetire(archiveStage: r.archiveStage, notes: r.notes, fullPath: path))
        #expect(!r.isLiveRelocateWitness, "a skipped file vouched for another drive")
    }

    // R2-2: a witness path with a backslash round-trips too (else the skip is
    // never disposed and the drive can never retire).
    @Test func aWitnessPathWithABackslashRoundTrips() {
        let w = "/Volumes/Y/Tape 3\\4.mov"
        let note = VideoScanModel.formatSafelyRedundantNote(stamp: "s", source: "/Volumes/X/a.mov",
                                                            witnesses: [w], totalWitnessCount: 1)
        #expect(VideoScanModel.ownSkipWitnesses(notes: note, fullPath: "/Volumes/X/a.mov") == [w])
    }

    // R2-3: retireVolume re-proves skipped files only. A record on the drive
    // that is neither labelled missing nor skipped (a scan found it after the
    // Volumes-window cache said "all accounted for", or Show Again cleared its
    // label while the sheet was open) is retired with it.
    // Pins VideoScanModel+RetireVolume.swift:282-388.
    @Test func retireRefusesWhenTheDriveHoldsAFileNobodyAccountedFor() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_retire_r2_\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let driveA = root.appendingPathComponent("A"), driveB = root.appendingPathComponent("B")
        for d in [driveA, driveB] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let witnessFile = driveB.appendingPathComponent("clip.mov")
        try Data(repeating: 1, count: 100).write(to: witnessFile)
        let model = VideoScanModel(logDirectory: root.appendingPathComponent("logs"))
        model.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog"))
        let skipped = record(driveA.appendingPathComponent("clip.mov").path)
        skipped.notes = VideoScanModel.formatSafelyRedundantNote(stamp: "s", source: skipped.fullPath,
                                                                 witnesses: [witnessFile.path], totalWitnessCount: 1)
        let witness = record(witnessFile.path)
        let onlyCopy = record(driveA.appendingPathComponent("only-copy.mov").path)
        model.records = [skipped, witness, onlyCopy]
        model.scanTargets = [CatalogScanTarget(searchPath: driveA.path)]
        #expect(!VideoScanModel.shouldOfferRetire(volumeRootPath: driveA.path, in: model.records))
        #expect(!model.retireVolume(at: driveA.path, reason: "test", witnesses: [witnessFile.path]),
                "retired a drive holding a file with no copy anywhere")
    }

    // R2-4: the Volumes-window gate "at least one SAFE witness" is satisfied
    // by a witness that has left the catalog. disposalWitnesses returns every
    // own witness, not the ones that hold.
    // Pins VideoScanModel+VolumeStatusCache.swift:114-117 / :298.
    @Test func aDeadWitnessOnASafeDriveDoesNotMakeTheDriveSafeToRetire() async {
        let src = "/Volumes/X/a.mov", raid = "/Volumes/Raid/a.mov", flaky = "/Volumes/Flaky/a.mov"
        let note = VideoScanModel.formatSafelyRedundantNote(stamp: "s", source: src,
                                                            witnesses: [raid, flaky], totalWitnessCount: 2)
        let records = [
            VolumeStatusRecordSnap(fullPath: src, isManuallyDeleted: false,
                                   skipWitnesses: VideoScanModel.ownSkipWitnesses(notes: note, fullPath: src),
                                   isLiveWitness: false, originVolume: nil, originalFullPath: nil, notes: nil),
            // Delete Duplicates trashed the RAID copy: row purged, not live.
            VolumeStatusRecordSnap(fullPath: raid, isManuallyDeleted: false, skipWitnesses: nil,
                                   isLiveWitness: false, originVolume: nil, originalFullPath: nil, notes: nil),
            VolumeStatusRecordSnap(fullPath: flaky, isManuallyDeleted: false, skipWitnesses: nil,
                                   isLiveWitness: true, originVolume: nil, originalFullPath: nil, notes: nil),
        ]
        let targets = [
            VolumeStatusTargetSnap(searchPath: "/Volumes/X", role: .workspace, trust: .reliable),
            VolumeStatusTargetSnap(searchPath: "/Volumes/Raid", role: .archive, trust: .reliable),
            VolumeStatusTargetSnap(searchPath: "/Volumes/Flaky", role: .workspace, trust: .unreliable),
        ]
        let out = await VideoScanModel.computeVolumeStatuses(records: records, targets: targets)
        #expect(out["/Volumes/X"]?.allDisposed == true)
        #expect(out["/Volumes/X"]?.canRetire == false,
                "the only copy left is on an unreliable drive, yet the drive reads safe to retire")
    }
}
