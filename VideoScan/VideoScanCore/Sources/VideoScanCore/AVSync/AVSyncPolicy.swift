// AVSyncPolicy.swift (VideoScanCore)
// ONE SENTENCE: every number the A/V sync verdict is judged by, in one
// versioned value, so a change of policy is data and a re-measure can tell
// an old verdict from a current one.
//
// Design: docs/design/av_sync_analysis.md §4–§5. Sign convention (§2):
// s > 0 = the sound comes EARLY against the picture, s < 0 = LATE. People
// notice early sound sooner (ITU-R BT.1359: detectable at about +45 / −125 ms),
// so the in-sync band is asymmetric: −60 ms ≤ s ≤ +30 ms.
//
// VERSIONING: `version` names the DEFAULT values. A test pins the defaults to
// the version (AVSyncPolicyTests), so changing a default without bumping the
// version is a red test. `identity` is what a stored result is keyed by: the
// version for the defaults, the version plus every value otherwise — a hand-
// tuned policy never passes for the default one.
//
// (For Rick: a plain struct of named constants ≈ a C++ POD config struct with
// default member initialisers; `Codable` is free serialisation.)

import Foundation

public struct AVSyncPolicy: Sendable, Equatable, Codable {
    /// Bump when a DEFAULT below changes (AVSyncPolicyTests pins them).
    public static let currentVersion = 1

    public var version: Int = AVSyncPolicy.currentVersion

    // MARK: Verdict thresholds (§4)

    /// Sound may come at most this early (s ≤ +earlyLimitMs) and still be in sync.
    public var earlyLimitMs: Double = 30
    /// Sound may come at most this late (s ≥ −lateLimitMs) and still be in sync.
    public var lateLimitMs: Double = 60
    /// A steady change of the shift across the file at or above this is drift.
    public var maxDriftMs: Double = 20
    /// Fewer measured windows than this → could not measure.
    public var minMeasuredWindows: Int = 3
    /// Less than this fraction of the windows measured → could not measure.
    public var minMeasuredFraction: Double = 0.30

    // MARK: Windows and search (§5)

    /// The correlation grid (seconds). 5 ms = 200 Hz.
    public var gridSeconds: Double = 0.005
    public var windowSeconds: Double = 20
    public var hopSeconds: Double = 10
    /// The sound search around the coarse (fingerprint) offset, ± ms.
    public var soundSearchMs: Double = 250
    /// The picture search around the window's sound lag, ± ms: the largest
    /// sound-vs-picture shift this can measure. Wider than the sound search
    /// because the coarse offset comes from the sound alone.
    public var pictureSearchMs: Double = 1_000
    /// The sound correlation is computed this far (± ms) so a repeat beyond
    /// the sound search — a metronome's beat every 500 ms — is seen and the
    /// window called ambiguous; the peak itself must still lie within
    /// `soundSearchMs`.
    public var soundAmbiguitySearchMs: Double = 1_000

    // MARK: Confidence (§5.4)

    /// A correlation peak below this (normalised, 0…1) is not a measurement.
    public var minPeak: Double = 0.30
    /// The best peak outside the main lobe ÷ the main peak above this is
    /// ambiguous (a repeating beat, a regular pattern of movement).
    public var maxSecondPeakRatio: Double = 0.80
    /// A window whose sound onset energy is below this carries no usable
    /// sound (silence or a steady tone). Units: mean onset strength per grid
    /// step, in log10-power steps (see AVSyncSignals.onsetEnvelope).
    public var minSoundActivity: Double = 0.002
    /// A window whose picture changes less than this carries no usable
    /// movement. Units: mean absolute grey-level change per second on the
    /// 32×18 thumbnail (0…255 per frame, divided by the frame interval).
    public var minPictureActivity: Double = 2.0

    // MARK: Across windows (§5.5)

    /// A window further than this many robust standard deviations from the
    /// median shift (and more than `outlierFloorMs` away) is set aside.
    public var outlierSigmas: Double = 4
    public var outlierFloorMs: Double = 20
    /// A step is a jump only when larger than this many times the window
    /// jitter, larger than `minJumpMs`, and held for `jumpHoldWindows` on
    /// each side.
    public var jumpJitterFactor: Double = 2
    public var minJumpMs: Double = 20
    public var jumpHoldWindows: Int = 3

    public init() {}
    public static let `default` = AVSyncPolicy()

    /// The in-sync band (§4), inclusive.
    public func isInSync(shiftMs s: Double) -> Bool {
        s >= -lateLimitMs && s <= earlyLimitMs
    }

    /// What a stored result is keyed by: "v1" for the defaults, otherwise
    /// "v1~" followed by every value, so a tuned policy has its own key.
    public var identity: String {
        var defaults = AVSyncPolicy.default
        defaults.version = version
        if self == defaults { return "v\(version)" }
        let values: [Double] = [earlyLimitMs, lateLimitMs, maxDriftMs, Double(minMeasuredWindows), minMeasuredFraction,
                                gridSeconds, windowSeconds, hopSeconds, soundSearchMs, pictureSearchMs,
                                soundAmbiguitySearchMs, minPeak,
                                maxSecondPeakRatio, minSoundActivity, minPictureActivity, outlierSigmas,
                                outlierFloorMs, jumpJitterFactor, minJumpMs, Double(jumpHoldWindows)]
        return "v\(version)~" + values.map { String($0) }.joined(separator: ",")
    }
}
