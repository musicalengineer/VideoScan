// AVSyncCorrelation.swift (VideoScanCore)
// ONE SENTENCE: normalised cross-correlation of a short reference against a
// slightly longer search segment by vDSP FFT, and the peak read off it with
// parabolic refinement and an ambiguity measure.
//
// c(τ) = Σₙ r[n]·o[n+L+τ] / (‖r‖·‖o over the same n‖), τ = −L…L, both sides
// zero-mean. Computed as IFFT(conj(R)·O) with real FFTs of size M ≥ N + 2L
// (no circular wrap can reach the lags read). A direct vDSP_conv version is
// kept as the tests' oracle.
//
// MEMORY: per correlator, four Float buffers of M (a 20 s window on the 5 ms
// grid with ±1 s search: M = 8192 → 128 KB) plus the FFT setup. One
// correlator per analysis, used serially.
//
// (For Rick: `final class` + deinit ≈ a C++ RAII class owning the vDSP
// FFTSetup; @unchecked Sendable is NOT claimed — it never leaves its task.)

import Accelerate
import Foundation

/// The best alignment found in one correlation.
public struct AVSyncPeak: Sendable, Equatable {
    /// Refined lag in grid steps, −L…L.
    public let lagSteps: Double
    /// Normalised correlation at the integer peak (≤ 1).
    public let height: Double
    /// Best peak outside the main lobe ÷ `height` (0 = unique, 1 = tie).
    public let secondPeakRatio: Double
    /// The maximum sat on the edge of the search: the true peak may lie
    /// outside it, so this is not a measurement.
    public let atEdge: Bool
}

final class AVSyncCorrelator {
    private let log2n: vDSP_Length
    private let size: Int
    private let setup: FFTSetup
    private var aReal: [Float], aImag: [Float], bReal: [Float], bImag: [Float]
    private var padded: [Float]

    /// A correlator for references up to `maxReference` samples and lags up
    /// to ±`maxLag`.
    init(maxReference: Int, maxLag: Int) {
        var n: vDSP_Length = 1
        while (1 << n) < maxReference + 2 * maxLag + 1 { n += 1 }
        log2n = n
        size = 1 << Int(n)
        guard let made = vDSP_create_fftsetup(n, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("AVSyncCorrelator: vDSP_create_fftsetup(\(n)) failed")
        }
        setup = made
        aReal = [Float](repeating: 0, count: size / 2)
        aImag = aReal; bReal = aReal; bImag = aReal
        padded = [Float](repeating: 0, count: size)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// c(τ) for τ = −L…L (2L+1 values). `search.count` must be
    /// `reference.count + 2L`. Zero energy on either side reads 0.
    func normalisedCrossCorrelation(reference r: [Float], search o: [Float], maxLag lag: Int) -> [Float] {
        let n = r.count
        precondition(o.count == n + 2 * lag, "search must be reference + 2·lag long")
        precondition(n + 2 * lag + 1 <= size, "correlator too small")
        let rz = AVSyncCorrelation.zeroMean(r), oz = AVSyncCorrelation.zeroMean(o)
        forward(rz, real: &aReal, imag: &aImag)
        forward(oz, real: &bReal, imag: &bImag)
        // conj(A)·B in vDSP's packed real format: element 0 holds DC (real)
        // and Nyquist (imag) as two separate reals.
        let dc = aReal[0] * bReal[0], nyquist = aImag[0] * bImag[0]
        for k in 1..<(size / 2) {
            let ar = aReal[k], ai = aImag[k], br = bReal[k], bi = bImag[k]
            aReal[k] = ar * br + ai * bi
            aImag[k] = ar * bi - ai * br
        }
        aReal[0] = dc
        aImag[0] = nyquist
        let cross = inverse()
        // vDSP: forward = 2·DFT, inverse = M·IDFT ⇒ product of two forwards
        // through the inverse = 4M · correlation.
        let scale = 1 / Float(4 * size)
        let refEnergy = AVSyncCorrelation.energy(rz[...])
        var prefix = [Double](repeating: 0, count: oz.count + 1)
        for i in 0..<oz.count { prefix[i + 1] = prefix[i] + Double(oz[i]) * Double(oz[i]) }
        var out = [Float](repeating: 0, count: 2 * lag + 1)
        for j in 0...(2 * lag) {
            let segEnergy = prefix[j + n] - prefix[j]
            let denom = (refEnergy * segEnergy).squareRoot()
            out[j] = denom > 1e-12 ? Float(Double(cross[j] * scale) / denom) : 0
        }
        return out
    }

    // The buffers are never empty (size ≥ 2), so every baseAddress exists;
    // the guards make that a no-op instead of a force unwrap.
    private func forward(_ x: [Float], real: inout [Float], imag: inout [Float]) {
        let used = min(x.count, size), half = size / 2
        padded.withUnsafeMutableBufferPointer { dst in
            x.withUnsafeBufferPointer { src in
                guard let d = dst.baseAddress else { return }
                if used > 0, let s = src.baseAddress { d.update(from: s, count: used) }
                if used < size { (d + used).update(repeating: 0, count: size - used) }
            }
        }
        real.withUnsafeMutableBufferPointer { re in
            imag.withUnsafeMutableBufferPointer { im in
                guard let r = re.baseAddress, let i = im.baseAddress else { return }
                var split = DSPSplitComplex(realp: r, imagp: i)
                padded.withUnsafeBufferPointer { p in
                    p.baseAddress?.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
    }

    private func inverse() -> [Float] {
        var out = [Float](repeating: 0, count: size)
        let half = size / 2
        aReal.withUnsafeMutableBufferPointer { re in
            aImag.withUnsafeMutableBufferPointer { im in
                guard let r = re.baseAddress, let i = im.baseAddress else { return }
                var split = DSPSplitComplex(realp: r, imagp: i)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Inverse))
                out.withUnsafeMutableBufferPointer { o in
                    o.baseAddress?.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                    }
                }
            }
        }
        return out
    }
}

public enum AVSyncCorrelation {

    static func zeroMean(_ x: [Float]) -> [Float] {
        guard !x.isEmpty else { return x }
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var negated = -mean
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsadd(x, 1, &negated, &out, 1, vDSP_Length(x.count))
        return out
    }

    static func energy(_ x: ArraySlice<Float>) -> Double {
        x.reduce(0.0) { $0 + Double($1) * Double($1) }
    }

    /// The same c(τ) computed directly (vDSP_conv) — the FFT's test oracle.
    static func directNormalisedCrossCorrelation(reference r: [Float], search o: [Float], maxLag lag: Int) -> [Float] {
        let n = r.count
        let rz = zeroMean(r), oz = zeroMean(o)
        var raw = [Float](repeating: 0, count: 2 * lag + 1)
        vDSP_conv(oz, 1, rz, 1, &raw, 1, vDSP_Length(2 * lag + 1), vDSP_Length(n))
        let refEnergy = energy(rz[...])
        return (0...(2 * lag)).map { j in
            let denom = (refEnergy * energy(oz[j..<(j + n)])).squareRoot()
            return denom > 1e-12 ? Float(Double(raw[j]) / denom) : 0
        }
    }

    /// The peak of a correlation over lags −L…L (`c.count` = 2L+1): its
    /// parabolic-refined lag, its height, the second-peak ratio (best value
    /// outside the main lobe — the run of values falling away from the peak on
    /// each side, at least ±2 steps), and whether it sits on the edge.
    public static func peak(of c: [Float]) -> AVSyncPeak? {
        guard c.count >= 3 else { return nil }
        let lag = (c.count - 1) / 2
        var best = 0
        for i in 1..<c.count where c[i] > c[best] { best = i }
        let height = Double(c[best])
        var lo = best, hi = best
        while lo > 0, c[lo - 1] < c[lo] { lo -= 1 }
        while hi < c.count - 1, c[hi + 1] < c[hi] { hi += 1 }
        lo = min(lo, best - 2); hi = max(hi, best + 2)
        var second: Float = 0
        for i in 0..<c.count where i < lo || i > hi { second = max(second, c[i]) }
        let atEdge = best == 0 || best == c.count - 1
        var delta = 0.0
        if !atEdge {
            let y0 = Double(c[best - 1]), y1 = height, y2 = Double(c[best + 1])
            let curvature = y0 - 2 * y1 + y2
            if curvature < 0 { delta = max(-0.5, min(0.5, 0.5 * (y0 - y2) / curvature)) }
        }
        return AVSyncPeak(lagSteps: Double(best - lag) + delta, height: height,
                          secondPeakRatio: height > 0 ? Double(second) / height : 1, atEdge: atEdge)
    }
}
