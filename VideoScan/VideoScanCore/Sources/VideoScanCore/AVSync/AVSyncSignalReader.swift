// AVSyncSignalReader.swift (VideoScanCore)
// ONE SENTENCE: read one media file through ffmpeg into its A/V sync
// evidence — the sound (AudioPCMDecoder, aligned to the file's time zero) and
// the picture (32×18 grey frames with their PTS) — streaming, with every
// failure a named outcome.
//
// Design: docs/design/av_sync_analysis.md §3. ffmpeg, not AVFoundation: much
// of the archive (DV in AVI, MXF, Matroska, old codecs) does not open in
// AVFoundation. Two ffmpeg children per file, run side by side (sound and
// picture), both through ProcessRunner (deadline, cancellation kills the
// child, ProcessControl pauses it). Nothing is written anywhere: both outputs
// are pipes ("-").
//
// The picture call:
//   ffmpeg -nostdin -hide_banner -nostats -v info -i <file> -map 0:v:0 -an -sn -dn
//          -vf scale=32:18:flags=area,format=gray,showinfo@vsmotion
//          -fps_mode passthrough -f rawvideo -
// The scale happens inside the decoder's filter graph, so the pipe carries
// 576 bytes a frame. `showinfo` logs each frame's pts_time on stderr (read
// line by line — ProcessRunner's line callback sees the whole stream, not just
// the 256 KB head it keeps); only lines starting with this instance's own
// "[showinfo@vsmotion @ " prefix are read. `-fps_mode passthrough` keeps one
// output frame per decoded frame (no duplication to a constant rate), so the
// n-th time belongs to the n-th frame on stdout.
//
// MEMORY (worst case): the sound decode holds the file's PCM until its onset
// envelope and print are made — 8 kHz Int16, 57.6 MB per hour of sound (the
// decoder's own cap is 4 h = 230 MB). The picture side keeps two frames
// (1.2 KB) and 12 B per frame (time + change): 2 h at 60 fps = 5.2 MB. The
// frames themselves stream through and are never held (1 h at 60 fps =
// 124 MB through the pipe).
//
// (For Rick: `async let` starts both decodes concurrently and joins them —
// ≈ two std::async futures awaited together.)

import Foundation

public struct AVSyncSignalReader: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        case ffmpegMissing(path: String)
        /// The sound could not be decoded (no stream, damaged, timed out).
        case sound(AudioPCMDecoder.Failure)
        /// The file has no picture stream.
        case noPicture
        case pictureDecodeFailed(exitCode: Int32, stderrTail: String)
        case pictureTimedOut
        /// ffmpeg delivered frames without times, or times without frames.
        case frameTimesMissing(frames: Int, times: Int)

        /// One line for a job row and the log.
        public var words: String {
            switch self {
            case let .ffmpegMissing(path): return "ffmpeg is not installed at \(path)"
            case let .sound(failure):
                switch failure {
                case .noAudioStream: return "the file has no sound to decode"
                case .timedOut: return "the sound decode timed out"
                case let .decodeFailed(code, _): return "the sound did not decode (ffmpeg exit \(code))"
                case let .ffmpegMissing(path): return "ffmpeg is not installed at \(path)"
                }
            case .noPicture: return "the file has no picture"
            case let .pictureDecodeFailed(code, _): return "the picture did not decode (ffmpeg exit \(code))"
            case .pictureTimedOut: return "the picture decode timed out"
            case let .frameTimesMissing(frames, times):
                return "the picture decode gave \(frames) frames but \(times) frame times"
            }
        }
    }

    public static let thumbnailWidth = 32
    public static let thumbnailHeight = 18
    static let showinfoTag = "vsmotion"
    static let stderrTailLength = 400

    public var ffmpegPath: String
    public var gridSeconds: Double

    public init(ffmpegPath: String = FFmpegLocator.ffmpegPath, gridSeconds: Double = AVSyncPolicy.default.gridSeconds) {
        self.ffmpegPath = ffmpegPath
        self.gridSeconds = gridSeconds
    }

    /// The picture decode's exact argv (pure, pinned by a test).
    public static func pictureArguments(path: String) -> [String] {
        ["-nostdin", "-hide_banner", "-nostats", "-v", "info", "-i", path,
         "-map", "0:v:0", "-an", "-sn", "-dn",
         "-vf", "scale=\(thumbnailWidth):\(thumbnailHeight):flags=area,format=gray,showinfo@\(showinfoTag)",
         "-fps_mode", "passthrough", "-f", "rawvideo", "-"]
    }

    /// A deadline that scales with the file: twice real time, at least 10 min.
    static func deadline(expectedDurationSeconds: Double?) -> Double {
        max(600, 2 * (expectedDurationSeconds ?? AudioPCMDecoder.defaultMaxSeconds))
    }

    /// Read `path` into its evidence. `progress` gets 0…1 by picture time
    /// against `expectedDurationSeconds` (nothing when that is unknown).
    public func read(path: String, expectedDurationSeconds: Double?, control: ProcessControl? = nil,
                     progress: (@Sendable (Double) -> Void)? = nil) async throws -> AVSyncFileEvidence {
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw Failure.ffmpegMissing(path: ffmpegPath)
        }
        async let sound = readSound(path: path, expectedDurationSeconds: expectedDurationSeconds, control: control)
        async let picture = readPicture(path: path, expectedDurationSeconds: expectedDurationSeconds,
                                        control: control, progress: progress)
        let (onset, fingerprint) = try await sound
        let (times, changes) = try await picture
        let length = Int((Double(times.last ?? 0) / gridSeconds).rounded(.up)) + 1
        let cutFlags = AVSyncSignalMath.cutFlags(frameTimes: times, changes: changes)
        let motion = AVSyncSignalMath.motionGrid(frameTimes: times, changes: changes, gridSeconds: gridSeconds,
                                                 count: length, cutFlags: cutFlags)
        let cuts = zip(cutFlags, times).compactMap { $0 ? $1 : nil }
        let signals = AVSyncSignals(gridSeconds: gridSeconds, onset: onset, motion: motion, cuts: cuts,
                                    frameCount: times.count)
        return AVSyncFileEvidence(signals: signals, fingerprint: fingerprint)
    }

    /// Sound: PCM on the file's timeline → onset envelope + sound print; the
    /// PCM is released when this returns.
    func readSound(path: String, expectedDurationSeconds: Double?,
                   control: ProcessControl?) async throws -> ([Float], AudioFingerprint) {
        let decoder = AudioPCMDecoder(ffmpegPath: ffmpegPath,
                                      deadlineSeconds: Self.deadline(expectedDurationSeconds: expectedDurationSeconds),
                                      alignToFileStart: true)
        let pcm: AudioPCM
        do {
            pcm = try await decoder.decode(path: path, control: control)
        } catch let failure as AudioPCMDecoder.Failure {
            throw Failure.sound(failure)
        }
        let onset = AVSyncSignalMath.onsetEnvelope(samples: pcm.samples, sampleRate: pcm.sampleRate,
                                                   gridSeconds: gridSeconds)
        return (onset, AudioFingerprint.compute(pcm))
    }

    /// Picture: frame times and per-frame changes.
    func readPicture(path: String, expectedDurationSeconds: Double?, control: ProcessControl?,
                     progress: (@Sendable (Double) -> Void)?) async throws -> ([Double], [Float]) {
        let sink = PictureSink(frameBytes: Self.thumbnailWidth * Self.thumbnailHeight)
        let prefix = "[showinfo@\(Self.showinfoTag) @ "
        let expected = expectedDurationSeconds ?? 0
        let result = await ProcessRunner.runProcess(
            executable: ffmpegPath,
            arguments: Self.pictureArguments(path: path),
            stderrLine: { line in
                guard let time = Self.frameTime(line: line, prefix: prefix) else { return }
                sink.addTime(time)
                if expected > 0, let progress { progress(min(1, max(0, time / expected))) }
            },
            stdoutData: { chunk in sink.append(chunk) },
            stdoutLimitBytes: 0,
            deadlineSeconds: Self.deadline(expectedDurationSeconds: expectedDurationSeconds),
            control: control)
        try Task.checkCancellation()
        if result.exitCode != 0 {
            if result.timedOut { throw Failure.pictureTimedOut }
            if result.stderr.contains("matches no streams") || result.stderr.contains("does not contain any stream") {
                throw Failure.noPicture
            }
            throw Failure.pictureDecodeFailed(exitCode: result.exitCode,
                                              stderrTail: String(result.stderr.suffix(Self.stderrTailLength)))
        }
        let (times, changes) = sink.take()
        guard !changes.isEmpty || !times.isEmpty else { throw Failure.noPicture }
        // The last line or frame can trail the other by one at EOF; more than
        // that means the pairing cannot be trusted.
        guard abs(times.count - changes.count) <= 1, min(times.count, changes.count) > 0 else {
            throw Failure.frameTimesMissing(frames: changes.count, times: times.count)
        }
        let count = min(times.count, changes.count)
        return (Array(times.prefix(count)), Array(changes.prefix(count)))
    }

    /// The pts_time of a showinfo frame line from THIS instance, else nil.
    static func frameTime(line: String, prefix: String) -> Double? {
        guard line.hasPrefix(prefix), line.contains(" n:"), let range = line.range(of: " pts_time:") else { return nil }
        let rest = line[range.upperBound...]
        let token = rest.prefix { !$0.isWhitespace }
        guard let value = Double(token), value.isFinite else { return nil }
        return value
    }
}

/// The picture pipe's sink: cuts the byte stream into frames, keeps only the
/// previous frame, records each frame's change; times arrive separately from
/// the stderr reader. Both callbacks run on ProcessRunner's reader threads.
final class PictureSink: @unchecked Sendable {   // guarded by `lock`
    private let lock = NSLock()
    private let frameBytes: Int
    private var partial: [UInt8] = []
    private var previous: [UInt8]?
    private var changes: [Float] = []
    private var times: [Double] = []

    init(frameBytes: Int) {
        self.frameBytes = frameBytes
        partial.reserveCapacity(frameBytes)
    }

    func append(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        var offset = chunk.startIndex
        while offset < chunk.endIndex {
            let take = min(frameBytes - partial.count, chunk.endIndex - offset)
            partial.append(contentsOf: chunk[offset..<(offset + take)])
            offset += take
            if partial.count == frameBytes {
                if let previous {
                    let change = previous.withUnsafeBufferPointer { a in
                        partial.withUnsafeBufferPointer { b in AVSyncSignalMath.meanAbsoluteDifference(a, b) }
                    }
                    changes.append(change)
                } else {
                    changes.append(0)
                }
                previous = partial
                partial.removeAll(keepingCapacity: true)
            }
        }
    }

    func addTime(_ time: Double) {
        lock.lock(); defer { lock.unlock() }
        times.append(time)
    }

    func take() -> ([Double], [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (times, changes)
    }
}
