// CatalogSpaceFloorTests.swift
// GH #357 — the free-space floor a catalog write is checked against before
// BEGIN (CatalogSpaceFloor → PreflightGate's edit floor; Rick 2026-10-21:
// 2 × (catalog + WAL), never under 1 GB). The disk-image half (a real full
// volume, the 100k fail-fast budget) is CatalogWriteCornerDiskTests; this is:
//   LOGIC      the rule's arithmetic on any disk: the 1 GB minimum, the
//              2 × (catalog + WAL) multiple with the WAL counted, the exact
//              boundary, an unreadable disk never refusing, `.offForTests`;
//   ISOLATION  a poisoned catalog folder (no WAL, no database) still gets the
//              minimum floor, never a zero one; the real statfs reading of a
//              temp folder is sane;
//   SENSOR     the per-write cost (statfs + two stats) stays far under a
//              millisecond, so it can sit in front of every debounced save;
//              the production repository refuses a write below the floor
//              through the real door, with no body run.
//   SCALE      N/A for the rule (constant work per write); the 100k commit
//              under disk pressure is CatalogWriteCornerDiskTests.
//   MEDIA      N/A.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Catalog space floor — refuse a save up front below 2 × (catalog + WAL), never under 1 GB")
struct CatalogSpaceFloorTests {

    static let gb: Int64 = 1_000_000_000

    static func disk(free: Int64, total: Int64 = 500 * gb) -> PreflightVolume {
        PreflightVolume(id: "/Volumes/Test", name: "Test", availableBytes: free, totalBytes: total)
    }

    // MARK: - Logic

    @Test("LOGIC: the 1 GB minimum holds for a small catalog; the boundary is exact")
    func minimumFloor() {
        let rule = PreflightThresholds()
        let small: UInt64 = 10_000_000                                    // 10 MB catalog + WAL
        #expect(CatalogSpaceFloor.refusal(volume: Self.disk(free: Self.gb - 1), catalogBytes: small, thresholds: rule) != nil)
        #expect(CatalogSpaceFloor.refusal(volume: Self.disk(free: Self.gb), catalogBytes: small, thresholds: rule) == nil)
        #expect(CatalogSpaceFloor.refusal(volume: Self.disk(free: 100 * Self.gb), catalogBytes: small, thresholds: rule) == nil)
    }

    @Test("LOGIC: above 512 MB of catalog + WAL the floor is twice that — the WAL counts")
    func multipleOfCatalogAndWAL() {
        let rule = PreflightThresholds()
        let catalogAndWAL: UInt64 = 3_000_000_000                         // e.g. 2 GB database + 1 GB WAL
        #expect(CatalogSpaceFloor.refusal(volume: Self.disk(free: 6 * Self.gb - 1), catalogBytes: catalogAndWAL, thresholds: rule) != nil)
        #expect(CatalogSpaceFloor.refusal(volume: Self.disk(free: 6 * Self.gb), catalogBytes: catalogAndWAL, thresholds: rule) == nil)
    }

    @Test("LOGIC: the words say nothing was saved, why (free space), how much is free and how much more to free, and that the changes are kept")
    func refusalWords() throws {
        let words = try #require(CatalogSpaceFloor.refusal(volume: Self.disk(free: 200_000_000), catalogBytes: 0,
                                                           thresholds: PreflightThresholds()))
        #expect(words.hasPrefix("nothing was saved — not enough free space."), Comment(rawValue: words))
        #expect(words.contains("Test has only 0.2 GB free"), Comment(rawValue: words))
        #expect(words.contains("free at least 0.8 GB more"), Comment(rawValue: words))
        #expect(words.hasSuffix("The changes are kept in memory."), Comment(rawValue: words))
    }

    @Test("LOGIC: a disk that cannot be read does not refuse (a failed probe is not a full disk); .offForTests never refuses")
    func unreadableAndOff() throws {
        #expect(CatalogSpaceFloor.refusal(volume: nil, catalogBytes: 0, thresholds: PreflightThresholds()) == nil)
        #expect(CatalogSpaceFloor.refusal(volume: Self.disk(free: 0, total: 0), catalogBytes: 0, thresholds: PreflightThresholds()) == nil)
        let folder = try StoreFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        var huge = PreflightThresholds()
        huge.editHoldFloorBytes = .max
        #expect(CatalogSpaceFloor.offForTests.refusal(forDatabaseAt: folder.appendingPathComponent("catalog.sqlite")) == nil)
        #expect(CatalogSpaceFloor.preflight(huge).refusal(forDatabaseAt: folder.appendingPathComponent("catalog.sqlite")) != nil)
    }

    // MARK: - Isolation

    @Test("ISOLATION: no database and no WAL beside the path → 0 catalog bytes → the minimum floor, never zero; the WAL is counted when present")
    func poisonedFolder() throws {
        let folder = try StoreFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("catalog.sqlite")
        #expect(CatalogSpaceFloor.catalogBytes(url) == 0)
        try Data(count: 4096).write(to: url)
        try Data(count: 1000).write(to: URL(fileURLWithPath: url.path + "-wal"))
        #expect(CatalogSpaceFloor.catalogBytes(url) == 5096)
        #expect(PreflightThresholds().editHoldFreeBytes(catalogBytes: 0) == Self.gb)
    }

    @Test("ISOLATION: the real statfs reading of a temp folder is sane (measurable, free ≤ total, named)")
    func realReading() throws {
        let folder = try StoreFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let volume = try #require(CatalogSpaceFloor.volume(holding: folder.appendingPathComponent("catalog.sqlite")))
        #expect(volume.isMeasurable)
        #expect(volume.availableBytes >= 0 && volume.availableBytes <= volume.totalBytes)
        #expect(!volume.id.isEmpty && !volume.name.isEmpty)
        #expect(CatalogSpaceFloor.volume(holding: URL(fileURLWithPath: "/no/such/folder/catalog.sqlite")) == nil)
    }

    // MARK: - Sensor

    @Test("SENSOR: the floor check (statfs + two stats) costs under 1 ms a write — 1,000 checks in under 1 s",
          .tags(.quietMachine))
    func costPerWrite() throws {
        let fixture = try StoreFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        let url = fixture.appendingPathComponent("catalog.sqlite")
        try Data(count: 4096).write(to: url)
        let clock = ContinuousClock()
        let start = clock.now
        var refusals = 0
        for _ in 0..<1_000 where CatalogSpaceFloor.production.refusal(forDatabaseAt: url) != nil { refusals += 1 }
        let elapsed = clock.now - start
        print("[space-floor] 1,000 checks: \(elapsed), \(refusals) refusals")
        expectBudget(elapsed, under: .seconds(1), "1,000 floor checks took \(elapsed)")
    }

    @Test("SENSOR: through the real door — a repository whose floor the disk cannot meet refuses every write before BEGIN; no body runs; generation and witness unchanged")
    func refusedThroughTheDoor() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 3)
        defer { fixture.remove() }
        var unreachable = PreflightThresholds()
        unreachable.editHoldFloorBytes = .max
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests, spaceFloor: .preflight(unreachable))
        try #require(await repository.open(at: fixture.url) == .readWrite)
        let ran = BodyRan()
        let outcome = await repository.write(as: .ui) { _ in ran.mark() }
        let blocking = repository.writeBlocking(as: .ui) { _ in ran.mark() }
        #expect(await repository.generation == 3)
        await repository.close()
        guard case .refused(let words) = outcome, case .refused = blocking else {
            Issue.record("below the floor: write \(outcome), writeBlocking \(blocking)"); return
        }
        #expect(words.contains("not enough free space"), Comment(rawValue: words))
        #expect(!ran.value, "a body ran below the floor")
        #expect(fixture.highWaterText() == "3")
    }

    /// Records whether a write's body ran (it runs on GRDB's writer queue).
    final class BodyRan: @unchecked Sendable {
        private let lock = NSLock()
        private var ran = false
        func mark() { lock.withLock { ran = true } }
        var value: Bool { lock.withLock { ran } }
    }
}
