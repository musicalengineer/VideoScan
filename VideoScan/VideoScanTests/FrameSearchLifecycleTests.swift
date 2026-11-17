// FrameSearchLifecycleTests.swift — what the Frames window and the Index Frames
// job owe each other over their lifetimes: a newer index, another index's job,
// a closed window, the end of a run, a cut. These are the behaviour findings of
// Codex review #302 (2026-11-17), each test seen RED on the code the review
// read (the table is in the fix's commit message).
//
//   1  NEWER INDEX, OLDER HITS. A newer index dropped the scope rows but left
//      hits computed against the older index on screen, and a search in flight
//      against the older index published under the newer standing line.
//   2  ANOTHER INDEX'S JOB. A window joined, or was handed, whatever Index
//      Frames job ran in the center — also one writing a different index
//      folder or made with a different model.
//   3  A CLOSED WINDOW PUBLISHED AGAIN. A save delivered after cancel() started
//      a fresh index look in a store something still held.
//   4  LISTENERS OUTLIVED THE RUN. A refusal (catalog read, refuseToStart)
//      ended the job without dropping its listeners; closing a window removed
//      nothing.
//   5  A CUT DURING THE CATALOG READ ENDED "FAILED / refused".
//   6  A LATE REFUSAL LOST ITS REASON in the line beside the button.
// (7, the words of a Foundation error with an underlying reason, is in
// FrameSearchRegressionTests.everyFamilyOfErrorIsSaidInTheWordsItCarries.)

import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private let two = ObsFixture.row(2, path: "/V/two.mov"), three = ObsFixture.row(3, path: "/V/three.mov")

/// The same stub model under another name: a different model identity.
private struct OtherModel: FrameEmbedding {
    let modelID = "test/other-siglip"
    let dims = 8
    func embed(images: [CGImage]) async throws -> [[Float]] { try await ObsStubEmbedder().embed(images: images) }
    func embed(text: String) async throws -> [Float] { try await ObsStubEmbedder().embed(text: text) }
}

@Suite("Frames mode — window and job lifetimes") @MainActor
struct FrameSearchLifecycleTests {

    typealias Flag = FrameIndexJobTests.Flag

    // MARK: 1 — a newer index and older hits

    @Test func hitsAlreadyShownAreRecomputedWhenANewerIndexIsShown() async throws {
        let seams = FrameSearchStoreTests.IndexSeams()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2])) }, files: { _ in [two, three] },
            startIndex: { _, onSaved in seams.onSaved = onSaved; return nil }))
        await store.loadIndex()
        await store.search("axis 2")
        #expect(store.hits.map(\.filename) == ["two.mov"])
        store.buildIndex()
        let handOver = try #require(seams.onSaved)
        handOver(ObsFixture.index([3], framesEach: 2))      // a newer index that no longer holds two.mov at all
        try await FrameIndexJobTests.until("the newer index is shown") { store.indexState == .ready(frames: 2, contents: 1) }
        try await FrameIndexJobTests.until("the page is the newer index's answer to the same words") {
            !store.searching && !store.hits.isEmpty && store.hits.allSatisfy { $0.filename == "three.mov" }
        }
        #expect(store.query == "axis 2", "the words in the field are asked again; nothing else changes")
    }

    @Test func aSearchInFlightAgainstAnOlderIndexNeverPublishesUnderANewerOne() async throws {
        let seams = FrameSearchStoreTests.IndexSeams()
        let atTheCatalog = Flag(), release = Flag()
        let reads = ObsCounter()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2])) },
            files: { _ in
                if reads.bump() == 1 {
                    atTheCatalog.set()
                    while !release.isSet { try? await Task.sleep(for: .milliseconds(2)) }   // keeps holding after it is cancelled: it finishes LATE
                }
                return [two, three]
            },
            startIndex: { _, onSaved in seams.onSaved = onSaved; return nil }))
        await store.loadIndex()
        let early = Task { await store.search("axis 2") }
        try await FrameIndexJobTests.until("the search is reading the catalog") { atTheCatalog.isSet }
        store.buildIndex()
        let handOver = try #require(seams.onSaved)
        handOver(ObsFixture.index([3], framesEach: 2))
        try await FrameIndexJobTests.until("the newer index is shown") { store.indexState == .ready(frames: 2, contents: 1) }
        release.set()
        await early.value
        #expect(!store.hits.contains { $0.filename == "two.mov" }, "two.mov is not in the index on screen: \(store.hits.map(\.filename))")
        try await FrameIndexJobTests.until("the same words are answered from the newer index") {
            !store.searching && !store.hits.isEmpty && store.hits.allSatisfy { $0.filename == "three.mov" }
        }
    }

    // MARK: 2 — a job for another index

    @Test func aWindowNeitherJoinsNorIsHandedAJobWritingAnotherIndex() async throws {
        let sandbox = try ShowAgainSandbox.make("frames_other_root")
        let rootA = try ObsFixture.tempDir("codex-a"), rootB = try ObsFixture.tempDir("codex-b")
        defer { sandbox.cleanup(); try? FileManager.default.removeItem(at: rootA); try? FileManager.default.removeItem(at: rootB) }
        let center = MediaFileOperationsCenter()
        let release = Flag()
        let running = center.startFrameIndex(scope: .everything, loadFiles: { _ in
            while !release.isSet { try await Task.sleep(for: .milliseconds(5)) }
            return []
        }, embedder: ObsStubEmbedder(), root: rootA, note: { _ in }, onSaved: nil)

        let same = FrameSearchStore(scope: .everything, loader: FrameSearchLoader.make(model: sandbox.model, embedder: ObsStubEmbedder(), root: rootA, center: { center }))
        await same.loadIndex()
        #expect(same.job === running, "the same folder and the same model: that is this window's job")

        for (what, loader) in [("another folder", FrameSearchLoader.make(model: sandbox.model, embedder: ObsStubEmbedder(), root: rootB, center: { center })),
                               ("another model", FrameSearchLoader.make(model: sandbox.model, embedder: OtherModel(), root: rootA, center: { center }))] {
            let other = FrameSearchStore(scope: .everything, loader: loader)
            await other.loadIndex()
            #expect(other.job == nil && other.jobLine == nil, "\(what): the running job writes a different index — not this window's to show")
            other.buildIndex()
            #expect(other.job == nil, "\(what): Index Frames is never handed the other index's job")
            #expect(other.jobLine?.contains("already running") == true, "\(what): refused in plain words: \(other.jobLine ?? "nil")")
            #expect(center.jobs.count == 1, "\(what): and nothing was started beside it")
        }
        release.set()
        await running.task?.value
    }

    // MARK: 3 — a closed window

    @Test func aClosedWindowNeverPublishesAgainEvenWhileSomethingStillHoldsIt() async throws {
        let seams = FrameSearchStoreTests.IndexSeams()
        let atTheCatalog = Flag(), release = Flag()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2])) },
            files: { _ in
                atTheCatalog.set()
                while !release.isSet { try? await Task.sleep(for: .milliseconds(2)) }
                return [two, three]
            },
            startIndex: { _, onSaved in seams.onSaved = onSaved; return nil }))
        await store.loadIndex()
        store.buildIndex()
        let handOver = try #require(seams.onSaved)
        let held = Task { await store.search("axis 2") }           // this search keeps the store alive after it is closed
        try await FrameIndexJobTests.until("the search is reading the catalog") { atTheCatalog.isSet }

        store.cancel()                                             // the window closes
        #expect(store.indexState == .loading && store.hits.isEmpty)
        handOver(ObsFixture.index([2, 3]))                         // … and the job saves afterwards
        for _ in 0..<2_000 { await Task.yield() }                  // let whatever the save started run
        #expect(store.indexState == .loading, "a closed window shows nothing new: \(store.indexState)")
        release.set()
        await held.value
        #expect(store.indexState == .loading && store.hits.isEmpty && store.query == nil && !store.searching, "\(store.indexState)")
        await store.search("axis 2")
        await store.loadIndex()
        #expect(store.indexState == .loading && store.hits.isEmpty, "closed is for good: nothing asked of it afterwards is published either")
    }

    /// Codex #304 F1: the index arrives, the words already in the field are being answered from it, and the
    /// window closes during that answer. No model warm-up may start for a window that is gone.
    @Test func aWindowClosedWhileAnArrivingIndexAnswersItsWordsStartsNoWarmUp() async throws {
        let warmed = ObsCounter()
        let atTheModel = Flag(), release = Flag()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2])) }, files: { _ in [two] },
            embedText: { text in
                atTheModel.set()
                while !release.isSet { try? await Task.sleep(for: .milliseconds(2)) }
                return try await ObsStubEmbedder().embed(text: text)
            },
            prewarm: { warmed.bump() }))
        await store.search("axis 2")                    // typed before the index is read: nothing is asked yet
        let opening = Task { await store.loadIndex() }  // the index arrives and the words are asked of it
        try await FrameIndexJobTests.until("the automatic search is at the model") { atTheModel.isSet }
        store.cancel()
        release.set()
        await opening.value
        for _ in 0..<2_000 { await Task.yield() }       // room for a warm-up to start, if one would
        #expect(warmed.value == 0, "a closed window warms no model (0.75 GB for nobody): \(warmed.value)")
        #expect(store.hits.isEmpty && store.indexState == .loading)
    }

    /// Codex #304 F3: Show in Catalog on a closed window says nothing and asks nothing of the Catalog.
    @Test func aClosedWindowRevealsNothingAndSaysNothing() async {
        var asked = 0
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(reveal: { _ in asked += 1; return true }))
        let orphan = FrameHit(model: "m", digest: "d", seconds: 1, score: 0.2, recordID: nil, filename: "Gone.dv", path: "/V/Gone.dv", removed: false)
        let known = FrameHit(model: "m", digest: "e", seconds: 1, score: 0.2, recordID: UUID(), filename: "Here.dv", path: "/V/Here.dv", removed: false)
        store.cancel()
        #expect(store.reveal(orphan) == false && store.revealProblem == nil, "nothing is published on a closed window: \(store.revealProblem ?? "nil")")
        #expect(store.reveal(known) == false && asked == 0, "and the Catalog is not asked to move for a window that is gone")
    }

    // MARK: 4 — listeners end with the run

    /// Lives exactly as long as the listener closure that captured it.
    private final class Probe {}

    @Test(arguments: ["the catalog read refuses", "refuseToStart", "the run finishes", "Stop"])
    func everyEndingDropsTheRunsListeners(_ ending: String) async throws {
        let root = try ObsFixture.tempDir("codex-listeners")
        defer { try? FileManager.default.removeItem(at: root) }
        let release = Flag()
        let refuses = ending == "the catalog read refuses"
        let job = FrameIndexJob(scope: .everything, loadFiles: { _ in
            while !release.isSet { try? await Task.sleep(for: .milliseconds(2)) }
            if refuses { throw Refusal("catalog.sqlite is not open in this session — there is nothing to read") }
            return []
        }, embedder: ObsStubEmbedder())
        job.root = root
        job.note = { _ in }
        var probe: Probe? = Probe()
        weak let alive = probe
        if ending != "refuseToStart" { job.start() }
        _ = job.alsoTell { [probe] _ in _ = probe }
        probe = nil
        #expect(alive != nil, "the job holds the listener while it runs")
        switch ending {
        case "refuseToStart": job.refuseToStart(reason: "this Mac is a viewer")
        case "Stop": job.cancel()
        default: break
        }
        release.set()
        await job.task?.value
        #expect(!job.state.isActive, "\(ending): \(job.state)")
        #expect(alive == nil, "\(ending): the ended job (still held here) keeps no listener alive")
    }

    // MARK: 5 — a cut during the catalog read

    @Test func aRunCutWhileItReadsTheCatalogIsStoppedNotRefused() async throws {
        let notes = FrameIndexJobTests.Notes()
        let job = FrameIndexJob(scope: .everything, loadFiles: { _ in try Task.checkCancellation(); return [] }, embedder: ObsStubEmbedder())
        job.note = { notes.lines.append($0) }
        job.start()
        job.stopForQuit()
        await job.task?.value
        #expect(job.outcome == .stopped, "\(String(describing: job.outcome))")
        #expect(job.state == .cancelled && !job.wasRefused, "\(job.state)")
        #expect(!notes.lines.contains { $0.contains("refused") }, "\(notes.lines)")

        // Stop (not Quit) pressed while the read is under way, and the read then fails: the user's Stop is what ended it.
        let release = Flag()
        let stopped = FrameIndexJob(scope: .everything, loadFiles: { _ in
            while !release.isSet { try? await Task.sleep(for: .milliseconds(2)) }
            throw Refusal("the catalog closed")
        }, embedder: ObsStubEmbedder())
        stopped.note = { _ in }
        stopped.start()
        stopped.cancel()
        release.set()
        await stopped.task?.value
        #expect(stopped.outcome == .stopped && stopped.state == .cancelled && !stopped.wasRefused, "a job whose Stop was asked never ends FAILED: \(stopped.state)")
    }
}
