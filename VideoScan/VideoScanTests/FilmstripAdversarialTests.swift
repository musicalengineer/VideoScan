import Testing
import Foundation
@testable import VideoScan

/// Adversarial lifecycle and cache-boundary coverage for the filmstrip player.
/// These tests deliberately exercise rapid user actions and hostile persisted
/// metadata rather than the ordinary one-click/one-file path.
@Suite("Filmstrip adversarial lifecycle",
       .serialized,
       .timeLimit(.minutes(5)),
       .enabled(if: TestMediaGenerator.isAvailable))
@MainActor
struct FilmstripAdversarialTests {

    private func makeRecord(path: String, duration: Double) -> VideoRecord {
        let record = VideoRecord()
        record.fullPath = path
        record.filename = URL(fileURLWithPath: path).lastPathComponent
        record.container = "Matroska / WebM"
        record.videoCodec = "ffv1"
        record.streamTypeRaw = StreamType.videoOnly.rawValue
        record.durationSeconds = duration
        return record
    }

    private func workItem(path: String, duration: Double) -> VideoScanModel.FilmstripWorkItem {
        .init(path: path,
              container: "Matroska / WebM",
              videoCodec: "ffv1",
              likelyUnanalyzable: false,
              durationSeconds: duration)
    }

    @Test("a different-row prewarm never preempts an interactive request")
    func prewarmCannotPreemptInteractive() async throws {
        let first = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
            duration: 8, prefix: "test_gen_filmstrip_interactive")
        let second = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
            duration: 8, prefix: "test_gen_filmstrip_prewarm_other")
        defer {
            TestMediaGenerator.cleanup(first)
            TestMediaGenerator.cleanup(second)
        }

        let model = VideoScanModel()
        model.previewRequestPath = first
        model.requestFilmstrip(for: makeRecord(path: first, duration: 8))
        let interactiveRunID = model.filmstripRunID
        try #require(model.filmstripTaskPath == first)
        try #require(model.filmstripTaskIsInteractive)

        model.prewarmFilmstripIfNeeded(item: workItem(path: second, duration: 8))

        #expect(model.filmstripRunID == interactiveRunID,
                "background prewarm replaced the user's interactive generation")
        #expect(model.filmstripTaskPath == first)
        #expect(model.filmstripTaskIsInteractive)
        model.stopFilmstrip()
    }

}

@Suite("Filmstrip cache shape stress", .timeLimit(.minutes(2)))
struct FilmstripCacheShapeStressTests {
    @Test("256 complete 16-frame strips remain discoverable within a bounded probe budget")
    func realisticMultiplierProbeBudget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_filmstrip_shape_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)

        for record in 0..<256 {
            let path = "/v/archive/\(record).mkv"
            let key = PreviewDiskCache.cacheKey(path: path, mtime: 1, size: 1)
            for index in 0..<16 {
                let name = PreviewDiskCache.stripFilename(
                    key: key, index: index, count: 16, offsetMillis: index * 500)
                FileManager.default.createFile(
                    atPath: root.appendingPathComponent(name).path,
                    contents: Data(), attributes: nil)
            }
        }

        let clock = ContinuousClock()
        var allFound = true
        let elapsed = clock.measure {
            for record in stride(from: 0, to: 256, by: 17) {
                allFound = allFound && cache.hasCompleteFilmstrip(
                    path: "/v/archive/\(record).mkv", mtime: 1, size: 1)
            }
        }
        #expect(allFound)
        #expect(elapsed < .seconds(3),
                "16-file-per-record cache shape made listing probes too expensive: \(elapsed)")
    }
}
