// ArchiveAngelPromoteCharacterizationTests.swift
// CHARACTERIZATION ONLY (refactor/angel-promote, 2026-11-08): pins every
// outcome of `ArchiveAngelPromoter.promote(plan:model:center:freshFixity:
// onFinished:)` — each refusal, what it leaves on the plan, on disk and on the
// batch claim, and on a start, exactly what is handed to the Promote job —
// so splitting it into its steps (claim → settle a pending undo → gather the
// selected rows and their companions, stamping family facts → build the
// promote plan and record its skips → save the journal → start) can be shown
// to change nothing. Written and seen green on the unchanged code first.
//
// Outcomes (safety-critical: "Name every outcome"):
//   refused — batch claimed elsewhere: nothing changed, the claim untouched
//   refused — no Master Archive: noted, saved, claim released
//   not started — the previous attempt's undo is still being saved
//   refused rows — identity changed: the row fails with the reason; with
//     nothing left, "nothing to promote", saved, claim released
//   skipped by Promote — a companion the archive refuses (purged)
//   refused — the rollback journal could not be saved: status restored,
//     every inherited value undone, nothing copied
//   started — titles, dates, date sources, role labels and the companion
//     ids handed to the job; the start line; status .promoting; the claim
//     handed to the job and ended when it settles
//
// Isolation: a sandbox per test (MasterArchiveTestSupport), synthetic blobs;
// every started job is cancelled and awaited.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("ArchiveAngelPromoter.promote — characterization (every outcome)", .serialized)
@MainActor
struct ArchiveAngelPromoteCharacterizationTests {

    struct Fixture {
        let sb: MasterArchiveTestSupport.Sandbox
        let model: VideoScanModel
        let original: VideoRecord
        let companion: VideoRecord
        var plan: ArchiveAngelPlan
    }

    /// One ready row (an original + a done access-copy companion in the
    /// batch folder), Master Archive initialized.
    private func fixture(_ label: String, batchDir: URL? = nil, initialize: Bool = true) throws -> Fixture {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.scanTargets = []
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        let file = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("tape.mov"), bytes: 4096, seed: 21)
        let original = MasterArchiveTestSupport.makeRecord(path: file.path, starRating: 3)
        original.contentHash = "v1:tape"
        let batch = batchDir ?? sb.root.appendingPathComponent("batch-char")
        let entryDir = batch.appendingPathComponent("e1")
        var companionPath = entryDir.appendingPathComponent("tape.vs.archive.mov")
        if (try? FileManager.default.createDirectory(at: entryDir, withIntermediateDirectories: true)) != nil {
            companionPath = try MasterArchiveTestSupport.writeBlob(at: companionPath, bytes: 2048, seed: 22)
        }
        let companion = MasterArchiveTestSupport.makeRecord(path: companionPath.path)
        model.records = [original, companion]
        var entry = ArchiveAngelPlan.Entry(
            id: original.id, sourcePath: file.path, filename: "tape.mov", sizeBytes: 4096,
            sourceContentHash: "v1:tape", sourceModifiedAt: nil,
            durationSeconds: 600, score: 105, evidence: [], proposedName: "Christmas morning.mov",
            proposedDate: "1987-12-25", status: .ready)
        if let i = entry.steps.firstIndex(where: { $0.kind == .accessCopy }) {
            entry.steps[i].state = .done
            entry.steps[i].recordID = companion.id
            entry.steps[i].outputRelPath = "e1/tape.vs.archive.mov"
        }
        var plan = ArchiveAngelPlan(batchDir: batch.path, requestedCount: 1, makeLossless: false, entries: [entry])
        plan.status = .ready
        if initialize { try MasterArchiveTestSupport.initialize(model, in: sb) }
        return Fixture(sb: sb, model: model, original: original, companion: companion, plan: plan)
    }

    private func promote(_ f: inout Fixture, center: MediaFileOperationsCenter = MediaFileOperationsCenter(),
                         fresh: Set<UUID> = [], onFinished: @escaping @MainActor (ArchiveAngelPlan) -> Void = { _ in })
        -> PromoteToArchiveJob? {
        ArchiveAngelPromoter().promote(plan: &f.plan, model: f.model, center: center, freshFixity: fresh,
                                       onFinished: onFinished)
    }

    // MARK: refusals

    @Test func aBatchClaimedElsewhereIsRefusedAndNothingChanges() throws {
        var f = try fixture("promchar_claimed"); defer { f.sb.cleanup() }
        #expect(ArchiveAngelLiveBatches.claim(f.plan.batchDir))
        defer { ArchiveAngelLiveBatches.end(f.plan.batchDir) }
        let before = f.plan
        let center = MediaFileOperationsCenter()
        #expect(promote(&f, center: center) == nil)
        #expect(f.plan == before, "the plan untouched")
        #expect(center.jobs.isEmpty)
        #expect(ArchiveAngelLiveBatches.isLive(f.plan.batchDir), "the other holder's claim left as it was")
        #expect((try? ArchiveAngelPlanStore.load(batchDir: f.plan.batchDir)) == nil, "nothing saved")
    }

    @Test func noMasterArchiveIsNotedSavedAndReleasesTheClaim() throws {
        var f = try fixture("promchar_nomaster", initialize: false); defer { f.sb.cleanup() }
        f.model.masterArchive = nil
        #expect(promote(&f) == nil)
        #expect(f.plan.log.last == "Archive Angel: Promote refused — no Master Archive designated")
        #expect(f.plan.status == .ready && f.plan.entries[0].status == .ready)
        let disk = try ArchiveAngelPlanStore.load(batchDir: f.plan.batchDir)
        #expect(disk.log.last == f.plan.log.last, "saved")
        #expect(!ArchiveAngelLiveBatches.isLive(f.plan.batchDir), "claim released")
    }

    @Test func anUndoStillBeingSavedHoldsThePromote() throws {
        var f = try fixture("promchar_awaiting"); defer { f.sb.cleanup() }
        let fact = ArchiveAngelPlan.StampedFact(recordID: f.original.id, field: .date, previousValue: nil,
                                                previousConfidence: nil, writtenValue: "1987-06",
                                                writtenConfidence: "known", previousAttestations: nil,
                                                writtenAttestations: nil, awaitingSave: true)
        f.plan.entries[0].stampedFacts = [fact]
        _ = ArchiveAngelPlanStore.saveLogged(f.plan, context: "test")   // the same journal on disk
        f.model.catalogStore.isReadOnly = true                          // the acknowledged save cannot land
        defer { f.model.catalogStore.isReadOnly = false }
        let center = MediaFileOperationsCenter()
        #expect(promote(&f, center: center) == nil)
        #expect(f.plan.log.contains { $0.hasPrefix("Archive Angel: Promote not started — the previous attempt's undo is still being saved") },
                "\(f.plan.log)")
        #expect(f.plan.status == .ready && f.plan.entries[0].status == .ready)
        #expect(f.plan.entries[0].stampedFacts?.first?.awaitingSave == true, "the undo stays journalled")
        #expect(center.jobs.isEmpty)
        #expect(!ArchiveAngelLiveBatches.isLive(f.plan.batchDir))
    }

    @Test func aChangedOriginalIsRefusedAndWithNothingLeftNothingIsPromoted() throws {
        var f = try fixture("promchar_changed"); defer { f.sb.cleanup() }
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: f.original.fullPath), bytes: 5000, seed: 23)
        let center = MediaFileOperationsCenter()
        #expect(promote(&f, center: center) == nil)
        let e = f.plan.entries[0]
        #expect(e.status == .failed)
        #expect(e.failure == "Source size changed since preparation (4096 → 5000 bytes)")
        #expect(f.plan.log.suffix(2) == ["Archive Angel: refused tape.mov — Source size changed since preparation (4096 → 5000 bytes)",
                                         "Archive Angel: Promote — nothing to promote"], "\(f.plan.log)")
        #expect(f.plan.status == .ready, "the batch stays reviewable")
        #expect(center.jobs.isEmpty)
        #expect(try ArchiveAngelPlanStore.load(batchDir: f.plan.batchDir).entries[0].status == .failed, "saved")
        #expect(!ArchiveAngelLiveBatches.isLive(f.plan.batchDir))
    }

    @Test func anUnselectedOrNotReadyRowIsNotPromoted() throws {
        var f = try fixture("promchar_unselected"); defer { f.sb.cleanup() }
        f.plan.entries[0].selected = false
        #expect(promote(&f) == nil)
        #expect(f.plan.entries[0].status == .ready, "left as it was")
        #expect(f.plan.log.last == "Archive Angel: Promote — nothing to promote")
    }

    @Test func aJournalThatCannotBeSavedRefusesAndUndoesEveryInheritedValue() async throws {
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("test_promchar_blocker_\(UUID().uuidString)")
        try Data([0]).write(to: blocker)                 // a FILE where the batch's parent folder should be
        defer { try? FileManager.default.removeItem(at: blocker) }
        var f = try fixture("promchar_nojournal", batchDir: blocker.appendingPathComponent("batch-x"))
        defer { f.sb.cleanup() }
        // A verified twin lends its known date (codex #1654 control).
        let twin = try AngelTestFixity.verifiedTwin(of: f.original, named: "Christmas copy.mov", in: f.sb.sources)
        twin.userDate = "1987-06"; twin.userDateConfidence = "known"
        f.model.records.append(twin)
        let fresh = await ArchiveAngelPromoter.verifiedFixity(for: f.plan, catalog: f.model)
        let center = MediaFileOperationsCenter()
        #expect(promote(&f, center: center, fresh: fresh) == nil)
        #expect(f.plan.status == .ready, "status restored")
        #expect(f.plan.entries.allSatisfy { $0.stampedFacts == nil })
        #expect(f.original.userDate == nil, "the inherited date undone")
        #expect(f.plan.log.last?.hasPrefix("Archive Angel: Promote refused — the batch's plan.json (its rollback journal) could not be saved; ") == true,
                "\(f.plan.log.last ?? "")")
        #expect(f.plan.log.last?.hasSuffix(" inherited value(s) undone, nothing copied") == true)
        #expect(center.jobs.isEmpty)
        #expect(!ArchiveAngelLiveBatches.isLive(f.plan.batchDir))
    }

    // MARK: started

    @Test func aStartHandsTheJobTheRowsNamesDatesRolesAndCompanions() async throws {
        var f = try fixture("promchar_start"); defer { f.sb.cleanup() }
        let center = MediaFileOperationsCenter()
        var settled: ArchiveAngelPlan?
        let job = try #require(promote(&f, center: center, onFinished: { settled = $0 }))
        let o = f.original.id, c = f.companion.id
        #expect(Set(job.plan.entries.map(\.recordID)) == [o, c])
        #expect(job.plan.archiveTitles == [o: "Christmas morning", c: "Christmas morning"])
        let hint = try #require(ArchiveAngelPromoter.dateHint(from: "1987-12-25"))
        #expect(job.plan.archiveDateOverrides == [o: hint, c: hint])
        let entry = f.plan.entries[0]
        let source = ArchiveAngelPromoter.dateSource(entry: entry, hint: hint)
        #expect(job.plan.archiveDateSources[o] == source && job.plan.archiveDateSources[c] == source)
        #expect(job.plan.roleLabels == [c: "Access copy"])
        #expect(job.ledgerActor == .angel)
        #expect(f.plan.status == .promoting)
        #expect(f.plan.log.last?.hasPrefix("Archive Angel: Promote started — 1 original(s) + 1 companion(s), 0 skipped by Promote, ") == true,
                "\(f.plan.log.last ?? "")")
        #expect(f.plan.log.last?.hasSuffix(" to copy") == true)
        #expect(try ArchiveAngelPlanStore.load(batchDir: f.plan.batchDir).status == .promoting, "saved before the job starts")
        #expect(ArchiveAngelLiveBatches.isLive(f.plan.batchDir), "the claim is the job's now")
        job.cancel()
        await job.task?.value
        for _ in 0..<500 where settled == nil {
            await Task.yield(); try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(settled != nil, "onFinished ran when the job settled")
        #expect(!ArchiveAngelLiveBatches.isLive(f.plan.batchDir), "the watcher ended the claim")
    }

    @Test func aCompanionPromoteRefusesIsNotedAndTheOriginalStillGoes() async throws {
        var f = try fixture("promchar_skip"); defer { f.sb.cleanup() }
        f.companion.purgedAt = Date()
        let job = try #require(promote(&f))
        #expect(job.plan.entries.map(\.recordID) == [f.original.id])
        #expect(f.plan.log.contains("Archive Angel: companion tape.vs.archive.mov skipped by Promote — record is purged"),
                "\(f.plan.log)")
        #expect(f.plan.log.last?.contains("1 original(s) + 1 companion(s), 1 skipped by Promote") == true,
                "\(f.plan.log.last ?? "")")
        #expect(f.plan.entries[0].status == .ready, "the original's row is not failed by its companion")
        job.cancel()
        await job.task?.value
    }

    @Test func anOriginalPromoteRefusesFailsItsRowWithTheReason() async throws {
        var f = try fixture("promchar_skip_original"); defer { f.sb.cleanup() }
        // A second ready row whose original Promote refuses (purged after the
        // identity check reads it: the record is still found, same size).
        let file2 = try MasterArchiveTestSupport.writeBlob(at: f.sb.sources.appendingPathComponent("reel.mov"), bytes: 3000, seed: 24)
        let rec2 = MasterArchiveTestSupport.makeRecord(path: file2.path)
        rec2.purgedAt = Date()
        f.model.records.append(rec2)
        f.plan.entries.append(ArchiveAngelPlan.Entry(
            id: rec2.id, sourcePath: file2.path, filename: "reel.mov", sizeBytes: 3000,
            sourceContentHash: "", sourceModifiedAt: nil, durationSeconds: 600, score: 90, evidence: [],
            proposedName: "reel.mov", proposedDate: nil, status: .ready))
        let job = try #require(promote(&f))
        let row = try #require(f.plan.entries.first { $0.id == rec2.id })
        #expect(row.status == .failed)
        #expect(row.failure == "Promote skipped it: record is purged")
        #expect(f.plan.log.contains("Archive Angel: reel.mov — Promote skipped it: record is purged"), "\(f.plan.log)")
        #expect(job.plan.archiveTitles[rec2.id] == ArchiveAngelPromoter.archiveTitle(from: "reel.mov"),
                "the refused row's title was still gathered (it is keyed by a record the job never sees)")
        #expect(!job.plan.entries.contains { $0.recordID == rec2.id })
        job.cancel()
        await job.task?.value
    }
}
