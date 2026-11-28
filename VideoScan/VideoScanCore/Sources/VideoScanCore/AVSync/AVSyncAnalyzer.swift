// AVSyncAnalyzer.swift (VideoScanCore)
// ONE SENTENCE: given both files' signals and sound prints, measure the
// sound-vs-picture shift of the processed file against its original, window
// by window, and judge it — pure, no I/O.
//
// Design: docs/design/av_sync_analysis.md §2 and §5.
//   1. Coarse: AudioFingerprintMatcher (query = processed, master = original)
//      gives the whole-file sound offset (64 ms resolution) — or no shared
//      sound, which is "could not measure", never a guess.
//   2. Windows: 20 s every 10 s across the shared stretch.
//   3. Per window: FFT normalised cross-correlation of the onset envelopes
//      within ±250 ms of the coarse offset → Δa (computed over ±1 s, so a
//      beat that repeats every 500 ms reads as ambiguous rather than as a
//      lucky match); of the motion signals within
//      ±1 s of Δa → Δv; parabolic refinement (~1 ms on the 5 ms grid).
//      s = Δa − Δv: a trim that removes the same span from sound and picture
//      moves both lags equally and leaves s = 0.
//   4. Confidence: a window is measured only when both peaks are high enough
//      and unique enough; else it says why.
//   5. Across windows: outliers set aside; then, in order — every window in
//      band and drift < 20 ms → in sync; a step held ≥ 3 windows each side and
//      larger than 2× the jitter → jump; a steady change ≥ 20 ms (Theil–Sen
//      line) → drift; otherwise → offset (median).
//
// SIGN: lag = processed(t) ≈ original(t + lag). Sound delayed by d in the
// processed file: Δa = −d, Δv = 0, s = −d → "late". (§2: s > 0 early.)
//
// MEMORY: the filtered motion copies (2 × the motion signal: 2 h → 23 MB) and
// one correlator (≈ 130 KB). Time: O(windows × M log M), M = 8192 — an hour
// (360 windows) is a fraction of a second.

import Foundation

/// The coarse sound alignment of processed against original.
public enum AVSyncCoarseAlignment: Sendable, Equatable {
    case aligned(offsetSeconds: Double)
    case cannotMeasure(AVSyncCannotMeasure)
}

public enum AVSyncAnalyzer {

    /// Picture motion filtering (grid steps): a short smooth removes the
    /// frame-rate staircase, the high-pass removes slow trends. Both linear
    /// and symmetric, so neither moves anything in time.
    static let motionSmoothRadius = 2
    static let motionHighPassRadius = 40
    /// Sound onset smoothing (grid steps).
    static let soundSmoothRadius = 1

    // MARK: Entry point

    public static func analyze(original: AVSyncFileEvidence, processed: AVSyncFileEvidence,
                               policy: AVSyncPolicy = .default) -> AVSyncReport {
        let coarse = coarseAlignment(original: original, processed: processed, policy: policy)
        switch coarse {
        case let .cannotMeasure(why):
            return AVSyncReport(policyIdentity: policy.identity, verdict: .couldNotMeasure(why),
                                processedCuts: processed.signals.cuts.count, originalCuts: original.signals.cuts.count)
        case let .aligned(offset):
            return analyze(original: original.signals, processed: processed.signals,
                           coarseOffsetSeconds: offset, policy: policy)
        }
    }

    /// The coarse step alone (§5.1).
    public static func coarseAlignment(original: AVSyncFileEvidence, processed: AVSyncFileEvidence,
                                       policy: AVSyncPolicy = .default) -> AVSyncCoarseAlignment {
        if !hasSound(processed, policy: policy) { return .cannotMeasure(.noSound(processed: true)) }
        if !hasSound(original, policy: policy) { return .cannotMeasure(.noSound(processed: false)) }
        let match = AudioFingerprintMatcher.match(query: processed.fingerprint, master: original.fingerprint)
        switch match.verdict {
        case .different, .inconclusive(reason: .incompatibleRecipe):
            return .cannotMeasure(.noSharedSound)
        case .sameRecording, .containedInMaster, .masterContainedInQuery, .overlap, .inconclusive:
            // An incomplete side still has a real offset: the windows measure
            // only the shared stretch either way.
            return .aligned(offsetSeconds: match.offsetSeconds)
        }
    }

    /// Sound worth lining up: a print with landmarks, not measured silent,
    /// and onset energy above the floor somewhere.
    static func hasSound(_ evidence: AVSyncFileEvidence, policy: AVSyncPolicy) -> Bool {
        if evidence.fingerprint.landmarkCount == 0 { return false }
        if evidence.fingerprint.secondsAboveSilenceCeiling == 0 { return false }
        let onset = evidence.signals.onset
        guard !onset.isEmpty else { return false }
        let mean = onset.reduce(0.0) { $0 + Double($1) } / Double(onset.count)
        return mean >= policy.minSoundActivity
    }

    // MARK: Windows (§5.2–5.4)

    /// Measure and judge, given the coarse offset (seconds).
    public static func analyze(original: AVSyncSignals, processed: AVSyncSignals, coarseOffsetSeconds: Double,
                               policy: AVSyncPolicy = .default) -> AVSyncReport {
        let g = policy.gridSeconds
        let coarse = Int((coarseOffsetSeconds / g).rounded())
        let n = Int((policy.windowSeconds / g).rounded())
        let hop = max(1, Int((policy.hopSeconds / g).rounded()))
        // Shared stretch on the processed timeline, by sound (the coarse
        // offset is the sound's).
        let lo = max(0, -coarse)
        let hi = min(processed.onset.count, original.onset.count - coarse)
        var report = AVSyncReport(policyIdentity: policy.identity, verdict: .couldNotMeasure(.noSharedSound),
                                  coarseOffsetSeconds: coarseOffsetSeconds,
                                  overlapStartSeconds: Double(lo) * g, overlapEndSeconds: Double(max(lo, hi)) * g,
                                  processedCuts: processed.cuts.count, originalCuts: original.cuts.count)
        guard hi - lo >= n else {
            report.verdict = .couldNotMeasure(.tooShort(overlapSeconds: Double(max(0, hi - lo)) * g,
                                                        neededSeconds: policy.windowSeconds))
            return report
        }
        let prepared = Prepared(original: original, processed: processed)
        let soundLag = max(1, Int((policy.soundSearchMs / 1_000 / g).rounded()))
        let soundSpan = max(soundLag, Int((policy.soundAmbiguitySearchMs / 1_000 / g).rounded()))
        let pictureLag = max(1, Int((policy.pictureSearchMs / 1_000 / g).rounded()))
        let correlator = AVSyncCorrelator(maxReference: n, maxLag: max(soundSpan, pictureLag))
        var windows: [AVSyncWindow] = []
        var start = lo
        while start + n <= hi {
            windows.append(measure(at: start, length: n, coarse: coarse,
                                   lags: Lags(sound: soundLag, soundSpan: soundSpan, picture: pictureLag),
                                   prepared: prepared, correlator: correlator, policy: policy))
            start += hop
        }
        report.windows = windows
        judge(&report, policy: policy)
        return report
    }

    /// The filtered signals every window reads.
    struct Prepared {
        let processedSound: [Float], originalSound: [Float]
        let processedMotion: [Float], originalMotion: [Float]
        let processedActivity: [Double]   // prefix sums of the raw motion rate
        let processedSoundActivity: [Double]

        init(original: AVSyncSignals, processed: AVSyncSignals) {
            func motion(_ x: [Float]) -> [Float] {
                AVSyncSignalMath.highPass(AVSyncSignalMath.movingAverage(x, radius: AVSyncAnalyzer.motionSmoothRadius),
                                          radius: AVSyncAnalyzer.motionHighPassRadius)
            }
            processedSound = AVSyncSignalMath.movingAverage(processed.onset, radius: AVSyncAnalyzer.soundSmoothRadius)
            originalSound = AVSyncSignalMath.movingAverage(original.onset, radius: AVSyncAnalyzer.soundSmoothRadius)
            processedMotion = motion(processed.motion)
            originalMotion = motion(original.motion)
            processedActivity = Self.prefix(processed.motion)
            processedSoundActivity = Self.prefix(processed.onset)
        }

        static func prefix(_ x: [Float]) -> [Double] {
            var out = [Double](repeating: 0, count: x.count + 1)
            for i in 0..<x.count { out[i + 1] = out[i] + Double(x[i]) }
            return out
        }

        /// Mean of `x` over [start, start+length), reading 0 past the end.
        static func mean(_ prefix: [Double], start: Int, length: Int) -> Double {
            let a = max(0, min(start, prefix.count - 1)), b = max(0, min(start + length, prefix.count - 1))
            return length > 0 ? (prefix[b] - prefix[a]) / Double(length) : 0
        }
    }

    /// `x[from ..< from+count]`, zero where out of range.
    static func slice(_ x: [Float], from: Int, count: Int) -> [Float] {
        var out = [Float](repeating: 0, count: count)
        let a = max(0, from), b = min(x.count, from + count)
        if b > a { for i in a..<b { out[i - from] = x[i] } }
        return out
    }

    /// Search half-widths in grid steps: the sound peak must lie within
    /// ±`sound`; the sound correlation is computed over ±`soundSpan`.
    struct Lags {
        let sound: Int, soundSpan: Int, picture: Int
    }

    static func measure(at start: Int, length n: Int, coarse: Int, lags: Lags,
                        prepared p: Prepared, correlator: AVSyncCorrelator, policy: AVSyncPolicy) -> AVSyncWindow {
        let g = policy.gridSeconds
        var window = AVSyncWindow(startSeconds: Double(start) * g, durationSeconds: Double(n) * g)
        // Sound.
        if Prepared.mean(p.processedSoundActivity, start: start, length: n) < policy.minSoundActivity {
            window.notMeasured = .noSound
            return window
        }
        let span = lags.soundSpan
        let ca = correlator.normalisedCrossCorrelation(
            reference: slice(p.processedSound, from: start, count: n),
            search: slice(p.originalSound, from: start + coarse - span, count: n + 2 * span), maxLag: span)
        guard let pa = AVSyncCorrelation.peak(of: ca) else { window.notMeasured = .soundUnmatched; return window }
        window.soundPeak = pa.height
        window.soundSecondPeakRatio = pa.secondPeakRatio
        if let why = refusal(pa, unmatched: .soundUnmatched, repeats: .soundRepeats, policy: policy) {
            window.notMeasured = why
            return window
        }
        if abs(pa.lagSteps) > Double(lags.sound) {
            window.notMeasured = .beyondSearch
            return window
        }
        let soundSteps = Double(coarse) + pa.lagSteps
        window.soundLagMs = soundSteps * g * 1_000
        // Picture, searched around the sound's lag.
        if Prepared.mean(p.processedActivity, start: start, length: n) < policy.minPictureActivity {
            window.notMeasured = .noMovement
            return window
        }
        let centre = Int(soundSteps.rounded())
        let pictureLag = lags.picture
        let cv = correlator.normalisedCrossCorrelation(
            reference: slice(p.processedMotion, from: start, count: n),
            search: slice(p.originalMotion, from: start + centre - pictureLag, count: n + 2 * pictureLag),
            maxLag: pictureLag)
        guard let pv = AVSyncCorrelation.peak(of: cv) else { window.notMeasured = .pictureUnmatched; return window }
        window.picturePeak = pv.height
        window.pictureSecondPeakRatio = pv.secondPeakRatio
        if let why = refusal(pv, unmatched: .pictureUnmatched, repeats: .movementRepeats, policy: policy) {
            window.notMeasured = why
            return window
        }
        window.pictureLagMs = (Double(centre) + pv.lagSteps) * g * 1_000
        return window
    }

    static func refusal(_ peak: AVSyncPeak, unmatched: AVSyncNotMeasured, repeats: AVSyncNotMeasured,
                        policy: AVSyncPolicy) -> AVSyncNotMeasured? {
        if peak.height < policy.minPeak { return unmatched }
        if peak.atEdge { return .beyondSearch }
        if peak.secondPeakRatio > policy.maxSecondPeakRatio { return repeats }
        return nil
    }

    // MARK: Across windows (§5.5, §4)

    static func judge(_ report: inout AVSyncReport, policy: AVSyncPolicy) {
        let total = report.windows.count
        var measured = report.windows.indices.filter { report.windows[$0].isMeasured }
        guard enough(measured.count, of: total, policy: policy) else {
            report.verdict = .couldNotMeasure(.tooFewWindows(measured: measured.count, total: total,
                                                             reasons: reasonCounts(report.windows)))
            return
        }
        markOutliers(&report.windows, indices: measured, policy: policy)
        measured = measured.filter { report.windows[$0].isMeasured }
        guard enough(measured.count, of: total, policy: policy) else {
            report.verdict = .couldNotMeasure(.tooFewWindows(measured: measured.count, total: total,
                                                             reasons: reasonCounts(report.windows)))
            return
        }
        let times = measured.map { report.windows[$0].centreSeconds }
        let values = measured.map { report.windows[$0].shiftMs ?? 0 }
        let line = AVSyncStats.theilSen(times: times, values: values)
        let step = jump(in: report.windows, indices: measured, policy: policy, line: line)
        let from = line.intercept + line.slope * report.overlapStartSeconds
        let to = line.intercept + line.slope * report.overlapEndSeconds
        let span = report.overlapEndSeconds - report.overlapStartSeconds
        report.medianShiftMs = AVSyncStats.median(values)
        report.driftMsPerMinute = line.slope * 60
        report.worstAbsShiftMs = values.map(abs).max()
        let allInBand = values.allSatisfy { policy.isInSync(shiftMs: $0) }
        if allInBand && abs(to - from) < policy.maxDriftMs {
            report.verdict = .inSync(withinMs: report.worstAbsShiftMs ?? 0, measured: measured.count, total: total,
                                     notMeasured: reasonCounts(report.windows))
        } else if let step {
            report.verdict = .jump(stepMs: step.stepMs, atSeconds: step.atSeconds)
        } else if abs(to - from) >= policy.maxDriftMs {
            report.verdict = .drift(fromMs: from, toMs: to, overSeconds: span)
        } else {
            report.verdict = .offset(shiftMs: report.medianShiftMs ?? 0)
        }
    }

    /// Set aside windows far from their level — the median, or the two
    /// medians of a step when the series has one (so a jump's second half is
    /// never thrown away as "outliers") — by `outlierSigmas` robust sigmas
    /// AND by `outlierFloorMs`.
    static func markOutliers(_ windows: inout [AVSyncWindow], indices: [Int], policy: AVSyncPolicy) {
        let values = indices.map { windows[$0].shiftMs ?? 0 }
        var levels = [Double](repeating: AVSyncStats.median(values), count: values.count)
        if let step = jump(in: windows, indices: indices, policy: policy) {
            let split = indices.firstIndex { windows[$0].centreSeconds > step.atSeconds } ?? values.count
            let left = AVSyncStats.median(Array(values[..<split])), right = AVSyncStats.median(Array(values[split...]))
            for i in values.indices { levels[i] = i < split ? left : right }
        }
        let residuals = zip(values, levels).map { $0 - $1 }
        let limit = max(policy.outlierSigmas * AVSyncStats.robustSigma(residuals), policy.outlierFloorMs)
        for (i, index) in indices.enumerated() where abs(residuals[i]) > limit {
            windows[index].notMeasured = .outlier
        }
    }

    static func enough(_ measured: Int, of total: Int, policy: AVSyncPolicy) -> Bool {
        measured >= policy.minMeasuredWindows && Double(measured) >= policy.minMeasuredFraction * Double(total)
    }

    /// Unmeasured windows by reason, largest first (ties in declaration order).
    static func reasonCounts(_ windows: [AVSyncWindow]) -> [AVSyncReasonCount] {
        AVSyncNotMeasured.allCases.compactMap { reason in
            let count = windows.filter { $0.notMeasured == reason }.count
            return count > 0 ? AVSyncReasonCount(reason: reason, count: count) : nil
        }.enumerated().sorted { a, b in
            a.element.count != b.element.count ? a.element.count > b.element.count : a.offset < b.offset
        }.map(\.element)
    }

    /// The step in the measured series, if there is one: the split that
    /// maximises the change-point statistic |mean(right) − mean(left)| ·
    /// √(k(n−k)/n) (binary segmentation; O(n) by prefix sums), kept only when
    /// (a) each side holds `jumpHoldWindows`, (b) the step between the two
    /// sides' MEDIANS exceeds `jumpJitterFactor` × the jitter around them and
    /// `minJumpMs`, and (c) two levels explain the series better than a
    /// straight line (a drift is not a jump).
    static func jump(in windows: [AVSyncWindow], indices: [Int], policy: AVSyncPolicy,
                     line known: (slope: Double, intercept: Double)? = nil) -> (stepMs: Double, atSeconds: Double)? {
        let hold = max(1, policy.jumpHoldWindows)
        let n = indices.count
        guard n >= 2 * hold else { return nil }
        let times = indices.map { windows[$0].centreSeconds }
        let values = indices.map { windows[$0].shiftMs ?? 0 }
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + values[i] }
        var bestK = hold, bestScore = -1.0
        for k in hold...(n - hold) {
            let left = prefix[k] / Double(k), right = (prefix[n] - prefix[k]) / Double(n - k)
            let score = abs(right - left) * (Double(k * (n - k)) / Double(n)).squareRoot()
            if score > bestScore { bestScore = score; bestK = k }
        }
        let left = Array(values[..<bestK]), right = Array(values[bestK...])
        let ml = AVSyncStats.median(left), mr = AVSyncStats.median(right)
        let residuals = left.map { $0 - ml } + right.map { $0 - mr }
        let step = mr - ml
        guard abs(step) >= policy.minJumpMs,
              abs(step) > policy.jumpJitterFactor * max(AVSyncStats.robustSigma(residuals), 1) else { return nil }
        let stepError = residuals.map(abs).reduce(0, +) / Double(n)
        let line = known ?? AVSyncStats.theilSen(times: times, values: values)
        let lineError = zip(times, values).map { abs($1 - (line.intercept + line.slope * $0)) }
            .reduce(0, +) / Double(n)
        guard stepError < 0.5 * lineError else { return nil }
        return (step, (times[bestK - 1] + times[bestK]) / 2)
    }
}

/// Small robust statistics.
enum AVSyncStats {
    static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return 0 }
        let s = x.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    /// 1.4826 × the median absolute deviation (≈ σ for normal data).
    static func robustSigma(_ x: [Double]) -> Double {
        guard x.count > 1 else { return 0 }
        let m = median(x)
        return 1.4826 * median(x.map { abs($0 - m) })
    }

    /// Theil–Sen line: slope = median of pairwise slopes, intercept = median
    /// of value − slope·time. O(n²) pairs: 720 windows (2 h) → 260 k.
    static func theilSen(times: [Double], values: [Double]) -> (slope: Double, intercept: Double) {
        guard times.count >= 2 else { return (0, median(values)) }
        var slopes: [Double] = []
        slopes.reserveCapacity(times.count * (times.count - 1) / 2)
        for i in 0..<times.count {
            for j in (i + 1)..<times.count where times[j] != times[i] {
                slopes.append((values[j] - values[i]) / (times[j] - times[i]))
            }
        }
        let slope = median(slopes)
        return (slope, median(zip(times, values).map { $1 - slope * $0 }))
    }
}
