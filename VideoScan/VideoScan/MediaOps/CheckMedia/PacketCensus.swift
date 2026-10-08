import Foundation

// MARK: - Check Media — the full packet census (2026-10-07)
//
// Full tier. Every packet of the picture, then every packet of the sound,
// streamed line by line from ffprobe (CheckMediaProbe+Census.swift) into
// small single-job tallies:
//
//   * StreamTimingTally — per stream: dts going backwards, gaps between
//     packets, first and last times (→ the sync row).
//   * KeyframeTally     — picture keyframe count and the longest gap.
//   * DataRateTally     — picture bytes per second of the file's time:
//     whole seconds with no picture data at all, and the spread.
//   * PictureIndex      — where (byte) the picture for each ¼ s is stored;
//     the sound pass then measures, for EVERY sound packet, how far it sits
//     from its picture: the full-file version of the quick Layout sample.
//
// One stream per ffprobe run (`-select_streams`): ffprobe discards the
// other streams, so on a non-interleaved mov the demuxer reads each stream
// straight through instead of seeking between the two ends of the file
// for every packet (the Brockton stutter, again).
//
// Memory (worst case): PictureIndex 8 B per ¼ s, capped at 800,000
// buckets (55 h) = 6.4 MB; DataRateTally 8 B per second, capped at 200,000
// s = 1.6 MB; everything else O(1). A 2 h tape: ≈ 290 KB.

/// One `-of compact=p=0` packet line with
/// `packet=pts_time,dts_time,duration_time,size,pos,flags`.
struct CensusPacket: Sendable, Equatable {
    var pts: Double?
    var dts: Double?
    var duration: Double?
    var size = 0
    var pos: Int64?
    var isKey = false

    var time: Double? { dts ?? pts }

    static func parse(_ line: String) -> CensusPacket? {
        guard let row = MediaPacketRow.rows(fromCompact: line).first else { return nil }
        let flags = MediaSignalScan.token(after: "flags=", in: line) ?? ""
        return CensusPacket(pts: row.pts, dts: row.dts, duration: row.duration, size: row.size,
                            pos: row.pos, isKey: flags.hasPrefix("K"))
    }
}

/// Timing health of one stream.
struct StreamTimingTally: Sendable, Equatable {
    var packets = 0
    var firstSeconds: Double?
    var endSeconds: Double?
    var backwards = MediaEventLog()
    var gaps = MediaEventLog()
    var largestGapSeconds = 0.0
    private var lastDTS: Double?
    private var expected: Double?

    /// A jump past the expected next packet this big is a gap.
    static func gapLimit(duration: Double?) -> Double { max(0.5, 3 * (duration ?? 0)) }

    mutating func observe(_ p: CensusPacket) {
        guard let t = p.time else { return }
        packets += 1
        // Only DECODE times must rise; presentation times reorder with
        // B-frames, so a stream without dts is never called "backwards".
        if let d = p.dts {
            if let last = lastDTS, d < last - 1e-6 { backwards.note(d) }
            lastDTS = d
        }
        if let next = expected, t - next > Self.gapLimit(duration: p.duration) {
            gaps.note(next)
            largestGapSeconds = max(largestGapSeconds, t - next)
        }
        expected = max(expected ?? t, t + (p.duration ?? 0))
        let shown = p.pts ?? t
        firstSeconds = min(firstSeconds ?? shown, shown)
        endSeconds = max(endSeconds ?? shown, shown + (p.duration ?? 0))
    }
}

/// Picture keyframes.
struct KeyframeTally: Sendable, Equatable {
    var packets = 0
    var keyframes = 0
    var longestGapSeconds = 0.0
    var longestGapAt: Double?
    private var lastKey: Double?

    mutating func observe(_ p: CensusPacket) {
        packets += 1
        guard p.isKey, let t = p.pts ?? p.dts else { return }
        keyframes += 1
        if let last = lastKey, t - last > longestGapSeconds {
            longestGapSeconds = t - last
            longestGapAt = last
        }
        lastKey = max(lastKey ?? t, t)
    }
}

/// Picture bytes per whole second of the file's time.
struct DataRateTally: Sendable, Equatable {
    static let maxSeconds = 200_000
    var bytes: [Int64] = []

    mutating func observe(_ p: CensusPacket) {
        guard let t = p.time, t >= 0, t < Double(Self.maxSeconds) else { return }
        let s = Int(t)
        if s >= bytes.count { bytes += Array(repeating: 0, count: s - bytes.count + 1) }
        bytes[s] += Int64(p.size)
    }

    /// Whole seconds (not the first or last) with no picture data at all.
    var emptySeconds: MediaEventLog {
        var log = MediaEventLog()
        guard bytes.count > 2 else { return log }
        for s in 1..<(bytes.count - 1) where bytes[s] == 0 { log.note(Double(s)) }
        return log
    }

    /// Lowest / median / highest bits per second over the interior seconds.
    var spread: (low: Int64, median: Int64, high: Int64)? {
        guard bytes.count > 2 else { return nil }
        let inner = bytes[1..<(bytes.count - 1)].sorted()
        guard let low = inner.first, let high = inner.last else { return nil }
        return (low * 8, inner[inner.count / 2] * 8, high * 8)
    }
}

/// Byte position of the picture, per ¼ s of time.
struct PictureIndex: Sendable, Equatable {
    static let bucketsPerSecond = 4.0
    static let maxBuckets = 800_000
    private var positions: [Int64] = []

    private func bucket(_ t: Double) -> Int? {
        guard t >= 0 else { return nil }
        let b = Int(t * Self.bucketsPerSecond)
        return b < Self.maxBuckets ? b : nil
    }

    mutating func note(_ p: CensusPacket) {
        guard let t = p.pts ?? p.dts, let pos = p.pos, let b = bucket(t) else { return }
        if b >= positions.count { positions += Array(repeating: -1, count: b - positions.count + 1) }
        if positions[b] < 0 { positions[b] = pos }
    }

    /// The picture stored for time `t`: its bucket, else the nearest
    /// filled one within ±2 s.
    func position(near t: Double) -> Int64? {
        guard let b = bucket(t) else { return nil }
        for d in 0...8 {
            for c in [b - d, b + d] where c >= 0 && c < positions.count && positions[c] >= 0 {
                return positions[c]
            }
        }
        return nil
    }
}

/// Every sound packet's distance from its picture.
struct FullLayoutTally: Sendable, Equatable {
    var soundPackets = 0
    var farApart = 0
    var maxDistance: Int64 = 0
    var firstFarAt: Double?

    mutating func observe(_ p: CensusPacket, index: PictureIndex, farBytes: Int64) {
        guard let t = p.pts ?? p.dts, let pos = p.pos, let picture = index.position(near: t) else { return }
        soundPackets += 1
        let d = abs(pos - picture)
        maxDistance = max(maxDistance, d)
        guard d > farBytes else { return }
        farApart += 1
        if firstFarAt == nil { firstFarAt = t }
    }

    var farShare: Double { soundPackets > 0 ? Double(farApart) / Double(soundPackets) : 0 }
}

/// What the census found.
struct PacketCensusReport: Sendable, Equatable {
    var video: StreamTimingTally?
    var audio: StreamTimingTally?
    var keyframes: KeyframeTally?
    var dataRate: DataRateTally?
    var layout: FullLayoutTally?
}

/// Builds the report as lines stream in: the picture run first (it fills
/// the index), then the sound run. The tallies are mutated IN PLACE (stored
/// properties, never copied out and back) — copying the per-second array
/// out of an optional on every packet would be O(n²) copy-on-write.
struct PacketCensus {
    private var video = StreamTimingTally()
    private var audio = StreamTimingTally()
    private var keyframes = KeyframeTally()
    private var dataRate = DataRateTally()
    private var layout = FullLayoutTally()
    private var index = PictureIndex()

    /// Returns the packet's time (for progress), nil for other lines.
    mutating func notePicture(line: String) -> Double? {
        guard let p = CensusPacket.parse(line) else { return nil }
        video.observe(p)
        keyframes.observe(p)
        dataRate.observe(p)
        index.note(p)
        return p.time
    }

    mutating func noteSound(line: String) -> Double? {
        guard let p = CensusPacket.parse(line) else { return nil }
        audio.observe(p)
        layout.observe(p, index: index, farBytes: CheckMediaRules.layoutApartBytes)
        return p.time
    }

    /// Streams that had no packets come back nil.
    var report: PacketCensusReport {
        let hasPicture = video.packets > 0
        return PacketCensusReport(video: hasPicture ? video : nil,
                                  audio: audio.packets > 0 ? audio : nil,
                                  keyframes: hasPicture ? keyframes : nil,
                                  dataRate: hasPicture ? dataRate : nil,
                                  layout: layout.soundPackets > 0 ? layout : nil)
    }
}

/// Thread-safe wrapper for the reader thread. (≈ C++: struct + mutex.)
final class PacketCensusTally: @unchecked Sendable {
    private let lock = NSLock()
    private var census = PacketCensus()

    func notePicture(_ line: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return census.notePicture(line: line)
    }

    func noteSound(_ line: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return census.noteSound(line: line)
    }

    var report: PacketCensusReport {
        lock.lock(); defer { lock.unlock() }
        return census.report
    }
}
