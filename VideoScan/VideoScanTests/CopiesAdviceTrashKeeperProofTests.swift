// CopiesAdviceTrashKeeperProofTests.swift
// Codex delete-engines review 2026-10-09, F2 (P1): "Copies & Advice bypasses
// move-time keeper verification." The card's Move This Copy to Trash… handed
// the record to the JUNK routine (trashSelectedRecords): the advice said Safe
// because keeper K existed, K disappeared before the Trash, and the copy
// still moved. Recomputing the advice before dispatch is not proof AT the
// move.
//
// Now the card hands ONE reviewed pick — this copy, the card's keeper — to
// the duplicates engine's reviewed path (reviewedDuplicateBatch →
// startReviewedDeleteDuplicates), which proves the keeper (digest +
// identity, not an alias of the target) at the move, and shows the outcome
// line on the card.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("Copies & Advice — the card's Trash proves the keeper at the move (codex F2)")
struct CopiesAdviceTrashKeeperProofTests {

    @Test("sensor: Move This Copy to Trash goes through the duplicates engine, never the junk routine")
    func theCardUsesTheReviewedDuplicatesPath() throws {
        let sheet = try SourceTree.appCode(named: "CopiesAdviceSheet.swift")
        #expect(!sheet.contains("trashSelectedRecords("), "the junk routine has no keeper proof")
        #expect(!sheet.contains("deleteConfirmedJunk("))
        #expect(sheet.contains("model.trashCopyThroughDuplicates("))
        let door = try SourceTree.appCode(named: "CopiesAdviceTrash.swift")
        #expect(door.contains("reviewedDuplicateBatch([pick])"))
        #expect(door.contains("ReviewedDuplicatePick(recordID: recordID, path: this.fullPath, keeperID: keeperID)"))
        #expect(door.contains("run.outcomeReport"))
    }
}

/// keeper (b, starred → the card's keeper) + one identical extra (a), one
/// duplicate group, whole-file digests on both, in a sandbox.
@MainActor
private struct CardRig {
    let sb: MasterArchiveTestSupport.Sandbox
    let model: VideoScanModel
    let a: VideoRecord
    let b: VideoRecord
    var trash: URL { sb.root.appendingPathComponent("Trash", isDirectory: true) }
    var plans: URL { sb.root.appendingPathComponent("plans", isDirectory: true) }

    init(_ label: String) throws {
        sb = try MasterArchiveTestSupport.makeSandbox(label)
        model = MasterArchiveTestSupport.makeModel(sb)
        model.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger", isDirectory: true))
        let aURL = try MasterArchiveTestSupport.writeBlob(at: sb.sources.appendingPathComponent("test_a.mov"),
                                                          bytes: FileHasher.segmentSize * 2, seed: 11)
        let bURL = sb.sources.appendingPathComponent("test_b.mov")
        try FileManager.default.copyItem(at: aURL, to: bURL)
        a = MasterArchiveTestSupport.makeRecord(path: aURL.path)
        b = MasterArchiveTestSupport.makeRecord(path: bURL.path, starRating: 3)
        let group = UUID()
        for (r, d) in [(a, DuplicateDisposition.extraCopy), (b, .keep)] {
            r.duplicateGroupID = group; r.duplicateDisposition = d; r.duplicateConfidence = .high
            r.dupAnalyzedAt = Date()
            let data = try Data(contentsOf: URL(fileURLWithPath: r.fullPath))
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            r.contentFixity = ContentFixity.captured(path: r.fullPath, digest: hex, byteCount: Int64(data.count))
        }
        model.records = [a, b]
    }

    /// The batch runs its jobs directly (no centre), the Trash a sandbox folder.
    func start(_ batch: DeleteDuplicatesBatch) -> DeleteDuplicatesBatchRun {
        let run = DeleteDuplicatesBatchRun(batch: batch)
        let hooks = SignatureVerification.Hooks.live.withScratchTrash(in: sb.root)
        let (model, plans) = (model, plans)
        run.start(make: { DeleteDuplicatesJob(model: model, reviewed: $0, hooks: hooks, planRoot: plans) },
                  launch: { $0.start() })
        return run
    }

    func cleanup() { sb.cleanup() }
}

@Suite("Copies & Advice — Move This Copy to Trash, keeper proven at the move (codex F2)", .serialized)
@MainActor
struct CopiesAdviceTrashBehaviourTests {

    @Test func theKeeperVanishingAfterTheAdviceHoldsTheCopy() async throws {
        let rig = try CardRig("f2_vanish"); defer { rig.cleanup() }
        let advice = try #require(await CopiesAdviceLoader.load(recordID: rig.a.id, model: rig.model))
        #expect(advice.rule == .safe && advice.keeperID == rig.b.id, "fixture: \(advice.verdict.sentence)")
        #expect(advice.keeperProvenTrashPick != nil)

        // The keeper disappears after the advice, before the move.
        try FileManager.default.removeItem(atPath: rig.b.fullPath)
        let outcome = await rig.model.trashCopyThroughDuplicates(advice, start: rig.start)

        #expect(!outcome.moved)
        #expect(FileManager.default.fileExists(atPath: rig.a.fullPath), "nothing moved")
        #expect(!FileManager.default.fileExists(atPath: rig.trash.appendingPathComponent("test_a.mov").path))
        #expect(outcome.line.contains("Moved 0"), Comment(rawValue: outcome.line))
        #expect(!outcome.reasons.isEmpty, "held WITH a reason: \(outcome.cardText)")
    }

    @Test func aProvenKeeperLetsTheCopyGoToTheTrash() async throws {
        let rig = try CardRig("f2_moves"); defer { rig.cleanup() }
        let advice = try #require(await CopiesAdviceLoader.load(recordID: rig.a.id, model: rig.model))
        let outcome = await rig.model.trashCopyThroughDuplicates(advice, start: rig.start)

        #expect(outcome.moved, Comment(rawValue: outcome.cardText))
        #expect(outcome.line.hasPrefix("Moved 1"), Comment(rawValue: outcome.line))
        #expect(!FileManager.default.fileExists(atPath: rig.a.fullPath))
        #expect(FileManager.default.fileExists(atPath: rig.trash.appendingPathComponent("test_a.mov").path))
        #expect(FileManager.default.fileExists(atPath: rig.b.fullPath), "the keeper stays")
    }

    /// Only a Safe advice with a proven exact-copy keeper offers a pick: the
    /// keeper's own card, or a sampled-only match, moves nothing.
    @Test func noPickUnlessSafeBecauseOfAProvenExactCopy() async throws {
        let rig = try CardRig("f2_nopick"); defer { rig.cleanup() }
        let keeperCard = try #require(await CopiesAdviceLoader.load(recordID: rig.b.id, model: rig.model))
        #expect(keeperCard.keeperProvenTrashPick == nil, "\(keeperCard.verdict.sentence)")
        let outcome = await rig.model.trashCopyThroughDuplicates(keeperCard, start: { _ in
            Issue.record("nothing may be started for the keeper's own card")
            return DeleteDuplicatesBatchRun(batch: DeleteDuplicatesBatch(plans: []))
        })
        #expect(!outcome.moved && outcome.line.hasPrefix("Nothing was moved"))

        rig.b.contentFixity = nil   // the keeper is no longer proven by digest
        let sampled = try #require(await CopiesAdviceLoader.load(recordID: rig.a.id, model: rig.model))
        #expect(sampled.keeperProvenTrashPick == nil, "\(sampled.verdict.sentence)")
    }
}
