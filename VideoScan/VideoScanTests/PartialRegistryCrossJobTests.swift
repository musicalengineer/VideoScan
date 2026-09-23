import Testing
import Foundation
@testable import VideoScan

// MARK: - PartialRegistryCrossJobTests
//
// fix/one-partial-registry (2026-09-22). Combine and Transcode both write
// `<stem>.<8 hex>.vs-partial.<ext>` beside their destination, and each
// sweeps "stale" ones. Before this fix:
//   - Combine's sweep (> 6 h) removed a PAUSED Transcode's partial in a
//     folder both write to — Transcode never registered its partials;
//   - Transcode's sweep (> 24 h) ignored the live registry and removed
//     directories too.
// Now both reserve through PartialFileNaming (reserve ⇒ registered live;
// publish / cleanup ⇒ unregistered), and both sweeps go through ONE
// PartialFileNaming.sweepStale: skip live, exact pattern, regular files
// only, one 24 h threshold, each removal logged with size and job.
//
// All files are `test_` prefixed in a per-test temp dir.

@Suite("Partial registry — cross-job sweeps", .serialized) @MainActor
struct PartialRegistryCrossJobTests {

    static func makeDir(_ purpose: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_partials_\(purpose)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func age(_ url: URL, hours: Double) throws {
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-hours * 3600)],
                                              ofItemAtPath: url.path)
    }

    static func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: Combine sweep vs Transcode partials

    /// The reported bug: a paused Transcode's partial stops getting fresh
    /// mtimes; 7 h later a Combine batch into the same folder removed it.
    @Test func aPausedTranscodePartialOlderThanSixHoursSurvivesACombineSweep() throws {
        let dir = try Self.makeDir("paused_transcode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_x.vs.edit.mov")
        let partial = DerivativeOutputPublish.uniquePartialURL(for: out)
        try Data(count: 2048).write(to: partial)
        try Self.age(partial, hours: 7)

        let result = CombineOutputPublish.sweepStalePartials(in: dir)
        #expect(result.removed.isEmpty, "\(result.removed)")
        #expect(Self.exists(partial), "a 7 h old Transcode partial must survive Combine's sweep")
    }

    /// A Transcode partial reserved through the shared registry survives a
    /// Combine sweep at ANY age while its job runs; released, it is fair game.
    @Test func aLiveTranscodePartialPastTheThresholdSurvivesACombineSweep() throws {
        let dir = try Self.makeDir("live_transcode")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_x.vs.edit.mov")
        let partial = try DerivativeOutputPublish.reservePartial(for: out)
        defer { PartialFileNaming.unregisterLive(partial) }
        #expect(PartialFileNaming.isLive(partial), "reservation registers")
        try Data(count: 4096).write(to: partial)
        try Self.age(partial, hours: 48)

        #expect(CombineOutputPublish.sweepStalePartials(in: dir).removed.isEmpty)
        #expect(Self.exists(partial))

        // Job over (crash leftovers look exactly like this): now swept.
        PartialFileNaming.unregisterLive(partial)
        let after = CombineOutputPublish.sweepStalePartials(in: dir)
        #expect(after.removed == [.init(name: partial.lastPathComponent, sizeBytes: 4096)])
        #expect(!Self.exists(partial))
    }

    // MARK: Transcode sweep vs live partials

    /// Symmetric: Transcode's sweep used to ignore the live registry. A
    /// live partial of the SAME output name (a second job to that name, or
    /// a Combine-style reservation) must survive it at any age.
    @Test func aLivePartialSurvivesATranscodeSweep() throws {
        let dir = try Self.makeDir("live_vs_transcode_sweep")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_x.vs.edit.mov")
        let live = try CombineOutputPublish.reservePartial(for: out)
        defer { PartialFileNaming.unregisterLive(live) }
        try Data(count: 10).write(to: live)
        try Self.age(live, hours: 48)

        let swept = DerivativeOutputPublish.sweepStalePartials(beside: out)
        #expect(swept.isEmpty, "\(swept)")
        #expect(Self.exists(live), "a live partial must survive Transcode's sweep")
    }

    /// Transcode's sweep removes only REGULAR files of the exact pattern.
    @Test func aTranscodeSweepNeverRemovesADirectory() throws {
        let dir = try Self.makeDir("transcode_dir_lookalike")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_x.vs.edit.mov")
        let folderLike = dir.appendingPathComponent("test_x.vs.edit.abcdef12.vs-partial.mov", isDirectory: true)
        try FileManager.default.createDirectory(at: folderLike, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: folderLike.appendingPathComponent("test_inner.txt"))
        try Self.age(folderLike, hours: 48)

        #expect(DerivativeOutputPublish.sweepStalePartials(beside: out).isEmpty)
        #expect(Self.exists(folderLike.appendingPathComponent("test_inner.txt")))
    }

    // MARK: One threshold

    @Test func bothSweepsUseTheOneTwentyFourHourThreshold() throws {
        #expect(PartialFileNaming.staleThreshold == 24 * 3600)
        let dir = try Self.makeDir("threshold")
        defer { try? FileManager.default.removeItem(at: dir) }
        let tOut = dir.appendingPathComponent("test_t.vs.edit.mov")
        let cOut = dir.appendingPathComponent("test_c_combined.mov")

        let tYoung = DerivativeOutputPublish.uniquePartialURL(for: tOut)
        let cYoung = CombineOutputPublish.uniquePartialURL(for: cOut)
        for u in [tYoung, cYoung] { try Data([1]).write(to: u); try Self.age(u, hours: 23) }
        #expect(DerivativeOutputPublish.sweepStalePartials(beside: tOut).isEmpty)
        #expect(CombineOutputPublish.sweepStalePartials(in: dir).removed.isEmpty)
        #expect(Self.exists(tYoung) && Self.exists(cYoung), "23 h: both kept by both sweeps")

        for u in [tYoung, cYoung] { try Self.age(u, hours: 25) }
        #expect(DerivativeOutputPublish.sweepStalePartials(beside: tOut) == [tYoung.lastPathComponent])
        #expect(CombineOutputPublish.sweepStalePartials(in: dir).removed.map(\.name) == [cYoung.lastPathComponent])
        #expect(!Self.exists(tYoung) && !Self.exists(cYoung), "25 h, not live: crash leftovers, removed")
    }

    /// Publishing releases the reservation (so a later sweep can reach a
    /// leftover of the same name) and never leaves the partial live.
    @Test func publishReleasesTheReservation() throws {
        let dir = try Self.makeDir("publish_releases")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_p.vs.edit.mov")
        let partial = try DerivativeOutputPublish.reservePartial(for: out)
        try Data([7]).write(to: partial)
        let outcome = try DerivativeOutputPublish.publish(partial: partial.path, as: out,
                                                          policy: .keep(reason: "test"),
                                                          archiveCheck: nil, trash: { _ in nil })
        #expect(outcome == .published(out))
        #expect(!PartialFileNaming.isLive(partial))
    }

    // MARK: Sensor — Transcode reserves through the registry

    @Test func transcodeReservesAndReleasesThroughTheOneRegistry() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/TranscodeJob.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        #expect(text.contains("DerivativeOutputPublish.reservePartial(for: outputURL)"),
                "Transcode reserves (and so registers) its partial")
        #expect(!text.contains("uniquePartialURL("), "no unregistered partial names in Transcode")
        #expect(text.contains("defer { PartialFileNaming.unregisterLive(partialURL) }"),
                "every exit of the run releases the reservation")
        #expect(!text.contains("removeItem(atPath: partialPath)"),
                "partials are removed through PartialFileNaming.remove (name-guarded, logged)")
    }

    // MARK: QA minors (2026-09-22)

    /// QA 1: a Transcode encode that could not be published is moved OFF
    /// the partial pattern, so no sweep can ever remove it.
    @Test func anUnpublishedTranscodeEncodeIsKeptOffThePartialPattern() throws {
        let dir = try Self.makeDir("keep_unpublished")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_k.vs.edit.mov")
        let partial = try DerivativeOutputPublish.reservePartial(for: out)
        try Data("encode".utf8).write(to: partial)
        let kept = DerivativeOutputPublish.keepUnpublished(partial)
        #expect(kept.lastPathComponent.contains(".vs-kept."), "\(kept.lastPathComponent)")
        #expect(!PartialFileNaming.isPartialName(kept.lastPathComponent))
        #expect(kept.pathExtension == "mov")
        #expect(try Data(contentsOf: kept) == Data("encode".utf8))
        #expect(!Self.exists(partial))
        #expect(!PartialFileNaming.isLive(partial))
        try Self.age(kept, hours: 48)
        #expect(CombineOutputPublish.sweepStalePartials(in: dir).removed.isEmpty)
        #expect(DerivativeOutputPublish.sweepStalePartials(beside: out).isEmpty)
        #expect(Self.exists(kept), "no sweep reaches a kept encode")
    }

    /// QA 1: keeping never overwrites — a taken kept-name leaves the
    /// partial where it is (still named, still reported).
    @Test func keepingNeverOverwritesAnExistingKeptFile() throws {
        let dir = try Self.makeDir("keep_no_clobber")
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("test_k.vs.edit.mov")
        let partial = try DerivativeOutputPublish.reservePartial(for: out)
        defer { PartialFileNaming.unregisterLive(partial) }
        try Data("new".utf8).write(to: partial)
        let taken = dir.appendingPathComponent(partial.lastPathComponent
            .replacingOccurrences(of: ".vs-partial.", with: ".vs-kept."))
        try Data("older".utf8).write(to: taken)
        let kept = DerivativeOutputPublish.keepUnpublished(partial)
        #expect(kept == partial)
        #expect(try Data(contentsOf: taken) == Data("older".utf8))
        #expect(try Data(contentsOf: partial) == Data("new".utf8))
    }

    /// QA 2: the registry matches the FILE (dev + ino), not the spelling
    /// of its path (/var vs /private/var, firmlinks, case).
    @Test func livePartialSurvivesASweepThroughAnAliasedPath() throws {
        let real = URL(fileURLWithPath: (NSTemporaryDirectory() as NSString).resolvingSymlinksInPath)
            .appendingPathComponent("alias-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: real) }
        let partial = try PartialFileNaming.reserve(for: real.appendingPathComponent("clip.mov"))
        defer { PartialFileNaming.unregisterLive(partial) }
        #expect(real.path.hasPrefix("/private/"), "the alias needs a /private path — \(real.path)")
        let alias = URL(fileURLWithPath: String(real.path.dropFirst("/private".count)))
        _ = PartialFileNaming.sweepStale(in: alias, job: "test", olderThan: -1)
        #expect(FileManager.default.fileExists(atPath: partial.path))
    }

    /// QA 3: remove() is unlink(2), never a recursive removal — a directory
    /// swapped in under a partial's name is refused and left intact.
    @Test func removeRefusesADirectoryWearingAPartialName() throws {
        let dir = try Self.makeDir("remove_dir")
        defer { try? FileManager.default.removeItem(at: dir) }
        let swapped = dir.appendingPathComponent("test_s.abcdef12.vs-partial.mov", isDirectory: true)
        try FileManager.default.createDirectory(at: swapped, withIntermediateDirectories: true)
        let inner = swapped.appendingPathComponent("test_inner.txt")
        try Data("keep".utf8).write(to: inner)
        #expect(throws: PartialFileNaming.Failure.self) { try PartialFileNaming.remove(swapped) }
        #expect(Self.exists(inner))
    }

    /// QA 4: the exit-failure branch removes the (reserved) partial too.
    @Test func transcodeExitFailureDiscardsItsPartialAndPublishFailureKeepsTheEncode() throws {
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/TranscodeJob.swift")
        let text = try String(contentsOf: src, encoding: .utf8)
        #expect(!text.contains("No partial at all"), "stale wording: the partial is reserved up front")
        let exitBranch = try #require(text.range(of: "if let failure = FFmpegEncodeCheck.exitFailure("))
        let nextReturn = try #require(text.range(of: "return", range: exitBranch.upperBound..<text.endIndex))
        #expect(text[exitBranch.upperBound..<nextReturn.lowerBound].contains("discardPartial(partialURL)"))
        #expect(text.contains("DerivativeOutputPublish.keepUnpublished(partialURL)"),
                "a failed publish moves the encode off the partial pattern")
        #expect(!text.contains("the encode is at \\(partialPath)"))
    }

    // MARK: Staging dir (VS_<uuid>) on a throwing buffer step

    static func stagingDirs(in base: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: base.path)) ?? []).filter { $0.hasPrefix("VS_") }
    }

    @Test func stagingDirIsRemovedWhenBufferingTheVideoThrows() async throws {
        let base = try Self.makeDir("staging_video_throws")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = VideoScanModel()
        let missing = base.appendingPathComponent("test_missing_video.mov").path
        let audio = base.appendingPathComponent("test_audio.wav")
        try Data(count: 64).write(to: audio)
        await #expect(throws: (any Error).self) {
            try await CombineTestSeams.$isNetworkPath.withValue({ _ in true }) {
                _ = try await model.stageCombineInputs(
                    videoPath: missing, videoFilename: "test_missing_video.mov",
                    audioPath: audio.path, audioFilename: "test_audio.wav",
                    tempBase: base, hasRAMDisk: false)
            }
        }
        #expect(Self.stagingDirs(in: base).isEmpty, "leaked: \(Self.stagingDirs(in: base))")
        #expect(Self.exists(audio), "the source is never touched")
    }

    @Test func stagingDirIsRemovedWhenBufferingTheAudioThrowsAfterTheVideoCopied() async throws {
        let base = try Self.makeDir("staging_audio_throws")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = VideoScanModel()
        let video = base.appendingPathComponent("test_video.mov")
        try Data(count: 128).write(to: video)
        let missing = base.appendingPathComponent("test_missing_audio.wav").path
        await #expect(throws: (any Error).self) {
            try await CombineTestSeams.$isNetworkPath.withValue({ _ in true }) {
                _ = try await model.stageCombineInputs(
                    videoPath: video.path, videoFilename: "test_video.mov",
                    audioPath: missing, audioFilename: "test_missing_audio.wav",
                    tempBase: base, hasRAMDisk: false)
            }
        }
        #expect(Self.stagingDirs(in: base).isEmpty, "leaked: \(Self.stagingDirs(in: base))")
        #expect(Self.exists(video), "the source is never touched")
    }

    /// Success keeps the staging dir for the mux (runMuxAndVerify removes it).
    @Test func stagingDirSurvivesASuccessfulBuffer() async throws {
        let base = try Self.makeDir("staging_ok")
        defer { try? FileManager.default.removeItem(at: base) }
        let model = VideoScanModel()
        let video = base.appendingPathComponent("test_video.mov")
        let audio = base.appendingPathComponent("test_audio.wav")
        try Data(count: 128).write(to: video); try Data(count: 64).write(to: audio)
        let staged = try await CombineTestSeams.$isNetworkPath.withValue({ _ in true }) {
            try await model.stageCombineInputs(
                videoPath: video.path, videoFilename: "test_video.mov",
                audioPath: audio.path, audioFilename: "test_audio.wav",
                tempBase: base, hasRAMDisk: false)
        }
        let tempDir = try #require(staged.tempDir)
        #expect(Self.exists(staged.video) && Self.exists(staged.audio))
        #expect(Self.stagingDirs(in: base) == [tempDir.lastPathComponent])
    }
}
