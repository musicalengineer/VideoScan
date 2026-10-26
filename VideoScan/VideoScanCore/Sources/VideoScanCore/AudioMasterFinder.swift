// AudioMasterFinder.swift (VideoScanCore)
// ONE SENTENCE: given one file's sound print, find every other content in
// the catalog whose sound lines up with it — the same recording, a longer
// recording it sits inside, a clip of it, or a shared stretch — and say so
// with the pair matcher's own evidence.
//
// TWO STAGES, ONE VERDICT (design provenance_retroactive_2026_10_26 §Phase A):
//   1. Candidates, cheaply: each query landmark (an even subsample of at
//      most `maxVotingLandmarks`) probes `AudioCatalogIndex` at its hash and
//      the dt ± `match.deltaFrameTolerance` neighbours, skips a hash longer
//      than `maxPostingsPerHash` catalog-wide (a hum, a click — it says
//      nothing about WHERE), and votes for (content, one-second offset
//      bin). A content's score is its best bin plus both neighbours. The
//      query's own content is never a candidate. The top `candidateCount`
//      with ≥ `minCandidateVotes` go on.
//   2. The verdict: each candidate's full print is loaded and asked through
//      `AudioFingerprintIndex(master:).match(query)` — byte-for-byte the
//      code Compare Media runs (rule 4: one engine per verb). `.different`
//      is dropped; the rest are ranked same › contained › contains ›
//      overlap › inconclusive, then by coverage, then matched landmarks.
// The finder never makes a verdict of its own; stage 1 can only lose a
// candidate (recall — the acceptance suite measures it), never invent one.
//
// MEMORY: the vote table holds one entry per (content, bin) touched: at most
// maxVotingLandmarks × (2·tol+1) × maxPostingsPerHash = 20,000 × 3 × 128
// = 7.7 M entries in the pathological case (≈ 150 MB transient, freed on
// return); typically < 1 MB. Stage 2 holds one candidate print and its
// pair index at a time (≈ 7 MB for an hour-long master).
//
// (For Rick: `rethrows` = the function throws only if the `load` closure
// you pass throws — like a template that is noexcept when its functor is.)

import Foundation

public struct AudioMasterFinderPolicy: Sendable, Equatable {
    /// Stage-2 pair matches per query.
    public var candidateCount = 10
    /// Stage-1 floor (stage 2 still needs `match.minMatchedLandmarks`).
    public var minCandidateVotes = 8
    /// A hash this common catalog-wide says nothing about WHERE.
    public var maxPostingsPerHash = 128
    /// Longer queries vote with an even subsample; stage 2 uses them all.
    public var maxVotingLandmarks = 20_000
    /// Frames per offset bin: 16 × 64 ms = 1.024 s.
    public var framesPerBin = 16
    /// The pair matcher's policy — the one verdict.
    public var match = AudioMatchPolicy.default
    public init() {}
    public static let `default` = AudioMasterFinderPolicy()
}

public struct AudioMasterCandidate: Sendable, Equatable {
    public let key: AudioFingerprintStore.Key
    /// From `AudioFingerprintIndex.match` — the one verdict.
    public let match: AudioMatch
    /// Stage-1 votes (for the report; never part of the verdict).
    public let votes: Int
    public init(key: AudioFingerprintStore.Key, match: AudioMatch, votes: Int) {
        self.key = key
        self.match = match
        self.votes = votes
    }
}

public enum AudioMasterRefusal: Sendable, Equatable {
    case otherRecipe(query: UInt32, index: UInt32)
    /// < policy.match.minMatchedLandmarks
    case tooLittleSound(landmarks: Int)
}

public enum AudioMasterSearch: Sendable, Equatable {
    /// Ranked; `.different` dropped. `searched` = searchable contents other
    /// than the query's own.
    case found([AudioMasterCandidate], searched: Int)
    case noneFound(searched: Int)
    case refused(AudioMasterRefusal)
}

public enum AudioMasterFinder {

    public static func find(query: AudioFingerprint, queryKey: AudioFingerprintStore.Key,
                            in index: AudioCatalogIndex,
                            load: (AudioFingerprintStore.Key) throws -> AudioFingerprint?,
                            policy: AudioMasterFinderPolicy = .default) rethrows -> AudioMasterSearch {
        let reference = AudioFingerprintParameters.default
        guard query.recipeID == index.recipeID, query.sampleRate == reference.sampleRate,
              query.hopSamples == reference.hopSamples, query.frameSize == reference.frameSize else {
            return .refused(.otherRecipe(query: query.recipeID, index: index.recipeID))
        }
        guard query.landmarkCount >= policy.match.minMatchedLandmarks else {
            return .refused(.tooLittleSound(landmarks: query.landmarkCount))
        }
        let own = index.ordinal(of: queryKey)
        let searched = index.searchableCount - (own.map { index.documents[$0].landmarks > 0 ? 1 : 0 } ?? 0)
        let ranked = candidates(query: query, excluding: own, in: index, policy: policy)
        var found: [AudioMasterCandidate] = []
        for (ordinal, votes) in ranked {
            let key = index.documents[ordinal].key
            guard let master = try load(key) else { continue }
            let match = AudioFingerprintIndex(master: master).match(query, policy: policy.match)
            if match.verdict == .different { continue }
            found.append(AudioMasterCandidate(key: key, match: match, votes: votes))
        }
        guard !found.isEmpty else { return .noneFound(searched: searched) }
        return .found(rank(found), searched: searched)
    }

    /// Stage 1: (ordinal, score) of the top `candidateCount` documents with
    /// ≥ `minCandidateVotes`, best first (ties by ordinal: deterministic).
    public static func candidates(query: AudioFingerprint, excluding own: Int?, in index: AudioCatalogIndex,
                                  policy: AudioMasterFinderPolicy = .default) -> [(ordinal: Int, votes: Int)] {
        let votes = vote(query: query, excluding: own, in: index, policy: policy)
        // Best bin plus both neighbours, per document.
        var best: [UInt32: Int] = [:]
        for (packed, count) in votes {
            let doc = UInt32(truncatingIfNeeded: packed >> 32)
            let bin = Int32(bitPattern: UInt32(truncatingIfNeeded: packed))
            let score = count + (votes[pack(doc, bin &- 1)] ?? 0) + (votes[pack(doc, bin &+ 1)] ?? 0)
            if score > best[doc, default: 0] { best[doc] = score }
        }
        return best.filter { $0.value >= policy.minCandidateVotes }
            .map { (ordinal: Int($0.key), votes: $0.value) }
            .sorted { $0.votes != $1.votes ? $0.votes > $1.votes : $0.ordinal < $1.ordinal }
            .prefix(policy.candidateCount)
            .map { $0 }
    }

    private static func vote(query: AudioFingerprint, excluding own: Int?, in index: AudioCatalogIndex,
                             policy: AudioMasterFinderPolicy) -> [UInt64: Int] {
        var votes: [UInt64: Int] = [:]
        let n = query.landmarkCount
        let cap = max(1, policy.maxVotingLandmarks)
        let tolerance = policy.match.deltaFrameTolerance
        let ownDoc = own.map(UInt32.init) ?? .max
        let binWidth = max(1, policy.framesPerBin)
        var i = 0.0
        let step = n > cap ? Double(n) / Double(cap) : 1
        while Int(i) < n {
            let hash = query.hashes[Int(i)]
            let t = Int(query.times[Int(i)])
            i += step
            let dt = Int(hash & 0x3F)
            for delta in -tolerance...tolerance {
                let probed = dt + delta
                guard probed >= 1, probed <= AudioFingerprintParameters.deltaFramesLimit else { continue }
                let h = UInt32(Int(hash) + delta)
                guard index.postingCount(of: h) <= policy.maxPostingsPerHash else { continue }
                for p in index.postings(of: h) where p.document != ownDoc && p != .unfilled {
                    let bin = floorDiv(Int(p.frame) - t, binWidth)
                    votes[pack(p.document, Int32(clamping: bin)), default: 0] += 1
                }
            }
        }
        return votes
    }

    /// Rank: verdict tier, then coverage, then matched landmarks, then key.
    public static func rank(_ found: [AudioMasterCandidate]) -> [AudioMasterCandidate] {
        found.sorted { a, b in
            let ta = tier(a.match.verdict), tb = tier(b.match.verdict)
            if ta != tb { return ta < tb }
            if a.match.coverage != b.match.coverage { return a.match.coverage > b.match.coverage }
            if a.match.matchedLandmarks != b.match.matchedLandmarks { return a.match.matchedLandmarks > b.match.matchedLandmarks }
            return a.key.contentDigest < b.key.contentDigest
        }
    }

    /// same › contained › contains › overlap › inconclusive › different.
    public static func tier(_ verdict: AudioMatchVerdict) -> Int {
        switch verdict {
        case .sameRecording: return 0
        case .containedInMaster: return 1
        case .masterContainedInQuery: return 2
        case .overlap: return 3
        case .inconclusive: return 4
        case .different: return 5
        }
    }

    private static func pack(_ doc: UInt32, _ bin: Int32) -> UInt64 {
        UInt64(doc) << 32 | UInt64(UInt32(bitPattern: bin))
    }

    private static func floorDiv(_ a: Int, _ b: Int) -> Int {
        a >= 0 ? a / b : -((-a + b - 1) / b)
    }
}
