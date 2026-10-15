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
/// version-1 recipe. The recipe (algorithm revision + every knob) has its
/// own identity, `recipeID`, written into each fingerprint: two
/// fingerprints can only be compared when their recipes agree. That is
/// separate from `AudioFingerprint.currentVersion` (the on-disk FORMAT) and
/// from `AudioMatchPolicy` (how evidence is READ).
///
/// The knobs are plain `var`s so a caller can tune them, and `validate()`
/// is the gate: `AudioFingerprint.compute` refuses invalid parameters
/// loudly (a programmer error, like an out-of-range subscript), never by
/// silently aliasing bits. (For Rick: validate() is the throwing
/// front door for the backfill job to call once at start-up; the
/// precondition in compute is the assert behind it.)
public struct AudioFingerprintParameters: Sendable, Equatable {
    /// Expected PCM rate (the decoder's default).
    public var sampleRate: Int = 8_000
    /// STFT size (power of two, ≤ `maxFrameSize`) and hop in samples.
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

    // MARK: Invariants

    /// `dt` is packed in 6 bits: 1…63.
    public static let deltaFramesLimit = 63
    /// `f1`/`f2` are packed in 9 bits: bins 0…511, so frameSize/2 ≤ 512.
    public static let maxFrameSize = 1_024
    /// Bumped when the ALGORITHM changes with the knobs unchanged (a new
    /// peak picker, say) so old fingerprints are not compared to new ones.
    public static let algorithmRevision: UInt32 = 1

    public enum ValidationError: Error, Equatable, Sendable {
        case sampleRateNotPositive(Int)
        /// Not a power of two, or below 8.
        case frameSizeNotPowerOfTwo(Int)
        /// More bins than the 9-bit hash field can name.
        case frameSizeExceedsHashField(frameSize: Int, limit: Int)
        /// hop must be 1…frameSize.
        case hopOutOfRange(hop: Int, frameSize: Int)
        /// Need 1 ≤ min ≤ max ≤ 63 (the 6-bit dt field).
        case deltaFramesOutOfRange(min: Int, max: Int, limit: Int)
        case deltaBinsNegative(Int)
        case radiusNotPositive(time: Int, frequency: Int)
        case countNotPositive(name: String, value: Int)
        case gainOutOfRange(targetRMS: Float, maxGain: Float)
    }

    /// Every invariant the hash packing and the STFT rely on. Throws the
    /// FIRST violation found (top to bottom).
    public func validate() throws {
        guard sampleRate > 0 else { throw ValidationError.sampleRateNotPositive(sampleRate) }
        try Self.validateFrame(sampleRate: sampleRate, frameSize: frameSize, hopSamples: hopSamples)
        guard minDeltaFrames >= 1, minDeltaFrames <= maxDeltaFrames, maxDeltaFrames <= Self.deltaFramesLimit else {
            throw ValidationError.deltaFramesOutOfRange(min: minDeltaFrames, max: maxDeltaFrames,
                                                        limit: Self.deltaFramesLimit)
        }
        guard maxDeltaBins >= 0 else { throw ValidationError.deltaBinsNegative(maxDeltaBins) }
        guard timeRadius >= 1, frequencyRadius >= 1 else {
            throw ValidationError.radiusNotPositive(time: timeRadius, frequency: frequencyRadius)
        }
        guard maxPeaksPerFrame >= 1 else {
            throw ValidationError.countNotPositive(name: "maxPeaksPerFrame", value: maxPeaksPerFrame)
        }
        guard fanOut >= 1 else { throw ValidationError.countNotPositive(name: "fanOut", value: fanOut) }
        guard targetRMS > 0, targetRMS <= 1, maxGain >= 1 else {
            throw ValidationError.gainOutOfRange(targetRMS: targetRMS, maxGain: maxGain)
        }
    }

    /// The part of `validate()` a decoded VSAF header is held to as well.
    static func validateFrame(sampleRate: Int, frameSize: Int, hopSamples: Int) throws {
        guard sampleRate > 0 else { throw ValidationError.sampleRateNotPositive(sampleRate) }
        guard frameSize >= 8, frameSize & (frameSize - 1) == 0 else {
            throw ValidationError.frameSizeNotPowerOfTwo(frameSize)
        }
        guard frameSize <= Self.maxFrameSize else {
            throw ValidationError.frameSizeExceedsHashField(frameSize: frameSize, limit: Self.maxFrameSize)
        }
        guard hopSamples >= 1, hopSamples <= frameSize else {
            throw ValidationError.hopOutOfRange(hop: hopSamples, frameSize: frameSize)
        }
    }

    public var isValid: Bool {
        do { try validate(); return true } catch { return false }
    }

    /// Identity of the recipe: FNV-1a (32-bit) over the algorithm revision
    /// and every knob, in declaration order, as little-endian 32-bit words
    /// (floats by bit pattern). Deterministic across machines.
    public var recipeID: UInt32 {
        var hash: UInt32 = 0x811C_9DC5
        func mix(_ word: UInt32) {
            for shift in stride(from: 0, to: 32, by: 8) {
                hash ^= (word >> UInt32(shift)) & 0xFF
                hash = hash &* 0x0100_0193
            }
        }
        mix(Self.algorithmRevision)
        for value in [sampleRate, frameSize, hopSamples, timeRadius, frequencyRadius, maxPeaksPerFrame] {
            mix(UInt32(truncatingIfNeeded: value))
        }
        for value in [targetRMS, maxGain, floorDB, aboveFrameMeanDB] { mix(value.bitPattern) }
        for value in [fanOut, minDeltaFrames, maxDeltaFrames, maxDeltaBins] {
            mix(UInt32(truncatingIfNeeded: value))
        }
        return hash
    }
}

public struct AudioFingerprint: Sendable, Equatable {
    /// On-disk FORMAT version (the header layout below). 2 = recipeID and
    /// completeness flag added (codex F3/F2, 2026-10-14). Nothing was
    /// persisted at version 1.
    public static let currentVersion: UInt16 = 2
    /// First four bytes of the binary encoding.
    public static let magic: [UInt8] = Array("VSAF".utf8)
    /// Header layout (little-endian):
    ///   magic 4 | version u16 | recipeID u32 | flags u8 | sampleRate u32 |
    ///   hop u32 | frameSize u32 | analyzedSeconds f64 | landmarkCount u32
    /// then `hashes` (u32 × count) and `times` (u32 × count).
    /// flags bit 0 = `complete`.
    static let headerBytes = 35
    static let recipeFieldOffset = 6
    static let flagsFieldOffset = 10
    static let sampleRateFieldOffset = 11
    /// Byte offset of the hop field in the header (tests patch it).
    static let hopFieldOffset = 15
    static let frameSizeFieldOffset = 19
    static let completeFlag: UInt8 = 0x01

    public let version: UInt16
    /// `AudioFingerprintParameters.recipeID` of the recipe that made this.
    public let recipeID: UInt32
    public let sampleRate: Int
    public let hopSamples: Int
    public let frameSize: Int
    /// Seconds of audio the landmarks were taken from — the whole
    /// recording when `complete`, else a prefix (or a window) of it.
    public let durationSeconds: Double
    /// False when the PCM hit the decoder's cap or came from a window:
    /// the landmarks describe a part of the recording, and no verdict may
    /// treat them as the whole (see `AudioMatchEvidence.verdict`).
    public let complete: Bool
    /// Parallel arrays: `hashes[i]` was anchored at frame `times[i]`.
    public let hashes: [UInt32]
    public let times: [UInt32]

    /// Memberwise; `sampleRate`, `hopSamples` and `frameSize` must be
    /// positive (decode and compute validate before they get here).
    public init(version: UInt16 = AudioFingerprint.currentVersion,
                recipeID: UInt32 = AudioFingerprintParameters.default.recipeID,
                sampleRate: Int, hopSamples: Int, frameSize: Int, durationSeconds: Double,
                complete: Bool = true, hashes: [UInt32], times: [UInt32]) {
        precondition(sampleRate > 0 && hopSamples > 0 && frameSize > 0,
                     "AudioFingerprint: sampleRate, hopSamples and frameSize must be positive")
        precondition(hashes.count == times.count, "AudioFingerprint: hashes and times must be parallel")
        self.version = version
        self.recipeID = recipeID
        self.sampleRate = sampleRate
        self.hopSamples = hopSamples
        self.frameSize = frameSize
        self.durationSeconds = durationSeconds
        self.complete = complete
        self.hashes = hashes
        self.times = times
    }

    public var landmarkCount: Int { hashes.count }
    public var analyzedSeconds: Double { durationSeconds }
    public var hopSeconds: Double { Double(hopSamples) / Double(sampleRate) }
    /// Exactly `encoded().count`.
    public var estimatedBytes: Int { Self.headerBytes + 8 * hashes.count }

    /// True when `other` was made by the same recipe on the same grid, so
    /// the two may be matched.
    public func recipeMatches(_ other: AudioFingerprint) -> Bool {
        recipeID == other.recipeID && sampleRate == other.sampleRate
            && hopSamples == other.hopSamples && frameSize == other.frameSize
    }

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
        Self.append(recipeID, to: &data)
        data.append(complete ? Self.completeFlag : 0)
        Self.append(UInt32(sampleRate), to: &data)
        Self.append(UInt32(hopSamples), to: &data)
        Self.append(UInt32(frameSize), to: &data)
        Self.append(durationSeconds.bitPattern, to: &data)
        Self.append(UInt32(hashes.count), to: &data)
        for h in hashes { Self.append(h, to: &data) }
        for t in times { Self.append(t, to: &data) }
        return data
    }

    /// Why a blob was refused. Every case is a fact about the bytes.
    public enum DecodingError: Error, Equatable, Sendable {
        case tooShort(bytes: Int)
        case badMagic
        case unsupportedVersion(UInt16)
        /// The landmark count in the header does not match the byte count.
        case sizeMismatch(expected: Int, actual: Int)
        /// hop 0, sample rate 0, frame size not a power of two, hop > frame…
        case invalidHeader(AudioFingerprintParameters.ValidationError)
    }

    /// The bytes, or a named reason they are not a current-version
    /// fingerprint. A header the matcher could trap on (hop 0, sample
    /// rate 0, a frame size that is not a power of two) is refused HERE.
    public static func decode(_ data: Data) throws -> AudioFingerprint {
        guard data.count >= Self.headerBytes else { throw DecodingError.tooShort(bytes: data.count) }
        guard Array(data.prefix(4)) == Self.magic else { throw DecodingError.badMagic }
        var reader = LittleEndianReader(data: data, offset: 4)
        guard let version: UInt16 = reader.read(), let recipeID: UInt32 = reader.read(),
              let flags: UInt8 = reader.read(),
              let sampleRate: UInt32 = reader.read(), let hop: UInt32 = reader.read(),
              let frameSize: UInt32 = reader.read(), let durationBits: UInt64 = reader.read(),
              let count: UInt32 = reader.read() else { throw DecodingError.tooShort(bytes: data.count) }
        guard version == Self.currentVersion else { throw DecodingError.unsupportedVersion(version) }
        let expected = Self.headerBytes + 8 * Int(count)
        guard data.count == expected else { throw DecodingError.sizeMismatch(expected: expected, actual: data.count) }
        do {
            try AudioFingerprintParameters.validateFrame(sampleRate: Int(sampleRate), frameSize: Int(frameSize),
                                                         hopSamples: Int(hop))
        } catch let error as AudioFingerprintParameters.ValidationError {
            throw DecodingError.invalidHeader(error)
        }
        var hashes = [UInt32](), times = [UInt32]()
        hashes.reserveCapacity(Int(count)); times.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let h: UInt32 = reader.read() else { throw DecodingError.tooShort(bytes: data.count) }
            hashes.append(h)
        }
        for _ in 0..<count {
            guard let t: UInt32 = reader.read() else { throw DecodingError.tooShort(bytes: data.count) }
            times.append(t)
        }
        return AudioFingerprint(version: version, recipeID: recipeID, sampleRate: Int(sampleRate),
                                hopSamples: Int(hop), frameSize: Int(frameSize),
                                durationSeconds: Double(bitPattern: durationBits),
                                complete: flags & Self.completeFlag != 0, hashes: hashes, times: times)
    }

    /// nil when the bytes are not a current-version fingerprint; `decode`
    /// says why.
    public init?(decoding data: Data) {
        do { self = try Self.decode(data) } catch { return nil }
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    // MARK: Compute

    /// The fingerprint of `pcm`. Pure and deterministic: equal samples give
    /// equal landmarks on every run and every Mac. Invalid `parameters`, or
    /// PCM at a rate other than the recipe's, are programmer errors and
    /// trap with the reason (call `parameters.validate()` first to get it
    /// as a thrown value).
    public static func compute(_ pcm: AudioPCM,
                               parameters: AudioFingerprintParameters = .default) -> AudioFingerprint {
        do { try parameters.validate() } catch {
            preconditionFailure("AudioFingerprint.compute: invalid parameters — \(error)")
        }
        precondition(pcm.sampleRate == parameters.sampleRate,
                     "AudioFingerprint.compute: PCM is \(pcm.sampleRate) Hz, recipe expects \(parameters.sampleRate)")
        let gain = normalisingGain(pcm.samples, parameters: parameters)
        let peaks = SpectralPeakPicker(parameters: parameters)?.peaks(in: pcm.samples, gain: gain) ?? []
        let landmarks = LandmarkPairer.pair(peaks, parameters: parameters)
        return AudioFingerprint(recipeID: parameters.recipeID, sampleRate: pcm.sampleRate,
                                hopSamples: parameters.hopSamples, frameSize: parameters.frameSize,
                                durationSeconds: pcm.durationSeconds, complete: !pcm.reachedCap,
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
