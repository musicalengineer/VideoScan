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
//   1. The source is MEASURED by its longest stream duration when the
//      container has none, and compared exactly as before. Nothing else is
//      tried: a packet count ÷ frame rate was removed (Codex r1 #6 — a
//      mixed-rate stream reads 6 s for 4 s); refuse rather than guess.
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
// ffmpeg and ffprobe are answered by a strict ScriptedExecutor; the rows at
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

    static let note = "Length not compared: the source has no readable duration."
    static let refusal = "Could not verify the new file against the original: the source has no readable duration — the original was not replaced."

    /// One probe chain: container, streams.
    struct Probes: Sendable {
        var format: Behaviour
        var streams: Behaviour = EncodeSourceWithoutDurationMatrixTests.noDuration
        static let none = Probes(format: EncodeSourceWithoutDurationMatrixTests.noDuration)
        static let twelveSeconds = Probes(format: EncodeSourceWithoutDurationMatrixTests.twelve)
    }

    /// The length probes of one file (told apart by `name`), strict.
    static func probeRules(_ mock: ScriptedExecutor, file name: String, _ p: Probes) -> ScriptedExecutor {
        mock.on("ffprobe", containing: ["format=duration", name], p.format)
            .on("ffprobe", containing: ["stream=duration", name], p.streams)
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
        // The output WAS measured (its own terms), and the source was asked both ways — and no third.
        #expect(m.calls(to: "ffprobe", containing: ["format=duration", ".vs-partial."]).count == 1)
        #expect(m.calls(to: "ffprobe", containing: ["stream=duration", MX.sourceName]).count == 1, "\(m.calls)")
        #expect(m.calls(to: "ffprobe", containing: ["-count_packets"]).isEmpty, "\(m.calls)")
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
        #expect(summary.contains(". " + Self.note + " The previous file is in the Trash."), "\(summary)")
        #expect(b.trashed.all == [b.target.path])
        #expect(MX.sha(b.fakeTrash.appendingPathComponent(b.target.lastPathComponent)) == b.priorSHA)
        #expect(b.model.records.first { $0.fullPath == b.target.path }?.derivedFrom == b.source.id)
    }

    /// Codex r1 #11: the note was dropped for Preservation. The proof is the
    /// verification, but "the length was not compared" is still true and
    /// still said — with or without Replace.
    @Test("Preservation of a source with no readable duration, proof passes: the summary and OUTCOME still carry 'Length not compared…'",
          arguments: [true, false])
    func aProvenMasterStillCarriesTheNote(_ replace: Bool) async throws {
        typealias P = TranscodePreservationProofMatrixTests
        let b = try mx.bench("nodur_proof_note_\(replace)", preset: .preservation); defer { b.sb.cleanup() }
        let m = try preservationMock(b, masterVideo: P.threeGoodFrames)
        let job = await mx.run(b, m, preset: .preservation, replace: replace)
        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasPrefix("✓ Verified bit-exact lossless (frame MD5) → "), "\(summary)")
        #expect(summary.contains(Self.note), "the row does not say the length was not compared: \(summary)")
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title, state: job.state, wasRefused: job.wasRefused)
        #expect(outcome?.contains(Self.note) == true, "OUTCOME: \(outcome ?? "nil")")
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
        #expect(m.calls(to: "ffprobe", containing: ["-count_packets"]).isEmpty, "\(m.calls)")
    }

    @Test("a source measured by its streams still catches a truncated encode: 12 s against a 2 s output is 'stopped early'")
    func aFallbackMeasureStillCatchesAShortOutput() async throws {
        let b = try mx.bench("nodur_short"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try transcodeMock(b, source: Probes(format: Self.noDuration, streams: Self.twelve),
                                  output: Probes(format: .output(stdout: "2.000000\n")))
        let job = await mx.run(b, m)
        mx.expectRefused(b, job, catalogBefore: before, reason: ["stopped early", "0:02", "0:12"])
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

    // MARK: - Codex r1 #5: a malformed reply is "could not be read", never a length, never "no duration"

    /// One malformed answer, on one side. `source` = the source's probes are
    /// malformed (the output measures 12 s); otherwise the output's are.
    struct Malformed: Sendable, CustomTestStringConvertible {
        let label: String
        let probes: Probes
        let source: Bool
        var testDescription: String { label }
    }

    nonisolated static let malformedReplies: [Malformed] = [
        // THE BUG, reproduction 1: `broken` was discarded and 12 accepted.
        Malformed(label: "output streams `12\\nbroken`", probes: Probes(format: noDuration, streams: .output(stdout: "12\nbroken\n")), source: false),
        Malformed(label: "source streams `12\\nbroken`", probes: Probes(format: noDuration, streams: .output(stdout: "12\nbroken\n")), source: true),
        // An empty container answer was "no duration": only "N/A" is absence.
        Malformed(label: "source container empty, streams N/A", probes: Probes(format: nothing), source: true),
        Malformed(label: "source container N/A, streams empty", probes: Probes(format: noDuration, streams: nothing), source: true),
        Malformed(label: "source streams `N/A\\n-3`", probes: Probes(format: noDuration, streams: .output(stdout: "N/A\n-3\n")), source: true),
        Malformed(label: "source streams `garbage`", probes: Probes(format: noDuration, streams: .output(stdout: "garbage\n")), source: true),
        Malformed(label: "output container `12\\nbroken`", probes: Probes(format: .output(stdout: "12\nbroken\n")), source: false),
    ]

    @Test("a malformed probe reply (container or streams, source or output) is 'could not be read' — a FAILED job with or without Replace",
          arguments: malformedReplies, [true, false])
    func aMalformedReplyIsUnreadable(_ bad: Malformed, _ replace: Bool) async throws {
        let b = try mx.bench("nodur_malformed_\(replace)"); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try bad.source ? transcodeMock(b, source: bad.probes, output: .twelveSeconds)
                               : transcodeMock(b, source: .twelveSeconds, output: bad.probes)
        let job = await mx.run(b, m, replace: replace)
        mx.expectRefused(b, job, catalogBefore: before,
                         reason: [bad.source ? "the source's length could not be read" : "the new file's length could not be read"])
        guard case .failed(let message) = job.state else { return }
        #expect(!message.contains("no readable duration") && !message.contains(Self.note), "a malformed reply was called a fact: \(message)")
    }

    // MARK: - The chain itself: pure parsing, the log line, and REAL elementary streams

    @Test("the chain's parsing (pure): what counts as 'no duration', the longest stream")
    func theChainsParsing() {
        typealias C = FFmpegEncodeCheck
        typealias R = ProcessRunner.Result
        #expect(C.saysNoDuration(R(stdout: "N/A\n", stderr: "", exitCode: 0, launched: true)))
        #expect(!C.saysNoDuration(R(stdout: "", stderr: "", exitCode: 0, launched: true)), "nothing is not absence (Codex r1 #5)")
        #expect(!C.saysNoDuration(R(stdout: "N/A\n12\n", stderr: "", exitCode: 0, launched: true)))
        #expect(C.saysNoDuration(R(stdout: "N/A\nN/A\n", stderr: "", exitCode: 0, launched: true)))
        #expect(!C.saysNoDuration(R(stdout: "N/A\n", stderr: "Invalid data", exitCode: 1, launched: true)), "a failed tool is not an answer")
        #expect(!C.saysNoDuration(R(stdout: nil, stderr: "x", exitCode: -1)), "a tool that never ran is not an answer")
        #expect(!C.saysNoDuration(R(stdout: "\u{7B}\"format\"", stderr: "", exitCode: 0, launched: true)), "garbage is not an answer")

        #expect(C.streamDurations("N/A\n11.5\n12.25\n") == .longest(12.25))
        #expect(C.streamDurations("N/A\nN/A\n") == .absent)
        #expect(C.streamDurations("") == .malformed(""))
        #expect(C.streamDurations("12\nbroken\n") == .malformed("12 · broken"), "a line that is not a length is not dropped")
        for bad in ["0.000000", "-3", "inf", "nan", "0x1p3", "1e3", "1.2.3", "12 s"] {
            #expect(C.streamDurations("N/A\n\(bad)\n") == .malformed("N/A · \(bad)"), "accepted: \(bad)")
            #expect(C.decimalSeconds(bad) == nil, "accepted: \(bad)")
        }
        #expect(C.decimalSeconds("12.000000") == 12 && C.decimalSeconds("7") == 7 && C.decimalSeconds(".5") == 0.5)
        // The container reply is held to the same shape.
        #expect(C.measurement(from: R(stdout: "12\nbroken\n", stderr: "", exitCode: 0, launched: true)) != .seconds(12))
        #expect(C.measurement(from: R(stdout: "0x1p3\n", stderr: "", exitCode: 0, launched: true)) != .seconds(8))
        #expect(C.measurement(from: R(stdout: "12.500000\n", stderr: "", exitCode: 0, launched: true)) == .seconds(12.5))
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

        (answer, log) = await verify(source: Probes(format: Self.noDuration, streams: .output(stdout: "12.5\n")), output: .twelveSeconds)
        #expect(answer == .verified)
        #expect(log == ["length: source.m2v has no container duration — measured 0:13 (12.500 s) by its longest stream duration"], "\(log)")

        (answer, log) = await verify(source: .none, output: .twelveSeconds)
        #expect(answer == .lengthNotCompared("no container duration and no stream duration"))

        (answer, log) = await verify(source: .twelveSeconds, output: .none)
        #expect(answer == .unmeasured("the new file's length could not be read: it has no readable duration (no container duration and no stream duration)"))

        // A fallback probe that FAILS is "could not be read", never "no duration".
        (answer, log) = await verify(source: Probes(format: Self.noDuration, streams: .crash(signal: SIGSEGV)), output: .twelveSeconds)
        #expect(answer == .unmeasured("the source's length could not be read to compare against: ffprobe stopped with exit code \(SIGSEGV)"))
        (answer, log) = await verify(source: Probes(format: Self.noDuration, streams: .launchFailure), output: .twelveSeconds)
        if case .unmeasured(let why) = answer { #expect(why.contains("ffprobe could not be started"), "\(why)") } else { Issue.record("\(answer)") }
    }

    /// Codex r1 #6 (P1), reproduced with REAL media: 2 s of MPEG-2 at 25 fps
    /// then 2 s at 50 fps, one elementary stream (4 s). ffprobe answers both
    /// frame rates 25/1 and 150 packets, so packets ÷ rate said 6 s — a
    /// complete 4 s output would have been refused as truncated. Agreeing
    /// header fields do not prove constant timing: no length is guessed.
    @Test("REAL 25 fps + 50 fps MPEG-2 concatenation (4 s, both rates read 25/1): no length is guessed — 'no readable duration', never 6 s")
    func aMixedRateStreamIsNotGivenALength() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let dir = try CleanupTestMedia.makeScratchDir("nodur_mixed_rate"); defer { try? FileManager.default.removeItem(at: dir) }
        let parts = try [25, 50].map { rate -> Data in
            let part = dir.appendingPathComponent("test_part_\(rate).m2v")
            try CleanupTestMedia.runFFmpeg(["-f", "lavfi", "-i", "testsrc=size=64x48:rate=\(rate):duration=2", "-c:v", "mpeg2video", "-f", "mpeg2video"], output: part.path)
            return try Data(contentsOf: part)
        }
        let mixed = dir.appendingPathComponent("test_mixed.m2v")
        try (parts[0] + parts[1]).write(to: mixed)
        let length = await FFmpegEncodeCheck.measureLength(mixed.path)
        #expect(length == .noDuration("no container duration and no stream duration"), "\(length)")
    }

    /// REAL sources with no container duration, made with ffmpeg: an
    /// MPEG-2 elementary stream (the `.m2v` control — it once had a length
    /// by packet count; Codex r1 #6 removed that measure) and a raw H.264
    /// stream. Both have no readable duration, and nothing logs a measure.
    @Test("REAL elementary streams: an .m2v and a raw .h264 have no readable duration and say why; a .mov is one probe, by its container")
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
        #expect(first == .noDuration("no container duration and no stream duration"), "m2v: \(first)")
        #expect(second == .noDuration("no container duration and no stream duration"), "h264: \(second)")
        #expect(sink.lines.isEmpty, "no measure was used, so none is said: \(sink.lines)")
        // …and a real file with a container duration is still one probe, by the container.
        let mov = dir.appendingPathComponent("test_nodur.mov")
        try CleanupTestMedia.runFFmpeg(lavfi + ["-c:v", "mpeg4"], output: mov.path)
        guard case .measured(let whole, by: .container) = await FFmpegEncodeCheck.measureLength(mov.path) else { Issue.record("mov"); return }
        #expect(abs(whole - 2) < 0.1)
    }
}
