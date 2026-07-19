// BalanceAudioTestSupport.swift
// Shared fixtures for the Balance Audio suite (GH #116).
//
// Channel-case fixtures are generated at test time with ffmpeg's
// `aevalsrc` source — per-channel expressions give exact control over
// which channel carries program:
//
//   left-only   0.5*sin(440·2πt) | 0
//   right-only  0                | 0.5*sin(440·2πt)
//   dual-mono   identical expressions on both channels
//   true-stereo different frequencies per channel (decorrelated)
//   silent      0 | 0
//   mono        a single expression (1-channel stream)
//   5.1         six copies of the sine (multichannel, not-applicable v1)
//
// Same conventions as CleanupTestMedia: `test_` filename prefix,
// temp-dir output, throws with stderr tail on failure, ffprobe-side
// verification independent of the app's probe pipeline.

import Foundation
@testable import VideoScan

enum BalanceAudioTestMedia {

    static var ffmpegPath: String { ToolLocator.ffmpegPath }
    static var toolsAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: ffmpegPath)
            && FileManager.default.isExecutableFile(atPath: ToolLocator.ffprobePath)
    }

    /// Fresh per-test directory under the system temp dir (isolation —
    /// no real volumes, no shared state). Callers remove it in a defer.
    static func makeScratchDir(_ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_balance_\(label)_\(UUID().uuidString.prefix(8))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: Channel cases

    enum ChannelCase: String, CaseIterable {
        case leftOnly, rightOnly, dualMono, trueStereo, silent, mono, surround51

        /// aevalsrc expression set — one expression per channel.
        var aevalExpressions: String {
            let tone = "0.5*sin(440*2*PI*t)"
            let tone2 = "0.5*sin(987*2*PI*t)"
            switch self {
            case .leftOnly:   return "\(tone)|0"
            case .rightOnly:  return "0|\(tone)"
            case .dualMono:   return "\(tone)|\(tone)"
            case .trueStereo: return "\(tone)|\(tone2)"
            case .silent:     return "0|0"
            case .mono:       return tone
            case .surround51:
                return Array(repeating: tone, count: 6).joined(separator: "|")
            }
        }

        var expectedClass: AudioChannelClass {
            switch self {
            case .leftOnly:   return .leftOnly
            case .rightOnly:  return .rightOnly
            case .dualMono:   return .dualMono
            case .trueStereo: return .trueStereo
            case .silent:     return .silent
            case .mono:       return .mono
            case .surround51: return .multichannel
            }
        }
    }

    /// Container/codec combos for the matrix (checklist dimension 3).
    enum Wrapper: String {
        case mp4H264Aac    // lossy family
        case movH264Pcm    // lossless PCM family

        var ext: String { self == .mp4H264Aac ? "mp4" : "mov" }
        var audioArgs: [String] {
            self == .mp4H264Aac ? ["-c:a", "aac", "-b:a", "128k"]
                                : ["-c:a", "pcm_s16le"]
        }
    }

    /// Generate one synthetic fixture: testsrc video + the channel
    /// case's audio, `test_` prefix, 2 s. Returns the absolute path.
    @discardableResult
    static func generate(into dir: URL,
                         channelCase: ChannelCase,
                         wrapper: Wrapper,
                         duration: Double = 2.0) throws -> String {
        let name = "test_balance_\(channelCase.rawValue).\(wrapper.ext)"
        let out = dir.appendingPathComponent(name).path
        var args: [String] = [
            "-f", "lavfi",
            "-i", "testsrc=duration=\(duration):size=320x240:rate=25",
            "-f", "lavfi",
            "-i", "aevalsrc=\(channelCase.aevalExpressions):s=48000:d=\(duration)",
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "libx264", "-preset", "ultrafast"
        ]
        args += wrapper.audioArgs
        try runFFmpeg(args, output: out)
        return out
    }

    // MARK: Multi-audio-stream fixtures (the 12-bit DV shape)

    /// Container choices for two-audio-stream fixtures.
    enum TwoPairContainer: String {
        /// REAL .dv container. ffmpeg's dv muxer only accepts a second
        /// audio pair in the 50 Mbps (DVCPRO50 / yuv422p) profile at
        /// 48 kHz — consumer 12-bit DV is 25 Mbps / 32 kHz, but the
        /// STREAM SHAPE (dvvideo + two pcm_s16le stereo pairs) is
        /// identical, which is all the probe/job care about.
        /// NOTE (fix/balance-dv-output-container, verified 2026-07-18):
        /// the muxer rejects 32 kHz PCM outright — even a SINGLE
        /// consumer-profile pair can't be synthesized ("Invalid sample
        /// rate 32000 … must be 48000"), which is the very bug that
        /// forces balanced raw-DV output into QuickTime. DVCPRO50 is
        /// therefore the only possible raw-.dv stand-in; the demuxed
        /// raw-DV quirks the fix depends on (format_name "dv", bogus
        /// avg_frame_rate 60000/1 with true r_frame_rate 30000/1001)
        /// are present on these fixtures too.
        case dv
        /// mov with h264 video + two pcm_s16le stereo streams — the
        /// same two-audio-stream shape in the QuickTime family.
        case movPcm

        var ext: String { self == .dv ? "dv" : "mov" }
        var videoArgs: [String] {
            self == .dv
                ? ["-c:v", "dvvideo", "-pix_fmt", "yuv422p"]
                : ["-c:v", "libx264", "-preset", "ultrafast"]
        }
    }

    /// Fixture with TWO stereo audio streams — the shape DV camcorders
    /// produce in 12-bit audio mode (two independent stereo pairs that
    /// ffprobe reports as two audio streams). `pair1`/`pair2` are
    /// aevalsrc per-channel expression sets ("L|R"), e.g.
    /// `"0|\(tone)"` for right-only program, `"0|0"` for a silent pair.
    @discardableResult
    static func generateTwoAudioPairs(into dir: URL,
                                      label: String,
                                      pair1: String,
                                      pair2: String,
                                      container: TwoPairContainer,
                                      duration: Double = 2.0) throws -> String {
        let name = "test_balance_2pair_\(label).\(container.ext)"
        let out = dir.appendingPathComponent(name).path
        var args: [String] = [
            "-f", "lavfi",
            "-i", "testsrc=duration=\(duration):size=720x480:rate=30000/1001",
            "-f", "lavfi",
            "-i", "aevalsrc=\(pair1):s=48000:d=\(duration)",
            "-f", "lavfi",
            "-i", "aevalsrc=\(pair2):s=48000:d=\(duration)",
            "-map", "0:v", "-map", "1:a", "-map", "2:a"
        ]
        args += container.videoArgs
        args += ["-c:a", "pcm_s16le"]
        try runFFmpeg(args, output: out)
        return out
    }

    /// The standard program tone, exposed for two-pair expressions.
    static let programTone = "0.5*sin(440*2*PI*t)"
    static let programTone2 = "0.5*sin(987*2*PI*t)"

    /// Audio-only fixture (no video) for probe-level tests.
    @discardableResult
    static func generateAudioOnly(into dir: URL,
                                  channelCase: ChannelCase,
                                  duration: Double = 2.0) throws -> String {
        let name = "test_balance_audio_\(channelCase.rawValue).m4a"
        let out = dir.appendingPathComponent(name).path
        try runFFmpeg([
            "-f", "lavfi",
            "-i", "aevalsrc=\(channelCase.aevalExpressions):s=48000:d=\(duration)",
            "-c:a", "aac"
        ], output: out)
        return out
    }

    static func runFFmpeg(_ args: [String], output: String) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ffmpegPath)
        proc.arguments = ["-y", "-hide_banner", "-loglevel", "error"] + args + [output]
        let errPipe = Pipe()
        proc.standardError = errPipe
        proc.standardOutput = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              FileManager.default.fileExists(atPath: output) else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw FixtureError.ffmpegFailed(status: proc.terminationStatus,
                                            stderr: String(err.suffix(400)))
        }
    }

    enum FixtureError: Error, CustomStringConvertible {
        case ffmpegFailed(status: Int32, stderr: String)
        var description: String {
            switch self {
            case .ffmpegFailed(let s, let e): return "ffmpeg failed (\(s)): \(e)"
            }
        }
    }
}

// MARK: - Record factory

/// Minimal catalog record pointing at a real on-disk fixture, shaped
/// the way the balance path reads it.
@MainActor
func makeBalanceSourceRecord(path: String,
                             durationSeconds: Double,
                             streamType: StreamType = .videoAndAudio,
                             audioCodec: String = "aac") -> VideoRecord {
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.fullPath = path
    r.directory = (path as NSString).deletingLastPathComponent
    r.durationSeconds = durationSeconds
    r.streamTypeRaw = streamType.rawValue
    r.audioCodec = audioCodec
    let attrs = (try? FileManager.default.attributesOfItem(atPath: path)) ?? [:]
    r.sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
    return r
}
