// DeleteDuplicatesCodex258Round4Tests.swift
// Codex round 4 on the delete-safety bundle (cycle #37, 2026-10-03): BLOCK,
// 3 findings (docs/reviews/codex/codex-review-delete-safety-bundle-258-r4-2026-10-03.md).
//
//   R4-1  a copy the run RETAINS because a protection was discovered at the
//         removal boundary became a countable survivor for a LATER row of the
//         same run — more permissive than main, which had removed it
//   R4-2  unreadable Angel-buffer evidence (a damaged plan.json, a batch
//         folder with no plan yet, a failed listing) contributed NO hold
//   R4-3  raw strings, string interpolation and regex literals could hide a
//         real comment from the code-only sensors
//   H     "Prefer the Trash for every duplicate" was sampled before phase two
//
// Dimensions: Logic (below) · Scale N/A (O(1) per removal; the boundary's
// cost budget is pinned in Round3Tests and re-run) · Media matrix N/A
// (synthetic bytes) · Isolation (temp catalog, ledger, plan root and Angel
// buffer per test; nothing reads the machine's drives or UserDefaults) ·
// Sensor (the principle sensor in Round3Tests; the stripper's own tests here).
//
// Suite: DeleteDuplicatesCodex258Round4Tests

import CryptoKit
import Darwin
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func tempDir(_ label: String) -> URL {
    let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_codex258r4_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
    model.mediaLedger = MediaLedger(directory: dir.appendingPathComponent("ledger", isDirectory: true))
    return model
}

@MainActor
private func scanTarget(_ path: String) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = .workspace
    t.isReachable = true
    return t
}

private let fileSize = FileHasher.segmentSize * 2
private let fileBytes: [UInt8] = (0..<fileSize).map { UInt8($0 % 197) }
private let fileDigest = SHA256.hash(data: Data(fileBytes)).map { String(format: "%02x", $0) }.joined()

@MainActor
private func setAngel(_ model: VideoScanModel, prepared: Set<UUID> = []) {
    var summary = model.archiveAngel.recommendations
    summary.preparedIDs = prepared
    summary.revision += 1
    model.archiveAngel.publishRecommendations(summary)
}

/// A lock-protected value a hook on a disk thread and the test can share.
private final class Shared<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
    func update<R>(_ body: (inout T) -> R) -> R { lock.withLock { body(&stored) } }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(20)
    while ContinuousClock.now < deadline, !condition() { await Task.yield() }
    #expect(condition(), "timed out waiting for: \(what)")
}

@Suite("Codex #258 round 4 — a copy retained for a protection is never a survivor; unreadable evidence holds", .serialized)
@MainActor
struct DeleteDuplicatesCodex258Round4Tests {

    struct Rig {
        let dir: URL
        let root: URL
        let model: VideoScanModel
        let keeper: VideoRecord
        let a: VideoRecord
        let b: VideoRecord
        /// A verified Review sibling (never a row of the run); nil when the fixture has none.
        let s1: VideoRecord?
        let environment: AngelEnvironment
        let target: CatalogScanTarget
        func cleanup() {
            // (A test may have taken the buffer's permissions away.)
            chmod(environment.bufferRoot.path, 0o755)
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// One "drive" (a folder): keeper K (NO stored fixity, so phase two
    /// re-reads the first pair's quarantined duplicate — the window the
    /// tests open), the extra copies A and B (planned in that order) and,
    /// by default, the verified Review sibling S1. `archiveFamily` gives the
    /// family its verified archive copy + sibling (the outright-delete rung).
    private func makeRig(_ label: String, sibling: Bool = true, archiveFamily: Bool = false) -> Rig {
        let dir = tempDir(label)
        let group = UUID()
        func record(_ name: String, _ disposition: DuplicateDisposition, verified: Bool) -> VideoRecord {
            let url = dir.appendingPathComponent(name)
            FileManager.default.createFile(atPath: url.path, contents: Data(fileBytes))
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
            if verified { r.contentFixity = ContentFixity.captured(path: url.path, digest: fileDigest, byteCount: Int64(fileSize)) }
            return r
        }
        let model = makeModel(dir)
        var env = AngelEnvironment.app
        env.bufferRoot = dir.appendingPathComponent("Buffer", isDirectory: true)
        env.evidenceDirectory = dir.appendingPathComponent("evidence", isDirectory: true)
        env.policyOverrideURL = dir.appendingPathComponent("no-policy.json")
        env.isTestHost = true
        model.archiveAngel = ArchiveAngel(model: model, environment: env)
        let target = scanTarget(dir.path)
        model.scanTargets = [target]
        let keeper = record("keeper.mov", .keep, verified: false)
        let a = record("a.mov", .extraCopy, verified: false)
        let b = record("b.mov", .extraCopy, verified: false)
        let s1 = sibling ? record("s1.mov", .review, verified: true) : nil
        model.records = [keeper, a, b] + (s1.map { [$0] } ?? [])
        if archiveFamily { addVerifiedArchiveFamily(to: model, keeper: keeper) }
        return Rig(dir: dir, root: dir.appendingPathComponent("plans", isDirectory: true), model: model,
                   keeper: keeper, a: a, b: b, s1: s1, environment: env, target: target)
    }

    private func readyBatch(for record: VideoRecord, in env: AngelEnvironment, name: String) throws {
        let folder = env.bufferRoot.appendingPathComponent("batch-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var plan = ArchiveAngelPlan(batchDir: folder.path, requestedCount: 1, makeLossless: false)
        plan.status = .ready
        var entry = ArchiveAngelPlan.Entry(id: record.id, sourcePath: record.fullPath, filename: record.filename, sizeBytes: 1,
                                           durationSeconds: 61, score: 0, evidence: [], proposedName: record.filename)
        entry.status = .ready
        plan.entries = [entry]
        try ArchiveAngelPlanStore.save(plan)
    }

    /// A `batch-` folder whose plan.json is half written.
    private func damagedBatch(in env: AngelEnvironment, name: String) throws -> URL {
        let folder = env.bufferRoot.appendingPathComponent("batch-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: folder.appendingPathComponent("plan.json"))
        return folder
    }

    /// The run, with two windows held open for the test:
    ///   `during`  — while phase two re-reads A's quarantined file (after
    ///               A's turn, its phase one and its ticket save; before
    ///               the final verdict);
    ///   `between` — at the pause boundary after A settled, before B's turn.
    private func run(_ rig: Rig, during: () throws -> Void,
                     between: (DeleteDuplicatesJob) throws -> Void = { _ in }) async throws -> DeleteDuplicatesJob {
        let armed = Shared(false), blocked = Shared(false)
        let release = DispatchSemaphore(value: 0)
        var hooks = SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir)
        hooks.didReadBlock = { label in
            guard label == "quarantine", armed.value, !blocked.update({ was in defer { was = true }; return was }) else { return }
            release.wait()
        }
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path, hooks: hooks, planRoot: rig.root)
        let first = rig.a.id
        job.testHookAfterQuarantineSaved = { entry in if entry.id == first { armed.value = true } }
        job.start()
        await waitUntil("phase two's re-read of A's quarantined file") { blocked.value }
        #expect(job.plan?.entries.map(\.id) == [rig.a.id, rig.b.id], "fixture: A and B were planned, in that order")
        try during()
        job.pause()
        release.signal()
        await waitUntil("the pause boundary after A") { job.isPausedValue }
        // Let the dispatch loop reach the pause too: it then takes the plan
        // afresh for B's turn — A's row settled, as after any real pause.
        // (Without this the loop may still hold the plan as it was while A
        // was in flight, where A reads "still to be decided" and is never
        // counted — the tests below assert that this is NOT why B's count
        // leaves A out.)
        for _ in 0..<500 { await Task.yield() }
        try between(job)
        job.resume()
        await job.task?.value
        return job
    }

    /// "Verify A again if it remains": the copy the run put back has a new
    /// ctime, so only a fresh fixity lets the sibling rules count it.
    private func verifyAgain(_ record: VideoRecord) {
        guard FileManager.default.fileExists(atPath: record.fullPath) else { return }
        record.contentFixity = ContentFixity.captured(path: record.fullPath, digest: fileDigest, byteCount: Int64(fileSize))
    }

    private func designateArchive(_ rig: Rig) {
        rig.model.masterArchive = MasterArchiveDesignation(targetPath: rig.dir.path,
                                                           rootPath: rig.dir.appendingPathComponent("Test_Family_Archive").path, volumeUUID: nil)
    }

    /// 0 = left alone · 1 = the Trash · 2 = deleted outright.
    private func rank(_ status: DeleteDuplicatesPlan.EntryStatus?) -> Int {
        switch status {
        case .skipped?: return 0
        case .trashed?: return 1
        case .deleted?: return 2
        default: return -1
        }
    }

    // MARK: R4-1

    /// Codex's reproduction, the variant WITHOUT a second sibling. A is
    /// refused by the fresh archive boundary (the Master Archive was
    /// designated during phase two) and put back; main removed A. Between
    /// the rows the designation is lifted, A is verified again and S1 goes
    /// away. Main: only the keeper would remain → B is LEFT ALONE. The
    /// branch counted the retained A → B went to the Trash.
    @Test func aCopyRetainedAtTheArchiveBoundaryNeverTrashesTheNextRow() async throws {
        let rig = makeRig("r41alone"); defer { rig.cleanup() }
        let job = try await run(rig, during: { designateArchive(rig) }, between: { _ in
            rig.model.masterArchive = nil
            verifyAgain(rig.a)
            try FileManager.default.removeItem(atPath: try #require(rig.s1).fullPath)
        })
        let rows = try #require(job.plan?.entries)
        #expect(rows[0].status == .refused && rows[0].note.contains("the Master Archive"), "fixture: \(rows[0].status): \(rows[0].note)")
        #expect(FileManager.default.fileExists(atPath: rig.a.fullPath), "fixture: A was put back")
        #expect(rig.a.duplicateDisposition == .review, "an archive refusal still marks the record Review, as on main")
        // EXPLICIT on the row — not read out of its note.
        #expect(rows[0].notCountedWhy == DuplicateDeletionHold.archiveRuleAtRemovalWhy, "\(String(describing: rows[0].notCountedWhy))")
        #expect(rows[1].status == .skipped && rows[1].remainingVerifiedCopies == 1,
                "B was decided \(rows[1].status) on the strength of the copy the boundary retained: \(rows[1].tierReason ?? rows[1].note)")
        #expect(FileManager.default.fileExists(atPath: rig.b.fullPath), "main leaves B alone — only the keeper would remain")
        // …and B's count left A out BY THE RULE, not because the loop still read A's row as in flight.
        let reason = rows[1].tierReason ?? ""
        #expect(reason.contains("a.mov") && reason.contains("not counted (\(DuplicateDeletionHold.archiveRuleAtRemovalWhy))")
                && !reason.contains("still to be decided"), Comment(rawValue: reason))
    }

    /// The row is BOTH newly in the Master Archive and held by the Angel at
    /// its removal: the hold boundary is asked even though the archive rule
    /// refuses, and the classification that is never counted wins — a hold
    /// (skipped, not marked Review).
    @Test func aCopyBothInTheArchiveAndHeldAtItsRemovalIsAHold() async throws {
        let rig = makeRig("r41both"); defer { rig.cleanup() }
        let job = try await run(rig, during: {
            designateArchive(rig)
            setAngel(rig.model, prepared: [rig.a.id])
        }, between: { _ in
            rig.model.masterArchive = nil
            setAngel(rig.model)
        })
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .skipped && row.note == DuplicateDeletionHold.inUseByAngel.note, "\(row.status): \(row.note)")
        #expect(row.notCountedWhy == DuplicateDeletionHold.inUseByAngel.why && rig.a.duplicateDisposition == .extraCopy)
        #expect(FileManager.default.fileExists(atPath: rig.a.fullPath))
    }

    /// The classification is DATA on the row; the note is only the fallback
    /// for rows written before the field existed. And main's own archive
    /// refusals (asked at the turn, or by the check captured there) keep
    /// main's treatment: decided on their merits, counted by their evidence.
    @Test func theRowSaysItselfThatItIsNotCountable() throws {
        func entry(_ status: DeleteDuplicatesPlan.EntryStatus, _ note: String, notCountedWhy: String? = nil) -> DeleteDuplicatesPlan.Entry {
            var e = DeleteDuplicatesPlan.Entry(id: UUID(), path: "/Volumes/TestDrive/\(UUID()).mov", filename: "x.mov", sizeBytes: 1,
                                               keeperID: UUID(), keeperPath: "/Volumes/TestDrive/k.mov", keeperFilename: "k.mov")
            e.status = status
            e.note = note
            e.notCountedWhy = notCountedWhy
            return e
        }
        let archiveNote = "lives on TestArchive, the Master Archive volume, which only archive actions may change"
        let atRemoval = entry(.refused, archiveNote + " — put back, nothing removed", notCountedWhy: DuplicateDeletionHold.archiveRuleAtRemovalWhy)
        let transientAtRemoval = entry(.skipped, DeleteDuplicatesDiskWorker.driveListRefreshing, notCountedWhy: DuplicateDeletionHold.archiveRuleAtRemovalWhy)
        let putBackFailed = entry(.failed, "retained safely at /Volumes/TestDrive/q/x.mov: left alone", notCountedWhy: "in use by the Archive Angel")
        let mainsOwnAtTurn = entry(.refused, archiveNote + " — refused before deletion")
        let mainsOwnCaptured = entry(.refused, archiveNote + " — put back, nothing removed")
        let byTier = entry(.skipped, "only 1 verified copy would remain — left alone (1 verified remain: keeper on TestDrive)")
        let olderHold = entry(.skipped, DuplicateDeletionHold.inUseByAngel.note)
        let plan = DeleteDuplicatesPlan(volumePath: "/Volumes/TestDrive", catalogLocation: "test", crossVolumeMode: false,
                                        skippedBeforePlan: 0, summaryLine: "",
                                        entries: [atRemoval, transientAtRemoval, putBackFailed, mainsOwnAtTurn, mainsOwnCaptured, byTier, olderHold])
        let scope = plan.runScope(deciding: nil)
        #expect(scope.leftAlone == [atRemoval.id: DuplicateDeletionHold.archiveRuleAtRemovalWhy,
                                    transientAtRemoval.id: DuplicateDeletionHold.archiveRuleAtRemovalWhy,
                                    putBackFailed.id: "in use by the Archive Angel",
                                    olderHold.id: "in use by the Archive Angel"])
        #expect(scope.decided == [mainsOwnAtTurn.id, mainsOwnCaptured.id, byTier.id], "main's own refusals keep main's treatment")
        // The field survives the plan's round trip, and an older plan (no field) still decodes.
        let data = try JSONEncoder().encode(plan)
        #expect(try JSONDecoder().decode(DeleteDuplicatesPlan.self, from: data).runScope(deciding: nil) == scope)
        let older = try #require(String(data: data, encoding: .utf8)).replacingOccurrences(of: "notCountedWhy", with: "someFutureField")
        let decoded = try JSONDecoder().decode(DeleteDuplicatesPlan.self, from: Data(older.utf8))
        #expect(decoded.entries.allSatisfy { $0.notCountedWhy == nil })
        #expect(Set(decoded.runScope(deciding: nil).leftAlone.keys) == [olderHold.id], "an older row is classified by its note")
    }

    /// Codex's reproduction, the variant WITH S1 on a second device. Main:
    /// K + S1 remain → the Trash. The branch counted K + S1 + the retained
    /// A on two devices → an outright delete. (Two devices cannot be had in
    /// one temp folder: the candidates are the job's own — the paused plan's
    /// run scope through THE survivor rule — and S1 "is on" device B through
    /// gather's seam.)
    @Test func aCopyRetainedAtTheArchiveBoundaryNeverEarnsTheNextRowAnOutrightDelete() async throws {
        let rig = makeRig("r41two"); defer { rig.cleanup() }
        var tier: DeletionTier? = .permanent
        var remaining = -1
        var notCounted: [String] = []
        let job = try await run(rig, during: { designateArchive(rig) }, between: { job in
            rig.model.masterArchive = nil
            verifyAgain(rig.a)
            let plan = try #require(job.plan)
            let candidates = rig.model.deletionTierCandidates(record: rig.b, keeper: rig.keeper, run: plan.runScope(deciding: rig.b.id))
            let facts = DeletionTierFacts.gather(candidates, digest: fileDigest) { path, _ in
                path.hasSuffix("/s1.mov") ? .init(key: "B", label: "TestX9") : .init(key: "A", label: "TestLaCie")
            }
            remaining = facts.remainingVerifiedCopies
            notCounted = facts.notCounted
            tier = DeletionTierDecision.decide(facts: facts, preferTrash: false).tier
        })
        #expect(job.plan?.entries.first?.status == .refused && FileManager.default.fileExists(atPath: rig.a.fullPath), "fixture: A was retained")
        #expect(remaining == 2, "K + S1 remain on main; the branch counts \(remaining)")
        #expect(tier == .trash, "B was decided \(String(describing: tier)) — main says the Trash")
        #expect(notCounted.contains { $0.contains("a.mov") && $0.contains("not counted (\(DuplicateDeletionHold.archiveRuleAtRemovalWhy))") },
                "A is left out by the rule, and the row says why: \(notCounted)")
    }

    enum Protection: String, CaseIterable { case archiveDesignated, angelPrepared, batchOnDisk, readOnlyMark, unreadableBatch }
    enum Fixture: String, CaseIterable { case siblingStays, siblingGoesAway }

    /// NO WEAKENING, as a property: for every protection that can be
    /// discovered at A's removal boundary, the fate of the OTHER row is
    /// never more permissive than with A simply removed — which is what
    /// main did. (The protection is lifted and A verified again between the
    /// rows, so nothing but the survivor rule stands between A and B's count.)
    @Test(arguments: Protection.allCases, Fixture.allCases)
    func aProtectionFoundAtTheBoundaryNeverMakesAnotherRowsFateMorePermissive(protection: Protection, fixture: Fixture) async throws {
        func between(_ rig: Rig, lift: () throws -> Void) throws {
            try lift()
            verifyAgain(rig.a)
            if fixture == .siblingGoesAway { try FileManager.default.removeItem(atPath: try #require(rig.s1).fullPath) }
        }
        // As on main: nothing protects A; the run removes it.
        let off = makeRig("r41off"); defer { off.cleanup() }
        let jobOff = try await run(off, during: {}, between: { _ in try between(off, lift: {}) })
        // The branch: the protection appears during phase two's re-read.
        let on = makeRig("r41on"); defer { on.cleanup() }
        let jobOn = try await run(on, during: {
            switch protection {
            case .archiveDesignated: designateArchive(on)
            case .angelPrepared: setAngel(on.model, prepared: [on.a.id])
            case .batchOnDisk: try readyBatch(for: on.a, in: on.environment, name: "late")
            case .readOnlyMark: on.model.setVolumeReadOnly(true, for: on.target)
            case .unreadableBatch: _ = try damagedBatch(in: on.environment, name: "partial")
            }
        }, between: { _ in
            try between(on) {
                switch protection {
                case .archiveDesignated: on.model.masterArchive = nil
                case .angelPrepared: setAngel(on.model)
                case .batchOnDisk: try FileManager.default.removeItem(at: on.environment.bufferRoot.appendingPathComponent("batch-late"))
                case .readOnlyMark: on.model.setVolumeReadOnly(false, for: on.target)
                case .unreadableBatch: try FileManager.default.removeItem(at: on.environment.bufferRoot.appendingPathComponent("batch-partial"))
                }
            }
        })
        let rowsOff = try #require(jobOff.plan?.entries), rowsOn = try #require(jobOn.plan?.entries)
        #expect(rowsOff[0].status.isRemoved && !FileManager.default.fileExists(atPath: off.a.fullPath), "fixture: unprotected, A is removed (\(rowsOff[0].status))")
        #expect(FileManager.default.fileExists(atPath: on.a.fullPath), "\(protection.rawValue): the protected copy was removed (\(rowsOn[0].status): \(rowsOn[0].note))")
        #expect(rowsOn[0].notCountedWhy != nil, "\(protection.rawValue): the retained row does not say it is not countable (\(rowsOn[0].status): \(rowsOn[0].note))")
        #expect(!(rowsOn[1].tierReason ?? "").contains("still to be decided"), "fixture: B's turn saw A's row settled")
        let fateOff = rank(rowsOff[1].status), fateOn = rank(rowsOn[1].status)
        #expect(fateOff >= 0 && fateOn >= 0, "fixture: B was decided in both runs (\(rowsOff[1].status), \(rowsOn[1].status): \(rowsOn[1].note))")
        #expect(fateOn <= fateOff,
                "\(protection.rawValue)/\(fixture.rawValue): retaining A made B's fate MORE permissive (\(rowsOff[1].status) → \(rowsOn[1].status): \(rowsOn[1].tierReason ?? rowsOn[1].note))")
    }

    // MARK: R4-2

    /// Codex's test: a batch folder whose plan.json is half written appears
    /// after the copy's turn. The boundary cannot say the record is free.
    @Test func anUnreadableBatchRefusesTheRemovalBoundary() async throws {
        let rig = makeRig("unreadable"); defer { rig.cleanup() }
        let copy = rig.a
        let ask = DeleteDuplicatesJob.removalBoundaryHold(model: rig.model, recordID: copy.id, path: copy.fullPath)
        let path = copy.fullPath
        #expect(await Task.detached { ask(path) }.value == nil)
        _ = try damagedBatch(in: rig.environment, name: "partial")
        #expect(await Task.detached { ask(path) }.value != nil)
    }

    /// A batch being written: its folder exists, its plan.json does not yet.
    @Test func aBatchFolderWithNoPlanYetRefusesTheRemovalBoundary() async throws {
        let rig = makeRig("noplan"); defer { rig.cleanup() }
        let copy = rig.a
        let ask = DeleteDuplicatesJob.removalBoundaryHold(model: rig.model, recordID: copy.id, path: copy.fullPath)
        let path = copy.fullPath
        #expect(await Task.detached { ask(path) }.value == nil)
        try FileManager.default.createDirectory(at: rig.environment.bufferRoot.appendingPathComponent("batch-being-written", isDirectory: true),
                                                withIntermediateDirectories: true)
        #expect(await Task.detached { ask(path) }.value != nil)
    }

    /// The buffer folder itself cannot be listed (its permissions are gone).
    @Test func aBufferThatCannotBeListedRefusesTheRemovalBoundary() async throws {
        let rig = makeRig("listing"); defer { rig.cleanup() }
        let copy = rig.a
        let ask = DeleteDuplicatesJob.removalBoundaryHold(model: rig.model, recordID: copy.id, path: copy.fullPath)
        let path = copy.fullPath
        try FileManager.default.createDirectory(at: rig.environment.bufferRoot, withIntermediateDirectories: true)
        #expect(await Task.detached { ask(path) }.value == nil, "fixture: an empty, readable buffer holds nothing")
        try #require(chmod(rig.environment.bufferRoot.path, 0o000) == 0)
        guard (try? FileManager.default.contentsOfDirectory(atPath: rig.environment.bufferRoot.path)) == nil else { return }  // (running as root)
        #expect(await Task.detached { ask(path) }.value != nil)
    }

    /// End to end: the damaged batch appears during phase two's re-read.
    /// The file is put back and the row says why.
    @Test func anUnreadableBatchAppearingDuringPhaseTwoStopsTheRemoval() async throws {
        let rig = makeRig("unreadablerun"); defer { rig.cleanup() }
        var folder: URL?
        let job = try await run(rig, during: { folder = try damagedBatch(in: rig.environment, name: "partial") },
                                between: { _ in try FileManager.default.removeItem(at: try #require(folder)) })
        let rows = try #require(job.plan?.entries)
        #expect(FileManager.default.fileExists(atPath: rig.a.fullPath), "removed although the Angel's buffer could not be read")
        #expect(rows[0].status == .skipped && rows[0].note.hasPrefix("left alone — the Archive Angel's batches could not be read just now"),
                "\(rows[0].status): \(rows[0].note)")
        #expect(rig.a.duplicateDisposition == .extraCopy && rows[0].quarantineDirectory == nil, "put back, not marked")
    }

    /// The reading itself, three ways. A buffer that was never made holds
    /// nothing; one on a drive that is not connected is unknown.
    @Test func theFreshReadingSaysWhatItCouldNotRead() throws {
        let rig = makeRig("reading"); defer { rig.cleanup() }
        let root = rig.environment.bufferRoot
        typealias Store = ArchiveAngelPlanStore
        #expect(!FileManager.default.fileExists(atPath: root.path), "fixture: no buffer yet")
        #expect(Store.inFlightRecordIDsFresh(bufferRoot: root) == .ids([]), "a buffer that was never made holds nothing")
        let away = URL(fileURLWithPath: "/Volumes/TestNotConnected-\(UUID().uuidString.prefix(8))/Buffer")
        if case .ids = Store.inFlightRecordIDsFresh(bufferRoot: away) { Issue.record("a buffer on a drive that is not connected read as empty") }
        #expect(!Store.bufferIsAbsent(away) && Store.bufferIsAbsent(root))

        try readyBatch(for: rig.a, in: rig.environment, name: "good")
        #expect(Store.inFlightRecordIDsFresh(bufferRoot: root) == .ids([rig.a.id]))
        // One damaged batch beside a good one: NOTHING is certain — not even for a record the good batch does not list.
        let damaged = try damagedBatch(in: rig.environment, name: "partial")
        if case .uncertain(let why) = Store.inFlightRecordIDsFresh(bufferRoot: root) {
            #expect(why.hasPrefix("batch-partial's plan.json can't be read"), Comment(rawValue: why))
        } else {
            Issue.record("a damaged batch beside a good one read as certain")
        }
        let probe = rig.model.archiveAngel.recordInBatchOnDiskFreshProbe()
        if case .uncertain = probe(rig.b.id) {} else { Issue.record("B read as \(probe(rig.b.id)) beside an unreadable batch") }
        // The advisory readers still skip it (a list on screen is not a verdict).
        #expect(Store.inFlightRecordIDsCached(bufferRoot: root) == [rig.a.id] && Store.listBatches(bufferRoot: root).count == 1)
        try FileManager.default.removeItem(at: damaged)
        // A plan.json that exists and cannot be opened.
        let locked = root.appendingPathComponent("batch-good/plan.json").path
        try #require(chmod(locked, 0o000) == 0)
        defer { chmod(locked, 0o644) }
        if (try? Data(contentsOf: URL(fileURLWithPath: locked))) == nil {   // (not when running as root)
            if case .uncertain = Store.inFlightRecordIDsFresh(bufferRoot: root) {} else { Issue.record("an unopenable plan.json read as certain") }
        }
    }

    // MARK: Fail closed — the other inputs of the final verdict

    /// The record left the catalog while its pair was being read. No record
    /// is not "no hold": the Angel's sets are sets of ids and are still asked.
    @Test func aRecordThatLeftTheCatalogIsStillAskedOfTheAngelByID() {
        let rig = makeRig("gone"); defer { rig.cleanup() }
        let id = rig.a.id
        setAngel(rig.model, prepared: [id])
        rig.model.records.removeAll { $0.id == id }
        #expect(rig.model.record(forID: id) == nil, "fixture: the record is gone")
        #expect(rig.model.duplicateRemovalBoundaryWord(recordID: id).holdNote == DuplicateDeletionHold.inUseByAngel.note)
        setAngel(rig.model)
        #expect(rig.model.duplicateRemovalBoundaryWord(recordID: id).holdNote == nil)
    }

    /// PIN: at the final verdict a volume the fresh lookup cannot identify
    /// never adds a drive — two drives at the turn, one at the removal, and
    /// the outright delete becomes the Trash.
    @Test func aDriveTheFreshLookupCannotIdentifyNeverAddsADrive() {
        let dir = tempDir("unknown"); defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["keeper.mov", "s1.mov", "s2.mov"] {
            FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data(fileBytes))
        }
        var c = DeletionTierCandidates()
        c.keeperPath = dir.appendingPathComponent("keeper.mov").path
        c.keeperLabel = "keeper"
        c.otherCopies = ["s1.mov", "s2.mov"].map {
            let path = dir.appendingPathComponent($0).path
            return .init(path: path, fixity: ContentFixity.captured(path: path, digest: fileDigest, byteCount: Int64(fileSize)), label: $0)
        }
        let q = DuplicateDrives.Identity(device: 1, kind: .physical, physicalDevice: "test-device-Q")
        let p = DuplicateDrives.Identity(device: 1, kind: .physical, physicalDevice: "test-device-P")
        // keeper + s1 are on Q by the identity seam; s2's volume is LOOKED UP.
        let others: @Sendable (String) -> DuplicateDrives.Identity? = { $0.hasSuffix("s2.mov") ? nil : q }
        let scope = "test-r4-unknown-\(UUID().uuidString)|"
        let gathered = DuplicateDrives.$cacheScope.withValue(scope) {
            DuplicateDrives.$lookupOverride.withValue({ _, _ in p }) {
                DuplicateDrives.$identityOverride.withValue(others) { DeletionTierFacts.gather(c, digest: fileDigest) }
            }
        }
        #expect(gathered.distinctDriveCount == 2 && DeletionTierDecision.decide(facts: gathered, preferTrash: false).tier == .permanent,
                "fixture: two drives at the turn (\(gathered.summary))")
        // At the verdict the lookup cannot say what s2's device is.
        let checked = DuplicateDrives.$cacheScope.withValue(scope) {
            DuplicateDrives.$lookupOverride.withValue({ _, device in .init(device: device, kind: .unknown) }) {
                DuplicateDrives.$identityOverride.withValue(others) { gathered.recheck() }
            }
        }
        #expect(checked.remainingVerifiedCopies == 3, "the copy still counts as a COPY")
        #expect(checked.distinctDriveCount == 1, "an unidentified volume added a drive at the final verdict: \(checked.countedDrives)")
        #expect(!checked.droppedAtBoundary.isEmpty && DeletionTierDecision.decide(facts: checked, preferTrash: false).tier == .trash)
    }

    // MARK: R4-3 — the comment stripper fails closed

    /// A code-only sensor's reader REFUSES `text`: it records the stripper's
    /// own failure (so the sensor fails) AND throws (so it never goes on to
    /// match against a text it cannot read).
    private func refuses(_ text: String) -> Bool {
        var threw = false
        withKnownIssue("a code-only sensor refuses a text the stripper cannot read") {
            do { _ = try SourceTree.code(of: text, named: "a test input") } catch { threw = true }
        } matching: { issue in
            String(describing: issue).contains("holds syntax the comment stripper does not understand")
        }
        return threw
    }

    /// Codex's three inputs (and the `//` variant): valid Swift whose REAL
    /// comment carries the text a sensor looks for, after a construct the
    /// stripper does not read. Each is REPORTED, and a code-only sensor
    /// refuses the text.
    @Test func theStripperReportsWhatItCannotRead() {
        let inputs = [
            "let _ = #\"a\"b\"# /* boundaryHold(ticket.quarantinedPath) */",
            "let _ = \"\\(/* boundaryHold(ticket.quarantinedPath) */ 0)\"",
            "let _ = #/\"/# /* boundaryHold(ticket.quarantinedPath) */",
            "let _ = #\"a\"b\"# // boundaryHold(ticket.quarantinedPath)",
            "let _ = ##\"a\"#b\"## /* boundaryHold(ticket.quarantinedPath) */",
            "let r = /\"/ /* boundaryHold(ticket.quarantinedPath) */",
            "let r = try! Regex(x).firstMatch(in: /\"/) /* boundaryHold(ticket.quarantinedPath) */",
        ]
        for input in inputs {
            let scanned = SourceTree.scan(input)
            #expect(!scanned.unsupported.isEmpty || !scanned.code.contains("boundaryHold("),
                    "a comment survived as code, unreported: \(input) → \(scanned.code)")
            #expect(!scanned.unsupported.isEmpty, "not reported: \(input)")
            #expect(refuses(input), "a code-only sensor read it: \(input)")
        }
        #expect(SourceTree.scan("a()\nlet _ = #\"x\"#\nb()").unsupported == [.init(line: 2, what: "a raw string or an extended regex literal (#\" or #/)")])
    }

    /// What the stripper DOES read — none of it reported, every comment gone.
    @Test func theStripperReadsNestedStringsAndDivision() throws {
        let cases: [(source: String, code: String)] = [
            ("let s = \"only \\(n) cop\\(n == 1 ? \"y\" : \"ies\") // not a comment\" /* gone */ + x",
             "let s = \"only \\(n) cop\\(n == 1 ? \"y\" : \"ies\") // not a comment\"  + x"),
            ("let s = \"\\(f(a, (b)))\" // gone", "let s = \"\\(f(a, (b)))\" "),
            ("let s = \"\\(d[\"k\"] ?? \"/*\")\" /* gone */", "let s = \"\\(d[\"k\"] ?? \"/*\")\" "),
            ("let q = a / b /* gone */", "let q = a / b "),
            ("let q = a/b // gone", "let q = a/b "),
            ("x /= 2 // gone", "x /= 2 "),
            ("let t = \"\"\"\n  a \\\"\"\" // kept: still inside the block\n  \\(n == 1 ? \"y\" : \"ies\")\n  \"\"\" // gone",
             "let t = \"\"\"\n  a \\\"\"\" // kept: still inside the block\n  \\(n == 1 ? \"y\" : \"ies\")\n  \"\"\" "),
            ("let p = \"a\\\\\" /* gone */", "let p = \"a\\\\\" "),
        ]
        for (source, code) in cases {
            let scanned = SourceTree.scan(source)
            #expect(scanned.unsupported.isEmpty, "\(source): \(scanned.unsupported)")
            #expect(scanned.code == code, "\(source) → \(scanned.code)")
            #expect(try SourceTree.code(of: source, named: "a test input") == code)
        }
    }

    /// Codex's SURVIVING MUTANT: the fresh reader's body opens with a raw
    /// string whose trailing comment carries the call the principle sensor
    /// looks for, and returns the CACHED reading. The stripper keeps that
    /// comment as "code" — and now says it cannot read the file, so the
    /// sensor (which reads through `appCode`) fails instead of passing.
    @Test func theMutantThatHidACachedReadBehindARawStringIsRefused() throws {
        let store = try SourceTree.appSource(named: "ArchiveAngelPlan.swift")
        let head = "nonisolated static func inFlightRecordIDsFresh(bufferRoot: URL, now: Date = Date()) -> FreshHoldReading {\n"
        let at = try #require(store.range(of: head), "the fresh reader's signature moved")
        let mutant = store.replacingCharacters(in: at.upperBound..<at.upperBound, with: """
                    let _ = #"a"b"# /* plan = try load(batchDir: dir) */
                    return .ids(inFlightRecordIDsCached(bufferRoot: bufferRoot, now: now))

            """)
        #expect(SourceTree.scan(store).unsupported.isEmpty, "fixture: the real file is readable")
        let scanned = SourceTree.scan(mutant)
        #expect(scanned.code.contains("/* plan = try load(batchDir: dir) */"), "fixture: the comment survives stripping — that is the hole")
        #expect(scanned.unsupported.count == 1, "the mutant is not reported: \(scanned.unsupported)")
        #expect(refuses(mutant), "the sensor's reader accepted the mutant")
    }

    /// Every production file a code-only sensor of this bundle reads is
    /// readable by the stripper today — none holds a raw string, a regex
    /// literal or a comment inside an interpolation.
    @Test func everyFileTheCodeOnlySensorsReadIsReadable() throws {
        for name in ["DeleteDuplicatesJob.swift", "DeleteDuplicatesPlan.swift", "DeleteDuplicatesDrives.swift",
                     "VideoScanModel+Duplicates.swift", "ArchiveAngel.swift", "ArchiveAngelPlan.swift",
                     "VideoScanModel+MasterArchive.swift", "ArchiveVolumeProtection.swift", "VideoScanModel+ArchiveVolumeSnapshot.swift",
                     "VideoScanModel+Workbench.swift", "JunkDeleteAction.swift", "VideoScanModel+PruneApply.swift",
                     "VideoScanModel+JunkDelete.swift", "TranscodeJob.swift", "DerivativeOutputPublish.swift"] {
            #expect(SourceTree.scan(try SourceTree.appSource(named: name)).unsupported.isEmpty, "\(name)")
        }
    }

    // MARK: H — "Prefer the Trash for every duplicate", read at the removal

    /// The setting is turned ON while phase two re-reads the pair in flight:
    /// that very file goes to the Trash, not away.
    @Test func preferTrashTurnedOnDuringPhaseTwoTrashesThePairInFlight() async throws {
        let rig = makeRig("prefer", archiveFamily: true); defer { rig.cleanup() }
        #expect(!rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate, "fixture: off at the copy's turn")
        let job = try await run(rig, during: { rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate = true })
        let rows = try #require(job.plan?.entries)
        #expect(rows[0].status == .trashed && rows[0].tier == .trash,
                "the pair in flight was \(rows[0].status) although \"Prefer the Trash\" was on before its removal: \(rows[0].tierReason ?? "")")
        #expect(FileManager.default.fileExists(atPath: rig.dir.appendingPathComponent("Trash/a.mov").path), "A is in the Trash")
        #expect(rows[1].status == .trashed, "and so is the next row (\(rows[1].status))")
        #expect(job.runTally.deleted == 0 && job.runTally.trashed == 2)
    }

    /// Turned OFF mid-pair: the recorded Trash stands — the fresh reading
    /// only ever makes the outcome more conservative.
    @Test func preferTrashTurnedOffDuringPhaseTwoNeverUpgradesTheRecordedTrash() async throws {
        let rig = makeRig("preferoff", archiveFamily: true); defer { rig.cleanup() }
        rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate = true
        let job = try await run(rig, during: { rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate = false })
        let rows = try #require(job.plan?.entries)
        #expect(rows[0].status == .trashed, "a recorded Trash was upgraded mid-pair (\(rows[0].status))")
        #expect(rows[1].status == .trashed, "the NEXT row is decided afresh — and is the Trash whatever the setting (\(rows[1].status))")
    }

    /// The model's part of the boundary is ONE value, read in one hop: the
    /// hold, the marks, the designation and the setting together; a catalog
    /// that went away holds, with the most conservative setting.
    @Test func theBoundaryReadsTheModelOnceAndAGoneCatalogHolds() async throws {
        let rig = makeRig("onehop"); defer { rig.cleanup() }
        rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate = true
        designateArchive(rig)
        let now = rig.model.duplicateRemovalBoundaryNow(recordID: rig.a.id)
        #expect(now.preferTrash && now.designation != nil && now.holdNote == nil && now.readOnlyMarks.isEmpty)
        let ask = DeleteDuplicatesJob.removalBoundary(model: rig.model, recordID: rig.a.id, path: rig.a.fullPath)
        let path = rig.a.fullPath
        let answer = await Task.detached { ask(path) }.value
        #expect(answer.holdNote == nil && answer.archive?.note.contains("the Master Archive") == true && answer.preferTrash)
        #expect(DuplicateRemovalBoundaryNow.catalogGone.holdNote != nil && DuplicateRemovalBoundaryNow.catalogGone.preferTrash)
    }

    // MARK: - Round 5 (codex cycle #38)

    /// S1 — codex r5 #2, the archive-candidate route: A is given promoted-copy
    /// provenance during phase two, so the boundary holds it (no Master
    /// Archive designated). Verified again, it must NOT enter B's archive
    /// copies: main removed A and Trashed B on the keeper + S1.
    @Test func r5aRowOfThisRunNeverEntersTheArchiveCopies() async throws {
        let rig = makeRig("r5arch"); defer { rig.cleanup() }
        let job = try await run(rig, during: {
            rig.a.derivedFrom = rig.keeper.id
            rig.a.derivationKind = ArchivePromotion.derivationKind
            rig.a.archiveFixity = ArchiveFixity(digest: fileDigest, verifiedAt: Date(), sizeBytes: Int64(fileSize))
        }, between: { _ in verifyAgain(rig.a) })
        let rows = try #require(job.plan?.entries)
        #expect(FileManager.default.fileExists(atPath: rig.a.fullPath) && rows[0].status == .skipped, "fixture: A held (\(rows[0].status): \(rows[0].note))")
        #expect(rows[1].status != .deleted && rows[1].remainingVerifiedCopies == 2,
                "B was decided \(rows[1].status) counting the run's own row A as an archive copy: \(rows[1].tierReason ?? rows[1].note)")
    }

    /// S1 — codex r5 #3: a plan written before `notCountedWhy` existed (the
    /// field absent), its row A retained by the fresh archive boundary (the
    /// note is the same as main's own refusal) or put back after a failed
    /// put-back and recovered. Resumed, A is a row of this run: never counted.
    @Test func r5bALegacyPlansRowIsNeverCountedOnResume() throws {
        let rig = makeRig("r5legacy", sibling: false); defer { rig.cleanup() }
        verifyAgain(rig.a)
        for (status, note) in [(DeleteDuplicatesPlan.EntryStatus.refused,
                                "lives on TestArchive, the Master Archive volume, which only archive actions may change — put back, nothing removed"),
                               (.failed, "retained safely at /Volumes/TestDrive/q/a.mov: left alone — recovered at resume"),
                               (.skipped, "only 1 verified copy would remain — left alone (1 verified remain: keeper on TestDrive)")] {
            var a = DeleteDuplicatesPlan.Entry(id: rig.a.id, path: rig.a.fullPath, filename: rig.a.filename, sizeBytes: rig.a.sizeBytes,
                                               keeperID: rig.keeper.id, keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename)
            a.status = status
            a.note = note
            let b = DeleteDuplicatesPlan.Entry(id: rig.b.id, path: rig.b.fullPath, filename: rig.b.filename, sizeBytes: rig.b.sizeBytes,
                                               keeperID: rig.keeper.id, keeperPath: rig.keeper.fullPath, keeperFilename: rig.keeper.filename)
            let written = DeleteDuplicatesPlan(volumePath: rig.dir.path, catalogLocation: "test", crossVolumeMode: false,
                                               skippedBeforePlan: 0, summaryLine: "", entries: [a, b])
            let legacy = try JSONDecoder().decode(DeleteDuplicatesPlan.self, from: try JSONEncoder().encode(written))
            #expect(legacy.entries[0].notCountedWhy == nil, "fixture: a plan without the field")
            let candidates = rig.model.deletionTierCandidates(record: rig.b, keeper: rig.keeper, run: legacy.runScope(deciding: rig.b.id))
            let facts = DeletionTierFacts.gather(candidates, digest: fileDigest)
            #expect(facts.remainingVerifiedCopies == 1 && DeletionTierDecision.decide(facts: facts, preferTrash: false).tier == nil,
                    "\(status): the run's own row A was counted for B (\(facts.summary))")
        }
    }

    /// S1, member by member: EVERY row of this run, whatever became of it,
    /// is never a survivor for another row.
    @Test func r5cEveryRowOfTheRunIsNeverASurvivor() {
        let rig = makeRig("r5rule"); defer { rig.cleanup() }
        var run = DuplicateRunScope(volumePath: rig.dir.path)
        run.decided = [rig.a.id]
        #expect(rig.model.duplicateSurvivorStandingRule(in: run)(rig.a) != .bySiblingRules, "a row decided on its merits was counted")
        #expect(rig.model.duplicateSurvivorStandingRule(in: run)(try! #require(rig.s1)) == .bySiblingRules, "a Review sibling counts by its evidence")
    }

    /// R5 #1 — the preference that produced the recorded Trash travels
    /// through phase two. Recorded with "Prefer the Trash" ON; turned OFF
    /// right after the ticket is saved; then a counted copy changes, so the
    /// final verdict re-decides. Keeper + archive copy + verified sibling
    /// still earn the archive exception — but the recorded Trash must stand.
    @Test func r5dThePreferenceThatRecordedTheTrashIsCarriedThroughPhaseTwo() async throws {
        let rig = makeRig("r5pref", archiveFamily: true); defer { rig.cleanup() }
        rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate = true
        let s1 = try #require(rig.s1)
        let job = DeleteDuplicatesJob(model: rig.model, volumePath: rig.dir.path,
                                      hooks: SignatureVerification.Hooks.live.withScratchTrash(in: rig.dir), planRoot: rig.root)
        let first = rig.a.id
        job.testHookAfterQuarantineSaved = { entry in
            guard entry.id == first else { return }
            rig.model.duplicateKeeperSettings.preferTrashForEveryDuplicate = false
            Thread.sleep(forTimeInterval: 0.01)
            try? Data(fileBytes).write(to: URL(fileURLWithPath: s1.fullPath))   // same bytes, new stamp: dropped at the boundary
        }
        job.start()
        await job.task?.value
        let row = try #require(job.plan?.entries.first)
        #expect(row.status == .trashed, "recorded Trash (preference on) became \(row.status): \(row.tierReason ?? row.note)")
    }

    /// R5 #4 (L), Read-only: marked as /Volumes/TestOld (UUID TEST-U), the
    /// drive is now mounted as /Volumes/TestNew and its UUID cannot be read.
    @Test func r5eAReadOnlyDriveWhoseIdentityCannotBeReadIsNotCleared() {
        let marks = [ReadOnlyVolumeProtection.Mark(searchPath: "/Volumes/TestOld", volumeUUID: "TEST-U")]
        let protection = ReadOnlyVolumeProtection.make(marks: marks, mountedRoots: { ["/Volumes/TestNew"] }, probe: { _ in nil },
                                                       identity: { _ in nil }, networkRoots: { [] })
        let path = "/Volumes/TestNew/clips/extra.mov"
        func at(_ mount: String, uuid: String?) -> ReadOnlyVolumeProtection.Verdict? {
            protection.verdictAtRemoval(path: path, probe: { _ in uuid },
                                        identity: { _ in MountIdentity(resolvedPath: path, mountPoint: mount) })
        }
        #expect(at("/Volumes/TestNew", uuid: nil) != nil, "a file on a drive whose identity cannot be read was cleared")
        #expect(at("/Volumes/TestNew", uuid: "TEST-OTHER") == nil, "a drive proven to be another one is clear")
        #expect(at("/", uuid: nil) == nil && at("/System/Volumes/Data", uuid: nil) == nil, "the boot disk is never a marked external drive")
        let refused = at("/Volumes/TestNew", uuid: nil).map { VideoScanModel.readOnlyRefusalNote($0) } ?? ""
        #expect(refused.contains("could not read"), Comment(rawValue: refused))
    }

    /// R5 #4 (L), Master Archive: designated as /Volumes/TestArchive (UUID
    /// TEST-U), now mounted at a custom path outside /Volumes; no UUID can
    /// be read. A file there is not provably off the archive drive.
    @Test func r5fAnArchiveDriveAtACustomMountWhoseIdentityCannotBeReadIsUnprovable() throws {
        let designation = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive", rootPath: "/Volumes/TestArchive/Test_Family_Archive",
                                                   volumeUUID: "TEST-U")
        let custom: (String) -> MountIdentity? = { p in p.hasPrefix("/TestCustom") ? MountIdentity(resolvedPath: p, mountPoint: "/TestCustom") : nil }
        let protection = try #require(ArchiveVolumeProtection.make(designation: designation, mountedRoots: { ["/TestCustom"] }, probe: { _ in nil },
                                                                   identity: custom, networkRoots: { [] }))
        let path = "/TestCustom/clips/extra.mov"
        #expect(protection.verdictAtRemoval(path: path, probe: { _ in nil }, identity: custom) == .unprovable,
                "a file on what may be the archive drive was cleared")
        #expect(protection.verdictAtRemoval(path: path, probe: { _ in "TEST-OTHER" }, identity: custom) == .clear, "another drive, proven by its UUID")
        #expect(protection.verdictAtRemoval(path: path, probe: { _ in "TEST-U" }, identity: custom) == .onArchiveVolume)
        #expect(protection.verdictAtRemoval(path: "/Users/test/x.mov", probe: { _ in nil },
                                            identity: { p in MountIdentity(resolvedPath: p, mountPoint: "/System/Volumes/Data") }) == .clear,
                "the boot disk is never the external archive")
    }

    /// R5 #5 — a `batch-` symlink is never read through, and never "free".
    @Test func r5gASymlinkedBatchIsUncertain() throws {
        let rig = makeRig("r5link"); defer { rig.cleanup() }
        let elsewhere = rig.dir.appendingPathComponent("elsewhere", isDirectory: true)
        let fakeEnv: AngelEnvironment = { var e = rig.environment; e.bufferRoot = elsewhere; return e }()
        try readyBatch(for: rig.a, in: fakeEnv, name: "real")
        try FileManager.default.createDirectory(at: rig.environment.bufferRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: rig.environment.bufferRoot.appendingPathComponent("batch-link"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("batch-real"))
        if case .uncertain = ArchiveAngelPlanStore.inFlightRecordIDsFresh(bufferRoot: rig.environment.bufferRoot) {} else {
            Issue.record("a symlinked batch read as \(ArchiveAngelPlanStore.inFlightRecordIDsFresh(bufferRoot: rig.environment.bufferRoot))")
        }
    }

    /// R5 #5 — a missing buffer is "never made" only when the drive it lives
    /// on is MOUNTED: a leftover mount directory, a symlink into one, a
    /// dangling symlink are all uncertain.
    @Test func r5hAMissingBufferOnALeftoverMountDirectoryIsUncertain() throws {
        let dir = tempDir("r5mount"); defer { try? FileManager.default.removeItem(at: dir) }
        let volumes = URL(fileURLWithPath: SourceTree.canonicalPath(dir)).appendingPathComponent("Volumes", isDirectory: true)
        let leftover = volumes.appendingPathComponent("TestDrive", isDirectory: true)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        let alias = volumes.deletingLastPathComponent().appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: leftover)
        let dangling = volumes.deletingLastPathComponent().appendingPathComponent("dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: volumes.appendingPathComponent("TestGone"))
        ArchiveAngelPlanStore.$volumesRoot.withValue(volumes.path) {
            #expect(!ArchiveAngelPlanStore.bufferIsAbsent(leftover.appendingPathComponent("Buffer/ArchiveAngel")), "a leftover mount directory")
            #expect(!ArchiveAngelPlanStore.bufferIsAbsent(alias.appendingPathComponent("Buffer")), "a symlink into a leftover mount directory")
            #expect(!ArchiveAngelPlanStore.bufferIsAbsent(dangling.appendingPathComponent("Buffer")), "a dangling symlink")
            #expect(!ArchiveAngelPlanStore.bufferIsAbsent(volumes.appendingPathComponent("TestGone/Buffer")), "a drive that is not there")
        }
        // A drive that IS mounted: a buffer never made there holds nothing.
        ArchiveAngelPlanStore.$volumesRoot.withValue("/System/Volumes") {
            #expect(ArchiveAngelPlanStore.bufferIsAbsent(URL(fileURLWithPath: "/System/Volumes/Data/test-no-such-\(UUID().uuidString)/Buffer")))
        }
        #expect(ArchiveAngelPlanStore.bufferIsAbsent(dir.appendingPathComponent("never-made/Buffer")), "on the boot disk, never made = empty")
    }
}
