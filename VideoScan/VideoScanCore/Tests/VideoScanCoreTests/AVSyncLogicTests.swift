// AVSyncLogicTests.swift — the A/V sync check's pure parts, no media:
// signals (onset envelope, motion grid, cuts, filters), the FFT correlation
// against its direct oracle, the analyzer on hand-built signals, the policy's
// versioning, and the report's exact words (design §1).

import Accelerate
import Foundation
import Testing
@testable import VideoScanCore

// MARK: - Signals

struct AVSyncSignalsTests {

    @Test("onset envelope: silence is flat zero; a burst makes one onset at its start frame")
    func onsetEnvelope() {
        let rate = 8_000
        var samples = [Int16](repeating: 0, count: rate)   // 1 s
        for i in 4_000..<4_400 { samples[i] = Int16(10_000 * sin(Double(i) * 0.3)) }   // burst at 0.5 s
        let env = AVSyncSignalMath.onsetEnvelope(samples: samples, sampleRate: rate, gridSeconds: 0.005)
        #expect(env.count == 200)
        let peak = env.indices.max { env[$0] < env[$1] } ?? -1
        #expect(peak == 100, "the burst starts at frame 100 (0.5 s / 5 ms)")
        #expect(env[0..<100].allSatisfy { $0 == 0 }, "silence (floored at −60 dB) gives no onsets")
        #expect(env.allSatisfy { $0 >= 0 }, "half-wave rectified")
    }

    @Test("onset envelope survives a gain change (log power differences)")
    func onsetGainInvariant() {
        var rng = SplitMix64(seed: 7)
        let loud = (0..<16_000).map { _ in Int16(Double(rng.noise()) * 4_000 * (rng.unit() < 0.01 ? 4 : 1)) }
        let quiet = loud.map { Int16(Double($0) / 4) }
        let a = AVSyncSignalMath.onsetEnvelope(samples: loud, sampleRate: 8_000, gridSeconds: 0.005)
        let b = AVSyncSignalMath.onsetEnvelope(samples: quiet, sampleRate: 8_000, gridSeconds: 0.005)
        let diff = zip(a, b).map { abs($0 - $1) }.max() ?? 1
        #expect(diff < 0.05, "a −12 dB copy has (almost) the same onsets: max diff \(diff)")
    }

    @Test("motion grid: a change becomes a rate over its frame interval, integrated exactly")
    func motionGridBox() {
        // Frames at 0, 0.1, 0.2 s; frame 1 changed by 10 grey levels.
        let grid = AVSyncSignalMath.motionGrid(frameTimes: [0, 0.1, 0.2], changes: [0, 10, 0], gridSeconds: 0.05,
                                               count: 4)
        #expect(grid.count == 4)
        #expect(abs(grid[0] - 100) < 1e-3 && abs(grid[1] - 100) < 1e-3, "10 levels over 0.1 s = 100 levels/s")
        #expect(grid[2] == 0 && grid[3] == 0)
        let total = grid.reduce(0) { $0 + Double($1) * 0.05 }
        #expect(abs(total - 10) < 1e-3, "area = the change")
    }

    @Test("motion grid: a VFR stream (uneven frame times) integrates to the same total")
    func motionGridVFR() {
        let times = [0.0, 0.033, 0.05, 0.1, 0.18, 0.2]
        let changes: [Float] = [0, 3, 1, 4, 6, 2]
        let grid = AVSyncSignalMath.motionGrid(frameTimes: times, changes: changes, gridSeconds: 0.005)
        let total = grid.reduce(0) { $0 + Double($1) * 0.005 }
        #expect(abs(total - 16) < 1e-3)
    }

    @Test("motion grid: a gap over 0.5 s carries no motion; out-of-order times are skipped")
    func motionGridGaps() {
        let grid = AVSyncSignalMath.motionGrid(frameTimes: [0, 1.0, 0.9], changes: [0, 50, 50], gridSeconds: 0.1,
                                               count: 12)
        #expect(grid.allSatisfy { $0 == 0 })
    }

    @Test("motion grid: a cut is an impulse at its frame's PTS, split between the nearest cell centres")
    func motionGridCutImpulse() {
        let grid = AVSyncSignalMath.motionGrid(frameTimes: [0, 0.1, 0.2], changes: [0, 0, 40], gridSeconds: 0.05,
                                               count: 6, cutFlags: [false, false, true])
        // t = 0.2 s sits on the boundary of cells 3 and 4 (centres 0.175, 0.225): half each.
        #expect(abs(grid[3] - 400) < 1e-3 && abs(grid[4] - 400) < 1e-3, "\(grid)")
        #expect(grid[2] == 0, "nothing spread back over the interval")
    }

    @Test("cuts: a spike against its ±0.5 s neighbourhood is a cut; steady fast motion is not")
    func cuts() {
        let times = (0..<90).map { Double($0) / 30 }
        var changes = [Float](repeating: 3, count: 90)
        changes[45] = 60                          // a cut
        let flags = AVSyncSignalMath.cutFlags(frameTimes: times, changes: changes)
        #expect(flags.indices.filter { flags[$0] } == [45])
        let fast = [Float](repeating: 35, count: 90)   // large but steady
        #expect(!AVSyncSignalMath.cutFlags(frameTimes: times, changes: fast).contains(true))
        #expect(AVSyncSignalMath.cuts(frameTimes: times, changes: changes) == [1.5])
    }

    @Test("filters are symmetric: a pulse's centre does not move")
    func filtersKeepTiming() {
        var x = [Float](repeating: 0, count: 400)
        for i in 195...205 { x[i] = 1 }
        let hp = AVSyncSignalMath.highPass(AVSyncSignalMath.movingAverage(x, radius: 2), radius: 40)
        // Centroid of the positive lobe (a flat top has tied maxima).
        let mass = hp.reduce(0.0) { $0 + Double(max(0, $1)) }
        let centroid = hp.indices.reduce(0.0) { $0 + Double($1) * Double(max(0, hp[$1])) } / mass
        #expect(abs(centroid - 200) < 0.01, "centroid \(centroid)")
    }

    @Test("mean absolute difference of two frames")
    func meanAbsDiff() {
        let a: [UInt8] = [0, 10, 20, 30], b: [UInt8] = [10, 10, 0, 34]
        let d = a.withUnsafeBufferPointer { pa in b.withUnsafeBufferPointer { pb in
            AVSyncSignalMath.meanAbsoluteDifference(pa, pb) } }
        #expect(d == 8.5)
    }
}

// MARK: - Correlation

struct AVSyncCorrelationTests {

    static func noise(_ count: Int, seed: UInt64) -> [Float] {
        var rng = SplitMix64(seed: seed)
        return (0..<count).map { _ in rng.noise() }
    }

    @Test("the FFT correlation equals the direct (vDSP_conv) oracle")
    func fftMatchesDirect() {
        let search = Self.noise(4_400, seed: 1)
        let reference = Array(search[230..<4_230]).map { $0 + 0.3 * Float.random(in: -1...1) }
        let correlator = AVSyncCorrelator(maxReference: 4_000, maxLag: 200)
        let fft = correlator.normalisedCrossCorrelation(reference: reference, search: search, maxLag: 200)
        let direct = AVSyncCorrelation.directNormalisedCrossCorrelation(reference: reference, search: search, maxLag: 200)
        #expect(fft.count == 401 && direct.count == 401)
        let worst = zip(fft, direct).map { abs($0 - $1) }.max() ?? 1
        #expect(worst < 1e-3, "max difference \(worst)")
        let peak = AVSyncCorrelation.peak(of: fft)
        #expect(peak.map { abs($0.lagSteps - 30) < 0.5 } == true, "reference starts 30 steps right of centre")
        #expect((peak?.height ?? 0) > 0.9)
    }

    @Test("parabolic refinement recovers a fractional shift of a smooth pulse within 0.1 step")
    func parabolicRefinement() {
        func pulse(_ centre: Double, count: Int) -> [Float] {
            (0..<count).map { Float(exp(-pow((Double($0) - centre) / 3, 2))) }
        }
        let correlator = AVSyncCorrelator(maxReference: 200, maxLag: 20)
        for shift in [-7.3, -0.5, 0.25, 4.6] {
            let reference = pulse(100, count: 200)
            let search = pulse(120 + shift, count: 240)   // search[n + L + τ] = reference[n] at τ = shift
            let c = correlator.normalisedCrossCorrelation(reference: reference, search: search, maxLag: 20)
            let lag = AVSyncCorrelation.peak(of: c)?.lagSteps ?? .nan
            #expect(abs(lag - shift) < 0.1, "shift \(shift) read as \(lag)")
        }
    }

    @Test("a periodic signal reads as ambiguous (second peak ≈ first); zero energy reads 0, never a peak")
    func ambiguityAndSilence() {
        let periodic = (0..<4_400).map { Float(sin(Double($0) * 2 * .pi / 60)) }
        let correlator = AVSyncCorrelator(maxReference: 4_000, maxLag: 200)
        let c = correlator.normalisedCrossCorrelation(reference: Array(periodic[200..<4_200]), search: periodic, maxLag: 200)
        let peak = AVSyncCorrelation.peak(of: c)
        #expect((peak?.secondPeakRatio ?? 0) > 0.95)
        let silent = correlator.normalisedCrossCorrelation(reference: [Float](repeating: 0, count: 4_000),
                                                           search: periodic, maxLag: 200)
        #expect(silent.allSatisfy { $0 == 0 })
    }

    @Test("a maximum on the edge of the search is flagged, not refined")
    func edge() {
        let c: [Float] = [0.9, 0.5, 0.2, 0.1, 0.05]
        let peak = AVSyncCorrelation.peak(of: c)
        #expect(peak?.atEdge == true && peak?.lagSteps == -2)
    }
}

// MARK: - Analyzer on hand-built signals

/// Builds an original/processed signal pair whose sound and picture are
/// shifted by known amounts, with `soundShift(t)` / `pictureShift(t)` in ms
/// (processed(t) = original(t + shift)), so s = soundShift − pictureShift.
enum AVSyncSyntheticSignals {
    static let grid = 0.005

    /// A sparse random event train (onsets / motion), smoothed a little.
    static func events(seconds: Double, seed: UInt64, rate: Double) -> [Float] {
        var rng = SplitMix64(seed: seed)
        var x = [Float](repeating: 0, count: Int(seconds / grid))
        for i in x.indices where rng.unit() < rate * grid { x[i] = Float(rng.range(0.5, 2)) }
        return AVSyncSignalMath.movingAverage(x, radius: 1)
    }

    /// processed[i] = original[i + shift(i)/grid] (linear interpolation).
    static func shifted(_ original: [Float], seconds: Double, shiftMs: (Double) -> Double) -> [Float] {
        (0..<Int(seconds / grid)).map { i in
            let t = Double(i) * grid
            let u = (t + shiftMs(t) / 1_000) / grid
            let k = Int(u.rounded(.down)), f = Float(u - Double(k))
            guard k >= 0, k + 1 < original.count else { return 0 }
            return original[k] * (1 - f) + original[k + 1] * f
        }
    }

    static func pair(seconds: Double, sound: @escaping (Double) -> Double, picture: @escaping (Double) -> Double,
                     silentSound: Bool = false, staticPicture: Bool = false) -> (AVSyncSignals, AVSyncSignals) {
        let onset = silentSound ? [Float](repeating: 0, count: Int(seconds / grid))
                                : events(seconds: seconds + 2, seed: 11, rate: 4).map { $0 * 0.2 }
        let motion = staticPicture ? [Float](repeating: 0, count: Int(seconds / grid))
                                   : events(seconds: seconds + 2, seed: 12, rate: 3).map { $0 * 300 + 5 }
        let original = AVSyncSignals(gridSeconds: grid, onset: Array(onset.prefix(Int(seconds / grid))),
                                     motion: Array(motion.prefix(Int(seconds / grid))))
        let processed = AVSyncSignals(gridSeconds: grid, onset: shifted(onset, seconds: seconds, shiftMs: sound),
                                      motion: shifted(motion, seconds: seconds, shiftMs: picture))
        return (original, processed)
    }
}

struct AVSyncAnalyzerTests {

    func analyze(_ pair: (AVSyncSignals, AVSyncSignals), policy: AVSyncPolicy = .default) -> AVSyncReport {
        AVSyncAnalyzer.analyze(original: pair.0, processed: pair.1, coarseOffsetSeconds: 0, policy: policy)
    }

    @Test("asymmetric band: 55 ms late is in sync, 35 ms early is an offset (−60 / +30 ms)")
    func asymmetricBand() {
        let late = analyze(AVSyncSyntheticSignals.pair(seconds: 120, sound: { _ in -55 }, picture: { _ in 0 }))
        #expect(late.verdict.isInSync, "\(late.sentence)")
        let early = analyze(AVSyncSyntheticSignals.pair(seconds: 120, sound: { _ in 35 }, picture: { _ in 0 }))
        guard case let .offset(shift) = early.verdict else {
            Issue.record("expected offset: \(early.sentence)"); return
        }
        #expect(abs(shift - 35) < 2)
        #expect(early.sentence == "sound 35 ms early against the picture, the same through the whole file")
    }

    @Test("the same trim on sound and picture is harmless: s = 0")
    func harmlessTrim() {
        let report = analyze(AVSyncSyntheticSignals.pair(seconds: 120, sound: { _ in 150 }, picture: { _ in 150 }))
        #expect(report.verdict.isInSync, "\(report.sentence)")
        #expect(abs(report.medianShiftMs ?? 99) < 1)
    }

    @Test("a steady drift reads as drift with its endpoints; a step reads as a jump at its time")
    func driftAndJump() {
        let drift = analyze(AVSyncSyntheticSignals.pair(seconds: 240, sound: { -0.5 * $0 }, picture: { _ in 0 }))
        guard case let .drift(from, to, over) = drift.verdict else {
            Issue.record("expected drift: \(drift.sentence)"); return
        }
        #expect(abs(from) < 5 && abs(to + 120) < 5 && abs(over - 240) < 1, "\(drift.sentence)")
        #expect(drift.sentence == "sound drifts from 0 to 120 ms late over 4 minutes")

        let jump = analyze(AVSyncSyntheticSignals.pair(seconds: 240, sound: { _ in 0 },
                                                       picture: { $0 < 121 ? 0 : 200 }))
        guard case let .jump(from, to, at) = jump.verdict else {
            Issue.record("expected jump: \(jump.sentence)"); return
        }
        #expect(abs(from) < 5 && abs(to + 200) < 5 && abs(at - 121) <= 10, "\(jump.sentence)")
        #expect(jump.sentence.hasPrefix("sound jumps from 0 to 200 ms late at "), "\(jump.sentence)")
    }

    @Test("could not measure: silent sound, static picture, too short — never in sync")
    func cannotMeasure() {
        let silent = analyze(AVSyncSyntheticSignals.pair(seconds: 120, sound: { _ in 0 }, picture: { _ in 0 },
                                                         silentSound: true))
        #expect(silent.verdict == .couldNotMeasure(.tooFewWindows(
            measured: 0, total: 11, reasons: [AVSyncReasonCount(reason: .noSound, count: 11)])), "\(silent.sentence)")
        let still = analyze(AVSyncSyntheticSignals.pair(seconds: 120, sound: { _ in 0 }, picture: { _ in 0 },
                                                        staticPicture: true))
        #expect(still.sentence == "could not measure: none of 11 windows could be measured (no movement)")
        let short = analyze(AVSyncSyntheticSignals.pair(seconds: 12, sound: { _ in 0 }, picture: { _ in 0 }))
        #expect(short.verdict == .couldNotMeasure(.tooShort(overlapSeconds: 12, neededSeconds: 20)))
    }

    @Test("fewer than 30 % of windows measured is could not measure, even when those agree")
    func tooFewFraction() {
        let pair = AVSyncSyntheticSignals.pair(seconds: 200, sound: { _ in 0 }, picture: { _ in 0 })
        let original = pair.0
        var processed = pair.1
        // Silence the processed sound after 50 s: 4 of 19 windows keep sound.
        var onset = processed.onset
        for i in Int(50 / 0.005)..<onset.count { onset[i] = 0 }
        processed = AVSyncSignals(gridSeconds: 0.005, onset: onset, motion: processed.motion)
        let report = analyze((original, processed))
        guard case let .couldNotMeasure(.tooFewWindows(measured, total, _)) = report.verdict else {
            Issue.record("expected too few windows: \(report.sentence)"); return
        }
        #expect(measured < 6 && total == 19, "\(report.sentence)")
    }

    @Test("a lone wild window is set aside as an outlier, not allowed to turn in sync into an offset")
    func outlier() {
        let report = analyze(AVSyncSyntheticSignals.pair(seconds: 200, sound: { _ in 0 },
                                                         picture: { ($0 > 101 && $0 < 109) ? -150 : 0 }))
        #expect(report.verdict.isInSync, "\(report.sentence)")
    }

    @Test("windows: 20 s every 10 s across the shared stretch (a 3-minute clip has 17)")
    func windowCount() {
        let report = analyze(AVSyncSyntheticSignals.pair(seconds: 180, sound: { _ in 0 }, picture: { _ in 0 }))
        #expect(report.windows.count == 17)
        #expect(report.windows.first?.startSeconds == 0 && report.windows.last?.startSeconds == 160)
    }

    @Test("the coarse offset shifts the shared stretch: windows only where both files have sound")
    func coarseOverlap() {
        let pair = AVSyncSyntheticSignals.pair(seconds: 120, sound: { _ in 0 }, picture: { _ in 0 })
        let report = AVSyncAnalyzer.analyze(original: pair.0, processed: pair.1, coarseOffsetSeconds: 30)
        #expect(report.overlapStartSeconds == 0 && abs(report.overlapEndSeconds - 90) < 0.01)
    }

    @Test("a tuned policy is judged by its own numbers and keyed by its own identity")
    func tunedPolicy() {
        var strict = AVSyncPolicy()
        strict.lateLimitMs = 20
        let report = analyze(AVSyncSyntheticSignals.pair(seconds: 120, sound: { _ in -40 }, picture: { _ in 0 }),
                             policy: strict)
        #expect(!report.verdict.isInSync)
        #expect(report.policyIdentity != AVSyncPolicy.default.identity)
        #expect(report.policyIdentity.hasPrefix("v1~"))
    }
}

// MARK: - Policy and words

struct AVSyncPolicyTests {

    @Test("the default policy is pinned to its version — change a default, bump the version")
    func pinned() {
        let p = AVSyncPolicy.default
        #expect(AVSyncPolicy.currentVersion == 1)
        #expect(p.earlyLimitMs == 30 && p.lateLimitMs == 60 && p.maxDriftMs == 20)
        #expect(p.minMeasuredWindows == 3 && p.minMeasuredFraction == 0.30)
        #expect(p.gridSeconds == 0.005 && p.windowSeconds == 20 && p.hopSeconds == 10)
        #expect(p.soundSearchMs == 250 && p.pictureSearchMs == 1_000 && p.soundAmbiguitySearchMs == 1_000)
        #expect(p.minPeak == 0.30 && p.maxSecondPeakRatio == 0.80)
        #expect(p.minSoundActivity == 0.002 && p.minPictureActivity == 2.0)
        #expect(p.outlierSigmas == 4 && p.outlierFloorMs == 20 && p.maxWindowSpreadMs == 15)
        #expect(p.jumpJitterFactor == 2 && p.minJumpMs == 20 && p.jumpHoldWindows == 3)
        #expect(p.identity == "v1")
    }

    @Test("the in-sync band is inclusive and asymmetric")
    func band() {
        let p = AVSyncPolicy.default
        #expect(p.isInSync(shiftMs: -60) && p.isInSync(shiftMs: 30) && p.isInSync(shiftMs: 0))
        #expect(!p.isInSync(shiftMs: -60.5) && !p.isInSync(shiftMs: 30.5))
    }

    @Test("the policy round-trips through JSON")
    func codable() throws {
        var p = AVSyncPolicy()
        p.maxDriftMs = 33
        let back = try JSONDecoder().decode(AVSyncPolicy.self, from: JSONEncoder().encode(p))
        #expect(back == p && back.identity == p.identity)
    }
}

struct AVSyncReportWordsTests {

    @Test("the verdict sentences are exactly the design's words (§1)")
    func sentences() {
        #expect(AVSyncVerdict.inSync(withinMs: 12, measured: 41, total: 44,
                                     notMeasured: [AVSyncReasonCount(reason: .noMovement, count: 3)], setAside: 0).sentence
                == "in sync: sound within 12 ms of the picture across 41 of 44 windows (3 could not be measured: no movement)")
        #expect(AVSyncVerdict.offset(shiftMs: -80).sentence
                == "sound 80 ms late against the picture, the same through the whole file")
        #expect(AVSyncVerdict.drift(fromMs: 0.4, toMs: -160, overSeconds: 58 * 60).sentence
                == "sound drifts from 0 to 160 ms late over 58 minutes")
        #expect(AVSyncVerdict.jump(fromMs: 0, toMs: -200, atSeconds: 23 * 60 + 41).sentence
                == "sound jumps from 0 to 200 ms late at 23:41 (frames dropped or added there)")
        #expect(AVSyncVerdict.localShift(shiftMs: -150, atSeconds: 80, forSeconds: 30).sentence
                == "sound 150 ms late for about 30 seconds at 1:20")
        #expect(AVSyncVerdict.couldNotMeasure(.windowsDisagree(spreadMs: 42.4)).sentence
                == "could not measure: the windows disagree (spread ±42 ms)")
        #expect(AVSyncVerdict.couldNotMeasure(.noSharedSound).sentence
                == "could not measure: these two files do not share the same sound")
    }

    @Test("early and late, never a bare signed number")
    func earlyLate() {
        #expect(AVSyncVerdict.offset(shiftMs: 45).sentence.hasPrefix("sound 45 ms early "))
        #expect(AVSyncVerdict.drift(fromMs: 20, toMs: -40, overSeconds: 600).sentence
                == "sound drifts from 20 ms early to 40 ms late over 10 minutes")
        #expect(AVSyncVerdict.jump(fromMs: -20, toMs: 100, atSeconds: 3_725).sentence
                == "sound jumps from 20 ms late to 100 ms early at 1:02:05 (frames dropped or added there)")
        for verdict in [AVSyncVerdict.offset(shiftMs: -80), .offset(shiftMs: 80), .jump(fromMs: -5, toMs: -50, atSeconds: 1),
                        .localShift(shiftMs: -90, atSeconds: 5, forSeconds: 20)] {
            #expect(!verdict.sentence.contains("-"), "\(verdict.sentence)")
        }
    }

    @Test("several reasons are counted, largest first; could-not-measure words")
    func reasons() {
        let v = AVSyncVerdict.inSync(withinMs: 3, measured: 7, total: 10, notMeasured: [
            AVSyncReasonCount(reason: .noMovement, count: 2), AVSyncReasonCount(reason: .noSound, count: 1)], setAside: 0)
        #expect(v.sentence.hasSuffix("(3 could not be measured: 2 no movement, 1 no sound)"))
        #expect(AVSyncVerdict.couldNotMeasure(.tooFewWindows(measured: 2, total: 10, reasons: [])).sentence
                == "could not measure: only 2 of 10 windows could be measured")
        #expect(AVSyncVerdict.couldNotMeasure(.noSound(processed: false)).sentence
                == "could not measure: the original has no sound to line up (silence or a steady tone)")
    }

    @Test("a report round-trips through JSON, windows and all")
    func codable() throws {
        var w = AVSyncWindow(startSeconds: 10, durationSeconds: 20)
        w.soundLagMs = 1.5
        w.pictureLagMs = 81.5
        let report = AVSyncReport(policyIdentity: "v1", verdict: .offset(shiftMs: -80), coarseOffsetSeconds: 0.064,
                                  overlapStartSeconds: 0, overlapEndSeconds: 60, windows: [w], medianShiftMs: -80)
        let back = try JSONDecoder().decode(AVSyncReport.self, from: JSONEncoder().encode(report))
        #expect(back == report)
        #expect(back.windows.first?.shiftMs == -80)
        #expect(back.sentence == report.sentence)
    }
}
