// AudioFingerprintMatcher.swift (VideoScanCore)
// ONE SENTENCE: given a master's fingerprint and a query's, find the time
// offset at which their landmarks line up and say what that means — same
// recording, clip of the master, master inside the query, partial overlap,
// or different.
//
// HOW: `AudioFingerprintIndex` turns the master into hash → [anchor frame].
// For a query, every landmark whose hash the master knows votes for
// `tMaster − tQuery` (the offset of the query inside the master, in
// frames). Landmarks from the same recording agree on ONE offset; random
// hash collisions scatter. The tallest bin (±offsetToleranceFrames) wins.
// (For Rick: a Hough transform with a single parameter, the time offset.)
//
// From the winning offset the match reports, in seconds:
//   offset    — the query's start inside the master (negative: the query
//               starts before the master does), centroid of the winning bins;
//   coverage  — of the 1-s buckets of the query that lie inside the master
//               at that offset, the fraction with at least one matched
//               landmark (a clip is "found" when most of it is found);
//   density   — matched ÷ query landmarks (a raw score, for the report);
//   span      — the longest run of matched seconds, gaps ≤ bucketGapSeconds
//               bridged (what "overlap" means for a partial match).
//
// `AudioMatchVerdict` is a pure function of those numbers and
// `AudioMatchPolicy` — every threshold has a name and lives in that one
// struct, so tuning is data. No I/O here; everything is a value.
//
// MEMORY: the index is one dictionary of ≈ 8 B per landmark plus overhead
// (a 60-min master ≈ 1 M landmarks ≈ 40 MB); the histogram is one Int per
// possible frame offset (query + master frames, ≈ 8 B each).

import Foundation

/// Every threshold of the verdict, in one place.
public struct AudioMatchPolicy: Sendable, Equatable {
    /// Fewer matched landmarks than this is noise, whatever the shape.
    public var minMatchedLandmarks: Int = 20
    /// Coverage at or above this makes the overlap a confirmed copy.
    public var minCoverage: Double = 0.5
    /// A file "lies inside" the overlap when it hangs out by at most this.
    public var edgeToleranceSeconds: Double = 1.5
    /// A matched run shorter than this is not called an overlap.
    public var minOverlapSeconds: Double = 5
    /// Unmatched seconds inside a run that do not break it.
    public var bucketGapSeconds: Double = 2
    /// ± frames merged into the winning offset bin (64 ms each).
    public var offsetToleranceFrames: Int = 1
    /// A landmark's `dt` is also probed at ± this many frames: a clip cut
    /// off the master's frame grid sees a peak that straddles a frame
    /// boundary land one frame early or late. 0 = exact hashes only.
    public var deltaFrameTolerance: Int = 1

    public init() {}
    public static let `default` = AudioMatchPolicy()
}

public enum AudioMatchVerdict: Sendable, Equatable {
    /// Both files cover each other: the same recording (any encoding).
    case sameRecording
    /// The query is a clip of the master, starting `offsetSeconds` in.
    case containedInMaster(offsetSeconds: Double)
    /// The master is a clip of the query, starting `offsetSeconds` in.
    case masterContainedInQuery(offsetSeconds: Double)
    /// They share `seconds` of recording; the query starts at
    /// `offsetSeconds` in the master's timeline (may be negative).
    case overlap(offsetSeconds: Double, seconds: Double)
    case different
    /// No verdict can honestly be given; `reason` says why. Never a claim
    /// about the recordings.
    case inconclusive(reason: AudioMatchInconclusiveReason)
}

public enum AudioMatchInconclusiveReason: Sendable, Equatable {
    /// The two fingerprints were made by different recipes (or grids) and
    /// their hashes do not mean the same thing. Re-fingerprint one side.
    case incompatibleRecipe(query: UInt32, master: UInt32)
}

/// The numbers a verdict is judged on — kept separate from the verdict so
/// the rule is testable without a fingerprint.
public struct AudioMatchEvidence: Sendable, Equatable {
    public var matchedLandmarks: Int
    public var coverage: Double
    /// Seconds of the query that lie inside the master at the offset.
    public var overlapSeconds: Double
    /// Longest matched run, in seconds.
    public var spanSeconds: Double
    public var offsetSeconds: Double
    public var queryDurationSeconds: Double
    public var masterDurationSeconds: Double

    public init(matchedLandmarks: Int, coverage: Double, overlapSeconds: Double, spanSeconds: Double,
                offsetSeconds: Double, queryDurationSeconds: Double, masterDurationSeconds: Double) {
        self.matchedLandmarks = matchedLandmarks
        self.coverage = coverage
        self.overlapSeconds = overlapSeconds
        self.spanSeconds = spanSeconds
        self.offsetSeconds = offsetSeconds
        self.queryDurationSeconds = queryDurationSeconds
        self.masterDurationSeconds = masterDurationSeconds
    }

    /// The pure rule. (For Rick: a decision table — read top to bottom,
    /// first row that applies wins.)
    public func verdict(policy: AudioMatchPolicy = .default) -> AudioMatchVerdict {
        guard matchedLandmarks >= policy.minMatchedLandmarks else { return .different }
        if coverage >= policy.minCoverage {
            let queryInside = overlapSeconds >= queryDurationSeconds - policy.edgeToleranceSeconds
            let masterInside = overlapSeconds >= masterDurationSeconds - policy.edgeToleranceSeconds
            switch (queryInside, masterInside) {
            case (true, true): return .sameRecording
            case (true, false): return .containedInMaster(offsetSeconds: offsetSeconds)
            case (false, true): return .masterContainedInQuery(offsetSeconds: -offsetSeconds)
            case (false, false): return .overlap(offsetSeconds: offsetSeconds, seconds: overlapSeconds)
            }
        }
        if spanSeconds >= policy.minOverlapSeconds {
            return .overlap(offsetSeconds: offsetSeconds, seconds: spanSeconds)
        }
        return .different
    }
}

public struct AudioMatch: Sendable, Equatable {
    public let evidence: AudioMatchEvidence
    public let verdict: AudioMatchVerdict
    public let queryLandmarks: Int
    public let masterLandmarks: Int
    /// Where the longest matched run sits in the master's timeline.
    public let spanStartInMasterSeconds: Double
    public let spanEndInMasterSeconds: Double

    public var offsetSeconds: Double { evidence.offsetSeconds }
    public var matchedLandmarks: Int { evidence.matchedLandmarks }
    public var coverage: Double { evidence.coverage }
    public var density: Double { queryLandmarks > 0 ? Double(matchedLandmarks) / Double(queryLandmarks) : 0 }
    public var spanSeconds: Double { evidence.spanSeconds }
}

/// The master's landmarks, inverted: hash → anchor frames. Build once,
/// match many queries against it.
public struct AudioFingerprintIndex: Sendable {
    public let master: AudioFingerprint
    private let postings: [UInt32: [UInt32]]

    public init(master: AudioFingerprint) {
        self.master = master
        var table: [UInt32: [UInt32]] = [:]
        table.reserveCapacity(master.landmarkCount)
        for (hash, time) in zip(master.hashes, master.times) {
            table[hash, default: []].append(time)
        }
        self.postings = table
    }

    public var distinctHashes: Int { postings.count }

    public func match(_ query: AudioFingerprint, policy: AudioMatchPolicy = .default) -> AudioMatch {
        guard query.recipeMatches(master) else {
            return Self.noMatch(query: query, master: master, policy: policy,
                                verdict: .inconclusive(reason: .incompatibleRecipe(query: query.recipeID,
                                                                                   master: master.recipeID)))
        }
        let hop = query.hopSeconds
        let queryFrames = Int(query.durationSeconds / hop) + 1
        let masterFrames = Int(master.durationSeconds / hop) + 1
        // Offset bin index = (tMaster − tQuery) + queryFrames, so negative
        // offsets (the query starts first) have a home too.
        let binCount = queryFrames + masterFrames + 1
        var histogram = [Int](repeating: 0, count: binCount)
        for (hash, time) in zip(query.hashes, query.times) {
            forEachPosting(of: hash, deltaTolerance: policy.deltaFrameTolerance) { t in
                let bin = Int(t) - Int(time) + queryFrames
                if bin >= 0, bin < binCount { histogram[bin] += 1 }
            }
        }
        let tolerance = policy.offsetToleranceFrames
        let best = Self.bestWindow(histogram, tolerance: tolerance)
        guard best.votes > 0 else {
            return Self.noMatch(query: query, master: master, policy: policy)
        }
        // Centroid of the winning bins, in frames, then seconds.
        var weighted = 0, votes = 0
        for bin in max(0, best.centre - tolerance)...min(binCount - 1, best.centre + tolerance) {
            weighted += histogram[bin] * (bin - queryFrames)
            votes += histogram[bin]
        }
        let offsetFrames = Double(weighted) / Double(votes)
        let offsetSeconds = offsetFrames * hop

        // Second pass: which query landmarks sit in the winning bins, and
        // which seconds of the query they cover.
        let bucketCount = Int(query.durationSeconds.rounded(.up)) + 1
        var covered = [Bool](repeating: false, count: bucketCount)
        var matched = 0
        for (hash, time) in zip(query.hashes, query.times) {
            var hit = false
            forEachPosting(of: hash, deltaTolerance: policy.deltaFrameTolerance) { t in
                if abs(Int(t) - Int(time) + queryFrames - best.centre) <= tolerance { hit = true }
            }
            if hit {
                matched += 1
                let bucket = Int(Double(time) * hop)
                if bucket < bucketCount { covered[bucket] = true }
            }
        }
        let overlap = Self.overlapRange(offsetSeconds: offsetSeconds, queryDuration: query.durationSeconds,
                                        masterDuration: master.durationSeconds)
        let coverage = Self.coverage(covered, overlap: overlap)
        let run = Self.longestRun(covered, overlap: overlap, gap: Int(policy.bucketGapSeconds))
        let evidence = AudioMatchEvidence(
            matchedLandmarks: matched, coverage: coverage,
            overlapSeconds: max(0, overlap.upperBound - overlap.lowerBound), spanSeconds: Double(run.length),
            offsetSeconds: offsetSeconds, queryDurationSeconds: query.durationSeconds,
            masterDurationSeconds: master.durationSeconds)
        return AudioMatch(evidence: evidence, verdict: evidence.verdict(policy: policy),
                          queryLandmarks: query.landmarkCount, masterLandmarks: master.landmarkCount,
                          spanStartInMasterSeconds: Double(run.start) + offsetSeconds,
                          spanEndInMasterSeconds: Double(run.start + run.length) + offsetSeconds)
    }

    /// The master's anchor frames for `hash`, and for the hashes whose
    /// `dt` differs by up to `deltaTolerance` (dt is the low 6 bits, so
    /// hash ± k is dt ± k while it stays inside 1…63).
    private func forEachPosting(of hash: UInt32, deltaTolerance: Int, _ body: (UInt32) -> Void) {
        let dt = Int(hash & 0x3F)
        for delta in -deltaTolerance...deltaTolerance {
            let probedDT = dt + delta
            guard probedDT >= 1, probedDT <= 63, let times = postings[UInt32(Int(hash) + delta)] else { continue }
            for t in times { body(t) }
        }
    }

    private static func noMatch(query: AudioFingerprint, master: AudioFingerprint,
                                policy: AudioMatchPolicy, verdict: AudioMatchVerdict = .different) -> AudioMatch {
        let evidence = AudioMatchEvidence(matchedLandmarks: 0, coverage: 0, overlapSeconds: 0, spanSeconds: 0,
                                          offsetSeconds: 0, queryDurationSeconds: query.durationSeconds,
                                          masterDurationSeconds: master.durationSeconds)
        return AudioMatch(evidence: evidence, verdict: verdict, queryLandmarks: query.landmarkCount,
                          masterLandmarks: master.landmarkCount, spanStartInMasterSeconds: 0,
                          spanEndInMasterSeconds: 0)
    }

    /// The bin whose ±tolerance window holds the most votes.
    static func bestWindow(_ histogram: [Int], tolerance: Int) -> (centre: Int, votes: Int) {
        var best = (centre: 0, votes: 0)
        guard !histogram.isEmpty else { return best }
        var window = 0
        for i in 0..<min(histogram.count, tolerance) { window += histogram[i] }
        for centre in 0..<histogram.count {
            let incoming = centre + tolerance
            if incoming < histogram.count { window += histogram[incoming] }
            let outgoing = centre - tolerance - 1
            if outgoing >= 0 { window -= histogram[outgoing] }
            if window > best.votes { best = (centre, window) }
        }
        return best
    }

    /// The part of the query (in query seconds) that lies inside the master.
    static func overlapRange(offsetSeconds: Double, queryDuration: Double,
                             masterDuration: Double) -> Range<Double> {
        let lower = max(0, -offsetSeconds)
        let upper = min(queryDuration, masterDuration - offsetSeconds)
        return upper > lower ? lower..<upper : lower..<lower
    }

    private static func bucketRange(_ covered: [Bool], overlap: Range<Double>) -> Range<Int> {
        let lower = max(0, Int(overlap.lowerBound))
        let upper = min(covered.count, Int(overlap.upperBound.rounded(.up)))
        return upper > lower ? lower..<upper : lower..<lower
    }

    static func coverage(_ covered: [Bool], overlap: Range<Double>) -> Double {
        let buckets = bucketRange(covered, overlap: overlap)
        guard !buckets.isEmpty else { return 0 }
        let hits = covered[buckets].reduce(0) { $0 + ($1 ? 1 : 0) }
        return Double(hits) / Double(buckets.count)
    }

    /// Longest run of covered buckets inside the overlap, bridging up to
    /// `gap` uncovered buckets. Returns (start bucket, length in buckets).
    static func longestRun(_ covered: [Bool], overlap: Range<Double>, gap: Int) -> (start: Int, length: Int) {
        let buckets = bucketRange(covered, overlap: overlap)
        var best = (start: 0, length: 0)
        var runStart: Int?
        var lastHit = 0
        for bucket in buckets {
            if covered[bucket] {
                if runStart == nil { runStart = bucket }
                lastHit = bucket
            } else if let start = runStart, bucket - lastHit > gap {
                if lastHit - start + 1 > best.length { best = (start, lastHit - start + 1) }
                runStart = nil
            }
        }
        if let start = runStart, lastHit - start + 1 > best.length { best = (start, lastHit - start + 1) }
        return best
    }
}

public enum AudioFingerprintMatcher {
    /// One-shot convenience; build an `AudioFingerprintIndex` to match many
    /// queries against the same master.
    public static func match(query: AudioFingerprint, master: AudioFingerprint,
                             policy: AudioMatchPolicy = .default) -> AudioMatch {
        AudioFingerprintIndex(master: master).match(query, policy: policy)
    }
}
