// AudioFingerprintFixtures.swift — the synthetic fixture matrix for the
// audio-fingerprint acceptance suite (frozen 2026-10-14, BEFORE the engine).
//
// No file of Rick's is read here. Every master is rendered in Swift from a
// seeded PRNG ("speech-like": band-limited noise bursts, pitched blips with
// harmonics, short sweeps, pauses — 8 kHz mono), written as WAV by this
// file, and the variants (AAC, MP3, resample, gain, stereo, speed, subclips,
// containers) are made with ffmpeg into one `test_`-prefixed temp dir that
// is removed at process exit. Fixtures and fingerprints are built once per
// process (an actor memoises the build) because Swift Testing runs the
// cases in parallel.
//
// (For Rick: the actor is a lazily-initialised singleton behind a mutex;
// `Task` memoisation is a std::shared_future — every caller awaits the
// same build.)

import Accelerate
import Foundation
import Testing
@testable import VideoScanCore

extension Tag {
    @Tag static var scale: Self
}

// MARK: - Seeded PRNG

/// SplitMix64 — tiny, seedable, good enough for fixtures. Same seed → same
/// bytes on every machine, so the WAVs are reproducible.
struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    mutating func range(_ lo: Double, _ hi: Double) -> Double {
        lo + (hi - lo) * unit()
    }

    /// Gaussian-ish (sum of 4 uniforms, centred, unit variance ≈ 1/3).
    mutating func noise() -> Float {
        Float(unit() + unit() + unit() + unit() - 2.0)
    }
}

// MARK: - Synthetic speech-like audio

enum SyntheticSpeech {

    /// Render `seconds` of speech-like audio in [-0.95, 0.95].
    static func render(seconds: Double, seed: UInt64, sampleRate: Int = 8_000) -> [Float] {
        let total = Int(seconds * Double(sampleRate))
        var out = [Float](repeating: 0, count: total)
        var rng = SplitMix64(seed: seed)
        var cursor = 0
        while cursor < total {
            let kind = rng.unit()
            if kind < 0.40 {
                cursor = noiseBurst(into: &out, at: cursor, rng: &rng, sampleRate: sampleRate)
            } else if kind < 0.70 {
                cursor = blip(into: &out, at: cursor, rng: &rng, sampleRate: sampleRate)
            } else if kind < 0.85 {
                cursor = sweep(into: &out, at: cursor, rng: &rng, sampleRate: sampleRate)
            } else {
                cursor += Int(rng.range(0.10, 0.50) * Double(sampleRate))
            }
            cursor += Int(rng.range(0, 0.04) * Double(sampleRate))
        }
        return out
    }

    /// Attack / exponential-decay envelope, hard release in the last 5 ms.
    private static func envelope(_ i: Int, count: Int, sampleRate: Int) -> Float {
        let attack = max(1, min(count / 5, sampleRate / 100))
        let release = max(1, min(count / 5, sampleRate / 200))
        var e: Float = 1
        if i < attack { e = Float(i) / Float(attack) }
        if i >= count - release { e = min(e, Float(count - i) / Float(release)) }
        let tau = Float(count) / 2
        return e * expf(-Float(i) / tau)
    }

    private static func noiseBurst(into out: inout [Float], at start: Int, rng: inout SplitMix64,
                                   sampleRate: Int) -> Int {
        let count = Int(rng.range(0.06, 0.35) * Double(sampleRate))
        let centre = rng.range(200, 3_000)
        let q = rng.range(1, 4)
        let amp = Float(rng.range(0.15, 0.6))
        // RBJ band-pass (constant 0 dB peak gain).
        let w0 = 2 * Double.pi * centre / Double(sampleRate)
        let alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0
        let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        var burst = [Float](repeating: 0, count: count)
        var peak: Float = 1e-6
        for i in 0..<count {
            let x = Double(rng.noise())
            let y = b0 * x + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x; y2 = y1; y1 = y
            let v = Float(y) * envelope(i, count: count, sampleRate: sampleRate)
            burst[i] = v
            peak = max(peak, abs(v))
        }
        let gain = amp / peak
        for i in 0..<count where start + i < out.count {
            out[start + i] += burst[i] * gain
        }
        return start + count
    }

    private static func blip(into out: inout [Float], at start: Int, rng: inout SplitMix64,
                             sampleRate: Int) -> Int {
        let count = Int(rng.range(0.05, 0.25) * Double(sampleRate))
        let f0 = rng.range(100, 1_800)
        let harmonics = 1 + Int(rng.unit() * 4)
        let amp = Float(rng.range(0.2, 0.7))
        let phase0 = rng.range(0, 2 * .pi)
        for i in 0..<count where start + i < out.count {
            let t = Double(i) / Double(sampleRate)
            var v = 0.0
            for h in 1...harmonics where f0 * Double(h) < Double(sampleRate) / 2 {
                v += sin(2 * .pi * f0 * Double(h) * t + phase0 * Double(h)) / Double(h)
            }
            out[start + i] += Float(v) * amp * 0.6 * envelope(i, count: count, sampleRate: sampleRate)
        }
        return start + count
    }

    private static func sweep(into out: inout [Float], at start: Int, rng: inout SplitMix64,
                              sampleRate: Int) -> Int {
        let count = Int(rng.range(0.10, 0.40) * Double(sampleRate))
        let f0 = rng.range(200, 3_000)
        let f1 = rng.range(200, 3_000)
        let amp = Float(rng.range(0.2, 0.6))
        let duration = Double(count) / Double(sampleRate)
        for i in 0..<count where start + i < out.count {
            let t = Double(i) / Double(sampleRate)
            let phase = 2 * .pi * (f0 * t + (f1 - f0) * t * t / (2 * duration))
            out[start + i] += Float(sin(phase)) * amp * envelope(i, count: count, sampleRate: sampleRate)
        }
        return start + count
    }

    static func toInt16(_ samples: [Float]) -> [Int16] {
        samples.map { Int16(max(-1, min(1, $0)) * 32_767) }
    }

    static func rms(_ samples: [Float]) -> Float {
        var value: Float = 0
        vDSP_rmsqv(samples, 1, &value, vDSP_Length(samples.count))
        return value
    }

    /// `samples` plus white noise at `snrDB` relative to the signal's RMS.
    static func addNoise(_ samples: [Float], snrDB: Double, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        let signal = rms(samples)
        let noiseRMS = signal / Float(pow(10, snrDB / 20))
        // SplitMix `noise()` has variance 1/3 → RMS 0.577.
        let gain = noiseRMS / 0.577
        return samples.map { $0 + rng.noise() * gain }
    }
}

// MARK: - WAV writer

enum WAVWriter {
    static func write(_ samples: [Int16], sampleRate: Int, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let byteCount = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16)
        u16(1); u16(1); u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(byteCount)
        samples.withUnsafeBufferPointer { buf in
            buf.baseAddress.map { data.append(UnsafeBufferPointer(start: UnsafeRawPointer($0)
                .assumingMemoryBound(to: UInt8.self), count: samples.count * 2)) }
        }
        try data.write(to: url)
    }
}

// MARK: - The fixture matrix

/// Every synthetic file the suite needs, by name. Rendered masters are kept
/// as Int16 so PCM-only tests (scale, determinism) skip ffmpeg entirely.
struct AudioFixtures: Sendable {
    let directory: URL
    let sampleRate = 8_000
    /// Masters A, B, C (180 s), D = [B 0–30 | A | C 0–30] (240 s),
    /// E = A with its last 120 s replaced by C's last 120 s (180 s).
    let a: [Int16], b: [Int16], c: [Int16], d: [Int16], e: [Int16]
    /// Fixture name → file. Missing names are in `unavailable` with a reason.
    let files: [String: URL]
    let unavailable: [String: String]

    func url(_ name: String) throws -> URL {
        if let url = files[name] { return url }
        throw FixtureUnavailable(name: name, reason: unavailable[name] ?? "not built")
    }

    struct FixtureUnavailable: Error, CustomStringConvertible {
        let name: String, reason: String
        var description: String { "fixture \(name) unavailable: \(reason)" }
    }

    static let masterSeconds = 180.0
    static let seedA: UInt64 = 0xA11CE, seedB: UInt64 = 0xB0B, seedC: UInt64 = 0xC0FFEE
}

/// Builds the matrix once per process and memoises fingerprints per file.
actor AudioFixtureStore {
    static let shared = AudioFixtureStore()

    private var buildTask: Task<AudioFixtures, Error>?
    private var fingerprints: [String: Task<AudioFingerprint, Error>] = [:]

    func fixtures() async throws -> AudioFixtures {
        if let buildTask { return try await buildTask.value }
        let task = Task { try await AudioFixtureBuilder.build() }
        buildTask = task
        return try await task.value
    }

    /// Fingerprint of a named fixture file, decoded through the real
    /// `AudioPCMDecoder` (ffmpeg) — computed once, shared by every case.
    func fingerprint(_ name: String) async throws -> AudioFingerprint {
        let fixtures = try await fixtures()
        let url = try fixtures.url(name)
        if let task = fingerprints[name] { return try await task.value }
        let task = Task {
            let pcm = try await AudioPCMDecoder().decode(path: url.path)
            return AudioFingerprint.compute(pcm)
        }
        fingerprints[name] = task
        return try await task.value
    }
}

enum AudioFixtureBuilder {

    static func build() async throws -> AudioFixtures {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_audiofp_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.path
        atexit_b { try? FileManager.default.removeItem(atPath: path) }

        let sr = 8_000
        let secs = AudioFixtures.masterSeconds
        let fa = SyntheticSpeech.render(seconds: secs, seed: AudioFixtures.seedA, sampleRate: sr)
        let fb = SyntheticSpeech.render(seconds: secs, seed: AudioFixtures.seedB, sampleRate: sr)
        let fc = SyntheticSpeech.render(seconds: secs, seed: AudioFixtures.seedC, sampleRate: sr)
        let a = SyntheticSpeech.toInt16(fa), b = SyntheticSpeech.toInt16(fb), c = SyntheticSpeech.toInt16(fc)
        let thirty = 30 * sr, sixty = 60 * sr
        let d = Array(b[0..<thirty]) + a + Array(c[0..<thirty])
        let e = Array(a[0..<sixty]) + Array(c[sixty...])
        let noisy = SyntheticSpeech.toInt16(SyntheticSpeech.addNoise(fa, snrDB: 10, seed: 0x5EED))

        var files: [String: URL] = [:]
        var unavailable: [String: String] = [:]
        func wav(_ name: String, _ samples: [Int16]) throws {
            let url = dir.appendingPathComponent("test_\(name).wav")
            try WAVWriter.write(samples, sampleRate: sr, to: url)
            files[name] = url
        }
        try wav("A", a); try wav("B", b); try wav("C", c); try wav("D", d); try wav("E", e)
        try wav("A_noise10dB", noisy)
        let aURL = dir.appendingPathComponent("test_A.wav")
        let bURL = dir.appendingPathComponent("test_B.wav")
        try FileManager.default.copyItem(at: aURL, to: dir.appendingPathComponent("test_A_copy.wav"))
        files["A_copy"] = dir.appendingPathComponent("test_A_copy.wav")

        // ffmpeg-made variants. Each is (name, extension, args between -i A and the output).
        let aPath = aURL.path
        let variants: [(name: String, ext: String, pre: [String], post: [String])] = [
            ("A_aac96", "mp4", [], ["-c:a", "aac", "-b:a", "96k"]),
            ("A_mp3_64", "mp3", [], ["-c:a", "libmp3lame", "-b:a", "64k"]),
            ("A_44k", "wav", [], ["-ar", "44100", "-c:a", "pcm_s16le"]),
            ("A_32k", "wav", [], ["-ar", "32000", "-c:a", "pcm_s16le"]),
            ("A_minus6dB", "wav", [], ["-af", "volume=-6dB", "-c:a", "pcm_s16le"]),
            ("A_plus6dB", "wav", [], ["-af", "volume=6dB", "-c:a", "pcm_s16le"]),
            ("A_stereo", "wav", [], ["-ac", "2", "-c:a", "pcm_s16le"]),
            ("A_stereo_delay300", "wav", [],
             ["-af", "pan=stereo|c0=c0|c1=c0,adelay=0|300", "-c:a", "pcm_s16le"]),
            ("A_speed0_5pct", "wav", [], ["-af", "asetrate=8040,aresample=8000", "-c:a", "pcm_s16le"]),
            ("A_sub20_at60_aac", "mp4", ["-ss", "60", "-t", "20"], ["-c:a", "aac", "-b:a", "96k"]),
            ("A_sub5_at100", "wav", ["-ss", "100", "-t", "5"], ["-c:a", "pcm_s16le"]),
            ("A_reversed", "wav", [], ["-af", "areverse", "-c:a", "pcm_s16le"]),
            ("A_copy_mov", "mov", [], ["-c:a", "pcm_s16le"]),
            ("A_copy_mkv", "mkv", [], ["-c:a", "flac"]),
            // The MXF muxer insists on exactly one video stream, first, and
            // 48 kHz PCM — so this one carries a black 64×64 MPEG-2 track and
            // a resample. The decoder's -vn must ignore the picture.
            ("A_copy_mxf", "mxf", ["-f", "lavfi", "-i", "color=c=black:s=64x64:r=25"],
             ["-map", "0:v", "-map", "1:a", "-c:v", "mpeg2video", "-ar", "48000", "-c:a", "pcm_s16le",
              "-shortest"]),
            ("A_copy_avi", "avi", [], ["-c:a", "pcm_s16le"]),
        ]
        for v in variants {
            let out = dir.appendingPathComponent("test_\(v.name).\(v.ext)")
            let args = ["-nostdin", "-v", "error"] + v.pre + ["-i", aPath] + v.post + ["-y", out.path]
            if let why = await ffmpeg(args) { unavailable[v.name] = why } else { files[v.name] = out }
        }
        // 20-s subclips of B every 20 s (9 of them), as negatives against A.
        for i in stride(from: 0, to: 180, by: 20) {
            let name = "B_sub20_at\(i)"
            let out = dir.appendingPathComponent("test_\(name).wav")
            let args = ["-nostdin", "-v", "error", "-ss", "\(i)", "-t", "20", "-i", bURL.path,
                        "-c:a", "pcm_s16le", "-y", out.path]
            if let why = await ffmpeg(args) { unavailable[name] = why } else { files[name] = out }
        }
        await buildSynthetics(in: dir, files: &files, unavailable: &unavailable)

        return AudioFixtures(directory: dir, a: a, b: b, c: c, d: d, e: e,
                             files: files, unavailable: unavailable)
    }

    /// Silence, a 1 kHz tone, a 0-byte file, a video-only file.
    private static func buildSynthetics(in dir: URL, files: inout [String: URL],
                                        unavailable: inout [String: String]) async {
        let silence = dir.appendingPathComponent("test_silence.wav")
        if let why = await ffmpeg(["-nostdin", "-v", "error", "-f", "lavfi", "-i", "anullsrc=r=8000:cl=mono",
                                   "-t", "180", "-c:a", "pcm_s16le", "-y", silence.path]) {
            unavailable["silence"] = why
        } else { files["silence"] = silence }
        let tone = dir.appendingPathComponent("test_tone1k.wav")
        if let why = await ffmpeg(["-nostdin", "-v", "error", "-f", "lavfi", "-i",
                                   "sine=frequency=1000:sample_rate=8000", "-t", "180",
                                   "-c:a", "pcm_s16le", "-y", tone.path]) {
            unavailable["tone1k"] = why
        } else { files["tone1k"] = tone }
        let empty = dir.appendingPathComponent("test_empty.mp4")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        files["empty"] = empty
        let videoOnly = dir.appendingPathComponent("test_video_only.mp4")
        if let why = await ffmpeg(["-nostdin", "-v", "error", "-f", "lavfi", "-i",
                                   "testsrc=duration=2:size=64x64:rate=5", "-c:v", "mpeg4",
                                   "-y", videoOnly.path]) {
            unavailable["video_only"] = why
        } else { files["video_only"] = videoOnly }
    }

    /// nil on success, otherwise the reason (ffmpeg's stderr tail).
    private static func ffmpeg(_ args: [String]) async -> String? {
        let result = await ProcessRunner.runProcess(executable: FFmpegLocator.ffmpegPath, arguments: args,
                                                    deadlineSeconds: 120)
        if result.exitCode == 0 { return nil }
        return "ffmpeg exit \(result.exitCode): \(result.stderr.suffix(300))"
    }
}
