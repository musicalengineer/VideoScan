// CatalogCodex145UndecodableReadBackTests.swift
// Codex cycle #145, finding 5 (docs/reviews/codex/
// codex-review-committer-refuse-and-name-2026-10-25.md): Reopen's read-back
// compared a stored row's LOCK before decoding it. A row another writer made
// undecodable (JSON-valid but structurally wrong lineage knowledge) changed
// the lock, so it became an ordinary HELD row, the decoding failure was
// swallowed while naming it, and saving was unblocked — against the
// contract that a failed read-back (error, missing row, undecodable row)
// keeps saving BLOCKED.
//
// The promise: every row the read-back reads is decoded, whatever its lock
// says; one that no longer decodes keeps saving blocked, with words.
//
// Red/green (Debug, M4 Max):
//   undecodableStoredRowKeepsSavingBlocked  RED on dfd4298ff (blockedReason nil — an ordinary HELD row) → GREEN
//
// Dimensions: LOGIC (the lock moved AND the row no longer decodes);
// ISOLATION (poisoned state: a structurally invalid row_knowledge value
// written by a second repository; CutoverScene sandbox); TRUTH (nothing is
// written while blocked). SCALE / MEDIA / SENSOR N/A.
//
// Suites (filter by SUITE): CatalogReopenUndecodableRowTests

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension CutoverScene {

    /// Another writer appends a lineage value for `record`'s row that is
    /// valid JSON but not a lineage (a string where an object belongs).
    func otherWriterPoisonsLineage(rowOf record: VideoRecord) async throws {
        let repository = GRDBCatalogRepository(host: "other-writer")
        guard case .readWrite = await repository.open(at: databaseURL) else {
            throw CutoverFailure(words: "the other writer could not open catalog.sqlite read-write")
        }
        let digest = try #require(CatalogCommit.digest(of: record))
        let knowledge = CatalogRow.RowKnowledge(fileID: record.id.uuidString, digest: digest, field: CatalogDDL.KnowledgeField.lineage.rawValue,
                                                value: .string("not a lineage"), setAt: 1_790_600_400,
                                                source: CatalogRow.RowKnowledge.appSource(.ui))
        let outcome = await repository.write(as: .ui) { tx in try tx.appendRowKnowledge(knowledge) }
        await repository.close()
        guard case .committed = outcome else { throw CutoverFailure(words: "the other writer's lineage: \(outcome)") }
    }
}

@Suite("Catalog Reopen — a stored row that no longer decodes keeps saving blocked (codex #145 F5)", .serialized)
@MainActor
struct CatalogReopenUndecodableRowTests {

    @Test("B makes R's row undecodable; A edits R and Reopens: saving stays blocked with words, nothing is written")
    func undecodableStoredRowKeepsSavingBlocked() async throws {
        let (scene, committer) = try await CatalogReopenReconcileTests.launched("codex145_undecodable")
        defer { scene.cleanup() }
        let r = try scene.record(.healthy)
        try await scene.otherWriterPoisonsLineage(rowOf: r)
        r.userNotes = "A's note"
        #expect(committer.commitNow() == false, "the generation check (or the door) refuses")

        await committer.reopen(at: scene.databaseURL)
        let blocked = try #require(committer.blockedReason, "an undecodable stored row keeps saving blocked")
        #expect(blocked.contains("could not be compared"), Comment(rawValue: blocked))
        #expect(blocked.contains(r.id.uuidString), Comment(rawValue: blocked))
        #expect(scene.sandbox.catalogLogText().contains("REFUSED Reopen's read-back"), Comment(rawValue: scene.sandbox.catalogLogText()))
        #expect(committer.commitNow() == false, "nothing may be written while blocked")
    }
}
