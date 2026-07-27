// FilmstripModelTests.swift
// ISOLATION + SENSOR dimensions for the filmstrip orchestration layer
// (feature/filmstrip-preview commits 0b9fa96 + fe0943d, 2026-07-27).
//
// The isolation contracts under test:
//
//   1. A filmstrip failure must NOT touch ThumbnailFailureStore — the
//      fast thumbnail already succeeded for these files, and poisoning
//      the shared negative cache would blank their previews entirely
//      (the 2026-07-26 cache-poison incident class). Failures land in
//      the session-scoped filmstripFailedPaths instead.
//
//   2. Strip cache writes land under the test-host-redirected
//      PreviewDiskCache root — never the production ~/Library path.
//
//   3. A pre-poisoned garbage strip set on disk degrades to
//      regeneration, never a crash or a garbage .ready publish.
//
// Plus the route-gate REGRESSION SENSOR (checklist dimension 5a):
// matroska/ffv1 routes .ffmpegDirect AND .ffmpegDirect maps to the
// filmstrip surface — the pure PreviewPlayAction seam extracted from
// the CatalogHelpers play-button click site. If either half flips,
// MKV/FFV1 records are back to a dead AVPlayer pane.

import Testing
import Foundation
import CoreGraphics
@testable import VideoScan

// MARK: - Pure sensors and state machine (no media, no model I/O)

@Suite("Filmstrip route gate + state (pure)")
struct FilmstripRouteGateSensorTests {

    /// REGRESSION SENSOR (5a) — BOTH halves of the play-button mapping:
    /// route(matroska/ffv1) == .ffmpegDirect, and .ffmpegDirect →
    /// .filmstrip (never AVPlayer). The CatalogHelpers click site
    /// switches on PreviewPlayAction.forRoute, so these two pins cover
    /// the full click-to-surface path for the archival masters.
    @Test("matroska/ffv1 → .ffmpegDirect → filmstrip surface; friendly routes keep AVPlayer")
    func routeGateSensor() {
        #expect(PreviewFrameRouter.previewRoute(container: "Matroska / WebM",
                                                videoCodec: "ffv1",
                                                likelyUnanalyzable: false) == .ffmpegDirect,
                "mkv/ffv1 stopped routing ffmpegDirect — filmstrip mode is unreachable")
        #expect(PreviewPlayAction.forRoute(.ffmpegDirect) == .filmstrip,
                "ffmpegDirect must NEVER construct an AVPlayer")
        #expect(PreviewPlayAction.forRoute(.avFoundation) == .avPlayer,
                "friendly records must keep the real AVPlayer path")
    }

    @Test("PreviewFilmstripState.isActive matches only its own path")
    func stateIsActive() {
        let frame = PreviewFilmstrip.Frame(offsetSeconds: 0.5,
                                           image: PreviewTestImages.twoTone())
        #expect(!PreviewFilmstripState.idle.isActive(forPath: "/v/a.mkv"))
        #expect(!PreviewFilmstripState.idle.isActive(forPath: nil))

        let loading = PreviewFilmstripState.loading(path: "/v/a.mkv", done: 3, total: 16)
        #expect(loading.isActive(forPath: "/v/a.mkv"))
        #expect(!loading.isActive(forPath: "/v/b.mkv"))
        #expect(!loading.isActive(forPath: nil))

        let ready = PreviewFilmstripState.ready(path: "/v/a.mkv", frames: [frame])
        #expect(ready.isActive(forPath: "/v/a.mkv"))
        #expect(!ready.isActive(forPath: "/v/b.mkv"))
    }
}

// MARK: - Model lifecycle (state machine, no generation in flight)

@Suite("Filmstrip model state machine", .serialized)
@MainActor
struct FilmstripModelStateTests {

    private func readyState(path: String) -> PreviewFilmstripState {
        .ready(path: path,
               frames: [PreviewFilmstrip.Frame(offsetSeconds: 0.5,
                                               image: PreviewTestImages.twoTone())])
    }

    @Test("stopFilmstrip returns the pane to idle")
    func stopReturnsToIdle() {
        let model = VideoScanModel()
        model.filmstripState = readyState(path: "/v/a.mkv")
        model.stopFilmstrip()
        guard case .idle = model.filmstripState else {
            Issue.record("stopFilmstrip left state \(model.filmstripState)")
            return
        }
    }

    @Test("resetFilmstrip drops state for a DIFFERENT row, keeps it for the same row")
    func resetIsPathScoped() {
        let model = VideoScanModel()

        // Same row: selection re-request must not blank a ready strip.
        model.filmstripState = readyState(path: "/v/a.mkv")
        model.resetFilmstrip(forNewPath: "/v/a.mkv")
        #expect(model.filmstripState.isActive(forPath: "/v/a.mkv"),
                "same-row reset must keep the ready strip")

        // Different row: stale frames must never show.
        model.resetFilmstrip(forNewPath: "/v/b.mkv")
        guard case .idle = model.filmstripState else {
            Issue.record("other-row reset left state \(model.filmstripState)")
            return
        }

        // Teardown (nil): always idle.
        model.filmstripState = readyState(path: "/v/a.mkv")
        model.resetFilmstrip(forNewPath: nil)
        #expect(!model.filmstripState.isActive(forPath: "/v/a.mkv"))
    }
}

// MARK: - Generation isolation (real ffmpeg, real disk cache)

@Suite("Filmstrip generation isolation",
       .serialized,
       .timeLimit(.minutes(5)),
       .enabled(if: TestMediaGenerator.isAvailable))
@MainActor
struct FilmstripGenerationIsolationTests {

    // MARK: Helpers

    private func makeRecord(path: String, durationSeconds: Double) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.container = "Matroska / WebM"
        r.videoCodec = "ffv1"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.durationSeconds = durationSeconds
        return r
    }

    /// Poll a main-actor condition — generation runs in a detached task
    /// and publishes back via MainActor.run, so sleeping between checks
    /// lets those hops land. (For Rick: like pumping a run loop while
    /// waiting on a worker thread's callback.)
    private func poll(timeoutSeconds: Double = 60,
                      until condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeoutSeconds))
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try await Task.sleep(for: .milliseconds(100))
        }
        return true
    }

    // MARK: 1. Failure must not poison ThumbnailFailureStore

    @Test("filmstrip failure records nothing in ThumbnailFailureStore — fast thumbnail stays served")
    func failureDoesNotPoisonFailureStore() async throws {
        // A real file with a real signature whose every rip fails:
        // garbage bytes with an .mkv name.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_gen_filmstrip_iso_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("garbage.mkv").path
        try Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 41) }).write(
            to: URL(fileURLWithPath: path))

        let model = VideoScanModel()
        // The fast thumbnail "already succeeded" for this row — put its
        // payload in the L2 so we can prove it survives the failure.
        let sig = try #require(PreviewDiskCache.fileSignature(atPath: path))
        model.previewDiskCache.store(PreviewTestImages.twoTone(),
                                     path: path, mtime: sig.mtime, size: sig.size,
                                     tier: .fast)

        model.previewRequestPath = path
        model.requestFilmstrip(for: makeRecord(path: path, durationSeconds: 8.0))

        let failed = try await poll { model.filmstripFailedPaths.contains(path) }
        try #require(failed, "filmstrip generation never failed — garbage fixture broke?")

        // THE contract: the shared negative cache is untouched…
        #expect(!model.thumbnailFailureStore.isKnownFailure(atPath: path),
                "filmstrip failure poisoned ThumbnailFailureStore — the row's fast thumbnail would blank")
        // swiftlint:disable:next empty_count
        #expect(model.thumbnailFailureStore.count == 0)
        // …the fast-tier payload is still served…
        #expect(model.previewDiskCache.lookup(path: path, mtime: sig.mtime, size: sig.size) != nil,
                "fast thumbnail payload vanished after a filmstrip failure")
        // …and the pane fell through to the interactive NO PREVIEW state.
        #expect(model.previewUnavailable)
        guard case .idle = model.filmstripState else {
            Issue.record("failed interactive generation left state \(model.filmstripState)")
            return
        }
    }

    // MARK: 2 + strip cache redirect, end to end

    @Test("interactive generation publishes .ready and stores the strip under the redirected root only")
    func endToEndInteractiveWithRedirectedCache() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoOnly,
            videoCodec: "ffv1",
            duration: 4.0,
            prefix: "test_gen_filmstrip_e2e")
        defer { TestMediaGenerator.cleanup(path) }

        let model = VideoScanModel()
        // The model's default cache must be the test-host redirect —
        // under the temp sandbox, never real App Support (guards this
        // suite the same way productionRootRedirectsForTests guards the
        // single-frame tiers).
        let rootPath = model.previewDiskCache.rootURL.standardizedFileURL.path
        try #require(rootPath.hasPrefix(
            URL(fileURLWithPath: NSTemporaryDirectory()).standardizedFileURL.path))
        try #require(!rootPath.contains("Application Support"))

        model.previewRequestPath = path
        model.requestFilmstrip(for: makeRecord(path: path, durationSeconds: 4.0))

        var readyFrames: [PreviewFilmstrip.Frame] = []
        let ready = try await poll {
            if case .ready(path, let frames) = model.filmstripState {
                readyFrames = frames
                return true
            }
            return false
        }
        try #require(ready, "interactive filmstrip never reached .ready (state: \(model.filmstripState))")
        #expect(readyFrames.count == PreviewFilmstripPlan.defaultFrameCount)
        let offsets = readyFrames.map(\.offsetSeconds)
        #expect(zip(offsets, offsets.dropFirst()).allSatisfy { $0 < $1 })

        // Write-through lands (after publish — poll for it), inside the
        // redirected root.
        let sig = try #require(PreviewDiskCache.fileSignature(atPath: path))
        let stored = try await poll(timeoutSeconds: 30) {
            model.previewDiskCache.hasCompleteFilmstrip(path: path,
                                                        mtime: sig.mtime, size: sig.size)
        }
        #expect(stored, "strip write-through never landed in the disk cache")
        let stripFiles = try FileManager.default
            .contentsOfDirectory(atPath: model.previewDiskCache.rootURL.path)
            .filter { $0.contains("-strip-") }
        #expect(stripFiles.count == readyFrames.count,
                "expected \(readyFrames.count) strip payloads under the redirected root, found \(stripFiles.count)")

        // Second click after stop: served from the L2, still .ready.
        model.stopFilmstrip()
        model.requestFilmstrip(for: makeRecord(path: path, durationSeconds: 4.0))
        let readyAgain = try await poll(timeoutSeconds: 30) {
            if case .ready(path, let frames) = model.filmstripState {
                return frames.count == readyFrames.count
            }
            return false
        }
        #expect(readyAgain, "cached strip was not re-served after stop → play")
    }

    // MARK: 3. Poisoned pre-existing strip set

    @Test("pre-poisoned garbage strip set degrades to regeneration — valid frames, no crash")
    func poisonedStripSetRegenerates() async throws {
        let path = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoOnly,
            videoCodec: "ffv1",
            duration: 4.0,
            prefix: "test_gen_filmstrip_poisoned")
        defer { TestMediaGenerator.cleanup(path) }

        let model = VideoScanModel()
        let sig = try #require(PreviewDiskCache.fileSignature(atPath: path))
        let key = PreviewDiskCache.cacheKey(path: path, mtime: sig.mtime, size: sig.size)
        let root = model.previewDiskCache.rootURL

        // A "complete" 3-set whose payloads are not JPEGs, plus a
        // malformed name under the key's prefix — the crashed-writer /
        // disk-corruption shape.
        for i in 0..<3 {
            let name = PreviewDiskCache.stripFilename(key: key, index: i, count: 3,
                                                      offsetMillis: i * 500)
            try Data("corrupt payload \(i)".utf8).write(to: root.appendingPathComponent(name))
        }
        try Data("junk".utf8).write(to: root.appendingPathComponent("\(key)-strip-junk.jpg"))

        model.previewRequestPath = path
        model.requestFilmstrip(for: makeRecord(path: path, durationSeconds: 4.0))

        var readyFrames: [PreviewFilmstrip.Frame] = []
        let ready = try await poll {
            if case .ready(path, let frames) = model.filmstripState {
                readyFrames = frames
                return true
            }
            return false
        }
        try #require(ready, "poisoned strip set blocked regeneration (state: \(model.filmstripState))")
        // 16 regenerated frames — NOT the 3-frame garbage set.
        #expect(readyFrames.count == PreviewFilmstripPlan.defaultFrameCount,
                "got \(readyFrames.count) frames — garbage set served instead of regenerating?")
        #expect(readyFrames.allSatisfy { $0.image.width > 0 })
        // And the path must not have been blacklisted as a failure.
        #expect(!model.filmstripFailedPaths.contains(path))
        #expect(!model.thumbnailFailureStore.isKnownFailure(atPath: path))
    }
}
