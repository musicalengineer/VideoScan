// CatalogCommitB26Tests.swift
// Cutover B2.6 in Core — the same class as codex's B2.4 closing-pass finding
// 2 (docs/reviews/codex/codex-review-cutover-b2-4-closing-pass-2026-10-18.md),
// for PEOPLE, written RED FIRST against 87c84b898: a people removal matched
// (name, kind) without the confirmation date, while a re-dated confirmation
// was an in-place upsert. Copies A and B share "Donna confirmed at t1"; A
// un-confirms Donna while B re-confirms her at t2: A→B kept Donna at t2,
// B→A deleted her — commit order decided, nothing said.
// Now a removal deletes only the EXACT row the copy's baseline held (name,
// kind AND confirmed_at), and a re-date is remove-old-row + add-new-row, so
// both orders end with Donna confirmed at t2 and without the t1 row.
//   LOGIC   both commit orders; the re-date alone; the removal alone; a
//           rejection of the copy's own confirmation; reject-vs-re-date ends
//           the same in both orders;
//   SCALE   CatalogCommitScaleTests (unchanged pipeline);
//   MEDIA   N/A — no media is opened.
// Under Tests/…/Store/ because it reads the database with GRDB.
// One condition per #expect.
//
// Suites (filter by SUITE): CatalogCommitB26Tests

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private let idA = PoisonedCatalogFixture.id(.curatedConflictA)
private let idB = PoisonedCatalogFixture.id(.curatedConflictB)

@Suite("CatalogCommit B2.6 — a people removal deletes only the exact row the copy saw", .serialized)
struct CatalogCommitB26Tests {

    private static let t1 = Date(timeIntervalSince1970: 1_790_000_000)
    private static let t2 = Date(timeIntervalSince1970: 1_790_500_000)
    private static let donna = ConfirmedTag(name: "Donna", confirmedAt: t1)
    private static let donnaRedated = ConfirmedTag(name: "Donna", confirmedAt: t2)
    private static let tim = ConfirmedTag(name: "Tim", confirmedAt: Date(timeIntervalSince1970: 1_790_000_100))

    @Test("A un-confirms Donna while B re-confirms her with a new date, one commit → Donna at the new date, in either order",
          arguments: [false, true])
    func removeVersusRedate(bFirst: Bool) async throws {
        let s = try await seeded([Self.donna, Self.tim])
        defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[idA])
        let b = try #require(loaded.records[idB])
        let baseA = CatalogSharedCurated(a)
        let baseB = CatalogSharedCurated(b)
        a.confirmedByUserPeople = [Self.tim]
        b.confirmedByUserPeople = [Self.donnaRedated, Self.tim]
        let items = [CommitScene.item(a, baseline: baseA), CommitScene.item(b, baseline: baseB)]
        #expect(try await s.commitItems(bFirst ? items.reversed() : items).isCommitted)
        let stored = try s.peopleRows(of: idA)
        #expect(stored == ["confirmed Donna 1790500000 settled", "confirmed Tim 1790000100 settled"])
    }

    @Test("a re-date alone: the old row goes, the new date is stored, nothing marked a conflict")
    func redateAlone() async throws {
        let s = try await seeded([Self.donna, Self.tim])
        defer { s.remove() }
        let loaded = try await s.load()
        let b = try #require(loaded.records[idB])
        let baseB = CatalogSharedCurated(b)
        b.confirmedByUserPeople = [Self.donnaRedated, Self.tim]
        #expect(try await s.commitItems([CommitScene.item(b, baseline: baseB)]).isCommitted)
        let stored = try s.peopleRows(of: idA)
        #expect(stored == ["confirmed Donna 1790500000 settled", "confirmed Tim 1790000100 settled"])
    }

    @Test("a removal alone still removes the exact row")
    func removalAlone() async throws {
        let s = try await seeded([Self.donna, Self.tim])
        defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[idA])
        let baseA = CatalogSharedCurated(a)
        a.confirmedByUserPeople = [Self.tim]
        #expect(try await s.commitItems([CommitScene.item(a, baseline: baseA)]).isCommitted)
        let stored = try s.peopleRows(of: idA)
        #expect(stored == ["confirmed Tim 1790000100 settled"])
    }

    @Test("a copy rejecting its OWN confirmation: the confirmed row goes, the rejection is stored")
    func rejectOwnConfirmation() async throws {
        let s = try await seeded([Self.donna, Self.tim])
        defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[idA])
        let baseA = CatalogSharedCurated(a)
        a.confirmedByUserPeople = [Self.tim]
        a.rejectedPeople = ["Donna"]
        #expect(try await s.commitItems([CommitScene.item(a, baseline: baseA)]).isCommitted)
        let stored = try s.peopleRows(of: idA)
        #expect(stored == ["confirmed Tim 1790000100 settled", "rejected Donna - settled"])
    }

    @Test("A rejects Donna while B re-confirms her with a new date: both commit orders store the same rows")
    func rejectVersusRedateIsOrderIndependent() async throws {
        let aFirst = try await rejectVersusRedate(bFirst: false)
        let bFirst = try await rejectVersusRedate(bFirst: true)
        #expect(aFirst == bFirst)
    }

    private func rejectVersusRedate(bFirst: Bool) async throws -> [String] {
        let s = try await seeded([Self.donna, Self.tim])
        defer { s.remove() }
        let loaded = try await s.load()
        let a = try #require(loaded.records[idA])
        let b = try #require(loaded.records[idB])
        let baseA = CatalogSharedCurated(a)
        let baseB = CatalogSharedCurated(b)
        a.confirmedByUserPeople = [Self.tim]
        a.rejectedPeople = ["Donna"]
        b.confirmedByUserPeople = [Self.donnaRedated, Self.tim]
        let items = [CommitScene.item(a, baseline: baseA), CommitScene.item(b, baseline: baseB)]
        try #require(try await s.commitItems(bFirst ? items.reversed() : items).isCommitted)
        return try s.peopleRows(of: idA)
    }

    /// A scene whose content (A and B share it) has `confirmed` people.
    private func seeded(_ confirmed: [ConfirmedTag]) async throws -> CommitScene {
        let s = try await CommitScene.make()
        let first = try await s.load()
        let seed = try #require(first.records[idA])
        seed.confirmedByUserPeople = confirmed
        let outcome = try await s.commit([seed])
        try #require(outcome.isCommitted)
        return s
    }
}

extension CommitScene {

    /// The content's `people_tags` rows as "kind name confirmed_at settled|conflict", sorted.
    func peopleRows(of id: String) throws -> [String] {
        try queue().read { db in
            try Row.fetchAll(db, sql: """
                SELECT kind, name, confirmed_at, conflict FROM people_tags
                 WHERE digest = (SELECT content_digest FROM files WHERE id = ?) ORDER BY kind, name, confirmed_at
                """, arguments: [id]).map { r in
                let at: Int64? = r[2]
                let conflict: Int64 = r[3]
                let state = conflict == 1 ? "conflict" : "settled"
                return "\(r[0] as String) \(r[1] as String) \(at.map(String.init) ?? "-") \(state)"
            }
        }
    }
}
