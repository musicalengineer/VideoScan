// DeleteDuplicatesTwoDrivesTests.swift
// The copy-count tier COUNTS DRIVES (Rick 2026-10-03, after a ledger row
// that read "permanent — 3 verified remain: keeper on A, sibling on A,
// sibling on A"): which physical devices hold the copies that remain is
// said on the row and in the ledger.
//
// Since 2026-10-09 (Trash only + keep one, design triage_delete_streamline
// §9 R3/R5) the drives no longer change the outcome: nothing is ever
// deleted outright, and one verified keeper is enough for the Trash. This
// suite now pins exactly that — the drives are still COUNTED (one volume
// however spelled is one drive; a copy dropped at the boundary takes its
// drive with it; an archive copy only on record is not counted) and NO
// count of drives or copies ever earns anything but the Trash; no sibling
// is read to reach a second drive.
//
// Dimensions: Logic (the decide() truth table, gather()'s drive counting)
// · Scale N/A (O(candidates) per row) · Media matrix N/A (synthetic bytes)
// · Isolation (temp catalog, ledger and plan root; scratch Trash) · Sensor
// (every place that prints the rule quotes the one sentence).
//
// Two real drives cannot be had inside one temp folder, so the two-drive
// cases go through `gather`'s `driveOf` seam; the one-drive cases run the
// real job end to end.
//
// Suite: DeleteDuplicatesTwoDrivesTests

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_twodrives_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let fileSize = FileHasher.segmentSize * 2

@Suite("Delete Duplicates — drives are counted, never decide (Trash only, keep one)", .serialized)
@MainActor
struct DeleteDuplicatesTwoDrivesTests {

    private struct Rig {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let copy: VideoRecord
        let siblings: [VideoRecord]
        let digest: String
        func cleanup() { try? FileManager.default.removeItem(at: dir) }
    }

    /// One "drive" (a folder): the keeper, the copy to go, and `siblings`
    /// verified siblings (`.review` rows with current stored evidence). NO
    /// archive copy.
    private func makeRig(_ label: String, siblings count: Int) -> Rig {
        let dir = tempDir(label)
        let bytes = (0..<fileSize).map { UInt8($0 % 193) }
        let digest = SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        let group = UUID()
        func record(_ name: String, _ disposition: DuplicateDisposition, evidence: Bool) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
            let r = VideoRecord()
            r.fullPath = url.path
            r.filename = name
            r.directory = dir.path
            r.sizeBytes = Int64(fileSize)
            r.partialMD5 = "same"
            r.durationSeconds = 61
            r.duplicateGroupID = group
            r.duplicateDisposition = disposition
            r.duplicateConfidence = .high
            if evidence {
                r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(fileSize))
            }
            return r
        }
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let keeper = record("keeper.mov", .keep, evidence: true)
        let copy = record("copy.mov", .extraCopy, evidence: false)
        let siblings = (0..<count).map { record("sibling \($0).mov", .review, evidence: true) }
        model.records = [keeper, copy] + siblings
        return Rig(dir: dir, root: dir.appendingPathComponent("plans", isDirectory: true), model: model,
                   keeper: keeper, copy: copy, siblings: siblings, digest: digest)
    }

    /// End to end: keeper + two verified siblings remain, all on ONE drive →
    /// the copy goes to the TRASH; the row and the ledger name the copies
    /// and the drive; the forecast said so too.
    @Test func threeCopiesOnOneDriveSendTheCopyToTheTrash() async throws {
        let rig = makeRig("onedrive", siblings: 2); defer { rig.cleanup() }
        let forecast = rig.model.deleteDuplicatesForecast(onVolume: rig.dir.path)
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir), planRoot: rig.root)
        job.start()
        await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.id == rig.copy.id && row.remainingVerifiedCopies == 3)
        #expect(row.status == .trashed && row.tier == .trash, "\(row.status), \(row.tierReason ?? "")")
        #expect(row.tierReason?.hasPrefix("to the Trash (3 verified remain: ") == true, Comment(rawValue: row.tierReason ?? ""))
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/copy.mov").path))
        #expect(job.result.deleted == 1 && job.runTally.trashed == 1 && job.runTally.deleted == 0)
        await rig.model.mediaLedger.waitForPendingWrites()
        let events = rig.model.mediaLedger.allEvents()
        #expect(events.filter { $0.event == .copyDeleted }.isEmpty, "the ledger records an outright delete")
        let trashed = try #require(events.first { $0.event == .copyTrashed })
        #expect(trashed.detail[MediaLedgerEvent.Detail.reason]?.contains("3 verified remain") == true)
        #expect(forecast.bucket(for: rig.copy.id) == .trash, "forecast said \(String(describing: forecast.bucket(for: rig.copy.id)))")
    }

    // MARK: The rule (pure)

    private func facts(_ n: Int, drives: [String], archive: Bool = false) -> DeletionTierFacts {
        var f = DeletionTierFacts()
        f.remainingVerifiedCopies = n
        f.countedDrives = drives.map { .init(key: $0, label: $0) }
        f.keeperDrive = f.countedDrives.first
        f.countsArchiveCopy = archive
        f.counted = (0..<n).map { "copy \($0)" }
        return f
    }

    @Test func theTruthTable() {
        typealias D = DeletionTierDecision
        func tier(_ n: Int, _ drives: [String], archive: Bool = false) -> DeletionTier? {
            D.decide(facts: facts(n, drives: drives, archive: archive)).tier
        }
        #expect(D.minimumForTrash == 1)
        for drives in [["A"], ["A", "B"], ["A", "B", "C"]] {
            for n in 1...5 {
                #expect(tier(n, drives) == .trash, "\(n) on \(drives): the Trash, never outright")
                #expect(tier(n, drives, archive: true) == .trash, "\(n) on \(drives) with the archive copy: the Trash")
            }
        }
        #expect(tier(0, []) == nil, "no verified copy: left alone")
        // Facts built without a stat (no drives known) count as one drive.
        #expect(D.decide(facts: DeletionTierFacts(remainingVerifiedCopies: 4)).tier == .trash)

        let oneDrive = D.decide(facts: facts(3, drives: ["LaCie"]))
        #expect(oneDrive.reason.hasPrefix("to the Trash (3 verified remain: copy 0, copy 1, copy 2 — on 1 drive"), Comment(rawValue: oneDrive.reason))
        let two = D.decide(facts: facts(3, drives: ["LaCie", "X9"]))
        #expect(two.reason.hasPrefix("to the Trash (3 verified remain: ") && two.reason.contains(" — on 2 drives (LaCie · X9)"),
                Comment(rawValue: two.reason))
    }

    /// Everything that PRINTS the rule quotes the one sentence.
    @Test func everyPrintedRuleFollowsTheOneSentence() throws {
        typealias D = DeletionTierDecision
        #expect(D.ruleSentence.contains("at least one verified copy remains") && D.ruleSentence.contains("Trash")
                && D.ruleSentence.contains("left alone") && D.ruleSentence.contains("Nothing is ever deleted outright"))
        #expect(ReclaimableEstimate.survivalRule == D.ruleSentence)
        #expect(DeletionTierText.preferTrashCaption.contains("never deletes outright"))
        let plan = try SourceTree.appCode(named: "DeleteDuplicatesPlan.swift")
        #expect(!plan.contains("earnsPermanent") && !plan.contains("minimumForPermanent"), "an outright-delete rule is back")
        let forecast = try SourceTree.appCode(named: "DeleteDuplicatesForecast.swift")
        #expect(!forecast.contains("case permanent"), "the forecast promises an outright delete")
        var repo = try #require(SourceTree.appSourceURL(named: "DeleteDuplicatesPlan.swift"))
        while repo.path != "/", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md").path) {
            repo = repo.deletingLastPathComponent()
        }
        let invariants = try String(contentsOf: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md"), encoding: .utf8)
        #expect(invariants.contains("TRASH ONLY") && invariants.contains("KEEP ONE")
                && invariants.contains("APFS volumes in one container") && invariants.contains("PHYSICAL DEVICE"))
    }

    // MARK: gather — which drives the counted copies sit on

    @Test func gatherCountsDistinctDrivesOfCountedCopiesOnly() throws {
        let rig = makeRig("gather", siblings: 2); defer { rig.cleanup() }
        // A hard link of sibling 0, a symlinked spelling of sibling 1's
        // folder, and a sibling whose file is gone (offline).
        let hardLink = rig.dir.appendingPathComponent("hardlink.mov")
        try FileManager.default.linkItem(at: URL(fileURLWithPath: rig.siblings[0].fullPath), to: hardLink)
        let alias = rig.dir.appendingPathComponent("alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: rig.dir)
        func other(_ path: String, _ label: String, evidenceFrom: String? = nil) -> DeletionTierCandidates.OtherCopy {
            .init(path: path, fixity: ContentFixity.captured(path: evidenceFrom ?? path, digest: rig.digest, byteCount: Int64(fileSize)),
                  label: label)
        }
        let gonePath = rig.dir.appendingPathComponent("gone.mov").path
        var candidates = DeletionTierCandidates()
        candidates.keeperPath = rig.keeper.fullPath
        candidates.keeperLabel = "keeper"
        candidates.otherCopies = [
            other(rig.siblings[0].fullPath, "sibling 0"),
            other(hardLink.path, "hard link"),
            other(alias.appendingPathComponent("sibling 1.mov").path, "sibling 1 (aliased)"),
            other(gonePath, "offline sibling", evidenceFrom: rig.siblings[1].fullPath),
        ]
        let real = DeletionTierFacts.gather(candidates, digest: rig.digest)
        #expect(real.remainingVerifiedCopies == 3, "keeper + sibling 0 + sibling 1; the hard link and the offline one are not counted: \(real.summary)")
        #expect(real.distinctDriveCount == 1, "one volume, however it is spelled, is one drive")
        if real.countedDrives.isEmpty {
            // Drive identity unreadable on this host (GitHub's macOS VM, CI
            // 2026-10-05): no drive is claimed and none named in the summary.
            #expect(!real.summary.contains(" — on "), "no drive claimed when identity is unreadable: \(real.summary)")
        } else {
            #expect(real.countedDrives.count == 1, "one volume is one drive: \(real.countedDrives)")
            #expect(real.summary.contains(" — on 1 drive"))
        }
        #expect(DeletionTierDecision.decide(facts: real).tier == .trash)

        // Two drives, through the seam: sibling 0 "is on" another drive —
        // named, and still the Trash.
        let twoDrives = DeletionTierFacts.gather(candidates, digest: rig.digest) { path, _ in
            path.hasSuffix("sibling 0.mov") ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
        }
        #expect(twoDrives.remainingVerifiedCopies == 3 && twoDrives.distinctDriveCount == 2)
        #expect(twoDrives.countedDrives.map(\.label) == ["LaCie", "X9"], "the keeper's drive first")
        #expect(DeletionTierDecision.decide(facts: twoDrives).tier == .trash)
        // A drive only an UNCOUNTED copy sits on does not count.
        let onlyOffline = DeletionTierFacts.gather(candidates, digest: rig.digest) { path, _ in
            path == gonePath ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
        }
        #expect(onlyOffline.distinctDriveCount == 1)
    }

    /// The removal boundary: the counted copy on the second drive changes →
    /// it is dropped and its drive goes with it; the keeper still holds, so
    /// the copy still goes to the Trash.
    @Test func aCopyDroppedAtTheBoundaryTakesItsDriveWithIt() throws {
        let rig = makeRig("boundary", siblings: 2); defer { rig.cleanup() }
        var candidates = DeletionTierCandidates()
        candidates.keeperPath = rig.keeper.fullPath
        candidates.otherCopies = rig.siblings.map { .init(path: $0.fullPath, fixity: $0.contentFixity, label: $0.filename, recordID: $0.id) }
        let twoDrives = DeletionTierFacts.gather(candidates, digest: rig.digest) { path, _ in
            path.hasSuffix("sibling 0.mov") ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
        }
        #expect(twoDrives.distinctDriveCount == 2)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: rig.siblings[0].fullPath))
        let after = twoDrives.recheck()
        #expect(after.remainingVerifiedCopies == 2 && after.distinctDriveCount == 1 && !after.droppedAtBoundary.isEmpty)
        #expect(DeletionTierDecision.decide(facts: after).tier == .trash)
    }

    /// An archive copy is COUNTED only through its stamp-bound fixity (codex
    /// 1606 #1) — on record alone it is "not verified now". Either way the
    /// outcome is the Trash: no archive exception earns an outright delete.
    @Test func onlyAVerifiedArchiveCopyIsCountedAndNeitherEarnsAnOutrightDelete() throws {
        let rig = makeRig("archive", siblings: 3); defer { rig.cleanup() }
        var candidates = DeletionTierCandidates()
        candidates.keeperPath = rig.keeper.fullPath
        let s0 = rig.siblings[0], s1 = rig.siblings[1], s2 = rig.siblings[2]
        candidates.otherCopies = [.init(path: s0.fullPath, fixity: s0.contentFixity, label: "sibling 0")]
        candidates.archiveCopies = [.init(path: s1.fullPath, digest: rig.digest, sizeBytes: Int64(fileSize),
                                          fixity: s1.contentFixity, label: "archive copy")]
        let counted = DeletionTierFacts.gather(candidates, digest: rig.digest)
        #expect(counted.remainingVerifiedCopies == 3 && counted.countsArchiveCopy && counted.distinctDriveCount == 1)
        #expect(DeletionTierDecision.decide(facts: counted).tier == .trash)

        candidates.archiveCopies[0].fixity = nil      // on record only — "not verified now"
        candidates.otherCopies.append(.init(path: s2.fullPath, fixity: s2.contentFixity, label: "sibling 2"))
        let onRecord = DeletionTierFacts.gather(candidates, digest: rig.digest)
        #expect(onRecord.remainingVerifiedCopies == 3 && onRecord.hasVerifiedArchive && !onRecord.countsArchiveCopy)
        #expect(DeletionTierDecision.decide(facts: onRecord).tier == .trash)
    }

    // MARK: Reads

    /// Keep one: the keeper alone reaches the goal, so no sibling read is
    /// ever worth making — whatever drive it sits on.
    @Test func noSiblingReadIsWorthMakingUnderKeepOne() {
        let goal = SiblingProver.Allowance.goal
        #expect(goal == 1)
        #expect(!SiblingProver.worthReading(count: 1, goal: goal), "the keeper is the one verified copy")
        #expect(!SiblingProver.worthReading(count: 3, goal: goal))
        #expect(SiblingProver.worthReading(count: 0, goal: goal), "only with nothing counted would a read earn anything")
    }

    /// End to end: keeper + one verified sibling and a sibling with NO
    /// evidence → nothing is read; the copy goes to the Trash.
    @Test func theRunReadsNoSibling() async throws {
        let rig = makeRig("noread", siblings: 2); defer { rig.cleanup() }
        rig.siblings[1].contentFixity = nil
        let forecast = rig.model.deleteDuplicatesForecast(onVolume: rig.dir.path)
        let lock = NSLock()
        var opened: [String] = []
        var hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)
        hooks.didOpen = { path in lock.withLock { opened.append(path) } }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: hooks, planRoot: rig.root)
        job.start()
        await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed && row.remainingVerifiedCopies == 2, "\(row.status) \(row.tierReason ?? "")")
        #expect(job.runTally.siblingReads == 0, "a sibling was read although nothing could be earned")
        #expect(!lock.withLock { opened }.contains(rig.siblings[1].fullPath))
        #expect(rig.siblings[1].contentFixity == nil)
        #expect(forecast.bucket(for: rig.copy.id) == .trash)
    }
}
