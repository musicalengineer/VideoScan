// TranscodePreservationProofMatrixTests.swift — GH #501: Transcode
// (Preservation) proves the new master bit-exact BEFORE it is published.
// Workflow, in Rick's words: "transcode to a temp, verify the temp, only
// when verified could it replace anything. If the transcode is not verified,
// the operation fails" — and for a preservation master, verified includes
// the frame-MD5 lossless proof.
//
// THE BUG: the proof ran against the PUBLISHED file. With Replace the prior
// master was already in the Trash and the name held a master that then
// failed its proof; without Replace a master that failed was left on disk
// beside a `.framemd5-MISMATCH.log` sidecar.
//
// Every row drives the production TranscodeJob with ffmpeg and ffprobe
// answered by a ScriptedExecutor (strict: an unnamed command is a failure),
// on TranscodeReplaceNegativeMatrixTests' bench (placeholder source, a
// seeded prior file at the output name, the Trash seam). What a failed
// proof must show (rules 1 and 2):
//   • the job is FAILED, and the row and the OUTCOME line carry the
//     evidence — which stream, which frame, both hashes, or the tool, its
//     exit code and its words — bounded;
//   • nothing went to the Trash, the prior file is byte-identical;
//   • the failed master is removed: no partial, no sidecar, nothing else
//     beside the original;
//   • the catalog is unchanged.
// Rows: video mismatch (with and without Replace) · audio mismatch · the
// proof tool crashing / failing to launch / answering garbage / answering
// nothing / exiting nonzero, on the source side and on the master side ·
// the proof hanging until the stall watchdog · Stop during the proof · Stop
// after the proof's last answer · a flood of differing frames (bounded).
// Controls: a matching proof publishes and replaces, and every proof
// command read the PARTIAL while nothing had been trashed; the media matrix
// with the real ffmpeg (mp4/h264, mov/prores, mkv/ffv1+pcm, mxf, avi/dv).
//
// Parallel by design (each test binds its own mock, Trash seam and log).
// Memory: placeholder blobs of tens of KB; real clips are 2 s at 320x240.

import CryptoKit
import Darwin
import Foundation
import Testing
@testable import VideoScan
@_spi(Testing) import VideoScanCore

@Suite("Transcode Preservation — the lossless proof runs before the publish (GH #501)", .timeLimit(.minutes(3)))
@MainActor
struct TranscodePreservationProofMatrixTests {

    typealias MX = TranscodeReplaceNegativeMatrixTests
    typealias Behaviour = ScriptedExecutor.Behaviour
    let mx = MX()

    nonisolated static let hashA = String(repeating: "a", count: 32)
    nonisolated static let hashB = String(repeating: "b", count: 32)

    /// A framemd5 stream: ffmpeg's header lines, then one row per hash.
    nonisolated static func frames(_ hashes: [String]) -> String {
        "#format: frame checksums\n#tb 0: 1/25\n" + hashes.enumerated().map {
            "0, \($0.offset), \($0.offset), 1, 115200, \($0.element)"
        }.joined(separator: "\n") + "\n"
    }

    nonisolated static func video(_ hashes: [String]) -> Behaviour { .output(stdout: frames(hashes)) }
    nonisolated static func audio(_ md5: String) -> Behaviour { .output(stdout: "MD5=\(md5)\n") }
    nonisolated static let threeGoodFrames = video([hashA, hashA, hashA])

    /// Strict script for a preservation run. Rule order matters (first
    /// match): the proof's decodes are told from the encode by `framemd5`
    /// (video) and `-vn` (audio), and the source side from the master side
    /// by the source's file name (the partial's name does not contain it).
    func mock(_ b: MX.Bench,
              sourceVideo: Behaviour = threeGoodFrames, masterVideo: Behaviour = threeGoodFrames,
              sourceAudio: Behaviour = audio(hashA), masterAudio: Behaviour = audio(hashA),
              encode: Behaviour = .writeOutputFile(Data(repeating: 0x5A, count: 20_000))) throws -> ScriptedExecutor {
        try ScriptedExecutor(claiming: [b.sb.root.path])
            .on("ffmpeg", containing: ["framemd5", MX.sourceName], sourceVideo)
            .on("ffmpeg", containing: ["framemd5"], masterVideo)
            .on("ffmpeg", containing: ["-vn", MX.sourceName], sourceAudio)
            .on("ffmpeg", containing: ["-vn"], masterAudio)
            .on("ffmpeg", containing: [MX.sourceName], encode)
            .on("ffprobe", containing: ["format=duration"], MX.twelveSeconds)
            .on("ffprobe", containing: ["bits_per_raw_sample"], .output(stdout: "bits_per_raw_sample=24\nsample_fmt=s32\n"))
            .on("ffprobe", containing: ["-show_streams"], .output(stdout: MX.h264ProbeJSON()))
    }

    func beside(_ b: MX.Bench) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: b.outDir.path)) ?? ["unreadable"]).sorted()
    }

    /// What every failed proof shares. `replace` chooses the sentence the
    /// row must end with.
    func expectProofFailed(_ b: MX.Bench, _ job: TranscodeJob, _ m: ScriptedExecutor, catalogBefore: [String],
                           evidence: [String], replace: Bool = true,
                           sourceLocation: SourceLocation = #_sourceLocation) {
        mx.expectRefused(b, job, catalogBefore: catalogBefore, reason: ["Lossless verification FAILED — "] + evidence,
                         sourceLocation: sourceLocation)
        guard case .failed(let message) = job.state else { return }
        #expect(message.hasPrefix("Lossless verification FAILED — "), "\(message)", sourceLocation: sourceLocation)
        if replace {
            #expect(message.contains("The original was not replaced: \(b.target.lastPathComponent) was not moved or changed; the failed new file was removed."),
                    "\(message)", sourceLocation: sourceLocation)
        } else {
            #expect(message.contains("Nothing was published or added to the catalog: the failed new file was removed."),
                    "\(message)", sourceLocation: sourceLocation)
            #expect(!message.contains("not replaced"), "no Replace was asked: \(message)", sourceLocation: sourceLocation)
        }
        #expect(!message.contains("MISMATCH.log") && !message.contains("sidecar"), "\(message)", sourceLocation: sourceLocation)
        #expect(message.count < 900, "the evidence is bounded: \(message.count)", sourceLocation: sourceLocation)
        #expect(job.subtitle == message, sourceLocation: sourceLocation)
        let outcome = MediaFileOperationsCenter.terminalSummaryLine(verb: job.kind.logVerb, title: job.title,
                                                                    state: job.state, wasRefused: job.wasRefused)
        #expect(outcome == "transcode FAILED: \(MX.sourceName) — \(message)", "OUTCOME: \(outcome ?? "nil")", sourceLocation: sourceLocation)
        // Only the prior file is in the folder: no master, no partial, no sidecar.
        #expect(beside(b) == [b.target.lastPathComponent], "left beside the original: \(beside(b))", sourceLocation: sourceLocation)
        let inTrash = (try? FileManager.default.contentsOfDirectory(atPath: b.fakeTrash.path)) ?? ["unreadable"]
        #expect(inTrash.isEmpty, "\(inTrash)", sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty, "a master that failed its proof was probed for the catalog",
                sourceLocation: sourceLocation)
        #expect(m.calls(to: "ffmpeg", containing: ["-c:v", "ffv1"]).count <= 1, "the encode was retried", sourceLocation: sourceLocation)
    }

    /// Poll until the proof's first decode has been launched.
    static func waitForProof(_ mock: ScriptedExecutor) async {
        for _ in 0..<400 where mock.calls(to: "ffmpeg", containing: ["framemd5"]).isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)   // the real child is up
    }

    // MARK: - Control

    @Test("control: a proof that matches publishes and replaces — and every proof decode read the PARTIAL while nothing had been trashed")
    func aMatchingProofPublishesAndReplaces() async throws {
        let b = try mx.bench("proof_ok", preset: .preservation); defer { b.sb.cleanup() }
        let trashedAtProof = MX.Box<[String]>()
        let trashed = b.trashed
        let m = try mock(b, masterAudio: .custom { _ in
            trashedAtProof.set(trashed.all)      // the LAST proof command
            return ProcessRunner.Result(stdout: "MD5=\(Self.hashA)\n", stderr: "", exitCode: 0, launched: true)
        })
        let job = await mx.run(b, m, preset: .preservation)
        let sink = b.log   // the bench binds its own sink as appLog for the run

        guard case .finished(let summary) = job.state else { Issue.record("\(job.state)"); return }
        #expect(summary.hasPrefix("✓ Verified bit-exact lossless (frame MD5) → \(b.target.lastPathComponent)"), "\(summary)")
        #expect(summary.contains("The previous file is in the Trash."), "\(summary)")
        #expect(trashedAtProof.value == [], "the prior master was trashed before the proof finished: \(trashedAtProof.value ?? ["never asked"])")
        #expect(b.trashed.all == [b.target.path])
        #expect(MX.sha(b.fakeTrash.appendingPathComponent(b.target.lastPathComponent)) == b.priorSHA)
        #expect(MX.sha(b.target) != b.priorSHA, "the new master took the name")
        #expect(beside(b) == [b.target.lastPathComponent])
        #expect(b.model.records.first { $0.fullPath == b.target.path }?.derivedFrom == b.source.id)
        // The master side of both proofs read this run's partial, never the output name.
        let masterDecodes = m.calls(to: "ffmpeg").filter { call in
            (call.arguments.contains("framemd5") || call.arguments.contains("-vn")) && !call.arguments.contains { $0.contains(MX.sourceName) }
        }
        #expect(masterDecodes.count == 2, "\(masterDecodes)")
        for call in masterDecodes {
            #expect(call.arguments.contains { $0.contains(".vs-partial.") }, "the proof read something other than the partial: \(call)")
            #expect(!call.arguments.contains(b.target.path), "the proof read the output name: \(call)")
        }
        #expect(sink.contains("✓ VERIFIED bit-exact lossless"), "\(sink.lines)")
    }

    // MARK: - The proof says no

    /// The row that was parked RED on main as
    /// `preservationReplaceProvesLosslessOnlyAfterTheReplace`.
    @Test("a master whose video frames differ never replaces: FAILED with the frame and both hashes; nothing trashed; the master is removed")
    func aVideoMismatchNeverReplaces() async throws {
        let b = try mx.bench("proof_video", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, sourceVideo: Self.video([Self.hashA, Self.hashA, Self.hashA]),
                         masterVideo: Self.video([Self.hashA, Self.hashB, Self.hashB]))
        let job = await mx.run(b, m, preset: .preservation)
        let sink = b.log   // the bench binds its own sink as appLog for the run
        expectProofFailed(b, job, m, catalogBefore: before,
                          evidence: ["video frame 1 (0-based) is the first of 2 that differ in 3 compared",
                                     "source MD5 \(Self.hashA)", "new master MD5 \(Self.hashB)"])
        // The audio proof is not reached once the video proof fails.
        #expect(m.calls(to: "ffmpeg", containing: ["-vn"]).isEmpty)
        // The evidence is RECORDED in the app log's summary block.
        #expect(sink.contains("✗ VERIFICATION FAILED — the new master was not published"), "\(sink.lines)")
        #expect(sink.lines.contains { $0.contains("Evidence:") && $0.contains("video frame 1 (0-based)") && $0.contains(Self.hashB) },
                "\(sink.lines)")
    }

    @Test("without Replace a master whose video differs is not published either: FAILED, removed, nothing catalogued, no sidecar")
    func aVideoMismatchIsNotPublishedWithoutReplace() async throws {
        let b = try mx.bench("proof_video_plain", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, masterVideo: Self.video([Self.hashB, Self.hashA, Self.hashA]))
        let job = await mx.run(b, m, preset: .preservation, replace: false)
        expectProofFailed(b, job, m, catalogBefore: before, evidence: ["video frame 0 (0-based) is the first of 1 that differ in 3 compared"],
                          replace: false)
    }

    @Test("a master with fewer frames than the source: FAILED with both frame counts")
    func aShortMasterIsNotProven() async throws {
        let b = try mx.bench("proof_count", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, masterVideo: Self.video([Self.hashA, Self.hashA]))
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before,
                          evidence: ["could not be compared", "source has 3 frames, output has 2"])
    }

    @Test("a master whose AUDIO differs (video proven): FAILED with both whole-stream hashes and the format they were compared in")
    func anAudioMismatchNeverReplaces() async throws {
        let b = try mx.bench("proof_audio", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, masterAudio: Self.audio(Self.hashB))
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before,
                          evidence: ["the audio whole-stream MD5s differ, both decoded as pcm_s24le",
                                     "source \(Self.hashA)", "new master \(Self.hashB)"])
    }

    @Test("a flood of differing frames is reported in one bounded line: the first frame, the count, never the stream")
    func theEvidenceIsBounded() async throws {
        let b = try mx.bench("proof_flood", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, sourceVideo: Self.video(Array(repeating: Self.hashA, count: 5_000)),
                         masterVideo: Self.video(Array(repeating: Self.hashB, count: 5_000)))
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before,
                          evidence: ["video frame 0 (0-based) is the first of 5000 that differ in 5000 compared"])
    }

    @Test("a 5,000-line stream of 500-character garbage tokens is one bounded 'could not be computed' line, never quoted whole")
    func garbageIsBoundedToo() async throws {
        let b = try mx.bench("proof_flood_garbage", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let garbageToken = String(repeating: "z", count: 500)
        let m = try mock(b, masterVideo: Self.video(Array(repeating: garbageToken, count: 5_000)))
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before,
                          evidence: ["the new master's video frame MD5 could not be computed: record 1", "is not a frame MD5 record"])
        guard case .failed(let message) = job.state else { return }
        #expect(!message.contains(garbageToken), "a 500-character token was quoted whole")
    }

    // MARK: - The proof tool misbehaves

    enum ToolFault: String, CaseIterable, Sendable {
        case crash, launchFailure, garbage, nothing, nonzero

        var behaviour: Behaviour {
            switch self {
            case .crash: .crash(signal: SIGSEGV, stderr: "")
            case .launchFailure: .launchFailure
            case .garbage: .garbage(stdout: "\u{7B}\"frames\": [\u{7B}\"md")
            case .nothing: .output(stdout: "")
            case .nonzero: .output(stdout: TranscodePreservationProofMatrixTests.frames([TranscodePreservationProofMatrixTests.hashA]),
                                   stderr: "frame=    1\n[matroska @ 0x1] Truncating packet of size 1048576 to 4096\nError while decoding stream #0:0: Invalid data found when processing input\n",
                                   exit: 183)
            }
        }

        /// What the row must say, for the side whose decode misbehaved.
        func evidence(_ side: String) -> [String] {
            switch self {
            case .crash: ["\(side) video frame MD5 could not be computed: ffmpeg stopped with exit code \(SIGSEGV)"]
            case .launchFailure: ["\(side) video frame MD5 could not be computed: ffmpeg could not be started (exit code -1)", "doesn’t exist"]
            case .garbage: ["\(side) video frame MD5 could not be computed: record 1", "is not a frame MD5 record"]
            case .nothing: ["the video frame MD5s could not be compared", "had no frame hashes"]
            case .nonzero: ["\(side) video frame MD5 could not be computed: ffmpeg stopped with exit code 183",
                            "Invalid data found when processing input"]
            }
        }
    }

    @Test("the SOURCE's proof decode crashes / cannot launch / answers garbage / answers nothing / exits nonzero: FAILED, never a pass; nothing trashed",
          arguments: ToolFault.allCases)
    func aSourceDecodeThatMisbehavesIsNeverAPass(_ fault: ToolFault) async throws {
        let b = try mx.bench("proof_src_\(fault.rawValue)", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, sourceVideo: fault.behaviour)
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before, evidence: fault.evidence("the source's"))
    }

    @Test("the NEW MASTER's proof decode crashes / cannot launch / answers garbage / answers nothing / exits nonzero: FAILED, never a pass; nothing trashed",
          arguments: ToolFault.allCases)
    func aMasterDecodeThatMisbehavesIsNeverAPass(_ fault: ToolFault) async throws {
        let b = try mx.bench("proof_out_\(fault.rawValue)", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, masterVideo: fault.behaviour)
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before, evidence: fault.evidence("the new master's"))
    }

    @Test("the AUDIO proof's decode crashes or prints no hash: FAILED with the cause; nothing trashed",
          arguments: [ToolFault.crash, .nothing])
    func anAudioDecodeThatMisbehavesIsNeverAPass(_ fault: ToolFault) async throws {
        let b = try mx.bench("proof_aud_\(fault.rawValue)", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, masterAudio: fault.behaviour)
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before,
                          evidence: fault == .crash ? ["the new master's audio MD5 could not be computed: ffmpeg stopped with exit code \(SIGSEGV)"]
                                                    : ["the new master's audio MD5 could not be computed: ffmpeg's answer was not an MD5 (it printed none)"])
    }

    // MARK: - Codex r1 #3: identical garbage is not a match

    /// Codex r1 #3 (P0). Both proof commands exit 0 and print the SAME
    /// thing that is not a proof — `garbage`. The comparison took each for
    /// one frame hash, found them equal, and the job reported "Verified
    /// bit-exact" and replaced the prior master. A hash stream must BE a
    /// hash stream before two of them can agree.
    @Test("identical GARBAGE from both video proof decodes is not a match: FAILED 'could not be computed', nothing trashed",
          arguments: ["garbage\n", "0, 0, 0, 1, 115200, nothexnothexnothexnothexnothex00\n", "0, 0, 0, 1, 115200\n", "0, 0, 0, 1, 115200, aaaa\n"])
    func identicalGarbageVideoProofsAreNotAMatch(_ reply: String) async throws {
        let b = try mx.bench("proof_same_garbage_v", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, sourceVideo: .output(stdout: reply), masterVideo: .output(stdout: reply))
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before, evidence: ["the source's video frame MD5 could not be computed", "is not a frame MD5 record"])
    }

    @Test("identical GARBAGE from both audio proof decodes (`MD5=garbage`) is not a match: FAILED 'could not be computed', nothing trashed",
          arguments: ["MD5=garbage\n", "MD5=\n", "MD5=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n", "md5 unavailable\n"])
    func identicalGarbageAudioProofsAreNotAMatch(_ reply: String) async throws {
        let b = try mx.bench("proof_same_garbage_a", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, sourceAudio: .output(stdout: reply), masterAudio: .output(stdout: reply))
        let job = await mx.run(b, m, preset: .preservation)
        expectProofFailed(b, job, m, catalogBefore: before, evidence: ["the source's audio MD5 could not be computed", "not an MD5"])
    }

    // MARK: - The proof hangs; Stop

    @Test("the proof HANGS and the stall watchdog fires: FAILED as Stalled (never Cancelled); nothing trashed; the master is removed")
    func aProofThatHangsIsStalled() async throws {
        let b = try mx.bench("proof_stall", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, sourceVideo: .hang(maxSeconds: 60))
        let job = await mx.run(b, m, preset: .preservation) { job in
            await Self.waitForProof(m)
            job.handleStall(phase: "transcode verify (video framemd5)", silentFor: 300)   // what StallMonitor calls
        }
        mx.expectRefused(b, job, catalogBefore: before, reason: ["Stalled", "transcode verify (video framemd5)"])
        await mx.expectFailedReplaceSaysWhatHappened(b, job)
        #expect(beside(b) == [b.target.lastPathComponent], "\(beside(b))")
    }

    @Test("Stop DURING the proof ends Cancelled: nothing trashed, nothing published, the master is removed, catalog unchanged")
    func stopDuringTheProofNeverPublishes() async throws {
        let b = try mx.bench("proof_stop", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let m = try mock(b, masterVideo: .hang(maxSeconds: 60))
        let started = ContinuousClock.now
        let job = await mx.run(b, m, preset: .preservation) { job in
            for _ in 0..<400 where m.calls(to: "ffmpeg", containing: ["framemd5", ".vs-partial."]).isEmpty {
                try? await Task.sleep(nanoseconds: 10_000_000)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
            job.cancel()
        }
        #expect(ContinuousClock.now - started < .seconds(15), "Stop did not stop the hung proof")
        mx.expectRefused(b, job, catalogBefore: before, reason: [], cancelled: true)
        #expect(beside(b) == [b.target.lastPathComponent], "\(beside(b))")
        #expect(m.calls(to: "ffprobe", containing: ["-show_streams"]).isEmpty)
    }

    @Test("Stop after the proof's LAST answer was already in hand still ends Cancelled — a good proof does not publish over a Stop")
    func stopAfterTheProofAnsweredNeverPublishes() async throws {
        let b = try mx.bench("proof_stop_late", preset: .preservation); defer { b.sb.cleanup() }
        let before = b.catalogSnapshot()
        let asked = MX.Box<Bool>(), release = MX.Box<Bool>()
        let m = try mock(b, masterAudio: .custom { _ in
            asked.set(true)
            _ = await release.wait()
            return ProcessRunner.Result(stdout: "MD5=\(Self.hashA)\n", stderr: "", exitCode: 0, launched: true)   // a MATCH
        })
        let job = await mx.run(b, m, preset: .preservation) { job in
            _ = await asked.wait()
            job.cancel()
            release.set(true)
        }
        mx.expectRefused(b, job, catalogBefore: before, reason: [], cancelled: true)
        #expect(beside(b) == [b.target.lastPathComponent], "\(beside(b))")
    }

    // MARK: - Media matrix (real ffmpeg and ffprobe, no mock)

    typealias Source = TranscodeReplaceVerifiedMatrixTests.Source

    @Test("media matrix: a real FFV1 master of each container/codec is proven on the partial, then replaces — trashed exactly once, catalogued, nothing left beside it",
          arguments: Source.allCases)
    func aRealMasterIsProvenThenReplaces(_ kind: Source) async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let sb = try MasterArchiveTestSupport.makeSandbox("proofmm_\(kind.rawValue)"); defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        let srcURL = sb.sources.appendingPathComponent(kind.fileName)
        try CleanupTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=size=320x240:rate=25:duration=2",
             "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000:duration=2"] + kind.codecArgs + ["-shortest"],
            output: srcURL.path)
        let source = MasterArchiveTestSupport.makeRecord(path: srcURL.path)
        source.durationSeconds = 2
        source.audioCodec = kind == .mp4H264 ? "aac" : "pcm_s16le"
        let outDir = sb.root.appendingPathComponent("Masters", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let target = TranscodeDestination.outputURL(in: outDir, record: source, preset: .preservation)
        _ = try MasterArchiveTestSupport.writeBlob(at: target, bytes: 4096, seed: 42)
        let priorSHA = MX.sha(target)
        model.records = [source, MasterArchiveTestSupport.makeRecord(path: target.path)]
        let fakeTrash = sb.root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        let trashed = MX.TrashLog()

        let job = TranscodeJob(record: source, preset: .preservation, outputURL: target, model: model, replaceExisting: true)
        await DerivativeOutputPublish.$trashItem.withValue({ url in
            trashed.add(url.path)
            let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest)
            return dest
        }) {
            job.start()
            await job.task?.value
        }

        guard case .finished(let summary) = job.state else { Issue.record("\(kind.rawValue): \(job.state)"); return }
        #expect(summary.hasPrefix("✓ Verified bit-exact lossless (frame MD5) → \(target.lastPathComponent)"), "\(summary)")
        #expect(trashed.all == [target.path], "\(trashed.all)")
        #expect(MX.sha(fakeTrash.appendingPathComponent(target.lastPathComponent)) == priorSHA)
        #expect(MX.sha(target) != priorSHA)
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: outDir.path)) ?? []).sorted()
        #expect(left == [target.lastPathComponent], "\(left)")
        let atName = model.records.filter { $0.fullPath == target.path }
        #expect(atName.count == 1 && atName.first?.derivedFrom == source.id)
        #expect(atName.first?.videoCodec == "ffv1", "the catalog's record is of the real new master: \(atName.first?.videoCodec ?? "nil")")
    }

    // MARK: - The evidence sentences (pure), scale, sensor

    @Test("the evidence sentences: which frame, how many, both hashes, both counts; a tool that failed is named with its exit code and words")
    func theEvidenceSentences() {
        typealias J = TranscodeJob
        let a = Self.hashA, b = Self.hashB
        #expect(J.frameMD5Evidence(source: Self.frames([a, a]), output: Self.frames([a, a])) == nil)
        #expect(J.frameMD5Evidence(source: Self.frames([a, a, a]), output: Self.frames([a, b, a]))
                == "video frame 1 (0-based) is the first of 1 that differ in 3 compared (source MD5 \(a), new master MD5 \(b))")
        #expect(J.frameMD5Evidence(source: Self.frames([a, a, a]), output: Self.frames([b, b]))
                == "video frame 0 (0-based) is the first of 2 that differ in 2 compared (source MD5 \(a), new master MD5 \(b)); the source has 3 frames, the new master 2")
        #expect(J.frameMD5Evidence(source: "", output: Self.frames([a]))
                == "the video frame MD5s could not be compared: source framemd5 stream had no frame hashes")
        #expect(J.evidenceHash("") == "(no hash)")
        #expect(J.evidenceHash(String(repeating: "z", count: 90)) == String(repeating: "z", count: 40) + "…")

        #expect(J.audioMD5Evidence(source: a, output: a, pcmCodec: "pcm_s24le") == nil)
        #expect(J.audioMD5Evidence(source: a, output: b, pcmCodec: "pcm_s16le")
                == "the audio whole-stream MD5s differ, both decoded as pcm_s16le (source \(a), new master \(b))")
        #expect(J.audioMD5Evidence(source: "", output: "", pcmCodec: "pcm_s24le")
                == "the source's audio MD5 could not be computed: ffmpeg's answer was not an MD5 (it printed none)", "two empty hashes are not a match")
        #expect(J.audioMD5Evidence(source: "garbage", output: "garbage", pcmCodec: "pcm_s24le")
                == "the source's audio MD5 could not be computed: ffmpeg's answer was not an MD5 (“garbage”)", "two identical non-hashes are not a match")
        #expect(J.audioMD5Evidence(source: a, output: "garbage", pcmCodec: "pcm_s24le")?.hasPrefix("the new master's audio MD5 could not be computed") == true)
        // A frame MD5 record: six fields, integers, stream 0, a 32-hex MD5.
        #expect(J.frameMD5Malformed(Self.frames([a, b])) == nil && J.frameMD5Malformed("") == nil && J.frameMD5Malformed("#tb 0: 1/25\n") == nil)
        #expect(J.frameMD5Malformed("0,          0,          0,        1,   115200, \(a)\n") == nil, "ffmpeg's own column padding")
        #expect(J.frameMD5Malformed("0, -3, 0, 1, 115200, \(a.uppercased())\n") == nil, "a negative dts and upper-case hex are still a record")
        for bad in ["garbage", "0, 0, 0, 1, 115200", "0, 0, 0, 1, 115200, zz", "1, 0, 0, 1, 115200, \(a)", "0, x, 0, 1, 115200, \(a)", "0, 0, 0, 1, 115200, \(a), 9"] {
            #expect(J.frameMD5Malformed(Self.frames([a]) + bad + "\n")?.hasPrefix("record 2 of ffmpeg's answer") == true, "accepted: \(bad)")
        }
        #expect(J.frameMD5Evidence(source: "garbage\n", output: "garbage\n")
                == "the source's video frame MD5 could not be computed: record 1 of ffmpeg's answer (“garbage”) is not a frame MD5 record")
        #expect(J.isMD5(a) && !J.isMD5(String(a.dropLast())) && !J.isMD5(a + "0") && !J.isMD5(String(repeating: "g", count: 32)))

        let ok = ProcessRunner.Result(stdout: "", stderr: "frame=  1\n", exitCode: 0, launched: true)
        #expect(J.proofToolFailure(ok, what: "x") == nil)
        let died = ProcessRunner.Result(stdout: "", stderr: "frame=  9\nError while decoding\n", exitCode: 183, launched: true)
        #expect(J.proofToolFailure(died, what: "the source's video frame MD5")
                == "the source's video frame MD5 could not be computed: ffmpeg stopped with exit code 183 — Error while decoding")
        let never = ProcessRunner.Result(stdout: nil, stderr: "The file “ffmpeg” doesn’t exist.", exitCode: -1)
        #expect(J.proofToolFailure(never, what: "the new master's audio MD5")
                == "the new master's audio MD5 could not be computed: ffmpeg could not be started (exit code -1) — The file “ffmpeg” doesn’t exist.")

        #expect(J.notPublishedMessage(failure: "Lossless verification FAILED — x", cleanup: .removed)
                == "Lossless verification FAILED — x. Nothing was published or added to the catalog: the failed new file was removed.")
        #expect(J.notPublishedMessage(failure: "F.", cleanup: .notRemoved("could not remove partial /x/p: Permission denied"))
                == "F. Nothing was published or added to the catalog: the failed new file was NOT removed: could not remove partial /x/p: Permission denied.")
    }

    /// Codex r2 #3 (P0): the record check accepted `\r`-separated records
    /// (ICU counts `\r` as a line end) while the comparison split only on
    /// `\n` and kept the last token — so source [A, A] against master
    /// [B, A] "matched". One line parser now serves both; a line end is
    /// `\n`, `\r\n` or `\r`, and anything else in a record (a Unicode line
    /// separator, a form feed) makes the record malformed.
    @Test("CR / CRLF / mixed line ends: records are checked and compared one by one — [A, A] against [B, A] is never a match")
    func carriageReturnSeparatedRecordsAreComparedOneByOne() {
        typealias J = TranscodeJob
        let a = Self.hashA, b = Self.hashB
        func stream(_ hashes: [String], _ end: String) -> String {
            "#format: frame checksums" + end + hashes.enumerated().map { "0, \($0.offset), \($0.offset), 1, 115200, \($0.element)" }
                .joined(separator: end) + end
        }
        for end in ["\r", "\r\n", "\n\r"] {
            let named = end.unicodeScalars.map { $0 == "\r" ? "CR" : "LF" }.joined(separator: "+")
            #expect(J.frameMD5Evidence(source: stream([a, a], end), output: stream([b, a], end))
                    == "video frame 0 (0-based) is the first of 1 that differ in 2 compared (source MD5 \(a), new master MD5 \(b))", "\(named)")
            #expect(J.frameMD5Evidence(source: stream([a, a], end), output: stream([a, a], end)) == nil, "\(named): equal records still match")
            #expect(J.frameMD5Malformed(stream([a, b], end)) == nil, "\(named)")
            #expect(J.frameCount(stream([a, b, a], end)) == 3, "\(named)")
            #expect(J.compareFrameMD5(source: stream([a, a], end), output: stream([b, a], end)) == .mismatch(frameIndex: 0, source: a, output: b), "\(named)")
        }
        // Mixed ends in one answer: each record is its own record.
        #expect(J.frameMD5Evidence(source: "0, 0, 0, 1, 1, \(a)\r0, 1, 1, 1, 1, \(a)\n", output: "0, 0, 0, 1, 1, \(b)\r\n0, 1, 1, 1, 1, \(a)\n") != nil)
        // A line end ffmpeg never prints is not a record separator: the answer is malformed, never a match.
        for odd in ["\u{2028}", "\u{2029}", "\u{0085}", "\u{000C}", "\u{000B}"] {
            let evidence = J.frameMD5Evidence(source: "0, 0, 0, 1, 1, \(a)\(odd)0, 1, 1, 1, 1, \(a)\n",
                                              output: "0, 0, 0, 1, 1, \(b)\(odd)0, 1, 1, 1, 1, \(a)\n")
            #expect(evidence?.hasPrefix("the source's video frame MD5 could not be computed: record 1 of ffmpeg's answer") == true,
                    "U+\(String(odd.unicodeScalars.first?.value ?? 0, radix: 16, uppercase: true)): \(evidence ?? "nil — a MATCH")")
        }
    }

    /// Scale: a 4-hour tape at 30 fps is 432,000 frames per stream. The
    /// evidence is computed from two such streams (≈30 MB of text each) in
    /// well under the budget, and stays one bounded sentence.
    @Test("scale: the evidence for a 4-hour tape (432,000 frames, every one differing) is one bounded line within 10 s", .timeLimit(.minutes(1)))
    func theEvidenceForALongTapeIsComputedInBudget() {
        let n = 432_000
        let source = Self.frames(Array(repeating: Self.hashA, count: n))
        let master = Self.frames(Array(repeating: Self.hashB, count: n))
        let started = ContinuousClock.now
        let evidence = TranscodeJob.frameMD5Evidence(source: source, output: master)
        let same = TranscodeJob.frameMD5Evidence(source: source, output: source)
        let took = ContinuousClock.now - started
        #expect(evidence == "video frame 0 (0-based) is the first of \(n) that differ in \(n) compared (source MD5 \(Self.hashA), new master MD5 \(Self.hashB))")
        #expect(same == nil)
        #expect(took < .seconds(10), "took \(took)")
    }

    /// Sensor: the order in the source. The proof reads the PARTIAL and
    /// comes before the one publish call; nothing after the publish can
    /// fail the proof; no sidecar is written beside media.
    @Test("sensor: in TranscodeJob the lossless proof reads the partial and precedes the publish; no mismatch sidecar is written")
    func theProofPrecedesThePublishInTheSource() throws {
        let source = try SourceTree.appSource(named: "TranscodeJob.swift")
        let proof = try #require(source.range(of: "await verifyLossless(ffmpeg: ffmpeg, source: inputPath, output: partialPath)"))
        let publish = try #require(source.range(of: "guard let publishNote = await publish(partialURL, verified: verified) else { return }"))
        #expect(proof.upperBound < publish.lowerBound, "the proof must run before the publish")
        #expect(source.components(separatedBy: "await verifyLossless(").count == 2, "one proof call")
        #expect(!source.contains("output: finalPath"), "the proof reads the published file again")
        #expect(!source.contains("MISMATCH.log\""), "a mismatch sidecar is written beside media again")
        #expect(!source.contains("body.write(to:"), "a sidecar is written again")
        // Unknown is not verified: an interrupted proof can never fall through to the publish.
        let between = String(source[proof.upperBound..<publish.lowerBound])
        #expect(between.contains("case .interrupted:") && between.contains("case .failed(let evidence):"))
        #expect(between.contains("if await stoppedBeforePublish(partialURL) { return }"))
    }
}
