// BalanceAudioUnlockedDVTests.swift
// GH #482 — "the balanced copy stores all of the original's sound but plays
// the last packet short".
//
// THE BUG (found 2026-11-17 by the balanced-copy proof on a real 27:18 raw DV
// tape; reproduced here on generated media):
//   Raw DV carries its sound inside each picture frame, and a consumer
//   camcorder's sample clock is UNLOCKED from its picture clock: a frame
//   holds 1580…1620 samples at 48 kHz, not the nominal 1601.6. ffmpeg's dv
//   demuxer stamps the sound by its running sample count and RE-ANCHORS it
//   to the picture whenever the two are a whole frame apart (measured here:
//   when the lead reaches the frame's own sample count). On a tape whose
//   sound runs fast the re-anchor steps BACK a frame, so the packets it
//   hands on overlap in time — their timestamps span fewer samples than
//   they hold. (Real tape of #482: 1,784 samples fast over 27:18, one
//   re-anchor, 1,602 samples of overlap.)
//   The QuickTime muxer stores every PCM sample back to back, but writes the
//   sound track's edit list from the timestamp span. The overlap total falls
//   outside the edit list: stored, and not played.
//
// A LOCKED file (what ffmpeg's own dv muxer writes: 1600/1602/1602/1602/1602)
// never reproduces it at any length — measured 2026-11-18 at 2 s, 10 s, 61 s
// and 4:47, stored = played every time. So the fixture is a generated raw DV
// file whose per-frame sample count (the AAUX source pack's 6-bit field) is
// rewritten here to imitate a camcorder that runs fast.
//
// THE CONTRACT (pinned below):
//   - the balanced copy of a raw DV file PLAYS every sample it STORES, and
//     those are the samples the original decodes, in order, on both sides;
//   - for sound that already advances by its sample count, nothing changes;
//   - whatever the cause, the job's own verification refuses a lossless copy
//     that would not play all the sound it stores (nothing is published).

import CryptoKit
import Foundation
import Testing
@testable import VideoScan

/// Generated raw DV whose sound is not locked to its picture.
enum UnlockedDVMedia {

    /// One NTSC 25 Mbit/s DV frame, and where its first AAUX source pack
    /// (pack id 0x50; the next byte's low six bits are the frame's sample
    /// count above the minimum) sits in it: after the header, subcode and
    /// VAUX blocks (6 × 80 bytes) and three audio-interleaved rows of 16
    /// blocks, past the block's 3-byte id. (libavformat/dv.c reads the same
    /// offset.)
    static let frameBytes = 120_000
    static let sourcePackOffset = 80 * 6 + 80 * 16 * 3 + 3
    /// 48 kHz NTSC: a frame holds `minimumSamples` + the field, 1580…1620.
    static let minimumSamples = 1580
    static let nominalSamplesPerFrame = 1601.6

    /// A left-only raw DV file of `seconds`, frame `n` holding
    /// `samplesPerFrame(n)` samples (nil = leave ffmpeg's locked cadence).
    static func generate(in dir: URL, name: String, seconds: Int,
                         samplesPerFrame: ((Int) -> Int)?) throws -> String {
        let out = dir.appendingPathComponent("test_unlocked_\(name).dv")
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=720x480:rate=30000/1001",
             "-f", "lavfi", "-i", "aevalsrc=\(BalancedCopyProofMedia.leftOnly):s=48000:d=\(seconds)",
             "-map", "0:v:0", "-map", "1:a:0", "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le"],
            output: out.path)
        guard let samplesPerFrame else { return out.path }
        var bytes = try Data(contentsOf: out)
        let frames = bytes.count / frameBytes
        try #require(frames > 0 && bytes.count == frames * frameBytes, "not whole NTSC DV frames")
        for frame in 0..<frames {
            let at = frame * frameBytes + sourcePackOffset
            try #require(bytes[at] == 0x50, "frame \(frame) has no AAUX source pack where one is expected")
            let field = samplesPerFrame(frame) - minimumSamples
            try #require((0...40).contains(field), "a 48 kHz NTSC DV frame holds 1580…1620 samples")
            bytes[at + 1] = (bytes[at + 1] & 0xC0) | UInt8(field)
        }
        try bytes.write(to: out)
        return out.path
    }

    /// One channel of a file's first sound track as it is DECODED (16-bit
    /// PCM), by another road than the job or the proof: the `pan` filter to
    /// a raw file. `inputArgs` go before `-i` (`-ignore_editlist 1` gives
    /// what a QuickTime file STORES, played or not).
    static func channel(_ channel: Int, of path: String, in dir: URL, inputArgs: [String] = []) throws -> Data {
        let raw = dir.appendingPathComponent("pcm_\(UUID().uuidString.prefix(6)).raw")
        defer { try? FileManager.default.removeItem(at: raw) }
        try BalanceAudioTestMedia.runFFmpeg(
            inputArgs + ["-i", path, "-map", "0:a:0", "-af", "pan=mono|c0=c\(channel)", "-f", "s16le", "-c:a", "pcm_s16le"],
            output: raw.path)
        return try Data(contentsOf: raw)
    }

    /// The picture's stored packets as "size sha256" lines, in order.
    static func picturePackets(of path: String) async -> [String] {
        let listing = await ProcessRunner.runProcess(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-v", "error", "-i", path, "-map", "0:v:0", "-c", "copy", "-f", "framehash", "-hash", "sha256", "-"],
            deadlineSeconds: 120)
        return (listing.stdout ?? "").split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line in
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            return fields.count == 6 ? "\(fields[4]) \(fields[5])" : nil
        }
    }
}

@Suite("Balance Audio — raw DV with unlocked sound (GH #482)", .serialized)
@MainActor
struct BalanceAudioUnlockedDVTests {

    typealias Media = UnlockedDVMedia
    private let fm = FileManager.default

    /// Every frame holds the most a frame can: the sample clock leads the
    /// picture by 18.4 samples a frame, and ffmpeg re-anchors the sound to
    /// the picture each time the lead reaches a whole frame (measured: at
    /// frame 89 of every 89).
    private static let fast: (Int) -> Int = { _ in 1620 }

    private func balance(_ path: String, ffmpeg: String? = nil) async throws -> BalanceAudioJob {
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        try #require(analysis.classification == .leftOnly, "fixture is not left-only: \(analysis.classification.rawValue)")
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: path, durationSeconds: analysis.shape.durationSeconds,
                                             audioCodec: analysis.shape.audioCodec)
        model.records = [record]
        let job = BalanceAudioJob(record: record, analysis: analysis, model: model, ffmpegPathOverride: ffmpeg)
        job.start()
        await job.task?.value
        return job
    }

    // MARK: The regression (red before the fix)

    @Test("REGRESSION #482: the balanced copy of a raw DV file whose sound runs fast PLAYS every sample it stores — the original's, on both sides",
          .timeLimit(.minutes(3)))
    func unlockedSoundPlaysToTheLastSample() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("unlocked_fast")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.generate(in: dir, name: "fast", seconds: 4, samplesPerFrame: Self.fast)
        let before = try CleanupTestMedia.fingerprint(original)

        let job = try await balance(original)
        guard case .finished = job.state else {
            Issue.record("the job did not finish: \(job.state) — \(job.subtitle)")
            return
        }
        let copy = try #require(job.publishedURL).path

        // The fixture is what it claims: more samples than the picture's grid has room for.
        let live = try Media.channel(0, of: original, in: dir, inputArgs: ["-r", "30000/1001"])
        let frames = try Data(contentsOf: URL(fileURLWithPath: original)).count / Media.frameBytes
        #expect(live.count / 2 == frames * 1620)
        #expect(Double(live.count / 2) > Double(frames) * Media.nominalSamplesPerFrame + 1620, "the lead must pass a whole frame")

        // PLAYED = STORED = the original's live channel, sample for sample, on both sides.
        let left = try Media.channel(0, of: copy, in: dir)
        let right = try Media.channel(1, of: copy, in: dir)
        let stored = try Media.channel(0, of: copy, in: dir, inputArgs: ["-ignore_editlist", "1"])
        #expect(stored.count == live.count, "the copy stores \(stored.count / 2) samples, the original decodes \(live.count / 2)")
        #expect(left.count == stored.count,
                "the copy PLAYS \(left.count / 2) of the \(stored.count / 2) samples it stores: \((stored.count - left.count) / 2) are hidden behind its edit list")
        #expect(left == live, "the copy's left channel is not the original's live channel")
        #expect(right == live, "the copy's right channel is not the original's live channel")

        // The picture is still the original's packets, and the source is untouched.
        let sourcePackets = await Media.picturePackets(of: original)
        #expect(sourcePackets.count == frames)
        #expect(await Media.picturePackets(of: copy) == sourcePackets)
        #expect(try CleanupTestMedia.fingerprint(original) == before)
    }

    @Test("SENSOR #482: the job's verification refuses a lossless copy that would not play all the sound it stores — nothing is published",
          .timeLimit(.minutes(3)))
    func aCopyWithAnUnplayedTailIsRefusedByTheJob() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("unlocked_refused")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.generate(in: dir, name: "fast", seconds: 4, samplesPerFrame: Self.fast)
        // An ffmpeg that renders as the job did before the fix: the same arguments
        // with the timestamp rewrite taken back out of the sound's filter chain.
        let tools = dir.appendingPathComponent("tools", isDirectory: true)
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        let old = tools.appendingPathComponent("ffmpeg")
        try """
        #!/bin/sh
        for a do
          shift
          set -- "$@" "$(printf '%s' "$a" | /usr/bin/sed 's/,asetpts=[^,]*$//')"
        done
        exec "\(ToolLocator.ffmpegPath)" "$@"
        """.write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)

        let job = try await balance(original, ffmpeg: old.path)
        guard case .failed(let message) = job.state else {
            Issue.record("a copy with an unplayed tail was not refused: \(job.state) — \(job.subtitle)")
            return
        }
        #expect(message.hasPrefix("Verification failed — the balanced copy was discarded."))
        #expect(message.contains("would not play all the sound it stores"), "\(message)")
        #expect(job.publishedURL == nil)
        let names = try fm.contentsOfDirectory(atPath: dir.path)
        #expect(names.sorted() == ["test_unlocked_fast.dv", "tools"], "nothing may be left beside the original: \(names)")
    }

    // MARK: Nothing else changes

    @Test("TRUTH: sound that is locked, slow or jittering within a frame of the picture is carried exactly as before — every sample, in order, played",
          .timeLimit(.minutes(4)),
          arguments: ["locked", "slow", "jitter"])
    func otherCadencesAreCarriedWhole(_ cadence: String) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("unlocked_\(cadence)")
        defer { try? fm.removeItem(at: dir) }
        let perFrame: ((Int) -> Int)? = switch cadence {
        case "slow": { _ in 1584 }
        case "jitter": { [1598, 1606, 1600, 1604][$0 % 4] }
        default: nil
        }
        let original = try Media.generate(in: dir, name: cadence, seconds: 4, samplesPerFrame: perFrame)

        let job = try await balance(original)
        guard case .finished = job.state else {
            Issue.record("\(cadence): the job did not finish: \(job.state) — \(job.subtitle)")
            return
        }
        let copy = try #require(job.publishedURL).path
        let live = try Media.channel(0, of: original, in: dir, inputArgs: ["-r", "30000/1001"])
        let stored = try Media.channel(0, of: copy, in: dir, inputArgs: ["-ignore_editlist", "1"])
        #expect(live.count > 2 * 48_000 * 3)
        #expect(try Media.channel(0, of: copy, in: dir) == live)
        #expect(try Media.channel(1, of: copy, in: dir) == live)
        #expect(stored == live)
        #expect(await Media.picturePackets(of: copy) == Media.picturePackets(of: original))
    }

    // MARK: The rewrite is exact

    /// (timestamp, samples) of each sound packet the muxer is handed when
    /// `original` is rendered with the sound filter `filter`.
    private func muxerPackets(of original: String, filter: String) async -> [(pts: Int64, samples: Int64)] {
        let listing = await ProcessRunner.runProcess(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-v", "error", "-nostdin", "-r", "30000/1001", "-i", original, "-map", "0:a:0", "-af", filter,
                        "-c:a", "pcm_s16le", "-f", "framecrc", "-"],
            deadlineSeconds: 120)
        return (listing.stdout ?? "").split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap { line in
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4, let pts = Int64(fields[2]), let samples = Int64(fields[3]) else { return nil }
            return (pts, samples)
        }
    }

    @Test("TRUTH: the rewritten timestamps are EXACT — every sound packet starts where the one before it ends, to the sample, from zero; and a tape that never re-anchors is rendered byte for byte as before the fix",
          .timeLimit(.minutes(4)),
          arguments: ["locked", "jitter", "slow", "fast", "fastOnce"])
    func rewrittenTimestampsAreExact(_ cadence: String) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("exact_\(cadence)")
        defer { try? fm.removeItem(at: dir) }
        let perFrame: ((Int) -> Int)? = switch cadence {
        case "jitter": { [1598, 1606, 1600, 1604][$0 % 4] }
        case "slow": { _ in 1584 }
        case "fast": Self.fast
        case "fastOnce": Self.fastOnce
        default: nil
        }
        // 12 s: long enough for a truncating `N/SR/TB` to land one sample early (measured: 10 times in 10 s of locked sound).
        let original = try Media.generate(in: dir, name: cadence, seconds: 12, samplesPerFrame: perFrame)
        let analysis = try await AudioBalanceProbe.analyze(path: original)
        let pan = try #require(BalanceAudioFix.panFilter(for: analysis.classification))
        let filter = BalanceAudioFix.soundFilter(panFilter: pan, shape: analysis.shape)
        #expect(filter != pan, "raw DV must get the rewrite")

        let packets = await muxerPackets(of: original, filter: filter)
        #expect(packets.count == 359 || packets.count == 360, "\(packets.count) packets")
        #expect(packets.first?.pts == 0)
        var expected: Int64 = 0
        var early = 0
        for packet in packets {
            if packet.pts != expected { early += 1 }
            expected = packet.pts + packet.samples
        }
        #expect(early == 0, "\(early) packets do not start where the one before them ends")
        let live = try Media.channel(0, of: original, in: dir, inputArgs: ["-r", "30000/1001"])
        #expect(expected == Int64(live.count / 2), "the timestamps span \(expected) samples, the tape decodes \(live.count / 2)")

        // Without the rewrite the same tape's packets are NOT contiguous exactly when it re-anchors.
        let before = await muxerPackets(of: original, filter: pan)
        var breaks = 0
        var end: Int64 = 0
        for packet in before {
            if packet.pts != end { breaks += 1 }
            end = packet.pts + packet.samples
        }
        let reanchors = ["slow", "fast", "fastOnce"].contains(cadence)
        #expect((breaks > 0) == reanchors, "\(cadence): \(breaks) breaks without the rewrite")

        // Byte for byte the old render when there was nothing to fix.
        func render(_ soundFilter: String, to name: String) async throws -> Data {
            let out = dir.appendingPathComponent(name)
            let args = BalanceAudioFix.ffmpegArgs(
                input: original, output: out.path,
                mapArgs: BalanceAudioFix.mapArgs(audioStreams: analysis.shape.audioStreams,
                                                 programStreamIndex: analysis.programStreamIndex),
                panFilter: soundFilter,
                audioArgs: BalanceAudioFix.audioEncodeArgs(sourceCodec: analysis.shape.audioCodec,
                                                           bitRateBitsPerSec: analysis.shape.audioBitRate),
                inputArgs: BalanceAudioFix.rawDVInputArgs(shape: analysis.shape))
            let result = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath, arguments: args, deadlineSeconds: 120)
            try #require(result.exitCode == 0, "render failed: \(result.stderr.suffix(300))")
            return try Data(contentsOf: out)
        }
        if !reanchors {
            let old = try await render(pan, to: "old.mov")
            let new = try await render(filter, to: "new.mov")
            #expect(old == new, "\(cadence): the fixed render differs from the old one though the tape never re-anchors")
        }
    }

    // MARK: The other writer on the same road — Rebuild Audio Track

    @Test("REGRESSION #482, Rebuild Audio: the rebuilt copy of a raw DV file whose sound runs fast PLAYS every sample it stores — both channels, the original's",
          .timeLimit(.minutes(3)))
    func rebuildAudioPlaysToTheLastSample() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("unlocked_rebuild")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.generate(in: dir, name: "fast", seconds: 4, samplesPerFrame: Self.fast)
        let diagnosis = try await VerifyAudioProbe.diagnose(path: original)
        let model = VideoScanModel()
        let record = makeBalanceSourceRecord(path: original, durationSeconds: diagnosis.shape.containerDurationSeconds,
                                             audioCodec: diagnosis.shape.audioCodec)
        model.records = [record]

        let job = RebuildAudioJob(record: record, reason: "test", shape: diagnosis.shape, model: model)
        job.start()
        await job.task?.value
        guard case .finished = job.state else {
            Issue.record("the rebuild did not finish: \(job.state) — \(job.subtitle)")
            return
        }
        let copy = try #require(job.publishedURL).path
        for channel in [0, 1] {
            let source = try Media.channel(channel, of: original, in: dir, inputArgs: ["-r", "30000/1001"])
            let stored = try Media.channel(channel, of: copy, in: dir, inputArgs: ["-ignore_editlist", "1"])
            let played = try Media.channel(channel, of: copy, in: dir)
            #expect(stored == source, "channel \(channel): the copy does not store the original's samples")
            #expect(played.count == stored.count,
                    "channel \(channel): the copy PLAYS \(played.count / 2) of the \(stored.count / 2) samples it stores")
            #expect(played == source)
        }
        #expect(await Media.picturePackets(of: copy) == Media.picturePackets(of: original))
    }

    @Test("SENSOR: Rebuild Audio's arguments — raw DV gets the same timestamp rewrite, before the sound encoder; every other container's vector is unchanged")
    func rebuildAudioArguments() throws {
        #expect(RebuildAudioFix.soundFilterArgs(containerFormat: "dv") == ["-af", "asetpts=STARTPTS+round(N/SR/TB)"])
        for other in ["mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm", "avi", "mxf", ""] {
            #expect(RebuildAudioFix.soundFilterArgs(containerFormat: other).isEmpty, "\(other)")
        }
        let dv = RebuildAudioFix.ffmpegArgs(input: "/in/clip.dv", output: "/out.mov", inputArgs: ["-r", "30000/1001"],
                                            soundFilterArgs: RebuildAudioFix.soundFilterArgs(containerFormat: "dv"))
        #expect(dv == ["-hide_banner", "-nostdin", "-y", "-r", "30000/1001", "-i", "/in/clip.dv", "-map", "0:v?", "-map", "0:a:0",
                       "-c:v", "copy", "-af", "asetpts=STARTPTS+round(N/SR/TB)", "-c:a", "pcm_s16le", "-map_metadata", "0",
                       "-progress", "pipe:2", "/out.mov"])
        #expect(!RebuildAudioFix.ffmpegArgs(input: "/in/a.mov", output: "/out.mov").contains("-af"))
    }

    // MARK: What the balanced-copy proof says about such a pair

    /// The shape of a real fast tape: the lead creeps up to a whole frame,
    /// then ONE re-anchor that does not step back past the packet before it
    /// (87 frames of 1620, one of 1590, then the locked cadence).
    private static let fastOnce: (Int) -> Int = { $0 < 87 ? 1620 : ($0 == 87 ? 1590 : ($0 % 5 == 0 ? 1600 : 1602)) }

    @Test("PROOF: a raw DV original whose sound is re-anchored to its picture is NOT THE SAME as its balanced copy, and the reason says exactly that, with the numbers — every sample is the original's, the placement is not",
          .timeLimit(.minutes(3)))
    func theProofNamesAReanchoredTape() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("unlocked_proof")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.generate(in: dir, name: "fastOnce", seconds: 5, samplesPerFrame: Self.fastOnce)
        let job = try await balance(original)
        guard case .finished = job.state else {
            Issue.record("the job did not finish: \(job.state) — \(job.subtitle)")
            return
        }
        let copy = try #require(job.publishedURL).path
        // The copy holds and plays every sample (the job's half of the contract)…
        let live = try Media.channel(0, of: original, in: dir, inputArgs: ["-r", "30000/1001"])
        #expect(try Media.channel(0, of: copy, in: dir) == live)

        // …and the proof still refuses it, for the one true reason: where the sound sits against the picture.
        let measured = await BalancedCopyProof.measurement(original: original, balanced: copy)
        #expect(measured.outcome == .notProven(.soundReanchored(times: 1, overlapSamples: 1601, gapSamples: 0, sampleRateHz: 48_000)),
                "\(measured.outcome)")
        #expect(!measured.outcome.playsTheSame)
        let facts = try #require(measured.facts)
        #expect(facts.originalRead?.soundSegments?.count == 2 && facts.balancedRead?.soundSegments?.count == 1)
        #expect(facts.originalRead?.soundSamples == Int64(live.count / 2) && facts.balancedRead?.soundSamples == Int64(live.count / 2))
        // Both reads were whole: the copy's decoded length is the length its header states (before the fix it was not).
        let copySound = try #require(facts.balanced.sound.first)
        #expect(BalancedCopyProof.readShortfall(facts.balanced, read: facts.balancedRead, kept: copySound) == nil)
    }

    @Test("PROOF: a tape whose re-anchor steps back PAST the sound before it cannot be decoded by ffmpeg as a timeline — COULD NOT CHECK, and the reason carries ffmpeg's own error line, not its last log line",
          .timeLimit(.minutes(3)))
    func aRunawayTapeIsCouldNotCheckWithTheErrorNamed() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("unlocked_runaway")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.generate(in: dir, name: "fast", seconds: 4, samplesPerFrame: Self.fast)
        let job = try await balance(original)
        let copy = try #require(job.publishedURL).path
        guard case .couldNotCheck(let reason) = await BalancedCopyProof.measure(original: original, balanced: copy) else {
            Issue.record("expected could not check")
            return
        }
        #expect(reason.hasPrefix("the original could not be decoded to the end (ffmpeg status "), "\(reason)")
        #expect(reason.contains("Non-monotonic DTS"), "\(reason)")
    }

    @Test("PROOF (decision table): the re-anchor reason is for a raw DV original against a copy that plays back to back from the same start — never the same; every other placement difference keeps its own reason")
    func reanchoredDecisionTable() {
        typealias Proof = BalancedCopyProof
        typealias Table = BalancedCopyProofDecisionTests
        func run(_ start: Int64, _ samples: Int64) -> Proof.SoundSegment { Proof.SoundSegment(start: start, samples: samples) }
        func decide(dv: Bool, original: [Proof.SoundSegment], copy: [Proof.SoundSegment]) -> Proof.Outcome {
            var facts = dv ? Table.dvFacts() : Table.goodFacts()
            facts.originalRead?.soundSegments = original
            facts.balancedRead?.soundSegments = copy
            return Proof.decide(facts)
        }
        let whole = [run(0, 96_000)]
        // Fast tape: the second run starts 1,601 samples before the first ends.
        let fast = decide(dv: true, original: [run(0, 48_000), run(46_399, 48_000)], copy: whole)
        #expect(fast == .notProven(.soundReanchored(times: 1, overlapSamples: 1601, gapSamples: 0, sampleRateHz: 48_000)))
        // Slow tape: a frame of nothing between the runs. Both kinds on one tape.
        #expect(decide(dv: true, original: [run(0, 48_000), run(49_584, 48_000)], copy: whole)
                == .notProven(.soundReanchored(times: 1, overlapSamples: 0, gapSamples: 1584, sampleRateHz: 48_000)))
        #expect(decide(dv: true, original: [run(0, 32_000), run(30_399, 32_000), run(64_000, 32_000)], copy: whole)
                == .notProven(.soundReanchored(times: 2, overlapSamples: 1601, gapSamples: 1601, sampleRateHz: 48_000)))
        // The sentences: plain, with the numbers and which way the copy drifts.
        #expect(Proof.NotProven.soundReanchored(times: 1, overlapSamples: 1601, gapSamples: 0, sampleRateHz: 48_000).message
                == "the original is raw DV and its sound is re-anchored to the picture 1 time as FFmpeg reads it (1601 samples "
                + "overlap, 0 samples of gap); the balanced copy plays the same samples back to back, so its sound ends 33.4 ms "
                + "later against the picture — the original is kept")
        #expect(Proof.NotProven.soundReanchored(times: 3, overlapSamples: 0, gapSamples: 4752, sampleRateHz: 48_000).message
            .contains("3 times as FFmpeg reads it (0 samples overlap, 4752 samples of gap)"))
        #expect(Proof.NotProven.soundReanchored(times: 3, overlapSamples: 0, gapSamples: 4752, sampleRateHz: 48_000).message
            .contains("its sound ends 99.0 ms earlier against the picture"))
        #expect(Proof.NotProven.soundReanchored(times: 2, overlapSamples: 1601, gapSamples: 1601, sampleRateHz: 48_000).message
            .contains("its sound ends at the same time against the picture"))
        // NOT this reason: the same runs in a QuickTime original (its timestamps are its own)…
        #expect(decide(dv: false, original: [run(0, 48_000), run(46_399, 48_000)], copy: whole)
                == .notProven(.soundPlacementDiffers("the original's sound plays in 2 unbroken runs, the balanced copy's in 1")))
        // …a raw DV copy that does not start where the original starts, or is itself in pieces…
        #expect(decide(dv: true, original: [run(0, 48_000), run(46_399, 48_000)], copy: [run(480, 96_000)])
                == .notProven(.soundPlacementDiffers("the original's sound plays in 2 unbroken runs, the balanced copy's in 1")))
        #expect(decide(dv: true, original: [run(0, 48_000), run(46_399, 48_000)], copy: [run(0, 40_000), run(40_100, 56_000)])
                == .notProven(.soundPlacementDiffers(
                    "run 1: 48000 samples from sample time 0, in the balanced copy 40000 from 0")))
        // …runs whose ends do not fit in 64 bits (no trap: the general reason)…
        #expect(decide(dv: true, original: [run(0, 32_000), run(.max - 10, 32_000), run(5, 32_000)], copy: whole)
                == .notProven(.soundPlacementDiffers("the original's sound plays in 3 unbroken runs, the balanced copy's in 1")))
        #expect(Proof.failureLines(fromStderr: "[in#0/dv @ 0x1] [verbose] a\n[aost#0:1/pcm_s16le @ 0x2] [error] Non-monotonic DTS; previous: 9, current: 8\n[verbose] Exiting with exit code -22")
                == "Non-monotonic DTS; previous: 9, current: 8")
        #expect(Proof.failureLines(fromStderr: "one\ntwo\nthree") == "two · three" && Proof.failureLines(fromStderr: "").isEmpty)
        // …and a raw DV original in ONE run against a copy in one run is the same content, as before.
        #expect(decide(dv: true, original: whole, copy: whole).playsTheSame)
        // A copy that kept the original's two runs exactly would be the same placement.
        let kept = [run(0, 48_000), run(46_399, 48_000)]
        #expect(decide(dv: true, original: kept, copy: kept).playsTheSame)
    }

    // MARK: Pure rules

    @Test("SENSOR: the sound filter — raw DV gets its timestamps rewritten from the sample count; every other container gets the pan alone")
    func soundFilterTable() {
        func shape(_ container: String) -> AudioBalanceStreamShape {
            AudioBalanceStreamShape(videoCodec: "dvvideo", totalStreams: 2, videoStreams: 1, audioStreams: 1,
                                    audioCodec: "pcm_s16le", audioChannels: 2, audioBitRate: nil, durationSeconds: 4,
                                    audioStreamInfos: [], containerFormat: container, videoRFrameRate: "30000/1001")
        }
        let pan = "pan=stereo|c0=c0|c1=c0"
        #expect(BalanceAudioFix.soundFilter(panFilter: pan, shape: shape("dv")) == pan + ",asetpts=STARTPTS+round(N/SR/TB)")
        for other in ["mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm", "mxf", "avi", ""] {
            #expect(BalanceAudioFix.soundFilter(panFilter: pan, shape: shape(other)) == pan, "\(other)")
        }
    }

    @Test("SENSOR: the unplayed-sound rule — lossless QuickTime sound must play what its sample table holds, to the sample; lossy sound (priming) and unread lengths are not judged")
    func unplayedSoundTable() throws {
        func verdict(_ codec: String, stored: Int64?, played: Double?, rate: Int = 48_000) -> String? {
            BalanceAudioFix.unplayedSoundMismatch(codec: codec, sampleRateHz: rate, storedSamples: stored, playedSeconds: played)
        }
        // The real tape of #482: 78,611,514 stored, the header states 1637.7065 s (78,609,912 samples) played.
        #expect(verdict("pcm_s16le", stored: 78_611_514, played: 1637.7065)
                == "the balanced copy would not play all the sound it stores (1602 samples, 33.4 ms, are outside its edit list)")
        // Equal — to within ffprobe's six printed decimals (±0.024 of a sample at 48 kHz). ONE sample is a breach.
        #expect(verdict("pcm_s16le", stored: 484_380, played: 10.09125) == nil)
        #expect(verdict("pcm_s16le", stored: 484_380, played: 10.091249) == nil)
        #expect(verdict("pcm_s16le", stored: 484_381, played: 10.09125)
                == "the balanced copy would not play all the sound it stores (1 samples, 0.0 ms, are outside its edit list)")
        #expect(verdict("pcm_s24le", stored: 484_382, played: 10.09125) != nil)
        // Played longer than stored (an edit list that holds a start delay) hides nothing.
        #expect(verdict("pcm_s16le", stored: 480_000, played: 10.5) == nil)
        // AAC keeps encoder priming outside its edit list by design: not this rule's.
        #expect(verdict("aac", stored: 481_024, played: 10.0) == nil)
        // No sample table to count, or no stated length: not judged. Numbers that are not numbers: refused.
        #expect(verdict("pcm_s16le", stored: nil, played: 10) == nil)
        #expect(verdict("pcm_s16le", stored: 480_000, played: nil) == nil)
        #expect(verdict("pcm_s16le", stored: 480_000, played: .nan) != nil)
        #expect(verdict("pcm_s16le", stored: 480_000, played: -.infinity) != nil)
        #expect(verdict("pcm_s16le", stored: -1, played: 10) != nil)
        #expect(verdict("pcm_s16le", stored: 480_000, played: 9, rate: 0) != nil)
        #expect(verdict("pcm_s16le", stored: .max, played: 1)?.contains("more than 10^15 samples") == true)

        // The header read: the stored count is the sample table's, and only in the QuickTime family.
        let mov = try #require(BalanceAudioFix.soundLengths(fromProbeJSON: Data("""
        {"streams":[{"codec_name":"pcm_s16le","sample_rate":"48000","duration":"9.988896","nb_frames":"484380"}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2"}}
        """.utf8)))
        #expect(mov == [BalanceAudioFix.SoundLength(codec: "pcm_s16le", sampleRateHz: 48_000, playedSeconds: 9.988896,
                                                    storedSamples: 484_380)])
        let mkv = try #require(BalanceAudioFix.soundLengths(fromProbeJSON: Data("""
        {"streams":[{"codec_name":"pcm_s16le","sample_rate":"48000","nb_frames":"94"}],"format":{"format_name":"matroska,webm"}}
        """.utf8)))
        #expect(mkv == [BalanceAudioFix.SoundLength(codec: "pcm_s16le", sampleRateHz: 48_000, playedSeconds: nil, storedSamples: nil)])
        #expect(BalanceAudioFix.soundLengths(fromProbeJSON: Data("not json".utf8)) == nil)
        #expect(BalanceAudioFix.soundLengthArgs(input: "/x/a.mov").suffix(3) == ["-of", "json", "/x/a.mov"])
    }
}
