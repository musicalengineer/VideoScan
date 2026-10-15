// AudioPCMDecoder.swift (VideoScanCore)
// ONE SENTENCE: turn any media file ffmpeg can open into 8 kHz mono 16-bit
// PCM in memory, over a pipe, with every failure a named outcome.
//
// The ffmpeg call is
//   ffmpeg -nostdin -v error [-ss S] -i <file> -vn -ac 1 -ar 8000 -t T -f s16le -
// read from stdout through ProcessRunner.runProcess's raw-bytes callback
// (`stdoutData`, `stdoutLimitBytes: 0`), the house shell-out primitive: the
// pipe is drained continuously (a child can never block on a full pipe), a
// deadline escalates SIGTERM → SIGKILL → abandon, and task cancellation
// kills the child. No temp file, no output path — the only "output" is `-`
// (stdout). The input is opened read-only by ffmpeg; nothing is written
// beside it (AudioFingerprintEngineTests' sensor pins that).
//
// SAFETY: a file with no audio stream, a 0-byte file, a damaged file, a
// missing ffmpeg and a dead volume are each a named `Failure` — never a
// crash, never a misread as "silence".
//
// MEMORY: `-t` always caps the decode at `maxSeconds` (default 4 h) AND the
// sink drops bytes past the cap, so the worst case in RAM is
// 4 h × 8 000 Hz × 2 B = 230 MB of Int16; a 16-minute file is 15 MB, a
// 3-minute clip 2.9 MB. The Data buffer grows amortised as chunks arrive
// (≤ 64 KB each), then is copied once into `[Int16]`.
//
// (For Rick: `Failure` is a tagged union — an enum with payloads — thrown
// and matched by case; `throws` is a checked error channel, not a C++
// exception with unwinding cost on the happy path. The sink is a small
// mutex-guarded byte buffer the pipe-reader thread appends to.)

import Foundation

/// Decoded PCM: mono, `sampleRate` Hz, signed 16-bit.
public struct AudioPCM: Sendable, Equatable {
    public let sampleRate: Int
    public let samples: [Int16]
    /// True when the decode filled the limit it was given (`maxSeconds`,
    /// or a `Window.durationSeconds`): `samples` are then a PREFIX of the
    /// recording (or a window of it), not the whole. A fingerprint made
    /// from such PCM is `complete == false` and can never be called
    /// "the same recording" as anything. (A file EXACTLY as long as the
    /// cap also reads as capped — the honest, conservative side.)
    public let reachedCap: Bool

    public init(sampleRate: Int, samples: [Int16], reachedCap: Bool = false) {
        self.sampleRate = sampleRate
        self.samples = samples
        self.reachedCap = reachedCap
    }

    /// Seconds of audio actually analysed (= `samples.count / sampleRate`).
    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
    public var analyzedSeconds: Double { durationSeconds }
}

public struct AudioPCMDecoder: Sendable {

    public enum Failure: Error, Equatable, Sendable {
        /// No executable at the resolved ffmpeg path — an environment fact.
        case ffmpegMissing(path: String)
        /// ffmpeg opened the file but found nothing to decode as audio
        /// (its "does not contain any stream", or a clean exit with zero
        /// bytes — an empty audio stream has nothing to fingerprint).
        case noAudioStream
        /// ffmpeg failed (0-byte file, damaged container, unsupported
        /// codec…). `stderrTail` is the last part of ffmpeg's stderr.
        case decodeFailed(exitCode: Int32, stderrTail: String)
        /// The runner's deadline fired (dead volume, wedged child).
        case timedOut
    }

    /// Optional `-ss` / `-t` window (seconds). Either side may be nil.
    public struct Window: Sendable, Equatable {
        public var startSeconds: Double?
        public var durationSeconds: Double?
        public init(startSeconds: Double? = nil, durationSeconds: Double? = nil) {
            self.startSeconds = startSeconds
            self.durationSeconds = durationSeconds
        }
        public static let whole = Window()
    }

    public static let defaultSampleRate = 8_000
    public static let defaultMaxSeconds: Double = 4 * 3_600
    public static let defaultDeadlineSeconds: Double = 300
    /// How much of ffmpeg's stderr a `decodeFailed` carries.
    static let stderrTailLength = 400

    public var ffmpegPath: String
    public var sampleRate: Int
    public var maxSeconds: Double
    public var deadlineSeconds: Double

    public init(ffmpegPath: String = FFmpegLocator.ffmpegPath,
                sampleRate: Int = AudioPCMDecoder.defaultSampleRate,
                maxSeconds: Double = AudioPCMDecoder.defaultMaxSeconds,
                deadlineSeconds: Double = AudioPCMDecoder.defaultDeadlineSeconds) {
        self.ffmpegPath = ffmpegPath
        self.sampleRate = sampleRate
        self.maxSeconds = maxSeconds
        self.deadlineSeconds = deadlineSeconds
    }

    /// The exact argv (pure, so the tests can pin its shape). `-ss` goes
    /// BEFORE `-i` (input seek: exact for audio, and cheap); `-t` is the
    /// smaller of the window and the cap, always present; the output is `-`.
    public static func arguments(path: String, window: Window, sampleRate: Int, maxSeconds: Double) -> [String] {
        var args = ["-nostdin", "-v", "error"]
        if let start = window.startSeconds {
            args += ["-ss", Self.seconds(start)]
        }
        args += ["-i", path, "-vn", "-ac", "1", "-ar", String(sampleRate)]
        let limit = min(window.durationSeconds ?? maxSeconds, maxSeconds)
        args += ["-t", Self.seconds(limit), "-f", "s16le", "-"]
        return args
    }

    private static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
    }

    /// Decode `path` (optionally a window of it) to PCM.
    public func decode(path: String, window: Window = .whole) async throws -> AudioPCM {
        guard FileManager.default.isExecutableFile(atPath: ffmpegPath) else {
            throw Failure.ffmpegMissing(path: ffmpegPath)
        }
        let capBytes = Int(min(window.durationSeconds ?? maxSeconds, maxSeconds) * Double(sampleRate)) * 2
        let sink = PCMSink(capBytes: capBytes)
        let result = await ProcessRunner.runProcess(
            executable: ffmpegPath,
            arguments: Self.arguments(path: path, window: window, sampleRate: sampleRate, maxSeconds: maxSeconds),
            stdoutData: { chunk in sink.append(chunk) },
            stdoutLimitBytes: 0,
            deadlineSeconds: deadlineSeconds)
        // A cancelled task kills the child and reads as exit -1; surface it
        // as cancellation, never as a verdict about the file.
        try Task.checkCancellation()
        if result.exitCode != 0 {
            if result.timedOut { throw Failure.timedOut }
            if result.stderr.contains("does not contain any stream") { throw Failure.noAudioStream }
            throw Failure.decodeFailed(exitCode: result.exitCode,
                                       stderrTail: String(result.stderr.suffix(Self.stderrTailLength)))
        }
        let samples = sink.takeSamples()
        guard !samples.isEmpty else { throw Failure.noAudioStream }
        // Exactly the cap's worth of samples means ffmpeg was stopped by
        // `-t` (or the sink dropped the rest): the file goes on past what
        // was analysed, as far as anyone can tell.
        return AudioPCM(sampleRate: sampleRate, samples: samples, reachedCap: samples.count * 2 >= capBytes)
    }
}

/// The byte sink the pipe-reader thread appends to. Bounded by `capBytes`.
private final class PCMSink: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    private let capBytes: Int

    init(capBytes: Int) {
        self.capBytes = capBytes
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = capBytes - bytes.count
        guard room > 0 else { return }
        bytes.append(chunk.count <= room ? chunk : chunk.prefix(room))
    }

    /// s16le bytes → host Int16. Apple silicon and Intel are little-endian,
    /// so this is one memcpy; an odd trailing byte (a truncated last
    /// sample) is dropped.
    func takeSamples() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        let count = bytes.count / 2
        guard count > 0 else { return [] }
        var samples = [Int16](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { dst in
            bytes.copyBytes(to: dst, count: count * 2)
        }
        if Int16(1).littleEndian != 1 {
            samples = samples.map { Int16(littleEndian: $0) }
        }
        bytes = Data()
        return samples
    }
}
