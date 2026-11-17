// BalancedCopyProofMediaTests.swift
// BalancedCopyProof.measure on REAL (tiny, synthetic) media. Every fixture
// is generated here with ffmpeg lavfi, one-sided, and balanced with the
// balance job's own argument builders (BalanceAudioFix.ffmpegArgs / mapArgs
// / panFilter / audioEncodeArgs / rawDVInputArgs / balancedOutputURL) — so
// a change to what the job renders shows up here as a proof that says no.
//
// Dimensions: MEDIA MATRIX (mov/prores, mkv/ffv1, mxf, avi/dv, raw dv → mov,
// mp4/h264+aac; 16-bit, 24-bit, float) · TRUTH (the evidence digests equal
// digests computed here by another road) · ISOLATION (missing, unreadable
// and swapped files; a tool that fails) · SENSOR (both files and their
// folder are byte-for-byte untouched by the proof). The negatives are the
// point: each damaged copy must be refused, with the right reason.
// The Codex reproductions are in the Hardening (#298), Packet (#301) and
// Presentation (#304, and the 2026-11-17 ruling) suites.

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
        /// What differs between the job's own copy and its original, by kind
        /// — measured 2026-11-17. Raw DV becomes QuickTime: a timecode
        /// track gained, another container, tracks marked "default" (raw DV
        /// has no such flag), the muxer's own tags. An MXF file's UMIDs are
        /// its identity and are new in every file.
        var expectedDifferences: [BalancedCopyProof.Difference.Kind] {
            switch self {
            case .rawDV: return [.track, .container, .playback, .metadata]
            case .mxfPCM16: return [.metadata]
            default: return []
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

    static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static func sha256(ofFile path: String) throws -> String {
        sha256(try Data(contentsOf: URL(fileURLWithPath: path)))
    }

    /// Name → SHA-256 of every file in `dir`.
    static func folderDigest(_ dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            out[name] = try sha256(ofFile: dir.appendingPathComponent(name).path)
        }
        return out
    }

    /// The proof's sound digest made by ANOTHER road: one channel written to
    /// a raw PCM file with the `pan` filter, cut HERE into one-second pieces,
    /// each hashed here, folded as "<bytes> <sha256>" lines.
    static func channelDigest(of path: String, channel: Int, in dir: URL, bytesPerSecond: Int = 96_000) throws -> (digest: String, bytes: Int) {
        let raw = dir.appendingPathComponent("channel_\(UUID().uuidString.prefix(6)).raw").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-i", path, "-map", "0:a:0", "-af", "pan=mono|c0=c\(channel)", "-f", "s16le", "-c:a", "pcm_s16le"], output: raw)
        let pcm = try Data(contentsOf: URL(fileURLWithPath: raw))
        var fold = SHA256()
        var at = 0
        while at < pcm.count {
            let piece = pcm.subdata(in: at..<min(at + bytesPerSecond, pcm.count))
            fold.update(data: Data("\(piece.count) \(sha256(piece))\n".utf8))
            at += piece.count
        }
        return (fold.finalize().map { String(format: "%02x", $0) }.joined(), pcm.count)
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

    @Test("MATRIX: a lossless one-sided original balanced by the job's own render PLAYS THE SAME in every wrapper — proven the same, or the same content with each difference named",
          .timeLimit(.minutes(3)),
          arguments: [Media.Wrapper.movProResPCM16, .movProResPCM24, .movProResFloat, .mkvFFV1PCM16,
                      .mkvFFV1PCM24, .mxfPCM16, .aviDVPCM16, .rawDV])
    func losslessWrappersPlayTheSame(_ wrapper: Media.Wrapper) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch(wrapper.rawValue)
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, wrapper)
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        guard let evidence = outcome.evidence else {
            Issue.record("\(wrapper.rawValue): expected the same content, got \(outcome)")
            return
        }
        #expect(outcome.differences.map(\.kind) == wrapper.expectedDifferences, "\(outcome.differences)")
        #expect(outcome.isProven == wrapper.expectedDifferences.isEmpty)
        #expect(evidence.liveChannel == 0 && evidence.originalClass == .leftOnly)
        #expect(evidence.sampleFormat == wrapper.sampleFormat && evidence.sampleRateHz == 48_000)
        #expect(evidence.soundCodec.hasPrefix("pcm_"))
        #expect(evidence.soundSHA256.count == 64 && evidence.soundSHA256 != Proof.emptySHA256)
        #expect(evidence.soundStartSeconds == 0)
        // The picture: every frame decoded and held, and — the second evidence — its packets identical too.
        let picture = try #require(evidence.streams.first)
        #expect(evidence.streams.count == 1 && picture.kind == "video" && picture.packetIdentical)
        #expect((picture.frames ?? 0) >= 50 && picture.frames == picture.packets)
        #expect(picture.framesSHA256?.count == 64 && picture.framesSHA256 != Proof.emptySHA256)
        #expect(picture.packetSHA256.count == 64 && picture.packetSHA256 != picture.framesSHA256)
        #expect(evidence.originalStamp == FileIdentityStamp.capture(path: original))
        #expect(evidence.balancedStamp == FileIdentityStamp.capture(path: balanced))
        #expect(evidence.originalResolvedPath == SourceTree.canonicalPath(URL(fileURLWithPath: original)))
        // The channel left behind is digital silence, and the sound was decoded to the end.
        #expect(evidence.discarded == Proof.Evidence.Discarded(channel: 1, peakDBFS: -.infinity))
        #expect(evidence.soundSamples >= 94_000 && evidence.soundSamples <= 96_096)
        let line = Proof.logLine(original: original, balanced: balanced, outcome: outcome)
        #expect(line.contains("original right: digital silence, not in the copy") && !line.contains("\n"))
        #expect(line.contains("stored packets identical"))
        // Raw DV is the one wrapper whose copy changes container (.mov) and gains the muxer's timecode track.
        #expect(URL(fileURLWithPath: balanced).pathExtension == (wrapper == .rawDV ? "mov" : wrapper.ext))
        if wrapper == .rawDV {
            #expect(outcome.differences.prefix(2) == [
                Proof.Difference(kind: .track, heldOnlyBy: .balancedCopy, what: "a timecode track"),
                Proof.Difference(kind: .container, heldOnlyBy: nil, what: "the original is a dv file, the balanced copy a mov file")
            ])
            // Nothing the ORIGINAL holds is missing from the copy: its one tag, the timecode, is on the copy's tracks.
            #expect(outcome.differences.allSatisfy { $0.heldOnlyBy != .original }, "\(outcome.differences)")
            #expect(outcome.differences.contains(Proof.Difference(
                kind: .playback, heldOnlyBy: nil,
                what: "track flags differ: picture stream 0 (the balanced copy only: default); the sound (the balanced copy only: default)")))
            #expect(line.contains("OUTCOME SAME CONTENT, DIFFERS IN 4"))
        }
    }

    @Test("MATRIX: a right-only original plays the same against its RIGHT channel", .timeLimit(.minutes(2)))
    func rightOnlyIsProvenAgainstTheRightChannel() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("right")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .mkvFFV1PCM16, channels: Media.rightOnly)
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        guard case .proven(let evidence) = outcome else { Issue.record("\(outcome)"); return }
        #expect(evidence.liveChannel == 1 && evidence.originalClass == .rightOnly)
        // Truth: the digest is the RIGHT channel's, computed here by another road — and not the left's.
        let right = try Media.channelDigest(of: original, channel: 1, in: dir).digest
        let left = try Media.channelDigest(of: original, channel: 0, in: dir).digest
        #expect(evidence.soundSHA256 == right && evidence.soundSHA256 != left)
    }

    @Test("MATRIX: mp4/h264 + AAC is NOT THE SAME by design — the sound was re-encoded", .timeLimit(.minutes(2)))
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

    @Test("MATRIX: two sound tracks in a recording that is NOT DV — the copy drops one — is NOT THE SAME",
          .timeLimit(.minutes(2)))
    func twoSoundTracksOutsideDVAreNotProven() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("twopair")
        defer { try? fm.removeItem(at: dir) }
        let original = try BalanceAudioTestMedia.generateTwoAudioPairs(
            into: dir, label: "proof", pair1: Media.leftOnly, pair2: "0|0", container: .movPcm)
        let balanced = try await Media.balance(original)

        #expect(await Proof.measure(original: original, balanced: balanced) == .notProven(.spareSoundTrack(
            "2 sound tracks; a spare one may be left behind only in a DV recording, and its picture is h264")))
    }

    // MARK: Truth + read-only

    @Test("TRUTH + SENSOR: the evidence digests equal digests made here by another road, and the proof touches nothing",
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
        let heldPicture = try #require(evidence.streams.first, "the evidence names no stream")
        #expect(evidence.streams.map(\.kind) == ["video", "data"], "the original's timecode track is held too")

        // DECODED PICTURE, by another road: every frame written to one raw
        // file by the rawvideo muxer (the proof uses framehash), cut HERE
        // into frames, each hashed here, folded with the times a 25 fps
        // recording has. 320×240 yuv444p10le is 460,800 bytes a frame.
        let raw = dir.appendingPathComponent("frames.raw").path
        try BalanceAudioTestMedia.runFFmpeg(["-i", balanced, "-map", "0:v:0", "-f", "rawvideo", "-pix_fmt", "yuv444p10le"], output: raw)
        let pixels = try Data(contentsOf: URL(fileURLWithPath: raw))
        #expect(pixels.count == 50 * 460_800)
        var played = SHA256()
        played.update(data: Data("#dimensions 320x240\n#sar 1/1\n".utf8))
        for n in 0..<50 {
            let frame = pixels.subdata(in: (n * 460_800)..<((n + 1) * 460_800))
            let at = n == 0 ? "0/1" : "\(n / gcd(n, 25))/\(25 / gcd(n, 25))"
            played.update(data: Data("\(at) 1/25 460800 \(Media.sha256(frame))\n".utf8))
        }
        #expect(heldPicture.frames == 50)
        #expect(heldPicture.framesSHA256 == played.finalize().map { String(format: "%02x", $0) }.joined())

        // STORED PACKETS, by another road: ffmpeg's framehash muxer over the
        // stream COPY lists every packet as "stream, dts, pts, duration,
        // size, sha256" (the proof's packet pass is ffprobe); folded here.
        let listing = await ProcessRunner.runProcess(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-v", "error", "-i", original, "-map", "0:v:0", "-c", "copy", "-f", "framehash", "-hash", "sha256", "-"],
            deadlineSeconds: 60)
        var bytes = SHA256(), packets = 0
        for line in (listing.stdout ?? "").split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 6 else { continue }
            bytes.update(data: Data("\(fields[4]) \(fields[5])\n".utf8))
            packets += 1
        }
        #expect(packets == 50 && heldPicture.packets == packets && heldPicture.packetIdentical)
        #expect(heldPicture.packetSHA256 == bytes.finalize().map { String(format: "%02x", $0) }.joined())

        // SOUND, by another road: the original's left channel written out as raw PCM with the pan filter.
        let sound = try Media.channelDigest(of: original, channel: 0, in: dir)
        #expect(evidence.soundSHA256 == sound.digest)
        #expect(sound.bytes == 2 * 48_000 * 2, "2 s of 48 kHz 16-bit mono")
        #expect(evidence.soundSamples == 96_000)

        // The log line carries exactly those digests.
        let line = Proof.logLine(original: original, balanced: balanced, outcome: outcome)
        #expect(line.contains(evidence.soundSHA256) && line.contains(heldPicture.packetSHA256))
        #expect(line.contains(heldPicture.framesSHA256 ?? "?") && line.contains(original) && line.contains(balanced))
    }

    private func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }

    // MARK: Negatives — the proof must say no

    @Test("NEGATIVE: a copy whose picture was re-encoded lossily is not the same", .timeLimit(.minutes(2)))
    func reencodedPictureIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("revideo")
        defer { try? fm.removeItem(at: dir) }
        let bad = try Media.derive("revideo_balanced", from: balanced,
                                   ["-map", "0", "-c", "copy", "-c:v", "prores_ks", "-profile:v", "0", "-q:v", "20"])

        let outcome = await Proof.measure(original: original, balanced: bad)
        guard case .notProven(.pictureDiffers(0, let what)) = outcome else {
            Issue.record("expected the picture to be refused, got \(outcome)")
            return
        }
        #expect(what.hasPrefix("its frames are not the original's"))
    }

    @Test("NEGATIVE: a copy whose sound was turned down 1 dB is not the same", .timeLimit(.minutes(2)))
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

    @Test("NEGATIVE: a copy whose two channels differ — by a whole channel, or by a hair — is not the same",
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

    @Test("NEGATIVE: a truncated copy — whole file cut short, or only its sound — is not the same",
          .timeLimit(.minutes(2)))
    func truncatedCopyIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("short")
        defer { try? fm.removeItem(at: dir) }
        let half = try Media.derive("half_balanced", from: balanced, ["-t", "1", "-map", "0", "-c", "copy"])
        let outcome = await Proof.measure(original: original, balanced: half)
        #expect(outcome == .notProven(.pictureDiffers(originalIndex: 0, "50 frames play in the original, 25 in the balanced copy")))
        // Picture whole, last 10 ms of sound missing.
        let shortSound = try Media.derive("short_sound_balanced", from: balanced,
                                          ["-map", "0", "-c", "copy", "-af", "atrim=end=1.99", "-c:a", "pcm_s16le"])
        let soundOutcome = await Proof.measure(original: original, balanced: shortSound)
        guard case .notProven(.soundDiffers) = soundOutcome else {
            Issue.record("expected the short sound to be refused, got \(soundOutcome)")
            return
        }
    }

    @Test("NEGATIVE: a second sound track or a second picture in the copy, or no picture, is not the same; a dropped timecode track is NAMED as held by the original",
          .timeLimit(.minutes(2)))
    func extraOrMissingStream() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("streams")
        defer { try? fm.removeItem(at: dir) }

        let extraSound = try Media.derive("extra_sound_balanced", from: balanced,
                                          ["-map", "0", "-map", "1:a", "-c", "copy"], secondInput: balanced)
        #expect(await Proof.measure(original: original, balanced: extraSound) == .notProven(.balancedSoundTracks(2)))

        let extraPicture = try Media.derive("extra_picture_balanced", from: balanced,
                                            ["-map", "0", "-map", "1:v", "-c", "copy"], secondInput: balanced)
        #expect(await Proof.measure(original: original, balanced: extraPicture)
                == .notProven(.streamsDiffer("the original has 1 picture streams, the balanced copy 2")))

        let noPicture = try Media.derive("no_picture_balanced", from: balanced, ["-map", "0:a", "-c", "copy"])
        #expect(await Proof.measure(original: original, balanced: noPicture)
                == .notProven(.streamsDiffer("the original has 1 picture streams, the balanced copy 0")))

        // The original's timecode track left behind: the picture and the sound
        // play the same, and the original HOLDS something the copy does not.
        let noTimecode = try Media.derive("no_timecode_balanced", from: balanced,
                                          ["-map", "0:v", "-map", "0:a", "-c", "copy", "-write_tmcd", "0"])
        let outcome = await Proof.measure(original: original, balanced: noTimecode)
        guard case .sameContent(_, let differs) = outcome else {
            Issue.record("no timecode: expected the same content with the track named, got \(outcome)")
            return
        }
        #expect(differs.first == Proof.Difference(kind: .track, heldOnlyBy: .original, what: "a timecode track"), "\(differs)")
        #expect(differs.allSatisfy { $0.heldOnlyBy != .balancedCopy }, "\(differs)")
        #expect(!outcome.isProven)
    }

    @Test("NEGATIVE: the two files the wrong way round are not the same — a balanced file is not a one-sided original",
          .timeLimit(.minutes(2)))
    func swappedFilesAreRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await provenPair("swapped")
        defer { try? fm.removeItem(at: dir) }
        #expect(await Proof.measure(original: balanced, balanced: original)
                == .notProven(.originalNotOneSided(.dualMono)))
    }

    // MARK: Isolation — could not check

    @Test("ISOLATION: a missing, unreadable or doubled file, or a tool that fails, is COULD NOT CHECK — never the same",
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
        #expect(reason(await Proof.measure(original: original, balanced: junk)) == "the balanced copy could not be read as media")
        #expect(reason(await Proof.measure(original: junk, balanced: balanced)) != nil)

        // The tools: absent, then present but failing.
        let noTools = Proof.Tools(ffmpeg: "/nonexistent/ffmpeg", ffprobe: ToolLocator.ffprobePath)
        #expect(reason(await Proof.measure(original: original, balanced: balanced, tools: noTools))?.contains("not found") == true)
        let failing = Proof.Tools(ffmpeg: "/usr/bin/false", ffprobe: ToolLocator.ffprobePath)
        #expect(reason(await Proof.measure(original: original, balanced: balanced, tools: failing))?
            .hasPrefix("the original could not be decoded to the end (ffmpeg status 1") == true)
        let failingProbe = Proof.Tools(ffmpeg: ToolLocator.ffmpegPath, ffprobe: "/usr/bin/false")
        #expect(reason(await Proof.measure(original: original, balanced: balanced, tools: failingProbe))
                == "the original could not be read as media")

        // And the pair itself is good: the same call with the real tools proves it.
        #expect(await Proof.measure(original: original, balanced: balanced).isProven)
    }

    @Test("ISOLATION: a copy that is modified while it is being read is COULD NOT CHECK, though its digests match",
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
