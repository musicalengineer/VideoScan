// CatalogRepositoryContractTests.swift
// The SAME tests against both CatalogRepository implementations (GRDB and
// the read-only JSON stub), wherever the operation is defined for both:
// open outcomes, generation, read, verify, close. Write / adopt /
// high-water are GRDB-only and live in GRDBCatalogRepositoryTests.
//
// One condition per #expect. The seam is only real if a caller cannot
// tell the two apart on these calls.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("CatalogRepositoryContract")
struct CatalogRepositoryContractTests {

    @Test("open names its mode", arguments: StoreKind.allCases)
    func openNamesItsMode(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 5)
        defer { fixture.remove() }
        let repository = fixture.makeRepository()
        let outcome = await repository.open(at: fixture.url)
        #expect(outcome == kind.expectedOpen)
        await repository.close()
    }

    @Test("generation is the store's generation", arguments: StoreKind.allCases)
    func generationIsTheStoresGeneration(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 5)
        defer { fixture.remove() }
        let repository = fixture.makeRepository()
        _ = await repository.open(at: fixture.url)
        let generation = await repository.generation
        #expect(generation == 5)
        await repository.close()
    }

    @Test("generation is 0 before open", arguments: StoreKind.allCases)
    func generationIsZeroBeforeOpen(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 5)
        defer { fixture.remove() }
        let generation = await fixture.makeRepository().generation
        #expect(generation == 0)
    }

    @Test("read sees the generation", arguments: StoreKind.allCases)
    func readSeesTheGeneration(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 5)
        defer { fixture.remove() }
        let repository = fixture.makeRepository()
        _ = await repository.open(at: fixture.url)
        let seen = try await repository.read { $0.generation }
        #expect(seen == 5)
        await repository.close()
    }

    @Test("read rethrows the body's error", arguments: StoreKind.allCases)
    func readRethrowsTheBodysError(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 1)
        defer { fixture.remove() }
        let repository = fixture.makeRepository()
        _ = await repository.open(at: fixture.url)
        await #expect(throws: FixtureFailure.self) {
            try await repository.read { _ in throw FixtureFailure(words: "from the body") }
        }
        await repository.close()
    }

    @Test("verify is ok at generation 5", arguments: StoreKind.allCases)
    func verifyIsOk(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 5)
        defer { fixture.remove() }
        let repository = fixture.makeRepository()
        _ = await repository.open(at: fixture.url)
        let verdict = await repository.verify()
        #expect(verdict == .ok(generation: 5, highWater: 5))
        await repository.close()
    }

    @Test("a missing folder is refused", arguments: StoreKind.allCases)
    func missingFolderIsRefused(kind: StoreKind) async throws {
        let nowhere = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)/\(kind.fileName)")
        let repository = StoreFixture(kind: kind, directory: nowhere.deletingLastPathComponent()).makeRepository()
        let outcome = await repository.open(at: nowhere)
        guard case .refused(let reason) = outcome else {
            Issue.record("expected .refused, got \(outcome)")
            return
        }
        #expect(!reason.isEmpty)
    }

    @Test("read before open throws notOpen", arguments: StoreKind.allCases)
    func readBeforeOpenThrows(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 1)
        defer { fixture.remove() }
        let repository = fixture.makeRepository()
        await #expect(throws: CatalogRepositoryError.notOpen) {
            try await repository.read { $0.generation }
        }
    }

    @Test("opening twice is refused", arguments: StoreKind.allCases)
    func openingTwiceIsRefused(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 1)
        defer { fixture.remove() }
        let repository = fixture.makeRepository()
        _ = await repository.open(at: fixture.url)
        let second = await repository.open(at: fixture.url)
        guard case .refused(let reason) = second else {
            Issue.record("expected .refused, got \(second)")
            await repository.close()
            return
        }
        #expect(reason.contains("already open"))
        await repository.close()
    }

    @Test("close is idempotent and read then throws", arguments: StoreKind.allCases)
    func closeIsIdempotent(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 1)
        defer { fixture.remove() }
        let repository = fixture.makeRepository()
        _ = await repository.open(at: fixture.url)
        await repository.close()
        await repository.close()
        await #expect(throws: CatalogRepositoryError.notOpen) {
            try await repository.read { $0.generation }
        }
    }

    @Test("verify before open names it", arguments: StoreKind.allCases)
    func verifyBeforeOpen(kind: StoreKind) async throws {
        let fixture = try await StoreFixture.make(kind, generation: 1)
        defer { fixture.remove() }
        let verdict = await fixture.makeRepository().verify()
        #expect(verdict == .problems(["not open"]))
    }
}
