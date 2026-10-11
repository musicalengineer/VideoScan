// DeleteDuplicatesTargetGateTests.swift
// R4 (design triage_delete_streamline_2026_10_09 §9 R4, codex F4): keeper
// precedence is ELECTION, not protection. Each kind of copy that may never
// be a target of Delete Duplicates has a named execution gate
// (DeleteDuplicatesTargetGates.swift lists them). This suite pins the gates
// that had no Delete Duplicates test of their own:
//   • a network mount (new gate) — before the move;
//   • half of a recovered A/V pair (new gate);
//   • a copy LONGER than an archive master of its content, or whose length
//     cannot be compared with one (new gate — the Tier 1 rule);
//   • a drive marked Archive backup (the Read-only gate; no dup test before).
// The Master Archive tree / volume and Read-only gates are pinned by the
// Codex 258 suites (HoldBoundary, Round2–4) and ReadOnlyVolume*.
//
// Every hold: the file at home, untouched, never quarantined; a skip with
// its reason (not Review); the run moves the others.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_dupgates_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: url.path, contents: Data(bytes)) }

private func plainSHA256(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private let fileSize = FileHasher.segmentSize * 2

/// keeper + two identical extras (a three-copy group: both pre-selected).
@MainActor
private struct Rig {
    let dir: URL
    let root: URL
    let model: VideoScanModel
    let keeper: VideoRecord
    let gated: VideoRecord
    let other: VideoRecord
    let bytes: [UInt8]

    init(_ label: String) {
        let folder = tempDir(label)
        let content = (0..<fileSize).map { UInt8($0 % 233) }
        let catalog = VideoScanModel()
        catalog.catalogStore = CatalogStore(directory: folder.appendingPathComponent("catalog", isDirectory: true))
        catalog.mediaLedger = MediaLedger(directory: folder.appendingPathComponent("ledger", isDirectory: true))
        let group = UUID()
        func rec(_ name: String, _ d: DuplicateDisposition) -> VideoRecord {
            let url = folder.appendingPathComponent(name); write(url, content)
            let r = VideoRecord()
            r.fullPath = url.path; r.filename = name; r.directory = folder.path
            r.sizeBytes = Int64(fileSize); r.partialMD5 = "same"; r.durationSeconds = 61
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            return r
        }
        let k = rec("keeper.mov", .keep)
        k.contentFixity = ContentFixity.captured(path: k.fullPath, digest: plainSHA256(URL(fileURLWithPath: k.fullPath)),
                                                 byteCount: Int64(fileSize))
        let g = rec("gated.mov", .extraCopy)
        let o = rec("other.mov", .extraCopy)
        catalog.records = [k, g, o]
        dir = folder
        root = folder.appendingPathComponent("plans", isDirectory: true)
        bytes = content
        model = catalog
        keeper = k
        gated = g
        other = o
    }

    var hooks: SignatureVerification.Hooks { SignatureVerification.Hooks.live.withScratchTrash(in: dir) }
    func inTrash(_ r: VideoRecord) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("Trash/\(r.filename)").path)
    }
    func atHome(_ r: VideoRecord) -> Bool { FileManager.default.fileExists(atPath: r.fullPath) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }

    /// A promoted Master Archive copy of the keeper's content, `seconds` long.
    func addArchiveMaster(seconds: Double) {
        let url = dir.appendingPathComponent("archive-master.mov"); write(url, bytes)
        let a = VideoRecord()
        a.fullPath = url.path; a.filename = url.lastPathComponent; a.directory = dir.path
        a.sizeBytes = Int64(fileSize); a.durationSeconds = seconds
        a.derivedFrom = keeper.id
        a.derivationKind = ArchivePromotion.derivationKind
        a.archiveFixity = ArchiveFixity(digest: plainSHA256(url), verifiedAt: Date(), sizeBytes: Int64(fileSize))
        model.records.append(a)
    }

    func run(_ configure: (DeleteDuplicatesJob) -> Void = { _ in }) async -> DeleteDuplicatesJob {
        let job = DeleteDuplicatesJob(model: model, volumePath: dir.path, hooks: hooks, planRoot: root)
        configure(job)
        job.start(); await job.task?.value
        return job
    }
}

@MainActor
private func expectHeld(_ job: DeleteDuplicatesJob, _ rig: Rig, containing words: String,
                        sourceLocation: SourceLocation = #_sourceLocation) throws {
    let plan = try #require(job.plan, sourceLocation: sourceLocation)
    let row = try #require(plan.entries.first { $0.id == rig.gated.id }, sourceLocation: sourceLocation)
    #expect(row.status == .skipped && row.note.contains(words), "\(row.status): \(row.note)", sourceLocation: sourceLocation)
    #expect(row.quarantineDirectory == nil, sourceLocation: sourceLocation)
    #expect(rig.atHome(rig.gated) && !rig.inTrash(rig.gated), "held at home, untouched", sourceLocation: sourceLocation)
    #expect((try? Data(contentsOf: URL(fileURLWithPath: rig.gated.fullPath))) == Data(rig.bytes), sourceLocation: sourceLocation)
    #expect(rig.gated.duplicateDisposition == .extraCopy, "a hold never re-marks the copy Review", sourceLocation: sourceLocation)
    #expect(plan.entries.first { $0.id == rig.other.id }?.status == .trashed, "the run moves the others",
            sourceLocation: sourceLocation)
}

@Suite("Delete Duplicates — never a target: the named gates (R4)", .serialized)
@MainActor
struct DeleteDuplicatesTargetGateTests {

    @Test func aCopyOnANetworkShareIsNeverATarget() async throws {
        let rig = Rig("network"); defer { rig.cleanup() }
        let gatedPath = rig.gated.fullPath
        let job = await rig.run { $0.isNetworkMountForPath = { $0 == gatedPath || $0.hasSuffix("/gated.mov") } }
        try expectHeld(job, rig, containing: "network drive")
    }

    @Test func halfOfARecoveredAVPairIsNeverATarget() async throws {
        let rig = Rig("avpair"); defer { rig.cleanup() }
        rig.gated.pairGroupID = UUID()
        let job = await rig.run()
        try expectHeld(job, rig, containing: ExcessCopiesPlan.pairReason)
    }

    @Test func aCopyLongerThanTheArchiveMasterIsNeverATarget() async throws {
        let rig = Rig("longer"); defer { rig.cleanup() }
        rig.addArchiveMaster(seconds: 30)            // the archive is missing footage
        rig.other.durationSeconds = 30               // the other extra fits
        let job = await rig.run()
        try expectHeld(job, rig, containing: "LONGER than the archive master")
    }

    @Test func aCopyWhoseLengthCannotBeComparedWithTheMasterIsHeld() async throws {
        let rig = Rig("unknown"); defer { rig.cleanup() }
        rig.addArchiveMaster(seconds: 61)
        rig.gated.durationSeconds = 0                // never probed
        let job = await rig.run()
        try expectHeld(job, rig, containing: "length could not be compared")
    }

    /// The keeper IS the archive copy: the copy is proven identical to it,
    /// so the length rule has nothing to say — it goes to the Trash.
    @Test func whenTheKeeperIsTheArchiveCopyTheLengthRuleDoesNotHold() async throws {
        let rig = Rig("keeperarchive"); defer { rig.cleanup() }
        rig.keeper.derivationKind = ArchivePromotion.derivationKind
        rig.gated.durationSeconds = 0
        let job = await rig.run()
        #expect(job.plan?.entries.allSatisfy { $0.status == .trashed } == true,
                "\(job.plan?.entries.map { "\($0.filename): \($0.status) \($0.note)" } ?? [])")
    }

    /// Marking a drive Archive backup makes it Read only — one mark, one
    /// gate. Nothing on it is ever a target.
    @Test func aDriveMarkedArchiveBackupIsNeverATarget() async throws {
        let rig = Rig("backup"); defer { rig.cleanup() }
        let target = CatalogScanTarget(searchPath: rig.dir.path)
        target.isReachable = true
        rig.model.scanTargets = [target]
        rig.model.setVolumeArchiveBackup(true, for: target)
        #expect(target.readOnlyMark?.isArchiveBackup == true)
        let job = await rig.run()
        let plan = try #require(job.plan)
        #expect(plan.entries.allSatisfy { $0.status != .trashed && $0.status != .deleted },
                "\(plan.entries.map { "\($0.filename): \($0.status) \($0.note)" })")
        #expect(rig.atHome(rig.gated) && rig.atHome(rig.other) && rig.atHome(rig.keeper))

        // A REVIEWED plan that names them anyway: each row is held at its
        // turn, named — the gate is an execution gate, not a planning filter.
        let picks = [rig.gated, rig.other].map { ReviewedDuplicatePick(recordID: $0.id, path: $0.fullPath, keeperID: rig.keeper.id) }
        let batch = await rig.model.reviewedDuplicateBatch(picks)
        let reviewed = DeleteDuplicatesJob(model: rig.model, reviewed: try #require(batch.plans.first), hooks: rig.hooks, planRoot: rig.root)
        reviewed.start(); await reviewed.task?.value
        let rows = try #require(reviewed.plan?.entries)
        #expect(rows.count == 2 && rows.allSatisfy { $0.status == .skipped && $0.note.contains("Read only") },
                "\(rows.map { "\($0.filename): \($0.status) \($0.note)" })")
        #expect(rig.atHome(rig.gated) && rig.atHome(rig.other))
    }
}
