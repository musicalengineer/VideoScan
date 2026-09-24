// ArchiveAngelResidualsTests.swift
// codex #1714 (2026-09-23): three residuals of the 9/19–9/20 Angel
// corrections, each reproduced by a bounded probe
// (~/Library/Logs/VideoScan/review_1592_e68fd7ce/).
//
//   R1  companion reconciliation retired a record when
//       `FileManager.fileExists` said false — which it also says for a file
//       inside a folder the app may not enter. Probe: mode-000 row folder,
//       removal fails, fileExists false, the 18-byte file intact afterwards.
//   R2  unchecked-at-Promote wrote its `angelSkipped` ledger line BEFORE
//       saving the stamp and ignored a failed save; reopen + retry noted the
//       same decision again (probe: ledger 1 → 2).
//   R3  Clear read and full-fsync-saved plan.json synchronously on the main
//       actor, so a slow external buffer stalled the UI.
//
// Dimensions: LOGIC · ISOLATION (sandbox folders + sandbox ledger; real
// permission bits on scratch folders only, always restored) · SENSOR (a
// positive control in every case: the thing that SHOULD happen still does).

import Foundation
import os
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel residuals (codex #1714)", .serialized)
@MainActor
struct ArchiveAngelResidualsTests {

    private func makeModel(_ sb: MasterArchiveTestSupport.Sandbox) throws -> VideoScanModel {
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        try MasterArchiveTestSupport.initialize(model, in: sb)
        return model
    }

    private func record(_ path: String, derivedFrom: UUID? = UUID()) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.sizeBytes = 18
        r.derivedFrom = derivedFrom
        r.workspaceActive = true
        return r
    }

    private func entry(_ id: UUID, selected: Bool = false) -> ArchiveAngelPlan.Entry {
        var e = ArchiveAngelPlan.Entry(id: id, sourcePath: "/Volumes/LaCie/Family/\(id).mov", filename: "\(id).mov",
                                       sizeBytes: 1, durationSeconds: 3_600, score: 40, evidence: [],
                                       proposedName: "x.mov", proposedDate: "1993", status: .ready)
        e.selected = selected
        return e
    }

    /// The console flushes on a 0.15 s timer (DashboardState.log).
    private func consoleContains(_ model: VideoScanModel, _ text: String) async -> Bool {
        try? await Task.sleep(nanoseconds: 300_000_000)
        return model.dashboard.consoleLines.contains { $0.contains(text) }
    }

    /// A catalogued original for a plan row — the ledger writes attention
    /// lines only for records it can find (ledgerAngelAttention).
    private func catalogued(_ model: VideoScanModel) -> UUID {
        let r = VideoRecord()
        r.filename = "tape-\(r.id.uuidString.prefix(4)).mov"
        r.fullPath = "/Volumes/LaCie/Family/\(r.filename)"
        r.sizeBytes = 5_000
        model.records.append(r)
        return r.id
    }

    private func setMode(_ mode: Int, _ path: String) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private func ledgerEvents(_ model: VideoScanModel, _ kind: MediaLedgerEvent.Kind) async -> [MediaLedgerEvent] {
        await model.mediaLedger.waitForPendingWrites()
        return model.mediaLedger.allEvents().filter { $0.event == kind }
    }

    // MARK: R1 — positive absence only

    @Test("R1: a companion inside a row folder the app cannot enter is KEPT (not retired, no copyDeleted); once really gone it retires")
    func inaccessibleSurvivorIsNotRetired() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("r1perm")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let batchDir = sb.root.appendingPathComponent("buffer/batch-r1").path
        let row = UUID()
        let rowDir = batchDir + "/\(row.uuidString)"
        try FileManager.default.createDirectory(atPath: rowDir, withIntermediateDirectories: true)
        let file = rowDir + "/tape_balanced.mov"
        try Data("eighteen bytes!!!\n".utf8).write(to: URL(fileURLWithPath: file))
        let rec = record(file)
        model.records = [rec]

        // codex's probe, as the app meets it: the row folder loses traversal
        // (a failed removal, a permissions glitch on an external drive).
        setMode(0o000, rowDir)
        defer { setMode(0o755, rowDir) }
        #expect(!FileManager.default.fileExists(atPath: file), "precondition: fileExists is fooled")

        let n = model.forgetArchiveAngelCompanions(batchDir: batchDir, entryIDs: [row], reason: "skipped by you")
        #expect(n == 0, "a surviving companion was recorded as deleted")
        #expect(!rec.isPurged)
        #expect(await ledgerEvents(model, .copyDeleted).isEmpty, "a copyDeleted line for a file that still exists")
        #expect(await consoleContains(model, "could not confirm their files are gone"),
                "the kept record must be named in the log")

        setMode(0o755, rowDir)
        #expect((try? Data(contentsOf: URL(fileURLWithPath: file)).count) == 18, "the survivor is intact")

        // Positive control: really removed → retired, with its ledger line.
        try FileManager.default.removeItem(atPath: file)
        #expect(model.forgetArchiveAngelCompanions(batchDir: batchDir, entryIDs: [row], reason: "skipped by you") == 1)
        #expect(rec.isPurged)
        #expect(await ledgerEvents(model, .copyDeleted).count == 1)
    }

    @Test("R1: launch reconciliation does not treat a row folder it cannot examine as gone")
    func launchReconcileKeepsUnexaminableFolders() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("r1launch")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let root = sb.root.appendingPathComponent("buffer", isDirectory: true)
        let batchDir = root.appendingPathComponent("batch-2026-09-23T10-00-00").path
        let row = UUID()
        try FileManager.default.createDirectory(atPath: batchDir + "/\(row.uuidString)", withIntermediateDirectories: true)
        let rec = record(batchDir + "/\(row.uuidString)/a.vs.archive.mov")
        model.records = [rec]
        setMode(0o000, batchDir)            // its row folders cannot be stat'd
        defer { setMode(0o755, batchDir) }

        #expect(await model.reconcileArchiveAngelBufferAtLaunch(bufferRoot: root) == 0)
        #expect(!rec.isPurged, "a row folder behind a permission error was treated as deleted")
        #expect(await consoleContains(model, "could not examine"))

        // Positive control: the folder really gone → retired.
        setMode(0o755, batchDir)
        try FileManager.default.removeItem(atPath: batchDir)
        #expect(await model.reconcileArchiveAngelBufferAtLaunch(bufferRoot: root) == 1)
        #expect(rec.isPurged)
    }

    @Test("R1: presence — ENOENT on a mounted volume is absence; EACCES and an unmounted /Volumes path are unknown")
    func presenceClassification() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("presence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("locked"), withIntermediateDirectories: true)
        defer {
            setMode(0o755, dir.appendingPathComponent("locked").path)
            try? FileManager.default.removeItem(at: dir)
        }
        try Data("x".utf8).write(to: dir.appendingPathComponent("locked/f"))
        #expect(ArchiveAngelFilePresence.of(dir.appendingPathComponent("locked/f").path) == .present)
        #expect(ArchiveAngelFilePresence.of(dir.appendingPathComponent("nope").path) == .absent)
        #expect(ArchiveAngelFilePresence.of(dir.appendingPathComponent("locked/f/under-a-file").path) == .absent, "ENOTDIR")
        setMode(0o000, dir.appendingPathComponent("locked").path)
        if case .unknown = ArchiveAngelFilePresence.of(dir.appendingPathComponent("locked/f").path) {} else {
            Issue.record("EACCES must be unknown, not absent")
        }
        if case .unknown = ArchiveAngelFilePresence.of("/Volumes/NotMounted-\(UUID().uuidString)/batch-x/f",
                                                        mountedRoots: ["/Volumes/Other"]) {} else {
            Issue.record("a path on an unmounted drive must be unknown, not absent")
        }
    }

    // MARK: R2 — save the stamp first, ledger only on success

    @Test("R2: a failed plan save records NO skip and no stamp; the reopened retry notes it exactly once")
    func failedSaveThenReopenNotesOnce() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("r2unchecked")
        defer { sb.cleanup() }
        let model = try makeModel(sb)
        let rowID = catalogued(model)
        let batchDir = sb.root.appendingPathComponent("buffer/batch-r2").path
        var plan = ArchiveAngelPlan(batchDir: batchDir, requestedCount: 1, makeLossless: false,
                                    entries: [entry(rowID, selected: false)])
        plan.status = .ready
        try ArchiveAngelPlanStore.save(plan)

        // codex's probe: the save is refused (injected), then the sheet is
        // reopened from disk and Promote is pressed again.
        var sheetCopy = plan
        let first = ArchiveAngelReviewSheet.noteUncheckedAtPromote(plan: &sheetCopy, model: model, save: { _ in false })
        #expect(first.isEmpty, "a decision that did not persist was reported as noted")
        #expect(sheetCopy.entries[0].uncheckedNotedAt == nil, "stamped in memory only")
        #expect(await ledgerEvents(model, .angelSkipped).isEmpty, "ledger written before (without) the save")

        // The same through a REAL refused save: a readable, unwritable folder.
        setMode(0o555, batchDir)
        var viaDisk = try ArchiveAngelPlanStore.load(batchDir: batchDir)
        #expect(ArchiveAngelReviewSheet.noteUncheckedAtPromote(plan: &viaDisk, model: model).isEmpty)
        #expect(await ledgerEvents(model, .angelSkipped).isEmpty)
        setMode(0o755, batchDir)

        var reopened = try ArchiveAngelPlanStore.load(batchDir: batchDir)
        #expect(reopened.entries[0].uncheckedNotedAt == nil)
        #expect(ArchiveAngelReviewSheet.noteUncheckedAtPromote(plan: &reopened, model: model) == [rowID])
        #expect(await ledgerEvents(model, .angelSkipped).count == 1)

        var again = try ArchiveAngelPlanStore.load(batchDir: batchDir)
        #expect(again.entries[0].uncheckedNotedAt != nil, "the stamp is on disk")
        #expect(ArchiveAngelReviewSheet.noteUncheckedAtPromote(plan: &again, model: model).isEmpty)
        #expect(await ledgerEvents(model, .angelSkipped).count == 1, "one decision, one line")
    }

    // MARK: R3 — Clear's plan I/O runs off the main actor

    @Test("R3: Clear reads and saves plan.json off the main actor; a stalled disk phase does not stall main; order and outcome unchanged")
    func clearDiskPhasesRunOffMain() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("r3offmain")
        defer {
            VideoScanModel.clearDiskProbe = nil
            sb.cleanup()
        }
        let model = try makeModel(sb)
        let rowID = catalogued(model)
        let batchDir = sb.root.appendingPathComponent("buffer/batch-r3").path
        try FileManager.default.createDirectory(atPath: batchDir + "/\(rowID.uuidString)", withIntermediateDirectories: true)
        var plan = ArchiveAngelPlan(batchDir: batchDir, requestedCount: 1, makeLossless: false, entries: [entry(rowID)])
        plan.status = .ready
        try ArchiveAngelPlanStore.save(plan)

        let seen = OSAllocatedUnfairLock(initialState: [(phase: String, onMain: Bool)]())
        VideoScanModel.clearDiskProbe = { phase, dir in
            guard dir == batchDir else { return }          // other suites run in parallel
            seen.withLock { $0.append((phase, Thread.isMainThread)) }
            if phase == "plan" { Thread.sleep(forTimeInterval: 0.3) }   // slow external storage
        }
        // A main-actor heartbeat: if the plan phase ran on main, it could not tick.
        let ticks = OSAllocatedUnfairLock(initialState: 0)
        let heartbeat = Task { @MainActor in
            while !Task.isCancelled {
                ticks.withLock { $0 += 1 }
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
        }
        let out = await model.clearArchiveAngelBatch(plan, reason: "r3")
        heartbeat.cancel()

        let phases = seen.withLock { $0 }
        #expect(phases.map(\.phase) == ["path", "plan"], "\(phases.map(\.phase))")
        #expect(phases.allSatisfy { !$0.onMain }, "a disk phase ran on the main thread")
        #expect(ticks.withLock { $0 } >= 10, "main was stalled during the plan phase (\(ticks.withLock { $0 }) ticks)")
        // Unchanged semantics: saved .discarded before the ledger line, then removed.
        #expect(out.cleared && out.rowsReturned == 1)
        #expect(await out.removal?.value.removed == true)
        #expect(await ledgerEvents(model, .angelCleared).map(\.recordID) == [rowID])
    }

    @Test("R3: the batch is CLAIMED across the off-main phases — a job cannot begin it, a second Clear is refused live")
    func batchIsClaimedDuringOffMainPhases() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("r3claim")
        defer {
            VideoScanModel.clearDiskProbe = nil
            sb.cleanup()
        }
        let model = try makeModel(sb)
        let rowID = UUID()
        let batchDir = sb.root.appendingPathComponent("buffer/batch-r3claim").path
        try FileManager.default.createDirectory(atPath: batchDir, withIntermediateDirectories: true)
        var plan = ArchiveAngelPlan(batchDir: batchDir, requestedCount: 1, makeLossless: false, entries: [entry(rowID)])
        plan.status = .ready
        try ArchiveAngelPlanStore.save(plan)

        let observed = OSAllocatedUnfairLock<(live: Bool, secondClaim: Bool)?>(initialState: nil)
        VideoScanModel.clearDiskProbe = { phase, dir in
            guard dir == batchDir, phase == "plan" else { return }
            let live = ArchiveAngelLiveBatches.isLive(dir)
            let second = ArchiveAngelLiveBatches.claim(dir)
            if second { ArchiveAngelLiveBatches.end(dir) }
            observed.withLock { $0 = (live, second) }
        }
        let out = await model.clearArchiveAngelBatch(plan, reason: "r3 claim")
        let seen = try #require(observed.withLock { $0 }, "the plan phase never ran")
        #expect(seen.live, "the plan was read and saved while the batch looked idle")
        #expect(!seen.secondClaim, "a second claimant got the batch mid-clear")
        _ = await out.removal?.value
        #expect(!ArchiveAngelLiveBatches.isLive(batchDir), "the claim was released once the removal ended")

        // A refused clear releases its claim too.
        let other = sb.root.appendingPathComponent("buffer/batch-r3promoting").path
        try FileManager.default.createDirectory(atPath: other, withIntermediateDirectories: true)
        var promoting = ArchiveAngelPlan(batchDir: other, requestedCount: 1, makeLossless: false, entries: [entry(UUID())])
        promoting.status = .promoting
        try ArchiveAngelPlanStore.save(promoting)
        #expect(await model.clearArchiveAngelBatch(promoting, reason: "r3").refusal == .promoting)
        #expect(!ArchiveAngelLiveBatches.isLive(other), "a refused clear kept the batch claimed")
    }
}
