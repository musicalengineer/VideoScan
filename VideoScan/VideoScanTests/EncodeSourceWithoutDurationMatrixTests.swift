// EncodeSourceWithoutDurationMatrixTests.swift — the rule for a SOURCE whose
// length cannot be read (2026-11-21, refining GH #502): strict where
// something destructive rests on the comparison, a plain note where not.
//
// THE BUG this refines. GH #502 made "a length could not be read" a failed
// job for every verb. For the OUTPUT that is the point. For the SOURCE it
// was too strict: real sources (elementary streams, damaged or odd
// containers) have no container duration, and refusing to make ANY
// derivative of them was a capability regression.
//
// The rule, row by row:
//   1. The source is MEASURED by a fallback chain when the container has no
//      duration: the longest stream duration, then a packet count ÷ frame
//      rate (only when ffprobe's two frame rates agree — refuse rather than
//      guess). A length found that way is compared exactly as before.
//   2. The source has NO measurable length:
//      • without Replace (plain Transcode, Reformat, Cleanup): the output is
//        verified on its own terms (measurable, ≥ 10 KB), published, and the
//        row + OUTCOME line carry "Length not compared: the source has no
//        readable duration.";
//      • with Replace: REFUSED — "Could not verify the new file against the
//        original: the source has no readable duration — the original was
//        not replaced" — except Preservation + Replace whose frame-MD5
//        proof passed (a content proof is stronger than a length compare).
//   3. An OUTPUT that cannot be measured at all is a failed job in every
//      mode (GH #502, unchanged) — but it too is measured by the chain.
// "No readable duration" is said only when ffprobe RAN and answered that
// there is none; a probe that crashed, hung or could not start is still
// "could not be read" and still fails (those rows are in the #500/#502
// matrices).
//
// ffmpeg and ffprobe are answered by a strict ScriptedExecutor; two rows at
// the end measure REAL elementary streams made with ffmpeg. Parallel by
// design. Memory: blobs of tens of KB; two 2 s clips.

import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

@Suite("Encode check — a source with no readable duration: a note without Replace, a refusal with it (GH #502 refined)", .timeLimit(.minutes(2)))
@MainActor
struct EncodeSourceWithoutDurationMatrixTests {

    typealias MX = TranscodeReplaceNegativeMatrixTests
    typealias Behaviour = ScriptedExecutor.Behaviour
    let mx = MX()

    /// What ffprobe answers for a duration it does not have.
    nonisolated static let noDuration = Behaviour.output(stdout: "N/A\n")
    /// What ffprobe answers when there is no such stream.
    nonisolated static let nothing = Behaviour.output(stdout: "")
    nonisolated static let twelve = Behaviour.output(stdout: "12.000000\n")
    nonisolated static func packets(_ count: Int, r: String = "25/1", avg: String = "25/1") -> Behaviour {
        .output(stdout: "r_frame_rate=\(r)\navg_frame_rate=\(avg)\nnb_read_packets=\(count)\n")
    }

    static let note = "Length not compared: the source has no readable duration."
    static let refusal = "Could not verify the new file against the original: the source has no readable duration — the original was not replaced."

    /// One probe chain: container, streams, packets.
    struct Probes: Sendable {
        var format: Behaviour
        var streams: Behaviour = EncodeSourceWithoutDurationMatrixTests.noDuration
        var packets: Behaviour = EncodeSourceWithoutDurationMatrixTests.nothing
        static let none = Probes(format: EncodeSourceWithoutDurationMatrixTests.noDuration)
        static let twelveSeconds = Probes(format: EncodeSourceWithoutDurationMatrixTests.twelve)
    }

    /// The length probes of one file (told apart by `name`), strict.
    static func probeRules(_ mock: ScriptedExecutor, file name: String, _ p: Probes) -> ScriptedExecutor {
        mock.on("ffprobe", containing: ["format=duration", name], p.format)
            .on("ffprobe", containing: ["stream=duration", name], p.streams)
            .on("ffprobe", containing: ["nb_read_packets", name], p.packets)
    }

    func transcodeMock(_ b: MX.Bench, source: Probes = .none, output: Probes = .twelveSeconds) throws -> ScriptedExecutor {
        var m = ScriptedExecutor(claiming: [b.sb.root.path])
            .on("ffmpeg", containing: [MX.sourceName], .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
        m = Self.probeRules(m, file: MX.sourceName, source)
        m = Self.probeRules(m, file: ".vs-partial.", output)
        return try m.on("ffprobe", containing: ["-show_streams"], .output(stdout: MX.h264ProbeJSON()))
    }

    func beside(_ b: MX.Bench) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: b.outDir.path)) ?? ["unreadable"]).sorted()
    }

    // MARK: - Rule 2, without Replace: published, with the note

    @Test("plain Transcode of a source with no readable duration: the measurable output is published and catalogued, and the row + OUTCOME carry the note")
    func aPlainTranscodeIsPublishedWithTheNote() async throws {
        let b = try mx.bench("nodur_plain"); defer { b.sb.cleanup() }
        let m = try transcodeMock(b)
        let job = await mx.run(b, m, replace: false)
        guard case .finished(let summary) = job.state else { Issue.record("a source with no duration could not be transcoded at all: \(job.state)"); return }
        #expect(summary.hasPrefix("Transcoded → "), "\(summary)")
        #expect(summary.contains(Self.note), "the row must say the length was not compared: \(summary)")
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title, state: job.state, wasRefused: job.wasRefused)
        #expect(outcome?.contains(Self.note) == true, "OUTCOME: \(outcome ?? "nil")")
        #expect(b.trashed.all.isEmpty && MX.sha(b.target) == b.priorSHA, "the existing file was touched")
        #expect(b.model.records.first { $0.fullPath == job.publishedURL.path }?.derivedFrom == b.source.id)
        #expect(b.partials().isEmpty)
        // The output WAS measured (its own terms), and the source was asked all three ways.
        #expect(m.calls(to: "ffprobe", containing: ["format=duration", ".vs-partial."]).count == 1)
        #expect(m.calls(to: "ffprobe", containing: ["stream=duration", MX.sourceName]).count == 1, "\(m.calls)")
        #expect(m.calls(to: "ffprobe", containing: ["nb_read_packets", MX.sourceName]).count == 1, "\(m.calls)")
    }

    @Test("Reformat of a source with no readable duration: published, catalogued, with the note")
    func aReformatIsPublishedWithTheNote() async throws {
        let rf = ReformatUnverifiedOutputMatrixTests()
        let b = try rf.bench("nodur"); defer { b.sb.cleanup() }
        let name = ReformatUnverifiedOutputMatrixTests.sourceName
        var m = ScriptedExecutor(claiming: [b.sb.root.path])
            .on("ffmpeg", containing: [name], .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
        m = Self.probeRules(m, file: name, .none)
        m = Self.probeRules(m, file: ".vs-partial.", .twelveSeconds)
        m = try m.on("ffprobe", containing: ["-show_streams"], .output(stdout: MX.h264ProbeJSON()))
        let job = await rf.run(b, m)
        guard case .finished(let summary) = job.state else { Issue.record("a source with no duration could not be reformatted at all: \(job.state)"); return }
        #expect(summary.hasPrefix("Reformatted → \(job.publishedURL.lastPathComponent)"), "\(summary)")
        #expect(summary.contains(Self.note), "\(summary)")
        #expect(job.subtitle == summary)
        #expect(b.model.records.first { $0.fullPath == job.publishedURL.path }?.derivedFrom == b.source.id)
    }

    @Test("Clean Up Video of a source with no readable duration: the measurable render is returned for publishing")
    func aCleanupRenderIsReturned() async throws {
        typealias CL = CleanupUnverifiedRenderMatrixTests
        let b = try CL.bench("nodur"); defer { b.cleanup() }
        var m = ScriptedExecutor(claiming: [b.dir.path])
            .on("ffmpeg", containing: [CL.sourceName, "cleanup-render"], .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
        m = Self.probeRules(m, file: "cleanup-render", Probes(format: .output(stdout: "60.000000\n")))
        m = Self.probeRules(m, file: CL.sourceName, .none)
        let notes = MX.Box<String>()
        let sink = InMemoryLogSink()
        do {
            let url = try await withAppLog(sink) {
                try await m.scoped {
                    try await CleanupFFmpegEngine().render(recipe: CleanupRecipeRegistry.vhsQuickClean, source: b.source, scratchDirectory: b.scratch,
                                                           progress: { beat in if let note = beat.note { notes.set(note) } })
                }
            }
            #expect(FileManager.default.fileExists(atPath: url.path))
        } catch {
            Issue.record("a source with no duration could not be cleaned at all: \(error)")
        }
        // The engine hands the job the note (a progress beat), and the job's summary appends it.
        #expect(notes.value == Self.note, "\(notes.value ?? "no note")")
        #expect(sink.lines.contains { $0.hasPrefix("cleanup: \(CL.sourceName) has no readable duration") }, "\(sink.lines)")
        let job = try SourceTree.appSource(named: "CleanupJob.swift")
        #expect(job.contains("resultNote.record(beat)"))
        #expect(job.contains("Original untouched.\\(resultNote.suffix)\")"), "the Cleanup row does not carry the engine's note")
        let carried = CleanupResultNote()
        #expect(carried.suffix == "")
        carried.record(CleanupProgress(phase: "x", fraction: 0.5))
        carried.record(CleanupProgress(phase: "x", fraction: 1, note: Self.note))
        carried.record(CleanupProgress(phase: "x", fraction: 1))
        #expect(carried.suffix == " " + Self.note, "an ordinary beat must not erase the note")
    }

    // MARK: - Rule 2, with Replace: refused — except a Preservation master whose proof passed

    @Test("Transcode + Replace of a source with no readable duration: REFUSED — nothing to verify the new file against; the original is untouched, the new file removed")
    func aReplaceIsRefused() async throws {
        let b = try mx.bench("nodur_replace"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try transcodeMock(b)
        let job = await mx.run(b, m)
        mx.expectRefused(b, job, catalogBefore: before, reason: [Self.refusal])
        guard case .failed(let message) = job.state else { return }
        #expect(message.hasPrefix(Self.refusal), "\(message)")
        #expect(message.contains("\(b.target.lastPathComponent) was not moved or changed; the unverified new file was removed."), "\(message)")
        #expect(message.count < 900 && job.subtitle == message)
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title, state: job.state, wasRefused: job.wasRefused)
        #expect(outcome == "transcode FAILED: \(MX.sourceName) — \(message)")
        #expect(beside(b) == [b.target.lastPathComponent], "\(beside(b))")
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty)
    }

    /// The preservation script: the proof's decodes, then the encode, then the probes.
    func preservationMock(_ b: MX.Bench, masterVideo: Behaviour) throws -> ScriptedExecutor {
        typealias P = TranscodePreservationProofMatrixTests
        var m = ScriptedExecutor(claiming: [b.sb.root.path])
            .on("ffmpeg", containing: ["framemd5", MX.sourceName], P.threeGoodFrames)
            .on("ffmpeg", containing: ["framemd5"], masterVideo)
            .on("ffmpeg", containing: ["-vn"], P.audio(P.hashA))
            .on("ffmpeg", containing: [MX.sourceName], .writeOutputFile(Data(repeating: 0x5A, count: 20_000)))
        m = Self.probeRules(m, file: MX.sourceName, .none)
        m = Self.probeRules(m, file: ".vs-partial.", .twelveSeconds)
        return try m.on("ffprobe", containing: ["bits_per_raw_sample"], .output(stdout: "bits_per_raw_sample=24\nsample_fmt=s32\n"))
            .on("ffprobe", containing: ["-show_streams"], .output(stdout: MX.h264ProbeJSON()))
    }

    @Test("Preservation + Replace of a source with no readable duration: the frame-MD5 proof PASSES, so the replace proceeds — a content proof is stronger than a length compare")
    func aProvenMasterStillReplaces() async throws {
        typealias P = TranscodePreservationProofMatrixTests
        let b = try mx.bench("nodur_proof_ok", preset: .preservation); defer { b.sb.cleanup() }
        let m = try preservationMock(b, masterVideo: P.threeGoodFrames)
        let job = await mx.run(b, m, preset: .preservation)
        guard case .finished(let summary) = job.state else { Issue.record("a proven master was refused: \(job.state)"); return }
        #expect(summary.hasPrefix("✓ Verified bit-exact lossless (frame MD5) → \(b.target.lastPathComponent)"), "\(summary)")
        #expect(b.trashed.all == [b.target.path])
        #expect(MX.sha(b.fakeTrash.appendingPathComponent(b.target.lastPathComponent)) == b.priorSHA)
        #expect(b.model.records.first { $0.fullPath == b.target.path }?.derivedFrom == b.source.id)
    }

    @Test("Preservation + Replace of a source with no readable duration whose proof FAILS: failed as any failed proof — nothing trashed")
    func anUnprovenMasterStillNeverReplaces() async throws {
        typealias P = TranscodePreservationProofMatrixTests
        let b = try mx.bench("nodur_proof_bad", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try preservationMock(b, masterVideo: P.video([P.hashB, P.hashA, P.hashA]))
        let job = await mx.run(b, m, preset: .preservation)
        mx.expectRefused(b, job, catalogBefore: before, reason: ["Lossless verification FAILED — ", "video frame 0 (0-based)"])
        await mx.expectFailedReplaceSaysWhatHappened(b, job)
    }

    // MARK: - Rule 1: the source is measured another way, and then compared as always

    @Test("no container duration but a STREAM duration: the source is measured by its longest stream and a Replace proceeds")
    func aStreamDurationMeasuresTheSource() async throws {
        let b = try mx.bench("nodur_streams"); defer { b.sb.cleanup() }
        let m = try transcodeMock(b, source: Probes(format: Self.noDuration, streams: .output(stdout: "N/A\n11.960000\n12.000000\n")))
        let job = await mx.run(b, m)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.contains("The previous file is in the Trash.") && !summary.contains("not compared"), "\(summary)")
        #expect(b.trashed.all == [b.target.path])
        #expect(m.calls(to: "ffprobe", containing: ["nb_read_packets"]).isEmpty, "the chain stops at the first measure: \(m.calls)")
    }

    @Test("no container or stream duration but a PACKET COUNT with one agreed frame rate: 300 packets at 25/1 is 12 s, and a Replace proceeds")
    func aPacketCountMeasuresTheSource() async throws {
        let b = try mx.bench("nodur_packets"); defer { b.sb.cleanup() }
        let m = try transcodeMock(b, source: Probes(format: Self.noDuration, packets: Self.packets(300)))
        let job = await mx.run(b, m)
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        #expect(b.trashed.all == [b.target.path])
    }

    @Test("a source measured by fallback still catches a truncated encode: 300 packets (12 s) against a 2 s output is 'stopped early'")
    func aFallbackMeasureStillCatchesAShortOutput() async throws {
        let b = try mx.bench("nodur_short"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try transcodeMock(b, source: Probes(format: Self.noDuration, packets: Self.packets(300)),
                                  output: Probes(format: .output(stdout: "2.000000\n")))
        let job = await mx.run(b, m)
        mx.expectRefused(b, job, catalogBefore: before, reason: ["stopped early", "0:02", "0:12"])
    }

    @Test("a packet count whose two frame rates DISAGREE (50/1 vs 25/1) is not a length — refuse rather than guess: a Replace is refused, a plain Transcode gets the note",
          arguments: [true, false])
    func anAmbiguousFrameRateIsNotALength(_ replace: Bool) async throws {
        let b = try mx.bench("nodur_ambiguous_\(replace)"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try transcodeMock(b, source: Probes(format: Self.noDuration, packets: Self.packets(300, r: "50/1", avg: "25/1")))
        let job = await mx.run(b, m, replace: replace)
        if replace {
            mx.expectRefused(b, job, catalogBefore: before, reason: [Self.refusal, "50/1", "25/1"])
        } else {
            guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
            #expect(summary.contains(Self.note), "\(summary)")
        }
    }

    // MARK: - Rule 3: the OUTPUT must be measurable, in every mode

    @Test("an OUTPUT with no readable duration at all is a FAILED job with or without Replace — even when the source has none either",
          arguments: [true, false])
    func anOutputWithNoDurationIsStillFailed(_ replace: Bool) async throws {
        let b = try mx.bench("nodur_output_\(replace)"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try transcodeMock(b, source: .none, output: .none)
        let job = await mx.run(b, m, replace: replace)
        mx.expectRefused(b, job, catalogBefore: before, reason: ["the new file's length could not be read", "no readable duration"])
        guard case .failed(let message) = job.state else { return }
        #expect(!message.contains("Transcoded") && !message.contains(Self.note), "\(message)")
        #expect(message.hasSuffix(replace ? "the unverified new file was removed." : "The unverified new file was removed."), "\(message)")
    }

    @Test("an OUTPUT with no container duration but a stream duration is measured by the same chain and compared: verified, published")
    func anOutputMeasuredByItsStreamsIsVerified() async throws {
        let b = try mx.bench("nodur_output_streams"); defer { b.sb.cleanup() }
        let m = try transcodeMock(b, source: .twelveSeconds, output: Probes(format: Self.noDuration, streams: .output(stdout: "12.000000\n")))
        let job = await mx.run(b, m)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(!summary.contains("not compared"), "both lengths were read: \(summary)")
        #expect(b.trashed.all == [b.target.path])
    }

    // MARK: - The chain itself: pure parsing, the log line, and REAL elementary streams

    @Test("the chain's parsing (pure): what counts as 'no duration', the longest stream, packets ÷ an agreed rate")
    func theChainsParsing() {
        typealias C = FFmpegEncodeCheck
        typealias R = ProcessRunner.Result
        #expect(C.saysNoDuration(R(stdout: "N/A\n", stderr: "", exitCode: 0, launched: true)))
        #expect(C.saysNoDuration(R(stdout: "", stderr: "", exitCode: 0, launched: true)))
        #expect(C.saysNoDuration(R(stdout: "N/A\nN/A\n", stderr: "", exitCode: 0, launched: true)))
        #expect(!C.saysNoDuration(R(stdout: "N/A\n", stderr: "Invalid data", exitCode: 1, launched: true)), "a failed tool is not an answer")
        #expect(!C.saysNoDuration(R(stdout: nil, stderr: "x", exitCode: -1)), "a tool that never ran is not an answer")
        #expect(!C.saysNoDuration(R(stdout: "\u{7B}\"format\"", stderr: "", exitCode: 0, launched: true)), "garbage is not an answer")

        #expect(C.longestStreamSeconds("N/A\n11.5\n12.25\n") == 12.25)
        #expect(C.longestStreamSeconds("N/A\n0.000000\n-3\ninf\n") == nil)
        #expect(C.rate("30000/1001").map { abs($0 - 29.97) < 0.001 } == true)
        #expect(C.rate("0/0") == nil && C.rate("N/A") == nil && C.rate(nil) == nil)

        #expect(C.packetSeconds("r_frame_rate=25/1\navg_frame_rate=25/1\nnb_read_packets=300\n").seconds == 12)
        #expect(C.packetSeconds("r_frame_rate=30000/1001\navg_frame_rate=30000/1001\nnb_read_packets=60\n").seconds.map { abs($0 - 2.002) < 0.001 } == true)
        #expect(C.packetSeconds("r_frame_rate=30000/1001\navg_frame_rate=0/0\nnb_read_packets=60\n")
                == (nil, "only one of its two frame rates is known (r_frame_rate 30000/1001, avg_frame_rate 0/0), so a packet count is not a length"))
        #expect(C.packetSeconds("") == (nil, "no video stream to count packets in"))
        #expect(C.packetSeconds("r_frame_rate=25/1\navg_frame_rate=25/1\nnb_read_packets=N/A\n") == (nil, "no packets were counted"))
        #expect(C.packetSeconds("r_frame_rate=0/0\navg_frame_rate=0/0\nnb_read_packets=9\n").why.hasPrefix("no frame rate to divide the packet count by"))
        #expect(C.packetSeconds("r_frame_rate=50/1\navg_frame_rate=25/1\nnb_read_packets=50\n")
                == (nil, "its frame rate is ambiguous (r_frame_rate 50/1, avg_frame_rate 25/1), so a packet count is not a length"))
    }

    @Test("the four answers of the length check, and the log says which fallback measure was used")
    func theFourAnswersAndTheLogLine() async {
        typealias C = FFmpegEncodeCheck
        func verify(source: Probes, output: Probes) async -> (C.Verification, [String]) {
            var m = ScriptedExecutor()
            m = Self.probeRules(m, file: "/test_nodur/source.m2v", source)
            m = Self.probeRules(m, file: "/test_nodur/output.mov", output)
            let sink = InMemoryLogSink()
            let answer = await withAppLog(sink) {
                await m.scoped { await C.lengthVerification(sourcePath: "/test_nodur/source.m2v", outputPath: "/test_nodur/output.mov") }
            }
            return (answer, sink.lines)
        }
        var (answer, log) = await verify(source: .twelveSeconds, output: .twelveSeconds)
        #expect(answer == .verified && log.isEmpty, "the ordinary case says nothing: \(log)")

        (answer, log) = await verify(source: Probes(format: Self.noDuration, packets: Self.packets(300)), output: .twelveSeconds)
        #expect(answer == .verified)
        #expect(log == ["length: source.m2v has no container duration — measured 0:12 (12.000 s) by its video packet count ÷ frame rate"], "\(log)")

        (answer, log) = await verify(source: Probes(format: Self.noDuration, streams: .output(stdout: "12.5\n")), output: .twelveSeconds)
        #expect(answer == .verified)
        #expect(log == ["length: source.m2v has no container duration — measured 0:13 (12.500 s) by its longest stream duration"], "\(log)")

        (answer, log) = await verify(source: .none, output: .twelveSeconds)
        #expect(answer == .lengthNotCompared("no container duration, no stream duration, and no video stream to count packets in"))

        (answer, log) = await verify(source: .twelveSeconds, output: .none)
        #expect(answer == .unmeasured("the new file's length could not be read: it has no readable duration (no container duration, no stream duration, and no video stream to count packets in)"))

        // A fallback probe that FAILS is "could not be read", never "no duration".
        (answer, log) = await verify(source: Probes(format: Self.noDuration, streams: .crash(signal: SIGSEGV)), output: .twelveSeconds)
        #expect(answer == .unmeasured("the source's length could not be read to compare against: ffprobe stopped with exit code \(SIGSEGV)"))
        (answer, log) = await verify(source: Probes(format: Self.noDuration, packets: .launchFailure), output: .twelveSeconds)
        if case .unmeasured(let why) = answer { #expect(why.contains("ffprobe could not be started"), "\(why)") } else { Issue.record("\(answer)") }
    }

    /// REAL sources with no container duration, made with ffmpeg: an
    /// MPEG-2 elementary stream (both frame rates 25/1 → measured by its
    /// packet count) and a raw H.264 stream (r_frame_rate 50/1 against
    /// avg_frame_rate 25/1 → no readable duration; refuse rather than guess).
    @Test("REAL elementary streams: an .m2v is measured by its packet count (2 s); a raw .h264 has no readable duration and says why")
    func realElementaryStreams() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let dir = try CleanupTestMedia.makeScratchDir("nodur_real"); defer { try? FileManager.default.removeItem(at: dir) }
        let lavfi = ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2"]
        let m2v = dir.appendingPathComponent("test_nodur.m2v"), h264 = dir.appendingPathComponent("test_nodur.h264")
        try CleanupTestMedia.runFFmpeg(lavfi + ["-c:v", "mpeg2video", "-f", "mpeg2video"], output: m2v.path)
        try CleanupTestMedia.runFFmpeg(lavfi + ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-f", "h264"], output: h264.path)

        // Neither has a container duration (the bench is what it claims).
        guard case .unreadable = await FFmpegEncodeCheck.measureDuration(m2v.path),
              case .unreadable = await FFmpegEncodeCheck.measureDuration(h264.path) else {
            Issue.record("this ffmpeg writes a container duration for an elementary stream: the bench proves nothing"); return
        }
        let sink = InMemoryLogSink()
        let (first, second) = await withAppLog(sink) {
            (await FFmpegEncodeCheck.measureLength(m2v.path), await FFmpegEncodeCheck.measureLength(h264.path))
        }
        guard case .measured(let seconds, by: .packets) = first else { Issue.record("m2v: \(first)"); return }
        #expect(abs(seconds - 2) < 0.1, "\(seconds)")
        #expect(sink.lines.contains { $0.hasPrefix("length: test_nodur.m2v has no container duration — measured 0:02") && $0.hasSuffix("by its video packet count ÷ frame rate") }, "\(sink.lines)")
        guard case .noDuration(let why) = second else { Issue.record("h264: \(second)"); return }
        #expect(why.hasPrefix("no container duration, no stream duration, and its frame rate is ambiguous"), "\(why)")
        // …and a real file with a container duration is still one probe, by the container.
        let mov = dir.appendingPathComponent("test_nodur.mov")
        try CleanupTestMedia.runFFmpeg(lavfi + ["-c:v", "mpeg4"], output: mov.path)
        guard case .measured(let whole, by: .container) = await FFmpegEncodeCheck.measureLength(mov.path) else { Issue.record("mov"); return }
        #expect(abs(whole - 2) < 0.1)
    }
}
