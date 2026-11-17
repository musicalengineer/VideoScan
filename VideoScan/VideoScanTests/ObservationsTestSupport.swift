// ObservationsTestSupport.swift — fixtures shared by the Observations
// hardening suites (ObservationsStoreBehaviourTests, FrameSearchStoreBehaviourTests,
// FrameIndexEngineTests, FrameIndexMediaMatrixTests, SigLIPTinyModelTests).
// Synthetic pictures and names only; every folder is a temp folder.

import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// A deterministic stand-in for SigLIP 2 (8 dims): an image's vector is the unit axis its WIDTH picks
/// (width % 8); the words "axis N" are axis N. So a test can say which frame a query must find.
struct ObsStubEmbedder: FrameEmbedding {
    let modelID = "test/stub-siglip"
    let dims = 8
    func embed(images: [CGImage]) async throws -> [[Float]] { images.map { Self.axis($0.width % 8) } }
    func embed(text: String) async throws -> [Float] { Self.axis(Int(text.split(separator: " ").last ?? "") ?? 0) }

    static func axis(_ n: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 8)
        v[min(7, max(0, n))] = 1
        return v
    }
}

/// A counter a `@Sendable` seam can bump and the test can read (≈ C++ std::atomic<int>).
final class ObsCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var value: Int { lock.withLock { n } }
    @discardableResult func bump() -> Int { lock.withLock { n += 1; return n } }
}

/// What a `@Sendable` seam was asked, in order (≈ a mutex-guarded std::vector<std::string>).
final class ObsAsked: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    var all: [String] { lock.withLock { items } }
    func add(_ item: String) { lock.withLock { items.append(item) } }
}

enum ObsFixture {

    static func digest(_ n: Int) -> String { String(format: "%064x", n) }

    static func tempDir(_ label: String = "obs") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Content `n` at `path` (digest and file id derived from `n`).
    static func row(_ n: Int, path: String, stream: String = "Video+Audio", duration: Double = 10, removed: Bool = false,
                    fileID: String? = nil) -> CatalogRow.FrameIndexFile {
        CatalogRow.FrameIndexFile(digest: digest(n), fileID: fileID ?? String(format: "00000000-0000-0000-0000-%012X", n),
                                  filename: (path as NSString).lastPathComponent, path: path, removed: removed,
                                  durationSeconds: duration, streamType: stream)
    }

    /// Content n has `framesEach` frames along axis (n % 8), the first at n seconds, each later one a little weaker.
    static func index(_ ns: [Int], framesEach: Int = 1) -> FrameIndex {
        var b = FrameIndexBuilder(model: "test/stub-siglip", dims: 8)
        for n in ns {
            let frames = (0..<framesEach).map { i -> (seconds: Double, vector: [Float]) in
                var v = [Float](repeating: 0.01 * Float(i + 1), count: 8)
                v[n % 8] = 1
                return (Double(n) + Double(i) * 0.5, v)
            }
            b.add(digest: digest(n), frames: frames)
        }
        return b.snapshot()
    }

    /// A Frames loader whose every door is a closure the test names; the ones it does not name are inert.
    @MainActor
    static func frameLoader(index: @escaping @Sendable () async -> FrameIndexStatus = { .notBuilt },
                            files: @escaping FrameSearchLoader.Files = { _ in [] },
                            embedText: @escaping @Sendable (String) async throws -> [Float] = { try await ObsStubEmbedder().embed(text: $0) },
                            prewarm: @escaping @Sendable () async throws -> Void = {},
                            startIndex: @escaping @MainActor (ObservationsScope, @escaping @MainActor (FrameIndex) -> Void) -> FrameIndexWatch? = { _, _ in nil },
                            reveal: @escaping @MainActor (UUID) -> Bool = { _ in true },
                            notes: FrameIndexJobTests.Notes? = nil) -> FrameSearchLoader {
        FrameSearchLoader(modelID: ObsStubEmbedder().modelID, loadIndex: index, files: files, embedText: embedText, prewarm: prewarm,
                          thumbnail: { _, _ in nil }, startIndex: startIndex, reveal: reveal, note: { notes?.lines.append($0) })
    }

    /// A job over `rows` in `root`: every file online, present, decoding to 3 cards 16 px wide (axis 0); one at a time.
    @MainActor
    static func job(_ rows: [CatalogRow.FrameIndexFile], root: URL, embedder: any FrameEmbedding = ObsStubEmbedder(),
                    notes: FrameIndexJobTests.Notes? = nil) -> FrameIndexJob {
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

    /// The index on disk under `root` for the stub model.
    static func onDisk(_ root: URL) -> FrameIndexStatus { FrameIndexStore.load(root: root, model: "test/stub-siglip") }
}
