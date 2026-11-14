// CatalogCloseDrainTests.swift
// GH #423 — close is "stop admitting, drain, then close".
//
// The weekly Thread Sanitizer run found a read STARTING while close ran: the
// repository is an actor, but an actor is released at every `await`, so while
// one read awaited the pool, close() could run and a second read could reach
// GRDB's unsynchronised `readerPool` as close cleared it. The reader then got
// whatever SQLite said about a closed connection, by luck of timing.
//
// The rule these tests pin: once close has begun, a read is refused with
// `notOpen`; close waits for the reads already inside; only then does it
// checkpoint and close the pool. A read never sees a half-closed pool.

import Foundation
import GRDB
import os
import Testing
@testable import VideoScanCore

@Suite("Catalog store — close stops admitting reads, drains, then closes (#423)")
struct CatalogCloseDrainTests {

    /// A read whose body waits inside the pool until the test lets it go.
    private final class HeldRead: Sendable {
        private let entered = OSAllocatedUnfairLock(initialState: false)
        private let release = DispatchSemaphore(value: 0)

        /// Runs ON GRDB's reader queue (a real thread, not the cooperative pool).
        func body() {
            entered.withLock { $0 = true }
            release.wait()
        }
        func letGo() { release.signal() }
        var isInside: Bool { entered.withLock { $0 } }
    }

    private final class Flag: Sendable {
        private let value = OSAllocatedUnfairLock(initialState: false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }

    /// Polls (never blocks a cooperative thread) until `condition`, or 10 s.
    private static func wait(until condition: @Sendable () async -> Bool) async -> Bool {
        for _ in 0..<2_000 {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    private static func walBytes(beside url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path + "-wal"))?[.size] as? Int
        return size ?? 0
    }

    private static func openStore(generation: Int = 3) async throws -> (StoreFixture, GRDBCatalogRepository) {
        let fixture = try await StoreFixture.make(.grdb, generation: generation)
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        return (fixture, repository)
    }

    @Test("LOGIC: with a read inside, close waits; a new read is refused notOpen; the held read finishes with its answer; the file ends checkpointed")
    func closeWaitsForTheReadInsideAndRefusesNewOnes() async throws {
        let (fixture, repository) = try await Self.openStore(generation: 3)
        defer { fixture.remove() }
        let held = HeldRead()
        let closed = Flag()

        let reader = Task.detached { try await repository.read { reader in held.body(); return reader.generation } }
        try #require(await Self.wait { held.isInside })

        let closer = Task.detached { await repository.close(); closed.set() }
        try #require(await Self.wait { await repository.closeDrainState.closing }, "close never said it had begun")
        #expect(await repository.closeDrainState.readsInFlight == 1)

        // Stop admitting: a read that arrives now is refused in the store's own word.
        await #expect(throws: CatalogRepositoryError.notOpen) {
            _ = try await repository.read { $0.generation }
        }
        #expect(await repository.verify() == .problems(["not open"]))
        // Drain: close has not finished, because the read is still inside.
        #expect(!closed.isSet)

        held.letGo()
        #expect(try await reader.value == 3, "the read admitted before close finishes with its answer, not an error")
        await closer.value
        #expect(closed.isSet)
        #expect(Self.walBytes(beside: fixture.url) == 0, "the checkpoint ran after the drain, with no reader in its way")

        // Closed is closed, and the same object opens again with nothing lost.
        await #expect(throws: CatalogRepositoryError.notOpen) { _ = try await repository.read { $0.generation } }
        #expect(await repository.open(at: fixture.url) == .readWrite)
        #expect(try await repository.read { $0.generation } == 3)
        await repository.close()
    }

    @Test("LOGIC: a second close that arrives during the first waits for it; neither runs beside the other")
    func aSecondCloseWaitsForTheFirst() async throws {
        let (fixture, repository) = try await Self.openStore()
        defer { fixture.remove() }
        let held = HeldRead()
        let first = Flag(), second = Flag()

        let reader = Task.detached { try await repository.read { _ in held.body() } }
        try #require(await Self.wait { held.isInside })
        let closerA = Task.detached { await repository.close(); first.set() }
        try #require(await Self.wait { await repository.closeDrainState.closing })
        let closerB = Task.detached { await repository.close(); second.set() }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!first.isSet && !second.isSet)

        held.letGo()
        try await reader.value
        await closerA.value
        await closerB.value
        #expect(first.isSet && second.isSet)
        #expect(Self.walBytes(beside: fixture.url) == 0)
        #expect(await repository.open(at: fixture.url) == .readWrite, "the flags are clear again: the store opens")
        await repository.close()
    }

    /// The shape Thread Sanitizer reported, through the repository: reads
    /// still STARTING while close runs. Before the fix a reader could meet the
    /// pool mid-close (a GRDB / SQLite error, and the #423 race report under
    /// `swift test --sanitize thread`). Now each read has exactly two endings.
    @Test("ISOLATION: 16 reads racing close, 40 rounds — every read either answers or is refused notOpen, nothing else",
          .timeLimit(.minutes(2)))
    func readsRacingCloseHaveOnlyTwoEndings() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 2)
        defer { fixture.remove() }
        var answered = 0, refused = 0
        var others: [String] = []
        for _ in 0..<40 {
            let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
            try #require(await repository.open(at: fixture.url) == .readWrite)
            let readers = (0..<16).map { _ in
                Task.detached { () -> Result<Int, any Error> in
                    do { return .success(try await repository.read { $0.generation }) } catch { return .failure(error) }
                }
            }
            await repository.close()
            for reader in readers {
                switch await reader.value {
                case .success(let generation):
                    #expect(generation == 2)
                    answered += 1
                case .failure(let error):
                    if error as? CatalogRepositoryError == .notOpen { refused += 1 } else { others.append(String(describing: error)) }
                }
            }
            let after = await repository.closeDrainState
            #expect(!after.closing && after.readsInFlight == 0)
        }
        #expect(others.isEmpty, "a read met the pool mid-close: \(others.prefix(3))")
        #expect(answered + refused == 40 * 16)
    }

    @Test("SCALE: 2,000 reads in flight at close all return, and close finishes within 10 s")
    func closeDrainsTwoThousandReads() async throws {
        let (fixture, repository) = try await Self.openStore()
        defer { fixture.remove() }
        let started = ContinuousClock.now
        let readers = (0..<2_000).map { _ in
            Task.detached { (try? await repository.read { $0.generation }) }
        }
        await repository.close()
        var answers = 0
        for reader in readers { if await reader.value != nil { answers += 1 } }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .seconds(10), "took \(elapsed)")
        let after = await repository.closeDrainState
            #expect(!after.closing && after.readsInFlight == 0)
        #expect(Self.walBytes(beside: fixture.url) == 0)
        #expect(answers <= 2_000)
    }

    @Test("SENSOR: every pool.read inside the repository actor is admitted first, and close sets `closing` before its first await")
    func everyActorReadIsAdmitted() throws {
        let source = try String(contentsOf: Self.repositorySource(), encoding: .utf8)
        let lines = source.components(separatedBy: "\n")
        // The reads that run on the actor's OWN open pool (not the static open-time
        // helpers, which take a pool no close can reach yet).
        var unadmitted: [String] = []
        var found = 0
        for (index, line) in lines.enumerated() where line.contains("await pool.read") || line.contains("checkEngine(pool)") {
            guard let declared = lines[..<index].lastIndex(where: { $0.contains("func ") }) else { continue }
            if lines[declared].contains("static func") { continue }
            found += 1
            let sinceDeclared = lines[declared...index].joined(separator: "\n")
            if !sinceDeclared.contains("admitRead()") { unadmitted.append("line \(index + 1): \(line.trimmingCharacters(in: .whitespaces))") }
        }
        #expect(found >= 5, "the sensor found only \(found) actor reads — has the file moved?")
        #expect(unadmitted.isEmpty, "a read the drain cannot see: \(unadmitted)")

        let close = try #require(source.range(of: "public func close() async {"))
        let body = source[close.upperBound...]
        let closingSet = try #require(body.range(of: "closing = true"))
        let firstPoolUse = try #require(body.range(of: "decideAtClose(pool"))
        #expect(closingSet.lowerBound < firstPoolUse.lowerBound)
        let drain = try #require(body.range(of: "drained = $0"))
        #expect(drain.lowerBound < firstPoolUse.lowerBound, "close must drain before it touches the pool")
    }

    private static func repositorySource() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore/Store/GRDBCatalogRepository.swift")
    }
}
