// AVSyncReport.swift (VideoScanCore)
// ONE SENTENCE: what one sync check measured — the verdict in plain words
// (design §1), every window's evidence, and the policy it was judged by.
//
// Words (docs/design/av_sync_analysis.md §1, exactly):
//   in sync:  "in sync: sound within 12 ms of the picture across 41 of 44
//              windows (3 could not be measured: no movement)"
//   offset:   "sound 80 ms late against the picture, the same through the whole file"
//   drift:    "sound drifts from 0 to 160 ms late over 58 minutes"
//   jump:     "sound jumps 200 ms late at 23:41 (frames dropped or added there)"
//   could not measure: "could not measure: …" — never "in sync".
// Every word says "early" or "late", never a signed number alone (§2:
// s > 0 = sound early, s < 0 = sound late). `worstAbsShiftMs` may ORDER a
// review list; it is never the verdict (§1).
//
// (For Rick: an enum with payloads ≈ std::variant; `Codable` makes the whole
// report JSON for a log line or a future evidence row.)

import Foundation

/// Why a window gave no measurement.
public enum AVSyncNotMeasured: String, Codable, Sendable, CaseIterable {
    case noSound
    case noMovement
    case soundRepeats
    case movementRepeats
    case soundUnmatched
    case pictureUnmatched
    case beyondSearch
    case outlier

    public var words: String {
        switch self {
        case .noSound: return "no sound"
        case .noMovement: return "no movement"
        case .soundRepeats: return "the sound repeats"
        case .movementRepeats: return "the movement repeats"
        case .soundUnmatched: return "the sound does not match"
        case .pictureUnmatched: return "the picture does not match"
        case .beyondSearch: return "the shift is beyond the search range"
        case .outlier: return "out of line with the rest"
        }
    }
}

/// One window's evidence. Lags are in ms on the processed file's timeline:
/// processed(t) ≈ original(t + lag). `shiftMs` = soundLag − pictureLag.
public struct AVSyncWindow: Codable, Sendable, Equatable {
    public let startSeconds: Double
    public let durationSeconds: Double
    public var soundLagMs: Double?
    public var pictureLagMs: Double?
    public var soundPeak: Double?
    public var soundSecondPeakRatio: Double?
    public var picturePeak: Double?
    public var pictureSecondPeakRatio: Double?
    public var notMeasured: AVSyncNotMeasured?

    public init(startSeconds: Double, durationSeconds: Double) {
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }

    public var centreSeconds: Double { startSeconds + durationSeconds / 2 }
    public var isMeasured: Bool { notMeasured == nil && shiftMs != nil }
    public var shiftMs: Double? {
        guard let a = soundLagMs, let v = pictureLagMs else { return nil }
        return a - v
    }
}

/// How many windows went unmeasured for one reason.
public struct AVSyncReasonCount: Codable, Sendable, Equatable {
    public let reason: AVSyncNotMeasured
    public let count: Int
    public init(reason: AVSyncNotMeasured, count: Int) {
        self.reason = reason
        self.count = count
    }
}

/// Why nothing could be said.
public enum AVSyncCannotMeasure: Codable, Sendable, Equatable {
    /// The coarse sound match found no shared recording.
    case noSharedSound
    /// One side has no sound to line up (silence, a steady tone).
    case noSound(processed: Bool)
    /// The shared stretch is shorter than one window.
    case tooShort(overlapSeconds: Double, neededSeconds: Double)
    /// Too few windows measured (§4: fewer than 3, or under 30 %).
    case tooFewWindows(measured: Int, total: Int, reasons: [AVSyncReasonCount])
}

public enum AVSyncVerdict: Codable, Sendable, Equatable {
    case inSync(withinMs: Double, measured: Int, total: Int, notMeasured: [AVSyncReasonCount])
    case offset(shiftMs: Double)
    case drift(fromMs: Double, toMs: Double, overSeconds: Double)
    case jump(stepMs: Double, atSeconds: Double)
    case couldNotMeasure(AVSyncCannotMeasure)

    /// True only for `.inSync`.
    public var isInSync: Bool { if case .inSync = self { return true } else { return false } }
    /// True for offset, drift and jump — flag for review.
    public var needsReview: Bool {
        switch self {
        case .offset, .drift, .jump: return true
        case .inSync, .couldNotMeasure: return false
        }
    }

    /// The plain-language verdict (§1).
    public var sentence: String {
        switch self {
        case let .inSync(within, measured, total, notMeasured):
            var text = "in sync: sound within \(AVSyncWords.ms(within)) ms of the picture across \(measured) of \(total) windows"
            let missing = notMeasured.reduce(0) { $0 + $1.count }
            if missing > 0 { text += " (\(missing) could not be measured: \(AVSyncWords.reasons(notMeasured)))" }
            return text
        case let .offset(shift):
            return "sound \(AVSyncWords.shift(shift)) against the picture, the same through the whole file"
        case let .drift(from, to, over):
            return "sound drifts from \(AVSyncWords.range(from, to)) over \(AVSyncWords.duration(over))"
        case let .jump(step, at):
            return "sound jumps \(AVSyncWords.shift(step)) at \(AVSyncWords.clock(at)) (frames dropped or added there)"
        case let .couldNotMeasure(why):
            return "could not measure: " + AVSyncWords.cannot(why)
        }
    }
}

/// The result of one check: processed file against its original.
public struct AVSyncReport: Codable, Sendable, Equatable {
    /// Bump when the measurement itself (signals, correlation, rules)
    /// changes in a way that could change a verdict.
    public static let currentAnalyzerVersion = 1

    public var analyzerVersion: Int
    public var policyIdentity: String
    public var verdict: AVSyncVerdict
    /// The whole-file sound offset from the fingerprint match (seconds;
    /// processed(t) ≈ original(t + offset)), nil when there was none.
    public var coarseOffsetSeconds: Double?
    /// The shared stretch on the processed timeline (seconds).
    public var overlapStartSeconds: Double
    public var overlapEndSeconds: Double
    public var windows: [AVSyncWindow]
    public var medianShiftMs: Double?
    public var driftMsPerMinute: Double?
    /// For ordering a review list only — never the verdict.
    public var worstAbsShiftMs: Double?
    public var processedCuts: Int
    public var originalCuts: Int

    public init(analyzerVersion: Int = AVSyncReport.currentAnalyzerVersion, policyIdentity: String,
                verdict: AVSyncVerdict, coarseOffsetSeconds: Double? = nil, overlapStartSeconds: Double = 0,
                overlapEndSeconds: Double = 0, windows: [AVSyncWindow] = [], medianShiftMs: Double? = nil,
                driftMsPerMinute: Double? = nil, worstAbsShiftMs: Double? = nil, processedCuts: Int = 0,
                originalCuts: Int = 0) {
        self.analyzerVersion = analyzerVersion
        self.policyIdentity = policyIdentity
        self.verdict = verdict
        self.coarseOffsetSeconds = coarseOffsetSeconds
        self.overlapStartSeconds = overlapStartSeconds
        self.overlapEndSeconds = overlapEndSeconds
        self.windows = windows
        self.medianShiftMs = medianShiftMs
        self.driftMsPerMinute = driftMsPerMinute
        self.worstAbsShiftMs = worstAbsShiftMs
        self.processedCuts = processedCuts
        self.originalCuts = originalCuts
    }

    public var sentence: String { verdict.sentence }
    public var measuredWindows: Int { windows.filter(\.isMeasured).count }
}

/// The few formatting rules the sentences share.
enum AVSyncWords {
    static func ms(_ value: Double) -> String { String(Int(abs(value).rounded())) }

    /// "80 ms late" / "40 ms early" / "0 ms" — s > 0 early, s < 0 late.
    static func shift(_ s: Double) -> String {
        let size = ms(s)
        if size == "0" { return "0 ms" }
        return "\(size) ms " + (s > 0 ? "early" : "late")
    }

    /// "0 to 160 ms late", "20 ms early to 40 ms late".
    static func range(_ from: Double, _ to: Double) -> String {
        let a = ms(from), b = ms(to)
        let fromWord = a == "0" ? nil : (from > 0 ? "early" : "late")
        let toWord = b == "0" ? nil : (to > 0 ? "early" : "late")
        switch (fromWord, toWord) {
        case (nil, nil): return "0 to 0 ms"
        case (nil, let w?): return "0 to \(b) ms \(w)"
        case (let w?, nil): return "\(a) ms \(w) to 0"
        case let (w1?, w2?): return w1 == w2 ? "\(a) to \(b) ms \(w2)" : "\(a) ms \(w1) to \(b) ms \(w2)"
        }
    }

    /// "58 minutes", "1 minute", "45 seconds".
    static func duration(_ seconds: Double) -> String {
        if seconds >= 90 {
            let minutes = Int((seconds / 60).rounded())
            return minutes == 1 ? "1 minute" : "\(minutes) minutes"
        }
        let whole = Int(seconds.rounded())
        return whole == 1 ? "1 second" : "\(whole) seconds"
    }

    /// "23:41", "1:02:03".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3_600, m = (total % 3_600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "no movement", or "2 no movement, 1 no sound" (largest first).
    static func reasons(_ counts: [AVSyncReasonCount]) -> String {
        let present = counts.filter { $0.count >= 1 }
        if present.count == 1 { return present[0].reason.words }
        return present.map { "\($0.count) \($0.reason.words)" }.joined(separator: ", ")
    }

    static func cannot(_ why: AVSyncCannotMeasure) -> String {
        switch why {
        case .noSharedSound:
            return "these two files do not share the same sound"
        case let .noSound(processed):
            return (processed ? "the processed file" : "the original") + " has no sound to line up (silence or a steady tone)"
        case let .tooShort(overlap, needed):
            return "the two files share only \(Int(overlap.rounded())) seconds of sound (a measurement needs \(Int(needed.rounded())))"
        case let .tooFewWindows(measured, total, reasons):
            let lead = measured == 0 ? "none of \(total) windows could be measured"
                                     : "only \(measured) of \(total) windows could be measured"
            return reasons.isEmpty ? lead : lead + " (\(Self.reasons(reasons)))"
        }
    }
}
