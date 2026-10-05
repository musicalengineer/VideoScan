// DeleteDuplicatesTwoDrivesTests.swift
// The copy-count tier counts DRIVES too (Rick 2026-10-03, after a ledger
// row that read "permanent — 3 verified remain: keeper on A, sibling on A,
// sibling on A"): a duplicate is deleted OUTRIGHT only when the verified
// copies that remain sit on at least two different drives, or the verified
// archive copy is among them. Three copies on one drive earn the Trash.
//
// Dimensions: Logic (the decide() truth table, gather()'s drive counting,
// the read rule) · Scale N/A (O(candidates) per row, unchanged) · Media
// matrix N/A (synthetic bytes; no media opened beyond the planner's reads)
// · Isolation (temp catalog, ledger and plan root; scratch Trash) · Sensor
// (every place that prints the rule quotes the constants).
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

@Suite("Delete Duplicates — an outright delete needs the remaining copies on two drives", .serialized)
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

    /// The finding, end to end: keeper + two verified siblings remain, all
    /// on ONE drive, no archive copy → the copy goes to the TRASH, never
    /// unlinked; the row and the ledger say why; the forecast said so too.
    @Test func threeCopiesOnOneDriveSendTheCopyToTheTrashNotOutright() async throws {
        let rig = makeRig("onedrive", siblings: 2); defer { rig.cleanup() }
        let forecast = rig.model.deleteDuplicatesForecast(onVolume: rig.dir.path)
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir), planRoot: rig.root)
        job.start()
        await job.task?.value

        let row = try #require(job.plan?.entries.first)
        #expect(row.id == rig.copy.id && row.remainingVerifiedCopies == 3)
        #expect(row.status == .trashed && row.tier == .trash,
                "three copies on one drive: \(row.status), \(row.tierReason ?? "")")
        #expect(row.tierReason?.hasPrefix("to the Trash, not gone — the 3 copies that remain are all on ") == true,
                Comment(rawValue: row.tierReason ?? ""))
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/copy.mov").path),
                "the copy was unlinked instead of moved to the Trash")
        #expect(job.result.deleted == 1 && job.runTally.trashed == 1 && job.runTally.deleted == 0)
        await rig.model.mediaLedger.waitForPendingWrites()
        let events = rig.model.mediaLedger.allEvents()
        #expect(events.filter { $0.event == .copyDeleted }.isEmpty, "the ledger records an outright delete")
        let trashed = try #require(events.first { $0.event == .copyTrashed })
        #expect(trashed.detail[MediaLedgerEvent.Detail.reason]?.contains("copies that remain are all on ") == true)
        // The forecast for the same fixture agrees with the run.
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
        func tier(_ n: Int, _ drives: [String], archive: Bool = false, preferTrash: Bool = false) -> DeletionTier? {
            D.decide(facts: facts(n, drives: drives, archive: archive), preferTrash: preferTrash).tier
        }
        #expect(tier(3, ["A"]) == .trash, "three on one drive")
        #expect(tier(3, ["A", "B"]) == .permanent, "three on two drives")
        #expect(tier(3, ["A"], archive: true) == .permanent, "three on one drive, one of them the archive copy")
        #expect(tier(2, ["A", "B"]) == .trash, "two never earn an outright delete")
        #expect(tier(2, ["A"], archive: true) == .trash)
        #expect(tier(5, ["A"]) == .trash, "any number on one drive")
        #expect(tier(5, ["A", "B", "C"]) == .permanent)
        #expect(tier(3, ["A", "B"], preferTrash: true) == .trash, "Prefer the Trash")
        #expect(tier(1, ["A"]) == nil && tier(1, ["A"], archive: true) == nil, "fewer than two: left alone")
        // Facts built without a stat (no drives known) count as ONE drive.
        #expect(D.decide(facts: DeletionTierFacts(remainingVerifiedCopies: 4), preferTrash: false).tier == .trash)

        let oneDrive = D.decide(facts: facts(3, drives: ["LaCie"]), preferTrash: false)
        #expect(oneDrive.reason.hasPrefix("to the Trash, not gone — the 3 copies that remain are all on LaCie ("), Comment(rawValue: oneDrive.reason))
        #expect(oneDrive.reason.contains("3 verified remain: copy 0, copy 1, copy 2 — on 1 drive"))
        let two = D.decide(facts: facts(3, drives: ["LaCie", "X9"]), preferTrash: false)
        #expect(two.reason.hasPrefix("space back now (3 verified remain: ") && two.reason.contains(" — on 2 drives"))
        #expect(D.minimumDrivesForPermanent == 2 && D.minimumForPermanent == 3 && D.minimumForTrash == 2)
    }

    /// Everything that PRINTS the rule quotes the constants.
    @Test func everyPrintedRuleFollowsTheConstants() throws {
        typealias D = DeletionTierDecision
        #expect(D.ruleSentence.contains("at least \(D.minimumForPermanent) verified copies remaining on at least \(D.minimumDrivesForPermanent) different drives"))
        #expect(D.ruleSentence.contains("verified archive copy") && D.ruleSentence.contains("Trash") && D.ruleSentence.contains("left alone"))
        #expect(ReclaimableEstimate.survivalRule == D.ruleSentence)
        #expect(DeletionTierText.preferTrashCaption.contains("on at least two different drives"))
        let plan = try SourceTree.appSource(named: "DeleteDuplicatesPlan.swift")
        #expect(plan.contains("if earnsPermanent(count: n, distinctDrives: facts.distinctDriveCount, countsArchiveCopy: facts.countsArchiveCopy) {"),
                "decide() no longer asks where the copies sit")
        let forecast = try SourceTree.appSource(named: "DeleteDuplicatesForecast.swift")
        #expect(forecast.contains("DeletionTierDecision.earnsPermanent(") && forecast.contains("SiblingProver.worthReading("),
                "the forecast must use the tier's own rule and the prover's own read rule")
        let steward = try SourceTree.appSource(named: "StewardEvidence.swift")
        #expect(steward.contains("SiblingProver.worthReading(") && steward.contains("DeletionTierDecision.decide(facts: hoped.facts"))
        var repo = try #require(SourceTree.appSourceURL(named: "DeleteDuplicatesPlan.swift"))
        while repo.path != "/", !FileManager.default.fileExists(atPath: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md").path) {
            repo = repo.deletingLastPathComponent()
        }
        let invariants = try String(contentsOf: repo.appendingPathComponent("docs/practices/invariants/MediaOps.md"), encoding: .utf8)
        #expect(invariants.contains("two different drives") && invariants.contains("APFS volumes in one container")
                && invariants.contains("PHYSICAL DEVICE"))
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
            // 2026-10-05): no drive is claimed and none named in the summary —
            // and the decision below must still be the conservative one.
            #expect(!real.summary.contains(" — on "), "no drive claimed when identity is unreadable: \(real.summary)")
        } else {
            #expect(real.countedDrives.count == 1, "one volume is one drive: \(real.countedDrives)")
            #expect(real.summary.contains(" — on 1 drive"))
        }
        #expect(DeletionTierDecision.decide(facts: real, preferTrash: false).tier == .trash)

        // Two drives, through the seam: sibling 0 "is on" another drive.
        let twoDrives = DeletionTierFacts.gather(candidates, digest: rig.digest) { path, _ in
            path.hasSuffix("sibling 0.mov") ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
        }
        #expect(twoDrives.remainingVerifiedCopies == 3 && twoDrives.distinctDriveCount == 2)
        #expect(twoDrives.countedDrives.map(\.label) == ["LaCie", "X9"], "the keeper's drive first")
        #expect(DeletionTierDecision.decide(facts: twoDrives, preferTrash: false).tier == .permanent)
        // A drive only an UNCOUNTED copy sits on does not count.
        let onlyOffline = DeletionTierFacts.gather(candidates, digest: rig.digest) { path, _ in
            path == gonePath ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
        }
        #expect(onlyOffline.distinctDriveCount == 1)
    }

    /// The removal boundary: the counted copy on the second drive changes →
    /// its drive goes with it → permanent becomes the Trash.
    @Test func aCopyDroppedAtTheBoundaryTakesItsDriveWithIt() throws {
        let rig = makeRig("boundary", siblings: 2); defer { rig.cleanup() }
        var candidates = DeletionTierCandidates()
        candidates.keeperPath = rig.keeper.fullPath
        candidates.otherCopies = rig.siblings.map { .init(path: $0.fullPath, fixity: $0.contentFixity, label: $0.filename, recordID: $0.id) }
        let twoDrives = DeletionTierFacts.gather(candidates, digest: rig.digest) { path, _ in
            path.hasSuffix("sibling 0.mov") ? .init(key: "B", label: "X9") : .init(key: "A", label: "LaCie")
        }
        #expect(twoDrives.distinctDriveCount == 2 && DeletionTierDecision.decide(facts: twoDrives, preferTrash: false).tier == .permanent)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: rig.siblings[0].fullPath))
        let after = twoDrives.recheck()
        #expect(after.remainingVerifiedCopies == 2 && after.distinctDriveCount == 1 && !after.droppedAtBoundary.isEmpty)
        #expect(DeletionTierDecision.decide(facts: after, preferTrash: false).tier == .trash)
    }

    /// An archive copy among the COUNTED copies earns the outright delete on
    /// one drive; an archive copy merely on record (not verified now) does not.
    @Test func onlyACountedArchiveCopyEarnsTheException() throws {
        let rig = makeRig("archive", siblings: 3); defer { rig.cleanup() }
        var candidates = DeletionTierCandidates()
        candidates.keeperPath = rig.keeper.fullPath
        let s0 = rig.siblings[0], s1 = rig.siblings[1], s2 = rig.siblings[2]
        candidates.otherCopies = [.init(path: s0.fullPath, fixity: s0.contentFixity, label: "sibling 0")]
        candidates.archiveCopies = [.init(path: s1.fullPath, digest: rig.digest, sizeBytes: Int64(fileSize),
                                          fixity: s1.contentFixity, label: "archive copy")]
        let counted = DeletionTierFacts.gather(candidates, digest: rig.digest)
        #expect(counted.remainingVerifiedCopies == 3 && counted.countsArchiveCopy && counted.distinctDriveCount == 1)
        #expect(DeletionTierDecision.decide(facts: counted, preferTrash: false).tier == .permanent)

        candidates.archiveCopies[0].fixity = nil      // on record only — "not verified now"
        candidates.otherCopies.append(.init(path: s2.fullPath, fixity: s2.contentFixity, label: "sibling 2"))
        let onRecord = DeletionTierFacts.gather(candidates, digest: rig.digest)
        #expect(onRecord.remainingVerifiedCopies == 3 && onRecord.hasVerifiedArchive && !onRecord.countsArchiveCopy)
        #expect(DeletionTierDecision.decide(facts: onRecord, preferTrash: false).tier == .trash,
                "an archive copy that is only on record must not earn an outright delete")
    }

    // MARK: Reads

    @Test func aReadThatCannotChangeTheTierIsNotMade() {
        func worth(_ count: Int, _ drives: Set<String>, _ candidate: String, archive: Bool = false, goal: Int = 3) -> Bool {
            SiblingProver.worthReading(count: count, drives: drives, countsArchiveCopy: archive, candidateDrive: candidate, goal: goal)
        }
        #expect(worth(1, ["A"], "A"), "below two: any sibling is worth reading (toward the Trash)")
        #expect(!worth(2, ["A"], "A"), "two on A: a third on A still means the Trash — no read")
        #expect(worth(2, ["A"], "B"), "…but a sibling on a second drive would make it permanent")
        #expect(worth(2, ["A", "B"], "A"), "two drives already spanned: the third copy anywhere counts")
        #expect(worth(2, ["A"], "A", archive: true), "the archive copy is counted: the third copy anywhere counts")
        // Codex #258 F11 (this line used to pin the denial): three counted on
        // ONE drive — a sibling on a second drive is the read that earns the
        // outright delete; one more on the same drive still changes nothing.
        #expect(worth(3, ["A"], "B"), "three on A: a sibling on B is worth reading")
        #expect(!worth(3, ["A"], "A") && !worth(3, ["A", "B"], "C"), "no read that cannot lift the tier")
        #expect(!worth(2, ["A"], "B", goal: 2), "Prefer the Trash: the goal is two")
    }

    /// End to end: keeper + one verified sibling (two, one drive) and a
    /// third sibling with NO evidence on the same drive → the third is not
    /// read (it could only make "three on one drive"), and the copy goes to
    /// the Trash.
    @Test func theRunDoesNotReadASameDriveSiblingJustToReachThree() async throws {
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
        #expect(job.runTally.siblingReads == 0, "a sibling was read although it could not change the tier")
        #expect(!lock.withLock { opened }.contains(rig.siblings[1].fullPath))
        #expect(rig.siblings[1].contentFixity == nil)
        #expect(forecast.bucket(for: rig.copy.id) == .trash && forecast.siblingReads == 0 && forecast.trashMayBecomePermanent == 0,
                "forecast: \(String(describing: forecast.bucket(for: rig.copy.id))), \(forecast.siblingReads) reads")
    }

    /// The forecast's pure rule, with drives given: same-drive survivors →
    /// trash; a second drive → permanent; a readable sibling on a second
    /// drive is the read that may make a Trash row permanent.
    @Test func theForecastFollowsTheTiersRuleAndTheReadRule() {
        typealias F = DeleteDuplicatesForecast
        let g = UUID(), keeper = UUID(), row = UUID(), s1 = UUID(), s2 = UUID()
        func copy(_ id: UUID, _ digest: String?, _ drive: String) -> F.Copy {
            .init(id: id, sizeBytes: 10, digest: digest, online: true, isArchive: false, archiveDigest: nil, drive: drive)
        }
        func run(_ d1: String, _ d2: String, s2Digest: String? = "d") -> F {
            F.compute(.init(rows: [.init(id: row, sizeBytes: 10, digest: "d", keeperID: keeper, groupID: g)],
                            copies: [keeper: copy(keeper, "d", "/volumes/a"), row: copy(row, "d", "/volumes/b"),
                                     s1: copy(s1, "d", d1), s2: copy(s2, s2Digest, d2)],
                            members: [g: [keeper, row, s1, s2]], preferTrash: false))
        }
        #expect(run("/volumes/a", "/volumes/a").bucket(for: row) == .trash, "the only copy on B, three on A: the Trash")
        #expect(run("/volumes/a", "/volumes/c").bucket(for: row) == .permanent)
        let unread = run("/volumes/a", "/volumes/a", s2Digest: nil)
        #expect(unread.bucket(for: row) == .trash && unread.siblingReads == 0 && unread.trashMayBecomePermanent == 0)
        let secondDrive = run("/volumes/a", "/volumes/c", s2Digest: nil)
        #expect(secondDrive.bucket(for: row) == .trash && secondDrive.siblingReads == 1 && secondDrive.trashMayBecomePermanent == 1)
        // A copy whose volume is not a drive (a disk image, unidentified)
        // never adds one — and is not worth a read once two are counted.
        #expect(run("/volumes/a", F.notADrive).bucket(for: row) == .trash)
        let imageUnread = run("/volumes/a", F.notADrive, s2Digest: nil)
        #expect(imageUnread.bucket(for: row) == .trash && imageUnread.siblingReads == 0 && imageUnread.trashMayBecomePermanent == 0)
    }
}
