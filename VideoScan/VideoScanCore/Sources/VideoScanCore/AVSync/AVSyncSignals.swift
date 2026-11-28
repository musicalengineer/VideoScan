// AVSyncSignals.swift (VideoScanCore)
// ONE SENTENCE: the two tiny time series the sync check correlates — a sound
// onset envelope and a picture motion signal, both on one 5 ms grid from the
// file's time zero — and the pure functions that make them.
//
// Design: docs/design/av_sync_analysis.md §3. Pure: no I/O here (the ffmpeg
// side is AVSyncSignalReader).
//
// SOUND — onset envelope: mono PCM → 5 ms frames → log10 power (floored at
// −60 dB, so silence is flat, not noise) → first difference, half-wave
// rectified. Correlating envelopes, not samples, survives re-encoding, sample-
// rate and gain changes and stereo folds.
//
// PICTURE — motion: each frame is a 32×18 grey thumbnail (ffmpeg scales it
// inside the decoder); a frame's change is the mean absolute difference from
// the frame before. On the grid it becomes a RATE (grey levels per second)
// held over the interval between the two frames' PTS, integrated exactly per
// grid cell. That is the picture as a linearly interpolated, continuous
// signal: a file whose frames were interpolated 30 → 60 fps (Topaz, the
// minterpolate filter) gives the same signal as its original, and VFR is
// handled by construction. A CUT is different: it is an instant, not a rate —
// the picture changes when the new frame is shown — so a cut frame's change is
// placed as an impulse at its PTS (otherwise an interpolated file, whose cut
// falls in a 16.7 ms interval instead of 33 ms, would read 8 ms late; measured
// 7.6 ms before this rule). A cut is a frame whose change exceeds `cutFloor`
// grey levels AND `cutFactor` × the median change of the frames within
// ±0.5 s — a spike against its own neighbourhood, so the same cut is a cut in
// both files whatever their frame rates. Known limit, by geometry: a file
// whose frames were DUPLICATED to a higher rate moves each ordinary change's
// centre by up to half an original frame interval (8 ms at 30 fps) — far
// below every threshold (§4).
//
// MEMORY (worst case, 2-hour file): onset 1.44 M Float (5.8 MB), motion the
// same, frame times/changes 432 k × 12 B at 60 fps (5.2 MB). About 17 MB.
//
// (For Rick: `[Float]` is a std::vector<float> with value semantics — copy on
// write, so passing one around never copies until someone mutates it.)

import Accelerate
import Foundation

/// The two signals of one file, on one grid from the file's time zero.
public struct AVSyncSignals: Sendable, Equatable {
    /// Seconds per grid step (AVSyncPolicy.gridSeconds, 5 ms).
    public let gridSeconds: Double
    /// Sound onset strength per grid step (≥ 0).
    public let onset: [Float]
    /// Picture motion rate per grid step (grey levels per second, ≥ 0).
    public let motion: [Float]
    /// Times (seconds) of picture cuts — single frames that change far more
    /// than their neighbours. Reported, and a reason to trust a window.
    public let cuts: [Double]
    /// Frames the picture decode delivered.
    public let frameCount: Int

    public init(gridSeconds: Double, onset: [Float], motion: [Float], cuts: [Double] = [], frameCount: Int = 0) {
        self.gridSeconds = gridSeconds
        self.onset = onset
        self.motion = motion
        self.cuts = cuts
        self.frameCount = frameCount
    }

    public var soundSeconds: Double { Double(onset.count) * gridSeconds }
    public var pictureSeconds: Double { Double(motion.count) * gridSeconds }
}

/// Everything the analyzer needs from one file: its signals and its sound
/// print (for the coarse alignment, AudioFingerprintMatcher).
public struct AVSyncFileEvidence: Sendable {
    public let signals: AVSyncSignals
    public let fingerprint: AudioFingerprint
    public init(signals: AVSyncSignals, fingerprint: AudioFingerprint) {
        self.signals = signals
        self.fingerprint = fingerprint
    }
}

public enum AVSyncSignalMath {

    /// Power floor of the onset envelope: −60 dB (log10 = −6).
    static let powerFloorLog10: Float = -6

    // MARK: Sound

    /// The onset envelope of mono 16-bit PCM on a `gridSeconds` grid.
    /// Frame k covers samples [k·n, (k+1)·n), n = sampleRate·grid; value k is
    /// max(0, log10 P(k) − log10 P(k−1)) with P floored at −60 dB; value 0 is 0.
    public static func onsetEnvelope(samples: [Int16], sampleRate: Int, gridSeconds: Double) -> [Float] {
        let n = max(1, Int((Double(sampleRate) * gridSeconds).rounded()))
        let frames = samples.count / n
        guard frames > 0 else { return [] }
        var out = [Float](repeating: 0, count: frames)
        var scratch = [Float](repeating: 0, count: n)
        var previous: Float = powerFloorLog10
        let scale: Float = 1.0 / 32_768.0
        samples.withUnsafeBufferPointer { pcm in
            guard let base = pcm.baseAddress else { return }
            for k in 0..<frames {
                // Int16 → Float, scaled to ±1, then mean of squares.
                vDSP_vflt16(base + k * n, 1, &scratch, 1, vDSP_Length(n))
                var meanSquare: Float = 0
                vDSP_measqv(scratch, 1, &meanSquare, vDSP_Length(n))
                let level = max(log10f(max(meanSquare * scale * scale, 1e-12)), powerFloorLog10)
                out[k] = k == 0 ? 0 : max(0, level - previous)
                previous = level
            }
        }
        return out
    }

    // MARK: Picture

    /// Mean absolute difference of two equal-length grey frames (0…255).
    public static func meanAbsoluteDifference(_ a: UnsafeBufferPointer<UInt8>, _ b: UnsafeBufferPointer<UInt8>) -> Float {
        let count = min(a.count, b.count)
        guard count > 0 else { return 0 }
        var total = 0
        for i in 0..<count { total += abs(Int(a[i]) - Int(b[i])) }
        return Float(total) / Float(count)
    }

    /// A gap between two frames longer than this carries no motion (a hole in
    /// the stream, not a slow change).
    static let maxFrameGapSeconds = 0.5

    /// Motion rate on the grid: frame i's change (from frame i−1) spread as a
    /// rate over [t(i−1), t(i)], integrated exactly per cell — or, when
    /// `cutFlags[i]`, placed as an impulse at t(i) (split between the two
    /// nearest cell centres). `changes[0]` is ignored. Times must be
    /// non-decreasing; out-of-order or too-long gaps are skipped. `count` =
    /// grid length (default: up to the last frame).
    public static func motionGrid(frameTimes: [Double], changes: [Float], gridSeconds: Double,
                                  count: Int? = nil, cutFlags: [Bool]? = nil) -> [Float] {
        let frames = min(frameTimes.count, changes.count)
        let lastTime = frames > 0 ? max(0, frameTimes[frames - 1]) : 0
        let length = count ?? Int((lastTime / gridSeconds).rounded(.up))
        var out = [Float](repeating: 0, count: max(0, length))
        guard frames > 1, length > 0 else { return out }
        for i in 1..<frames {
            let t0 = max(0, frameTimes[i - 1]), t1 = frameTimes[i]
            let dt = t1 - t0
            guard dt > 0, dt <= maxFrameGapSeconds else { continue }
            if let cutFlags, i < cutFlags.count, cutFlags[i] {
                let u = t1 / gridSeconds - 0.5
                let k = Int(u.rounded(.down)), frac = u - Double(k)
                let amount = Double(changes[i]) / gridSeconds
                if k >= 0, k < length { out[k] += Float(amount * (1 - frac)) }
                if k + 1 >= 0, k + 1 < length { out[k + 1] += Float(amount * frac) }
                continue
            }
            let rate = Double(changes[i]) / dt
            var cell = Int(t0 / gridSeconds)
            while cell < length {
                let lo = max(t0, Double(cell) * gridSeconds)
                let hi = min(t1, Double(cell + 1) * gridSeconds)
                if hi <= lo { break }
                out[cell] += Float(rate * (hi - lo) / gridSeconds)
                cell += 1
            }
        }
        return out
    }

    public static let cutFloor: Float = 20
    public static let cutFactor: Float = 4
    static let cutNeighbourhoodSeconds = 0.5

    /// Per frame: is it a cut — change > `cutFloor` AND > `cutFactor` × the
    /// median change of the other frames within ±0.5 s? Frame 0 never is.
    /// O(frames × neighbourhood): 2 h at 60 fps ≈ 26 M compares.
    public static func cutFlags(frameTimes: [Double], changes: [Float]) -> [Bool] {
        let frames = min(frameTimes.count, changes.count)
        var flags = [Bool](repeating: false, count: frames)
        guard frames > 2 else { return flags }
        var lo = 1, hi = 1
        var neighbours: [Float] = []
        for i in 1..<frames where changes[i] > cutFloor {
            while lo < i, frameTimes[lo] < frameTimes[i] - cutNeighbourhoodSeconds { lo += 1 }
            hi = max(hi, i)
            while hi + 1 < frames, frameTimes[hi + 1] <= frameTimes[i] + cutNeighbourhoodSeconds { hi += 1 }
            neighbours.removeAll(keepingCapacity: true)
            for j in lo...hi where j != i { neighbours.append(changes[j]) }
            guard !neighbours.isEmpty else { continue }
            neighbours.sort()
            flags[i] = changes[i] > cutFactor * neighbours[neighbours.count / 2]
        }
        return flags
    }

    /// The times of the cut frames.
    public static func cuts(frameTimes: [Double], changes: [Float]) -> [Double] {
        zip(cutFlags(frameTimes: frameTimes, changes: changes), frameTimes).compactMap { $0 ? $1 : nil }
    }

    // MARK: Filters (linear, symmetric: they move no feature in time)

    /// `x` minus its centred moving average over ±`radius` samples — keeps
    /// changes, removes slow trends.
    public static func highPass(_ x: [Float], radius: Int) -> [Float] {
        guard radius > 0, !x.isEmpty else { return x }
        let smooth = movingAverage(x, radius: radius)
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsub(smooth, 1, x, 1, &out, 1, vDSP_Length(x.count))
        return out
    }

    /// Centred moving average over ±`radius` samples (edges average what exists).
    public static func movingAverage(_ x: [Float], radius: Int) -> [Float] {
        guard radius > 0, !x.isEmpty else { return x }
        var prefix = [Double](repeating: 0, count: x.count + 1)
        for i in 0..<x.count { prefix[i + 1] = prefix[i] + Double(x[i]) }
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            let lo = max(0, i - radius), hi = min(x.count, i + radius + 1)
            out[i] = Float((prefix[hi] - prefix[lo]) / Double(hi - lo))
        }
        return out
    }
}
