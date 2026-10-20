// DuplicateGroupDigestSplit+Likeness.swift
// What an old duplicate group KNEW, kept as pairs (schema v1.11,
// `footage_likeness`; Rick approved the table 2026-10-19).
//
// An old group was a STAR: the duplicate check matched each member to its
// hub (the keeper). When the split takes a group of several whole-file
// digests apart, each of those assertions — "this content is alike to the
// keeper's" — becomes one pair, recorded in catalog.sqlite BEFORE the split
// runs:
//
//   hub        the keeper's content (else the first known digest);
//   per other  the best-scoring member pair across the two contents by the
//   content    duplicate check's own rule (DuplicateLikeness.score) —
//                lengths agree   → source 'duplicateCheck', its reasons
//                                  verbatim; 'anchored' when the sampled
//                                  hash, a specific timecode or a specific
//                                  name anchor it, else 'weak';
//                lengths differ  → NO pair: evidence says not the same (the
//                                  sampled-hash collision class);
//                no score today  → source 'oldGroup', 'weak', the member's
//                                  recorded group reasons verbatim — only
//                                  the old group remembered they matched.
//
// So after the split every file that left its copies group is still a copy
// in a new group, OR its content has a pair here, OR the evidence says it
// is a different length. Nothing the group knew is lost; nothing is
// invented (pairs follow the old star's edges, never all-pairs).
//
// Pure value code. Memory: one pair per non-hub content of a split group.
//
// (For Rick: an adjacency list built from a star — `hub` is the centre, one
// edge per other node, each edge labelled by how the scorer saw it.)

import Foundation
import VideoScanCore

extension DuplicateGroupDigestSplit {

    /// One likeness the split keeps, as `footage_likeness` will hold it.
    struct LikenessPair: Sendable, Equatable {
        /// `footage_likeness.strength`.
        enum Strength: String, Sendable { case weak, anchored }
        /// `footage_likeness.source`.
        enum Source: String, Sendable { case duplicateCheck, oldGroup }

        /// The content that leaves (or stays without the hub) and its file.
        var digest: String
        var filename: String
        /// The hub's content and its file.
        var hubDigest: String
        var hubFilename: String
        var reasons: String
        var strength: Strength
        var source: Source

        /// The row catalog.sqlite stores (ordered, lowercase).
        func row(recordedAt: Int64) -> CatalogRow.FootageLikeness {
            CatalogRow.FootageLikeness(digest, hubDigest, reasons: reasons, strength: strength.rawValue,
                                       source: source.rawValue, recordedAt: recordedAt)
        }

        /// "b.mov ~ a.mov (possible — timecode+duration)" for the log.
        var words: String {
            let how = strength == .weak ? "possible" : "likely"
            let from = source == .oldGroup ? "only the old group matched them: " : ""
            return "\(filename) ~ \(hubFilename) (\(how) — \(from)\(reasons.isEmpty ? "no reasons recorded" : reasons))"
        }
    }

    /// The pairs one old group leaves (see the file header). `keeper` is the
    /// group's kept member; nil = none. Members without a known digest are
    /// not known to differ and make no pair.
    static func likenessPairs(_ members: [MemberFact], keeper: MemberFact?,
                              isGenericName: (String) -> Bool = { FootageStem.isGenericName(FootageStem.analyze($0)) }) -> [LikenessPair] {
        var byDigest: [String: [MemberFact]] = [:]
        var order: [String] = []
        for m in members {
            guard let d = m.digest?.lowercased() else { continue }
            if byDigest[d] == nil { order.append(d) }
            byDigest[d, default: []].append(m)
        }
        guard order.count > 1 else { return [] }
        let keeperDigest = keeper?.digest?.lowercased()
        let hub = keeperDigest.flatMap { byDigest[$0] == nil ? nil : $0 } ?? order[0]
        let hubMembers = byDigest[hub] ?? []
        return order.filter { $0 != hub }.compactMap { d in
            pair(byDigest[d] ?? [], digest: d, hub: hubMembers, hubDigest: hub, isGenericName: isGenericName)
        }
    }

    /// One content against the hub: the best-scoring member pair decides.
    private static func pair(_ side: [MemberFact], digest: String, hub: [MemberFact], hubDigest: String,
                             isGenericName: (String) -> Bool) -> LikenessPair? {
        guard let first = side.first, let hubFirst = hub.first else { return nil }
        guard let best = bestScore(side, hub) else {
            // Today's rule does not pair them: only the old group remembers.
            let reasons = side.map(\.groupReasons).first { !$0.isEmpty } ?? ""
            return LikenessPair(digest: digest, filename: first.filename, hubDigest: hubDigest, hubFilename: hubFirst.filename,
                                reasons: reasons, strength: .weak, source: .oldGroup)
        }
        guard best.score.reasons.contains("duration") else { return nil }   // a different length: not the same
        let anchored = DuplicateLikeness.isAnchored(best.score.reasons, timecode: best.mover.timecode,
                                                    isGenericName: { isGenericName(best.mover.filename) })
        return LikenessPair(digest: digest, filename: best.mover.filename, hubDigest: hubDigest, hubFilename: best.other.filename,
                            reasons: best.score.reasons.joined(separator: "+"), strength: anchored ? .anchored : .weak,
                            source: .duplicateCheck)
    }

    private static func bestScore(_ side: [MemberFact], _ hub: [MemberFact])
        -> (mover: DuplicateLikeness.Facts, other: DuplicateLikeness.Facts, score: DuplicateLikeness.Score)? {
        var best: (mover: DuplicateLikeness.Facts, other: DuplicateLikeness.Facts, score: DuplicateLikeness.Score)?
        for m in side {
            guard let a = m.likeness else { continue }
            for h in hub {
                guard let b = h.likeness, let s = DuplicateLikeness.score(a, b) else { continue }
                if let current = best, s.points <= current.score.points { continue }
                best = (a, b, s)
            }
        }
        return best
    }
}
