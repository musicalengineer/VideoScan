// DeleteDuplicatesTrashOnlyTests.swift
// R3 (design triage_delete_streamline_2026_10_09 §2.1 / §9 R3, codex F3):
// TRASH ONLY is an EXECUTION rule of Delete Duplicates, not a button
// removal. Rick's ruling 2026-10-09: "the app never deletes permanently —
// trash day is the permanent step."
//
// Pinned here:
//   1. the disk worker given a recorded `.permanent` decision (a legacy
//      plan, or any caller) moves the file to the Trash — it never unlinks;
//   2. a fresh run whose family would once have earned an outright delete
//      (archive copy + sibling + keeper) moves the copy to the Trash;
//   3. a RESUMED legacy plan whose row was recorded `.permanent` and left
//      in quarantine by a crash is put back, re-verified, and goes to the
//      Trash;
//   4. a failed move to the Trash is a visible HOLD — the file is back at
//      its path, untouched — never an unlink and never "failed";
//   5. SENSOR: no removeItem / unlink / permanent disposal is reachable from
//      DeleteDuplicatesJob.swift.
//
// Synthetic files in temp folders only; the Trash step is always a scratch
// folder (never Rick's real Trash).

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_duptrashonly_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func write(_ url: URL, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: url.path, contents: Data(bytes)) }

private func plainSHA256(_ url: URL) -> String {
    SHA256.hash(data: (try? Data(contentsOf: url)) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private let fileSize = FileHasher.segmentSize * 2

private struct TrashRefused: Error, LocalizedError {
    var errorDescription: String? { "the volume has no usable Trash" }
}

@MainActor
private func dupRecord(_ url: URL, group: UUID, _ d: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = url.path; r.filename = url.lastPathComponent
    r.directory = url.deletingLastPathComponent().path
    r.sizeBytes = Int64(fileSize); r.partialMD5 = "same"; r.durationSeconds = 61
    r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
    return r
}

/// keeper (with a stored fixity) + one identical extra copy, in `dir`.
@MainActor
private struct Rig {
    let dir: URL
    let root: URL
    let model: VideoScanModel
    let keeper: VideoRecord
    let copy: VideoRecord
    let bytes: [UInt8]

    init(_ label: String) {
        dir = tempDir(label)
        root = dir.appendingPathComponent("plans", isDirectory: true)
        bytes = (0..<fileSize).map { UInt8($0 % 211) }
        let keeperURL = dir.appendingPathComponent("keeper.mov"); write(keeperURL, bytes)
        let copyURL = dir.appendingPathComponent("copy.mov"); write(copyURL, bytes)
        model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
        let group = UUID()
        keeper = dupRecord(keeperURL, group: group, .keep)
        keeper.contentFixity = ContentFixity.captured(path: keeperURL.path, digest: plainSHA256(keeperURL),
                                                      byteCount: Int64(fileSize))
        copy = dupRecord(copyURL, group: group, .extraCopy)
        model.records = [keeper, copy]
    }

    var trashFolder: URL { dir.appendingPathComponent("Trash", isDirectory: true) }
    var hooks: SignatureVerification.Hooks { SignatureVerification.Hooks.live.withScratchTrash(in: dir) }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

@Suite("Delete Duplicates — Trash only is an execution rule (R3)", .serialized)
@MainActor
struct DeleteDuplicatesTrashOnlyTests {

    // MARK: 1. The disk worker

    /// A decision recorded as `.permanent` — by a legacy plan, or by any
    /// caller — is executed as the Trash. Red on main: `.deleted` (unlinked).
    @Test func aRecordedPermanentDecisionIsExecutedAsTheTrash() throws {
        let rig = Rig("worker"); defer { rig.cleanup() }
        let fixity = try #require(rig.keeper.contentFixity)
        guard case .held(let hold) = SignatureVerification.holdForSingleRead(
                keeperPath: rig.keeper.fullPath, keeperFixity: fixity, duplicatePath: rig.copy.fullPath, hooks: rig.hooks),
              case .verified(let ticket) = SignatureVerification.verifyHeld(hold, hooks: rig.hooks) else {
            Issue.record("expected a verified ticket"); return
        }
        let legacy = DeletionTierDecision(tier: .permanent, remainingVerifiedCopies: 3,
                                          reason: "space back now (a plan written before 2026-10-09)")
        let two = DeleteDuplicatesDiskWorker.deleteQuarantined(ticket, decided: legacy, facts: DeletionTierFacts(),
                                                               preferTrash: false,
                                                               keeperFilename: "keeper.mov", hooks: rig.hooks)
        guard case .trashed(_, let location, _) = two.outcome else {
            Issue.record("a recorded permanent disposal must go to the Trash — got \(two.outcome)"); return
        }
        #expect(location.hasPrefix(rig.trashFolder.path), "in the (scratch) Trash: \(location)")
        #expect(FileManager.default.fileExists(atPath: location))
        #expect(two.decision.tier == .trash, "the decision the file went by says Trash")
        #expect(two.decision.reason.contains("Trash only"), Comment(rawValue: two.decision.reason))
    }

    // MARK: 2. A fresh run

    /// Archive copy + verified sibling + keeper: three verified copies
    /// that once earned "space back now". The copy goes to the Trash.
    @Test func aFamilyThatOnceEarnedAnOutrightDeleteGoesToTheTrash() async throws {
        let rig = Rig("fresh"); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: rig.hooks, planRoot: rig.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        #expect(plan.entries[0].status == .trashed, Comment(rawValue: plan.entries[0].note))
        #expect(plan.entries[0].tier == .trash)
        #expect(!FileManager.default.fileExists(atPath: rig.copy.fullPath))
        let trashed = rig.trashFolder.appendingPathComponent("copy.mov")
        #expect((try? Data(contentsOf: trashed)) == Data(rig.bytes), "the bytes are in the Trash, not gone")
        #expect(plan.counts.deleted == 0 && plan.counts.freedBytes == 0)
        await rig.model.mediaLedger.waitForPendingWrites()
        let all = rig.model.mediaLedger.allEvents()
        #expect(all.filter { $0.event == .copyDeleted }.isEmpty, "the ledger never records an outright delete")
        let events = all.filter { $0.event == .copyTrashed }
        #expect(events.count == 1 && events.first?.detail[MediaLedgerEvent.Detail.tier] == "trash")
    }

    // MARK: 3. A resumed legacy plan

    /// A plan written before the ruling: the row recorded `.permanent`, and
    /// a crash left the file in its quarantine folder. Resume puts it back,
    /// re-verifies it, and the Trash takes it.
    @Test func aResumedLegacyPermanentRowGoesToTheTrash() async throws {
        let rig = Rig("resume"); defer { rig.cleanup() }
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper)
        var e = DeleteDuplicatesPlan.Entry(id: rig.copy.id, path: rig.copy.fullPath, filename: rig.copy.filename,
                                           sizeBytes: rig.copy.sizeBytes, keeperID: rig.keeper.id,
                                           keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename,
                                           keeperStamp: FileIdentityStamp.capture(path: rig.keeper.fullPath))
        var plan = DeleteDuplicatesPlan(volumePath: rig.dir.path, catalogLocation: rig.model.catalogStore.fileLocation,
                                        crossVolumeMode: false, skippedBeforePlan: 0, summaryLine: "", entries: [])
        let folder = rig.dir.appendingPathComponent(
            DeleteDuplicatesJob.quarantineDirectoryName(planID: plan.id, entryID: rig.copy.id), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let quarantined = folder.appendingPathComponent("copy.mov")
        try FileManager.default.moveItem(at: URL(fileURLWithPath: rig.copy.fullPath), to: quarantined)
        e.status = .verified
        e.quarantineDirectory = folder.path
        e.quarantinedStamp = FileIdentityStamp.capture(path: quarantined.path)
        e.tier = .permanent
        e.tierReason = "space back now (3 verified remain)"
        e.remainingVerifiedCopies = 3
        plan.entries = [e]
        try DeleteDuplicatesPlanStore.save(plan, root: rig.root)

        let job = DeleteDuplicatesJob(model: rig.model, resuming: plan, hooks: rig.hooks, planRoot: rig.root)
        job.start(); await job.task?.value

        let after = try #require(job.plan)
        #expect(after.entries[0].status == .trashed, Comment(rawValue: after.entries[0].note))
        #expect(after.entries[0].tier == .trash)
        #expect(FileManager.default.fileExists(atPath: rig.trashFolder.appendingPathComponent("copy.mov").path))
        #expect(!FileManager.default.fileExists(atPath: folder.path), "nothing left in quarantine")
    }

    // MARK: 4. A failed move to the Trash is a HOLD

    @Test func aFailedMoveToTheTrashIsAVisibleHoldWithTheFileAtHome() async throws {
        let rig = Rig("trashfail"); defer { rig.cleanup() }
        // An archive copy too, so the pair reaches the Trash step under any
        // survival rule (before keep-one, two copies had to remain).
        addVerifiedArchiveFamily(to: rig.model, keeper: rig.keeper, withSibling: false)
        var hooks = SignatureVerification.Hooks.live
        hooks.trashItem = { _ in throw TrashRefused() }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: hooks, planRoot: rig.root)
        job.start(); await job.task?.value

        let plan = try #require(job.plan)
        let row = plan.entries[0]
        #expect((try? Data(contentsOf: URL(fileURLWithPath: rig.copy.fullPath))) == Data(rig.bytes),
                "back at its path, untouched")
        #expect(row.status == .skipped, "a HOLD, not a failure: \(row.status) — \(row.note)")
        #expect(row.note.contains("couldn't move it to the Trash") && row.note.contains("nothing was deleted"),
                Comment(rawValue: row.note))
        #expect(row.quarantineDirectory == nil)
        #expect(rig.copy.duplicateDisposition == .extraCopy, "a hold never re-marks the copy Review")
        #expect(job.runTally.failed == 0, "a hold is not a failure")
    }

    // MARK: 5. Sensor

    static var jobFile: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/MediaOps/DeleteDuplicatesJob.swift")
    }

    /// The job's source without comment lines (documentation, not calls).
    static func code(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
    }

    @Test("SENSOR: nothing in DeleteDuplicatesJob.swift can unlink a duplicate")
    func noRemovalPathRemainsInTheJob() throws {
        let lines = try Self.code(Self.jobFile)
        let text = lines.joined(separator: "\n")
        for token in ["removeItem(", "unlink(", "unlinkat(", "quarantineAndDelete(",
                      ".proceed(.permanent)", "disposal: .permanent"] {
            #expect(!text.contains(token), "DeleteDuplicatesJob.swift contains \(token)")
        }
        // The verifier's disposal type is never asked for `.permanent`.
        for line in lines where line.contains("Disposal") {
            #expect(!line.contains("permanent"), "a permanent disposal is requested: \(line)")
        }
        // Every hand-off to the verifier's removal step names the Trash.
        let calls = lines.filter { $0.contains("SignatureVerification.deleteQuarantined(") }
        #expect(!calls.isEmpty, "the job hands its tickets to deleteQuarantined")
        for call in calls {
            #expect(call.contains("disposal: .trash"), "every deleteQuarantined call passes .trash: \(call)")
        }
        // Every final verdict that lets a file go names the Trash.
        for line in lines where line.contains(".proceed(") {
            #expect(line.contains(".proceed(.trash)"), "a final verdict that is not the Trash: \(line)")
        }
        // The one live Trash step (a test host routes it to a scratch folder).
        let trashCalls = lines.filter { $0.contains("trashItem(at:") }
        #expect(trashCalls.count == 1, "exactly one live Trash call: \(trashCalls)")
    }
}
