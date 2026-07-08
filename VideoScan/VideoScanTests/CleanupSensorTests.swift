// CleanupSensorTests.swift
// SENSOR dimension for Clean Up Video (feature-test checklist item 5):
// regression sensors pinning the feature's safety-critical invariants so
// a future change that weakens them breaks LOUDLY.
//
//   (a) ORIGINAL NEVER MODIFIED — full REAL-engine job on the longest
//       fixture this suite generates (4 s interlaced NTSC h264); SHA-256
//       of the source is byte-identical before and after, mtime included.
//   (b) ATOMIC PUBLISH — `<stem>_cleaned.mov` never exists in the
//       destination directory until it is complete. Pinned two ways:
//       the `.vs-partial` sibling naming convention (same directory ⇒
//       same volume ⇒ metadata-only rename), and a mid-render probe via
//       the stub engine proving the destination directory contains ONLY
//       the source while rendering, plus no partial debris afterwards.
//   (c) LEGACY CATALOG JSON round-trips byte-identical without the new
//       provenance keys — extension of the existing checked-in golden in
//       CatalogStoreAsyncSaveTests (see legacyGoldenRoundTrip there; the
//       golden constants predate the cleanup fields, which makes them a
//       true legacy-catalog fixture).

import Testing
import Foundation
@testable import VideoScan

@Suite(.serialized) @MainActor
struct CleanupSensorTests {

    // MARK: - (a) Original byte-identical after a full REAL job

    @Test("the original file is byte-identical (sha256 + mtime) after a full real-engine job",
          .timeLimit(.minutes(2)))
    func originalUntouchedAfterFullRealJob() async throws {
        try #require(CleanupTestMedia.toolsAvailable,
                     "ffmpeg/ffprobe are required project dependencies")
        let dir = try CleanupTestMedia.makeScratchDir("sensor_orig")
        defer { try? FileManager.default.removeItem(at: dir) }

        // Longest fixture in the cleanup suite: 4 s interlaced NTSC-shaped
        // h264 — the closest small analogue of a real VHS capture.
        let srcPath = try CleanupTestMedia.generate(
            into: dir,
            name: "test_sensor_tape.mp4",
            duration: 4.0,
            size: "720x480", rate: "30000/1001",
            videoCodec: "libx264",
            extraVideoArgs: ["-flags", "+ilme+ildct", "-x264opts", "tff=1"],
            audioCodec: "aac")
        let before = try CleanupTestMedia.fingerprint(srcPath)

        let model = VideoScanModel()
        // durationSeconds 0 keeps the scratch estimate at 0 → system temp;
        // tests must never mount a real RAM disk. The REAL engine doesn't
        // consult duration except for progress fractions.
        let source = makeCleanupSourceRecord(path: srcPath,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")
        model.records = [source]

        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model)   // default = real CleanupFFmpegEngine
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("real-engine job did not finish: \(job.state)")
            return
        }

        // THE sensor: source bytes and mtime untouched.
        let after = try CleanupTestMedia.fingerprint(srcPath)
        #expect(after.sha256 == before.sha256,
                "ORIGINAL FILE BYTES CHANGED during cleanup — this must never happen")
        #expect(after == before,
                "Original's size/mtime changed during cleanup: \(before) → \(after)")

        // And the output really is the recipe's product.
        #expect(FileManager.default.fileExists(atPath: job.outputURL.path))
        let outProbe = try CleanupTestMedia.probe(job.outputURL.path)
        #expect(outProbe.video?.codec_name == "prores")
        #expect(outProbe.video?.profile == "LT")
        #expect(outProbe.video?.field_order == "progressive")
        #expect(outProbe.audio?.codec_name == "aac", "audio must be stream-copied")

        // Catalog got exactly one new record, fully provenance-stamped.
        #expect(model.records.count == 2)
        let published = model.records.last
        #expect(published?.derivedFrom == source.id)
        #expect(published?.cleanupRecipeID == "vhs-quick-clean")
        #expect(published?.cleanupRecipeVersion == 1)
    }

    // MARK: - (b) Atomic publish: final name never exists early

    @Test("the partial-name convention keeps in-flight output out of the final name, same directory")
    func partialNamingConventionPinned() {
        // CleanupJob publishes through ReformatJob.partialURL/atomicPublish.
        // Pin the exact convention for a cleaned output so a rename or a
        // cross-directory "optimization" (which would break same-volume
        // rename atomicity) fails here.
        let final = URL(fileURLWithPath: "/Volumes/Tapes/1998/thanksgiving_cleaned.mov")
        let partial = ReformatJob.partialURL(for: final)
        #expect(partial.lastPathComponent == "thanksgiving_cleaned.vs-partial.mov")
        #expect(partial.deletingLastPathComponent() == final.deletingLastPathComponent(),
                "Partial must be a SIBLING of the final name — same directory, same volume, atomic rename")
    }

    @Test("<stem>_cleaned.mov does not exist in the destination during render, and no partial survives")
    func finalNameNeverExistsMidRender() async throws {
        let dir = try CleanupTestMedia.makeScratchDir("sensor_atomic")
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = try TestMediaGenerator.generate(
            container: "mp4", streams: .videoAndAudio, duration: 2.0,
            prefix: "test_cleanup_atomic")
        let ownedSrc = dir.appendingPathComponent("test_atomic_src.mp4").path
        try FileManager.default.moveItem(atPath: src, toPath: ownedSrc)

        let model = VideoScanModel()
        let source = makeCleanupSourceRecord(path: ownedSrc,
                                             durationSeconds: 0,
                                             fieldOrder: "tt")
        model.records = [source]

        // Mid-render observation: while the engine is rendering, the
        // destination directory must contain ONLY the source — no final
        // name, no partial, nothing.
        struct MidRenderView { var entries: [String] = []; var sawRender = false }
        let observed = CleanupObservationBox(MidRenderView())
        let destDir = dir.path
        var stub = StubCleanupEngine()
        stub.onRender = { _, _ in
            let entries = (try? FileManager.default
                .contentsOfDirectory(atPath: destDir)) ?? []
            observed.mutate { $0.entries = entries; $0.sawRender = true }
        }

        let job = CleanupJob(record: source,
                             recipe: CleanupRecipeRegistry.vhsQuickClean,
                             model: model,
                             engine: stub)
        let finalName = job.outputURL.lastPathComponent
        job.start()
        await job.task?.value

        guard case .finished = job.state else {
            Issue.record("job did not finish: \(job.state)")
            return
        }
        let mid = observed.value
        #expect(mid.sawRender, "stub engine never rendered")
        #expect(!mid.entries.contains(finalName),
                "\(finalName) existed in the destination DURING the render — atomic-publish invariant broken")
        #expect(!mid.entries.contains { $0.contains(".vs-partial") },
                "a .vs-partial existed in the destination during the render (publish must start only after the render completes)")
        #expect(mid.entries == ["test_atomic_src.mp4"],
                "destination directory must hold ONLY the source mid-render; saw \(mid.entries)")

        // After completion: the final exists, and no partial debris.
        let after = try FileManager.default.contentsOfDirectory(atPath: destDir)
        #expect(after.contains(finalName))
        #expect(!after.contains { $0.contains(".vs-partial") },
                "partial file left behind after publish: \(after)")
    }
}
