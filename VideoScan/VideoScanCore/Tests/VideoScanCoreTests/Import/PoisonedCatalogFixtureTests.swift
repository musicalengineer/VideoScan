// PoisonedCatalogFixtureTests.swift
// The poisoned fixture must be a catalog.json the APP can open. It is read
// here through the app's own record decoder (`VideoRecord.init(from:)`,
// C/VideoRecord.swift:756) with the app's decoder settings
// (`CatalogStore.decode(url:)`, A/Catalog/CatalogStore.swift:803: JSONDecoder,
// .iso8601 dates) under a verbatim copy of the `CatalogSnapshot` header.
// `CatalogSnapshot` itself lives in the app target, which this package cannot
// import; the Mac-side importer tests decode through `CatalogStore` proper.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Poisoned fixture — read by the app's own record decoder")
struct PoisonedCatalogFixtureAppDecodeTests {

    /// `CatalogSnapshot` (A/Catalog/CatalogStore.swift:78) — its header
    /// decode, verbatim, over the real `VideoRecord` decoder.
    private struct AppSnapshot: Decodable {
        var version: Int
        var generation: Int
        var savedAt: Date
        var records: [VideoRecord]
        var savedFromHost: String

        private enum CodingKeys: String, CodingKey { case version, generation, savedAt, records, savedFromHost }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
            generation = try c.decodeIfPresent(Int.self, forKey: .generation) ?? 0
            savedAt = try c.decodeIfPresent(Date.self, forKey: .savedAt) ?? Date()
            records = try c.decodeIfPresent([VideoRecord].self, forKey: .records) ?? []
            savedFromHost = try c.decodeIfPresent(String.self, forKey: .savedFromHost) ?? ""
        }
    }

    /// `CatalogStore.decode(url:)`: a JSONDecoder with .iso8601 dates.
    private static func decodeLikeTheApp(_ data: Data) throws -> AppSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppSnapshot.self, from: data)
    }

    @Test func theAppDecoderReadsTheHeaderAndEveryRow() throws {
        let fixture = PoisonedCatalogFixture()
        let snapshot = try Self.decodeLikeTheApp(fixture.catalogData)
        #expect(snapshot.version == 6)
        #expect(snapshot.generation == PoisonedCatalogFixture.generation)
        #expect(snapshot.savedFromHost == "FixtureHost")
        #expect(snapshot.records.count == fixture.order.count)
    }

    @Test func theAppDecoderSeesTheSameIdsAndPathsInFileOrder() throws {
        let fixture = PoisonedCatalogFixture()
        let snapshot = try Self.decodeLikeTheApp(fixture.catalogData)
        #expect(snapshot.records.map { $0.id.uuidString } == fixture.order.map { PoisonedCatalogFixture.id($0) })
        #expect(snapshot.records.map(\.fullPath) == fixture.order.map { PoisonedCatalogFixture.path($0) })
    }

    /// The app and the importer read the same whole-file digests off the
    /// same bytes (nil where the shape carries none).
    @Test func theAppDecoderSeesTheSameDigestsAsTheImporter() throws {
        let fixture = PoisonedCatalogFixture()
        let snapshot = try Self.decodeLikeTheApp(fixture.catalogData)
        let importer = try CatalogFileJSON.decode(fixture.catalogData).records
        #expect(snapshot.records.map { $0.contentFixity?.digest } == importer.map { $0.contentFixity?.digest })
    }

    @Test func theAppDecoderSeesTheTombstoneAndTheConflictingStars() throws {
        let fixture = PoisonedCatalogFixture()
        let snapshot = try Self.decodeLikeTheApp(fixture.catalogData)
        let tombstone = try #require(fixture.ordinals(of: .tombstonedWithDigest).first)
        let a = try #require(fixture.ordinals(of: .curatedConflictA).first)
        let b = try #require(fixture.ordinals(of: .curatedConflictB).first)
        #expect(snapshot.records[tombstone].removal?.state == .inTrash)
        #expect(snapshot.records[a].starRating == 2)
        #expect(snapshot.records[b].starRating == 3)
        #expect(snapshot.records[a].userDate == "1991")
    }

    @Test func theAppDecoderSeesTheAuditStampTheGateReads() throws {
        let fixture = PoisonedCatalogFixture()
        let snapshot = try Self.decodeLikeTheApp(fixture.catalogData)
        let healthy = try #require(fixture.ordinals(of: .healthy).first)
        let neverSeen = try #require(fixture.ordinals(of: .neverSeen).first)
        let seenAt = try #require(snapshot.records[healthy].auditSeenOn?.seenAt)
        #expect(Int64(seenAt.timeIntervalSince1970) == PoisonedCatalogFixture.seenAt)
        #expect(snapshot.records[neverSeen].auditSeenOn == nil)
    }
}
