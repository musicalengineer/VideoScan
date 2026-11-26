// AudioPCMDecoder.swift (VideoScanCore)
// ONE SENTENCE: turn any media file ffmpeg can open into 8 kHz mono 16-bit
// PCM in memory, over a pipe, with every failure a named outcome.
//
// The ffmpeg call is
//   ffmpeg -nostdin -hide_banner -nostats -v info [-ss S] -i <file> -vn
//          -af astats@vsprint=measure_perchannel=Peak_level:measure_overall=none
//          -ac 1 -ar 8000 -t T -f s16le -
// The astats instance sits BEFORE the mono downmix (ffmpeg appends the -ac /
// -ar conversion after the user's filters), so its per-channel peaks are the
// SOURCE channels' (GH #345, Codex round 2: anti-phase stereo at −21 dBFS
// per channel sums to a −68 dBFS mono mix — the mix alone is no evidence of
// silence). `-v info` is what makes astats print its summary; only lines
// that start with the instance's own "[astats@vsprint @ " prefix are read
// (a metadata dump line is indented, so a tag cannot forge one).
// ProcessRunner keeps the HEAD of stderr (256 KB): a damaged file that floods
// stderr with decode errors may lose the summary — it is then `.unmeasured`,
// which is never evidence of silence (the conservative side).
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
// sink drops samples past the cap. Each pipe chunk (≤ 64 KB) is converted
// to Int16 as it arrives and appended to ONE `[Int16]` whose capacity is
// reserved up front for the cap (virtual only — macOS commits a page when
// it is first written), so the resident cost is the audio actually
// decoded plus one chunk, with no second copy and no reallocation:
// 4 h = 230 MB, a 16-minute file 15 MB, a 3-minute clip 2.9 MB. Measured
// (AudioFingerprintEngineTests, 60-min WAV): peak growth ≈ the PCM size
// (55 MB), down from 2× before 2026-10-14 (codex F5). A decode that fills
// the cap says so (`AudioPCM.reachedCap`).
//
// (For Rick: `Failure` is a tagged union — an enum with payloads — thrown
// and matched by case; `throws` is a checked error channel, not a C++
// exception with unwinding cost on the happy path. The sink is a small
// mutex-guarded sample buffer the pipe-reader thread appends to.)

import Foundation

/// Decoded PCM: mono, `sampleRate` Hz, signed 16-bit.
public struct AudioPCM: Sendable, Equatable {
    public let sampleRate: Int
    public let samples: [Int16]
    /// How loud the SOURCE channels were before the mono downmix — the only
    /// evidence that may call a recording silent (GH #345, Codex round 2).
    public let sourceLevel: AudioSourceLevel
    /// True when the decode filled the limit it was given (`maxSeconds`,
    /// or a `Window.durationSeconds`): `samples` are then a PREFIX of the
    /// recording (or a window of it), not the whole. A fingerprint made
    /// from such PCM is `complete == false` and can never be called
    /// "the same recording" as anything. (A file EXACTLY as long as the
    /// cap also reads as capped — the honest, conservative side.)
    public let reachedCap: Bool

    /// `sourceLevel` defaults to `.samplesAreSource`: PCM built by hand is
    /// its own source. The decoder always says what it measured.
    public init(sampleRate: Int, samples: [Int16], reachedCap: Bool = false,
                sourceLevel: AudioSourceLevel = .samplesAreSource) {
        self.sampleRate = sampleRate
        self.samples = samples
        self.reachedCap = reachedCap
        self.sourceLevel = sourceLevel
    }

    /// Seconds of audio actually analysed (= `samples.count / sampleRate`).
    public var durationSeconds: Double {
        sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0
    }
    public var analyzedSeconds: Double { durationSeconds }
}

/// The source channels' loudness behind a mono `AudioPCM`.
/// (For Rick: a tagged union ≈ std::variant<SamplesAreSource, double, Unmeasured>.)
public enum AudioSourceLevel: Sendable, Equatable {
    /// The samples ARE the source (hand-built mono PCM, tests).
    case samplesAreSource
    /// The loudest source channel's peak over the decoded span, dBFS
    /// (−∞ = digital zeros), measured before the downmix.
    case peakDBFS(Double)
    /// Decoded, but ffmpeg printed no per-channel peak: never evidence of
    /// silence.
    case unmeasured

    /// True only when this is evidence that no source channel's peak
    /// clears `ceilingDBFS`.
    public func isAtOrBelow(_ ceilingDBFS: Double) -> Bool {
        switch self {
        case .samplesAreSource: return true
        case .peakDBFS(let p): return p <= ceilingDBFS
        case .unmeasured: return false
        }
    }

    /// The astats instance the decoder names (`arguments`).
    static let astatsTag = "vsprint"

    /// The loudest "Peak level dB:" among the lines THIS decoder's astats
    /// instance logged (prefix "[astats@vsprint @ " at the start of the
    /// line), or `.unmeasured`. Several summaries (a graph ffmpeg rebuilt
    /// re-creates the filter) → the loudest. "-inf" → −∞. Pure.
    static func parse(stderr: String) -> AudioSourceLevel {
        let prefix = "[astats@\(astatsTag) @ "
        var loudest: Double?
        for line in stderr.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) where line.hasPrefix(prefix) {
            guard let close = line.range(of: "] ") else { continue }
            let payload = line[close.upperBound...]
            guard payload.hasPrefix("Peak level dB:") else { continue }
            let text = payload.dropFirst("Peak level dB:".count).trimmingCharacters(in: .whitespaces)
            let value: Double? = text == "-inf" ? -.infinity : Double(text)
            guard let value, !value.isNaN else { return .unmeasured }   // garbage: refuse rather than guess
            loudest = max(loudest ?? -.infinity, value)
        }
        return loudest.map { .peakDBFS($0) } ?? .unmeasured
    }
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
        var args = ["-nostdin", "-hide_banner", "-nostats", "-v", "info"]
        if let start = window.startSeconds {
            args += ["-ss", Self.seconds(start)]
        }
        args += ["-i", path, "-vn",
                 "-af", "astats@\(AudioSourceLevel.astatsTag)=measure_perchannel=Peak_level:measure_overall=none",
                 "-ac", "1", "-ar", String(sampleRate)]
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
        let capSamples = Int(min(window.durationSeconds ?? maxSeconds, maxSeconds) * Double(sampleRate))
        let sink = PCMSink(capSamples: capSamples)
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
        return AudioPCM(sampleRate: sampleRate, samples: samples, reachedCap: samples.count >= capSamples,
                        sourceLevel: AudioSourceLevel.parse(stderr: result.stderr))
    }
}

/// The sample sink the pipe-reader thread appends to. Bounded by
/// `capSamples`; converts s16le bytes to Int16 chunk by chunk so the raw
/// bytes are never held alongside the samples.
final class PCMSink: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    /// A chunk may end mid-sample; its last byte waits here for the next.
    private var carry: UInt8?
    private let capSamples: Int
    /// Aligned staging for one chunk (grown if a chunk is ever larger):
    /// bytes are copied here, then appended as Int16 in one contiguous
    /// copy — a Data chunk's bytes can sit at any alignment.
    private var staging: UnsafeMutablePointer<Int16>
    private var stagingCapacity: Int

    init(capSamples: Int) {
        self.capSamples = capSamples
        stagingCapacity = 32_768 + 1
        staging = .allocate(capacity: stagingCapacity)
        // Virtual reservation: pages turn resident only as they are
        // written, so a 3-minute clip costs 2.9 MB however large the cap.
        samples.reserveCapacity(capSamples)
    }

    deinit { staging.deallocate() }

    /// Samples held so far (tests).
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return samples.count
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        let room = capSamples - samples.count
        guard room > 0, !chunk.isEmpty else { return }
        let needed = (chunk.count + 1) / 2 + 1
        if needed > stagingCapacity {
            staging.deallocate()
            stagingCapacity = needed
            staging = .allocate(capacity: stagingCapacity)
        }
        let whole = chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Int in
            guard let base = raw.baseAddress else { return 0 }
            let bytes = UnsafeMutableRawPointer(staging)
            var length = 0
            if let low = carry {
                bytes.storeBytes(of: low, as: UInt8.self)
                length = 1
                carry = nil
            }
            bytes.advanced(by: length).copyMemory(from: base, byteCount: raw.count)
            length += raw.count
            if length % 2 == 1 {
                carry = bytes.load(fromByteOffset: length - 1, as: UInt8.self)
            }
            return length / 2
        }
        let take = min(whole, room)
        if take > 0 {
            samples.append(contentsOf: UnsafeBufferPointer(start: staging, count: take))
        }
        if samples.count >= capSamples { carry = nil }
    }

    /// The samples, host-endian (Apple silicon and Intel are little-endian,
    /// so the copy above IS the conversion); a trailing unpaired byte is
    /// dropped. The sink is empty afterwards.
    func takeSamples() -> [Int16] {
        lock.lock()
        defer { lock.unlock() }
        var out = samples
        samples = []
        carry = nil
        if Int16(1).littleEndian != 1 {
            out = out.map { Int16(littleEndian: $0) }
        }
        return out
    }
}
