// GRDBCatalogRepositoryLedgerTests.swift
// The high-water LOG (`catalog.highwater.log`, CatalogHighWaterLedger —
// codex C′ #3, 2026-10-17) on its own: what its reader makes of a file
// (last parseable line, torn tail, empty, garbage), that every commit
// appends exactly one line, and that a poisoned log opens the store
// read-only until a person's adoption appends a readable line. The
// restore scenarios the log exists for are in GRDBCatalogRepositoryTests
// beside the sidecar's. One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("GRDBCatalogRepository — the high-water log")
struct GRDBCatalogRepositoryLedgerTests {

    @Test func theLogsLastParseableLineIsItsValue() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try fixture.writeHighWaterLog("3 2026-10-17T18:00:00Z Rick's Mac Studio\n7 2026-10-17T18:00:01Z Rick's Mac Studio\n8 2026-10-17T18")
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: fixture.url) == .value(7))
        try fixture.writeHighWaterLog("")
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: fixture.url) == .missing)
        try fixture.writeHighWaterLog("banana\n")
        guard case .unreadable(let words) = CatalogHighWaterLedger.read(besideDatabaseAt: fixture.url) else {
            Issue.record("expected .unreadable")
            return
        }
        #expect(words.contains(CatalogHighWaterLedger.fileName))
    }

    /// A log longer than the first tail read: the value is still the last
    /// line, and the fragment at the head of the tail is not mistaken for one.
    @Test func aLongLogIsReadFromItsTail() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        let lines = (1...2_000).map { "\($0) 2026-10-17T18:00:00Z host" }.joined(separator: "\n") + "\n"
        try fixture.writeHighWaterLog(lines)
        #expect(lines.utf8.count > CatalogHighWaterLedger.tailSizes[0])
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: fixture.url) == .value(2_000))
    }

    @Test func everyCommitAppendsOneLineToTheLog() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let opened = await repository.open(at: fixture.url)
        try #require(opened == .readWrite)
        _ = await repository.write(as: .ui) { _ in }
        await repository.close()
        let lines = (fixture.highWaterLogText() ?? "").split(separator: "\n")
        #expect(lines.count == 7)                                  // 0 at creation, then 1…6
        #expect(lines.last?.hasPrefix("6 ") == true)
        #expect(lines.last?.hasSuffix(" test-host") == true)
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: fixture.url) == .value(6))
    }

    /// An append onto a file that does not end in a newline (a torn
    /// append, a hand-made file) starts a fresh line rather than merging.
    @Test func anAppendNeverMergesIntoATornLastLine() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try fixture.writeHighWaterLog("5 apples")
        try CatalogHighWaterLedger.append(6, host: "test-host", besideDatabaseAt: fixture.url, durability: .fast)
        let lines = (fixture.highWaterLogText() ?? "").split(separator: "\n")
        #expect(lines.count == 2)
        #expect(lines.first == "5 apples")
        #expect(lines.last?.hasPrefix("6 ") == true)
        #expect(lines.last?.hasSuffix(" test-host") == true)
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: fixture.url) == .value(6))
    }

    @Test("an unreadable high-water log opens read-only", arguments: ["banana\n", "\u{0}\u{FF}\u{FE}", "5 apples"])
    func anUnreadableLogOpensReadOnly(text: String) async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 5)
        defer { fixture.remove() }
        try fixture.writeHighWaterLog(text)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        let outcome = await repository.open(at: fixture.url)
        guard case .readOnly(let reason) = outcome else {
            Issue.record("expected .readOnly for '\(text)', got \(outcome)")
            return
        }
        #expect(reason.contains(CatalogHighWaterLedger.fileName))
        // A person's explicit adoption repairs it: the log gains a readable line.
        let adopted = await repository.adopt(toHighWater: 6)
        #expect(adopted == .adopted(from: 5, to: 6))
        #expect(CatalogHighWaterLedger.read(besideDatabaseAt: fixture.url) == .value(6))
        let next = await repository.write(as: .ui) { _ in }
        #expect(next == .committed(generation: 7))
        await repository.close()
    }
}
