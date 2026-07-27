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

    private func poll(timeout: Duration = .seconds(30),
                      until condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try await Task.sleep(for: .milliseconds(25))
        }
        return true
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

    @Test("same-row play promotes a prewarm without starting a second run")
    func playPromotesExistingPrewarm() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
            duration: 8, prefix: "test_gen_filmstrip_promote")
        defer { TestMediaGenerator.cleanup(path) }

        let model = VideoScanModel()
        model.previewRequestPath = path
        model.prewarmFilmstripIfNeeded(item: workItem(path: path, duration: 8))
        let prewarmRunID = model.filmstripRunID
        try #require(model.filmstripTaskPath == path)
        try #require(!model.filmstripTaskIsInteractive)

        model.requestFilmstrip(for: makeRecord(path: path, duration: 8))

        #expect(model.filmstripRunID == prewarmRunID,
                "promotion started a duplicate media rip instead of coalescing")
        #expect(model.filmstripTaskIsInteractive)
        #expect(model.filmstripState.isActive(forPath: path))

        let ready = try await poll {
            if case .ready(let publishedPath, let frames) = model.filmstripState {
                return publishedPath == path && !frames.isEmpty
            }
            return false
        }
        #expect(ready, "promoted prewarm never published its completed strip")
    }

    @Test("rapid row replacement never republishes the cancelled row")
    func replacementRejectsStaleCompletion() async throws {
        let first = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
            duration: 12, prefix: "test_gen_filmstrip_stale_first")
        let second = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
            duration: 4, prefix: "test_gen_filmstrip_stale_second")
        defer {
            TestMediaGenerator.cleanup(first)
            TestMediaGenerator.cleanup(second)
        }

        let model = VideoScanModel()
        model.previewRequestPath = first
        model.requestFilmstrip(for: makeRecord(path: first, duration: 12))
        let firstRunID = model.filmstripRunID

        model.previewRequestPath = second
        model.requestFilmstrip(for: makeRecord(path: second, duration: 4))
        #expect(model.filmstripRunID != firstRunID)
        #expect(model.filmstripTaskPath == second)

        let ready = try await poll {
            if case .ready(let publishedPath, let frames) = model.filmstripState {
                return publishedPath == second && !frames.isEmpty
            }
            return false
        }
        try #require(ready, "replacement row never reached ready")

        // Give any queued completion hop from the cancelled run time to land.
        try await Task.sleep(for: .milliseconds(500))
        guard case .ready(let publishedPath, _) = model.filmstripState else {
            Issue.record("cancelled run changed the replacement's ready state")
            return
        }
        #expect(publishedPath == second,
                "stale completion from the cancelled row reached the preview pane")
        #expect(!model.filmstripFailedPaths.contains(first),
                "cancellation incorrectly classified the first file as bad media")
    }

    @Test("Stop cancels an interactive run and queued callbacks cannot revive it")
    func stopCannotBeUndoneByQueuedCompletion() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mkv", streams: .videoOnly, videoCodec: "ffv1",
            duration: 12, prefix: "test_gen_filmstrip_stop")
        defer { TestMediaGenerator.cleanup(path) }

        let model = VideoScanModel()
        model.previewRequestPath = path
        model.requestFilmstrip(for: makeRecord(path: path, duration: 12))
        try #require(model.filmstripTask != nil)

        model.stopFilmstrip()
        #expect(model.filmstripTask == nil)
        #expect(model.filmstripTaskPath == nil)
        #expect(!model.filmstripTaskIsInteractive)
        guard case .idle = model.filmstripState else {
            Issue.record("Stop did not immediately return to idle")
            return
        }

        try await Task.sleep(for: .seconds(1))
        guard case .idle = model.filmstripState else {
            Issue.record("a queued progress/completion callback revived stopped playback")
            return
        }
        #expect(!model.filmstripFailedPaths.contains(path))
    }

}

@Suite("Filmstrip crash provocation", .serialized)
struct FilmstripCrashAdversarialTests {
    @Test("finite-but-unrepresentable offsets are rejected without trapping")
    func oversizedOffsetDoesNotTrapOrPublishCacheFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_filmstrip_huge_offset_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = PreviewDiskCache(rootURL: root)

        // `Double.greatestFiniteMagnitude` passes the old finite/nonnegative
        // guard but traps when multiplied by 1000 and converted to Int.
        cache.storeFilmstrip(
            [(offsetSeconds: Double.greatestFiniteMagnitude,
              image: PreviewTestImages.twoTone())],
            path: "/v/hostile.mkv", mtime: 1, size: 1)

        let payloads = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("-strip-") }
        #expect(payloads.isEmpty,
                "an offset outside Int milliseconds was persisted into the cache namespace")
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
