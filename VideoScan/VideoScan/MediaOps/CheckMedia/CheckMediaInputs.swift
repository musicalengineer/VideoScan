import Foundation

// MARK: - Check Media — what the probe measured (Rick 2026-10-07)
//
// The rules' inputs as plain values, plus their pure parsers. The probe
// (CheckMediaProbe.swift) runs ffprobe/ffmpeg and hands text here; tests
// hand canned text. Nothing in this file touches the disk.
//
// Memory: every type here is O(1) in the file's size — packet windows are
// summarized, not kept (≤ 3 × 300 short rows while summarizing), and the
// signal tally keeps running sums only.

/// One packet line from `ffprobe -of compact=p=0` with
/// `packet=pts_time,dts_time,duration_time,size,pos`. Any field may be N/A.
struct MediaPacketRow: Sendable, Equatable {
    var pts: Double?
    var dts: Double?
    var duration: Double?
    var size: Int
    var pos: Int64?

    /// The VerifyVideoRules row, so its sample/merge rules are reused as is.
    var verifyRow: VerifyVideoRules.PacketRow {
        VerifyVideoRules.PacketRow(pts: pts, dts: dts, size: size)
    }

    static func rows(fromCompact text: String) -> [MediaPacketRow] {
        text.split(whereSeparator: \.isNewline).compactMap(row(fromLine:))
    }

    private static func row(fromLine line: Substring) -> MediaPacketRow? {
        var row = MediaPacketRow(size: -1)
        for field in line.split(separator: "|") {
            guard let eq = field.firstIndex(of: "=") else { continue }
            let value = String(field[field.index(after: eq)...])
            switch field[..<eq] {
            case "pts_time": row.pts = Double(value)
            case "dts_time": row.dts = Double(value)
            case "duration_time": row.duration = Double(value)
            case "size": row.size = Int(value) ?? -1
            case "pos": row.pos = Int64(value)
            default: break
            }
        }
        return row.size >= 0 ? row : nil
    }
}

/// The packet windows, summarized.
struct MediaPacketScan: Sendable, Equatable {
    /// Start/middle windows merged by VerifyVideoRules (order, gaps,
    /// tiny-packet share, the stored-frame rate).
    var sample: VideoPacketSample?
    /// Median of the packets' own durations (nil when the container
    /// doesn't record them).
    var medianDurationSeconds: Double?
    /// 90th ÷ 10th percentile of packet durations — the VFR spread.
    var durationSpread: Double?
    /// Byte where the last sampled packet ends (pos + size), from the
    /// window at the end of the file.
    var lastPacketEndByte: Int64?

    var packets: Int { sample?.packets ?? 0 }

    /// The step between frames: their recorded duration, else the median
    /// gap between presentation times.
    var medianStepSeconds: Double? {
        if let d = medianDurationSeconds, d > 0 { return d }
        if let d = sample?.medianDeltaSeconds, d > 0 { return d }
        return nil
    }

    static func summarize(windows: [[MediaPacketRow]], tail: [MediaPacketRow]) -> MediaPacketScan {
        var scan = MediaPacketScan()
        scan.sample = VerifyVideoRules.merge(windows.map {
            VerifyVideoRules.packetSample(from: $0.map(\.verifyRow))
        })
        let durations = windows.joined().compactMap(\.duration).filter { $0 > 0 }.sorted()
        if !durations.isEmpty {
            scan.medianDurationSeconds = durations[durations.count / 2]
            let p10 = durations[durations.count / 10]
            let p90 = durations[(durations.count * 9) / 10]
            if p10 > 0 { scan.durationSpread = p90 / p10 }
        }
        scan.lastPacketEndByte = (tail + windows.joined())
            .compactMap { r in r.pos.map { $0 + Int64(r.size) } }
            .max()
        return scan
    }
}

/// Short `mpdecimate` windows: how many decoded frames were really a new
/// picture. One window = `framesIn` frames from `offsetSeconds`.
struct DistinctFrameSample: Sendable, Equatable {
    struct Window: Sendable, Equatable {
        var offsetSeconds: Double
        var framesIn: Int
        var framesKept: Int
        var ratio: Double { framesIn > 0 ? Double(framesKept) / Double(framesIn) : 0 }
    }

    var windows: [Window]

    /// Frames per window the probe asks for, and the fewest that count.
    static let framesPerWindow = 300
    static let minimumFrames = 30

    var usable: [Window] { windows.filter { $0.framesIn >= Self.minimumFrames } }

    /// The MOST distinct window: a "mostly repeats" claim must hold
    /// everywhere we looked, not just in one still stretch.
    var bestRatio: Double? { usable.map(\.ratio).max() }

    /// `-progress` output → frames written (= frames mpdecimate kept).
    /// The last "frame=N" line wins; nil when there is none.
    static func framesWritten(fromProgress text: String) -> Int? {
        text.split(whereSeparator: \.isNewline).reversed().lazy
            .compactMap { line -> Int? in
                guard line.hasPrefix("frame=") else { return nil }
                return Int(line.dropFirst("frame=".count).trimmingCharacters(in: .whitespaces))
            }.first
    }
}

/// What the full decode's idet / blackdetect / freezedetect reported.
struct MediaSignalScan: Sendable, Equatable {
    var blackStretches = 0
    var blackSeconds: Double = 0
    var freezeStretches = 0
    var freezeSeconds: Double = 0
    /// idet multi-frame totals (the LAST report wins — ffmpeg prints one
    /// per filter-graph instance, the first often all zeros).
    var topFieldFirst = 0
    var bottomFieldFirst = 0
    var progressive = 0
    var undetermined = 0

    var idetJudged: Int { topFieldFirst + bottomFieldFirst + progressive }
    var interlacedShare: Double? {
        idetJudged > 0 ? Double(topFieldFirst + bottomFieldFirst) / Double(idetJudged) : nil
    }

    /// Fold one info-level stderr line in. Pure (returns the new value).
    func adding(line: String) -> MediaSignalScan {
        var s = self
        if let d = Self.number(after: "black_duration:", in: line) {
            s.blackStretches += 1
            s.blackSeconds += d
        } else if let d = Self.number(after: "freezedetect.freeze_duration:", in: line) {
            s.freezeStretches += 1
            s.freezeSeconds += d
        } else if line.contains("Multi frame detection:") {
            s.topFieldFirst = Self.int(after: "TFF:", in: line) ?? 0
            s.bottomFieldFirst = Self.int(after: "BFF:", in: line) ?? 0
            s.progressive = Self.int(after: "Progressive:", in: line) ?? 0
            s.undetermined = Self.int(after: "Undetermined:", in: line) ?? 0
        }
        return s
    }

    static func token(after key: String, in line: String) -> Substring? {
        guard let r = line.range(of: key) else { return nil }
        let rest = line[r.upperBound...].drop(while: { $0 == " " })
        return rest.prefix { !$0.isWhitespace }
    }

    static func number(after key: String, in line: String) -> Double? {
        token(after: key, in: line).flatMap { Double($0) }
    }

    static func int(after key: String, in line: String) -> Int? {
        token(after: key, in: line).flatMap { Int($0) }
    }
}

/// Thread-safe accumulator for the signal lines, which arrive on GCD
/// threads. (≈ C++: the struct above guarded by a std::mutex.)
final class MediaSignalTally: @unchecked Sendable {
    private let lock = NSLock()
    private var scan = MediaSignalScan()

    func note(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        scan = scan.adding(line: line)
    }

    var snapshot: MediaSignalScan {
        lock.lock(); defer { lock.unlock() }
        return scan
    }
}

/// Everything the quick tier measured.
struct CheckMediaQuickInputs: Sendable, Equatable {
    var facts: MediaFacts
    /// The same JSON read by VerifyVideoRules — one set of numbers.
    var videoFacts: VideoVerifyFacts
    var packets: MediaPacketScan?
    var distinct: DistinctFrameSample?
    /// Where sound and picture sit in the file (CheckMediaLayout.swift).
    var layout: MediaLayoutSample?
}

/// Everything the full tier measured. A nil diagnosis carries its reason.
struct CheckMediaFullInputs: Sendable {
    var video: Result<VideoVerifyDiagnosis, CheckMediaSkip>?
    var audio: Result<AudioVerifyDiagnosis, CheckMediaSkip>?
    var signals: MediaSignalScan?
    /// The streamed decode of every sound sample (SoundContinuity.swift).
    var continuity: Result<SoundContinuityReport, CheckMediaSkip>?
}

/// Why a full-tier pass produced no diagnosis — becomes a "not run" row.
struct CheckMediaSkip: Error, Sendable, Equatable {
    var reason: String
}
