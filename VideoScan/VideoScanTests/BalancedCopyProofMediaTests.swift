// BalancedCopyProofMediaTests.swift
// BalancedCopyProof.measure on REAL (tiny, synthetic) media. Every fixture
// is generated here with ffmpeg lavfi, one-sided, and balanced with the
// balance job's own argument builders (BalanceAudioFix.ffmpegArgs / mapArgs
// / panFilter / audioEncodeArgs / rawDVInputArgs / balancedOutputURL) — so
// a change to what the job renders shows up here as a proof that says no.
//
// Dimensions: MEDIA MATRIX (mov/prores, mkv/ffv1, mxf, avi/dv, raw dv,
// mp4/h264+aac; 16-bit, 24-bit, float) · TRUTH (the evidence hashes equal
// hashes computed here by another road) · ISOLATION (missing, unreadable
// and swapped files; a tool that fails) · SENSOR (both files and their
// folder are byte-for-byte untouched by the proof). The negatives are the
// point: each damaged copy must be refused, with the right reason.
// The Codex #298 reproductions (discarded channel, timing, partial reads,
// symlinks, decoder configuration, layout, cancellation) are in
// BalancedCopyProofHardeningTests; the attacks it found untested are in
// BalancedCopyProofCoverageTests.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Fixture builder for the balanced-copy proof.
enum BalancedCopyProofMedia {

    /// Two partials, so the samples are not a trivially repeating pattern.
    static let tone = "0.5*sin(440*2*PI*t)+0.2*sin(1234*2*PI*t)"
    static let leftOnly = "\(tone)|0"
    static let rightOnly = "0|\(tone)"

    enum Wrapper: String, CaseIterable, Sendable {
        case movProResPCM16, movProResPCM24, movProResFloat, mkvFFV1PCM16, mkvFFV1PCM24, mxfPCM16, aviDVPCM16,
             rawDV, mp4H264AAC

        var ext: String {
            switch self {
            case .movProResPCM16, .movProResPCM24, .movProResFloat: return "mov"
            case .mkvFFV1PCM16, .mkvFFV1PCM24: return "mkv"
            case .mxfPCM16: return "mxf"
            case .aviDVPCM16: return "avi"
            case .rawDV: return "dv"
            case .mp4H264AAC: return "mp4"
            }
        }
        var isDV: Bool { self == .aviDVPCM16 || self == .rawDV }
        var videoArgs: [String] {
            switch self {
            case .movProResPCM16, .movProResPCM24, .movProResFloat:
                return ["-c:v", "prores_ks", "-profile:v", "0"]
            case .mkvFFV1PCM16, .mkvFFV1PCM24: return ["-c:v", "ffv1"]
            case .mxfPCM16: return ["-c:v", "mpeg2video", "-pix_fmt", "yuv422p"]
            case .aviDVPCM16, .rawDV: return ["-c:v", "dvvideo", "-pix_fmt", "yuv411p"]
            case .mp4H264AAC: return ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"]
            }
        }
        var audioArgs: [String] {
            switch self {
            case .movProResPCM24, .mkvFFV1PCM24: return ["-c:a", "pcm_s24le"]
            case .movProResFloat: return ["-c:a", "pcm_f32le"]
            case .mp4H264AAC: return ["-c:a", "aac", "-b:a", "128k"]
            default: return ["-c:a", "pcm_s16le"]
            }
        }
        /// The decoded sample format ffprobe states for the wrapper's audio.
        var sampleFormat: String {
            switch self {
            case .movProResPCM24, .mkvFFV1PCM24: return "s32"
            case .movProResFloat: return "flt"
            case .mp4H264AAC: return "fltp"
            default: return "s16"
            }
        }
    }

    static func scratch(_ label: String) throws -> URL {
        try BalanceAudioTestMedia.makeScratchDir("proof_\(label)")
    }

    /// A 2-second one-sided original. `extra` goes before the output name
    /// (e.g. `-timecode` to give a QuickTime file a tmcd track).
    static func original(in dir: URL, _ wrapper: Wrapper, channels: String = leftOnly,
                         extra: [String] = []) throws -> String {
        let out = dir.appendingPathComponent("test_proof_\(wrapper.rawValue).\(wrapper.ext)").path
        let picture = wrapper.isDV || wrapper == .mxfPCM16
            ? "testsrc=duration=2:size=720x480:rate=30000/1001"
            : "testsrc=duration=2:size=320x240:rate=25"
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", picture, "-f", "lavfi", "-i", "aevalsrc=\(channels):s=48000:d=2",
             "-map", "0:v:0", "-map", "1:a:0"] + wrapper.videoArgs + wrapper.audioArgs + extra,
            output: out)
        return out
    }

    /// Balance `original` the way BalanceAudioJob renders it: the job's own
    /// analysis and argument builders, straight to the planned output name.
    static func balance(_ original: String) async throws -> String {
        let analysis = try await AudioBalanceProbe.analyze(path: original)
        let pan = try #require(BalanceAudioFix.panFilter(for: analysis.classification),
                               "fixture is not one-sided: \(analysis.classification.rawValue)")
        let output = BalanceAudioFix.balancedOutputURL(
            forSourcePath: original, containerFormat: analysis.shape.containerFormat).path
        let args = BalanceAudioFix.ffmpegArgs(
            input: original, output: output,
            mapArgs: BalanceAudioFix.mapArgs(audioStreams: analysis.shape.audioStreams,
                                             programStreamIndex: analysis.programStreamIndex),
            panFilter: pan,
            audioArgs: BalanceAudioFix.audioEncodeArgs(sourceCodec: analysis.shape.audioCodec,
                                                       bitRateBitsPerSec: analysis.shape.audioBitRate),
            inputArgs: BalanceAudioFix.rawDVInputArgs(shape: analysis.shape))
        let result = await ProcessRunner.runProcess(executable: ToolLocator.ffmpegPath, arguments: args,
                                                    deadlineSeconds: 120)
        try #require(result.exitCode == 0, "balance render failed: \(result.stderr.suffix(400))")
        return output
    }

    /// A damaged stand-in for the balanced copy, made from `input` with the
    /// given ffmpeg arguments (between `-i input` and the output name).
    static func derive(_ name: String, from input: String, _ args: [String], secondInput: String? = nil) throws -> String {
        let url = URL(fileURLWithPath: input)
        let out = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).\(url.pathExtension)").path
        var all = ["-i", input]
        if let secondInput { all += ["-i", secondInput] }
        try BalanceAudioTestMedia.runFFmpeg(all + args, output: out)
        return out
    }

    static func sha256(ofFile path: String) throws -> String {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Name → SHA-256 of every file in `dir`.
    static func folderDigest(_ dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            out[name] = try sha256(ofFile: dir.appendingPathComponent(name).path)
        }
        return out
    }
}

@Suite("Balanced copy proof — real media through the balance job's own render", .serialized)
struct BalancedCopyProofMediaTests {

    typealias Proof = BalancedCopyProof
    typealias Media = BalancedCopyProofMedia
    private let fm = FileManager.default

    /// A proven pair in a fresh folder: mov/prores + 16-bit PCM, left only,
    /// with a timecode track (the shape of a captured tape).
    private func provenPair(_ label: String) async throws -> (dir: URL, original: String, balanced: String) {
        let dir = try Media.scratch(label)
        let original = try Media.original(in: dir, .movProResPCM16, extra: ["-timecode", "01:00:00:00"])
        let balanced = try await Media.balance(original)
        return (dir, original, balanced)
    }

    // MARK: Media matrix

    @Test("MATRIX: a lossless one-sided original balanced by the job's own render is PROVEN in every wrapper",
          .timeLimit(.minutes(3)),
          arguments: [Media.Wrapper.movProResPCM16, .movProResPCM24, .movProResFloat, .mkvFFV1PCM16,
                      .mkvFFV1PCM24, .mxfPCM16, .aviDVPCM16, .rawDV])
    func losslessWrappersAreProven(_ wrapper: Media.Wrapper) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch(wrapper.rawValue)
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, wrapper)
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        guard case .proven(let evidence) = outcome else {
            Issue.record("\(wrapper.rawValue): expected proven, got \(outcome)")
            return
        }
        #expect(evidence.liveChannel == 0)
        #expect(evidence.originalClass == .leftOnly)
        #expect(evidence.sampleFormat == wrapper.sampleFormat)
        #expect(evidence.sampleRateHz == 48_000)
        #expect(evidence.soundCodec.hasPrefix("pcm_"))
        #expect(evidence.soundSHA256.count == 64 && evidence.soundSHA256 != Proof.emptySHA256)
        #expect(evidence.carried.first?.kind == "video")
        #expect(evidence.carried.allSatisfy { $0.packetSHA256.count == 64 && $0.packetSHA256 != Proof.emptySHA256 })
        #expect(evidence.originalStamp == FileIdentityStamp.capture(path: original))
        #expect(evidence.balancedStamp == FileIdentityStamp.capture(path: balanced))
        #expect(evidence.originalResolvedPath == SourceTree.canonicalPath(URL(fileURLWithPath: original)))
        // What the hardened proof also holds, on what the job really writes:
        // the channel left behind is digital silence, every stream's packets
        // were counted, and the sound was decoded to the end.
        #expect(evidence.discarded == Proof.Evidence.Discarded(channel: 1, peakDBFS: -.infinity))
        #expect(evidence.carried.allSatisfy { $0.packets >= 50 })
        #expect(evidence.soundSamples >= 94_000 && evidence.soundSamples <= 96_096)
        let line = Proof.logLine(original: original, balanced: balanced, outcome: outcome)
        #expect(line.contains("original right: digital silence, not in the copy") && !line.contains("\n"))
        // Raw DV is the one wrapper whose copy changes container (.mov) and
        // gains the muxer's timecode track.
        #expect(evidence.gainedTimecodeTrack == (wrapper == .rawDV))
        #expect(URL(fileURLWithPath: balanced).pathExtension == (wrapper == .rawDV ? "mov" : wrapper.ext))
    }

    @Test("MATRIX: a right-only original is proven against its RIGHT channel", .timeLimit(.minutes(2)))
    func rightOnlyIsProvenAgainstTheRightChannel() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("right")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .mkvFFV1PCM16, channels: Media.rightOnly)
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        guard case .proven(let evidence) = outcome else { Issue.record("\(outcome)"); return }
        #expect(evidence.liveChannel == 1)
        #expect(evidence.originalClass == .rightOnly)
        // Truth: the hash is the RIGHT channel's, computed here by another road.
        let raw = dir.appendingPathComponent("right.raw").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-i", original, "-map", "0:a:0", "-af", "pan=mono|c0=c1", "-f", "s16le", "-c:a", "pcm_s16le"], output: raw)
        let independent = try Media.sha256(ofFile: raw)
        #expect(evidence.soundSHA256 == independent)
    }

    @Test("MATRIX: mp4/h264 + AAC is NOT PROVEN by design — the sound was re-encoded", .timeLimit(.minutes(2)))
    func lossyOriginalIsNotProven() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("aac")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .mp4H264AAC)
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        #expect(outcome == .notProven(.soundReencoded(codec: "aac")))
        #expect(Proof.logLine(original: original, balanced: balanced, outcome: outcome)
            .hasSuffix("the sound was re-encoded (aac) — the original is kept"))
    }

    @Test("MATRIX: an original with two sound tracks (the 12-bit DV shape) is NOT PROVEN — the copy drops a track",
          .timeLimit(.minutes(2)))
    func twoSoundTracksAreNotProven() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("twopair")
        defer { try? fm.removeItem(at: dir) }
        let original = try BalanceAudioTestMedia.generateTwoAudioPairs(
            into: dir, label: "proof", pair1: Media.leftOnly, pair2: "0|0", container: .movPcm)
        let balanced = try await Media.balance(original)

        #expect(await Proof.measure(original: original, balanced: balanced) == .notProven(.originalSoundTracks(2)))
    }

    // MARK: Truth + read-only

    @Test("TRUTH + SENSOR: the evidence hashes equal hashes made here by another road, and the proof touches nothing",
          .timeLimit(.minutes(2)))
    func evidenceIsTrueAndTheProofIsReadOnly() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("truth")
        defer { try? fm.removeItem(at: dir) }
        let before = try Media.folderDigest(dir)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        let after = try Media.folderDigest(dir)
        #expect(after == before, "the proof must not create, change or remove any file")
        guard case .proven(let evidence) = outcome else { Issue.record("\(outcome)"); return }

        // Picture: ffmpeg's framehash muxer (another tool than the proof's
        // ffprobe packet pass) lists every packet as "stream, dts, pts,
        // duration, size, sha256"; folded HERE the way the header says.
        let listing = await ProcessRunner.runProcess(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-v", "error", "-i", original, "-map", "0:v:0", "-c", "copy", "-f", "framehash", "-hash", "sha256", "-"],
            deadlineSeconds: 60)
        var bytes = SHA256(), times = SHA256(), packets = 0
        var ticksPerSecond: Int64 = 0
        for line in (listing.stdout ?? "").split(separator: "\n") {
            if line.hasPrefix("#tb 0: 1/") { ticksPerSecond = Int64(line.dropFirst("#tb 0: 1/".count)) ?? 0 }
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard !line.hasPrefix("#"), fields.count == 6, let pts = Int64(fields[2]), let duration = Int64(fields[3]) else { continue }
            func fraction(_ ticks: Int64) -> String {
                var a = abs(ticks), b = ticksPerSecond
                while b != 0 { (a, b) = (b, a % b) }
                return "\(ticks / max(a, 1))/\(ticksPerSecond / max(a, 1))"
            }
            bytes.update(data: Data("\(fields[4]) \(fields[5])\n".utf8))
            times.update(data: Data("\(fraction(pts)) \(fraction(duration))\n".utf8))
            packets += 1
        }
        func hex(_ hasher: SHA256) -> String { hasher.finalize().map { String(format: "%02x", $0) }.joined() }
        let heldPicture = try #require(evidence.carried.first, "the evidence names no carried stream")
        #expect(ticksPerSecond == 12_800 && packets == 50)
        #expect(heldPicture.packets == packets)
        #expect(heldPicture.packetSHA256 == hex(bytes))
        #expect(heldPicture.timingSHA256 == hex(times))
        #expect(evidence.carried.map(\.kind) == ["video", "data"], "the original's timecode track is held too")

        // Sound: the original's left channel written out as raw PCM with the
        // pan filter, hashed in this process.
        let raw = dir.appendingPathComponent("left.raw").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-i", original, "-map", "0:a:0", "-af", "pan=mono|c0=c0", "-f", "s16le", "-c:a", "pcm_s16le"], output: raw)
        let independent = try Media.sha256(ofFile: raw)
        #expect(evidence.soundSHA256 == independent)
        let samples = (try fm.attributesOfItem(atPath: raw)[.size] as? NSNumber)?.intValue ?? 0
        #expect(samples == 2 * 48_000 * 2, "2 s of 48 kHz 16-bit mono")

        // The log line carries exactly those hashes.
        let line = Proof.logLine(original: original, balanced: balanced, outcome: outcome)
        #expect(line.contains(evidence.soundSHA256) && line.contains(heldPicture.packetSHA256))
        #expect(line.contains(original) && line.contains(balanced))
    }

    // MARK: Negatives — the proof must say no

    @Test("NEGATIVE: a copy whose picture was re-encoded is not proven", .timeLimit(.minutes(2)))
    func reencodedPictureIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("revideo")
        defer { try? fm.removeItem(at: dir) }
        let bad = try Media.derive("revideo_balanced", from: balanced,
                                   ["-map", "0", "-c", "copy", "-c:v", "prores_ks", "-profile:v", "0", "-q:v", "20"])

        let outcome = await Proof.measure(original: original, balanced: bad)
        guard case .notProven(.carriedStreamDiffers(let kind, _, _, _)) = outcome else {
            Issue.record("expected the picture to be refused, got \(outcome)")
            return
        }
        #expect(kind == "video")
    }

    @Test("NEGATIVE: a copy whose sound was turned down 1 dB is not proven", .timeLimit(.minutes(2)))
    func attenuatedSoundIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("quiet")
        defer { try? fm.removeItem(at: dir) }
        let bad = try Media.derive("quiet_balanced", from: balanced,
                                   ["-map", "0", "-c", "copy", "-af", "volume=-1dB", "-c:a", "pcm_s16le"])

        let outcome = await Proof.measure(original: original, balanced: bad)
        guard case .notProven(.soundDiffers) = outcome else {
            Issue.record("expected the sound to be refused, got \(outcome)")
            return
        }
    }

    @Test("NEGATIVE: a copy whose two channels differ — by a whole channel, or by a hair — is not proven",
          .timeLimit(.minutes(2)))
    func differingChannelsAreRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, _) = try await provenPair("channels")
        defer { try? fm.removeItem(at: dir) }
        // Still one-sided: a plain remux of the original under a balanced name.
        let unbalanced = try Media.derive("still_one_sided_balanced", from: original, ["-map", "0", "-c", "copy"])
        // Right channel 0.01 % quieter than left.
        let hair = try Media.derive("hair_balanced", from: original,
                                    ["-map", "0", "-c", "copy", "-af", "pan=stereo|c0=c0|c1=0.9999*c0",
                                     "-c:a", "pcm_s16le"])
        for bad in [unbalanced, hair] {
            let outcome = await Proof.measure(original: original, balanced: bad)
            guard case .notProven(.channelsDiffer) = outcome else {
                Issue.record("\((bad as NSString).lastPathComponent): expected channelsDiffer, got \(outcome)")
                continue
            }
        }
    }

    @Test("NEGATIVE: a truncated copy — whole file cut short, or only its sound — is not proven",
          .timeLimit(.minutes(2)))
    func truncatedCopyIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("short")
        defer { try? fm.removeItem(at: dir) }
        let half = try Media.derive("half_balanced", from: balanced, ["-t", "1", "-map", "0", "-c", "copy"])
        // Since Codex #298 F2/F3 ffprobe's own packet count refuses it, before any hash pass.
        let outcome = await Proof.measure(original: original, balanced: half)
        #expect(outcome == .notProven(.timingDiffers("video stream 0 has 50 packets, the balanced copy 25")))
        // Picture whole, last 10 ms of sound missing.
        let shortSound = try Media.derive("short_sound_balanced", from: balanced,
                                          ["-map", "0", "-c", "copy", "-af", "atrim=end=1.99", "-c:a", "pcm_s16le"])
        let soundOutcome = await Proof.measure(original: original, balanced: shortSound)
        #expect(soundOutcome == .notProven(.timingDiffers(
            "the sound lasts 2.000000 s, in the balanced copy 1.990000 s")))
    }

    @Test("NEGATIVE: a copy with an extra stream or a missing stream is not proven", .timeLimit(.minutes(2)))
    func extraOrMissingStreamIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("streams")
        defer { try? fm.removeItem(at: dir) }

        let extraSound = try Media.derive("extra_sound_balanced", from: balanced,
                                          ["-map", "0", "-map", "1:a", "-c", "copy"], secondInput: balanced)
        #expect(await Proof.measure(original: original, balanced: extraSound) == .notProven(.balancedSoundTracks(2)))

        let extraPicture = try Media.derive("extra_picture_balanced", from: balanced,
                                            ["-map", "0", "-map", "1:v", "-c", "copy"], secondInput: balanced)
        let extraOutcome = await Proof.measure(original: original, balanced: extraPicture)
        guard case .notProven(.streamsDiffer) = extraOutcome else {
            Issue.record("extra picture: \(extraOutcome)")
            return
        }

        let noPicture = try Media.derive("no_picture_balanced", from: balanced, ["-map", "0:a", "-c", "copy"])
        let noPictureOutcome = await Proof.measure(original: original, balanced: noPicture)
        guard case .notProven(.streamsDiffer) = noPictureOutcome else {
            Issue.record("no picture: \(noPictureOutcome)")
            return
        }

        // The original's timecode track left behind.
        let noTimecode = try Media.derive("no_timecode_balanced", from: balanced,
                                          ["-map", "0:v", "-map", "0:a", "-c", "copy", "-write_tmcd", "0"])
        let noTimecodeOutcome = await Proof.measure(original: original, balanced: noTimecode)
        guard case .notProven(.streamsDiffer) = noTimecodeOutcome else {
            Issue.record("no timecode: \(noTimecodeOutcome)")
            return
        }
    }

    @Test("NEGATIVE: the two files the wrong way round are not proven — a balanced file is not a one-sided original",
          .timeLimit(.minutes(2)))
    func swappedFilesAreRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("swapped")
        defer { try? fm.removeItem(at: dir) }
        #expect(await Proof.measure(original: balanced, balanced: original)
                == .notProven(.originalNotOneSided(.dualMono)))
    }

    // MARK: Isolation — could not check

    @Test("ISOLATION: a missing, unreadable or doubled file, or a tool that fails, is COULD NOT CHECK — never proven",
          .timeLimit(.minutes(2)))
    func unmeasurableIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("unchecked")
        defer { try? fm.removeItem(at: dir) }
        func reason(_ outcome: Proof.Outcome) -> String? {
            if case .couldNotCheck(let why) = outcome { return why }
            return nil
        }
        let nowhere = dir.appendingPathComponent("gone.mov").path

        #expect(reason(await Proof.measure(original: nowhere, balanced: balanced))?.contains("the original is not on disk") == true)
        #expect(reason(await Proof.measure(original: original, balanced: nowhere))?.contains("the balanced copy is not on disk") == true)
        // A folder is not a file.
        #expect(reason(await Proof.measure(original: original, balanced: dir.path))?.contains("the balanced copy is not on disk") == true)
        // One file under both names.
        #expect(reason(await Proof.measure(original: original, balanced: original))?.contains("the same file") == true)
        let link = dir.appendingPathComponent("link_balanced.mov").path
        try fm.linkItem(atPath: original, toPath: link)
        #expect(reason(await Proof.measure(original: original, balanced: link))?.contains("the same file") == true)

        // Bytes that are not media.
        let junk = dir.appendingPathComponent("junk_balanced.mov").path
        try Data(repeating: 0x5a, count: 64 * 1024).write(to: URL(fileURLWithPath: junk))
        #expect(reason(await Proof.measure(original: original, balanced: junk))?.contains("could not be read as media") == true)
        #expect(reason(await Proof.measure(original: junk, balanced: balanced)) != nil)

        // The tools: absent, then present but failing.
        let noTools = Proof.Tools(ffmpeg: "/nonexistent/ffmpeg", ffprobe: ToolLocator.ffprobePath)
        #expect(reason(await Proof.measure(original: original, balanced: balanced, tools: noTools))?.contains("not found") == true)
        let failing = Proof.Tools(ffmpeg: "/usr/bin/false", ffprobe: ToolLocator.ffprobePath)
        #expect(reason(await Proof.measure(original: original, balanced: balanced, tools: failing))?.contains("could not be read to the end") == true)
        let failingProbe = Proof.Tools(ffmpeg: ToolLocator.ffmpegPath, ffprobe: "/usr/bin/false")
        #expect(reason(await Proof.measure(original: original, balanced: balanced, tools: failingProbe))?.contains("could not be read as media") == true)

        // And the pair itself is good: the same call with the real tools proves it.
        #expect(await Proof.measure(original: original, balanced: balanced).isProven)
    }

    @Test("ISOLATION: a copy that is modified while it is being read is COULD NOT CHECK, though its hashes match",
          .timeLimit(.minutes(2)))
    func fileChangedDuringTheCheckIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("changed")
        defer { try? fm.removeItem(at: dir) }
        // An ffmpeg that re-stamps the balanced copy (same bytes, new
        // modification time) before doing the real work.
        let tools = dir.appendingPathComponent("tools", isDirectory: true)
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        let fake = tools.appendingPathComponent("ffmpeg")
        try """
        #!/bin/sh
        /usr/bin/touch "\(balanced)"
        exec "\(ToolLocator.ffmpegPath)" "$@"
        """.write(to: fake, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let outcome = await Proof.measure(
            original: original, balanced: balanced,
            tools: Proof.Tools(ffmpeg: fake.path, ffprobe: ToolLocator.ffprobePath))
        #expect(outcome == .couldNotCheck("a file changed while it was being checked"))
        // The same pair, left alone, is proven.
        #expect(await Proof.measure(original: original, balanced: balanced).isProven)
    }

    @Test("ISOLATION: a check that is cancelled says could not check", .timeLimit(.minutes(2)))
    func cancelledCheckIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("cancelled")
        defer { try? fm.removeItem(at: dir) }
        let task = Task { () -> Proof.Outcome in
            withUnsafeCurrentTask { $0?.cancel() }
            return await Proof.measure(original: original, balanced: balanced)
        }
        let outcome = await task.value
        guard case .couldNotCheck = outcome else { Issue.record("\(outcome)"); return }
    }
}
