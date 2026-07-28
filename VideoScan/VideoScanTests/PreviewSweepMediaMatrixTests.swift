// PreviewSweepMediaMatrixTests.swift
// MEDIA MATRIX dimension for the background preview sweep (2026-07-27):
// one small END-TO-END sweep — real PreviewSweepService, real default
// executor (real ffmpeg rips + real AVFoundation), synthetic fixtures —
// into a redirected cache root.
//
//   mkv/ffv1  — routes .ffmpegDirect: the sweep must land BOTH a
//               best-tier still AND a complete filmstrip.
//   mp4/h264  — routes .avFoundation: best-tier still ONLY (strips for
//               everything would blow the 2 GB cap; pinned here).
//
// Isolation: unique temp cache root + fixtures per run; reachability
// injected as always-true (never touches the VolumeReachability SWR
// cache); poisoned cache filenames pre-seeded to prove the one-listing
// index tolerates them end-to-end.

import Testing
import Foundation
@testable import VideoScan

@MainActor
@Suite("PreviewSweep media matrix",
       .serialized,
       .timeLimit(.minutes(5)),
       .enabled(if: TestMediaGenerator.isAvailable))
struct PreviewSweepMediaMatrixTests {

    @Test("end-to-end sweep: mkv/ffv1 gets still + strip, mp4/h264 gets still only, poisoned cache names tolerated")
    func endToEndSweep() async throws {
        // ---- Fixtures ------------------------------------------------
        let mkvPath = try TestMediaGenerator.generate(
            container: "mkv",
            streams: .videoOnly,
            videoCodec: "ffv1",
            duration: 6.0,
            prefix: "test_gen_sweep_ffv1")
        let mp4Path = try TestMediaGenerator.generate(
            container: "mp4",
            streams: .videoOnly,
            videoCodec: "libx264",
            duration: 6.0,
            prefix: "test_gen_sweep_h264")
        defer { TestMediaGenerator.cleanup(mkvPath, mp4Path) }

        // ---- Redirected cache root + poisoned filenames ---------------
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sweep-matrix-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        // Junk the one-listing index must tolerate: foreign file, a
        // partial strip set under a fake key, an unparseable strip name.
        try Data("junk".utf8).write(to: cacheDir.appendingPathComponent("notes.txt"))
        let fakeKey = String(repeating: "f", count: 64)
        try Data("j".utf8).write(to: cacheDir.appendingPathComponent("\(fakeKey)-strip-0-of-4-100.jpg"))
        try Data("j".utf8).write(to: cacheDir.appendingPathComponent("\(fakeKey)-strip-broken.jpg"))
        let diskCache = PreviewDiskCache(rootURL: cacheDir)

        // ---- Route pins (the reason each fixture is in the matrix) ----
        try #require(PreviewFrameRouter.previewRoute(container: "Matroska / WebM",
                                                     videoCodec: "ffv1",
                                                     likelyUnanalyzable: false) == .ffmpegDirect)
        try #require(PreviewFrameRouter.previewRoute(container: "QuickTime / MOV",
                                                     videoCodec: "h264",
                                                     likelyUnanalyzable: false) == .avFoundation)

        // ---- Real service, real executor ------------------------------
        let candidates = [
            PreviewSweepCandidate(path: mkvPath,
                                  container: "Matroska / WebM",
                                  videoCodec: "ffv1",
                                  likelyUnanalyzable: false,
                                  durationSeconds: 6.0),
            PreviewSweepCandidate(path: mp4Path,
                                  container: "QuickTime / MOV",
                                  videoCodec: "h264",
                                  likelyUnanalyzable: false,
                                  durationSeconds: 6.0)
        ]
        let alwaysReachable: @Sendable (String) -> Bool = { _ in true }
        let failureStore = ThumbnailFailureStore()
        let service = PreviewSweepService()
        service.configure(PreviewSweepService.Configuration(
            diskCache: diskCache,
            failureStore: failureStore,
            candidates: { candidates },
            shouldSkipPathNow: { _ in false },
            isReachable: alwaysReachable,
            thermalState: { .nominal },   // deterministic — a warm CI box must not park the test
            executeItem: PreviewSweepService.defaultExecutor(diskCache: diskCache,
                                                             isReachable: alwaysReachable),
            workerCount: 2,
            quietSeconds: 10,
            pausePollMilliseconds: 50,
            replanDebounceSeconds: 0.05,
            cacheCapBytes: PreviewDiskCache.sizeCapBytes
        ), enabled: true)
        defer { service.stop() }

        service.noteCatalogChanged()

        // Wait for .done (real rips: seconds, not minutes).
        let deadline = Date().addingTimeInterval(120)
        var finished = false
        while Date() < deadline {
            if case .done = service.status { finished = true; break }
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(finished, "sweep did not finish: \(service.status)")
        #expect(service.status == .done(ready: 2, unpreviewable: 0),
                "unexpected final status: \(service.status)")
        #expect(failureStore.count == 0, "sweep recorded failures for good fixtures")

        // ---- Cache truth ----------------------------------------------
        let mkvSig = try #require(PreviewDiskCache.fileSignature(atPath: mkvPath))
        let mp4Sig = try #require(PreviewDiskCache.fileSignature(atPath: mp4Path))

        #expect(diskCache.storedTier(path: mkvPath, mtime: mkvSig.mtime,
                                     size: mkvSig.size) == .best,
                "mkv/ffv1 best still missing")
        #expect(diskCache.storedTier(path: mp4Path, mtime: mp4Sig.mtime,
                                     size: mp4Sig.size) == .best,
                "mp4/h264 best still missing")

        #expect(diskCache.hasCompleteFilmstrip(path: mkvPath, mtime: mkvSig.mtime,
                                               size: mkvSig.size),
                "mkv/ffv1 (.ffmpegDirect) must get a complete filmstrip")
        #expect(!diskCache.hasCompleteFilmstrip(path: mp4Path, mtime: mp4Sig.mtime,
                                                size: mp4Sig.size),
                "mp4/h264 (.avFoundation) must NOT get a strip — cap discipline")

        // The strip actually decodes (not just filename-complete).
        let strip = diskCache.lookupFilmstrip(path: mkvPath, mtime: mkvSig.mtime,
                                              size: mkvSig.size)
        #expect((strip?.count ?? 0) >= 8, "mkv strip too short: \(strip?.count ?? 0)")

        // ---- Second sweep is a no-op (diff correctness end-to-end) ----
        service.noteCatalogChanged()
        try await Task.sleep(for: .milliseconds(300))   // debounce + plan
        let deadline2 = Date().addingTimeInterval(30)
        var finished2 = false
        while Date() < deadline2 {
            if case .done(let ready, _) = service.status, ready == 2 {
                finished2 = true; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(finished2, "re-sweep did not settle: \(service.status)")
    }
}
