// EvidenceSampler.swift (VideoScanCore/ModelLab)
// ONE SENTENCE: how a media file becomes model input — a PURE plan of
// windows and frame times from probe facts; the job decodes later through
// the existing extractors (docs/design/video_llm_lab_2026_10_30.md §3.2).
//
// For Rick (C++): `EvidenceSampler` is an abstract base class with one
// virtual, `plan(for:)`; the two samplers here are concrete subclasses that
// are plain value types (no state, no I/O), so a plan is a deterministic
// function of (probe, parameters) and can be unit-tested without a file.
//
// Samplers never decode and never touch the file system. They never see a
// path, only numbers from ffprobe/AVFoundation and, when the job has them,
// scene-cut times.
//
// MEMORY: a plan holds one Double per frame time. Worst case is a 4-hour
// tape at 1 fps: 14,400 doubles ≈ 115 KB in 240 windows. StillsSampler is
// n doubles. Nothing is cached.

import Foundation

/// Pure: given probe facts, returns a plan. Decode happens in the job.
public protocol EvidenceSampler: Sendable {
    /// Stable id for the run record: "stills-8", "window-60s-1fps-scenecut".
    var id: String { get }
    func plan(for probe: SamplerProbe) -> SamplePlan
}

/// What the job knows about a file before any frame is decoded.
public struct SamplerProbe: Sendable, Equatable {
    public let durationS: Double
    public let fps: Double
    public let hasAudio: Bool
    /// Scene-cut times in seconds (ffmpeg `select='gt(scene,0.3)'` today),
    /// or nil when the job did not run the detector. Need not be sorted or
    /// clean; the sampler sanitizes.
    public let sceneCutsS: [Double]?

    public init(durationS: Double, fps: Double, hasAudio: Bool, sceneCutsS: [Double]? = nil) {
        self.durationS = durationS
        self.fps = fps
        self.hasAudio = hasAudio
        self.sceneCutsS = sceneCutsS
    }
}

/// One stretch of the file the model sees as a unit.
public struct SampleWindow: Sendable, Hashable {
    /// Closed range in the file, seconds. Consecutive windows share a
    /// boundary (`next.startS == endS`) and never overlap inside it.
    public let startS: Double
    public let endS: Double
    /// What the model sees, in order; each inside [startS, endS).
    public let frameTimesS: [Double]
    /// nil = no audio for this window.
    public let audioRange: ClosedRange<Double>?

    public init(startS: Double, endS: Double, frameTimesS: [Double], audioRange: ClosedRange<Double>?) {
        self.startS = startS
        self.endS = endS
        self.frameTimesS = frameTimesS
        self.audioRange = audioRange
    }

    public var durationS: Double { endS - startS }
}

public struct SamplePlan: Sendable, Equatable {
    public let windows: [SampleWindow]
    public init(windows: [SampleWindow]) { self.windows = windows }
    public static let empty = SamplePlan(windows: [])
    /// Frames the job will decode for this file.
    public var frameCount: Int { windows.reduce(0) { $0 + $1.frameTimesS.count } }
}

// MARK: - StillsSampler (A0: what the app does today)

/// N stills evenly spaced over the middle 90 % of the file — the app's
/// `framesEvenlySpaced` (Media/CaptionOrchestrator.swift) exactly, so the
/// A0 control sees the frames today's captioner sees. One window spans the
/// file; stills carry no audio.
public struct StillsSampler: EvidenceSampler {
    public let frames: Int
    public init(_ frames: Int) { self.frames = frames }
    public var id: String { "stills-\(frames)" }

    public func plan(for probe: SamplerProbe) -> SamplePlan {
        let times = Self.framesEvenlySpaced(framesPerFile: frames, durationSec: probe.durationS)
        guard let last = times.last else { return .empty }
        // The app's 0.1 s floor can place a frame past the end of a
        // sub-0.1 s clip; the window is widened to hold it so the plan's
        // own invariant (frames inside the window) stays true.
        let end = max(probe.durationS, last)
        return SamplePlan(windows: [SampleWindow(startS: 0, endS: end, frameTimesS: times, audioRange: nil)])
    }

    /// Byte-for-byte the app's `framesEvenlySpaced` (CaptionOrchestrator.swift,
    /// `internal` there so Core cannot call it). ModelLabSamplerTests pins
    /// the two to the same literal values for three durations; change both
    /// or neither.
    public static func framesEvenlySpaced(framesPerFile: Int, durationSec: Double) -> [Double] {
        guard framesPerFile > 0, durationSec > 0 else { return [] }
        let safe = max(0.1, durationSec)
        let lo = safe * 0.05
        let hi = safe * 0.95
        if framesPerFile == 1 {
            return [(lo + hi) / 2.0]
        }
        let stride = (hi - lo) / Double(framesPerFile - 1)
        return (0..<framesPerFile).map { i in lo + Double(i) * stride }
    }
}

// MARK: - WindowSampler (A1+: chronological windows)

/// Where a window boundary may move to.
public enum CutSnapping: Sendable, Equatable {
    /// Boundaries fall exactly every `seconds`.
    case exactSeconds
    /// A boundary moves to the scene cut nearest its nominal position when
    /// one lies within `withinS` of it (either side), so a window does not
    /// straddle a cut by a second or two. The next window starts at the cut.
    case sceneCuts(withinS: Double)
}

/// Consecutive windows of `seconds`, `fps` frames per second inside each,
/// boundaries snapped to scene cuts when asked. Covers the file from 0 to
/// its duration; the last window may be short; windows never overlap. A
/// snapped window may run up to `seconds + withinS` (75 s at the defaults:
/// 75 frames ≈ 45 MB in flight at 448×448, the job's worst case per window).
public struct WindowSampler: EvidenceSampler {
    public let seconds: Double
    public let fps: Double
    public let cutAt: CutSnapping

    /// `seconds` and `fps` are clamped to small positive floors (a zero or
    /// negative value is a caller bug, not a reason to crash a job).
    public init(seconds: Double, fps: Double, cutAt: CutSnapping = .sceneCuts(withinS: 15)) {
        self.seconds = seconds.isFinite && seconds > 0 ? seconds : 1
        self.fps = fps.isFinite && fps > 0 ? fps : 1
        self.cutAt = cutAt
    }

    public var id: String {
        let base = "window-\(Self.trimmed(seconds))s-\(Self.trimmed(fps))fps"
        if case .sceneCuts = cutAt { return base + "-scenecut" }
        return base
    }

    private static func trimmed(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    public func plan(for probe: SamplerProbe) -> SamplePlan {
        let duration = probe.durationS
        guard duration.isFinite, duration > 0 else { return .empty }
        let cuts = sanitizedCuts(probe.sceneCutsS, duration: duration)
        let interval = 1 / fps
        // Upper bound on windows: ceil(duration / minimum window) — bounded
        // below by `seconds - tolerance`, floored at interval. Reserve once.
        var windows: [SampleWindow] = []
        windows.reserveCapacity(Int((duration / seconds).rounded(.up)) + 1)
        var start = 0.0
        while start < duration {
            let nominal = start + seconds
            var end = min(nominal, duration)
            if nominal < duration, let cut = snappedCut(cuts, nominal: nominal, after: start, before: duration) {
                end = cut
            }
            // Frames at start, start + 1/fps, … strictly before end; a window
            // shorter than one interval still shows its first frame.
            var times: [Double] = [start]
            var t = start + interval
            while t < end - 1e-9 {
                times.append(t)
                t += interval
            }
            let audio: ClosedRange<Double>? = probe.hasAudio ? start...end : nil
            windows.append(SampleWindow(startS: start, endS: end, frameTimesS: times, audioRange: audio))
            start = end
        }
        return SamplePlan(windows: windows)
    }

    /// Finite, strictly inside (0, duration), sorted, unique.
    private func sanitizedCuts(_ cuts: [Double]?, duration: Double) -> [Double] {
        guard case .sceneCuts = cutAt, let cuts, !cuts.isEmpty else { return [] }
        var clean = cuts.filter { $0.isFinite && $0 > 0 && $0 < duration }
        clean.sort()
        var unique: [Double] = []
        unique.reserveCapacity(clean.count)
        for c in clean where unique.last != c { unique.append(c) }
        return unique
    }

    /// The cut nearest `nominal` within the tolerance, if it also leaves a
    /// non-empty window after `after` and before `before`.
    private func snappedCut(_ cuts: [Double], nominal: Double, after: Double, before: Double) -> Double? {
        guard case .sceneCuts(let tolerance) = cutAt, tolerance > 0, !cuts.isEmpty else { return nil }
        // Binary search for the insertion point of `nominal`, then look at
        // its two neighbours — the only candidates for "nearest".
        var lo = 0, hi = cuts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cuts[mid] < nominal { lo = mid + 1 } else { hi = mid }
        }
        var best: Double?
        for index in [lo - 1, lo] where cuts.indices.contains(index) {
            let c = cuts[index]
            guard abs(c - nominal) <= tolerance, c > after, c < before else { continue }
            if let b = best, abs(b - nominal) <= abs(c - nominal) { continue }
            best = c
        }
        return best
    }
}
