// FrameSearchStoreBehaviourTests.swift — what the Frames mode's window
// depends on from its store beyond FrameSearchTests.swift
// (Observations/FrameSearch/FrameSearchStore.swift).
//
//   LOGIC      words too short ask nothing; a search before the index is read
//              asks nothing; the scope's files are read once per scope; the
//              page is at most 48 hits, at most 2 per video, best first, and
//              the same words give the same page; Index Frames with no MFO
//              center says so; a job is watched until it ends.
//   TRUTH      the timing line counts the frames IN SCOPE; a removed copy
//              reads as removed; a hit whose file is not a record of this
//              session cannot be revealed and says why; the index shown after
//              a job's saves equals the index on disk.
//   ISOLATION  an index damaged on disk AFTER it was shown reads "Index not
//              built" with the reason at the next open, and a search has no
//              hits (never the stale ones); an unreadable index is logged;
//              a model that cannot warm up is not the window's problem; a
//              window closed mid warm-up cancels it.
//   SCALE      100,000 frames from 20,000 videos, half in scope: one search
//              inside 2 s, 48 hits, none out of scope.
// Synthetic pictures and names only; every index folder is a temp folder.

import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func twoAndThree() -> [CatalogRow.FrameIndexFile] {
    [ObsFixture.row(2, path: "/V/a/two.mov"), ObsFixture.row(3, path: "/V/a/three.mov")]
}

@Suite("Frames mode — the store, hardening") @MainActor
struct FrameSearchStoreBehaviourTests {

    typealias Notes = FrameIndexJobTests.Notes

    // MARK: Logic

    @Test func wordsTooShortAskNothingAndTheWordsAreTrimmed() async {
        let embeds = ObsCounter()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2, 3])) }, files: { _ in twoAndThree() },
            embedText: { embeds.bump(); return try await ObsStubEmbedder().embed(text: $0) }))
        await store.loadIndex()
        await store.search(" a ")
        #expect(embeds.value == 0 && store.query == nil && store.hits.isEmpty, "one character is not a question; the model is not asked")
        await store.search("  axis 3\n")
        #expect(store.query == "axis 3" && store.hits.first?.filename == "three.mov" && embeds.value == 1)
        await store.search("")
        #expect(store.query == nil && store.hits.isEmpty && store.timing == nil && !store.searching, "clearing the field clears the page")
    }

    @Test func aSearchBeforeTheIndexIsReadAsksNothingAndFindsOnceItIs() async {
        let embeds = ObsCounter(), reads = ObsCounter()
        let notes = Notes()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2, 3])) }, files: { _ in reads.bump(); return twoAndThree() },
            embedText: { embeds.bump(); return try await ObsStubEmbedder().embed(text: $0) }, notes: notes))
        #expect(store.indexState == .loading)
        await store.search("axis 3")
        #expect(store.hits.isEmpty && store.failure == nil && store.timing == nil && !store.searching)
        #expect(embeds.value == 0 && reads.value == 0 && notes.lines.isEmpty, "no index: neither the model nor the catalog is asked, nothing is logged")
        await store.loadIndex()
        await store.search("axis 3")
        #expect(store.hits.first?.filename == "three.mov" && embeds.value == 1 && reads.value == 1)
    }

    @Test func theScopesFilesAreReadOncePerScope() async {
        let asked = ObsAsked()
        let store = FrameSearchStore(scope: .folder("/V/a"), loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2, 3])) }, files: { scope in asked.add(scope.words); return twoAndThree() }))
        await store.loadIndex()
        await store.search("axis 2")
        await store.search("axis 3")
        #expect(asked.all == ["the folder /V/a"], "a second question of the same scope does not read the catalog again")
        await store.set(scope: .folder("/V/a"))
        #expect(asked.all.count == 1, "the same scope again changes nothing")
        await store.set(scope: .everything)
        #expect(asked.all == ["the folder /V/a", "everything in the catalog"] && store.query == "axis 3", "a new scope reads its own files and asks the same words")
    }

    @Test func thePageIsFortyEightHitsTwoPerVideoBestFirstAndRepeatable() async {
        let ns = (1...60).map { $0 * 8 }                         // sixty videos, all along axis 0, three frames each
        let rows = ns.map { ObsFixture.row($0, path: "/V/\($0).mov") }
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index(ns, framesEach: 3)) }, files: { _ in rows }))
        await store.loadIndex()
        #expect(store.indexState == .ready(frames: 180, contents: 60))
        await store.search("axis 0")
        let page = store.hits
        #expect(page.count == FrameSearchStore.pageSize && page.count == 48)
        #expect(Dictionary(grouping: page, by: \.digest).values.allSatisfy { $0.count <= FrameSearchStore.perContent }, "one long tape never fills the page")
        #expect(zip(page, page.dropFirst()).allSatisfy { $0.score >= $1.score }, "best first")
        #expect(Set(page.map(\.id)).count == page.count, "a frame appears once")
        await store.search("axis 0")
        #expect(store.hits == page, "the same words over the same index give the same page")
    }

    // MARK: Truth

    @Test func theTimingLineCountsOnlyTheFramesInScope() async {
        let store = FrameSearchStore(scope: .folder("/V/a"), loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2, 3, 5], framesEach: 2)) }, files: { _ in twoAndThree() }))
        await store.loadIndex()
        #expect(store.indexState == .ready(frames: 6, contents: 3), "the standing line is the whole index")
        await store.search("axis 5")
        #expect(store.timing?.hasSuffix("over 4 frames in scope") == true, "\(store.timing ?? "nil")")
        #expect(store.timing?.hasPrefix("query ") == true && store.timing?.contains("text tower") == true)
        #expect(store.hits.count == 4 && store.hits.allSatisfy { $0.digest != ObsFixture.digest(5) }, "content 5 is indexed but not in /V/a")
        #expect(FrameSearchStore.seconds(.milliseconds(1_234)) == "1.23 s" && FrameSearchStore.seconds(.zero) == "0.00 s")
    }

    @Test func aHitCarriesItsRowsFactsAndOneThatIsNotARecordHereSaysWhy() async {
        let rows = [ObsFixture.row(2, path: "/V/a/two.mov", removed: true), ObsFixture.row(3, path: "/V/a/three.mov", fileID: "not-a-uuid"),
                    ObsFixture.row(4, path: "/V/a/four.mov")]
        var asked: [UUID] = []
        let refuse = FrameIndexJobTests.Flag()      // the Catalog says no while this is set
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2, 3, 4])) }, files: { _ in rows },
            reveal: { id in asked.append(id); return !refuse.isSet }))
        await store.loadIndex()

        await store.search("axis 2")
        let two = store.hits[0]
        #expect(two.filename == "two.mov" && two.removed, "a removed copy reads as removed")
        #expect(two.id == FrameIndex.cacheKey(model: "test/stub-siglip", digest: ObsFixture.digest(2), seconds: 2))
        #expect(two.sourceWords == "SigLIP 2 (test/stub-siglip), similarity 1.00")
        #expect(store.reveal(two) && asked.map(\.uuidString) == [rows[0].fileID], "the reveal door is asked for the row's own file")

        await store.search("axis 3")
        let three = store.hits[0]
        #expect(three.filename == "three.mov" && three.recordID == nil)
        #expect(store.reveal(three) == false && asked.count == 1, "no record: the Catalog is not asked")
        #expect(store.revealProblem == "three.mov is not in this session's catalog — nothing to show")

        await store.search("axis 4")
        #expect(store.revealProblem == nil, "a new search starts with no stale words")
        refuse.set()
        #expect(store.reveal(store.hits[0]) == false)
        #expect(store.revealProblem == "four.mov is not in this session's catalog — nothing to show")
        refuse.set(false)
        #expect(store.reveal(store.hits[0]) && store.revealProblem == nil)
    }

    @Test func aSimilarityBelowZeroIsShownAsItIs() {
        let hit = FrameHit(model: "m", digest: "d", seconds: 1.5, score: -0.034, recordID: nil, filename: "f", path: "/p", removed: false)
        #expect(hit.sourceWords == "SigLIP 2 (m), similarity -0.03", "a cosine, not a probability: never clamped or rounded up")
        #expect(hit.id == "m|d|1500")
    }

    // MARK: The job, from the window

    @Test func indexFramesWithNoOperationsCenterSaysSo() async {
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader())
        store.buildIndex()
        #expect(store.job == nil && store.jobLine == "The Media File Operations center is not available in this window.")
    }

    @Test func aJobIsStartedOverTheWindowsScopeWatchedUntilItEndsAndItsSavesAreShown() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [ObsFixture.row(1, path: "/V/a.mov"), ObsFixture.row(2, path: "/V/b.mov"), ObsFixture.row(3, path: "/V/c.mov")]
        var started: [ObservationsScope] = []
        let store = FrameSearchStore(scope: .folder("/V"), loader: ObsFixture.frameLoader(
            index: { ObsFixture.onDisk(root) }, files: { _ in rows },
            startIndex: { scope, onSaved in
                started.append(scope)
                let job = ObsFixture.job(rows, root: root)
                job.checkpointFiles = 1
                job.onSaved = onSaved
                job.start()
                return job
            }))
        await store.loadIndex()
        guard case .notBuilt = store.indexState else { Issue.record("an empty folder must read as not built: \(store.indexState)"); return }
        store.buildIndex()
        let job = try #require(store.job, "the window holds the job it started")
        #expect(started == [.folder("/V")] && store.jobLine == job.subtitle)
        await job.task?.value
        #expect(job.outcome == .finished && job.saves == 3)
        try await FrameIndexJobTests.until("the finished job leaves the window") { store.job == nil && store.jobLine == nil }
        try await FrameIndexJobTests.until("the last save is shown") { store.indexState == .ready(frames: 9, contents: 3) }
        #expect(ObsFixture.onDisk(root).index?.count == 9, "truth: the standing line equals the index on disk")
        await store.search("axis 0")
        #expect(store.hits.count == 6 && (store.hits.first?.score ?? 0) > 0.99, "and the search runs over it")
    }

    // MARK: Isolation

    @Test func anIndexDamagedOnDiskAfterItWasShownIsNotBuiltAtTheNextOpenAndNeverStaleHits() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        try FrameIndexStore.save(ObsFixture.index([2, 3]), root: root)
        let notes = Notes()
        func window() -> FrameSearchStore {
            FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(index: { ObsFixture.onDisk(root) }, files: { _ in twoAndThree() }, notes: notes))
        }
        let first = window()
        await first.loadIndex()
        await first.search("axis 3")
        #expect(first.indexState == .ready(frames: 2, contents: 2) && first.hits.first?.filename == "three.mov")

        // The matrix loses its tail (a torn copy, a full disk).
        let matrix = FrameIndexStore.directory(root: root, model: "test/stub-siglip").appendingPathComponent("vectors-a.f16")
        try Data(try Data(contentsOf: matrix).prefix(10)).write(to: matrix)
        let second = window()
        await second.loadIndex()
        guard case .notBuilt(let words) = second.indexState else { Issue.record("a torn matrix must read as not built: \(second.indexState)"); return }
        #expect(words == "Index not built — the index on disk cannot be used (the matrix is 10 bytes; 2 frames × 8 need 32). Index Frames builds a new one.")
        #expect(notes.lines.filter { $0.hasPrefix("the frame index cannot be used") } == ["the frame index cannot be used: the matrix is 10 bytes; 2 frames × 8 need 32"],
                "said once, through the one sink: \(notes.lines)")
        await second.search("axis 3")
        #expect(second.hits.isEmpty && second.failure == nil, "no index, no hits — never a partial answer")

        // The sidecar is not JSON at all.
        try Data("{ not json".utf8).write(to: FrameIndexStore.directory(root: root, model: "test/stub-siglip").appendingPathComponent("index.json"))
        let third = window()
        await third.loadIndex()
        guard case .notBuilt(let why) = third.indexState else { Issue.record("a torn sidecar must read as not built: \(third.indexState)"); return }
        #expect(why.hasPrefix("Index not built — the index on disk cannot be used (the index's sidecar does not parse"))

        // Nothing there at all.
        let empty = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(index: { ObsFixture.onDisk(root.appendingPathComponent("nowhere")) }))
        await empty.loadIndex()
        #expect(empty.indexState == .notBuilt("Index not built — no frames have been indexed with test/stub-siglip yet."))
    }

    @Test func aModelThatCannotWarmUpIsNotTheWindowsProblemAndClosingCancelsAWarmUp() async throws {
        let warmed = ObsCounter()
        let failing = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2])) }, prewarm: { warmed.bump(); throw SigLIPError.weightsMissing("offline") }))
        await failing.loadIndex()
        try await FrameIndexJobTests.until("the first look warms the model") { warmed.value == 1 }
        #expect(failing.indexState == .ready(frames: 1, contents: 1) && failing.failure == nil, "the index is shown whether or not the model warmed")

        let inFlight = FrameIndexJobTests.Flag(), cut = FrameIndexJobTests.Flag()
        let closing = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(index: { .notBuilt }, prewarm: {
            inFlight.set()
            do { try await Task.sleep(for: .seconds(60)) } catch { cut.set(); throw error }
        }))
        await closing.loadIndex()
        try await FrameIndexJobTests.until("the warm-up is in flight") { inFlight.isSet }
        closing.cancel()
        try await FrameIndexJobTests.until("the warm-up is cancelled with the window") { cut.isSet }
    }

    // MARK: Scale

    @Test(.timeLimit(.minutes(2)))
    func oneHundredThousandFramesHalfInScopeAreSearchedInsideTheBudget() async {
        let videos = 20_000, each = 5
        var builder = FrameIndexBuilder(model: "test/stub-siglip", dims: 8)
        for n in 0..<videos {
            let frames = (0..<each).map { i -> (seconds: Double, vector: [Float]) in
                var v = [Float](repeating: 0.02 * Float(i + 1), count: 8)
                v[n % 8] = 1
                return (Double(i), v)
            }
            builder.add(digest: ObsFixture.digest(n), frames: frames)
        }
        let index = builder.snapshot()
        let rows = stride(from: 0, to: videos, by: 2).map { ObsFixture.row($0, path: "/V/\($0).mov") }   // the even half is in scope
        let inScope = Set(rows.map(\.digest))
        let store = FrameSearchStore(scope: .folder("/V"), loader: ObsFixture.frameLoader(index: { .ready(index) }, files: { _ in rows }))
        await store.loadIndex()
        #expect(store.indexState == .ready(frames: 100_000, contents: 20_000))
        let started = ContinuousClock.now
        await store.search("axis 4")
        let took = ContinuousClock.now - started
        #expect(store.hits.count == 48 && store.hits.allSatisfy { inScope.contains($0.digest) }, "no frame from outside the scope")
        #expect(store.hits.allSatisfy { $0.score > 0.9 }, "the page is the frames along the asked axis")
        #expect(store.timing?.hasSuffix("over 50,000 frames in scope") == true, "\(store.timing ?? "nil")")
        #expect(took < .seconds(2), "one search over 100,000 frames took \(took)")
    }
}
