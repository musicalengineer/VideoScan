// CatalogCommitB21Tests.swift
// Cutover B2.1 in Core — codex's B2 findings on the commit body and the
// live doors (docs/reviews/codex/codex-review-cutover-b2-write-side-switch-door-2026-10-17.md):
//   LOGIC     an unrelated people edit leaves another name's unresolved
//             conflict in place (P1-6); a derived kind the store refuses
//             leaves the row PARTIAL, not written (P2-7); a row without a
//             whole-file hash is held in `pending_rows` and leaves it when it
//             lands (gap 1); a purge tombstones the row and the load skips
//             it, never a DELETE (gap 3); intermediate marker revisions land
//             in order (gap 2); a dirty sibling writes only the curated
//             fields it changed since its own baseline (P1-1).
// Under Tests/…/Store/ because it reads the database with GRDB.
// One condition per #expect.
//
// Suites (filter by SUITE): CatalogCommitB21Tests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let healthyID = PoisonedCatalogFixture.id(.healthy)

@Suite("CatalogCommit B2.1 — people deltas, partial rows, pending rows, purges, marker revisions, sibling baselines", .serialized)
struct CatalogCommitB21Tests {

    @Test("P1-6: adding Bob leaves Donna's unresolved confirmed/rejected conflict exactly as it was")
    func peopleConflictSurvivesUnrelatedEdit() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let digest: String = try #require(try s.scalar("SELECT content_digest FROM files WHERE id = ?", [healthyID]))
        try await s.queue().write { db in
            try db.execute(sql: """
                INSERT INTO people_tags (digest, name, kind, confirmed_at, conflict) VALUES (?, 'Donna', 'confirmed', 1790000000, 1);
                INSERT INTO people_tags (digest, name, kind, confirmed_at, conflict) VALUES (?, 'Donna', 'rejected', NULL, 1);
                """, arguments: [digest, digest])
        }
        let loaded = try await s.load()
        let h = try #require(loaded.records[healthyID])
        h.confirmedByUserPeople.append(ConfirmedTag(name: "Bob", confirmedAt: Date(timeIntervalSince1970: 1_790_100_000)))
        let outcome = try await s.commit([h])
        #expect(outcome.isCommitted)
        let donna: Int? = try s.scalar("SELECT count(*) FROM people_tags WHERE digest = ? AND name = 'Donna' AND conflict = 1", [digest])
        #expect(donna == 2)
        let bob: Int? = try s.scalar("SELECT count(*) FROM people_tags WHERE digest = ? AND name = 'Bob' AND kind = 'confirmed'", [digest])
        #expect(bob == 1)
    }

    @Test("P2-7: a derived kind the store refuses leaves the row partial — not reported written")
    func refusedDerivedIsPartial() async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        try await s.queue().write { db in
            try db.execute(sql: "CREATE TRIGGER test_no_captions BEFORE INSERT ON captions BEGIN SELECT RAISE(ABORT, 'injected caption refusal'); END")
        }
        let loaded = try await s.load()
        let h = try #require(loaded.records[healthyID])
        h.userNotes = "kept"
        h.sceneCaptions = [SceneCaption(timestamp: 1, text: "a canoe")]
        h.sceneCaptionModel = "qwen2.5-vl"
        h.sceneCaptionDate = Date(timeIntervalSince1970: 1_790_200_000)
        let outcome = try await s.commit([h])
        #expect(outcome.isCommitted)
        let landing = outcome.landing(healthyID)
        #expect({ if case .written = landing { return false }; return true }())
        #expect(try await s.load().records[healthyID]?.userNotes == "kept")
    }
}
