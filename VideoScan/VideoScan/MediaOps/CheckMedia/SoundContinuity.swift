import Foundation

// MARK: - Check Media — "Sound continuity" (Rick 2026-10-07)
//
// Full tier. Every sound sample is decoded once (ffmpeg → raw s32le PCM on
// a pipe) and streamed through four small detectors, each a value type
// with one job:
//
//   * SilenceRunTracker  — exact digital-zero runs on ALL channels. 5 ms…
//     2 s mid-track = a dropout (a lost buffer); ≥ 2 s = a silent passage
//     (often a deliberate gap in an edit) — counted, never a verdict.
//   * BlockRepeatTracker — 1024 non-silent frames in a row identical to the
//     1024 before them (at ANY alignment): a replayed buffer. Only that
//     one buffer length is looked for (the common codec/driver size; the
//     Manager's hand diagnosis used it); other lengths are a follow-up.
//   * ClickTracker       — one per channel: a sample far off the line its
//     neighbours draw (second difference) compared with the recent level
//     of that same measure.
//   * SoundTimeline      — decoded-frame timestamps from `ashowinfo`
//     (after `asettb=1/sr`, so pts is in samples, exact): gaps and
//     overlaps between consecutive frames.
//
// The first and last 100 ms are ignored (start-up and end-of-take edges);
// events are held in a small pending queue until the decode is 100 ms past
// them, so the tail can be dropped without knowing the length up front.
//
// Memory (worst case, independent of the file's length): the pipe chunk
// (≈ 64 KB, owned by ProcessRunner), < 1 frame of carry, one ring of
// 1024 × channels Int32 (channels capped at 32 → 128 KB), per-channel click
// state (32 × 24 B), ≤ ~40 pending events and 5 timestamps per kind.
// ≈ 0.4 MB in all. (≈ C++: a fixed-size ring of state, no growth.)

/// A counted kind of event plus the first few times it happened.
struct SoundEventLog: Sendable, Equatable {
    static let kept = 5
    var occurrences = 0
    var firstSeconds: [Double] = []

    mutating func note(_ seconds: Double) {
        occurrences += 1
        if firstSeconds.count < Self.kept { firstSeconds.append(seconds) }
    }

    var timesText: String {
        firstSeconds.map { String(format: "%.2f s", $0) }.joined(separator: ", ")
            + (occurrences > firstSeconds.count ? ", …" : "")
    }
}

/// What the continuity pass found.
struct SoundContinuityReport: Sendable, Equatable {
    var seconds: Double = 0
    var dropouts = SoundEventLog()
    var longestDropoutSeconds: Double = 0
    var silentPassages = 0
    var repeatedBlocks = SoundEventLog()
    var clicks = SoundEventLog()
    var timingJumps = SoundEventLog()
    var largestTimingJumpSeconds: Double = 0

    /// Dropouts, replays and timing jumps — the stutter family.
    var stutterEvents: Int { dropouts.occurrences + repeatedBlocks.occurrences + timingJumps.occurrences }
}

// MARK: Detectors

/// Exact digital-zero runs across every channel.
struct SilenceRunTracker {
    private var runStart: Int?

    /// Feed one frame. Returns the run (start..<end, in frames) that just
    /// ended, if a sounding frame closed one.
    mutating func observe(silent: Bool, at frame: Int) -> Range<Int>? {
        if silent {
            if runStart == nil { runStart = frame }
            return nil
        }
        defer { runStart = nil }
        return runStart.map { $0..<frame }
    }
}

/// A non-silent block identical to the previous one = a replayed buffer.
struct BlockRepeatTracker {
    static let blockFrames = 1024
    /// Peak-to-peak below this (≈ −60 dBFS) is near-silence: constant DC or
    /// idle bits legitimately repeat, so they don't count.
    static let soundingPeakToPeak: Int64 = 2_147_483

    private let blockSamples: Int
    /// The last `blockSamples` samples (a ring ≈ C++ circular buffer).
    private var ring: [Int32]
    private var position = 0
    private var seen = 0
    /// Consecutive samples equal to the one exactly one block earlier.
    private var matching = 0
    private var low = Int32.max, high = Int32.min

    init(channels: Int) {
        blockSamples = Self.blockFrames * channels
        ring = Array(repeating: 0, count: blockSamples)
    }

    /// Feed one sample (interleaved order). True when this sample completes
    /// a full block that repeats the block before it.
    mutating func append(_ x: Int32) -> Bool {
        let same = seen >= blockSamples && ring[position] == x
        ring[position] = x
        position = position + 1 == blockSamples ? 0 : position + 1
        seen += 1
        guard same else {
            matching = 0
            low = .max
            high = .min
            return false
        }
        matching += 1
        low = min(low, x)
        high = max(high, x)
        guard matching == blockSamples else { return false }
        let sounding = Int64(high) - Int64(low) >= Self.soundingPeakToPeak
        matching = 0
        low = .max
        high = .min
        return sounding
    }
}

/// One channel: is the middle of the last three samples a click?
///
/// A digital click (a bit error, a glitched buffer edge) is one sample far
/// off the line its neighbours draw AND far above the programme around it.
/// Calibrated on Brockton (2026-10-07): with only the first two tests, 43
/// loud real transients (paper, cutlery: e ≈ 0.11–0.22 FS in audio peaking
/// at 0.2–0.5) read as clicks. All three tests together → none.
struct ClickTracker {
    /// Second difference this many times its own recent level…
    static let ratio = 25.0
    /// …at least half of full scale off the line (≈ −6 dBFS)…
    static let absolute = 0.5
    /// …and this many times the recent signal envelope (mean |x|).
    static let envelopeRatio = 4.0
    private static let fullScale = 2_147_483_648.0

    private var a: Int32 = 0, b: Int32 = 0
    private var seen = 0
    private var level = 0.0
    private var envelope = 0.0
    private let alpha: Double

    /// `sampleRate` sets the ~10 ms memory of both levels.
    init(sampleRate: Int) {
        alpha = 1 / max(1, 0.010 * Double(sampleRate))
    }

    /// Feed one sample; true when the PREVIOUS sample was a click.
    mutating func observe(_ x: Int32) -> Bool {
        defer { a = b; b = x; seen += 1 }
        guard seen >= 2 else { return false }
        let e = abs(Double(b) - (Double(a) + Double(x)) / 2) / Self.fullScale
        let isClick = e > Self.absolute && e > Self.ratio * level && e > Self.envelopeRatio * envelope
        level += (e - level) * alpha
        envelope += (abs(Double(a)) / Self.fullScale - envelope) * alpha
        return isClick
    }
}

/// Decoded-frame timestamps (pts in samples) → gaps and overlaps.
struct SoundTimeline {
    private var expected: Int64?

    /// A jump in samples (+ gap, − overlap) beyond `tolerance`, else nil.
    mutating func observe(pts: Int64, samples: Int, tolerance: Int64) -> Int64? {
        defer { expected = pts + Int64(samples) }
        guard let expected else { return nil }
        let jump = pts - expected
        return abs(jump) > tolerance ? jump : nil
    }

    /// `ashowinfo` line → (pts, nb_samples); nil for any other line.
    static func frame(fromShowInfo line: String) -> (pts: Int64, samples: Int)? {
        guard line.contains("nb_samples:"),
              let pts = MediaSignalScan.token(after: " pts:", in: line).flatMap({ Int64($0) }),
              let n = MediaSignalScan.int(after: "nb_samples:", in: line) else { return nil }
        return (pts, n)
    }
}

// MARK: The analyzer

/// Streams raw interleaved s32le PCM and `ashowinfo` lines into the
/// detectors. A value type — wrap it in `SoundContinuityTally` to share it
/// across the pipe threads.
struct SoundContinuityAnalyzer {
    static let maxChannels = 32
    static let edgeSeconds = 0.100
    static let dropoutMin = 0.005
    static let dropoutMax = 2.0
    /// Two ms of timing slack: mkv stores times to the millisecond.
    static let timingToleranceSeconds = 0.002

    private enum Kind { case dropout, repeated, click }
    private struct Pending { var kind: Kind; var startFrame: Int; var endFrame: Int }

    let channels: Int
    let sampleRate: Int
    private var silence = SilenceRunTracker()
    private var blocks: BlockRepeatTracker
    private var clickers: [ClickTracker]
    private var timeline = SoundTimeline()
    private var carry = Data()
    private var frame = 0
    private var lastClickFrame = Int.min / 2
    private var pending: [Pending] = []
    private(set) var report = SoundContinuityReport()

    init(channels: Int, sampleRate: Int) {
        self.channels = min(max(channels, 1), Self.maxChannels)
        self.sampleRate = max(sampleRate, 1)
        blocks = BlockRepeatTracker(channels: self.channels)
        clickers = Array(repeating: ClickTracker(sampleRate: self.sampleRate), count: self.channels)
    }

    private var edgeFrames: Int { Int(Self.edgeSeconds * Double(sampleRate)) }
    private func seconds(_ f: Int) -> Double { Double(f) / Double(sampleRate) }

    // MARK: Samples

    mutating func consume(_ data: Data) {
        carry.append(data)
        let frameBytes = 4 * channels
        let whole = carry.count / frameBytes * frameBytes
        guard whole > 0 else { return }
        carry.withUnsafeBytes { raw in
            var offset = 0
            while offset < whole {
                consumeFrame(raw, at: offset)
                offset += frameBytes
            }
        }
        carry.removeFirst(whole)
        commit(throughFrame: frame - edgeFrames)
    }

    private mutating func consumeFrame(_ raw: UnsafeRawBufferPointer, at offset: Int) {
        var silent = true
        var repeated = false
        var click = false
        for ch in 0..<channels {
            // s32le → Int32 (≈ C++ memcpy of a little-endian int32).
            let x = Int32(littleEndian: raw.loadUnaligned(fromByteOffset: offset + 4 * ch, as: Int32.self))
            if x != 0 { silent = false }
            if blocks.append(x) { repeated = true }
            if clickers[ch].observe(x) { click = true }
        }
        if let run = silence.observe(silent: silent, at: frame) { noteSilence(run) }
        if repeated { enqueue(.repeated, frame + 1 - BlockRepeatTracker.blockFrames, frame + 1) }
        if click, frame - lastClickFrame > sampleRate / 20 {   // ≤ one click per 50 ms
            lastClickFrame = frame
            enqueue(.click, frame - 1, frame)
        }
        frame += 1
    }

    private mutating func noteSilence(_ run: Range<Int>) {
        let length = seconds(run.count)
        if length >= Self.dropoutMax {
            report.silentPassages += 1
        } else if length >= Self.dropoutMin {
            enqueue(.dropout, run.lowerBound, run.upperBound)
        }
    }

    private mutating func enqueue(_ kind: Kind, _ start: Int, _ end: Int) {
        guard start >= edgeFrames else { return }
        pending.append(Pending(kind: kind, startFrame: start, endFrame: end))
    }

    /// Events that ended at least 100 ms ago are no longer "the tail".
    private mutating func commit(throughFrame limit: Int) {
        while let first = pending.first, first.endFrame <= limit {
            pending.removeFirst()
            let t = seconds(first.startFrame)
            switch first.kind {
            case .dropout:
                report.dropouts.note(t)
                report.longestDropoutSeconds = max(report.longestDropoutSeconds,
                                                   seconds(first.endFrame - first.startFrame))
            case .repeated: report.repeatedBlocks.note(t)
            case .click: report.clicks.note(t)
            }
        }
    }

    // MARK: Timestamps

    /// Returns the frame's time in seconds (for progress), nil for other lines.
    @discardableResult
    mutating func consume(showInfoLine line: String) -> Double? {
        guard let f = SoundTimeline.frame(fromShowInfo: line) else { return nil }
        let tolerance = Int64(Self.timingToleranceSeconds * Double(sampleRate))
        if let jump = timeline.observe(pts: f.pts, samples: f.samples, tolerance: tolerance) {
            report.timingJumps.note(Double(f.pts) / Double(sampleRate))
            report.largestTimingJumpSeconds = max(report.largestTimingJumpSeconds,
                                                  Double(abs(jump)) / Double(sampleRate))
        }
        return Double(f.pts) / Double(sampleRate)
    }

    /// End of stream: whatever is still pending is in the last 100 ms (or
    /// a silence that ran to the end) — dropped by design.
    mutating func finish() -> SoundContinuityReport {
        report.seconds = seconds(frame)
        pending.removeAll()
        return report
    }
}

/// Thread-safe wrapper: PCM chunks arrive on stdout's reader thread and
/// `ashowinfo` lines on stderr's. (≈ C++: the struct + a std::mutex.)
final class SoundContinuityTally: @unchecked Sendable {
    private let lock = NSLock()
    private var analyzer: SoundContinuityAnalyzer

    init(channels: Int, sampleRate: Int) {
        analyzer = SoundContinuityAnalyzer(channels: channels, sampleRate: sampleRate)
    }

    func consume(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        analyzer.consume(data)
    }

    /// The frame's time in seconds, nil for any other line.
    func consume(showInfoLine line: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return analyzer.consume(showInfoLine: line)
    }

    func finish() -> SoundContinuityReport {
        lock.lock(); defer { lock.unlock() }
        return analyzer.finish()
    }
}

// MARK: - The rule

extension CheckMediaRules {

    /// Stutter-family events (dropouts + replays + timing jumps) at or
    /// above this many make it a Problem; fewer, a Warning.
    static let continuityProblemEvents = 3

    static func checkSoundContinuity(_ result: Result<SoundContinuityReport, CheckMediaSkip>?,
                                     facts: MediaFacts) -> MediaCheck {
        guard facts.audio != nil else { return .notRun(.soundContinuity, because: "this file has no sound track") }
        guard let result else { return .notRun(.soundContinuity, because: "the sound pass did not run") }
        let r: SoundContinuityReport
        switch result {
        case .failure(let skip): return .notRun(.soundContinuity, because: skip.reason)
        case .success(let report): r = report
        }
        let evidence = continuityEvidence(r)
        let found = continuityFindings(r)
        guard !found.isEmpty else {
            return MediaCheck(kind: .soundContinuity, verdict: .ok,
                              sentence: "Every sample decoded: no dropouts, no replayed sound, no clicks, no timing gaps.",
                              evidence: evidence)
        }
        let verdict: MediaCheckVerdict = r.stutterEvents >= continuityProblemEvents ? .problem : .warning
        return MediaCheck(kind: .soundContinuity, verdict: verdict,
                          sentence: "The sound breaks up: \(found.joined(separator: "; ")).",
                          evidence: evidence,
                          fix: "Listen at the times shown. If it skips there, look for another copy; dropouts and replays can't be repaired without the original.")
    }

    private static func continuityFindings(_ r: SoundContinuityReport) -> [String] {
        var out: [String] = []
        if r.dropouts.occurrences >= 1 { out.append(countWords(r.dropouts.occurrences, "dropout", "to digital silence")) }
        if r.repeatedBlocks.occurrences >= 1 { out.append(countWords(r.repeatedBlocks.occurrences, "replayed stretch", "of sound")) }
        if r.timingJumps.occurrences >= 1 { out.append(countWords(r.timingJumps.occurrences, "jump", "in the sound's timing")) }
        if r.clicks.occurrences >= 1 { out.append(countWords(r.clicks.occurrences, "click", "")) }
        return out
    }

    private static func countWords(_ n: Int, _ noun: String, _ tail: String) -> String {
        let plural = n == 1 ? noun : (noun.hasSuffix("ch") ? noun + "es" : noun + "s")
        return "\(V.groupedInt(n)) \(plural)" + (tail.isEmpty ? "" : " \(tail)")
    }

    private static func continuityEvidence(_ r: SoundContinuityReport) -> [MediaEvidence] {
        var e = [MediaEvidence("Listened to", V.durationText(r.seconds))]
        let logs: [(String, SoundEventLog)] = [("Dropouts", r.dropouts), ("Replayed blocks", r.repeatedBlocks),
                                               ("Timing jumps", r.timingJumps), ("Clicks", r.clicks)]
        for (label, log) in logs {
            e.append(MediaEvidence(label, log.occurrences < 1 ? "0" : "\(V.groupedInt(log.occurrences)) at \(log.timesText)"))
        }
        if r.longestDropoutSeconds > 0 {
            e.append(MediaEvidence("Longest dropout", String(format: "%.0f ms", r.longestDropoutSeconds * 1000)))
        }
        if r.silentPassages > 0 { e.append(MediaEvidence("Silent passages (≥ 2 s)", V.groupedInt(r.silentPassages))) }
        return e
    }
}
