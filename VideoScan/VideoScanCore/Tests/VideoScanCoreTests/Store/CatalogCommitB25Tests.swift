// CatalogCommitB25Tests.swift
// Cutover B2.5 in Core — codex's B2.4 closing-pass finding 2, written RED
// FIRST against 6e6717930 (docs/reviews/codex/codex-review-cutover-b2-4-
// closing-pass-2026-10-18.md, "Codex answer"): an attestation REMOVAL
// matched the table key (digest, kind, attested_at, answer, by_whom) without
// the label, while an addition overwrote that key's label. Copies A and B
// share attestation x; A removes it while B relabels it: A→B kept the
// relabelled row, B→A deleted it — commit order decided, nothing said.
// Now a removal deletes only the EXACT row the copy's baseline held (key and
// label), and a relabel is remove-old-row + add-new-row, so both orders end
// with the relabelled row and without the old one.
//   LOGIC   both commit orders; the relabel alone; the removal alone;
//   SCALE   CatalogCommitScaleTests (unchanged pipeline);
//   MEDIA   N/A — no media is opened.
// Under Tests/…/Store/ because it reads the database with GRDB.
// One condition per #expect.
//
// Suites (filter by SUITE): CatalogCommitB25Tests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let idA = PoisonedCatalogFixture.id(.curatedConflictA)
private let idB = PoisonedCatalogFixture.id(.curatedConflictB)

@Suite("CatalogCommit B2.5 — an attestation removal deletes only the exact row the copy saw", .serialized)
struct CatalogCommitB25Tests {

    private static let x = BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud",
                                             attestedAt: Date(timeIntervalSince1970: 1_790_000_000))
    /// x with a new label: the same table key, a different row.
    private static let xRelabelled = BackupAttestation(kind: .cloud, answer: .yes, label: "iCloud (Donna's account)",
                                                       attestedAt: Date(timeIntervalSince1970: 1_790_000_000))
    private static let z = BackupAttestation(kind: .drive, answer: .yes, label: "the drive at Tim's",
                                             attestedAt: Date(timeIntervalSince1970: 1_790_000_100))

    @Test("codex B2.4 F2: from {x, z}, A removes x while B relabels x, one commit → the relabelled x and z, in either order",
          arguments: [false, true])
    func removeVersusRelabel(bFirst: Bool) async throws {
        let s = try await seeded([Self.x, Self.z])
        defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[idA])
        let b = try #require(loaded.records[idB])
        let baseA = CatalogSharedCurated(a)
        let baseB = CatalogSharedCurated(b)
        a.backupAttestations = [Self.z]
        b.backupAttestations = [Self.xRelabelled, Self.z]
        let items = [CommitScene.item(a, baseline: baseA), CommitScene.item(b, baseline: baseB)]
        #expect(try await s.commitItems(bFirst ? items.reversed() : items).isCommitted)
        let stored = try s.attestationLabels(of: idA)
        #expect(stored == ["iCloud (Donna's account)", "the drive at Tim's"])
    }

    @Test("a relabel alone: the old row goes, the new label is stored, nothing marked a conflict")
    func relabelAlone() async throws {
        let s = try await seeded([Self.x, Self.z])
        defer { s.remove() }
        let loaded = try await s.load()
        let b = try #require(loaded.records[idB])
        let baseB = CatalogSharedCurated(b)
        b.backupAttestations = [Self.xRelabelled, Self.z]
        #expect(try await s.commitItems([CommitScene.item(b, baseline: baseB)]).isCommitted)
        let stored = try s.attestationLabels(of: idA)
        #expect(stored == ["iCloud (Donna's account)", "the drive at Tim's"])
        let conflicts = try s.attestationConflicts(of: idA)
        #expect(conflicts == 0)
    }

    @Test("a removal alone still removes the exact row")
    func removalAlone() async throws {
        let s = try await seeded([Self.x, Self.z])
        defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[idA])
        let baseA = CatalogSharedCurated(a)
        a.backupAttestations = [Self.z]
        #expect(try await s.commitItems([CommitScene.item(a, baseline: baseA)]).isCommitted)
        let stored = try s.attestationLabels(of: idA)
        #expect(stored == ["the drive at Tim's"])
    }

    /// A scene whose content (A and B share it) holds `attestations`.
    private func seeded(_ attestations: [BackupAttestation]) async throws -> CommitScene {
        let s = try await CommitScene.make()
        let first = try await s.load()
        let seed = try #require(first.records[idA])
        seed.backupAttestations = attestations
        let outcome = try await s.commit([seed])
        try #require(outcome.isCommitted)
        return s
    }
}

extension CommitScene {

    /// How many of the content's `backup_attestations` rows are marked a conflict.
    func attestationConflicts(of id: String) throws -> Int {
        try queue().read { db in
            try Int.fetchOne(db, sql: """
                SELECT count(*) FROM backup_attestations
                 WHERE conflict = 1 AND digest = (SELECT content_digest FROM files WHERE id = ?)
                """, arguments: [id]) ?? 0
        }
    }
}
