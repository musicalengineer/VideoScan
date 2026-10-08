import Foundation

// MARK: - Check Media — sound levels from the continuity pass (2026-10-07)
//
// Riding the SAME streamed sound decode as SoundContinuity.swift (no extra
// read of the file):
//
//   * DCOffsetTracker      — per-channel mean: a constant offset from zero.
//   * ClipRunTracker       — per channel, ≥ 3 samples in a row pinned at
//     full scale (flat-topped waveform: real clipping, not one loud peak).
//   * ChannelRelation      — the first two channels: identical (mono
//     stored as stereo), inverted (one wired backwards: mono playback
//     cancels), or independent; plus their correlation.
//   * LoudnessSummary      — `ebur128=peak=true` in the decode's filter
//     chain prints Integrated loudness / LRA / True peak at the end.
//
// Memory: O(channels) running sums; no buffers. Doubles for the sums: 2^53
// headroom over 2^31-scaled samples is ample for any home recording.

private let fullScale = 2_147_483_648.0

/// Running mean per channel.
struct DCOffsetTracker: Sendable, Equatable {
    var sums: [Double]
    var frames = 0

    init(channels: Int) { sums = Array(repeating: 0, count: channels) }

    mutating func observe(_ x: Int32, channel: Int) { sums[channel] += Double(x) }

    /// Each channel's offset as a fraction of full scale.
    var offsets: [Double] { frames > 0 ? sums.map { $0 / Double(frames) / fullScale } : [] }
}

/// Runs of samples pinned at (within one 16-bit step of) full scale.
struct ClipRunTracker: Sendable, Equatable {
    static let pinned = Int32.max - 65_536
    static let minimumRun = 3
    var runs = MediaEventLog()
    private var lengths: [Int]

    init(channels: Int) { lengths = Array(repeating: 0, count: channels) }

    /// Feed one sample; a run that just ended (≥ 3 long) is noted.
    mutating func observe(_ x: Int32, channel: Int, at seconds: Double) {
        if x >= Self.pinned || x <= -Self.pinned {
            lengths[channel] += 1
            return
        }
        if lengths[channel] >= Self.minimumRun { runs.note(seconds) }
        lengths[channel] = 0
    }
}

/// How the first two channels relate.
struct ChannelRelation: Sendable, Equatable {
    /// Below this (≈ −80 dBFS on both) a frame is silence, not evidence.
    static let soundingFloor: Int64 = 214_748
    var soundingFrames = 0
    var identicalFrames = 0
    var invertedFrames = 0
    var sumLL = 0.0, sumRR = 0.0, sumLR = 0.0

    mutating func observe(left l: Int32, right r: Int32) {
        guard abs(Int64(l)) + abs(Int64(r)) > Self.soundingFloor else { return }
        soundingFrames += 1
        if l == r { identicalFrames += 1 } else if Int64(l) == -Int64(r) { invertedFrames += 1 }
        let a = Double(l) / fullScale, b = Double(r) / fullScale
        sumLL += a * a
        sumRR += b * b
        sumLR += a * b
    }

    var correlation: Double? {
        let d = (sumLL * sumRR).squareRoot()
        return soundingFrames > 0 && d > 0 ? sumLR / d : nil
    }

    enum Kind: Sendable, Equatable { case identical, inverted, independent, notEnough }

    var kind: Kind {
        guard soundingFrames >= 4_800 else { return .notEnough }   // 0.1 s at 48 kHz
        let n = Double(soundingFrames)
        if Double(identicalFrames) >= 0.999 * n { return .identical }
        if Double(invertedFrames) >= 0.999 * n || (correlation ?? 0) < -0.9 { return .inverted }
        return .independent
    }
}

/// The `ebur128` end-of-stream summary.
struct LoudnessSummary: Sendable, Equatable {
    var integratedLUFS: Double?
    var rangeLU: Double?
    var truePeakDBFS: Double?

    /// Lines are trimmed by ProcessRunner: "I:         -19.6 LUFS".
    func adding(line: String) -> LoudnessSummary {
        var s = self
        if line.hasPrefix("I:") {
            s.integratedLUFS = MediaSignalScan.number(after: "I:", in: line)
        } else if line.hasPrefix("LRA:") {
            s.rangeLU = MediaSignalScan.number(after: "LRA:", in: line)
        } else if line.hasPrefix("Peak:") {
            s.truePeakDBFS = MediaSignalScan.number(after: "Peak:", in: line)
        }
        return s
    }
}

/// All the level facts of one sound pass.
struct SoundLevelReport: Sendable, Equatable {
    var dcOffsets: [Double] = []
    var clipRuns = MediaEventLog()
    var channels: ChannelRelation.Kind = .notEnough
    var correlation: Double?
    var loudness = LoudnessSummary()
    var channelCount = 0
}

/// The three sample-level trackers, fed one sample at a time.
struct SoundLevelTracker {
    private var dc: DCOffsetTracker
    private var clips: ClipRunTracker
    private var relation = ChannelRelation()
    private var left: Int32 = 0
    let channels: Int

    init(channels: Int) {
        self.channels = channels
        dc = DCOffsetTracker(channels: channels)
        clips = ClipRunTracker(channels: channels)
    }

    mutating func observe(_ x: Int32, channel: Int, at seconds: Double) {
        dc.observe(x, channel: channel)
        clips.observe(x, channel: channel, at: seconds)
        if channel == 0 { left = x } else if channel == 1 { relation.observe(left: left, right: x) }
    }

    mutating func endFrame() { dc.frames += 1 }

    func report(loudness: LoudnessSummary) -> SoundLevelReport {
        SoundLevelReport(dcOffsets: dc.offsets, clipRuns: clips.runs,
                         channels: channels >= 2 ? relation.kind : .notEnough,
                         correlation: channels >= 2 ? relation.correlation : nil,
                         loudness: loudness, channelCount: channels)
    }
}
