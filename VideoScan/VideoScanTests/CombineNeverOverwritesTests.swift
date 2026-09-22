import Testing
import Foundation
@testable import VideoScan

// MARK: - CombineNeverOverwritesTests
//
// Regression net for the 2026-09-22 audit finding: processCombinePair
// checked "does <video>_combined.mov exist?", then staged inputs (can take
// minutes), then ffmpeg wrote DIRECTLY to that final name with `-y`, and
// the failure / verify-failure paths called removeItem on the final name.
// Two pairs whose videos share a base name (different source folders, one
// output folder) — or anything else that created the name in the gap —
// could be overwritten or deleted.
//
// The contract pinned here:
//   • ffmpeg writes a unique partial beside the destination;
//   • success + verify → publish with RENAME_EXCL; name taken → "name 2.mov";
//   • failure / verify failure / cancel remove ONLY our own partial;
//   • the catalog record carries the name actually published.
//
// Fixtures are synthetic (ffmpeg lavfi), `test_` prefixed, in a per-test
// temp dir. Media matrix: mov/ProRes video + wav/PCM audio, and an Avid-
// style pair (OP1a MPEG-2 video-only MXF + OP-Atom PCM audio-only MXF).

@Suite(.serialized) @MainActor
struct CombineNeverOverwritesTests {

    enum Kind: String, CaseIterable, Sendable, CustomStringConvertible {
        case movProRes
        case mxfPair
        var description: String { rawValue }
    }

    struct Pair {
        let video: VideoRecordSnapshot
        let audio: VideoRecordSnapshot
    }

    // MARK: - Fixture helpers

    static func makeDir(_ purpose: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_combine_never_overwrites_\(purpose)_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func ffmpeg(_ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ToolLocator.ffmpegPath)
        proc.arguments = ["-hide_banner", "-loglevel", "error", "-y"] + args
        proc.standardOutput = FileHandle.nullDevice
        let err = Pipe()
        proc.standardError = err
        try proc.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "test_combine", code: Int(proc.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "ffmpeg failed: \((String(bytes: errData, encoding: .utf8) ?? "<non-UTF-8 stderr>"))"
            ])
        }
    }

    static func record(path: URL, streamType: StreamType, videoCodec: String = "",
                       audioCodec: String = "", seconds: Double, group: UUID?) -> VideoRecord {
        let r = VideoRecord()
        r.filename = path.lastPathComponent
        r.fullPath = path.path
        r.directory = path.deletingLastPathComponent().path
        r.ext = path.pathExtension.lowercased()
        r.streamTypeRaw = streamType.rawValue
        r.videoCodec = videoCodec
        r.audioCodec = audioCodec
        r.durationSeconds = seconds
        r.pairGroupID = group
        return r
    }

    /// A video-only + audio-only pair named `<stem>.<ext>` in `dir`.
    /// `seconds` differs between pairs so each output can be traced to its
    /// source by duration alone.
    static func makePair(_ kind: Kind, in dir: URL, stem: String, seconds: Int,
                         group: UUID = UUID()) throws -> Pair {
        let videoURL: URL
        let audioURL: URL
        let videoCodec: String
        switch kind {
        case .movProRes:
            videoURL = dir.appendingPathComponent("\(stem).mov")
            audioURL = dir.appendingPathComponent("\(stem)_audio.wav")
            videoCodec = "prores"
            try ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=320x240:rate=25",
                        "-an", "-c:v", "prores_ks", "-profile:v", "0", videoURL.path])
            try ffmpeg(["-f", "lavfi", "-i", "sine=duration=\(seconds):sample_rate=48000",
                        "-c:a", "pcm_s16le", audioURL.path])
        case .mxfPair:
            videoURL = dir.appendingPathComponent("\(stem).mxf")
            audioURL = dir.appendingPathComponent("\(stem)_A1.mxf")
            videoCodec = "mpeg2video"   // not MOV-stream-copy-safe → ProRes re-encode path
            try ffmpeg(["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=720x576:rate=25",
                        "-an", "-c:v", "mpeg2video", "-pix_fmt", "yuv422p", "-b:v", "5M", videoURL.path])
            try ffmpeg(["-f", "lavfi", "-i", "sine=duration=\(seconds):sample_rate=48000",
                        "-ac", "1", "-c:a", "pcm_s16le", "-f", "mxf_opatom", audioURL.path])
        }
        let v = record(path: videoURL, streamType: .videoOnly, videoCodec: videoCodec,
                       seconds: Double(seconds), group: group)
        let a = record(path: audioURL, streamType: .audioOnly, audioCodec: "pcm_s16le",
                       seconds: Double(seconds), group: group)
        return Pair(video: v.snapshot(), audio: a.snapshot())
    }

    /// Register a dashboard job so processCombinePair reads the expected
    /// duration (verify compares against it) and the technique.
    static func addJob(_ model: VideoScanModel, pair: Pair, outputFolder: URL,
                       expectedDuration: Double) -> Int {
        let idx = model.dashboard.combineJobs.count
        let base = URL(fileURLWithPath: pair.video.fullPath).deletingPathExtension().lastPathComponent
        model.dashboard.combineTotal += 1
        model.dashboard.combineJobs.append(CombineJobStatus(
            pairIndex: idx,
            videoFilename: pair.video.filename,
            audioFilename: pair.audio.filename,
            outputFilename: "\(base)_combined.mov",
            outputPath: outputFolder.appendingPathComponent("\(base)_combined.mov").path,
            videoSizeBytes: 0, audioSizeBytes: 0,
            totalDurationSeconds: expectedDuration,
            videoOnline: true, audioOnline: true,
            technique: .streamCopy
        ))
        return idx
    }

    static func run(_ model: VideoScanModel, _ pair: Pair, into out: URL,
                    expectedDuration: Double? = nil) async -> Bool {
        let job = addJob(model, pair: pair, outputFolder: out,
                         expectedDuration: expectedDuration ?? pair.video.durationSeconds)
        return await model.processCombinePair(
            video: pair.video, audio: pair.audio, outputFolder: out,
            tempBase: FileManager.default.temporaryDirectory, hasRAMDisk: false,
            jobIndex: job
        )
    }

    static func probeDuration(_ url: URL) -> Double? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ToolLocator.ffprobePath)
        proc.arguments = ["-v", "error", "-show_entries", "format=duration",
                          "-of", "default=nw=1:nk=1", url.path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return (String(bytes: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(Double.init)
    }

    static func names(in dir: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
    }

    static func partials(in dir: URL) -> [String] {
        names(in: dir).filter { $0.contains("vs-partial") }
    }

    static let sentinel = Data("test_sentinel — a file that was here first; Combine must never touch it\n".utf8)

    static var toolsPresent: Bool {
        FileManager.default.isExecutableFile(atPath: ToolLocator.ffmpegPath)
            && FileManager.default.isExecutableFile(atPath: ToolLocator.ffprobePath)
    }

    // MARK: - Same base name, one output folder

    @Test(arguments: Kind.allCases)
    func sameBaseName_twoPairs_oneFolder_bothOutputsKept(_ kind: Kind) async throws {
        try #require(Self.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try Self.makeDir("same_base_\(kind)")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcA = root.appendingPathComponent("srcA"), srcB = root.appendingPathComponent("srcB")
        let out = root.appendingPathComponent("out")
        for d in [srcA, srcB, out] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let pairA = try Self.makePair(kind, in: srcA, stem: "test_clip", seconds: 2)
        let pairB = try Self.makePair(kind, in: srcB, stem: "test_clip", seconds: 4)

        let model = VideoScanModel()
        let okA = await Self.run(model, pairA, into: out)
        let okB = await Self.run(model, pairB, into: out)
        #expect(okA && okB)

        let first = out.appendingPathComponent("test_clip_combined.mov")
        let second = out.appendingPathComponent("test_clip_combined 2.mov")
        let d1 = Self.probeDuration(first)
        let d2 = Self.probeDuration(second)
        #expect(d1.map { abs($0 - 2) < 0.5 } == true, "first output should be pair A's (2s); got \(String(describing: d1)) — \(Self.names(in: out))")
        #expect(d2.map { abs($0 - 4) < 0.5 } == true, "second output should be pair B's (4s) beside it; got \(String(describing: d2)) — \(Self.names(in: out))")
        #expect(Self.partials(in: out).isEmpty, "partials left behind: \(Self.partials(in: out))")
        #expect(model.dashboard.combineSucceeded == 2)

        // The catalog carries the names actually published.
        let paths = Set(model.records.filter { $0.combinedFromPairID != nil }.map(\.fullPath))
        #expect(paths == [first.path, second.path], "catalog paths: \(paths)")
        // …and the dashboard job reports them too.
        let jobPaths = Set(model.dashboard.combineJobs.map(\.outputPath))
        #expect(jobPaths == [first.path, second.path], "job paths: \(jobPaths)")
    }

    @Test func sameBaseName_concurrentPairs_neverShareANameOrPartial() async throws {
        try #require(Self.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try Self.makeDir("concurrent")
        defer { try? FileManager.default.removeItem(at: root) }
        let srcA = root.appendingPathComponent("srcA"), srcB = root.appendingPathComponent("srcB")
        let out = root.appendingPathComponent("out")
        for d in [srcA, srcB, out] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }

        let pairA = try Self.makePair(.movProRes, in: srcA, stem: "test_clip", seconds: 2)
        let pairB = try Self.makePair(.movProRes, in: srcB, stem: "test_clip", seconds: 4)

        let model = VideoScanModel()
        let jobA = Self.addJob(model, pair: pairA, outputFolder: out, expectedDuration: 2)
        let jobB = Self.addJob(model, pair: pairB, outputFolder: out, expectedDuration: 4)
        let tmp = FileManager.default.temporaryDirectory
        async let okA = model.processCombinePair(video: pairA.video, audio: pairA.audio, outputFolder: out,
                                                 tempBase: tmp, hasRAMDisk: false, jobIndex: jobA)
        async let okB = model.processCombinePair(video: pairB.video, audio: pairB.audio, outputFolder: out,
                                                 tempBase: tmp, hasRAMDisk: false, jobIndex: jobB)
        let results = await [okA, okB]
        #expect(results == [true, true])

        let outs = Self.names(in: out)
        #expect(outs == ["test_clip_combined 2.mov", "test_clip_combined.mov"], "outputs: \(outs)")
        let durations = outs.compactMap { Self.probeDuration(out.appendingPathComponent($0)) }
            .map { $0.rounded() }.sorted()
        #expect(durations == [2, 4], "each pair's output must survive intact: \(durations)")
    }

    // MARK: - A file already at (or appearing at) the final name

    @Test func preExistingFinal_isUntouched_andOutputPublishedBeside() async throws {
        try #require(Self.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try Self.makeDir("pre_existing")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pair = try Self.makePair(.movProRes, in: root, stem: "test_clip", seconds: 2)
        let final = out.appendingPathComponent("test_clip_combined.mov")
        try Self.sentinel.write(to: final)

        let model = VideoScanModel()
        let ok = await Self.run(model, pair, into: out)
        #expect(ok)
        #expect(try Data(contentsOf: final) == Self.sentinel, "pre-existing file was modified")
        let beside = out.appendingPathComponent("test_clip_combined 2.mov")
        #expect(Self.probeDuration(beside).map { abs($0 - 2) < 0.5 } == true,
                "new output should be published beside: \(Self.names(in: out))")
        #expect(model.records.last?.fullPath == beside.path)
        #expect(Self.partials(in: out).isEmpty)
    }

    @Test func ffmpegFailure_leavesFileAtFinalName_untouched() async throws {
        try #require(Self.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try Self.makeDir("ffmpeg_fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let good = try Self.makePair(.movProRes, in: root, stem: "test_clip", seconds: 2)
        // Audio half is not media at all → ffmpeg exits non-zero.
        let badAudio = root.appendingPathComponent("test_clip_bad.wav")
        try Data("not audio".utf8).write(to: badAudio)
        let pair = Pair(video: good.video,
                        audio: Self.record(path: badAudio, streamType: .audioOnly, audioCodec: "pcm_s16le",
                                           seconds: 2, group: good.video.pairGroupID).snapshot())
        let final = out.appendingPathComponent("test_clip_combined.mov")

        let model = VideoScanModel()
        // Something else lands at the final name AFTER the pre-check —
        // exactly the audit's window (e.g. a same-named pair publishing).
        let sentinel = Self.sentinel
        let ok = await CombineTestSeams.$beforeMux.withValue({ destination, _ in
            try? sentinel.write(to: destination)
        }) {
            await Self.run(model, pair, into: out)
        }
        #expect(!ok)
        #expect((try? Data(contentsOf: final)) == Self.sentinel, "failure path deleted/overwrote a file it did not create")
        #expect(Self.partials(in: out).isEmpty, "partial left behind: \(Self.partials(in: out))")
        #expect(Self.names(in: out) == ["test_clip_combined.mov"])
    }

    @Test func verifyFailure_removesOnlyThePartial() async throws {
        try #require(Self.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try Self.makeDir("verify_fail")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pair = try Self.makePair(.movProRes, in: root, stem: "test_clip", seconds: 2)
        let final = out.appendingPathComponent("test_clip_combined.mov")

        let model = VideoScanModel()
        let sentinel = Self.sentinel
        // Expected 100 s vs a 2 s mux → CombineVerifier reports a duration mismatch.
        let ok = await CombineTestSeams.$beforeMux.withValue({ destination, _ in
            try? sentinel.write(to: destination)
        }) {
            await Self.run(model, pair, into: out, expectedDuration: 100)
        }
        #expect(!ok)
        #expect(model.dashboard.combineFailed == 1)
        #expect((try? Data(contentsOf: final)) == Self.sentinel, "verify-failure path deleted/overwrote a file it did not create")
        #expect(Self.names(in: out) == ["test_clip_combined.mov"], "only the sentinel may remain: \(Self.names(in: out))")
        #expect(!model.records.contains { $0.combinedFromPairID != nil }, "an unverified output must not be catalogued")
    }

    // MARK: - Re-run after Stop

    @Test func rerun_pairAlreadyCombinedHere_isSkipped_notDuplicated() async throws {
        try #require(Self.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try Self.makeDir("rerun")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pair = try Self.makePair(.movProRes, in: root, stem: "test_clip", seconds: 2)

        let model = VideoScanModel()
        #expect(await Self.run(model, pair, into: out))
        let prior = VideoScanModel.priorCombinedOutputs(records: model.records, outputFolder: out)
        let priorPath = try #require(pair.video.pairGroupID.flatMap { prior[$0] })

        let job = Self.addJob(model, pair: pair, outputFolder: out, expectedDuration: 2)
        let ok = await model.processCombinePair(
            video: pair.video, audio: pair.audio, outputFolder: out,
            tempBase: FileManager.default.temporaryDirectory, hasRAMDisk: false,
            jobIndex: job, priorOutputPath: priorPath)
        #expect(ok)
        #expect(model.dashboard.combineSkipped == 1)
        #expect(Self.names(in: out) == ["test_clip_combined.mov"])
    }

    // MARK: - Cancel

    @Test func cancelDuringMux_leavesNoPartial_andPublishesNothing() async throws {
        try #require(Self.toolsPresent, "ffmpeg/ffprobe not found")
        let root = try Self.makeDir("cancel")
        defer { try? FileManager.default.removeItem(at: root) }
        let out = root.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let pair = try Self.makePair(.movProRes, in: root, stem: "test_clip", seconds: 2)

        let model = VideoScanModel()
        let task = Task { @MainActor in
            await CombineTestSeams.$beforeMux.withValue({ _, writeTarget in
                // A half-written output exists, then the user presses Stop.
                try? Data("half-written".utf8).write(to: writeTarget)
                withUnsafeCurrentTask { $0?.cancel() }
            }) {
                await Self.run(model, pair, into: out)
            }
        }
        let ok = await task.value
        #expect(!ok)
        #expect(Self.names(in: out).isEmpty, "cancel must leave nothing behind: \(Self.names(in: out))")
    }
}
