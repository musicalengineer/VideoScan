// FrameSearchTests.swift — the Observations window's Frames mode
// (Observations/FrameSearch/; docs/design/file_dossier_view.md §II.7).
// Streamlined (Rick 11/06: an experiment), the dimensions that apply — the
// pure index logic (top-k, cache key, scope, the on-disk truth and
// isolation) is in Core's FrameIndexTests; here:
//   PARITY, SMOKE  the real model: SigLIPEmbedderTests.swift (its own file since
//              2026-11-10, so the gauntlet can list it as not runnable in
//              its sandboxed home — it needs the weights in ~/.cache).
//   TRUTH      a store hit names the file and time of the index row whose
//              vector produced it; a content outside the scope is never shown.
//   ISOLATION  no index / an unreadable index → "Index not built" and no
//              hits, never a crash or stale rows.
//   JOB        the MFO job indexes the files with a picture, skips a drive
//              that is not connected (not a try), records an undecodable
//              file, and a second run resumes with nothing to do.
//   SENSOR     no `extension VideoScanModel`; nothing in FrameSearch/ writes
//              the catalog; the window still observes stores only.
// Synthetic pictures and names only.

import AppKit
import CoreGraphics
import Foundation
import os
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures

/// Shared with SigLIPEmbedderTests.swift (the real-model suite lives there).
enum FrameSearchTestCards {
    /// A solid sRGB card.
    static func solid(_ r: UInt8, _ g: UInt8, _ b: UInt8, size: Int = 224) -> CGImage {
        pixels(size: size) { _, _ in (r, g, b) }
    }

    /// The reference fixture's gradient: green = x, blue = y.
    static func gradient(size: Int = 224) -> CGImage {
        pixels(size: size) { x, y in (0, UInt8(x), UInt8(y)) }
    }

    static func pixels(size: Int, _ f: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: size * size * 4)
        for y in 0..<size { for x in 0..<size {
            let (r, g, b) = f(x, y)
            let i = (y * size + x) * 4
            bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b
        } }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: size, height: size, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: size * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }
}

/// Unit vectors along an axis, for a deterministic stub model.
private struct StubEmbedder: FrameEmbedding {
    let modelID = "test/stub-siglip"
    let dims = 8
    var imageVector: @Sendable (CGImage) -> [Float] = { image in
        var v = [Float](repeating: 0, count: 8)
        v[min(7, image.width % 8)] = 1   // the card's width picks the axis
        return v
    }
    func embed(images: [CGImage]) async throws -> [[Float]] { images.map(imageVector) }
    func embed(text: String) async throws -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[min(7, Int(text.split(separator: " ").last.flatMap { Int($0) } ?? 0))] = 1   // "axis 3" → axis 3
        return v
    }
}

private enum Env {
    static func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("framesearch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func row(_ n: Int, path: String, stream: String = "Video+Audio", duration: Double = 10) -> CatalogRow.FrameIndexFile {
        CatalogRow.FrameIndexFile(digest: String(format: "%064x", n), fileID: String(format: "00000000-0000-0000-0000-%012X", n),
                                  filename: (path as NSString).lastPathComponent, path: path, removed: false, durationSeconds: duration, streamType: stream)
    }

    @MainActor
    static func loader(status: FrameIndexStatus, rows: [CatalogRow.FrameIndexFile], embedder: StubEmbedder = StubEmbedder()) -> FrameSearchLoader {
        FrameSearchLoader(modelID: embedder.modelID, loadIndex: { status }, files: { _ in rows },
                          embedText: { try await embedder.embed(text: $0) }, prewarm: {}, thumbnail: { _, _ in nil },
                          startIndex: { _, _ in nil }, reveal: { _ in true }, note: { _ in })
    }
}

// MARK: - Store: truth and isolation (stub model)

@Suite("Frames mode — the store") @MainActor
struct FrameSearchStoreTests {

    /// Content n has one frame along axis n at n seconds.
    static func index(_ ns: [Int]) -> FrameIndex {
        var b = FrameIndexBuilder(model: "test/stub-siglip", dims: 8)
        for n in ns {
            var v = [Float](repeating: 0, count: 8); v[n] = 1
            b.add(digest: String(format: "%064x", n), frames: [(Double(n), v), (Double(n) + 0.5, v.map { $0 * 0.5 + 0.1 })])
        }
        return b.snapshot()
    }

    @Test func aHitNamesTheFileAndTimeOfTheRowThatProducedItAndStaysInScope() async {
        let rows = [Env.row(2, path: "/V/a/two.mov"), Env.row(3, path: "/V/a/three.mov")]   // content 5 is indexed but out of scope
        let store = FrameSearchStore(scope: .folder("/V/a"), loader: Env.loader(status: .ready(Self.index([2, 3, 5])), rows: rows))
        await store.loadIndex()
        #expect(store.indexState == .ready(frames: 6, contents: 3))
        await store.search("axis 3")
        let top = store.hits.first
        #expect(top != nil)
        #expect(top?.digest == String(format: "%064x", 3) && top?.seconds == 3 && top?.filename == "three.mov" && top?.path == "/V/a/three.mov")
        #expect((top?.score ?? 0) > 0.999)
        #expect(top?.sourceWords == "SigLIP 2 (test/stub-siglip), similarity 1.00")
        #expect(store.hits.allSatisfy { $0.digest != String(format: "%064x", 5) }, "content 5 is outside the scope")
        await store.search("axis 5")
        #expect(store.hits.allSatisfy { $0.digest != String(format: "%064x", 5) })
        #expect(store.hits.count <= FrameSearchStore.perContent * rows.count)
        #expect(store.timing?.contains("frames in scope") == true)
    }

    @Test func noIndexOrAnUnreadableOneIsIndexNotBuiltAndNoHits() async {
        for status in [FrameIndexStatus.notBuilt, .unreadable("the matrix is 6 bytes; 3 frames × 8 need 48")] {
            let store = FrameSearchStore(scope: .everything, loader: Env.loader(status: status, rows: [Env.row(1, path: "/V/x.mov")]))
            await store.loadIndex()
            guard case .notBuilt(let words) = store.indexState else { Issue.record("\(status) must read as not built"); continue }
            #expect(words.hasPrefix("Index not built"))
            if case .unreadable = status { #expect(words.contains("6 bytes"), "the reason is shown") }
            await store.search("axis 1")
            #expect(store.hits.isEmpty && store.failure == nil, "no stale or partial hits")
        }
    }

    // MARK: Latest wins (a result is published only for the request that is still current)

    /// Contents 2 and 3 are indexed; /V/a holds content 2, /V/b holds content 3. `embedGate` holds the text tower
    /// for the words it is given; `filesGate` holds the catalog read for the scope it is given.
    private static func gatedLoader(_ gate: AsyncStream<Void>, heldWords: String? = nil, heldScope: ObservationsScope? = nil,
                                    embed: @escaping @Sendable (String) async throws -> [Float] = { try await StubEmbedder().embed(text: $0) }) -> FrameSearchLoader {
        let index = Self.index([2, 3])
        return FrameSearchLoader(modelID: StubEmbedder().modelID, loadIndex: { .ready(index) },
                          files: { scope in
                              if scope == heldScope { for await _ in gate { break } }
                              return scope == .folder("/V/b") ? [Env.row(3, path: "/V/b/three.mov")] : [Env.row(2, path: "/V/a/two.mov")]
                          },
                          embedText: { text in
                              if text == heldWords { for await _ in gate { break } }
                              return try await embed(text)
                          },
                          prewarm: {}, thumbnail: { _, _ in nil }, startIndex: { _, _ in nil }, reveal: { _ in true }, note: { _ in })
    }

    /// REGRESSION (reviewer 2026-11-10, A): clearing the field during a search returned without ending it, and the
    /// superseded search returned early too — "Asking SigLIP 2…" stayed and Search stayed disabled.
    @Test func clearingTheFieldDuringASearchEndsTheSearch() async {
        let gate = AsyncStream<Void>.makeStream()
        let store = FrameSearchStore(scope: .folder("/V/a"), loader: Self.gatedLoader(gate.stream, heldWords: "axis 2"))
        await store.loadIndex()
        let first = Task { await store.search("axis 2") }
        while !store.searching { await Task.yield() }
        await store.search("")
        #expect(store.searching == false, "the field is empty; the spinner goes at once")
        gate.continuation.yield()
        await first.value
        #expect(store.searching == false, "no search is in flight; the spinner must go")
        #expect(store.hits.isEmpty && store.query == nil && store.timing == nil && store.failure == nil, "and the cleared search publishes nothing")
    }

    @Test func aSupersededSearchNeverPublishes() async {
        let gate = AsyncStream<Void>.makeStream()
        let store = FrameSearchStore(scope: .everything, loader: Self.gatedLoader(gate.stream, heldWords: "axis 5"))
        await store.loadIndex()
        let old = Task { await store.search("axis 5") }
        while !store.searching { await Task.yield() }
        await store.search("axis 2")
        #expect(store.query == "axis 2" && store.hits.first?.filename == "two.mov" && store.searching == false)
        let shown = store.hits
        gate.continuation.yield()
        await old.value
        #expect(store.query == "axis 2" && store.hits == shown, "the older search never replaces the newer one's hits")
        #expect(store.searching == false && store.failure == nil)
    }

    @Test func aScopeChangeReSearchesAndShowsOnlyTheNewScopesHits() async {
        let gate = AsyncStream<Void>.makeStream()
        let store = FrameSearchStore(scope: .folder("/V/a"), loader: Self.gatedLoader(gate.stream, heldScope: .folder("/V/a")))
        await store.loadIndex()
        let old = Task { await store.search("axis 2") }
        while !store.searching { await Task.yield() }
        await store.set(scope: .folder("/V/b"))
        #expect(store.query == "axis 2" && !store.hits.isEmpty && store.hits.allSatisfy { $0.path == "/V/b/three.mov" }, "the same words, asked of the new scope")
        gate.continuation.yield()
        await old.value
        #expect(store.hits.allSatisfy { $0.path == "/V/b/three.mov" } && !store.hits.isEmpty, "a frame read for /V/a never shows under /V/b")
        #expect(store.searching == false)
        await store.search("axis 3")
        #expect(store.hits.first?.path == "/V/b/three.mov", "the next search reads the new scope's files, not the old scope's cached ones")
    }

    private struct TowerDown: LocalizedError {
        var errorDescription: String? { "the text tower is not loaded" }
    }

    @Test func aFailedSearchShowsTheFailureAndARetryClearsIt() async {
        let calls = OSAllocatedUnfairLock(initialState: 0)
        let gate = AsyncStream<Void>.makeStream()
        let loader = Self.gatedLoader(gate.stream, embed: { text in
            if calls.withLock({ $0 += 1; return $0 }) == 1 { throw TowerDown() }
            return try await StubEmbedder().embed(text: text)
        })
        let store = FrameSearchStore(scope: .folder("/V/a"), loader: loader)
        await store.loadIndex()
        await store.search("axis 2")
        #expect(store.failure?.contains("not loaded") == true && store.hits.isEmpty && store.searching == false)
        await store.search("axis 2")
        #expect(store.failure == nil && store.hits.first?.filename == "two.mov" && store.searching == false, "the retry's hits replace the failure")
    }
}

// MARK: - The job (stub decode, stub model)

@Suite("Frames mode — Index Frames job") @MainActor
struct FrameIndexJobTests {

    @Test func indexesPicturesSkipsOfflineRecordsUndecodableAndResumes() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [Env.row(1, path: "/V/ok.mov"), Env.row(2, path: "/V/song.wav", stream: "Audio only"),
                    Env.row(3, path: "/Offline/tape.dv"), Env.row(4, path: "/V/broken.mov"), Env.row(5, path: "/V/ok2.mov", duration: 3)]
        func job() -> FrameIndexJob {
            let j = FrameIndexJob(scope: .everything, loadFiles: { _ in rows }, embedder: StubEmbedder())
            j.root = root
            j.framesPerFile = 3
            j.volumeOnline = { !$0.hasPrefix("/Offline") }
            j.fileExists = { _ in true }
            j.note = { _ in }
            j.extract = { path, times in
                times.map { ($0, path.contains("broken") ? nil : FrameSearchTestCards.solid(9, 9, 9, size: 16 + Int($0.rounded()) % 8)) }
            }
            return j
        }
        let first = job()
        first.start()
        await first.task?.value
        guard case .finished(let summary) = first.state else { Issue.record("job did not finish: \(first.state)"); return }
        #expect(first.indexed == 2 && first.unreadable == 1 && first.offline == 1, "\(summary)")
        let index = try #require(FrameIndexStore.load(root: root, model: "test/stub-siglip").index)
        #expect(index.indexedDigests == [String(format: "%064x", 1), String(format: "%064x", 5)])
        #expect(index.count == 6, "3 frames per file")
        #expect(index.failures[String(format: "%064x", 4)]?.contains("no frame") == true)
        #expect(index.entries.filter { $0.digest == String(format: "%064x", 1) }.map(\.seconds) == FrameIndexEngine.timestamps(durationSeconds: 10, framesPerFile: 3).map { FrameIndexEntry(digest: "", seconds: $0).seconds },
                "the rows carry the times the engine decoded")

        let second = job()
        second.start()
        await second.task?.value
        #expect(second.planned == 1, "only the offline file is left (the undecodable one is recorded, not retried)")
        #expect(second.indexed == 0 && second.offline == 1)
    }

    // MARK: Whose fault it was (Codex sweep 11/09 #14)

    /// A model that is not there (weights missing, offline).
    struct NoModel: FrameEmbedding {
        let modelID = "test/stub-siglip"
        let dims = 8
        func embed(images: [CGImage]) async throws -> [[Float]] { throw SigLIPError.weightsMissing("offline") }
        func embed(text: String) async throws -> [Float] { throw SigLIPError.weightsMissing("offline") }
    }

    /// A flag a `@Sendable` seam can read and the test can set (≈ C++ std::atomic<bool>).
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set(_ v: Bool = true) { lock.withLock { value = v } }
    }

    /// The log lines a job wrote through its one sink.
    @MainActor final class Notes {
        var lines: [String] = []
    }

    static func digest(_ n: Int) -> String { String(format: "%064x", n) }

    /// A job over `rows` whose every file is online, present and decodes to `framesPerFile` (3) cards.
    static func job(_ rows: [CatalogRow.FrameIndexFile], root: URL, embedder: any FrameEmbedding = StubEmbedder(),
                    notes: Notes? = nil) -> FrameIndexJob {
        let j = FrameIndexJob(scope: .everything, loadFiles: { _ in rows }, embedder: embedder)
        j.root = root
        j.framesPerFile = 3
        j.concurrency = 1
        j.volumeOnline = { _ in true }
        j.fileExists = { _ in true }
        j.note = { notes?.lines.append($0) }
        j.extract = { _, times in times.map { ($0, FrameSearchTestCards.solid(9, 9, 9, size: 16)) } }
        return j
    }

    @Test func aModelThatCannotLoadIsNotHeldAgainstTheFile() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [Env.row(1, path: "/V/ok.mov")]
        let offline = Self.job(rows, root: root, embedder: NoModel())
        offline.start()
        await offline.task?.value
        let online = Self.job(rows, root: root)
        online.start()
        await online.task?.value
        #expect(online.indexed == 1, "the file decoded; the MODEL failed — the next run must index it")
    }

    @Test func aModelThatCannotLoadFailsTheJobAndTheOutcomeLineNamesTheCause() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = Notes()
        let job = Self.job([Env.row(1, path: "/V/a.mov"), Env.row(2, path: "/V/b.mov")], root: root, embedder: NoModel(), notes: notes)
        job.start()
        await job.task?.value
        guard case .failed(let message) = job.state else { Issue.record("a run whose model never loaded ended \(job.state)"); return }
        #expect(message.contains("SigLIP 2 weights are not on this Mac (offline)"), "\(message)")
        #expect(!job.wasRefused, "it started; it did not refuse")
        #expect(job.outcome == .modelUnavailable("SigLIP 2 weights are not on this Mac (offline)") && job.savePoints.isEmpty)
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title, state: job.state, wasRefused: job.wasRefused)
        #expect(outcome?.contains("FAILED") == true && outcome?.contains("weights are not on this Mac") == true, "\(outcome ?? "nil")")
        #expect(job.indexed == 0 && job.unreadable == 0)
        #expect(FrameIndexStore.load(root: root, model: "test/stub-siglip").index?.failures.isEmpty ?? true, "nothing is recorded against a file")
        #expect(!notes.lines.contains { $0.hasPrefix("could not index") }, "\(notes.lines)")
    }

    @Test func aDriveThatGoesAwayMidDecodeDefersTheFile() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [Env.row(1, path: "/Tape/a.mov")]
        let gone = Flag()
        let first = Self.job(rows, root: root)
        first.volumeOnline = { _ in !gone.isSet }
        first.extract = { _, _ in
            gone.set()
            throw CocoaError(.fileReadNoSuchFile)
        }
        first.start()
        await first.task?.value
        #expect(first.unreadable == 0 && first.offline == 1 && first.indexed == 0)
        #expect(FrameIndexStore.load(root: root, model: "test/stub-siglip").index?.failures.isEmpty ?? true, "a drive's fault is not the file's")
        let second = Self.job(rows, root: root)
        second.start()
        await second.task?.value
        #expect(second.planned == 1 && second.indexed == 1, "the drive is back: the file is indexed")
    }

    @Test func aModelThatFailsMidRunKeepsWhatWasIndexedAndBlamesNoFile() async throws {
        /// Embeds the first file, then the model is gone.
        actor OneThenGone: FrameEmbedding {
            nonisolated let modelID = "test/stub-siglip"
            nonisolated let dims = 8
            private var calls = 0
            func embed(images: [CGImage]) async throws -> [[Float]] {
                calls += 1
                guard calls == 1 else { throw SigLIPError.loadFailed("the GPU went away") }
                return try await StubEmbedder().embed(images: images)
            }
            func embed(text: String) async throws -> [Float] { throw SigLIPError.unavailable }
        }
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [Env.row(1, path: "/V/a.mov"), Env.row(2, path: "/V/b.mov"), Env.row(3, path: "/V/c.mov")]
        let first = Self.job(rows, root: root, embedder: OneThenGone())
        first.start()
        await first.task?.value
        #expect(first.outcome == .modelUnavailable("SigLIP 2 could not be loaded: the GPU went away"), "\(String(describing: first.outcome))")
        guard case .failed(let message) = first.state else { Issue.record("ended \(first.state)"); return }
        #expect(message.contains("2 files left for the next run") && message.contains("1 file indexed"), "\(message)")
        #expect(first.savePoints == [.modelFailed], "what was indexed before the model failed is saved")
        let index = try #require(FrameIndexStore.load(root: root, model: "test/stub-siglip").index)
        #expect(index.indexedDigests == [Self.digest(1)] && index.failures.isEmpty)
        let second = Self.job(rows, root: root)
        second.start()
        await second.task?.value
        #expect(second.alreadyDone == 1 && second.indexed == 2 && second.outcome == .finished)
    }

    @Test func aFileTheDecoderCannotReadIsRecordedOnceAndNotTriedAgain() async throws {
        /// The model is fine; its pixel door refuses this file's frames (the one model error that is the file's).
        struct RefusesPixels: FrameEmbedding {
            let modelID = "test/stub-siglip"
            let dims = 8
            func embed(images: [CGImage]) async throws -> [[Float]] {
                if images.first?.width == 24 { throw SigLIPError.badImage }
                return try await StubEmbedder().embed(images: images)
            }
            func embed(text: String) async throws -> [Float] { [] }
        }
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [Env.row(1, path: "/V/torn.mov"), Env.row(2, path: "/V/odd-pixels.mov"), Env.row(3, path: "/V/ok.mov")]
        let tries = Flag()
        func job() -> FrameIndexJob {
            let j = Self.job(rows, root: root, embedder: RefusesPixels())
            j.extract = { path, times in
                if path.contains("torn") {
                    tries.set()
                    throw CocoaError(.fileReadCorruptFile)   // the file is there (the seams say so) and will not decode
                }
                return times.map { ($0, FrameSearchTestCards.solid(9, 9, 9, size: path.contains("odd") ? 24 : 16)) }
            }
            return j
        }
        let first = job()
        first.start()
        await first.task?.value
        #expect(first.outcome == .finished && first.unreadable == 2 && first.indexed == 1 && first.offline == 0, "\(first.state)")
        let index = try #require(FrameIndexStore.load(root: root, model: "test/stub-siglip").index)
        #expect(index.failures[Self.digest(1)] == CocoaError(.fileReadCorruptFile).localizedDescription, "the decoder's own words")
        #expect(index.failures[Self.digest(2)] == "a frame could not be converted to pixels")
        #expect(index.indexedDigests == [Self.digest(3)])

        tries.set(false)
        let second = job()
        second.start()
        await second.task?.value
        #expect(second.planned == 0 && second.alreadyDone == 3 && !tries.isSet, "recorded, so a resume does not grind on it")
        #expect(second.outcome == .finished && second.subtitle == "Nothing to index")
    }

    // MARK: When the index is saved (each save point by name)

    /// Wait (main actor free) until `condition`, or fail naming what never happened.
    static func until(_ what: String, _ condition: () -> Bool) async throws {
        var waits = 0
        while !condition(), waits < 2_000 {
            waits += 1
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(condition(), "never happened in 10 s: \(what)")
    }

    /// Three files; the decode of the first one waits at a gate so the test can act while it is in hand.
    static func gated(root: URL) -> (job: FrameIndexJob, rows: [CatalogRow.FrameIndexFile], inHand: Flag, release: Flag) {
        let rows = [Env.row(1, path: "/V/a.mov"), Env.row(2, path: "/V/b.mov"), Env.row(3, path: "/V/c.mov")]
        let inHand = Flag(), release = Flag()
        let j = job(rows, root: root)
        j.extract = { path, times in
            if path.hasSuffix("a.mov") {
                inHand.set()
                while !release.isSet { try await Task.sleep(for: .milliseconds(5)) }
            }
            return times.map { ($0, FrameSearchTestCards.solid(9, 9, 9, size: 16)) }
        }
        return (j, rows, inHand, release)
    }

    @Test func pauseSavesWhatIsInHandHoldsThereAndResumeFinishes() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (job, _, inHand, release) = Self.gated(root: root)
        job.start()
        try await Self.until("the first file is in hand") { inHand.isSet }
        job.pause()
        #expect(job.isPaused && job.subtitle.hasPrefix("Pausing after the files in hand"))
        release.set()
        try await Self.until("the paused save") { job.subtitle.hasPrefix("Paused — 1 of 3 done") }
        #expect(job.savePoints == [.paused] && job.state == .running && job.indexed == 1, "the file in hand finished; no other was taken")
        #expect(FrameIndexStore.load(root: root, model: "test/stub-siglip").index?.indexedDigests == [Self.digest(1)], "paused = on disk")
        try await Task.sleep(for: .milliseconds(300))
        #expect(job.indexed == 1 && job.savePoints == [.paused], "nothing moves while paused")
        job.resume()
        await job.task?.value
        #expect(job.outcome == .finished && job.indexed == 3 && job.savePoints == [.paused, .finished])
        #expect(FrameIndexStore.load(root: root, model: "test/stub-siglip").index?.count == 9)
    }

    @Test func stopLetsTheFileInHandFinishSavesAndEndsCancelled() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let (job, rows, inHand, release) = Self.gated(root: root)
        let notes = Notes()
        job.note = { notes.lines.append($0) }
        job.start()
        try await Self.until("the first file is in hand") { inHand.isSet }
        job.cancel()
        #expect(job.state == .cancelling && job.subtitle == "Stopping — finishing 1 file, then saving…")
        release.set()
        await job.task?.value
        #expect(job.state == .cancelled && job.outcome == .stopped && job.savePoints == [.stopped] && job.indexed == 1)
        #expect(notes.lines.last?.hasPrefix("stopped after 1 file indexed (3 frames") == true, "\(notes.lines)")
        #expect(FrameIndexStore.load(root: root, model: "test/stub-siglip").index?.indexedDigests == [Self.digest(1)])
        let next = Self.job(rows, root: root)
        next.start()
        await next.task?.value
        #expect(next.alreadyDone == 1 && next.indexed == 2, "stopped = resumable")
    }

    @Test func quitCutsTheDecodeAndHoldsNothingAgainstTheFile() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let inHand = Flag()
        let job = Self.job([Env.row(1, path: "/V/a.mov"), Env.row(2, path: "/V/b.mov")], root: root)
        job.extract = { _, _ in
            inHand.set()
            try await Task.sleep(for: .seconds(60))   // cut by the quit (throws CancellationError)
            return []
        }
        job.start()
        try await Self.until("the first file is in hand") { inHand.isSet }
        job.stopForQuit()
        await job.task?.value
        #expect(job.state == .cancelled && job.outcome == .stopped)
        #expect(job.done == 0 && job.indexed == 0 && job.unreadable == 0 && job.savePoints.isEmpty, "a cut decode is not a try")
        #expect(FrameIndexStore.load(root: root, model: "test/stub-siglip") == .notBuilt)
    }

    @Test func aCheckpointSavesAndHandsOverExactlyWhatItWrote() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [Env.row(1, path: "/V/a.mov"), Env.row(2, path: "/V/b.mov"), Env.row(3, path: "/V/c.mov")]
        let job = Self.job(rows, root: root)
        job.checkpointFiles = 1
        var handed: [FrameIndex] = []
        var onDiskAtHandover: [FrameIndex?] = []
        job.onSaved = { index in
            handed.append(index)
            onDiskAtHandover.append(FrameIndexStore.load(root: root, model: "test/stub-siglip").index)
        }
        job.start()
        await job.task?.value
        #expect(job.savePoints == [.checkpoint, .checkpoint, .checkpoint], "one per file; the end has nothing new to write")
        #expect(handed.map(\.count) == [3, 6, 9])
        #expect(handed == onDiskAtHandover.compactMap { $0 }, "truth: the snapshot handed over is the index on disk at that moment")
        #expect(job.outcome == .finished)
    }

    @Test(arguments: [(1, FrameIndexSavePoint.checkpoint, 1), (100, FrameIndexSavePoint.finished, 3)])
    func aSaveThatFailsFailsTheJobAndSaysWhatIsNotOnDisk(checkpointFiles: Int, point: FrameIndexSavePoint, indexedByThen: Int) async throws {
        let dir = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: root)   // the index folder cannot be made under a plain file
        let notes = Notes()
        let job = Self.job([Env.row(1, path: "/V/a.mov"), Env.row(2, path: "/V/b.mov"), Env.row(3, path: "/V/c.mov")], root: root, notes: notes)
        job.checkpointFiles = checkpointFiles
        var handed = 0
        job.onSaved = { _ in handed += 1 }
        job.start()
        await job.task?.value
        guard case .saveFailed(at: point, why: let why) = job.outcome else { Issue.record("ended \(String(describing: job.outcome))"); return }
        guard case .failed(let message) = job.state else { Issue.record("ended \(job.state)"); return }
        #expect(message.hasPrefix("The frame index could not be saved: \(why) (\(point.rawValue))"), "\(message)")
        #expect(message.contains("\(indexedByThen) result\(indexedByThen == 1 ? "" : "s") since the last save"), "\(message)")
        #expect(message.contains("not on disk"), "\(message)")
        #expect(job.indexed == indexedByThen && job.savePoints.isEmpty && handed == 0, "the job stops at the failed save; nobody is told of an index")
        #expect(notes.lines.contains { $0.hasPrefix("could not save the frame index (\(point.rawValue))") }, "\(notes.lines)")
        #expect((try? Data(contentsOf: root)) == Data("x".utf8), "what was in the way is untouched")
    }

    // MARK: Scale and sensor

    @Test(.timeLimit(.minutes(1)))
    func oneHundredThousandRowsOverAFiftyThousandContentIndexArePlannedInsideTheBudget() async throws {
        let root = try Env.tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // 50,000 contents already indexed (one frame each), 50,000 without a picture: nothing to do.
        var seed = FrameIndexBuilder(model: "test/stub-siglip", dims: 8)
        var v = [Float](repeating: 0, count: 8); v[0] = 1
        for n in 0..<50_000 { seed.add(digest: Self.digest(n), frames: [(1, v)]) }
        try FrameIndexStore.save(seed.snapshot(), root: root)
        let rows = (0..<100_000).map { Env.row($0, path: "/V/\($0).mov", stream: $0 < 50_000 ? "Video+Audio" : "Audio only") }
        let job = Self.job(rows, root: root)
        let started = ContinuousClock.now
        job.start()
        await job.task?.value
        let took = ContinuousClock.now - started
        #expect(job.outcome == .finished && job.planned == 0 && job.alreadyDone == 50_000, "\(job.state)")
        #expect(job.savePoints == [.finished], "kept from before: a complete run that changed nothing still writes once, so the window is told")
        #expect(took < .seconds(10), "100k rows over a 50k-content index planned in \(took)")
    }

    @Test func theJobLeavesEveryIndexReadAndWriteToTheWriter() throws {
        let src = try SourceTree.appCode(named: "FrameIndexJob.swift")   // comments stripped
        let writerStart = try #require(src.range(of: "actor FrameIndexWriter {"))
        let writerEnd = try #require(src.range(of: "enum FrameIndexSavePoint"), "the job's types follow the writer")
        try #require(writerStart.lowerBound < writerEnd.lowerBound)
        #expect(src[writerStart.lowerBound..<writerEnd.lowerBound].contains("FrameIndexStore.save("), "the writer is where the save is")
        let code = String(src[..<writerStart.lowerBound]) + String(src[writerEnd.lowerBound...])
        for forbidden in ["FrameIndexStore.load(", "FrameIndexStore.save(", "FrameIndexBuilder(", "save(reason:", "\"finished\""] {
            #expect(!code.contains(forbidden), "`\(forbidden)` outside actor FrameIndexWriter — index IO belongs to the writer, save points are an enum")
        }
    }
}

// MARK: - Sensor

@Suite("Frames mode — sensors")
struct FrameSearchSensorTests {

    private let files = ["SigLIPEmbedder.swift", "FrameIndexJob.swift", "FrameSearchStore.swift", "FrameSearchView.swift"]

    @Test func noModelExtensionAndNothingWritesTheCatalog() throws {
        for file in files {
            let src = try SourceTree.appCode(named: file)
            #expect(!src.contains("extension VideoScanModel"), "rule 12: \(file)")
            for forbidden in ["repository.write", "commit(as", "writeBlocking", "INSERT", "UPDATE ", "saveCatalog", ".records"] {
                #expect(!src.contains(forbidden), "\(file): `\(forbidden)` — the frame index never writes the catalog or walks records")
            }
        }
        let view = try SourceTree.appCode(named: "FrameSearchView.swift")
        #expect(!view.contains("@EnvironmentObject") && !view.contains("model.") && !view.contains(".yellow"))
        #expect(try SourceTree.appCode(named: "FrameSearchStore.swift").contains("repository.read {"), "the catalog through the read door only")
    }
}

// MARK: - Mockup (rendered from the real view, synthetic cards)

@Suite("Frames mode — the view renders (mockup)") @MainActor
struct FrameSearchMockupTests {

    @Test func framesDark() async throws {
        // Twelve synthetic "frames": colour cards with a word drawn on them (no family pixels).
        let words = ["cake", "candles", "beach", "snow", "dog", "tree", "boat", "table", "presents", "baby", "lake", "party"]
        var b = FrameIndexBuilder(model: SigLIPConfig.modelID, dims: 8)
        var thumbs: [String: CGImage] = [:]
        var rows: [CatalogRow.FrameIndexFile] = []
        for (i, word) in words.enumerated() {
            var v = [Float](repeating: 0.05, count: 8); v[0] = 1 - Float(i) * 0.06
            let digest = String(format: "%064x", i + 1)
            b.add(digest: digest, frames: [(Double(30 + i * 17), v)])
            rows.append(Env.row(i + 1, path: "/Volumes/Synthetic/Tape_\(String(format: "%02d", i + 1))_\(word).mov"))
            thumbs[FrameIndex.cacheKey(model: SigLIPConfig.modelID, digest: digest, seconds: Double(30 + i * 17))] = Self.card(word, hue: Double(i) / 12)
        }
        let index = b.snapshot()
        let fixedRows = rows
        let loader = FrameSearchLoader(modelID: SigLIPConfig.modelID, loadIndex: { .ready(index) }, files: { _ in fixedRows },
                                       embedText: { _ in [1, 0, 0, 0, 0, 0, 0, 0] }, prewarm: {}, thumbnail: { _, _ in nil },
                                       startIndex: { _, _ in nil }, reveal: { _ in true }, note: { _ in })
        let store = FrameSearchStore(scope: .everything, loader: loader)
        await store.loadIndex()
        await store.search("a birthday cake with candles")
        #expect(store.hits.count == 12)
        let view = VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("Observations").font(.title2.weight(.semibold))
                Text("· everything in the catalog").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text("Words | **Frames**").font(.callout)
            }
            Text("🔍  a birthday cake with candles").padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.08)).cornerRadius(7)
            FrameSearchView(frames: store, dossiers: nil, mockupThumbnails: thumbs)
            Text("MOCKUP — rendered from the real view with synthetic cards and names").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 980, alignment: .top)
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark).background(Color(white: 0.12)))
        renderer.scale = 2
        var rendered: CGImage?
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance { rendered = renderer.cgImage }
        let image = try #require(rendered)
        #expect(image.width == 1960 && image.height > 600)
        let dir = ProcessInfo.processInfo.environment["VIDEOSCAN_MOCKUP_DIR"]
            ?? (try? JSONSerialization.jsonObject(with: Data(contentsOf: FrameIndexStore.productionRoot.appendingPathComponent("realrun.json"))) as? [String: Any])?["queriesOut"] as? String
        if let dir, !dir.isEmpty {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("MOCKUP-observations-frames-dark.png")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)
        }
    }

    static func card(_ word: String, hue: Double) -> CGImage {
        let w = 320, h = 180
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let c = NSColor(hue: hue, saturation: 0.45, brightness: 0.7, alpha: 1)
        ctx.setFillColor(c.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (word as NSString).draw(at: NSPoint(x: 24, y: 70), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.white])
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }
}
