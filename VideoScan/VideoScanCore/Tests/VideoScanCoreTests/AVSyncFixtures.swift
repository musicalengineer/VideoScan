// AVSyncFixtures.swift — synthetic sound + picture pairs for the A/V sync
// suites (docs/design/av_sync_analysis.md §7). No file of Rick's is read.
//
// A SOURCE is rendered in Swift from a seeded PRNG: a 64×36 grey picture at
// 30 fps (a background that cuts to a new level every 2–7 s, three blocks
// whose velocities change at random times — movement with structure, never
// periodic) and 16 kHz speech-like sound (SyntheticSpeech). ffmpeg encodes it
// into an ORIGINAL in one of the five matrix formats, then makes the
// PROCESSED file from the original with one known change: the sound moved
// late or early, a steady drift, frames dropped at one moment, both trimmed,
// a frame-rate change, a re-encode. Everything lands in one TestScratch folder
// per test case, removed when the case ends (`@Suite(.scratchCleanup)`).
//
// Memory: the raw picture is written frame by frame through a FileHandle
// (2.3 KB a frame); the sound is rendered whole (16 kHz Float: 3.8 MB a
// minute — the 2-hour scale source is rendered at 8 kHz, 230 MB transient,
// written as 115 MB of WAV).
//
// (For Rick: `enum` with only static members ≈ a C++ namespace.)

import Foundation
import Testing
@testable import VideoScanCore

enum AVSyncFixtures {

    static let width = 64
    static let height = 36
    static let fps = 30

    enum Sound: Sendable { case speech, silence, tone, metronome }
    enum Picture: Sendable { case moving, staticSlide }

    /// The five media-matrix formats (CLAUDE.md rule 8).
    enum Format: String, CaseIterable, Sendable {
        case mp4H264, movProRes, mkvFFV1, mxfMPEG2, aviDV

        var ext: String {
            switch self {
            case .mp4H264: return "mp4"
            case .movProRes: return "mov"
            case .mkvFFV1: return "mkv"
            case .mxfMPEG2: return "mxf"
            case .aviDV: return "avi"
            }
        }

        /// The picture filter the format needs (size, rate).
        var videoFilter: String {
            switch self {
            case .mp4H264, .movProRes, .mkvFFV1: return "scale=320:180"
            case .mxfMPEG2: return "scale=320:180,fps=25"
            case .aviDV: return "scale=720:576,fps=25,setsar=16/15"
            }
        }

        var codecArgs: [String] {
            switch self {
            case .mp4H264:
                return ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-b:a", "128k", "-ar", "48000"]
            case .movProRes:
                return ["-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-ar", "48000"]
            case .mkvFFV1:
                return ["-c:v", "ffv1", "-c:a", "pcm_s16le", "-ar", "48000"]
            case .mxfMPEG2:
                return ["-c:v", "mpeg2video", "-q:v", "4", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-ar", "48000"]
            case .aviDV:
                return ["-c:v", "dvvideo", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", "-ar", "48000"]
            }
        }
    }

    /// The one known change made to the processed file.
    enum Change: Sendable {
        /// Re-encoded, nothing moved.
        case none
        /// The sound moved by `ms` (positive = later; expected s = −ms).
        case soundLate(ms: Double)
        /// The sound slowed so it ends `msPerMinute` later per minute.
        case soundDrifts(lateMsPerMinute: Double)
        /// `dropMs` of picture removed at `atSeconds`; the sound runs on —
        /// from there the sound is `dropMs` late.
        case pictureDrop(atSeconds: Double, dropMs: Double)
        /// Both sound and picture trimmed by `seconds` at the head (harmless).
        case trimBoth(seconds: Double)
        /// Frames duplicated to 60 fps.
        case fps60Duplicated
        /// Frames interpolated (blended) to 60 fps.
        case fps60Interpolated
        /// A different codec and bit rate (H.264 at low quality, AAC 64k).
        case lowQualityReencode
    }

    struct Source {
        let rawPicture: URL
        let sound: URL
        let seconds: Double
    }

    // MARK: Render

    static func makeSource(in dir: URL, seconds: Double, seed: UInt64, sound: Sound = .speech,
                           picture: Picture = .moving, soundRate: Int = 16_000) throws -> Source {
        let raw = dir.appendingPathComponent("source.gray")
        try renderPicture(to: raw, seconds: seconds, seed: seed, kind: picture)
        let wav = dir.appendingPathComponent("source.wav")
        try WAVWriter.write(SyntheticSpeech.toInt16(renderSound(seconds: seconds, seed: seed &+ 1, kind: sound,
                                                                 sampleRate: soundRate)),
                            sampleRate: soundRate, to: wav)
        return Source(rawPicture: raw, sound: wav, seconds: seconds)
    }

    static func renderSound(seconds: Double, seed: UInt64, kind: Sound, sampleRate: Int) -> [Float] {
        let count = Int(seconds * Double(sampleRate))
        switch kind {
        case .speech:
            return SyntheticSpeech.render(seconds: seconds, seed: seed, sampleRate: sampleRate)
        case .silence:
            return [Float](repeating: 0, count: count)
        case .tone:
            return (0..<count).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / Double(sampleRate))) }
        case .metronome:
            // A 10 ms 2 kHz click every 0.5 s.
            let period = sampleRate / 2, click = sampleRate / 100
            return (0..<count).map { i in
                let k = i % period
                guard k < click else { return 0 }
                return Float(0.8 * sin(2 * Double.pi * 2_000 * Double(k) / Double(sampleRate))
                             * exp(-Double(k) / Double(click / 3)))
            }
        }
    }

    /// Raw 8-bit grey frames, `width`×`height`, `fps`, written as they are made.
    static func renderPicture(to url: URL, seconds: Double, seed: UInt64, kind: Picture) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var rng = SplitMix64(seed: seed)
        let frames = Int(seconds * Double(fps))
        var background = 80.0, gradient = 0.5, nextCut = rng.range(2, 7)
        struct Block { var x, y, vx, vy, level: Double; var nextTurn: Double }
        var blocks = (0..<3).map { _ in
            Block(x: rng.range(0, 56), y: rng.range(0, 28), vx: rng.range(-40, 40), vy: rng.range(-30, 30),
                  level: rng.range(150, 250), nextTurn: rng.range(0.3, 2))
        }
        var frame = [UInt8](repeating: 0, count: width * height)
        for f in 0..<frames {
            let t = Double(f) / Double(fps)
            if kind == .moving {
                if t >= nextCut {
                    background = rng.range(20, 120)
                    gradient = rng.range(-1, 1)
                    nextCut = t + rng.range(2, 7)
                }
                for i in blocks.indices {
                    if t >= blocks[i].nextTurn {
                        blocks[i].vx = rng.range(-40, 40)
                        blocks[i].vy = rng.range(-30, 30)
                        blocks[i].nextTurn = t + rng.range(0.3, 2)
                    }
                    blocks[i].x += blocks[i].vx / Double(fps)
                    blocks[i].y += blocks[i].vy / Double(fps)
                    if blocks[i].x < 0 || blocks[i].x > Double(width - 8) { blocks[i].vx = -blocks[i].vx }
                    if blocks[i].y < 0 || blocks[i].y > Double(height - 8) { blocks[i].vy = -blocks[i].vy }
                    blocks[i].x = min(max(blocks[i].x, 0), Double(width - 8))
                    blocks[i].y = min(max(blocks[i].y, 0), Double(height - 8))
                }
            }
            for y in 0..<height {
                for x in 0..<width {
                    frame[y * width + x] = UInt8(max(0, min(255, background + gradient * Double(x - width / 2))))
                }
            }
            for b in blocks {
                for y in Int(b.y)..<min(height, Int(b.y) + 8) {
                    for x in Int(b.x)..<min(width, Int(b.x) + 8) { frame[y * width + x] = UInt8(b.level) }
                }
            }
            handle.write(Data(frame))
        }
    }

    // MARK: Encode

    /// The source encoded as an original in `format`.
    static func encodeOriginal(_ source: Source, format: Format, in dir: URL, name: String = "original",
                               loopPicture: Bool = false) async throws -> URL {
        let out = dir.appendingPathComponent("\(name).\(format.ext)")
        var args = ["-nostdin", "-v", "error"]
        if loopPicture { args += ["-stream_loop", "-1"] }
        args += ["-f", "rawvideo", "-pix_fmt", "gray", "-s", "\(width)x\(height)", "-r", "\(fps)",
                 "-i", source.rawPicture.path, "-i", source.sound.path,
                 "-map", "0:v", "-map", "1:a", "-vf", format.videoFilter] + format.codecArgs
        args += ["-t", String(source.seconds), "-y", out.path]
        try await run(args)
        return out
    }

    /// The processed file: `original` with `change`, encoded in `format`.
    static func process(_ original: URL, change: Change, format: Format, in dir: URL,
                        name: String = "processed") async throws -> URL {
        let out = dir.appendingPathComponent("\(name).\(format.ext)")
        var pre: [String] = []
        var video = format.videoFilter
        var audio: String?
        var complex: String?
        var codec = format.codecArgs
        switch change {
        case .none:
            break
        case let .soundLate(ms):
            audio = ms >= 0 ? "adelay=\(Int(ms.rounded())):all=1"
                            : "atrim=start=\(String(format: "%.4f", -ms / 1_000)),asetpts=PTS-STARTPTS"
        case let .soundDrifts(lateMsPerMinute):
            let delta = lateMsPerMinute / 60_000
            audio = "asetrate=\(String(format: "%.4f", 48_000 * (1 - delta))),aresample=48000"
        case let .pictureDrop(at, dropMs):
            let resume = at + dropMs / 1_000
            complex = "[0:v]split[a][b];[a]trim=end=\(at),setpts=PTS-STARTPTS[v1];"
                + "[b]trim=start=\(String(format: "%.4f", resume)),setpts=PTS-STARTPTS[v2];"
                + "[v1][v2]concat=n=2:v=1:a=0,\(format.videoFilter)[v]"
        case let .trimBoth(seconds):
            pre = ["-ss", String(seconds)]
        case .fps60Duplicated:
            video += ",fps=60"
        case .fps60Interpolated:
            video += ",minterpolate=fps=60:mi_mode=blend"
        case .lowQualityReencode:
            codec = ["-c:v", "libx264", "-preset", "ultrafast", "-crf", "35", "-pix_fmt", "yuv420p",
                     "-c:a", "aac", "-b:a", "64k", "-ar", "48000"]
        }
        var args = ["-nostdin", "-v", "error"] + pre + ["-i", original.path]
        if let complex {
            args += ["-filter_complex", complex, "-map", "[v]", "-map", "0:a"]
        } else {
            args += ["-map", "0:v", "-map", "0:a", "-vf", video]
        }
        if let audio { args += ["-af", audio] }
        args += codec + ["-y", out.path]
        try await run(args)
        return out
    }

    struct FFmpegFailed: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ args: [String]) async throws {
        let result = await ProcessRunner.runProcess(executable: FFmpegLocator.ffmpegPath, arguments: args,
                                                    deadlineSeconds: 900)
        guard result.exitCode == 0 else {
            throw FFmpegFailed(description: "ffmpeg exit \(result.exitCode): \(result.stderr.suffix(400))")
        }
    }

    // MARK: Measure

    /// Read both files through the real reader and analyse.
    static func measure(original: URL, processed: URL, seconds: Double,
                        policy: AVSyncPolicy = .default) async throws -> AVSyncReport {
        let reader = AVSyncSignalReader()
        async let o = reader.read(path: original.path, expectedDurationSeconds: seconds)
        async let p = reader.read(path: processed.path, expectedDurationSeconds: seconds)
        return AVSyncAnalyzer.analyze(original: try await o, processed: try await p, policy: policy)
    }

    /// With VIDEOSCAN_AVSYNC_ACCURACY=1 in the environment, print one
    /// "AVSYNC-ACCURACY" line per measured case (for the accuracy table in
    /// a report). Silent otherwise.
    static func note(_ label: String, expected: String, report: AVSyncReport, seconds: Double? = nil,
                     elapsed: Double? = nil) {
        guard ProcessInfo.processInfo.environment["VIDEOSCAN_AVSYNC_ACCURACY"] == "1" else { return }
        let median = report.medianShiftMs.map { String(format: "%.2f", $0) } ?? "-"
        let drift = report.driftMsPerMinute.map { String(format: "%.2f", $0) } ?? "-"
        var line = "AVSYNC-ACCURACY \(label) | expected \(expected) | median \(median) ms | drift \(drift) ms/min"
            + " | \(report.measuredWindows)/\(report.windows.count) windows | \(report.sentence)"
        if let seconds, let elapsed { line += String(format: " | %.0f s of media in %.1f s", seconds, elapsed) }
        print(line)
    }

    /// One line per report for a failing expectation.
    static func describe(_ report: AVSyncReport) -> String {
        let windows = report.windows.map { (w: AVSyncWindow) -> String in
            let s = w.shiftMs.map { String(format: "%.1f", $0) } ?? "-"
            let a = w.soundLagMs.map { String(format: "%.1f", $0) } ?? "-"
            let v = w.pictureLagMs.map { String(format: "%.1f", $0) } ?? "-"
            let pk = String(format: "%.2f/%.2f %.2f/%.2f", w.soundPeak ?? -1, w.soundSecondPeakRatio ?? -1,
                            w.picturePeak ?? -1, w.pictureSecondPeakRatio ?? -1)
            return "  @\(Int(w.startSeconds)) s=\(s) a=\(a) v=\(v) [\(pk)] \(w.notMeasured?.rawValue ?? "")"
        }.joined(separator: "\n")
        return "\(report.sentence)\n coarse=\(report.coarseOffsetSeconds ?? .nan) median=\(report.medianShiftMs ?? .nan)"
            + " drift/min=\(report.driftMsPerMinute ?? .nan)\n\(windows)"
    }
}
