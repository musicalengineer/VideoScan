// ObservationsStoreBehaviourTests.swift — what a caller of the Observations
// window's store depends on beyond the thin net in ObservationsTests.swift
// (Observations/ObservationsStore.swift).
//
//   LOGIC      LatestWins by itself: only the current ticket publishes; the
//              answer stays for the same key and goes when the key changes;
//              a read that gave up on its own is not a failure.
//   TRUTH      a Refresh keeps the report on screen; a new scope drops the
//              old scope's report AT ONCE (never the old numbers under the new
//              header); an older read finishing late never replaces a newer
//              one; a hit that cannot be shown says why in words.
//   ISOLATION  a failed search is words, logged, and a retry clears it; the
//              window closing stops both reads and nothing publishes after.
//   SCALE      10,000 requests in a burst publish exactly one answer inside
//              a time budget; a search at the 2,000-hit cap is said as capped.
//   PRODUCTION `ObservationsLoader.production(model:)` on a real cutover
//              scene: the report is this session's catalog.sqlite (its
//              contents equal an independent read of the same catalog), the
//              read writes nothing, and a session with no catalog open
//              refuses in words.
// Synthetic names only.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private enum Obs {
    typealias Notes = FrameIndexJobTests.Notes

    static func report(_ scope: ObservationsScope, files: Int = 3, analyzed: Int = 2) -> ObservationsReport {
        ObservationsReport(scope: scope, files: files, contents: files, analyzed: analyzed,
                           technical: .init(layer: .technical, summary: "", groups: []),
                           patterns: .init(layer: .patterns, summary: "", groups: []),
                           collection: .init(layer: .collection, summary: "", groups: []), builtAt: 1_762_470_000)
    }

    static func hit(_ n: Int, recordID: UUID? = UUID(), removed: Bool = false) -> ObservationsSearch.Hit {
        ObservationsSearch.Hit(id: "\(n)", kind: .scene, text: "a table with a cake", at: Double(n), source: "qwen3-vl-8b", digest: "d\(n)",
                               recordID: recordID, filename: "Tape_\(n).dv", path: "/V/tapes/Tape_\(n).dv", removed: removed)
    }

    static func found(_ query: String, hits: Int = 1, truncated: Bool = false) -> ObservationsSearch {
        ObservationsSearch(query: query, hits: (0..<hits).map { hit($0) }, truncated: truncated, counts: [.scene: hits])
    }

    @MainActor
    static func loader(report: @escaping ObservationsLoader.LoadReport = { Obs.report($0) },
                       search: @escaping ObservationsLoader.Search = { _, q in Obs.found(q) },
                       reveal: @escaping @MainActor (UUID) -> Bool = { _ in true }, notes: Notes? = nil) -> ObservationsLoader {
        ObservationsLoader(loadReport: report, search: search, reveal: reveal, dossiers: nil, note: { notes?.lines.append($0) })
    }

    /// Holds until `release` is set — and, unlike a stream, keeps holding after its task is cancelled, so a
    /// superseded read really does finish LATE (the case latest-wins exists for).
    static func hold(until release: FrameIndexJobTests.Flag) async {
        while !release.isSet {
            try? await Task.sleep(for: .milliseconds(2))
            await Task.yield()
        }
    }
}

// MARK: - LatestWins (the one rule both stores follow)

@Suite("Observations — latest wins")
struct LatestWinsTests {

    /// Await the ticket and hand its result to `finish` (what both stores do).
    private static func settle<K: Equatable, V: Sendable>(_ run: inout LatestWins<K, V>, _ ticket: LatestWins<K, V>.Ticket) async -> Bool {
        let result = await ticket.result
        return run.finish(ticket, result)
    }

    @Test func onlyTheCurrentTicketPublishesAndTheAnswerStaysForTheSameKey() async {
        var run = LatestWins<String, Int>()
        #expect(run.key == nil && !run.isLoading && run.value == nil && run.failure == nil)

        let first = run.begin("tapes") { 1 }
        #expect(run.isLoading && run.key == "tapes")
        let second = run.begin("tapes") { 2 }
        #expect(first.isCancelled, "a newer request cancels the one it replaces")
        let olderPublished = await Self.settle(&run, first)
        #expect(olderPublished == false, "the older ticket has nothing to say")
        #expect(run.isLoading && run.value == nil, "and it does not end the newer request")
        let newerPublished = await Self.settle(&run, second)
        #expect(newerPublished == true && run.value == 2 && !run.isLoading && run.failure == nil)
        let twice = await Self.settle(&run, second)
        #expect(twice == false, "a ticket publishes once")

        let refresh = run.begin("tapes") { 3 }
        #expect(run.value == 2 && run.isLoading, "the same request re-run: the answer stays on screen meanwhile")
        let refreshed = await Self.settle(&run, refresh)
        #expect(refreshed && run.value == 3)

        let other = run.begin("beach") { 4 }
        #expect(run.value == nil && run.key == "beach", "a new key: the old key's answer goes at once")
        let otherPublished = await Self.settle(&run, other)
        #expect(otherPublished && run.value == 4)
    }

    @Test func aFailureIsShownAndAResetForgetsEverything() async {
        var run = LatestWins<String, Int>()
        let failing = run.begin("tapes") { throw Refusal("the catalog is closed") }
        let said = await Self.settle(&run, failing)
        #expect(said == true, "a failure is something to say")
        #expect(run.failure.map { "\($0)" } == "the catalog is closed" && !run.isLoading && run.value == nil)

        let retry = run.begin("tapes") { 7 }
        #expect(run.failure == nil && run.isLoading, "a retry clears the failure at once")
        run.reset()
        #expect(retry.isCancelled && run.key == nil && run.value == nil && !run.isLoading && run.failure == nil)
        let afterReset = await Self.settle(&run, retry)
        #expect(afterReset == false && run.value == nil && run.key == nil, "a reset request never publishes")
    }

    @Test func aReadThatGaveUpOnItsOwnIsNotAFailure() async {
        var run = LatestWins<String, Int>()
        let gaveUp = run.begin("tapes") { throw CancellationError() }
        let said = await Self.settle(&run, gaveUp)
        #expect(said == false, "nothing to say")
        #expect(run.failure == nil && !run.isLoading && run.value == nil, "back to idle, not 'failed'")

        let good = run.begin("tapes") { 5 }
        _ = await Self.settle(&run, good)
        let again = run.begin("tapes") { throw CancellationError() }
        let saidAgain = await Self.settle(&run, again)
        #expect(saidAgain == false && run.value == 5 && run.failure == nil && !run.isLoading, "the answer already shown stays shown")
    }

    @Test(.timeLimit(.minutes(1)))
    func tenThousandRequestsInABurstPublishExactlyOneAnswer() async {
        var run = LatestWins<Int, Int>()
        var tickets: [LatestWins<Int, Int>.Ticket] = []
        tickets.reserveCapacity(10_000)
        let started = ContinuousClock.now
        for n in 0..<10_000 { tickets.append(run.begin(n) { n }) }
        var published = 0
        for ticket in tickets {
            if await Self.settle(&run, ticket) { published += 1 }
        }
        let took = ContinuousClock.now - started
        #expect(published == 1 && run.value == 9_999 && run.key == 9_999 && !run.isLoading)
        #expect(took < .seconds(10), "10,000 superseded requests settled in \(took)")
    }
}

// MARK: - The store

@Suite("Observations — the store, hardening")
@MainActor
struct ObservationsStoreBehaviourTests {

    @Test func aRefreshKeepsTheReportOnScreenWhileItRereads() async {
        let calls = ObsCounter()
        let gate = AsyncStream<Void>.makeStream()
        let store = ObservationsStore(scope: .everything, loader: Obs.loader(report: { scope in
            let n = calls.bump()
            if n == 2 { for await _ in gate.stream { break } }
            return Obs.report(scope, files: 2 + n)
        }))
        await store.load()
        #expect(store.report?.files == 3 && store.reads == 1)
        let refresh = Task { await store.load() }
        while !store.loading { await Task.yield() }
        #expect(store.report?.files == 3, "the report already read stays on screen during a Refresh")
        gate.continuation.yield()
        await refresh.value
        #expect(store.report?.files == 4 && !store.loading && store.reads == 2, "and is replaced by the newer read")
    }

    @Test func aNewScopeDropsTheOldScopesReportAtOnceAndALateOldReadNeverReplacesTheNewOne() async throws {
        let release = FrameIndexJobTests.Flag()
        let notes = Obs.Notes()
        let store = ObservationsStore(scope: .folder("/V/tapes"), loader: Obs.loader(report: { scope in
            if scope == .folder("/V/slow") { await Obs.hold(until: release) }
            return Obs.report(scope, files: scope == .everything ? 100 : 7)
        }, notes: notes))
        await store.load()
        #expect(store.report?.scope == .folder("/V/tapes"))

        let slow = Task { await store.set(scope: .folder("/V/slow")) }
        try await FrameIndexJobTests.until("the slow read is in flight") { store.scope == .folder("/V/slow") && store.loading }
        #expect(store.report == nil, "truth: /V/tapes' numbers are never shown under the /V/slow header")

        await store.set(scope: .everything)
        #expect(store.report?.scope == .everything && store.report?.files == 100 && !store.loading)
        release.set()
        await slow.value
        #expect(store.report?.scope == .everything && store.report?.files == 100, "the older read finished late and published nothing")
        #expect(store.reads == 2, "two reads were shown: /V/tapes and everything")
        #expect(!notes.lines.contains { $0.contains("/V/slow") }, "nothing is logged for a read nobody saw: \(notes.lines)")
    }

    @Test func settingTheScopeAlreadyShownReadsNothing() async {
        let calls = ObsCounter()
        let store = ObservationsStore(scope: .folder("/V/tapes"), loader: Obs.loader(report: { calls.bump(); return Obs.report($0) }))
        await store.load()
        await store.search("cake")
        await store.set(scope: .folder("/V/tapes"))
        #expect(calls.value == 1 && store.search != nil, "the same scope again: no re-read, the hits stay")
    }

    @Test func aFailedSearchIsWordsIsLoggedAndARetryClearsIt() async {
        let calls = ObsCounter()
        let notes = Obs.Notes()
        let store = ObservationsStore(scope: .everything, loader: Obs.loader(search: { _, q in
            if calls.bump() == 1 { throw Refusal("catalog.sqlite is not open") }
            return Obs.found(q)
        }, notes: notes))
        await store.search("cake")
        #expect(store.searchFailure == "catalog.sqlite is not open" && store.search == nil && !store.searching)
        #expect(notes.lines == ["the search for \"cake\" in everything in the catalog could not be read — catalog.sqlite is not open"])
        await store.search("cake")
        #expect(store.searchFailure == nil && store.search?.hits.count == 1 && !store.searching)
        #expect(notes.lines.last == "searched \"cake\" in everything in the catalog: 1 hit")
    }

    @Test(.timeLimit(.minutes(1)))
    func aSearchAtTheCapIsPublishedWholeAndSaidAsCapped() async {
        let notes = Obs.Notes()
        let store = ObservationsStore(scope: .folder("/V"), loader: Obs.loader(search: { _, q in Obs.found(q, hits: 2_000, truncated: true) }, notes: notes))
        let started = ContinuousClock.now
        await store.search("tree")
        #expect(store.search?.hits.count == 2_000 && store.search?.truncated == true)
        #expect(notes.lines == ["searched \"tree\" in the folder /V: 2,000 hits (capped)"])
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test func closingTheWindowStopsBothReadsAndNothingPublishesAfter() async throws {
        let release = FrameIndexJobTests.Flag()
        let notes = Obs.Notes()
        let store = ObservationsStore(scope: .everything, loader: Obs.loader(
            report: { await Obs.hold(until: release); return Obs.report($0) },
            search: { _, q in await Obs.hold(until: release); return Obs.found(q) }, notes: notes))
        let load = Task { await store.load() }
        let search = Task { await store.search("cake") }
        try await FrameIndexJobTests.until("both reads are in flight") { store.loading && store.searching }
        store.cancel()
        #expect(!store.loading && !store.searching, "closed: nothing is in flight as far as the window knows")
        release.set()
        await load.value
        await search.value
        #expect(store.report == nil && store.search == nil && store.failure == nil && store.searchFailure == nil)
        #expect(store.reads == 0 && notes.lines.isEmpty, "a read the window no longer wants is neither shown nor logged: \(notes.lines)")
    }

    @Test func aReadThatGivesUpIsNotShownAsAFailure() async {
        let notes = Obs.Notes()
        let store = ObservationsStore(scope: .everything, loader: Obs.loader(report: { _ in throw CancellationError() },
                                                                             search: { _, _ in throw CancellationError() }, notes: notes))
        await store.load()
        await store.search("cake")
        #expect(store.failure == nil && store.searchFailure == nil && !store.loading && !store.searching)
        #expect(store.report == nil && store.search == nil && notes.lines.isEmpty)
    }

    @Test func aHitThatCannotBeShownSaysWhyAndAGoodOneClearsTheWords() async {
        let known = UUID()
        var asked: [UUID] = []
        let store = ObservationsStore(scope: .everything, loader: Obs.loader(reveal: { id in
            asked.append(id)
            return id == known
        }))
        #expect(store.reveal(Obs.hit(1, recordID: nil, removed: true)) == false)
        #expect(store.revealProblem == "Tape_1.dv is not in this session's catalog (every copy was removed from the catalog) — nothing to show")
        #expect(asked.isEmpty, "a hit with no record is never handed to the Catalog")

        let stranger = UUID()
        #expect(store.reveal(Obs.hit(2, recordID: stranger)) == false)
        #expect(store.revealProblem == "Tape_2.dv is not in this session's catalog — nothing to show")

        #expect(store.reveal(Obs.hit(3, recordID: known)) == true)
        #expect(store.revealProblem == nil && asked == [stranger, known], "the one reveal door is asked with the hit's own record")

        store.reveal(Obs.hit(2, recordID: stranger))
        await store.search("cake")
        #expect(store.revealProblem == nil, "a new search starts with no stale words under the list")
    }
}

// MARK: - The production door

@Suite("Observations — the production door reads this session's catalog.sqlite", .serialized)
@MainActor
struct ObservationsProductionDoorTests {

    @Test func theReportIsThisSessionsCatalogAndTheReadWritesNothing() async throws {
        let scene = try CutoverScene.make("observations_door"); defer { scene.cleanup() }
        try await scene.importCatalog()
        try scene.writeLatch()
        scene.model.records = scene.model.loadCatalogAtLaunch()
        let repository = try #require(scene.model.catalogCutover.committer?.repository)
        let generation = await repository.generation

        let loader = ObservationsLoader.production(model: scene.model)
        #expect(ObservationsLoader.production(model: scene.model).id == loader.id, "one loader per model, never rebuilt per window")
        let store = ObservationsStore(scope: .everything, loader: loader)
        await store.load()
        let report = try #require(store.report, "\(store.failure ?? "no failure")")
        // An independent read of the same catalog: one row per distinct live content.
        let contents = try await repository.read { try $0.frameIndexFiles(.everything) }
        #expect(report.scope == .everything && report.contents == contents.count && report.contents > 0)
        #expect(report.files >= report.contents)

        await store.set(scope: .folder("/no/such/folder/anywhere"))
        #expect(store.report?.files == 0 && store.report?.contents == 0 && store.failure == nil, "an empty scope is a report of nothing, not a failure")

        await store.search("zz-no-observation-says-this")
        #expect(store.search?.hits.isEmpty == true && store.searchFailure == nil)
        #expect(store.reveal(ObservationsSearch.Hit(id: "x", kind: .scene, text: "", at: nil, source: "", digest: "", recordID: UUID(),
                                                    filename: "Gone.dv", path: "/V/Gone.dv", removed: false)) == false,
                "a record this session does not hold cannot be shown")
        #expect(store.revealProblem == "Gone.dv is not in this session's catalog — nothing to show")
        #expect(await repository.generation == generation, "READ ONLY: no commit")
    }

    @Test func aSessionWithNoCatalogOpenRefusesInWords() async throws {
        let sandbox = try ShowAgainSandbox.make("observations_closed"); defer { sandbox.cleanup() }
        let store = ObservationsStore(scope: .everything, loader: ObservationsLoader.production(model: sandbox.model))
        await store.load()
        #expect(store.failure == "catalog.sqlite is not open in this session — there is nothing to read" && store.report == nil)
        await store.search("cake")
        #expect(store.searchFailure == "catalog.sqlite is not open in this session — there is nothing to read" && store.search == nil)
    }
}
