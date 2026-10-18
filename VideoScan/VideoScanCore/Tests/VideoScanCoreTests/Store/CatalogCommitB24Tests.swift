// CatalogCommitB24Tests.swift
// Cutover B2.4 in Core — codex's B2.3 finding F2 (sets), written RED FIRST
// against 64ea21ac6 (docs/reviews/codex/codex-review-cutover-b2-3-veto-
// explicit-purge-2026-10-18.md): two copies of one content change a SHARED
// SET (tags, backup attestations) differently in ONE commit. Before: each
// copy deleted and replaced the content's whole set, so the LAST copy in
// commit order won and the other copy's addition (or removal) was silently
// undone. Now each copy writes its own DELTA against its own baseline, so
// the order of the copies cannot change what the store ends with.
//   LOGIC   tags {base}→{base,a} on A and {base}→{base,b} on B → {a,b,base},
//           in BOTH commit orders; attestations: A removes x while B adds
//           y → {z, y}, in both orders; each written row reports the set the
//           store ENDS with (the app shows it on every copy);
//   SCALE   CatalogCommitScaleTests (unchanged pipeline);
//   MEDIA   N/A — no media is opened.
// Under Tests/…/Store/ because it reads the database with GRDB.
// One condition per #expect.
//
// Suites (filter by SUITE): CatalogCommitB24Tests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let idA = PoisonedCatalogFixture.id(.curatedConflictA)
private let idB = PoisonedCatalogFixture.id(.curatedConflictB)

@Suite("CatalogCommit B2.4 — shared sets are per-copy deltas: commit order never decides the stored set", .serialized)
struct CatalogCommitB24Tests {

    private static let x = BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud",
                                             attestedAt: Date(timeIntervalSince1970: 1_790_000_000))
    private static let z = BackupAttestation(kind: .drive, answer: .yes, label: "the drive at Tim's",
                                             attestedAt: Date(timeIntervalSince1970: 1_790_000_100))
    private static let y = BackupAttestation(kind: .offsite, answer: .yes, label: "the bank box",
                                             attestedAt: Date(timeIntervalSince1970: 1_790_000_200))

    @Test("codex F2 (tags): A {base}→{base,a}, B {base}→{base,b}, one commit → the store holds {a, b, base}",
          arguments: [false, true])
    func tagsAreDeltas(bFirst: Bool) async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let seeded = try await s.load()
        let seed = try #require(seeded.records[idA])
        seed.tags = ["base"]
        #expect(try await s.commit([seed]).isCommitted)

        let loaded = try await s.load()
        let a = try #require(loaded.records[idA])
        let b = try #require(loaded.records[idB])
        let baseA = CatalogSharedCurated(a)
        let baseB = CatalogSharedCurated(b)
        a.tags = ["base", "a"]
        b.tags = ["base", "b"]
        let items = [CommitScene.item(a, baseline: baseA), CommitScene.item(b, baseline: baseB)]
        #expect(try await s.commitItems(bFirst ? items.reversed() : items).isCommitted)
        let stored = try s.tags(of: idA)
        #expect(stored == ["a", "b", "base"])
    }

    @Test("codex F2 (attestations): from {x, z}, A removes x while B adds y, one commit → the store holds {z, y}",
          arguments: [false, true])
    func attestationsAreDeltas(bFirst: Bool) async throws {
        let s = try await CommitScene.make(); defer { s.remove() }
        let seeded = try await s.load()
        let seed = try #require(seeded.records[idA])
        seed.backupAttestations = [Self.x, Self.z]
        #expect(try await s.commit([seed]).isCommitted)

        let loaded = try await s.load()
        let a = try #require(loaded.records[idA])
        let b = try #require(loaded.records[idB])
        let baseA = CatalogSharedCurated(a)
        let baseB = CatalogSharedCurated(b)
        a.backupAttestations = [Self.z]
        b.backupAttestations = [Self.x, Self.z, Self.y]
        let items = [CommitScene.item(a, baseline: baseA), CommitScene.item(b, baseline: baseB)]
        #expect(try await s.commitItems(bFirst ? items.reversed() : items).isCommitted)
        let stored = try s.attestationLabels(of: idA)
        #expect(stored == ["the bank box", "the drive at Tim's"])
    }
}

extension CommitScene {

    /// The content's `workflow_tags`, sorted (the content of row `id`).
    func tags(of id: String) throws -> [String] {
        try queue().read { db in
            try String.fetchAll(db, sql: """
                SELECT tag FROM workflow_tags WHERE digest = (SELECT content_digest FROM files WHERE id = ?) ORDER BY tag
                """, arguments: [id])
        }
    }

    /// The content's `backup_attestations` labels, sorted.
    func attestationLabels(of id: String) throws -> [String] {
        try queue().read { db in
            try String.fetchAll(db, sql: """
                SELECT label FROM backup_attestations WHERE digest = (SELECT content_digest FROM files WHERE id = ?) ORDER BY label
                """, arguments: [id])
        }
    }
}
