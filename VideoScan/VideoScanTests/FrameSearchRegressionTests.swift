// FrameSearchRegressionTests.swift — bugs found while hardening the Frames
// mode (2026-11-16), each test seen RED on the unfixed code (the table is in
// the fix's commit message).
//
//   1. STALE SCOPE FILES. The store kept the scope's files from its first
//      search for the life of the scope. A video catalogued after that first
//      search and then indexed by Index Frames was in the index on screen
//      ("N frames from M videos") and could never be a hit until the window
//      was closed and opened again.
//   2. A REFUSED JOB WATCHED FOREVER. Index Frames on a viewer Mac returns a
//      job that is already over (refused). The store watched it for a change
//      that never comes: the button stayed "Indexing…" (disabled) and the
//      line beside it read "Reading the catalog…" for as long as the window
//      was open; the reason was never said.
//   3. A REFUSAL SHOWN AS FOUNDATION'S BOILERPLATE. "catalog.sqlite is not
//      open in this session — there is nothing to read" (a `Refusal`, the
//      production door's own error) reached the Frames window and the job's
//      FAILED line as "The operation couldn’t be completed.
//      (VideoScanCore.Refusal error 1.)" — `localizedDescription` of an error
//      that carries its words in `description`.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private let notOpen = "catalog.sqlite is not open in this session — there is nothing to read"

@Suite("Frames mode — regressions (2026-11-16)") @MainActor
struct FrameSearchRegressionTests {

    // MARK: 1

    @Test func aVideoCataloguedAndIndexedAfterTheFirstSearchIsFound() async throws {
        let seams = FrameSearchStoreTests.IndexSeams()
        let catalogued = FrameIndexJobTests.Flag()
        let reads = ObsCounter()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2])) },
            files: { _ in
                reads.bump()
                let two = ObsFixture.row(2, path: "/V/two.mov")
                return catalogued.isSet ? [two, ObsFixture.row(3, path: "/V/three.mov")] : [two]
            },
            startIndex: { _, onSaved in seams.onSaved = onSaved; return nil }))
        await store.loadIndex()
        await store.search("axis 3")
        #expect(!store.hits.contains { $0.filename == "three.mov" }, "three.mov is not in the catalog yet")

        catalogued.set()                                   // a scan adds three.mov; Index Frames then indexes it
        store.buildIndex()
        let onSaved = try #require(seams.onSaved)
        onSaved(ObsFixture.index([2, 3]))
        try await FrameIndexJobTests.until("the saved index is shown") { store.indexState == .ready(frames: 2, contents: 2) }
        await store.search("axis 3")
        #expect(store.hits.first?.filename == "three.mov", "a frame the standing line counts must be findable: \(store.hits.map(\.filename))")
        #expect(reads.value == 2, "the scope's files are read again once the index changed — and only then")
        await store.search("axis 2")
        #expect(reads.value == 2, "the same index, the same scope: no further read")
    }

    /// The same bug by another road: rows read BEFORE a newer index was shown came back after it and were kept.
    @Test func rowsReadBeforeANewerIndexWasShownAreNotKept() async throws {
        let seams = FrameSearchStoreTests.IndexSeams()
        let catalogued = FrameIndexJobTests.Flag(), atTheCatalog = FrameIndexJobTests.Flag(), release = FrameIndexJobTests.Flag()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2])) },
            files: { _ in
                let two = ObsFixture.row(2, path: "/V/two.mov")
                guard catalogued.isSet else {            // the first read: taken before the scan, answered after the save
                    atTheCatalog.set()
                    while !release.isSet { try await Task.sleep(for: .milliseconds(2)) }
                    return [two]
                }
                return [two, ObsFixture.row(3, path: "/V/three.mov")]
            },
            startIndex: { _, onSaved in seams.onSaved = onSaved; return nil }))
        await store.loadIndex()
        let early = Task { await store.search("axis 3") }
        try await FrameIndexJobTests.until("the first search is reading the catalog") { atTheCatalog.isSet }
        catalogued.set()
        store.buildIndex()
        let handOver = try #require(seams.onSaved)
        handOver(ObsFixture.index([2, 3]))
        try await FrameIndexJobTests.until("the saved index is shown") { store.indexState == .ready(frames: 2, contents: 2) }
        release.set()
        await early.value
        await store.search("axis 3")
        #expect(store.hits.first?.filename == "three.mov", "rows older than the index on screen must not be what the next search uses: \(store.hits.map(\.filename))")
    }

    // MARK: 2

    @Test func aJobThatWasRefusedIsNotWatchedAndItsReasonIsSaid() async {
        let reason = "Index Frames runs on the Mac that holds the catalog — this one is a viewer."
        let refused = FrameIndexJob(scope: .everything, loadFiles: { _ in [] }, embedder: ObsStubEmbedder())
        refused.refuseToStart(reason: reason)
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(startIndex: { _, _ in refused.watched(by: nil) }))
        store.buildIndex()
        #expect(store.job == nil, "a job that is already over is nothing to watch: the button must not read 'Indexing…' for ever")
        #expect(store.jobLine == reason, "and the window says why: \(store.jobLine ?? "nil")")
    }

    // MARK: 3

    @Test func aRefusalReachesTheWindowInItsOwnWords() async {
        let notes = FrameIndexJobTests.Notes()
        let store = FrameSearchStore(scope: .everything, loader: ObsFixture.frameLoader(
            index: { .ready(ObsFixture.index([2])) }, files: { _ in throw Refusal(notOpen) }, notes: notes))
        await store.loadIndex()
        await store.search("axis 2")
        #expect(store.failure == notOpen, "shown: \(store.failure ?? "nil")")
        #expect(notes.lines == ["the search for \"axis 2\" in everything in the catalog could not run — \(notOpen)"], "\(notes.lines)")
    }

    @Test func aRefusalReachesTheJobsFailedLineInItsOwnWords() async throws {
        let root = try ObsFixture.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = FrameIndexJobTests.Notes()
        let job = FrameIndexJob(scope: .everything, loadFiles: { _ in throw Refusal(notOpen) }, embedder: ObsStubEmbedder())
        job.root = root
        job.note = { notes.lines.append($0) }
        job.start()
        await job.task?.value
        #expect(job.state == .failed(message: "Refused — the catalog could not be read: \(notOpen)"), "\(job.state)")
        #expect(notes.lines == ["refused — the catalog could not be read (\(notOpen)). Nothing was read or written."], "\(notes.lines)")
    }

    @Test func everyFamilyOfErrorIsSaidInTheWordsItCarries() {
        struct Said: LocalizedError { var errorDescription: String? { "the drive spun down" } }
        enum Bare: Error { case notOpen }
        #expect(FailureWords.of(Said()) == "the drive spun down")
        #expect(FailureWords.of(Refusal(notOpen)) == notOpen)
        #expect(FailureWords.of(Bare.notOpen) == "notOpen", "a bare Swift error names its case, not Foundation's boilerplate")
        #expect(FailureWords.of(CatalogRepositoryError.notOpen) == "notOpen")
        let cocoa = CocoaError(.fileReadCorruptFile)
        #expect(FailureWords.of(cocoa) == cocoa.localizedDescription && !FailureWords.of(cocoa).contains("CocoaError("), "a Foundation error keeps Foundation's sentence")
        let ns = NSError(domain: "AVFoundationErrorDomain", code: -11_800, userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed"])
        #expect(FailureWords.of(ns) == "The operation could not be completed")
        #expect(FailureWords.of(SigLIPError.weightsMissing("offline")) == "SigLIP 2 weights are not on this Mac (offline)")
        #expect(!FailureWords.of(Refusal(notOpen)).contains("couldn’t be completed"))

        // Codex #302 finding 7: a Foundation error whose sentence is generic keeps its reason and its underlying error's words.
        let codec = NSError(domain: "AVFoundationErrorDomain", code: -11_833, userInfo: [NSLocalizedDescriptionKey: "Cannot Decode"])
        let wrapped = NSError(domain: "AVFoundationErrorDomain", code: -11_800,
                              userInfo: [NSLocalizedDescriptionKey: "The operation could not be completed",
                                         NSLocalizedFailureReasonErrorKey: "An unknown error occurred (-12909)",
                                         NSUnderlyingErrorKey: codec, NSFilePathErrorKey: "/Volumes/Tapes/secret/path.mov"])
        #expect(FailureWords.of(wrapped) == "The operation could not be completed — An unknown error occurred (-12909) (Cannot Decode)")
        #expect(!FailureWords.of(wrapped).contains("/Volumes") && !FailureWords.of(wrapped).contains("Error Domain"), "no userInfo dump, no path that was not in the sentence")
        let reasonOnly = NSError(domain: "X", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not open", NSLocalizedFailureReasonErrorKey: "the codec is not supported"])
        #expect(FailureWords.of(reasonOnly) == "Could not open — the codec is not supported")
        let underlyingRefusal = NSError(domain: "X", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not read", NSUnderlyingErrorKey: Refusal("the drive spun down")])
        #expect(FailureWords.of(underlyingRefusal) == "Could not read (the drive spun down)", "the underlying error in ITS own words, one level")
        let echo = NSError(domain: "X", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not read: disk full", NSLocalizedFailureReasonErrorKey: "disk full"])
        #expect(FailureWords.of(echo) == "Could not read: disk full", "a reason the sentence already says is not said twice")
        struct Reasoned: LocalizedError {
            var errorDescription: String? { "the index could not be saved" }
            var failureReason: String? { "the volume is read-only" }
        }
        #expect(FailureWords.of(Reasoned()) == "the index could not be saved — the volume is read-only")
    }

    @Test func aDecoderOrModelRefusalIsRecordedInItsOwnWords() async {
        let decode = await FrameIndexEngine.outcome(path: "/V/a.mov", durationSeconds: 10, framesPerFile: 2,
                                                    extract: { _, _ in throw Refusal("ffmpeg is not installed") },
                                                    embedder: ObsStubEmbedder(), whereabouts: { _ in nil })
        guard case .unreadable(let why) = decode else { Issue.record("\(decode)"); return }
        #expect(why == "ffmpeg is not installed")
    }
}
