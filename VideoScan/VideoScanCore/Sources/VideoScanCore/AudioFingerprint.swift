// AudioFingerprint.swift (VideoScanCore)
// ONE SENTENCE: a Shazam-style landmark fingerprint of an audio signal — a
// deterministic, compact list of (hash, time) pairs that survives re-encodes,
// rewraps, gain changes and noise, so two files can be asked "same recording,
// at what offset?".
//
// HOW (Wang 2003, "An Industrial-Strength Audio Search Algorithm"):
//   1. STFT — Hann window, N = 1024, hop 512 at 8 kHz: one frame every
//      64 ms, bins 15.6 Hz wide, 512 usable bins (bin 0 = DC, ignored).
//      Power is normalised so a full-scale sine reads 0 dB.
//   2. Peaks — a bin is a peak when it equals the maximum of its
//      ±timeRadius × ±frequencyRadius neighbourhood (so it is ≥ every
//      neighbour), sits above an absolute floor and above the frame's mean
//      level by a margin; at most `maxPeaksPerFrame`, loudest first.
//      Digital silence yields none (it never clears the floor).
//   3. Landmarks — each peak anchors pairs with the next `fanOut` peaks
//      1…63 frames later and within ±maxDeltaBins: one UInt32 hash packs
//      (f1, f2, dt); the anchor frame is the landmark's time. Gain changes
//      do not move peaks; a lossy codec or added noise removes some peaks
//      and adds a few, and the survivors still vote (AudioFingerprintMatcher).
//
// MEMORY: the spectrogram is never held whole. A ring of 2×timeRadius+1
// level frames and the same number of frequency-dilated frames (7 × 512
// floats each) feeds peak picking; pairing runs over the finished peak list
// (≈ 3 peaks/frame × 16 B). For a 60-minute file: peaks ≈ 2.7 MB, the
// landmarks ≈ 8 B each. The PCM passed in is the only O(file) buffer.
//
// (For Rick: `vDSP_DFT_zrop` is Accelerate's real-to-complex FFT — the
// same half-spectrum trick as FFTW's r2c; the setup object is reused across
// frames like an FFTW plan. The doubling max-filter is van Herk's trick:
// log₂(radius) vector max ops instead of a radius-wide loop.)

import Accelerate
import Foundation

/// Every knob of the fingerprint, in one place. The defaults ARE the
/// fingerprint's version-1 recipe; change them and bump `currentVersion`.
public struct AudioFingerprintParameters: Sendable, Equatable {
    /// Expected PCM rate (the decoder's default).
    public var sampleRate: Int = 8_000
    /// STFT size (power of two) and hop in samples.
    public var frameSize: Int = 1_024
    public var hopSamples: Int = 512
    /// Peak neighbourhood: ± frames and ± bins.
    public var timeRadius: Int = 3
    public var frequencyRadius: Int = 15
    public var maxPeaksPerFrame: Int = 5
    /// Before analysis the signal is scaled so its RMS is `targetRMS`
    /// (0.1 = −20 dBFS) — a −6 dB or +6 dB copy then yields the same
    /// peaks as the original. Silence is left alone; `maxGain` bounds the
    /// boost for near-silent input so hiss is not promoted to signal.
    public var targetRMS: Float = 0.1
    public var maxGain: Float = 100
    /// Absolute floor in dB re full-scale sine (0 dB), after normalisation.
    /// −60 dB clears the 16-bit dither floor (≈ −58 dB per bin for white
    /// noise at −90 dBFS) while keeping quiet speech (−40 dBFS) in play.
    public var floorDB: Float = -60
    /// A peak must also stand this far above its frame's mean level.
    public var aboveFrameMeanDB: Float = 6
    /// Targets paired with each anchor, and the target zone.
    public var fanOut: Int = 5
    public var minDeltaFrames: Int = 1
    public var maxDeltaFrames: Int = 63
    public var maxDeltaBins: Int = 127

    public init() {}
    public static let `default` = AudioFingerprintParameters()

    public var hopSeconds: Double { Double(hopSamples) / Double(sampleRate) }
    var binCount: Int { frameSize / 2 }
}

public struct AudioFingerprint: Sendable, Equatable {
    public static let currentVersion: UInt16 = 1
    /// First four bytes of the binary encoding.
    public static let magic: [UInt8] = Array("VSAF".utf8)
    /// magic 4 + version 2 + sampleRate 4 + hop 4 + frameSize 4 + duration 8 + count 4.
    static let headerBytes = 30

    public let version: UInt16
    public let sampleRate: Int
    public let hopSamples: Int
    public let frameSize: Int
    public let durationSeconds: Double
    /// Parallel arrays: `hashes[i]` was anchored at frame `times[i]`.
    public let hashes: [UInt32]
    public let times: [UInt32]

    public init(version: UInt16 = AudioFingerprint.currentVersion, sampleRate: Int, hopSamples: Int,
                frameSize: Int, durationSeconds: Double, hashes: [UInt32], times: [UInt32]) {
        self.version = version
        self.sampleRate = sampleRate
        self.hopSamples = hopSamples
        self.frameSize = frameSize
        self.durationSeconds = durationSeconds
        self.hashes = hashes
        self.times = times
    }

    public var landmarkCount: Int { hashes.count }
    public var hopSeconds: Double { Double(hopSamples) / Double(sampleRate) }
    /// Exactly `encoded().count`.
    public var estimatedBytes: Int { Self.headerBytes + 8 * hashes.count }

    // MARK: Hash packing — f1: 9 bits, f2: 9 bits, dt: 6 bits (24 used)

    public static func packHash(f1: Int, f2: Int, dt: Int) -> UInt32 {
        (UInt32(f1 & 0x1FF) << 15) | (UInt32(f2 & 0x1FF) << 6) | UInt32(dt & 0x3F)
    }

    public static func unpackHash(_ hash: UInt32) -> (f1: Int, f2: Int, dt: Int) {
        (Int((hash >> 15) & 0x1FF), Int((hash >> 6) & 0x1FF), Int(hash & 0x3F))
    }

    // MARK: Binary encoding (little-endian, versioned)

    public func encoded() -> Data {
        var data = Data(capacity: estimatedBytes)
        data.append(contentsOf: Self.magic)
        Self.append(version, to: &data)
        Self.append(UInt32(sampleRate), to: &data)
        Self.append(UInt32(hopSamples), to: &data)
        Self.append(UInt32(frameSize), to: &data)
        Self.append(durationSeconds.bitPattern, to: &data)
        Self.append(UInt32(hashes.count), to: &data)
        for h in hashes { Self.append(h, to: &data) }
        for t in times { Self.append(t, to: &data) }
        return data
    }

    /// nil when the bytes are not a version-1 fingerprint of the stated size.
    public init?(decoding data: Data) {
        guard data.count >= Self.headerBytes, Array(data.prefix(4)) == Self.magic else { return nil }
        var reader = LittleEndianReader(data: data, offset: 4)
        guard let version: UInt16 = reader.read(), version == Self.currentVersion,
              let sampleRate: UInt32 = reader.read(), let hop: UInt32 = reader.read(),
              let frameSize: UInt32 = reader.read(), let durationBits: UInt64 = reader.read(),
              let count: UInt32 = reader.read(),
              data.count == Self.headerBytes + 8 * Int(count) else { return nil }
        var hashes = [UInt32](), times = [UInt32]()
        hashes.reserveCapacity(Int(count)); times.reserveCapacity(Int(count))
        for _ in 0..<count { guard let h: UInt32 = reader.read() else { return nil }; hashes.append(h) }
        for _ in 0..<count { guard let t: UInt32 = reader.read() else { return nil }; times.append(t) }
        self.init(version: version, sampleRate: Int(sampleRate), hopSamples: Int(hop), frameSize: Int(frameSize),
                  durationSeconds: Double(bitPattern: durationBits), hashes: hashes, times: times)
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: Compute

    /// The fingerprint of `pcm`. Pure and deterministic: equal samples give
    /// equal landmarks on every run and every Mac.
    public static func compute(_ pcm: AudioPCM,
                               parameters: AudioFingerprintParameters = .default) -> AudioFingerprint {
        let gain = normalisingGain(pcm.samples, parameters: parameters)
        let peaks = SpectralPeakPicker(parameters: parameters)?.peaks(in: pcm.samples, gain: gain) ?? []
        let landmarks = LandmarkPairer.pair(peaks, parameters: parameters)
        return AudioFingerprint(sampleRate: pcm.sampleRate, hopSamples: parameters.hopSamples,
                                frameSize: parameters.frameSize, durationSeconds: pcm.durationSeconds,
                                hashes: landmarks.hashes, times: landmarks.times)
    }

    /// Linear gain that brings the signal's RMS to `targetRMS` (1 for
    /// silence; at most `maxGain`). Summed in 64 K-sample chunks so no
    /// whole-file Float copy is made.
    static func normalisingGain(_ samples: [Int16], parameters: AudioFingerprintParameters) -> Float {
        guard !samples.isEmpty else { return 1 }
        let chunk = 65_536
        var scratch = [Float](repeating: 0, count: chunk)
        var sumOfSquares = 0.0
        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            var offset = 0
            while offset < samples.count {
                let count = min(chunk, samples.count - offset)
                vDSP_vflt16(base + offset, 1, &scratch, 1, vDSP_Length(count))
                var sum: Float = 0
                vDSP_svesq(scratch, 1, &sum, vDSP_Length(count))
                sumOfSquares += Double(sum)
                offset += count
            }
        }
        let rms = Float((sumOfSquares / Double(samples.count)).squareRoot()) / 32_768
        guard rms > 0 else { return 1 }
        return min(parameters.maxGain, parameters.targetRMS / rms)
    }
}

/// Reads little-endian fixed-width integers out of a Data, in order.
private struct LittleEndianReader {
    let data: Data
    var offset: Int

    mutating func read<T: FixedWidthInteger>() -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.count else { return nil }
        var raw: T = 0
        _ = withUnsafeMutableBytes(of: &raw) { data.copyBytes(to: $0, from: offset..<(offset + size)) }
        offset += size
        return T(littleEndian: raw)
    }
}

// MARK: - Spectral peaks

struct SpectralPeak: Equatable {
    let frame: Int
    let bin: Int
    let level: Float
}

/// Streaming STFT → level frames → neighbourhood-max peak picking. One
/// instance per `compute` call; its scratch buffers are allocated once and
/// reused for every frame (no per-frame allocation, no pointer escapes).
final class SpectralPeakPicker {
    private let p: AudioFingerprintParameters
    private let dft: vDSP_DFT_Setup
    private let bins: Int
    private let size: Int
    private let window: UnsafeMutablePointer<Float>      // size
    private let frame: UnsafeMutablePointer<Float>       // size: windowed samples
    private let inReal: UnsafeMutablePointer<Float>      // bins
    private let inImag: UnsafeMutablePointer<Float>
    private let outReal: UnsafeMutablePointer<Float>
    private let outImag: UnsafeMutablePointer<Float>
    private let power: UnsafeMutablePointer<Float>
    private let scratchA: UnsafeMutablePointer<Float>
    private let scratchB: UnsafeMutablePointer<Float>
    /// dB at or below this is silence (and never ties a real peak).
    private static let silentDB: Float = -200

    init?(parameters: AudioFingerprintParameters) {
        let size = parameters.frameSize
        guard size >= 8, size & (size - 1) == 0, parameters.hopSamples > 0,
              let dft = vDSP_DFT_zrop_CreateSetup(nil, vDSP_Length(size), .FORWARD)
        else { return nil }
        self.p = parameters
        self.dft = dft
        self.size = size
        self.bins = parameters.binCount
        window = .allocate(capacity: size)
        frame = .allocate(capacity: size)
        inReal = .allocate(capacity: bins); inImag = .allocate(capacity: bins)
        outReal = .allocate(capacity: bins); outImag = .allocate(capacity: bins)
        power = .allocate(capacity: bins)
        scratchA = .allocate(capacity: bins); scratchB = .allocate(capacity: bins)
        vDSP_hann_window(window, vDSP_Length(size), Int32(vDSP_HANN_DENORM))
    }

    deinit {
        vDSP_DFT_DestroySetup(dft)
        for buffer in [window, frame, inReal, inImag, outReal, outImag, power, scratchA, scratchB] {
            buffer.deallocate()
        }
    }

    func peaks(in samples: [Int16], gain: Float = 1) -> [SpectralPeak] {
        let n = samples.count
        guard n >= size else { return [] }
        let frameCount = (n - size) / p.hopSamples + 1
        let ringSize = 2 * p.timeRadius + 1
        var levelRing = [[Float]](repeating: [], count: ringSize)
        var dilatedRing = [[Float]](repeating: [], count: ringSize)
        var neighbourhood = [Float](repeating: 0, count: bins)
        var peaks: [SpectralPeak] = []
        peaks.reserveCapacity(frameCount * 3)

        samples.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            for index in 0..<frameCount {
                let level = levelFrame(base + index * p.hopSamples, gain: gain)
                levelRing[index % ringSize] = level
                dilatedRing[index % ringSize] = frequencyDilated(level)
                // The frame `timeRadius` back now has all its neighbours.
                let centre = index - p.timeRadius
                guard centre >= p.timeRadius else { continue }
                timeMax(dilatedRing, into: &neighbourhood)
                pick(frame: centre, level: levelRing[centre % ringSize], neighbourhood: neighbourhood,
                     into: &peaks)
            }
        }
        return peaks
    }

    /// Level (dB re full-scale sine) per bin for one Hann-windowed frame.
    private func levelFrame(_ start: UnsafePointer<Int16>, gain: Float) -> [Float] {
        let length = vDSP_Length(size)
        vDSP_vflt16(start, 1, frame, 1, length)
        var scale = gain / 32_768
        vDSP_vsmul(frame, 1, &scale, frame, 1, length)
        vDSP_vmul(frame, 1, window, 1, frame, 1, length)
        // Real → split-complex packing (even samples real, odd imaginary).
        var split = DSPSplitComplex(realp: inReal, imagp: inImag)
        frame.withMemoryRebound(to: DSPComplex.self, capacity: bins) { complex in
            vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(bins))
        }
        vDSP_DFT_Execute(dft, inReal, inImag, outReal, outImag)
        var outSplit = DSPSplitComplex(realp: outReal, imagp: outImag)
        vDSP_zvmags(&outSplit, 1, power, 1, vDSP_Length(bins))
        // zrop output is 2× the DFT; a full-scale Hann-windowed sine peaks
        // at |X| = 2 × A × Σw / 2 = N/2 → power (N/2)². Normalise to 0 dB.
        var reference = Float(size / 2) * Float(size / 2)
        var floor: Float = reference * powf(10, Self.silentDB / 10)
        vDSP_vsadd(power, 1, &floor, power, 1, vDSP_Length(bins))
        vDSP_vdbcon(power, 1, &reference, scratchA, 1, vDSP_Length(bins), 1)   // 10·log10(power/ref)
        scratchA[0] = Self.silentDB   // DC + Nyquist share bin 0; never a peak
        return Array(UnsafeBufferPointer(start: scratchA, count: bins))
    }

    /// max over ±frequencyRadius bins, by doubling steps (1, 2, 4, …, rest).
    private func frequencyDilated(_ level: [Float]) -> [Float] {
        level.withUnsafeBufferPointer { src in
            guard let base = src.baseAddress else { return }
            scratchA.update(from: base, count: bins)
        }
        var covered = 0
        var step = 1
        while covered < p.frequencyRadius {
            let s = min(step, p.frequencyRadius - covered)
            let length = vDSP_Length(bins - s)
            scratchB.update(from: scratchA, count: bins)
            // B[s...] = max(B[s...], A[..<bins-s])  (shift right)
            vDSP_vmax(scratchA, 1, scratchB + s, 1, scratchB + s, 1, length)
            // B[..<bins-s] = max(B[..<bins-s], A[s...])  (shift left)
            vDSP_vmax(scratchA + s, 1, scratchB, 1, scratchB, 1, length)
            scratchA.update(from: scratchB, count: bins)
            covered += s
            step *= 2
        }
        return Array(UnsafeBufferPointer(start: scratchA, count: bins))
    }

    /// Elementwise max over every frame in the ring.
    private func timeMax(_ ring: [[Float]], into out: inout [Float]) {
        out = ring[0]
        for i in 1..<ring.count {
            vDSP_vmax(ring[i], 1, out, 1, &out, 1, vDSP_Length(bins))
        }
    }

    private func pick(frame: Int, level: [Float], neighbourhood: [Float], into peaks: inout [SpectralPeak]) {
        var mean: Float = 0
        vDSP_meanv(level, 1, &mean, vDSP_Length(bins))
        let threshold = max(p.floorDB, mean + p.aboveFrameMeanDB)
        var candidates: [SpectralPeak] = []
        level.withUnsafeBufferPointer { lv in
            neighbourhood.withUnsafeBufferPointer { nb in
                for bin in 1..<bins where lv[bin] > threshold && lv[bin] == nb[bin] {
                    candidates.append(SpectralPeak(frame: frame, bin: bin, level: lv[bin]))
                }
            }
        }
        if candidates.count > p.maxPeaksPerFrame {
            candidates.sort { $0.level != $1.level ? $0.level > $1.level : $0.bin < $1.bin }
            candidates.removeSubrange(p.maxPeaksPerFrame...)
            candidates.sort { $0.bin < $1.bin }
        }
        peaks.append(contentsOf: candidates)
    }
}

// MARK: - Landmarks

enum LandmarkPairer {
    /// Anchor → next `fanOut` peaks in the target zone. `peaks` must be in
    /// frame order (then bin order), as the picker emits them.
    static func pair(_ peaks: [SpectralPeak],
                     parameters p: AudioFingerprintParameters) -> (hashes: [UInt32], times: [UInt32]) {
        var hashes: [UInt32] = [], times: [UInt32] = []
        hashes.reserveCapacity(peaks.count * p.fanOut)
        times.reserveCapacity(peaks.count * p.fanOut)
        for i in peaks.indices {
            let anchor = peaks[i]
            var paired = 0
            var j = i + 1
            while j < peaks.count, paired < p.fanOut {
                let target = peaks[j]
                let dt = target.frame - anchor.frame
                if dt > p.maxDeltaFrames { break }
                if dt >= p.minDeltaFrames, abs(target.bin - anchor.bin) <= p.maxDeltaBins {
                    hashes.append(AudioFingerprint.packHash(f1: anchor.bin, f2: target.bin, dt: dt))
                    times.append(UInt32(anchor.frame))
                    paired += 1
                }
                j += 1
            }
        }
        return (hashes, times)
    }
}
