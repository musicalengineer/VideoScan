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
//   coverage  — of the AUDIBLE 1-s buckets of the query that lie inside the
//               master at that offset, the fraction with at least one
//               matched landmark (silence is evidence for nothing);
//   gap       — the longest stretch of audible, unmatched query seconds in
//               the overlap (a minute of other audio is a different edit);
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
///
/// DECISION TABLE (`AudioMatchEvidence.verdict`; read top to bottom, the
/// first row that applies wins — every evidence tuple lands on exactly
/// one row):
///
///   1. matchedLandmarks < minMatchedLandmarks           → .different
///   2. spanSeconds < minOverlapSeconds                   → .different
///      (a demonstrated matched run shorter than this is noise on EVERY
///      branch — a 4-s query with 2 matched seconds is not "contained")
///   3. coverage < minCoverage
///      OR unmatchedGapSeconds > maxUnmatchedGapSeconds   → .overlap(offset, span)
///      (the match is real but not DISTRIBUTED over the audible query:
///      a stretch of audible, unmatched audio contradicts "same"/"contained")
///   4. geometry × completeness, with
///      queryInside  = overlap ≥ queryDuration − edgeTolerance
///      masterInside = overlap ≥ masterDuration − edgeTolerance:
///        inside both, both complete                      → .sameRecording
///        inside both, only master incomplete             → .containedInMaster
///        inside both, only query incomplete              → .masterContainedInQuery
///        inside both, both incomplete                    → .inconclusive(.bothIncomplete)
///        query inside, query complete                    → .containedInMaster
///        query inside, query incomplete                  → .inconclusive(.queryIncomplete)
///        master inside, master complete                  → .masterContainedInQuery
///        master inside, master incomplete                → .inconclusive(.masterIncomplete)
///        neither inside                                  → .overlap(offset, span)
///
/// `coverage` and `unmatchedGapSeconds` are measured over the query's
/// AUDIBLE seconds inside the overlap (`AudioFingerprint.activeSeconds`);
/// silent seconds are evidence for nothing and sit in neither numerator
/// nor denominator.
public struct AudioMatchPolicy: Sendable, Equatable {
    /// Fewer matched landmarks than this is noise, whatever the shape.
    public var minMatchedLandmarks: Int = 20
    /// Coverage (matched ÷ audible seconds of the overlap) at or above
    /// this is one condition for a confirmed copy; see the table.
    public var minCoverage: Double = 0.5
    /// A file "lies inside" the overlap when it hangs out by at most this.
    public var edgeToleranceSeconds: Double = 1.5
    /// A matched run shorter than this is not called anything (row 2).
    public var minOverlapSeconds: Double = 5
    /// Unmatched audible seconds inside a run that do not break it (span).
    public var bucketGapSeconds: Double = 2
    /// The longest stretch of audible, unmatched query seconds inside the
    /// overlap that "same" / "contained" tolerate (row 3). Longer = a
    /// different edit, not a lossy copy.
    public var maxUnmatchedGapSeconds: Double = 10
    /// ± frames merged into the winning offset bin (64 ms each).
    public var offsetToleranceFrames: Int = 1
    /// A landmark's `dt` is also probed at ± this many frames: a clip cut
    /// off the master's frame grid sees a peak that straddles a frame
    /// boundary land one frame early or late. 0 = exact hashes only.
    public var deltaFrameTolerance: Int = 1
    /// A hash the master holds more than this many times (a metronome
    /// click, a hum, a repeated jingle) is skipped: it says nothing about
    /// WHERE the query is, and walking it is the quadratic case. Bounds
    /// the work per query landmark at (2·deltaFrameTolerance + 1) × this.
    public var maxPostingsPerHash: Int = 64

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
    /// They share a matched run of `seconds`; the query starts at
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
    /// The evidence says "contained" or "same", but the side(s) named were
    /// only partly analysed (decoder cap or window), so the unseen rest
    /// could contradict it. The evidence (offset, span) is still reported.
    case queryIncomplete
    case masterIncomplete
    case bothIncomplete
}

/// The numbers a verdict is judged on — kept separate from the verdict so
/// the rule is testable without a fingerprint.
public struct AudioMatchEvidence: Sendable, Equatable {
    public var matchedLandmarks: Int
    /// Matched ÷ audible seconds of the query inside the overlap.
    public var coverage: Double
    /// Seconds of the query that lie inside the master at the offset.
    public var overlapSeconds: Double
    /// Longest matched run, in seconds.
    public var spanSeconds: Double
    public var offsetSeconds: Double
    public var queryDurationSeconds: Double
    public var masterDurationSeconds: Double
    /// `AudioFingerprint.complete` of each side: false = the duration above
    /// is the analysed part, not the recording.
    public var queryComplete: Bool
    public var masterComplete: Bool
    /// Longest stretch of audible, UNMATCHED query seconds inside the
    /// overlap (silent seconds skipped, not counted). 0 = none.
    public var unmatchedGapSeconds: Double

    public init(matchedLandmarks: Int, coverage: Double, overlapSeconds: Double, spanSeconds: Double,
                offsetSeconds: Double, queryDurationSeconds: Double, masterDurationSeconds: Double,
                queryComplete: Bool = true, masterComplete: Bool = true, unmatchedGapSeconds: Double = 0) {
        self.matchedLandmarks = matchedLandmarks
        self.coverage = coverage
        self.overlapSeconds = overlapSeconds
        self.spanSeconds = spanSeconds
        self.offsetSeconds = offsetSeconds
        self.queryDurationSeconds = queryDurationSeconds
        self.masterDurationSeconds = masterDurationSeconds
        self.queryComplete = queryComplete
        self.masterComplete = masterComplete
        self.unmatchedGapSeconds = unmatchedGapSeconds
    }

    /// The pure rule — the decision table in `AudioMatchPolicy`'s header.
    public func verdict(policy: AudioMatchPolicy = .default) -> AudioMatchVerdict {
        guard matchedLandmarks >= policy.minMatchedLandmarks else { return .different }          // row 1
        guard spanSeconds >= policy.minOverlapSeconds else { return .different }                // row 2
        let distributed = coverage >= policy.minCoverage && unmatchedGapSeconds <= policy.maxUnmatchedGapSeconds
        guard distributed else { return .overlap(offsetSeconds: offsetSeconds, seconds: spanSeconds) }  // row 3
        let queryInside = overlapSeconds >= queryDurationSeconds - policy.edgeToleranceSeconds
        let masterInside = overlapSeconds >= masterDurationSeconds - policy.edgeToleranceSeconds
        // Row 4. A side that was only partly analysed can be CONTAINED (its
        // analysed part lies inside the other) but can never be "the same"
        // or "containing" — the unseen rest might differ.
        switch (queryInside, masterInside, queryComplete, masterComplete) {
        case (true, true, true, true): return .sameRecording
        case (true, true, true, false): return .containedInMaster(offsetSeconds: offsetSeconds)
        case (true, true, false, true): return .masterContainedInQuery(offsetSeconds: -offsetSeconds)
        case (true, true, false, false): return .inconclusive(reason: .bothIncomplete)
        case (true, false, true, _): return .containedInMaster(offsetSeconds: offsetSeconds)
        case (true, false, false, _): return .inconclusive(reason: .queryIncomplete)
        case (false, true, _, true): return .masterContainedInQuery(offsetSeconds: -offsetSeconds)
        case (false, true, _, false): return .inconclusive(reason: .masterIncomplete)
        case (false, false, _, _): return .overlap(offsetSeconds: offsetSeconds, seconds: spanSeconds)
        }
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
            forEachPosting(of: hash, policy: policy) { t in
                let bin = Int(t) - Int(time) + queryFrames
                if bin >= 0, bin < binCount { histogram[bin] += 1 }
                return true
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
            forEachPosting(of: hash, policy: policy) { t in
                hit = abs(Int(t) - Int(time) + queryFrames - best.centre) <= tolerance
                return !hit   // one hit is enough; stop walking
            }
            if hit {
                matched += 1
                let bucket = Int(Double(time) * hop)
                if bucket < bucketCount { covered[bucket] = true }
            }
        }
        let overlap = Self.overlapRange(offsetSeconds: offsetSeconds, queryDuration: query.durationSeconds,
                                        masterDuration: master.durationSeconds)
        // Audible seconds of the query; unknown (empty) = every second counts.
        let active = query.activeSeconds.isEmpty
            ? [Bool](repeating: true, count: bucketCount)
            : query.activeSeconds + [Bool](repeating: false, count: max(0, bucketCount - query.activeSeconds.count))
        let coverage = Self.coverage(covered, active: active, overlap: overlap)
        let gap = Self.longestUnmatchedGap(covered, active: active, overlap: overlap)
        let run = Self.longestRun(covered, active: active, overlap: overlap, gap: Int(policy.bucketGapSeconds))
        let evidence = AudioMatchEvidence(
            matchedLandmarks: matched, coverage: coverage,
            overlapSeconds: max(0, overlap.upperBound - overlap.lowerBound), spanSeconds: Double(run.length),
            offsetSeconds: offsetSeconds, queryDurationSeconds: query.durationSeconds,
            masterDurationSeconds: master.durationSeconds,
            queryComplete: query.complete, masterComplete: master.complete, unmatchedGapSeconds: Double(gap))
        return AudioMatch(evidence: evidence, verdict: evidence.verdict(policy: policy),
                          queryLandmarks: query.landmarkCount, masterLandmarks: master.landmarkCount,
                          spanStartInMasterSeconds: Double(run.start) + offsetSeconds,
                          spanEndInMasterSeconds: Double(run.start + run.length) + offsetSeconds)
    }

    /// The master's anchor frames for `hash`, and for the hashes whose
    /// `dt` differs by up to `policy.deltaFrameTolerance` (dt is the low
    /// 6 bits, so hash ± k is dt ± k while it stays inside 1…63). Lists
    /// longer than `policy.maxPostingsPerHash` are skipped (see the
    /// policy); `body` returns false to stop the walk.
    private func forEachPosting(of hash: UInt32, policy: AudioMatchPolicy, _ body: (UInt32) -> Bool) {
        let dt = Int(hash & 0x3F)
        for delta in -policy.deltaFrameTolerance...policy.deltaFrameTolerance {
            let probedDT = dt + delta
            guard probedDT >= 1, probedDT <= 63, let times = postings[UInt32(Int(hash) + delta)],
                  times.count <= policy.maxPostingsPerHash else { continue }
            for t in times where !body(t) { return }
        }
    }

    private static func noMatch(query: AudioFingerprint, master: AudioFingerprint,
                                policy: AudioMatchPolicy, verdict: AudioMatchVerdict = .different) -> AudioMatch {
        let evidence = AudioMatchEvidence(matchedLandmarks: 0, coverage: 0, overlapSeconds: 0, spanSeconds: 0,
                                          offsetSeconds: 0, queryDurationSeconds: query.durationSeconds,
                                          masterDurationSeconds: master.durationSeconds,
                                          queryComplete: query.complete, masterComplete: master.complete)
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

    /// Matched ÷ audible buckets inside the overlap (0 when none audible).
    static func coverage(_ covered: [Bool], active: [Bool], overlap: Range<Double>) -> Double {
        let buckets = bucketRange(covered, overlap: overlap)
        var audible = 0, hits = 0
        for bucket in buckets where active[bucket] {
            audible += 1
            if covered[bucket] { hits += 1 }
        }
        return audible > 0 ? Double(hits) / Double(audible) : 0
    }

    /// Longest stretch of audible, unmatched buckets inside the overlap.
    /// Silent buckets neither break nor lengthen a stretch.
    static func longestUnmatchedGap(_ covered: [Bool], active: [Bool], overlap: Range<Double>) -> Int {
        var best = 0, run = 0
        for bucket in bucketRange(covered, overlap: overlap) where active[bucket] {
            run = covered[bucket] ? 0 : run + 1
            best = max(best, run)
        }
        return best
    }

    /// Longest run of covered buckets inside the overlap, bridging up to
    /// `gap` audible uncovered buckets (silent ones are transparent).
    /// Returns (start bucket, length in buckets on the real timeline).
    static func longestRun(_ covered: [Bool], active: [Bool], overlap: Range<Double>,
                           gap: Int) -> (start: Int, length: Int) {
        let buckets = bucketRange(covered, overlap: overlap)
        var best = (start: 0, length: 0)
        var runStart: Int?
        var lastHit = 0
        var missed = 0
        for bucket in buckets {
            if covered[bucket] {
                if runStart == nil { runStart = bucket }
                lastHit = bucket
                missed = 0
            } else if active[bucket], runStart != nil {
                missed += 1
                if missed > gap, let start = runStart {
                    if lastHit - start + 1 > best.length { best = (start, lastHit - start + 1) }
                    runStart = nil
                    missed = 0
                }
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
