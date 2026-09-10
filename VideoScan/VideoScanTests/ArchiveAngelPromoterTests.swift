// ArchiveAngelPromoterTests.swift
// Archive Angel Stage 2 — LOGIC (typed-date parsing, role labels, archive
// title, report summary), ISOLATION + SENSOR (identity re-check on a
// sandboxed model with real on-disk files: a changed or vanished source is
// refused row by row, never silently promoted — codex #1239 guardrail 1).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel promoter — pure rules")
struct ArchiveAngelPromoterRuleTests {

    @Test("typed dates become archive hints", arguments: [
        ("1994-11-24", ArchiveDateHint.day(year: 1994, month: 11, day: 24)),
        ("1994-11", .month(year: 1994, month: 11)),
        ("1994", .year(1994)),
        ("1990s", .decade(startYear: 1990)),
        ("1990-1999", .decade(startYear: 1990)),
    ])
    func dateHints(typed: String, expected: ArchiveDateHint) {
        #expect(ArchiveAngelPromoter.dateHint(from: typed) == expected)
    }

    @Test("empty, nil and nonsense are NOT overrides", arguments: [nil, "", "   ", "sometime", "1990-1998", "abc-def"])
    func noHint(typed: String?) {
        #expect(ArchiveAngelPromoter.dateHint(from: typed) == nil)
    }

    @Test("companion role labels")
    func roles() {
        #expect(ArchiveAngelPromoter.roleLabel(for: .accessCopy) == "Access copy")
        #expect(ArchiveAngelPromoter.roleLabel(for: .losslessCopy) == "Lossless copy")
        #expect(ArchiveAngelPromoter.roleLabel(for: .balanceAudio) == "Balanced audio")
        #expect(ArchiveAngelPromoter.roleLabel(for: .verifyAudio) == nil)
    }

    @Test("archive title is the stem, never the extension; blank keeps the file's own stem")
    func titles() {
        #expect(ArchiveAngelPromoter.archiveTitle(from: "Cape Cod 1993.mov") == "Cape Cod 1993")
        #expect(ArchiveAngelPromoter.archiveTitle(from: "  .mov") == nil)
        #expect(ArchiveAngelPromoter.archiveTitle(from: "") == nil)
    }

    @Test("report summary reads as one sentence with the fallbacks named")
    func reportSummary() {
        var r = ArchiveAngelPlan.Report()
        r.promotedOriginals = 22; r.accessCopies = 21; r.losslessCopies = 4; r.balancedAudio = 3
        r.originalOnly = ["tape7.dv"]
        #expect(r.summary == "22 promoted (22 originals, 21 access copies, 4 lossless, 3 balanced audio); 1 original-only: tape7.dv")
        var one = ArchiveAngelPlan.Report()
        one.promotedOriginals = 1; one.accessCopies = 1
        #expect(one.summary == "1 promoted (1 originals, 1 access copy, 0 lossless, 0 balanced audio)")
        var failed = ArchiveAngelPlan.Report()
        failed.failed = ["a.mov", "b.mov"]
        #expect(failed.summary.hasSuffix("; 2 failed: a.mov, b.mov"))
    }
}

@Suite("Archive Angel promoter — identity re-check (sandboxed)")
struct ArchiveAngelPromoterIdentityTests {

    @MainActor
    private func fixture() throws -> (MasterArchiveTestSupport.Sandbox, VideoScanModel, VideoRecord, ArchiveAngelPlan.Entry) {
        let sandbox = try MasterArchiveTestSupport.makeSandbox("angel_identity")
        let file = sandbox.sources.appendingPathComponent("clip.mov")
        try MasterArchiveTestSupport.writeBlob(at: file, bytes: 4096, seed: 7)
        let model = MasterArchiveTestSupport.makeModel(sandbox)
        let rec = MasterArchiveTestSupport.makeRecord(path: file.path, starRating: 3)
        rec.contentHash = "abc123"
        model.records = [rec]
        let entry = ArchiveAngelPlan.Entry(
            id: rec.id, sourcePath: file.path, filename: "clip.mov", sizeBytes: 4096,
            sourceContentHash: "abc123", sourceModifiedAt: nil,
            durationSeconds: 600, score: 105, evidence: [], proposedName: "clip.mov",
            proposedDate: "1993", status: .ready)
        return (sandbox, model, rec, entry)
    }

    @Test("an unchanged original passes")
    @MainActor
    func unchangedPasses() throws {
        let (sandbox, model, _, entry) = try fixture()
        defer { sandbox.cleanup() }
        #expect(ArchiveAngelPromoter.identityProblem(for: entry, model: model) == nil)
    }

    @Test("a rewritten source (size changed) is refused with the sizes named")
    @MainActor
    func sizeMismatch() throws {
        let (sandbox, model, _, entry) = try fixture()
        defer { sandbox.cleanup() }
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: entry.sourcePath), bytes: 5000, seed: 8)
        let problem = ArchiveAngelPromoter.identityProblem(for: entry, model: model)
        #expect(problem?.contains("4096 → 5000") == true, Comment(rawValue: problem ?? "nil"))
    }

    @Test("a changed content hash is refused even when the size matches")
    @MainActor
    func hashMismatch() throws {
        let (sandbox, model, rec, entry) = try fixture()
        defer { sandbox.cleanup() }
        rec.contentHash = "zzz999"
        let problem = ArchiveAngelPromoter.identityProblem(for: entry, model: model)
        #expect(problem?.contains("hash") == true, Comment(rawValue: problem ?? "nil"))
    }

    @Test("a vanished file or record is refused")
    @MainActor
    func vanished() throws {
        let (sandbox, model, _, entry) = try fixture()
        defer { sandbox.cleanup() }
        try FileManager.default.removeItem(atPath: entry.sourcePath)
        #expect(ArchiveAngelPromoter.identityProblem(for: entry, model: model)?.contains("not found") == true)
        model.records = []
        #expect(ArchiveAngelPromoter.identityProblem(for: entry, model: model)?.contains("record is gone") == true)
    }

    @Test("a catalog rename is FOLLOWED: new path, new filename, new proposed name; identity passes")
    @MainActor
    func renameFollowed() throws {
        let (sandbox, model, rec, entry) = try fixture()
        defer { sandbox.cleanup() }
        var plan = ArchiveAngelPlan(batchDir: sandbox.root.appendingPathComponent("batch-test").path,
                                    requestedCount: 10, makeLossless: false, entries: [entry])
        _ = try model.renameRecord(rec, toBaseName: "Cape Cod 1998 whole tape")
        #expect(rec.filename == "Cape Cod 1998 whole tape.mov")
        // Before: the row still names the old file and would be refused.
        #expect(ArchiveAngelPromoter.identityProblem(for: plan.entries[0], model: model) != nil)
        let lines = ArchiveAngelPromoter.followRenames(plan: &plan, model: model)
        #expect(lines.count == 1)
        #expect(lines[0].contains("clip.mov → Cape Cod 1998 whole tape.mov"))
        #expect(plan.entries[0].sourcePath == rec.fullPath)
        #expect(plan.entries[0].filename == "Cape Cod 1998 whole tape.mov")
        #expect(plan.entries[0].proposedName.contains("Cape-Cod-1998-whole-tape"), "naming rule hyphenates the new stem: \(plan.entries[0].proposedName)")
        #expect(ArchiveAngelPromoter.identityProblem(for: plan.entries[0], model: model) == nil)
        // Idempotent.
        #expect(ArchiveAngelPromoter.followRenames(plan: &plan, model: model).isEmpty)
    }

    @Test("a name typed in the sheet survives a catalog rename; a moved-then-rewritten file is refused with the reason")
    @MainActor
    func renameEdgeCases() throws {
        let (sandbox, model, rec, entry) = try fixture()
        defer { sandbox.cleanup() }
        var edited = entry
        edited.proposedName = "Donna at the Cape.mov"
        edited.userEditedName = true
        var plan = ArchiveAngelPlan(batchDir: sandbox.root.appendingPathComponent("batch-test").path,
                                    requestedCount: 10, makeLossless: false, entries: [edited])
        _ = try model.renameRecord(rec, toBaseName: "renamed")
        ArchiveAngelPromoter.followRenames(plan: &plan, model: model)
        #expect(plan.entries[0].filename == "renamed.mov")
        #expect(plan.entries[0].proposedName == "Donna at the Cape.mov", "the user's word stands")

        // Rewritten after the move → not followed, identity names the new path.
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: rec.fullPath), bytes: 1, seed: 9)
        rec.sizeBytes = 1
        var plan2 = ArchiveAngelPlan(batchDir: plan.batchDir, requestedCount: 10, makeLossless: false, entries: [entry])
        let lines = ArchiveAngelPromoter.followRenames(plan: &plan2, model: model)
        #expect(lines.first?.contains("not followed") == true)
        #expect(plan2.entries[0].sourcePath == entry.sourcePath, "left alone")
        let problem = ArchiveAngelPromoter.identityProblem(for: plan2.entries[0], model: model)
        #expect(problem?.contains("now points at") == true && problem?.contains("not the one prepared") == true)
    }

    @Test("SENSOR: promote refuses the changed row, keeps it out of the plan, and leaves the batch reviewable")
    @MainActor
    func promoteRefusesChangedRow() throws {
        let (sandbox, model, _, entry) = try fixture()
        defer { sandbox.cleanup() }
        try MasterArchiveTestSupport.initialize(model, in: sandbox)
        var plan = ArchiveAngelPlan(batchDir: sandbox.root.appendingPathComponent("batch-test").path,
                                    requestedCount: 10, makeLossless: false, entries: [entry])
        plan.status = .ready
        try MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: entry.sourcePath), bytes: 1, seed: 9)
        let promoter = ArchiveAngelPromoter()
        let center = MediaFileOperationsCenter()
        let job = promoter.promote(plan: &plan, model: model, center: center) { _ in }
        #expect(job == nil)
        #expect(plan.entries[0].status == .failed)
        #expect(plan.entries[0].failure?.contains("size changed") == true)
        #expect(plan.status == .ready)
        // Durable: the refusal is in plan.json.
        let reloaded = try ArchiveAngelPlanStore.load(batchDir: plan.batchDir)
        #expect(reloaded.entries[0].status == .failed)
    }
}
